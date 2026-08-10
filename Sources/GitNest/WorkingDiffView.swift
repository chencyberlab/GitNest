import Foundation
import SwiftUI

/// Applies the same persisted appearance as the main scene to each secondary
/// working-diff window. A separate scene does not inherit the main window's view
/// environment, so both the theme and the full manager graph are injected at root.
struct WorkingDiffWindowRoot: View {
    let target: WorkingDiffTarget?

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
                WorkingDiffView(target: target)
            } else {
                Text("No repository selected.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(theme.background)
        .environment(\.theme, theme)
        // A secondary scene gets a fresh environment branch. Every `.tooltip`
        // below requires the same controller/overlay pair installed by ContentView;
        // omitting it traps on the first hover via EnvironmentObject.error().
        .coordinateSpace(name: TooltipController.space)
        .overlay { TooltipOverlay() }
        .environmentObject(tooltip)
        .tint(theme.accent)
        .preferredColorScheme(resolvedScheme)
        .navigationTitle(target.map { "Working Changes — \($0.repoName)" } ?? "Working Changes")
        .toolbarBackground(
            theme.hasCustomWindowChrome ? theme.windowChromeBackground : .clear,
            for: .windowToolbar
        )
        .toolbarBackground(
            theme.hasCustomWindowChrome ? .visible : .automatic,
            for: .windowToolbar)
    }
}

/// Read-only, editor-like viewer for current working-tree changes versus the exact
/// local commit captured on refresh. File patches load one at a time on demand.
struct WorkingDiffView: View {
    let target: WorkingDiffTarget

    @EnvironmentObject private var repoActionCoordinator: RepoActionCoordinator
    @Environment(\.theme) private var theme

    @State private var snapshotPhase: SnapshotPhase = .loading
    @State private var diffPhase: DiffPhase = .idle
    @State private var selectedFileKey: String?
    @State private var snapshotSessionID = UUID()
    @State private var diffSessionID = UUID()
    @State private var searchQuery = ""
    @FocusState private var searchFieldFocused: Bool
    @State private var searchIndex: GitWorkingDiffSearchIndex?
    @State private var searchMatches = GitWorkingDiffSearchMatches.empty
    @State private var isIndexingSearch = false
    @State private var isMatchingSearch = false
    @State private var searchIndexError: String?
    @State private var searchIndexSessionID = UUID()
    @State private var searchMatchSessionID = UUID()
    @State private var pathMatchSessionID = UUID()
    @State private var diffScrollRequest: DiffScrollRequest?
    /// Grouped/ordered once per snapshot. `GitChanges.grouped` allocates a
    /// dictionary and sorts every group, and the sidebar plus the file header both
    /// need it — recomputing inside `body` re-sorted the whole tree on every
    /// keystroke and every hover.
    @State private var fileGroups: [GitChangeGroup] = []
    @State private var orderedFiles: [GitFileChange] = []
    /// Width of the widest line in the loaded patch, measured once (see
    /// `GitFileDiff.maximumDisplayColumns`).
    @State private var diffContentWidth: CGFloat = WorkingDiffView.minimumContentWidth

    private enum SnapshotPhase {
        case loading
        case loaded(GitWorkingTreeSnapshot)
        case failed(String)
    }

    private enum DiffPhase {
        case idle
        case loading
        case loaded(GitFileDiff)
        case failed(String)
    }

    private struct DiffScrollRequest: Equatable {
        let lineID: Int
        let nonce: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            windowHeader
            ThemeDivider()
            content
        }
        .background(theme.background)
        .task(id: target.id) { await loadSnapshot() }
        .onChange(of: searchQuery) { _ in
            searchQueryChanged()
        }
    }

    private var windowHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Working Changes")
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
                    Text("Compared with \(snapshot.base.displayName)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("Local only · read-only")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textTertiary)
                }
            }
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
            .tooltip("Reload the current working tree and comparison base")
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
                systemImage: "doc.text.magnifyingglass",
                title: "Reading working changes…",
                detail: "Comparing local files with the latest local commit.",
                showsProgress: true)
        case .failed(let message):
            failureView(title: "Couldn't read working changes", message: message) {
                Task { await loadSnapshot() }
            }
        case .loaded(let snapshot):
            if snapshot.files.isEmpty {
                stateView(
                    systemImage: "checkmark.circle",
                    title: "Working tree is clean",
                    detail: "There are no staged, unstaged, or untracked files to show.",
                    tint: theme.success)
            } else {
                loadedContent(snapshot)
            }
        }
    }

    private func loadedContent(_ snapshot: GitWorkingTreeSnapshot) -> some View {
        HStack(spacing: 0) {
            fileSidebar(snapshot)
                .frame(width: 300)
            Rectangle()
                .fill(theme.border)
                .frame(width: 1)
            diffPane(snapshot)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileSidebar(_ snapshot: GitWorkingTreeSnapshot) -> some View {
        VStack(spacing: 0) {
            searchBar
            ThemeDivider()
            if trimmedSearchQuery.isEmpty {
                HStack {
                    Text("Files")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Spacer()
                    countBadge(snapshot.files.count)
                }
                .padding(.horizontal, 12)
                .frame(height: 38)
                ThemeDivider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(fileGroups) { group in
                            fileGroup(group, snapshot: snapshot)
                        }
                    }
                    .padding(10)
                }
            } else {
                searchResults(snapshot)
            }
        }
        .background(theme.surface)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Button {
                searchFieldFocused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(searchFieldFocused ? theme.accent : theme.textTertiary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)
            .tooltip("Search changed files and code (⌘F)")

            TextField("Find files or changed code…", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(theme.text)
                .focused($searchFieldFocused)
                .onExitCommand {
                    if !searchQuery.isEmpty {
                        searchQuery = ""
                    } else {
                        searchFieldFocused = false
                    }
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textTertiary)
                }
                .buttonStyle(.plain)
                .tooltip("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .fill(theme.elevatedSurface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous)
                .stroke(searchFieldFocused ? theme.accent.opacity(0.7) : theme.border, lineWidth: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(theme.textMuted)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background(theme.surfaceMuted)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func searchResults(_ snapshot: GitWorkingTreeSnapshot) -> some View {
        HStack(spacing: 7) {
            Text("Matches")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.text)
            if isIndexingSearch || isMatchingSearch {
                ProgressView().controlSize(.mini)
            }
            Spacer()
            if !isIndexingSearch && searchIndexError == nil {
                countBadge(searchMatches.totalCount)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        ThemeDivider()

        if let searchIndexError {
            compactSearchState(
                systemImage: "exclamationmark.triangle",
                title: "Couldn't search changed code",
                detail: searchIndexError,
                tint: theme.error
            ) {
                retrySearchIndex(snapshot)
            }
        } else if isIndexingSearch && searchIndex == nil && searchMatches.totalCount == 0 {
            compactSearchState(
                systemImage: "doc.text.magnifyingglass",
                title: "Indexing changed code…",
                detail: "File names are included with each line-by-line diff.",
                tint: theme.accent)
        } else if !isMatchingSearch && searchMatches.totalCount == 0 {
            compactSearchState(
                systemImage: "magnifyingglass",
                title: "No matches",
                detail: "Try text, a glob such as *.swift, or a fuzzy abbreviation.",
                tint: theme.textTertiary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !searchMatches.files.isEmpty {
                        searchSectionTitle("Files", count: searchMatches.files.count)
                        ForEach(searchMatches.files) { match in
                            fileSearchResult(match, snapshot: snapshot)
                        }
                    }
                    if !searchMatches.code.isEmpty {
                        searchSectionTitle("Changed Code", count: searchMatches.code.count)
                        ForEach(searchMatches.code) { match in
                            codeSearchResult(match, snapshot: snapshot)
                        }
                    }
                    searchLimitNotice
                }
                .padding(10)
            }
        }
    }

    private func searchSectionTitle(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.textMuted)
            Spacer()
            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 5)
    }

    private func fileSearchResult(
        _ match: GitWorkingDiffFileMatch,
        snapshot: GitWorkingTreeSnapshot
    ) -> some View {
        Button {
            activateSearchFile(match.file, in: snapshot)
        } label: {
            HStack(spacing: 7) {
                Text(statusGlyph(match.file.status))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor(match.file.status))
                    .frame(width: 14)
                Text(untrusted: fileLabel(match.file))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 7)
            .background(searchResultBackground(match.file))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tooltip("Open \(fileLabel(match.file))")
    }

    private func codeSearchResult(
        _ match: GitWorkingDiffCodeMatch,
        snapshot: GitWorkingTreeSnapshot
    ) -> some View {
        Button {
            activateCodeMatch(match, in: snapshot)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(untrusted: match.file.path.sanitizedForSingleLineDisplay())
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(searchLineLabel(match.line))
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                }
                HStack(spacing: 5) {
                    Text(lineMarker(match.line.kind))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(lineMarkerColor(match.line.kind))
                        .frame(width: 9)
                    Text(untrusted: match.line.text.sanitizedForCodeLineDisplay())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 7)
            .background(searchResultBackground(match.file))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tooltip(match.hunkHeader.sanitizedForSingleLineDisplay())
    }

    private func searchResultBackground(_ file: GitFileChange) -> some View {
        RoundedRectangle(cornerRadius: Theme.radiusMicro, style: .continuous)
            .fill(selectedFileKey == file.workingDiffKey ? theme.accentSubtle : theme.elevatedSurface)
    }

    @ViewBuilder
    private var searchLimitNotice: some View {
        if searchMatches.isTruncated || searchIndex?.isCodeIndexTruncated == true {
            Label(
                searchMatches.isTruncated
                    ? "More matches exist. Refine your search to narrow the list."
                    : "The code index reached its safety limit; all file paths are still searchable.",
                systemImage: "info.circle"
            )
            .font(.system(size: 9))
            .foregroundStyle(theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(6)
        } else if let failedFileCount = searchIndex?.failedFileCount, failedFileCount > 0 {
            Label(
                "\(failedFileCount) file diff\(failedFileCount == 1 ? "" : "s") couldn't be indexed.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 9))
            .foregroundStyle(theme.warning)
            .padding(6)
        }
    }

    private func compactSearchState(
        systemImage: String,
        title: String,
        detail: String,
        tint: Color,
        retry: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(untrusted: detail)
                .font(.system(size: 10))
                .foregroundStyle(theme.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(SubtleButtonStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileGroup(
        _ group: GitChangeGroup,
        snapshot: GitWorkingTreeSnapshot
    ) -> some View {
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

    private func fileButton(
        _ file: GitFileChange,
        snapshot: GitWorkingTreeSnapshot
    ) -> some View {
        let selected = selectedFileKey == fileKey(file)
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
                    .fill(selected ? theme.accentSubtle : Color.clear)
            )
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

    private func diffPane(_ snapshot: GitWorkingTreeSnapshot) -> some View {
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

    private func fileHeader(
        _ file: GitFileChange,
        snapshot: GitWorkingTreeSnapshot
    ) -> some View {
        let index = orderedFiles.firstIndex(where: { fileKey($0) == fileKey(file) })
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
    private func diffBody(
        _ file: GitFileChange,
        snapshot: GitWorkingTreeSnapshot
    ) -> some View {
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
                detail: "Comparing this file with \(snapshot.base.displayName).",
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
    private func diffContent(
        _ diff: GitFileDiff,
        file: GitFileChange
    ) -> some View {
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
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hunks) { hunk in
                        hunkHeader(hunk.header)
                        ForEach(hunk.lines) { line in
                            diffLine(line, isSearchTarget: diffScrollRequest?.lineID == line.id)
                                .id(line.id)
                        }
                    }
                }
                .frame(minWidth: diffContentWidth, alignment: .leading)
                .textSelection(.enabled)
            }
            .background(theme.elevatedSurface)
            .onAppear {
                scrollToSearchResult(using: proxy)
            }
            .onChange(of: diffScrollRequest) { _ in
                scrollToSearchResult(using: proxy)
            }
        }
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

    private func diffLine(_ line: GitDiffLine, isSearchTarget: Bool) -> some View {
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
        .background(isSearchTarget ? theme.accentSubtle : lineBackground(line.kind))
        .overlay(alignment: .leading) {
            if isSearchTarget {
                Rectangle()
                    .fill(theme.accent)
                    .frame(width: 3)
            }
        }
    }

    private func scrollToSearchResult(using proxy: ScrollViewProxy) {
        guard let request = diffScrollRequest else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(request.lineID, anchor: .center)
            }
        }
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

    /// Sanitized like every other git-sourced single-line string: a filename can
    /// legally carry the same bidi/control scalars as a commit subject.
    private func fileLabel(_ file: GitFileChange) -> String {
        guard let originalPath = file.originalPath else {
            return file.path.sanitizedForSingleLineDisplay()
        }
        return "\(originalPath) → \(file.path)".sanitizedForSingleLineDisplay()
    }

    private func fileKey(_ file: GitFileChange) -> String {
        file.workingDiffKey
    }

    /// Every `.loaded` transition goes through here so the row width is measured
    /// exactly once per patch instead of on every render of a 50k-line diff.
    private func showDiff(_ diff: GitFileDiff) {
        diffContentWidth = Self.contentWidth(for: diff)
        diffPhase = .loaded(diff)
    }

    // MARK: Code-pane geometry

    /// Minimum width of a diff row, so a short patch still fills the pane.
    private static let minimumContentWidth: CGFloat = 900
    /// Gutters ahead of the code text: two line-number columns plus the +/- marker.
    private static let gutterWidth: CGFloat = 48 * 2 + 7 * 2 + 22
    /// Monospaced advance at the 11pt code size, rounded up (see `displayColumns`).
    private static let columnWidth: CGFloat = 7
    /// Ceiling on the measured width. Pairs with the per-line display cap in
    /// `sanitizedForCodeLineDisplay`, so one pathological line can't ask AppKit for
    /// a scroll view millions of points wide.
    private static let maximumContentColumns = 2200

    private static func contentWidth(for diff: GitFileDiff) -> CGFloat {
        let columns = diff.maximumDisplayColumns(limit: maximumContentColumns)
        return max(minimumContentWidth, gutterWidth + CGFloat(columns) * columnWidth + 12)
    }

    private func selectedFile(in snapshot: GitWorkingTreeSnapshot) -> GitFileChange? {
        guard let selectedFileKey else { return nil }
        return snapshot.files.first { fileKey($0) == selectedFileKey }
    }

    private func navigate(
        from file: GitFileChange,
        offset: Int,
        snapshot: GitWorkingTreeSnapshot
    ) {
        guard let current = orderedFiles.firstIndex(where: { fileKey($0) == fileKey(file) }) else { return }
        let next = current + offset
        guard orderedFiles.indices.contains(next) else { return }
        select(orderedFiles[next], in: snapshot)
    }

    private func select(
        _ file: GitFileChange,
        in snapshot: GitWorkingTreeSnapshot
    ) {
        diffScrollRequest = nil
        selectedFileKey = fileKey(file)
        loadSelectedFile(file, snapshot: snapshot)
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func searchLineLabel(_ line: GitDiffLine) -> String {
        guard let number = line.newLineNumber ?? line.oldLineNumber else { return "Line" }
        return "L\(number)"
    }

    private func activateSearchFile(
        _ file: GitFileChange,
        in snapshot: GitWorkingTreeSnapshot
    ) {
        diffScrollRequest = nil
        selectedFileKey = file.workingDiffKey
        guard let diff = searchIndex?.entry(for: file.workingDiffKey)?.diff else {
            loadSelectedFile(file, snapshot: snapshot)
            return
        }
        diffSessionID = UUID()
        showDiff(diff)
    }

    private func activateCodeMatch(
        _ match: GitWorkingDiffCodeMatch,
        in snapshot: GitWorkingTreeSnapshot
    ) {
        selectedFileKey = match.file.workingDiffKey
        guard let diff = searchIndex?.entry(for: match.file.workingDiffKey)?.diff else {
            diffScrollRequest = nil
            loadSelectedFile(match.file, snapshot: snapshot)
            return
        }
        diffSessionID = UUID()
        showDiff(diff)
        diffScrollRequest = DiffScrollRequest(lineID: match.line.id, nonce: UUID())
    }

    private func retrySearchIndex(_ snapshot: GitWorkingTreeSnapshot) {
        searchIndex = nil
        searchIndexError = nil
        searchMatches = .empty
        beginSearch(in: snapshot)
    }

    private func searchQueryChanged() {
        searchMatchSessionID = UUID()
        pathMatchSessionID = UUID()
        searchMatches = .empty
        isMatchingSearch = false
        guard !trimmedSearchQuery.isEmpty,
            case .loaded(let snapshot) = snapshotPhase
        else { return }
        beginSearch(in: snapshot)
    }

    private func beginSearch(in snapshot: GitWorkingTreeSnapshot) {
        guard !trimmedSearchQuery.isEmpty else { return }
        if let searchIndex {
            let query = trimmedSearchQuery
            let expectedSnapshotSession = snapshotSessionID
            Task {
                await updateSearchMatches(
                    query: query,
                    index: searchIndex,
                    expectedSnapshotSession: expectedSnapshotSession)
            }
        } else {
            let query = trimmedSearchQuery
            let expectedSnapshotSession = snapshotSessionID
            Task {
                await updatePathMatches(
                    query: query,
                    snapshot: snapshot,
                    expectedSnapshotSession: expectedSnapshotSession)
            }
            if !isIndexingSearch {
                // Claim the flag synchronously. `loadSearchIndex` used to set it
                // after its first suspension, so typing two characters quickly
                // started two full index builds — each spawning one git process per
                // changed file.
                isIndexingSearch = true
                Task {
                    await loadSearchIndex(snapshot, expectedSnapshotSession: expectedSnapshotSession)
                }
            }
        }
    }

    @MainActor
    private func updatePathMatches(
        query: String,
        snapshot: GitWorkingTreeSnapshot,
        expectedSnapshotSession: UUID
    ) async {
        guard searchIndex == nil else { return }
        let session = UUID()
        pathMatchSessionID = session
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard snapshotSessionID == expectedSnapshotSession,
            pathMatchSessionID == session,
            trimmedSearchQuery == query,
            searchIndex == nil
        else { return }
        let matches = await repoActionCoordinator.workingDiffPathMatches(query: query, snapshot: snapshot)
        guard snapshotSessionID == expectedSnapshotSession,
            pathMatchSessionID == session,
            trimmedSearchQuery == query,
            searchIndex == nil
        else { return }
        searchMatches = matches
    }

    @MainActor
    private func loadSearchIndex(
        _ snapshot: GitWorkingTreeSnapshot,
        expectedSnapshotSession: UUID
    ) async {
        // A snapshot reload between the caller claiming `isIndexingSearch` and this
        // task running already reset it, along with every other search state.
        guard snapshotSessionID == expectedSnapshotSession else { return }
        let session = UUID()
        searchIndexSessionID = session
        isIndexingSearch = true
        searchIndexError = nil

        let result = await repoActionCoordinator.workingDiffSearchIndex(for: target, snapshot: snapshot)
        guard snapshotSessionID == expectedSnapshotSession,
            searchIndexSessionID == session
        else { return }
        isIndexingSearch = false
        switch result {
        case .success(let index):
            searchIndex = index
            guard !trimmedSearchQuery.isEmpty else { return }
            await updateSearchMatches(
                query: trimmedSearchQuery,
                index: index,
                expectedSnapshotSession: expectedSnapshotSession)
        case .failure(let error):
            searchIndexError = error.displayMessage
        }
    }

    @MainActor
    private func updateSearchMatches(
        query: String,
        index: GitWorkingDiffSearchIndex,
        expectedSnapshotSession: UUID
    ) async {
        let session = UUID()
        searchMatchSessionID = session
        isMatchingSearch = true
        searchMatches = .empty

        try? await Task.sleep(nanoseconds: 120_000_000)
        guard snapshotSessionID == expectedSnapshotSession,
            searchMatchSessionID == session,
            trimmedSearchQuery == query
        else { return }
        let matches = await repoActionCoordinator.workingDiffSearchMatches(query: query, index: index)
        guard snapshotSessionID == expectedSnapshotSession,
            searchMatchSessionID == session,
            trimmedSearchQuery == query
        else { return }
        searchMatches = matches
        isMatchingSearch = false
    }

    private func loadSelectedFile(
        _ file: GitFileChange,
        snapshot: GitWorkingTreeSnapshot
    ) {
        let expectedSnapshotSession = snapshotSessionID
        Task {
            await loadDiff(file, base: snapshot.base, expectedSnapshotSession: expectedSnapshotSession)
        }
    }

    @MainActor
    private func loadSnapshot() async {
        let session = UUID()
        snapshotSessionID = session
        diffSessionID = UUID()
        searchIndexSessionID = UUID()
        searchMatchSessionID = UUID()
        pathMatchSessionID = UUID()
        let preferredFileKey = selectedFileKey
        snapshotPhase = .loading
        fileGroups = []
        orderedFiles = []
        diffPhase = .idle
        diffScrollRequest = nil
        searchIndex = nil
        searchMatches = .empty
        isIndexingSearch = false
        isMatchingSearch = false
        searchIndexError = nil

        let result = await repoActionCoordinator.workingTreeChanges(for: target)
        guard snapshotSessionID == session else { return }
        switch result {
        case .success(let snapshot):
            snapshotPhase = .loaded(snapshot)
            fileGroups = GitChanges.grouped(snapshot.files)
            orderedFiles = fileGroups.flatMap(\.files)
            let selected =
                preferredFileKey.flatMap { key in
                    snapshot.files.first { fileKey($0) == key }
                } ?? orderedFiles.first
            guard let selected else {
                selectedFileKey = nil
                diffPhase = .idle
                return
            }
            selectedFileKey = fileKey(selected)
            await loadDiff(selected, base: snapshot.base, expectedSnapshotSession: session)
            beginSearch(in: snapshot)
        case .failure(let error):
            snapshotPhase = .failed(error.displayMessage)
        }
    }

    @MainActor
    private func loadDiff(
        _ file: GitFileChange,
        base: GitDiffBase,
        expectedSnapshotSession: UUID
    ) async {
        guard snapshotSessionID == expectedSnapshotSession else { return }
        let session = UUID()
        let expectedFileKey = fileKey(file)
        diffSessionID = session
        diffPhase = .loading

        let result = await repoActionCoordinator.workingFileDiff(for: target, file: file, base: base)
        guard snapshotSessionID == expectedSnapshotSession,
            diffSessionID == session,
            selectedFileKey == expectedFileKey
        else { return }
        switch result {
        case .success(let diff): showDiff(diff)
        case .failure(let error): diffPhase = .failed(error.displayMessage)
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
            Text(detail)
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
            Text(untrusted: message)
                .font(.system(size: 11))
                .foregroundStyle(theme.textMuted)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
            Button("Try Again", action: retry)
                .buttonStyle(SubtleButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.elevatedSurface)
    }
}
