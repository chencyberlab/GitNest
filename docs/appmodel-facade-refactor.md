# AppModel Facade Refactor — Phased Plan

> **Status:** not started. Pick up at **Phase 0**.
> **Goal:** remove the ~26 mirror `@Published` properties + 25 `assign(to:)` lines on
> `AppModel` and the pure pass-through methods, by having views observe the child
> managers directly. `AppModel` shrinks to composition + cross-manager orchestration
> + lifecycle. **No behavior change** — this is a structural refactor.

This is the deferred **item #6** from the security review. It is the riskiest change
on the list (it touches the least-tested layer — SwiftUI views), so it is done in
small, always-green phases with a manual smoke test between each.

---

## Why / what's the deal (recap)

`AppModel` owns almost no state. The real state lives in nine child managers; AppModel
re-publishes it upward so every view can bind to one object. The cost is **triple
bookkeeping**: each piece of state is declared in the manager (source of truth), again
as a mirror `@Published` on AppModel, and again in the `assign(to:)` wiring. Forgetting
the wiring silently breaks a view's reactivity. The refactor deletes the middle layer.

**Important nuance:** removing a mirror *requires* views to observe the manager
directly — a computed `var repos { repoManager.repos }` would compile but never trigger
SwiftUI updates. So after the refactor a heavy view declares the 2–6 managers it
actually uses. That's the idiomatic "scene observes its stores" pattern and is the
accepted trade.

---

## Target architecture

**Managers that are `ObservableObject` (views may observe directly):**
`AccountManager`, `RepoManager`, `RepoActionCoordinator`, `ProjectWorkflow`,
`SetupCoordinator`, `LogStore`, `AlertStore`.

**Not `ObservableObject` (never injected):** `GhChain`, `AuthProcessController`.

**Stays on `AppModel` (genuine cross-manager orchestration + lifecycle — do NOT move):**
- `selectAccount(_:)` — coordinates `repoManager.saveVisibleRepoState()` +
  `accountManager.selectAccount()` + `repoManager.restoreRepoState()` + auto-refresh.
- `startLifecycle(...)`, `prepareForTermination()`, app-activation observers.
- `configureRepoAutoRefresh(...)`, `configureAccountStatusLoadMode(...)` (need
  `appIsActive`, which AppModel owns).
- `repoSearchBinding`, `addAccountActiveBinding` — write-through bindings with logic
  (the add-account one calls `cancelAddAccount()` on dismiss). See the **landmine** note.
- `localFolderState(...)`, `run(_:)` helpers.

> **⚠ Landmine — read before touching bindings.** `AppModel` documents a past
> stack-overflow crash from a two-way Combine binding bridging an AppModel mirror to a
> manager. The refactor *removes* that class of bug (views talk to the manager
> directly, no bridge). But do **not** reintroduce a Combine bridge. For the search
> field, replace `model.repoSearchBinding` with the direct SwiftUI binding
> `$repoManager.repoSearch` — a plain `Binding` to the source of truth, no loop.
> `addAccountActiveBinding` must keep its dismiss→`cancelAddAccount()` logic; leave it
> on AppModel (or move it onto `SetupCoordinator` as a computed `Binding`, preserving
> the cancel call). Never make it a bare `$setupCoordinator.addAccountActive`.

---

## Master mapping: `model.X` → owner

Use this as the find/replace reference. **Read-state** = a `@Published` to observe;
**method** = a pass-through to call on the manager.

### → `repoManager` (`RepoManager`)
| `model.…` | becomes | kind |
|---|---|---|
| `repos`, `filteredRepos`, `repoSearch`, `selectedRepo`, `repoSortField`, `repoSortAscending`, `repoStatuses`, `clonedRepos`, `repoFolderConflicts`, `isLoadingRepos`, `isRefreshingRepos`, `isCheckingRepoRemotes`, `repoRefreshMessage` | `repoManager.<same>` | read-state |
| `sortBy(_:)`, `isCloned(_:)`, `folderConflict(_:)`, `localPath(_:in:)`, `loadRepos(...)` | `repoManager.<same>` | method |
| `setRepoSearch(t)` | `repoManager.repoSearch = t` (or `$repoManager.repoSearch` binding) | method |

### → `accountManager` (`AccountManager`)
| `model.…` | becomes | kind |
|---|---|---|
| `accounts`, `selectedAccount`, `sshGreetings`, `ghIndicators`, `accountStatusChecksPending` | `accountManager.<same>` | read-state |
| `accountReady`, `accountChecking`, `accountStatusKnown`, `accountSSHReady`, `accountGhReady` | `accountManager.<same>` | method |
| `refreshAll(...)`, `logAuthStatus()`, `openGitHubProfile(_:)`, `reauthenticateGh(_:)`, `moveAccount(...)` | `accountManager.<same>` | method |

### → `repoActionCoordinator` (`RepoActionCoordinator`)
| `model.…` | becomes | kind |
|---|---|---|
| `busyRepos` | `repoActionCoordinator.busyRepos` | read-state |
| `isRepoActionBusy`, `clone`, `pull`, `fetch`, `push`, `commit`, `deleteLocalFolder`, `openGitHubRepo`, `openPullRequests`, `openIssues`, `openLocalFolder`, `openInEditor`, `openInTerminal`, `copyHTTPSURL`, `copySSHURL`, `copyCloneCommand`, `changedFiles`, `recentCommits`, `incomingCommits`, `stashList`, `hasLocalChanges`, `stashPush`, `stashApply`, `stashPop`, `stashDrop` | `repoActionCoordinator.<same>` | method |

### → `projectWorkflow` (`ProjectWorkflow`)
| `model.…` | becomes | kind |
|---|---|---|
| `isInitializingProject`, `isForkingProject` | `projectWorkflow.<same>` | read-state |
| `makeInitPlan`, `initProject`, `forkProject` | `projectWorkflow.<same>` | method |

### → `logStore` (`LogStore`)
| `model.…` | becomes | kind |
|---|---|---|
| `log` | `logStore.log` | read-state |
| `lastLogWasError` | `logStore.lastWasError` ← **note the name change** | read-state |

### → `alertStore` (`AlertStore`)
| `model.…` | becomes | kind |
|---|---|---|
| `pullWarning` | `alertStore.pullWarning` | read-state |
| `dismissPullWarning()` | `alertStore.dismissPullWarning()` | method |

### → `setupCoordinator` (`SetupCoordinator`)
| `model.…` | becomes | kind |
|---|---|---|
| `addAccountActive` | `setupCoordinator.addAccountActive` | read-state |
| `beginAddAccount()` | `setupCoordinator.beginAddAccount()` | method |
| `setupCoordinator` | (already the object) | — |

### STAYS on `model` (do not migrate)
`selectAccount`, `startLifecycle`, `prepareForTermination`,
`configureRepoAutoRefresh`, `configureAccountStatusLoadMode`,
`repoSearchBinding`*, `addAccountActiveBinding`.
*ContentView may instead use `$repoManager.repoSearch` directly (preferred) — see landmine.

---

## Phase 0 — inject managers into the environment (zero behavior change)

This makes every manager available to every view **before** any view is migrated, so
no migration step can hit a "No ObservableObject of type X found" runtime crash.

1. Create a single environment helper (new file, e.g. `EnvironmentInjection.swift`):

   ```swift
   import SwiftUI

   extension View {
       /// Inject AppModel plus every observable child manager, so any view (and any
       /// sheet/popover, which gets a fresh environment branch) can observe what it
       /// needs. Apply at the app root AND at every sheet/popover content root.
       func gitNestEnvironment(_ model: AppModel) -> some View {
           self
               .environmentObject(model)
               .environmentObject(model.accountManager)
               .environmentObject(model.repoManager)
               .environmentObject(model.repoActionCoordinator)
               .environmentObject(model.projectWorkflow)
               .environmentObject(model.setupCoordinator)
               .environmentObject(model.logStore)
               .environmentObject(model.alertStore)
       }
   }
   ```

2. In `App.swift`, replace `.environmentObject(appDelegate.model)` with
   `.gitNestEnvironment(appDelegate.model)`.

3. **Re-injection sites (critical — sheets/popovers branch the environment):** replace
   every existing `.environmentObject(model)` at a sheet/popover root with
   `.gitNestEnvironment(model)`:
   - `RepoRowView.swift` lines ~84, ~87, ~231
   - `ChangeSummaryView.swift` line ~34
   - `SidebarView.swift` line ~161 (currently injects `model.setupCoordinator`; widen it)
   - any `.sheet`/`.popover` in `ContentView.swift` / `ProjectSheets.swift`
   - (Leave `ContentView`'s `.environmentObject(tooltip)` alone — that's the TooltipController.)

   To find them all: `grep -rn "\.sheet(\|\.popover(\|environmentObject(model" Sources/`

**Done when:** builds, app launches and behaves *identically* (nothing observes the new
injections yet). This phase is pure safety scaffolding.

---

## Phases 1–3 — migrate views (mirrors stay in place)

Migrate views from `@EnvironmentObject var model: AppModel` to the specific managers
they use, per the **master mapping**. **Leave all AppModel mirrors and pass-throughs in
place** during these phases — they keep updating harmlessly and unmigrated views keep
working. Deletions happen in Phase 4, one compiler-checked sweep. This keeps every phase
trivially green and the app fully functional throughout.

For a view that *only* reads/calls migrated members, replace `model` entirely. For a
view that also uses orchestration (ContentView), **keep `model` AND add the managers**.

### Phase 1 — leaf views (lowest risk)
| View | Replace `model.` with |
|---|---|
| `CommitHistoryView` | `recentCommits` → `repoActionCoordinator`. Swap to `@EnvironmentObject var repoActionCoordinator: RepoActionCoordinator`. |
| `ChangeSummaryView` | `changedFiles` → `repoActionCoordinator`. (Note line ~34 re-injection from Phase 0.) |
| `IncomingCommitsView` | `incomingCommits` → `repoActionCoordinator`; `repoStatuses` → `repoManager`. Add both env objects. |

### Phase 2 — small views
| View | Replace `model.` with |
|---|---|
| `LogOutputView` | `log`, `lastLogWasError` → `logStore` (`lastLogWasError`→`lastWasError`); `logAuthStatus()` → `accountManager`. |
| `ProjectSheets` | `isInitializingProject`, `isForkingProject`, `initProject`, `forkProject` → `projectWorkflow`; `selectedAccount` → `accountManager`. |
| `StashView` | `stashList/Push/Apply/Pop/Drop`, `hasLocalChanges` → `repoActionCoordinator`; `repoStatuses` → `repoManager`. |

### Phase 3 — heavy views (one file per sub-step; smoke-test each individually)
| View | Replace `model.` with |
|---|---|
| `RepoListView` | `repos`, `filteredRepos`, `repoSearch`, `repoSortField`, `repoSortAscending`, `sortBy`, `setRepoSearch` → `repoManager`; `commit`, `push`, `deleteLocalFolder` → `repoActionCoordinator`. |
| `SidebarView` | `accounts`, `selectedAccount`, `sshGreetings`, `ghIndicators`, `account*` readiness, `moveAccount`, `openGitHubProfile`, `reauthenticateGh`, `refreshAll` → `accountManager`; `addAccountActiveBinding`, `beginAddAccount`, `setupCoordinator` → `setupCoordinator` (keep binding logic); `selectAccount` → **stays `model`**. |
| `RepoRowView` | `clone/pull/fetch/push`, `open*`, `copy*`, `isRepoActionBusy` → `repoActionCoordinator`; `repos`-derived state, `repoStatuses`, `selectedRepo`, `selectRepo`, `isCloned`, `folderConflict` → `repoManager`; `openGitHubRepo` → `repoActionCoordinator`. |
| `ContentView` | **keep `model`** for `startLifecycle`, `prepareForTermination`, `selectAccount`, `configure*`, `dismissPullWarning`/`pullWarning` (or move to `alertStore`), `refreshAll`. Move pure reads: `repos`/`filteredRepos`/`repoSearch`→`repoManager` (search field → `$repoManager.repoSearch`, see landmine); `selectedAccount`/`account*`→`accountManager`; `isLoading/Refreshing/CheckingRepoRemotes`/`repoRefreshMessage`→`repoManager`; `isForking/InitializingProject`→`projectWorkflow`; `makeInitPlan`/`loadRepos`→ managers. |

---

## Phase 4 — delete the orphans (compiler-guarded sweep)

After Phase 3, **no view** references the mirrors or pass-throughs. Now delete them:

1. In `AppModel.swift`, delete the 26 mirror `@Published var`s and their matching
   `assign(to:)` lines from `init` — **except** the ones still used: none should remain
   if Phases 1–3 are complete. Keep `appIsActive`, lifecycle state, and the manager
   `let`s.
2. Delete the now-unused pass-through methods in `AppModel+Repos.swift` and
   `AppModel+RepoActions.swift` (keep any still called by orchestration that stays).
3. Keep on AppModel: `selectAccount`, `startLifecycle`, `prepareForTermination`,
   `observeAppActivation`, `configure*`, `repoSearchBinding`/`addAccountActiveBinding`
   (if not moved), `localFolderState`, `run`.
4. `swift build` — **the compiler is the proof**: any deletion that something still used
   fails to compile. If it builds, nothing referenced it.
5. `grep -rn "model\." Sources/` — remaining hits should only be orchestration/lifecycle.

**Done when:** AppModel is ~composition + lifecycle only; `grep -c "@Published" AppModel.swift`
is down to just the genuinely-owned state (`appIsActive`, etc.); full suite + manual
smoke green.

---

## Per-phase workflow checklist

```
□ git checkout -b refactor/appmodel-facade   (Phase 0 only; stay on this branch)
□ make the phase's edits
□ swift build                      → must be clean
□ swift test                       → 235 tests must still pass (no view tests, but
                                      managers/parsers must be untouched/green)
□ ./build.sh && open ./GitNest.app → launch the real app
□ run THIS phase's manual test plan (below)
□ git add -A && git commit -m "refactor(appmodel): phase N — <views>"
□ checkpoint with the team / next session
```

Rollback for any phase: `git restore .` (uncommitted) or `git revert <phase commit>`.

---

## Manual test plans (per phase)

**Test fixtures you need:** at least **2 configured accounts**, each with **≥1 cloned
repo** and **≥1 not-yet-cloned repo**, and one cloned repo with **local uncommitted
changes** and **≥1 stash**. Keep the **Output panel open** to watch log reactivity.

> **What you're really testing:** not "does it compile" (the build proves that) but
> **does the UI still update** — the one thing the compiler can't verify. For each item,
> the "regression watch" is the symptom that means a view lost its observation.

### After Phase 0
1. Launch the app. **Expect:** identical to before — accounts list populates, you can
   select an account, load repos, see status chips. Nothing should look or behave
   different. *Regression watch:* a crash on opening any sheet/popover ⇒ a re-injection
   site was missed (re-check the `grep` in Phase 0 step 3).
2. Open every popover/sheet at least once: repo row **⋯ menu → Commit history**,
   **Changed files**, **Incoming commits**, **Stash**, the **Add account** sheet, the
   **Init project** / **Fork** sheets. **Expect:** each opens without crashing.

### After Phase 1 (CommitHistory / ChangeSummary / IncomingCommits)
1. **Commit history:** on a cloned repo, open the commit-history popover. **Expect:** the
   recent commits list renders. *Regression watch:* empty/blank popover that never fills.
2. **Changed files:** edit a file in a cloned repo (outside the app), wait for the next
   status sweep, open the changed-files popover. **Expect:** the changed file appears.
3. **Incoming commits:** on a repo that is *behind* its upstream, run **Fetch** from the
   row menu, then open the incoming-commits popover. **Expect:** the behind-commits list
   shows, and the row's behind/ahead badge (driven by `repoStatuses`) is current.

### After Phase 2 (LogOutput / ProjectSheets / Stash)
1. **Output log:** click **Load repos**. **Expect:** log lines stream in live; a failing
   action shows a `✗`/`⚠` line that stays pinned in the collapsed status. Click the
   **gh auth status** button in the Output header. **Expect:** raw status appended (and,
   per the redaction work, no token visible). *Regression watch:* log frozen / not
   appending ⇒ `LogOutputView` lost its `logStore` observation.
2. **Project sheets:** open **Init project**, pick a folder, start it. **Expect:** the
   busy spinner (driven by `isInitializingProject`) appears while it runs and clears
   after. Repeat for **Fork** (`isForkingProject`).
3. **Stash:** on a repo with local changes, open the stash popover → **Stash current
   changes**. **Expect:** the change badge clears, a stash badge appears, the stash list
   gains an entry. Then **Apply**, **Pop**, and **Drop** a stash. **Expect:** the list
   and badges update after each. *Regression watch:* list not refreshing after an action.

### After Phase 3 — test each heavy view right after its own sub-step
1. **RepoListView:** type in the **search field** → list filters live. Toggle **sort** by
   Name then Updated, and the direction arrows. **Expect:** order changes immediately.
   Run **Commit**, **Push**, **Delete local** from the list. **Expect:** rows reflect the
   result; cloned/▲▼ badges update. *Regression watch:* typing doesn't filter (search
   binding broken) or sort header doesn't reorder.
2. **SidebarView:** **select** different accounts → selection highlight moves and the
   repo pane switches. Watch the **status chips** (checking → ready/login-required).
   **Drag to reorder** accounts → order persists after relaunch. Open **Add account**,
   then **cancel** it → the in-flight `gh` poll is killed and the sheet dismisses
   cleanly (this exercises `addAccountActiveBinding`'s cancel logic — verify no hang).
   Trigger **Re-authenticate** and **Refresh**. *Regression watch:* chips stuck on
   "checking", or selection not updating.
3. **RepoRowView:** for a not-cloned repo, **Clone** → button shows busy/disabled while
   running, row flips to cloned. For a cloned repo: **Pull**, **Fetch**, **Push** →
   buttons disable during the action (busy state) and the status badge updates after.
   Open **in editor** / **in terminal**, **copy HTTPS/SSH/clone command** (check the
   clipboard), open **Issues/PRs/GitHub**. Click a row → selection highlight. *Regression
   watch:* buttons not disabling during an action (busy observation lost), or badge stale.
4. **ContentView:** overall window renders; the **search field** two-way binding works
   (type, clear); global loading indicators show during **Load repos** / refresh; trigger
   a **pull on a dirty repo** → the pull-warning alert appears and **dismiss** closes it.
   **Quit and relaunch** → confirm the app restored `gh`'s original active account
   (run `gh auth status` in a terminal before/after) and auto-refresh resumes.

### After Phase 4 (deletion sweep)
Re-run the **full** sequence above (Phase 0 item 2 + Phases 1–3 tests). Because nothing
should have changed behaviorally, every item must still pass. Plus:
1. `swift build` clean and `swift test` = 235 green.
2. `grep -rn "model\." Sources/` returns only lifecycle/orchestration calls
   (`startLifecycle`, `prepareForTermination`, `selectAccount`, `configure*`,
   the bindings) — no state reads or action pass-throughs.

---

## Definition of done
- `AppModel` contains only: the manager `let`s, `appIsActive` + lifecycle/activation
  state, orchestration (`selectAccount`), lifecycle (`startLifecycle`,
  `prepareForTermination`, `configure*`), the two write-through bindings, and the
  `localFolderState`/`run` helpers.
- All 26 mirrors + their `assign(to:)` lines and the pure pass-throughs are gone.
- Views declare the specific managers they use; sheets/popovers re-inject via
  `gitNestEnvironment`.
- Full test suite green; full manual smoke (above) green; `gh` account restore on quit
  verified.
