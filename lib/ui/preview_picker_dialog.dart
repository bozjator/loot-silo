import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/file_search.dart';
import 'cursors.dart';
import '../core/animation_detector.dart';
import 'widgets/preview_picture.dart';
import 'widgets/thumb_size.dart'
    show detailControlHeight, detailControlRadius, detailControlWidth;

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
    this.animations = const {},
    required this.initial,
    required this.custom,
  });

  final String packPath;
  final List<String> files;

  /// The [files] that are animations, by file: they play.
  final Map<String, SpriteAnim> animations;
  final List<String> initial;
  final bool custom;

  @override
  State<PreviewPickerDialog> createState() => _PreviewPickerDialogState();
}

class _PreviewPickerDialogState extends State<PreviewPickerDialog> {
  late final _chosen = [...widget.initial];
  var _filter = '';

  /// The chosen strip: a scrollbar under it, and the mouse wheel scrolls
  /// it sideways.
  final _strip = ScrollController();
  final _filterText = TextEditingController();

  @override
  void dispose() {
    _strip.dispose();
    _filterText.dispose();
    super.dispose();
  }

  /// A vertical wheel turn scrolls the strip sideways; sideways ones
  /// (trackpads, Shift + wheel) the list handles itself.
  void _wheel(PointerSignalEvent e) {
    if (e is! PointerScrollEvent || !_strip.hasClients) return;
    final d = e.scrollDelta;
    if (d.dx != 0 || d.dy == 0) return;
    final pos = _strip.position;
    _strip.jumpTo(
      (pos.pixels + d.dy).clamp(pos.minScrollExtent, pos.maxScrollExtent),
    );
  }

  bool get _changed {
    final a = widget.initial;
    if (a.length != _chosen.length) return true;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != _chosen[i]) return true;
    }
    return false;
  }

  void _toggle(String f) {
    final added = !_chosen.contains(f);
    setState(() {
      if (!_chosen.remove(f)) _chosen.add(f);
    });
    // Show the one just added at the strip's end.
    if (added) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_strip.hasClients) return;
        // Worked out from the fixed card width: the list does not lay out
        // again for a card added out of sight, so its own maxScrollExtent
        // still ends before the new card.
        final pos = _strip.position;
        final end =
            _stripPadding.horizontal +
            _chosen.length * _cardExtent -
            pos.viewportDimension;
        _strip.animateTo(
          math.max(0, end),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }

  /// A chosen card's width in the strip, its margins included. Fixed, so
  /// the strip's end can be worked out without laying it out.
  static const _cardExtent = 140.0;

  /// Around the strip's cards; the bottom leaves room for the scrollbar.
  static const _stripPadding = EdgeInsets.fromLTRB(16, 0, 16, 14);

  Widget _thumb(String rel) => PreviewPicture(
    packPath: widget.packPath,
    rel: rel,
    anim: widget.animations[rel],
  );

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
              height: 126,
              child: _chosen.isEmpty
                  ? Center(
                      child: Text(
                        'None chosen: previews are picked automatically.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Listener(
                      onPointerSignal: _wheel,
                      child: Scrollbar(
                        controller: _strip,
                        thumbVisibility: true,
                        child: ReorderableListView.builder(
                          key: const ValueKey('chosen-previews'),
                          scrollController: _strip,
                          scrollDirection: Axis.horizontal,
                          buildDefaultDragHandles: false,
                          padding: _stripPadding,
                          itemExtent: _cardExtent,
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
                                  waitDuration: const Duration(
                                    milliseconds: 600,
                                  ),
                                  child: Container(
                                    width: _cardExtent - 8,
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
                                            visualDensity:
                                                VisualDensity.compact,
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
                    // As the pack page's search field: the icon's box
                    // as tall as the field, so hint, icon and border line
                    // up.
                    SizedBox(
                      width: detailControlWidth,
                      height: detailControlHeight,
                      child: TextField(
                        key: const ValueKey('previews-filter'),
                        controller: _filterText,
                        textAlignVertical: TextAlignVertical.center,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8,
                          ),
                          prefixIcon: const Icon(Icons.search, size: 20),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: detailControlHeight,
                          ),
                          suffixIconConstraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: detailControlHeight,
                          ),
                          hintText: 'Filter images',
                          border: const OutlineInputBorder(
                            borderRadius: detailControlRadius,
                          ),
                          suffixIcon: _filter.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear filter',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.close, size: 18),
                                  onPressed: () => setState(() {
                                    _filterText.clear();
                                    _filter = '';
                                  }),
                                ),
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
