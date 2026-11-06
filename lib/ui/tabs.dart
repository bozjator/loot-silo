import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'cursors.dart';
import 'pack_detail_screen.dart';

/// Tracks a navigator's top route, so app-wide shortcuts can skip dialogs
/// and menus.
class TopRoute extends NavigatorObserver {
  Route<dynamic>? top;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      top = route;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      top = previousRoute;

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == top) top = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == top) top = newRoute;
  }
}

/// One open pack, with its own navigator so its pages keep their state
/// while another tab is shown.
class PackTab {
  PackTab(this.id, this.packId, {this.folder, this.search, this.file});

  /// Unique for the session; keys the tab's subtree.
  final int id;
  final String packId;
  final String? folder;
  final SearchFilter? search;
  final String? file;
  final navigator = GlobalKey<NavigatorState>(debugLabel: 'pack tab');
  final top = TopRoute();
}

/// The open pack tabs and which tab shows: 0 is the dashboard, `i + 1` is
/// `tabs[i]`. Session only; nothing is saved.
class Tabs {
  const Tabs(this.tabs, this.active);

  final List<PackTab> tabs;
  final int active;
}

final tabsProvider = NotifierProvider<TabsNotifier, Tabs>(TabsNotifier.new);

class TabsNotifier extends Notifier<Tabs> {
  /// The dashboard tab's navigator (plain clicks open packs on it).
  final dashboardNavigator = GlobalKey<NavigatorState>(debugLabel: 'dash');
  final dashboardTop = TopRoute();
  var _next = 0;

  @override
  Tabs build() => const Tabs([], 0);

  NavigatorState? get currentNavigator => switch (state.active) {
    0 => dashboardNavigator.currentState,
    final i => state.tabs[i - 1].navigator.currentState,
  };

  Route<dynamic>? get currentTop => switch (state.active) {
    0 => dashboardTop.top,
    final i => state.tabs[i - 1].top.top,
  };

  /// Opens [packId] in a new tab behind the current one; a pack that
  /// already has a tab is shown instead.
  void open(
    String packId, {
    String? folder,
    SearchFilter? search,
    String? file,
  }) {
    final at = state.tabs.indexWhere((t) => t.packId == packId);
    if (at >= 0) {
      select(at + 1);
      return;
    }
    state = Tabs([
      ...state.tabs,
      PackTab(_next++, packId, folder: folder, search: search, file: file),
    ], state.active);
  }

  void select(int index) {
    if (index < 0 || index > state.tabs.length) return;
    if (index != state.active) state = Tabs(state.tabs, index);
  }

  /// Closes pack tab [i]; closing the shown tab shows its left neighbour.
  void close(int i) {
    if (i < 0 || i >= state.tabs.length) return;
    final tabs = [...state.tabs]..removeAt(i);
    final shown = i + 1;
    final active = switch (state.active) {
      final a when a == shown => i,
      final a when a > shown => a - 1,
      final a => a,
    };
    state = Tabs(tabs, active);
  }

  /// Ctrl+W: the shown pack tab (never the dashboard).
  void closeCurrent() {
    if (state.active > 0) close(state.active - 1);
  }

  /// Ctrl+Tab / Ctrl+Shift+Tab, wrapping around.
  void cycle(int delta) {
    final n = state.tabs.length + 1;
    select((state.active + delta) % n);
  }

  /// The dashboard tab at its root page.
  void showDashboard() {
    select(0);
    dashboardNavigator.currentState?.popUntil((r) => r.isFirst);
  }
}

/// Whether the tab around a page is the shown one; pages take the focus
/// back when their tab is shown again.
class TabActive extends InheritedWidget {
  const TabActive({super.key, required this.active, required super.child});

  final bool active;

  /// True outside any tab (pages pushed on the root navigator, tests).
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabActive>()?.active ?? true;

  @override
  bool updateShouldNotify(TabActive old) => active != old.active;
}

/// Calls [focus] after a frame whenever the tab around [context] becomes
/// the shown one (and once at the start), if [context]'s route is the top
/// one of its tab. Use from `didChangeDependencies`.
class TabFocus {
  bool _wasActive = false;

  void update(BuildContext context, VoidCallback focus) {
    final active = TabActive.of(context);
    if (active && !_wasActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        if (ModalRoute.of(context)?.isCurrent == false) return;
        focus();
      });
    }
    _wasActive = active;
  }
}

/// The dashboard and the open packs, each on its own navigator; only the
/// shown one ticks, takes focus and gets pointer events.
class TabsHost extends ConsumerWidget {
  const TabsHost({super.key, required this.dashboard});

  /// The dashboard tab's first page.
  final Widget dashboard;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(tabsProvider);
    final notifier = ref.read(tabsProvider.notifier);
    Widget tab(
      Key key,
      bool active,
      GlobalKey<NavigatorState> navigator,
      TopRoute top,
      Widget page,
    ) => KeyedSubtree(
      key: key,
      child: TickerMode(
        enabled: active,
        child: ExcludeFocus(
          excluding: !active,
          child: TabActive(
            active: active,
            // Hidden tabs keep out of page transitions over the tabs: every
            // tab's Scaffold shows the app's snack bar, and two snack bar
            // heroes with one tag would assert.
            child: HeroMode(
              enabled: active,
              // Each navigator needs its own (or no) hero controller.
              child: HeroControllerScope.none(
                child: Navigator(
                  key: navigator,
                  observers: [top],
                  onGenerateRoute: (settings) => MaterialPageRoute<void>(
                    settings: settings,
                    builder: (_) => page,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return IndexedStack(
      index: tabs.active,
      children: [
        tab(
          const ValueKey('tab-dashboard'),
          tabs.active == 0,
          notifier.dashboardNavigator,
          notifier.dashboardTop,
          dashboard,
        ),
        for (final (i, t) in tabs.tabs.indexed)
          tab(
            ValueKey('tab-${t.id}'),
            tabs.active == i + 1,
            t.navigator,
            t.top,
            PackDetailScreen(
              packId: t.packId,
              folder: t.folder,
              search: t.search,
              file: t.file,
            ),
          ),
      ],
    );
  }
}

/// Dashboard plus one tab per open pack, under the app bar of the
/// dashboard and of pack pages. Shown only while a pack tab is open.
class PackTabStrip extends ConsumerWidget implements PreferredSizeWidget {
  const PackTabStrip({super.key});

  static const height = 40.0;

  @override
  Size get preferredSize => const Size.fromHeight(height);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tabs = ref.watch(tabsProvider);
    final notifier = ref.read(tabsProvider.notifier);
    final packs = ref.watch(libraryProvider).value?.packs ?? const [];
    // From a page pushed over the tabs (e.g. itch.io → a pack), a tab
    // click first goes back to the tabs.
    void show(int i) {
      Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
      notifier.select(i);
    }

    return SizedBox(
      height: height,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              _StripTab(
                key: const ValueKey('strip-dashboard'),
                label: 'Dashboard',
                icon: Icons.dashboard_outlined,
                selected: tabs.active == 0,
                onTap: () => show(0),
              ),
              for (final (i, t) in tabs.tabs.indexed)
                _StripTab(
                  key: ValueKey('strip-${t.id}'),
                  label:
                      packs.where((p) => p.id == t.packId).firstOrNull?.title ??
                      t.packId,
                  selected: tabs.active == i + 1,
                  onTap: () => show(i + 1),
                  onClose: () => notifier.close(i),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StripTab extends StatelessWidget {
  const _StripTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.onClose,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  /// Null for the dashboard, which can't be closed.
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme.labelLarge?.copyWith(
      color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: Listener(
        // Middle-click closes, as in a browser.
        onPointerDown: (e) {
          if (onClose != null && e.buttons & kMiddleMouseButton != 0) {
            onClose!();
          }
        },
        child: Tooltip(
          message: label,
          waitDuration: const Duration(milliseconds: 500),
          child: Material(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              mouseCursor: clickCursor,
              onTap: onTap,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  12,
                  6,
                  onClose == null ? 12 : 4,
                  6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, size: 18, color: text?.color),
                      const SizedBox(width: 6),
                    ],
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 220),
                      child: Text(
                        label,
                        style: text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (onClose != null) ...[
                      const SizedBox(width: 2),
                      IconButton(
                        tooltip: 'Close tab (Ctrl+W)',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints.tightFor(
                          width: 24,
                          height: 24,
                        ),
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close),
                        onPressed: onClose,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Middle-click, or "Open in new tab" from the right-click menu, calls
/// [onOpenInNewTab]; [child] keeps its own taps.
class OpenInNewTab extends StatelessWidget {
  const OpenInNewTab({
    super.key,
    required this.onOpenInNewTab,
    required this.child,
  });

  final VoidCallback? onOpenInNewTab;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final open = onOpenInNewTab;
    if (open == null) return child;
    return Listener(
      onPointerDown: (e) {
        if (e.buttons & kMiddleMouseButton != 0) open();
      },
      child: GestureDetector(
        onSecondaryTapUp: (details) async {
          final at = details.globalPosition;
          final choice = await showMenu<bool>(
            context: context,
            position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
            items: const [
              PopupMenuItem(
                value: true,
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.tab_outlined),
                  title: Text('Open in new tab'),
                  subtitle: Text('Middle-click'),
                ),
              ),
            ],
          );
          if (choice == true) open();
        },
        child: child,
      ),
    );
  }
}

/// An app bar's `bottom`: the tab strip while a pack tab is open, plus a
/// thin progress bar when [progress]; null when neither shows.
PreferredSizeWidget? tabStrip(WidgetRef ref, {bool progress = false}) {
  final shown = ref.watch(tabsProvider.select((t) => t.tabs.isNotEmpty));
  if (!shown && !progress) return null;
  return PreferredSize(
    preferredSize: Size.fromHeight(
      (shown ? PackTabStrip.height : 0) + (progress ? 4 : 0),
    ),
    child: Column(
      children: [
        if (shown) const PackTabStrip(),
        if (progress) const LinearProgressIndicator(),
      ],
    ),
  );
}
