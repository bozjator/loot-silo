import 'package:flutter/material.dart';

import '../../core/type_classifier.dart';
import '../../state/dashboard.dart';
import '../cursors.dart';
import '../format.dart';
import 'favorite_star.dart';

/// Search box, type chips, author / tag / source menus and sorting.
class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.query,
    required this.facets,
    required this.resultCount,
    this.resultUnit = 'pack',
    required this.searchController,
    required this.searchFocus,
    this.onLeaveSearch,
    required this.onText,
    required this.onToggleType,
    required this.onToggleAuthor,
    required this.onToggleTag,
    required this.onToggleSource,
    required this.onSort,
    required this.onClear,
    this.onToggleFavorites,
    this.trailing,
    this.compact = false,
  });

  final DashboardQuery query;
  final Facets facets;
  final int resultCount;

  /// What [resultCount] counts, singular.
  final String resultUnit;
  final TextEditingController searchController;
  final FocusNode searchFocus;

  /// A click outside the search field; unfocuses it when null.
  final VoidCallback? onLeaveSearch;
  final ValueChanged<String> onText;
  final ValueChanged<String> onToggleType;
  final ValueChanged<String> onToggleAuthor;
  final ValueChanged<String> onToggleTag;
  final ValueChanged<String> onToggleSource;
  final ValueChanged<PackSort> onSort;
  final VoidCallback onClear;

  /// Shows the Favorites chip (first among the chips) when set.
  final VoidCallback? onToggleFavorites;

  /// Shown after the sort menu, e.g. the tile size slider.
  final Widget? trailing;

  /// Narrow window: the Author, Tag and Source menus show only their icons
  /// (with a count badge when something is selected), so the search box
  /// keeps its room.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.colorScheme.onSurface.withValues(alpha: 0.45);
    final typeCounts = {for (final (t, n) in facets.types) t: n};
    final active = [
      for (final a in query.authors) (a, onToggleAuthor, Icons.person_outline),
      for (final t in query.tags) (t, onToggleTag, Icons.sell_outlined),
      for (final s in query.sources) (s, onToggleSource, Icons.input),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: searchController,
                  focusNode: searchFocus,
                  onChanged: onText,
                  onTapOutside: (_) {
                    if (!searchFocus.hasFocus) return;
                    (onLeaveSearch ?? searchFocus.unfocus)();
                  },
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search packs, authors, tags, file names   ( / )',
                    border: const OutlineInputBorder(),
                    // Follows the field, not the (debounced) query.
                    suffixIcon: ValueListenableBuilder(
                      valueListenable: searchController,
                      builder: (context, value, _) => value.text.isEmpty
                          ? const SizedBox.shrink()
                          : IconButton(
                              tooltip: 'Clear search',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                searchController.clear();
                                onText('');
                              },
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _FacetMenu(
                label: 'Author',
                compact: compact,
                icon: Icons.person_outline,
                values: facets.authors,
                selected: query.authors,
                onToggle: onToggleAuthor,
              ),
              _FacetMenu(
                label: 'Tag',
                compact: compact,
                icon: Icons.sell_outlined,
                values: facets.tags,
                selected: query.tags,
                onToggle: onToggleTag,
              ),
              _FacetMenu(
                label: 'Source',
                compact: compact,
                icon: Icons.input,
                values: facets.sources,
                selected: query.sources,
                onToggle: onToggleSource,
              ),
              const SizedBox(width: 8),
              DropdownButton<PackSort>(
                key: const ValueKey('sort-menu'),
                mouseCursor: clickCursor,
                dropdownMenuItemMouseCursor: clickCursor,
                value: query.sort,
                underline: const SizedBox(),
                // The sort icon sits left of the label (selectedItemBuilder);
                // padding and rounding keep the focus highlight off both.
                icon: const SizedBox.shrink(),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                borderRadius: BorderRadius.circular(8),
                selectedItemBuilder: (context) => [
                  for (final s in PackSort.values)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.sort, size: 20),
                        const SizedBox(width: 8),
                        Text(s.label),
                      ],
                    ),
                ],
                items: [
                  for (final s in PackSort.values)
                    DropdownMenuItem(value: s, child: Text(s.label)),
                ],
                onChanged: (s) => onSort(s!),
              ),
              if (trailing case final trailing?) ...[
                const SizedBox(width: 16),
                trailing,
              ],
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (onToggleFavorites case final toggle?)
                      FilterChip(
                        key: const ValueKey('favorites-chip'),
                        mouseCursor: clickCursor,
                        avatar: Icon(
                          query.favorites ? Icons.star : Icons.star_border,
                          size: 18,
                          color: FavoriteStar.color,
                        ),
                        showCheckmark: false,
                        tooltip: 'Favorites',
                        // Only the star and the count: `★ 12`.
                        label: Text(
                          formatCount(facets.favorites),
                          style: facets.favorites == 0
                              ? TextStyle(color: dim)
                              : null,
                        ),
                        visualDensity: VisualDensity.compact,
                        selected: query.favorites,
                        onSelected: (_) => toggle(),
                      ),
                    // Types no pack in view has are hidden, unless
                    // selected (then dimmed, at 0).
                    for (final t in AssetType.values)
                      if (typeCounts[t.id] ?? 0 case final count
                          when count > 0 || query.types.contains(t.id))
                        FilterChip(
                          mouseCursor: clickCursor,
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                t.id,
                                style: count == 0
                                    ? TextStyle(color: dim)
                                    : null,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '$count',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: dim,
                                ),
                              ),
                            ],
                          ),
                          visualDensity: VisualDensity.compact,
                          selected: query.types.contains(t.id),
                          onSelected: (_) => onToggleType(t.id),
                        ),
                    for (final (value, toggle, icon) in active)
                      // Coloured like a selected type chip, own icon kept.
                      InputChip(
                        avatar: Icon(icon, size: 16),
                        label: Text(value),
                        selected: true,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        deleteIcon: deleteIcon,
                        onDeleted: () => toggle(value),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$resultCount ${resultCount == 1 ? resultUnit : '${resultUnit}s'}',
                style: theme.textTheme.labelLarge,
              ),
              if (query.isFlat)
                TextButton(onPressed: onClear, child: const Text('Clear')),
            ],
          ),
        ],
      ),
    );
  }
}

class _FacetMenu extends StatelessWidget {
  const _FacetMenu({
    required this.label,
    required this.icon,
    required this.values,
    required this.selected,
    required this.onToggle,
    required this.compact,
  });

  final String label;
  final IconData icon;
  final bool compact;
  final List<(String, int)> values;
  final Set<String> selected;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      style: const MenuStyle(
        maximumSize: WidgetStatePropertyAll(Size(360, 480)),
      ),
      menuChildren: [
        for (final (value, count) in values)
          CheckboxMenuButton(
            value: selected.contains(value),
            closeOnActivate: false,
            onChanged: (_) => onToggle(value),
            // Selected, but nothing in view matches any more.
            child: Text(
              '$value  ($count)',
              style: count == 0
                  ? TextStyle(
                      color: Theme.of(context).colorScheme.onSurface
                          .withValues(alpha: 0.45),
                    )
                  : null,
            ),
          ),
      ],
      builder: (context, controller, _) {
        final onPressed = values.isEmpty
            ? null
            : () => controller.isOpen ? controller.close() : controller.open();
        if (compact) {
          return IconButton(
            tooltip: label,
            color: Theme.of(context).colorScheme.primary,
            onPressed: onPressed,
            icon: Badge(
              isLabelVisible: selected.isNotEmpty,
              label: Text('${selected.length}'),
              child: Icon(icon, size: 18),
            ),
          );
        }
        return TextButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 18),
          label: Text(selected.isEmpty ? label : '$label · ${selected.length}'),
        );
      },
    );
  }
}
