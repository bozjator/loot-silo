import 'dart:convert';
import 'dart:io';

/// Light, dark or follow the system.
enum ThemeChoice { system, light, dark }

/// How a pack's Images and Animations tabs list their files.
enum ItemsView { flat, folders }

/// The dashboard shows one tile per pack, or splits packs that are
/// collections (one tile per character folder, say).
enum DashboardView { packs, expanded }

/// User settings, stored as JSON in the app support folder.
class AppSettings {
  const AppSettings({
    this.libraryPath,
    this.theme = ThemeChoice.system,
    this.animateAll = false,
    this.audioLoop = false,
    this.viewerPixelPerfect = false,
    this.dashboardTileSize = 240,
    this.imageThumbSize = 160,
    this.animationThumbSize = 200,
    this.detailHeaderPinned = true,
    this.imagesView = ItemsView.flat,
    this.animationsView = ItemsView.flat,
    this.dashboardView = DashboardView.packs,
  });

  /// The managed library folder; null until the user picks one.
  final String? libraryPath;
  final ThemeChoice theme;

  /// Play every sprite preview on the dashboard, not just the hovered one.
  final bool animateAll;

  /// Repeat the playing sound in a pack's Audio tab.
  final bool audioLoop;

  /// The image viewer keeps whole-number scaling even when a fractional fit
  /// would fill much more of the window.
  final bool viewerPixelPerfect;

  /// Widest a dashboard tile may get, in logical pixels.
  final double dashboardTileSize;

  /// Widest an image card in a pack's Images tab may get.
  final double imageThumbSize;

  /// Widest an animation card in a pack's Animations tab may get.
  final double animationThumbSize;

  /// The pack detail header (previews + info) stays above the tabs; when
  /// off it shrinks to a slim bar that shows the header on hover.
  final bool detailHeaderPinned;

  final ItemsView imagesView;
  final ItemsView animationsView;
  final DashboardView dashboardView;

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    libraryPath: json['library_path'] as String?,
    theme: ThemeChoice.values.asNameMap()[json['theme']] ?? ThemeChoice.system,
    animateAll: json['animate_all'] == true,
    audioLoop: json['audio_loop'] == true,
    viewerPixelPerfect: json['viewer_pixel_perfect'] == true,
    dashboardTileSize: (json['dashboard_tile_size'] as num?)?.toDouble() ?? 240,
    imageThumbSize: (json['image_thumb_size'] as num?)?.toDouble() ?? 160,
    animationThumbSize:
        (json['animation_thumb_size'] as num?)?.toDouble() ?? 200,
    detailHeaderPinned: json['detail_header_pinned'] != false,
    imagesView:
        ItemsView.values.asNameMap()[json['images_view']] ?? ItemsView.flat,
    animationsView:
        ItemsView.values.asNameMap()[json['animations_view']] ?? ItemsView.flat,
    dashboardView:
        DashboardView.values.asNameMap()[json['dashboard_view']] ??
        DashboardView.packs,
  );

  Map<String, Object?> toJson() => {
    'library_path': ?libraryPath,
    'theme': theme.name,
    'animate_all': animateAll,
    'audio_loop': audioLoop,
    'viewer_pixel_perfect': viewerPixelPerfect,
    'dashboard_tile_size': dashboardTileSize,
    'image_thumb_size': imageThumbSize,
    'animation_thumb_size': animationThumbSize,
    'detail_header_pinned': detailHeaderPinned,
    'images_view': imagesView.name,
    'animations_view': animationsView.name,
    'dashboard_view': dashboardView.name,
  };

  AppSettings copyWith({
    String? libraryPath,
    ThemeChoice? theme,
    bool? animateAll,
    bool? audioLoop,
    bool? viewerPixelPerfect,
    double? dashboardTileSize,
    double? imageThumbSize,
    double? animationThumbSize,
    bool? detailHeaderPinned,
    ItemsView? imagesView,
    ItemsView? animationsView,
    DashboardView? dashboardView,
  }) => AppSettings(
    libraryPath: libraryPath ?? this.libraryPath,
    theme: theme ?? this.theme,
    animateAll: animateAll ?? this.animateAll,
    audioLoop: audioLoop ?? this.audioLoop,
    viewerPixelPerfect: viewerPixelPerfect ?? this.viewerPixelPerfect,
    dashboardTileSize: dashboardTileSize ?? this.dashboardTileSize,
    imageThumbSize: imageThumbSize ?? this.imageThumbSize,
    animationThumbSize: animationThumbSize ?? this.animationThumbSize,
    detailHeaderPinned: detailHeaderPinned ?? this.detailHeaderPinned,
    imagesView: imagesView ?? this.imagesView,
    animationsView: animationsView ?? this.animationsView,
    dashboardView: dashboardView ?? this.dashboardView,
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
