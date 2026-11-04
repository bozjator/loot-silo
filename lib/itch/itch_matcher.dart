import 'dart:math' as math;

import '../core/author_resolver.dart';
import '../core/library_index.dart';
import 'itch_api.dart';

enum MatchKind {
  /// The pack's sidecar already names this game.
  linked,

  /// Title and author look alike; the pack has no itch metadata yet.
  fuzzy,

  /// No pack, but a folder inside one of the author's packs matches (an
  /// author's single packs merged into one folder).
  inside,

  /// Nothing in the library looks like it.
  missing,
}

class ItchMatch {
  const ItchMatch(this.key, this.kind, {this.pack, this.score = 0});

  final OwnedKey key;
  final MatchKind kind;
  final PackRow? pack;
  final double score;
}

/// Words that say nothing about which pack it is.
const _noise = {
  'asset', 'pack', 'free', 'the', 'a', 'an', 'and', 'by', 'of', 'for', //
  'with', 'version', 'ver', 'vol', 'full', 'edition', 'collection', 'sprite',
  'pixel', 'art', 'pixelart', 'kit', 'v',
};

/// Abbreviations spelled out so `SFX` matches "Sound Effects".
const _expand = {
  'sfx': ['sound', 'effect'],
  'fx': ['effect'],
  'ui': ['user', 'interface'],
  'bgm': ['music'],
};

String _stem(String w) => w.length > 3 && w.endsWith('s') && !w.endsWith('ss')
    ? w.substring(0, w.length - 1)
    : w;

/// Title words in order: lower-case, camelCase split, version numbers
/// dropped, abbreviations expanded, plurals stemmed, numbers without
/// leading zeros, filler removed.
List<String> titleTokens(String title) {
  final cleaned = title
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .toLowerCase()
      .replaceAll(RegExp(r'\bv?\d+(\.\d+)+[a-z]?\b'), ' ')
      .replaceAll(RegExp(r'\bv\d+\b'), ' ');
  final out = <String>[];
  for (final raw in cleaned.split(RegExp(r'[^a-z0-9]+'))) {
    if (raw.isEmpty) continue;
    if (RegExp(r'^\d+$').hasMatch(raw)) {
      out.add(raw.replaceFirst(RegExp(r'^0+(?=\d)'), ''));
      continue;
    }
    for (final w in _expand[raw] ?? [raw]) {
      final s = _stem(w);
      if (!_noise.contains(s)) out.add(s);
    }
  }
  return out;
}

Set<String> titleWords(String title) => titleTokens(title).toSet();

bool _isNumber(String w) => RegExp(r'^\d+$').hasMatch(w);

/// Replaces an acronym in [a] (e.g. `erw`) by the words of [b] whose
/// initials spell it (`epic rpg world`).
Set<String> _expandAcronyms(List<String> a, List<String> b) {
  final out = <String>{};
  for (final w in a) {
    var expanded = false;
    if (w.length >= 2 && w.length <= 5 && !_isNumber(w) && !b.contains(w)) {
      for (var i = 0; i + w.length <= b.length; i++) {
        final run = b.sublist(i, i + w.length);
        if (run.map((x) => x[0]).join() == w) {
          out.addAll(run);
          expanded = true;
          break;
        }
      }
    }
    if (!expanded) out.add(w);
  }
  return out;
}

/// The itch account slug in an author URL (`https://name.itch.io/`).
String? itchSlugOf(String? url) {
  final host = Uri.tryParse(url ?? '')?.host.toLowerCase() ?? '';
  return host.endsWith('.itch.io') ? host.split('.').first : null;
}

bool sameAuthor(PackRow pack, ItchUser user) {
  final slug = itchSlugOf(pack.authorUrl);
  final names = {
    normalizeName(user.username),
    if (user.displayName != null) normalizeName(user.displayName!),
    if (itchSlugOf(user.url) case final s?) normalizeName(s),
  };
  return (slug != null && names.contains(normalizeName(slug))) ||
      (pack.author != null && names.contains(normalizeName(pack.author!)));
}

/// Title similarity with words weighted by rarity across [corpus].
class TitleMatcher {
  TitleMatcher(Iterable<String> corpus) {
    var n = 0;
    for (final title in corpus) {
      n++;
      for (final w in titleWords(title)) {
        _df[w] = (_df[w] ?? 0) + 1;
      }
    }
    _n = math.max(n, 1);
  }

  final _df = <String, int>{};
  late final int _n;

  double weight(String w) => math.log(1 + _n / (_df[w] ?? 1));

  double _sum(Iterable<String> ws) => ws.fold(0, (s, w) => s + weight(w));

  /// 0..~1.1. Mostly how much of the shorter title the longer one
  /// contains, plus a little overall overlap; titles whose numbers
  /// disagree ("… 2" vs "… 3") score 0.
  double score(String a, String b) {
    final ta = titleTokens(a), tb = titleTokens(b);
    final wa = _expandAcronyms(ta, tb), wb = _expandAcronyms(tb, ta);
    if (wa.isEmpty || wb.isEmpty) return 0;
    final na = wa.where(_isNumber).toSet(), nb = wb.where(_isNumber).toSet();
    if (na.isNotEmpty &&
        nb.isNotEmpty &&
        !na.containsAll(nb) &&
        !nb.containsAll(na)) {
      return 0;
    }
    final shared = _sum(wa.intersection(wb));
    final sa = _sum(wa), sb = _sum(wb);
    final containment = shared / math.min(sa, sb);
    final dice = 2 * shared / (sa + sb);
    var s = 0.8 * containment + 0.2 * dice;
    if (na.isNotEmpty && na.length == nb.length && na.containsAll(nb)) {
      s += 0.02;
    }
    if (normalizeName(a) == normalizeName(b)) s += 0.05;
    return s;
  }
}

/// Matches owned keys to library packs: by itch game id first, then by
/// title + author similarity, one pack per game, best pairs first.
/// Duplicate keys for the same game collapse into one. Games left over
/// are looked up among [folders] (pack id → folder names inside it).
List<ItchMatch> matchOwnedKeys(
  List<OwnedKey> keys,
  List<PackRow> packs, {
  Map<String, Set<String>> folders = const {},
}) {
  final unique = <int, OwnedKey>{};
  for (final k in keys) {
    unique.putIfAbsent(k.game.id, () => k);
  }
  final byGameId = {
    for (final pk in packs)
      if (pk.itchGameId != null) pk.itchGameId!: pk,
  };
  final matcher = TitleMatcher([
    for (final pk in packs) pk.title,
    for (final k in unique.values) k.game.title,
  ]);

  final result = <int, ItchMatch>{};
  final candidates = <(OwnedKey, PackRow, double)>[];
  for (final key in unique.values) {
    final linked = byGameId[key.game.id];
    if (linked != null) {
      result[key.game.id] = ItchMatch(
        key,
        MatchKind.linked,
        pack: linked,
        score: 1,
      );
      continue;
    }
    for (final pk in packs) {
      if (pk.itchGameId != null) continue;
      final author = sameAuthor(pk, key.game.user);
      var score = matcher.score(pk.title, key.game.title);
      // Without the same author only near-identical, specific titles count.
      if (!author && (score < 0.95 || titleWords(pk.title).length < 3)) {
        continue;
      }
      if (author && score < 0.75) continue;
      if (pk.parentId == null) score += 0.005;
      candidates.add((key, pk, score));
    }
  }
  candidates.sort((a, b) => b.$3.compareTo(a.$3));
  final taken = <String>{};
  for (final (key, pk, score) in candidates) {
    if (result.containsKey(key.game.id) || taken.contains(pk.id)) continue;
    result[key.game.id] = ItchMatch(
      key,
      MatchKind.fuzzy,
      pack: pk,
      score: score,
    );
    taken.add(pk.id);
  }
  for (final key in unique.values) {
    if (result.containsKey(key.game.id)) continue;
    ItchMatch? best;
    for (final pk in packs) {
      final names = folders[pk.id];
      if (names == null || !sameAuthor(pk, key.game.user)) continue;
      for (final name in names) {
        final score = matcher.score(name, key.game.title);
        if (score >= 0.75 && score > (best?.score ?? 0)) {
          best = ItchMatch(key, MatchKind.inside, pack: pk, score: score);
        }
      }
    }
    result[key.game.id] = best ?? ItchMatch(key, MatchKind.missing);
  }
  return [for (final key in unique.values) result[key.game.id]!];
}

/// Folder names (any depth, at most [maxDepth]) of a pack's files.
Set<String> folderNamesOf(Iterable<String> relPaths, {int maxDepth = 2}) => {
  for (final rel in relPaths)
    ...rel.split('/').reversed.skip(1).toList().reversed.take(maxDepth),
};
