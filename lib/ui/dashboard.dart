import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dashboard.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import '../core/library_index.dart' show LibraryIndex;
import 'file_results.dart';
import 'shortcuts.dart';
import 'tabs.dart';
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
    super.dispose();
  }

  /// `/` or Ctrl+F jumps to search (`/` not while typing); Esc leaves it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final typing =
        FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    final ctrlF = AppKeys.dashboardSearch.activators
        .whereType<SingleActivator>()
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

  /// The Files view: a hint without search text, else the matching files.
  Widget _filesBody({
    required bool searching,
    required bool loaded,
    required List<FileTile> files,
    required double size,
    required SearchFilter search,
  }) {
    if (!searching || (loaded && files.isEmpty)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(searching ? Icons.search_off : Icons.manage_search, size: 48),
            const SizedBox(height: 8),
            Text(searching ? 'No files match' : 'Type to search file names'),
          ],
        ),
      );
    }
    final settings = ref.read(settingsProvider.notifier);
    return CtrlWheelResize(
      onSteps: (n) =>
          settings.setImageThumbSize(imageThumbRange.nudge(size, n)),
      child: FileResultsGrid(
        key: const PageStorageKey('files'),
        files: files,
        tileSize: size,
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
    // The search can be cleared from elsewhere (a pack page's author link).
    ref.listen(dashboardQueryProvider.select((q) => q.text), (_, text) {
      if (text.isEmpty && _search.text.isNotEmpty) _search.clear();
    });
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
            onClear: () {
              _search.clear();
              notifier.clearFilters();
            },
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _ViewToggle(view: view, onChanged: settings.setDashboardView),
                const SizedBox(width: 12),
                // File results use the image card size.
                if (filesView)
                  ThumbSizeSlider(
                    range: imageThumbRange,
                    value: imageSize,
                    onChanged: settings.setImageThumbSize,
                  )
                else
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
                    onPressed: () => openPackDetail(
                      context,
                      bundle.id,
                      returnFocus: _gridFocus,
                    ),
                    icon: const Icon(Icons.info_outline, size: 18),
                    label: const Text('Bundle details'),
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
            child: filesView
                ? _filesBody(
                    searching: searching,
                    loaded: visibleFiles?.hasValue ?? false,
                    files: files,
                    size: imageSize,
                    search: search,
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
                      dashboardTileRange.nudge(tileSize, n),
                    ),
                    child: ThumbRows(
                      // Root and each bundle keep their own scroll position.
                      key: PageStorageKey(
                        'grid:${query.bundleId}:${view.name}',
                      ),
                      physics: const CtrlWheelPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      maxTileWidth: tileSize,
                      itemCount: tiles.length,
                      itemBuilder: (context, i) {
                        final DashboardTile(:tile, :pack, :folder) = tiles[i];
                        return OpenInNewTab(
                          key: ValueKey(tiles[i].key),
                          // Bundles open in place; their details have a
                          // button.
                          onOpenInNewTab: pack.isContainer
                              ? null
                              : () =>
                                    tabsNotifier.open(pack.id, folder: folder),
                          child: PackTile(
                            pack: tile,
                            subPackCount: subCounts[pack.id] ?? 0,
                            alwaysAnimate: animateAll,
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
                            onTap: pack.isContainer
                                ? () => notifier.openBundle(pack.id)
                                : () => openPackDetail(
                                    context,
                                    pack.id,
                                    folder: folder,
                                    returnFocus: _gridFocus,
                                  ),
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
      ButtonSegment(
        value: DashboardView.files,
        icon: Icon(Icons.insert_drive_file_outlined, size: 18),
        label: Text('Files'),
        tooltip: 'Files whose names match the search',
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
      ),
    ),
  );
}
