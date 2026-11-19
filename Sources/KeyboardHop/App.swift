import SwiftUI
import AppKit

@main
struct KeyboardHopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var hop = HopController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(hop)
        } label: {
            Image(systemName: hop.anyEnabledConnected ? "keyboard.fill" : "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Makes the app reachable even when the menu bar icon is hidden (crowded menu bar or notch).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        HopController.shared.applyDockPolicy()
        // First run (nothing selected yet): show the window so setup does not depend on the menu bar icon.
        if !HopController.shared.hasSavedDevices {
            DispatchQueue.main.async { WindowPresenter.show() }
        }
    }

    // Opening the app again (Applications, Spotlight, Dock) brings up the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowPresenter.show()
        return true
    }
}

enum WindowPresenter {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            // Fixed-size window: auto-sizing to SwiftUI content caused a layout-pass crash.
            let content = ScrollView { MenuView() }
                .frame(width: 340, height: 460)
                .environmentObject(HopController.shared)
            let hosting = NSHostingController(rootView: content)
            hosting.sizingOptions = []
            let w = NSWindow(contentViewController: hosting)
            w.setContentSize(NSSize(width: 340, height: 460))
            w.title = "KeyboardHop"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
