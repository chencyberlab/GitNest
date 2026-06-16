import XCTest
@testable import GitNest

final class DeviceCodeTests: XCTestCase {
    // MARK: gh output

    func testExtractsCodeFromGhLoginOutput() {
        let output = "! First copy your one-time code: 57C6-CEA6\n- Press Enter to open github.com in your browser..."
        XCTAssertEqual(DeviceCode.extract(fromGhOutput: output), "57C6-CEA6")
    }

    func testGhOutputCodeIsUppercased() {
        XCTAssertEqual(DeviceCode.extract(fromGhOutput: "code: 57c6-cea6"), "57C6-CEA6")
    }

    func testGhOutputIgnoresUUIDFragments() {
        // Every XXXX-XXXX inside a UUID is adjacent to a hyphen or another
        // alphanumeric, so none of them is a valid code.
        XCTAssertNil(DeviceCode.extract(fromGhOutput: "id 550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertNil(DeviceCode.extract(fromGhOutput: "serial AB12-CD34-EF56"))
        XCTAssertNil(DeviceCode.extract(fromGhOutput: "run x550e8400-e29b done"))
    }

    func testGhOutputWithoutCodeReturnsNil() {
        XCTAssertNil(DeviceCode.extract(fromGhOutput: ""))
        XCTAssertNil(DeviceCode.extract(fromGhOutput: "gh auth login failed: network error"))
    }

    // MARK: clipboard

    func testClipboardAcceptsExactCodeOnly() {
        XCTAssertEqual(DeviceCode.extract(fromClipboard: "57C6-CEA6"), "57C6-CEA6")
        XCTAssertEqual(DeviceCode.extract(fromClipboard: "  57c6-cea6\n"), "57C6-CEA6")
    }

    func testClipboardRejectsCodeEmbeddedInOtherText() {
        XCTAssertNil(DeviceCode.extract(fromClipboard: "your code: 57C6-CEA6"))
        XCTAssertNil(DeviceCode.extract(fromClipboard: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertNil(DeviceCode.extract(fromClipboard: "550E8400-E29B-41D4-A716-446655440000"))
        XCTAssertNil(DeviceCode.extract(fromClipboard: "password-1234"))
    }

    // MARK: - Clipboard watcher

    func testWatchClipboardReturnsCodeWhenClipboardChangesToCode() async {
        let startingChangeCount = NSPasteboard.general.changeCount
        let task = Task {
            await DeviceCodeWatcher.watchClipboard(
                startingChangeCount: startingChangeCount,
                maxIterations: 200,
                intervalNanoseconds: 1_000_000
            )
        }

        // Simulate `gh auth login --web` copying the code to the clipboard
        // after the watcher has already started polling.
        try? await Task.sleep(nanoseconds: 10_000_000)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("57C6-CEA6", forType: .string)

        let code = await task.value
        XCTAssertEqual(code, "57C6-CEA6")
    }

    func testWatchClipboardReturnsNilWhenClipboardChangesToNonCodeContent() async {
        let startingChangeCount = NSPasteboard.general.changeCount
        let task = Task {
            await DeviceCodeWatcher.watchClipboard(
                startingChangeCount: startingChangeCount,
                maxIterations: 200,
                intervalNanoseconds: 1_000_000
            )
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("not a valid code", forType: .string)

        let code = await task.value
        XCTAssertNil(code)
    }

    func testWatchClipboardRespectsCancellation() async {
        let task = Task {
            await DeviceCodeWatcher.watchClipboard(
                startingChangeCount: NSPasteboard.general.changeCount,
                maxIterations: 1000,
                intervalNanoseconds: 1_000_000
            )
        }
        task.cancel()

        let code = await task.value
        XCTAssertNil(code)
    }
}
