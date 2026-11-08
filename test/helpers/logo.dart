import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/ui/widgets/branding.dart';
import 'package:loot_silo/version.dart';

/// M52/M54: the one logo on screen is the lockup: the app icon, then the
/// title-and-slogan picture, labelled for screen readers; no gamepad logo.
void expectLockup(WidgetTester tester) {
  final logo = find.byKey(const ValueKey('app-logo'));
  expect(logo, findsOneWidget);
  String asset(String key) =>
      (tester.widget<Image>(find.byKey(ValueKey(key))).image as AssetImage)
          .assetName;
  expect(
    find.descendant(of: logo, matching: find.byType(Image)),
    findsNWidgets(2),
  );
  // M54: the app icon, then the title-and-slogan picture.
  expect(asset('app-logo-icon'), Branding.iconLarge);
  expect(asset('app-logo-title'), Branding.title);
  expect(tester.getSemantics(logo).label, '$appName. $appSlogan');
  expect(
    find.byWidgetPredicate(
      (w) =>
          w is Image &&
          w.image is AssetImage &&
          (w.image as AssetImage).assetName.contains('logo_wide'),
    ),
    findsNothing,
  );
}
