import 'package:assets_explorer/ui/cursors.dart';
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
  });
}
