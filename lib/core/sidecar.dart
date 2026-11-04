import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const authorFileName = 'ASSET_AUTHOR.txt';
const packFileName = 'asset_pack.json';

/// Contents of an `ASSET_AUTHOR.txt` file.
///
/// The format is `key: value` per line. `user` and `url` are the original
/// keys; `itch_user` and `license` were added by the app. Unknown keys are
/// kept so a round trip never loses information.
class AuthorInfo {
  const AuthorInfo({
    required this.user,
    this.url,
    this.itchUser,
    this.license,
    this.extra = const {},
  });

  final String user;
  final String? url;
  final String? itchUser;
  final String? license;
  final Map<String, String> extra;

  static final _line = RegExp(r'^\s*([A-Za-z_][\w-]*)\s*:\s*(.*?)\s*$');
  static final _itchHost = RegExp(r'^([a-z0-9-]+)\.itch\.io$');

  /// Parses author text; returns null when there is no `user` line.
  static AuthorInfo? parse(String text) {
    final values = <String, String>{};
    for (final line in const LineSplitter().convert(text)) {
      final m = _line.firstMatch(line);
      if (m == null || m.group(2)!.isEmpty) continue;
      values.putIfAbsent(m.group(1)!.toLowerCase(), () => m.group(2)!);
    }
    final user = values.remove('user');
    if (user == null) return null;
    return AuthorInfo(
      user: user,
      url: values.remove('url'),
      itchUser: values.remove('itch_user'),
      license: values.remove('license'),
      extra: values,
    );
  }

  static AuthorInfo? read(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    return parse(f.readAsStringSync());
  }

  /// Exact credit wording the author asks for, when it differs from [user].
  String? get credit => extra['credit'];

  /// `required`, `optional` or `unknown` (from the license, when known).
  String? get attribution => extra['attribution'];

  /// Copy with new values; an empty string removes that key.
  AuthorInfo copyWith({
    String? url,
    String? license,
    String? credit,
    String? attribution,
  }) {
    String? pick(String? next, String? old) =>
        next == null ? old : (next.trim().isEmpty ? null : next.trim());
    final extra = {...this.extra};
    void put(String key, String? next) {
      if (next == null) return;
      if (next.trim().isEmpty) {
        extra.remove(key);
      } else {
        extra[key] = next.trim();
      }
    }

    put('credit', credit);
    put('attribution', attribution);
    return AuthorInfo(
      user: user,
      url: pick(url, this.url),
      itchUser: itchUser,
      license: pick(license, this.license),
      extra: extra,
    );
  }

  /// The itch.io account slug, from `itch_user` or a `*.itch.io` url.
  String? get itchSlug {
    if (itchUser != null) return itchUser;
    final host = Uri.tryParse(url ?? '')?.host.toLowerCase();
    return host == null ? null : _itchHost.firstMatch(host)?.group(1);
  }

  String serialize() {
    final b = StringBuffer('user: $user\n');
    if (url != null) b.writeln('url: $url');
    if (itchUser != null) b.writeln('itch_user: $itchUser');
    if (license != null) b.writeln('license: $license');
    extra.forEach((k, v) => b.writeln('$k: $v'));
    return b.toString();
  }

  void write(String dir) =>
      File(p.join(dir, authorFileName)).writeAsStringSync(serialize());

  @override
  bool operator ==(Object other) =>
      other is AuthorInfo &&
      other.user == user &&
      other.url == url &&
      other.itchUser == itchUser &&
      other.license == license;

  @override
  int get hashCode => Object.hash(user, url, itchUser, license);

  @override
  String toString() => 'AuthorInfo($user, $url)';
}

/// Where a pack came from.
enum PackSource { manual, imported, itch }

/// Contents of an `asset_pack.json` file. Every field is optional.
class PackSidecar {
  const PackSidecar({
    this.title,
    this.types = const [],
    this.tags = const [],
    this.source,
    this.sourcePath,
    this.itchGameId,
    this.itchUrl,
    this.cover,
    this.notes,
    this.usedIn = const [],
    this.isContainer = false,
    this.animations = const {},
    this.extra = const {},
  });

  final String? title;
  final List<String> types;
  final List<String> tags;
  final PackSource? source;
  final String? sourcePath;
  final int? itchGameId;
  final String? itchUrl;

  /// Cover image path, relative to the pack folder.
  final String? cover;
  final String? notes;
  final List<String> usedIn;
  final bool isContainer;

  /// Per-file animation overrides keyed by path relative to the pack.
  final Map<String, Object?> animations;

  /// Unknown keys, preserved on write.
  final Map<String, Object?> extra;

  static const _known = {
    'title', 'types', 'tags', 'source', 'source_path', 'itch_game_id', //
    'itch_url', 'cover', 'notes', 'used_in', 'is_container', 'animations',
  };

  factory PackSidecar.fromJson(Map<String, Object?> json) {
    List<String> strings(Object? v) =>
        v is List ? v.whereType<String>().toList() : const [];
    final source = json['source'];
    return PackSidecar(
      title: json['title'] as String?,
      types: strings(json['types']),
      tags: strings(json['tags']),
      source: PackSource.values.where((s) => s.name == source).firstOrNull,
      sourcePath: json['source_path'] as String?,
      itchGameId: (json['itch_game_id'] as num?)?.toInt(),
      itchUrl: json['itch_url'] as String?,
      cover: json['cover'] as String?,
      notes: json['notes'] as String?,
      usedIn: strings(json['used_in']),
      isContainer: json['is_container'] == true,
      animations:
          (json['animations'] as Map?)?.cast<String, Object?>() ?? const {},
      extra: {
        for (final e in json.entries)
          if (!_known.contains(e.key)) e.key: e.value,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'title': ?title,
    if (types.isNotEmpty) 'types': types,
    if (tags.isNotEmpty) 'tags': tags,
    'source': ?source?.name,
    'source_path': ?sourcePath,
    'itch_game_id': ?itchGameId,
    'itch_url': ?itchUrl,
    'cover': ?cover,
    'notes': ?notes,
    if (usedIn.isNotEmpty) 'used_in': usedIn,
    if (isContainer) 'is_container': true,
    if (animations.isNotEmpty) 'animations': animations,
    ...extra,
  };

  static PackSidecar? read(String packDir) {
    final f = File(p.join(packDir, packFileName));
    if (!f.existsSync()) return null;
    try {
      final json = jsonDecode(f.readAsStringSync());
      return json is Map<String, Object?> ? PackSidecar.fromJson(json) : null;
    } on FormatException {
      return null;
    }
  }

  void write(String packDir) => File(p.join(packDir, packFileName))
      .writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(toJson())}\n',
      );

  PackSidecar copyWith({
    String? title,
    List<String>? types,
    List<String>? tags,
    PackSource? source,
    String? sourcePath,
    bool? isContainer,
    List<String>? usedIn,
    Map<String, Object?>? animations,
    int? itchGameId,
    String? itchUrl,
    String? cover,
  }) => PackSidecar(
    title: title ?? this.title,
    types: types ?? this.types,
    tags: tags ?? this.tags,
    source: source ?? this.source,
    sourcePath: sourcePath ?? this.sourcePath,
    itchGameId: itchGameId ?? this.itchGameId,
    itchUrl: itchUrl ?? this.itchUrl,
    cover: cover ?? this.cover,
    notes: notes,
    usedIn: usedIn ?? this.usedIn,
    isContainer: isContainer ?? this.isContainer,
    animations: animations ?? this.animations,
    extra: extra,
  );
}
