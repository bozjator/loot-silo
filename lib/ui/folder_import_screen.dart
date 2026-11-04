import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/sidecar.dart';
import '../install/folder_importer.dart';
import '../state/providers.dart';
import 'format.dart';
import 'widgets/meta_dialogs.dart';

/// Top-level so the isolate closure captures nothing but its arguments.
Future<ImportPlan> _planInBackground(
  String source,
  String library,
  Map<String, String> origins,
) => Isolate.run(() => planFolderImport(source, library, origins: origins));

enum _Phase { planning, review, importing, done }

/// Review table for importing an existing folder into the library.
///
/// Pops with `true` when anything was imported.
class FolderImportScreen extends ConsumerStatefulWidget {
  const FolderImportScreen({
    super.key,
    required this.sourcePath,
    this.origins = const {},
    this.title = 'Import folder',
    this.notes = const [],
  });

  final String sourcePath;

  /// Top-level folder → archive it came from (see [planFolderImport]).
  final Map<String, String> origins;
  final String title;

  /// Problems from an earlier step (e.g. archives that failed to extract).
  final List<String> notes;

  @override
  ConsumerState<FolderImportScreen> createState() => _FolderImportScreenState();
}

class _FolderImportScreenState extends ConsumerState<FolderImportScreen> {
  var _phase = _Phase.planning;
  ImportPlan? _plan;
  Object? _error;
  final _outcomes = <ImportOutcome>[];
  var _total = 0;

  @override
  void initState() {
    super.initState();
    _makePlan();
  }

  Future<void> _makePlan() async {
    final source = widget.sourcePath;
    final library = ref.read(settingsProvider).libraryPath!;
    try {
      final plan = await _planInBackground(source, library, widget.origins);
      if (mounted) setState(() => (_plan = plan, _phase = _Phase.review));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
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
    if (mounted) setState(() => _phase = _Phase.done);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        automaticallyImplyLeading: _phase != _Phase.importing,
      ),
      body: switch (_phase) {
        _ when _error != null => Center(child: Text('Cannot import: $_error')),
        _Phase.planning => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Looking for packs…'),
            ],
          ),
        ),
        _Phase.review => _review(context),
        _Phase.importing || _Phase.done => _progress(context),
      },
    );
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: widget.origins.isEmpty
                      ? '${plan.items.length} packs found in '
                      : '${plan.items.length} packs found in '
                            '${widget.origins.length} '
                            '${widget.origins.length == 1 ? 'archive' : 'archives'}',
                  style: theme.textTheme.titleMedium,
                ),
                if (widget.origins.isEmpty)
                  TextSpan(
                    text: plan.sourceRoot,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                TextSpan(
                  text: widget.origins.isEmpty
                      ? '\nFiles are copied into ${plan.libraryRoot}; '
                            'the source folder is never changed. '
                            'Click an author, type or tag to edit it.'
                      : '\nExtracted files are copied into '
                            '${plan.libraryRoot}; the archives are kept. '
                            'Click an author, type or tag to edit it.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        for (final note in widget.notes)
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
              );
            },
          ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              if (unknown > 0)
                Text(
                  '$unknown selected packs have no author; '
                  'they go to "$unknownAuthor".',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              const Spacer(),
              Text(
                '${formatCount(files)} files · ${formatBytes(bytes)}',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(width: 16),
              FilledButton.icon(
                onPressed: selected.isEmpty ? null : _import,
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
                onPressed: () =>
                    Navigator.of(context).pop(_outcomes.isNotEmpty),
                child: const Text('Done'),
              ),
            ),
        ],
      ),
    );
  }
}

const _colPack = 5;
const _colAuthor = 3;
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
  });

  final ImportItem item;
  final String? target;
  final VoidCallback onChanged;
  final List<AuthorInfo> Function() knownAuthors;

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
                        child: Text(
                          item.title,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      if (item.isContainer) ...[
                        const SizedBox(width: 6),
                        _Badge('bundle · ${item.subPackCount} sub-packs'),
                      ],
                    ],
                  ),
                  Text(
                    item.sourceRel,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                ],
              ),
            ),
            editable(
              _colAuthor,
              item.author == null
                  ? Text(
                      'Unknown — set author',
                      style: small?.copyWith(color: theme.colorScheme.error),
                    )
                  : Text(
                      item.author!.user,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    ),
              () async {
                final a = await showDialog<AuthorInfo>(
                  context: context,
                  builder: (_) =>
                      AuthorDialog(initial: item.author, known: knownAuthors()),
                );
                if (a != null) item.author = a;
              },
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
              Text(
                item.tags.isEmpty ? '—' : item.tags.join(', '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: small,
              ),
              () async {
                final t = await showDialog<List<String>>(
                  context: context,
                  builder: (_) => TagsDialog(initial: item.tags),
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
                  ? Text('Already imported as ${item.importedAs}', style: muted)
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
                          child: Text(
                            target ?? '—',
                            overflow: TextOverflow.ellipsis,
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
