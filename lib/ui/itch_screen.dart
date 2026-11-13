import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../itch/itch_api.dart';
import '../itch/itch_matcher.dart';
import '../state/itch.dart';
import 'dashboard.dart' show openPackDetail;

/// itch.io sync: connect with an API key, then see which owned assets are
/// in the library, which can be linked, and download the missing ones.
class ItchScreen extends ConsumerWidget {
  const ItchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = ref.watch(itchKeyProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('itch.io'),
        actions: [
          if (key.value != null) ...[
            IconButton(
              tooltip: 'Refresh owned assets',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(itchAccountProvider),
            ),
            TextButton(
              onPressed: () => ref.read(itchKeyProvider.notifier).disconnect(),
              child: const Text('Disconnect'),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: switch (key) {
        AsyncData(value: null) => const _Connect(),
        AsyncData() => const _Sync(),
        AsyncError(:final error) => Center(child: Text('$error')),
        _ => const Center(child: CircularProgressIndicator()),
      },
    );
  }
}

class _Connect extends ConsumerStatefulWidget {
  const _Connect();

  @override
  ConsumerState<_Connect> createState() => _ConnectState();
}

class _ConnectState extends ConsumerState<_Connect> {
  final _key = TextEditingController();
  String? _error;
  var _busy = false;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (_key.text.trim().isEmpty) return;
    setState(() => (_busy = true, _error = null));
    try {
      await ref.read(itchKeyProvider.notifier).connect(_key.text);
    } on ItchApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Connect itch.io', style: theme.textTheme.headlineSmall),
                const SizedBox(height: 8),
                const Text(
                  'Optional. With an API key the app can list the assets you '
                  'own, link them to packs in your library, fetch covers and '
                  'download the ones you are missing. Everything else works '
                  'without it.',
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse('https://itch.io/user/settings/api-keys'),
                  ),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Create a key on itch.io'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _key,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'API key',
                    errorText: _error,
                  ),
                  onSubmitted: (_) => _connect(),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: Text(_busy ? 'Checking…' : 'Connect'),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'The key is stored in the system keychain and only sent to '
                  'api.itch.io.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Sync extends ConsumerWidget {
  const _Sync();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(itchAccountProvider);
    final matches = ref.watch(itchMatchesProvider);
    if (account case AsyncError(:final error)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 8),
            Text('$error'),
            TextButton(
              onPressed: () => ref.invalidate(itchAccountProvider),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    final list = matches.value;
    if (list == null || account.value == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('Loading owned assets…'),
          ],
        ),
      );
    }
    final storageProblem = ref.read(itchKeyProvider.notifier).storageProblem;
    List<ItchMatch> of(MatchKind k) => [
      for (final m in list)
        if (m.kind == k) m,
    ];
    final missing = of(MatchKind.missing);
    final fuzzy = of(MatchKind.fuzzy);
    final inside = of(MatchKind.inside);
    final linked = of(MatchKind.linked);
    final jobs = ref.read(itchJobsProvider.notifier);
    final bulk = bulkDownloads(list);
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Signed in as ${account.value!.user.username} · '
              '${list.length} owned assets · ${linked.length + fuzzy.length} '
              'in the library',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (storageProblem != null)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'The system keychain is not available; the key is kept for '
                'this session only.',
              ),
            ),
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Missing'),
              Tab(text: 'To link'),
              Tab(text: 'Inside a pack'),
              Tab(text: 'In library'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                _Group(
                  matches: missing,
                  empty: 'Every owned asset is in the library.',
                  hint:
                      'Not in the library. Game builds and programs (Windows, '
                      'macOS, Linux and Android files) are never downloaded, '
                      'only assets. Tools and bundles from authors you already '
                      'have are left out of "Download all". Items from bundles '
                      'appear here only after you claim them on itch.io.',
                  bulkLabel: 'Download all missing (${bulk.length})',
                  onBulk: bulk.isEmpty
                      ? null
                      : () => jobs.download([for (final m in bulk) m.key]),
                ),
                _Group(
                  matches: fuzzy,
                  empty: 'Nothing left to link.',
                  hint:
                      'Packs you added yourself (folder or archive) that look '
                      'like assets you own on itch.io: same title and author. '
                      'Linking stores the itch id in the pack and fetches the '
                      'cover and screenshots.',
                  bulkLabel: 'Link all (${fuzzy.length})',
                  onBulk: () => jobs.linkAll(fuzzy),
                ),
                _Group(
                  matches: inside,
                  empty: 'None.',
                  hint:
                      'A folder inside one of the author\'s packs has this '
                      'name, so it is likely there already. Download it only '
                      'if you want it as its own pack.',
                ),
                _Group(
                  matches: linked,
                  empty: 'No pack is linked to itch yet.',
                  hint: 'Packs that know their itch.io page.',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Missing games "Download all" takes: no tools, and no bundles from an
/// author whose packs are already in the library (they'd re-download what
/// is there).
List<ItchMatch> bulkDownloads(List<ItchMatch> matches) {
  final authorsInLibrary = {
    for (final m in matches)
      if (m.kind != MatchKind.missing) m.key.game.user.id,
  };
  return [
    for (final m in matches)
      if (m.kind == MatchKind.missing &&
          m.key.game.classification != 'tool' &&
          !(titleWords(m.key.game.title).contains('bundle') &&
              authorsInLibrary.contains(m.key.game.user.id)))
        m,
  ];
}

class _Group extends ConsumerWidget {
  const _Group({
    required this.matches,
    required this.empty,
    required this.hint,
    this.bulkLabel,
    this.onBulk,
  });

  final List<ItchMatch> matches;
  final String empty;
  final String hint;
  final String? bulkLabel;
  final VoidCallback? onBulk;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The hint shows when the tab is empty too: it says what the tab is
    // for.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
              ),
              if (bulkLabel != null && matches.isNotEmpty) ...[
                const SizedBox(width: 16),
                FilledButton(onPressed: onBulk, child: Text(bulkLabel!)),
              ],
            ],
          ),
        ),
        Expanded(
          child: matches.isEmpty
              ? Center(child: Text(empty))
              : ListView.builder(
                  itemCount: matches.length,
                  // Striped by the position shown, so they re-flow when
                  // a download removes a row.
                  itemBuilder: (context, i) => _StripedRow(
                    key: ValueKey('itch-row:${matches[i].key.game.id}'),
                    index: i,
                    child: _GameTile(match: matches[i]),
                  ),
                ),
        ),
      ],
    );
  }
}

/// One itch.io row's background across the full list width: odd rows
/// `surfaceContainer`, the row under the pointer `surfaceContainerHighest`,
/// so each Download / Link button reads as part of its row on a wide
/// window. A [Material], so the buttons' ripples show on top of it.
class _StripedRow extends StatefulWidget {
  const _StripedRow({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  State<_StripedRow> createState() => _StripedRowState();
}

class _StripedRowState extends State<_StripedRow> {
  var _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = _hover
        ? scheme.surfaceContainerHighest
        : widget.index.isOdd
        ? scheme.surfaceContainer
        : theme.scaffoldBackgroundColor;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(color: color, child: widget.child),
    );
  }
}

class _GameTile extends ConsumerWidget {
  const _GameTile({required this.match});

  final ItchMatch match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final game = match.key.game;
    final job = ref.watch(itchJobsProvider.select((j) => j[game.id]));
    final jobs = ref.read(itchJobsProvider.notifier);
    final theme = Theme.of(context);
    final pack = match.pack;
    final busy = job != null && !job.done && job.error == null;
    return ListTile(
      leading: SizedBox(
        width: 80,
        height: 64,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: game.coverUrl == null
              ? ColoredBox(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.image_outlined),
                )
              : Image.network(
                  game.coverUrl!,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.none,
                  errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                ),
        ),
      ),
      title: Text(game.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              game.user.name,
              ?game.classification,
              if (pack != null)
                '${match.kind == MatchKind.inside ? 'inside' : '→'} '
                    '${pack.id}',
            ].join(' · '),
          ),
          if (job != null)
            Text(
              job.error ?? job.status,
              style: TextStyle(
                color: job.error != null
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          if (busy && job.progress != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(value: job.progress),
            ),
        ],
      ),
      trailing: Wrap(
        spacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          IconButton(
            tooltip: 'Open on itch.io',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => launchUrl(Uri.parse(game.url)),
          ),
          if (pack != null && match.kind != MatchKind.missing)
            IconButton(
              tooltip: 'Show pack',
              icon: const Icon(Icons.inventory_2_outlined),
              onPressed: () => openPackDetail(context, pack.id),
            ),
          if (match.kind == MatchKind.fuzzy && !(job?.done ?? false))
            OutlinedButton(
              onPressed: busy ? null : () => jobs.link(match.key, pack!),
              child: const Text('Link'),
            ),
          if ((match.kind == MatchKind.missing ||
                  match.kind == MatchKind.inside) &&
              !(job?.done ?? false))
            OutlinedButton(
              onPressed: busy ? null : () => jobs.download([match.key]),
              child: Text(job?.error != null ? 'Retry' : 'Download'),
            ),
        ],
      ),
    );
  }
}
