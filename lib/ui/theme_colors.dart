import 'package:flutter/material.dart';

import '../state/settings.dart';
import 'cursors.dart';

/// Seed colours and names for [ThemeColor]: the Material palette's primary
/// swatches.
extension ThemeColorSeed on ThemeColor {
  Color get seed => switch (this) {
    ThemeColor.teal => Colors.teal,
    ThemeColor.green => Colors.green,
    ThemeColor.blue => Colors.blue,
    ThemeColor.indigo => Colors.indigo,
    ThemeColor.purple => Colors.purple,
    ThemeColor.pink => Colors.pink,
    ThemeColor.red => Colors.red,
    ThemeColor.orange => Colors.orange,
    ThemeColor.amber => Colors.amber,
    ThemeColor.brown => Colors.brown,
    ThemeColor.blueGrey => Colors.blueGrey,
  };

  /// "Blue grey".
  String get label => switch (this) {
    ThemeColor.blueGrey => 'Blue grey',
    _ => '${name[0].toUpperCase()}${name.substring(1)}',
  };
}

/// The app's theme for [brightness], seeded from [color].
ThemeData appTheme(ThemeColor color, Brightness brightness) => withClickCursors(
  ThemeData(colorSchemeSeed: color.seed, brightness: brightness),
);

/// A row of round swatches, one per [ThemeColor]; the selected one has a
/// check mark.
class ThemeColorPicker extends StatelessWidget {
  const ThemeColorPicker({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final ThemeColor selected;
  final ValueChanged<ThemeColor> onChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final c in ThemeColor.values)
          Tooltip(
            message: c.label,
            child: Semantics(
              selected: c == selected,
              button: true,
              label: c.label,
              child: InkWell(
                key: ValueKey('theme-color:${c.name}'),
                mouseCursor: clickCursor,
                customBorder: const CircleBorder(),
                onTap: () => onChanged(c),
                // The seed itself: the dark scheme's pastel primaries
                // made pink, red and brown look alike.
                child: _Swatch(color: c.seed, selected: c == selected),
              ),
            ),
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected});

  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onColor =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? scheme.onSurface : scheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      child: selected ? Icon(Icons.check, size: 18, color: onColor) : null,
    );
  }
}
