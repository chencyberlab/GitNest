import XCTest
@testable import GitNest

final class EditorLauncherTests: XCTestCase {
    func testResolveAppNameForBuiltInEditors() throws {
        XCTAssertEqual(try EditorLauncher.resolveAppName(.visualStudioCode, customAppName: ""), "Visual Studio Code")
        XCTAssertEqual(try EditorLauncher.resolveAppName(.cursor, customAppName: ""), "Cursor")
        XCTAssertEqual(try EditorLauncher.resolveAppName(.windsurf, customAppName: ""), "Windsurf")
        XCTAssertEqual(try EditorLauncher.resolveAppName(.zed, customAppName: ""), "Zed")
        XCTAssertEqual(try EditorLauncher.resolveAppName(.xcode, customAppName: ""), "Xcode")
    }

    func testResolveAppNameTrimsCustomName() throws {
        XCTAssertEqual(try EditorLauncher.resolveAppName(.custom, customAppName: "  Sublime Text  "), "Sublime Text")
    }

    func testResolveAppNameThrowsForBlankCustomName() {
        XCTAssertThrowsError(try EditorLauncher.resolveAppName(.custom, customAppName: "   ")) { error in
            XCTAssertEqual(error as? EditorOpenError, .missingCustomAppName)
        }
    }

    func testResolveAppNameThrowsWhenNotConfigured() {
        XCTAssertThrowsError(try EditorLauncher.resolveAppName(.none, customAppName: "")) { error in
            XCTAssertEqual(error as? EditorOpenError, .notConfigured)
        }
    }

    func testMessagesAreFriendly() {
        XCTAssertTrue(EditorLauncher.message(for: .notConfigured).contains("Settings"))
        XCTAssertTrue(EditorLauncher.message(for: .missingCustomAppName).contains("custom"))
        XCTAssertTrue(EditorLauncher.message(for: .openFailed(appName: "Foo", detail: "")).contains("Foo"))
        XCTAssertTrue(EditorLauncher.message(for: .openFailed(appName: "Foo", detail: "not found")).contains("not found"))
    }

    func testDisplayNameFallsBackForCustom() {
        XCTAssertEqual(PreferredEditor.custom.displayName(customAppName: "Nova"), "Nova")
        XCTAssertEqual(PreferredEditor.custom.displayName(customAppName: "   "), "your editor")
        XCTAssertEqual(PreferredEditor.zed.displayName(customAppName: ""), "Zed")
    }
}
