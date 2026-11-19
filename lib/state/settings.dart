import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';

import '../core/audio_formats.dart' show AudioSort, audioFormatOrder;

/// Light, dark or follow the system.
enum ThemeChoice { system, light, dark }

/// The colour the light and dark themes are seeded from (Settings →
/// Appearance). Stored by name; the seeds live in `ui/theme_colors.dart`.
enum ThemeColor {
  teal,
  green,
  blue,
  indigo,
  purple,
  pink,
  red,
  orange,
  amber,
  brown,
  blueGrey,
}

/// The app's look (Settings → Appearance). Glass: a lit backdrop behind
/// see-through surfaces, and cards that lift and glow on hover. Classic:
/// solid surfaces, no hover glow. Shapes and type are the same in both.
enum AppStyle { glass, classic }

/// How a pack tile's cover sits in its picture area (Settings →
/// Appearance). Fit: the whole image, with room around it. Fill: the image
/// covers the area, cropped at the sides it overflows.
enum CoverFit { fit, fill }

/// How a pack's Images and Animations tabs list their files.
enum ItemsView { flat, folders }

/// The dashboard shows one tile per pack, splits packs that are
/// collections (one tile per character folder, say), or lists the files
/// matching the search.
enum DashboardView { packs, expanded, files }

/// A pack's Audio tab as a list of rows or a grid of cards.
enum AudioView { rows, cards }

/// Which cards in a pack's Animations tab play: all of them, or only the
/// one under the mouse.
enum AnimateMode { all, hover }

/// One open pack page as it was left: its pack, folder limit, open tab
/// (`animations`, `images`, `audio`, `files`), search text and Favorites
/// chip.
class PageSession {
  const PageSession({
    required this.packId,
    this.folder,
    this.tab,
    this.search = '',
    this.favorites = false,
  });

  final String packId;
  final String? folder;
  final String? tab;
  final String search;
  final bool favorites;

  factory PageSession.fromJson(Map<String, Object?> json) => PageSession(
    packId: json['pack_id']! as String,
    folder: json['folder'] as String?,
    tab: json['tab'] as String?,
    search: json['search'] as String? ?? '',
    favorites: json['favorites'] == true,
  );

  Map<String, Object?> toJson() => {
    'pack_id': packId,
    'folder': ?folder,
    'tab': ?tab,
    if (search.isNotEmpty) 'search': search,
    if (favorites) 'favorites': true,
  };

  @override
  bool operator ==(Object other) =>
      other is PageSession &&
      other.packId == packId &&
      other.folder == folder &&
      other.tab == tab &&
      other.search == search &&
      other.favorites == favorites;

  @override
  int get hashCode => Object.hash(packId, folder, tab, search, favorites);
}

/// What "Resume where I left off" brings back: the open pack tabs (in
/// order) and the shown one (0 = dashboard, `i + 1` = [tabs]`[i]`), the
/// dashboard's search, filters and sort, and a pack page open
/// in the Dashboard tab. The dashboard view is its own setting
/// ([AppSettings.dashboardView]). Settings key `last_session`.
class LastSession {
  const LastSession({
    this.tabs = const [],
    this.active = 0,
    this.dashboardPage,
    this.search = '',
    this.types = const [],
    this.authors = const [],
    this.tags = const [],
    this.sources = const [],
    this.favorites = false,
    this.sort,
    this.node,
    this.treeExpanded = const [],
  });

  final List<PageSession> tabs;
  final int active;
  final PageSession? dashboardPage;
  final String search;
  final List<String> types;
  final List<String> authors;
  final List<String> tags;
  final List<String> sources;
  final bool favorites;

  /// A `PackSort` name.
  final String? sort;

  /// The dashboard's folder tree node (M98): a library-relative path.
  final String? node;

  /// The folder tree's expanded nodes, by path.
  final List<String> treeExpanded;

  static List<String> _strings(Object? v) => [
    if (v is List)
      for (final e in v)
        if (e is String) e,
  ];

  factory LastSession.fromJson(Map<String, Object?> json) {
    final page = json['dashboard_page'];
    return LastSession(
      tabs: [
        if (json['tabs'] case final List<Object?> tabs)
          for (final t in tabs)
            if (t is Map<String, Object?> && t['pack_id'] is String)
              PageSession.fromJson(t),
      ],
      active: (json['active'] as num?)?.toInt() ?? 0,
      dashboardPage: page is Map<String, Object?> && page['pack_id'] is String
          ? PageSession.fromJson(page)
          : null,
      search: json['search'] as String? ?? '',
      types: _strings(json['types']),
      authors: _strings(json['authors']),
      tags: _strings(json['tags']),
      sources: _strings(json['sources']),
      favorites: json['favorites'] == true,
      sort: json['sort'] as String?,
      node: json['node'] as String?,
      treeExpanded: _strings(json['tree_expanded']),
    );
  }

  Map<String, Object?> toJson() => {
    'tabs': [for (final t in tabs) t.toJson()],
    'active': active,
    'dashboard_page': ?dashboardPage?.toJson(),
    'search': search,
    'types': types,
    'authors': authors,
    'tags': tags,
    'sources': sources,
    'favorites': favorites,
    'sort': ?sort,
    'node': ?node,
    if (treeExpanded.isNotEmpty) 'tree_expanded': treeExpanded,
  };

  @override
  bool operator ==(Object other) =>
      other is LastSession &&
      jsonEncode(toJson()) == jsonEncode(other.toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// User settings, stored as JSON in the app support folder.
class AppSettings {
  const AppSettings({
    this.libraryPath,
    this.theme = ThemeChoice.system,
    this.themeColor = ThemeColor.teal,
    this.style = AppStyle.glass,
    this.coverFit = CoverFit.fill,
    this.animateAll = false,
    this.audioLoop = false,
    this.dashboardTileSize = 240,
    this.imageThumbSize = 160,
    this.animationThumbSize = 200,
    this.modelThumbSize = 200,
    this.materialThumbSize = 200,
    this.detailHeaderPinned = true,
    this.imagesView = ItemsView.flat,
    this.animationsView = ItemsView.flat,
    this.modelsView = ItemsView.flat,
    this.materialsView = ItemsView.flat,
    this.dashboardView = DashboardView.packs,
    this.detailAnimateMode = AnimateMode.hover,
    this.audioView = AudioView.rows,
    this.audioSort = AudioSort.name,
    this.audioSortDesc = false,
    this.audioFormat = 'ogg',
    this.previewsColumns = 4,
    this.previewsFit = CoverFit.fit,
    this.dashboardTreeOpen = false,
    this.dashboardTreeWidth = defaultTreeWidth,
    this.resumeSession = true,
    this.lastSession,
  });

  /// The managed library folder; null until the user picks one.
  final String? libraryPath;
  final ThemeChoice theme;

  /// The theme's seed colour; teal (the original look) by default.
  final ThemeColor themeColor;

  /// Glass (the default) or Classic.
  final AppStyle style;

  /// Pack tile covers: filling the area (the default) or the whole image.
  final CoverFit coverFit;

  /// Play every sprite preview on the dashboard, not just the hovered one.
  final bool animateAll;

  /// Repeat the playing sound in a pack's Audio tab.
  final bool audioLoop;

  /// Widest a dashboard tile may get, in logical pixels.
  final double dashboardTileSize;

  /// Widest an image card in a pack's Images tab may get.
  final double imageThumbSize;

  /// Widest an animation card in a pack's Animations tab may get.
  final double animationThumbSize;

  /// Widest a model card in a pack's Models tab may get.
  final double modelThumbSize;

  /// Widest a material card in a pack's Materials tab may get.
  final double materialThumbSize;

  /// The pack detail header (previews + info) stays above the tabs; when
  /// off it shrinks to a slim bar that shows the header on hover.
  final bool detailHeaderPinned;

  final ItemsView imagesView;
  final ItemsView animationsView;
  final ItemsView modelsView;
  final ItemsView materialsView;
  final DashboardView dashboardView;

  /// Animations tab play mode. Hover by default (a deliberate change from
  /// the earlier always-playing cards).
  final AnimateMode detailAnimateMode;

  final AudioView audioView;

  /// What the Audio tab sorts by (the shown format's values), and whether
  /// largest / last first.
  final AudioSort audioSort;
  final bool audioSortDesc;

  /// The format an Audio tab card plays when its sound comes in several
  /// (one of `audioFormatOrder`).
  final String audioFormat;

  /// Wanted columns in the "All previews" grid (1–8); rows are balanced
  /// from it. 4 is what the 440 px cards gave in a full-width window.
  final int previewsColumns;

  /// How the "All previews" grid's cards show their images: the whole
  /// image (Fit) or cropped to fill the card (Fill).
  final CoverFit previewsFit;

  /// The dashboard's folder tree panel (M98) is shown.
  final bool dashboardTreeOpen;

  /// The folder tree panel's width in logical pixels.
  final double dashboardTreeWidth;

  /// [dashboardTreeWidth]'s default and lower bound.
  static const defaultTreeWidth = 280.0;
  static const minTreeWidth = 200.0;

  /// "Resume where I left off": reopen [lastSession] on start.
  final bool resumeSession;

  /// The tabs, dashboard and pack pages as they were left; null when
  /// nothing was saved or [resumeSession] is off.
  final LastSession? lastSession;

  factory AppSettings.fromJson(Map<String, Object?> json) => AppSettings(
    libraryPath: json['library_path'] as String?,
    theme: ThemeChoice.values.asNameMap()[json['theme']] ?? ThemeChoice.system,
    themeColor:
        ThemeColor.values.asNameMap()[json['theme_color']] ?? ThemeColor.teal,
    style: AppStyle.values.asNameMap()[json['style']] ?? AppStyle.glass,
    coverFit: CoverFit.values.asNameMap()[json['cover_fit']] ?? CoverFit.fill,
    animateAll: json['animate_all'] == true,
    audioLoop: json['audio_loop'] == true,
    dashboardTileSize: (json['dashboard_tile_size'] as num?)?.toDouble() ?? 240,
    imageThumbSize: (json['image_thumb_size'] as num?)?.toDouble() ?? 160,
    animationThumbSize:
        (json['animation_thumb_size'] as num?)?.toDouble() ?? 200,
    modelThumbSize: (json['model_thumb_size'] as num?)?.toDouble() ?? 200,
    materialThumbSize: (json['material_thumb_size'] as num?)?.toDouble() ?? 200,
    detailHeaderPinned: json['detail_header_pinned'] != false,
    imagesView:
        ItemsView.values.asNameMap()[json['images_view']] ?? ItemsView.flat,
    animationsView:
        ItemsView.values.asNameMap()[json['animations_view']] ?? ItemsView.flat,
    modelsView:
        ItemsView.values.asNameMap()[json['models_view']] ?? ItemsView.flat,
    materialsView:
        ItemsView.values.asNameMap()[json['materials_view']] ?? ItemsView.flat,
    dashboardView:
        DashboardView.values.asNameMap()[json['dashboard_view']] ??
        DashboardView.packs,
    detailAnimateMode:
        AnimateMode.values.asNameMap()[json['detail_animate_mode']] ??
        AnimateMode.hover,
    audioView:
        AudioView.values.asNameMap()[json['audio_view']] ?? AudioView.rows,
    audioSort:
        AudioSort.values.asNameMap()[json['audio_sort']] ?? AudioSort.name,
    audioSortDesc: json['audio_sort_desc'] == true,
    audioFormat: switch (json['audio_format']) {
      final String f when audioFormatOrder.contains(f) => f,
      _ => 'ogg',
    },
    previewsColumns: ((json['previews_columns'] as num?)?.toInt() ?? 4).clamp(
      1,
      8,
    ),
    previewsFit:
        CoverFit.values.asNameMap()[json['previews_fit']] ?? CoverFit.fit,
    dashboardTreeOpen: json['dashboard_tree_open'] == true,
    dashboardTreeWidth: math.max(
      minTreeWidth,
      (json['dashboard_tree_width'] as num?)?.toDouble() ?? defaultTreeWidth,
    ),
    resumeSession: json['resume_session'] != false,
    // Kept only while resuming is on.
    lastSession: switch (json['last_session']) {
      final Map<String, Object?> m when json['resume_session'] != false =>
        LastSession.fromJson(m),
      _ => null,
    },
  );

  Map<String, Object?> toJson() => {
    'library_path': ?libraryPath,
    'theme': theme.name,
    'theme_color': themeColor.name,
    'style': style.name,
    'cover_fit': coverFit.name,
    'animate_all': animateAll,
    'audio_loop': audioLoop,
    'dashboard_tile_size': dashboardTileSize,
    'image_thumb_size': imageThumbSize,
    'animation_thumb_size': animationThumbSize,
    'model_thumb_size': modelThumbSize,
    'material_thumb_size': materialThumbSize,
    'detail_header_pinned': detailHeaderPinned,
    'images_view': imagesView.name,
    'animations_view': animationsView.name,
    'models_view': modelsView.name,
    'materials_view': materialsView.name,
    'dashboard_view': dashboardView.name,
    'detail_animate_mode': detailAnimateMode.name,
    'audio_view': audioView.name,
    'audio_sort': audioSort.name,
    'audio_sort_desc': audioSortDesc,
    'audio_format': audioFormat,
    'previews_columns': previewsColumns,
    'previews_fit': previewsFit.name,
    'dashboard_tree_open': dashboardTreeOpen,
    'dashboard_tree_width': dashboardTreeWidth,
    'resume_session': resumeSession,
    'last_session': ?lastSession?.toJson(),
  };

  AppSettings copyWith({
    String? libraryPath,
    ThemeChoice? theme,
    ThemeColor? themeColor,
    AppStyle? style,
    CoverFit? coverFit,
    bool? animateAll,
    bool? audioLoop,
    double? dashboardTileSize,
    double? imageThumbSize,
    double? animationThumbSize,
    double? modelThumbSize,
    double? materialThumbSize,
    bool? detailHeaderPinned,
    ItemsView? imagesView,
    ItemsView? animationsView,
    ItemsView? modelsView,
    ItemsView? materialsView,
    DashboardView? dashboardView,
    AnimateMode? detailAnimateMode,
    AudioView? audioView,
    AudioSort? audioSort,
    bool? audioSortDesc,
    String? audioFormat,
    int? previewsColumns,
    CoverFit? previewsFit,
    bool? dashboardTreeOpen,
    double? dashboardTreeWidth,
    bool? resumeSession,
    Object? lastSession = _keep,
  }) => AppSettings(
    libraryPath: libraryPath ?? this.libraryPath,
    theme: theme ?? this.theme,
    themeColor: themeColor ?? this.themeColor,
    style: style ?? this.style,
    coverFit: coverFit ?? this.coverFit,
    animateAll: animateAll ?? this.animateAll,
    audioLoop: audioLoop ?? this.audioLoop,
    dashboardTileSize: dashboardTileSize ?? this.dashboardTileSize,
    imageThumbSize: imageThumbSize ?? this.imageThumbSize,
    animationThumbSize: animationThumbSize ?? this.animationThumbSize,
    modelThumbSize: modelThumbSize ?? this.modelThumbSize,
    materialThumbSize: materialThumbSize ?? this.materialThumbSize,
    detailHeaderPinned: detailHeaderPinned ?? this.detailHeaderPinned,
    imagesView: imagesView ?? this.imagesView,
    animationsView: animationsView ?? this.animationsView,
    modelsView: modelsView ?? this.modelsView,
    materialsView: materialsView ?? this.materialsView,
    dashboardView: dashboardView ?? this.dashboardView,
    detailAnimateMode: detailAnimateMode ?? this.detailAnimateMode,
    audioView: audioView ?? this.audioView,
    audioSort: audioSort ?? this.audioSort,
    audioSortDesc: audioSortDesc ?? this.audioSortDesc,
    audioFormat: audioFormat ?? this.audioFormat,
    previewsColumns: previewsColumns ?? this.previewsColumns,
    previewsFit: previewsFit ?? this.previewsFit,
    dashboardTreeOpen: dashboardTreeOpen ?? this.dashboardTreeOpen,
    dashboardTreeWidth: dashboardTreeWidth ?? this.dashboardTreeWidth,
    resumeSession: resumeSession ?? this.resumeSession,
    lastSession: identical(lastSession, _keep)
        ? this.lastSession
        : lastSession as LastSession?,
  );

  /// [copyWith]'s "leave [lastSession] as it is"; pass null to clear it.
  static const _keep = Object();
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
