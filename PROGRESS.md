# Asset Explorer — Progress

Plan: `~/.claude/plans/i-have-bought-lots-sequential-possum.md`
Decision log: `../REPORT_APP_CREATION.md`

## Milestones
- [x] 1. Setup — SDK, Linux toolchain, MCP, project, repo, progress/report files
- [x] 2. Scanner and index — 201 packs (71 top-level, 130 sub-packs) in OLD; cold 1.6 s, warm 0.2 s
- [ ] 3. Folder import
  - [ ] `FolderImporter.plan(source)` → import plan rows (pack, author, types, tags, target `<Author>/<Pack>`), sub-packs stay inside their bundle
  - [ ] copy step with per-pack file count + checksum verification; writes sidecars; never touches the source
  - [ ] review UI (table, fix unknown authors, edit tags/types, target conflicts)
  - [ ] run for real: `assets_library_OLD` → `assets_library`, verify counts/checksums
- [ ] 4. Dashboard
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
- Done: milestone 2. `lib/core/`: `sidecar`, `fs_tree` (tree snapshot + dir-mtime fingerprint),
  `pack_detector`, `author_resolver`, `type_classifier` (+ path tag suggester), `library_scanner`,
  `library_index` (drift + FTS5), `library_service` (warm/cold load in isolates).
  Fixtures in `test/fixtures/{library_src,managed}`; 40 tests incl. read-only real-data test
  (`test/real_library_test.dart`, auto-skips without `../assets_library_OLD`).
  `dart run tool/scan_report.dart <folder>` prints a read-only detection report.
- Next: milestone 3 — `FolderImporter.plan()` + copy/verify step (core first, then review UI).
- After editing `library_index.dart`: `dart run build_runner build`.

## Open questions
- Pixel-Banner's 13 character folders are one pack ("Pixel-Banner") — they have no license/preview each.
  Can be split later by editing in the review UI.
- None blocking. `7zz` isn't installed but `7z` is; extractor will try `7zz`, then `7z`, then `unrar`.
