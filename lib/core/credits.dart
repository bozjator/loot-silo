import 'package:path/path.dart' as p;

import 'library_index.dart';
import 'sidecar.dart';

/// One author's block in a credits file.
class CreditAuthor {
  const CreditAuthor({
    required this.name,
    this.url,
    this.license,
    this.credit,
    this.attribution,
    required this.packs,
  });

  /// Folder / `user` name.
  final String name;
  final String? url;
  final String? license;

  /// Wording the author asks for; falls back to [name].
  final String? credit;
  final String? attribution;

  /// Pack titles, sorted.
  final List<String> packs;

  String get displayName => credit ?? name;
}

/// Every game any pack is marked as used in, sorted.
List<String> knownGames(Iterable<PackRow> packs) =>
    {for (final pk in packs) ...pk.usedIn}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

/// Packs marked as used in [game].
List<PackRow> packsUsedIn(Iterable<PackRow> packs, String game) => [
  for (final pk in packs)
    if (pk.usedIn.contains(game)) pk,
]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

/// Groups the packs used in [game] by author, reading each author's
/// `ASSET_AUTHOR.txt` from `<root>/<Author>/` for URL and license.
List<CreditAuthor> collectCredits(
  String root,
  Iterable<PackRow> packs,
  String game,
) {
  final byFolder = <String, List<PackRow>>{};
  for (final pk in packsUsedIn(packs, game)) {
    final folder = p.split(pk.id).first;
    (byFolder[folder] ??= []).add(pk);
  }
  final out = <CreditAuthor>[];
  for (final MapEntry(key: folder, value: list) in byFolder.entries) {
    final info = AuthorInfo.read(p.join(root, folder, authorFileName));
    out.add(
      CreditAuthor(
        name: info?.user ?? list.first.author ?? folder,
        url: info?.url ?? list.first.authorUrl,
        license: info?.license,
        credit: info?.credit,
        attribution: info?.attribution,
        packs: [for (final pk in list) pk.title],
      ),
    );
  }
  return out..sort(
    (a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()),
  );
}

String creditsMarkdown(String game, List<CreditAuthor> authors) {
  final b = StringBuffer('# Credits — $game\n\n')
    ..writeln('Assets used in $game, grouped by author.');
  for (final a in authors) {
    b
      ..writeln()
      ..writeln('## ${a.displayName}')
      ..writeln();
    if (a.url != null) b.writeln('- Website: <${a.url}>');
    if (a.license != null) b.writeln('- License: ${a.license}');
    b.writeln('- Assets: ${a.packs.join(', ')}');
  }
  return b.toString();
}

String creditsText(String game, List<CreditAuthor> authors) {
  final b = StringBuffer('CREDITS — $game\n');
  for (final a in authors) {
    b
      ..writeln()
      ..writeln(a.url == null ? a.displayName : '${a.displayName} — ${a.url}');
    if (a.license != null) b.writeln('  License: ${a.license}');
    b.writeln('  Assets: ${a.packs.join('; ')}');
  }
  return b.toString();
}
