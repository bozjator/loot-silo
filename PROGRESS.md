# Asset Explorer — Progress

Plan: `~/.claude/plans/i-have-bought-lots-sequential-possum.md`
Decision log: `../REPORT_APP_CREATION.md`

## Milestones
- [x] 1. Setup — SDK, Linux toolchain, MCP, project, repo, progress/report files
- [ ] 2. Scanner and index
  - [ ] fixture library under `test/fixtures/`
  - [ ] sidecar read/write (`ASSET_AUTHOR.txt`, `asset_pack.json`)
  - [ ] pack detector (incl. bundle sub-packs)
  - [ ] author resolver
  - [ ] type classifier
  - [ ] library scanner + drift/FTS5 index
  - [ ] real-data check on `assets_library_OLD` (18 author files, Kenney sub-packs, Zerie/RafaelMatos; cold <10 s, warm <1 s)
- [ ] 3. Folder import
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
- Done: milestone 1. Flutter 3.47.9 / Dart 3.13.7, `flutter doctor` Linux ✓, dart MCP in `../.mcp.json`,
  app shell + widget test + xvfb screenshot integration test.
- Next: milestone 2 — fixture library and sidecar parsing.

## Open questions
- None blocking. `7zz` isn't installed but `7z` is; extractor will try `7zz`, then `7z`, then `unrar`.
