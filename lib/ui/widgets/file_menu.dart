import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:path/path.dart' as p;

import '../../state/providers.dart';
import '../clipboard.dart';

/// What a right-click on a file card or row acts on.
class FileMenuTarget {
  const FileMenuTarget({required this.files, this.image, this.open, this.gif});

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
}

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
};

/// The items [target] gets on this platform: only what applies, never
/// greyed out. Nothing that a card's own icons already do (star, select,
/// reveal, open in a viewer) and no Play / Stop.
List<FileMenuAction> fileMenuActions(
  FileMenuTarget target,
  FileClipboard clipboard,
) => [
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
  final actions = fileMenuActions(target, clipboard);
  if (actions.isEmpty) return;
  final n = target.files.length;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final choice = await showMenu<FileMenuAction>(
    context: context,
    position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
    items: [
      for (final a in actions)
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
            }),
            title: Text(fileMenuLabel(a, n)),
          ),
        ),
    ],
  );
  if (choice == null) return;
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
    }
  } on Object catch (e) {
    say(
      'Could not ${choice == FileMenuAction.open || choice == FileMenuAction.openWith ? 'open' : 'copy'}: $e',
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
