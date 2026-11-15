import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dashboard.dart';
import '../state/folder_tree.dart';
import '../state/favorites.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import '../core/library_index.dart' show LibraryIndex;
import 'cursors.dart';
import 'file_results.dart';
import 'folder_tree_panel.dart';
import 'shortcuts.dart';
import 'tabs.dart';
import 'pack_detail_screen.dart';
import 'session.dart';
import 'widgets/filter_bar.dart';
import 'widgets/thumb_size.dart';
import 'widgets/pack_tile.dart';

/// Width of the app bar's row of icon buttons, measured when it lays out
/// (null before that). The dashboard's size slider is made as wide.
final appBarActionsWidthProvider =
    NotifierProvider<AppBarActionsWidth, double?>(AppBarActionsWidth.new);

class AppBarActionsWidth extends Notifier<double?> {
  @override
  double? build() => null;

  void set(double width) => state = width;
}

/// Below this dashboard width the view toggle and the Author, Tag and
/// Source menus show only their icons (each keeps its tooltip), so the
/// search box keeps room at the 1024 px minimum.
const viewLabelsMinWidth = 1200.0;

/// The pack grid with search, filters and sorting.
class Dashboard extends ConsumerStatefulWidget {
  const Dashboard({super.key});

  @override
  ConsumerState<Dashboard> createState() => _DashboardState();
}

/// How many matching file names a pack tile's tooltip lists.
const fileMatchExamples = 10;

class _DashboardState extends ConsumerState<Dashboard> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'search');

  /// Holds focus when the search doesn't, so `/` and Ctrl+F keep working:
  /// leaving the search (Esc, a click elsewhere) and opening a pack move
  /// focus here instead of up to the page's focus scope, which is outside
  /// this widget's key handler.
  final _gridFocus = FocusNode(debugLabel: 'dashboard');

  /// The pack grid's and the file results' slider stops (M79).
  final _packScale = ThumbScale(dashboardTileRange);
  final _fileScale = ThumbScale(imageThumbRange, spacing: fileResultsSpacing);

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(dashboardQueryProvider).text;
  }

  final _tabFocus = TabFocus();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Back on the dashboard tab: `/` and Ctrl+F work again without a click.
    _tabFocus.update(context, () {
      if (!_gridFocus.hasFocus) _gridFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _gridFocus.dispose();
    _packScale.dispose();
    _fileScale.dispose();
    super.dispose();
  }

  /// `/` or Ctrl+F jumps to search (`/` not while typing); Esc leaves it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final typing =
        FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    final ctrlF = AppKeys.dashboardSearch.activators
        .whereType<PrimaryActivator>()
        .any((a) => a.accepts(event, HardwareKeyboard.instance));
    if (ctrlF || (AppKeys.dashboardSearch.pressed(event) && !typing)) {
      _searchFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (AppKeys.leaveSearch.pressed(event) && _searchFocus.hasFocus) {
      _gridFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Below this window width the folder tree overlays the grid instead of
  /// pushing it aside, and closes on a selection.
  static const treeOverlayBelow = 900.0;

  /// [child] (the grid or the file results) with the folder tree on its
  /// left while the tree is open (M98).
  Widget _withTree({required double windowWidth, required Widget child}) {
    if (!ref.watch(settingsProvider.select((s) => s.dashboardTreeOpen))) {
      return child;
    }
    final settings = ref.read(settingsProvider.notifier);
    final overlay = windowWidth < treeOverlayBelow;
    final panel = FolderTreePanel(
      onOpenPack: (packId, folder, newTab) {
        if (newTab) {
          ref.read(tabsProvider.notifier).open(packId, folder: folder);
        } else {
          openPackDetail(
            context,
            packId,
            folder: folder,
            returnFocus: _gridFocus,
          );
        }
      },
      onSelected: overlay ? () => settings.setDashboardTreeOpen(false) : null,
      onLeave: _gridFocus.requestFocus,
    );
    final side = FolderTreeSide(
      key: const ValueKey('folder-tree-panel'),
      panel: panel,
      maxWidth: windowWidth * 0.4,
    );
    if (overlay) {
      return Stack(
        children: [
          Positioned.fill(child: child),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Material(
              elevation: 6,
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: side,
            ),
          ),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        side,
        Expanded(child: child),
      ],
    );
  }

  /// The Files view: a hint without search text, else the matching files.
  Widget _filesBody({
    required bool searching,
    required bool favorites,
    required bool loaded,
    required List<FileTile> files,
    required double size,
    required SearchFilter search,
    required int generation,
  }) {
    final listing = searching || favorites;
    if (!listing || (loaded && files.isEmpty)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              !listing
                  ? Icons.manage_search
                  : favorites && !searching
                  ? Icons.star_border
                  : Icons.search_off,
              size: 48,
            ),
            const SizedBox(height: 8),
            Text(
              !listing
                  ? 'Type to search file names'
                  : favorites && !searching
                  ? 'No starred files'
                  : 'No files match',
            ),
          ],
        ),
      );
    }
    final settings = ref.read(settingsProvider.notifier);
    return CtrlWheelResize(
      onSteps: (n) => settings.setImageThumbSize(_fileScale.step(size, n)),
      child: FileResultsGrid(
        key: PageStorageKey('files:$generation'),
        files: files,
        // Hits that are animations play (M97), as cards do on a pack's
        // Animations tab.
        animations: ref.watch(fileAnimationsProvider).value ?? const {},
        playAll:
            ref.watch(settingsProvider.select((s) => s.detailAnimateMode)) ==
            AnimateMode.all,
        tileSize: size,
        scale: _fileScale,
        onOpen: (f) => openPackDetail(
          context,
          f.pack.id,
          search: search,
          file: f.relPath,
          returnFocus: _gridFocus,
        ),
        onOpenInNewTab: (f) => ref
            .read(tabsProvider.notifier)
            .open(f.pack.id, search: search, file: f.relPath),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The search can be cleared from elsewhere (a pack page's author link),
    // or set when the last session is resumed.
    ref.listen(dashboardQueryProvider.select((q) => q.text), (_, text) {
      if (text.isEmpty && _search.text.isNotEmpty) {
        _search.clear();
      } else if (text.isNotEmpty && _search.text.isEmpty) {
        _search.text = text;
      }
    });
    final query = ref.watch(dashboardQueryProvider);
    final notifier = ref.read(dashboardQueryProvider.notifier);
    final visible = ref.watch(visibleTilesProvider);
    final tiles = visible.value ?? const [];
    final view = ref.watch(settingsProvider.select((s) => s.dashboardView));
    final generation = ref.watch(libraryGenerationProvider);
    final searching = query.text.trim().isNotEmpty;
    final fileSearch = searching ? ref.watch(fileSearchProvider).value : null;
    final filesView = view == DashboardView.files;
    final visibleFiles = filesView ? ref.watch(visibleFilesProvider) : null;
    final files = visibleFiles?.value ?? const <FileTile>[];
    // A pack's first matching files, for its "N files match" line and its
    // tooltip.
    final examples = <String, List<String>>{};
    for (final h in fileSearch?.hits ?? const []) {
      final l = examples[h.packId] ??= [];
      if (l.length < fileMatchExamples) l.add(h.relPath);
    }
    final imageSize = imageThumbRange.clamp(
      ref.watch(settingsProvider.select((s) => s.imageThumbSize)),
    );
    final search = SearchFilter(query.text, infix: fileSearch?.infix ?? false);
    final theme = Theme.of(context);
    final animateAll = ref.watch(settingsProvider.select((s) => s.animateAll));
    final tileSize = dashboardTileRange.clamp(
      ref.watch(settingsProvider.select((s) => s.dashboardTileSize)),
    );
    final settings = ref.read(settingsProvider.notifier);
    final tabsNotifier = ref.read(tabsProvider.notifier);
    final favorites = ref.watch(favoritesProvider);
    final treeOpen = ref.watch(
      settingsProvider.select((s) => s.dashboardTreeOpen),
    );
    // Bundles (M95): their pack counts, and titles for their packs' tiles.
    final bundles = bundleInfo(ref.watch(libraryProvider).value?.packs);
    final sliderWidth = ref.watch(appBarActionsWidthProvider);
    // Larger text needs a wider window for the labels.
    final labelsMinWidth = MediaQuery.textScalerOf(context)
        .scale(viewLabelsMinWidth);

    return LayoutBuilder(
      builder: (context, box) {
        final narrow = box.maxWidth < labelsMinWidth;
        // Below 1000 px the size slider gives up its app-bar width, so the
        // search keeps room next to the folder tree toggle (M98).
        final slider = box.maxWidth < 1000
            ? math.min(sliderWidth ?? 120, 120.0)
            : sliderWidth;
        return Focus(
          focusNode: _gridFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilterBar(
                query: query,
                facets: ref.watch(facetsProvider),
                resultCount: filesView ? files.length : tiles.length,
                resultUnit: switch (view) {
                  DashboardView.packs => 'pack',
                  DashboardView.expanded => 'tile',
                  DashboardView.files => 'file',
                },
                searchController: _search,
                searchFocus: _searchFocus,
                onLeaveSearch: _gridFocus.requestFocus,
                onText: notifier.setText,
                onToggleType: notifier.toggleType,
                onToggleAuthor: notifier.toggleAuthor,
                onToggleTag: notifier.toggleTag,
                onToggleSource: notifier.toggleSource,
                onSort: notifier.setSort,
                onToggleFavorites: notifier.toggleFavorites,
                compact: narrow,
                onClear: () {
                  _search.clear();
                  notifier.clearFilters();
                },
                leading: switch (query.node) {
                  final node? => _NodeChip(
                    node: node,
                    onClear: () => notifier.setNode(null),
                  ),
                  null => null,
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: const ValueKey('folder-tree-toggle'),
                      tooltip: 'Folder tree',
                      isSelected: treeOpen,
                      icon: const Icon(Icons.account_tree_outlined),
                      selectedIcon: const Icon(Icons.account_tree),
                      onPressed: () => settings.setDashboardTreeOpen(!treeOpen),
                    ),
                    const SizedBox(width: 4),
                    _ViewToggle(
                      view: view,
                      labels: !narrow,
                      onChanged: settings.setDashboardView,
                    ),
                    const SizedBox(width: 12),
                    // File results use the image card size. As wide as the app
                    // bar's icons above it.
                    if (filesView)
                      ThumbSizeSlider(
                        key: const ValueKey('dashboard-size-slider'),
                        range: imageThumbRange,
                        value: imageSize,
                        width: slider,
                        scale: _fileScale,
                        onChanged: settings.setImageThumbSize,
                      )
                    else
                      ThumbSizeSlider(
                        key: const ValueKey('dashboard-size-slider'),
                        range: dashboardTileRange,
                        value: tileSize,
                        width: slider,
                        scale: _packScale,
                        onChanged: settings.setDashboardTileSize,
                      ),
                  ],
                ),
              ),
              if (filesView && (fileSearch?.capped ?? false))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    'Showing the first ${LibraryIndex.fileHitLimit} of '
                    '${fileSearch!.total} matching files — refine the search '
                    'to see the rest',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              Expanded(
                child: _withTree(
                  windowWidth: box.maxWidth,
                  child: filesView
                      ? _filesBody(
                          searching: searching,
                          favorites: query.favorites,
                          loaded: visibleFiles?.hasValue ?? false,
                          files: files,
                          size: imageSize,
                          search: search,
                          generation: generation,
                        )
                      : tiles.isEmpty && visible.hasValue
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
                            _packScale.step(tileSize, n),
                          ),
                          child: ThumbRows(
                            // Each view keeps its own scroll position.
                            key: PageStorageKey(
                              'grid:${view.name}:$generation',
                            ),
                            physics: const CtrlWheelPhysics(),
                            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                            maxTileWidth: tileSize,
                            scale: _packScale,
                            tileHeight: packTileMaxHeight,
                            itemCount: tiles.length,
                            itemBuilder: (context, i) {
                              final DashboardTile(:tile, :pack, :folder) =
                                  tiles[i];
                              return OpenInNewTab(
                                key: ValueKey(tiles[i].key),
                                onOpenInNewTab: () => tabsNotifier.open(
                                  pack.id,
                                  folder:
                                      folder ??
                                      nodeFolderIn(pack.id, query.node),
                                ),
                                child: PackTile(
                                  pack: tile,
                                  alwaysAnimate: animateAll,
                                  bundlePacks: bundles.counts[pack.id] ?? 0,
                                  subtitle: folder == null
                                      ? bundles.subtitle(pack)
                                      : null,
                                  starred:
                                      folder == null &&
                                      favorites.isPack(pack.id),
                                  onToggleStar: folder == null && !pack.isBundle
                                      ? () => ref
                                            .read(favoritesProvider.notifier)
                                            .togglePack(pack.id)
                                      : null,
                                  showTags: query.sort == PackSort.tags,
                                  fileMatches: folder == null
                                      ? fileMatchLine(
                                          fileSearch?.counts[pack.id] ?? 0,
                                          examples[pack.id] ?? const [],
                                        )
                                      : null,
                                  fileMatchesTooltip: fileMatchTooltip(
                                    fileSearch?.counts[pack.id] ?? 0,
                                    examples[pack.id] ?? const [],
                                  ),
                                  onFileMatchesTap: () => openPackDetail(
                                    context,
                                    pack.id,
                                    search: search,
                                    returnFocus: _gridFocus,
                                  ),
                                  onTap: () => openPackDetail(
                                    context,
                                    pack.id,
                                    // Inside a pack, the tree's node picks
                                    // where its page starts (M98).
                                    folder:
                                        folder ??
                                        nodeFolderIn(pack.id, query.node),
                                    returnFocus: _gridFocus,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The folder tree's node in the chip row: "In: Kenney › 2D assets" with ×.
class _NodeChip extends ConsumerWidget {
  const _NodeChip({required this.node, required this.onClear});

  final String node;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packs = ref.watch(libraryProvider).value?.packs ?? const [];
    final label = nodeLabel(node, packs);
    return InputChip(
      key: const ValueKey('node-chip'),
      avatar: const Icon(Icons.account_tree_outlined, size: 16),
      label: Text('In: ${middleEllipsis(label, 48)}'),
      tooltip: label,
      selected: true,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      deleteIcon: deleteIcon,
      onDeleted: onClear,
    );
  }
}

/// Packs or Expanded (one tile per character folder and the like).
class _ViewToggle extends StatelessWidget {
  const _ViewToggle({
    required this.view,
    required this.labels,
    required this.onChanged,
  });

  final DashboardView view;

  /// False: icons only (narrow windows).
  final bool labels;
  final ValueChanged<DashboardView> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<DashboardView>(
    showSelectedIcon: false,
    style: const ButtonStyle(
      visualDensity: VisualDensity.compact,
      mouseCursor: WidgetStatePropertyAll(SystemMouseCursors.click),
    ),
    segments: [
      ButtonSegment(
        value: DashboardView.packs,
        icon: const Icon(Icons.grid_view, size: 18),
        label: labels ? const Text('Packs') : null,
        tooltip: labels ? 'One tile per pack' : 'Packs: one tile per pack',
      ),
      ButtonSegment(
        value: DashboardView.expanded,
        icon: const Icon(Icons.view_comfy_alt_outlined, size: 18),
        label: labels ? const Text('Expanded') : null,
        tooltip:
            '${labels ? '' : 'Expanded: '}One tile per sub-folder of packs '
            'that are collections',
      ),
      ButtonSegment(
        value: DashboardView.files,
        icon: const Icon(Icons.insert_drive_file_outlined, size: 18),
        label: labels ? const Text('Files') : null,
        tooltip: labels
            ? 'Files whose names match the search'
            : 'Files: files whose names match the search',
      ),
    ],
    selected: {view},
    onSelectionChanged: (s) => onChanged(s.first),
  );
}

/// Opens a pack; with [folder], its Images and Animations tabs start at
/// that first-level folder; with [search], only matching files are listed
/// and [file] (a clicked result) opens on its tab. [returnFocus] gets the
/// focus back when the page closes.
void openPackDetail(
  BuildContext context,
  String packId, {
  String? folder,
  SearchFilter? search,
  String? file,
  FocusNode? returnFocus,
}) {
  // Leaving search focused would restore it on return without a live text
  // input connection; start from the grid instead (`/` refocuses).
  if (returnFocus != null) {
    returnFocus.requestFocus();
  } else {
    FocusManager.instance.primaryFocus?.unfocus();
  }
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PackDetailScreen(
        packId: packId,
        folder: folder,
        search: search,
        file: file,
        sessionKey: dashboardSessionKey,
      ),
    ),
  );
}
