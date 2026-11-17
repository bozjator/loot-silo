import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import 'reveal.dart';

/// Files and images on the system clipboard, and opening files in other
/// apps. Text uses Flutter's own [Clipboard]; images and files go through
/// our `loot_silo/clipboard` channel (Linux runner on GTK, macOS runner on
/// NSPasteboard, Windows runner on the Win32 clipboard), so [canCopyFiles]
/// and [canOpenWith] are false elsewhere.
abstract class FileClipboard {
  /// Copy image / Copy file are offered.
  bool get canCopyFiles;

  /// Open with… is offered.
  bool get canOpenWith;

  /// The image at [path] as `image/png` (other formats re-encoded once),
  /// at its own size.
  Future<void> copyImage(String path);

  /// [paths] as files to paste into a file manager (Linux: `text/uri-list`,
  /// `x-special/gnome-copied-files`; macOS: file URLs; Windows: `CF_HDROP`;
  /// and the paths as text); never an image.
  Future<void> copyFiles(List<String> paths);

  Future<void> copyText(String text);

  /// In the default app.
  Future<void> open(String path);

  /// Asks which app; false when none was picked.
  Future<bool> openWith(String path);
}

/// The platform's clipboard; tests swap in a fake.
final fileClipboardProvider = Provider<FileClipboard>(
  (ref) => PlatformFileClipboard(),
);

class PlatformFileClipboard implements FileClipboard {
  PlatformFileClipboard({bool? native})
    : _native =
          native ??
          (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  static const channel = MethodChannel('loot_silo/clipboard');

  /// The runner has the channel.
  final bool _native;

  @override
  bool get canCopyFiles => _native;

  @override
  bool get canOpenWith => _native;

  @override
  Future<void> copyImage(String path) async {
    final png = await Isolate.run(() => pngBytesOf(path));
    if (png == null) throw FormatException('Not an image', path);
    await channel.invokeMethod<void>('copyImage', png);
  }

  @override
  Future<void> copyFiles(List<String> paths) =>
      channel.invokeMethod<void>('copyFiles', {'paths': paths});

  @override
  Future<void> copyText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<void> open(String path) => openPath(path);

  @override
  Future<bool> openWith(String path) async =>
      await channel.invokeMethod<bool>('openWith', path) ?? false;

  /// The clipboard's data for [target] (`image/png`, `text/uri-list` …);
  /// for tests.
  static Future<Uint8List?> read(String target) =>
      channel.invokeMethod<Uint8List>('read', target);

  /// The targets the clipboard offers now; for tests.
  static Future<List<String>> targets() async =>
      (await channel.invokeListMethod<String>('targets')) ?? const [];
}

/// The file's bytes when it is a PNG, else the image decoded and encoded as
/// PNG (first frame of a GIF); null when it isn't an image.
Uint8List? pngBytesOf(String path) {
  final bytes = File(path).readAsBytesSync();
  const signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  var png = bytes.length > signature.length;
  for (var i = 0; png && i < signature.length; i++) {
    png = bytes[i] == signature[i];
  }
  if (png) return bytes;
  final image = img.decodeImage(bytes);
  return image == null ? null : img.encodePng(image);
}
