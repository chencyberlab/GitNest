import SwiftUI
import XCTest

@testable import GitNest

/// Locks in the untrusted-text rendering invariant (R2). Commit subjects, author
/// names, repo descriptions, and stash messages are attacker-controllable. They are
/// rendered through `Text(untrusted:)`, which must stay the *verbatim* initializer —
/// if it ever silently became a markdown-parsing form (`Text("\(string)")`), a
/// crafted value like `[click](javascript:…)` would render as a tappable injected
/// link. `Text` is `Equatable`, so this pins the helper to verbatim semantics.
final class TextSafetyTests: XCTestCase {
    private let crafted = "**bold** _em_ [click](https://evil.example) `code` <b>x</b>"

    /// The helper must equal the explicit verbatim initializer for crafted markdown —
    /// i.e. it does not parse markdown.
    func testUntrustedTextIsVerbatim() {
        XCTAssertEqual(Text(untrusted: crafted), Text(verbatim: crafted))
    }

    /// And it must differ from the markdown-parsed (LocalizedStringKey) form, so a
    /// regression that swaps the init for an interpolated literal is caught.
    func testUntrustedTextDiffersFromMarkdownParsedForm() {
        XCTAssertNotEqual(Text(untrusted: crafted), Text(LocalizedStringKey(crafted)))
    }
}
