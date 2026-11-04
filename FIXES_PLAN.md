# Asset Explorer — Fix & feature round 2

Seven milestones, ordered so that shared building blocks land first (title formatting, image viewer,
settings fields) and later milestones reuse them. Each milestone below is a self-contained prompt: paste
one at a time into a fresh session, review, then move to the next.

---

## Shared preamble (prepend to every milestone prompt)

> You are working on the Flutter desktop app in `assets_explorer_app/` (Linux first; Riverpod 3, drift,
> audioplayers). Read `../REPORT_APP_CREATION.md` first: it records conventions and past decisions — follow
> them (core stays pure Dart, settings live in `settings.json` via `lib/state/settings.dart`, tests use
> `test/helpers/`). The real library is `../assets_library`; never write to it from tests.
>
> Rules:
> - Keep the style of the surrounding code (small private widgets, `///` doc comments on non-obvious things).
> - Every new setting is persisted in `AppSettings` (JSON key in snake_case) and has a sensible default that
>   keeps today's behaviour unless the milestone says otherwise.
> - Add/extend widget tests for each item; update golden tests if they change on purpose.
> - Done = `flutter analyze` clean, `flutter test` green, the app launched and each item checked by hand
>   (hot reload is fine), and a new "Milestone N" section appended to `../REPORT_APP_CREATION.md` listing
>   any decisions you took without asking.
> - If an item is ambiguous, pick the most conservative option, note it in the report, and move on.

---

## Milestone 11 — Quick wins & shared helpers

Small, low-risk fixes plus one helper the later milestones depend on.

1. **`prettyName()` helper** (`lib/ui/format.dart`): takes a file or folder name, strips the extension
   (for files), replaces `-` and `_` with spaces, collapses repeated whitespace, trims, and upper-cases the
   first character (leave the rest as-is so `NPC` / `UI` survive). Unit-test it with real names from the
   library (`Knight_Idle-Anim.png` → `Knight Idle Anim`, `walk-cycle_v2.png`, `  __weird--name__ `).
2. **Animation card titles** (`_AnimationCard` in `lib/ui/pack_detail_screen.dart`): show `prettyName(file)`
   as the title; keep the raw relative path available in a tooltip.
3. **Pointer cursor on everything clickable**: audit `InkWell`/`GestureDetector`/custom tap targets
   (pack tiles, image cards, carousel, chips, file rows, credits rows…). Material buttons already do this;
   bare `GestureDetector`s don't — wrap them in `MouseRegion(cursor: SystemMouseCursors.click)` or switch to
   `InkWell`. Prefer a central fix (e.g. theme or a tiny `Clickable` wrapper) over sprinkling.
4. **Mouse back button**: pressing the mouse "back" side button (`kBackMouseButton`) closes the current page
   exactly like Esc does (pack detail → dashboard, bundle → parent). Implement once, next to the existing Esc
   `CallbackShortcuts` around the navigator in `lib/ui/app.dart`, with a `Listener` on `onPointerDown`. Must
   also leave an opened bundle on the dashboard (`DashboardQueryNotifier` bundle state), not only routes.
   Optional: forward button re-opens the last closed pack, only if trivial.
5. **Credits — confirm removal**: `_remove` in `lib/ui/credits_screen.dart` asks "Remove *<pack>* from
   *<game>*?" with Cancel / Remove before calling `setUsedIn`.
6. **Info panel without scrollbar**: the detail header is a fixed `SizedBox(height: 300)`. Make the info
   column fit its content (e.g. let the header size to the taller of info vs. carousel, with the carousel
   keeping a minimum height), so the info text no longer gets a vertical scrollbar for typical packs.
   Check with the longest real pack (many tags/types) and a pack with no author.
7. **Audio looping**: add a loop toggle to the audio tab (one toggle for the tab, shown in a small toolbar
   above the list; remembered in settings as `audio_loop`). When on, use `ReleaseMode.loop` so the playing
   file repeats; turning it off mid-play lets the current play finish. Keep the "stop" icon state correct.

Acceptance: each item verified by hand; tests for `prettyName`, credits confirmation dialog, back button
(simulate a pointer down with `buttons: kBackMouseButton`) and loop toggle state.

---

## Milestone 12 — Image viewer rework

Replace `_ImageDialog` with a proper viewer used everywhere an image can be enlarged.

**Known root cause for "wrong ratio / limited size"**: `PixelImage` uses `integerScale()`, which floors
upscaling to whole numbers, so a 500 px image in an 868 px box stays at 1× (and a 1000 px-wide image in a
900 px dialog is shrunk while a 450 px one is not enlarged at all). On top of that the dialog is a fixed
900 × 700 box. Fix both:

1. **Viewer size**: near full-window (e.g. 95% of the window, dark backdrop), resizes with the window.
2. **Scaling**: fit the image to the available area *preserving aspect ratio*. Keep integer scaling for small
   pixel art (crisp), but allow fractional fit when integer scaling would waste a lot of space (e.g. when the
   integer result is < 75% of the fit size), or offer a toggle "Pixel-perfect / Fit". Add mouse-wheel zoom and
   drag-to-pan (`InteractiveViewer`), double-click to reset. Make sure thumbnails keep their current look
   unless they were also wrong — verify a few wide sprite sheets and tall UI images.
3. **Title**: file name at the top center via `prettyName()` (no `-`/`_`, no extension, first letter
   capitalised). Below/beside it in small text: relative path, `W × H px`, file size.
4. **Prev / next**: on-screen chevron buttons left/right plus ←/→ keys; navigates within the list the viewer
   was opened from (images tab order, or the carousel list). Show "3 / 42". Wraps or stops at the ends — pick
   stop and disable the button.
5. **Open in file explorer** button in the viewer (see Milestone 13 item 1 for the shared helper — if 13 is
   not done yet, create the helper here).
6. **Click the detail preview to enlarge**: clicking the carousel image in the pack detail header opens the
   same viewer on the carousel's image list at the current index.
7. Esc and mouse-back close the viewer.

Acceptance: a 16×16 sprite, a 500×300 image, a 4000×200 strip and a 300×1200 image all open filling the
viewer with correct proportions; prev/next works by button and keyboard; widget tests for navigation and title.

---

## Milestone 13 — Reveal in file explorer & text file preview

1. **Reveal helper** `revealInFileManager(String path)` in `lib/ui/` (or a small platform util): Linux — try
   `dbus-send` to `org.freedesktop.FileManager1.ShowItems` (selects the file in Nautilus/Dolphin/etc.), fall
   back to opening the parent folder with `launchUrl(Uri.directory(...))`; Windows `explorer /select,`;
   macOS `open -R`. Use it from:
   - each image card (context menu or small icon on hover) and the image viewer,
   - each animation card,
   - optionally audio rows and other-files rows (cheap once the helper exists).
2. **Text preview in "Other files"**: `.txt` and `.md` rows (also `.json`, `.csv`, `.ini`, `.cfg`, `.tsx`/`.tmx`
   if cheap — plain text) become clickable and open a preview dialog/side panel:
   - `.txt` and others: monospace, selectable, scrollable; decode as UTF-8 with Latin-1 fallback; cap at ~1 MB
     with a "file too large, open externally" message.
   - `.md`: rendered Markdown with a "Raw / Rendered" toggle. Choose a maintained Markdown package (the old
     `flutter_markdown` is discontinued — check pub.dev for its maintained successor) and record the choice in
     the report. Links open in the browser via `url_launcher`.
   - Buttons: Copy all, Open externally, Reveal in file manager.

Acceptance: README/license files from real packs render correctly; non-UTF-8 file doesn't crash; tests for
decoding fallback and the size cap.

---

## Milestone 14 — Thumbnail size controls

1. **Dashboard**: a size slider (or S/M/L/XL segmented control) in the dashboard toolbar that drives
   `maxCrossAxisExtent` of the grid (currently fixed at 240). Range roughly 140–480. Persist as
   `dashboard_tile_size`.
2. **Pack detail → Images tab**: same control above the grid, driving the images grid (currently fixed 160).
   Range roughly 80–400. Persist as `image_thumb_size`.
3. Ctrl + mouse wheel over a grid changes its size too (nice to have).
4. Keep `childAspectRatio` sensible at every size (labels must not clip); make sure `PageStorageKey` scroll
   restore still works after a size change.

Acceptance: sizes survive an app restart; golden/widget test at min and max sizes.

---

## Milestone 15 — Animations grid with focus mode

1. Replace the `ListView` of `_AnimationCard`s with a responsive grid: multiple cards per row, column count
   from available width. The editing controls (fps, frame size, row) may move into a compact footer or an
   expandable "Edit" section so cards stay small; saving overrides must keep working exactly as today.
2. Card size follows the same kind of size control as Milestone 14 (persist as `animation_thumb_size`).
3. **Focus mode**: clicking a card (or a "focus" icon) focuses it — all other cards dim (e.g. 35% opacity /
   dark overlay, animated) and the focused one gets a highlight border and may scale up slightly. Click the
   focused card again, click empty space, or press Esc to clear focus. ←/→ move focus between cards.
4. Performance: many animations playing at once must stay smooth — consider only animating visible cards and,
   in focus mode, optionally pausing the dimmed ones.

Acceptance: a pack with 50+ animations scrolls smoothly; saving an override from the grid still updates the
dashboard tile; widget test for focus/unfocus.

---

## Milestone 16 — Pack detail layout: pinnable header & folder grouping

1. **Pin / unpin header**: a pin icon in the app bar. Pinned (default) = today's layout. Unpinned = the header
   (carousel + info) collapses to just a slim title bar so tabs get the whole height; hovering the title bar
   shows the full header as a floating overlay above the tabs (no layout shift), hiding again when the mouse
   leaves. Persist as `detail_header_pinned`. Keyboard: a shortcut (e.g. `H`) toggles it.
2. **Folder-grouped view** for the Images and Animations tabs: a view toggle (Flat | By folder) in each tab's
   toolbar. "By folder" groups items by their parent folder with a section header per folder showing
   `prettyName(folderName)` (or the relative folder path prettified when nested, e.g. `Characters / Knight`)
   and a count; sections are collapsible. Files at the pack root go under a "Pack root" (or pack title)
   section. Persist the choice per tab (`images_view`, `animations_view`).
3. Prev/next in the image viewer follows the visible order (grouped order when grouped).

Acceptance: Pixel-Banner (13 character folders) reads as 13 labelled sections; unpinning gives the images grid
the full window height; widget tests for the toggle and hover overlay.

---

## Milestone 17 — Dashboard: sub-folder view & tag sorting

**Problem**: some packs are collections of distinct things (e.g. Pixel-Banner = one pack with 13
character folders). Today you only see one tile and must open the pack to see what's inside.

1. **Dashboard view modes** (segmented control in the toolbar, persisted as `dashboard_view`):
   - **Packs** — today's behaviour.
   - **Expanded** — packs whose content splits into several meaningful sub-folders (reuse/extend the
     sub-folder logic from `pack_detector.dart`; e.g. ≥2 first-level folders that each contain images/animations)
     are shown as one tile per sub-folder: preview picked from that folder (reuse `preview_picker.dart`), title
     `prettyName(folder)`, subtitle = pack title. Clicking opens the pack detail with that folder pre-selected
     (scroll to / filter by that folder, using Milestone 16 grouping). Packs without such sub-folders stay a
     single tile.
   - Optional: **Grouped by pack** — a header per pack followed by its sub-folder tiles.
   Decide whether sub-folder tiles need to be indexed (preview picking at scan time, stored in drift) or can be
   computed lazily; prefer indexing if lazy is slow on the real library, and bump the index schema if so (the
   index is disposable). Search should match sub-folder names in Expanded view.
2. **Sorting by tags**: add a `PackSort.tags` option ("Tags"). Same flat grid as today — no grouping or
   headers. Sort key = the pack's tags sorted alphabetically (case-insensitive) and joined into one string
   (e.g. `characters, fantasy, pixel`), compared alphabetically; ties broken by title. Don't assume the stored
   tag order is sorted — sort the tags when building the key (and check whether the tile already shows them
   sorted; if not, show them sorted too so the order on screen matches the sort). Untagged packs go last.
   Compute the key once per pack (e.g. when packs are loaded), not inside the comparator. If this is
   measurably slow on the real library, fall back to sorting by the first tag only and note it in the report
   (expected cost is negligible for a few hundred packs). Works together with the existing tag filter.

Acceptance: Pixel-Banner shows 13 character tiles in Expanded view; switching views keeps search/filters;
tag sort orders by the joined sorted tags and is stable; tests in `test/state/dashboard_test.dart` for the new sort and view state.

---

## Item → milestone map

| Request | Milestone |
|---|---|
| Audio looping | 11 |
| Dashboard views for packs with different contents (characters) | 17 |
| Prev/next in opened image | 12 |
| Mouse back button | 11 |
| Taller info text, no scrollbar | 11 |
| Animations: several per row + focus mode | 15 |
| Images wrong ratio / limited size | 12 |
| Thumbnail size (dashboard + images tab) | 14 |
| Show .txt / .md content | 13 |
| Open animation / image in file explorer | 13 (helper may land in 12) |
| Animation title: no `-`/`_`, capitalised | 11 |
| Image viewer: file name at top center, prettified | 12 |
| Click detail preview to enlarge | 12 |
| Images/animations: view grouped by folder titles | 16 |
| Pin / unpin detail header, hover to expand | 16 |
| Credits: confirm removal | 11 |
| Sorting by tags | 17 |
| Pointer cursor on clickable things | 11 |
