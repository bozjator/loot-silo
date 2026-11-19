import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/bundle_detector.dart';
import '../core/fs_tree.dart';
import '../core/library_index.dart';
import '../core/pack_detector.dart' show isPreviewDirName;
import '../core/pack_editor.dart';
import '../core/sidecar.dart';
import '../state/folder_folds.dart';
import '../state/favorites.dart';
import '../state/providers.dart';
import 'cursors.dart';
import 'dashboard.dart' show openPackDetail;
import 'format.dart';
import 'reveal.dart';
import 'tabs.dart';
import 'widgets/pack_tile.dart';
import 'widgets/pixel_image.dart';
import 'widgets/thumb_size.dart';

/// A bundle of packs (M95): its cover and details, then its packs under
/// their section headings. Opens where a pack page would (current tab, new
/// tab, session restore); Esc and mouse back leave it like a pack page.
class BundleScreen extends ConsumerStatefulWidget {
  const BundleScreen({super.key, required this.bundle});

  final PackRow bundle;

  @override
  ConsumerState<BundleScreen> createState() => _BundleScreenState();
}

class _BundleScreenState extends ConsumerState<BundleScreen> {
  /// Sections folded away, remembered per bundle like By folder folds.
  late final _collapsed = ref
      .read(folderFoldsProvider)
      .of(bundle.path, FoldTab.bundle);
  var _busy = false;

  PackRow get bundle => widget.bundle;

  Future<void> _merge() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Merge into one pack?'),
        content: Text(
          '"${bundle.title}" becomes one pack holding all its folders. '
          'No file moves, and each pack keeps its own details, so you can '
          'split it again from its page at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      setPackLayout(bundle.path, PackLayout.pack);
      await ref.read(libraryProvider.notifier).reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final packs = ref.watch(libraryProvider).value?.packs ?? const [];
    final children = [
      for (final pk in packs)
        if (pk.bundleId == bundle.id) pk,
    ];
    // Sections in folder order; packs outside any first.
    final bySection = <String?, List<PackRow>>{};
    for (final pk in children) {
      (bySection[pk.section] ??= []).add(pk);
    }
    final sections = [
      ...bySection.keys.where((s) => s == null),
      ...bySection.keys.where((s) => s != null),
    ];
    final tileSize = dashboardTileRange.clamp(
      ref.watch(settingsProvider.select((s) => s.dashboardTileSize)),
    );
    final animateAll = ref.watch(settingsProvider.select((s) => s.animateAll));
    final theme = Theme.of(context);
    const spacing = 12.0;
    return Scaffold(
      appBar: tabStripBar(ref) ?? AppBar(title: Text(bundle.title)),
      body: LayoutBuilder(
        builder: (context, box) {
          const pad = EdgeInsets.fromLTRB(16, 12, 16, 16);
          final width = box.maxWidth - pad.horizontal;
          final (count, tile) = thumbColumns(width, tileSize, spacing);
          final rows = <Widget>[
            _Header(
              bundle: bundle,
              packCount: children.length,
              busy: _busy,
              onMerge: _merge,
            ),
            for (final s in sections) ...[
              _SectionHeader(
                key: ValueKey('section:$s'),
                title: s ?? 'Packs',
                count: bySection[s]!.length,
                open: !_collapsed.contains(s ?? ''),
                onTap: () => setState(() {
                  if (!_collapsed.remove(s ?? '')) _collapsed.add(s ?? '');
                  ref
                      .read(folderFoldsProvider)
                      .set(bundle.path, FoldTab.bundle, _collapsed);
                }),
              ),
              if (!_collapsed.contains(s ?? ''))
                for (var r = 0; r * count < bySection[s]!.length; r++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: spacing),
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var c = 0; c < count; c++) ...[
                            if (c > 0) const SizedBox(width: spacing),
                            SizedBox(
                              width: tile,
                              child: switch (r * count + c) {
                                final i when i < bySection[s]!.length =>
                                  _packTile(bySection[s]![i], animateAll),
                                _ => null,
                              },
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
            ],
            if (children.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'This bundle holds no packs',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
          ];
          return ListView.builder(
            key: PageStorageKey('bundle:${bundle.id}'),
            padding: pad,
            itemCount: rows.length,
            itemBuilder: (context, i) => rows[i],
          );
        },
      ),
    );
  }

  Widget _packTile(PackRow pk, bool animateAll) {
    final favorites = ref.watch(favoritesProvider);
    return OpenInNewTab(
      key: ValueKey('bundle-pack:${pk.id}'),
      onOpenInNewTab: () => ref.read(tabsProvider.notifier).open(pk.id),
      child: PackTile(
        pack: pk,
        alwaysAnimate: animateAll,
        starred: favorites.isPack(pk.id),
        onToggleStar: () =>
            ref.read(favoritesProvider.notifier).togglePack(pk.id),
        onTap: () => openPackDetail(context, pk.id),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.bundle,
    required this.packCount,
    required this.busy,
    required this.onMerge,
  });

  final PackRow bundle;
  final int packCount;
  final bool busy;
  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final preview = bundle.preview;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 280,
              height: 210,
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.all(6),
              child: preview == null
                  ? Icon(
                      Icons.folder_copy_outlined,
                      size: 64,
                      color: scheme.onSurfaceVariant,
                    )
                  : PixelImage(File(p.join(bundle.path, preview))),
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.folder_copy_outlined, color: scheme.tertiary),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        bundle.title,
                        style: theme.textTheme.headlineSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  bundle.author ?? 'Unknown author',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Bundle of $packCount pack${packCount == 1 ? '' : 's'} · '
                  '${formatCount(bundle.fileCount)} files · '
                  '${formatBytes(bundle.totalBytes)}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  bundle.path,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.tonalIcon(
                      // Outlined like "Show in file manager" beside it.
                      style: FilledButton.styleFrom(
                        side: BorderSide(color: scheme.outline),
                      ),
                      icon: const Icon(Icons.call_merge, size: 18),
                      label: const Text('Merge into one pack'),
                      onPressed: busy ? null : onMerge,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.folder_open, size: 18),
                      label: const Text('Show in file manager'),
                      onPressed: () => ref.read(revealProvider)(bundle.path),
                    ),
                    if (busy)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    super.key,
    required this.title,
    required this.count,
    required this.open,
    required this.onTap,
  });

  final String title;
  final int count;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        mouseCursor: clickCursor,
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(open ? Icons.expand_more : Icons.chevron_right),
              const SizedBox(width: 4),
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(width: 8),
              Text(
                formatCount(count),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Whether [path] has two or more folders that could be packs, or one
/// folder holding two or more (a section, Kenney's `2D assets`): the pack
/// page offers "Split into packs…" then; its dialog says when the closer
/// look finds nothing to split.
bool canSplitIntoPacks(String path) {
  List<Directory> dirs(String at) =>
      Directory(at)
          .listSync(followLinks: false)
          .whereType<Directory>()
          .where((d) {
            final name = p.basename(d.path);
            return !name.startsWith('_') && !isPreviewDirName(name);
          })
          .toList();
  try {
    final top = dirs(path);
    return top.length >= 2 ||
        top.length == 1 && dirs(top.single.path).length >= 2;
  } on FileSystemException {
    return false;
  }
}

/// "Split into packs…" on a pack's header (M95): shows what the pack would
/// split into, then saves `layout: bundle` and rescans.
class SplitPackButton extends ConsumerWidget {
  const SplitPackButton({super.key, required this.pack});

  final PackRow pack;

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    tooltip: 'Split into packs…',
    visualDensity: VisualDensity.compact,
    icon: const Icon(Icons.call_split),
    onPressed: () async {
      final plan = BundleDetector().force(readTree(pack.path));
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => _SplitDialog(pack: pack, plan: plan),
      );
      if (ok != true) return;
      setPackLayout(pack.path, PackLayout.bundle);
      await ref.read(libraryProvider.notifier).reload();
    },
  );
}

class _SplitDialog extends StatelessWidget {
  const _SplitDialog({required this.pack, required this.plan});

  final PackRow pack;
  final BundlePlan? plan;

  static const _shown = 12;

  @override
  Widget build(BuildContext context) {
    final plan = this.plan;
    final theme = Theme.of(context);
    if (plan == null) {
      return AlertDialog(
        title: const Text('Split into packs'),
        content: const Text(
          'Nothing to split: a pack needs two or more folders with files to '
          'split into packs.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Close'),
          ),
        ],
      );
    }
    final names = [
      for (final c in plan.packs)
        c.section == null ? c.dir.name : '${c.section} › ${c.dir.name}',
    ];
    return AlertDialog(
      title: Text('Split "${pack.title}" into ${plan.packs.length} packs?'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'It becomes a bundle: each pack gets its own tile, page and '
              'details, and searches and filters list them directly. No file '
              'moves; "Merge into one pack" on the bundle undoes it.',
            ),
            if (plan.sections.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                'Sections: ${plan.sections.join(', ')}',
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: 12),
            for (final n in names.take(_shown))
              Text('• $n', overflow: TextOverflow.ellipsis),
            if (names.length > _shown)
              Text('…and ${names.length - _shown} more'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Split'),
        ),
      ],
    );
  }
}
