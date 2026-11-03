import 'package:flutter/material.dart';

import '../../core/type_classifier.dart';
import '../../state/dashboard.dart';

/// Search box, type chips, author / tag / source menus and sorting.
class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.query,
    required this.facets,
    required this.resultCount,
    required this.searchController,
    required this.searchFocus,
    required this.onText,
    required this.onToggleType,
    required this.onToggleAuthor,
    required this.onToggleTag,
    required this.onToggleSource,
    required this.onSort,
    required this.onClear,
  });

  final DashboardQuery query;
  final Facets facets;
  final int resultCount;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onText;
  final ValueChanged<String> onToggleType;
  final ValueChanged<String> onToggleAuthor;
  final ValueChanged<String> onToggleTag;
  final ValueChanged<String> onToggleSource;
  final ValueChanged<PackSort> onSort;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search packs, authors, tags, file names   ( / )',
                    border: const OutlineInputBorder(),
                    suffixIcon: query.text.isEmpty
                        ? null
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
              const SizedBox(width: 12),
              _FacetMenu(
                label: 'Author',
                icon: Icons.person_outline,
                values: facets.authors,
                selected: query.authors,
                onToggle: onToggleAuthor,
              ),
              _FacetMenu(
                label: 'Tag',
                icon: Icons.sell_outlined,
                values: facets.tags,
                selected: query.tags,
                onToggle: onToggleTag,
              ),
              _FacetMenu(
                label: 'Source',
                icon: Icons.input,
                values: facets.sources,
                selected: query.sources,
                onToggle: onToggleSource,
              ),
              const SizedBox(width: 8),
              DropdownButton<PackSort>(
                value: query.sort,
                underline: const SizedBox(),
                icon: const Icon(Icons.sort),
                items: [
                  for (final s in PackSort.values)
                    DropdownMenuItem(value: s, child: Text(s.label)),
                ],
                onChanged: (s) => onSort(s!),
              ),
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
                    for (final t in AssetType.values)
                      FilterChip(
                        label: Text(t.id),
                        visualDensity: VisualDensity.compact,
                        selected: query.types.contains(t.id),
                        onSelected: (_) => onToggleType(t.id),
                      ),
                    for (final (value, toggle, icon) in active)
                      InputChip(
                        avatar: Icon(icon, size: 16),
                        label: Text(value),
                        visualDensity: VisualDensity.compact,
                        onDeleted: () => toggle(value),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$resultCount ${resultCount == 1 ? 'pack' : 'packs'}',
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
  });

  final String label;
  final IconData icon;
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
            child: Text('$value  ($count)'),
          ),
      ],
      builder: (context, controller, _) => TextButton.icon(
        onPressed: values.isEmpty
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        icon: Icon(icon, size: 18),
        label: Text(selected.isEmpty ? label : '$label · ${selected.length}'),
      ),
    );
  }
}
