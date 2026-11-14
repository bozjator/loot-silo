import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../state/settings.dart';
import 'folder_groups.dart';
import 'shortcuts.dart';

/// Focus mode of a card grid (M93): the focused card's id, or null. Cards
/// listen through [FocusedCard], so a click repaints the cards whose look
/// changes instead of rebuilding the whole tab.
class CardFocus<K> extends ValueNotifier<K?> {
  CardFocus() : super(null);
}

/// Builds one card with its focus state: [focused] for the focused card,
/// [dimmed] for the others while one is focused. Rebuilds only when that
/// pair changes.
class FocusedCard<K> extends StatefulWidget {
  const FocusedCard({
    super.key,
    required this.focus,
    required this.id,
    required this.builder,
  });

  final ValueListenable<K?> focus;
  final K id;
  final Widget Function(BuildContext context, bool focused, bool dimmed)
  builder;

  /// Builds of every [FocusedCard], for tests that check what a focus
  /// change rebuilds.
  @visibleForTesting
  static var builds = 0;

  @override
  State<FocusedCard<K>> createState() => _FocusedCardState<K>();
}

class _FocusedCardState<K> extends State<FocusedCard<K>> {
  late (bool, bool) _state = _read();

  (bool, bool) _read() {
    final f = widget.focus.value;
    return (f == widget.id, f != null && f != widget.id);
  }

  void _changed() {
    final s = _read();
    if (s != _state) setState(() => _state = s);
  }

  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_changed);
  }

  @override
  void didUpdateWidget(FocusedCard<K> old) {
    super.didUpdateWidget(old);
    if (!identical(old.focus, widget.focus)) {
      old.focus.removeListener(_changed);
      widget.focus.addListener(_changed);
    }
    _state = _read();
  }

  @override
  void dispose() {
    widget.focus.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    FocusedCard.builds++;
    return widget.builder(context, _state.$1, _state.$2);
  }
}

/// Esc / mouse back leave focus mode while a card of [focus] is focused;
/// otherwise they go on to the app. Rebuilds only the handler, not [child].
class FocusBackHandler extends StatelessWidget {
  const FocusBackHandler({
    super.key,
    required this.focus,
    required this.onBack,
    required this.child,
  });

  final ValueListenable<Object?> focus;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Object?>(
    valueListenable: focus,
    builder: (context, focused, child) =>
        BackHandler(enabled: focused != null, onBack: onBack, child: child!),
    child: child,
  );
}

/// A tab's on-screen order (M93): the folder groups of its items and
/// [visibleOrder], kept until the items (by identity), the view or the
/// folded folders change. Huge packs (12,000+ images) would otherwise
/// regroup on every click and key press.
class ShownOrder {
  List<String>? _rels;
  List<FolderGroup>? _groups;
  ItemsView? _view;
  Set<String> _folds = const {};
  List<int> _order = const [];
  List<String>? _shown;
  Map<int, int>? _at;
  Map<String, int>? _atRel;

  /// The folder groups of [rels] ([groupByFolder]).
  List<FolderGroup> groups(List<String> rels) {
    if (!identical(rels, _rels)) {
      _rels = rels;
      _groups = null;
      _view = null;
    }
    return _groups ??= groupByFolder(rels);
  }

  /// Item indices of [rels] in on-screen order ([visibleOrder]).
  List<int> of(List<String> rels, ItemsView view, Set<String> collapsed) {
    final g = groups(rels);
    if (view != _view || !setEquals(collapsed, _folds)) {
      _view = view;
      _folds = Set.of(collapsed);
      _order = view == ItemsView.flat
          ? [for (var i = 0; i < rels.length; i++) i]
          : [
              for (final x in g)
                if (!collapsed.contains(x.folder)) ...x.items,
            ];
      _shown = null;
      _at = null;
      _atRel = null;
    }
    return _order;
  }

  /// The items of the last [of], in on-screen order.
  List<String> get shown => _shown ??= [for (final i in _order) _rels![i]];

  /// Where item [i] is on screen in the last [of]; -1 when folded away.
  int indexOf(int i) =>
      (_at ??= {for (var j = 0; j < _order.length; j++) _order[j]: j})[i] ?? -1;

  /// Where [rel] is on screen in the last [of]; -1 when folded away.
  int indexOfRel(String rel) =>
      (_atRel ??= {
        for (var j = 0; j < _order.length; j++) _rels![_order[j]]: j,
      })[rel] ??
      -1;
}
