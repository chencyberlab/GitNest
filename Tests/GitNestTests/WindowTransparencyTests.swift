import XCTest
@testable import GitNest

final class WindowTransparencyTests: XCTestCase {
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
