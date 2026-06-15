import SwiftUI

/// Read-only popover listing the commits the current branch is behind its
/// upstream by — i.e. what a pull would bring in. Loads on demand when shown,
/// mirroring `CommitHistoryContent`. Reflects the most recent fetch (the Fetch
/// action or a repo-list refresh — the 10s status sweep is local-only and does not
/// fetch), so it pairs with Fetch rather than running the network itself, and the
/// copy says "as of the last fetch" to be honest about that.
struct IncomingCommitsContent: View {
    let repo: Repo
    let account: Account
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @State private var phase: Phase = .loading

    /// Cap the scroll area; longer lists scroll inside it.
    private static let maxListHeight: CGFloat = 340
    // Approximate row metrics used to size the scroll area from the data, so the
    // popover never collapses (a ScrollView has no natural height of its own).
    private static let rowHeight: CGFloat = 38
    private static let rowSpacing: CGFloat = 10

    enum Phase {
        case loading
        case upToDate
        case unavailable(String)   // no upstream / detached / gone — nothing to compare
        case failed(String)
        case loaded([GitCommit])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Incoming commits for \(repo.name)")
                    .font(Theme.title(14))
                    .foregroundStyle(theme.text)
                // Frames every state below: this is the remote→local direction, so
                // it's never about the user's own local edits (a common mix-up).
                Text("New commits on GitHub not yet in your branch, as of the last fetch.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(16)
        .frame(width: 360)
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for incoming commits…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .upToDate:
            VStack(alignment: .leading, spacing: 4) {
                Label("No new commits on GitHub to pull.", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.success)
                // The exact mix-up this popover invites: local work goes the other
                // way (commit → push), so it never appears in this list.
                Text("Your own uncommitted or unpushed changes aren't shown here.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Nothing to compare", systemImage: "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't read incoming commits", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.error)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .loaded(let commits):
            loadedList(commits)
        }
    }

    private func loadedList(_ commits: [GitCommit]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(commits) { commitRow($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Concrete height derived from the rows we'll draw, capped so long lists
        // scroll. A ScrollView with only a max height collapses in a popover.
        .frame(height: min(estimatedHeight(commits), Self.maxListHeight))
    }

    private func estimatedHeight(_ commits: [GitCommit]) -> CGFloat {
        let n = CGFloat(commits.count)
        return n * Self.rowHeight + max(0, n - 1) * Self.rowSpacing
    }

    private func commitRow(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(commit.shortHash)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.accent)
                    .textSelection(.enabled)
                Text(commit.subject)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if !commitMeta(commit).isEmpty {
                Text(commitMeta(commit))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func commitMeta(_ commit: GitCommit) -> String {
        [commit.author, commit.relativeDate]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// Plain message when the branch isn't tracking a remote (no upstream, detached
    /// HEAD, …) — there's simply nothing to compare against GitHub. Neutral wording
    /// so it reads correctly whether you're off-branch or just haven't pushed.
    private static let noComparisonMessage =
        "This branch isn't tracking a remote branch on GitHub, so there's nothing to compare."

    /// Whether a git failure means "no upstream to compare against" rather than a real
    /// error — the fatals git emits for no-upstream / detached HEAD / unborn branch.
    private static func isNoComparison(_ gitMessage: String) -> Bool {
        let m = gitMessage.lowercased()
        return m.contains("no upstream")
            || m.contains("does not point to a branch")
            || m.contains("no such branch")
            || m.contains("unknown revision")
            || m.contains("ambiguous argument")
    }

    private func load() async {
        phase = .loading
        // No upstream / detached HEAD / deleted upstream → there's nothing to compare.
        // Use the row's already-computed status to say so plainly, instead of letting
        // git's raw "fatal: no upstream configured…" reach the user (the row's own
        // badge already reports these states the friendly way).
        if let status = model.repoStatuses[repo.id] {
            if status.remoteState == .upstreamGone {
                phase = .unavailable("The upstream branch no longer exists on GitHub (deleted or renamed). Push the branch again to re-establish it.")
                return
            }
            if !status.hasUpstream {
                phase = .unavailable(Self.noComparisonMessage)
                return
            }
        }
        switch await model.incomingCommits(for: repo, in: account) {
        case .success(let commits):
            phase = commits.isEmpty ? .upToDate : .loaded(commits)
        case .failure(let error):
            // Fallback for when status was nil above (popover opened before the first
            // sweep populated it): map git's "can't resolve the upstream" fatals to the
            // same plain message rather than leaking `fatal:` into the popover.
            phase = Self.isNoComparison(error.message) ? .unavailable(Self.noComparisonMessage) : .failed(error.message)
        }
    }
}
