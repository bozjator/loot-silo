import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/file_search.dart';
import 'cursors.dart';
import 'widgets/pixel_image.dart';

/// Lets the user choose a pack's previews: click images in the grid to add
/// or remove them, drag the chosen ones (the strip at the top) to reorder.
/// The first is the tile cover. Pops the new list, in order (empty: back
/// to automatic), or null when cancelled.
///
/// [files] are every image and animation of the pack; [initial] what the
/// header shows now; [custom] whether [initial] was chosen by the user
/// (else it is the automatic pick, and "Reset to automatic" is off).
class PreviewPickerDialog extends StatefulWidget {
  const PreviewPickerDialog({
    super.key,
    required this.packPath,
    required this.files,
    required this.initial,
    required this.custom,
  });

  final String packPath;
  final List<String> files;
  final List<String> initial;
  final bool custom;

  @override
  State<PreviewPickerDialog> createState() => _PreviewPickerDialogState();
}

class _PreviewPickerDialogState extends State<PreviewPickerDialog> {
  late final _chosen = [...widget.initial];
  var _filter = '';

  bool get _changed {
    final a = widget.initial;
    if (a.length != _chosen.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != _chosen[i]) return true;
    }
    return false;
  }

  void _toggle(String f) => setState(() {
    if (!_chosen.remove(f)) _chosen.add(f);
  });

  Widget _thumb(String rel) => PixelImage(File(p.join(widget.packPath, rel)));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final words = queryWords(_filter);
    final shown = words.isEmpty
        ? widget.files
        : [
            for (final f in widget.files)
              if (fileMatches(f, words, infix: true)) f,
          ];
    final order = {for (final (i, f) in _chosen.indexed) f: i};
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100, maxHeight: 900),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Choose previews',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                'Click images to add or remove them. Drag the chosen ones '
                'to change their order; the first is the pack\'s cover.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            SizedBox(
              height: 112,
              child: _chosen.isEmpty
                  ? Center(
                      child: Text(
                        'None chosen: previews are picked automatically.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ReorderableListView.builder(
                      key: const ValueKey('chosen-previews'),
                      scrollDirection: Axis.horizontal,
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _chosen.length,
                      onReorderItem: (from, to) => setState(
                        () => _chosen.insert(to, _chosen.removeAt(from)),
                      ),
                      itemBuilder: (context, i) {
                        final f = _chosen[i];
                        return ReorderableDragStartListener(
                          key: ValueKey('chosen:$f'),
                          index: i,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.grab,
                            child: Tooltip(
                              message: f,
                              waitDuration: const Duration(milliseconds: 600),
                              child: Container(
                                width: 132,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: scheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: i == 0
                                        ? scheme.primary
                                        : scheme.outlineVariant,
                                    width: i == 0 ? 2 : 1,
                                  ),
                                ),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.all(6),
                                      child: _thumb(f),
                                    ),
                                    Positioned(
                                      left: 4,
                                      top: 4,
                                      child: _Badge(
                                        i == 0 ? 'Cover' : '${i + 1}',
                                      ),
                                    ),
                                    Positioned(
                                      right: 0,
                                      top: 0,
                                      child: IconButton(
                                        tooltip: 'Remove',
                                        iconSize: 16,
                                        visualDensity: VisualDensity.compact,
                                        icon: const Icon(Icons.close),
                                        onPressed: () => _toggle(f),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Row(
                children: [
                  Text(
                    '${widget.files.length} images',
                    style: theme.textTheme.labelLarge,
                  ),
                  const Spacer(),
                  if (widget.files.length > 12)
                    SizedBox(
                      width: 240,
                      child: TextField(
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 18),
                          hintText: 'Filter',
                        ),
                        onChanged: (v) => setState(() => _filter = v),
                      ),
                    ),
                ],
              ),
            ),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 170,
                  mainAxisExtent: 150,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final f = shown[i];
                  final at = order[f];
                  return Card(
                    key: ValueKey('pick:$f'),
                    clipBehavior: Clip.antiAlias,
                    margin: EdgeInsets.zero,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: at == null
                          ? BorderSide.none
                          : BorderSide(color: scheme.primary, width: 2),
                    ),
                    child: InkWell(
                      mouseCursor: clickCursor,
                      onTap: () => _toggle(f),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: _thumb(f),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                                child: Tooltip(
                                  message: f,
                                  child: Text(
                                    p.basename(f),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (at != null)
                            Positioned(
                              left: 4,
                              top: 4,
                              child: _Badge(at == 0 ? 'Cover' : '${at + 1}'),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  TextButton.icon(
                    key: const ValueKey('previews-reset'),
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: const Text('Reset to automatic'),
                    onPressed: widget.custom
                        ? () => Navigator.of(context).pop(<String>[])
                        : null,
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('previews-save'),
                    onPressed: _changed
                        ? () => Navigator.of(context).pop([..._chosen])
                        : null,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onPrimary),
      ),
    );
  }
}
