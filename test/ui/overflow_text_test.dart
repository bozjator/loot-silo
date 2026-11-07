import 'package:assets_explorer/ui/widgets/overflow_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, double width, String text) =>
      tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(width: width, child: OverflowText(text)),
          ),
        ),
      );

  testWidgets('a tooltip only when the text is cut (M39)', (tester) async {
    await pump(tester, 400, 'short');
    expect(find.byType(Tooltip), findsNothing);

    const long = 'a folder name much too long for a sixty pixel box';
    await pump(tester, 60, long);
    expect(tester.widget<Tooltip>(find.byType(Tooltip)).message, long);
    expect(tester.widget<Text>(find.text(long)).maxLines, 1);
  });
}
