import 'package:assets_explorer/state/settings.dart';
import 'package:assets_explorer/ui/folder_groups.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const rels = [
    'characters/knight/idle.png',
    'Cover.png',
    'characters/archer/shoot.png',
    'characters/knight/walk.png',
    'ui/buttons-big.png',
    'preview.png',
    'characters/archer/aim.png',
    'ui/icons.png',
  ];

  test('groups by parent folder: root first, then folders by path', () {
    final groups = groupByFolder(rels);
    expect(
      [for (final g in groups) g.folder],
      ['', 'characters/archer', 'characters/knight', 'ui'],
    );
    expect(groups.first.items, [1, 5]);
    expect(groups[2].items, [0, 3]);
    expect(folderOf('a.png'), '');
    expect(folderOf('a/b/c.png'), 'a/b');
    expect(folderOf('a/b/c.png', depth: 1), 'a');
  });

  test('single-file sub-folders merge into their parent folder', () {
    // Pixel-Banner: <Character>/<Action>/<sheet>.png, one sheet per action.
    final banner = [
      for (final c in ['ArcherSkeleton', 'BruteGoblin', 'Wolf'])
        for (final a in ['Attack', 'Death', 'Idle', 'Walk']) '$c/$a/$a.png',
    ];
    final groups = groupByFolder(banner);
    expect(
      [for (final g in groups) g.folder],
      ['ArcherSkeleton', 'BruteGoblin', 'Wolf'],
    );
    expect(groups.first.items, hasLength(4));
  });

  test('folder titles are prettified per level', () {
    expect(folderTitle(''), 'Pack root');
    expect(folderTitle('characters/knight_v2'), 'Characters / Knight v2');
    expect(folderTitle('UI-elements'), 'UI elements');
  });

  test('visible order follows the view and skips folded folders', () {
    expect(visibleOrder(rels, ItemsView.flat, {}), [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(visibleOrder(rels, ItemsView.folders, {}), [
      1, 5, 2, 6, 0, 3, 4, 7, //
    ]);
    expect(visibleOrder(rels, ItemsView.folders, {'characters/knight'}), [
      1, 5, 2, 6, 4, 7, //
    ]);
    // Folding does nothing in the flat view.
    expect(visibleOrder(rels, ItemsView.flat, {'ui'}), hasLength(8));
  });

  testWidgets('sections show titles and counts and fold on click', (
    tester,
  ) async {
    final collapsed = <String>{};
    Widget grid() => MaterialApp(
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => GroupedGrid(
            rels: rels,
            view: ItemsView.folders,
            collapsed: collapsed,
            onToggleFolder: (f) => setState(
              () => collapsed.contains(f)
                  ? collapsed.remove(f)
                  : collapsed.add(f),
            ),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 120,
            ),
            itemBuilder: (_, i) => Text('item ${rels[i]}'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(grid());
    expect(find.text('Pack root'), findsOneWidget);
    expect(find.text('Characters / Knight'), findsOneWidget);
    expect(find.text('Characters / Archer'), findsOneWidget);
    expect(find.text('Ui'), findsOneWidget);
    expect(find.text('item characters/knight/walk.png'), findsOneWidget);

    await tester.tap(find.text('Characters / Knight'));
    await tester.pump();
    expect(collapsed, {'characters/knight'});
    expect(find.text('item characters/knight/walk.png'), findsNothing);
    expect(find.text('item ui/buttons-big.png'), findsOneWidget);
    await tester.tap(find.text('Characters / Knight'));
    await tester.pump();
    expect(find.text('item characters/knight/walk.png'), findsOneWidget);
  });
}
