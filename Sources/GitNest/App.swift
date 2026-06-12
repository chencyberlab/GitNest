import SwiftUI
import AppKit

@main
struct GitNestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 980, height: 660)
    }
}

/// This is a single-window utility, so quit the whole app when that window's red
/// X is clicked instead of leaving it running in the Dock (SwiftUI's default for a
/// WindowGroup). Multiple windows still work — it only terminates on the *last* close.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
