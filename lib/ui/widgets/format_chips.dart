import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/audio_formats.dart' show formatOf;
import '../cursors.dart';

/// A sound's or model's formats as small chips (`OGG · WAV · MP3`), the shown one
/// highlighted; a click on another switches to that file. Materials use
/// them for their maps and tool files ([label]).
class FormatChips extends StatelessWidget {
  const FormatChips({
    super.key,
    required this.files,
    required this.shown,
    required this.onPick,
    this.vertical = false,
    this.tooltip,
    this.label,
    this.pickSingle = false,
    this.slots,
  });

  final List<String> files;
  final String shown;
  final ValueChanged<String> onPick;

  /// Stacked, one width (on a card's left edge, clear of the play button).
  final bool vertical;

  /// A chip's tooltip; by default its file name, or "Switch to …".
  final String Function(String file)? tooltip;

  /// A chip's text; by default the file's format (`OGG`).
  final String Function(String file)? label;

  /// A lone chip is clickable too (it reveals a file, say).
  final bool pickSingle;

  /// List rows only: a slot per format (`ogg` → width), in order. Each chip
  /// sits in its format's slot and a missing format leaves its slot empty,
  /// so the same format lines up down a list.
  final Map<String, double>? slots;

  @override
  Widget build(BuildContext context) {
    final chipOf = {for (final f in files) f: _chip(context, f)};
    final slots = this.slots;
    if (slots != null && !vertical) {
      final byFormat = {for (final f in files) formatOf(f): f};
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final MapEntry(key: format, value: width) in slots.entries)
            SizedBox(
              key: ValueKey('format-slot:$format'),
              width: width,
              child: switch (byFormat[format]) {
                final f? => Align(
                  alignment: Alignment.centerLeft,
                  child: chipOf[f],
                ),
                null => null,
              },
            ),
        ],
      );
    }
    final chips = Flex(
      direction: vertical ? Axis.vertical : Axis.horizontal,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: vertical
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.center,
      children: [for (final f in files) chipOf[f]!],
    );
    return vertical ? IntrinsicWidth(child: chips) : chips;
  }

  Widget _chip(BuildContext context, String f) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: vertical
          ? const EdgeInsets.only(bottom: 4)
          : const EdgeInsets.only(right: 4),
      child: Tooltip(
        message:
            tooltip?.call(f) ??
            (f == shown ? p.basename(f) : 'Switch to ${p.basename(f)}'),
        child: Material(
          key: ValueKey('format:$f'),
          color: f == shown
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          child: InkWell(
            mouseCursor: f == shown ? null : clickCursor,
            borderRadius: BorderRadius.circular(4),
            onTap: f == shown || (files.length == 1 && !pickSingle)
                ? null
                : () => onPick(f),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              child: Text(
                label?.call(f) ?? formatOf(f).toUpperCase(),
                textAlign: TextAlign.center,
                style: style?.copyWith(
                  color: f == shown
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                  fontWeight: f == shown ? FontWeight.bold : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
