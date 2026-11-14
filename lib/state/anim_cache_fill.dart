import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/library_index.dart';
import '../core/pack_editor.dart';
import 'providers.dart';

/// Fills the animation cache (M94) for packs whose cache is missing or
/// stale, one pack at a time in a background isolate, largest first, so
/// that pack pages open without decoding sprite sheets.
class AnimCacheFiller {
  AnimCacheFiller(this.index, {this.pause = const Duration(milliseconds: 200)});

  final LibraryIndex index;

  /// Rest between packs, so the fill never keeps a core busy for long.
  final Duration pause;

  /// Off under `flutter test` (widget tests run on fake time); integration
  /// tests switch it as they need.
  @visibleForTesting
  static var enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  /// How long after the library loads the fill starts.
  static const startDelay = Duration(seconds: 10);

  var _cancelled = false;
  bool get cancelled => _cancelled;

  /// Stops after the pack being detected (the library changed, or the app
  /// closes).
  void cancel() => _cancelled = true;

  /// Detects the animations of every pack of [packs] whose cache doesn't
  /// match it any more and stores them; returns the ids it detected.
  /// A pack opened meanwhile has stored its own entry, so it is skipped.
  Future<List<String>> fill(List<PackRow> packs) async {
    final done = <String>[];
    final order = [...packs]
      ..sort((a, b) => b.fileCount.compareTo(a.fileCount));
    for (final pk in order) {
      if (_cancelled) break;
      try {
        final files = await index.filesWithSizes(pk.id);
        final cached = await index.animCache(pk.id);
        final fresh = await _staleInBackground(pk.path, files, cached);
        if (_cancelled) break;
        if (fresh != null) {
          await index.putAnimCache(pk.id, fresh.signature, fresh.json);
          done.add(pk.id);
        }
      } on Object {
        // A pack that can't be read (moved, unmounted) waits for its page.
      }
      if (pause > Duration.zero) await Future<void>.delayed(pause);
    }
    return done;
  }
}

Future<AnimCache?> _staleInBackground(
  String path,
  List<(String, int)> files,
  AnimCache? cached,
) => Isolate.run(() => _detectIfStale(path, files, cached));

AnimCache? _detectIfStale(
  String path,
  List<(String, int)> files,
  AnimCache? cached,
) => loadPackContentsCached(path, files, cached: cached).fresh;

/// Runs an [AnimCacheFiller] [AnimCacheFiller.startDelay] after the library
/// loads; a new load (rescan, another library) or closing the app cancels
/// it. Watched by the app.
final animCacheFillProvider = Provider<void>((ref) {
  final library = ref.watch(libraryProvider).value;
  if (!AnimCacheFiller.enabled || library == null || library.packs.isEmpty) {
    return;
  }
  final filler = AnimCacheFiller(ref.read(libraryIndexProvider));
  ref.onDispose(filler.cancel);
  Future<void>.delayed(AnimCacheFiller.startDelay, () {
    if (!filler.cancelled) filler.fill(library.packs);
  });
});
