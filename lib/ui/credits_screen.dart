import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/credits.dart';
import '../core/library_index.dart';
import '../core/pack_editor.dart';
import '../state/providers.dart';
import 'widgets/meta_dialogs.dart';

enum _Format { markdown, text }

/// Games on the left; the chosen game's packs and its credits file on the
/// right, ready to copy or save.
class CreditsScreen extends ConsumerStatefulWidget {
  const CreditsScreen({super.key});

  @override
  ConsumerState<CreditsScreen> createState() => _CreditsScreenState();
}

class _CreditsScreenState extends ConsumerState<CreditsScreen> {
  String? _game;

  /// Games created here that have no packs yet.
  final _newGames = <String>{};
  var _format = _Format.markdown;

  Future<void> _newGame(List<String> known) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => GameNameDialog(known: known, title: 'New game'),
    );
    if (name == null) return;
    setState(() {
      if (!known.contains(name)) _newGames.add(name);
      _game = name;
    });
  }

  Future<void> _addPacks(List<PackRow> all, String game) async {
    final chosen = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _PackPickerDialog(
        packs: all,
        initial: {
          for (final pk in all)
            if (pk.usedIn.contains(game)) pk.id,
        },
      ),
    );
    if (chosen == null) return;
    for (final pk in all) {
      final used = chosen.contains(pk.id);
      if (used != pk.usedIn.contains(game) && packExists(pk.path)) {
        setUsedIn(pk.path, game, used: used);
      }
    }
    await ref.read(libraryProvider.notifier).reload();
  }

  Future<void> _remove(PackRow pk, String game) async {
    if (!packExists(pk.path)) return;
    setUsedIn(pk.path, game, used: false);
    await ref.read(libraryProvider.notifier).reload();
  }

  Future<void> _save(String game, String content) async {
    final ext = _format == _Format.markdown ? 'md' : 'txt';
    final path = await ref.read(saveLocationProvider)('CREDITS.$ext');
    if (path == null) return;
    await File(path).writeAsString(content);
    _toast('Saved $path');
  }

  void _toast(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(libraryProvider).value;
    final packs = library?.packs ?? const <PackRow>[];
    final games = {...knownGames(packs), ..._newGames}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    final game = games.contains(_game) ? _game : games.firstOrNull;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Credits')),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 260,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.tonalIcon(
                    onPressed: () => _newGame(games),
                    icon: const Icon(Icons.add),
                    label: const Text('New game'),
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final g in games)
                        ListTile(
                          title: Text(g),
                          subtitle: Text(
                            _packCount(packsUsedIn(packs, g).length),
                          ),
                          selected: g == game,
                          onTap: () => setState(() => _game = g),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: game == null || library?.root == null
                ? const Center(
                    child: Text(
                      'No games yet. Create one, or mark a pack as '
                      '"used in" from its detail page.',
                    ),
                  )
                : _GameCredits(
                    game: game,
                    root: library!.root!,
                    packs: packs,
                    format: _format,
                    onFormat: (f) => setState(() => _format = f),
                    onAdd: () => _addPacks(packs, game),
                    onRemove: (pk) => _remove(pk, game),
                    onCopy: (content) async {
                      await Clipboard.setData(ClipboardData(text: content));
                      _toast('Credits copied');
                    },
                    onSave: (content) => _save(game, content),
                    theme: theme,
                  ),
          ),
        ],
      ),
    );
  }
}

class _GameCredits extends StatelessWidget {
  const _GameCredits({
    required this.game,
    required this.root,
    required this.packs,
    required this.format,
    required this.onFormat,
    required this.onAdd,
    required this.onRemove,
    required this.onCopy,
    required this.onSave,
    required this.theme,
  });

  final String game;
  final String root;
  final List<PackRow> packs;
  final _Format format;
  final ValueChanged<_Format> onFormat;
  final VoidCallback onAdd;
  final ValueChanged<PackRow> onRemove;
  final ValueChanged<String> onCopy;
  final ValueChanged<String> onSave;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final used = packsUsedIn(packs, game);
    final authors = collectCredits(root, packs, game);
    final content = format == _Format.markdown
        ? creditsMarkdown(game, authors)
        : creditsText(game, authors);
    final unlicensed = [
      for (final a in authors)
        if (a.license == null) a.displayName,
    ];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(game, style: theme.textTheme.headlineSmall),
              ),
              SegmentedButton<_Format>(
                segments: const [
                  ButtonSegment(value: _Format.markdown, label: Text('.md')),
                  ButtonSegment(value: _Format.text, label: Text('.txt')),
                ],
                selected: {format},
                onSelectionChanged: (s) => onFormat(s.single),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: used.isEmpty ? null : () => onCopy(content),
                icon: const Icon(Icons.copy),
                label: const Text('Copy'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: used.isEmpty ? null : () => onSave(content),
                icon: const Icon(Icons.save_alt),
                label: const Text('Save…'),
              ),
            ],
          ),
          if (unlicensed.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                color: theme.colorScheme.tertiaryContainer,
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.warning_amber),
                  title: Text(
                    'No license on file for ${unlicensed.join(', ')}',
                  ),
                  subtitle: const Text(
                    'Check the store page and add it from a pack\'s author '
                    'info before release.',
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 340,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Text(
                            _packCount(used.length),
                            style: theme.textTheme.titleSmall,
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: onAdd,
                            icon: const Icon(Icons.playlist_add),
                            label: const Text('Choose packs…'),
                          ),
                        ],
                      ),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final pk in used)
                              ListTile(
                                dense: true,
                                title: Text(pk.title),
                                subtitle: Text(pk.author ?? ''),
                                trailing: IconButton(
                                  tooltip: 'Remove from $game',
                                  icon: const Icon(Icons.close),
                                  onPressed: () => onRemove(pk),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.all(16),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        content,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Searchable checklist of every pack.
class _PackPickerDialog extends StatefulWidget {
  const _PackPickerDialog({required this.packs, required this.initial});

  final List<PackRow> packs;
  final Set<String> initial;

  @override
  State<_PackPickerDialog> createState() => _PackPickerDialogState();
}

class _PackPickerDialogState extends State<_PackPickerDialog> {
  late final _selected = {...widget.initial};
  var _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final shown = [
      for (final pk in widget.packs)
        if (q.isEmpty ||
            pk.title.toLowerCase().contains(q) ||
            (pk.author ?? '').toLowerCase().contains(q))
          pk,
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return AlertDialog(
      title: Text('Choose packs (${_selected.length} selected)'),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Filter by title or author',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: shown.length,
                itemBuilder: (context, i) {
                  final pk = shown[i];
                  return CheckboxListTile(
                    dense: true,
                    value: _selected.contains(pk.id),
                    title: Text(pk.title),
                    subtitle: Text(
                      [
                        pk.author ?? 'Unknown author',
                        if (pk.parentId != null) 'in ${pk.parentId}',
                      ].join(' · '),
                    ),
                    onChanged: (on) => setState(
                      () =>
                          on! ? _selected.add(pk.id) : _selected.remove(pk.id),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

String _packCount(int n) => n == 1 ? '1 pack' : '$n packs';
