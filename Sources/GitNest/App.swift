import SwiftUI
import AppKit

@main
struct GitNestApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .gitNestEnvironment(appDelegate.model)
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

    /// Guards the single `reply(toApplicationShouldTerminate:)` call — both the
    /// drain task and the watchdog below race to send it, and sending twice is
    /// undefined.
    private var terminationReplySent = false

    /// `prepareForTermination` is async (@MainActor): it drains the gh chain and
    /// restores the pre-app active account before we quit. Use AppKit's deferred
    /// termination — `.terminateLater` keeps the app alive until we reply — instead
    /// of hand-pumping the run loop, which can re-enter and process stray events.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        func reply() {
            guard !terminationReplySent else { return }
            terminationReplySent = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await model.prepareForTermination()
            reply()
        }
        // Watchdog: never block quit on a hung restore (e.g. a wedged gh chain).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
            reply()
        }
        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if activateExistingInstanceAndTerminateIfNeeded() {
            return
        }
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

    /// Enforce a single running process for this bundle. Pick one deterministic
    /// "primary" PID from all siblings and keep only that process alive. This avoids
    /// a dual-launch race where two fresh instances each decide to terminate.
    private func activateExistingInstanceAndTerminateIfNeeded() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let siblings = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let primaryPID = Self.primaryProcessIDForDuplicate(currentPID: currentPID,
                                                                 candidatePIDs: siblings.map(\.processIdentifier)),
              let primary = siblings.first(where: { $0.processIdentifier == primaryPID }) else {
            return false
        }
        let options: NSApplication.ActivationOptions = [.activateAllWindows, .activateIgnoringOtherApps]
        _ = primary.unhide()
        guard primary.activate(options: options) else { return false }
        NSApplication.shared.terminate(nil)
        return true
    }

    nonisolated static func primaryProcessID(candidatePIDs: [pid_t]) -> pid_t? {
        candidatePIDs.min()
    }

    nonisolated static func primaryProcessIDForDuplicate(currentPID: pid_t, candidatePIDs: [pid_t]) -> pid_t? {
        guard let primaryPID = primaryProcessID(candidatePIDs: candidatePIDs),
              primaryPID != currentPID else { return nil }
        return primaryPID
    }
}
