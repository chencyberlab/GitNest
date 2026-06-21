import SwiftUI

/// Interactive popover for a cloned repo's stashes: create one from the current
/// changes, and apply / pop / drop existing entries. Opened from the row's
/// archivebox button (`ActionPopoverButton`); the trigger lives in the row, this is
/// just the content. Mutating actions go through the coordinator's busy guard, and
/// the list reloads after each so a shifted `stash@{N}` index is never reused. Drop —
/// the one destructive, non-recoverable action — is confirmed inline before it runs.
struct StashContent: View {
    let repo: Repo
    let account: Account
    @EnvironmentObject private var repoActionCoordinator: RepoActionCoordinator
    @EnvironmentObject private var repoManager: RepoManager
    @Environment(\.theme) private var theme

    @State private var phase: Phase = .loading
    /// True while a stash action is in flight; disables the popover's buttons.
    @State private var isWorking = false
    /// The stash index armed for deletion via the inline confirm, if any.
    @State private var armedDrop: Int?
    /// Optional note for the next stash; becomes its description in `git stash list`.
    /// Cleared once a stash is actually created.
    @State private var noteDraft = ""
    /// Live working-tree dirty state, loaded with the list so the "Stash current
    /// changes" affordance reflects the tree now, not the ≤10s-old sweep status.
    @State private var treeDirty: Bool?

    private static let maxListHeight: CGFloat = 300
    private static let rowHeight: CGFloat = 54
    private static let rowSpacing: CGFloat = 8

    enum Phase {
        case loading
        case empty
        case failed(String)
        case loaded([GitStashEntry])
    }

    /// Whether the working tree has changes worth stashing. Prefers the live check in
    /// `treeDirty` (accurate now); falls back to the cached sweep status only until
    /// that first load lands, so a just-made edit can't wrongly disable the button.
    private var hasChanges: Bool {
        treeDirty ?? ((repoManager.repoStatuses[repo.id]?.changedFiles ?? 0) > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Stashes for \(repo.name)")
                        .font(Theme.title(14))
                        .foregroundStyle(theme.text)
                    if isWorking { ProgressView().controlSize(.small) }
                }
                Text("Parks all uncommitted changes — including new files — on your machine. Never on GitHub.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            stashComposer
            ThemeDivider()
            content
        }
        .padding(16)
        .frame(width: 360)
        .task { await load() }
        .disabled(isWorking)
    }

    /// The "create a stash" controls: an optional note field (shown only when there
    /// is something to stash) above the stash button. The note becomes the entry's
    /// description in the list; blank falls back to git's auto "WIP on…" text.
    @ViewBuilder
    private var stashComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if hasChanges {
                TextField("Optional note (e.g. half-done login refactor)", text: $noteDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(stashCurrent)
            }
            stashCurrentButton
        }
    }

    private var stashCurrentButton: some View {
        Button(action: stashCurrent) {
            Label(hasChanges ? "Stash current changes" : "No changes to stash",
                  systemImage: "archivebox")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hasChanges ? theme.accent : theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7).padding(.horizontal, 9)
                .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                    .fill(theme.accentSubtle.opacity(hasChanges ? 1 : 0.4)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasChanges || isWorking)
    }

    /// Stash the working tree with the current note, then clear the note. Guards on
    /// `hasChanges` so a stray submit on a clean tree is a no-op.
    private func stashCurrent() {
        guard hasChanges, !isWorking else { return }
        armedDrop = nil
        let note = noteDraft
        Task {
            let stashed = await perform { await repoActionCoordinator.stashPush(repo, message: note, in: account) }
            if stashed { noteDraft = "" }   // keep the typed note if the stash was a no-op/failure
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading stashes…")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .empty:
            Label("No stashes parked here.", systemImage: "archivebox")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Label("Couldn't read stashes", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.error)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .loaded(let entries):
            loadedList(entries)
        }
    }

    private func loadedList(_ entries: [GitStashEntry]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.rowSpacing) {
                ForEach(entries) { stashRow($0) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Concrete height derived from the rows, capped so long stacks scroll. A
        // ScrollView with only a max height collapses in a popover.
        .frame(height: min(estimatedHeight(entries), Self.maxListHeight))
    }

    private func estimatedHeight(_ entries: [GitStashEntry]) -> CGFloat {
        let n = CGFloat(entries.count)
        return n * Self.rowHeight + max(0, n - 1) * Self.rowSpacing
    }

    private func stashRow(_ entry: GitStashEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(untrusted: entry.subject)
                .font(.system(size: 12))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if armedDrop == entry.index {
                dropConfirm(entry)
            } else {
                HStack(spacing: 6) {
                    Text(entry.selector)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    actionChip("Apply", theme.accent) {
                        Task { await perform { await repoActionCoordinator.stashApply(repo, at: entry.index, expectedHash: entry.hash, in: account) } }
                    }
                    actionChip("Pop", theme.accent) {
                        Task { await perform { await repoActionCoordinator.stashPop(repo, at: entry.index, expectedHash: entry.hash, in: account) } }
                    }
                    actionChip("Drop", theme.error) { armedDrop = entry.index }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func dropConfirm(_ entry: GitStashEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(theme.error)
            Text("Delete permanently? Can't be undone.")
                .font(.system(size: 10))
                .foregroundStyle(theme.error)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            actionChip("Cancel", theme.textMuted) { armedDrop = nil }
            actionChip("Delete", theme.error, filled: true) {
                Task { await perform { await repoActionCoordinator.stashDrop(repo, at: entry.index, expectedHash: entry.hash, in: account) } }
            }
        }
    }

    private func actionChip(_ title: String, _ color: Color, filled: Bool = false,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                // `filled` = a stronger same-hue tint for the destructive confirm, so
                // the text stays theme-safe (no hardcoded white on a light error).
                .padding(.vertical, 3).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMicro, style: .continuous)
                    .fill(color.opacity(filled ? 0.24 : 0.12)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Run a stash mutation, then quietly reload the list (no loading flicker) so a
    /// just-shifted `stash@{N}` index is never reused. Disables buttons meanwhile.
    @discardableResult
    private func perform<T>(_ work: @escaping () async -> T) async -> T {
        isWorking = true
        let result = await work()
        await reload()
        isWorking = false
        return result
    }

    private func load() async {
        phase = .loading
        await reload()
    }

    private func reload() async {
        // Clearing armedDrop on every reload means a list change (after any op) can
        // never leave a stale row showing the delete confirm — nor arm a row that
        // renumbered into the previously-armed index.
        armedDrop = nil
        treeDirty = await repoActionCoordinator.hasLocalChanges(for: repo, in: account)
        switch await repoActionCoordinator.stashList(for: repo, in: account) {
        case .success(let entries):
            phase = entries.isEmpty ? .empty : .loaded(entries)
        case .failure(let error):
            phase = .failed(error.displayMessage)
        }
    }
}
