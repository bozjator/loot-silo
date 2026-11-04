import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// Runs a program and waits for it; [Process.run] outside tests.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

/// Shows [path] selected in the system file manager.
///
/// Linux asks the file manager over D-Bus (`FileManager1.ShowItems`, which
/// Nautilus, Dolphin, Nemo and Thunar answer) and falls back to opening the
/// parent folder when nothing answers. Windows uses `explorer /select,` and
/// macOS `open -R`.
Future<void> revealInFileManager(
  String path, {
  ProcessRunner run = Process.run,
  Future<bool> Function(Uri) open = launchUrl,
  String? os,
}) async {
  switch (os ?? Platform.operatingSystem) {
    case 'windows':
      // explorer exits with 1 even when it worked; nothing to check.
      await run('explorer', ['/select,${p.windows.normalize(path)}']);
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
