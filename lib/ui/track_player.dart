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
///
/// Looping fix: audioplayers handles every completion event by marking the
/// player completed and stopping its position updater. The Linux plugin
/// sends one per loop pass while the sound keeps playing, so after the
/// first pass no position events came and the seek bar froze at the start.
/// This player owns the updater and starts it again (and marks the player
/// playing) after a pass ends while looping.
class AudioplayersTrackPlayer implements TrackPlayer {
  AudioplayersTrackPlayer() {
    _player.positionUpdater = _updater;
    // Subscribed after the player's own handler, so this runs after it.
    _loopPass = _player.onPlayerComplete.listen((_) {
      if (!looping) return;
      _player.state = PlayerState.playing;
      _updater.start();
    });
  }

  final _player = AudioPlayer();
  late final _updater = FramePositionUpdater(
    getPosition: _player.getCurrentPosition,
  );
  late final StreamSubscription<void> _loopPass;

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
  Future<void> dispose() async {
    await _loopPass.cancel();
    await _player.dispose();
  }
}

/// Makes the Audio tab's player, on first play.
final trackPlayerFactoryProvider = Provider<TrackPlayer Function()>(
  (ref) => AudioplayersTrackPlayer.new,
);

/// Header infos by absolute path, kept for the session. Null values
/// (unknown format) are cached too.
final _infos = <String, Future<AudioInfo?>>{};

Future<AudioInfo?> _readInIsolate(String path) =>
    Isolate.run(() => audioInfo(path));

/// Reads an audio file's header ([AudioInfo]: length, rate, channels, bit
/// depth or bitrate) off the UI thread, once per path.
final audioInfoProvider = Provider<Future<AudioInfo?> Function(String)>(
  (ref) =>
      (path) => _infos.putIfAbsent(path, () => _readInIsolate(path)),
);

/// Reads an audio file's length off the UI thread, once per path (from
/// the same header read as [audioInfoProvider]).
final audioDurationProvider = Provider<Future<Duration?> Function(String)>((
  ref,
) {
  final read = ref.watch(audioInfoProvider);
  return (path) => read(path).then((info) => info?.duration);
});
