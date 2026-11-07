import 'package:flutter/material.dart';

import '../../version.dart';

/// Branding images, built by `tool/branding/make_branding.py`.
abstract final class Branding {
  /// The silo on its rounded square, no text: for small sizes (≤ 64 px).
  static const iconSmall = 'assets/branding/icon_small.png';

  /// The same silo at 256 px, for the logo lockup ([AppLogo]).
  static const iconLarge = 'assets/branding/icon_small_256.png';

  /// The full app icon: silo, name and slogan on the rounded square.
  static const iconFull = 'assets/branding/icon_full.png';

  /// The README logo: [AppLogo]'s lockup as an image (transparent, outlined
  /// text that reads on light and dark backgrounds). Not bundled.
  static const logoReadme = 'assets/branding/logo_readme.png';
}

/// The logo, [height] tall: the app icon's silo, then the name over the
/// slogan in the theme's text styles (so it follows light / dark and the
/// theme colour). Screen readers get the name and slogan as one label.
/// Scales down to fit a narrower space.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.height = 120});

  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      key: const ValueKey('app-logo'),
      label: '$appName. $appSlogan',
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                Branding.iconLarge,
                key: const ValueKey('app-logo-icon'),
                width: height,
                height: height,
                filterQuality: FilterQuality.medium,
              ),
              SizedBox(width: height * 0.16),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    appName,
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontSize: height * 0.42,
                      height: 1.1,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Text(
                    appSlogan,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: height * 0.15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
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
