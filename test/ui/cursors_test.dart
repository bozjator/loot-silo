import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:loot_silo/core/model_cache.dart';
import 'package:loot_silo/core/model_formats.dart';
import 'package:loot_silo/state/providers.dart';
import 'package:loot_silo/ui/cursors.dart';
import 'package:loot_silo/ui/model_viewer.dart';

import '../helpers/models.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

enum _Pick { a, b }

void main() {
  testWidgets('clickable controls show the hand cursor', (tester) async {
    final controls = <String, Widget>{
      'IconButton': IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
      'FilledButton': FilledButton(onPressed: () {}, child: const Text('x')),
      'TextButton': TextButton(onPressed: () {}, child: const Text('x')),
      'OutlinedButton': OutlinedButton(
        onPressed: () {},
        child: const Text('x'),
      ),
      'Checkbox': Checkbox(value: false, onChanged: (_) {}),
      'ListTile': ListTile(title: const Text('x'), onTap: () {}),
      'TabBar': const DefaultTabController(
        length: 1,
        child: TabBar(tabs: [Tab(text: 'x')]),
      ),
      'SegmentedButton': SegmentedButton<_Pick>(
        segments: const [
          ButtonSegment(value: _Pick.a, label: Text('a')),
          ButtonSegment(value: _Pick.b, label: Text('b')),
        ],
        selected: const {_Pick.a},
        onSelectionChanged: (_) {},
      ),
      'InkWell': InkWell(
        mouseCursor: clickCursor,
        onTap: () {},
        child: const Text('x'),
      ),
      'FilterChip': FilterChip(
        mouseCursor: clickCursor,
        label: const Text('x'),
        onSelected: (_) {},
      ),
      'DropdownButton': DropdownButton<int>(
        mouseCursor: clickCursor,
        value: 1,
        items: const [DropdownMenuItem(value: 1, child: Text('one'))],
        onChanged: (_) {},
      ),
      'PopupMenuButton': PopupMenuButton<int>(
        icon: const Icon(Icons.download_outlined),
        itemBuilder: (_) => const [PopupMenuItem(value: 1, child: Text('x'))],
      ),
      'Chip delete': Chip(
        label: const Text('x'),
        deleteIcon: deleteIcon,
        onDeleted: () {},
      ),
    };
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    for (final MapEntry(key: name, value: control) in controls.entries) {
      await tester.pumpWidget(
        MaterialApp(
          theme: withClickCursors(ThemeData()),
          home: Scaffold(
            body: Center(child: SizedBox(width: 300, child: control)),
          ),
        ),
      );
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      final target = name == 'Chip delete'
          ? find.byIcon(Icons.clear)
          : name == 'SegmentedButton'
          ? find.text('b')
          : find.byWidget(control);
      await mouse.moveTo(tester.getCenter(target));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
        reason: name,
      );
    }
    // The items of an open popup menu (the app bar's import menu).
    await tester.pumpWidget(
      MaterialApp(
        theme: withClickCursors(ThemeData()),
        home: Scaffold(body: Center(child: controls['PopupMenuButton'])),
      ),
    );
    await tester.tap(find.byIcon(Icons.download_outlined));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.text('x').last));
    await tester.pump();
    expect(
      RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.click,
      reason: 'PopupMenuItem',
    );
  });

  testWidgets('model viewer: grab over the stage, hand on its controls', (
    tester,
  ) async {
    final tmp = Directory.systemTemp.createTempSync('cursor-model');
    addTearDown(() => tmp.deleteSync(recursive: true));
    writeCubeGlb(tmp.path, 'cube');
    writeCubeObj(tmp.path, 'cube');
    final items = groupModelFormats(['cube.glb', 'cube.obj']);
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          modelCacheProvider.overrideWithValue(
            ModelCache(read: (path) async => readModelForPreview(path)),
          ),
        ],
        child: MaterialApp(
          theme: withClickCursors(ThemeData()),
          home: ModelViewer(
            packPath: tmp.path,
            items: items,
            files: const ['cube.glb'],
            initialIndex: 0,
          ),
        ),
      ),
    );
    await tester.pump();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    Future<MouseCursor?> over(Finder f) async {
      await mouse.moveTo(tester.getCenter(f));
      await tester.pump();
      return RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    }

    expect(
      await over(find.byKey(const ValueKey('model-viewer-stage'))),
      SystemMouseCursors.grab,
    );
    expect(
      await over(find.byKey(const ValueKey('toggle-wireframe'))),
      SystemMouseCursors.click,
    );
    expect(
      await over(find.byKey(const ValueKey('format:cube.obj'))),
      SystemMouseCursors.click,
    );
    expect(await over(find.text('Copy path')), SystemMouseCursors.click);
  });
}
