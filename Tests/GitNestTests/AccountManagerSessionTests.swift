import XCTest
@testable import GitNest

/// Pins the session-staleness contract around `loadAccountStatus`. Two distinct
/// rules cooperate, and they are deliberately *not* the same predicate:
///
///  • The in-body `await` guards use `isCurrentAccountStatusSession` (session ID
///    AND account still present), so a late-resuming check writes no state for a
///    superseded batch or a removed account.
///  • The exit-path `defer` uses `clearAccountStatusPending` (session ID ONLY), so
///    a same-session check whose account was removed mid-flight still drops the
///    marker it inserted instead of leaking it in `accountStatusChecksPending`.
///
/// The looser defer is the bug-prone part: making it match the stricter `await`
/// guard (as an "enhancement" once did) reintroduces the leak. These tests pin
/// both rules, including that exact divergence.
///
/// All assertions are network-free: they exercise the session-token and pending-
/// set mechanics directly, never `loadAccountStatus`'s real ssh/gh calls.
@MainActor
final class AccountManagerSessionTests: XCTestCase {
    private func makeManager(accounts: [Account]) -> AccountManager {
        let ghChain = GhChain()
        let logStore = LogStore()
        let manager = AccountManager(ghChain: ghChain,
                                     logStore: logStore,
                                     authProcessController: AuthProcessController())
        manager.accounts = accounts
        return manager
    }

    private func account(_ alias: String) -> Account {
        Account(alias: alias, name: alias, email: "\(alias)@example.com", folder: "/tmp/gitnest-\(alias)")
    }

    /// `refreshAll` must mint a fresh session and clear the in-flight pending set,
    /// so a previous batch's leftover markers can't pin cards in "checking…" state.
    func testRefreshAllBumpsSessionAndClearsPending() {
        let manager = makeManager(accounts: [account("a"), account("b")])
        let originalSession = manager.accountStatusSessionID
        manager.accountStatusChecksPending = ["a", "b"]

        manager.refreshAll()

        XCTAssertNotEqual(manager.accountStatusSessionID, originalSession,
                          "refreshAll must mint a new session")
        XCTAssertTrue(manager.accountStatusChecksPending.isEmpty,
                      "refreshAll must clear stale in-flight markers")
    }

    /// A session older than the current one is no longer "current" — the guards in
    /// `loadAccountStatus` rely on this so a late-resuming old check writes nothing.
    /// (Bumps the session ID directly rather than via `refreshAll`, which also
    /// reloads accounts from disk and would wipe the in-memory test account.)
    func testIsCurrentAccountStatusSessionIsFalseForSupersededSession() {
        let a = account("a")
        let manager = makeManager(accounts: [a])
        let oldSession = manager.accountStatusSessionID

        manager.accountStatusSessionID = UUID()   // a newer batch supersedes the old one

        XCTAssertFalse(manager.isCurrentAccountStatusSession(oldSession, alias: "a"),
                       "an old session must not be considered current once superseded")
        XCTAssertTrue(manager.isCurrentAccountStatusSession(manager.accountStatusSessionID, alias: "a"),
                      "the live session for a present account is current")
    }

    /// `isCurrentAccountStatusSession` (the guard the in-body `await`s use) also
    /// requires the account to still be configured — a check whose account was
    /// removed mid-flight reads as stale even under the same session, so its result
    /// is dropped. Note this is the *stricter* of the two rules; the defer cleanup
    /// uses the looser `clearAccountStatusPending` (see below), which is exactly why
    /// the marker still gets removed in that case.
    func testIsCurrentAccountStatusSessionRequiresAccountStillPresent() {
        let manager = makeManager(accounts: [account("a")])
        let session = manager.accountStatusSessionID

        // Account removed (e.g. user edited ~/.gitconfig) but session unchanged.
        manager.accounts = []

        XCTAssertFalse(manager.isCurrentAccountStatusSession(session, alias: "a"),
                       "a session check for a removed account must read as stale")
    }

    /// The leak regression. `loadAccountStatus` inserts a pending marker, then can
    /// early-return when its account is removed mid-flight (same session). The
    /// exit-path defer must STILL clear that marker — its condition is the looser
    /// `clearAccountStatusPending` (session only), not the stricter
    /// `isCurrentAccountStatusSession` that the early-returns use. If the defer is
    /// "tidied" to reuse `isCurrentAccountStatusSession`, the removed account's
    /// marker leaks and pins its card; this test fails in that case.
    func testClearAccountStatusPendingClearsMarkerWhenAccountRemovedMidFlight() {
        let manager = makeManager(accounts: [account("a")])
        let session = manager.accountStatusSessionID
        manager.accountStatusChecksPending = ["a"]   // as loadAccountStatus's caller inserted it

        // Account removed mid-flight (e.g. user edited ~/.gitconfig); session intact.
        manager.accounts = []

        manager.clearAccountStatusPending("a", session: session)

        XCTAssertFalse(manager.accountStatusChecksPending.contains("a"),
                       "a same-session check must drop its own marker even after its account is removed")
    }

    /// The other side of the divergence: a marker belonging to a newer batch must
    /// NOT be cleared by a superseded check's defer. After the session is bumped,
    /// the in-flight set is owned by the new batch, so an old check exiting late
    /// must leave it untouched.
    func testClearAccountStatusPendingLeavesMarkerForSupersededSession() {
        let manager = makeManager(accounts: [account("a")])
        let oldSession = manager.accountStatusSessionID
        manager.accountStatusSessionID = UUID()       // a newer batch took over
        manager.accountStatusChecksPending = ["a"]    // and re-inserted its own marker

        manager.clearAccountStatusPending("a", session: oldSession)

        XCTAssertTrue(manager.accountStatusChecksPending.contains("a"),
                      "a superseded check must not delete the live batch's in-flight marker")
    }

    /// `runAccountStatusCheckIfNeeded` must refuse to act under a stale session,
    /// and crucially must NOT insert into `accountStatusChecksPending` (which would
    /// then route into `loadAccountStatus`'s real ssh/gh call). This keeps the
    /// test network-free while proving the stale-session gate fires before any
    /// side effect.
    func testRunAccountStatusCheckIfNeededRefusesStaleSessionWithoutTouchingPending() async {
        let a = account("a")
        let manager = makeManager(accounts: [a])
        let staleSession = UUID()   // never current

        await manager.runAccountStatusCheckIfNeeded(a, session: staleSession, force: true)

        XCTAssertTrue(manager.accountStatusChecksPending.isEmpty,
                      "a stale session must not insert a pending marker (which would start a real check)")
        XCTAssertFalse(manager.accountChecking(a),
                       "the card must not be left in the checking state by a refused stale check")
    }

    /// The background status sweep snapshots the active gh account, switches to the
    /// account it's verifying, then restores. A *failed* restore leaves gh flipped to
    /// `alias` — that must surface as a warning, not be swallowed. A successful
    /// restore is silent.
    func testActiveAccountRestoreWarningOnlyFiresOnFailureAndNamesBothAccounts() {
        XCTAssertNil(AccountManager.activeAccountRestoreWarning(
            leftActiveOn: "work", original: "personal", restoreOK: true),
            "a successful restore must not warn")

        let warning = AccountManager.activeAccountRestoreWarning(
            leftActiveOn: "work", original: "personal", restoreOK: false)
        XCTAssertNotNil(warning, "a failed restore must produce a warning")
        XCTAssertTrue(warning?.contains("work") == true, "names the account gh was left on")
        XCTAssertTrue(warning?.contains("personal") == true, "names the account it could not restore")
    }
}
