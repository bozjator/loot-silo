import 'package:flutter/material.dart';

import '../../version.dart';

/// Branding images, built by `tool/branding/make_branding.py` from the two
/// source images in `tool/branding/source` (icon_full_centered.png and
/// app-title-with-slogan.png).
abstract final class Branding {
  /// The app icon (the silo on its rounded square) at 64 px, for small sizes.
  static const iconSmall = 'assets/branding/icon_small.png';

  /// The same icon at 256 px, for the logo lockup ([AppLogo]).
  static const iconLarge = 'assets/branding/icon_small_256.png';

  /// The same icon at 512 px.
  static const iconFull = 'assets/branding/icon_full.png';

  /// "LootSilo" over the slogan, as one picture (outlined, so it reads on
  /// light and dark backgrounds).
  static const title = 'assets/branding/title_slogan.png';

  /// The README logo: [AppLogo]'s lockup as one image. Not bundled.
  static const logoReadme = 'assets/branding/logo_readme.png';
}

/// The logo, [height] tall: the app icon, then the title-and-slogan picture
/// ([Branding.title]). Screen readers get the name and slogan as one label.
/// Scales down to fit a narrower space.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.height = 120});

  final double height;

  /// The title's height as a share of the icon's, and the gap between them
  /// (the same proportions as `logo_readme.png`).
  static const titleScale = 0.78;
  static const gapScale = 0.1;

  @override
  Widget build(BuildContext context) => Semantics(
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
            SizedBox(width: height * gapScale),
            Image.asset(
              Branding.title,
              key: const ValueKey('app-logo-title'),
              height: height * titleScale,
              filterQuality: FilterQuality.medium,
            ),
          ],
        ),
      ),
    ),
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
