/// `1.2 GB`-style sizes.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var u = 0;
  while (v >= 1000 && u < units.length - 1) {
    v /= 1000;
    u++;
  }
  return u == 0
      ? '$bytes B'
      : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[u]}';
}

/// `49,797`-style counts.
String formatCount(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+$)'), (_) => ',');

/// `Knight_Idle-Anim.png` → `Knight Idle Anim`: drops the extension when
/// [isFile], turns `-` and `_` into spaces and capitalises the first letter
/// (the rest is kept, so `NPC` and `UI` survive).
String prettyName(String name, {bool isFile = true}) {
  var base = name.trim();
  if (isFile) {
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
  }
  final words = base.replaceAll(RegExp(r'[-_\s]+'), ' ').trim();
  if (words.isEmpty) return name.trim();
  return words[0].toUpperCase() + words.substring(1);
}
