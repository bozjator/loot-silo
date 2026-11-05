import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../core/animation_detector.dart';
import '../core/credits.dart';
import '../core/library_index.dart';
import '../core/pack_editor.dart';
import '../core/sidecar.dart';
import '../core/text_preview.dart';
import '../state/dashboard.dart' show sortedTags;
import '../state/providers.dart';
import '../state/settings.dart';
import 'format.dart';
import 'animation_grid.dart';
import 'folder_groups.dart';
import 'image_viewer.dart';
import 'reveal.dart';
import 'text_preview_dialog.dart';
import 'widgets/animated_sprite.dart';
import 'widgets/meta_dialogs.dart';
import 'widgets/pack_tile.dart' show iconForTypes;
import 'widgets/pixel_image.dart';
import 'widgets/thumb_size.dart';
import 'cursors.dart';

/// Everything about one pack: previews, files, animations, metadata.
class PackDetailScreen extends ConsumerWidget {
  const PackDetailScreen({super.key, required this.packId, this.folder});

  final String packId;

  /// First-level folder the Images and Animations tabs start at (from an
  /// Expanded dashboard tile).
  final String? folder;

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
      autofocus: true,
      // H pins or unpins the header, unless a text field has the key.
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.keyH ||
            HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isAltPressed ||
            FocusManager.instance.primaryFocus?.context?.widget
                is EditableText) {
          return KeyEventResult.ignored;
        }
        togglePin();
        return KeyEventResult.handled;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(pack.title),
          actions: [
            IconButton(
              tooltip: pinned
                  ? 'Unpin header — show it on hover (H)'
                  : 'Pin header (H)',
              isSelected: pinned,
              icon: const Icon(Icons.push_pin_outlined),
              selectedIcon: const Icon(Icons.push_pin),
              onPressed: togglePin,
            ),
            if (pack.itchUrl case final url?)
              IconButton(
                tooltip: 'itch.io page',
                icon: const Icon(Icons.storefront_outlined),
                onPressed: () => launchUrl(Uri.parse(url)),
              ),
            IconButton(
              tooltip: 'Open folder',
              icon: const Icon(Icons.folder_open),
              onPressed: () => launchUrl(Uri.directory(pack.path)),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: switch (contents) {
          AsyncData(:final value) => _Body(
            pack: pack,
            contents: value,
            pinned: pinned,
            folder: folder,
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
    this.folder,
  });

  final PackRow pack;
  final PackContents contents;
  final String? folder;

  /// False: a slim bar replaces the header; hovering it shows the header
  /// floating over the tabs, so nothing below moves.
  final bool pinned;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  var _peek = false;
  late String? _folder = widget.folder;

  @override
  void didUpdateWidget(_Body old) {
    super.didUpdateWidget(old);
    if (widget.pinned) _peek = false;
  }

  @override
  Widget build(BuildContext context) {
    final pack = widget.pack;
    final folder = _folder;
    final contents = folder == null
        ? widget.contents
        : widget.contents.within(folder);
    final tabs = <(String, Widget)>[
      if (contents.animations.isNotEmpty)
        (
          'Animations (${formatCount(contents.animations.length)})',
          _AnimationsTab(pack: pack, contents: contents),
        ),
      if (contents.images.isNotEmpty)
        (
          'Images (${formatCount(contents.images.length)})',
          _ImagesTab(pack: pack, contents: contents),
        ),
      if (contents.audio.isNotEmpty)
        (
          'Audio (${formatCount(contents.audio.length)})',
          _AudioTab(pack: pack, contents: contents),
        ),
      if (contents.other.isNotEmpty)
        (
          'Other files (${formatCount(contents.other.length)})',
          _FilesTab(pack: pack, contents: contents),
        ),
    ];
    final header = _Header(pack: pack, contents: widget.contents);
    final tabArea = <Widget>[
      if (folder != null)
        _FolderBar(
          folder: folder,
          onShowAll: () => setState(() => _folder = null),
        ),
      if (tabs.isEmpty)
        const Expanded(child: Center(child: Text('No files')))
      else ...[
        TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [for (final (label, _) in tabs) Tab(text: label)],
        ),
        Expanded(child: TabBarView(children: [for (final (_, t) in tabs) t])),
      ],
    ];
    return DefaultTabController(
      // A new controller when the folder is cleared and the tab count
      // changes.
      key: ValueKey(folder),
      length: tabs.length,
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
                      onEnter: (_) => setState(() => _peek = true),
                      child: _SlimHeader(pack: pack, contents: contents),
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
  const _Header({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 400,
              height: 300,
              child: _Carousel(
                pack: pack,
                images: contents.carousel(pack.preview),
                sizes: contents.sizes,
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: _Info(pack: pack, contents: contents),
            ),
          ],
        ),
      ),
    );
  }
}

/// The unpinned header: one line of facts; hover shows the full header.
class _SlimHeader extends StatelessWidget {
  const _SlimHeader({required this.pack, required this.contents});

  final PackRow pack;
  final PackContents contents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
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
        ],
      ),
    );
  }
}

/// The tile preview (animated when it's a sheet) plus covers and named
/// previews, one at a time.
class _Carousel extends StatefulWidget {
  const _Carousel({
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
    return ClipRRect(
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
            ],
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
                builder: (_) => TagsDialog(initial: pack.tags),
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

  PackRow get pack => widget.pack;
  PackContents get contents => widget.contents;

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
              const Spacer(),
              ThumbSizeSlider(
                range: imageThumbRange,
                value: size,
                onChanged: settings.setImageThumbSize,
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
        return _HoverReveal(
          path: file.path,
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            child: InkWell(
              mouseCursor: clickCursor,
              onTap: () => showImageViewer(
                context,
                packPath: pack.path,
                images: [for (final j in order) images[j]],
                index: order.indexOf(i),
                sizes: contents.sizes,
              ),
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
    detected: contents.detected,
    onEdit: (anim) => showDialog<void>(
      context: context,
      builder: (_) => _AnimationEditorDialog(pack: pack, path: anim.path),
    ),
  );
}

/// The fps / frame size / row editor for the animation at [path]. Watches
/// the pack, so after Save the editor shows the stored override, as the old
/// in-list cards did.
class _AnimationEditorDialog extends ConsumerWidget {
  const _AnimationEditorDialog({required this.pack, required this.path});

  final PackRow pack;
  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contents = ref.watch(packContentsProvider(pack.id)).value;
    final i = contents?.detected.indexWhere((a) => a.path == path) ?? -1;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: contents == null || i < 0
              ? const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _AnimationEditor(
                      key: ValueKey(path),
                      packPath: pack.path,
                      detected: contents.detected[i],
                      current: contents.animations[i],
                      onSave: (anim) async {
                        if (!packExists(pack.path)) return;
                        saveAnimationOverride(
                          pack.path,
                          contents.detected[i],
                          anim,
                        );
                        // The tile preview may be this sheet; rescan picks the
                        // override up.
                        await ref.read(libraryProvider.notifier).reload();
                      },
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Close'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Plays one animation with live fps / frame-size / row controls; Save
/// writes the override into the pack sidecar. Shown in the Edit dialog.
class _AnimationEditor extends StatefulWidget {
  const _AnimationEditor({
    super.key,
    required this.packPath,
    required this.detected,
    required this.current,
    required this.onSave,
  });

  final String packPath;
  final SpriteAnim detected;
  final SpriteAnim current;

  /// Null resets to the detected values.
  final Future<void> Function(SpriteAnim? anim) onSave;

  @override
  State<_AnimationEditor> createState() => _AnimationEditorState();
}

class _AnimationEditorState extends State<_AnimationEditor> {
  late SpriteAnim _anim = widget.current;
  int? _row = 0;
  late final _w = TextEditingController(text: '${widget.current.frameW}');
  late final _h = TextEditingController(text: '${widget.current.frameH}');
  late final _n = TextEditingController(text: '${widget.current.frameCount}');

  /// Shown under the Frames field when the count doesn't fit the sheet.
  String? _framesError;

  @override
  void didUpdateWidget(_AnimationEditor old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current) _reset(widget.current);
  }

  void _reset(SpriteAnim a) {
    setState(() {
      _anim = a;
      _row = 0;
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
      _anim = widget.detected.copyWith(frameW: w, frameH: h, fps: _anim.fps);
      _row = 0;
      _n.text = '${_anim.frameCount}';
      _framesError = null;
    });
  }

  /// Re-slices the sheet into the typed total frame count; the frame width
  /// follows. A count that doesn't fit keeps the old slicing.
  void _applyFrames() {
    if (_n.text.trim().isEmpty) return;
    final n = int.tryParse(_n.text.trim());
    final next = n == null ? null : _anim.withFrameCount(n);
    setState(() {
      if (next == null) {
        _framesError = 'Doesn\'t fit ${_anim.frameW * _anim.cols} px';
        return;
      }
      _framesError = null;
      _anim = next;
      _row = 0;
      _w.text = '${next.frameW}';
    });
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
    final dirty = a != widget.current;
    final overridden = widget.current != widget.detected;
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 240,
              height: 240,
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
                  : AnimatedSprite(
                      packPath: widget.packPath,
                      anim: a,
                      row: _row,
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
                        child: Text(
                          prettyName(a.label, isFile: false),
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      RevealButton(p.join(widget.packPath, a.path)),
                    ],
                  ),
                  Text(
                    a.path,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(switch (a.kind) {
                    AnimKind.sheet =>
                      'Sheet · ${a.frameW}×${a.frameH} frames · '
                          '${a.cols} × ${a.rows} · ${a.frameCount} frames',
                    AnimKind.sequence =>
                      'Sequence · ${a.frames.length} files · '
                          '${a.frameW}×${a.frameH}',
                    AnimKind.gif => 'Animated GIF',
                  }),
                  if (a.kind != AnimKind.gif)
                    Row(
                      children: [
                        const Text('FPS'),
                        SizedBox(
                          width: 240,
                          child: Slider(
                            min: 1,
                            max: 30,
                            divisions: 29,
                            value: a.fps.clamp(1, 30),
                            label: a.fps.round().toString(),
                            onChanged: (v) => setState(
                              () => _anim = a.copyWith(fps: v.roundToDouble()),
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
                        _NumberField(
                          label: 'Frames',
                          controller: _n,
                          onSubmit: _applyFrames,
                          onChanged: _applyFrames,
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
                            value: _row,
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
                            onChanged: (r) => setState(() => _row = r),
                          ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: dirty ? () => widget.onSave(a) : null,
                        child: const Text('Save'),
                      ),
                      const SizedBox(width: 8),
                      if (overridden)
                        TextButton(
                          onPressed: () => widget.onSave(null),
                          child: const Text('Reset to detected'),
                        )
                      else if (dirty)
                        TextButton(
                          onPressed: () => _reset(widget.current),
                          child: const Text('Undo'),
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

class _AudioTabState extends ConsumerState<_AudioTab> {
  // Created on first play so tests and silent browsing never touch audio.
  AudioPlayer? _player;
  String? _playing;

  static ReleaseMode _modeFor(bool loop) =>
      loop ? ReleaseMode.loop : ReleaseMode.release;

  Future<void> _toggle(String rel) async {
    final player = _player ??= AudioPlayer()
      ..onPlayerComplete.listen((_) {
        // Looping players report each pass as complete; they keep playing.
        if (_player?.releaseMode == ReleaseMode.loop) return;
        if (mounted) setState(() => _playing = null);
      });
    if (_playing == rel) {
      await player.stop();
      setState(() => _playing = null);
      return;
    }
    setState(() => _playing = rel);
    try {
      await player.stop();
      await player.setReleaseMode(
        _modeFor(ref.read(settingsProvider).audioLoop),
      );
      await player.play(DeviceFileSource(p.join(widget.pack.path, rel)));
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _playing = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not play $rel: $e')));
    }
  }

  /// Turning loop off lets the current sound finish its pass.
  void _setLoop(bool on) {
    ref.read(settingsProvider.notifier).setAudioLoop(on);
    _player?.setReleaseMode(_modeFor(on));
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final audio = widget.contents.audio;
    final loop = ref.watch(settingsProvider.select((s) => s.audioLoop));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              mouseCursor: clickCursor,
              avatar: const Icon(Icons.repeat, size: 18),
              label: const Text('Loop'),
              tooltip: 'Repeat the playing sound',
              selected: loop,
              showCheckmark: false,
              onSelected: _setLoop,
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: audio.length,
            itemBuilder: (context, i) {
              final rel = audio[i];
              final playing = _playing == rel;
              return ListTile(
                dense: true,
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
                    Text(formatBytes(widget.contents.sizes[rel] ?? 0)),
                    RevealButton(p.join(widget.pack.path, rel)),
                  ],
                ),
                onTap: () => _toggle(rel),
              );
            },
          ),
        ),
      ],
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
  const _HoverReveal({required this.path, required this.child});

  final String path;
  final Widget child;

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
        if (_hover)
          Positioned(
            top: 2,
            right: 2,
            child: Material(
              color: Theme.of(context).colorScheme.surface
                  .withValues(alpha: 0.85),
              shape: const CircleBorder(),
              child: RevealButton(widget.path),
            ),
          ),
      ],
    ),
  );
}
