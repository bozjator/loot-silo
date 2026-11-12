import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  #if DEBUG
  // `flutter run` starts the binary directly and then calls `open` on the
  // bundle to bring it forward; that `open` often runs before the app has
  // checked in with LaunchServices and fails (-600), printing "Failed to
  // foreground app; open returned 1". Harmless, but the window can stay
  // behind the terminal, so come forward on our own.
  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    NSApp.activate(ignoringOtherApps: true)
  }
  #endif

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
