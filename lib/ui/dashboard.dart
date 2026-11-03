import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/dashboard.dart';
import '../state/providers.dart';
import 'widgets/filter_bar.dart';
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

  /// `/` jumps to search from anywhere except a text field; Esc leaves it.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final typing =
        FocusManager.instance.primaryFocus?.context?.widget is EditableText;
    if (event.logicalKey == LogicalKeyboardKey.slash && !typing) {
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
    final visible = ref.watch(visiblePacksProvider);
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
    final packs = visible.value ?? const [];
    final theme = Theme.of(context);

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilterBar(
            query: query,
            facets: ref.watch(facetsProvider),
            resultCount: packs.length,
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
                  Expanded(
                    child: Text(
                      '${bundle.title} · ${bundle.author ?? ''}',
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: packs.isEmpty && visible.hasValue
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
                : GridView.builder(
                    // Root and each bundle keep their own scroll position.
                    key: PageStorageKey('grid:${query.bundleId}'),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 240,
                          childAspectRatio: 0.8,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                        ),
                    itemCount: packs.length,
                    itemBuilder: (context, i) {
                      final pack = packs[i];
                      return PackTile(
                        key: ValueKey(pack.id),
                        pack: pack,
                        subPackCount: subCounts[pack.id] ?? 0,
                        onTap: pack.isContainer
                            ? () => notifier.openBundle(pack.id)
                            : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
