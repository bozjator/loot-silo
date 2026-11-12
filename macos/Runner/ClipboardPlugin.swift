import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// The `loot_silo/clipboard` channel on macOS (the Linux runner's
/// clipboard_plugin.cc on NSPasteboard): images and files on the
/// clipboard, Open with.
///
/// `read` and `targets` speak MIME names (`image/png`, `text/uri-list` …)
/// like the Linux side, so the integration tests read the same targets.
class ClipboardPlugin: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "loot_silo/clipboard", binaryMessenger: registrar.messenger)
    let instance = ClipboardPlugin()
    channel.setMethodCallHandler(instance.handle)
    // The channel keeps the handler (and so the instance) alive.
  }

  private var pasteboard: NSPasteboard { NSPasteboard.general }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "copyImage": result(copyImage(call.arguments))
    case "copyFiles": result(copyFiles(call.arguments))
    case "copyBytes": result(copyBytes(call.arguments))
    case "read": result(read(call.arguments))
    case "targets": result(targets())
    case "openWith": openWith(call.arguments, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: code, message: message, details: nil)
  }

  /// PNG bytes: offered as PNG and TIFF (what most Mac apps paste), at the
  /// image's own size.
  private func copyImage(_ args: Any?) -> Any? {
    guard let data = (args as? FlutterStandardTypedData)?.data else {
      return error("bad-args", "copyImage takes PNG bytes")
    }
    guard let rep = NSBitmapImageRep(data: data) else {
      return error("decode", "not a PNG")
    }
    // Pixel size, not points: a 72-dpi assumption keeps 1 px = 1 pt.
    rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setData(data, forType: .png)
    if let tiff = rep.tiffRepresentation {
      item.setData(tiff, forType: .tiff)
    }
    guard pasteboard.writeObjects([item]) else {
      return error("clipboard", "the clipboard refused the image")
    }
    return nil
  }

  /// {paths}: the files only (Finder pastes the files themselves), plus
  /// the paths as text; never an image.
  private func copyFiles(_ args: Any?) -> Any? {
    guard let paths = (args as? [String: Any])?["paths"] as? [String],
      !paths.isEmpty
    else {
      return error("bad-args", "no paths")
    }
    let items = paths.enumerated().map { (i, path) -> NSPasteboardItem in
      let item = NSPasteboardItem()
      item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
      // The first item carries all paths as text, like Linux's text target.
      if i == 0 { item.setString(paths.joined(separator: "\n"), forType: .string) }
      return item
    }
    pasteboard.clearContents()
    guard pasteboard.writeObjects(items) else {
      return error("clipboard", "the clipboard refused the files")
    }
    return nil
  }

  /// {mime, bytes}: offers only that type (e.g. image/gif → GIF).
  private func copyBytes(_ args: Any?) -> Any? {
    guard let map = args as? [String: Any],
      let mime = map["mime"] as? String,
      let data = (map["bytes"] as? FlutterStandardTypedData)?.data
    else {
      return error("bad-args", "copyBytes takes mime and bytes")
    }
    guard let type = Self.pasteboardType(mime: mime) else {
      return error("bad-args", "unknown type \(mime)")
    }
    pasteboard.clearContents()
    guard pasteboard.setData(data, forType: type) else {
      return error("clipboard", "the clipboard refused the data")
    }
    return nil
  }

  /// The clipboard's data for a MIME [target]; `text/uri-list` is the
  /// copied files' URLs, one per line. For tests.
  private func read(_ args: Any?) -> Any? {
    guard let target = args as? String else {
      return error("bad-args", "read takes a target name")
    }
    if target == "text/uri-list" {
      let urls =
        pasteboard.readObjects(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        as? [URL] ?? []
      if urls.isEmpty { return nil }
      let list = urls.map { $0.absoluteString }.joined(separator: "\r\n") + "\r\n"
      return FlutterStandardTypedData(bytes: Data(list.utf8))
    }
    guard let type = Self.pasteboardType(mime: target),
      let data = pasteboard.data(forType: type)
    else { return nil }
    return FlutterStandardTypedData(bytes: data)
  }

  /// The types on offer, as MIME names where one exists (else the UTI).
  /// For tests.
  private func targets() -> [String] {
    var names: [String] = []
    for type in pasteboard.types ?? [] {
      let name: String
      if type == .fileURL {
        name = "text/uri-list"
      } else if let mime = UTType(type.rawValue)?.preferredMIMEType {
        name = mime
      } else {
        name = type.rawValue
      }
      if !names.contains(name) { names.append(name) }
    }
    return names
  }

  static func pasteboardType(mime: String) -> NSPasteboard.PasteboardType? {
    switch mime {
    case "text/plain", "UTF8_STRING", "STRING": return .string
    case "text/uri-list": return .fileURL
    default:
      guard let uti = UTType(mimeType: mime) else { return nil }
      return NSPasteboard.PasteboardType(uti.identifier)
    }
  }

  /// A menu at the mouse of the apps that open [path] (Finder's Open With),
  /// the default first, then Other… to pick any app. Answers false when
  /// nothing was picked.
  private func openWith(_ args: Any?, result: @escaping FlutterResult) {
    guard let path = args as? String else {
      result(error("bad-args", "openWith takes a path"))
      return
    }
    let file = URL(fileURLWithPath: path)
    let workspace = NSWorkspace.shared
    let fallback = workspace.urlForApplication(toOpen: file)
    var apps = workspace.urlsForApplications(toOpen: file)
    if let d = fallback {
      apps.removeAll { $0 == d }
      apps.insert(d, at: 0)
    }

    final class Picker: NSObject {
      var picked: URL?
      var other = false
      @objc func pick(_ sender: NSMenuItem) { picked = sender.representedObject as? URL }
      @objc func pickOther(_ sender: NSMenuItem) { other = true }
    }
    let picker = Picker()
    let menu = NSMenu(title: "Open with")
    menu.autoenablesItems = false
    let heading = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
    heading.isEnabled = false
    menu.addItem(heading)
    for (i, app) in apps.enumerated() {
      var name = FileManager.default.displayName(atPath: app.path)
      if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
      if i == 0 && app == fallback { name += " (default)" }
      let item = NSMenuItem(title: name, action: #selector(Picker.pick(_:)), keyEquivalent: "")
      item.target = picker
      item.representedObject = app
      let icon = workspace.icon(forFile: app.path)
      icon.size = NSSize(width: 16, height: 16)
      item.image = icon
      menu.addItem(item)
      if i == 0 && app == fallback && apps.count > 1 { menu.addItem(.separator()) }
    }
    if !apps.isEmpty { menu.addItem(.separator()) }
    let other = NSMenuItem(title: "Other…", action: #selector(Picker.pickOther(_:)), keyEquivalent: "")
    other.target = picker
    menu.addItem(other)

    // Blocks until the menu closes; the item's action has run by then.
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)

    var app = picker.picked
    if app == nil && picker.other {
      let panel = NSOpenPanel()
      panel.title = "Open with"
      panel.prompt = "Open"
      panel.directoryURL = URL(fileURLWithPath: "/Applications")
      panel.allowedContentTypes = [.application]
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      if panel.runModal() == .OK { app = panel.url }
    }
    guard let chosen = app else {
      result(false)
      return
    }
    workspace.open(
      [file], withApplicationAt: chosen, configuration: NSWorkspace.OpenConfiguration()
    ) { _, err in
      DispatchQueue.main.async {
        if let err = err {
          result(FlutterError(code: "launch", message: err.localizedDescription, details: nil))
        } else {
          result(true)
        }
      }
    }
  }
}
