import XCTest
@testable import GitNest

/// Pins the session-staleness contract that protects `loadAccountStatus`'s two
/// `await`s from writing state for an account that was removed, or clobbering a
/// newer batch's in-flight markers. These guards are the multi-account safety
/// boundary and were previously untested; a regression here (e.g. the defer's
/// clearing condition diverging from the early-return guards, as it once did)
/// can leak `accountStatusChecksPending` entries or let a stale result land.
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

    /// `isCurrentAccountStatusSession` also requires the account to still be
    /// configured — a check whose account was removed mid-flight must read as
    /// stale even under the same session, so its result is dropped and its pending
    /// marker can be cleaned up by the defer.
    func testIsCurrentAccountStatusSessionRequiresAccountStillPresent() {
        let manager = makeManager(accounts: [account("a")])
        let session = manager.accountStatusSessionID

        // Account removed (e.g. user edited ~/.gitconfig) but session unchanged.
        manager.accounts = []

        XCTAssertFalse(manager.isCurrentAccountStatusSession(session, alias: "a"),
                       "a session check for a removed account must read as stale")
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
}
