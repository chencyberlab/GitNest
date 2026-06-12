import XCTest
@testable import GitNest

final class TerminalLauncherTests: XCTestCase {
    func testResolveAppNameForBuiltInTerminals() throws {
        XCTAssertEqual(try TerminalLauncher.resolveAppName(.terminal, customAppName: ""), "Terminal")
        XCTAssertEqual(try TerminalLauncher.resolveAppName(.iTerm2, customAppName: ""), "iTerm")
        XCTAssertEqual(try TerminalLauncher.resolveAppName(.ghostty, customAppName: ""), "Ghostty")
    }

    func testResolveAppNameTrimsCustomName() throws {
        XCTAssertEqual(try TerminalLauncher.resolveAppName(.custom, customAppName: "  WezTerm  "), "WezTerm")
    }

    func testResolveAppNameThrowsForBlankCustomName() {
        XCTAssertThrowsError(try TerminalLauncher.resolveAppName(.custom, customAppName: "   ")) { error in
            XCTAssertEqual(error as? TerminalOpenError, .missingCustomAppName)
        }
    }

    func testResolveAppNameThrowsWhenNotConfigured() {
        XCTAssertThrowsError(try TerminalLauncher.resolveAppName(.none, customAppName: "")) { error in
            XCTAssertEqual(error as? TerminalOpenError, .notConfigured)
        }
    }

    func testMessagesAreFriendly() {
        XCTAssertTrue(TerminalLauncher.message(for: .notConfigured).contains("Settings"))
        XCTAssertTrue(TerminalLauncher.message(for: .missingCustomAppName).contains("custom"))
        XCTAssertTrue(TerminalLauncher.message(for: .openFailed(appName: "Foo", detail: "")).contains("Foo"))
        XCTAssertTrue(TerminalLauncher.message(for: .openFailed(appName: "Foo", detail: "not found")).contains("not found"))
    }

    func testDisplayNameFallsBackForCustom() {
        XCTAssertEqual(PreferredTerminal.custom.displayName(customAppName: "Warp"), "Warp")
        XCTAssertEqual(PreferredTerminal.custom.displayName(customAppName: "   "), "your terminal")
        XCTAssertEqual(PreferredTerminal.ghostty.displayName(customAppName: ""), "Ghostty")
    }
}
