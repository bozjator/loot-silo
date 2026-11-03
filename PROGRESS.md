# Asset Explorer — Progress

Plan: `~/.claude/plans/i-have-bought-lots-sequential-possum.md`
Decision log: `../REPORT_APP_CREATION.md`

## Milestones
- [x] 1. Setup — SDK, Linux toolchain, MCP, project, repo, progress/report files
- [x] 2. Scanner and index — 201 packs (71 top-level, 130 sub-packs) in OLD; cold 1.6 s, warm 0.2 s
- [x] 3. Folder import — OLD → `assets_library`: 71/71 packs, 49,778 files, SHA-1 verified; OLD byte-identical
- [x] 4. Dashboard — preview picker, pixel-aware tiles, FTS search, type/author/tag/source filters, sort, bundle browsing, goldens
- [ ] 5. Animations
  - [ ] `animation_detector` (core): GIF/APNG/WebP, strips & grids (name hints `(96x96)`, `_8f`, `-sheet`, folder hints; square-frame and transparent-column heuristics), numbered frame sequences; cached per pack
  - [ ] `AnimatedSprite` widget (frame slicing, ~10 fps, FilterQuality.none, integer scale)
  - [ ] tile: static first frame, animate on hover; preview rank 5 (detected animation) and sprite-sheet tiles show one frame instead of the whole sheet
  - [ ] detail controls (fps, frame size) saved to sidecar `animations{}` — may land with milestone 6 detail view
  - [ ] tests with generated sheets; screenshots of Zerie, OboroPixel, Special Effects
- [ ] 6. Pack detail
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
- Done: milestone 4. `core/preview_picker.dart` (plan priority + word rank, promo images skipped, bundles
  fall back to a sub-pack preview); index schema v2 (`packs.preview`, `pack_files.size`).
  `state/dashboard.dart` (query, pure `applyQuery`, facets, FTS hits). UI: `ui/dashboard.dart`,
  `widgets/{pixel_image,pack_tile,filter_bar}.dart`; `/` focuses search, Esc leaves it.
  Goldens in `test/ui/goldens/` (Roboto + Material Icons loaded from the SDK). 74 tests + 3 integration.
- Kenney bundle sidecars in `assets_library` rewritten with the new bundle-type rule (≥10 % of sub-packs).
- Next: milestone 5 — `animation_detector` with generated-sheet tests, then `AnimatedSprite` + hover.
- Golden update: `flutter test test/ui --update-goldens` (Linux-rendered; regenerate on other OSes).

## Open questions
- Pixel-Banner's 13 character folders are one pack ("Pixel-Banner") — they have no license/preview each.
  Can be split later by editing in the review UI.
- `assets_library_OLD/INDEX.md` (root-level notes, not a pack) was not copied. Its license table could
  pre-fill `license:` in author files during milestone 7.
- None blocking. `7zz` isn't installed but `7z` is; extractor will try `7zz`, then `7z`, then `unrar`.
