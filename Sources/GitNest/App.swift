import SwiftUI
import AppKit

@main
struct GitNestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.model)
                .frame(minWidth: 920, minHeight: 580)
        }
        .defaultSize(width: 980, height: 660)
    }
}

/// This is a single-window utility, so quit the whole app when that window's red
/// X is clicked instead of leaving it running in the Dock (SwiftUI's default for a
/// WindowGroup). Multiple windows still work — it only terminates on the *last* close.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillTerminate(_ notification: Notification) {
        // `prepareForTermination` is async (@MainActor). Pump the run loop so the
        // chain can drain and restore gh before the process exits — a bare
        // semaphore.wait on the main thread would deadlock MainActor work.
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await model.prepareForTermination()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(15)
        while done.wait(timeout: .now()) == .timedOut {
            if Date() >= deadline { break }
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cache GitHub avatar images so the sidebar doesn't re-fetch them on every
        // appearance. Other network traffic goes through `gh`, not URLSession, so
        // this only affects avatars.
        let memoryCapacity = 50 * 1024 * 1024   // 50 MB
        let diskCapacity = 100 * 1024 * 1024    // 100 MB
        URLCache.shared = URLCache(memoryCapacity: memoryCapacity,
                                   diskCapacity: diskCapacity)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
