import 'dart:io';

/// Deletes [path] and everything in it, if it is there. Files in use (or
/// gone meanwhile) are left for next time, without an error. For work
/// folders a crash may leave behind: Copy as GIF's files and the itch.io
/// download folders.
void deleteLeftovers(String path) {
  try {
    final dir = Directory(path);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } on FileSystemException {
    // In use or gone: left for next time.
  }
}
