import XCTest

@testable import GitNest

/// Pins the staleness guard added in R4. The reauth one-time code is written from two
/// async places (the clipboard watcher and the post-login parser); both route through
/// `applyClipboardAuthCode(_:session:)`. A reauth flow superseded by a newer one (the
/// user retried, possibly on a different account) must not clobber the code field the
/// newer flow owns. Same session-token idiom as `isCurrentAccountStatusSession`.
@MainActor
final class ReauthCodeTests: XCTestCase {
    private func makeManager() -> AccountManager {
        AccountManager(ghChain: GhChain(),
                       logStore: LogStore(),
                       authProcessController: AuthProcessController())
    }

    /// The active flow's code is published.
    func testApplyClipboardAuthCodePublishesForCurrentSession() {
        let manager = makeManager()
        manager.applyClipboardAuthCode("ABCD-1234", session: manager.reauthWatcherSession)
        XCTAssertEqual(manager.currentAuthFlowCode, "ABCD-1234")
    }

    /// A code from a superseded flow is dropped (the session was bumped by a newer one).
    func testApplyClipboardAuthCodeIgnoresSupersededSession() {
        let manager = makeManager()
        let staleSession = manager.reauthWatcherSession
        manager.reauthWatcherSession = UUID()   // a newer reauth started
        manager.applyClipboardAuthCode("ABCD-1234", session: staleSession)
        XCTAssertNil(manager.currentAuthFlowCode, "a superseded flow must not write the code field")
    }

    /// A superseded flow must not overwrite the code a newer flow already published.
    func testApplyClipboardAuthCodeDoesNotClobberNewerCode() {
        let manager = makeManager()
        let firstSession = manager.reauthWatcherSession
        manager.applyClipboardAuthCode("ABCD-1234", session: firstSession)

        // Newer flow takes over and shows its own code…
        let secondSession = UUID()
        manager.reauthWatcherSession = secondSession
        manager.applyClipboardAuthCode("WXYZ-5678", session: secondSession)
        XCTAssertEqual(manager.currentAuthFlowCode, "WXYZ-5678")

        // …a late write from the first (now stale) flow is ignored.
        manager.applyClipboardAuthCode("ABCD-1234", session: firstSession)
        XCTAssertEqual(manager.currentAuthFlowCode, "WXYZ-5678")
    }
}
