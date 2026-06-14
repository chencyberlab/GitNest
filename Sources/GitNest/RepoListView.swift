import SwiftUI

/// Target of a per-repo action that needs confirmation (commit/push/delete).
struct RepoActionTarget: Identifiable {
    let repo: Repo
    let account: Account

    var id: String { "\(account.alias)|\(repo.id)" }
}

/// Repo list for the selected account: search, sort, rows, and action sheets.
struct RepoListView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    let account: Account

    @Binding var commitTarget: RepoActionTarget?
    @Binding var commitMessage: String
    @Binding var pushTarget: RepoActionTarget?
    @Binding var deleteTarget: RepoActionTarget?

    let preferredEditor: PreferredEditor
    let preferredTerminal: PreferredTerminal
    let customEditorName: String
    let customTerminalName: String

    var body: some View {
        VStack(spacing: 0) {
            repoListHeader
            Divider().overlay(theme.border)
            ScrollView {
                if model.filteredRepos.isEmpty {
                    repoListEmptyState
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(model.filteredRepos) { repo in
                            RepoRowView(
                                repo: repo,
                                account: account,
                                commitTarget: $commitTarget,
                                pushTarget: $pushTarget,
                                deleteTarget: $deleteTarget,
                                preferredEditor: preferredEditor,
                                preferredTerminal: preferredTerminal,
                                customEditorName: customEditorName,
                                customTerminalName: customTerminalName
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minHeight: 240)
        .background(theme.surface)
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
            .strokeBorder(theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous))
        .sheet(item: $commitTarget) { target in
            CommitSheet(
                target: target,
                commitMessage: $commitMessage,
                commitTarget: $commitTarget
            )
        }
        .confirmationDialog(
            "Push this repository to GitHub?",
            isPresented: Binding(get: { pushTarget != nil },
                                 set: { if !$0 { pushTarget = nil } }),
            presenting: pushTarget
        ) { target in
            Button("Push to GitHub") {
                let target = target
                pushTarget = nil
                Task { await model.repoActionCoordinator.push(target.repo, in: target.account) }
            }
            Button("Cancel", role: .cancel) {
                pushTarget = nil
            }
        } message: { target in
            Text("This will run git push for “\(target.repo.name)” in \(target.account.alias)'s folder. Make sure the local commits and branch are ready to publish.")
        }
        .confirmationDialog(
            "Move this folder to Trash?",
            isPresented: Binding(get: { deleteTarget != nil },
                                 set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { target in
            Button("Move to Trash", role: .destructive) {
                let target = target; deleteTarget = nil
                Task { await model.repoActionCoordinator.deleteLocalFolder(target.repo, in: target.account) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: { target in
            Text("“\(target.repo.name)” in \(target.account.alias)'s folder will be moved to the Trash (recoverable). The GitHub repository is NOT affected.")
        }
    }

    // MARK: Header

    private var repoListHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 18, height: 18)
            sortHeader("Repository", field: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: LayoutMetrics.visWidth, height: 1)   // visibility column (icon-only, no title)
            sortHeader("Updated", field: .updated)
                .frame(width: LayoutMetrics.updatedWidth, alignment: .leading)
            Text("Actions").frame(width: LayoutMetrics.actionsWidth, alignment: .trailing)
        }
        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(theme.textMuted)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(height: 28)
    }

    /// A clickable column title: click toggles ASC/DESC, click another column to
    /// switch. An arrow shows the active column and direction.
    private func sortHeader(_ title: String, field: RepoSortField) -> some View {
        let active = model.repoSortField == field
        return Button {
            model.sortBy(field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: active ? (model.repoSortAscending ? "chevron.up" : "chevron.down")
                                         : "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(active ? theme.accent : theme.textMuted.opacity(0.45))
            }
            .foregroundStyle(active ? theme.text : theme.textMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var repoListEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: model.repos.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(theme.textTertiary)
            Text(model.repos.isEmpty
                 ? "No repositories loaded yet."
                 : "No repositories match “\(model.repoSearch)”.")
                .font(.system(size: 12))
                .foregroundStyle(theme.textMuted)
            if !model.repos.isEmpty {
                Button("Clear search") { model.repoSearch = "" }
                    .buttonStyle(SubtleButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }

    // MARK: Commit sheet
}

/// Sheet that collects a commit message and runs `git commit -a -m …`.
struct CommitSheet: View {
    let target: RepoActionTarget
    @Binding var commitMessage: String
    @Binding var commitTarget: RepoActionTarget?
    @EnvironmentObject var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Commit all changes in \(target.repo.name)").font(Theme.title(16))
            Text(target.account.folder)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Runs:  git add -A  &&  git commit -m …")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(theme.textMuted)
            TextField("Commit message", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
            HStack {
                Spacer()
                Button("Cancel") { commitTarget = nil }
                    .buttonStyle(SubtleButtonStyle())
                Button("Commit") {
                    let message = commitMessage
                    let target = target
                    commitTarget = nil
                    Task { await model.repoActionCoordinator.commit(target.repo, message: message, in: target.account) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .background(theme.surface)
    }
}
