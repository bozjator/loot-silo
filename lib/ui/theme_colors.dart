import 'package:flutter/material.dart';

import '../state/settings.dart';
import 'cursors.dart';
import 'widgets/glass.dart';

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

/// The app's theme for [brightness], seeded from [color]. [style] picks the
/// surfaces: see-through glass over the AuroraBackdrop, or solid ones. The
/// shapes and type are the same in both. [coverFit] is how pack tiles show
/// their covers.
ThemeData appTheme(
  ThemeColor color,
  Brightness brightness, {
  AppStyle style = AppStyle.glass,
  CoverFit coverFit = CoverFit.fill,
}) {
  final dark = brightness == Brightness.dark;
  final glass = style == AppStyle.glass;
  final scheme = ColorScheme.fromSeed(
    seedColor: color.seed,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  );
  final base = ThemeData(colorScheme: scheme, brightness: brightness);
  final radius = BorderRadius.circular(14);
  // Glass edges are a thin light line; classic ones a soft outline.
  final hairline = BorderSide(
    color: glass
        ? (dark ? Colors.white : Colors.black).withValues(
            alpha: dark ? 0.10 : 0.08,
          )
        : scheme.outlineVariant.withValues(alpha: dark ? 0.35 : 0.6),
  );
  final text = base.textTheme.copyWith(
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -0.3,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    titleSmall: base.textTheme.titleSmall?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
    ),
  );
  return withClickCursors(
    base.copyWith(
      textTheme: text,
      extensions: [
        AppLook(glass: glass, fillCovers: coverFit == CoverFit.fill),
      ],
      // Glass pages are see-through: the AuroraBackdrop under the navigator
      // shows through, and every surface on it is glass.
      scaffoldBackgroundColor: glass
          ? Colors.transparent
          : base.scaffoldBackgroundColor,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: glass ? glassFill(scheme, 0.05) : scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: radius, side: hairline),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glass
            ? glassFill(scheme, 0.07)
            : scheme.surfaceContainerHigh.withValues(alpha: 0.7),
        hoverColor: glass ? glassFill(scheme, 0.10) : null,
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: hairline,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(999),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: const StadiumBorder(),
        side: hairline,
        backgroundColor: glass
            ? glassFill(scheme, 0.06)
            : scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: glass ? glassFill(scheme, 0.05) : null,
          selectedBackgroundColor: scheme.primary,
          selectedForegroundColor: scheme.onPrimary,
          side: hairline,
        ),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        trackHeight: 6,
        inactiveTrackColor: scheme.surfaceContainerHighest,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        barrierColor: Colors.black.withValues(alpha: dark ? 0.55 : 0.3),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: hairline,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerHigh.withValues(alpha: 0.96),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: hairline,
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: hairline,
            ),
          ),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.inverseSurface.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(color: scheme.onInverseSurface, fontSize: 12),
        waitDuration: const Duration(milliseconds: 350),
      ),
      dividerTheme: DividerThemeData(color: hairline.color, space: 1),
      tabBarTheme: TabBarThemeData(
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: text.labelLarge,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      scrollbarTheme: ScrollbarThemeData(
        radius: const Radius.circular(8),
        thickness: const WidgetStatePropertyAll(6),
        thumbColor: WidgetStatePropertyAll(
          scheme.onSurface.withValues(alpha: 0.25),
        ),
      ),
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          for (final p in TargetPlatform.values)
            p: const FadeForwardsPageTransitionsBuilder(),
        },
      ),
    ),
  );
}

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

/// Behind a drawn 3D model: the card stage colour, so models sit on the
/// same ground as images in light and dark themes.
Color modelStageColor(ColorScheme scheme) => scheme.surfaceContainerHighest;
