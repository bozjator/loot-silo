# Loot Silo

## Data compatibility

Status: RELEASED. Saved user files must keep working across versions.

- The index database is a disposable cache. When its tables change, bump
  `LibraryIndex.schemaVersion`; the app drops and rebuilds it (rescan). Never
  write migration code for it.
- `asset_pack.json`, `ASSET_AUTHOR.txt` and `settings.json` are user data.
  Each carries a format version (`"format_version"` in the JSON files, a
  version line in `ASSET_AUTHOR.txt`); version 1 is the first released format.
- Every change to those files must:
  - still read every older format version (upgrade on read, write the new one);
  - never drop a key the app doesn't know (applies to all three files);
  - come with a test that loads a saved file of the previous version.
