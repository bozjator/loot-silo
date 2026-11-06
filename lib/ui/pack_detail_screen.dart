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
import '../core/file_search.dart';
import '../core/credits.dart';
import '../core/library_index.dart';
import '../core/pack_editor.dart';
import '../core/sidecar.dart';
import '../core/text_preview.dart';
import '../core/type_classifier.dart' show AssetType;
import '../state/dashboard.dart'
    show DashboardQueryNotifier, dashboardQueryProvider, knownTags, sortedTags;
import '../state/providers.dart';
import '../state/settings.dart';
import 'format.dart';
import 'animation_grid.dart';
import 'folder_groups.dart';
import 'image_viewer.dart';
import 'reveal.dart';
import 'shortcuts.dart';
import 'tabs.dart';
import 'text_preview_dialog.dart';
import 'track_player.dart';
import 'widgets/animated_sprite.dart';
import 'widgets/meta_dialogs.dart';
import 'widgets/pack_tile.dart' show iconForTypes;
import 'widgets/pixel_image.dart';
import 'widgets/thumb_size.dart';
import 'cursors.dart';

/// Everything about one pack: previews, files, animations, metadata.
class PackDetailScreen extends ConsumerWidget {
  const PackDetailScreen({
    super.key,
    required this.packId,
    this.folder,
    this.search,
    this.file,
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
    final pinned = ref.watch(
      settingsProvider.select((s) => s.detailHeaderPinned),
    );
    void togglePin() =>
        ref.read(settingsProvider.notifier).setDetailHeaderPinned(!pinned);
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
            folder: folder,
            search: search,
            file: file,
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
    this.folder,
    this.search,
    this.file,
  });

  final PackRow pack;
  final PackContents contents;
  final String? folder;
  final SearchFilter? search;
  final String? file;

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
  Type? _tab;
  late String? _folder = widget.folder;

  /// The file-name search over every tab, seeded with the dashboard search
  /// the page was opened with. [_query] is what the tabs are filtered by;
  /// it follows the field once typing pauses.
  late final _searchText = TextEditingController(
    text: widget.search?.text ?? '',
  );
  late String _query = widget.search?.text ?? '';
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
    // A tab without matches goes, unless it is the open one: it stays and
    // says so, so typing doesn't jump to another tab.
    final tabs = <(Type, String, Widget)>[];
    void add(Type kind, String label, int count, int all, Widget Function() t) {
      if (count == 0 && !(searching && kind == _tab && all > 0)) return;
      tabs.add((
        kind,
        '$label (${formatCount(count)})',
        count == 0 ? _NoMatches(query: _query) : t(),
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
      contents.audio.length,
      base.audio.length,
      () => _AudioTab(pack: pack, contents: contents),
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
        child: TextField(
          key: _fieldKey,
          controller: _searchText,
          focusNode: _searchFocus,
          onChanged: _onSearchText,
          onTapOutside: (_) {
            if (_searchFocus.hasFocus) _keys.requestFocus();
          },
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'Search files (Ctrl+F)',
            border: const OutlineInputBorder(),
            suffixIcon: ValueListenableBuilder(
              valueListenable: _searchText,
              builder: (context, value, _) => value.text.isEmpty
                  ? const SizedBox.shrink()
                  : IconButton(
                      tooltip: 'Clear search (Esc)',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: _clearSearch,
                    ),
            ),
          ),
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
        Row(children: [const Spacer(), field]),
        Expanded(
          child: searching
              ? _NoMatches(query: _query)
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
            field,
          ],
        ),
        _TabMemory(
          onChanged: (i) => _tab = i < tabs.length ? tabs[i].$1 : null,
        ),
        Expanded(
          child: TabBarView(children: [for (final (_, _, t) in tabs) t]),
        ),
      ],
    ];
    // Music / sfx packs open on their Audio tab; a clicked file result on
    // the tab that lists it.
    final audioTab = tabs.indexWhere((t) => t.$1 == _AudioTab);
    var initial = isAudioPack(pack.types) && audioTab >= 0 ? audioTab : 0;
    if (widget.file case final file? when widget.search != null) {
      final at = tabs.indexWhere(
        (t) => switch (t.$1) {
          const (_AnimationsTab) => contents.shownDetected.any(
            (a) => a.path == file,
          ),
          const (_ImagesTab) => contents.images.contains(file),
          const (_AudioTab) => contents.audio.contains(file),
          const (_FilesTab) => contents.other.contains(file),
          _ => false,
        },
      );
      if (at >= 0) initial = at;
    }
    final kept = tabs.indexWhere((t) => t.$1 == _tab);
    if (kept >= 0) initial = kept;
    if (tabs.isNotEmpty) _tab = tabs[initial].$1;
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
  const _NoMatches({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.search_off, size: 48),
        const SizedBox(height: 8),
        Text('No files match “${query.trim()}”'),
      ],
    ),
  );
}

/// Every type is music or sfx (mixed packs such as characters + sfx keep
/// their first tab).
bool isAudioPack(List<String> types) =>
    types.isNotEmpty &&
    types.every((t) => t == AssetType.music.id || t == AssetType.sfx.id);

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
            images: contents.carousel(pack.preview),
            sizes: contents.sizes,
          ),
          // The icons take their own column on the right, so the info
          // never runs under them.
          info: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('header-info'),
                  child: _Info(pack: pack, contents: contents),
                ),
              ),
              const SizedBox(width: 8),
              actions,
            ],
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
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              [
                pack.author ?? 'Unknown author',
                if (pack.types.isNotEmpty) pack.types.join(', '),
                '${formatCount(pack.fileCount)} files',
                formatBytes(pack.totalBytes),
              ].join(' · '),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 12),
          Icon(Icons.unfold_more, size: 16, color: muted?.color),
          const SizedBox(width: 4),
          Text('Hover for details', style: muted),
          const Spacer(),
          actions,
        ],
      ),
    );
  }
}

/// The tile preview (animated when it's a sheet) plus covers and named
/// previews, one at a time.
class _Carousel extends StatefulWidget {
  const _Carousel({
    super.key,
    required this.pack,
    required this.images,
    this.sizes = const {},
  });

  final PackRow pack;
  final List<String> images;
  final Map<String, int> sizes;

  @override
  State<_Carousel> createState() => _CarouselState();
}

class _CarouselState extends State<_Carousel> {
  var _index = 0;
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final images = widget.images;
    final pack = widget.pack;
    final i = images.isEmpty ? 0 : _index % images.length;
    final Widget view;
    if (images.isEmpty) {
      view = Center(
        child: Icon(iconForTypes(pack.types), size: 72, color: scheme.primary),
      );
    } else if (i == 0 && pack.previewAnim != null) {
      view = AnimatedSprite(packPath: pack.path, anim: pack.previewAnim!);
    } else {
      view = PixelImage(File(p.join(pack.path, images[i])), animate: true);
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

/// Widest card in the "All previews" dialog.
const previewGridTileWidth = 440.0;

/// Every preview candidate of a pack in a grid; a click opens it in the
/// viewer, stepping through the grid.
class PreviewGridDialog extends StatelessWidget {
  const PreviewGridDialog({
    super.key,
    required this.packPath,
    required this.images,
    this.sizes = const {},
  });

  final String packPath;
  final List<String> images;
  final Map<String, int> sizes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      child: ConstrainedBox(
        // Twice the cards of the first version (220 → 440 px); the window
        // limits the dialog first.
        constraints: const BoxConstraints(maxWidth: 2000, maxHeight: 1440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Previews (${images.length})',
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: GridView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                gridDelegate: ThumbGridDelegate(
                  maxTileWidth: previewGridTileWidth,
                  imageAspect: 4 / 3,
                  footer: (_) => 26,
                  spacing: 8,
                ),
                itemCount: images.length,
                itemBuilder: (context, i) => Card(
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
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: PixelImage(
                              File(p.join(packPath, images[i])),
                              animate: true,
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
  const _Info({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  Future<void> _save(
    WidgetRef ref, {
    String? title,
    List<String>? types,
    List<String>? tags,
  }) async {
    if (!packExists(pack.path)) return;
    updatePackSidecar(pack.path, title: title, types: types, tags: tags);
    await ref.read(libraryProvider.notifier).reload();
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
    await ref.read(libraryProvider.notifier).reload();
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
            children: [
              Flexible(
                child: Text(pack.title, style: theme.textTheme.headlineSmall),
              ),
              IconButton(
                tooltip: 'Edit title',
                icon: const Icon(Icons.edit, size: 18),
                onPressed: () async {
                  final title = await showDialog<String>(
                    context: context,
                    builder: (_) => TitleDialog(
                      initial: contents.sidecar?.title ?? pack.title,
                      folderName: p.basename(pack.path),
                    ),
                  );
                  if (title != null) await _save(ref, title: title);
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Icon(Icons.person_outline, size: 18),
              const SizedBox(width: 6),
              if (authorUrl != null)
                InkWell(
                  mouseCursor: clickCursor,
                  onTap: () => launchUrl(Uri.parse(authorUrl)),
                  child: Text(
                    pack.author ?? authorUrl,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
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
              final types = await showDialog<List<String>>(
                context: context,
                builder: (_) => TypesDialog(initial: pack.types),
              );
              if (types != null) await _save(ref, types: types);
            },
          ),
          const SizedBox(height: 8),
          _ChipRow(
            label: 'Tags',
            values: sortedTags(pack.tags),
            onEdit: () async {
              final tags = await showDialog<List<String>>(
                context: context,
                builder: (_) =>
                    TagsDialog(initial: pack.tags, known: knownTags(ref)),
              );
              if (tags != null) await _save(ref, tags: tags);
            },
          ),
          const SizedBox(height: 8),
          _ChipRow(
            label: 'Used in',
            values: pack.usedIn,
            editIcon: Icons.add,
            editTooltip: 'Mark as used in a game',
            onDelete: (game) async {
              final ok = await confirmRemoveFromGame(
                context,
                pack: pack.title,
                game: game,
              );
              if (!ok || !packExists(pack.path)) return;
              setUsedIn(pack.path, game, used: false);
              await ref.read(libraryProvider.notifier).reload();
            },
            onEdit: () async {
              final packs = ref.read(libraryProvider).value?.packs ?? const [];
              final game = await showDialog<String>(
                context: context,
                builder: (_) => GameNameDialog(known: knownGames(packs)),
              );
              if (game == null || !packExists(pack.path)) return;
              setUsedIn(pack.path, game, used: true);
              await ref.read(libraryProvider.notifier).reload();
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
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (values.isEmpty) const Text('—'),
              for (final v in values)
                Chip(
                  label: Text(v),
                  visualDensity: VisualDensity.compact,
                  deleteIcon: deleteIcon,
                  onDeleted: onDelete == null ? null : () => onDelete!(v),
                  deleteButtonTooltipMessage: 'Remove $v',
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: editTooltip ?? 'Edit ${label.toLowerCase()}',
          icon: Icon(editIcon, size: 18),
          onPressed: onEdit,
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
  /// Folders folded away in the "By folder" view, for this visit.
  final _collapsed = <String>{};

  /// Flat view selection (Ctrl/Shift-click or the hover checkbox), for
  /// "Combine N images into animation".
  final _selected = <String>{};
  String? _anchor;
  var _busy = false;

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

  /// "Make animation…": the Edit dialog with a one-row strip guess.
  void _makeAnimation(String rel) {
    final size = readImageSize(p.join(pack.path, rel));
    if (size == null) return;
    showDialog<void>(
      context: context,
      builder: (_) => _AnimationEditorDialog(
        pack: pack,
        path: rel,
        pending: guessStrip(rel, size.$1, size.$2),
      ),
    );
  }

  /// Combines [rels] into one strip ([combinedName]); [unique] picks a free
  /// name, otherwise Save asks before replacing. Asks first, builds the strip
  /// in memory and opens it in the Edit dialog; only Save writes anything.
  Future<void> _combine(List<String> rels, {required bool unique}) async {
    if (rels.length < 2 || _busy || !packExists(pack.path)) return;
    final taken = {
      ...contents.images,
      ...contents.other,
    }.where((r) => File(p.join(pack.path, r)).existsSync()).toSet();
    final out = combinedName(rels, taken: taken, unique: unique);
    final folder = p.posix.dirname(out);
    final from = folder == '.'
        ? prettyName(pack.title, isFile: false)
        : prettyName(p.posix.basename(folder), isFile: false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    // The tab may be rebuilt meanwhile; the dialog opens from the
    // navigator, which stays.
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        key: const ValueKey('combine-confirm'),
        title: const Text('Combine into animation'),
        content: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: 'Combine ${rels.length} images from '),
              TextSpan(
                text: from,
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
              const TextSpan(text: ' into one animation?\n\nSaved as '),
              TextSpan(
                text: out,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const TextSpan(
                text: ' when you press Save. Nothing is written before.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
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
    final size = imageThumbRange.clamp(
      ref.watch(settingsProvider.select((s) => s.imageThumbSize)),
    );
    final view = ref.watch(settingsProvider.select((s) => s.imagesView));
    final settings = ref.read(settingsProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
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
                onChanged: settings.setImageThumbSize,
              ),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_selected.isNotEmpty && view == ItemsView.flat)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
            onSteps: (n) =>
                settings.setImageThumbSize(imageThumbRange.nudge(size, n)),
            child: _imageGrid(context, images, size, view),
          ),
        ),
      ],
    );
  }

  Widget _imageGrid(
    BuildContext context,
    List<String> images,
    double size,
    ItemsView view,
  ) {
    // The viewer steps through images in the order they're shown.
    final order = visibleOrder(images, view, _collapsed);
    return GroupedGrid(
      key: PageStorageKey('images:${pack.id}'),
      rels: images,
      view: view,
      collapsed: _collapsed,
      onToggleFolder: (f) => setState(
        () => _collapsed.contains(f) ? _collapsed.remove(f) : _collapsed.add(f),
      ),
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
      // A square image over a one-line file name.
      gridDelegate: ThumbGridDelegate(
        maxTileWidth: size,
        imageAspect: 1,
        footer: (_) => 26,
        spacing: 8,
      ),
      itemBuilder: (context, i) {
        final rel = images[i];
        final file = File(p.join(pack.path, rel));
        final flat = view == ItemsView.flat;
        final selected = _selected.contains(rel);
        final canAnimate =
            !_animated.contains(rel) &&
            p.extension(rel).toLowerCase() == '.png';
        final shown = [for (final j in order) images[j]];
        return _HoverReveal(
          path: file.path,
          showLeading: selected,
          leading: flat
              ? Checkbox(
                  key: ValueKey('select:$rel'),
                  mouseCursor: clickCursor,
                  value: selected,
                  onChanged: (_) => _toggle(rel),
                )
              : null,
          actions: [
            if (canAnimate)
              IconButton(
                tooltip: 'Make animation…',
                mouseCursor: clickCursor,
                icon: const Icon(Icons.animation, size: 18),
                onPressed: () => _makeAnimation(rel),
              ),
          ],
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            shape: selected
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  )
                : null,
            child: InkWell(
              mouseCursor: clickCursor,
              onTap: () {
                final keys = HardwareKeyboard.instance;
                if (flat && keys.isShiftPressed) {
                  _selectRange(shown, rel);
                } else if (flat && keys.isControlPressed) {
                  _toggle(rel);
                } else {
                  showImageViewer(
                    context,
                    packPath: pack.path,
                    images: shown,
                    index: order.indexOf(i),
                    sizes: contents.sizes,
                  );
                }
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: PixelImage(file),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: Tooltip(
                      message: rel,
                      child: Text(
                        p.basename(rel),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _AnimationsTab extends StatelessWidget {
  const _AnimationsTab({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  Widget build(BuildContext context) => AnimationGrid(
    gridId: pack.id,
    packPath: pack.path,
    animations: contents.animations,
    detected: contents.shownDetected,
    sizes: contents.sizes,
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
  String get path => widget.path;

  /// The unsaved strip; null once saved (or for files on disk).
  late Uint8List? _bytes = widget.bytes;
  var _saved = false;

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
    super.dispose();
  }

  /// Asks before a combined strip replaces an existing file.
  Future<bool> _confirmReplace() async {
    if (!File(p.join(pack.path, path)).existsSync()) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace animation?'),
        content: Text('$path already exists. Replace it?'),
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
                      AnimationEditor(
                        key: ValueKey('$path:${bytes != null}'),
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
                            if (anim == null || !await _confirmReplace()) {
                              return;
                            }
                            saveCombinedStrip(pack.path, bytes, detected, anim);
                            // The same path may be cached from an older file.
                            await FileImage(File(p.join(pack.path, path)))
                                .evict();
                            _saved = true;
                            await library.reload();
                            if (mounted) setState(() => _bytes = null);
                            return;
                          }
                          saveAnimationOverride(
                            pack.path,
                            detected,
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
  });

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
                              prettyName(a.label, isFile: false),
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
                              a.path,
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
                            onPressed: dirty && !_saving
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
                              onPressed: _saving
                                  ? null
                                  : () => _runSave(widget.onNotAnimation),
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

  TrackPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = ref.read(trackPlayerFactoryProvider)();
    _subs
      ..add(
        player.onComplete.listen((_) {
          // Looping players report each pass as complete; they keep playing.
          if (_player?.looping ?? false) return;
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

  Future<void> _toggle(String rel) async {
    final player = _ensurePlayer();
    _keys.requestFocus();
    _selected = rel;
    if (_playing == rel) {
      await player.stop();
      setState(() => _playing = null);
      return;
    }
    setState(() {
      _playing = rel;
      _position = Duration.zero;
      _length = null;
    });
    try {
      await player.stop();
      await player.setLoop(ref.read(settingsProvider).audioLoop);
      await player.play(p.join(widget.pack.path, rel));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _playing = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not play $rel: $e')));
    }
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

  /// Turning loop off lets the current sound finish its pass.
  void _setLoop(bool on) {
    ref.read(settingsProvider.notifier).setAudioLoop(on);
    _player?.setLoop(on);
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    _keys.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final audio = widget.contents.audio;
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
    return Focus(
      focusNode: _keys,
      onKeyEvent: _onKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Like Images / Animations: view options left, controls right.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                _AudioViewToggle(
                  view: view,
                  onChanged: ref.read(settingsProvider.notifier).setAudioView,
                ),
                const Spacer(),
                FilterChip(
                  mouseCursor: clickCursor,
                  avatar: const Icon(Icons.repeat, size: 18),
                  label: const Text('Loop'),
                  tooltip: 'Repeat the playing sound',
                  selected: loop,
                  showCheckmark: false,
                  onSelected: _setLoop,
                ),
              ],
            ),
          ),
          Expanded(
            child: switch (view) {
              AudioView.rows => _rows(audio, readLength),
              AudioView.cards => _cards(audio, readLength),
            },
          ),
        ],
      ),
    );
  }

  /// The playing track's length: the player's once it reports one, else
  /// the header's.
  Duration? _lengthOf(String rel) => _length ?? _known[rel];

  /// Long tracks get a seek bar while playing; short ones show only their
  /// length.
  bool _seekable(String rel) {
    final length = _lengthOf(rel);
    return length != null && length >= seekBarMinLength;
  }

  Widget _rows(
    List<String> audio,
    Future<Duration?> Function(String) readLength,
  ) => ListView.builder(
    padding: const EdgeInsets.symmetric(vertical: 8),
    itemCount: audio.length,
    itemBuilder: (context, i) {
      final rel = audio[i];
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
        title: Text(p.basename(rel)),
        subtitle: p.dirname(rel) == '.' ? null : Text(p.dirname(rel)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Built only for visible rows, so only they are read.
            _TrackLength(future: readLength(rel)),
            const SizedBox(width: 16),
            Text(formatBytes(widget.contents.sizes[rel] ?? 0)),
            RevealButton(path),
          ],
        ),
        onTap: () => _toggle(rel),
      );
      if (!playing || !_seekable(rel)) return tile;
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          tile,
          _SeekBar(position: _position, length: _lengthOf(rel)!, onSeek: _seek),
        ],
      );
    },
  );

  Widget _cards(
    List<String> audio,
    Future<Duration?> Function(String) readLength,
  ) => GridView.builder(
    key: const PageStorageKey('audio-cards'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    gridDelegate: ThumbGridDelegate(
      maxTileWidth: 220,
      // Room for the button and, while a long track plays, its seek bar.
      imageAspect: 1.6,
      footer: (_) => 60,
    ),
    itemCount: audio.length,
    itemBuilder: (context, i) {
      final rel = audio[i];
      final playing = _playing == rel;
      return _AudioCard(
        key: ValueKey(rel),
        rel: rel,
        packPath: widget.pack.path,
        length: readLength(rel),
        selected: _selected == rel,
        playing: playing,
        position: playing ? _position : null,
        playingLength: playing ? _lengthOf(rel) : null,
        onToggle: () => _toggle(rel),
        onSeek: _seek,
      );
    },
  );
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

/// One sound as a grid card: a big play / stop button with a progress
/// ring while playing, the prettified name, its length and folder; long
/// tracks get a seek bar while they play.
class _AudioCard extends StatelessWidget {
  const _AudioCard({
    super.key,
    required this.rel,
    required this.packPath,
    required this.length,
    required this.selected,
    required this.playing,
    required this.position,
    required this.playingLength,
    required this.onToggle,
    required this.onSeek,
  });

  final String rel;
  final String packPath;
  final Future<Duration?> length;
  final bool selected;
  final bool playing;

  /// While playing: where it is and how long it is (if known).
  final Duration? position;
  final Duration? playingLength;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final total = playingLength;
    final progress = playing && total != null && total > Duration.zero
        ? (position!.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
        : null;
    final long = playing && total != null && total >= seekBarMinLength;
    final folder = p.dirname(rel);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        mouseCursor: clickCursor,
        onTap: onToggle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox.square(
                          dimension: 56,
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              if (progress != null)
                                SizedBox.square(
                                  dimension: 56,
                                  child: CircularProgressIndicator(
                                    key: const ValueKey('progress'),
                                    value: progress,
                                    strokeWidth: 3,
                                  ),
                                ),
                              IconButton(
                                tooltip: playing ? 'Stop' : 'Play',
                                iconSize: 40,
                                color: scheme.primary,
                                icon: Icon(
                                  playing
                                      ? Icons.stop_circle
                                      : Icons.play_circle,
                                ),
                                onPressed: onToggle,
                              ),
                            ],
                          ),
                        ),
                        if (long)
                          _SeekBar(
                            position: position!,
                            length: total,
                            onSeek: onSeek,
                            compact: true,
                          ),
                      ],
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: RevealButton(p.join(packPath, rel)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    prettyName(p.basename(rel)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      _TrackLength(
                        future: length,
                        align: TextAlign.start,
                        width: null,
                      ),
                      if (folder != '.')
                        Expanded(
                          child: Text(
                            ' · $folder',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `m:ss` once the header has been read; nothing for unknown formats.
class _TrackLength extends StatelessWidget {
  const _TrackLength({
    required this.future,
    this.align = TextAlign.end,
    this.width = 56,
  });

  final Future<Duration?> future;
  final TextAlign align;

  /// Null: as wide as the text.
  final double? width;

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: future,
    builder: (context, snap) {
      final d = snap.data;
      return SizedBox(
        width: width,
        child: Text(
          d == null ? '' : formatDuration(d),
          textAlign: align,
          style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        ),
      );
    },
  );
}

/// Elapsed time, a slider that seeks on click or drag, and the total, for
/// tracks of [seekBarMinLength] or more. [compact] (in an audio card) puts
/// the times under the slider.
class _SeekBar extends StatefulWidget {
  const _SeekBar({
    required this.position,
    required this.length,
    required this.onSeek,
    this.compact = false,
  });

  final Duration position;
  final Duration length;
  final ValueChanged<Duration> onSeek;
  final bool compact;

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
    if (widget.compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: 24, child: slider),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [elapsed, total],
            ),
          ],
        ),
      );
    }
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

class _FilesTab extends StatelessWidget {
  const _FilesTab({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  Widget build(BuildContext context) {
    final files = contents.other;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: files.length,
      itemBuilder: (context, i) {
        final rel = files[i];
        final previewable = isTextPreviewable(rel);
        return ListTile(
          dense: true,
          leading: Icon(_iconFor(rel)),
          title: Text(rel),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(formatBytes(contents.sizes[rel] ?? 0)),
              RevealButton(p.join(pack.path, rel)),
            ],
          ),
          // Text files open in the preview; the rest only reveal.
          onTap: previewable
              ? () => showTextPreview(context, packPath: pack.path, rel: rel)
              : null,
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

/// Shows a [RevealButton] in the top-right corner of [child] while the
/// mouse is over it, so small image cards stay uncluttered.
class _HoverReveal extends StatefulWidget {
  const _HoverReveal({
    required this.path,
    required this.child,
    this.actions = const [],
    this.leading,
    this.showLeading = false,
  });

  final String path;
  final Widget child;

  /// More hover buttons, before the reveal button.
  final List<Widget> actions;

  /// A top-left control (the selection checkbox): shown on hover, or always
  /// with [showLeading].
  final Widget? leading;
  final bool showLeading;

  @override
  State<_HoverReveal> createState() => _HoverRevealState();
}

class _HoverRevealState extends State<_HoverReveal> {
  var _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (widget.leading case final leading?
            when _hover || widget.showLeading)
          Positioned(
            top: 2,
            left: 2,
            child: Material(
              color: Theme.of(context).colorScheme.surface
                  .withValues(alpha: 0.85),
              shape: const CircleBorder(),
              child: leading,
            ),
          ),
        if (_hover)
          Positioned(
            top: 2,
            right: 2,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in [...widget.actions, RevealButton(widget.path)])
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Material(
                      color: Theme.of(context).colorScheme.surface
                          .withValues(alpha: 0.85),
                      shape: const CircleBorder(),
                      child: a,
                    ),
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}
