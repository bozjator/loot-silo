import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/library_index.dart';
import '../state/dashboard.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'pack_detail_screen.dart';
import 'tabs.dart';

/// The session key of a pack page opened in the Dashboard tab; pack tabs
/// use [tabSessionKey].
const dashboardSessionKey = 'dashboard';

String tabSessionKey(PackTab tab) => 'tab-${tab.id}';

/// Keeps "Resume where I left off" up to date: pack pages report their
/// state here ([page]); with the tabs and the dashboard query it is saved
/// to `last_session` about a second after the last change, and at once on
/// [flush] (window close). Records nothing until [start].
class SessionKeeper {
  SessionKeeper(this._ref);

  final Ref _ref;
  final _pages = <String, PageSession>{};
  Timer? _timer;
  var _started = false;

  /// How long changes settle before they are written.
  static const delay = Duration(seconds: 1);

  bool get started => _started;

  /// Begins recording (after the restore, so it can't overwrite the saved
  /// session with an empty start).
  void start() {
    if (_started) return;
    _started = true;
    _changed();
  }

  /// A pack page's current state, under its session key.
  void page(String key, PageSession session) {
    if (_pages[key] == session) return;
    _pages[key] = session;
    _changed();
  }

  /// The page under [key] closed.
  void removePage(String key) {
    if (_pages.remove(key) != null) _changed();
  }

  void _changed() {
    if (!_started) return;
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  /// Writes the session now.
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (!_started) return;
    final settings = _ref.read(settingsProvider.notifier);
    if (!_ref.read(settingsProvider).resumeSession) return;
    settings.setLastSession(capture());
  }

  /// The session as it is now.
  LastSession capture() {
    final tabs = _ref.read(tabsProvider);
    final q = _ref.read(dashboardQueryProvider);
    return LastSession(
      tabs: [
        for (final t in tabs.tabs)
          _pages[tabSessionKey(t)] ??
              PageSession(packId: t.packId, folder: t.folder),
      ],
      active: tabs.active,
      dashboardPage: _pages[dashboardSessionKey],
      search: q.text,
      types: q.types.toList()..sort(),
      authors: q.authors.toList()..sort(),
      tags: q.tags.toList()..sort(),
      sources: q.sources.toList()..sort(),
      favorites: q.favorites,
      sort: q.sort == PackSort.relevance ? null : q.sort.name,
      bundleId: q.bundleId,
    );
  }

  void dispose() => _timer?.cancel();
}

final sessionKeeperProvider = Provider<SessionKeeper>((ref) {
  final keeper = SessionKeeper(ref);
  ref.onDispose(keeper.dispose);
  ref.listen(tabsProvider, (_, _) => keeper._changed());
  ref.listen(dashboardQueryProvider, (_, _) => keeper._changed());
  return keeper;
});

/// [session]'s dashboard query, without values no pack in [packs] has: an
/// unknown tag isn't selected, a removed bundle isn't opened.
DashboardQuery restoredQuery(LastSession session, List<PackRow> packs) {
  final types = {for (final p in packs) ...p.types};
  final authors = {for (final p in packs) p.author ?? ''};
  final tags = {for (final p in packs) ...p.tags};
  final sources = {noSource, for (final p in packs) ?p.source};
  final bundles = {
    for (final p in packs)
      if (p.isContainer) p.id,
  };
  return DashboardQuery(
    text: session.search,
    types: {...session.types.where(types.contains)},
    authors: {...session.authors.where(authors.contains)},
    tags: {...session.tags.where(tags.contains)},
    sources: {...session.sources.where(sources.contains)},
    favorites: session.favorites,
    sort: PackSort.values.asNameMap()[session.sort] ?? PackSort.relevance,
    bundleId: bundles.contains(session.bundleId) ? session.bundleId : null,
  );
}

/// Restores the saved session once the library has loaded (when "Resume
/// where I left off" is on), then starts recording it; flushes it when the
/// app is asked to exit. A library that fails to load restores nothing.
class SessionHost extends ConsumerStatefulWidget {
  const SessionHost({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SessionHost> createState() => _SessionHostState();
}

class _SessionHostState extends ConsumerState<SessionHost> {
  late final AppLifecycleListener _lifecycle;
  var _restored = false;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        ref.read(sessionKeeperProvider).flush();
        return AppExitResponse.exit;
      },
      onDetach: () => ref.read(sessionKeeperProvider).flush(),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeRestore(ref.read(libraryProvider));
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  void _maybeRestore(AsyncValue<LibraryState> library) {
    if (_restored || library.isLoading) return;
    final value = library.value;
    if (library.hasError || value == null || value.root == null) {
      // A missing library shows the recovery screen: nothing is restored,
      // and what the session is from now on is saved.
      if (library.hasError) {
        _restored = true;
        ref.read(sessionKeeperProvider).start();
      }
      return;
    }
    _restored = true;
    final settings = ref.read(settingsProvider);
    final saved = settings.lastSession;
    if (settings.resumeSession && saved != null) _restore(saved, value.packs);
    ref.read(sessionKeeperProvider).start();
  }

  void _restore(LastSession session, List<PackRow> packs) {
    final ids = {for (final p in packs) p.id};
    ref
        .read(dashboardQueryProvider.notifier)
        .restore(restoredQuery(session, packs));
    final tabs = ref.read(tabsProvider.notifier);
    var active = 0;
    var kept = 0;
    for (final (i, t) in session.tabs.indexed) {
      if (!ids.contains(t.packId)) continue;
      kept++;
      tabs.open(t.packId, folder: t.folder, restore: t);
      if (session.active == i + 1) active = kept;
    }
    tabs.select(active);
    final page = session.dashboardPage;
    if (page != null && ids.contains(page.packId)) {
      // The Dashboard tab's navigator exists once the tabs are built.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        tabs.dashboardNavigator.currentState?.push(
          MaterialPageRoute<void>(
            builder: (_) => PackDetailScreen(
              packId: page.packId,
              folder: page.folder,
              sessionKey: dashboardSessionKey,
              restore: page,
            ),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(libraryProvider, (_, next) => _maybeRestore(next));
    return widget.child;
  }
}
