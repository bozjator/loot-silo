import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'cursors.dart';
import '../state/settings.dart';
import 'pack_detail_screen.dart';
import 'session.dart';
import 'widgets/dialog_close.dart';

/// Tracks a navigator's top route, so app-wide shortcuts can skip dialogs
/// and menus, and how many pages ([PageRoute]s, not menus) it holds.
class TopRoute extends NavigatorObserver {
  Route<dynamic>? top;

  /// Pages on the navigator; 1 means it shows its first page.
  final pages = ValueNotifier<int>(0);

  void _count(Route<dynamic> route, int delta) {
    if (route is! PageRoute) return;
    void apply() => pages.value = math.max(0, pages.value + delta);
    // Navigators push their first page while building; listeners may not
    // rebuild then.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    top = route;
    _count(route, 1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    top = previousRoute;
    _count(route, -1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route == top) top = previousRoute;
    _count(route, -1);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == top) top = newRoute;
  }
}

/// One open pack, with its own navigator so its pages keep their state
/// while another tab is shown.
class PackTab {
  PackTab(
    this.id,
    this.packId, {
    this.folder,
    this.search,
    this.file,
    this.restore,
  });

  /// Unique for the session; keys the tab's subtree.
  final int id;
  final String packId;
  final String? folder;
  final SearchFilter? search;
  final String? file;

  /// The page's saved state, when the tab is resumed from the last session.
  final PageSession? restore;
  final navigator = GlobalKey<NavigatorState>(debugLabel: 'pack tab');
  final top = TopRoute();
}

/// The open pack tabs and which tab shows: 0 is the dashboard, `i + 1` is
/// `tabs[i]`. Saved for the next start by the session keeper.
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
    PageSession? restore,
  }) {
    final at = state.tabs.indexWhere((t) => t.packId == packId);
    if (at >= 0) {
      select(at + 1);
      return;
    }
    state = Tabs([
      ...state.tabs,
      PackTab(
        _next++,
        packId,
        folder: folder,
        search: search,
        file: file,
        restore: restore,
      ),
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

  /// Moves pack tab [from] to index [to] (both before the move); the
  /// shown tab stays shown.
  void move(int from, int to) {
    final n = state.tabs.length;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    final shown = state.active > 0 ? state.tabs[state.active - 1] : null;
    final tabs = [...state.tabs];
    tabs.insert(to, tabs.removeAt(from));
    state = Tabs(tabs, shown == null ? 0 : tabs.indexOf(shown) + 1);
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
              sessionKey: tabSessionKey(t),
              restore: t.restore,
            ),
          ),
      ],
    );
  }
}

/// Dashboard plus one tab per open pack, under the app bar of the
/// dashboard and of pack pages. Shown only while a pack tab is open.
///
/// The Dashboard tab stays put; the pack tabs scroll (mouse wheel or the
/// arrows that show when they don't fit), and the list button jumps to
/// any of them. The shown tab, or a newly opened one, scrolls into view.
class PackTabStrip extends ConsumerStatefulWidget {
  const PackTabStrip({super.key});

  static const height = 40.0;

  @override
  ConsumerState<PackTabStrip> createState() => _PackTabStripState();
}

class _PackTabStripState extends ConsumerState<PackTabStrip> {
  final _scroll = ScrollController();
  final _keys = <int, GlobalKey>{};
  var _overflows = false;
  var _canLeft = false;
  var _canRight = false;

  /// Each arrow and the list button are this wide.
  static const _controlSize = 28.0;
  static const _controlsWidth = 3 * _controlSize;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateArrows();
      final tabs = ref.read(tabsProvider);
      if (tabs.active > 0) {
        _reveal(tabs.tabs[tabs.active - 1].id, animate: false);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (!p.hasContentDimensions) return;
    // Judged against the room the tabs would have without the arrows, or
    // showing the arrows could itself keep the tabs from fitting.
    final content = p.maxScrollExtent - p.minScrollExtent + p.viewportDimension;
    final room = p.viewportDimension + (_overflows ? _controlsWidth : 0);
    final over = content > room + 0.5;
    final left = over && p.pixels > p.minScrollExtent + 0.5;
    final right = over && p.pixels < p.maxScrollExtent - 0.5;
    if (over == _overflows && left == _canLeft && right == _canRight) return;
    final appeared = over && !_overflows;
    setState(() {
      _overflows = over;
      _canLeft = left;
      _canRight = right;
    });
    // The arrows take room from the tabs: show the last revealed one again.
    final last = _revealed;
    if (appeared && last != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal(last, animate: false);
      });
    }
  }

  /// The tab last scrolled into view.
  int? _revealed;

  /// Scrolls just enough to show the whole tab [id].
  void _reveal(int id, {bool animate = true}) {
    _revealed = id;
    final box = _keys[id]?.currentContext?.findRenderObject();
    if (box == null || !_scroll.hasClients || !box.attached) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final p = _scroll.position;
    final atStart = viewport.getOffsetToReveal(box, 0).offset;
    final atEnd = viewport.getOffsetToReveal(box, 1).offset;
    var to = p.pixels;
    if (to > atStart) {
      to = atStart;
    } else if (to < atEnd) {
      to = atEnd;
    }
    to = to.clamp(p.minScrollExtent, p.maxScrollExtent);
    if ((to - p.pixels).abs() < 0.5) return;
    if (animate) {
      _scroll.animateTo(
        to,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(to);
    }
  }

  /// About most of the visible width, so one click moves a page.
  void _page(int dir) {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final to = (p.pixels + dir * p.viewportDimension * 0.8).clamp(
      p.minScrollExtent,
      p.maxScrollExtent,
    );
    _scroll.animateTo(
      to,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  /// The wheel scrolls the tabs sideways, as vertical wheels can't.
  void _wheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (p.maxScrollExtent <= p.minScrollExtent) return;
    GestureBinding.instance.pointerSignalResolver.register(e, (e) {
      final d = (e as PointerScrollEvent).scrollDelta;
      final delta = d.dx.abs() > d.dy.abs() ? d.dx : d.dy;
      _scroll.jumpTo(
        (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabs = ref.watch(tabsProvider);
    final notifier = ref.read(tabsProvider.notifier);
    final packs = ref.watch(libraryProvider).value?.packs ?? const [];
    String label(PackTab t) =>
        packs.where((p) => p.id == t.packId).firstOrNull?.title ?? t.packId;

    // From a page pushed over the tabs (e.g. itch.io → a pack), a tab
    // click first goes back to the tabs. The Dashboard tab also goes back
    // from a pack opened in it to the dashboard itself.
    void show(int i) {
      Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
      if (i == 0) {
        notifier.showDashboard();
      } else {
        notifier.select(i);
      }
    }

    _keys.removeWhere((id, _) => !tabs.tabs.any((t) => t.id == id));
    for (final t in tabs.tabs) {
      _keys.putIfAbsent(t.id, () => GlobalKey(debugLabel: 'strip-${t.id}'));
    }

    final overflows = _overflows;
    Widget arrow(IconData icon, String tip, bool enabled, int dir) =>
        IconButton(
          tooltip: tip,
          iconSize: 20,
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          constraints: const BoxConstraints.tightFor(
            width: _controlSize,
            height: _controlSize,
          ),
          padding: EdgeInsets.zero,
          icon: Icon(icon),
          onPressed: enabled ? () => _page(dir) : null,
        );

    return SizedBox(
      height: PackTabStrip.height,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // Selected only while it shows the dashboard itself, not a
            // pack opened in it.
            ValueListenableBuilder(
              valueListenable: notifier.dashboardTop.pages,
              builder: (context, pages, _) => _StripTab(
                key: const ValueKey('strip-dashboard'),
                label: 'Dashboard',
                icon: Icons.dashboard_outlined,
                selected: tabs.active == 0 && pages <= 1,
                onTap: () => show(0),
              ),
            ),
            if (overflows)
              arrow(Icons.chevron_left, 'Scroll tabs left', _canLeft, -1),
            Flexible(
              child: Listener(
                onPointerSignal: _wheel,
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: (_) {
                    _updateArrows();
                    return false;
                  },
                  child: _RevealOnChange(
                    tabs: tabs,
                    reveal: _reveal,
                    // Drag a pack tab to move it; a click without moving
                    // still selects it.
                    child: ReorderableListView.builder(
                      key: const ValueKey('strip-scroll'),
                      scrollController: _scroll,
                      scrollDirection: Axis.horizontal,
                      buildDefaultDragHandles: false,
                      // Every tab is built, so any can be scrolled into view.
                      scrollCacheExtent: const ScrollCacheExtent.pixels(1e6),
                      itemCount: tabs.tabs.length,
                      onReorderItem: notifier.move,
                      proxyDecorator: (child, _, _) => Material(
                        type: MaterialType.transparency,
                        child: child,
                      ),
                      itemBuilder: (context, i) {
                        final t = tabs.tabs[i];
                        return ReorderableDragStartListener(
                          key: ValueKey('strip-${t.id}'),
                          index: i,
                          child: KeyedSubtree(
                            key: _keys[t.id],
                            child: Center(
                              child: _StripTab(
                                label: label(t),
                                selected: tabs.active == i + 1,
                                onTap: () => show(i + 1),
                                onClose: () => notifier.close(i),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            if (overflows) ...[
              arrow(Icons.chevron_right, 'Scroll tabs right', _canRight, 1),
              SizedBox.square(
                key: const ValueKey('strip-all'),
                dimension: _controlSize,
                child: PopupMenuButton<int>(
                  tooltip: 'All tabs',
                  iconSize: 20,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    minimumSize: const Size.square(_controlSize),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const Icon(Icons.keyboard_arrow_down),
                  onSelected: show,
                  itemBuilder: (_) => [
                    for (final (i, t) in tabs.tabs.indexed)
                      CheckedPopupMenuItem(
                        value: i + 1,
                        checked: tabs.active == i + 1,
                        child: Text(
                          label(t),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// After a frame where the shown tab changed or a tab was opened, scrolls
/// that tab into view.
class _RevealOnChange extends StatefulWidget {
  const _RevealOnChange({
    required this.tabs,
    required this.reveal,
    required this.child,
  });

  final Tabs tabs;
  final void Function(int id) reveal;
  final Widget child;

  @override
  State<_RevealOnChange> createState() => _RevealOnChangeState();
}

class _RevealOnChangeState extends State<_RevealOnChange> {
  static int? _shownId(Tabs t) => t.active > 0 ? t.tabs[t.active - 1].id : null;

  @override
  void didUpdateWidget(_RevealOnChange old) {
    super.didUpdateWidget(old);
    final now = widget.tabs;
    final before = old.tabs;
    final shown = now.active > 0 ? now.tabs[now.active - 1].id : null;
    final id = shown != null && shown != _shownId(before)
        ? shown
        // A new tab, normally opened behind the shown one: show it's there.
        : now.tabs
              .where((t) => !before.tabs.any((b) => b.id == t.id))
              .lastOrNull
              ?.id;
    if (id == null) return;
    final target = id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.reveal(target);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
    // On the left on macOS, as in Safari and Finder.
    final left = closeOnLeft(context);
    final close = onClose == null
        ? null
        : IconButton(
            tooltip: 'Close tab (Ctrl+W)',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 24, height: 24),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close),
            onPressed: onClose,
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
                  close != null && left ? 4 : 12,
                  6,
                  close != null && !left ? 4 : 12,
                  6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (close != null && left) ...[
                      close,
                      const SizedBox(width: 2),
                    ],
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
                    if (close != null && !left) ...[
                      const SizedBox(width: 2),
                      close,
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
