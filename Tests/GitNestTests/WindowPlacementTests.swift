import AppKit
import XCTest
@testable import GitNest

final class WindowPlacementTests: XCTestCase {
    private typealias Screen = WindowPlacement.Screen

    // Menu-bar display first, as NSScreen.screens orders them.
    private let primary = Screen(id: "primary", visibleFrame: CGRect(x: 0, y: 0, width: 2048, height: 1100))
    private let external = Screen(id: "external", visibleFrame: CGRect(x: 2048, y: 200, width: 1920, height: 1055))

    func testCaptureBindsToScreenWithLargestOverlap() throws {
        // Straddles the seam, but most of the window sits on the external display.
        let frame = CGRect(x: 1848, y: 400, width: 1000, height: 600)
        let placement = try XCTUnwrap(WindowPlacement.capture(frame: frame, screens: [primary, external]))
        XCTAssertEqual(placement.screenID, "external")
        XCTAssertEqual(placement.screenVisibleFrame, external.visibleFrame)
        XCTAssertEqual(placement.frame, frame)
    }

    func testCaptureRejectsOffscreenAndDegenerateFrames() {
        XCTAssertNil(WindowPlacement.capture(frame: CGRect(x: -5000, y: -5000, width: 800, height: 600),
                                             screens: [primary, external]))
        XCTAssertNil(WindowPlacement.capture(frame: CGRect(x: 100, y: 100, width: 0, height: 600),
                                             screens: [primary]))
        XCTAssertNil(WindowPlacement.capture(frame: CGRect(x: CGFloat.nan, y: 100, width: 800, height: 600),
                                             screens: [primary]))
        XCTAssertNil(WindowPlacement.capture(frame: CGRect(x: 100, y: 100, width: 800, height: 600), screens: []))
    }

    func testRestoreOnUnchangedScreenIsIdentity() throws {
        let frame = CGRect(x: 2300, y: 350, width: 980, height: 660)
        let placement = try XCTUnwrap(WindowPlacement.capture(frame: frame, screens: [primary, external]))
        XCTAssertEqual(placement.restoredFrame(screens: [primary, external]), frame)
    }

    func testMissingScreenFallsBackToCenterOfPrimary() throws {
        let frame = CGRect(x: 2300, y: 350, width: 980, height: 660)
        let placement = try XCTUnwrap(WindowPlacement.capture(frame: frame, screens: [primary, external]))
        let restored = try XCTUnwrap(placement.restoredFrame(screens: [primary]))
        XCTAssertEqual(restored.size, frame.size)
        XCTAssertEqual(restored.midX, primary.visibleFrame.midX, accuracy: 0.5)
        XCTAssertEqual(restored.midY, primary.visibleFrame.midY, accuracy: 0.5)
    }

    func testRearrangedScreenKeepsTopLeftOffset() throws {
        // 100pt from the left edge, 45pt below the top of the external display.
        let frame = CGRect(x: 2148, y: 550, width: 980, height: 660)
        let placement = try XCTUnwrap(WindowPlacement.capture(frame: frame, screens: [primary, external]))
        // Same display, now placed to the left of the primary with a moved Dock.
        let moved = Screen(id: "external", visibleFrame: CGRect(x: -1920, y: 80, width: 1920, height: 1000))
        let restored = try XCTUnwrap(placement.restoredFrame(screens: [primary, moved]))
        XCTAssertEqual(restored.size, frame.size)
        XCTAssertEqual(restored.minX, moved.visibleFrame.minX + 100)
        XCTAssertEqual(moved.visibleFrame.maxY - restored.maxY, 45)
    }

    func testOversizedOrOffsetFramesAreClampedIntoTheScreen() throws {
        let frame = CGRect(x: 2148, y: 250, width: 1900, height: 1000)
        let placement = try XCTUnwrap(WindowPlacement.capture(frame: frame, screens: [primary, external]))
        // Same display at a much smaller resolution.
        let small = Screen(id: "external", visibleFrame: CGRect(x: 2048, y: 0, width: 1280, height: 720))
        let restored = try XCTUnwrap(placement.restoredFrame(screens: [primary, small]))
        XCTAssertEqual(restored, small.visibleFrame)

        // A shrunk primary should still contain a fallback-centered window.
        let tiny = Screen(id: "primary", visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let fallback = try XCTUnwrap(placement.restoredFrame(screens: [tiny]))
        XCTAssertEqual(fallback, tiny.visibleFrame)
    }

    func testRestoreWithoutUsableScreensReturnsNil() throws {
        let placement = try XCTUnwrap(WindowPlacement.capture(
            frame: CGRect(x: 10, y: 10, width: 800, height: 600), screens: [primary]))
        XCTAssertNil(placement.restoredFrame(screens: []))
        XCTAssertNil(placement.restoredFrame(screens: [Screen(id: "p", visibleFrame: .zero)]))
    }

    func testPlacementRoundTripsThroughJSON() throws {
        let placement = try XCTUnwrap(WindowPlacement.capture(
            frame: CGRect(x: 2300.5, y: 350.25, width: 980, height: 660), screens: [primary, external]))
        let data = try JSONEncoder().encode(placement)
        XCTAssertEqual(try JSONDecoder().decode(WindowPlacement.self, from: data), placement)
    }
}

final class WindowPlacementControllerTests: XCTestCase {
    private typealias Screen = WindowPlacement.Screen

    /// Reports itself visible so the controller restores on attach without the
    /// test ever ordering a real window on screen.
    @MainActor
    private final class VisibleWindow: NSWindow {
        var reportsVisible = true
        override var isVisible: Bool { reportsVisible }
    }

    // Small fake displays so every computed frame also fits on the test host's
    // real primary display: AppKit constrains real window frames to real screens.
    private let primary = Screen(id: "primary", visibleFrame: CGRect(x: 0, y: 0, width: 640, height: 720))
    private let external = Screen(id: "external", visibleFrame: CGRect(x: 640, y: 0, width: 640, height: 720))
    private let initial = CGRect(x: 100, y: 100, width: 400, height: 300)
    private let saved = CGRect(x: 700, y: 100, width: 500, height: 400)
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "GitNestTests.WindowPlacement.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    @MainActor
    private func makeWindow(frame: CGRect) -> VisibleWindow {
        // AppKit needs its application singleton before allocating test windows.
        _ = NSApplication.shared
        let window = VisibleWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func store(_ placement: WindowPlacement) throws {
        defaults.set(try JSONEncoder().encode(placement), forKey: WindowPlacement.defaultsKey)
    }

    private func stored() throws -> WindowPlacement? {
        try defaults.data(forKey: WindowPlacement.defaultsKey).map { try JSONDecoder().decode(WindowPlacement.self, from: $0) }
    }

    @MainActor
    func testAttachRestoresSavedFrameAndSavesLaterMoves() throws {
        try store(try XCTUnwrap(WindowPlacement.capture(frame: saved, screens: [primary, external])))
        let window = makeWindow(frame: initial)
        defer { window.close() }
        let screens = [primary, external]
        let controller = WindowPlacementController(defaults: defaults, readScreens: { screens })

        controller.attach(to: window)
        XCTAssertEqual(window.frame, saved)

        let moved = CGRect(x: 50, y: 150, width: 450, height: 350)
        window.setFrame(moved, display: false)
        XCTAssertEqual(try stored()?.frame, moved)
        XCTAssertEqual(try stored()?.screenID, "primary")
    }

    @MainActor
    func testMovesBeforeTheWindowIsShownAreNotSaved() throws {
        let placement = try XCTUnwrap(WindowPlacement.capture(frame: saved, screens: [primary, external]))
        try store(placement)
        let window = makeWindow(frame: initial)
        defer { window.close() }
        window.reportsVisible = false
        let screens = [primary, external]
        let controller = WindowPlacementController(defaults: defaults, readScreens: { screens })

        controller.attach(to: window)
        // SwiftUI centring/sizing the window before it appears must not clobber
        // the placement we are about to restore.
        window.setFrame(CGRect(x: 200, y: 200, width: 500, height: 400), display: false)
        XCTAssertEqual(try stored(), placement)
        XCTAssertNotEqual(window.frame, saved)

        window.reportsVisible = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(window.frame, saved)
    }

    @MainActor
    func testMissingDisplayRestoresOntoPrimary() throws {
        try store(try XCTUnwrap(WindowPlacement.capture(frame: saved, screens: [primary, external])))
        let window = makeWindow(frame: initial)
        defer { window.close() }
        let screens = [primary]
        let controller = WindowPlacementController(defaults: defaults, readScreens: { screens })

        controller.attach(to: window)
        XCTAssertTrue(primary.visibleFrame.contains(window.frame))
        XCTAssertEqual(window.frame.size, saved.size)
    }

    @MainActor
    func testFullScreenTransitionsDoNotReplaceTheNormalFrame() throws {
        let window = makeWindow(frame: initial)
        defer { window.close() }
        let screens = [primary, external]
        let controller = WindowPlacementController(defaults: defaults, readScreens: { screens })
        controller.attach(to: window)

        let normal = CGRect(x: 300, y: 200, width: 500, height: 400)
        window.setFrame(normal, display: false)
        XCTAssertEqual(try stored()?.frame, normal)

        let center = NotificationCenter.default
        center.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        window.setFrame(primary.visibleFrame, display: false)
        XCTAssertEqual(try stored()?.frame, normal)

        center.post(name: NSWindow.didExitFullScreenNotification, object: window)
        XCTAssertEqual(try stored()?.frame, primary.visibleFrame)
        window.setFrame(normal, display: false)
        XCTAssertEqual(try stored()?.frame, normal)
    }

    @MainActor
    func testDetachSavesAndStopsObserving() throws {
        let window = makeWindow(frame: initial)
        defer { window.close() }
        let screens = [primary, external]
        let controller = WindowPlacementController(defaults: defaults, readScreens: { screens })
        controller.attach(to: window)
        XCTAssertNil(try stored())

        controller.detach()
        let detachedFrame = window.frame
        XCTAssertEqual(try stored()?.frame, detachedFrame)

        window.setFrame(CGRect(x: 300, y: 300, width: 450, height: 350), display: false)
        XCTAssertEqual(try stored()?.frame, detachedFrame)
    }
}

extension WindowPlacementControllerTests {
    @MainActor
    func testSecondMainWindowKeepsItsCascadedFrame() throws {
        try store(try XCTUnwrap(WindowPlacement.capture(frame: saved, screens: [primary, external])))
        let first = makeWindow(frame: initial)
        let second = makeWindow(frame: CGRect(x: 120, y: 80, width: 400, height: 300))
        defer {
            first.close()
            second.close()
        }
        let screens = [primary, external]
        let firstController = WindowPlacementController(defaults: defaults, readScreens: { screens })
        let secondController = WindowPlacementController(defaults: defaults, readScreens: { screens })

        firstController.attach(to: first)
        XCTAssertEqual(first.frame, saved)

        let cascaded = second.frame
        secondController.attach(to: second)
        XCTAssertEqual(second.frame, cascaded)

        // Yet the second window still records where it was left.
        let moved = CGRect(x: 50, y: 150, width: 450, height: 350)
        second.setFrame(moved, display: false)
        XCTAssertEqual(try stored()?.frame, moved)

        // Once no other main window is visible, the next one restores again.
        firstController.detach()
        secondController.detach()
        let third = makeWindow(frame: initial)
        defer { third.close() }
        let thirdController = WindowPlacementController(defaults: defaults, readScreens: { screens })
        thirdController.attach(to: third)
        XCTAssertEqual(third.frame, moved)
    }
}
