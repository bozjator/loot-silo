import 'dart:io';

import 'package:loot_silo/core/library_index.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/state/settings.dart';
import 'package:loot_silo/ui/folder_import_screen.dart';
import 'package:loot_silo/ui/widgets/meta_dialogs.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/fs.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('import_ui'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(finder, findsWidgets);
  }

  /// The import review of [source] into a copy of the managed fixture
  /// library (author HeroMaker with 2 packs).
  Future<String> openReview(WidgetTester tester, String source) async {
    final lib = p.join(tmp.path, 'library');
    copyTree('test/fixtures/managed', lib);
    final store = SettingsStore(File(p.join(tmp.path, 'settings.json')))
      ..save(AppSettings(libraryPath: lib));
    final index = LibraryIndex(NativeDatabase.memory());
    addTearDown(index.close);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          libraryIndexProvider.overrideWithValue(index),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            // Load the library, for its authors and tags.
            ref.watch(libraryProvider);
            return MaterialApp(home: FolderImportScreen(paths: [source]));
          },
        ),
      ),
    );
    return lib;
  }

  Future<void> waitForLibrary(WidgetTester tester) async {
    final container = ProviderScope.containerOf(
      tester.element(find.byType(FolderImportScreen)),
    );
    for (var i = 0; i < 200 && !container.read(libraryProvider).hasValue; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
  }

  testWidgets('a pack picked as the folder itself has a one-line cell', (
    tester,
  ) async {
    final src = p.join(tmp.path, 'Loose Sounds');
    copyTree('test/fixtures/library_src/sfx/Loose Sounds', src);
    await openReview(tester, src);
    await pumpUntil(tester, find.text('Import 1 packs'));
    expect(find.text('Loose Sounds'), findsOneWidget);
    // No "." line under the title.
    expect(find.text('.'), findsNothing);
  });

  testWidgets('dropped folders join the open review, once each', (
    tester,
  ) async {
    final sounds = p.join(tmp.path, 'Loose Sounds');
    copyTree('test/fixtures/library_src/sfx/Loose Sounds', sounds);
    final bundle = p.join(tmp.path, 'Mega Bundle v3');
    copyTree('test/fixtures/library_src/bundles/Mega Bundle v3', bundle);
    await openReview(tester, sounds);
    await pumpUntil(tester, find.text('Import 1 packs'));
    expect(find.text('Import folder'), findsOneWidget);

    expect(FolderImportScreen.isOpen, isTrue);
    expect(FolderImportScreen.addToOpen([bundle, sounds]), isTrue);
    await pumpUntil(tester, find.text('Import 2 packs'));
    // Planning done: the button is back.
    for (var i = 0; i < 200; i++) {
      final button = tester.widget<ButtonStyleButton>(
        find.ancestor(
          of: find.text('Import 2 packs'),
          matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
        ),
      );
      if (button.onPressed != null) break;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(
      find.textContaining('2 packs found in 2 folders', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Import folders'), findsOneWidget);
    expect(find.text('Loose Sounds'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    expect(FolderImportScreen.isOpen, isFalse);
    expect(FolderImportScreen.addToOpen([sounds]), isFalse);
  });

  testWidgets('the source path shows when it adds something', (tester) async {
    final src = p.join(tmp.path, 'src');
    copyTree('test/fixtures/library_src', src);
    await openReview(tester, src);
    await pumpUntil(tester, find.text('Import 7 packs'));
    expect(find.text('sfx/Loose Sounds'), findsOneWidget);
    expect(find.text('.'), findsNothing);
  });

  testWidgets('a cut library folder shows in full on hover (M39)', (
    tester,
  ) async {
    const name =
        'An Extremely Long Pack Folder Name That Cannot Possibly Fit '
        'Into The Library Folder Column Of The Review';
    final src = p.join(tmp.path, name);
    copyTree('test/fixtures/library_src/sfx/Loose Sounds', src);
    await openReview(tester, src);
    await pumpUntil(tester, find.text('Import 1 packs'));
    final cell = find.byKey(const ValueKey('import-target'));
    expect(cell, findsOneWidget);
    final text = tester.widget<Text>(
      find.descendant(of: cell, matching: find.byType(Text)),
    );
    expect(text.data, endsWith(name));
    expect(text.maxLines, 1);
    // Cut, so the whole text is in a tooltip around it.
    final tip = find.ancestor(
      of: find.descendant(of: cell, matching: find.byType(Text)),
      matching: find.byType(Tooltip),
    );
    expect(tester.widget<Tooltip>(tip.first).message, text.data);
  });

  testWidgets('author picker: library authors with counts, add new', (
    tester,
  ) async {
    final src = p.join(tmp.path, 'src');
    copyTree('test/fixtures/library_src', src);
    await openReview(tester, src);
    await pumpUntil(tester, find.text('Import 7 packs'));
    await waitForLibrary(tester);

    // The unknown author starts empty; focusing it opens the suggestions.
    final unknown = find.widgetWithText(TextField, 'Unknown — set author');
    expect(unknown, findsOneWidget);
    await tester.tap(unknown);
    await tester.pump();
    expect(find.text('HeroMaker'), findsWidgets);
    expect(find.text('2 packs'), findsOneWidget);
    expect(find.text('Add new author…'), findsOneWidget);

    // Typing filters; a new name gets its own entry.
    await tester.enterText(unknown, 'Pixel Me');
    await tester.pump();
    expect(find.text('2 packs'), findsNothing);
    await tester.tap(find.text('Add new author “Pixel Me”'));
    await tester.pump();
    expect(find.text('Pixel Me/misc'), findsOneWidget);

    // Picking a library author, in any case.
    final field = find.widgetWithText(TextField, 'Pixel Me');
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'heromak');
    await tester.pump();
    await tester.tap(find.text('HeroMaker').last);
    await tester.pump();
    expect(find.text('HeroMaker/misc'), findsOneWidget);
  });

  testWidgets('a typed author is taken when the field loses focus', (
    tester,
  ) async {
    final src = p.join(tmp.path, 'src');
    copyTree('test/fixtures/library_src', src);
    await openReview(tester, src);
    await pumpUntil(tester, find.text('Import 7 packs'));
    await waitForLibrary(tester);
    final unknown = find.widgetWithText(TextField, 'Unknown — set author');
    await tester.tap(unknown);
    await tester.pump();
    await tester.enterText(unknown, 'Typed');
    await tester.pump();
    // Tab moves focus on.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.text('Typed/misc'), findsOneWidget);
  });

  testWidgets('tags show as chips and open the chip editor', (tester) async {
    final src = p.join(tmp.path, 'src');
    copyTree('test/fixtures/library_src', src);
    await openReview(tester, src);
    await pumpUntil(tester, find.text('Import 7 packs'));
    await waitForLibrary(tester);
    // The tag column of the first row ("—" when it has none).
    await tester.tap(find.text('—').first);
    await tester.pumpAndSettle();
    expect(find.byType(TagsDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Retro');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('retro'), findsOneWidget);
  });

  testWidgets('M64: a tag or author new on one row is offered on the next', (
    tester,
  ) async {
    final src = p.join(tmp.path, 'src');
    copyTree('test/fixtures/library_src', src);
    await openReview(tester, src);
    await pumpUntil(tester, find.text('Import 7 packs'));
    await waitForLibrary(tester);

    // A new tag on the first row without tags…
    await tester.tap(find.text('—').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Zanzibar');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('zanzibar'), findsOneWidget);

    // …is suggested on the next one.
    await tester.tap(find.text('—').first);
    await tester.pumpAndSettle();
    final dialog = find.byType(TagsDialog);
    expect(tester.widget<TagsDialog>(dialog).known, contains('zanzibar'));
    await tester.enterText(find.byType(TextField).last, 'zan');
    await tester.pump();
    expect(
      find.descendant(of: dialog, matching: find.text('zanzibar')),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // A new author typed on one row is a choice on another.
    final unknown = find.widgetWithText(TextField, 'Unknown — set author');
    await tester.tap(unknown);
    await tester.pump();
    await tester.enterText(unknown, 'Quokka Art');
    await tester.pump();
    await tester.tap(find.text('Add new author “Quokka Art”'));
    await tester.pump();
    expect(find.text('Quokka Art/misc'), findsOneWidget);
    final other = find.widgetWithText(TextField, 'HeroMaker').first;
    await tester.tap(other);
    await tester.pump();
    await tester.enterText(other, 'quo');
    await tester.pump();
    expect(find.text('Quokka Art'), findsWidgets);
    expect(find.text('Add new author “quo”'), findsOneWidget);
  });

  testWidgets('a folder inside the library gets a plain message', (
    tester,
  ) async {
    final lib = p.join(tmp.path, 'library');
    final inside = p.join(lib, 'HeroMaker');
    await openReview(tester, inside);
    await pumpUntil(tester, find.textContaining('This folder is inside'));
    expect(
      find.text(
        'This folder is inside your library (${p.canonicalize(lib)}). '
        'Pick a folder outside the library, or move it out first.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Invalid argument'), findsNothing);
    expect(find.text('Back'), findsOneWidget);
  });

  testWidgets('a folder containing the library is explained too', (
    tester,
  ) async {
    await openReview(tester, tmp.path);
    await pumpUntil(tester, find.textContaining('This folder contains'));
  });

  group('TagsDialog', () {
    Future<List<String>?> edit(
      WidgetTester tester,
      Future<void> Function() steps, {
      List<String> initial = const ['pixel', 'rpg'],
      List<String> known = const ['dungeon', 'pixel', 'desert'],
    }) async {
      List<String>? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await showDialog<List<String>>(
                context: context,
                builder: (_) => TagsDialog(initial: initial, known: known),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await steps();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('remove a chip, add by Enter and comma', (tester) async {
      final result = await edit(tester, () async {
        expect(find.widgetWithText(InputChip, 'pixel'), findsOneWidget);
        await tester.tap(find.byTooltip('Remove rpg'));
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'Cave');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pump();
        await tester.enterText(find.byType(TextField), 'top-down, ');
        await tester.pump();
        expect(find.widgetWithText(InputChip, 'top-down'), findsOneWidget);
      });
      expect(result, ['cave', 'pixel', 'top-down']);
    });

    testWidgets('suggestions come from the library, minus chosen ones', (
      tester,
    ) async {
      final result = await edit(tester, () async {
        await tester.enterText(find.byType(TextField), 'd');
        await tester.pump();
        expect(find.text('dungeon'), findsOneWidget);
        expect(find.text('desert'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'pix');
        await tester.pump();
        // Already a chip, so not offered again.
        expect(find.text('pixel'), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'dun');
        await tester.pump();
        await tester.tap(find.text('dungeon'));
        await tester.pump();
      });
      expect(result, ['dungeon', 'pixel', 'rpg']);
    });

    testWidgets('text left in the field is saved too', (tester) async {
      final result = await edit(tester, () async {
        await tester.enterText(find.byType(TextField), 'ui');
        await tester.pump();
      });
      expect(result, ['pixel', 'rpg', 'ui']);
    });
  });
}
