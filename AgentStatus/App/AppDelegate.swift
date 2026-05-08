import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Belt-and-braces: LSUIElement=true in Info.plist already keeps us out of the Dock.
        NSApp.setActivationPolicy(.accessory)
    }
}
