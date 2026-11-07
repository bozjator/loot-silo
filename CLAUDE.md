# Asset Explorer

## Data compatibility

Status: PRE-RELEASE. No backward compatibility for anything.

- The index database is a disposable cache. When its tables change, bump
  `LibraryIndex.schemaVersion`; the app drops and rebuilds it (rescan). Never
  write migration code for it, before or after release.
- `asset_pack.json`, `ASSET_AUTHOR.txt` and `settings.json`: while pre-release,
  change their format freely, with no code for old formats. The test library
  (`../assets_library`) is re-imported from `../assets_library_OLD` when needed.
- BEFORE PUBLIC RELEASE (when the user says so):
  1. Add `"format_version": 1` to `asset_pack.json` and `settings.json`, and a
     version line to `ASSET_AUTHOR.txt`.
  2. Change the Status line above to RELEASED.
- After release, every change to those files must:
  - still read every older `format_version` (upgrade on read, write the new one);
  - never drop a key the app doesn't know (already the rule for
    `asset_pack.json`);
  - come with a test that loads a saved file of the previous version.

  The index stays a rebuild-only cache.
