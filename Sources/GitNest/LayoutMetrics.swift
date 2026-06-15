import Foundation

/// Shared layout constants for the repo list and account cards so the header,
/// rows, and divider insets stay aligned when sizes change.
enum LayoutMetrics {
    /// Visibility icon column (no title, just the globe/lock icon).
    static let visWidth: CGFloat = 52
    /// "Updated" date column.
    static let updatedWidth: CGFloat = 150
    /// Actions column: Open menu + fetch/pull/commit/push/delete icon buttons.
    static let actionsWidth: CGFloat = 213
    /// Fixed width for both profile-card auth pills so they read as a matched pair.
    static let authBadgeWidth: CGFloat = 78
    /// Leading inset for the row divider so it lines up with the repo-name text.
    static let rowDividerLeadingInset: CGFloat = 30
}
