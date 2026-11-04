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
- [x] 9. itch sync — key from keychain (or ITCH_API_KEY / .env / ITCH_ENV_FILE, never logged), owned keys
  paginated, IDF title matcher + author check (real account: 53 to link, 12 inside Pixel-Banner, 5 missing),
  link/download queue through the import pipeline, covers + screenshots in `<Pack>/_itch/`
- [x] 10. Polish — settings screen (library path with confirm, theme, animate-all, itch status), shortcuts
  (`/`/Ctrl+F, Esc, Ctrl+I, Ctrl+O, F5/Ctrl+R, Ctrl+,), missing-library state with recovery, m10 screenshots

Round 2 (plan: `FIXES_PLAN.md`):
- [x] 11. Quick wins — `prettyName()` titles, hand cursor on clickable controls, mouse back button, confirm
  "remove from game", info panel sized to content, audio loop toggle (`audio_loop`)
- [x] 12. Image viewer rework — near full-window viewer (fit keeping ratio, auto whole-step vs exact fit,
  `viewer_pixel_perfect` toggle, wheel zoom/pan), prettified title + path/size, prev/next by button and ←/→,
  reveal in file manager, carousel click opens it; fixed `PixelImage` stretching under tight constraints
- [x] 13. Reveal in file manager + text/Markdown preview — reveal buttons on image cards (hover), animation
  cards, audio and file rows; text preview (UTF-8 → Latin-1, 1 MiB cap) and Markdown via `flutter_markdown_plus`
  with Raw/Rendered, copy, open externally; remote images never fetched
- [x] 14. Thumbnail size controls — sliders for dashboard tiles (140–480, `dashboard_tile_size`) and image cards
  (80–400, `image_thumb_size`), Ctrl + wheel over either grid, `ThumbGridDelegate` (fixed footer, no clipping)
- [x] 15. Animations grid + focus mode — responsive grid (`animation_thumb_size`, slider + Ctrl + wheel), editor
  in an Edit dialog (saving unchanged), focus dims/pauses others, Esc/click/←→; 60 animations scroll at ~2 ms/frame
- [x] 16. Pinnable detail header + folder grouping — pin button / `H` (`detail_header_pinned`), slim bar with
  floating header on hover; Flat | By folder for images and animations (`images_view`, `animations_view`) with
  collapsible sections at an adaptive folder depth; viewer and ←/→ follow the on-screen order
- [x] 17. Dashboard sub-folder view + tag sort — Packs | Expanded (`dashboard_view`): packs with ≥2 meaningful
  first-level image folders become one tile per folder (indexed at scan time, schema v6; Pixel-Banner → 12),
  folder-name search, tile opens the detail limited to that folder; `Tags` sort (precomputed key, untagged last)
  with sorted tag lines on tiles

## How to verify
```
export PATH=$HOME/development/flutter/bin:$PATH
flutter analyze && flutter test
xvfb-run -a -s "-screen 0 1440x900x24" flutter test integration_test/app_test.dart -d linux
```
Screenshots land in `screenshots/` (gitignored).

## Last iteration
- Done: milestone 17 — the last one. `core/sub_folders.dart`, `pack_sub_folders` table (index schema 5 → 6),
  `expandPacks` / `visibleTilesProvider`, `PackSort.tags`. 177 unit/widget tests + 21 integration.
- Next: nothing — round 2 is complete.

## Open questions
- Pixel-Banner's 13 character folders are one pack ("Pixel-Banner") — they have no license/preview each.
  Can be split later by editing in the review UI.
- `assets_library_OLD/INDEX.md` (root-level notes, not a pack) was not copied; its license table now lives in the
  author files. Pixel Banner, Zerie, RafaelMatos, ashishlko11, greatdocbrown and Robert Brooks still have no license
  on file — the Credits screen warns about them.
- None blocking. `7zz` isn't installed but `7z` is; the extractor tries `7zz`, `7z`, `7za`, then `unrar`.
- No `.rar` test fixture: nothing on this machine can create one (`rar` isn't installed). 7z goes through the
  same CLI path and is tested; drag-and-drop itself can't be driven under xvfb (the drop handler is plain code).
- itch: the 12 Pixel-Banner enemies show as "inside a pack" (folders of the big Pixel-Banner pack). Bundle items
  must be claimed on itch.io before they show up as owned — that's a website action for you. Nothing was downloaded
  from the real account; the 3 "Download all" candidates are waiting for you to press the button.
