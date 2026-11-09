import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../clipboard.dart';

/// What a right-click on a file card or row acts on.
class FileMenuTarget {
  const FileMenuTarget({required this.files, this.image, this.open});

  /// Absolute paths for Copy file and Copy path (a selection, or a
  /// material's maps).
  final List<String> files;

  /// The image file for Copy image (images and animations); null: no item.
  final String? image;

  /// The file for Open and Open with…; null: no items (several files).
  final String? open;
}

/// The menu's items, in the order they show.
enum FileMenuAction { copyImage, copyFiles, copyPath, open, openWith }

/// The items [target] gets on this platform: only what applies, never
/// greyed out. Nothing that a card's own icons already do (star, select,
/// reveal, open in a viewer) and no Play / Stop.
List<FileMenuAction> fileMenuActions(
  FileMenuTarget target,
  FileClipboard clipboard,
) => [
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
              FileMenuAction.copyFiles => Icons.file_copy_outlined,
              FileMenuAction.copyPath => Icons.link,
              FileMenuAction.open => Icons.open_in_new,
              FileMenuAction.openWith => Icons.apps,
            }),
            title: Text(switch (a) {
              FileMenuAction.copyImage => 'Copy image',
              FileMenuAction.copyFiles =>
                n == 1 ? 'Copy file' : 'Copy $n files',
              FileMenuAction.copyPath => n == 1 ? 'Copy path' : 'Copy $n paths',
              FileMenuAction.open => 'Open',
              FileMenuAction.openWith => 'Open with…',
            }),
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
