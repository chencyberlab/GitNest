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

    /// `sanitizedForCodeLineDisplay` backs the working-diff viewer, which renders
    /// verbatim file content (diff lines, hunk headers) — the exact place an
    /// attacker would plant a Trojan Source payload, so it must strip the same
    /// bytes as the label sanitizer, but keep hard tabs since real source code
    /// indents with them.
    func testCodeLineDisplayStripsDangerousBytesLikeTheLabelSanitizer() {
        XCTAssertEqual("a\u{1f}b".sanitizedForCodeLineDisplay(), "ab")
        XCTAssertEqual("a\u{00}b".sanitizedForCodeLineDisplay(), "ab")
        XCTAssertEqual("a\u{1b}b".sanitizedForCodeLineDisplay(), "ab")
        XCTAssertEqual("a\u{7f}b".sanitizedForCodeLineDisplay(), "ab")
        XCTAssertEqual("x\u{202e}y".sanitizedForCodeLineDisplay(), "xy")   // RLO
        XCTAssertEqual("x\u{2066}y".sanitizedForCodeLineDisplay(), "xy")   // isolate
    }

    func testCodeLineDisplayPreservesHardTabsUnlikeTheLabelSanitizer() {
        XCTAssertEqual("\tfunc f() {".sanitizedForCodeLineDisplay(), "\tfunc f() {")
        XCTAssertEqual("\tfunc f() {".sanitizedForSingleLineDisplay(), "func f() {")
    }

    func testCodeLineDisplayLeavesOrdinaryTextUnchanged() {
        let s = "let total = a + b // café"
        XCTAssertEqual(s.sanitizedForCodeLineDisplay(), s)
    }

    /// A minified bundle's diff has single lines hundreds of kilobytes long; the
    /// viewer hands each one to a `Text` that sizes to its ideal width, so the
    /// sanitizer caps display length. Search still sees the untruncated line.
    func testCodeLineDisplayCapsPathologicallyLongLines() {
        let long = String(repeating: "x", count: 5_000)
        let shown = long.sanitizedForCodeLineDisplay()
        XCTAssertEqual(shown.count, 1_001)
        XCTAssertTrue(shown.hasSuffix("…"))
        XCTAssertEqual("abcdef".sanitizedForCodeLineDisplay(maxCharacters: 3), "abc…")
        XCTAssertEqual("abc".sanitizedForCodeLineDisplay(maxCharacters: 3), "abc")
    }

    /// The cap counts graphemes, not scalars, so it can never slice an emoji
    /// sequence into its component scalars.
    func testCodeLineDisplayCapNeverSplitsAGraphemeCluster() {
        let family = "👨‍👩‍👧"
        let capped = (family + family).sanitizedForCodeLineDisplay(maxCharacters: 1)
        XCTAssertEqual(capped, family + "…")
    }
}
