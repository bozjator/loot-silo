/// Natural order: "frame2" before "frame10".
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final x = re.allMatches(a.toLowerCase()).toList();
  final y = re.allMatches(b.toLowerCase()).toList();
  for (var i = 0; i < x.length && i < y.length; i++) {
    final s = x[i].group(0)!, t = y[i].group(0)!;
    final m = int.tryParse(s), n = int.tryParse(t);
    final c = m != null && n != null
        ? m != n
              ? m.compareTo(n)
              : s.length.compareTo(t.length)
        : s.compareTo(t);
    if (c != 0) return c;
  }
  return x.length.compareTo(y.length);
}
