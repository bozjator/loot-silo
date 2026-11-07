<p align="center">
  <img src="assets/branding/logo_wide.png" alt="Loot Silo" width="480">
</p>

<p align="center"><b>Your game assets. At a glance.</b></p>

Loot Silo is a desktop app for the game assets you have collected: sprites,
tilesets, animations, audio and fonts. It keeps them in one library folder,
arranged as `Author/Pack`, and lets you:

- import folders and archives (zip, tar, 7z, rar), each copied file checked
  against its SHA-1, or link your itch.io purchases;
- browse packs on a dashboard with search, tags, authors, sources and
  favorites;
- open a pack to see its images, audio and animations, with sprite sheets and
  strips detected and played automatically and editable by hand;
- keep credits and licenses per author, ready to paste into your game.

The library is plain files: `ASSET_AUTHOR.txt` per author and
`asset_pack.json` per pack, both safe to edit by hand. Press F1 in the app for
the full guide and every shortcut.

## Build and run (Linux)

Needs the Flutter SDK (stable) with Linux desktop support, plus
`libsecret-1-dev` (for the itch.io key) and, for 7z and rar archives, `7zz`,
`7z` or `unrar` on the PATH.

```bash
flutter pub get
flutter run -d linux
```

A release build lands in `build/linux/x64/release/bundle/`:

```bash
flutter build linux --release
```

Windows and macOS runners are included but not yet tested.

## Tests

```bash
dart format lib test integration_test
flutter analyze
flutter test
```

Integration tests drive the real app and write screenshots to `screenshots/`;
on a headless machine run them under Xvfb:

```bash
xvfb-run -a -s "-screen 0 1440x900x24" flutter test integration_test/app_test.dart -d linux
```

The branding assets are rebuilt from the source artwork with
`python3 tool/branding/make_branding.py` (needs Pillow).
