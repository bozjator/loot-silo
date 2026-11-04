import 'dart:io';

/// Reads `ITCH_API_KEY` from a `KEY=value` env file; quotes are stripped.
/// Returns null when the file or the line is missing.
String? readKeyFromEnvFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  for (final raw in file.readAsLinesSync()) {
    final line = raw.trim().replaceFirst(RegExp(r'^export\s+'), '');
    if (!line.startsWith('ITCH_API_KEY=')) continue;
    final value = line
        .substring('ITCH_API_KEY='.length)
        .trim()
        .replaceAll(RegExp(r'''^["']|["']$'''), '');
    return value.isEmpty ? null : value;
  }
  return null;
}

/// Development fallbacks, in order: the `ITCH_API_KEY` environment
/// variable, then a `.env` file in the working directory, then the file
/// named by `ITCH_ENV_FILE`. The app itself prefers the key saved in
/// secure storage.
String? keyFromEnvironment({
  Map<String, String>? environment,
  String? workingDirectory,
}) {
  final env = environment ?? Platform.environment;
  final direct = env['ITCH_API_KEY']?.trim();
  if (direct != null && direct.isNotEmpty) return direct;
  final dotEnv = readKeyFromEnvFile(
    '${workingDirectory ?? Directory.current.path}/.env',
  );
  if (dotEnv != null) return dotEnv;
  final file = env['ITCH_ENV_FILE'];
  return file == null ? null : readKeyFromEnvFile(file);
}
