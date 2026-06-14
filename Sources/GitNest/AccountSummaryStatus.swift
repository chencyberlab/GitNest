import SwiftUI

/// Connection-readiness summary shown on each account card.
enum AccountSummaryStatus {
    case loading
    case notLoaded
    case ready
    case partial
    case failed

    var help: String {
        switch self {
        case .loading: return "Loading SSH and GitHub status"
        case .notLoaded: return "Connection status not loaded"
        case .ready: return "SSH and GitHub are ready"
        case .partial: return "SSH or GitHub needs attention"
        case .failed: return "SSH and GitHub checks failed"
        }
    }
}
