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
