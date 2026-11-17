import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'reveal_windows.dart';

/// Runs a program and waits for it; [Process.run] outside tests.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// How the UI reveals a file; tests swap it so no file manager opens.
final revealProvider = Provider<Future<void> Function(String path)>(
  (ref) => revealInFileManager,
);

/// Shows [path] selected in the system file manager.
///
/// Linux asks the file manager over D-Bus (`FileManager1.ShowItems`, which
/// Nautilus, Dolphin, Nemo and Thunar answer) and falls back to opening the
/// parent folder when nothing answers. Windows asks the shell directly
/// ([selectInExplorer]) and falls back to `explorer /select,`; macOS uses
/// `open -R`.
Future<void> revealInFileManager(
  String path, {
  ProcessRunner run = Process.run,
  Future<bool> Function(Uri) open = launchUrl,
  String? os,
  bool Function(String path)? selectWindows,
}) async {
  switch (os ?? Platform.operatingSystem) {
    case 'windows':
      final native = p.windows.normalize(path);
      if ((selectWindows ?? selectInExplorer)(native)) return;
      // `/select,` and the path go as separate arguments: Dart quotes an
      // argument with spaces, and explorer ignores a quoted "/select,…"
      // and just opens its home folder. explorer exits with 1 even when it
      // worked; nothing to check.
      await run('explorer', ['/select,', native]);
    case 'macos':
      await run('open', ['-R', path]);
    default:
      try {
        final result = await run('dbus-send', [
          '--session',
          '--print-reply',
          '--dest=org.freedesktop.FileManager1',
          '--type=method_call',
          '/org/freedesktop/FileManager1',
          'org.freedesktop.FileManager1.ShowItems',
          'array:string:${Uri.file(path)}',
          'string:',
        ]);
        if (result.exitCode == 0) return;
      } on ProcessException {
        // No dbus-send; open the folder instead.
      }
      await open(Uri.directory(p.dirname(path)));
  }
}

/// Opens [path] with the system: a folder in the file manager, a file in
/// its default app. Windows gets the plain path ([shellOpen]); a `file:`
/// URL there loses everything after a `#` in the path.
Future<void> openPath(
  String path, {
  Future<bool> Function(Uri) open = launchUrl,
  String? os,
  bool Function(String path)? openWindows,
}) async {
  if ((os ?? Platform.operatingSystem) == 'windows') {
    (openWindows ?? shellOpen)(p.windows.normalize(path));
    return;
  }
  await open(
    FileSystemEntity.isDirectorySync(path)
        ? Uri.directory(path)
        : Uri.file(path),
  );
}

/// Small "show in file manager" button for a file row or card.
class RevealButton extends ConsumerWidget {
  const RevealButton(this.path, {super.key});

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: 'Show in file manager',
    iconSize: 18,
    visualDensity: VisualDensity.compact,
    icon: const Icon(Icons.drive_file_move_outline),
    onPressed: () => ref.read(revealProvider)(path),
  );
}
