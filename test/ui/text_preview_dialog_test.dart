import 'dart:io';

import 'package:assets_explorer/ui/reveal.dart';
import 'package:assets_explorer/ui/text_preview_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('preview'));
  tearDown(() => tmp.deleteSync(recursive: true));

  final revealed = <String>[];

  Future<void> open(WidgetTester tester, String rel) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          revealProvider.overrideWithValue((path) async => revealed.add(path)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TextPreviewDialog(packPath: tmp.path, rel: rel),
          ),
        ),
      ),
    );
    // The file is read with real IO; give each step real time.
    for (
      var i = 0;
      i < 40 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('Markdown renders, and Raw shows the source', (tester) async {
    File(p.join(tmp.path, 'README.md'))
        .writeAsStringSync('# Knight Pack\n\nMade by **HeroMaker**.\n');
    await open(tester, 'README.md');
    expect(find.byType(Markdown), findsOneWidget);
    expect(find.text('Knight Pack', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Raw'));
    await tester.pump();
    expect(find.byType(Markdown), findsNothing);
    expect(find.textContaining('# Knight Pack'), findsOneWidget);
    await tester.tap(find.byTooltip('Show in file manager'));
    expect(revealed.last, p.join(tmp.path, 'README.md'));
  });

  testWidgets('remote images are not fetched; pack images are shown', (
    tester,
  ) async {
    File(p.join(tmp.path, 'a.png')).writeAsBytesSync(const [0]);
    File(p.join(tmp.path, 'README.md')).writeAsStringSync(
      '![Logo](https://example.com/logo.png)\n\n![Local](a.png)\n\n'
      '![Outside](../secret.png)\n',
    );
    await open(tester, 'README.md');
    expect(find.text('[Logo]', findRichText: true), findsOneWidget);
    expect(find.text('[Outside]', findRichText: true), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('plain text has no Raw/Rendered switch; Latin-1 is noted', (
    tester,
  ) async {
    File(p.join(tmp.path, 'license.txt'))
        .writeAsBytesSync([...'Caf'.codeUnits, 0xE9]);
    await open(tester, 'license.txt');
    expect(find.text('Café'), findsOneWidget);
    expect(find.textContaining('shown as Latin-1'), findsOneWidget);
    expect(find.text('Raw'), findsNothing);
  });

  testWidgets('a file over 1 MB offers to open externally', (tester) async {
    File(p.join(tmp.path, 'huge.txt'))
        .writeAsBytesSync(List.filled(1024 * 1024 + 1, 0x41));
    await open(tester, 'huge.txt');
    expect(find.textContaining('too large to preview'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Open externally'),
      findsOneWidget,
    );
    final copy = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.copy),
    );
    expect(copy.onPressed, isNull);
  });
}
