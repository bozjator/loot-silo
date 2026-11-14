import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/animation_detector.dart';
import '../core/audio_duration.dart';
import '../core/audio_formats.dart';
import '../core/file_search.dart';
import '../core/credits.dart';
import '../core/library_index.dart';
import '../core/model_formats.dart';
import '../core/pack_editor.dart';
import '../core/sidecar.dart';
import '../core/text_preview.dart';
import '../core/type_classifier.dart' show AssetType;
import '../state/dashboard.dart'
    show DashboardQueryNotifier, dashboardQueryProvider, knownTags, sortedTags;
import '../state/favorites.dart';
import '../state/folder_folds.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'format.dart';
import 'animation_grid.dart';
import 'card_focus.dart';
import 'folder_groups.dart';
import 'image_viewer.dart';
import 'materials_tab.dart';
import 'models_tab.dart';
import 'preview_picker_dialog.dart';
import 'double_click.dart';
import 'reveal.dart';
import 'session.dart';
import 'shortcuts.dart';
import 'tabs.dart';
import 'text_preview_dialog.dart';
import 'track_player.dart';
import 'widgets/animated_sprite.dart';
import 'widgets/favorite_star.dart';
import 'widgets/file_menu.dart';
import 'widgets/format_chips.dart';
import 'widgets/tab_toolbar.dart';
import 'widgets/item_card.dart';
import 'widgets/meta_dialogs.dart';
import 'widgets/overflow_text.dart';
import 'widgets/pack_tile.dart' show iconForTypes;
import 'widgets/pixel_image.dart';
import 'widgets/preview_picture.dart';
import 'widgets/thumb_size.dart';
import 'widgets/waveform.dart';
import 'cursors.dart';
import 'widgets/dialog_close.dart';

/// Everything about one pack: previews, files, animations, metadata.
class PackDetailScreen extends ConsumerWidget {
  const PackDetailScreen({
    super.key,
    required this.packId,
    this.folder,
    this.search,
    this.file,
    this.sessionKey,
    this.restore,
  });

  final String packId;

  /// First-level folder the Images and Animations tabs start at (from an
  /// Expanded dashboard tile).
  final String? folder;

  /// Lists only the files matching this dashboard search (from a file
  /// result or a "files match" line).
  final SearchFilter? search;

  /// The file result that was clicked: its tab opens first.
  final String? file;

  /// Where the page reports its state for "Resume where I left off" (see
  /// [SessionKeeper]); null: not saved.
  final String? sessionKey;

  /// The state saved last time: tab, folder, search and Favorites chip.
  final PageSession? restore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider).value;
    final pack = library?.packs.where((p) => p.id == packId).firstOrNull;
    if (pack == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(
          child: Text('This pack is no longer in the library'),
        ),
      );
    }
    final contents = ref.watch(packContentsProvider(packId));
    final favoriteFiles = ref.watch(
      favoritesProvider.select((f) => f.filesOf(packId)),
    );
    final pinned = ref.watch(
      settingsProvider.select((s) => s.detailHeaderPinned),
    );
    void togglePin() =>
        ref.read(settingsProvider.notifier).setDetailHeaderPinned(!pinned);
    final keeper = sessionKey == null ? null : ref.read(sessionKeeperProvider);
    return Focus(
      // H pins or unpins the header, unless a text field has the key. The
      // body holds the focus (see _BodyState._keys); keys bubble up here.
      onKeyEvent: (node, event) {
        if (!AppKeys.pinHeader.pressed(event) ||
            FocusManager.instance.primaryFocus?.context?.widget
                is EditableText) {
          return KeyEventResult.ignored;
        }
        togglePin();
        return KeyEventResult.handled;
      },
      child: Scaffold(
        // With the tab strip there is no bar: the title is in the header
        // and the tab, the icons in the header's corner. Without it, a bar
        // with the back arrow.
        appBar: tabStrip(ref) ?? AppBar(title: Text(pack.title)),
        // While a rescan reloads the contents, the old ones stay on screen,
        // so the open tab and its state survive.
        body: switch (contents) {
          AsyncValue(hasValue: true, :final value?) => _Body(
            pack: pack,
            contents: value,
            pinned: pinned,
            onTogglePin: togglePin,
            favoriteFiles: favoriteFiles,
            folder: folder,
            search: search,
            file: file,
            restore: restore,
            onSession: switch ((sessionKey, keeper)) {
              (final key?, final keeper?) => (s) => keeper.page(key, s),
              _ => null,
            },
            onSessionEnd: switch ((sessionKey, keeper)) {
              (final key?, final keeper?) => () => keeper.removePage(key),
              _ => null,
            },
          ),
          AsyncError(:final error) => Center(
            child: Text('Could not read: $error'),
          ),
          _ => const Center(child: CircularProgressIndicator()),
        },
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body({
    required this.pack,
    required this.contents,
    required this.pinned,
    required this.onTogglePin,
    this.favoriteFiles = const {},
    this.folder,
    this.search,
    this.file,
    this.restore,
    this.onSession,
    this.onSessionEnd,
  });

  final PackRow pack;
  final PackContents contents;

  /// The pack's starred files, for the Favorites chip.
  final Set<String> favoriteFiles;
  final String? folder;
  final SearchFilter? search;
  final String? file;
  final PageSession? restore;

  /// Told the page's state whenever it changes, and when it goes.
  final ValueChanged<PageSession>? onSession;
  final VoidCallback? onSessionEnd;

  /// False: a slim bar replaces the header; hovering it shows the header
  /// floating over the tabs, so nothing below moves.
  final bool pinned;
  final VoidCallback onTogglePin;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var _peek = false;

  /// Opens the floating header once the pointer has rested on the slim bar
  /// for [headerHoverDelay]; leaving first cancels it.
  Timer? _peekTimer;

  void _hoverSlim(bool inside) {
    _peekTimer?.cancel();
    _peekTimer = null;
    if (!inside) return;
    _peekTimer = Timer(headerHoverDelay, () {
      if (mounted) setState(() => _peek = true);
    });
  }

  /// The open tab, by kind, so it stays open when a tab appears or goes
  /// (e.g. the Animations tab after "Combine into animation").
  late Type? _tab = _tabKinds[widget.restore?.tab];
  late String? _folder = widget.restore?.folder ?? widget.folder;

  /// The Favorites chip: only starred files in every tab.
  late var _onlyFavorites = widget.restore?.favorites ?? false;

  /// Session names of the tab kinds.
  static const _tabKinds = {
    'animations': _AnimationsTab,
    'images': _ImagesTab,
    'audio': _AudioTab,
    'models': ModelsTab,
    'materials': MaterialsTab,
    'files': _FilesTab,
  };

  /// Tells the session keeper the page's state now.
  void _report() {
    final report = widget.onSession;
    if (report == null) return;
    report(
      PageSession(
        packId: widget.pack.id,
        folder: _folder,
        tab: _tabKinds.entries.where((e) => e.value == _tab).firstOrNull?.key,
        search: _query,
        favorites: _onlyFavorites,
      ),
    );
  }

  /// The file-name search over every tab, seeded with the dashboard search
  /// the page was opened with. [_query] is what the tabs are filtered by;
  /// it follows the field once typing pauses.
  late final _searchText = TextEditingController(text: _query);
  late String _query = widget.restore?.search ?? widget.search?.text ?? '';
  final _searchFocus = FocusNode(debugLabel: 'detail search');
  Timer? _debounce;

  /// Holds focus when the search doesn't, so Ctrl+F and H keep working
  /// after Esc or a click outside the field.
  final _keys = FocusNode(debugLabel: 'detail');

  /// Keeps the field (and its focus) when the tab set changes and the tab
  /// controller is rebuilt around it.
  final _fieldKey = GlobalKey(debugLabel: 'detail search field');

  final _tabFocus = TabFocus();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Back in a pack tab: keys work again without a click.
    _tabFocus.update(context, () {
      if (!_keys.hasFocus) _keys.requestFocus();
    });
  }

  @override
  void didUpdateWidget(_Body old) {
    super.didUpdateWidget(old);
    if (widget.pinned) {
      _peek = false;
      _peekTimer?.cancel();
    }
  }

  @override
  void dispose() {
    widget.onSessionEnd?.call();
    _peekTimer?.cancel();
    _debounce?.cancel();
    _searchText.dispose();
    _searchFocus.dispose();
    _keys.dispose();
    super.dispose();
  }

  /// Same timing as the dashboard: applied once typing pauses, clearing at
  /// once.
  void _onSearchText(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      if (_query != text) setState(() => _query = text);
      return;
    }
    _debounce = Timer(DashboardQueryNotifier.searchDebounce, () {
      if (mounted && _query != text) setState(() => _query = text);
    });
  }

  void _clearSearch() {
    _searchText.clear();
    _onSearchText('');
  }

  /// Ctrl+F focuses the search; Esc in it clears it, or leaves it when it
  /// is already empty.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (AppKeys.fileSearch.accepts(event)) {
      _searchFocus.requestFocus();
      _searchText.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchText.text.length,
      );
      return KeyEventResult.handled;
    }
    if (AppKeys.clearFileSearch.accepts(event) && _searchFocus.hasFocus) {
      if (_searchText.text.isEmpty) {
        _keys.requestFocus();
      } else {
        _clearSearch();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;
    final folder = _folder;
    final base = folder == null
        ? widget.contents
        : widget.contents.within(folder);
    final words = queryWords(_query);
    final searching = words.isNotEmpty;
    var contents = base;
    if (searching) {
      contents = base.matching(words);
      // The dashboard's infix fallback: only when no file matches by word
      // prefix and every word has 3+ characters.
      if (contents.isEmpty && words.every((w) => w.length >= 3)) {
        contents = base.matching(words, infix: true);
      }
    }
    final favorites = _onlyFavorites;
    if (favorites) contents = contents.only(widget.favoriteFiles);
    final filtering = searching || favorites;
    // A tab without matches goes, unless it is the open one: it stays and
    // says so, so typing doesn't jump to another tab.
    final tabs = <(Type, String, Widget)>[];
    void add(Type kind, String label, int count, int all, Widget Function() t) {
      if (count == 0 && !(filtering && kind == _tab && all > 0)) return;
      tabs.add((
        kind,
        '$label (${formatCount(count)})',
        count == 0 ? _NoMatches(query: _query, favorites: favorites) : t(),
      ));
    }

    add(
      _AnimationsTab,
      'Animations',
      contents.animations.length,
      base.animations.length,
      () => _AnimationsTab(pack: pack, contents: contents),
    );
    add(
      _ImagesTab,
      'Images',
      contents.images.length,
      base.images.length,
      () => _ImagesTab(pack: pack, contents: contents),
    );
    add(
      _AudioTab,
      'Audio',
      groupAudioFormats(contents.audio).length,
      groupAudioFormats(base.audio).length,
      () => _AudioTab(pack: pack, contents: contents),
    );
    add(
      ModelsTab,
      'Models',
      groupModelFormats(contents.models).length,
      groupModelFormats(base.models).length,
      () => ModelsTab(pack: pack, contents: contents),
    );
    add(
      MaterialsTab,
      'Materials',
      contents.materials.length,
      base.materials.length,
      () => MaterialsTab(pack: pack, contents: contents),
    );
    add(
      _FilesTab,
      'Other files',
      contents.other.length,
      base.other.length,
      () => _FilesTab(pack: pack, contents: contents),
    );
    final actions = _HeaderActions(
      pack: pack,
      pinned: widget.pinned,
      onTogglePin: widget.onTogglePin,
    );
    final header = _Header(
      pack: pack,
      contents: widget.contents,
      actions: actions,
    );
    final field = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 16, 6),
      child: SizedBox(
        width: detailControlWidth,
        height: detailControlHeight,
        // One line: `expands` would need `maxLines: null`, and a long search
        // then wrapped onto a second line.
        child: TextField(
          textAlignVertical: TextAlignVertical.center,
          key: _fieldKey,
          controller: _searchText,
          focusNode: _searchFocus,
          onChanged: _onSearchText,
          onTapOutside: (_) {
            if (_searchFocus.hasFocus) _keys.requestFocus();
          },
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            prefixIcon: const Icon(Icons.search, size: 20),
            prefixIconConstraints: const BoxConstraints(
              minWidth: 36,
              minHeight: detailControlHeight,
            ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 36,
              minHeight: detailControlHeight,
            ),
            hintText: 'Search files',
            border: const OutlineInputBorder(borderRadius: detailControlRadius),
            suffixIcon: ValueListenableBuilder(
              valueListenable: _searchText,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'Clear search (Esc)',
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
        ),
      ),
    );
    final favoritesChip = Padding(
      padding: const EdgeInsets.only(left: 8),
      child: SizedBox(
        height: detailControlHeight,
        child: FilterChip(
          key: const ValueKey('detail-favorites-chip'),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          mouseCursor: clickCursor,
          avatar: Icon(
            favorites ? Icons.star : Icons.star_border,
            size: 18,
            color: FavoriteStar.color,
          ),
          showCheckmark: false,
          tooltip: favorites
              ? 'Favorites: show all files'
              : 'Favorites: show only the starred files of this pack',
          // Only the star and the count: `★ 12`.
          label: Text(formatCount(widget.favoriteFiles.length)),
          visualDensity: detailChipDensity,
          shape: const RoundedRectangleBorder(
            borderRadius: detailControlRadius,
          ),
          selected: favorites,
          onSelected: (on) => setState(() => _onlyFavorites = on),
        ),
      ),
    );
    final tabArea = <Widget>[
      if (folder != null)
        _FolderBar(
          folder: folder,
          onShowAll: () => setState(() => _folder = null),
        ),
      if (searching) _SearchFilterBar(text: _query, onShowAll: _clearSearch),
      if (tabs.isEmpty) ...[
        Row(children: [const Spacer(), favoritesChip, field]),
        Expanded(
          child: filtering
              ? _NoMatches(query: _query, favorites: favorites)
              : const Center(child: Text('No files')),
        ),
      ] else ...[
        Row(
          children: [
            Expanded(
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (final (_, label, _) in tabs) Tab(text: label)],
              ),
            ),
            favoritesChip,
            field,
          ],
        ),
        _TabMemory(
          onChanged: (i) {
            _tab = i < tabs.length ? tabs[i].$1 : null;
            _report();
          },
        ),
        Expanded(
          child: TabBarView(children: [for (final (_, _, t) in tabs) t]),
        ),
      ],
    ];
    // Music / sfx packs open on their Audio tab, packs typed `material` on
    // Materials, 3D packs on Models; a
    // clicked file result on the tab that lists it.
    final audioTab = tabs.indexWhere((t) => t.$1 == _AudioTab);
    final modelsTab = tabs.indexWhere((t) => t.$1 == ModelsTab);
    final materialsTab = tabs.indexWhere((t) => t.$1 == MaterialsTab);
    var initial = isAudioPack(pack.types) && audioTab >= 0
        ? audioTab
        : pack.types.contains(AssetType.material.id) && materialsTab >= 0
        ? materialsTab
        : isModelPack(pack.types) && modelsTab >= 0
        ? modelsTab
        : 0;
    if (widget.file case final file? when widget.search != null) {
      final at = tabs.indexWhere(
        (t) => switch (t.$1) {
          const (_AnimationsTab) => contents.shownDetected.any(
            (a) => a.path == file,
          ),
          const (_ImagesTab) => contents.images.contains(file),
          const (_AudioTab) => contents.audio.contains(file),
          const (ModelsTab) => contents.models.contains(file),
          const (MaterialsTab) => contents.materials.any(
            (m) => m.files.contains(file),
          ),
          const (_FilesTab) => contents.other.contains(file),
          _ => false,
        },
      );
      if (at >= 0) initial = at;
    }
    final kept = tabs.indexWhere((t) => t.$1 == _tab);
    if (kept >= 0) initial = kept;
    if (tabs.isNotEmpty) _tab = tabs[initial].$1;
    _report();
    return Focus(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: DefaultTabController(
        // A new controller when the folder filter is cleared or the set of
        // tabs changes; the open tab is kept by kind.
        key: ValueKey((folder, [for (final (k, _, _) in tabs) k].join(','))),
        length: tabs.length,
        initialIndex: initial,
        child: widget.pinned
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [header, ...tabArea],
              )
            : Stack(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      MouseRegion(
                        onEnter: (_) => _hoverSlim(true),
                        onExit: (_) => _hoverSlim(false),
                        child: _SlimHeader(
                          pack: pack,
                          contents: contents,
                          actions: actions,
                        ),
                      ),
                      ...tabArea,
                    ],
                  ),
                  if (_peek)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: MouseRegion(
                        onExit: (_) => setState(() => _peek = false),
                        child: Material(
                          elevation: 8,
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          child: header,
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

/// An open tab whose files all miss the search.
class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.query, this.favorites = false});

  final String query;

  /// The Favorites chip is on: says nothing here is starred (matching the
  /// search, if any).
  final bool favorites;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(favorites ? Icons.star_border : Icons.search_off, size: 48),
        const SizedBox(height: 8),
        Text(
          !favorites
              ? 'No files match “${query.trim()}”'
              : query.trim().isEmpty
              ? 'No starred files'
              : 'No starred files match “${query.trim()}”',
        ),
      ],
    ),
  );
}

/// Every type is music or sfx (mixed packs such as characters + sfx keep
/// their first tab).
bool isAudioPack(List<String> types) =>
    types.isNotEmpty &&
    types.every((t) => t == AssetType.music.id || t == AssetType.sfx.id);

/// Only 3D models: the page opens on the Models tab.
bool isModelPack(List<String> types) =>
    types.isNotEmpty && types.every((t) => t == AssetType.threeD.id);

/// A dashboard search the detail page is filtered by.
class SearchFilter {
  const SearchFilter(this.text, {this.infix = false});

  final String text;

  /// The search matched by substring (see [fileMatches]).
  final bool infix;

  List<String> get words => queryWords(text);
}

/// Says the tabs list only the files matching the search, with a way back to
/// all of them. One chip, whether the search came from the dashboard or was
/// typed here.
class _SearchFilterBar extends StatelessWidget {
  const _SearchFilterBar({required this.text, required this.onShowAll});

  final String text;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          InputChip(
            avatar: const Icon(Icons.search, size: 18),
            label: Text('Matching “${text.trim()}”'),
            tooltip: 'Showing only files that match the search',
            mouseCursor: clickCursor,
            onDeleted: onShowAll,
            deleteButtonTooltipMessage: 'Show all files',
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onShowAll,
            child: Text('Show all files', style: theme.textTheme.labelLarge),
          ),
        ],
      ),
    );
  }
}

/// Says the tabs show one folder of the pack, with a way back to all of it.
class _FolderBar extends StatelessWidget {
  const _FolderBar({required this.folder, required this.onShowAll});

  final String folder;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          InputChip(
            avatar: const Icon(Icons.folder_outlined, size: 18),
            label: Text(prettyName(folder, isFile: false)),
            tooltip: 'Showing only this folder',
            mouseCursor: clickCursor,
            onDeleted: onShowAll,
            deleteButtonTooltipMessage: 'Show the whole pack',
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onShowAll,
            child: Text('Show whole pack', style: theme.textTheme.labelLarge),
          ),
        ],
      ),
    );
  }
}

/// Carousel and info side by side.
class _Header extends StatelessWidget {
  const _Header({
    required this.pack,
    required this.contents,
    required this.actions,
  });

  final PackRow pack;
  final PackContents contents;

  /// Pin / itch.io / folder, in the top-right corner.
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      // The info sizes to its content; it only scrolls when it would
      // take more than half the window from the tabs.
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: math.max(300, MediaQuery.sizeOf(context).height * 0.5),
        ),
        // The preview box is as tall as the info column (at least
        // [previewBoxMinHeightFor] the window), so neither sticks out
        // below the other.
        child: _HeaderRow(
          minBoxHeight: previewBoxMinHeightFor(MediaQuery.sizeOf(context)),
          box: _Carousel(
            key: const ValueKey('header-preview'),
            pack: pack,
            contents: contents,
            images: contents.carousel(pack.preview),
            sizes: contents.sizes,
          ),
          // The info takes the full width; the icons sit in its top-right
          // corner and only the title row leaves room for them.
          info: KeyedSubtree(
            key: const ValueKey('header-info'),
            child: _Info(pack: pack, contents: contents, actions: actions),
          ),
        ),
      ),
    );
  }
}

/// Header preview box: width, and height when the info column is shorter.
const previewBoxWidth = 440.0;
const previewBoxMinHeight = 320.0;

/// The box's least height in a window of [window]: [previewBoxMinHeight],
/// down to 240 in short windows (40% of the height) so the grid's first
/// row stays in view.
double previewBoxMinHeightFor(Size window) =>
    (window.height * 0.4).clamp(240.0, previewBoxMinHeight);

/// [box] (the preview, [previewBoxWidth] wide) beside [info]: the info is
/// laid out first and the box takes its height, at least [minBoxHeight],
/// never more than the space given.
class _HeaderRow extends MultiChildRenderObjectWidget {
  _HeaderRow({
    required this.minBoxHeight,
    required Widget box,
    required Widget info,
  }) : super(children: [box, info]);

  final double minBoxHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderHeaderRow()..minBoxHeight = minBoxHeight;

  @override
  void updateRenderObject(BuildContext context, _RenderHeaderRow render) =>
      render.minBoxHeight = minBoxHeight;
}

class _HeaderRowParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderHeaderRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _HeaderRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _HeaderRowParentData> {
  static const _gap = 24.0;

  double get minBoxHeight => _minBoxHeight;
  var _minBoxHeight = previewBoxMinHeight;
  set minBoxHeight(double v) {
    if (v == _minBoxHeight) return;
    _minBoxHeight = v;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _HeaderRowParentData) {
      child.parentData = _HeaderRowParentData();
    }
  }

  @override
  void performLayout() {
    final box = firstChild!;
    final info = childAfter(box)!;
    final width = constraints.maxWidth;
    final infoWidth = math.max(0.0, width - previewBoxWidth - _gap);
    info.layout(
      BoxConstraints(
        minWidth: infoWidth,
        maxWidth: infoWidth,
        maxHeight: constraints.maxHeight,
      ),
      parentUsesSize: true,
    );
    final height = constraints.constrainHeight(
      math.max(info.size.height, _minBoxHeight),
    );
    box.layout(BoxConstraints.tightFor(width: previewBoxWidth, height: height));
    (info.parentData! as _HeaderRowParentData).offset = const Offset(
      previewBoxWidth + _gap,
      0,
    );
    size = constraints.constrain(Size(width, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// How long the pointer rests on the slim bar before the header opens.
const headerHoverDelay = Duration(milliseconds: 400);

/// Pin header, itch.io page (when linked) and open folder: the header's
/// top-right corner, and the slim bar's right end.
class _HeaderActions extends StatelessWidget {
  const _HeaderActions({
    required this.pack,
    required this.pinned,
    required this.onTogglePin,
  });

  final PackRow pack;
  final bool pinned;
  final VoidCallback onTogglePin;

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('header-actions'),
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: pinned
            ? 'Unpin header — show it on hover (H)'
            : 'Pin header (H)',
        isSelected: pinned,
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.push_pin_outlined),
        selectedIcon: const Icon(Icons.push_pin),
        onPressed: onTogglePin,
      ),
      if (pack.itchUrl case final url?)
        IconButton(
          tooltip: 'itch.io page',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.storefront_outlined),
          onPressed: () => launchUrl(Uri.parse(url)),
        ),
      IconButton(
        tooltip: 'Open folder',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.folder_open),
        onPressed: () => launchUrl(Uri.directory(pack.path)),
      ),
    ],
  );
}

/// The unpinned header: one line of facts; hover shows the full header.
class _SlimHeader extends StatelessWidget {
  const _SlimHeader({
    required this.pack,
    required this.contents,
    required this.actions,
  });

  final PackRow pack;
  final PackContents contents;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Container(
      height: 40,
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      color: theme.colorScheme.surfaceContainerLow,
      child: Row(
        children: [
          Icon(iconForTypes(pack.types), size: 18),
          const SizedBox(width: 4),
          _PackStar(packId: pack.id),
          const SizedBox(width: 4),
          // One Expanded for everything before the icons: a Flexible text
          // next to a Spacer would split the free space with it and leave
          // the icons in the middle of the bar.
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) {
                // The title keeps its width and the facts take what is
                // left, so they are cut first; the title is cut only when
                // the hint alone fills the bar.
                const hint = 'Hover for details';
                final painter = TextPainter(
                  text: TextSpan(text: hint, style: muted),
                  textDirection: TextDirection.ltr,
                  textScaler: MediaQuery.textScalerOf(context),
                )..layout();
                final reserved = painter.width.ceilToDouble() + 12 + 16 + 4;
                painter.dispose();
                return Row(
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: math.max(0, box.maxWidth - reserved),
                      ),
                      child: Text(
                        pack.title,
                        key: const ValueKey('slim-title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        [
                          pack.author ?? 'Unknown author',
                          if (pack.types.isNotEmpty) pack.types.join(', '),
                          '${formatCount(pack.fileCount)} files',
                          formatBytes(pack.totalBytes),
                        ].join(' · '),
                        key: const ValueKey('slim-facts'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.unfold_more, size: 16, color: muted?.color),
                    const SizedBox(width: 4),
                    Text(hint, style: muted),
                  ],
                );
              },
            ),
          ),
          actions,
        ],
      ),
    );
  }
}

/// The tile preview (animated when it's a sheet) plus covers and named
/// previews, one at a time.
class _Carousel extends ConsumerStatefulWidget {
  const _Carousel({
    super.key,
    required this.pack,
    required this.contents,
    required this.images,
    this.sizes = const {},
  });

  final PackRow pack;
  final PackContents contents;
  final List<String> images;
  final Map<String, int> sizes;

  @override
  ConsumerState<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends ConsumerState<_Carousel> {
  var _index = 0;
  var _hover = false;

  Future<void> _choose() async {
    // Read before the dialog: the header may collapse (and this widget
    // unmount) once the pointer leaves it.
    final library = ref.read(libraryProvider.notifier);
    final pack = widget.pack;
    final custom = widget.contents.chosenPreviews.isNotEmpty;
    final next = await showDialog<List<String>>(
      context: context,
      builder: (_) => PreviewPickerDialog(
        packPath: pack.path,
        files: widget.contents.previewable,
        animations: widget.contents.animationsByPath,
        initial: widget.images,
        custom: custom,
      ),
    );
    if (next == null || !packExists(pack.path)) return;
    savePreviews(pack.path, next);
    if (mounted) setState(() => _index = 0);
    await library.reload();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final images = widget.images;
    final pack = widget.pack;
    final i = images.isEmpty ? 0 : _index % images.length;
    final anims = widget.contents.animationsByPath;
    final Widget view;
    if (images.isEmpty) {
      view = Center(
        child: Icon(iconForTypes(pack.types), size: 72, color: scheme.primary),
      );
    } else {
      // An animation plays, also when it is not the cover.
      view = PreviewPicture(
        packPath: pack.path,
        rel: images[i],
        anim:
            anims[images[i]] ??
            (i == 0 && images[i] == pack.preview ? pack.previewAnim : null),
      );
    }
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: scheme.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (images.isEmpty)
                Padding(padding: const EdgeInsets.all(8), child: view)
              else
                // Click to enlarge, on the same list at the same image.
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => showImageViewer(
                      context,
                      packPath: pack.path,
                      images: images,
                      index: i,
                      sizes: widget.sizes,
                      animations: anims,
                    ),
                    child: Tooltip(
                      message: 'Enlarge',
                      waitDuration: const Duration(milliseconds: 600),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: view,
                      ),
                    ),
                  ),
                ),
              if (_hover && widget.contents.previewable.isNotEmpty)
                Positioned(
                  top: 8,
                  left: 8,
                  child: IconButton.filledTonal(
                    key: const ValueKey('edit-previews'),
                    tooltip: 'Choose previews',
                    mouseCursor: clickCursor,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _choose,
                  ),
                ),
              if (images.length > 1) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton.filledTonal(
                    tooltip: 'Previous image',
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () => setState(
                      () => _index = (i - 1 + images.length) % images.length,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton.filledTonal(
                    tooltip: 'Next image',
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () =>
                        setState(() => _index = (i + 1) % images.length),
                  ),
                ),
                Positioned(
                  bottom: 8,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: scheme.surface.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '${i + 1} / ${images.length} · ${p.basename(images[i])}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
                if (_hover)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: IconButton.filledTonal(
                      tooltip: 'All previews (${images.length})',
                      mouseCursor: clickCursor,
                      icon: const Icon(Icons.grid_view),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => PreviewGridDialog(
                          packPath: pack.path,
                          images: images,
                          sizes: widget.sizes,
                          animations: anims,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Every preview candidate of a pack in a grid; a click opens it in the
/// viewer, stepping through the grid.
class PreviewGridDialog extends ConsumerWidget {
  const PreviewGridDialog({
    super.key,
    required this.packPath,
    required this.images,
    this.sizes = const {},
    this.animations = const {},
  });

  /// The previews that are animations, by file: they play.
  final Map<String, SpriteAnim> animations;

  final String packPath;
  final List<String> images;
  final Map<String, int> sizes;

  static const _spacing = 8.0;
  static const _footer = 26.0;
  static const _padding = EdgeInsets.fromLTRB(16, 0, 16, 16);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final wanted = ref.watch(settingsProvider.select((s) => s.previewsColumns));
    final settings = ref.read(settingsProvider.notifier);
    final columns = balancedColumns(images.length, wanted);
    final left = closeOnLeft(context);
    return Dialog(
      child: ConstrainedBox(
        // The window limits the dialog first.
        constraints: const BoxConstraints(maxWidth: 2000, maxHeight: 1440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: dialogHeaderPadding(context, text: 20, top: 16),
              child: Row(
                children: [
                  if (left) ...[
                    const DialogCloseButton(),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      'Previews (${images.length})',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  // Fewer columns = bigger cards, like the size sliders.
                  IconButton(
                    tooltip: 'Fewer columns ($primaryKey + wheel up)',
                    icon: const Icon(Icons.remove),
                    onPressed: wanted > 1
                        ? () => settings.setPreviewsColumns(wanted - 1)
                        : null,
                  ),
                  Tooltip(
                    message: 'Columns',
                    child: SizedBox(
                      width: 28,
                      child: Text(
                        '$wanted',
                        key: const ValueKey('previews-columns'),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'More columns ($primaryKey + wheel down)',
                    icon: const Icon(Icons.add),
                    onPressed: wanted < 8
                        ? () => settings.setPreviewsColumns(wanted + 1)
                        : null,
                  ),
                  if (!left) ...[
                    const SizedBox(width: 8),
                    const DialogCloseButton(),
                  ],
                ],
              ),
            ),
            Flexible(
              child: CtrlWheelResize(
                // Wheel up = bigger cards = fewer columns.
                onSteps: (n) => settings.setPreviewsColumns(wanted - n),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // The cards share the width; each keeps a 4:3 image
                    // area over its name.
                    final width =
                        (constraints.maxWidth -
                            _padding.horizontal -
                            _spacing * (columns - 1)) /
                        columns;
                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const CtrlWheelPhysics(),
                      padding: _padding,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: _spacing,
                        mainAxisSpacing: _spacing,
                        mainAxisExtent: width * 3 / 4 + _footer,
                      ),
                      itemCount: images.length,
                      itemBuilder: (context, i) => Card(
                        key: ValueKey('preview:${images[i]}'),
                        clipBehavior: Clip.antiAlias,
                        margin: EdgeInsets.zero,
                        child: InkWell(
                          mouseCursor: clickCursor,
                          onTap: () => showImageViewer(
                            context,
                            packPath: packPath,
                            images: images,
                            index: i,
                            sizes: sizes,
                            animations: animations,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.all(6),
                                  child: PreviewPicture(
                                    packPath: packPath,
                                    rel: images[i],
                                    anim: animations[images[i]],
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                                child: Tooltip(
                                  message: images[i],
                                  child: Text(
                                    p.basename(images[i]),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Title, author, types, tags and totals, each editable in place.
class _Info extends ConsumerWidget {
  const _Info({
    required this.pack,
    required this.contents,
    required this.actions,
  });

  final PackRow pack;
  final PackContents contents;

  /// Pin / itch.io / folder: the end of the title row, so a long title
  /// wraps before them and every line below runs to the right edge.
  final Widget actions;

  /// Takes the notifier rather than [WidgetRef]: the header collapses
  /// once the pointer leaves it for a dialog, unmounting this widget, so
  /// its ref is dead by the time the dialog returns.
  Future<void> _save(
    LibraryNotifier library, {
    String? title,
    List<String>? types,
    List<String>? tags,
  }) async {
    if (!packExists(pack.path)) return;
    updatePackSidecar(pack.path, title: title, types: types, tags: tags);
    await library.reload();
  }

  /// The pack's author folder: the first path segment under the library.
  String? _authorDir(WidgetRef ref) {
    final root = ref.read(libraryProvider).value?.root;
    return root == null ? null : p.join(root, p.split(pack.id).first);
  }

  AuthorInfo? _author(WidgetRef ref) {
    final dir = _authorDir(ref);
    return dir == null ? null : AuthorInfo.read(p.join(dir, authorFileName));
  }

  Future<void> _editAuthor(BuildContext context, WidgetRef ref) async {
    final dir = _authorDir(ref);
    if (dir == null) return;
    final library = ref.read(libraryProvider.notifier);
    final edit = await showDialog<AuthorEdit>(
      context: context,
      builder: (_) => AuthorInfoDialog(
        initial: _author(ref) ?? AuthorInfo(user: p.basename(dir)),
      ),
    );
    if (edit == null || !Directory(dir).existsSync()) return;
    updateAuthorInfo(
      dir,
      url: edit.url,
      license: edit.license,
      credit: edit.credit,
      attribution: edit.attribution == 'unknown' ? '' : edit.attribution,
    );
    await library.reload();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final authorUrl = pack.authorUrl;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Row(
                  children: [
                    _PackStar(packId: pack.id),
                    const SizedBox(width: _headerIconGap),
                    Flexible(
                      child: Text(
                        pack.title,
                        key: const ValueKey('header-title'),
                        style: theme.textTheme.headlineSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit title',
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () async {
                        final library = ref.read(libraryProvider.notifier);
                        final title = await showDialog<String>(
                          context: context,
                          builder: (_) => TitleDialog(
                            initial: contents.sidecar?.title ?? pack.title,
                            folderName: p.basename(pack.path),
                          ),
                        );
                        if (title != null) await _save(library, title: title);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              actions,
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              // As wide as the star above, so the two icons share a centre
              // line and the title and author start at the same x.
              const SizedBox(
                key: ValueKey('header-author-icon'),
                width: _headerStarSize,
                child: Icon(Icons.person_outline, size: 18),
              ),
              const SizedBox(width: _headerIconGap),
              if (authorUrl != null)
                InkWell(
                  mouseCursor: clickCursor,
                  onTap: () => launchUrl(Uri.parse(authorUrl)),
                  child: Text(
                    pack.author ?? authorUrl,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                )
              else
                Text(pack.author ?? 'Unknown author'),
              if (pack.author case final author?)
                _AuthorPacksLink(author: author),
              IconButton(
                tooltip: 'Edit author info',
                icon: const Icon(Icons.edit, size: 18),
                onPressed: () => _editAuthor(context, ref),
              ),
            ],
          ),
          if (_author(ref) case final AuthorInfo info when info.license != null)
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: Text(
                'License: ${info.license}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          _ChipRow(
            label: 'Types',
            values: pack.types,
            onEdit: () async {
              final library = ref.read(libraryProvider.notifier);
              final types = await showDialog<List<String>>(
                context: context,
                builder: (_) => TypesDialog(initial: pack.types),
              );
              if (types != null) await _save(library, types: types);
            },
          ),
          const SizedBox(height: 8),
          _ChipRow(
            label: 'Tags',
            values: sortedTags(pack.tags),
            onEdit: () async {
              final library = ref.read(libraryProvider.notifier);
              final tags = await showDialog<List<String>>(
                context: context,
                builder: (_) =>
                    TagsDialog(initial: pack.tags, known: knownTags(ref)),
              );
              if (tags != null) await _save(library, tags: tags);
            },
          ),
          const SizedBox(height: 8),
          _ChipRow(
            label: 'Used in',
            values: pack.usedIn,
            editIcon: Icons.add,
            editTooltip: 'Mark as used in a game',
            onDelete: (game) async {
              final library = ref.read(libraryProvider.notifier);
              final ok = await confirmRemoveFromGame(
                context,
                pack: pack.title,
                game: game,
              );
              if (!ok || !packExists(pack.path)) return;
              setUsedIn(pack.path, game, used: false);
              await library.reload();
            },
            onEdit: () async {
              final library = ref.read(libraryProvider.notifier);
              final packs = ref.read(libraryProvider).value?.packs ?? const [];
              final game = await showDialog<String>(
                context: context,
                builder: (_) => GameNameDialog(known: knownGames(packs)),
              );
              if (game == null || !packExists(pack.path)) return;
              setUsedIn(pack.path, game, used: true);
              await library.reload();
            },
          ),
          const SizedBox(height: 16),
          Text(
            '${formatCount(pack.fileCount)} files · '
            '${formatBytes(pack.totalBytes)}'
            '${pack.source == null ? '' : ' · ${pack.source}'}',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 4),
          SelectableText(
            pack.path,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// "N packs" by the author name: how many packs in the library carry this
/// author (sub-packs too, as the dashboard's Author filter lists them).
/// Clicking it shows exactly those on the dashboard.
class _AuthorPacksLink extends ConsumerWidget {
  const _AuthorPacksLink({required this.author});

  final String author;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final packs = ref.watch(libraryProvider).value?.packs ?? const [];
    final n = packs.where((p) => p.author == author).length;
    return TextButton(
      key: const ValueKey('author-packs'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      onPressed: () {
        ref.read(dashboardQueryProvider.notifier).showAuthor(author);
        // Also from a pack tab, or a pack opened over the tabs (itch.io).
        Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
        ref.read(tabsProvider.notifier).showDashboard();
      },
      child: Tooltip(
        message: 'Show $author’s packs on the dashboard',
        child: Text('${formatCount(n)} pack${n == 1 ? '' : 's'}'),
      ),
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.label,
    required this.values,
    required this.onEdit,
    this.onDelete,
    this.editIcon = Icons.edit,
    this.editTooltip,
  });

  final String label;
  final List<String> values;
  final VoidCallback onEdit;

  /// When set, chips get a delete button.
  final ValueChanged<String>? onDelete;
  final IconData editIcon;
  final String? editTooltip;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 64,
          child: Text(label, style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(
          // The edit / add icon follows the last chip, so it wraps to the
          // next line with them.
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final v in values)
                Chip(
                  label: Text(v),
                  visualDensity: VisualDensity.compact,
                  deleteIcon: deleteIcon,
                  onDeleted: onDelete == null ? null : () => onDelete!(v),
                  deleteButtonTooltipMessage: 'Remove $v',
                ),
              IconButton(
                tooltip: editTooltip ?? 'Edit ${label.toLowerCase()}',
                visualDensity: VisualDensity.compact,
                icon: Icon(editIcon, size: 18),
                onPressed: onEdit,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Reports the [DefaultTabController]'s index whenever it changes.
class _TabMemory extends StatefulWidget {
  const _TabMemory({required this.onChanged});

  final ValueChanged<int> onChanged;

  @override
  State<_TabMemory> createState() => _TabMemoryState();
}

class _TabMemoryState extends State<_TabMemory> {
  TabController? _controller;

  void _changed() => widget.onChanged(_controller!.index);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = DefaultTabController.maybeOf(context);
    if (c == _controller) return;
    _controller?.removeListener(_changed);
    _controller = c?..addListener(_changed);
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Files marked "Not an animation", each with Restore (back to detected).
class _HiddenAnimationsDialog extends ConsumerWidget {
  const _HiddenAnimationsDialog({required this.pack, required this.hidden});

  final PackRow pack;
  final List<SpriteAnim> hidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AlertDialog(
    title: const Text('Not animations'),
    content: SizedBox(
      width: 420,
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final a in hidden)
            ListTile(
              dense: true,
              title: Text(prettyName(a.label, isFile: false)),
              subtitle: Text(a.path),
              trailing: TextButton(
                onPressed: () async {
                  if (!packExists(pack.path)) return;
                  setNotAnimation(pack.path, a.path, hidden: false);
                  final library = ref.read(libraryProvider.notifier);
                  Navigator.of(context).pop();
                  await library.reload();
                },
                child: const Text('Restore'),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
    ],
  );
}

class _ImagesTab extends ConsumerStatefulWidget {
  const _ImagesTab({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  ConsumerState<_ImagesTab> createState() => _ImagesTabState();
}

class _ImagesTabState extends ConsumerState<_ImagesTab> {
  /// Folders folded away in the "By folder" view; remembered per pack.
  late final _collapsed = ref
      .read(folderFoldsProvider)
      .of(widget.pack.path, FoldTab.images);

  void _saveFolds() => ref
      .read(folderFoldsProvider)
      .set(widget.pack.path, FoldTab.images, _collapsed);

  /// Flat view selection (Ctrl/Shift-click or the hover checkbox), for
  /// "Combine N images into animation".
  final _selected = <String>{};
  String? _anchor;
  var _busy = false;

  /// Focus mode: the clicked card (by path); the others dim.
  final _focusedCard = CardFocus<String>();
  String? get _focused => _focusedCard.value;
  final _keys = FocusNode(debugLabel: 'images');

  /// The on-screen order, kept between clicks and key presses (M93).
  final _order = ShownOrder();

  /// A second click on a card opens the image viewer.
  final _clicks = DoubleClick<String>();

  /// Image sizes read from the file headers, for the card footers.
  final _dims = <String, (int, int)?>{};

  /// The grid's slider stops (M79).
  final _scale = ThumbScale(imageThumbRange, spacing: 8);

  @override
  void dispose() {
    _keys.dispose();
    _scale.dispose();
    _focusedCard.dispose();
    super.dispose();
  }

  void _focus(String? rel) {
    _focusedCard.value = rel;
    _keys.requestFocus();
  }

  /// The images in on-screen order.
  List<String> _shown() {
    _order.of(
      contents.images,
      ref.read(settingsProvider).imagesView,
      _collapsed,
    );
    return _order.shown;
  }

  /// Whether [rel] is on screen (not folded away).
  bool _isShown(String rel) {
    _shown();
    return _order.indexOfRel(rel) >= 0;
  }

  /// Esc and arrows act only while a card is focused; otherwise Esc goes on
  /// to the app and closes the page.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final focused = _focused;
    if (event is KeyUpEvent || focused == null) return KeyEventResult.ignored;
    final order = _shown();
    final at = _order.indexOfRel(focused);
    if (AppKeys.leaveFocus.accepts(event)) {
      _focus(null);
    } else if (AppKeys.focusPrevious.accepts(event) && at >= 0) {
      _focus(order[math.max(0, at - 1)]);
    } else if (AppKeys.focusNext.accepts(event) && at >= 0) {
      _focus(order[math.min(order.length - 1, at + 1)]);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  PackRow get pack => widget.pack;
  PackContents get contents => widget.contents;

  /// Images that are already (part of) a shown animation.
  late Set<String> _animated = _animatedFiles();

  Set<String> _animatedFiles() => {
    for (final a in contents.shownDetected) a.path,
  };

  @override
  void didUpdateWidget(_ImagesTab old) {
    super.didUpdateWidget(old);
    if (!identical(old.contents, contents)) {
      _animated = _animatedFiles();
      _selected.retainAll(contents.images);
      if (!contents.images.contains(_focused)) _focusedCard.value = null;
    }
  }

  void _toggle(String rel) => setState(() {
    _selected.contains(rel) ? _selected.remove(rel) : _selected.add(rel);
    _anchor = rel;
  });

  /// Shift-click: selects from the anchor to [rel] in the shown [order].
  void _selectRange(List<String> order, String rel) => setState(() {
    final a = _anchor == null ? -1 : order.indexOf(_anchor!);
    final b = order.indexOf(rel);
    if (a < 0) {
      _selected.add(rel);
    } else {
      _selected.addAll(order.sublist(math.min(a, b), math.max(a, b) + 1));
    }
    _anchor ??= rel;
  });

  /// "Make animation…": the Edit dialog with the best guess
  /// ([guessAnimation]): an animation's cells in the same folder, the gap
  /// grid, square frames, or one frame.
  Future<void> _makeAnimation(String rel) async {
    final size = readImageSize(p.join(pack.path, rel));
    if (size == null || _busy) return;
    setState(() => _busy = true);
    final SpriteAnim guess;
    try {
      guess = await guessAnimationInBackground(
        pack.path,
        rel,
        size.$1,
        size.$2,
        folderSizes: folderFrameSizes(rel, contents.shownDetected),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _AnimationEditorDialog(pack: pack, path: rel, pending: guess),
    );
  }

  /// Combines [rels] into one strip ([combinedName]); [unique] picks a free
  /// name, otherwise Save asks before replacing. Builds the strip in memory
  /// and opens it in the Edit dialog right away (no confirmation: only Save
  /// writes anything, under the name typed there).
  Future<void> _combine(List<String> rels, {required bool unique}) async {
    if (rels.length < 2 || _busy || !packExists(pack.path)) return;
    final taken = {
      ...contents.images,
      ...contents.other,
    }.where((r) => File(p.join(pack.path, r)).existsSync()).toSet();
    final out = combinedName(rels, taken: taken, unique: unique);
    final messenger = ScaffoldMessenger.maybeOf(context);
    // The tab may be rebuilt meanwhile; the dialog opens from the
    // navigator, which stays.
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    final CombinedStripImage strip;
    try {
      strip = await buildCombinedStripInBackground(pack.path, rels);
    } on Object catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger?.showSnackBar(
        SnackBar(content: Text('Could not combine the images: $e')),
      );
      return;
    }
    if (mounted) setState(() => _busy = false);
    if (!navigator.mounted) return;
    final saved = await showDialog<bool>(
      context: navigator.context,
      builder: (_) => _AnimationEditorDialog(
        pack: pack,
        path: out,
        bytes: strip.png,
        pending: SpriteAnim(
          path: out,
          kind: AnimKind.sheet,
          frameW: strip.frameW,
          frameH: strip.frameH,
          cols: strip.frames,
        ),
      ),
    );
    if (saved == true && mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final images = contents.images;
    final favorites = ref.watch(
      favoritesProvider.select((f) => f.filesOf(pack.id)),
    );
    final size = imageThumbRange.clamp(
      ref.watch(settingsProvider.select((s) => s.imageThumbSize)),
    );
    final view = ref.watch(settingsProvider.select((s) => s.imagesView));
    final settings = ref.read(settingsProvider.notifier);
    final column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TabToolbar(
          children: [
            if (view == ItemsView.folders) ...[
              FoldAllButton(
                rels: images,
                collapsed: _collapsed,
                onPressed: () => setState(() {
                  toggleAllFolders(images, _collapsed);
                  _saveFolds();
                  // A card folded out of sight can't stay focused.
                  if (_focused case final rel? when !_isShown(rel)) {
                    _focusedCard.value = null;
                  }
                }),
              ),
              const SizedBox(width: 4),
            ],
            ItemsViewToggle(view: view, onChanged: settings.setImagesView),
            if (contents.hiddenAnimations case final hidden
                when hidden.isNotEmpty) ...[
              const SizedBox(width: 12),
              TextButton.icon(
                icon: const Icon(Icons.motion_photos_off_outlined, size: 18),
                label: Text('${hidden.length} marked not an animation'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      _HiddenAnimationsDialog(pack: pack, hidden: hidden),
                ),
              ),
            ],
            const Spacer(),
            ThumbSizeSlider(
              width: detailControlWidth,
              range: imageThumbRange,
              value: size,
              scale: _scale,
              onChanged: settings.setImageThumbSize,
            ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_selected.isNotEmpty)
          Padding(
            key: const ValueKey('selection-bar'),
            // Space below, like above, before the grid's own padding.
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Text('${_selected.length} selected'),
                const SizedBox(width: 12),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.animation, size: 18),
                  label: Text(
                    'Combine ${_selected.length} images into animation',
                  ),
                  onPressed: _selected.length >= 2 && !_busy
                      ? () => _combine(
                          images.where(_selected.contains).toList(),
                          unique: true,
                        )
                      : null,
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(_selected.clear),
                  child: const Text('Clear selection'),
                ),
              ],
            ),
          ),
        Expanded(
          child: CtrlWheelResize(
            onSteps: (n) => settings.setImageThumbSize(_scale.step(size, n)),
            // Taps that miss every card clear the focus.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _focus(null),
              child: _imageGrid(context, images, size, view, favorites),
            ),
          ),
        ),
      ],
    );
    return FocusBackHandler(
      focus: _focusedCard,
      onBack: () => _focus(null),
      child: Focus(focusNode: _keys, onKeyEvent: _onKey, child: column),
    );
  }

  Widget _imageGrid(
    BuildContext context,
    List<String> images,
    double size,
    ItemsView view,
    Set<String> favorites,
  ) {
    // The viewer steps through images in the order they're shown.
    _order.of(images, view, _collapsed);
    return GroupedGrid(
      key: PageStorageKey('images:${pack.id}'),
      rels: images,
      groups: _order.groups(images),
      view: view,
      collapsed: _collapsed,
      onToggleFolder: (f) => setState(() {
        if (!_collapsed.remove(f)) _collapsed.add(f);
        _saveFolds();
        // A card folded out of sight can't stay focused.
        if (_focused case final rel? when !_isShown(rel)) {
          _focusedCard.value = null;
        }
      }),
      physics: const CtrlWheelPhysics(),
      folderAction: (folder, items) => items.length < 2
          ? null
          : TextButton.icon(
              icon: const Icon(Icons.animation, size: 18),
              label: const Text('Combine into animation'),
              onPressed: _busy
                  ? null
                  : () => _combine([
                      for (final i in items) images[i],
                    ], unique: false),
            ),
      // A square image over a title and a size line, like animations.
      gridDelegate: ThumbGridDelegate(
        maxTileWidth: size,
        imageAspect: 1,
        footer: (_) => itemCardFooter,
        spacing: 8,
        mainAxisPadding: GroupedGrid.defaultPadding.vertical,
        scale: _scale,
      ),
      itemBuilder: (context, i) {
        final rel = images[i];
        final file = File(p.join(pack.path, rel));
        final selected = _selected.contains(rel);
        final canAnimate =
            !_animated.contains(rel) &&
            p.extension(rel).toLowerCase() == '.png';
        final shown = _order.shown;
        void open() => showImageViewer(
          context,
          packPath: pack.path,
          images: shown,
          index: math.max(0, _order.indexOf(i)),
          sizes: contents.sizes,
        );
        final dims = _dims.putIfAbsent(rel, () => readImageSize(file.path));
        // Plain click focuses; Ctrl/Shift-click select in the Flat view.
        // A right-click on one of several selected images acts on them all.
        return FileMenuArea(
          target: () => _selected.length > 1 && _selected.contains(rel)
              ? FileMenuTarget(
                  files: [
                    for (final s in shown)
                      if (_selected.contains(s)) p.join(pack.path, s),
                  ],
                )
              : FileMenuTarget(
                  files: [file.path],
                  image: file.path,
                  open: file.path,
                  preview: PreviewTarget(
                    packId: pack.id,
                    packPath: pack.path,
                    preview: pack.preview,
                    file: rel,
                  ),
                ),
          child: FocusedCard<String>(
            focus: _focusedCard,
            id: rel,
            builder: (context, focused, dimmed) => ItemCard(
              key: ValueKey('image:$rel'),
              path: rel,
              title: prettyName(p.basename(rel)),
              details: switch (dims) {
                (final w, final h) => '$w×$h',
                null => p.extension(rel).replaceFirst('.', '').toUpperCase(),
              },
              stagePadding: 6,
              stage: (_) => PixelImage(file),
              focused: focused,
              dimmed: dimmed,
              selected: selected,
              starred: favorites.contains(rel),
              onToggleStar: () =>
                  ref.read(favoritesProvider.notifier).toggleFile(pack.id, rel),
              showLeading: selected,
              // An icon toggle, the size of the other card icons.
              leading: IconButton(
                key: ValueKey('select:$rel'),
                tooltip: selected ? 'Deselect' : 'Select ($primaryKey-click)',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                isSelected: selected,
                icon: const Icon(Icons.check_box_outline_blank),
                selectedIcon: const Icon(Icons.check_box),
                onPressed: () => _toggle(rel),
              ),
              onTap: () {
                final keys = HardwareKeyboard.instance;
                if (keys.isShiftPressed) {
                  _clicks.reset();
                  _selectRange(shown, rel);
                } else if (primaryPressed) {
                  _clicks.reset();
                  _toggle(rel);
                } else if (_clicks.second(rel)) {
                  // Focused, without taking the keyboard from the viewer.
                  _focusedCard.value = rel;
                  open();
                } else {
                  _focus(_focused == rel ? null : rel);
                }
              },
              actions: [
                if (canAnimate)
                  CardIconButton(
                    tooltip: 'Make animation…',
                    icon: Icons.animation,
                    onPressed: () => _makeAnimation(rel),
                  ),
                OpenImageButton(onPressed: open),
                RevealButton(file.path),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _AnimationsTab extends ConsumerWidget {
  const _AnimationsTab({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  Widget build(BuildContext context, WidgetRef ref) => AnimationGrid(
    gridId: pack.id,
    packPath: pack.path,
    favoriteFiles: ref.watch(
      favoritesProvider.select((f) => f.filesOf(pack.id)),
    ),
    onToggleFavorite: (rel) =>
        ref.read(favoritesProvider.notifier).toggleFile(pack.id, rel),
    animations: contents.animations,
    detected: contents.shownDetected,
    sizes: contents.sizes,
    previewFor: (rel) => PreviewTarget(
      packId: pack.id,
      packPath: pack.path,
      preview: pack.preview,
      file: rel,
    ),
    onEdit: (anim) => showDialog<void>(
      context: context,
      builder: (_) => _AnimationEditorDialog(pack: pack, path: anim.path),
    ),
  );
}

/// The fps / frame size / row editor for the animation at [path]. Watches
/// the pack, so after Save the editor shows the stored override, as the old
/// in-list cards did.
class _AnimationEditorDialog extends ConsumerStatefulWidget {
  const _AnimationEditorDialog({
    required this.pack,
    required this.path,
    this.pending,
    this.bytes,
  });

  final PackRow pack;
  final String path;

  /// "Make animation…": the starting guess for an image that isn't an
  /// animation yet. Save then marks it `manual`. Once the pack reloads with
  /// it, the stored animation takes over.
  final SpriteAnim? pending;

  /// "Combine into animation": the strip built in memory, written to
  /// [path] only on Save (asking before replacing a file). Cancel / Esc
  /// write nothing. The dialog pops `true` once it has been saved.
  final Uint8List? bytes;

  @override
  ConsumerState<_AnimationEditorDialog> createState() =>
      _AnimationEditorDialogState();
}

class _AnimationEditorDialogState
    extends ConsumerState<_AnimationEditorDialog> {
  PackRow get pack => widget.pack;

  /// Where the animation is: [_AnimationEditorDialog.path], or for a
  /// combined strip the name typed into the file name field once saved.
  late String path = widget.path;

  /// The unsaved strip; null once saved (or for files on disk).
  late Uint8List? _bytes = widget.bytes;
  var _saved = false;

  /// The combined strip's file name, without `.png`.
  late final _name = TextEditingController(
    text: p.posix.basenameWithoutExtension(widget.path),
  );

  /// Takes the keyboard focus once shown, so Esc closes this dialog even
  /// when it opened while the Combine confirmation was still closing.
  final _focus = FocusNode(debugLabel: 'animation editor dialog');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_focus.hasFocus) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Where Save writes the combined strip: [_name] next to the frames.
  String get _target {
    final folder = p.posix.dirname(widget.path);
    // A typed ".png" isn't doubled.
    final stem = _name.text.trim().replaceFirst(
      RegExp(r'\.png$', caseSensitive: false),
      '',
    );
    final file = '$stem.png';
    return folder == '.' ? file : p.posix.join(folder, file);
  }

  /// Asks before a combined strip replaces an existing file at [rel].
  Future<bool> _confirmReplace(String rel) async {
    if (!File(p.join(pack.path, rel)).existsSync()) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace animation?'),
        content: Text('$rel already exists. Replace it?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pending;
    final contents = ref.watch(packContentsProvider(pack.id)).value;
    final bytes = _bytes;
    // `animations` follows `shownDetected`, index for index. An unsaved
    // strip is always new, even when a file of that name exists.
    final shown = contents?.shownDetected ?? const <SpriteAnim>[];
    final i = bytes != null ? -1 : shown.indexWhere((a) => a.path == path);
    final isNew = i < 0 && pending != null;
    final detected = i >= 0 ? shown[i] : pending;
    final current = i >= 0 ? contents!.animations[i] : pending;
    // Made by hand: resetting turns it back into a plain image.
    final manual =
        bytes == null &&
        contents != null &&
        manualAnimations(contents.sidecar?.animations ?? const {})
            .contains(path);
    return Dialog(
      child: Focus(
        focusNode: _focus,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: contents == null || detected == null || current == null
                ? const SizedBox(
                    height: 200,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (bytes != null)
                        _FileNameField(
                          controller: _name,
                          onChanged: () => setState(() {}),
                        ),
                      AnimationEditor(
                        // The same editor while the name is typed.
                        key: ValueKey(
                          '${bytes != null ? widget.path : path}:'
                          '${bytes != null}',
                        ),
                        saveBlocked:
                            bytes != null &&
                            fileNameProblem(_name.text) != null,
                        newPath: bytes != null ? _target : null,
                        packPath: pack.path,
                        detected: detected,
                        current: current,
                        isNew: isNew,
                        manual: manual,
                        bytes: bytes,
                        onSave: (anim) async {
                          if (!packExists(pack.path)) return;
                          final library = ref.read(libraryProvider.notifier);
                          if (bytes != null) {
                            if (fileNameProblem(_name.text) != null) return;
                            final target = _target;
                            if (anim == null ||
                                !await _confirmReplace(target)) {
                              return;
                            }
                            saveCombinedStrip(
                              pack.path,
                              bytes,
                              detected.copyWith(path: target),
                              anim.copyWith(path: target),
                            );
                            // The same path may be cached from an older file.
                            await FileImage(File(p.join(pack.path, target)))
                                .evict();
                            _saved = true;
                            await library.reload();
                            if (mounted) {
                              setState(() {
                                path = target;
                                _bytes = null;
                              });
                            }
                            return;
                          }
                          saveAnimationOverride(
                            pack.path,
                            // A new one is saved against what detection
                            // gives a manual file (a strip guess), not
                            // against the dialog's starting guess.
                            isNew
                                ? guessStrip(
                                    detected.path,
                                    detected.frameW * detected.cols,
                                    detected.frameH * detected.rows,
                                  )
                                : detected,
                            anim,
                            manual: isNew,
                          );
                          // Back to image: nothing is left to edit here.
                          if (anim == null && manual && context.mounted) {
                            Navigator.of(context).pop(_saved);
                          }
                          // The tile preview may be this sheet; rescan picks the
                          // override up.
                          await library.reload();
                        },
                        onNotAnimation: () =>
                            markNotAnimation(context, ref, pack, path),
                      ),
                      TextButton(
                        // maybePop: the editor holds it while saving.
                        onPressed: () => Navigator.of(context).maybePop(_saved),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Why [name] can't be a file name (without `.png`), or null when it can.
String? fileNameProblem(String name) {
  final n = name.trim();
  if (n.isEmpty) return 'Enter a file name';
  if (n == '.' || n == '..' || n.startsWith('.')) {
    return 'The name can\'t start with a dot';
  }
  if (RegExp(r'[/\\<>:"|?*\x00-\x1f]').hasMatch(n)) {
    return 'Not allowed: / \\ < > : " | ? *';
  }
  return null;
}

/// The file name of a combined strip before it is saved; `.png` is added.
class _FileNameField extends StatelessWidget {
  const _FileNameField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
    child: TextField(
      key: const ValueKey('combine-name'),
      controller: controller,
      onChanged: (_) => onChanged(),
      decoration: InputDecoration(
        isDense: true,
        labelText: 'File name',
        suffixText: '.png',
        border: const OutlineInputBorder(),
        errorText: fileNameProblem(controller.text),
      ),
    ),
  );
}

/// How long a snack bar with Undo stays before it hides by itself.
const undoSnackDuration = Duration(seconds: 6);

/// Marks [rel] as not an animation, closes the editor and offers Undo.
///
/// The editor's own `ref` is gone once it closes, so the reloads go
/// through the provider container.
Future<void> markNotAnimation(
  BuildContext context,
  WidgetRef ref,
  PackRow pack,
  String rel,
) async {
  if (!packExists(pack.path)) return;
  setNotAnimation(pack.path, rel);
  final container = ProviderScope.containerOf(context, listen: false);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (context.mounted) Navigator.of(context).pop();
  messenger?.showSnackBar(
    SnackBar(
      content: Text('${p.basename(rel)} is now listed as an image only'),
      // With an action Flutter keeps it open until clicked otherwise.
      persist: false,
      duration: undoSnackDuration,
      action: SnackBarAction(
        label: 'Undo',
        onPressed: () {
          if (!packExists(pack.path)) return;
          setNotAnimation(pack.path, rel, hidden: false);
          container.read(libraryProvider.notifier).reload();
        },
      ),
    ),
  );
  await container.read(libraryProvider.notifier).reload();
}

/// Plays one animation with live fps / frame-size / row controls; Save
/// writes the override into the pack sidecar. Shown in the Edit dialog.
class AnimationEditor extends StatefulWidget {
  const AnimationEditor({
    super.key,
    required this.packPath,
    required this.detected,
    required this.current,
    required this.onSave,
    required this.onNotAnimation,
    this.isNew = false,
    this.manual = false,
    this.bytes,
    this.saveBlocked = false,
    this.newPath,
  });

  /// Save stays disabled (the new file's name isn't valid).
  final bool saveBlocked;

  /// An unsaved strip: where Save will write it (the name being typed),
  /// shown as the title and path.
  final String? newPath;

  /// The encoded sheet when it isn't on disk yet (a combined strip shown
  /// before Save); [SpriteAnim.path] is then where Save will write it.
  final Uint8List? bytes;

  /// Made into an animation by hand ("Make animation…" / combined): Reset
  /// is always offered and makes it a plain image again.
  final bool manual;

  final String packPath;

  /// Not saved as an animation yet: Save is enabled from the start and
  /// "Not an animation" isn't offered.
  final bool isNew;
  final SpriteAnim detected;
  final SpriteAnim current;

  /// Null resets to the detected values.
  final Future<void> Function(SpriteAnim? anim) onSave;

  /// "Not an animation": the file then only shows in the Images tab.
  final Future<void> Function() onNotAnimation;

  @override
  State<AnimationEditor> createState() => _AnimationEditorState();
}

class _AnimationEditorState extends State<AnimationEditor> {
  late SpriteAnim _anim = widget.current;
  late final _w = TextEditingController(text: '${widget.current.frameW}');
  late final _h = TextEditingController(text: '${widget.current.frameH}');
  late final _n = TextEditingController(text: '${widget.current.frameCount}');

  /// Shown under the Frames field when the count doesn't fit the sheet.
  String? _framesError;

  /// A save (Save, Reset / Back to image, Not an animation) is running: its
  /// buttons are disabled, Save shows a spinner, and Close / Esc wait.
  bool _saving = false;

  /// "Not an animation", after a confirmation; Cancel changes nothing.
  Future<void> _confirmNotAnimation() async {
    final name = prettyName(p.basename(widget.detected.path));
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Not an animation?'),
        content: Text(
          'Mark "$name" as not an animation? It moves to the Images tab; '
          'you can restore it there.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-not-animation'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Mark as image'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _runSave(widget.onNotAnimation);
  }

  /// Runs [save] with the buttons locked; ignores a second click meanwhile.
  Future<void> _runSave(Future<void> Function() save) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await save();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void didUpdateWidget(AnimationEditor old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) _reset(widget.current);
  }

  void _reset(SpriteAnim a) {
    setState(() {
      _anim = a;
      _w.text = '${a.frameW}';
      _h.text = '${a.frameH}';
      _n.text = '${a.frameCount}';
      _framesError = null;
    });
  }

  void _applySize() {
    final w = int.tryParse(_w.text);
    final h = int.tryParse(_h.text);
    if (w == null || h == null || w < 1 || h < 1) return;
    // Re-slice from the detected sheet so repeated edits don't drift.
    setState(() {
      _anim = widget.detected.copyWith(
        frameW: w,
        frameH: h,
        fps: _anim.fps,
        playRow: _anim.playRow,
        zoom: _anim.zoom,
      );
      _n.text = '${_anim.frameCount}';
      _framesError = null;
    });
  }

  /// Re-slices the sheet into the typed total frame count on the best grid
  /// that fits; frame width and height follow. A count with no fitting grid
  /// keeps the old slicing.
  void _applyFrames() {
    if (_n.text.trim().isEmpty) return;
    final n = int.tryParse(_n.text.trim());
    final next = n == null ? null : _anim.withFrameCount(n);
    setState(() {
      if (next == null) {
        _framesError =
            'Doesn\'t fit ${_anim.frameW * _anim.cols}'
            '×${_anim.frameH * _anim.rows} px';
        return;
      }
      _framesError = null;
      _anim = next;
      _w.text = '${next.frameW}';
      _h.text = '${next.frameH}';
    });
  }

  /// −/+, Up/Down and the wheel: the next count with a fitting grid.
  void _stepFrames(int step) {
    final from = int.tryParse(_n.text.trim()) ?? _anim.frameCount;
    final next = _anim.nextFrameCount(from, step);
    if (next == null) return;
    _n.text = '$next';
    _applyFrames();
  }

  @override
  void dispose() {
    _w.dispose();
    _h.dispose();
    _n.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = _anim;
    final shownPath = widget.newPath ?? a.path;
    final isSheet = a.kind == AnimKind.sheet;
    final dirty = widget.isNew || a != widget.current;
    final overridden = widget.manual || widget.current != widget.detected;
    // The preview box is as tall as the controls (at least 240 px); the
    // whole editor scrolls when the window is too short. Close and Esc
    // (both `maybePop`) wait while a save runs.
    return PopScope(
      canPop: !_saving,
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  width: 240,
                  constraints: const BoxConstraints(minHeight: 240),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: a.kind == AnimKind.gif
                      ? PixelImage(
                          File(p.join(widget.packPath, a.path)),
                          animate: true,
                        )
                      // Wheel / −, +, reset over the preview set the zoom.
                      : ZoomPreview(
                          anim: a,
                          onZoom: (z) =>
                              setState(() => _anim = _anim.copyWith(zoom: z)),
                          child: AnimatedSprite(
                            packPath: widget.packPath,
                            anim: a,
                            bytes: widget.bytes,
                          ),
                        ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: SelectableText(
                              prettyName(
                                p.posix.basenameWithoutExtension(shownPath),
                                isFile: false,
                              ),
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          // Opens on top of this dialog; Esc closes it first.
                          // Nothing to open before an unsaved strip exists.
                          if (widget.bytes == null) ...[
                            OpenImageButton(
                              onPressed: () => showImageViewer(
                                context,
                                packPath: widget.packPath,
                                images: [a.path],
                                index: 0,
                              ),
                            ),
                            RevealButton(p.join(widget.packPath, a.path)),
                          ],
                        ],
                      ),
                      Row(
                        children: [
                          Flexible(
                            child: SelectableText(
                              shownPath,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          if (widget.bytes == null) ...[
                            _CopyButton(
                              tooltip: 'Copy relative path',
                              text: a.path,
                              icon: Icons.content_copy,
                            ),
                            _CopyButton(
                              tooltip: 'Copy full path',
                              text: p.join(widget.packPath, a.path),
                              icon: Icons.copy_all,
                            ),
                          ] else
                            Text(
                              '  (not saved yet)',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(switch (a.kind) {
                        AnimKind.sheet =>
                          'Sheet · ${a.frameW}×${a.frameH} frames · '
                              '${a.cols} × ${a.rows} · ${a.frameCount} frames',
                        AnimKind.gif => 'Animated GIF',
                      }),
                      if (a.kind != AnimKind.gif)
                        Row(
                          children: [
                            const Text('FPS'),
                            Flexible(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 240,
                                ),
                                child: Slider(
                                  min: 1,
                                  max: 30,
                                  divisions: 29,
                                  value: a.fps.clamp(1, 30),
                                  label: a.fps.round().toString(),
                                  onChanged: (v) => setState(
                                    () => _anim = a.copyWith(
                                      fps: v.roundToDouble(),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Text('${a.fps.round()}'),
                          ],
                        ),
                      if (isSheet)
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _NumberField(
                              label: 'Frame width',
                              controller: _w,
                              onSubmit: _applySize,
                            ),
                            _NumberField(
                              label: 'Frame height',
                              controller: _h,
                              onSubmit: _applySize,
                            ),
                            _FramesField(
                              controller: _n,
                              onSubmit: _applyFrames,
                              onChanged: _applyFrames,
                              onStep: _stepFrames,
                              errorText: _framesError,
                            ),
                            OutlinedButton(
                              onPressed: _applySize,
                              child: const Text('Apply size'),
                            ),
                            if (a.rows > 1)
                              DropdownButton<int?>(
                                mouseCursor: clickCursor,
                                dropdownMenuItemMouseCursor: clickCursor,
                                value: a.rowToPlay,
                                items: [
                                  const DropdownMenuItem(
                                    value: null,
                                    child: Text('All rows'),
                                  ),
                                  for (var r = 0; r < a.rows; r++)
                                    DropdownMenuItem(
                                      value: r,
                                      child: Text('Row ${r + 1}'),
                                    ),
                                ],
                                // Saved with the animation; cards play it.
                                onChanged: (r) => setState(
                                  () => _anim = a.copyWith(
                                    playRow: r ?? SpriteAnim.allRows,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      const Spacer(),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton(
                            onPressed: dirty && !_saving && !widget.saveBlocked
                                ? () => _runSave(() => widget.onSave(a))
                                : null,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_saving) ...[
                                  const SizedBox.square(
                                    key: ValueKey('save-spinner'),
                                    dimension: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                ],
                                const Text('Save'),
                              ],
                            ),
                          ),
                          if (overridden)
                            TextButton(
                              onPressed: _saving
                                  ? null
                                  : () => _runSave(() => widget.onSave(null)),
                              child: Text(
                                widget.manual
                                    ? 'Back to image'
                                    : 'Reset to detected',
                              ),
                            )
                          else if (dirty)
                            TextButton(
                              onPressed: _saving
                                  ? null
                                  : () => _reset(widget.current),
                              child: const Text('Undo'),
                            ),
                          if (!widget.isNew)
                            TextButton.icon(
                              onPressed: _saving ? null : _confirmNotAnimation,
                              icon: const Icon(Icons.image_outlined, size: 18),
                              label: const Text('Not an animation'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The Edit dialog's preview: the mouse wheel zooms in whole steps
/// (1×–8×), and on hover a small overlay shows −, the value, + and reset
/// (Auto, the fit). The wheel is claimed, so nothing under the dialog scrolls
/// or zooms.
class ZoomPreview extends StatefulWidget {
  const ZoomPreview({
    super.key,
    required this.anim,
    required this.onZoom,
    required this.child,
  });

  final SpriteAnim anim;

  /// The new [SpriteAnim.zoom]; null is Auto.
  final ValueChanged<int?> onZoom;
  final Widget child;

  @override
  State<ZoomPreview> createState() => _ZoomPreviewState();
}

class _ZoomPreviewState extends State<ZoomPreview> {
  var _hover = false;

  /// What Auto draws at in this box; the first step starts from it. Read
  /// from the laid-out size (no LayoutBuilder: the editor sizes itself with
  /// IntrinsicHeight).
  int _fit() {
    final a = widget.anim;
    final box = context.size ?? const Size(224, 224);
    return integerScale(math.min(box.width / a.frameW, box.height / a.frameH))
        .floor()
        .clamp(SpriteAnim.zoomSteps.first, SpriteAnim.zoomSteps.last);
  }

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) {
      final a = widget.anim;
      final steps = SpriteAnim.zoomSteps;
      void step(int by) {
        final next = ((a.zoom ?? _fit()) + by).clamp(steps.first, steps.last);
        if (next != a.zoom) widget.onZoom(next);
      }

      final zoom = a.zoom;
      final theme = Theme.of(context);
      return MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          // The whole box, transparent pixels and padding included.
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (e) {
            if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
              GestureBinding.instance.pointerSignalResolver.register(
                e,
                (_) => step(e.scrollDelta.dy < 0 ? 1 : -1),
              );
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (_hover)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Material(
                    key: const ValueKey('zoom-overlay'),
                    color: theme.colorScheme.surface.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: const ValueKey('zoom-out'),
                          tooltip: 'Zoom out',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          onPressed: zoom == null || zoom > steps.first
                              ? () => step(-1)
                              : null,
                          icon: const Icon(Icons.remove),
                        ),
                        Text(
                          a.zoom == null ? 'Auto' : '${a.zoom}×',
                          key: const ValueKey('zoom-value'),
                          style: theme.textTheme.labelMedium,
                        ),
                        IconButton(
                          key: const ValueKey('zoom-in'),
                          tooltip: 'Zoom in',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          onPressed: zoom == null || zoom < steps.last
                              ? () => step(1)
                              : null,
                          icon: const Icon(Icons.add),
                        ),
                        IconButton(
                          key: const ValueKey('zoom-reset'),
                          tooltip: 'Reset zoom (Auto)',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          onPressed: a.zoom == null
                              ? null
                              : () => widget.onZoom(null),
                          icon: const Icon(Icons.fit_screen_outlined),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// Copies [text] to the clipboard and says so in a snack bar.
class _CopyButton extends StatelessWidget {
  const _CopyButton({
    required this.tooltip,
    required this.text,
    required this.icon,
  });

  final String tooltip;
  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    iconSize: 16,
    visualDensity: VisualDensity.compact,
    icon: Icon(icon),
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: text));
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Copied $text'),
          duration: const Duration(seconds: 2),
        ),
      );
    },
  );
}

/// The Frames field: −/+ buttons, Up/Down and the mouse wheel step to the
/// next count that has a fitting grid ([onStep] with +1 / −1).
class _FramesField extends StatelessWidget {
  const _FramesField({
    required this.controller,
    required this.onSubmit,
    required this.onChanged,
    required this.onStep,
    this.errorText,
  });

  final TextEditingController controller;
  final VoidCallback onSubmit;
  final VoidCallback onChanged;
  final ValueChanged<int> onStep;
  final String? errorText;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      IconButton(
        tooltip: 'Fewer frames',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.remove),
        onPressed: () => onStep(-1),
      ),
      Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
            GestureBinding.instance.pointerSignalResolver.register(
              e,
              (_) => onStep(e.scrollDelta.dy < 0 ? 1 : -1),
            );
          }
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: (node, event) {
            if (event is KeyUpEvent) return KeyEventResult.ignored;
            if (AppKeys.framesUp.accepts(event)) {
              onStep(1);
              return KeyEventResult.handled;
            }
            if (AppKeys.framesDown.accepts(event)) {
              onStep(-1);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: _NumberField(
            label: 'Frames',
            controller: controller,
            onSubmit: onSubmit,
            onChanged: onChanged,
            errorText: errorText,
          ),
        ),
      ),
      IconButton(
        tooltip: 'More frames',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add),
        onPressed: () => onStep(1),
      ),
    ],
  );
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.label,
    required this.controller,
    required this.onSubmit,
    this.onChanged,
    this.errorText,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onSubmit;

  /// Applies while typing (the Frames field updates the width live).
  final VoidCallback? onChanged;
  final String? errorText;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 110,
    child: TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        errorText: errorText,
        errorMaxLines: 2,
      ),
      onSubmitted: (_) => onSubmit(),
      onChanged: onChanged == null ? null : (_) => onChanged!(),
    ),
  );
}

/// Audio files with one shared player; only one sound plays at a time.
class _AudioTab extends ConsumerStatefulWidget {
  const _AudioTab({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  ConsumerState<_AudioTab> createState() => _AudioTabState();
}

/// Tracks at least this long get a seek bar with the elapsed time while
/// playing; shorter sounds show only their length.
const seekBarMinLength = Duration(seconds: 10);

/// Play all: the pause between two tracks, so short sounds are told apart.
const playAllGap = Duration(milliseconds: 300);

class _AudioTabState extends ConsumerState<_AudioTab> {
  // Created on first play so tests and silent browsing never touch audio.
  TrackPlayer? _player;
  final _subs = <StreamSubscription<Object?>>[];
  String? _playing;

  /// The last row played or clicked; Space toggles it.
  String? _selected;
  Duration _position = Duration.zero;
  Duration? _length;
  final _keys = FocusNode(debugLabel: 'audio');

  /// Header lengths by relative path, requested as rows are built, and
  /// those already read.
  final _lengths = <String, Future<Duration?>>{};
  final _known = <String, Duration>{};

  /// Header details by file, read when a row or card first shows it.
  final _infos = <String, Future<AudioInfo?>>{};
  final _chipTips = <String, Future<String?>>{};

  /// Play all is running: each finished track starts the next one in the
  /// shown order (search and folder filter applied), after [playAllGap].
  /// With Loop on, the list starts over at the end; the player itself then
  /// never loops (so its per-pass completions can't skip tracks).
  var _all = false;
  Timer? _gap;
  final _scroll = ScrollController();

  /// Rows / cards by path, to scroll the playing one into view.
  final _itemKeys = <String, GlobalKey>{};
  GlobalKey _keyFor(String rel) => _itemKeys.putIfAbsent(rel, GlobalKey.new);

  /// The format picked on a card, by track key; else the preferred one.
  final _chosen = <String, String>{};
  List<String>? _groupedFrom;
  var _grouped = const <AudioTrack>[];

  /// The sounds, one per track, whatever formats they come in, in the
  /// pack's order.
  List<AudioTrack> get _byName {
    final audio = widget.contents.audio;
    if (!identical(audio, _groupedFrom)) {
      _groupedFrom = audio;
      _grouped = groupAudioFormats(audio);
    }
    return _grouped;
  }

  /// Headers read so far, by file (null: nothing to read in it).
  final _infoKnown = <String, AudioInfo?>{};

  /// Reading the headers a sort needs; the list shows a progress bar.
  var _loadingInfos = false;

  /// Bumped when a picked format or a read header changes the order.
  var _orderVersion = 0;
  Object? _sortedFor;
  var _sorted = const <AudioTrack>[];

  /// The shown sounds in the shown order (the tab's sort, each track by
  /// the format it shows); Play all and ←/→ go by it.
  List<AudioTrack> get _tracks {
    final settings = ref.read(settingsProvider);
    final grouped = _byName;
    final signature = (
      grouped,
      settings.audioSort,
      settings.audioSortDesc,
      settings.audioFormat,
      _orderVersion,
    );
    if (signature != _sortedFor) {
      _sortedFor = signature;
      _sorted = sortAudioTracks(
        grouped,
        settings.audioSort,
        descending: settings.audioSortDesc,
        fileOf: _fileOf,
        sizeOf: (rel) => widget.contents.sizes[rel],
        infoOf: (rel) => _infoKnown[rel],
      );
    }
    return _sorted;
  }

  /// A sort by a header value: reads the shown files' headers that are
  /// not read yet (all at once, off the UI thread), then sorts.
  void _readForSort(AudioSort key) {
    if (!key.needsInfo || _loadingInfos) return;
    final missing = [
      for (final t in _byName)
        if (!_infoKnown.containsKey(_fileOf(t))) _fileOf(t),
    ];
    if (missing.isEmpty) return;
    _loadingInfos = true;
    Future.wait(missing.map(_info)).whenComplete(() {
      if (!mounted) return;
      setState(() {
        _loadingInfos = false;
        _orderVersion++;
      });
      // A format picked meanwhile may still be missing.
      _readForSort(ref.read(settingsProvider).audioSort);
    });
  }

  /// Picks [key] (the dropdown or a header); [flip] turns the direction
  /// when it is already the sort.
  void _sortBy(AudioSort key, {bool flip = false}) {
    final settings = ref.read(settingsProvider);
    final same = settings.audioSort == key;
    ref
        .read(settingsProvider.notifier)
        .setAudioSort(
          key,
          descending: flip && same ? !settings.audioSortDesc : null,
        );
    _readForSort(key);
  }

  /// The file [t] plays: the format picked on it, else the preferred one.
  String _fileOf(AudioTrack t) {
    final chosen = _chosen[t.key];
    if (chosen != null && t.files.contains(chosen)) return chosen;
    return t.pick(ref.read(settingsProvider).audioFormat);
  }

  /// The shown track [rel] (in any format) belongs to; -1 if none.
  int _trackIndex(String? rel) =>
      rel == null ? -1 : _tracks.indexWhere((t) => t.files.contains(rel));

  /// A format chip: picks [rel] for [t]; a playing track carries on in
  /// the new format from where it was.
  Future<void> _switchFormat(AudioTrack t, String rel) async {
    final was = _playing;
    final at = _position;
    setState(() {
      _chosen[t.key] = rel;
      if (t.files.contains(_selected)) _selected = rel;
      _orderVersion++;
    });
    _readForSort(ref.read(settingsProvider).audioSort);
    if (was == rel || was == null || !t.files.contains(was)) return;
    await _start(rel);
    if (mounted && _playing == rel && at > Duration.zero) await _seek(at);
  }

  TrackPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = ref.read(trackPlayerFactoryProvider)();
    _subs
      ..add(
        player.onComplete.listen((_) {
          if (_all) {
            if (mounted) _next();
            return;
          }
          // Looping players report each pass as complete; they keep playing.
          if (_player?.looping ?? false) return;
          _release();
          if (mounted) setState(() => _playing = null);
        }),
      )
      ..add(
        player.onPosition.listen((d) {
          if (mounted && _playing != null) setState(() => _position = d);
        }),
      )
      ..add(
        player.onDuration.listen((d) {
          if (mounted && _playing != null && d > Duration.zero) {
            setState(() => _length = d);
          }
        }),
      );
    return _player = player;
  }

  /// A click on a row / card: stops it when it's playing (ending Play
  /// all), otherwise plays it; a running Play all continues from there.
  Future<void> _toggle(String rel) async {
    _keys.requestFocus();
    _selected = rel;
    if (_playing == rel) {
      _all = false;
      _gap?.cancel();
      _release();
      await _ensurePlayer().stop();
      if (mounted) setState(() => _playing = null);
      return;
    }
    await _start(rel);
  }

  Future<void> _start(String rel) async {
    final player = _ensurePlayer();
    _gap?.cancel();
    setState(() {
      _playing = rel;
      _selected = rel;
      _position = Duration.zero;
      _length = null;
    });
    if (_all) _reveal(rel);
    // One sound in the app: one playing elsewhere stops.
    ref.read(nowPlayingProvider).claim(this, _stopHere);
    try {
      await player.stop();
      await player.setLoop(!_all && ref.read(settingsProvider).audioLoop);
      await player.play(p.join(widget.pack.path, rel));
    } on Object catch (e) {
      _release();
      if (!mounted) return;
      setState(() {
        _playing = null;
        _all = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not play $rel: $e')));
    }
  }

  /// "Play all" / "Stop" (Shift+Space): starts from the selected or last
  /// played sound when it is shown, else from the first.
  Future<void> _playAll() async {
    if (_all) return _stopAll();
    final tracks = _tracks;
    if (tracks.isEmpty) return;
    final at = [
      _trackIndex(_selected),
      _trackIndex(_playing),
    ].firstWhere((i) => i >= 0, orElse: () => 0);
    _keys.requestFocus();
    _all = true;
    await _start(_fileOf(tracks[at]));
  }

  Future<void> _stopAll() async {
    _all = false;
    _gap?.cancel();
    _release();
    if (mounted) setState(() => _playing = null);
    await _player?.stop();
  }

  /// Play all: the track after the one that just ended, after a short gap;
  /// past the end, the first again with Loop on, else the run ends.
  void _next() {
    final tracks = _tracks;
    var next = _trackIndex(_playing) + 1;
    if (next >= tracks.length) {
      if (tracks.isEmpty || !ref.read(settingsProvider).audioLoop) {
        _all = false;
        _release();
        setState(() => _playing = null);
        return;
      }
      next = 0;
    }
    final rel = _fileOf(tracks[next]);
    setState(() {
      _playing = null;
      _selected = rel;
    });
    _gap?.cancel();
    _gap = Timer(playAllGap, () {
      if (mounted && _all) _start(rel);
    });
  }

  /// Scrolls [rel]'s row or card into view (estimating first when it
  /// isn't built yet).
  void _reveal(String rel) {
    void show() {
      final context = _itemKeys[rel]?.currentContext;
      if (context == null || !context.mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_itemKeys[rel]?.currentContext != null) return show();
      if (!_scroll.hasClients) return;
      final i = _trackIndex(rel);
      if (i < 0) return;
      final pos = _scroll.position;
      final estimate =
          (pos.maxScrollExtent + pos.viewportDimension) * i / _tracks.length -
          pos.viewportDimension / 2;
      _scroll.jumpTo(estimate.clamp(0.0, pos.maxScrollExtent));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) show();
      });
    });
  }

  Future<void> _seek(Duration to) async {
    final length = _length;
    final clamped = to < Duration.zero
        ? Duration.zero
        : length != null && to > length
        ? length
        : to;
    setState(() => _position = clamped);
    await _player?.seek(clamped);
  }

  /// Space plays / stops the selected row; ←/→ seek 5 s while playing.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (AppKeys.playAll.pressed(event)) {
      _playAll();
      return KeyEventResult.handled;
    }
    // Space ends a running Play all.
    if (_all && AppKeys.playStop.pressed(event)) {
      _stopAll();
      return KeyEventResult.handled;
    }
    if (AppKeys.playStop.pressed(event)) {
      final rel = _selected ?? _playing;
      if (rel == null) return KeyEventResult.ignored;
      _toggle(rel);
      return KeyEventResult.handled;
    }
    if (_playing == null) return KeyEventResult.ignored;
    const step = Duration(seconds: 5);
    if (AppKeys.seekForward.accepts(event)) {
      _seek(_position + step);
      return KeyEventResult.handled;
    }
    if (AppKeys.seekBack.accepts(event)) {
      _seek(_position - step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// This tab no longer plays the app's sound.
  void _release() => _nowPlaying.release(this);

  /// Read in [initState]: [dispose] can't read providers.
  late final NowPlaying _nowPlaying;

  @override
  void initState() {
    super.initState();
    _nowPlaying = ref.read(nowPlayingProvider);
  }

  /// Another sound started, or the tab was left: stops this tab's sound
  /// (and Play all). Coming back does not resume it.
  void _stopHere() {
    _all = false;
    _gap?.cancel();
    _release();
    _player?.stop();
    if (mounted && _playing != null) setState(() => _playing = null);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Another pack tab or the dashboard is shown: this tab's sound stops.
    if (!TabActive.of(context) && _nowPlaying.owns(this)) {
      // Not during the build that hid it.
      WidgetsBinding.instance.addPostFrameCallback((_) => _stopHere());
    }
  }

  /// Turning loop off lets the current sound finish its pass. During
  /// Play all, Loop repeats the list, not the sound.
  void _setLoop(bool on) {
    ref.read(settingsProvider.notifier).setAudioLoop(on);
    if (!_all) _player?.setLoop(on);
  }

  @override
  void dispose() {
    _release();
    _gap?.cancel();
    _scroll.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    _keys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt when they change: cards without a picked format follow the
    // format; the order follows the sort.
    ref.watch(settingsProvider.select((s) => s.audioFormat));
    final sort = ref.watch(settingsProvider.select((s) => s.audioSort));
    final desc = ref.watch(settingsProvider.select((s) => s.audioSortDesc));
    // A saved sort, or a format changed elsewhere, may need headers.
    _readForSort(sort);
    final audio = _tracks;
    final theme = Theme.of(context);
    final loop = ref.watch(settingsProvider.select((s) => s.audioLoop));
    final read = ref.watch(audioDurationProvider);
    Future<Duration?> readLength(String rel) => _lengths.putIfAbsent(
      rel,
      () => read(p.join(widget.pack.path, rel)).then((d) {
        if (d != null) _known[rel] = d;
        return d;
      }),
    );
    final view = ref.watch(settingsProvider.select((s) => s.audioView));
    final favorites = ref.watch(
      favoritesProvider.select((f) => f.filesOf(widget.pack.id)),
    );
    return Focus(
      focusNode: _keys,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Like Images / Animations: view options left, controls right.
          TabToolbar(
            children: [
              _AudioViewToggle(
                view: view,
                onChanged: ref.read(settingsProvider.notifier).setAudioView,
              ),
              const SizedBox(width: 16),
              _AudioSortMenu(
                sort: sort,
                descending: desc,
                onSort: _sortBy,
                onFlip: () => _sortBy(sort, flip: true),
              ),
              const Spacer(),
              Tooltip(
                message: _all
                    ? 'Stop playing all (Shift+Space)'
                    : 'Play every sound shown, in order (Shift+Space)',
                child: FilledButton.tonalIcon(
                  key: const ValueKey('play-all'),
                  onPressed: audio.isEmpty ? null : _playAll,
                  icon: Icon(_all ? Icons.stop : Icons.playlist_play, size: 18),
                  label: Text(_all ? 'Stop' : 'Play all'),
                ),
              ),
              const SizedBox(width: 8),
              // The same button type as Play all, so both have one
              // shape; on = the filled primary colour.
              Tooltip(
                message: _all
                    ? 'Repeat the whole list'
                    : 'Repeat the playing sound',
                child: Semantics(
                  toggled: loop,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('loop'),
                    style: loop
                        ? FilledButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.onPrimary,
                          )
                        : null,
                    onPressed: () => _setLoop(!loop),
                    icon: const Icon(Icons.repeat, size: 18),
                    label: const Text('Loop'),
                  ),
                ),
              ),
            ],
          ),
          // Reading the headers a sort needs.
          if (_loadingInfos && sort.needsInfo)
            const LinearProgressIndicator(
              key: ValueKey('audio-sort-progress'),
              minHeight: 2,
            ),
          Expanded(
            child: switch (view) {
              AudioView.rows => _rows(audio, readLength, favorites),
              AudioView.cards => _cards(audio, readLength, favorites),
            },
          ),
        ],
      ),
    );
  }

  /// The file's [AudioInfo], read once (header only, off the UI thread).
  Future<AudioInfo?> _info(String rel) => _infos.putIfAbsent(
    rel,
    () =>
        ref.read(audioInfoProvider)(p.join(widget.pack.path, rel)).then((info) {
          _infoKnown[rel] = info;
          return info;
        }),
  );

  /// A format chip's tooltip: `WAV · 44.1 kHz · Stereo · 16-bit · 1.2 MB`.
  Future<String?> _chipDetails(String rel) => _chipTips.putIfAbsent(
    rel,
    () => _info(rel).then(
      (info) => [
        formatOf(rel).toUpperCase(),
        if (info != null && info.details.isNotEmpty) info.details,
        formatBytes(widget.contents.sizes[rel] ?? 0),
      ].join(' · '),
    ),
  );

  /// The playing track's length: the player's once it reports one, else
  /// the header's.
  Duration? _lengthOf(String rel) => _length ?? _known[rel];

  /// How far the playing track [rel] is (0..1), once its length is known.
  double? _progressOf(String rel) {
    final length = _lengthOf(rel);
    if (length == null || length <= Duration.zero) return null;
    return (_position.inMilliseconds / length.inMilliseconds).clamp(0.0, 1.0);
  }

  /// Long tracks get a seek bar while playing; short ones show only their
  /// length.
  bool _seekable(String rel) {
    final length = _lengthOf(rel);
    return length != null && length >= seekBarMinLength;
  }

  /// Width of [text] in [style] at the screen's text scale.
  double _textWidth(String text, TextStyle? style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w.ceilToDouble();
  }

  Widget _rows(
    List<AudioTrack> audio,
    Future<Duration?> Function(String) readLength,
    Set<String> favorites,
  ) {
    final theme = Theme.of(context);
    // Fixed columns, so formats, length and size line up down the list:
    // one slot per format used in the tab (in [audioFormatOrder], each as
    // wide as its chip), the size as wide as the widest size there can be
    // (right-aligned).
    final chip = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    final used = {
      for (final track in audio)
        for (final f in track.files) formatOf(f),
    };
    int rank(String f) {
      final i = audioFormatOrder.indexOf(f);
      return i < 0 ? audioFormatOrder.length : i;
    }

    final slots = {
      for (final f
          in used.toList()..sort((a, b) {
            final r = rank(a).compareTo(rank(b));
            return r != 0 ? r : a.compareTo(b);
          }))
        // Text, the chip's padding and the gap after it ([FormatChips]).
        f: _textWidth(f.toUpperCase(), chip) + 10 + 4,
    };
    // Slots only when the tracks differ: the same formats everywhere are
    // packed as they always were.
    final mixed = audio.any((t) => t.files.length != used.length);
    var chipsWidth = mixed ? slots.values.fold(0.0, (a, b) => a + b) : 0.0;
    for (final track in audio.take(mixed ? 0 : audio.length)) {
      var w = 0.0;
      for (final f in track.files) {
        w += _textWidth(formatOf(f).toUpperCase(), chip) + 10 + 4;
      }
      chipsWidth = math.max(chipsWidth, w);
    }
    // The size keeps the row's trailing text style (as the length does);
    // only the figures are made tabular.
    const sizeStyle = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
    // A ListTile's trailing text style (Material 3: labelSmall).
    final trailing = theme.textTheme.labelSmall?.merge(sizeStyle);
    // [formatBytes] gives `999 B`, `9.9 KB` or `999 MB`.
    final sizeWidth = [
      for (final u in ['B', 'KB', 'MB', 'GB']) ...['999 $u', '9.9 $u'],
    ].map((t) => _textWidth(t, trailing)).reduce(math.max);
    // Details: as wide as the usual longest lines; less (cut with an
    // ellipsis) when the window leaves the title too little room.
    final detailsIdeal = [
      '44.1 kHz · Stereo · 24-bit',
      '44.1 kHz · Stereo · ~320 kbps',
      '48 kHz · Stereo · VBR ~128 kbps',
    ].map((t) => _textWidth(t, trailing)).reduce(math.max);
    return LayoutBuilder(
      builder: (context, box) {
        // Leading button and paddings (~72), a title of at least 160, and
        // every other trailing column.
        final others =
            chipsWidth + 12 + 80 + 12 + 56 + 16 + sizeWidth + 40 + 40 + 12;
        final room = box.maxWidth - 72 - 160 - others;
        final detailsWidth = room < 48 ? 0.0 : math.min(detailsIdeal, room);
        return _rowList(
          audio,
          readLength,
          favorites,
          chipsWidth: chipsWidth,
          slots: mixed ? slots : null,
          sizeWidth: sizeWidth,
          sizeStyle: sizeStyle,
          detailsWidth: detailsWidth,
        );
      },
    );
  }

  Widget _rowList(
    List<AudioTrack> audio,
    Future<Duration?> Function(String) readLength,
    Set<String> favorites, {
    required double chipsWidth,
    required Map<String, double>? slots,
    required double sizeWidth,
    required TextStyle sizeStyle,
    required double detailsWidth,
  }) {
    final list = ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: audio.length,
      itemBuilder: (context, i) {
        final track = audio[i];
        final rel = _fileOf(track);
        final path = p.join(widget.pack.path, rel);
        final playing = _playing == rel;
        final tile = ListTile(
          dense: true,
          selected: _selected == rel,
          leading: IconButton(
            tooltip: playing ? 'Stop' : 'Play',
            icon: Icon(playing ? Icons.stop_circle : Icons.play_circle),
            onPressed: () => _toggle(rel),
          ),
          // The path in the pack, not a folder line under the name.
          title: Tooltip(
            message: rel,
            child: Text(
              p.basenameWithoutExtension(rel),
              key: ValueKey('name:$rel'),
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                key: ValueKey('formats-column:$rel'),
                width: chipsWidth,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FormatChips(
                    files: track.files,
                    shown: rel,
                    onPick: (f) => _switchFormat(track, f),
                    slots: slots,
                    details: _chipDetails,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (detailsWidth > 0) ...[
                // The first format's details ([audioFormatOrder]).
                SizedBox(
                  key: ValueKey('details-column:$rel'),
                  width: detailsWidth,
                  child: _AudioDetails(
                    key: ValueKey('details:$rel'),
                    future: _info(track.files.first),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              // Built only for visible rows, so only they are decoded.
              Waveform(
                key: ValueKey('waveform:$rel'),
                path: path,
                progress: playing ? _progressOf(rel) : null,
                width: 80,
                height: 20,
              ),
              const SizedBox(width: 12),
              // Built only for visible rows, so only they are read.
              _TrackLength(
                key: ValueKey('length:$rel'),
                future: readLength(rel),
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: sizeWidth,
                child: Text(
                  formatBytes(widget.contents.sizes[rel] ?? 0),
                  key: ValueKey('size:$rel'),
                  textAlign: TextAlign.end,
                  style: sizeStyle,
                ),
              ),
              _trackStar(track, rel, favorites),
              RevealButton(path),
            ],
          ),
          onTap: () => _toggle(rel),
        );
        final menu = FileMenuArea(
          target: () => FileMenuTarget(files: [path], open: path),
          child: tile,
        );
        return KeyedSubtree(
          key: _keyFor(rel),
          child: !playing || !_seekable(rel)
              ? menu
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    menu,
                    _SeekBar(
                      position: _position,
                      length: _lengthOf(rel)!,
                      onSeek: _seek,
                    ),
                  ],
                ),
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: tabContentGap),
          child: _listHeader(
            chipsWidth: chipsWidth,
            sizeWidth: sizeWidth,
            detailsWidth: detailsWidth,
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  /// The list's column headers, laid out like a row (an invisible play
  /// button, star and reveal icon keep them over their columns). A click
  /// sorts by the column, a second click flips the direction.
  Widget _listHeader({
    required double chipsWidth,
    required double sizeWidth,
    required double detailsWidth,
  }) {
    // Watched in build; read here (a layout callback).
    final settings = ref.read(settingsProvider);
    final sort = settings.audioSort;
    final desc = settings.audioSortDesc;
    // Details sorts by the menu's detail key, else by sample rate.
    final detail = sort.isDetail ? sort : AudioSort.sampleRate;
    void pick(AudioSort key) => key == sort
        ? _sortBy(key, flip: true)
        : ref
              .read(settingsProvider.notifier)
              .setAudioSort(key, descending: false);
    Widget cell(
      String label,
      AudioSort key, {
      required bool sorted,
      bool end = false,
    }) => _SortHeader(
      key: ValueKey('audio-header:$label'),
      label: label,
      sorted: sorted,
      descending: desc,
      end: end,
      onTap: () {
        pick(key);
        _readForSort(key);
      },
    );
    Widget hidden(Widget child) => Visibility.maintain(
      visible: false,
      child: ExcludeSemantics(child: child),
    );
    return ListTile(
      key: const ValueKey('audio-list-header'),
      dense: true,
      minTileHeight: 28,
      visualDensity: const VisualDensity(vertical: -4),
      leading: hidden(
        const IconButton(icon: Icon(Icons.play_circle), onPressed: null),
      ),
      title: cell('Name', AudioSort.name, sorted: sort == AudioSort.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: chipsWidth),
          const SizedBox(width: 12),
          if (detailsWidth > 0) ...[
            SizedBox(
              width: detailsWidth,
              child: cell('Details', detail, sorted: sort.isDetail),
            ),
            const SizedBox(width: 12),
          ],
          // Over the waveform and the length, ending with the length.
          SizedBox(
            width: 80 + 12 + 56,
            child: cell(
              'Duration',
              AudioSort.duration,
              sorted: sort == AudioSort.duration,
              end: true,
            ),
          ),
          SizedBox(
            width: 16 + sizeWidth,
            child: cell(
              'Size',
              AudioSort.size,
              sorted: sort == AudioSort.size,
              end: true,
            ),
          ),
          hidden(FavoriteStar(starred: false, onPressed: () {})),
          hidden(RevealButton(widget.pack.path)),
        ],
      ),
    );
  }

  Widget _cards(
    List<AudioTrack> audio,
    Future<Duration?> Function(String) readLength,
    Set<String> favorites,
  ) => GridView.builder(
    key: const PageStorageKey('audio-cards'),
    controller: _scroll,
    padding: const EdgeInsets.fromLTRB(16, tabContentGap, 16, 16),
    gridDelegate: ThumbGridDelegate(
      maxTileWidth: 220,
      // Room for the button and the times; the footer holds the waveform
      // (the seek bar while a long track plays), the name and details.
      imageAspect: 1.6,
      footer: (_) => 60 + _AudioCard.waveformHeight + 6,
    ),
    itemCount: audio.length,
    itemBuilder: (context, i) {
      final track = audio[i];
      final rel = _fileOf(track);
      final playing = _playing == rel;
      final path = p.join(widget.pack.path, rel);
      return KeyedSubtree(
        key: _keyFor(rel),
        child: FileMenuArea(
          target: () => FileMenuTarget(files: [path], open: path),
          child: _AudioCard(
            key: ValueKey(track.key),
            rel: rel,
            formats: FormatChips(
              files: track.files,
              shown: rel,
              onPick: (f) => _switchFormat(track, f),
              vertical: true,
              details: _chipDetails,
            ),
            packPath: widget.pack.path,
            length: readLength(rel),
            size: widget.contents.sizes[rel] ?? 0,
            info: _info(rel),
            selected: _selected == rel,
            playing: playing,
            position: playing ? _position : null,
            playingLength: playing ? _lengthOf(rel) : null,
            onToggle: () => _toggle(rel),
            onSeek: _seek,
            star: _trackStar(track, rel, favorites),
            starred: track.files.any(favorites.contains),
          ),
        ),
      );
    },
  );

  /// Starred when any of its formats is; a click stars the shown file, or
  /// unstars every starred format.
  Widget _trackStar(AudioTrack track, String rel, Set<String> favorites) {
    final starred = [
      for (final f in track.files)
        if (favorites.contains(f)) f,
    ];
    return FavoriteStar(
      key: ValueKey('star:$rel'),
      starred: starred.isNotEmpty,
      onPressed: () {
        final favs = ref.read(favoritesProvider.notifier);
        for (final f in starred.isEmpty ? [rel] : starred) {
          favs.toggleFile(widget.pack.id, f);
        }
      },
    );
  }
}

/// Rows or Cards in the Audio tab.
class _AudioViewToggle extends StatelessWidget {
  const _AudioViewToggle({required this.view, required this.onChanged});

  final AudioView view;
  final ValueChanged<AudioView> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<AudioView>(
    showSelectedIcon: false,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    segments: const [
      ButtonSegment(
        value: AudioView.rows,
        icon: Icon(Icons.view_list_outlined, size: 18),
        label: Text('Rows'),
      ),
      ButtonSegment(
        value: AudioView.cards,
        icon: Icon(Icons.grid_view, size: 18),
        label: Text('Cards'),
      ),
    ],
    selected: {view},
    onSelectionChanged: (s) => onChanged(s.single),
  );
}

/// A clickable column header of the audio list; the sorted one shows an
/// arrow for the direction.
class _SortHeader extends StatelessWidget {
  const _SortHeader({
    super.key,
    required this.label,
    required this.sorted,
    required this.descending,
    required this.onTap,
    this.end = false,
  });

  final String label;
  final bool sorted;
  final bool descending;
  final VoidCallback onTap;

  /// Right-aligned (numbers), the arrow before the label.
  final bool end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = sorted
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    final text = Flexible(
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: sorted ? FontWeight.bold : null,
        ),
      ),
    );
    final arrow = sorted
        ? Icon(
            descending ? Icons.arrow_downward : Icons.arrow_upward,
            key: const ValueKey('sort-arrow'),
            size: 14,
            color: color,
          )
        : null;
    // The whole cell takes the click, not only the label.
    return InkWell(
      mouseCursor: clickCursor,
      borderRadius: BorderRadius.circular(4),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: end
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: [
            if (end && arrow != null) ...[arrow, const SizedBox(width: 2)],
            text,
            if (!end && arrow != null) ...[const SizedBox(width: 2), arrow],
          ],
        ),
      ),
    );
  }
}

/// Padding before the audio sort's direction arrow (from the stadium end).
const sortArrowPad = 11.0;

/// How far the arrow glyph sits inside its 18 px icon box.
const sortArrowGlyphInset = 3.0;

/// Padding after the arrow: plus the glyph's inset, the same visible gap
/// to the divider as the name has on the other side ([sortNamePadLeft]).
const sortArrowPadRight = sortNamePadLeft - sortArrowGlyphInset;

/// Padding before the audio sort's name (from the divider).
const sortNamePadLeft = 12.0;

/// Padding after the drop-down caret: plus the glyph's ~5 px inset, the
/// same visible gap as [sortNamePadLeft].
const sortNamePadRight = 7.0;

/// The Audio tab's sort, shaped like the Play all / Loop buttons (one
/// tonal stadium): the leading arrow flips the direction, the label (with
/// a small drop arrow) opens the menu of [AudioSort] keys. Two halves of
/// real [FilledButton]s, so the height, padding and colours follow the
/// theme exactly like Play all's.
class _AudioSortMenu extends StatelessWidget {
  const _AudioSortMenu({
    required this.sort,
    required this.descending,
    required this.onSort,
    required this.onFlip,
  });

  final AudioSort sort;
  final bool descending;
  final ValueChanged<AudioSort> onSort;
  final VoidCallback onFlip;

  /// A [FilledButton.tonal] side: rounded on [start] or the other end
  /// (the radius is cut to half the height, a stadium end).
  static ButtonStyle _half({required bool start, required EdgeInsets pad}) {
    const round = Radius.circular(999);
    return FilledButton.styleFrom(
      minimumSize: const Size(0, 40),
      padding: pad,
      shape: RoundedRectangleBorder(
        borderRadius: start
            ? const BorderRadius.horizontal(left: round)
            : const BorderRadius.horizontal(right: round),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('audio-sort-button'),
    mainAxisSize: MainAxisSize.min,
    children: [
      // The arrow's glyph as far from the divider as the name is on the
      // other side of it.
      Tooltip(
        message: descending ? 'Descending' : 'Ascending',
        child: FilledButton.tonal(
          key: const ValueKey('audio-sort-direction'),
          style: _half(
            start: true,
            pad: const EdgeInsets.only(
              left: sortArrowPad,
              right: sortArrowPadRight,
            ),
          ),
          onPressed: onFlip,
          child: Icon(
            descending ? Icons.arrow_downward : Icons.arrow_upward,
            size: 18,
          ),
        ),
      ),
      MenuAnchor(
        menuChildren: [
          for (final s in AudioSort.values)
            MenuItemButton(
              key: ValueKey('audio-sort:${s.name}'),
              style: MenuItemButton.styleFrom(
                enabledMouseCursor: clickCursor,
                backgroundColor: s == sort
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : null,
              ),
              onPressed: () => onSort(s),
              child: Text(s.label),
            ),
        ],
        builder: (context, controller, _) => Tooltip(
          message: 'Sort by',
          child: FilledButton.tonal(
            key: const ValueKey('audio-sort'),
            style: _half(
              start: false,
              // The same visible space before the name as after the
              // drop-down glyph, which sits ~5 px inside its 20 px box.
              pad: const EdgeInsets.only(
                left: sortNamePadLeft,
                right: sortNamePadRight,
              ),
            ),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(sort.label, key: const ValueKey('audio-sort-label')),
                const SizedBox(width: 2),
                const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        ),
      ),
    ],
  );
}

/// One sound as a grid card: a big play / stop button with a progress
/// ring while playing, the length above the waveform's right end (the
/// elapsed time above its left end while a long track plays), the waveform
/// (the played part highlighted; the seek bar while a long track plays),
/// the prettified name (its path in the pack as the tooltip) and a details
/// line: channels (S / M), size, sample rate, bit depth or bitrate.
class _AudioCard extends StatefulWidget {
  const _AudioCard({
    super.key,
    required this.rel,
    required this.formats,
    required this.packPath,
    required this.length,
    required this.size,
    required this.info,
    required this.selected,
    required this.playing,
    required this.position,
    required this.playingLength,
    required this.onToggle,
    required this.onSeek,
    this.star,
    this.starred = false,
  });

  /// The shown file, relative to the pack: the name's tooltip.
  final String rel;

  /// The star shows without hover (the reveal icon still hides).
  final bool starred;

  /// The format chips, stacked on the left edge.
  final Widget formats;
  final String packPath;

  /// The shown file's size in bytes and header details.
  final int size;
  final Future<AudioInfo?> info;

  /// The waveform strip between the button and the name.
  static const waveformHeight = 32.0;

  /// The play button with its progress ring.
  static const buttonSize = 56.0;

  /// The times' gap to the waveform below them.
  static const timeBottom = 2.0;

  /// The favorites star, in the top-right corner.
  final Widget? star;
  final Future<Duration?> length;
  final bool selected;
  final bool playing;

  /// While playing: where it is and how long it is (if known).
  final Duration? position;
  final Duration? playingLength;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeek;

  @override
  State<_AudioCard> createState() => _AudioCardState();
}

/// Where the button's centre goes, from the top of the area above the
/// waveform ([areaHeight] tall, [width] wide): halfway between the card's
/// top edge and the waveform. The times ([timeWidth] × [timeHeight],
/// [_AudioCard.timeBottom] above the waveform's ends) and the top row ([chips],
/// [icons]) only count where they are under the ring's column: the ring
/// moves down or up just enough to clear them. When nothing fits that
/// way, the M72 rule: halfway between the top row and the times band,
/// only the top-row parts above the ring counting, else just above the
/// times (it never covers them or the waveform).
@visibleForTesting
double audioButtonCentre({
  required double areaHeight,
  required double width,
  required double timeHeight,
  double timeWidth = 0,
  Rect? chips,
  Rect? icons,
}) {
  const d = _AudioCard.buttonSize;
  final bottom = areaHeight - _AudioCard.timeBottom - timeHeight;
  final row = [?chips, ?icons];
  double lowest(Iterable<Rect> rects) =>
      rects.fold(0.0, (a, r) => math.max(a, r.bottom));
  final left = width / 2 - d / 2;
  final right = width / 2 + d / 2;
  bool under(Rect r) => r.right > left && r.left < right;
  final above = lowest(row.where(under));
  // The times sit 10 px in from both edges.
  final times = [
    Rect.fromLTWH(10, bottom, timeWidth, timeHeight),
    Rect.fromLTWH(width - 10 - timeWidth, bottom, timeWidth, timeHeight),
  ];
  final floor = times.any(under) ? bottom : areaHeight;
  final lo = above + d / 2;
  final hi = floor - d / 2;
  if (lo <= hi) return (areaHeight / 2).clamp(lo, hi);
  final top = lowest(row);
  if (bottom - top >= d) return (top + bottom) / 2;
  if (bottom - above >= d) return (above + bottom) / 2;
  return math.max(d / 2, bottom - d / 2);
}

/// The parts of an audio card above its waveform.
enum _CardPart { chips, icons, elapsed, total, button }

/// Lays out [_CardPart]s with their real sizes: chips top-left, icons
/// top-right, the times above the waveform's ends and the button where
/// [audioButtonCentre] puts it.
class _AudioCardLayout extends MultiChildLayoutDelegate {
  _AudioCardLayout({required this.timeHeight, required this.timeWidth});

  /// The times' line height, kept free even before the length is read.
  final double timeHeight;

  /// A time's width (`00:00`), kept free at both ends the same way.
  final double timeWidth;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    Rect? place(_CardPart part, Offset Function(Size) at) {
      if (!hasChild(part)) return null;
      final s = layoutChild(part, loose);
      final o = at(s);
      positionChild(part, o);
      return o & s;
    }

    final chips = place(_CardPart.chips, (_) => const Offset(8, 8));
    final icons = place(
      _CardPart.icons,
      (s) => Offset(size.width - s.width, 0),
    );
    double timeTop(Size s) => size.height - _AudioCard.timeBottom - s.height;
    place(_CardPart.elapsed, (s) => Offset(10, timeTop(s)));
    place(
      _CardPart.total,
      (s) => Offset(size.width - 10 - s.width, timeTop(s)),
    );
    final centre = audioButtonCentre(
      areaHeight: size.height,
      width: size.width,
      timeHeight: timeHeight,
      timeWidth: timeWidth,
      chips: chips,
      icons: icons,
    );
    place(
      _CardPart.button,
      (s) => Offset((size.width - s.width) / 2, centre - s.height / 2),
    );
  }

  @override
  bool shouldRelayout(_AudioCardLayout old) =>
      old.timeHeight != timeHeight || old.timeWidth != timeWidth;
}

class _AudioCardState extends State<_AudioCard> {
  /// Where a drag on the waveform is (0..1); position updates wait.
  double? _drag;

  /// The pointer is over the card: the star and reveal icons show.
  var _hover = false;

  /// Fades like [ItemCard]'s hover icons; not clickable while hidden.
  Widget _hoverIcon(Widget child, {required bool shown}) => IgnorePointer(
    ignoring: !shown,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: shown ? 1 : 0,
      child: child,
    ),
  );

  double _fractionAt(Offset local, double width) =>
      width <= 0 ? 0 : (local.dx / width).clamp(0.0, 1.0);

  void _seekTo(double fraction) {
    final total = widget.playingLength;
    if (total == null) return;
    widget.onSeek(
      Duration(milliseconds: (fraction * total.inMilliseconds).round()),
    );
  }

  @override
  void didUpdateWidget(_AudioCard old) {
    super.didUpdateWidget(old);
    if (!widget.playing) _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = widget.playingLength;
    final position = widget.position;
    final playing = widget.playing;
    final progress = playing && total != null && total > Duration.zero
        ? (position!.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : null;
    final long = playing && total != null && total >= seekBarMinLength;
    final shown = long ? (_drag ?? progress) : progress;
    final timeStyle = _audioCardTimeStyle(theme);
    // Kept free for the times, so the button never moves as they show.
    final timeBox = (TextPainter(
      text: TextSpan(text: '00:00', style: timeStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout());
    final timeHeight = timeBox.height;
    final timeWidth = timeBox.width;
    timeBox.dispose();
    final button = SizedBox.square(
      dimension: _AudioCard.buttonSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (progress != null)
            SizedBox.square(
              dimension: _AudioCard.buttonSize,
              child: CircularProgressIndicator(
                key: const ValueKey('progress'),
                value: progress,
                strokeWidth: 3,
              ),
            ),
          IconButton(
            key: const ValueKey('card-play'),
            tooltip: playing ? 'Stop' : 'Play',
            iconSize: 40,
            color: scheme.primary,
            icon: Icon(playing ? Icons.stop_circle : Icons.play_circle),
            onPressed: widget.onToggle,
          ),
        ],
      ),
    );
    final waveform = Waveform(
      key: ValueKey('waveform:${widget.rel}'),
      path: p.join(widget.packPath, widget.rel),
      progress: shown,
      height: _AudioCard.waveformHeight,
      playhead: long,
    );
    final area = CustomMultiChildLayout(
      delegate: _AudioCardLayout(timeHeight: timeHeight, timeWidth: timeWidth),
      children: [
        LayoutId(id: _CardPart.chips, child: widget.formats),
        LayoutId(
          id: _CardPart.icons,
          child: Row(
            key: const ValueKey('audio-card-icons'),
            mainAxisSize: MainAxisSize.min,
            children: [
              _hoverIcon(
                RevealButton(p.join(widget.packPath, widget.rel)),
                shown: _hover,
              ),
              if (widget.star case final star?)
                _hoverIcon(star, shown: _hover || widget.starred),
            ],
          ),
        ),
        if (long)
          LayoutId(
            id: _CardPart.elapsed,
            child: Text(
              formatDuration(
                Duration(
                  milliseconds: ((shown ?? 0) * total.inMilliseconds).round(),
                ),
              ),
              key: const ValueKey('elapsed'),
              style: timeStyle,
            ),
          ),
        LayoutId(
          id: _CardPart.total,
          child: FutureBuilder(
            future: widget.length,
            builder: (context, snap) {
              final d = total ?? snap.data;
              return Text(
                d == null ? '' : formatDuration(d),
                key: const ValueKey('total'),
                style: timeStyle,
              );
            },
          ),
        ),
        LayoutId(id: _CardPart.button, child: button),
      ],
    );
    final card = Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: widget.selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        mouseCursor: clickCursor,
        onTap: widget.onToggle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: area),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              // While a long track plays the strip seeks (a click or a
              // drag); otherwise a click plays or stops, like the card.
              child: !long
                  ? waveform
                  : LayoutBuilder(
                      builder: (context, strip) => MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          key: const ValueKey('waveform-seek'),
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (d) => _seekTo(
                            _fractionAt(d.localPosition, strip.maxWidth),
                          ),
                          onHorizontalDragStart: (d) => setState(
                            () => _drag = _fractionAt(
                              d.localPosition,
                              strip.maxWidth,
                            ),
                          ),
                          onHorizontalDragUpdate: (d) => setState(
                            () => _drag = _fractionAt(
                              d.localPosition,
                              strip.maxWidth,
                            ),
                          ),
                          onHorizontalDragEnd: (_) {
                            final to = _drag;
                            setState(() => _drag = null);
                            if (to != null) _seekTo(to);
                          },
                          onHorizontalDragCancel: () =>
                              setState(() => _drag = null),
                          child: waveform,
                        ),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Tooltip(
                    message: widget.rel,
                    child: Text(
                      prettyName(p.basename(widget.rel)),
                      key: ValueKey('name:${widget.rel}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FutureBuilder(
                    future: widget.info,
                    builder: (context, snap) => OverflowText(
                      audioCardDetails(widget.size, snap.data),
                      key: ValueKey('card-details:${widget.rel}'),
                      tooltip: audioCardDetails(
                        widget.size,
                        snap.data,
                        words: true,
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: card,
    );
  }
}

/// The audio card's times: a bit bigger than body text, tabular figures.
TextStyle _audioCardTimeStyle(ThemeData theme) {
  final body = theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
  return body.copyWith(
    fontSize: (body.fontSize ?? 14) + 1,
    fontFeatures: const [FontFeature.tabularFigures()],
    color: theme.colorScheme.onSurfaceVariant,
  );
}

/// An audio card's details line: `S · 1.2 MB · 44.1 kHz · 16-bit` (with
/// [words]: `Stereo · 1.2 MB · …`, the line's tooltip); only the size until
/// the header is read (or when it says nothing).
@visibleForTesting
String audioCardDetails(int bytes, AudioInfo? info, {bool words = false}) =>
    info?.shortDetails(size: formatBytes(bytes), words: words) ??
    formatBytes(bytes);

/// A file's audio details (`44.1 kHz · Stereo · 16-bit`) once its header
/// has been read; empty when it says nothing.
class _AudioDetails extends StatelessWidget {
  const _AudioDetails({super.key, required this.future});

  final Future<AudioInfo?> future;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (context, snap) {
      final text = snap.data?.details ?? '';
      final line = Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
      );
      // The whole line when the column cuts it.
      return text.isEmpty ? line : Tooltip(message: text, child: line);
    },
  );
}

/// `m:ss` once the header has been read; nothing for unknown formats.
class _TrackLength extends StatelessWidget {
  const _TrackLength({super.key, required this.future});

  final Future<Duration?> future;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (context, snap) {
      final d = snap.data;
      return SizedBox(
        width: 56,
        child: Text(
          d == null ? '' : formatDuration(d),
          textAlign: TextAlign.end,
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        ),
      );
    },
  );
}

/// Elapsed time, a slider that seeks on click or drag, and the total, in
/// one line under a list row, for tracks of [seekBarMinLength] or more.
/// (Cards seek on their waveform.)
class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.position,
    required this.length,
    required this.onSeek,
  });

  final Duration position;
  final Duration length;
  final ValueChanged<Duration> onSeek;

  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  /// Where the thumb is while dragging, in ms; position updates wait.
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final max = widget.length.inMilliseconds.toDouble();
    final value = (_drag ?? widget.position.inMilliseconds.toDouble()).clamp(
      0.0,
      max,
    );
    final elapsed = Text(
      formatDuration(Duration(milliseconds: value.round())),
      key: const ValueKey('elapsed'),
      style: style,
    );
    final total = Text(formatDuration(widget.length), style: style);
    final slider = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 2,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      ),
      child: Slider(
        key: const ValueKey('seek'),
        mouseCursor: clickCursor,
        max: max,
        value: value,
        onChanged: (v) => setState(() => _drag = v),
        onChangeEnd: (v) {
          setState(() => _drag = null);
          widget.onSeek(Duration(milliseconds: v.round()));
        },
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, 24, 6),
      child: Row(
        children: [
          elapsed,
          Expanded(child: slider),
          total,
        ],
      ),
    );
  }
}

class _FilesTab extends ConsumerWidget {
  const _FilesTab({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = contents.other;
    final favorites = ref.watch(
      favoritesProvider.select((f) => f.filesOf(pack.id)),
    );
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: files.length,
      itemBuilder: (context, i) {
        final rel = files[i];
        final previewable = isTextPreviewable(rel);
        final path = p.join(pack.path, rel);
        return FileMenuArea(
          target: () => FileMenuTarget(files: [path], open: path),
          child: ListTile(
            dense: true,
            leading: Icon(_iconFor(rel)),
            title: Text(rel),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatBytes(contents.sizes[rel] ?? 0)),
                fileStar(ref, pack.id, rel, starred: favorites.contains(rel)),
                RevealButton(p.join(pack.path, rel)),
              ],
            ),
            // Text files open in the preview; the rest only reveal.
            onTap: previewable
                ? () => showTextPreview(context, packPath: pack.path, rel: rel)
                : null,
          ),
        );
      },
    );
  }

  static IconData _iconFor(String rel) =>
      switch (p.extension(rel).toLowerCase()) {
        '.txt' || '.md' || '.pdf' => Icons.description_outlined,
        '.json' ||
        '.csv' ||
        '.ini' ||
        '.cfg' ||
        '.tsx' ||
        '.tmx' ||
        '.xml' => Icons.data_object,
        '.ttf' || '.otf' || '.woff' || '.woff2' => Icons.font_download_outlined,
        '.fbx' || '.obj' || '.glb' || '.gltf' || '.blend' => Icons.view_in_ar,
        '.zip' || '.rar' || '.7z' => Icons.archive_outlined,
        '.aseprite' || '.ase' || '.psd' || '.kra' => Icons.brush_outlined,
        _ => Icons.insert_drive_file_outlined,
      };
}

/// The star toggle of one file of [packId].
Widget fileStar(
  WidgetRef ref,
  String packId,
  String rel, {
  required bool starred,
}) => FavoriteStar(
  key: ValueKey('star:$rel'),
  starred: starred,
  onPressed: () => ref.read(favoritesProvider.notifier).toggleFile(packId, rel),
);

/// The pack's favorites star, beside the title in the header.
/// The header star's size; the author icon below takes the same width.
const _headerStarSize = 22.0;

/// Between the header's icons (star, author) and their text.
const _headerIconGap = 6.0;

class _PackStar extends ConsumerWidget {
  const _PackStar({required this.packId});

  final String packId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FavoriteStar(
    key: const ValueKey('header-star'),
    starred: ref.watch(favoritesProvider.select((f) => f.isPack(packId))),
    size: _headerStarSize,
    tight: true,
    onPressed: () => ref.read(favoritesProvider.notifier).togglePack(packId),
  );
}
