import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/itch.dart';
import '../state/providers.dart';
import '../state/settings.dart';
import 'itch_screen.dart';

/// Keyboard shortcuts, listed on the settings screen.
const shortcutHelp = [
  ('/  or  Ctrl+F', 'Search the library'),
  ('Esc', 'Leave search, close a page'),
  ('Ctrl+I', 'Import folder'),
  ('Ctrl+O', 'Import archive'),
  ('F5  or  Ctrl+R', 'Rescan the library'),
  ('Ctrl+,', 'Settings'),
];

class SettingsScreen extends ConsumerWidget {
  /// Its route's name, so Ctrl+, doesn't open it twice.
  static const routeName = 'settings';

  const SettingsScreen({super.key});

  Future<void> _changeLibrary(BuildContext context, WidgetRef ref) async {
    final path = await ref.read(directoryPickerProvider)('Use as library');
    if (path == null || !context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Switch library?'),
        content: Text(
          'Asset Explorer will manage $path: it writes pack and author '
          'files there when you import or edit. Nothing is moved from the '
          'current library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(settingsProvider.notifier).setLibraryPath(path);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final notifier = ref.read(settingsProvider.notifier);
    final theme = Theme.of(context);
    final key = ref.watch(itchKeyProvider);
    final user = key.value == null
        ? null
        : ref.watch(itchAccountProvider).value?.user;
    final library = ref.watch(libraryProvider).value;
    final packCount = library?.topLevel.length;

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            children: [
              section('Library'),
              ListTile(
                leading: const Icon(Icons.folder_special_outlined),
                title: Text(settings.libraryPath ?? 'Not chosen'),
                subtitle: Text(
                  packCount == null
                      ? 'The folder Asset Explorer manages (Author/Pack)'
                      : '$packCount packs, ${library!.packs.length} '
                            'including bundle contents',
                ),
                trailing: OutlinedButton(
                  onPressed: () => _changeLibrary(context, ref),
                  child: const Text('Change…'),
                ),
              ),
              section('Appearance'),
              ListTile(
                leading: const Icon(Icons.brightness_6_outlined),
                title: const Text('Theme'),
                trailing: SegmentedButton<ThemeChoice>(
                  segments: const [
                    ButtonSegment(
                      value: ThemeChoice.system,
                      label: Text('System'),
                    ),
                    ButtonSegment(
                      value: ThemeChoice.light,
                      label: Text('Light'),
                    ),
                    ButtonSegment(value: ThemeChoice.dark, label: Text('Dark')),
                  ],
                  selected: {settings.theme},
                  onSelectionChanged: (s) => notifier.setTheme(s.first),
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.animation),
                title: const Text('Animate all sprite previews on dashboard'),
                subtitle: const Text(
                  'Off: a sprite plays while the pointer is over its tile. '
                  'The Animations tab has its own All / Hover toggle.',
                ),
                value: settings.animateAll,
                onChanged: notifier.setAnimateAll,
              ),
              section('itch.io'),
              ListTile(
                leading: const Icon(Icons.storefront_outlined),
                title: Text(switch (key) {
                  AsyncData(value: null) => 'Not connected',
                  AsyncData() when user != null =>
                    'Connected as ${user.username}',
                  AsyncData() => 'Connected',
                  _ => 'Checking…',
                }),
                subtitle: const Text(
                  'Optional. The API key is kept in the system keychain.',
                ),
                trailing: Wrap(
                  spacing: 8,
                  children: [
                    if (key.value != null)
                      TextButton(
                        onPressed: () =>
                            ref.read(itchKeyProvider.notifier).disconnect(),
                        child: const Text('Disconnect'),
                      ),
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ItchScreen(),
                        ),
                      ),
                      child: Text(key.value == null ? 'Connect…' : 'Open'),
                    ),
                  ],
                ),
              ),
              section('Keyboard shortcuts'),
              for (final (keys, action) in shortcutHelp)
                ListTile(
                  dense: true,
                  leading: SizedBox(
                    width: 140,
                    child: Text(
                      keys,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  title: Text(action),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
