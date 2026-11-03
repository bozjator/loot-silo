import 'dart:convert';
import 'dart:io';

/// User settings, stored as JSON in the app support folder.
class AppSettings {
  const AppSettings({this.libraryPath});

  /// The managed library folder; null until the user picks one.
  final String? libraryPath;

  factory AppSettings.fromJson(Map<String, Object?> json) =>
      AppSettings(libraryPath: json['library_path'] as String?);

  Map<String, Object?> toJson() => {'library_path': ?libraryPath};

  AppSettings copyWith({String? libraryPath}) =>
      AppSettings(libraryPath: libraryPath ?? this.libraryPath);
}

class SettingsStore {
  SettingsStore(this.file);

  final File file;

  AppSettings load() {
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is Map<String, Object?>) return AppSettings.fromJson(json);
    } on FileSystemException {
      // First run.
    } on FormatException {
      // Corrupt file; start fresh rather than refusing to open.
    }
    return const AppSettings();
  }

  void save(AppSettings settings) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }
}
