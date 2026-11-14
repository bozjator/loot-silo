import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/ui/preview_picker_dialog.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('picker'));
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('many chosen previews: a scrollbar, and the wheel scrolls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final files = [for (var i = 0; i < 30; i++) 'p$i.png'];
    for (final f in files) {
      File(p.join(tmp.path, f))
          .writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewPickerDialog(
            packPath: tmp.path,
            files: files,
            initial: files,
            custom: true,
          ),
        ),
      ),
    );
    await tester.pump();
    final strip = find.byKey(const ValueKey('chosen-previews'));
    final bar = find.ancestor(of: strip, matching: find.byType(Scrollbar));
    expect(bar, findsOneWidget);
    expect(tester.widget<Scrollbar>(bar).thumbVisibility, isTrue);
    final controller = tester.widget<Scrollbar>(bar).controller!;
    expect(controller.position.maxScrollExtent, greaterThan(0));
    expect(controller.offset, 0);
    // A plain (vertical) wheel turn scrolls the strip sideways.
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(tester.getCenter(strip)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 300)));
    await tester.pump();
    expect(controller.offset, 300);
    // A sideways one is the list's own: scrolled once, not twice.
    await tester.sendEventToBinding(mouse.scroll(const Offset(100, 0)));
    await tester.pump();
    expect(controller.offset, 400);
  });

  testWidgets('adding a preview scrolls the strip all the way to it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final files = [for (var i = 0; i < 60; i++) 'p$i.png'];
    for (final f in files) {
      File(p.join(tmp.path, f))
          .writeAsBytesSync(img.encodePng(img.Image(width: 4, height: 4)));
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PreviewPickerDialog(
            packPath: tmp.path,
            files: files,
            // All but the last chosen; the strip starts at its beginning.
            initial: files.sublist(0, 59),
            custom: true,
          ),
        ),
      ),
    );
    await tester.pump();
    final strip = find.byKey(const ValueKey('chosen-previews'));
    final controller = tester
        .widget<Scrollbar>(
          find.ancestor(of: strip, matching: find.byType(Scrollbar)),
        )
        .controller!;
    expect(controller.offset, 0);
    final last = find.byKey(const ValueKey('pick:p59.png'));
    await tester.scrollUntilVisible(
      last,
      300,
      scrollable: find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
      ),
    );
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(controller.offset, controller.position.maxScrollExtent);
    final added = tester.getRect(find.byKey(const ValueKey('chosen:p59.png')));
    final view = tester.getRect(strip);
    expect(added.right, lessThanOrEqualTo(view.right));
    expect(added.left, greaterThanOrEqualTo(view.left));
  });
}
