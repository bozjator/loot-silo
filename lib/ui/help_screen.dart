import 'package:flutter/material.dart';

import '../core/animation_detector.dart'
    show animationWords, notAnimationWords, sheetWords;
import '../core/sidecar.dart' show authorFileName, packFileName;
import '../version.dart';
import 'shortcuts.dart';
import 'widgets/branding.dart';

/// Opens the Help page over everything (from the app bar, Settings or F1).
void openHelp(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: HelpScreen.routeName),
        builder: (_) => const HelpScreen(),
      ),
    );

/// How Loot Silo works: plain text in sections. The word lists come
/// from the animation detector and the shortcuts from [shortcutSections],
/// so the page follows the code.
class HelpScreen extends StatelessWidget {
  /// Its route's name, so F1 doesn't open it twice.
  static const routeName = 'help';

  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('How Loot Silo works')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 16, bottom: 8),
                child: Center(child: AppLogo(height: 120)),
              ),
              const _Section('Library layout', [
                _P(
                  'The library is one folder that Loot Silo manages, '
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
                  'The import button in the top bar (next to Help) opens a '
                  'menu: Import folder (Ctrl+I) and Import archive (Ctrl+O, '
                  'or drop files on the window) copy packs into the library '
                  'and check '
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
                  'Animations are found when the library is scanned. One file '
                  'is one animation: numbered frame files (walk_0.png, '
                  'walk_1.png …) stay separate images; use Combine into '
                  'animation (below) to make one strip of them. Two kinds '
                  'are detected:',
                ),
                const _Bullets([
                  'Sheets: one image cut into frames, from a size hint in the '
                      'name like (32x32) (or 7x7 for 7 × 7 frames), a frame '
                      'count like _8f or 8frames, or a horizontal strip. A '
                      'strip is cut into square frames, unless transparent '
                      'gaps between its frames show another frame width. In '
                      'effect packs, transparent gaps also find grids.',
                  'Frames don\'t have to be square: for a file whose name or '
                      'folder has an animation word (below), the transparent '
                      'gaps between frames decide the frame width and height, '
                      'even on big strips and grids (a ship of 608×640 '
                      'frames). Empty cells at the end of a grid don\'t count '
                      'as frames. A file named as one frame (sail-frame12.png) '
                      'is not cut.',
                  'A file with an animation word that nothing detects (its '
                      'gaps are hidden by particles) borrows the frame size '
                      'of an animation of exactly the same size in its '
                      'folder.',
                  'A sheet can take its cell size from other animations in '
                      'its folder: an image that is a whole grid of their '
                      'frames (a 6 × 6 grid of 192 px cells next to 192 px '
                      'strips) is cut into those cells when the cuts fall on '
                      'transparent lines and at least three cells hold '
                      'something. Empty cells at the end don\'t count.',
                  'A wide image without a sheet or animation word is a strip '
                      'only if its frames look apart: a picture that runs '
                      'across the square frame cuts (a bench, a row of bags) '
                      'stays one image.',
                  'GIF and animated WebP files.',
                ]),
                const _P(
                  'A sheet with several rows plays all its rows, unless you '
                  'save one row in Edit. A file shown in the Animations tab '
                  'isn\'t listed again in the Images tab; "Not an animation" '
                  'puts it back there.',
                ),
                const _P(
                  'Cards, focus mode and the Edit preview show the whole '
                  'frame, transparent border included (no cropping), scaled '
                  'up in whole steps, so every animation of one character '
                  'keeps the same size. Fully empty frames are skipped.',
                ),
                _P('Animation words: ${animationWords.join(', ')}.'),
                _P('Sheet words: ${sheetWords.join(', ')}.'),
                _P(
                  'Not sheets unless a sheet word is in the name: '
                  '${notAnimationWords.join(', ')}.',
                ),
                const _P('Naming tips'),
                const _Bullets([
                  'Frame files: combine them into one animation.',
                  '…_strip8.png or …_8f.png for a strip of 8 frames.',
                  '(32x32) in the name for the frame size of a grid.',
                ]),
                const _P('Your overrides (saved in the pack\'s file)'),
                const _Bullets([
                  'Edit (on a card): fps, frame size, total frames (−/+, '
                      '↑/↓ or the wheel step through counts that fit), and '
                      'the row to play or all rows.',
                  'Zoom: the mouse wheel over the Edit preview, or the −, + '
                      'and reset buttons shown on hover (1×–8×; reset is '
                      'Auto, the fit). Cards then use that zoom.',
                  '"Not an animation" asks first, then moves a file to '
                      'Images; Restore (or Undo on the message) brings it '
                      'back.',
                  '"Make animation…" on an image marks it as a sheet, '
                      'starting from the best guess (the cells of an '
                      'animation in its folder, then the transparent gaps, '
                      'then square frames); "Back to image" undoes that.',
                  'Combine frame files: the button after a folder\'s name '
                      '(By folder), or select images (the checkbox, or Ctrl/'
                      'Shift-click, in either view) and use the selection '
                      'bar. The strip opens in Edit straight away, with a '
                      'file name field (<folder>_animation to start with). '
                      'Only Save writes it next to the frames (asking before '
                      'replacing a file); Cancel or Esc writes nothing. The '
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
                  'grid whose cards share the dialog\'s width. −/+ in its '
                  'title bar or Ctrl + wheel over it set how many columns '
                  '(1–8, remembered); rows are kept even, so 8 previews at 5 '
                  'columns show as two rows of 4.',
                ),
              ]),
              const _Section('Pack page & tabs', [
                _P(
                  'A pack page has a header (previews and info) above the '
                  'Animations, Images, Audio and Other files tabs. The pin '
                  '(H), itch.io page (when linked) and open folder icons sit '
                  'in the header\'s top-right corner. When the header is '
                  'unpinned, a slim bar replaces it, with the same icons at '
                  'its right end. Rest the pointer on the bar for a moment '
                  'to see the full header floating over the tabs; passing '
                  'over it on the way to a tab doesn\'t open it.',
                ),
                _P(
                  'Middle-click a pack (or right-click → Open in new tab) to '
                  'open it in a tab. While tabs are open, the tab strip '
                  'replaces the page\'s top bar; without tabs the bar with '
                  'the back arrow stays. A plain click opens a pack inside '
                  'the Dashboard tab, which then isn\'t shown as selected; '
                  'clicking it takes you back to the dashboard. Esc and the '
                  'mouse back button go back as well.',
                ),
                _P(
                  'Animations and Images tabs: the cards work alike. Click a '
                  'card to focus it: it is outlined and the others dim (and '
                  'pause). ←/→ move the focus in on-screen order; Esc, the '
                  'mouse back button, a click on empty space or on the '
                  'focused card leave it. On hover, a card shows its star '
                  '(top right) and its icons over the footer: Edit (animations) '
                  'or Make animation… (images), Open image (the viewer, in '
                  'on-screen order) and Show in file manager. Image cards '
                  'show the image size under the name. Ctrl-click or '
                  'Shift-click select images instead of focusing them, in '
                  'the Flat and By folder views alike; Shift selects a range '
                  'in on-screen order, across folders. Folding a folder or '
                  'switching views keeps the selection. In the By folder '
                  'view, the button next to the view switch collapses every '
                  'folder shown (or expands them all when all are folded).',
                ),
                _P(
                  'Audio tab: click a sound (or Space) to play or stop it; '
                  'Loop repeats it. Play all (Shift+Space) plays every sound '
                  'shown, in order (the file search and folder filter '
                  'apply), with a short pause between them, starting from '
                  'the selected one. The playing sound is highlighted and '
                  'scrolled into view. Clicking another sound continues from '
                  'there; Stop, Space or a click on the playing sound ends '
                  'it. While Play all runs, Loop repeats the whole list '
                  'instead of one sound.',
                ),
              ]),
              const _Section('Favorites', [
                _P(
                  'Star packs and single files to find them again. The star '
                  'sits on a dashboard tile (shown on hover, always once '
                  'starred), next to the title in a pack\'s header, on image '
                  'and animation cards, on audio rows and cards, and on '
                  'Other files rows. Click it again to unstar.',
                ),
                _P(
                  'The Favorites chip (★ and a count) in the dashboard '
                  'filter bar lists '
                  'starred packs and packs with starred files (in the '
                  'Expanded view, the folders holding them); its count '
                  'follows the other filters. In the Files view it lists the '
                  'starred files, all of them without a search. The '
                  'Favorites chip on a pack page shows only that pack\'s '
                  'starred files, and the tab counts follow.',
                ),
                _P(
                  'Stars are saved in the pack\'s asset_pack.json '
                  '(favorite and favorite_files), so they move with the '
                  'pack and survive a rescan.',
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
              const _Section('Settings', [
                _P(
                  'Resume where I left off (on by default): the next start '
                  'opens the same pack tabs, the dashboard search, filters, '
                  'sort and open bundle, and on each pack page its folder, '
                  'tab, file search and Favorites chip. Packs no longer in '
                  'the library and filter values no pack has are left out. '
                  'Scroll positions, selections and playing sounds are not '
                  'kept. Off: every start shows a clean dashboard.',
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
