import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dashboard.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'pack_detail_screen.dart';
import 'widgets/filter_bar.dart';
import 'widgets/thumb_size.dart';
import 'widgets/pack_tile.dart';

/// The pack grid with search, filters, sorting and bundle browsing.
class Dashboard extends ConsumerStatefulWidget {
  const Dashboard({super.key});

  @override
  ConsumerState<Dashboard> createState() => _DashboardState();
}

class _DashboardState extends ConsumerState<Dashboard> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'search');

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(dashboardQueryProvider).text;
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// `/` or Ctrl+F jumps to search (`/` not while typing); Esc leaves it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final typing =
        FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    final ctrlF =
        event.logicalKey == LogicalKeyboardKey.keyF &&
        HardwareKeyboard.instance.isControlPressed;
    if (ctrlF || (event.logicalKey == LogicalKeyboardKey.slash && !typing)) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        _searchFocus.hasFocus) {
      _searchFocus.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(dashboardQueryProvider);
    final notifier = ref.read(dashboardQueryProvider.notifier);
    final visible = ref.watch(visibleTilesProvider);
    final library = ref.watch(libraryProvider).value;
    final allPacks = library?.packs ?? const [];
    final subCounts = <String, int>{};
    for (final pk in allPacks) {
      if (pk.parentId != null) {
        subCounts[pk.parentId!] = (subCounts[pk.parentId!] ?? 0) + 1;
      }
    }
    final bundle = query.bundleId == null
        ? null
        : allPacks.where((p) => p.id == query.bundleId).firstOrNull;
    final tiles = visible.value ?? const [];
    final view = ref.watch(settingsProvider.select((s) => s.dashboardView));
    final theme = Theme.of(context);
    final animateAll = ref.watch(settingsProvider.select((s) => s.animateAll));
    final tileSize = dashboardTileRange.clamp(
      ref.watch(settingsProvider.select((s) => s.dashboardTileSize)),
    );
    final settings = ref.read(settingsProvider.notifier);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterBar(
            query: query,
            facets: ref.watch(facetsProvider),
            resultCount: tiles.length,
            resultUnit: view == DashboardView.expanded ? 'tile' : 'pack',
            searchController: _search,
            searchFocus: _searchFocus,
            onText: notifier.setText,
            onToggleType: notifier.toggleType,
            onToggleAuthor: notifier.toggleAuthor,
            onToggleTag: notifier.toggleTag,
            onToggleSource: notifier.toggleSource,
            onSort: notifier.setSort,
            onClear: () {
              _search.clear();
              notifier.clearFilters();
            },
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ViewToggle(view: view, onChanged: settings.setDashboardView),
                const SizedBox(width: 12),
                ThumbSizeSlider(
                  range: dashboardTileRange,
                  value: tileSize,
                  onChanged: settings.setDashboardTileSize,
                ),
              ],
            ),
          ),
          if (bundle != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => notifier.openBundle(null),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('All packs'),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      '${bundle.title} · ${bundle.author ?? ''}',
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => openPackDetail(context, bundle.id),
                    icon: const Icon(Icons.info_outline, size: 18),
                    label: const Text('Bundle details'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: tiles.isEmpty && visible.hasValue
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.search_off, size: 48),
                        const SizedBox(height: 8),
                        const Text('No packs match'),
                        TextButton(
                          onPressed: () {
                            _search.clear();
                            notifier.clearFilters();
                          },
                          child: const Text('Clear search and filters'),
                        ),
                      ],
                    ),
                  )
                : CtrlWheelResize(
                    onSteps: (n) => settings.setDashboardTileSize(
                      dashboardTileRange.nudge(tileSize, n),
                    ),
                    child: GridView.builder(
                      // Root and each bundle keep their own scroll position.
                      key: PageStorageKey(
                        'grid:${query.bundleId}:${view.name}',
                      ),
                      physics: const CtrlWheelPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      // A 4:3 preview over a footer for title, author and
                      // types; narrow tiles get room for a second chip row.
                      gridDelegate: ThumbGridDelegate(
                        maxTileWidth: tileSize,
                        imageAspect: 4 / 3,
                        footer: (w) =>
                            (w < 190 ? 148 : 120) +
                            (query.sort == PackSort.tags ? tagsLineHeight : 0),
                        footerKey: query.sort == PackSort.tags,
                      ),
                      itemCount: tiles.length,
                      itemBuilder: (context, i) {
                        final DashboardTile(:tile, :pack, :folder) = tiles[i];
                        return PackTile(
                          key: ValueKey(tiles[i].key),
                          pack: tile,
                          subPackCount: subCounts[pack.id] ?? 0,
                          alwaysAnimate: animateAll,
                          showTags: query.sort == PackSort.tags,
                          onTap: pack.isContainer
                              ? () => notifier.openBundle(pack.id)
                              : () => openPackDetail(
                                  context,
                                  pack.id,
                                  folder: folder,
                                ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Packs or Expanded (one tile per character folder and the like).
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});

  final DashboardView view;
  final ValueChanged<DashboardView> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<DashboardView>(
    showSelectedIcon: false,
    style: const ButtonStyle(
      visualDensity: VisualDensity.compact,
      mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
    ),
    segments: const [
      ButtonSegment(
        value: DashboardView.packs,
        icon: Icon(Icons.grid_view, size: 18),
        label: Text('Packs'),
        tooltip: 'One tile per pack',
      ),
      ButtonSegment(
        value: DashboardView.expanded,
        icon: Icon(Icons.view_comfy_alt_outlined, size: 18),
        label: Text('Expanded'),
        tooltip: 'One tile per sub-folder of packs that are collections',
      ),
    ],
    selected: {view},
    onSelectionChanged: (s) => onChanged(s.first),
  );
}

/// Opens a pack; with [folder], its Images and Animations tabs start at
/// that first-level folder.
void openPackDetail(BuildContext context, String packId, {String? folder}) {
  // Leaving search focused would restore it on return without a live text
  // input connection; start from the grid instead (`/` refocuses).
  FocusManager.instance.primaryFocus?.unfocus();
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PackDetailScreen(packId: packId, folder: folder),
    ),
  );
}
