import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:loot_silo/ui/itch_screen.dart';

/// A 3-frame GIF, 100 ms a frame, each frame its own colour.
Uint8List animatedGif() {
  final colours = [
    img.ColorRgba8(255, 0, 0, 255),
    img.ColorRgba8(0, 255, 0, 255),
    img.ColorRgba8(0, 0, 255, 255),
  ];
  img.Image? first;
  for (final c in colours) {
    final frame = img.Image(width: 4, height: 4, numChannels: 4)
      ..frameDuration = 100;
    img.fill(frame, color: c);
    if (first == null) {
      first = frame;
    } else {
      first.addFrame(frame);
    }
  }
  return img.encodeGif(first!);
}

void main() {
  ui.Image? shown(WidgetTester tester) =>
      tester.widget<RawImage>(find.byType(RawImage)).image;

  /// Lets the codec decode for real, then draws.
  Future<void> settleDecode(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('an animated cover holds its first frame until hovered', (
    tester,
  ) async {
    final image = MemoryImage(animatedGif());
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(width: 80, height: 64, child: ItchCover(image)),
        ),
      ),
    );
    await settleDecode(tester);
    final first = shown(tester);
    expect(first, isNotNull);

    // Not hovered: no frames asked for, the picture stays.
    await tester.pump(const Duration(milliseconds: 500));
    await settleDecode(tester);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(shown(tester)!.isCloneOf(first!), isTrue);

    // Hovered: it plays.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byType(ItchCover)));
    await tester.pump();
    var changed = false;
    for (var i = 0; i < 6 && !changed; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await settleDecode(tester);
      changed = !shown(tester)!.isCloneOf(first);
    }
    expect(changed, isTrue);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
  });
}
