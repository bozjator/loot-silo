import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // Remember the window's frame between runs (in the app's user defaults).
    // AppKit puts it back on its screen if that is still attached, and onto
    // a visible one otherwise.
    self.setFrameAutosaveName("MainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Our own channel: images and files on the clipboard, Open with.
    ClipboardPlugin.register(
      with: flutterViewController.registrar(forPlugin: "LootSiloClipboard"))

    super.awakeFromNib()
  }
}
