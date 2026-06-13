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
    /// `haystacks` are expected to already be lowercased by the caller.
    static func matches(query: String, haystacks: [String]) -> Bool {
        let tokens = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { token in
            haystacks.contains { tokenMatches(token, in: $0) }
        }
    }

    static func tokenMatches(_ token: String, in hay: String) -> Bool {
        if token.contains("*") || token.contains("?") {
            return glob(Array(token), Array(hay))
        }
        if hay.contains(token) { return true }
        return isSubsequence(token, of: hay)
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
