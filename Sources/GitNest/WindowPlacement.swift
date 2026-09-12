import AppKit
import SwiftUI

/// A normal window frame and the display it belongs to. Keep the display's usable
/// frame so rearranging monitors preserves the window's offset on that display.
struct WindowPlacement: Codable, Equatable, Sendable {
    static let defaultsKey = "mainWindowPlacement.v1"

    struct Screen: Equatable, Sendable {
        let id: String
        let visibleFrame: CGRect
    }

    let frame: CGRect
    let screenID: String
    let screenVisibleFrame: CGRect

    static func capture(frame: CGRect, screens: [Screen]) -> WindowPlacement? {
        guard isUsable(frame) else { return nil }
        let candidates = screens.filter { isUsable($0.visibleFrame) }
        guard let screen = candidates.max(by: {
            overlap(frame, $0.visibleFrame) < overlap(frame, $1.visibleFrame)
        }), overlap(frame, screen.visibleFrame) > 0 else { return nil }
        return WindowPlacement(frame: frame, screenID: screen.id, screenVisibleFrame: screen.visibleFrame)
    }

    /// Screens are ordered with the primary display first, as NSScreen supplies
    /// them. NSScreen.main instead means the screen with keyboard focus.
    func restoredFrame(screens: [Screen]) -> CGRect? {
        guard Self.isUsable(frame), Self.isUsable(screenVisibleFrame) else { return nil }
        let candidates = screens.filter { Self.isUsable($0.visibleFrame) }
        guard let primary = candidates.first else { return nil }
        let originalScreen = candidates.first { $0.id == screenID }
        let visible = (originalScreen ?? primary).visibleFrame
        let size = CGSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        let origin: CGPoint
        if originalScreen != nil {
            // Anchor to the top-left so resolution, Dock, and menu-bar changes
            // keep the title bar reachable instead of pushing it above the screen.
            origin = CGPoint(
                x: visible.minX + frame.minX - screenVisibleFrame.minX,
                y: visible.maxY - (screenVisibleFrame.maxY - frame.maxY) - size.height)
        } else {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        return CGRect(
            x: min(max(origin.x, visible.minX), visible.maxX - size.width),
            y: min(max(origin.y, visible.minY), visible.maxY - size.height),
            width: size.width, height: size.height)
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0
    }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

/// Owns one main window's placement observers. Preferences and display discovery
/// are injected so multi-monitor restoration can be tested without that hardware.
@MainActor
final class WindowPlacementController: NSObject {
    /// Every attached main window. A second one (File > New Window) keeps SwiftUI's
    /// cascade instead of landing exactly on top of the first.
    private static let attachedWindows = NSHashTable<NSWindow>.weakObjects()

    private let defaults: UserDefaults
    private let readScreens: @MainActor () -> [WindowPlacement.Screen]
    private weak var window: NSWindow?
    private var restored = false
    private var changingFullScreen = false

    init(
        defaults: UserDefaults = .standard,
        readScreens: @escaping @MainActor () -> [WindowPlacement.Screen] = { currentScreens() }
    ) {
        self.defaults = defaults
        self.readScreens = readScreens
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        Self.attachedWindows.add(window)
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            center.addObserver(self, selector: #selector(restoreIfNeeded), name: name, object: window)
        }
        center.addObserver(self, selector: #selector(windowUpdated), name: NSWindow.didUpdateNotification, object: window)
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            center.addObserver(self, selector: #selector(save), name: name, object: window)
        }
        center.addObserver(
            self, selector: #selector(willEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
        center.addObserver(
            self, selector: #selector(didExitFullScreen), name: NSWindow.didExitFullScreenNotification, object: window)
        if window.isVisible { restoreIfNeeded() }
    }

    func detach() {
        save()
        NotificationCenter.default.removeObserver(self)
        if let window { Self.attachedWindows.remove(window) }
        window = nil
        restored = false
        changingFullScreen = false
    }

    @objc private func windowUpdated() {
        if window?.isVisible == true { restoreIfNeeded() }
    }

    @objc private func restoreIfNeeded() {
        guard !restored, let window else { return }
        // SwiftUI may center/size a window after the bridge first attaches. Wait
        // until it is shown, and ignore those initial moves when saving preferences.
        // setFrame emits move/resize notifications synchronously, before this flag.
        let isFirstMainWindow = !Self.attachedWindows.allObjects.contains { $0 !== window && $0.isVisible }
        if isFirstMainWindow, !window.styleMask.contains(.fullScreen),
            let data = defaults.data(forKey: WindowPlacement.defaultsKey),
            let placement = try? JSONDecoder().decode(WindowPlacement.self, from: data),
            let frame = placement.restoredFrame(screens: readScreens())
        {
            window.setFrame(frame, display: true)
        }
        restored = true
    }

    @objc private func save() {
        guard restored, !changingFullScreen, let window,
            !window.styleMask.contains(.fullScreen), !window.isMiniaturized,
            let placement = WindowPlacement.capture(frame: window.frame, screens: readScreens()),
            let data = try? JSONEncoder().encode(placement)
        else { return }
        defaults.set(data, forKey: WindowPlacement.defaultsKey)
    }

    @objc private func willEnterFullScreen() {
        save()
        // Full-screen animation frames must not replace the last ordinary frame.
        changingFullScreen = true
    }

    @objc private func didExitFullScreen() {
        changingFullScreen = false
        save()
    }

    static func currentScreens() -> [WindowPlacement.Screen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            // A display number can change after reconnect/reboot. Prefer the
            // system's persistent UUID so three identical monitors stay distinct.
            let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
            let id = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "display-\(number.uint32Value)"
            return WindowPlacement.Screen(id: id, visibleFrame: screen.visibleFrame)
        }
    }
}

/// The main scene owns this bridge; inspection windows cannot overwrite its saved
/// placement. Attachment follows the same lifecycle hook as the glass bridge.
struct WindowPlacementBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowView {
        WindowView(controller: WindowPlacementController())
    }

    func updateNSView(_ nsView: WindowView, context: Context) {}

    final class WindowView: NSView {
        private let controller: WindowPlacementController

        init(controller: WindowPlacementController) {
            self.controller = controller
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                controller.attach(to: window)
            } else {
                controller.detach()
            }
        }
    }
}
