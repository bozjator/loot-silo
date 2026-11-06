import 'dart:async';
import 'dart:io';

import 'package:assets_explorer/core/animation_detector.dart';
import 'package:assets_explorer/state/dashboard.dart';
import 'package:assets_explorer/ui/help_screen.dart';
import 'package:assets_explorer/ui/pack_detail_screen.dart';
import 'package:assets_explorer/ui/widgets/filter_bar.dart';
import 'package:assets_explorer/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Milestone 33: the small UI fixes that don't need a whole app.
void main() {
  test('the version constant follows pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(
      r'^version:\s*(\S+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec)!;
    expect(appVersion, m[1]);
    expect(appBuild, int.parse(m[2]!));
    expect(appVersionLabel, 'Asset Explorer $appVersion (build $appBuild)');
  });

  testWidgets('the Help page ends with the version', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 12000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: HelpScreen()));
    await tester.pump();
    final footer = tester.widget<Text>(
      find.byKey(const ValueKey('help-version')),
    );
    expect(footer.data, appVersionLabel);
    expect(footer.data, matches(RegExp(r'^Asset Explorer \d+\.\d+\.\d+')));
  });

  group('filter bar', () {
    late TextEditingController controller;
    late FocusNode focus;
    setUp(() {
      controller = TextEditingController();
      focus = FocusNode();
    });
    tearDown(() {
      controller.dispose();
      focus.dispose();
    });

    Future<void> pumpBar(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 300));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FilterBar(
              query: const DashboardQuery(
                types: {'character'},
                authors: {'Zerie'},
                tags: {'pixel-art'},
              ),
              facets: const Facets(
                types: [('character', 3), ('sfx', 2)],
                authors: [('Zerie', 1)],
                tags: [('pixel-art', 9)],
                sources: [],
              ),
              resultCount: 3,
              searchController: controller,
              searchFocus: focus,
              onText: (_) {},
              onToggleType: (_) {},
              onToggleAuthor: (_) {},
              onToggleTag: (_) {},
              onToggleSource: (_) {},
              onSort: (_) {},
              onClear: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('sort icon sits left of the label, padded and rounded', (
      tester,
    ) async {
      await pumpBar(tester);
      final menu = find.byKey(const ValueKey('sort-menu'));
      final icon = find.descendant(of: menu, matching: find.byIcon(Icons.sort));
      final label = find.descendant(
        of: menu,
        matching: find.text(PackSort.relevance.label),
      );
      expect(icon, findsOneWidget);
      expect(tester.getRect(icon).right, lessThan(tester.getRect(label).left));
      // The focus highlight (the InkWell) leaves room on both sides.
      final ink = tester.widget<InkWell>(
        find.descendant(of: menu, matching: find.byType(InkWell)).first,
      );
      expect(ink.borderRadius, BorderRadius.circular(8));
      final menuRect = tester.getRect(menu);
      expect(
        tester.getRect(icon).left - menuRect.left,
        greaterThanOrEqualTo(8),
      );
      expect(
        menuRect.right - tester.getRect(label).right,
        greaterThanOrEqualTo(8),
      );
    });

    testWidgets('author and tag chips are coloured like a selected type', (
      tester,
    ) async {
      await pumpBar(tester);
      Color? background(Finder chip) {
        final ink = tester.widget<Ink>(
          find.descendant(of: chip, matching: find.byType(Ink)).first,
        );
        return (ink.decoration! as ShapeDecoration).color;
      }

      Color? textColor(String text) =>
          DefaultTextStyle.of(tester.element(find.text(text))).style.color;

      final type = find.widgetWithText(FilterChip, 'character');
      expect(tester.widget<FilterChip>(type).selected, isTrue);
      for (final value in ['Zerie', 'pixel-art']) {
        final chip = find.widgetWithText(InputChip, value);
        expect(background(chip), background(type), reason: value);
        expect(textColor(value), textColor('character'), reason: value);
        // Own icon, no check mark.
        expect(
          find.descendant(of: chip, matching: find.byIcon(Icons.check)),
          findsNothing,
        );
      }
      expect(
        find.descendant(
          of: find.widgetWithText(InputChip, 'Zerie'),
          matching: find.byIcon(Icons.person_outline),
        ),
        findsOneWidget,
      );
    });
  });

  group('animation editor save', () {
    const anim = SpriteAnim(
      path: 'walk.png',
      kind: AnimKind.sheet,
      frameW: 16,
      frameH: 16,
      cols: 4,
    );

    testWidgets('Save is disabled with a spinner; Close and Esc wait', (
      tester,
    ) async {
      final saving = Completer<void>();
      var saves = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => Dialog(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimationEditor(
                        packPath: Directory.systemTemp.path,
                        detected: anim,
                        current: anim,
                        isNew: true,
                        onSave: (_) {
                          saves++;
                          return saving.future;
                        },
                        onNotAnimation: () async {},
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).maybePop(),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      FilledButton save() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save().onPressed, isNotNull);
      expect(find.byKey(const ValueKey('save-spinner')), findsNothing);

      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(saves, 1);
      expect(save().onPressed, isNull);
      expect(find.byKey(const ValueKey('save-spinner')), findsOneWidget);

      // Neither Close nor Esc leaves while the save runs.
      await tester.tap(find.text('Close'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(AnimationEditor), findsOneWidget);

      saving.complete();
      await tester.pump();
      expect(find.byKey(const ValueKey('save-spinner')), findsNothing);
      expect(save().onPressed, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AnimationEditor), findsNothing);
    });
  });
}
