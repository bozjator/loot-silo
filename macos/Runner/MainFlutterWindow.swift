import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Our own channel: images and files on the clipboard, Open with.
    ClipboardPlugin.register(
      with: flutterViewController.registrar(forPlugin: "LootSiloClipboard"))

    super.awakeFromNib()
  }
}
