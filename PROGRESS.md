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
- [x] 7. Credits — "used in" chips on the detail page, Credits screen (games, pack picker, .md/.txt preview,
  copy, save), author info dialog (URL, license, credit wording, attribution); licenses prefilled from OLD INDEX.md
- [ ] 8. Archive import
  - [ ] `core/archive_extractor`: zip via `archive` (zip-slip safe), rar/7z via `7zz` → `7z` → `unrar`
  - [ ] normalise the root (unwrap single nested folders), staging dir, cleanup
  - [ ] drop zone on the dashboard (desktop_drop) + "Import archive" button; author dialog → PackInstaller
  - [ ] tests: zip with/without root, nested single folders, rar/7z via the CLI, bad archives
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
- Done: milestone 7. `core/credits.dart` (`collectCredits`, markdown/text renderers), `setUsedIn` and
  `updateAuthorInfo` in `pack_editor.dart`, index schema v4 (`packs.used_in`), `ui/credits_screen.dart`,
  `GameNameDialog`/`AuthorInfoDialog`. `tool/prefill_licenses.dart` filled 9 author files in `assets_library`.
  `pumpUntil` now waits in real time (isolate rescans). 96 tests + 7 integration (m7_credits screenshot).
- Next: milestone 8 — archive import.

## Open questions
- Pixel-Banner's 13 character folders are one pack ("Pixel-Banner") — they have no license/preview each.
  Can be split later by editing in the review UI.
- `assets_library_OLD/INDEX.md` (root-level notes, not a pack) was not copied; its license table now lives in the
  author files. Pixel Banner, Zerie, RafaelMatos, ashishlko11, greatdocbrown and Robert Brooks still have no license
  on file — the Credits screen warns about them.
- None blocking. `7zz` isn't installed but `7z` is; extractor will try `7zz`, then `7z`, then `unrar`.
