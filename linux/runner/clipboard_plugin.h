#ifndef RUNNER_CLIPBOARD_PLUGIN_H_
#define RUNNER_CLIPBOARD_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

// The `loot_silo/clipboard` channel: puts images and files on the GTK
// clipboard (works on X11 and Wayland), reads it back, and shows GTK's
// "Open with" chooser.
//
// Methods:
//   copyImage(Uint8List png)        image/png (and the other pixbuf formats)
//   copyFiles(List<String> paths, [String mime, Uint8List bytes])
//                                   text/uri-list, x-special/gnome-copied-files
//                                   and the paths as text; plus `mime` with
//                                   `bytes` when given (image/gif)
//   read(String target) -> Uint8List?  the clipboard's data for `target`
//   targets() -> List<String>       the clipboard's target names
//   openWith(String path) -> bool   the app chooser, then launches the pick
void clipboard_plugin_register_with_registrar(FlPluginRegistrar* registrar);

#endif  // RUNNER_CLIPBOARD_PLUGIN_H_
