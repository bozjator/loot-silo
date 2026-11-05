import 'dart:async';
import 'dart:isolate';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/audio_duration.dart';

/// What the Audio tab needs from a player; tests swap in a fake.
abstract interface class TrackPlayer {
  Future<void> play(String path);
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setLoop(bool loop);
  bool get looping;
  Stream<Duration> get onPosition;
  Stream<Duration> get onDuration;
  Stream<void> get onComplete;
  Future<void> dispose();
}

/// [TrackPlayer] on top of audioplayers.
class AudioplayersTrackPlayer implements TrackPlayer {
  final _player = AudioPlayer();

  @override
  Future<void> play(String path) => _player.play(DeviceFileSource(path));
  @override
  Future<void> stop() => _player.stop();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setLoop(bool loop) =>
      _player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.release);
  @override
  bool get looping => _player.releaseMode == ReleaseMode.loop;
  @override
  Stream<Duration> get onPosition => _player.onPositionChanged;
  @override
  Stream<Duration> get onDuration => _player.onDurationChanged;
  @override
  Stream<void> get onComplete => _player.onPlayerComplete;
  @override
  Future<void> dispose() => _player.dispose();
}

/// Makes the Audio tab's player, on first play.
final trackPlayerFactoryProvider = Provider<TrackPlayer Function()>(
  (ref) => AudioplayersTrackPlayer.new,
);

/// Header durations by absolute path, kept for the session. Null values
/// (unknown format) are cached too.
final _durations = <String, Future<Duration?>>{};

Future<Duration?> _readInIsolate(String path) =>
    Isolate.run(() => audioDuration(path));

/// Reads an audio file's length off the UI thread, once per path.
final audioDurationProvider = Provider<Future<Duration?> Function(String)>(
  (ref) =>
      (path) => _durations.putIfAbsent(path, () => _readInIsolate(path)),
);
