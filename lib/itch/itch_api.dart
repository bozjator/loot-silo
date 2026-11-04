import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// The author of an itch.io game.
class ItchUser {
  const ItchUser({
    required this.id,
    required this.username,
    this.displayName,
    this.url,
  });

  factory ItchUser.fromJson(Map<String, Object?> json) => ItchUser(
    id: (json['id'] as num?)?.toInt() ?? 0,
    username: json['username'] as String? ?? '',
    displayName: _nonEmpty(json['display_name']),
    url: _nonEmpty(json['url']),
  );

  final int id;
  final String username;
  final String? displayName;
  final String? url;

  String get name => displayName ?? username;
}

class ItchGame {
  const ItchGame({
    required this.id,
    required this.title,
    required this.url,
    required this.user,
    this.coverUrl,
    this.shortText,
    this.classification,
  });

  factory ItchGame.fromJson(Map<String, Object?> json) => ItchGame(
    id: (json['id'] as num).toInt(),
    title: json['title'] as String? ?? '',
    url: json['url'] as String? ?? '',
    user: ItchUser.fromJson(
      (json['user'] as Map?)?.cast<String, Object?>() ?? const {},
    ),
    coverUrl: _nonEmpty(json['cover_url']),
    shortText: _nonEmpty(json['short_text']),
    classification: _nonEmpty(json['classification']),
  );

  final int id;
  final String title;
  final String url;
  final ItchUser user;
  final String? coverUrl;
  final String? shortText;

  /// `assets`, `game`, `tool`, `soundtrack`, …
  final String? classification;
}

/// A purchase or claim: what lets us list and download a game's uploads.
class OwnedKey {
  const OwnedKey({required this.id, required this.game});

  factory OwnedKey.fromJson(Map<String, Object?> json) => OwnedKey(
    id: (json['id'] as num).toInt(),
    game: ItchGame.fromJson((json['game'] as Map).cast<String, Object?>()),
  );

  final int id;
  final ItchGame game;
}

class ItchUpload {
  const ItchUpload({
    required this.id,
    required this.filename,
    this.size = 0,
    this.type,
    this.traits = const [],
  });

  factory ItchUpload.fromJson(Map<String, Object?> json) => ItchUpload(
    id: (json['id'] as num).toInt(),
    filename: json['filename'] as String? ?? 'upload-${json['id']}',
    size: (json['size'] as num?)?.toInt() ?? 0,
    type: _nonEmpty(json['type']),
    // An empty list comes back as `{}`.
    traits: json['traits'] is List
        ? (json['traits'] as List).whereType<String>().toList()
        : const [],
  );

  final int id;
  final String filename;
  final int size;

  /// `default`, `graphical_assets`, `audio_assets`, `documentation`, …
  final String? type;

  /// e.g. `p_windows`, `p_linux`, `p_osx`, `p_android`, `demo`.
  final List<String> traits;

  bool get isPlatformBuild =>
      type == 'executable' || traits.any((t) => t.startsWith('p_'));
}

class ItchApiException implements Exception {
  ItchApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isAuthError => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// Minimal client for the itch.io server-side API (`api.itch.io`).
///
/// The key only ever goes into the Authorization header of API requests;
/// it is never part of a URL, an error message or a CDN request.
class ItchApi {
  ItchApi(this._key, {http.Client? client, Uri? base})
    : _client = client ?? http.Client(),
      _base = base ?? Uri.parse('https://api.itch.io');

  final String _key;
  final http.Client _client;
  final Uri _base;

  Map<String, String> get _auth => {'Authorization': 'Bearer $_key'};

  Future<Map<String, Object?>> _get(
    String path, [
    Map<String, String>? query,
  ]) async {
    final uri = _base.replace(path: path, queryParameters: query);
    final http.Response r;
    try {
      r = await _client.get(uri, headers: _auth);
    } on Object catch (e) {
      throw ItchApiException('itch.io is unreachable: ${_scrub(e)}');
    }
    if (r.statusCode != 200) {
      throw ItchApiException(
        r.statusCode == 401 || r.statusCode == 403
            ? 'itch.io rejected the API key (${r.statusCode})'
            : 'itch.io returned ${r.statusCode} for $path',
        statusCode: r.statusCode,
      );
    }
    final body = jsonDecode(r.body);
    if (body is! Map<String, Object?>) {
      throw ItchApiException('Unexpected response for $path');
    }
    if (body['errors'] case final List errors when errors.isNotEmpty) {
      throw ItchApiException('itch.io: ${errors.join(', ')}');
    }
    return body;
  }

  String _scrub(Object e) => '$e'.replaceAll(_key, '***');

  /// The account the key belongs to.
  Future<ItchUser> profile() async {
    final json = await _get('/profile');
    return ItchUser.fromJson((json['user'] as Map).cast<String, Object?>());
  }

  /// Every owned key, following pages until one comes back empty.
  Future<List<OwnedKey>> ownedKeys({void Function(int fetched)? onPage}) async {
    final out = <OwnedKey>[];
    for (var page = 1; page < 1000; page++) {
      final json = await _get('/profile/owned-keys', {'page': '$page'});
      final keys = json['owned_keys'];
      // An empty page is `{}` rather than `[]`.
      if (keys is! List || keys.isEmpty) break;
      out.addAll([
        for (final k in keys.whereType<Map>())
          if (k['game'] is Map) OwnedKey.fromJson(k.cast<String, Object?>()),
      ]);
      onPage?.call(out.length);
      final perPage = (json['per_page'] as num?)?.toInt();
      if (perPage != null && keys.length < perPage) break;
    }
    return out;
  }

  Future<List<ItchUpload>> uploads(OwnedKey key) async {
    final json = await _get('/games/${key.game.id}/uploads', {
      'download_key_id': '${key.id}',
    });
    final list = json['uploads'];
    return list is List
        ? [
            for (final u in list.whereType<Map>())
              ItchUpload.fromJson(u.cast<String, Object?>()),
          ]
        : const [];
  }

  /// Downloads [upload] to [target]. The API answers with a redirect to a
  /// storage mirror, which is fetched without the Authorization header.
  Future<void> download(
    OwnedKey key,
    ItchUpload upload,
    File target, {
    void Function(int received, int total)? onProgress,
  }) async {
    final request =
        http.Request(
            'GET',
            _base.replace(
              path: '/uploads/${upload.id}/download',
              queryParameters: {'download_key_id': '${key.id}'},
            ),
          )
          ..followRedirects = false
          ..headers.addAll(_auth);
    var response = await _client.send(request);
    if (response.isRedirect || response.statusCode == 302) {
      final location = response.headers['location'];
      await response.stream.drain<void>();
      if (location == null) {
        throw ItchApiException('No download location for ${upload.filename}');
      }
      response = await _client.send(http.Request('GET', Uri.parse(location)));
    }
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw ItchApiException(
        'Download of ${upload.filename} failed (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }
    final total = response.contentLength ?? upload.size;
    target.parent.createSync(recursive: true);
    final sink = target.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
    }
    if (upload.size > 0 && received != upload.size) {
      throw ItchApiException(
        'Download of ${upload.filename} is incomplete '
        '($received of ${upload.size} bytes)',
      );
    }
  }

  /// Plain GET for public pages and images (no key).
  Future<http.Response> fetchPublic(Uri uri) => _client.get(uri);

  void close() => _client.close();
}

String? _nonEmpty(Object? v) => v is String && v.isNotEmpty ? v : null;
