import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../install/archive_extractor.dart';
import '../state/dashboard.dart';
import '../state/itch.dart' show itchKeyProvider;
import '../state/providers.dart';
import '../state/settings.dart';
import 'archive_import.dart';
import 'credits_screen.dart';
import 'dashboard.dart';
import 'folder_import_screen.dart';
import 'itch_screen.dart';
import 'settings_screen.dart';
import 'tabs.dart';
import 'theme_colors.dart';
import 'help_screen.dart';
import 'session.dart';
import '../version.dart';
import 'shortcuts.dart';
import 'widgets/branding.dart';
import 'widgets/measure_size.dart';

/// Root widget of Loot Silo.
class LootSiloApp extends ConsumerStatefulWidget {
  const LootSiloApp({super.key});

  @override
  ConsumerState<LootSiloApp> createState() => _AppState();
}

class _AppState extends ConsumerState<LootSiloApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _top = TopRoute();

  /// Runs an app-wide shortcut on any page, but not over a dialog or a
  /// popup menu, and only once a library is set up.
  void Function() _shortcut(
    void Function(BuildContext context) action, {
    bool needsLibrary = true,
    String? notOn,
  }) => () {
    final context = _navigator.currentContext;
    final top = _top.top;
    if (context == null || top is! PageRoute) return;
    // A popup menu inside a tab is on that tab's navigator.
    final tabTop = ref.read(tabsProvider.notifier).currentTop;
    if (top.isFirst && tabTop != null && tabTop is! PageRoute) return;
    if (notOn != null && top.settings.name == notOn) return;
    if (needsLibrary && ref.read(settingsProvider).libraryPath == null) return;
    action(context);
  };

  /// Ctrl+I/O import, Ctrl+R/F5 rescan, Ctrl+, settings. They live above the
  /// navigator, so they work wherever focus is (also when it fell back to a
  /// page's focus scope after a click on empty space or a page closing).
  Map<ShortcutActivator, VoidCallback> get _appShortcuts {
    final rescan = _shortcut((_) => rescanLibrary(ref));
    return {
      ...AppKeys.importFolder.bind(
        _shortcut(
          (c) => importFolder(c, ref),
          notOn: FolderImportScreen.routeName,
        ),
      ),
      ...AppKeys.importArchive.bind(
        _shortcut(
          (c) => importArchive(c, ref),
          notOn: FolderImportScreen.routeName,
        ),
      ),
      ...AppKeys.rescan.bind(rescan),
      // Pack tabs: only while the tabs are shown (no page over them).
      ...AppKeys.nextTab.bind(_onTabs((t) => t.cycle(1))),
      ...AppKeys.previousTab.bind(_onTabs((t) => t.cycle(-1))),
      ...AppKeys.closeTab.bind(_onTabs((t) => t.closeCurrent())),
      ...AppKeys.settings.bind(
        _shortcut(
          openSettings,
          needsLibrary: false,
          notOn: SettingsScreen.routeName,
        ),
      ),
      ...AppKeys.help.bind(
        _shortcut(openHelp, needsLibrary: false, notOn: HelpScreen.routeName),
      ),
    };
  }

  /// A tab shortcut, run when the tabs are on top (no page or dialog over
  /// them, no menu inside the shown tab).
  VoidCallback _onTabs(void Function(TabsNotifier tabs) action) =>
      _shortcut((_) {
        if (_top.top?.isFirst ?? false) action(ref.read(tabsProvider.notifier));
      });

  /// Closes the top page or dialog, else goes back within the shown tab; on
  /// the dashboard, leaves an open bundle.
  Future<void> _back() async {
    final root = _navigator.currentState;
    if (root != null && root.canPop()) {
      await root.maybePop();
      return;
    }
    final tabs = ref.read(tabsProvider.notifier);
    if (await tabs.currentNavigator?.maybePop() ?? false) return;
    if (ref.read(tabsProvider).active != 0) return;
    final query = ref.read(dashboardQueryProvider.notifier);
    if (ref.read(dashboardQueryProvider).bundleId != null) {
      query.openBundle(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ref.watch(settingsProvider.select((s) => s.theme));
    final themeColor = ref.watch(settingsProvider.select((s) => s.themeColor));
    return MaterialApp(
      title: appName,
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigator,
      navigatorObservers: [_top],
      themeMode: switch (theme) {
        ThemeChoice.system => ThemeMode.system,
        ThemeChoice.light => ThemeMode.light,
        ThemeChoice.dark => ThemeMode.dark,
      },
      // Esc and the mouse back button close the current page; dialogs and
      // search handle Esc first.
      builder: (context, child) => Listener(
        onPointerDown: (event) {
          if (event.buttons & kBackMouseButton != 0 && !offerBack()) _back();
        },
        child: CallbackShortcuts(
          bindings: {...AppKeys.back.bind(_back), ..._appShortcuts},
          child: child!,
        ),
      ),
      theme: appTheme(themeColor, Brightness.light),
      darkTheme: appTheme(themeColor, Brightness.dark),
      home: const SessionHost(child: TabsHost(dashboard: HomeScreen())),
    );
  }
}

/// Picks a folder and opens the import review; rescans after an import.
Future<void> importFolder(BuildContext context, WidgetRef ref) async {
  final source = await ref.read(directoryPickerProvider)('Import folder');
  if (source == null || !context.mounted) return;
  final imported = await Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      settings: const RouteSettings(name: FolderImportScreen.routeName),
      builder: (_) => FolderImportScreen(sourcePath: source),
    ),
  );
  if (imported == true) await ref.read(libraryProvider.notifier).rescan();
}

/// Picks archives and imports them; rescans after an import.
Future<void> importArchive(BuildContext context, WidgetRef ref) async {
  final paths = await ref.read(archivePickerProvider)();
  if (paths.isEmpty || !context.mounted) return;
  if (await importArchives(context, ref, paths)) {
    await ref.read(libraryProvider.notifier).rescan();
  }
}

/// Rescans the library unless a scan is already running.
void rescanLibrary(WidgetRef ref) {
  if (!ref.read(libraryProvider).isLoading) {
    ref.read(libraryProvider.notifier).rescan();
  }
}

/// The itch.io view (connect, or download what you own).
void openItch(BuildContext context) => Navigator.of(
  context,
  rootNavigator: true,
).push(MaterialPageRoute<void>(builder: (_) => const ItchScreen()));

void openSettings(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: SettingsScreen.routeName),
        builder: (_) => const SettingsScreen(),
      ),
    );

/// Library overview: the dashboard plus import, itch.io, credits and
/// settings.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  Future<void> _chooseLibrary(BuildContext context, WidgetRef ref) async {
    final path = await ref.read(directoryPickerProvider)('Use as library');
    if (path != null) ref.read(settingsProvider.notifier).setLibraryPath(path);
  }

  /// Dropped folders go through the folder import, archives through the
  /// archive import; anything else is reported.
  Future<void> _onDrop(
    BuildContext context,
    WidgetRef ref,
    List<String> paths,
  ) async {
    final folders = [
      for (final path in paths)
        if (FileSystemEntity.isDirectorySync(path)) path,
    ];
    final archives = [
      for (final path in paths)
        if (archiveKindOf(path) != null && File(path).existsSync()) path,
    ];
    final skipped = paths.length - folders.length - archives.length;
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Skipped $skipped dropped '
            '${skipped == 1 ? 'item' : 'items'}: only folders and '
            'zip / rar / 7z / tar archives can be imported',
          ),
        ),
      );
    }
    var imported = false;
    if (archives.isNotEmpty) {
      imported = await importArchives(context, ref, archives);
    }
    for (final folder in folders) {
      if (!context.mounted) break;
      imported |=
          await Navigator.of(context, rootNavigator: true).push<bool>(
            MaterialPageRoute(
              settings: const RouteSettings(name: FolderImportScreen.routeName),
              builder: (_) => FolderImportScreen(sourcePath: folder),
            ),
          ) ??
          false;
    }
    if (imported) await ref.read(libraryProvider.notifier).rescan();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final libraryPath = ref.watch(
      settingsProvider.select((s) => s.libraryPath),
    );
    if (libraryPath == null) {
      return Scaffold(
        appBar: AppBar(title: const AppBarTitle()),
        body: _Message(
          header: const AppLogo(height: 112),
          icon: Icons.folder_special_outlined,
          title: 'Choose a library folder',
          body:
              'Loot Silo keeps your packs in one folder it manages, '
              'organised as Author/Pack.',
          action: FilledButton.icon(
            onPressed: () => _chooseLibrary(context, ref),
            icon: const Icon(Icons.folder_open),
            label: const Text('Choose folder'),
          ),
        ),
      );
    }

    final library = ref.watch(libraryProvider);
    final scanning = library.isLoading;
    void rescan() => rescanLibrary(ref);
    // A newly chosen library (first run, or switched in Settings) scans
    // behind a wait screen: Riverpod keeps the previous value while it
    // loads, which is the empty state on first run and the old library's
    // packs after a switch. A rescan of the packs on screen keeps them.
    final waiting = switch (library) {
      AsyncValue(isLoading: false) => false,
      // An error stays on screen while Riverpod retries the load.
      AsyncValue(hasError: true) => false,
      AsyncValue(:final value?) =>
        value.packs.isEmpty || value.root != libraryPath,
      _ => true,
    };

    // Ctrl+I/O/R, F5 and Ctrl+, are bound app-wide (LootSiloApp).
    return Scaffold(
      appBar: AppBar(
        title: const AppBarTitle(),
        bottom: tabStrip(ref, progress: scanning),
        actions: [
          // Measured: the dashboard's size slider is as wide as this row.
          MeasureSize(
            onSize: (s) =>
                ref.read(appBarActionsWidthProvider.notifier).set(s.width),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'itch.io',
                  onPressed: () => openItch(context),
                  icon: const Icon(Icons.storefront_outlined),
                ),
                IconButton(
                  tooltip: 'Credits',
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const CreditsScreen(),
                        ),
                      ),
                  icon: const Icon(Icons.receipt_long_outlined),
                ),
                IconButton(
                  tooltip: 'Rescan library (F5)',
                  onPressed: scanning ? null : rescan,
                  icon: const Icon(Icons.refresh),
                ),
                const _ImportMenu(),
                IconButton(
                  tooltip: 'How Loot Silo works (F1)',
                  onPressed: () => openHelp(context),
                  icon: const Icon(Icons.help_outline),
                ),
                IconButton(
                  tooltip: 'Settings (Ctrl+,)',
                  onPressed: () => openSettings(context),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
          ),
          // The dashboard's 16 px side padding, so the slider lines up
          // under the icons.
          const SizedBox(width: 16),
        ],
      ),
      body: DropZone(
        onDrop: (paths) => _onDrop(context, ref, paths),
        child: switch (library) {
          _ when waiting => _ScanningLibrary(path: libraryPath),
          AsyncValue(:final value?)
              when value.packs.isNotEmpty && value.root == libraryPath =>
            const Dashboard(),
          AsyncValue(:final error?) => _Message(
            icon: Icons.error_outline,
            title: 'Could not read the library',
            body: '$error',
            action: Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: rescan,
                  child: const Text('Try again'),
                ),
                FilledButton(
                  onPressed: () => _chooseLibrary(context, ref),
                  child: const Text('Choose another folder'),
                ),
              ],
            ),
          ),
          AsyncValue(hasValue: true) => const _Message(
            icon: Icons.inventory_2_outlined,
            title: 'Your library is empty',
            body: 'Add your first packs in one of these ways:',
            action: _FirstPacks(),
          ),
          _ => _ScanningLibrary(path: libraryPath),
        },
      ),
    );
  }
}

/// An empty library's ways to add packs: the same actions as the top
/// bar's import menu and itch.io button, each with a line on what it does.
/// All three are filled buttons of one width, the widest label's (a
/// [Table]'s intrinsic column), so the lines beside them start at one x.
class _FirstPacks extends ConsumerWidget {
  const _FirstPacks();

  /// The column of lines at most this wide; narrow windows wrap them.
  static const lineWidth = 320.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(itchKeyProvider).value != null;
    final style = Theme.of(context).textTheme.bodySmall;
    TableRow choice({
      required Key key,
      required IconData icon,
      required String label,
      required String line,
      required VoidCallback onPressed,
    }) => TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          // The cell is the column's width; the button fills it.
          child: FilledButton.icon(
            key: key,
            onPressed: onPressed,
            icon: Icon(icon),
            label: Text(label),
          ),
        ),
        const SizedBox(),
        Text(line, style: style),
      ],
    );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260 + 12 + lineWidth),
      child: Table(
        key: const ValueKey('first-choices'),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: const {
          0: IntrinsicColumnWidth(),
          1: FixedColumnWidth(12),
          2: FlexColumnWidth(),
        },
        children: [
          choice(
            key: const ValueKey('first-import-folder'),
            icon: Icons.drive_folder_upload_outlined,
            label: 'Import folder',
            line: 'Copy packs from a folder on your computer.',
            onPressed: () => importFolder(context, ref),
          ),
          choice(
            key: const ValueKey('first-import-archive'),
            icon: Icons.archive_outlined,
            label: 'Import archive',
            line:
                'Unpack zip, tar, 7z or rar files into the library '
                '(or drop them on the window).',
            onPressed: () => importArchive(context, ref),
          ),
          choice(
            key: const ValueKey('first-itch'),
            icon: Icons.storefront_outlined,
            label: connected ? 'Import from itch.io' : 'Connect itch.io',
            line: connected
                ? 'Download the assets you own on itch.io.'
                : 'Sign in with an API key to download the assets you own.',
            onPressed: () => openItch(context),
          ),
        ],
      ),
    );
  }
}

/// The app bar's import button: one icon with a menu for a folder or
/// archives. The shortcuts and drag-and-drop work without it.
class _ImportMenu extends ConsumerWidget {
  const _ImportMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<void Function()>(
      key: const ValueKey('import-menu'),
      tooltip: 'Import',
      icon: const Icon(Icons.download_outlined),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: () => importFolder(context, ref),
          child: ListTile(
            leading: const Icon(Icons.drive_folder_upload_outlined),
            title: Text('Import folder… (${AppKeys.importFolder.keys})'),
          ),
        ),
        PopupMenuItem(
          value: () => importArchive(context, ref),
          child: ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: Text('Import archive… (${AppKeys.importArchive.keys})'),
          ),
        ),
      ],
    );
  }
}

/// Accepts files dragged in from the desktop and shows a hint while
/// something hovers.
class DropZone extends StatefulWidget {
  const DropZone({super.key, required this.onDrop, required this.child});

  final ValueChanged<List<String>> onDrop;
  final Widget child;

  @override
  State<DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<DropZone> {
  var _hovering = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DropTarget(
      onDragEntered: (_) => setState(() => _hovering = true),
      onDragExited: (_) => setState(() => _hovering = false),
      onDragDone: (details) {
        setState(() => _hovering = false);
        widget.onDrop([for (final f in details.files) f.path]);
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          if (_hovering)
            IgnorePointer(
              child: Container(
                margin: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer.withValues(alpha: 0.85),
                  border: Border.all(color: scheme.primary, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.file_download,
                        size: 64,
                        color: scheme.primary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Drop archives or folders to import',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Shown while a newly chosen library scans: the logo, a spinner and the
/// folder being read.
class _ScanningLibrary extends StatelessWidget {
  const _ScanningLibrary({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: const ValueKey('library-wait'),
    child: _Message(
      header: const AppLogo(height: 112),
      visual: const SizedBox.square(
        dimension: 48,
        child: CircularProgressIndicator(),
      ),
      title: 'Please wait while we scan your library',
      body: path,
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message({
    this.icon,
    this.visual,
    required this.title,
    required this.body,
    this.action,
    this.header,
  }) : assert((icon == null) != (visual == null));

  /// Shown above the icon (the first-start screen's name and slogan).
  final Widget? header;
  final IconData? icon;

  /// In place of [icon], e.g. a spinner.
  final Widget? visual;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The text keeps to a readable width; the action may be wider (the
    // empty library's three choices, each with a line beside it).
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (header != null) ...[header!, const SizedBox(height: 32)],
                  visual ??
                      Icon(icon, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(title, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(body, textAlign: TextAlign.center),
                ],
              ),
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}
