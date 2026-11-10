import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../core/library_index.dart';
import '../itch/itch_api.dart';
import '../itch/itch_key.dart';
import '../itch/itch_matcher.dart';
import '../itch/itch_sync.dart';
import 'providers.dart';

/// Where the itch API key is kept between runs.
abstract class KeyStore {
  Future<String?> read();
  Future<void> write(String key);
  Future<void> delete();
}

/// The OS keychain (libsecret on Linux, Keychain on macOS, DPAPI on
/// Windows).
class SecureKeyStore implements KeyStore {
  static const _name = 'itch_api_key';
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> read() => _storage.read(key: _name);

  @override
  Future<void> write(String key) => _storage.write(key: _name, value: key);

  @override
  Future<void> delete() => _storage.delete(key: _name);
}

final keyStoreProvider = Provider<KeyStore>((ref) => SecureKeyStore());

/// Development fallback for the key (env var / `.env`); off in tests.
final envKeyProvider = Provider<String? Function()>(
  (ref) => keyFromEnvironment,
);

/// Builds the API client; swapped for a mock in tests.
final itchApiFactoryProvider = Provider<ItchApi Function(String key)>(
  (ref) => ItchApi.new,
);

/// The itch key: saved key first, then the development fallbacks.
/// `null` means "not connected" and the itch UI shows a connect hint.
class ItchKeyNotifier extends AsyncNotifier<String?> {
  /// Set when the keychain could not be used; the key then lives only in
  /// memory for this run.
  String? storageProblem;

  @override
  Future<String?> build() async {
    try {
      final saved = await ref.read(keyStoreProvider).read();
      if (saved != null && saved.isNotEmpty) return saved;
    } on Object catch (e) {
      storageProblem = '$e';
    }
    return ref.read(envKeyProvider)();
  }

  /// Checks [key] against itch.io and keeps it. Throws [ItchApiException]
  /// when itch.io rejects it.
  Future<void> connect(String key) async {
    final trimmed = key.trim();
    final api = ref.read(itchApiFactoryProvider)(trimmed);
    try {
      await api.profile();
    } finally {
      api.close();
    }
    try {
      await ref.read(keyStoreProvider).write(trimmed);
      storageProblem = null;
    } on Object catch (e) {
      storageProblem = '$e';
    }
    state = AsyncData(trimmed);
  }

  Future<void> disconnect() async {
    try {
      await ref.read(keyStoreProvider).delete();
    } on Object {
      // Nothing saved, or no keychain: forgetting it in memory is enough.
    }
    state = const AsyncData(null);
  }
}

final itchKeyProvider = AsyncNotifierProvider<ItchKeyNotifier, String?>(
  ItchKeyNotifier.new,
);

class ItchAccount {
  const ItchAccount(this.user, this.keys);

  final ItchUser user;
  final List<OwnedKey> keys;
}

/// The signed-in account and its owned keys; refetch with
/// `ref.invalidate(itchAccountProvider)`.
final itchAccountProvider = FutureProvider<ItchAccount?>((ref) async {
  final key = await ref.watch(itchKeyProvider.future);
  if (key == null) return null;
  final api = ref.read(itchApiFactoryProvider)(key);
  try {
    final user = await api.profile();
    final keys = await api.ownedKeys();
    return ItchAccount(user, keys);
  } finally {
    api.close();
  }
});

/// Owned keys matched against the current library.
final itchMatchesProvider = FutureProvider<List<ItchMatch>>((ref) async {
  final account = await ref.watch(itchAccountProvider.future);
  if (account == null) return const [];
  final library = await ref.watch(libraryProvider.future);
  final folders = await ref.read(libraryIndexProvider).folderNames();
  return matchOwnedKeys(account.keys, library.packs, folders: folders);
});

/// Progress of one game's download or link.
class ItchJob {
  const ItchJob(this.status, {this.progress, this.error, this.done = false});

  final String status;
  final double? progress;
  final String? error;
  final bool done;
}

/// Runs downloads one after another and links on demand, keyed by game id.
class ItchJobsNotifier extends Notifier<Map<int, ItchJob>> {
  final _queue = <OwnedKey>[];
  var _running = false;

  @override
  Map<int, ItchJob> build() => const {};

  void _set(int gameId, ItchJob job) => state = {...state, gameId: job};

  /// Queues downloads; each finished install triggers a library reload.
  void download(Iterable<OwnedKey> keys) {
    for (final k in keys) {
      final job = state[k.game.id];
      if (job != null && (job.error == null)) continue;
      _queue.add(k);
      _set(k.game.id, const ItchJob('Waiting'));
    }
    _run();
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final k = _queue.removeAt(0);
        final key = ref.read(itchKeyProvider).value;
        final root = ref.read(libraryProvider).value?.root;
        if (key == null || root == null) {
          _set(k.game.id, const ItchJob('Not connected', error: 'no key'));
          continue;
        }
        final api = ref.read(itchApiFactoryProvider)(key);
        try {
          final result = await installItchGame(
            api,
            k,
            libraryRoot: root,
            workRoot: itchWorkRoot(ref.read(extractRootProvider)),
            onStatus: (s, progress) =>
                _set(k.game.id, ItchJob(s, progress: progress)),
          );
          _set(
            k.game.id,
            result.ok
                ? ItchJob('Installed in ${result.target}', done: true)
                : ItchJob('Failed', error: result.error),
          );
          if (result.ok) await ref.read(libraryProvider.notifier).reload();
        } finally {
          api.close();
        }
      }
    } finally {
      _running = false;
    }
  }

  /// Writes the itch id into [pack]'s sidecar and fetches its media,
  /// then reloads the library unless [reload] is false.
  Future<void> link(OwnedKey k, PackRow pack, {bool reload = true}) async {
    final key = ref.read(itchKeyProvider).value;
    if (key == null) return;
    _set(k.game.id, const ItchJob('Linking'));
    final api = ref.read(itchApiFactoryProvider)(key);
    try {
      linkPack(pack.path, k.game);
      await fetchItchMedia(api, pack.path, k.game);
      _set(k.game.id, ItchJob('Linked to ${pack.title}', done: true));
      if (reload) await ref.read(libraryProvider.notifier).reload();
    } on Object catch (e) {
      _set(k.game.id, ItchJob('Failed', error: '$e'));
    } finally {
      api.close();
    }
  }

  /// Links several matches, then reloads the library once.
  Future<void> linkAll(Iterable<ItchMatch> matches) async {
    for (final m in matches) {
      if (m.pack != null) await link(m.key, m.pack!, reload: false);
    }
    await ref.read(libraryProvider.notifier).reload();
  }
}

final itchJobsProvider = NotifierProvider<ItchJobsNotifier, Map<int, ItchJob>>(
  ItchJobsNotifier.new,
);

/// Where itch.io downloads are unpacked before they are copied into the
/// library (one folder per install, deleted when it ends; emptied on start).
String itchWorkRoot(String extractRoot) => p.join(extractRoot, 'itch');
