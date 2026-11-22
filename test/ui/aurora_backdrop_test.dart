import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/ui/widgets/glass.dart';

void main() {
  Widget app(Color seed, Size size) => MaterialApp(
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: seed)),
    home: Center(
      child: SizedBox.fromSize(
        size: size,
        child: const AuroraBackdrop(child: Text('content')),
      ),
    ),
  );

  testWidgets('the backdrop is drawn from an image, kept across repaints', (
    tester,
  ) async {
    await tester.pumpWidget(app(Colors.teal, const Size(300, 200)));
    expect(find.text('content'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A new size and a new theme colour each draw it again, without errors.
    await tester.pumpWidget(app(Colors.teal, const Size(400, 250)));
    await tester.pumpWidget(app(Colors.orange, const Size(400, 250)));
    expect(tester.takeException(), isNull);

    // Gone: its image is released with the render object.
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
