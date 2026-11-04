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
- [x] 6. Pack detail — carousel, info with editable title/types/tags (sidecar + quiet rescan), tabs for
  animations (fps / frame size / row, saved as sidecar overrides), images (viewer dialog), audio (play/stop),
  other files; open folder; author link; bundle details from the breadcrumb
- [ ] 7. Credits
  - [ ] mark packs "used in <game>" (sidecar `used_in`), from the detail view and multi-select on the dashboard
  - [ ] credits screen: pick a game → CREDITS.md / .txt grouped by author (name, URL, license, packs)
  - [ ] copy to clipboard + save file; license lines from author files (prefill from OLD INDEX.md table)
  - [ ] tests + screenshots
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
- Done: milestone 6. `core/pack_editor.dart` (`loadPackContents` in an isolate, `updatePackSidecar`,
  `saveAnimationOverride`), `ui/pack_detail_screen.dart`, dialogs moved to `widgets/meta_dialogs.dart`,
  `LibraryNotifier.reload()` (rescan without a loading screen), `LibraryIndex.filesWithSizes`.
  93 tests + 6 integration (m6_* screenshots). Edits in tests run on temp copies only.
- Next: milestone 7 — credits.

## Open questions
- Pixel-Banner's 13 character folders are one pack ("Pixel-Banner") — they have no license/preview each.
  Can be split later by editing in the review UI.
- `assets_library_OLD/INDEX.md` (root-level notes, not a pack) was not copied. Its license table could
  pre-fill `license:` in author files during milestone 7.
- None blocking. `7zz` isn't installed but `7z` is; extractor will try `7zz`, then `7z`, then `unrar`.
