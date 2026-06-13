import SwiftUI
import Combine

@MainActor
final class AlertStore: ObservableObject {
    struct PullWarning: Identifiable, Sendable {
        let id = UUID()
        let repoName: String
        let message: String

        /// Builds the user-facing alert body from Git's combined stdout+stderr.
        /// Long output is capped so the alert stays readable — the full text is
        /// always available in the Output pane.
        static func message(repoName: String, gitOutput: String) -> String {
            let output = gitOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail: String
            if output.isEmpty {
                detail = "Git did not provide details."
            } else if output.count > 1200 {
                detail = String(output.prefix(1200)) + "\n\nFull output is in the Output pane."
            } else {
                detail = output
            }
            return """
            Git could not pull \(repoName). Your local files were not force-replaced.

            This usually means uncommitted changes, a divergent branch, or merge conflicts that need manual resolution — see Git's output below for the exact reason.

            \(detail)
            """
        }
    }

    @Published var pullWarning: PullWarning?

    func showPullWarning(_ warning: PullWarning) {
        pullWarning = warning
    }

    func dismissPullWarning() {
        pullWarning = nil
    }
}
