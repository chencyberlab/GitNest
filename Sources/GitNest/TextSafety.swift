import SwiftUI

extension Text {
    /// Render an untrusted string with **no** markdown or localization parsing.
    ///
    /// Use this for any value sourced from the GitHub API or a repo's git history —
    /// commit subjects, author names, repo descriptions, stash messages — so a
    /// crafted value such as `[click](javascript:…)` can never be parsed into an
    /// injected, tappable link.
    ///
    /// `Text(someString)` is already verbatim, so this is currently a no-op rename.
    /// Its value is that it *names* the trust boundary: `Text("\(someString)")`
    /// (interpolation into a string literal) is **not** verbatim — it becomes a
    /// `LocalizedStringKey` and SwiftUI parses its markdown. Funnelling untrusted
    /// fields through this initializer keeps that safe-but-fragile invariant from
    /// silently regressing the next time one of these views is edited.
    init(untrusted string: String) {
        self.init(verbatim: string)
    }
}
