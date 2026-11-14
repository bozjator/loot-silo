import 'dart:io';

import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/image_viewer.dart';
import 'package:loot_silo/ui/reveal.dart';
import 'package:loot_silo/ui/widgets/pixel_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

void main() {
  test('tiles keep floored upscaling', () => expect(integerScale(1.73), 1));

  group('revealInFileManager', () {
    test('Linux asks the file manager over D-Bus', () async {
      final calls = <List<String>>[];
      Uri? opened;
      await revealInFileManager(
        '/lib/My Pack/a b.png',
        os: 'linux',
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
        open: (uri) async {
          opened = uri;
          return true;
        },
      );
      expect(calls.single.first, 'dbus-send');
      expect(
        calls.single,
        contains('array:string:file:///lib/My%20Pack/a%20b.png'),
      );
      expect(opened, isNull);
    });

    test('Linux opens the parent folder when D-Bus fails', () async {
      for (final fail in [
        () async => ProcessResult(0, 1, '', 'no service'),
        () async => throw const ProcessException('dbus-send', []),
      ]) {
        Uri? opened;
        await revealInFileManager(
          '/lib/Pack/x.png',
          os: 'linux',
          run: (_, _) => fail(),
          open: (uri) async {
            opened = uri;
            return true;
          },
        );
        expect(opened, Uri.directory('/lib/Pack'));
      }
    });

    test('Windows selects with explorer, macOS with open -R', () async {
      final calls = <List<String>>[];
      Future<ProcessResult> run(String exe, List<String> args) async {
        calls.add([exe, ...args]);
        return ProcessResult(0, 1, '', '');
      }

      await revealInFileManager(r'C:\lib\x.png', os: 'windows', run: run);
      await revealInFileManager('/lib/x.png', os: 'macos', run: run);
      expect(calls, [
        ['explorer', r'/select,C:\lib\x.png'],
        ['open', '-R', '/lib/x.png'],
      ]);
    });
  });

  group('ImageViewer', () {
    late Directory tmp;
    late SettingsStore store;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('viewer');
      store = SettingsStore(File(p.join(tmp.path, 'settings.json')));
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void png(String rel, int w, int h) {
      final f = File(p.join(tmp.path, rel))..parent.createSync(recursive: true);
      f.writeAsBytesSync(img.encodePng(img.Image(width: w, height: h)));
    }

    final revealed = <String>[];

    Future<void> open(
      WidgetTester tester,
      List<String> images, {
      int index = 0,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsStoreProvider.overrideWithValue(store),
            revealProvider.overrideWithValue(
              (path) async => revealed.add(path),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => ImageViewer(
                    packPath: tmp.path,
                    images: images,
                    initialIndex: index,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// The drawn size of the image once it has decoded.
    Future<Size> drawn(WidgetTester tester) async {
      for (var i = 0; i < 20 && find.byType(RawImage).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      // The laid-out size, not the requested one: tight constraints used
      // to stretch the image to the whole area.
      return tester.getSize(find.byType(RawImage));
    }

    double zoomShown(WidgetTester tester) => double.parse(
      tester
          .widget<Text>(find.byKey(const ValueKey('zoom-label')))
          .data!
          .replaceAll('×', ''),
    );

    testWidgets(
      'close button: top left on macOS, top right elsewhere; closes',
      (tester) async {
        png('a.png', 8, 8);
        await open(tester, ['a.png']);
        final close = find.byKey(const ValueKey('dialog-close'));
        final counter = find.text('1 / 1');
        expect(close, findsOneWidget);
        final mac = defaultTargetPlatform == TargetPlatform.macOS;
        final x = tester.getCenter(close).dx;
        expect(x < tester.getCenter(counter).dx, mac);
        expect(x < 1440 / 2, mac);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewer), findsNothing);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.macOS,
      }),
    );

    testWidgets('zoom: label, 1:1 actual pixels, wheel below fit, Fit', (
      tester,
    ) async {
      png('hero.png', 32, 32);
      await open(tester, ['hero.png']);
      await drawn(tester);
      await tester.pump();
      // M50: it opens at 1:1.
      expect(find.text('1×'), findsOneWidget);
      expect(tester.getRect(find.byType(RawImage)).width, closeTo(32, 0.5));

      // Fit: a 32 px sprite fills the viewer's height exactly (no whole
      // steps).
      await tester.tap(find.text('Fit'));
      await tester.pump();
      final fit = zoomShown(tester);
      expect(fit, greaterThan(10));
      final area = tester.getSize(find.byType(InteractiveViewer));
      expect(
        tester.getRect(find.byType(RawImage)).height,
        closeTo(area.height - 32, 0.5),
      );
      expect(tester.getRect(find.byType(RawImage)).width, closeTo(32 * fit, 2));

      await tester.tap(find.text('1:1'));
      await tester.pump();
      expect(find.text('1×'), findsOneWidget);
      expect(tester.getRect(find.byType(RawImage)).width, closeTo(32, 0.5));

      // The wheel zooms out below 1×, down to the floor.
      final center = tester.getCenter(find.byType(InteractiveViewer));
      for (var i = 0; i < 30; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, 200),
            kind: PointerDeviceKind.mouse,
          ),
        );
        await tester.pump();
      }
      expect(zoomShown(tester), closeTo(minViewerZoom, 0.01));
      // And back in, past the fit.
      for (var i = 0; i < 60; i++) {
        await tester.sendEventToBinding(
          PointerScrollEvent(
            position: center,
            scrollDelta: const Offset(0, -200),
            kind: PointerDeviceKind.mouse,
          ),
        );
        await tester.pump();
      }
      expect(zoomShown(tester), greaterThan(fit));

      await tester.tap(find.text('Fit'));
      await tester.pump();
      expect(zoomShown(tester), fit);
    });

    testWidgets('opens at 1:1, or at the fit when bigger than the window '
        '(M50), and so does each next image', (tester) async {
      png('tiny.png', 16, 16);
      png('huge.png', 4000, 4000);
      png('small.png', 40, 20);
      await open(tester, ['tiny.png', 'huge.png', 'small.png']);
      await drawn(tester);
      await tester.pump();
      expect(zoomShown(tester), 1.0);
      final tiny = tester.getRect(find.byType(RawImage));
      expect(tiny.size, const Size(16, 16));
      // Centred in the image area.
      final area = tester.getRect(find.byType(InteractiveViewer));
      expect(tiny.center.dx, closeTo(area.center.dx, 0.5));
      expect(tiny.center.dy, closeTo(area.center.dy, 0.5));

      // Zoomed in, then the next image: the rule again, not the zoom.
      await tester.tap(find.text('Fit'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await drawn(tester);
      await tester.pump();
      final fit = zoomShown(tester);
      expect(fit, lessThan(1));
      final huge = tester.getRect(find.byType(RawImage));
      // Never cropped: the whole image is inside the area.
      expect(huge.height, closeTo(area.height - 32, 0.5));
      expect(
        area.contains(huge.topLeft) &&
            area.contains(huge.bottomRight - const Offset(1, 1)),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await drawn(tester);
      await tester.pump();
      expect(zoomShown(tester), 1.0);
      expect(tester.getRect(find.byType(RawImage)).size, const Size(40, 20));
    });

    test('zoom labels', () {
      expect(zoomLabel(4), '4×');
      expect(zoomLabel(0.5), '0.5×');
      expect(zoomLabel(0.25), '0.25×');
      expect(zoomLabel(2.37), '2.4×');
      expect(zoomLabel(23.04), '23×');
    });

    testWidgets('title is prettified; details show path, size and bytes', (
      tester,
    ) async {
      png('chars/knight_idle-sheet.png', 32, 16);
      await open(tester, ['chars/knight_idle-sheet.png']);
      expect(find.text('Knight idle sheet'), findsOneWidget);
      expect(
        find.textContaining('chars/knight_idle-sheet.png'),
        findsOneWidget,
      );
      expect(find.textContaining('32 × 16 px'), findsOneWidget);
      expect(find.text('1 / 1'), findsOneWidget);
      // One image: no chevrons.
      expect(find.byIcon(Icons.chevron_left), findsNothing);
    });

    testWidgets('prev/next by button and arrow keys, stopping at the ends', (
      tester,
    ) async {
      for (final n in ['a', 'b', 'c']) {
        png('$n.png', 8, 8);
      }
      await open(tester, ['a.png', 'b.png', 'c.png'], index: 1);
      expect(find.text('2 / 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Next image (→)'));
      await tester.pump();
      expect(find.text('3 / 3'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right),
      );
      expect(next.onPressed, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(find.text('3 / 3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
      expect(find.text('1 / 3'), findsOneWidget);
      final prev = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_left),
      );
      expect(prev.onPressed, isNull);
    });

    testWidgets('images fill the viewer with their own proportions', (
      tester,
    ) async {
      const cases = {
        'tiny.png': (16, 16),
        'mid.png': (500, 300),
        'strip.png': (4000, 200),
        'tall.png': (300, 1200),
      };
      cases.forEach((name, d) => png(name, d.$1, d.$2));
      await open(tester, cases.keys.toList());
      final area = tester.getSize(find.byType(InteractiveViewer));
      for (final (w, h) in cases.values) {
        final size = await drawn(tester);
        expect(size.width / size.height, closeTo(w / h, 0.01));
        // Fit is exact: one side of the (padded) area is filled completely.
        final fill =
            (size.width - (area.width - 128)).abs() < 0.5 ||
            (size.height - (area.height - 32)).abs() < 0.5;
        expect(fill, isTrue, reason: '$w×$h drawn at $size in $area');
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
    });

    testWidgets('no Fit / Pixel-perfect toggle; reveal gets the file', (
      tester,
    ) async {
      png('x.png', 8, 8);
      await open(tester, ['x.png']);
      expect(find.byTooltip('Fit to window'), findsNothing);
      expect(find.byTooltip('Pixel-perfect (whole steps)'), findsNothing);
      expect(find.byIcon(Icons.fit_screen_outlined), findsNothing);
      await tester.tap(find.byTooltip('Show in file manager'));
      expect(revealed.last, p.join(tmp.path, 'x.png'));
    });

    testWidgets('Esc closes the viewer', (tester) async {
      png('x.png', 8, 8);
      await open(tester, ['x.png']);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewer), findsNothing);
    });
  });
}
