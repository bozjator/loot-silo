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
- [x] 8. Archive import — zip/tar/tar.gz via `archive` (zip-slip safe), 7z/rar via 7zz → 7z → unrar; root
  normalised; drop zone + "Import archive" button feed the folder-import review; source_path = the archive
- [ ] 9. itch sync
  - [ ] API key from secure storage / env file (never logged); settings field
  - [ ] client: owned keys (paginated), game + uploads, download URL; live smoke test with the env key
  - [ ] matching owned games ↔ library packs (itch_game_id, url, normalised title + author)
  - [ ] itch screen: matched / missing list, "Download all missing", per-item download → archive installer
  - [ ] covers + screenshots into `<Pack>/_itch/`; app fully usable without a key
- [ ] 10. Polish

## How to verify
```
export PATH=$HOME/development/flutter/bin:$PATH
flutter analyze && flutter test
xvfb-run -a -s "-screen 0 1440x900x24" flutter test integration_test/app_test.dart -d linux
```
Screenshots land in `screenshots/` (gitignored).

## Last iteration
- Done: milestone 8. `install/archive_extractor.dart`, `ui/archive_import.dart`, `DropZone` on the home screen,
  `planFolderImport(origins:)` so archive imports record the archive as `source_path` and re-imports are flagged.
  107 tests + 8 integration (m8_* screenshots).
- Next: milestone 9 — itch sync.

## Open questions
- Pixel-Banner's 13 character folders are one pack ("Pixel-Banner") — they have no license/preview each.
  Can be split later by editing in the review UI.
- `assets_library_OLD/INDEX.md` (root-level notes, not a pack) was not copied; its license table now lives in the
  author files. Pixel Banner, Zerie, RafaelMatos, ashishlko11, greatdocbrown and Robert Brooks still have no license
  on file — the Credits screen warns about them.
- None blocking. `7zz` isn't installed but `7z` is; the extractor tries `7zz`, `7z`, `7za`, then `unrar`.
- No `.rar` test fixture: nothing on this machine can create one (`rar` isn't installed). 7z goes through the
  same CLI path and is tested; drag-and-drop itself can't be driven under xvfb (the drop handler is plain code).
