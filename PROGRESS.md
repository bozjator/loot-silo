# Asset Explorer — Progress

Plan: `~/.claude/plans/i-have-bought-lots-sequential-possum.md`
Decision log: `../REPORT_APP_CREATION.md`

## Milestones
- [x] 1. Setup — SDK, Linux toolchain, MCP, project, repo, progress/report files
- [x] 2. Scanner and index — 201 packs (71 top-level, 130 sub-packs) in OLD; cold 1.6 s, warm 0.2 s
- [x] 3. Folder import — OLD → `assets_library`: 71/71 packs, 49,778 files, SHA-1 verified; OLD byte-identical
- [ ] 4. Dashboard
  - [ ] thumbnail cache + preview picker (sidecar cover → preview/mockup names → gif → largest PNG)
  - [ ] pack tile (preview, title, author, type chips; bundles group sub-packs)
  - [ ] grid replacing the temporary list on the home screen
  - [ ] FTS search box + filter chips (type, author, tag, source) + sorting
  - [ ] goldens for tile + filter bar; screenshot check on real library
- [ ] 5. Animations
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
- Done: milestone 3. `lib/install/folder_importer.dart` (plan → targets with ` (n)` on clashes →
  staged copy + per-file SHA-1 check → sidecar + merged author file → atomic rename; source/library
  overlap refused; re-imports detected via `source_path`). `lib/state/` (settings JSON, Riverpod
  providers, library notifier). UI: home (choose library / empty / temporary pack list), review screen
  with editable author/types/tags, progress + summary. `tool/import_folder.dart` = headless import.
  56 unit/widget tests + 3 integration tests (fixture import via UI, real OLD review, real library open).
- Real run: 5 min for 2.9 GB; independent `sha1sum` check of OLD before/after identical; python
  re-verification of every pack vs its `source_path`: 0 mismatches. Rescan of the library → 201 packs.
- App settings written to `~/.local/share/dev.uzo.assets_explorer/settings.json` → `assets_library`.
- Next: milestone 4 — thumbnail cache + preview picker, then tiles/grid.

## Open questions
- Pixel-Banner's 13 character folders are one pack ("Pixel-Banner") — they have no license/preview each.
  Can be split later by editing in the review UI.
- `assets_library_OLD/INDEX.md` (root-level notes, not a pack) was not copied. Its license table could
  pre-fill `license:` in author files during milestone 7.
- None blocking. `7zz` isn't installed but `7z` is; extractor will try `7zz`, then `7z`, then `unrar`.
