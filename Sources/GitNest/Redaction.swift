import Foundation

/// Defense-in-depth scrubbing for anything bound for the Output log.
///
/// GitNest never holds a token itself, but it surfaces `gh`/`git` output verbatim —
/// so if a future tool change (or a stray `--show-token`) ever prints a credential,
/// this is the single choke point (`LogStore.append`) that keeps it out of the
/// visible, in-memory log. It also folds the home directory to `~`, so a log a user
/// pastes into a bug report doesn't disclose their account name or filesystem layout.
enum Redaction {
    static let mask = "‹redacted›"

    private struct Rule { let regex: NSRegularExpression; let template: String }

    /// Order matters: token rules run before the URL-userinfo rule so a token used as
    /// the userinfo (`https://ghp_…@github.com`) is masked by its own prefix-keeping
    /// rule rather than the generic one.
    private static let rules: [Rule] = {
        let specs: [(pattern: String, template: String)] = [
            // GitHub token formats: ghp_/gho_/ghu_/ghs_/ghr_ classic + OAuth + server
            // tokens, and the fine-grained github_pat_ form. Keep the prefix so a
            // redacted line still says *what* leaked, never the secret body.
            (#"(gh[pousr]_)[A-Za-z0-9]{16,}"#, "$1\(mask)"),
            (#"(github_pat_)[A-Za-z0-9_]{16,}"#, "$1\(mask)"),
            // Credentials embedded in a URL's userinfo, e.g. an HTTPS remote that
            // carries a token: https://user:TOKEN@github.com → keep the user, drop it.
            (#"(https?://)([^/\s:@]+):[^/\s@]+@"#, "$1$2:\(mask)@"),
            // A credential sitting in the userinfo with no password half:
            // https://TOKEN@github.com. Runs after the prefix rules, so a recognized
            // gh*/github_pat token is already masked to e.g. `ghp_‹redacted›`; this
            // rule then re-masks that whole userinfo segment to `‹redacted›`. The
            // identifying prefix is therefore NOT preserved in the userinfo position
            // (unlike a token in body text) — the secret body is gone either way,
            // which is the only property that matters here. Deliberately narrow: it
            // fires on a single userinfo segment only, never on a bare 40-char hex
            // commit SHA in body text (which masking hex would clobber).
            // Pinned by RedactionTests.testTokenInURLUserInfoIsFullyMaskedEvenIfPrefixNotKept.
            (#"(https?://)[^/\s:@]+@"#, "$1\(mask)@"),
        ]
        return specs.compactMap { spec in
            (try? NSRegularExpression(pattern: spec.pattern, options: [.caseInsensitive]))
                .map { Rule(regex: $0, template: spec.template) }
        }
    }()

    static func scrub(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(location: 0, length: (result as NSString).length)
            result = rule.regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: rule.template)
        }
        // Fold the home directory to `~` last, after any token has been masked. Only
        // fold `<home>/…` (a real path boundary) so a sibling whose name merely starts
        // with the home dir's — e.g. `/Users/alice2` when home is `/Users/alice` — is
        // never corrupted into `~2`.
        let home = NSHomeDirectory()
        if home.count > 1 {   // never collapse a "/" home into nothing
            result = result.replacingOccurrences(of: home + "/", with: "~/")
        }
        return result
    }
}

extension CommandError {
    var displayMessage: String {
        Redaction.scrub(message)
    }
}
