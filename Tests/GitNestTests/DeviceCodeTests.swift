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
    //
    // These drive an in-memory clipboard through the injectable change-count /
    // read closures, so they never read or overwrite the real system pasteboard.
    // That global is shared state: the earlier versions clobbered whatever the
    // user had copied and could flake when another process touched the clipboard.
    // Progress is driven by poll count, not wall-clock, so they're deterministic.

    func testWatchClipboardReturnsCodeWhenClipboardChangesToCode() async {
        var changeCount = 0
        var contents: String?
        var polls = 0
        let code = await DeviceCodeWatcher.watchClipboard(
            startingChangeCount: 0,
            maxIterations: 10,
            intervalNanoseconds: 1_000,
            currentChangeCount: {
                // Simulate `gh auth login --web` copying the code to the clipboard
                // a couple of polls after the watcher has already started.
                polls += 1
                if polls == 2 { contents = "57C6-CEA6"; changeCount += 1 }
                return changeCount
            },
            readClipboard: { contents }
        )
        XCTAssertEqual(code, "57C6-CEA6")
    }

    func testWatchClipboardReturnsNilWhenClipboardChangesToNonCodeContent() async {
        var changeCount = 0
        var contents: String?
        var polls = 0
        let code = await DeviceCodeWatcher.watchClipboard(
            startingChangeCount: 0,
            maxIterations: 5,
            intervalNanoseconds: 1_000,
            currentChangeCount: {
                polls += 1
                if polls == 2 { contents = "not a valid code"; changeCount += 1 }
                return changeCount
            },
            readClipboard: { contents }
        )
        XCTAssertNil(code)
    }

    func testWatchClipboardRespectsCancellation() async {
        let task = Task {
            await DeviceCodeWatcher.watchClipboard(
                startingChangeCount: 0,
                maxIterations: 1000,
                intervalNanoseconds: 1_000_000,
                currentChangeCount: { 0 },
                readClipboard: { nil }
            )
        }
        task.cancel()

        let code = await task.value
        XCTAssertNil(code)
    }

    func testWatchClipboardWithNonPositiveIterationsReturnsNilWithoutTrapping() async {
        // `0..<maxIterations` would trap for a negative bound; the clamp turns it
        // into a no-op poll that returns nil instead of crashing.
        let code = await DeviceCodeWatcher.watchClipboard(
            startingChangeCount: 0,
            maxIterations: -1,
            currentChangeCount: { 1 },          // a code is "present"…
            readClipboard: { "57C6-CEA6" }      // …but the loop never runs to see it
        )
        XCTAssertNil(code)
    }
}
