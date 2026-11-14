import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/sidecar.dart';
import '../install/archive_extractor.dart';
import '../install/folder_importer.dart';
import '../state/dashboard.dart' show knownAuthors, knownTags;
import '../state/providers.dart';
import 'format.dart';
import 'widgets/drop_zone.dart';
import 'widgets/meta_dialogs.dart';
import 'widgets/overflow_text.dart';
import 'cursors.dart';

/// Top-level so the isolate closure captures nothing but its arguments.
Future<ImportPlan> _planInBackground(
  String source,
  String library,
  Map<String, String> origins,
) => Isolate.run(() => planFolderImport(source, library, origins: origins));

/// Top-level so the isolate closure captures nothing but its arguments.
Future<ImportPlan> _planUnpackedInBackground(
  String folder,
  String library,
  String work,
) => Isolate.run(() => planFolderImportUnpacked(folder, library, work));

/// Top-level so the isolate closure captures nothing but its arguments.
Future<ExtractedArchive> _extractInBackground(String archive, String dest) =>
    Isolate.run(() => extractArchive(archive, dest));

enum _Phase { review, importing, done }

/// Imports folders and archives: adds them to the open import review, or
/// opens one. Anything else is reported.
Future<void> importPaths(
  BuildContext context,
  WidgetRef ref,
  List<String> paths,
) async {
  final usable = [
    for (final path in paths)
      if (FileSystemEntity.isDirectorySync(path) ||
          (archiveKindOf(path) != null && File(path).existsSync()))
        path,
  ];
  final skipped = paths.length - usable.length;
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
  if (usable.isEmpty || FolderImportScreen.addToOpen(usable)) return;
  await Navigator.of(context, rootNavigator: true).push<void>(
    MaterialPageRoute(
      settings: const RouteSettings(name: FolderImportScreen.routeName),
      builder: (_) => FolderImportScreen(paths: usable),
    ),
  );
}

/// Review table for importing folders and archives into the library.
///
/// [paths] are folders and archives (zip, rar, 7z, tar). Archives, and
/// folders holding archives, are unpacked into a temporary folder, removed
/// when the screen closes; the sources themselves are never touched. More can be added while the
/// screen is open ([addToOpen]): dropped files join this review instead of
/// opening another one.
///
/// Rescans the library when an import finishes.
class FolderImportScreen extends ConsumerStatefulWidget {
  /// Its route's name, so app-wide shortcuts can tell it is open.
  static const routeName = 'folder-import';

  const FolderImportScreen({super.key, required this.paths});

  final List<String> paths;

  /// The open import review, if any.
  static _FolderImportScreenState? _open;

  /// Whether an import review is open.
  static bool get isOpen => _open?.mounted ?? false;

  /// Adds [paths] to the open import review; false when none is open.
  static bool addToOpen(List<String> paths) {
    final open = _open;
    if (open == null || !open.mounted) return false;
    open._add(paths);
    return true;
  }

  @override
  ConsumerState<FolderImportScreen> createState() => _FolderImportScreenState();
}

class _FolderImportScreenState extends ConsumerState<FolderImportScreen> {
  var _phase = _Phase.review;

  /// Every pack found so far, from all sources; null until the first
  /// source is planned.
  ImportPlan? _plan;

  /// Sources still to extract or plan, worked off one at a time.
  final _queue = <String>[];

  /// The source being worked on, and what is done with it ('' when idle).
  String? _current;
  var _status = '';

  /// The folders and archives in this review.
  final _folders = <String>[];
  final _archives = <String>[];

  /// Problems with single sources (failed extraction, overlapping folders).
  final _notes = <String>[];

  /// Extraction folders, removed when the screen closes.
  final _temps = <Directory>[];

  final _outcomes = <ImportOutcome>[];
  var _total = 0;

  bool get _busy => _queue.isNotEmpty || _current != null;

  @override
  void initState() {
    super.initState();
    FolderImportScreen._open = this;
    _queue.addAll(widget.paths);
    // After this build: the queue calls setState.
    Future.microtask(_drain);
  }

  @override
  void dispose() {
    if (FolderImportScreen._open == this) FolderImportScreen._open = null;
    for (final temp in _temps) {
      temp.delete(recursive: true).ignore();
    }
    super.dispose();
  }

  /// Queues [paths] for this review. While importing nothing can be added;
  /// once done, the added paths start a new review here.
  void _add(List<String> paths) {
    if (_phase == _Phase.importing) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Wait for this import to finish, then drop again'),
        ),
      );
      return;
    }
    if (_phase == _Phase.done) {
      setState(() {
        _phase = _Phase.review;
        _plan = null;
        _folders.clear();
        _archives.clear();
        _notes.clear();
        _outcomes.clear();
      });
    }
    // A folder or archive already here is not looked at again.
    final have = {
      for (final path in [..._folders, ..._archives, ?_current, ..._queue])
        p.canonicalize(path),
    };
    final fresh = [
      for (final path in paths)
        if (have.add(p.canonicalize(path))) path,
    ];
    if (fresh.isEmpty) return;
    final wasBusy = _busy;
    setState(() => _queue.addAll(fresh));
    if (!wasBusy) _drain();
  }

  Future<void> _drain() async {
    final library = ref.read(settingsProvider).libraryPath!;
    while (_queue.isNotEmpty && mounted) {
      final path = _current = _queue.removeAt(0);
      final isArchive = archiveKindOf(path) != null && File(path).existsSync();
      setState(
        () => _status = isArchive
            ? 'Extracting ${p.basename(path)}…'
            : 'Looking for packs in ${p.basename(path)}…',
      );
      try {
        final ImportPlan plan;
        final temp = Directory(
          p.join(
            ref.read(extractRootProvider),
            'import-${DateTime.now().microsecondsSinceEpoch}',
          ),
        )..createSync(recursive: true);
        _temps.add(temp);
        if (isArchive) {
          final extracted = await _extractInBackground(path, temp.path);
          if (!mounted) return;
          setState(() => _status = 'Looking for packs in ${p.basename(path)}…');
          plan = await _planInBackground(temp.path, library, {
            p.basename(extracted.folder): extracted.archivePath,
          });
        } else {
          // Archives inside are unpacked into a copy in [temp] first.
          plan = await _planUnpackedInBackground(path, library, temp.path);
        }
        if (!mounted) return;
        setState(() {
          (isArchive ? _archives : _folders).add(path);
          _merge(plan);
        });
      } on Object catch (e) {
        if (!mounted) return;
        setState(
          () => _notes.add(switch (e) {
            ExtractError(:final message) => message,
            OverlappingFoldersError() => importErrorMessage(e),
            _ => '${p.basename(path)}: $e',
          }),
        );
      }
    }
    if (mounted) setState(() => (_current = null, _status = ''));
  }

  /// Adds the packs of [plan] that are not in this review yet (the same
  /// folder or archive dropped twice).
  void _merge(ImportPlan plan) {
    final current = _plan;
    if (current == null) {
      _plan = plan;
      return;
    }
    String key(ImportItem i) => p.canonicalize(i.origin ?? i.sourcePath);
    final have = {for (final i in current.items) key(i)};
    current.items.addAll(plan.items.where((i) => have.add(key(i))));
  }

  Future<void> _import() async {
    final plan = _plan!;
    setState(() {
      _phase = _Phase.importing;
      _total = plan.selected.length;
      _outcomes.clear();
    });
    await for (final o in runImport(plan)) {
      if (!mounted) return;
      setState(() => _outcomes.add(o));
    }
    if (!mounted) return;
    setState(() => _phase = _Phase.done);
    // Here, not on Done: the review may be left by back or Esc as well.
    // The dashboard keeps its packs shown until the scan is through.
    if (_outcomes.any((o) => o.verified)) {
      ref.read(libraryProvider.notifier).reload();
    }
  }

  /// Author picker entries: the authors on this import's rows first (a
  /// name typed on one row is offered on the next), then the library's
  /// authors with their pack counts, then the rest found in this import.
  List<AuthorChoice> _authorChoices() {
    final packs = ref.read(libraryProvider).value?.packs ?? const [];
    final urls = {for (final a in _knownAuthors()) a.user: a.url};
    final counts = {
      for (final (name, n) in knownAuthors(packs)) name.toLowerCase(): n,
    };
    final out = <AuthorChoice>[];
    final seen = <String>{};
    void add(String name, String? url) {
      final key = name.toLowerCase();
      if (seen.add(key)) {
        out.add(AuthorChoice(name, packs: counts[key] ?? 0, url: url));
      }
    }

    for (final i in _plan?.items ?? const <ImportItem>[]) {
      if (i.author case final a?) add(a.user, a.url ?? urls[a.user]);
    }
    for (final (name, _) in knownAuthors(packs)) {
      add(name, urls[name]);
    }
    for (final a in _knownAuthors()) {
      add(a.user, a.url);
    }
    return out;
  }

  /// Tag suggestions: the tags on this import's rows first (a tag made on
  /// one row is offered on the next), then the library's, most used first.
  List<String> _knownTags() {
    final seen = <String>{};
    return [
      for (final i in _plan?.items ?? const <ImportItem>[])
        for (final t in i.tags)
          if (seen.add(t)) t,
      for (final t in knownTags(ref))
        if (seen.add(t)) t,
    ];
  }

  /// Authors already in the library plus those found in this import.
  List<AuthorInfo> _knownAuthors() {
    final byName = <String, AuthorInfo>{};
    for (final p in ref.read(libraryProvider).value?.packs ?? const []) {
      if (p.author != null) {
        byName[p.author!] ??= AuthorInfo(user: p.author!, url: p.authorUrl);
      }
    }
    for (final i in _plan?.items ?? const <ImportItem>[]) {
      if (i.author != null) byName[i.author!.user] ??= i.author!;
    }
    return byName.values.toList()..sort((a, b) => a.user.compareTo(b.user));
  }

  /// From what was added, also what is still being extracted or planned.
  String get _title {
    final all = [..._folders, ..._archives, ?_current, ..._queue];
    final archives = all.where((p) => archiveKindOf(p) != null).length;
    final folders = all.length - archives;
    if (archives == 0) return folders > 1 ? 'Import folders' : 'Import folder';
    if (folders == 0) {
      return archives > 1 ? 'Import archives' : 'Import archive';
    }
    return 'Import';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        automaticallyImplyLeading: _phase != _Phase.importing,
      ),
      body: DropZone(
        onDrop: (paths) => importPaths(context, ref, paths),
        child: _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final plan = _plan;
    return switch (_phase) {
      _Phase.review when plan == null && !_busy => _ErrorMessage(
        _notes.isEmpty ? 'Nothing to import' : _notes.join('\n'),
      ),
      _Phase.review when plan == null => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(_status),
          ],
        ),
      ),
      _Phase.review => _review(context),
      _Phase.importing || _Phase.done => _progress(context),
    };
  }

  /// "3 packs found in /some/folder", or in "2 folders and 1 archive".
  List<InlineSpan> _foundIn(ThemeData theme, ImportPlan plan) {
    final title = theme.textTheme.titleMedium;
    final found = '${plan.items.length} packs found in ';
    if (_archives.isEmpty && _folders.length == 1) {
      return [
        TextSpan(text: found, style: title),
        TextSpan(
          text: plan.sourceRoot,
          style: title?.copyWith(fontFamily: 'monospace'),
        ),
      ];
    }
    String count(int n, String word) => '$n ${n == 1 ? word : '${word}s'}';
    return [
      TextSpan(
        text:
            found +
            [
              if (_folders.isNotEmpty) count(_folders.length, 'folder'),
              if (_archives.isNotEmpty) count(_archives.length, 'archive'),
            ].join(' and '),
        style: title,
      ),
    ];
  }

  Widget _review(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _plan!;
    final targets = plan.targets();
    final selected = plan.selected.toList();
    final files = selected.fold(0, (n, i) => n + i.fileCount);
    final bytes = selected.fold(0, (n, i) => n + i.totalBytes);
    final unknown = selected.where((i) => i.author == null).length;
    final allSelected = selected.length == plan.items.length;
    final kept = switch ((_folders.isEmpty, _archives.isEmpty)) {
      (false, true) => 'the source folder is never changed',
      (true, false) => 'the archives are kept',
      _ => 'source folders and archives are never changed',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Room for the bar, so the list doesn't jump when it goes.
        SizedBox(
          height: 4,
          child: _busy ? const LinearProgressIndicator() : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Text.rich(
            TextSpan(
              children: [
                ..._foundIn(theme, plan),
                TextSpan(
                  text:
                      '\nFiles are copied into ${plan.libraryRoot}; $kept. '
                      'Click an author, type or tag to edit it.',
                  style: theme.textTheme.bodySmall,
                ),
                if (_busy)
                  TextSpan(
                    text: '\n$_status',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
          ),
        ),
        for (final note in _notes)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Card(
              margin: EdgeInsets.zero,
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                leading: const Icon(Icons.error_outline),
                title: Text(note),
              ),
            ),
          ),
        _HeaderRow(
          value: allSelected ? true : (selected.isEmpty ? false : null),
          onChanged: (v) => setState(() {
            for (final i in plan.items) {
              i.selected = v ?? false;
            }
          }),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: plan.items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = plan.items[index];
              return _ItemRow(
                item: item,
                target: targets[item],
                onChanged: () => setState(() {}),
                knownAuthors: _knownAuthors,
                authorChoices: _authorChoices,
                knownTags: _knownTags,
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: unknown > 0
                    ? Text(
                        '$unknown selected packs have no author; '
                        'they go to "$unknownAuthor".',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: theme.colorScheme.error),
                      )
                    : const SizedBox(),
              ),
              Text(
                '${formatCount(files)} files · ${formatBytes(bytes)}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: selected.isEmpty || _busy ? null : _import,
                icon: const Icon(Icons.download_done),
                label: Text('Import ${selected.length} packs'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _progress(BuildContext context) {
    final theme = Theme.of(context);
    final done = _phase == _Phase.done;
    final failed = _outcomes.where((o) => !o.verified).toList();
    final copied = _outcomes.fold(0, (n, o) => n + o.copiedFiles);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            done
                ? '${_outcomes.length - failed.length} of $_total packs imported '
                      'and verified${failed.isEmpty ? '' : ', ${failed.length} failed'}'
                : 'Importing ${_outcomes.length + 1} of $_total…',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: _total == 0 ? null : _outcomes.length / _total,
          ),
          const SizedBox(height: 8),
          Text(
            '${formatCount(copied)} files copied, every file checked '
            'against the source by SHA-1.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView(
              children: [
                for (final o in _outcomes.reversed)
                  ListTile(
                    dense: true,
                    leading: Icon(
                      o.verified ? Icons.check_circle : Icons.error,
                      color: o.verified
                          ? theme.colorScheme.primary
                          : theme.colorScheme.error,
                    ),
                    title: Text(o.title),
                    subtitle: Text(
                      o.error ??
                          '${o.target} · ${o.copiedFiles} files · '
                              '${formatBytes(o.bytes)}',
                    ),
                  ),
              ],
            ),
          ),
          if (done)
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Done'),
              ),
            ),
        ],
      ),
    );
  }
}

const _colPack = 4;
const _colAuthor = 4;
const _colTypes = 3;
const _colTags = 3;
const _colSize = 2;
const _colTarget = 4;

class _HeaderRow extends StatelessWidget {
  const _HeaderRow({required this.value, required this.onChanged});

  final bool? value;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    Widget col(int flex, String text) => Expanded(
      flex: flex,
      child: Text(text, style: style),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Checkbox(tristate: true, value: value, onChanged: onChanged),
          col(_colPack, 'Pack'),
          col(_colAuthor, 'Author'),
          col(_colTypes, 'Types'),
          col(_colTags, 'Tags'),
          col(_colSize, 'Files'),
          col(_colTarget, 'Library folder'),
        ],
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({
    required this.item,
    required this.target,
    required this.onChanged,
    required this.knownAuthors,
    required this.authorChoices,
    required this.knownTags,
  });

  final ImportItem item;
  final String? target;
  final VoidCallback onChanged;
  final List<AuthorInfo> Function() knownAuthors;
  final List<AuthorChoice> Function() authorChoices;
  final List<String> Function() knownTags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final muted = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final renamed = target != null && !target!.endsWith('/${item.folderName}');

    Widget editable(int flex, Widget child, Future<void> Function() onTap) =>
        Expanded(
          flex: flex,
          child: InkWell(
            mouseCursor: clickCursor,
            onTap: () async {
              await onTap();
              onChanged();
            },
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: child,
            ),
          ),
        );

    return Opacity(
      opacity: item.selected ? 1 : 0.55,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            Checkbox(
              value: item.selected,
              onChanged: (v) {
                item.selected = v ?? false;
                onChanged();
              },
            ),
            Expanded(
              flex: _colPack,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: OverflowText(
                          item.title,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (item.isContainer) ...[
                        const SizedBox(width: 6),
                        _Badge('bundle · ${item.subPackCount} sub-packs'),
                      ],
                    ],
                  ),
                  // The source path, when it says more than the title.
                  if (item.sourceRel != '.' && item.sourceRel != item.title)
                    OverflowText(item.sourceRel, style: muted),
                ],
              ),
            ),
            Expanded(
              flex: _colAuthor,
              child: Row(
                children: [
                  Expanded(
                    child: AuthorPicker(
                      // A new field when the author changes from elsewhere.
                      key: ValueKey(item.author?.user),
                      author: item.author,
                      choices: authorChoices,
                      onChanged: (a) {
                        item.author = a;
                        onChanged();
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: 'Edit author and profile URL',
                    visualDensity: VisualDensity.compact,
                    iconSize: 16,
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () async {
                      final a = await showDialog<AuthorInfo>(
                        context: context,
                        builder: (_) => AuthorDialog(
                          initial: item.author,
                          known: knownAuthors(),
                        ),
                      );
                      if (a != null) {
                        item.author = a;
                        onChanged();
                      }
                    },
                  ),
                ],
              ),
            ),
            editable(
              _colTypes,
              Wrap(
                spacing: 4,
                runSpacing: 2,
                children: [for (final t in item.types) _Badge(t)],
              ),
              () async {
                final t = await showDialog<List<String>>(
                  context: context,
                  builder: (_) => TypesDialog(initial: item.types),
                );
                if (t != null) item.types = t;
              },
            ),
            editable(
              _colTags,
              item.tags.isEmpty
                  ? Text('—', style: small)
                  : Wrap(
                      spacing: 4,
                      runSpacing: 2,
                      children: [for (final t in item.tags) _Badge(t)],
                    ),
              () async {
                final t = await showDialog<List<String>>(
                  context: context,
                  builder: (_) =>
                      TagsDialog(initial: item.tags, known: knownTags()),
                );
                if (t != null) item.tags = t;
              },
            ),
            Expanded(
              flex: _colSize,
              child: Text(
                '${formatCount(item.fileCount)}\n${formatBytes(item.totalBytes)}',
                style: small,
              ),
            ),
            Expanded(
              flex: _colTarget,
              child: item.importedAs != null && !item.selected
                  ? OverflowText(
                      'Already imported as ${item.importedAs}',
                      style: muted,
                    )
                  : Row(
                      children: [
                        if (renamed)
                          Tooltip(
                            message:
                                'A folder with this name exists; '
                                'a number is added',
                            child: Icon(
                              Icons.info_outline,
                              size: 16,
                              color: theme.colorScheme.tertiary,
                            ),
                          ),
                        Flexible(
                          child: OverflowText(
                            target ?? '—',
                            key: const ValueKey('import-target'),
                            style: small?.copyWith(fontFamily: 'monospace'),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}

/// What the import screens say about [error]: a plain explanation for
/// known problems, the error itself otherwise.
String importErrorMessage(Object error) => switch (error) {
  OverlappingFoldersError(:final message) => message,
  _ => 'Cannot import: $error',
};

class _ErrorMessage extends StatelessWidget {
  const _ErrorMessage(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One entry of the [AuthorPicker]: an author and how many packs the
/// library has from them (0: only in this import).
class AuthorChoice {
  const AuthorChoice(this.name, {this.packs = 0, this.url, this.isNew = false});

  final String name;
  final int packs;
  final String? url;

  /// The "Add new author …" entry.
  final bool isNew;
}

/// The author cell of the import review: type to filter the library's
/// authors, pick one, or add a new one. An unknown author starts empty, and
/// the suggestions open as soon as the field gets focus.
class AuthorPicker extends StatefulWidget {
  const AuthorPicker({
    super.key,
    required this.author,
    required this.choices,
    required this.onChanged,
  });

  final AuthorInfo? author;
  final List<AuthorChoice> Function() choices;

  /// The chosen author, or null when the field was cleared.
  final ValueChanged<AuthorInfo?> onChanged;

  @override
  State<AuthorPicker> createState() => _AuthorPickerState();
}

class _AuthorPickerState extends State<AuthorPicker> {
  late final _controller = TextEditingController(
    text: widget.author?.user ?? '',
  );
  final _focus = FocusNode(debugLabel: 'author');

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (_focus.hasFocus) {
      // Selecting the text also makes the autocomplete list its options,
      // so they show on focus, even for an empty field.
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    } else {
      _commit(_controller.text);
    }
  }

  /// Takes typed text as the author: a known one (any case) or a new name.
  void _commit(String text, {String? url}) {
    final name = text.trim();
    final current = widget.author;
    if (name.isEmpty) {
      if (current != null) widget.onChanged(null);
      return;
    }
    if (name == current?.user) return;
    final known = widget
        .choices()
        .where((c) => c.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
    widget.onChanged(
      AuthorInfo(user: known?.name ?? name, url: url ?? known?.url),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RawAutocomplete<AuthorChoice>(
      textEditingController: _controller,
      focusNode: _focus,
      displayStringForOption: (c) => c.name,
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        final all = widget.choices();
        final hits = [
          for (final c in all)
            if (q.isEmpty || c.name.toLowerCase().contains(q)) c,
        ];
        final exact = all.any((c) => c.name.toLowerCase() == q);
        return [
          ...hits,
          if (!exact) AuthorChoice(value.text.trim(), isNew: true),
        ];
      },
      onSelected: (c) {
        if (c.isNew && c.name.isEmpty) {
          // "Add new author…" with nothing typed yet: type the name.
          _controller.clear();
          _focus.requestFocus();
          return;
        }
        _commit(c.name, url: c.url);
        _focus.unfocus();
      },
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
        controller: controller,
        focusNode: focus,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          // Only built while unknown (a hint is laid out even when hidden).
          hintText: widget.author == null ? 'Unknown — set author' : null,
          hintStyle: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        onSubmitted: (_) => onSubmit(),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              shrinkWrap: true,
              children: [
                for (final (i, c) in options.indexed)
                  _AuthorOption(
                    choice: c,
                    highlighted: AutocompleteHighlightedOption.of(context) == i,
                    onTap: () => onSelected(c),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthorOption extends StatelessWidget {
  const _AuthorOption({
    required this.choice,
    required this.highlighted,
    required this.onTap,
  });

  final AuthorChoice choice;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = choice;
    final color = highlighted ? theme.colorScheme.primary : null;
    return InkWell(
      mouseCursor: clickCursor,
      onTap: onTap,
      child: Container(
        color: highlighted
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : null,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Icon(
              c.isNew ? Icons.person_add_alt : Icons.person_outline,
              size: 16,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                c.isNew
                    ? (c.name.isEmpty
                          ? 'Add new author…'
                          : 'Add new author “${c.name}”')
                    : c.name,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
            if (!c.isNew) ...[
              const SizedBox(width: 8),
              Text(
                c.packs == 0
                    ? 'new'
                    : '${c.packs} ${c.packs == 1 ? 'pack' : 'packs'}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
