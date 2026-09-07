import Foundation

/// Attention categories for cloned repos, used by the list strip and filter chips.
enum RepoAttentionKind: String, CaseIterable, Identifiable, Sendable {
    case dirty
    case ahead
    case behind
    case diverged

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dirty: return "dirty"
        case .ahead: return "ahead"
        case .behind: return "behind"
        case .diverged: return "diverged"
        }
    }

    var help: String {
        switch self {
        case .dirty: return "Repos with uncommitted or untracked changes"
        case .ahead: return "Repos with local commits not yet pushed (not diverged)"
        case .behind: return "Repos behind their upstream (not diverged)"
        case .diverged: return "Repos with both local and remote commits to reconcile"
        }
    }
}

/// Counts of cloned repos that need attention, split the same way as the strip chips.
struct RepoAttentionSummary: Equatable, Sendable {
    var dirty: Int = 0
    var ahead: Int = 0
    var behind: Int = 0
    var diverged: Int = 0

    var isEmpty: Bool { dirty == 0 && ahead == 0 && behind == 0 && diverged == 0 }

    func count(for kind: RepoAttentionKind) -> Int {
        switch kind {
        case .dirty: return dirty
        case .ahead: return ahead
        case .behind: return behind
        case .diverged: return diverged
        }
    }
}

enum RepoAttention {
    /// Whether `status` belongs in the given attention chip / filter.
    /// Ahead/behind exclude diverged so the strip counts don't double-book those rows.
    static func matches(_ status: RepoStatus, kind: RepoAttentionKind) -> Bool {
        switch kind {
        case .dirty:
            return status.changedFiles > 0
        case .ahead:
            return status.ahead > 0 && !status.isDiverged
        case .behind:
            return status.behind > 0 && !status.isDiverged
        case .diverged:
            return status.isDiverged
        }
    }

    /// Summarise cloned repos that have a known status. Remote-only rows (no status)
    /// never contribute — the strip is about local work pending.
    static func summary(statuses: [Repo.ID: RepoStatus],
                        clonedRepos: Set<Repo.ID>) -> RepoAttentionSummary {
        var summary = RepoAttentionSummary()
        for id in clonedRepos {
            guard let status = statuses[id] else { continue }
            if matches(status, kind: .dirty) { summary.dirty += 1 }
            if matches(status, kind: .ahead) { summary.ahead += 1 }
            if matches(status, kind: .behind) { summary.behind += 1 }
            if matches(status, kind: .diverged) { summary.diverged += 1 }
        }
        return summary
    }
}
