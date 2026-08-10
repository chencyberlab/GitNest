import Foundation

/// Forgiving "wild" matching for the repo search bar.
///
/// Each whitespace-separated token must match somewhere in the repo's name,
/// owner/name, or description. A token matches when it is a plain substring,
/// a fuzzy subsequence (e.g. `mgm` → `multi-git-manager`), or a glob pattern
/// using `*` (any run) and `?` (single char).
enum RepoSearch {
    static func matches(query: String, repo: Repo) -> Bool {
        WildcardMatcher.matches(query: query, haystacks: repo.searchableHaystacks)
    }
}

/// Same forgiving matcher as repo search, applied to account card fields.
enum AccountSearch {
    static func matches(query: String, account: Account) -> Bool {
        WildcardMatcher.matches(query: query, haystacks: account.searchableHaystacks)
    }
}

enum WildcardMatcher {
    /// How hard a token is allowed to stretch to find a hit.
    ///
    /// `.forgiving` adds fuzzy subsequence matching, which is what makes
    /// `mgm` → `multi-git-manager` work for short labels (repo names, file paths).
    /// It is actively harmful on long text: a three-letter token is a subsequence
    /// of nearly every line of code, so a whole-diff search would drown the real
    /// hits in noise and blow the match cap before reaching them. Long-text
    /// corpora use `.literal` (substring + glob only).
    enum Strictness {
        case forgiving
        case literal
    }

    /// A query tokenized once, with any glob token pre-expanded to `[Character]`.
    ///
    /// Matching one corpus entry is cheap; matching *tens of thousands* of them
    /// (every changed line in a working diff) is not, if each candidate re-lowercases
    /// and re-splits the query and re-allocates the glob pattern. Compile once,
    /// match many.
    struct Query {
        fileprivate let tokens: [Token]

        var isEmpty: Bool { tokens.isEmpty }
    }

    fileprivate struct Token {
        let text: String
        /// Non-nil only when the token uses `*`/`?`, so the common substring path
        /// never pays for a character array.
        let glob: [Character]?
    }

    static func compile(_ query: String) -> Query {
        let tokens = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { token -> Token in
                let text = String(token)
                let isGlob = token.contains("*") || token.contains("?")
                return Token(text: text, glob: isGlob ? Array(text) : nil)
            }
        return Query(tokens: tokens)
    }

    /// `haystacks` are expected to already be lowercased by the caller.
    static func matches(query: String, haystacks: [String]) -> Bool {
        matches(compile(query), haystacks: haystacks)
    }

    /// `haystacks` are expected to already be lowercased by the caller.
    static func matches(
        _ query: Query,
        haystacks: [String],
        strictness: Strictness = .forgiving
    ) -> Bool {
        guard !query.isEmpty else { return true }
        return query.tokens.allSatisfy { token in
            haystacks.contains { tokenMatches(token, in: $0, strictness: strictness) }
        }
    }

    fileprivate static func tokenMatches(
        _ token: Token,
        in hay: String,
        strictness: Strictness
    ) -> Bool {
        if let glob = token.glob {
            return WildcardMatcher.glob(glob, Array(hay))
        }
        if hay.contains(token.text) { return true }
        guard strictness == .forgiving else { return false }
        return isSubsequence(token.text, of: hay)
    }

    /// Classic iterative wildcard matcher with backtracking.
    static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1; t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; mark = t; p += 1
            } else if star != -1 {
                p = star + 1; mark += 1; t = mark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// True when every character of `needle` appears in `hay` in order.
    static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var idx = hay.startIndex
        for ch in needle {
            var found = false
            while idx < hay.endIndex {
                let cur = hay[idx]
                idx = hay.index(after: idx)
                if cur == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }
}
