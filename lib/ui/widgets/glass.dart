import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The app's backdrop: a deep base with softly lit colour fields in hues
/// around the theme colour, a faint dot grid and a vignette. Glass surfaces
/// above it pick up its colour.
///
/// Static on purpose: a drifting backdrop repainted every frame under the
/// translucent cards slowed hover effects over time.
class AuroraBackdrop extends StatelessWidget {
  const AuroraBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: CustomPaint(
            isComplex: true,
            painter: _AuroraPainter(
              scheme: scheme,
              dark: scheme.brightness == Brightness.dark,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter({required this.scheme, required this.dark});

  final ColorScheme scheme;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final base = dark
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.04),
            const Color(0xFF07090D),
          )
        : Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.05),
            const Color(0xFFF4F6FA),
          );
    canvas.drawRect(rect, Paint()..color = base);

    const a = 0.0;
    final w = size.width, h = size.height;
    final r = math.max(w, h);
    final strength = dark ? 0.38 : 0.22;
    // Colour fields: centre (as a drifting fraction of the window), radius,
    // colour.
    // Vivid hues around the theme's: the seed, a warm neighbour and a cool
    // counterpoint, so every theme colour gets a lively, not muddy, sky.
    final hue = HSLColor.fromColor(scheme.primary).hue;
    Color tone(double shift, [double light = 0.55]) =>
        HSLColor.fromAHSL(1, (hue + shift) % 360, 0.9, light).toColor();
    final blobs = [
      (
        Offset(
          w * (0.18 + 0.10 * math.sin(a)),
          h * (0.10 + 0.08 * math.cos(a)),
        ),
        r * 0.55,
        tone(0),
      ),
      (
        Offset(
          w * (0.88 + 0.08 * math.cos(a * 2)),
          h * (0.20 + 0.12 * math.sin(a)),
        ),
        r * 0.48,
        tone(-55),
      ),
      (
        Offset(
          w * (0.60 + 0.15 * math.sin(a + 2)),
          h * (1.0 + 0.06 * math.cos(a * 3)),
        ),
        r * 0.62,
        tone(160, 0.5),
      ),
      (
        Offset(w * (0.02 + 0.05 * math.cos(a + 1)), h * 0.85),
        r * 0.38,
        tone(-110, 0.5),
      ),
    ];
    for (final (center, radius, color) in blobs) {
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = ui.Gradient.radial(
            center,
            radius,
            [
              color.withValues(alpha: strength),
              color.withValues(alpha: strength * 0.35),
              color.withValues(alpha: 0),
            ],
            const [0, 0.45, 1],
          ),
      );
    }

    // A faint dot grid, the "instrument panel" texture.
    final dot = Paint()
      ..color = (dark ? Colors.white : Colors.black).withValues(
        alpha: dark ? 0.035 : 0.04,
      );
    const step = 28.0;
    for (var y = step / 2; y < h; y += step) {
      for (var x = step / 2; x < w; x += step) {
        canvas.drawCircle(Offset(x, y), 0.8, dot);
      }
    }

    // Vignette.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          rect.center,
          r * 0.75,
          [
            Colors.transparent,
            Colors.black.withValues(alpha: dark ? 0.45 : 0.06),
          ],
          const [0.55, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.scheme != scheme || old.dark != dark;
}

/// A frosted-glass surface: blurs what is behind it, tints it, and lights
/// its top edge.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.blur = 24,
    this.opacity,
    this.border = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final double blur;
  final double? opacity;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final tint = dark ? const Color(0xFF12161D) : Colors.white;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                tint.withValues(
                  alpha: (opacity ?? (dark ? 0.45 : 0.55)) + 0.08,
                ),
                tint.withValues(alpha: opacity ?? (dark ? 0.45 : 0.55)),
              ],
            ),
            border: border ? glassBorder(scheme) : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The thin, light edge every glass surface has.
Border glassBorder(ColorScheme scheme) {
  final dark = scheme.brightness == Brightness.dark;
  return Border.all(
    color: (dark ? Colors.white : Colors.black).withValues(
      alpha: dark ? 0.10 : 0.08,
    ),
  );
}

/// Glass tint for a translucent fill of [alpha] (cards, fields, chips).
Color glassFill(ColorScheme scheme, [double alpha = 0.06]) {
  final dark = scheme.brightness == Brightness.dark;
  return dark
      ? Colors.white.withValues(alpha: alpha)
      : Colors.white.withValues(alpha: 0.45 + alpha * 3);
}

/// Hover depth for a card: lifts it, lights a glow in the theme colour under
/// it and rims it with that colour.
class HoverLift extends StatelessWidget {
  const HoverLift({
    super.key,
    required this.hover,
    required this.child,
    this.highlighted = false,
    this.radius = 16,
  });

  final bool hover;
  final bool highlighted;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isGlass(context)) return child;
    final scheme = Theme.of(context).colorScheme;
    final lit = hover || highlighted;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      transform: Matrix4.translationValues(0, hover ? -5 : 0, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: lit
                ? scheme.primary.withValues(alpha: 0.45)
                : Colors.black.withValues(alpha: 0.18),
            blurRadius: lit ? 30 : 10,
            spreadRadius: lit ? 1 : -2,
            offset: Offset(0, hover ? 14 : 4),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: lit
              ? scheme.primary.withValues(alpha: 0.85)
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: child,
    );
  }
}

/// A sheen over the top of a glass card: light falling on the edge.
class GlassSheen extends StatelessWidget {
  const GlassSheen({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isGlass(context)) return const SizedBox.shrink();
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: const Alignment(0.2, 0.2),
            colors: [
              Colors.white.withValues(alpha: dark ? 0.10 : 0.35),
              Colors.white.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// Which look the theme has (Settings → Appearance): the Style, read with
/// [isGlass], and whether pack covers fill their tiles ([fillsCovers]).
class AppLook extends ThemeExtension<AppLook> {
  const AppLook({required this.glass, this.fillCovers = false});

  final bool glass;

  /// Pack tile covers fill the picture area (Settings → Covers: Fill).
  final bool fillCovers;

  @override
  AppLook copyWith({bool? glass, bool? fillCovers}) => AppLook(
    glass: glass ?? this.glass,
    fillCovers: fillCovers ?? this.fillCovers,
  );

  @override
  AppLook lerp(AppLook? other, double t) =>
      t < 0.5 || other == null ? this : other;
}

/// Whether [context]'s theme is the Glass style; false for a theme without
/// [AppLook] (built outside appTheme), which then looks classic.
bool isGlass(BuildContext context) =>
    Theme.of(context).extension<AppLook>()?.glass ?? false;

/// Whether pack tile covers fill their picture area; false for a theme
/// without [AppLook], which then shows the whole image.
bool fillsCovers(BuildContext context) =>
    Theme.of(context).extension<AppLook>()?.fillCovers ?? false;
