import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:path/path.dart' as p;

import '../../core/pack_editor.dart';
import '../../core/sidecar.dart';
import '../../state/providers.dart';
import '../clipboard.dart';

/// What a right-click on a file card or row acts on.
class FileMenuTarget {
  const FileMenuTarget({
    required this.files,
    this.image,
    this.open,
    this.gif,
    this.preview,
  });

  /// Absolute paths for Copy file and Copy path (a selection, or a
  /// material's maps).
  final List<String> files;

  /// The image file for Copy image (images and animations); null: no item.
  final String? image;

  /// The file for Open and Open with…; null: no items (several files).
  final String? open;

  /// Animations: Copy as GIF to clipboard / file; the file is saved as
  /// `<name>.gif` in the GIF cache.
  final ({String name, Future<Uint8List?> Function() make})? gif;

  /// One image or animation of a pack: the cover and previews items.
  final PreviewTarget? preview;
}

/// A file that can be one of its pack's previews.
class PreviewTarget {
  const PreviewTarget({
    required this.packId,
    required this.packPath,
    required this.preview,
    required this.file,
  });

  final String packId;
  final String packPath;

  /// The pack's tile preview now (`PackRow.preview`).
  final String? preview;

  /// Relative to the pack.
  final String file;
}

/// The pack's previews as the header shows them; null while the pack's
/// files are loading. The user's list is read from the file, so a save
/// that the loaded files don't show yet counts.
List<String>? _previewsOf(WidgetRef ref, PreviewTarget t) {
  final contents = ref.read(packContentsProvider(t.packId)).value;
  if (contents == null) return null;
  final saved = PackSidecar.read(t.packPath)?.previews ?? const [];
  if (saved.isNotEmpty) {
    final present = contents.previewable.toSet();
    final chosen = [
      for (final f in saved)
        if (present.contains(f)) f,
    ];
    if (chosen.isNotEmpty) return chosen;
  }
  return contents.carousel(t.preview);
}

bool _isPreview(FileMenuAction a) =>
    a == FileMenuAction.useAsCover ||
    a == FileMenuAction.addPreview ||
    a == FileMenuAction.removePreview;

/// The pack's preview list after [a] on [file]. Without a list of the
/// user's own, the automatic previews are its start, so adding one keeps
/// the others.
List<String> previewsAfter(
  FileMenuAction a,
  String file,
  List<String> current,
) => switch (a) {
  FileMenuAction.useAsCover => [file, ...current.where((f) => f != file)],
  FileMenuAction.addPreview => [...current.where((f) => f != file), file],
  FileMenuAction.removePreview => [...current.where((f) => f != file)],
  _ => current,
};

/// The menu's items, in the order they show: on animations the two GIF
/// items first, then the image card's items.
enum FileMenuAction {
  /// The GIF as a picture only (`image/gif`): chats, email.
  copyGif,

  /// The GIF as a file only: file managers, a game's folder.
  copyGifFile,
  copyImage,
  copyFiles,
  copyPath,
  open,
  openWith,
  useAsCover,
  addPreview,
  removePreview,
}

/// The item's label; [n] files are copied.
String fileMenuLabel(FileMenuAction a, int n) => switch (a) {
  FileMenuAction.copyGif => 'Copy as GIF to clipboard',
  FileMenuAction.copyGifFile => 'Copy as GIF file',
  FileMenuAction.copyImage => 'Copy image to clipboard',
  FileMenuAction.copyFiles => n == 1 ? 'Copy file' : 'Copy $n files',
  FileMenuAction.copyPath => n == 1 ? 'Copy path' : 'Copy $n paths',
  FileMenuAction.open => 'Open',
  FileMenuAction.openWith => 'Open with…',
  FileMenuAction.useAsCover => 'Use as pack cover',
  FileMenuAction.addPreview => 'Add to pack previews',
  FileMenuAction.removePreview => 'Remove from pack previews',
};

/// The items [target] gets on this platform: only what applies, never
/// greyed out. Nothing that a card's own icons already do (star, select,
/// reveal, open in a viewer) and no Play / Stop.
///
/// [previews] are the pack's previews now, for the cover and previews
/// items of a [FileMenuTarget.preview].
List<FileMenuAction> fileMenuActions(
  FileMenuTarget target,
  FileClipboard clipboard, {
  List<String>? previews,
}) => [
  if (target.gif != null && clipboard.canCopyFiles) ...[
    FileMenuAction.copyGif,
    FileMenuAction.copyGifFile,
  ],
  if (target.image != null && clipboard.canCopyFiles) FileMenuAction.copyImage,
  if (target.files.isNotEmpty && clipboard.canCopyFiles)
    FileMenuAction.copyFiles,
  if (target.files.isNotEmpty) FileMenuAction.copyPath,
  if (target.open != null) FileMenuAction.open,
  if (target.open != null && clipboard.canOpenWith) FileMenuAction.openWith,
  if (target.preview?.file case final f? when previews != null) ...[
    if (previews.firstOrNull != f) FileMenuAction.useAsCover,
    if (!previews.contains(f))
      FileMenuAction.addPreview
    else
      FileMenuAction.removePreview,
  ],
];

/// One file card's or row's right-click menu at [at] (global), then the
/// chosen action and its snack bar.
Future<void> showFileMenu(
  BuildContext context,
  WidgetRef ref,
  Offset at,
  FileMenuTarget target,
) async {
  final clipboard = ref.read(fileClipboardProvider);
  final pt = target.preview;
  final previews = pt == null ? null : _previewsOf(ref, pt);
  final actions = fileMenuActions(target, clipboard, previews: previews);
  if (actions.isEmpty) return;
  final n = target.files.length;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await showMenu<FileMenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      for (final (i, a) in actions.indexed) ...[
        // A line between the file's items and the pack's.
        if (i > 0 && _isPreview(a) && !_isPreview(actions[i - 1]))
          const PopupMenuDivider(),
        PopupMenuItem(
          key: ValueKey('menu:${a.name}'),
          value: a,
          child: ListTile(
            dense: true,
            leading: Icon(switch (a) {
              FileMenuAction.copyImage => Icons.image_outlined,
              FileMenuAction.copyGif => Icons.gif_box_outlined,
              FileMenuAction.copyGifFile => Icons.insert_drive_file_outlined,
              FileMenuAction.copyFiles => Icons.file_copy_outlined,
              FileMenuAction.copyPath => Icons.link,
              FileMenuAction.open => Icons.open_in_new,
              FileMenuAction.openWith => Icons.apps,
              FileMenuAction.useAsCover => Icons.wallpaper,
              FileMenuAction.addPreview => Icons.add_photo_alternate_outlined,
              FileMenuAction.removePreview => Icons.hide_image_outlined,
            }),
            title: Text(fileMenuLabel(a, n)),
          ),
        ),
      ],
    ],
  );
  if (choice == null) return;
  // Before any await: the menu's card may be gone after it.
  final library = ref.read(libraryProvider.notifier);
  void say(String text) => messenger
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
  try {
    switch (choice) {
      case FileMenuAction.copyImage:
        await clipboard.copyImage(target.image!);
        say('Image copied');
      case FileMenuAction.copyGif || FileMenuAction.copyGifFile:
        final (:name, :make) = target.gif!;
        say('Making GIF…');
        final bytes = await make();
        if (bytes == null) throw const FormatException('no frames');
        if (choice == FileMenuAction.copyGif) {
          // Only the picture: a file manager would save it as a still.
          await clipboard.copyBytes('image/gif', bytes);
          say('GIF copied');
        } else {
          // Only the file: pasted, it stays a moving .gif.
          final dir = Directory(ref.read(gifCacheProvider))
            ..createSync(recursive: true);
          final file = File(p.join(dir.path, '${gifFileName(name)}.gif'))
            ..writeAsBytesSync(bytes);
          await clipboard.copyFiles([file.path]);
          say('GIF file copied');
        }
      case FileMenuAction.copyFiles:
        await clipboard.copyFiles(target.files);
        say(n == 1 ? 'File copied' : '$n files copied');
      case FileMenuAction.copyPath:
        await clipboard.copyText(target.files.join('\n'));
        say(n == 1 ? 'Path copied' : '$n paths copied');
      case FileMenuAction.open:
        await clipboard.open(target.open!);
      case FileMenuAction.openWith:
        await clipboard.openWith(target.open!);
      case FileMenuAction.useAsCover ||
          FileMenuAction.addPreview ||
          FileMenuAction.removePreview:
        if (!packExists(pt!.packPath)) return;
        final next = previewsAfter(choice, pt.file, previews!);
        savePreviews(pt.packPath, next);
        say(switch (choice) {
          FileMenuAction.useAsCover => 'Cover set',
          FileMenuAction.addPreview => 'Added to previews',
          _ =>
            next.isEmpty
                ? 'Previews picked automatically'
                : 'Removed from previews',
        });
        await library.reload();
    }
  } on Object catch (e) {
    say(
      'Could not ${switch (choice) {
        FileMenuAction.open || FileMenuAction.openWith => 'open',
        FileMenuAction.useAsCover || FileMenuAction.addPreview || FileMenuAction.removePreview => 'save',
        _ => 'copy',
      }}: $e',
    );
  }
}

/// [name] as a safe file name: path separators and control characters
/// become `_`.
String gifFileName(String name) {
  final safe = name.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1F]'), '_').trim();
  return safe.isEmpty ? 'animation' : safe;
}

/// Shows the file menu on a right-click anywhere over [child]. [target] is
/// asked at click time (a selection may have changed).
class FileMenuArea extends ConsumerWidget {
  const FileMenuArea({super.key, required this.target, required this.child});

  final FileMenuTarget Function() target;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onSecondaryTapUp: (d) =>
        showFileMenu(context, ref, d.globalPosition, target()),
    child: child,
  );
}
