import 'package:flutter/material.dart';

/// Dresses the chips under it like the theme's text fields (the search
/// boxes): a pill with the field's fill and thin edge. A selected chip
/// gets the theme colour's edge and a light tint, as a focused field does.
///
/// A chip lays its fill over a canvas-coloured `Material`, which made a
/// see-through fill look solid, so the canvas is cleared here. Keep only
/// chips under this: a dropdown's menu is drawn in the canvas colour.
class FieldChips extends StatelessWidget {
  const FieldChips({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(data: fieldChipTheme(theme), child: child);
  }
}

/// [theme] with chips styled as [FieldChips] describes.
ThemeData fieldChipTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  final input = theme.inputDecorationTheme;
  final fill = input.fillColor ?? scheme.surfaceContainerHigh;
  final edge = input.enabledBorder?.borderSide ?? BorderSide.none;
  return theme.copyWith(
    canvasColor: Colors.transparent,
    chipTheme: theme.chipTheme.copyWith(
      shape: const StadiumBorder(),
      backgroundColor: fill,
      selectedColor: Color.alphaBlend(
        scheme.primary.withValues(alpha: 0.16),
        fill,
      ),
      side: WidgetStateBorderSide.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? BorderSide(color: scheme.primary, width: 1.5)
            : edge,
      ),
      // Replaces the chip's own label style, so the whole style: the
      // default's, in the field's text colour.
      labelStyle: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurface),
      checkmarkColor: scheme.primary,
    ),
  );
}
