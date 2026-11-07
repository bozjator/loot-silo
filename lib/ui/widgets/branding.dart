import 'package:flutter/material.dart';

import '../../version.dart';

/// Branding images, built by `tool/branding/make_branding.py`.
abstract final class Branding {
  /// The silo on its rounded square, no text: for small sizes (≤ 64 px).
  static const iconSmall = 'assets/branding/icon_small.png';

  /// The full app icon: silo, name and slogan on the rounded square.
  static const iconFull = 'assets/branding/icon_full.png';

  /// The wide logo: gamepad silo, name and slogan (transparent, outlined,
  /// so it reads on light and dark backgrounds).
  static const logoWide = 'assets/branding/logo_wide.png';
}

/// The wide logo, [height] tall. It shows the name and slogan, so screen
/// readers get them as its label.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.height = 120});

  final double height;

  @override
  Widget build(BuildContext context) => Image.asset(
    Branding.logoWide,
    key: const ValueKey('app-logo'),
    height: height,
    filterQuality: FilterQuality.medium,
    semanticLabel: '$appName. $appSlogan',
  );
}

/// The app bar title: the small silo icon, then "Loot Silo".
class AppBarTitle extends StatelessWidget {
  const AppBarTitle({super.key});

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Image.asset(
        Branding.iconSmall,
        key: const ValueKey('app-bar-icon'),
        width: 28,
        height: 28,
        filterQuality: FilterQuality.medium,
        excludeFromSemantics: true,
      ),
      const SizedBox(width: 10),
      const Text(appName),
    ],
  );
}
