import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:url_launcher/url_launcher.dart';

/// Files and images on the system clipboard, and opening files in other
/// apps. Text uses Flutter's own [Clipboard]; images and files go through
/// our `loot_silo/clipboard` channel (Linux runner, GTK), so [canCopyFiles]
/// and [canOpenWith] are false elsewhere.
abstract class FileClipboard {
  /// Copy image / Copy file are offered.
  bool get canCopyFiles;

  /// Open with… is offered.
  bool get canOpenWith;

  /// The image at [path] as `image/png` (other formats re-encoded once),
  /// at its own size.
  Future<void> copyImage(String path);

  /// [paths] as files to paste into a file manager (`text/uri-list`,
  /// `x-special/gnome-copied-files`, the paths as text); plus [bytes] as
  /// [mime] when given.
  Future<void> copyFiles(List<String> paths, {String? mime, Uint8List? bytes});

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
  PlatformFileClipboard({bool? linux}) : _linux = linux ?? Platform.isLinux;

  static const channel = MethodChannel('loot_silo/clipboard');
  final bool _linux;

  @override
  bool get canCopyFiles => _linux;

  @override
  bool get canOpenWith => _linux;

  @override
  Future<void> copyImage(String path) async {
    final png = await Isolate.run(() => pngBytesOf(path));
    if (png == null) throw FormatException('Not an image', path);
    await channel.invokeMethod<void>('copyImage', png);
  }

  @override
  Future<void> copyFiles(
    List<String> paths, {
    String? mime,
    Uint8List? bytes,
  }) => channel.invokeMethod<void>('copyFiles', {
    'paths': paths,
    'mime': ?mime,
    'bytes': ?bytes,
  });

  @override
  Future<void> copyText(String text) =>
      Clipboard.setData(ClipboardData(text: text));

  @override
  Future<void> open(String path) => launchUrl(Uri.file(path));

  @override
  Future<bool> openWith(String path) async =>
      await channel.invokeMethod<bool>('openWith', path) ?? false;

  /// The clipboard's data for [target] (`image/png`, `text/uri-list` …);
  /// for tests.
  static Future<Uint8List?> read(String target) =>
      channel.invokeMethod<Uint8List>('read', target);
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
