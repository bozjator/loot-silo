import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loot_silo/ui/widgets/item_card.dart';

void main() {
  testWidgets('the hover fade spans the footer, however short the title', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ItemCard(
              path: 'a.png',
              stage: (_) => const SizedBox(),
              title: 'A',
              details: 'B',
              onTap: () {},
              actions: [
                CardIconButton(
                  tooltip: 'Icon',
                  icon: Icons.folder,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('A')));
    addTearDown(mouse.removePointer);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    // The card less the footer's 10 px side paddings: the fade lands under
    // the icons, not after the title's last letter.
    expect(tester.getSize(find.byType(ShaderMask)).width, 400 - 20);
  });
}
