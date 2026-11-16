import 'dart:io';

/// Clears the read-only flag on everything under [path] (Windows only).
/// Archives carry Windows attributes: a read-only folder or file from one
/// can't be deleted (Access is denied) and, copied into the library,
/// can't be edited either. Best effort: failures are ignored.
void clearReadOnly(String path) {
  if (!Platform.isWindows) return;
  try {
    Process.runSync('attrib', ['-R', '$path\\*', '/S', '/D']);
    Process.runSync('attrib', ['-R', path]);
  } on Object {
    // No attrib: nothing to do.
  }
}

/// Deletes [path] and everything in it, if it is there. Files in use (or
/// gone meanwhile) are left for next time, without an error. For work
/// folders a crash may leave behind: Copy as GIF's files and the itch.io
/// download folders.
void deleteLeftovers(String path) {
  final dir = Directory(path);
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Read-only entries (from an archive) refuse deletion on Windows.
    clearReadOnly(path);
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // In use or gone: left for next time.
    }
  }
}
