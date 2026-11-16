import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

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

/// Starts the one SoLoud engine on first use. Never shut down: it lives
/// until the app exits. A failed start is tried again on the next play.
Future<void>? _engineStart;
Future<void> _engine() {
  if (SoLoud.instance.isInitialized) return Future.value();
  return _engineStart ??= SoLoud.instance.init().whenComplete(
    () => _engineStart = null,
  );
}

/// Files up to this size are decoded into memory (instant, exact seeks);
/// larger ones (music) are streamed from disk, which keeps a long track
/// from taking hundreds of MB once decoded.
const _memoryLoadBytes = 4 << 20;

/// A loaded file, shared by the players using it: SoLoud keeps one source
/// per path, so a second load of a path returns the first one.
class _Shared {
  _Shared(this.source);
  final Future<AudioSource> source;
  var users = 1;
}

final _sources = <String, _Shared>{};

/// Disposals still running, by path: a new load waits for them, or SoLoud
/// would hand back the source being disposed.
final _disposing = <String, Future<void>>{};

Future<AudioSource> _acquire(String path) {
  final shared = _sources[path];
  if (shared != null) {
    shared.users++;
    return shared.source;
  }
  Future<AudioSource> load() async {
    await _disposing[path];
    final big = await File(path).length() > _memoryLoadBytes;
    return SoLoud.instance.loadFile(
      path,
      mode: big ? LoadMode.disk : LoadMode.memory,
    );
  }

  final entry = _Shared(load());
  _sources[path] = entry;
  // A failed load is forgotten, so the next play tries again.
  entry.source.then<void>(
    (_) {},
    onError: (Object _) {
      if (identical(_sources[path], entry)) _sources.remove(path);
    },
  );
  return entry.source;
}

void _releaseSource(String path) {
  final shared = _sources[path];
  if (shared == null || --shared.users > 0) return;
  _sources.remove(path);
  late final Future<void> done;
  done = () async {
    try {
      final source = await shared.source;
      if (SoLoud.instance.isInitialized) {
        await SoLoud.instance.disposeSource(source);
      }
    } on Object {
      // Never loaded, or already gone with the engine.
    } finally {
      if (identical(_disposing[path], done)) _disposing.remove(path);
    }
  }();
  _disposing[path] = done;
}

/// [TrackPlayer] on top of SoLoud, which decodes every format itself
/// (Ogg Vorbis/Opus, FLAC, MP3, WAV) instead of leaving it to the OS:
/// Windows' Media Foundation can't open Ogg in a desktop app.
///
/// SoLoud has no player objects or event streams: a file is loaded as a
/// source and played as a voice ([SoundHandle]). Position is polled while
/// a voice plays; the end comes from the source's events.
class SoloudTrackPlayer implements TrackPlayer {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _complete = StreamController<void>.broadcast();

  /// The file loaded for this player, and its source once loaded.
  String? _path;
  AudioSource? _source;
  StreamSubscription<void>? _events;

  /// The playing voice; null when stopped or ended.
  SoundHandle? _handle;
  Timer? _ticker;
  var _loop = false;

  /// Bumped by every play and stop, so a play still loading gives up when
  /// a newer call came meanwhile.
  var _run = 0;

  static const _tick = Duration(milliseconds: 33);

  @override
  Future<void> play(String path) async {
    final run = ++_run;
    await _stopVoice();
    await _engine();
    if (run != _run) return;
    var source = _source;
    if (_path != path || source == null) {
      _unload();
      _path = path;
      try {
        source = await _acquire(path);
      } on Object {
        // Still ours (no newer play unloaded it): let go of it here.
        if (_path == path) {
          _path = null;
          _releaseSource(path);
        }
        rethrow;
      }
      // Another play or stop came while loading; it released this path.
      if (run != _run || _path != path) return;
      _source = source;
      _events = source.soundEvents.listen((e) {
        if (e.event == SoundEventType.handleIsNoMoreValid &&
            e.handle == _handle) {
          _ended();
        }
      });
    }
    final handle = SoLoud.instance.play(source, looping: _loop);
    _handle = handle;
    _duration.add(SoLoud.instance.getLength(source));
    _position.add(Duration.zero);
    _ticker = Timer.periodic(_tick, (_) => _report());
  }

  /// The voice reached its end (a looping voice never does).
  void _ended() {
    _handle = null;
    _ticker?.cancel();
    _ticker = null;
    final source = _source;
    if (source != null && SoLoud.instance.isInitialized) {
      _position.add(SoLoud.instance.getLength(source));
    }
    _complete.add(null);
  }

  /// The voice still playing, if any.
  SoundHandle? get _live {
    final handle = _handle;
    if (handle == null || !SoLoud.instance.isInitialized) return null;
    return SoLoud.instance.getIsValidVoiceHandle(handle) ? handle : null;
  }

  void _report() {
    final handle = _live;
    if (handle != null) _position.add(SoLoud.instance.getPosition(handle));
  }

  /// Stops the voice; no completion is reported for it.
  Future<void> _stopVoice() async {
    _ticker?.cancel();
    _ticker = null;
    final handle = _live;
    _handle = null;
    if (handle != null) await SoLoud.instance.stop(handle);
  }

  /// Lets go of the loaded file.
  void _unload() {
    _events?.cancel();
    _events = null;
    _source = null;
    final path = _path;
    _path = null;
    if (path != null) _releaseSource(path);
  }

  @override
  Future<void> stop() {
    _run++;
    return _stopVoice();
  }

  @override
  Future<void> seek(Duration position) async {
    final handle = _live;
    if (handle != null) SoLoud.instance.seek(handle, position);
  }

  @override
  Future<void> setLoop(bool loop) async {
    _loop = loop;
    final handle = _live;
    if (handle != null) SoLoud.instance.setLooping(handle, loop);
  }

  @override
  bool get looping => _loop;
  @override
  Stream<Duration> get onPosition => _position.stream;
  @override
  Stream<Duration> get onDuration => _duration.stream;
  @override
  Stream<void> get onComplete => _complete.stream;

  @override
  Future<void> dispose() async {
    _run++;
    await _stopVoice();
    _unload();
    await Future.wait([
      _position.close(),
      _duration.close(),
      _complete.close(),
    ]);
  }
}

/// Makes the Audio tab's player, on first play.
final trackPlayerFactoryProvider = Provider<TrackPlayer Function()>(
  (ref) => SoloudTrackPlayer.new,
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
