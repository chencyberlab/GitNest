import AppKit
import XCTest
@testable import GitNest

final class WindowTransparencyTests: XCTestCase {
    @MainActor
    private final class ShadowTrackingWindow: NSWindow {
        var shadowInvalidations = 0

        override func invalidateShadow() {
            shadowInvalidations += 1
            super.invalidateShadow()
        }
    }

    @MainActor
    private func makeWindow() -> ShadowTrackingWindow {
        // AppKit needs its application singleton before allocating test windows.
        // The windows stay offscreen and never become key or change focus.
        _ = NSApplication.shared
        let window = ShadowTrackingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }

    @MainActor
    func testApplyingTransparencyRefreshesContentAndShadowInBothDirections() throws {
        let window = makeWindow()
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)

        for enabled in [true, false] {
            content.needsLayout = false
            content.needsDisplay = false
            window.shadowInvalidations = 0

            WindowTransparency.apply(enabled, to: window)

            XCTAssertEqual(window.isOpaque, !enabled)
            XCTAssertEqual(window.backgroundColor, enabled ? .clear : NSColor.windowBackgroundColor)
            XCTAssertFalse(window.titlebarAppearsTransparent)
            XCTAssertTrue(content.needsLayout)
            XCTAssertTrue(content.needsDisplay)
            XCTAssertGreaterThan(window.shadowInvalidations, 0)
        }
    }

    @MainActor
    func testBridgeAppliesLatestPreferenceWhenAttachedAndMovedBetweenWindows() async throws {
        let first = makeWindow()
        let second = makeWindow()
        defer {
            first.close()
            second.close()
        }
        let view = WindowTransparencyBridge.WindowView(frame: .zero)
        view.enabled = true
        // Attachment can occur later than the first queued update at launch.
        await Task.yield()
        XCTAssertNil(view.window)
        try XCTUnwrap(first.contentView).addSubview(view)
        XCTAssertFalse(first.isOpaque)

        view.enabled = false
        XCTAssertTrue(first.isOpaque)
        view.removeFromSuperview()
        view.enabled = true
        view.enabled = false
        view.enabled = true
        try XCTUnwrap(second.contentView).addSubview(view)

        XCTAssertFalse(second.isOpaque)
        XCTAssertEqual(second.backgroundColor, .clear)
        XCTAssertTrue(first.isOpaque)
    }

    func testEnabledChromeIsClearAndNonOpaque() {
        let chrome = WindowTransparency.Chrome.forEnabled(true)
        XCTAssertFalse(chrome.isOpaque)
        XCTAssertTrue(chrome.usesClearBackground)
        // Transparent title bars collapse sidebar content under the traffic lights.
        XCTAssertFalse(chrome.titlebarAppearsTransparent)
    }

    func testDisabledChromeRestoresSolidWindow() {
        let chrome = WindowTransparency.Chrome.forEnabled(false)
        XCTAssertTrue(chrome.isOpaque)
        XCTAssertFalse(chrome.usesClearBackground)
        XCTAssertFalse(chrome.titlebarAppearsTransparent)
    }

    func testDefaultsKeysAreStable() {
        XCTAssertEqual(WindowTransparencyPreference.defaultsKey, "windowTransparencyEnabled")
        XCTAssertEqual(WindowTransparencyPreference.enabledKey, "windowTransparencyEnabled")
        XCTAssertEqual(WindowTransparencyPreference.percentKey, "windowTransparencyPercent")
        XCTAssertEqual(WindowTransparencyPreference.defaultPercent, 40)
    }

    func testClampedPercentBounds() {
        XCTAssertEqual(WindowTransparencyPreference.clampedPercent(-10), 0)
        XCTAssertEqual(WindowTransparencyPreference.clampedPercent(40), 40)
        XCTAssertEqual(WindowTransparencyPreference.clampedPercent(140), 100)
    }

    func testPaneOpacityIsUniformAndMapsPercentFromSolidToFloor() {
        let solid = WindowTransparencyPreference.paneOpacity(percent: 0)
        let mid = WindowTransparencyPreference.paneOpacity(percent: 40)
        let maxGlass = WindowTransparencyPreference.paneOpacity(percent: 100)

        XCTAssertEqual(solid, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(solid, mid)
        XCTAssertGreaterThan(mid, maxGlass)
        XCTAssertEqual(maxGlass, WindowTransparencyPreference.minimumPaneOpacity, accuracy: 0.0001)
        // Floor stays high enough that chrome regions don't diverge into "holes".
        XCTAssertGreaterThanOrEqual(maxGlass, 0.3)
    }

    func testFrostIntensityFadesButStaysAsAVeil() {
        let solid = WindowTransparencyPreference.frostIntensity(percent: 0)
        let mid = WindowTransparencyPreference.frostIntensity(percent: 40)
        let maxGlass = WindowTransparencyPreference.frostIntensity(percent: 100)

        XCTAssertEqual(solid, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(solid, mid)
        XCTAssertGreaterThan(mid, maxGlass)
        XCTAssertGreaterThanOrEqual(maxGlass, 0.45)
    }
}
