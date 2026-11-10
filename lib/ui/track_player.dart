import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

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

/// Paths asked for in this microtask, read together by [_flush].
List<(String, Completer<AudioInfo?>)>? _pending;

/// Most isolates one batch is split over (the reads are file IO and a
/// little parsing; a few in parallel are enough).
const _maxIsolates = 4;

/// Requests made in the same microtask (a frame's rows, or a sort reading
/// a whole tab) share isolates instead of starting one per file.
Future<AudioInfo?> _readInIsolate(String path) {
  final c = Completer<AudioInfo?>();
  (_pending ??= []).add((path, c));
  // One flush per request: the first takes the whole batch, the others
  // find it gone (and none is left waiting on a microtask that never ran).
  scheduleMicrotask(_flush);
  return c.future;
}

/// Top level, so the isolate's closure captures only [paths] (a closure
/// in [_flush] would carry the completers along, which can't be sent).
Future<List<AudioInfo?>> _readAll(List<String> paths) =>
    Isolate.run(() => [for (final path in paths) audioInfo(path)]);

void _flush() {
  final batch = _pending;
  if (batch == null) return;
  _pending = null;
  final per = math.max(16, (batch.length / _maxIsolates).ceil());
  for (var start = 0; start < batch.length; start += per) {
    final part = batch.sublist(start, math.min(start + per, batch.length));
    final paths = [for (final (path, _) in part) path];
    _readAll(paths).then(
      (infos) {
        for (var i = 0; i < part.length; i++) {
          part[i].$2.complete(infos[i]);
        }
      },
      onError: (Object _) {
        for (final (_, c) in part) {
          c.complete(null);
        }
      },
    );
  }
}

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

/// The one sound playing in the app. Whoever starts a sound claims it;
/// the previous owner's stop callback runs, so a sound elsewhere (another
/// pack tab) ends.
class NowPlaying {
  Object? _owner;
  void Function()? _stop;

  /// [owner] starts a sound; [stop] ends it when another owner claims.
  void claim(Object owner, void Function() stop) {
    final previous = identical(_owner, owner) ? null : _stop;
    _owner = owner;
    _stop = stop;
    previous?.call();
  }

  /// [owner]'s sound ended (or it went away).
  void release(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _stop = null;
  }

  /// Whether [owner] holds the sound.
  bool owns(Object owner) => identical(_owner, owner);

  /// Whether anything holds the sound.
  bool get playing => _owner != null;
}

/// The app's [NowPlaying].
final nowPlayingProvider = Provider<NowPlaying>((ref) => NowPlaying());
