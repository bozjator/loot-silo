# Asset Explorer — Progress

Plan: `~/.claude/plans/i-have-bought-lots-sequential-possum.md`
Decision log: `../REPORT_APP_CREATION.md`

## Milestones
- [x] 1. Setup — SDK, Linux toolchain, MCP, project, repo, progress/report files
- [x] 2. Scanner and index — 201 packs (71 top-level, 130 sub-packs) in OLD; cold 1.6 s, warm 0.2 s
- [x] 3. Folder import — OLD → `assets_library`: 71/71 packs, 49,778 files, SHA-1 verified; OLD byte-identical
- [x] 4. Dashboard — preview picker, pixel-aware tiles, FTS search, type/author/tag/source filters, sort, bundle browsing, goldens
- [x] 5. Animations — strips/grids/sequences/GIFs detected at scan time (schema v3 `previewAnim`); tiles show one
  cropped frame and play on hover; fps/frame-size editing moved into milestone 6 (detail view)
- [ ] 6. Pack detail
  - [ ] detail screen (opens from tile): header (title, author link, types, tags, size), preview carousel
  - [ ] file browser grid (images/sprites, audio rows with play, other files), open folder
  - [ ] animations list with fps + frame-size controls saved to sidecar `animations{}`
  - [ ] edit types/tags/title (writes `asset_pack.json`, re-indexes)
  - [ ] tests + screenshots
- [ ] 7. Credits
- [ ] 8. Archive import
- [ ] 9. itch sync
- [ ] 10. Polish

## How to verify
```
export PATH=$HOME/development/flutter/bin:$PATH
flutter analyze && flutter test
xvfb-run -a -s "-screen 0 1440x900x24" flutter test integration_test/app_test.dart -d linux
```
Screenshots land in `screenshots/` (gitignored).

## Last iteration
- Done: milestone 5. `core/animation_detector.dart` (PNG/GIF header sizes; strips/grids from `(WxH)` and `_Nf`
  hints, square-frame strips, pack-wide strip-height consensus for grids; numbered sequences; transparency-gap
  grid detection for effect packs); scanner stores `previewAnim` (index schema v3).
  `widgets/animated_sprite.dart` slices frames, drops empty cells, crops to shared opaque bounds, integer scale.
  Tiles hover-animate via MouseRegion. 89 tests + 4 integration (m5_* screenshots: Zerie, OboroPixel, Special Effects).
- Next: milestone 6 — pack detail screen.

## Open questions
- Pixel-Banner's 13 character folders are one pack ("Pixel-Banner") — they have no license/preview each.
  Can be split later by editing in the review UI.
- `assets_library_OLD/INDEX.md` (root-level notes, not a pack) was not copied. Its license table could
  pre-fill `license:` in author files during milestone 7.
- None blocking. `7zz` isn't installed but `7z` is; extractor will try `7zz`, then `7z`, then `unrar`.
