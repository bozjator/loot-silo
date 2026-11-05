import 'type_classifier.dart';

final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// The words of a search, lowercased, as the FTS query uses them.
List<String> queryWords(String input) => [
  for (final w in input.split(_nonWord))
    if (w.isNotEmpty) w.toLowerCase(),
];

/// The words a file is found by: its path split like the FTS tokenizer
/// does, plus camelCase splits (`HumanSoldier.png` → human, soldier).
Set<String> fileWords(String rel) => {
  for (final w in rel.split(_nonWord))
    if (w.isNotEmpty) w.toLowerCase(),
  ...pathWords(rel),
};

/// What the file index stores for [rel]: the path and its split words.
String fileSearchText(String rel) => '$rel ${pathWords(rel).join(' ')}';

/// Whether every one of [words] is a prefix of one of [rel]'s words — the
/// rule `LibraryIndex.searchFiles` applies, so the detail page filters the
/// same files the dashboard listed. With [infix], each word only has to
/// appear somewhere in the path (the trigram fallback).
bool fileMatches(String rel, List<String> words, {bool infix = false}) {
  if (words.isEmpty) return true;
  if (infix) {
    final lower = rel.toLowerCase();
    return words.every(lower.contains);
  }
  final own = fileWords(rel);
  return words.every((q) => own.any((w) => w.startsWith(q)));
}
