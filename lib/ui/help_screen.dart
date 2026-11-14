import 'package:flutter/material.dart';

import '../core/animation_detector.dart'
    show animationWords, notAnimationWords, sheetWords;
import '../core/sidecar.dart' show authorFileName, packFileName;
import '../version.dart';
import 'shortcuts.dart';
import 'widgets/branding.dart';
import 'widgets/project_links.dart';

/// Opens the Help page over everything (from the app bar, Settings or F1).
void openHelp(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: HelpScreen.routeName),
        builder: (_) => const HelpScreen(),
      ),
    );

/// How Loot Silo works, written for the people using it: what to do and
/// why the app treats a file the way it does. The word lists come from
/// the animation detector and the shortcuts from [shortcutSections], so
/// the page follows the code.
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
              _Section('Getting started', [
                _P(
                  'Loot Silo keeps your game assets in one library folder, '
                  'sorted as Author / Pack. When you choose a folder that '
                  'already holds packs (at the first start or in Settings), '
                  'it is scanned first, then shown. An empty library shows three '
                  'ways to start: Import folder copies packs from a folder '
                  'on your computer, Import archive unpacks zip, tar, 7z or '
                  'rar files, and Connect itch.io downloads the asset packs '
                  'you own. Later, the import button in the top bar does the '
                  'same ($primaryKey+I, $primaryKey+O, or drop files on the window). Your '
                  'original folder or archive is never changed. 7z and rar '
                  'use 7-Zip or unrar if installed; on macOS the built-in '
                  'tar opens most of them without either.',
                ),
                const _P(
                  'Before anything is copied, a review lists the packs found: '
                  'set each one\'s author, title, types and tags, and untick '
                  'the ones you don\'t want.',
                ),
                const _P(
                  'A bundle is a pack that holds other packs, such as a big '
                  'collection with one folder per theme. Its tile opens the '
                  'list of its packs; "Bundle details" shows the bundle '
                  'itself.',
                ),
                const _P(
                  'What you set on a pack (tags, notes, stars, animation '
                  'fixes) is saved in $packFileName in the pack\'s folder, '
                  'and an author\'s details in $authorFileName in theirs, '
                  'so it moves with the pack. Both are plain text you can '
                  'edit by hand.',
                ),
              ]),
              _Section('Rescan library', [
                _P(
                  'The rescan button in the top bar (F5 or $primaryKey+R) reads the '
                  'whole library folder again: it finds packs and files you '
                  'added, removed or renamed outside the app, and detects '
                  'animations again. Nothing you set is lost, since it is '
                  'kept in the pack files.',
                ),
                const _P(
                  'When the app starts, it notices files added, removed or '
                  'renamed since last time and rescans on its own. Rescan '
                  'yourself when you change the library while the app is '
                  'open, or after changing a file in place, such as a '
                  'redrawn image or a pack file edited by hand. Imports '
                  'rescan for you.',
                ),
              ]),
              const _Section('Finding assets', [
                _P(
                  'The dashboard search looks at pack titles, authors, tags '
                  'and file names. The start of a word is enough: barr finds '
                  'barrels, and HumanSoldier is found by human or soldier. '
                  'When that finds nothing, words of three or more letters '
                  'are also looked for inside other words.',
                ),
                _P(
                  'The Files view lists the matching files instead of packs. '
                  'A pack opened from there shows only those files; "Show '
                  'all files" shows the rest. On a pack page, the search '
                  'field next to the tabs filters that pack\'s files.',
                ),
                _P(
                  'A pack\'s tile shows its cover: one you chose, the '
                  'itch.io cover, an image named preview, cover, mockup, '
                  'screenshot or similar, else an animation or its largest '
                  'image (texture maps last). The header of a pack page '
                  'steps through all its previews; "All previews" shows them '
                  'together.',
                ),
                _P(
                  'To choose your own, use the pencil on the header\'s '
                  'preview: click images to add or remove them and drag the '
                  'chosen ones into order; the first is the cover. "Reset to '
                  'automatic" undoes it. Right-click an image or animation '
                  'for "Use as pack cover" and "Add to" or "Remove from pack '
                  'previews".',
                ),
              ]),
              _Section('Pack page & tabs', [
                const _P(
                  'A pack page shows its previews and info at the top and '
                  'its files in tabs: Animations, Images, Audio, Models, '
                  'Materials and Other files. Press H, or the pin in the '
                  'header\'s corner, to hide the header and give the files '
                  'more room; rest the pointer on the slim bar left in its '
                  'place to see it again.',
                ),
                const _P(
                  'Click a pack to open it; Esc or the mouse back button '
                  'goes back. Middle-click a pack (or right-click → Open in '
                  'new tab) to open it in a tab of its own, so you can keep '
                  'several packs open and switch between them.',
                ),
                _P(
                  'Click a card to focus it, and ←/→ to move to the next. '
                  'Double-click a card to open it large. $primaryKey / Shift-click '
                  'images to select several, to copy them or combine them '
                  'into an animation. Flat shows all files in one grid; By '
                  'folder groups them by the pack\'s folders, which you can '
                  'fold away. The size slider (or $primaryKey + wheel) makes the '
                  'cards bigger or smaller.',
                ),
                const _P(
                  'The image viewer shows an image at its real size (1:1, '
                  'as in a game), or fitted when it is bigger than the '
                  'window. The wheel zooms and dragging moves it.',
                ),
              ]),
              _Section('Animations', [
                const _P(
                  'Loot Silo looks for animations each time it scans the '
                  'library. An animation is always a single file: a GIF, an '
                  'animated WebP, or a sprite sheet (one image with all the '
                  'frames side by side, in a row or a grid). It plays on its '
                  'card in the Animations tab and is not listed again under '
                  'Images.',
                ),
                const _P('What makes an image an animation'),
                const _Bullets([
                  'GIF and animated WebP files always are.',
                  'A frame size in the name: hero (32x32).png is cut into '
                      '32 × 32 frames. Small numbers count frames instead: '
                      'sheet 7x7.png is 7 columns × 7 rows.',
                  'A frame count in the name: walk_8f.png, run_strip8.png '
                      'or 8frames is cut into 8 frames.',
                  'An animation word (walk, idle, attack … the full list is '
                      'below) in the file or folder name. Then the empty, '
                      'transparent gaps between the drawings decide the '
                      'frame size, so frames don\'t have to be square.',
                  'A wide image with no such word, whose square frames '
                      'clearly stand apart. A picture that runs across the '
                      'cuts, like a bench or a row of bags, stays one image.',
                  'An image next to an animation of exactly the same size, '
                      'or made of a grid of its frames, uses that '
                      'animation\'s frame size.',
                ]),
                const _P('Why an image is not shown as an animation'),
                const _Bullets([
                  'Its frames are separate files (walk_0.png, walk_1.png …). '
                      'Each stays an image; combine them into one '
                      'animation (below).',
                  'Nothing tells the frame size: no size, count or '
                      'animation word in the name, and the drawings touch, '
                      'so there are no gaps to cut at.',
                  'Its name says it is one frame (sail-frame12.png), or has '
                      'a word for still images (tileset, icons, ui … listed '
                      'below) and no sheet word.',
                ]),
                const _P('Why an image is shown as an animation by mistake'),
                const _Bullets([
                  'Its folder name has an animation word, for example a '
                      'folder "Attack" that also holds still pictures.',
                  'It is a row of separate pieces, like icons or items, '
                      'that looks just like a strip of frames.',
                ]),
                const _P('Fixing it yourself'),
                const _Bullets([
                  '"Make animation…" on an image card turns it into an '
                      'animation, starting from the best guess; set the '
                      'frame size there. "Back to image" undoes it.',
                  '"Not an animation" asks first, then moves the file back '
                      'to Images; Restore (or Undo on the message) brings it '
                      'back.',
                  'Edit on an animation card sets the speed (fps), the '
                      'frame size, the number of frames, and which row of a '
                      'grid plays (or all rows). The mouse wheel over the '
                      'Edit preview zooms.',
                  'Combine frame files: select the frames and use the '
                      'selection bar, or the button after a folder\'s name '
                      'in By folder. The new strip opens in Edit straight '
                      'away, with a file name field. Only Save writes it next '
                      'to the frames; the frame files stay.',
                ]),
                const _P(
                  'Your fixes are saved in the pack file, so they survive a '
                  'rescan.',
                ),
                const _P('Naming tips for your own files'),
                const _Bullets([
                  '…_8f.png or …_strip8.png: a strip of 8 frames.',
                  '(32x32) in the name: the frame size of a grid.',
                  'An animation word (walk, idle, run …) in the name: the '
                      'gaps between the frames decide their size.',
                ]),
                const _P(
                  'Animations show the whole frame, empty border included '
                  '(no cropping), so all animations of one character keep '
                  'the same size.',
                ),
                _P('Animation words: ${animationWords.join(', ')}.'),
                _P('Sheet words: ${sheetWords.join(', ')}.'),
                _P(
                  'Still-image words (not an animation unless a sheet word is '
                  'in the name too): ${notAnimationWords.join(', ')}.',
                ),
              ]),
              const _Section('Audio', [
                _P(
                  'Click a sound (or press Space) to play or stop it; Loop '
                  'repeats it. Play all (Shift+Space) plays every sound '
                  'shown, one after another, from the selected one; while it '
                  'runs, Loop repeats the whole list. Only one sound plays '
                  'at a time, and it stops when you leave the tab.',
                ),
                _P(
                  'The waveform shows what a sound looks like before you '
                  'play it: a short hit, a slow swell, a loop with a gap. '
                  'Sounds of 10 seconds or more can be sought by clicking '
                  'the waveform (on a card) or the bar under the row (in the '
                  'list).',
                ),
                _P(
                  'A sound saved in several formats (song.ogg, song.wav, '
                  'song.mp3) is shown once, with a chip per format; click a '
                  'chip to play that file. Settings → Audio picks the format '
                  'shown first. The sort button orders the sounds by name, '
                  'length, size, sample rate, bitrate and more.',
                ),
                _P(
                  'The line under a card\'s name tells S (stereo) or M '
                  '(mono), size and quality. Mono doesn\'t mean one side '
                  'only: it plays the same sound on both speakers. It is '
                  'common for sound effects, since game engines place them '
                  'in space themselves; music is usually stereo.',
                ),
              ]),
              const _Section('3D models', [
                _P(
                  'The Models tab shows every GLB, glTF and OBJ model of the '
                  'pack; hover a card to turn it. Double-click a card to '
                  'look at it up close: drag to turn around it, the wheel '
                  'zooms, right- or middle-drag moves it, and a double-click '
                  'resets the view. The toolbar switches textures, '
                  'wireframe, turntable and floor grid.',
                ),
                _P(
                  'A model saved in several formats is one card with a chip '
                  'per format. FBX, DAE, STL, Blend, 3DS and VOX are not '
                  'drawn: their chip opens the file\'s folder, and a model in '
                  'only those formats is listed under Other files. Models '
                  'are shown without their animations.',
                ),
              ]),
              const _Section('Materials', [
                _P(
                  'A material is a surface made of several images, its '
                  'maps: Color, Normal, Roughness, Metalness, AO, Height and '
                  'others (sites also call them "PBR textures" or a "texture '
                  'set"). Maps are grouped by their shared name, like '
                  'Wood_Color.png and Wood_Normal.png. It takes at least two '
                  'maps, one of them Color or Normal, so a lone '
                  'hero_normal.png stays an image.',
                ),
                _P(
                  'Hover a material card to show its maps one by one. '
                  'Double-click it to see it on a sphere or a plane: drag to '
                  'move the light, the Tiling slider repeats it, and Tiled '
                  '3 × 3 shows whether its edges join without seams.',
                ),
              ]),
              const _Section('Copying files', [
                _P(
                  'Right-click a card or row for: Copy image to clipboard '
                  '(to paste into a chat or an image editor), Copy file (to '
                  'paste into your game\'s folder), Copy path, Open and Open '
                  'with…. With several images selected, Copy file copies '
                  'them all.',
                ),
                _P(
                  'Animations also have Copy as GIF to clipboard and Copy as '
                  'GIF file, a looping GIF as the card plays it. Some chat '
                  'apps show a pasted GIF as a still picture; the file always '
                  'moves. The copy items and Open with… work on Linux only '
                  'for now.',
                ),
              ]),
              const _Section('Favorites', [
                _P(
                  'Click a star to keep a pack or a single file at hand. '
                  'Stars sit on dashboard tiles, in a pack\'s header, on '
                  'image and animation cards and on every other card and '
                  'row. Click again to unstar.',
                ),
                _P(
                  'The Favorites chip (★ and a count) in the dashboard '
                  'filter bar shows the starred packs and the packs holding '
                  'starred files. In the Files view it lists the starred '
                  'files themselves. The Favorites chip on a pack page shows '
                  'only that pack\'s starred files. Stars are saved in the '
                  'pack\'s asset_pack.json, so they move with the pack.',
                ),
              ]),
              const _Section('Credits & itch.io', [
                _P(
                  'Mark a pack as used in a game with the + next to "Used in" '
                  'on its page. The Credits screen lists each game\'s packs '
                  'with their authors and licences, warns about authors '
                  'without a licence, and copies or saves a CREDITS file.',
                ),
                _P(
                  'itch.io: connect with an API key (kept in the system '
                  'keychain). The itch.io screen sorts the assets you own '
                  'into tabs. Missing: not in the library yet; Download '
                  'fetches them (games and programs are never downloaded). '
                  'To link: packs you imported yourself that look like ones '
                  'you own; Link connects them and fetches their cover. '
                  'Inside a pack: found as a folder inside another of the '
                  'author\'s packs. In library: already linked.',
                ),
              ]),
              const _Section('Settings', [
                _P(
                  'Appearance: light, dark or follow the system, and a '
                  'colour for the whole app.',
                ),
                _P(
                  'Resume where I left off (on by default): the next start '
                  'opens the same pack tabs, search and filters. Off: every '
                  'start shows a clean dashboard.',
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
              const Divider(height: 32),
              const ProjectLinks(textAlign: TextAlign.center),
              const SizedBox(height: 12),
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
