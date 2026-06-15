import SwiftUI

/// Read-only popover listing the commits the current branch is behind its
/// upstream by — i.e. what a pull would bring in. Loads on demand when shown,
/// mirroring `CommitHistoryContent`. Reflects the most recent fetch (the status
/// sweep fetches each cycle, and the row's Fetch action fetches on demand), so it
/// pairs with Fetch in the menu rather than running the network itself.
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
                Text("New commits on GitHub, not yet in your local branch.")
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

    private func load() async {
        phase = .loading
        switch await model.incomingCommits(for: repo, in: account) {
        case .success(let commits):
            phase = commits.isEmpty ? .upToDate : .loaded(commits)
        case .failure(let error):
            phase = .failed(error.message)
        }
    }
}
