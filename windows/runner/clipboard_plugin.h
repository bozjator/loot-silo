#ifndef RUNNER_CLIPBOARD_PLUGIN_H_
#define RUNNER_CLIPBOARD_PLUGIN_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// The `loot_silo/clipboard` channel on Windows (the Linux runner's
// clipboard_plugin.cc, the macOS runner's ClipboardPlugin.swift): images
// and files on the clipboard, Open with.
//
// `read` and `targets` speak MIME names (`image/png`, `text/uri-list` …)
// like the other runners, so the integration tests read the same targets.
class ClipboardPlugin {
 public:
  // |window| owns the clipboard while we write to it and parents the
  // Open with dialog.
  ClipboardPlugin(flutter::BinaryMessenger* messenger, HWND window);
  ~ClipboardPlugin();

  ClipboardPlugin(const ClipboardPlugin&) = delete;
  ClipboardPlugin& operator=(const ClipboardPlugin&) = delete;

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
};

#endif  // RUNNER_CLIPBOARD_PLUGIN_H_
