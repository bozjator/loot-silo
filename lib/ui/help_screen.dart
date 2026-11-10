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
                  'An empty library shows three ways to start: Import folder '
                  '(copy packs from a folder on your computer), Import '
                  'archive (unpack zip, tar, 7z or rar files) and Connect '
                  'itch.io (Import from itch.io once a key is set), three '
                  'buttons of one width with a line on each.',
                ),
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
                  'Animations, Images, Audio, Models, Materials and Other '
                  'files tabs. Music and sound packs open on Audio, packs '
                  'of the material type on Materials, 3D packs on Models. '
                  'The pin '
                  '(H), itch.io page (when linked) and open folder icons sit '
                  'in the header\'s top-right corner. When the header is '
                  'unpinned, a slim bar replaces it: the pack\'s title, then '
                  'author, types, file count and size (cut first when the '
                  'bar is narrow), and the same icons at its right end. Rest the pointer on the bar for a moment '
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
                  'mouse back button go back as well. Drag a pack tab to '
                  'move it along the strip. When the tabs don\'t '
                  'fit, scroll them with the mouse wheel or the ‹ › arrows, '
                  'or pick one from the ⌄ list of all tabs.',
                ),
                _P(
                  'Animations and Images tabs: the cards work alike. Click a '
                  'card to focus it: it is outlined and the others dim (and '
                  'pause). ←/→ move the focus in on-screen order; Esc, the '
                  'mouse back button, a click on empty space or on the '
                  'focused card leave it. On hover, a card shows its star '
                  '(top right; always once starred), its select box (top '
                  'left, images; always once selected) and its icons over '
                  'the footer: Edit (animations) '
                  'or Make animation… (images), Open image (the viewer, in '
                  'on-screen order) and Show in file manager. A double-click '
                  'on a card opens it in the image viewer as well (not with '
                  'Ctrl or Shift held). Image cards '
                  'show the image size under the name. Ctrl-click or '
                  'Shift-click select images instead of focusing them, in '
                  'the Flat and By folder views alike; Shift selects a range '
                  'in on-screen order, across folders. Folding a folder or '
                  'switching views keeps the selection. In the By folder '
                  'view, the button left of the view switch collapses every '
                  'folder shown (or expands them all when all are folded). Each '
                  'pack remembers which folders you folded, per tab.',
                ),
                _P(
                  'The image viewer opens each image at 1:1 (actual pixels, '
                  'as in a game); an image bigger than the window opens '
                  'fitted instead. Fit and 1:1 in its toolbar switch, the '
                  'wheel zooms, drag pans and a double-click fits. The '
                  'thumbnail size sliders (dashboard, Images, Animations, '
                  'Models, Materials) '
                  'step one size smaller or larger with the small and big '
                  'icons at their ends.',
                ),
                _P(
                  'Each stop of a size slider is one number of cards per '
                  'row: the cards share the row\'s width, so every stop '
                  'changes their size, and the size the slider shows (and '
                  'its tooltip, with the cards per row) is the cards\' real '
                  'width. The stops follow the window: a wider or narrower '
                  'window gives other sizes, and the grid keeps the one '
                  'nearest the size you picked. The end icons and Ctrl + '
                  'wheel move one stop.',
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
                _P(
                  'One sound plays at a time in the whole app: starting a '
                  'sound in one pack tab stops the one playing in another. '
                  'A sound also stops when you leave its tab (another pack '
                  'tab, the Dashboard, another tab of the pack, or closing '
                  'the tab); it does not start again when you come back.',
                ),
                _P(
                  'A sound saved in several formats (song.ogg, song.wav, '
                  'song.mp3, side by side or in MP3 / OGG / WAV folders) is '
                  'one row or card with a chip per format. The highlighted '
                  'chip is the file that plays; click another to switch '
                  '(a playing sound carries on from the same spot). In the '
                  'list, each format keeps its own column, so a sound saved '
                  'only as WAV shows its chip under the other WAV chips. '
                  'Settings → Audio picks the format shown first.',
                ),
                _P(
                  'Each row and card shows the sound\'s waveform, so a '
                  'short hit, a swell or a loop with a gap can be told '
                  'apart before you play it. It is read the first time the '
                  'row or card appears (WAV, MP3 and Ogg Vorbis; other '
                  'formats leave the strip empty). While a sound plays, the '
                  'part already heard is drawn in the accent colour. Sounds '
                  'of 10 seconds or more can be sought while they play: on '
                  'a card, click or drag the waveform (the elapsed time '
                  'shows above its left end, the length above its right '
                  'end); in the list, use the seek bar under the row.',
                ),
                _P(
                  'Sort the sounds with the sort button in the toolbar: '
                  'click its name for the menu (Name, the pack\'s order, '
                  'Duration, File size, Sample rate, Channels, Bitrate or '
                  'Bit depth); the arrow at its left shows the direction '
                  '(up: ascending, down: descending) and a click on it '
                  'flips it. Each sound is sorted by the format '
                  'it shows. Sounds without the value (a WAV has no '
                  'bitrate, an MP3 no bit depth) go last either way. The '
                  'first sort by a detail reads every sound\'s header, '
                  'with a thin progress bar under the toolbar. In the list, '
                  'click the Name, Details, Duration or Size heading to sort '
                  'by it, and again to flip; Details sorts by the menu\'s '
                  'detail, or by sample rate. Play all follows the shown '
                  'order. The sort is remembered.',
                ),
                _P(
                  'Under a card\'s name is a line about the file it plays: '
                  'S (stereo) or M (mono; 6ch for six channels), size, '
                  'sample rate and bit depth (WAV, AIFF, FLAC) or bitrate '
                  '(MP3, Ogg; ~ when it varies or is an average), e.g. '
                  '"S · 1.2 MB · 44.1 kHz · 16-bit". Rest the pointer on '
                  'the line to read it with the words spelled out. '
                  'Rest the pointer on the name to see the file\'s path in '
                  'the pack.',
                ),
                _P(
                  'Mono does not mean one side only: a mono file has one '
                  'channel and plays the same sound on both speakers. '
                  'Stereo has a separate left and right. Mono is common '
                  'and often wanted for sound effects, since game engines '
                  'place mono sounds in 2D or 3D space themselves; music '
                  'and ambience are usually stereo. The sample rate (kHz) '
                  'is how many samples per second the sound is stored at, '
                  'the bit depth how fine each sample is, and the bitrate '
                  'how much data a second of a compressed file takes.',
                ),
                _P(
                  'Rest the pointer on a format chip to see that file\'s '
                  'details: sample rate, Mono / Stereo, bit depth (WAV, '
                  'AIFF, FLAC) or bitrate (MP3, with VBR when it varies; '
                  'Ogg as a ~ figure) and size, e.g. "WAV · 44.1 kHz · '
                  'Stereo · 16-bit · 1.2 MB". The list shows the first '
                  'format\'s details in a Details column (cut short in '
                  'narrow windows).',
                ),
              ]),
              const _Section('3D models', [
                _P(
                  'The Models tab draws every GLB, glTF and OBJ model of the '
                  'pack as a card, seen from a three-quarter view with '
                  'simple lighting in the model\'s own colours (and its '
                  'texture, when it has one). Hover a card to turn the '
                  'model slowly. The footer shows the name, the formats and '
                  'the triangle count. Cards work like image cards: click '
                  'to focus, ←/→, the star, Flat or By folder, the size '
                  'slider and Ctrl + wheel.',
                ),
                _P(
                  'Double-click a card, or use its Open in viewer icon, to '
                  'look at the model up close. Drag to orbit around it, use '
                  'the wheel (or pinch) to zoom, right- or middle-drag to '
                  'move it, and double-click to reset the camera. Keys: '
                  'Shift+←/→ turn it, ↑/↓ look from higher or lower, + and '
                  '− zoom, 0 resets; ←/→ go to the previous or next model of '
                  'the tab, in on-screen order. The toolbar switches '
                  'between the texture and flat colours, and turns on a '
                  'wireframe, a turntable that keeps it turning, and a '
                  'floor grid; these stay as you leave them until the app '
                  'closes. The panel on the right shows the folder, the '
                  'formats (click one to draw it), the triangle and vertex '
                  'counts, the size in model units, the texture, the file '
                  'size and each material the model uses (its colour as a '
                  'swatch, its name and hex value; hover one to show its '
                  'texture or .mtl file in the file manager), with Show in file '
                  'manager and Copy path. Esc '
                  'or the mouse back button close the viewer.',
                ),
                _P(
                  'A model saved in several formats (tree.glb, tree.obj, '
                  'tree.fbx, side by side or in "GLTF format" / "OBJ '
                  'format" folders) is one card with a chip per format; the '
                  'By folder view leaves the format folders out. Click GLB, '
                  'glTF or OBJ to draw that file. FBX, DAE, STL, Blend, 3DS '
                  'and VOX are not drawn: their chip shows the file in the '
                  'file manager, and a model that only comes in those '
                  'formats is listed under Other files.',
                ),
                _P(
                  'A file that can\'t be read shows a broken-image icon (the '
                  'reason in its tooltip). Models are drawn as they are '
                  'stored, without their animations, and very large ones '
                  '(over 200,000 triangles) show "Too large to preview".',
                ),
              ]),
              const _Section('Materials', [
                _P(
                  'A texture is one image; a material is a whole surface '
                  'made of several textures, its maps: Color (also called '
                  'albedo, base colour or diffuse), Normal (GL or DX), '
                  'Roughness, Metalness, AO (ambient occlusion), Height '
                  '(displacement), Opacity, Emission, Specular, and ARM / ORM '
                  '(several packed in one). Sites such as ambientCG call '
                  'them materials, others "PBR textures" or a "texture set"; '
                  'the app says Materials and maps.',
                ),
                _P(
                  'Maps are grouped by a shared name plus a known ending '
                  '(Wood_Color.png, Wood_Normal.png, rock_diff_1k.jpg), '
                  'ignoring the resolution tag (_1K, _2K-JPG). It takes two '
                  'maps, one of them Color or Normal, so a lone '
                  'hero_normal.png stays an image. A .mtlx (MaterialX) file '
                  'next to the maps names them itself, with their roles. '
                  'A material\'s maps and the picture the pack ships for it '
                  '(Wood.png, Wood_preview.png) leave the Images tab; its '
                  'files for other tools leave Other files. Packs with a '
                  'material get the material type (a type you set on a pack '
                  'stays).',
                ),
                _P(
                  'The Materials tab shows one card per material: the '
                  'shipped picture, else the Color map tiled 2 × 2 so seams '
                  'and scale show. The footer gives the name, the '
                  'resolution and the number of maps. Hover a card for its '
                  'chips: a map chip (Color, Normal, Roughness…) shows that '
                  'map in the card until the pointer leaves (click it again '
                  'for the picture); a tool chip (MaterialX, Godot, USD, '
                  'Blender, Substance, Unity) shows its file in the file '
                  'manager. Cards work like model cards: click to focus, '
                  '←/→, the star, Flat or By folder, the size slider and '
                  'Ctrl + wheel.',
                ),
                _P(
                  'Double-click a card, or use its Open in viewer icon, to '
                  'open the material viewer. Sphere (1) and Plane (2) draw '
                  'the material lit by one light, from its Color, Normal, '
                  'Roughness, Metalness and AO maps (a missing map counts as '
                  'plain: white, flat, half rough, not metal, no shadow; the '
                  'Height map and packed ARM maps are not used). Drag to '
                  'move the light, right- or middle-drag to turn the sphere, '
                  'the wheel or + and − zoom, double-click or 0 resets; the '
                  'Tiling slider repeats the maps 1 to 8 times. Tiled 3 × 3 '
                  '(3) shows the Color map nine times to judge its seams, '
                  'and Map (4) one map at actual pixels (wheel to zoom, drag '
                  'to pan). The strip under the stage lists the maps with '
                  'their role, file and pixel size; click one to show it. '
                  'The panel on the right gives the folder, resolution, '
                  'maps, the files for other tools (click to show one in '
                  'the file manager) and the total size, with Show in file '
                  'manager and Copy path. ←/→ go to the previous or next '
                  'material of the tab; the mode, tiling and light stay '
                  'until the app closes. Esc or the mouse back button '
                  'close the viewer.',
                ),
              ]),
              const _Section('Right-click menu', [
                _P(
                  'Right-click an image, animation, audio, model or material '
                  'card, an audio or Other files row, or the picture in the '
                  'image viewer for a menu with only what applies: Copy image '
                  'to clipboard puts the picture itself on the clipboard (at its own '
                  'size), to paste into a chat or an image editor; Copy file '
                  'copies the file, to paste into a game\'s assets folder in '
                  'the file manager (an animation copies its one image file, '
                  'a material all its maps); Copy path copies the full path '
                  'as text; Open opens the file in its default app and Open '
                  'with… asks which app. With several images selected, a '
                  'right-click on one of them copies all selected files. '
                  'Ctrl+C in the image viewer copies the shown image.',
                ),
                _P(
                  'On animation cards and in the image viewer opened from '
                  'them, two GIF items come first. Both make a looping GIF '
                  'of the animation as its card plays it (its frames at '
                  'their own size, at its speed). Copy as GIF to clipboard '
                  'copies it as a picture, to paste into a chat or an email; '
                  'some chat apps show a pasted GIF as a still. Copy as GIF '
                  'file copies it as a .gif file, to paste into a file '
                  'manager or a game\'s folder, where it stays moving. The '
                  'copy items and Open with… are Linux only for now.',
                ),
              ]),
              const _Section('Favorites', [
                _P(
                  'Star packs and single files to find them again. The star '
                  'sits on a dashboard tile (shown on hover, always once '
                  'starred), next to the title in a pack\'s header, on image '
                  'and animation cards, on audio rows and cards (on cards '
                  'the star and Show in file manager show on hover, a set '
                  'star always), on model '
                  'and material cards, and on Other files rows. Click it '
                  'again to unstar.',
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
                _P(
                  'The itch.io screen counts your owned assets and sorts them '
                  'into four tabs. Missing: not in the library yet (game '
                  'builds and programs are never downloaded, only assets). '
                  'To link: packs you added yourself (folder or archive) '
                  'that look like assets you own, by the same title and '
                  'author; Link stores the itch id in the pack and fetches '
                  'the cover and screenshots. Inside a pack: a folder in one of '
                  'the author\'s packs has this name. In library: packs that '
                  'know their itch.io page. Each tab says what it holds, '
                  'even when it is empty. Downloads are unpacked in a '
                  'temporary folder that is deleted when they end, and '
                  'emptied on start in case the app was closed mid-way.',
                ),
              ]),
              const _Section('Settings', [
                _P(
                  'Appearance: light, dark or follow the system, and a '
                  'colour for the whole app (the swatches; teal by '
                  'default). Both apply at once.',
                ),
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
