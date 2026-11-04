import 'dart:convert';
import 'dart:io';

/// Light, dark or follow the system.
enum ThemeChoice { system, light, dark }

/// User settings, stored as JSON in the app support folder.
class AppSettings {
  const AppSettings({
    this.libraryPath,
    this.theme = ThemeChoice.system,
    this.animateAll = false,
    this.audioLoop = false,
  });

  /// The managed library folder; null until the user picks one.
  final String? libraryPath;
  final ThemeChoice theme;

  /// Play every sprite preview on the dashboard, not just the hovered one.
  final bool animateAll;

  /// Repeat the playing sound in a pack's Audio tab.
  final bool audioLoop;

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    libraryPath: json['library_path'] as String?,
    theme: ThemeChoice.values.asNameMap()[json['theme']] ?? ThemeChoice.system,
    animateAll: json['animate_all'] == true,
    audioLoop: json['audio_loop'] == true,
  );

  Map<String, Object?> toJson() => {
    'library_path': ?libraryPath,
    'theme': theme.name,
    'animate_all': animateAll,
    'audio_loop': audioLoop,
  };

  AppSettings copyWith({
    String? libraryPath,
    ThemeChoice? theme,
    bool? animateAll,
    bool? audioLoop,
  }) => AppSettings(
    libraryPath: libraryPath ?? this.libraryPath,
    theme: theme ?? this.theme,
    animateAll: animateAll ?? this.animateAll,
    audioLoop: audioLoop ?? this.audioLoop,
  );
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
