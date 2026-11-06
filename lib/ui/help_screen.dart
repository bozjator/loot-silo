import 'package:flutter/material.dart';

import '../core/animation_detector.dart'
    show animationWords, notAnimationWords, sheetWords;
import '../core/sidecar.dart' show authorFileName, packFileName;
import '../version.dart';
import 'shortcuts.dart';

/// Opens the Help page over everything (from the app bar, Settings or F1).
void openHelp(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: HelpScreen.routeName),
        builder: (_) => const HelpScreen(),
      ),
    );

/// How Asset Explorer works: plain text in sections. The word lists come
/// from the animation detector and the shortcuts from [shortcutSections],
/// so the page follows the code.
class HelpScreen extends StatelessWidget {
  /// Its route's name, so F1 doesn't open it twice.
  static const routeName = 'help';

  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How Asset Explorer works')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            children: [
              const _Section('Library layout', [
                _P(
                  'The library is one folder that Asset Explorer manages, '
                  'arranged as <Author>/<Pack>. Each author folder holds '
                  '$authorFileName; each pack folder may hold $packFileName. '
                  'Both are plain text you can edit by hand; the app rewrites '
                  'only the fields it changes and keeps the rest.',
                ),
                _P(
                  'A bundle is a pack that contains other packs (sub-packs), '
                  'for example a big collection with one folder per theme. '
                  'Its tile opens the bundle; "Bundle details" shows the '
                  'bundle itself. Sub-packs take their bundle\'s source.',
                ),
                _Bullets([
                  '$authorFileName: user (the name shown), url, itch_user, '
                      'license, and the credit and attribution wording used '
                      'by Credits. Edit it with the pencil next to the author.',
                  '$packFileName: title, types, tags, source and '
                      'source_path, itch_game_id and itch_url, cover (your '
                      'own preview), notes, used_in (games), is_container '
                      '(bundle) and animations (your overrides).',
                ]),
                _P('Sources'),
                _Bullets([
                  'imported: copied in with Import folder or Import archive.',
                  'itch: downloaded or linked from your itch.io library.',
                  'manual: placed in the library by hand.',
                  'unknown: no source on file.',
                ]),
              ]),
              const _Section('Import', [
                _P(
                  'Import folder (Ctrl+I) and Import archive (Ctrl+O, or drop '
                  'files on the window) copy packs into the library and check '
                  'every copied file against its SHA-1. The original folder or '
                  'archive is never changed. Archives are zip, tar, tar.gz, 7z '
                  'and rar (7z and rar need 7zz, 7z or unrar installed).',
                ),
                _P(
                  'The review table lists the packs found. Before importing '
                  'you can set each pack\'s author (pick one from the library '
                  'or add a new one), title, types and tags, and choose which '
                  'packs to import. Importing a folder that is already inside '
                  'the library is refused.',
                ),
              ]),
              _Section('Animations', [
                const _P(
                  'Animations are found when the library is scanned. Three '
                  'kinds are detected:',
                ),
                const _Bullets([
                  'Numbered sequences: three or more numbered PNGs with the '
                      'same prefix in one folder (walk_0.png, walk_1.png …), '
                      'frames of the same size up to 512 px. The prefix or a '
                      'folder name must contain an animation word (below), so '
                      'barrels_0.png, barrels_1.png stay separate images.',
                  'Sheets: one image cut into frames, from a size hint in the '
                      'name like (32x32), a frame count like _8f or 8frames, a '
                      'horizontal strip of square frames, or a grid of the '
                      'pack\'s usual frame size. A transparent gap between '
                      'frames also counts.',
                  'GIF and animated WebP files.',
                ]),
                _P('Animation words: ${animationWords.join(', ')}.'),
                _P('Sheet words: ${sheetWords.join(', ')}.'),
                _P(
                  'Not sheets unless a sheet word is in the name: '
                  '${notAnimationWords.join(', ')}.',
                ),
                const _P('Naming tips'),
                const _Bullets([
                  '<name>_<frame>.png for frame files: knight_walk_0.png …',
                  '…_strip8.png or …_8f.png for a strip of 8 frames.',
                  '(32x32) in the name for the frame size of a grid.',
                ]),
                const _P('Your overrides (saved in the pack\'s file)'),
                const _Bullets([
                  'Edit (on a card): fps, frame size, total frames (−/+, '
                      '↑/↓ or the wheel step through counts that fit), the '
                      'row to play or all rows, and zoom.',
                  '"Not an animation" moves a file to Images; Restore brings '
                      'it back.',
                  '"Make animation…" on an image marks it as a sheet; "Back '
                      'to image" undoes that.',
                  'Combine frame files: the button on a folder header (By '
                      'folder), or select images in Flat view (Ctrl/Shift-'
                      'click), writes <folder>_animation.png next to them; the '
                      'frame files stay.',
                ]),
              ]),
              const _Section('Search', [
                _P(
                  'The dashboard search looks at pack titles, authors, tags '
                  'and file names. Each word you type matches the start of a '
                  'word (barr finds barrels, HumanSoldier counts as human '
                  'and soldier). When nothing matches that way and every '
                  'word has three or more letters, words are also found '
                  'inside other words (arrel finds barrels).',
                ),
                _P(
                  'The Files view lists the matching files themselves. A '
                  'pack opened from a file search, or from a tile\'s "N files '
                  'match" line, shows only those files ("Matching …"; "Show '
                  'all files" clears it). On a pack page, the search field '
                  'next to the tabs filters its files by name the same way.',
                ),
              ]),
              const _Section('Previews', [
                _P('The tile image of a pack is chosen in this order:'),
                _Bullets([
                  'the cover set in its pack file;',
                  'the itch.io cover or screenshots (in _itch/);',
                  'files, or folders, named preview, mockup, cover, '
                      'showcase, screenshot, thumbnail, all…, sample or '
                      'example, in that order;',
                  'a GIF or animated WebP, then a detected animation;',
                  'else the largest image near the top of the pack.',
                ]),
                _P(
                  'Promo images (logos, coupons, Patreon, licence …) are '
                  'never picked. To choose your own, put "cover": '
                  '"<path in the pack>" in its pack file, or name an image '
                  'preview.png. The header of a pack page steps through all '
                  'its preview candidates; "All previews" shows them in a '
                  'grid.',
                ),
              ]),
              _Section('Keyboard & mouse', [
                for (final (where, keys) in shortcutSections) ...[
                  _P(where),
                  _Table([for (final k in keys) (k.keys, k.label)]),
                ],
                const _P('Mouse'),
                _Table([for (final m in mouseHelp) (m.gesture, m.label)]),
              ]),
              const _Section('Credits & itch.io', [
                _P(
                  'Mark a pack as used in a game with the + next to "Used in" '
                  'on its page. The Credits screen lists each game\'s packs '
                  'with their authors and licences, warns about authors '
                  'without a licence, and copies or saves a CREDITS file '
                  '(Markdown or text).',
                ),
                _P(
                  'itch.io: connect with an API key (kept in the system '
                  'keychain). Sync lists the asset packs you own and matches '
                  'them to library packs by title and author. Link records '
                  'the match in the pack file; Download fetches a missing '
                  'pack through the usual import, with its cover and '
                  'screenshots in _itch/.',
                ),
              ]),
              const Divider(height: 32),
              Text(
                appVersionLabel,
                key: const ValueKey('help-version'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.children);

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        ...children,
      ],
    ),
  );
}

/// A paragraph; selectable, so words and keys can be copied.
class _P extends StatelessWidget {
  const _P(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SelectableText(text, style: Theme.of(context).textTheme.bodyMedium),
  );
}

class _Bullets extends StatelessWidget {
  const _Bullets(this.items);

  final List<String> items;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 8, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final item in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: SelectableText(item)),
              ],
            ),
          ),
      ],
    ),
  );
}

/// Keys (or gestures) and what they do, two columns.
class _Table extends StatelessWidget {
  const _Table(this.rows);

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 12),
      child: Column(
        children: [
          for (final (keys, label) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 260,
                    child: SelectableText(
                      keys,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(child: SelectableText(label)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
