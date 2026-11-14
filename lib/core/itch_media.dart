/// Folder for itch.io covers and screenshots inside a pack.
///
/// It is pack metadata, not content: its files show as the tile preview
/// and in the header carousel only, never in the tabs, folder groups,
/// types, tags, file search or the pack's file count and size.
const itchMediaDir = '_itch';

/// Whether [rel] (pack-relative, `/`-separated) is itch metadata.
bool isItchMedia(String rel) =>
    rel == itchMediaDir || rel.startsWith('$itchMediaDir/');
