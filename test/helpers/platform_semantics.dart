import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// A test binding that keeps the accessibility tree a platform would build
/// from the app's semantics updates, and records the updates the Windows
/// embedder rejects.
///
/// Windows (Chromium's `ui::AXTree`) rejects a whole update when it carries
/// a node that no parent lists as a child ("X will not be in the tree and
/// is not the new root"). From then on its tree no longer matches the app,
/// so every later update fails too, and a screen reader reads a stale app.
/// Flutter itself doesn't check this.
///
/// Example: an `OverlayPortal` (Tooltip, MenuAnchor, Slider's value
/// indicator) whose child's semantics merge into a node that already holds
/// another portal's traversal parent. A node keeps only one, so the other
/// portal's overlay is listed by no parent. Give such a widget its own node
/// (`Semantics(container: true)`).
class PlatformSemanticsBinding extends AutomatedTestWidgetsFlutterBinding {
  /// Installs this binding; call before any other binding is created (from
  /// `flutter_test_config.dart`).
  static PlatformSemanticsBinding ensureInitialized() {
    if (_instance == null) PlatformSemanticsBinding();
    return _instance!;
  }

  static PlatformSemanticsBinding? _instance;

  /// The binding `flutter_test_config.dart` installed.
  static PlatformSemanticsBinding get instanceForTests => _instance!;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  /// Child ids in traversal order, by node id, as the platform has them.
  final Map<int, List<int>> _tree = {};

  /// One description per rejected update since [resetPlatformTree].
  final List<String> rejected = [];

  /// Forgets the tree: each test's semantics start from a fresh root.
  void resetPlatformTree() {
    _tree.clear();
    rejected.clear();
  }

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() =>
      _RecordingBuilder(super.createSemanticsUpdateBuilder(), this);

  void _apply(Map<int, List<int>> nodes) {
    final next = {..._tree, ...nodes};
    final reached = <int>{};
    void walk(int id) {
      if (!reached.add(id)) return;
      for (final child in next[id] ?? const <int>[]) {
        walk(child);
      }
    }

    walk(0);
    final orphans = [
      for (final id in nodes.keys)
        if (!reached.contains(id)) id,
    ];
    if (orphans.isNotEmpty) {
      rejected.add(
        'An update sends semantics nodes no parent lists: '
        '${orphans.map(_describe).join('; ')}',
      );
    }
    // Keep going as if the platform had taken the update, so one mistake
    // is reported once rather than in every later update.
    _tree
      ..addAll(nodes)
      ..removeWhere((id, _) => !reached.contains(id));
  }

  String _describe(int id) {
    for (final view in renderViews) {
      RenderObject? found;
      void visit(RenderObject o) {
        if (found != null) return;
        if (o.debugSemantics?.id == id) {
          found = o;
          return;
        }
        o.visitChildren(visit);
      }

      visit(view);
      final creator = found?.debugCreator;
      if (creator is DebugCreator) {
        return '#$id, created by ${creator.element.debugGetCreatorChain(40)}';
      }
    }
    return '#$id';
  }
}

/// Forwards to the real builder and hands the update's tree shape to the
/// binding when it is built.
class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  _RecordingBuilder(this._inner, this._binding);

  final ui.SemanticsUpdateBuilder _inner;
  final PlatformSemanticsBinding _binding;
  final Map<int, List<int>> _nodes = {};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final args = invocation.namedArguments;
    switch (invocation.memberName) {
      case #updateNode:
        _nodes[args[#id] as int] =
            (args[#childrenInTraversalOrder] as Int32List).toList();
        return Function.apply(_inner.updateNode, const [], args);
      case #updateCustomAction:
        return Function.apply(_inner.updateCustomAction, const [], args);
      case #build:
        _binding._apply(_nodes);
        return _inner.build();
    }
    return super.noSuchMethod(invocation);
  }
}
