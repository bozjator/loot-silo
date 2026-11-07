import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/ui/widgets/branding.dart';
import 'package:loot_silo/version.dart';

/// M52: the one logo on screen is the lockup: the app icon's silo, the
/// name and the slogan, labelled for screen readers; no gamepad logo.
void expectLockup(WidgetTester tester) {
  final logo = find.byKey(const ValueKey('app-logo'));
  expect(logo, findsOneWidget);
  final icon = tester.widget<Image>(
    find.descendant(of: logo, matching: find.byType(Image)),
  );
  expect((icon.image as AssetImage).assetName, Branding.iconLarge);
  expect(
    find.descendant(of: logo, matching: find.text(appName)),
    findsOneWidget,
  );
  expect(
    find.descendant(of: logo, matching: find.text(appSlogan)),
    findsOneWidget,
  );
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
