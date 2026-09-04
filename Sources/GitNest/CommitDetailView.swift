import Foundation
import SwiftUI

/// Applies the persisted appearance and tooltip environment to each secondary
/// commit-detail window. Secondary scenes do not inherit the main scene's view
/// environment, so they need the same root setup as working-diff windows.
struct CommitDetailWindowRoot: View {
    let target: CommitDetailTarget?

    @StateObject private var tooltip = TooltipController()
    @AppStorage("appearancePreference") private var appearancePreference = "system"
    @AppStorage("colorThemeID") private var colorThemeID = ColorThemePalette.gitNest.id

    private var theme: Theme {
        Theme(palette: ColorThemePalette.palette(for: colorThemeID) ?? .gitNest)
    }

    private var resolvedScheme: ColorScheme? {
        switch appearancePreference {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        Group {
            if let target {
                CommitDetailView(target: target)
            } else {
                Text("No commit selected.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(theme.background)
        .environment(\.theme, theme)
        .coordinateSpace(name: TooltipController.space)
        .overlay { TooltipOverlay() }
        .environmentObject(tooltip)
        .tint(theme.accent)
        .preferredColorScheme(resolvedScheme)
        .navigationTitle(target.map { "Commit \($0.shortHash) — \($0.repoName)" } ?? "Commit Details")
        .toolbarBackground(
            theme.hasCustomWindowChrome ? theme.windowChromeBackground : .clear,
            for: .windowToolbar)
        .toolbarBackground(
            theme.hasCustomWindowChrome ? .visible : .automatic,
            for: .windowToolbar)
    }
}

/// Lazy, read-only inspection of one local commit. The changed-file inventory is
/// loaded once; only the currently selected file's patch is materialized.
struct CommitDetailView: View {
    let target: CommitDetailTarget

    @EnvironmentObject private var repoActionCoordinator: RepoActionCoordinator
    @Environment(\.theme) private var theme

    @State private var snapshotPhase: SnapshotPhase = .loading
    @State private var diffPhase: DiffPhase = .idle
    @State private var selectedFileKey: String?
    @State private var snapshotSessionID = UUID()
    @State private var diffSessionID = UUID()
    @State private var fileGroups: [GitChangeGroup] = []
    @State private var orderedFiles: [GitFileChange] = []
    @State private var diffContentWidth: CGFloat = Self.minimumContentWidth

    private enum SnapshotPhase {
        case loading
        case loaded(GitCommitSnapshot)
        case failed(String)
    }

    private enum DiffPhase {
        case idle
        case loading
        case loaded(GitFileDiff)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            windowHeader
            ThemeDivider()
            content
        }
        .background(theme.background)
        .task(id: target.id) { await loadSnapshot() }
    }

    private var windowHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Commit \(target.shortHash)")
                    .font(Theme.title(16))
                    .foregroundStyle(theme.text)
                Text(untrusted: "\(target.nameWithOwner) · \(target.accountAlias)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if case .loaded(let snapshot) = snapshotPhase {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(untrusted: snapshot.comparisonDescription)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("Local only · read-only")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Button {
                repoActionCoordinator.copyCommitSHA(target.hash)
            } label: {
                Label("Copy SHA", systemImage: "doc.on.doc")
            }
            .buttonStyle(SubtleButtonStyle())
            .tooltip("Copy the full commit SHA")
            Button {
                Task { await loadSnapshot() }
            } label: {
                if isLoadingSnapshot {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(SubtleButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .tooltip("Reload this commit from the local repository")
            .disabled(isLoadingSnapshot)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(theme.surface)
    }

    private var isLoadingSnapshot: Bool {
        if case .loading = snapshotPhase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch snapshotPhase {
        case .loading:
            stateView(
                systemImage: "clock.arrow.circlepath",
                title: "Reading commit…",
                detail: "Loading commit metadata and its changed-file list.",
                showsProgress: true)
        case .failed(let message):
            failureView(title: "Couldn't read this commit", message: message) {
                Task { await loadSnapshot() }
            }
        case .loaded(let snapshot):
            loadedContent(snapshot)
        }
    }

    private func loadedContent(_ snapshot: GitCommitSnapshot) -> some View {
        VStack(spacing: 0) {
            commitSummary(snapshot.detail)
            ThemeDivider()
            if snapshot.files.isEmpty {
                stateView(
                    systemImage: "doc.badge.ellipsis",
                    title: "No changed files",
                    detail: "This commit does not contain any file changes.")
            } else {
                HSplitView {
                    fileSidebar(snapshot)
                        .frame(minWidth: 220, idealWidth: 270, maxWidth: 360)
                    diffPane(snapshot)
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func commitSummary(_ detail: GitCommitDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(untrusted: detail.subject)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.text)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Label {
                    Text(untrusted: detail.author)
                } icon: {
                    Image(systemName: "person")
                }
                Label {
                    Text(untrusted: detail.authoredAt.sanitizedForSingleLineDisplay())
                } icon: {
                    Image(systemName: "calendar")
                }
                Spacer()
                Text(detail.hash)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .textSelection(.enabled)
            }
            .font(.system(size: 10))
            .foregroundStyle(theme.textMuted)
            if let body = messageBody(detail.message) {
                ScrollView {
                    Text(untrusted: body)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textMuted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 92)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(theme.surface)
    }

    private func messageBody(_ message: String) -> String? {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let body = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private func fileSidebar(_ snapshot: GitCommitSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Changed Files")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.text)
                Spacer()
                Text("\(snapshot.files.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(theme.surface)
            ThemeDivider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(fileGroups) { group in
                        fileGroup(group, snapshot: snapshot)
                    }
                }
                .padding(8)
            }
            .background(theme.background)
        }
    }

    private func fileGroup(_ group: GitChangeGroup, snapshot: GitCommitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(group.title) (\(group.files.count))")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(statusColor(group.status))
                .padding(.horizontal, 6)
            ForEach(group.files) { file in
                fileButton(file, snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileButton(_ file: GitFileChange, snapshot: GitCommitSnapshot) -> some View {
        let selected = selectedFileKey == file.workingDiffKey
        return Button {
            select(file, in: snapshot)
        } label: {
            HStack(spacing: 7) {
                Text(statusGlyph(file.status))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 14)
                Text(untrusted: fileLabel(file))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(selected ? theme.text : theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMicro, style: .continuous)
                    .fill(selected ? theme.accentSubtle : Color.clear))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(theme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tooltip(fileLabel(file))
    }

    private func diffPane(_ snapshot: GitCommitSnapshot) -> some View {
        VStack(spacing: 0) {
            if let selected = selectedFile(in: snapshot) {
                fileHeader(selected, snapshot: snapshot)
                ThemeDivider()
                diffBody(selected, snapshot: snapshot)
            } else {
                stateView(
                    systemImage: "doc.text",
                    title: "Select a file",
                    detail: "Choose a changed file to inspect its line-by-line difference.")
            }
        }
        .background(theme.elevatedSurface)
    }

    private func fileHeader(_ file: GitFileChange, snapshot: GitCommitSnapshot) -> some View {
        let index = orderedFiles.firstIndex { $0.workingDiffKey == file.workingDiffKey }
        return HStack(spacing: 10) {
            Text(statusGlyph(file.status))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(statusColor(file.status))
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(statusColor(file.status).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMicro, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(untrusted: file.path.sanitizedForSingleLineDisplay())
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let originalPath = file.originalPath {
                    Text(untrusted: "Renamed from \(originalPath.sanitizedForSingleLineDisplay())")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if case .loaded(let diff) = diffPhase {
                Text("+\(diff.additions)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.success)
                Text("−\(diff.deletions)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.error)
            }
            Button {
                navigate(from: file, offset: -1, snapshot: snapshot)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(IconChipButtonStyle())
            .disabled(index == nil || index == 0)
            .tooltip("Previous changed file")
            Button {
                navigate(from: file, offset: 1, snapshot: snapshot)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(IconChipButtonStyle())
            .disabled(index == nil || index == orderedFiles.count - 1)
            .tooltip("Next changed file")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(theme.surface)
    }

    @ViewBuilder
    private func diffBody(_ file: GitFileChange, snapshot: GitCommitSnapshot) -> some View {
        switch diffPhase {
        case .idle:
            stateView(
                systemImage: "doc.text",
                title: "Select a file",
                detail: "Choose a changed file to inspect its line-by-line difference.")
        case .loading:
            stateView(
                systemImage: "doc.text.magnifyingglass",
                title: "Reading diff…",
                detail: snapshot.comparisonDescription,
                showsProgress: true)
        case .failed(let message):
            failureView(title: "Couldn't read this diff", message: message) {
                loadSelectedFile(file, snapshot: snapshot)
            }
        case .loaded(let diff):
            diffContent(diff, file: file)
        }
    }

    @ViewBuilder
    private func diffContent(_ diff: GitFileDiff, file: GitFileChange) -> some View {
        switch diff.content {
        case .text(let hunks):
            codeView(hunks)
        case .binary:
            stateView(
                systemImage: "doc.fill",
                title: "Binary file changed",
                detail: "Binary content cannot be displayed as a line-by-line diff.")
        case .noLineChanges:
            stateView(
                systemImage: "doc.badge.ellipsis",
                title: noLineChangesTitle(file),
                detail: "There are no text-line additions or removals to display.")
        case .tooLarge(let limitBytes):
            let limit = ByteCountFormatter.string(fromByteCount: Int64(limitBytes), countStyle: .file)
            stateView(
                systemImage: "doc.text.magnifyingglass",
                title: "Diff too large to display",
                detail: "GitNest limits the in-app viewer to source files and patches up to \(limit).")
        case .unreadableSource(let source):
            stateView(
                systemImage: source == .nestedRepository ? "folder.badge.questionmark" : "doc.questionmark",
                title: source.title,
                detail: source.detail)
        }
    }

    private func codeView(_ hunks: [GitDiffHunk]) -> some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(hunks) { hunk in
                    hunkHeader(hunk.header)
                    ForEach(hunk.lines) { line in
                        diffLine(line)
                    }
                }
            }
            .frame(minWidth: diffContentWidth, alignment: .leading)
            .textSelection(.enabled)
        }
        .background(theme.elevatedSurface)
    }

    private func hunkHeader(_ header: String) -> some View {
        HStack(spacing: 0) {
            Text(untrusted: header.sanitizedForCodeLineDisplay())
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.accent)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 12)
            Spacer(minLength: 12)
        }
        .frame(minWidth: diffContentWidth, minHeight: 26, alignment: .leading)
        .background(theme.accentSubtle)
    }

    private func diffLine(_ line: GitDiffLine) -> some View {
        HStack(spacing: 0) {
            lineNumber(line.oldLineNumber)
            lineNumber(line.newLineNumber)
            Text(lineMarker(line.kind))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(lineMarkerColor(line.kind))
                .frame(width: 22, alignment: .center)
            Text(untrusted: line.text.sanitizedForCodeLineDisplay())
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(line.kind == .metadata ? theme.textMuted : theme.text)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
        }
        .frame(minWidth: diffContentWidth, minHeight: 20, alignment: .leading)
        .background(lineBackground(line.kind))
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(theme.textTertiary)
            .frame(width: 48, alignment: .trailing)
            .frame(minHeight: 20)
            .padding(.trailing, 7)
            .background(theme.surfaceMuted.opacity(0.38))
            .overlay(alignment: .trailing) {
                Rectangle().fill(theme.border.opacity(0.65)).frame(width: 1)
            }
    }

    private func lineBackground(_ kind: GitDiffLineKind) -> Color {
        switch kind {
        case .addition: return theme.successSubtle.opacity(0.78)
        case .deletion: return theme.errorSubtle.opacity(0.78)
        case .metadata: return theme.surfaceMuted.opacity(0.45)
        case .context: return Color.clear
        }
    }

    private func lineMarker(_ kind: GitDiffLineKind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "−"
        case .context, .metadata: return ""
        }
    }

    private func lineMarkerColor(_ kind: GitDiffLineKind) -> Color {
        switch kind {
        case .addition: return theme.success
        case .deletion: return theme.error
        case .context, .metadata: return theme.textTertiary
        }
    }

    private func noLineChangesTitle(_ file: GitFileChange) -> String {
        switch file.status {
        case .added, .untracked: return "New empty file"
        case .renamed: return "File renamed without line changes"
        default: return "Only file metadata changed"
        }
    }

    private func fileLabel(_ file: GitFileChange) -> String {
        guard let originalPath = file.originalPath else {
            return file.path.sanitizedForSingleLineDisplay()
        }
        return "\(originalPath) → \(file.path)".sanitizedForSingleLineDisplay()
    }

    private func selectedFile(in snapshot: GitCommitSnapshot) -> GitFileChange? {
        guard let selectedFileKey else { return nil }
        return snapshot.files.first { $0.workingDiffKey == selectedFileKey }
    }

    private func navigate(from file: GitFileChange, offset: Int, snapshot: GitCommitSnapshot) {
        guard let current = orderedFiles.firstIndex(where: { $0.workingDiffKey == file.workingDiffKey }) else {
            return
        }
        let next = current + offset
        guard orderedFiles.indices.contains(next) else { return }
        select(orderedFiles[next], in: snapshot)
    }

    private func select(_ file: GitFileChange, in snapshot: GitCommitSnapshot) {
        selectedFileKey = file.workingDiffKey
        loadSelectedFile(file, snapshot: snapshot)
    }

    private func loadSelectedFile(_ file: GitFileChange, snapshot: GitCommitSnapshot) {
        let expectedSnapshotSession = snapshotSessionID
        Task {
            await loadDiff(file, snapshot: snapshot, expectedSnapshotSession: expectedSnapshotSession)
        }
    }

    @MainActor
    private func loadSnapshot() async {
        let session = UUID()
        snapshotSessionID = session
        diffSessionID = UUID()
        let preferredFileKey = selectedFileKey
        snapshotPhase = .loading
        diffPhase = .idle
        fileGroups = []
        orderedFiles = []

        let result = await repoActionCoordinator.commitDetails(for: target)
        guard snapshotSessionID == session else { return }
        switch result {
        case .success(let snapshot):
            snapshotPhase = .loaded(snapshot)
            fileGroups = GitChanges.grouped(snapshot.files)
            orderedFiles = fileGroups.flatMap(\.files)
            let selected = preferredFileKey.flatMap { key in
                snapshot.files.first { $0.workingDiffKey == key }
            } ?? orderedFiles.first
            guard let selected else {
                selectedFileKey = nil
                return
            }
            selectedFileKey = selected.workingDiffKey
            await loadDiff(selected, snapshot: snapshot, expectedSnapshotSession: session)
        case .failure(let error):
            snapshotPhase = .failed(error.displayMessage)
        }
    }

    @MainActor
    private func loadDiff(
        _ file: GitFileChange,
        snapshot: GitCommitSnapshot,
        expectedSnapshotSession: UUID
    ) async {
        guard snapshotSessionID == expectedSnapshotSession else { return }
        let session = UUID()
        let expectedFileKey = file.workingDiffKey
        diffSessionID = session
        diffPhase = .loading

        let result = await repoActionCoordinator.commitFileDiff(
            for: target,
            snapshot: snapshot,
            file: file)
        guard snapshotSessionID == expectedSnapshotSession,
            diffSessionID == session,
            selectedFileKey == expectedFileKey
        else { return }
        switch result {
        case .success(let diff):
            diffContentWidth = Self.contentWidth(for: diff)
            diffPhase = .loaded(diff)
        case .failure(let error):
            diffPhase = .failed(error.displayMessage)
        }
    }

    private func statusGlyph(_ status: GitChangeStatus) -> String {
        switch status {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .conflicted: return "!"
        case .other(let code): return code
        }
    }

    private func statusColor(_ status: GitChangeStatus) -> Color {
        switch status {
        case .modified: return theme.warning
        case .added: return theme.success
        case .deleted: return theme.error
        case .renamed: return theme.accent
        case .untracked: return theme.blue
        case .conflicted: return theme.pink
        case .other: return theme.teal
        }
    }

    private func stateView(
        systemImage: String,
        title: String,
        detail: String,
        tint: Color? = nil,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 9) {
            if showsProgress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 24))
                    .foregroundStyle(tint ?? theme.textTertiary)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(untrusted: detail)
                .font(.system(size: 11))
                .foregroundStyle(theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.elevatedSurface)
    }

    private func failureView(
        title: String,
        message: String,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(theme.error)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(untrusted: message.sanitizedForMultilineDisplay())
                .font(.system(size: 11))
                .foregroundStyle(theme.textMuted)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
            Button("Try Again", action: retry)
                .buttonStyle(SubtleButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.elevatedSurface)
    }

    private static let minimumContentWidth: CGFloat = 900
    private static let gutterWidth: CGFloat = 48 * 2 + 7 * 2 + 22
    private static let columnWidth: CGFloat = 7
    private static let maximumContentColumns = 2200

    private static func contentWidth(for diff: GitFileDiff) -> CGFloat {
        let columns = diff.maximumDisplayColumns(limit: maximumContentColumns)
        return max(minimumContentWidth, gutterWidth + CGFloat(columns) * columnWidth + 12)
    }
}
