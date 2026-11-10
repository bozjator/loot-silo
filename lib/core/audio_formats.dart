import 'package:path/path.dart' as p;

import 'audio_duration.dart' show AudioInfo;

/// Audio formats in the order a track picks one when the preferred format
/// is missing: lossless and open formats first.
const audioFormatOrder = ['ogg', 'wav', 'flac', 'opus', 'mp3', 'm4a', 'aiff'];

/// A folder that only sorts files by format (`MP3/`, `ogg`, `WAV files`).
final _formatFolder = RegExp(
  r'^(ogg|wave?|flac|opus|mp3|m4a|aiff?)([ _-]?(files?|format|versions?))?$',
  caseSensitive: false,
);

/// One sound, saved in one or more formats.
class AudioTrack {
  AudioTrack(this.key, this.files);

  /// What its files share: the path without the extension and without
  /// format folders, lowercased.
  final String key;

  /// Pack-relative paths, one per format, in [audioFormatOrder].
  final List<String> files;

  /// The track's folder with the format folders left out; '.' at the top.
  String get folder {
    final parts = p.split(p.dirname(files.first));
    final kept = [
      for (final s in parts)
        if (s != '.' && !_formatFolder.hasMatch(s)) s,
    ];
    return kept.isEmpty ? '.' : p.joinAll(kept);
  }

  /// The file in [preferred] format, else the first in [audioFormatOrder].
  String pick(String preferred) => files.firstWhere(
    (f) => formatOf(f) == preferred,
    orElse: () => files.first,
  );
}

/// The lowercase extension without the dot: `ogg`.
String formatOf(String rel) {
  final ext = p.extension(rel);
  return ext.isEmpty ? '' : ext.substring(1).toLowerCase();
}

String _keyOf(String rel) {
  final parts = p.split(p.withoutExtension(rel));
  return [
    for (var i = 0; i < parts.length; i++)
      if (i == parts.length - 1 || !_formatFolder.hasMatch(parts[i])) parts[i],
  ].join('/').toLowerCase();
}

int _rank(String rel) {
  final i = audioFormatOrder.indexOf(formatOf(rel));
  return i < 0 ? audioFormatOrder.length : i;
}

/// [audio] (pack-relative paths) as tracks: files that differ only in
/// their extension, or in a format folder (`MP3/a.mp3`, `OGG/a.ogg`), are
/// one track. Tracks keep the order of their first file in [audio].
List<AudioTrack> groupAudioFormats(List<String> audio) {
  final byKey = <String, List<String>>{};
  for (final rel in audio) {
    final files = byKey.putIfAbsent(_keyOf(rel), () => []);
    // Two files of one format (`a.ogg`, `A.OGG`) stay apart.
    if (files.any((f) => formatOf(f) == formatOf(rel))) {
      byKey.putIfAbsent(rel.toLowerCase(), () => []).add(rel);
    } else {
      files.add(rel);
    }
  }
  return [
    for (final MapEntry(:key, :value) in byKey.entries)
      AudioTrack(key, value..sort((a, b) => _rank(a) - _rank(b))),
  ];
}

/// What the Audio tab sorts its tracks by.
enum AudioSort {
  name('Name'),
  duration('Duration'),
  size('File size'),
  sampleRate('Sample rate'),
  channels('Channels'),
  bitrate('Bitrate'),
  bitDepth('Bit depth');

  const AudioSort(this.label);
  final String label;

  /// Sorting by it needs each track's header ([AudioInfo]).
  bool get needsInfo => this != name && this != size;

  /// One of the details the list's Details column shows.
  bool get isDetail => index >= sampleRate.index;
}

/// [tracks] sorted by [key] of the file each one shows ([fileOf]); with
/// [AudioSort.name] they keep their order (reversed when [descending]).
/// Tracks without the value go last in both directions; ties keep their
/// order. [sizeOf] gives a file's size, [infoOf] its header if read.
List<AudioTrack> sortAudioTracks(
  List<AudioTrack> tracks,
  AudioSort key, {
  required bool descending,
  required String Function(AudioTrack) fileOf,
  required int? Function(String) sizeOf,
  required AudioInfo? Function(String) infoOf,
}) {
  if (key == AudioSort.name) {
    return descending ? tracks.reversed.toList() : [...tracks];
  }
  num? valueOf(AudioTrack t) {
    final rel = fileOf(t);
    if (key == AudioSort.size) return sizeOf(rel);
    final info = infoOf(rel);
    final v = switch (key) {
      AudioSort.duration => info?.duration?.inMicroseconds,
      AudioSort.sampleRate => info?.sampleRate,
      AudioSort.channels => info?.channels,
      AudioSort.bitrate => info?.kbps,
      AudioSort.bitDepth => info?.bitDepth,
      AudioSort.name || AudioSort.size => null,
    };
    return v == null || v <= 0 ? null : v;
  }

  final keyed = [
    for (var i = 0; i < tracks.length; i++) (i, valueOf(tracks[i])),
  ];
  keyed.sort((a, b) {
    final (ai, av) = a;
    final (bi, bv) = b;
    if (av == null || bv == null) {
      if (av != null) return -1;
      if (bv != null) return 1;
      return ai - bi;
    }
    final c = descending ? bv.compareTo(av) : av.compareTo(bv);
    return c != 0 ? c : ai - bi;
  });
  return [for (final (i, _) in keyed) tracks[i]];
}
