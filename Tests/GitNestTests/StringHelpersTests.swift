import XCTest

@testable import GitNest

/// Pins `sanitizedForSingleLineDisplay` (review round 3, SEC-1/SEC-2): it must strip
/// the bytes that corrupt the field-separated git parse or visually spoof a one-line
/// label, while leaving legitimate text — including ZWJ emoji — untouched.
final class StringHelpersTests: XCTestCase {
    func testStripsFieldSeparatorAndOtherControlBytes() {
        XCTAssertEqual("a\u{1f}b".sanitizedForSingleLineDisplay(), "ab")   // unit separator
        XCTAssertEqual("a\u{00}b".sanitizedForSingleLineDisplay(), "ab")   // NUL
        XCTAssertEqual("a\u{1b}b".sanitizedForSingleLineDisplay(), "ab")   // ESC
        XCTAssertEqual("a\u{7f}b".sanitizedForSingleLineDisplay(), "ab")   // DEL
    }

    func testStripsBidirectionalOverridesAndIsolates() {
        // Trojan Source (CVE-2021-42574): overrides and isolates that reorder text.
        XCTAssertEqual("x\u{202e}y".sanitizedForSingleLineDisplay(), "xy")   // RLO
        XCTAssertEqual("x\u{2066}y".sanitizedForSingleLineDisplay(), "xy")   // isolate
    }

    func testLeavesOrdinaryTextUnchanged() {
        let s = "feat: add thing (x), commas & a colon — café"
        XCTAssertEqual(s.sanitizedForSingleLineDisplay(), s)
    }

    func testPreservesZWJEmojiAsSingleGrapheme() {
        // The family emoji is man+ZWJ+woman+ZWJ+girl — stripping the ZWJ would split
        // it into three glyphs, so the sanitizer must keep the joiners.
        let family = "👨‍👩‍👧"
        let sanitized = family.sanitizedForSingleLineDisplay()
        XCTAssertEqual(sanitized, family)
        XCTAssertEqual(sanitized.count, 1, "must remain a single grapheme cluster")
    }
}
