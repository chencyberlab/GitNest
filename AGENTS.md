# AGENT.md — Engineering guide for GitNest

This document tells AI agents (and human contributors) **how to add features to
GitNest without degrading it**. GitNest is a small, deliberately well-factored
native macOS app. The bar here is not "make it work" — it is "make it indis­tin­guishable
from the code already in the repo." Read this whole file before writing code.

> **Golden rule:** Match the surrounding code. Every pattern below already exists
> in the codebase for a reason (usually a concurrency bug, a `gh` race, or a data-loss
> risk that was fixed once). Follow the established pattern instead of inventing a
> new one. If you think a pattern is wrong, say so explicitly and explain why —
> don't silently diverge.

---

## 1. What GitNest is

A single-window SwiftUI/AppKit macOS utility for managing a **local multi-account
GitHub setup**. It shells out to tools the user already has — `gh`, `git`, `ssh`,
`ssh-keygen` — and presents accounts, repos, and per-repo status in one window. It
**does not** embed libgit2, talk to the GitHub REST API over URLSession (except for
avatar images), or store tokens. Auth is delegated entirely to `gh` and the user's
SSH config.

- Language: **Swift 5.9**, SwiftPM (no Xcode project). Target: **macOS 13+**.
- No third-party dependencies. Foundation + SwiftUI + AppKit + Darwin only.
- Source: `Sources/GitNest/*.swift` (flat, one concern per file).
- Tests: `Tests/GitNestTests/*.swift` (XCTest).
- Build: `./build.sh` assembles `GitNest.app`. See README for arch/release options.

Read `README.md` for the user-facing behavior and the exact shell commands each
action runs — it is kept accurate and is the spec for what the app does.

---

## 2. Build, test, and format commands

Always run these before considering a change done:

```bash
swift build                 # must compile clean — no new warnings
swift test                  # full suite must stay green
```

Useful during development:

```bash
swift test --filter GitStashTests                 # one test class
swift test --filter testParsesMultipleStashes     # one test
swift-format lint --recursive Sources Tests       # style check (config: .swift-format)
swift-format format --in-place --recursive Sources  # auto-format
./build.sh && open ./GitNest.app                  # build + run the real app
```

- `swift build` writes to `.build/` (gitignored). `build.sh` uses a scratch dir
  **outside iCloud** (`~/Library/Caches/GitNest`) because SQLite `build.db` locking
  fails on iCloud-synced folders — don't change that.
- **Never commit `.build/`, `*.app/`, or `.plan/`** (already gitignored).

---

## 3. Architecture: the layers and the rule that holds them together

GitNest has a strict layering. Data and side effects flow **down**; UI observes
**up** through `AppModel`. Learn these four layers and which one your change belongs in.

```
┌─────────────────────────────────────────────────────────────────┐
│  VIEW LAYER  (SwiftUI)                                           │
│  ContentView, SidebarView, RepoListView, RepoRowView, *View,    │
│  *Sheet, Theme, Tooltip, ContentViewComponents                  │
│  • Reads @EnvironmentObject AppModel. Writes go THROUGH AppModel.│
│  • No shell calls, no business logic, no git parsing here.       │
└───────────────▲─────────────────────────────────────────────────┘
                │ @Published mirrors (one-way) + intent methods
┌───────────────┴─────────────────────────────────────────────────┐
│  FACADE  AppModel (@MainActor, ObservableObject)                │
│  • Owns the managers/coordinators, wires them in init().        │
│  • Re-publishes their @Published state via assign(to:).         │
│  • Thin proxy methods (AppModel+Repos, AppModel+RepoActions).   │
└───────────────▲─────────────────────────────────────────────────┘
                │ owns & calls
┌───────────────┴─────────────────────────────────────────────────┐
│  COORDINATION LAYER  (@MainActor, ObservableObject)             │
│  AccountManager, RepoManager, RepoActionCoordinator,            │
│  ProjectWorkflow, SetupCoordinator, AuthProcessController,      │
│  LogStore, AlertStore, GhChain                                  │
│  • State + orchestration. Decides WHEN/WHAT to run.             │
│  • Calls the domain layer through runBlocking / GhChain.        │
└───────────────▲─────────────────────────────────────────────────┘
                │ calls (pure, nonisolated, Sendable)
┌───────────────┴─────────────────────────────────────────────────┐
│  DOMAIN LAYER  (enums of static funcs — no instance state)      │
│  GitHub, GitConfig, AccountSetup, GitChanges, GitLog, GitStash, │
│  DeviceCode, Search, FileOps, EditorLauncher, TerminalLauncher  │
│  • Build argv, run via Shell, parse output. Pure + testable.    │
│  • Split: pure parser (testable) vs the Shell-calling wrapper.  │
└───────────────▲─────────────────────────────────────────────────┘
                │ Shell.run([...]) — the ONE process boundary
┌───────────────┴─────────────────────────────────────────────────┐
│  PROCESS LAYER  Shell.run (posix_spawn), TaskRunner.runBlocking │
└─────────────────────────────────────────────────────────────────┘
```

### The dependency-direction rule
- A layer may only call **downward**. Domain code must never import SwiftUI, touch
  `AppModel`, or know about UI state. UI must never call `Shell.run` or `GitHub.*`
  directly — it goes through `AppModel`.
- Managers receive their collaborators via **`init` injection** (see
  `AppModel.init()`), never reach for globals or singletons.

---

## 4. The concurrency model — this is where bugs live. Internalize it.

Everything that mutates observable state is `@MainActor`. Everything that blocks
(spawning processes, `waitpid`, file I/O) runs **off** the main actor and lands its
result back on it. Three primitives make this safe:

### 4a. `runBlocking` — for blocking work
`Shell.run` blocks its thread on semaphores/`waitpid`. Never call it directly from
the main actor. Wrap it:

```swift
let res = await runBlocking { GitHub.pull(at: path) }   // off-actor
logStore.report(res, ok: "pulled \(repo.name)")          // back on main actor
```

`runBlocking` (in `TaskRunner.swift`) dispatches to a dedicated concurrent queue,
**not** Swift's cooperative pool — a few concurrent `git pull`s must not starve
unrelated async work. The closure must be `@Sendable` and return a `Sendable` value.

### 4b. `GhChain` — for anything that touches the active `gh` account
`gh`'s active account is **global on-disk state**. Two operations that each do
"switch account → use it" will flip the account out from under each other. Any code
path that runs `gh auth switch` (directly or via `ensureActiveAccount`) **must** be
serialized through `GhChain`:

```swift
// Serializes; runs in call order, one at a time.
let result = await ghChain.serialized { GitHub.listRepos(owner: owner) }

// Same, but snapshots the active account first and restores it afterward.
// Use this for one-off operations that shouldn't leave gh pointing elsewhere.
let res = await ghChain.serializedPreservingActiveAccount {
    initAndPushProject(plan, visibility)
}
```

If you add a feature that lists/creates/forks repos or verifies an account, it goes
through `GhChain`. Local-only `git` operations (status, commit, stash, fetch of a
cloned repo) do **not** need the chain — they don't touch `gh`'s active account.

### 4c. Cancellable processes via `Shell.ProcessHandle`
Long-lived commands (`gh auth login --web` polls GitHub for minutes) must be
cancellable so dismissing the UI doesn't wedge the `GhChain`. Pass a
`ProcessHandle`; `AuthProcessController` owns the in-flight one. See
`SetupCoordinator.addAccountSignIn` for the full pattern.

### 4d. Timers, sessions, and generations
Background work that can be superseded uses a **session/generation token** so a
stale result can't clobber fresh state. Two existing idioms — copy them, don't reinvent:
- **Session UUID** (`AccountManager.accountStatusSessionID`, `SetupCoordinator.addAccountSessionID`):
  capture it before async work, re-check `isCurrent…Session(session)` after each
  `await` before writing state.
- **Generation counter** (`RepoManager.statusTimerGeneration`): a timer Task clears
  its own `var` on exit only if the generation still matches, so stop+start races
  can't nil out a live timer.

> Every time you `await` in a `@MainActor` method, the world may have changed
> (account switched, sheet dismissed, account removed). **Re-validate before you
> write.** Most of the subtle correctness comments in this codebase are about exactly
> this. The `accountManager.selectedAccount?.alias == alias` checks scattered through
> `RepoManager` are this pattern — preserve them.

---

## 5. Domain layer conventions (the part you'll most often extend)

### 5a. Split pure parsing from the shell call
This is the single most important domain pattern. A git operation is **two pieces**:
a pure, unit-testable parser, and a thin `Shell`-calling wrapper that's an extension
on `GitHub`. See `GitChanges.swift`, `GitLog.swift`, `GitStash.swift`:

```swift
enum GitStash {                                   // PURE — no Shell, fully testable
    static func parse(listZ output: String) -> [GitStashEntry] { ... }
}

extension GitHub {                                // WRAPPER — runs Shell, returns Result
    static func stashList(at path: String) -> Result<[GitStashEntry], CommandError> {
        let res = Shell.run(["git", "--no-optional-locks", "-C", path,
                             "stash", "list", "-z", "--format=\(GitStash.listFormat)"])
        guard res.ok else {
            let raw = (res.stderr.isEmpty ? res.stdout : res.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(CommandError(message: raw.isEmpty ? "git stash list failed" : raw))
        }
        return .success(GitStash.parse(listZ: res.stdout))
    }
}
```

When you add a git read, you write a parser (tested) + a wrapper (returns
`Result<…, CommandError>`). **Always add the parser test.**

### 5b. Run git with machine-readable, robust flags
- **`-z` / NUL termination** for any list output (`status`, `log`, `stash list`).
  `-z` is never quoted/escaped, so filenames with spaces, newlines, `" -> "`, or
  non-ASCII are unambiguous. Pair with a control-char field separator (`%x1f`,
  ASCII Unit Separator) inside records. Never parse git's human-formatted output.
- **`--no-optional-locks`** (sets `GIT_OPTIONAL_LOCKS=0`) for every **read** that
  runs on the background scan, so it can't collide with a concurrent
  commit/add/pull and produce a spurious `index.lock` error. Mutating commands
  (commit, push) omit it.
- **`-C <path>`** to target a repo — never `cd`.
- Errors: prefer `stderr` then `stdout`, trim, and provide a non-empty fallback
  message.

### 5c. Domain types are `Sendable` value types
Models (`Repo`, `Account`, `RepoStatus`, `GitCommit`, `GitStashEntry`,
`GitFileChange`, `ProjectInitPlan`) are `struct`s marked `Sendable`. `Repo` and
`Account` precompute `searchableHaystacks` (lowercased) so the search loop doesn't
reallocate on every keystroke — keep that optimization if you add searchable fields.

### 5d. Validate untrusted input before it reaches `git`/`gh`
`RepoReference.parse`, `isValidOwner`, `isValidRepo`, and `sanitizedRepoName`
(`StringHelpers.swift`) exist so that user-typed addresses and folder names can't
become surprising arguments. Reuse them; don't hand a raw string to a command.

---

## 6. Coordination layer conventions

- **`@MainActor final class …: ObservableObject`** with `@Published` state.
  Collaborators injected via `init`. `AppModel` wires everyone together and mirrors
  their `@Published` properties up with `assign(to: &$x)` (one-way).
- **UI write-through, not mirror-mutation.** Some `AppModel` `@Published` properties
  are *one-way mirrors* of a manager's source of truth (`selectedRepo`, `repoSearch`,
  `addAccountActive`). The UI reads the mirror but must **write through** to the
  owning manager via an intent method or a custom `Binding` (see the
  `repoSearchBinding` / `addAccountActiveBinding` and the "UI write intents" comment
  in `AppModel.swift`). Mutating a mirror directly does nothing — and a naive two-way
  Combine binding caused an infinite `willSet` loop that crashed the app. Don't redo that.
- **Mutating per-repo actions go through `RepoActionCoordinator.beginRepoAction` /
  `finishRepoAction`** (use `defer { finishRepoAction(context) }`). This sets the
  busy state that disables the row's buttons and serializes actions per-folder. Every
  new mutating repo action follows the existing `clone`/`pull`/`push`/`commit` shape:
  begin → log "doing…" → `runBlocking { GitHub.x }` → `logStore.report` → refresh status.
- **Re-confirm destructive preconditions at action time.** Before trashing a folder
  or restoring/dropping a stash, re-check state immediately before acting (the UI
  status is up to ≤10s stale). See `deleteLocalFolder` (re-checks `.cloned`) and the
  stash `expectedHash` re-validation in `restoreStash`/`stashDrop`.
- **Account-explicit actions.** Repo actions take an optional `Account?` and fall
  back to `selectedAccount`, because an action can finish after the user switches
  accounts. Snapshot the target account's state via `repoManager.cloneState(for:)`
  and commit back to its cache — don't assume the visible account is still the target.

---

## 7. Logging, errors, and user-facing messages

- All command output and progress goes to **`LogStore`** (the Output pane). Use
  `logStore.append("…")` for progress and `logStore.report(result, ok: "…")` for
  command results. `report` prefixes `✓`/`✗`; `append` lines starting with `✗` or
  `⚠` mark `lastWasError` (the collapsed status line stays pinned on problems).
- Use the established glyphs: `✓` success, `✗` failure, `⚠` warning, `ℹ` info.
- **Errors are values, not crashes.** Return `Result<…, CommandError>` or a
  `ShellResult` and surface a friendly message. The `.swift-format` rules **forbid**
  `NeverForceUnwrap`, `NeverUseForceTry`, `NeverUseImplicitlyUnwrappedOptionals` —
  no `!`, no `try!`, no implicitly-unwrapped optionals. Use `guard let … else`,
  `UseEarlyExits`.
- User-facing copy is plain, specific, and says what happened to *their* data
  ("your stash was kept", "local files were not force-replaced"). Match that tone.

---

## 8. Safety & security rules (non-negotiable)

These reflect real safeguards already in the code. Preserve them; never weaken them.

1. **No shell string interpolation. Ever.** `Shell.run` takes an **argv array** and
   uses `posix_spawn` with **no intermediate shell**, so metacharacters are literal
   bytes. Never build a command string and pass it to `sh -c` for user-influenced
   data. (`ShellTests.testArgumentsAreNotShellInterpreted` pins this.)
2. **Back up before editing user config.** `~/.ssh/config`, `~/.gitconfig`, and
   per-account configs get a timestamped backup before any edit, and edits roll back
   on failure so a failed run is a true no-op (see `AccountSetup.writeGitConfig`).
3. **Never overwrite an SSH key.** Existing keys are reused (they may already be on
   GitHub). New private keys are written `0600` atomically (`writePrivately`).
4. **Deletes go to Trash, never `rm`.** Local "delete" is `FileManager.trashItem`
   (`FileOps.moveToTrash`) and never touches the GitHub repo.
5. **Refuse to act on the wrong account.** Before creating a remote, verify
   `gh api user --jq .login` matches the selected account (`ensureActiveAccount`).
6. **Scrub the environment for git.** `Shell.sanitizedEnvironment` removes inherited
   `GIT_*` overrides and sets `GIT_TERMINAL_PROMPT=0` so commands fail fast instead
   of hanging on a prompt. SSH host keys are pinned (`StrictHostKeyChecking=yes` +
   bundled `known_hosts`).
7. **Fetch/refresh never touches the working tree.** Background refresh uses `git
   fetch` (remote-tracking refs only) — it must never merge or modify files. Pull is
   blocked when the tree is dirty.

---

## 9. Testing — required, not optional

Tests are a first-class part of every change. The suite is ~2,400 lines covering
parsers, scheduler math, DI-seam orchestration, and `Shell` itself.

### What to test
- **Every new parser** gets a test (table-style: feed crafted output, assert the
  struct). Include the awkward cases the existing tests do: trailing NUL, embedded
  separators/punctuation, malformed/short records, empty input. See `GitStashTests`,
  `GitChangesTests`, `GitLogTests`.
- **Every new orchestration path** gets a test using the **closure-injection seam**,
  not the network. Coordinators take their side-effecting dependencies as injectable
  `@Sendable` closures with production defaults — tests pass fakes and assert on
  call counts / outcomes. See `ProjectWorkflow.init` (defaults to `GitHub.*`, tests
  pass stubs) and `ForkProjectTests` / `InitProjectTests` / `RepoListTests`
  (`GitHub.listRepos` takes `ensureActive`/`ownedRepos`/… as parameters for this).
- **Pure logic** (scheduler intervals, sorting/filtering, validation, hex parsing)
  gets direct unit tests. `RefreshSchedulerTests` pins the API-budget math the
  README documents — that class is the template for "lock in a formula so it can't
  silently regress."

### How to write them
- `@testable import GitNest`. Mirror the file under test: `Foo.swift` → `FooTests.swift`.
- Test names are full sentences describing the guarantee:
  `testBackgroundAccountIsFlooredToFiveMinutes`, `testToleratesTrailingNUL`.
- Mark the class (or method) `@MainActor` when touching main-actor types; use
  `await Task.yield()` to let Combine `assign(to:)` propagate before asserting (see
  `CoordinatorTests.testAppModelMirrorsRepoActionBusyState`).
- For concurrency-shared counters in fakes, use a locked box (`LockedCounter` in
  `ForkProjectTests`), not a bare `var`.
- Prefer the injection seam over hitting real `git`. Where a test genuinely needs a
  real repo, create one in `NSTemporaryDirectory()` and clean it up in `defer`.

### The DI seam — add one when you add orchestration
If your new coordinator calls a domain function that hits the network or mutates the
filesystem, expose it as an injected closure so it's testable:

```swift
init(...,
     doThing: @escaping @Sendable (Input) -> Result<Output, CommandError> = {
         GitHub.doThing($0)              // production default
     }) { self.doThing = doThing; ... }
```

Then a test constructs the coordinator with a stub and asserts behavior without a
single real process. **A new orchestration path without a test is incomplete.**

---

## 10. Code hygiene & style

The `.swift-format` config is enforced — read it. Highlights:

- 4-space indent, 120-col lines, `lowerCamelCase`, `CapitalizedTypes`,
  `OrderedImports`, no semicolons, no force-unwrap/try/IUO, early exits, omit
  explicit `return` in single-expression bodies, prefer `for` over `forEach`.
- **One concern per file**, named after the type it defines. Keep the flat structure.
- **Comments explain *why*, not *what*.** This codebase's comments are excellent and
  load-bearing — they record the race or data-loss bug a line prevents. When you
  touch such a line, keep (and update) the comment. When you add a non-obvious
  safeguard, leave the same kind of comment. Don't add narration that restates the code.
- Use `// MARK:` sections to group members, as existing files do.
- Prefer small `enum`s of `static func`s for stateless domain logic (no instances to
  manage); `final class … ObservableObject` only when you need observable state.
- Keep view bodies declarative and free of logic — push decisions into the model.
  Reuse `Theme` tokens and the shared button styles (`PrimaryButtonStyle`,
  `SubtleButtonStyle`, `IconChipButtonStyle`); never hardcode colors (light/dark must
  both read correctly) and use `.tooltip(_:)`, not `.help(_:)`.

---

## 11. Worked example — adding a new git operation end to end

Suppose you're asked to add a **"Discard local changes" (git restore)** action to a
cloned repo row. Here is the full, idiomatic path:

1. **Domain (`GitChanges.swift` or a new `GitRestore.swift`):** add the `Shell`
   wrapper as an `extension GitHub`, returning `ShellResult`. Use an argv array and
   `-C path`. (It mutates the tree, so no `--no-optional-locks`.)
   ```swift
   extension GitHub {
       static func discardChanges(at path: String) -> ShellResult {
           Shell.run(["git", "-C", path, "restore", "--staged", "--worktree", "."])
       }
   }
   ```
   If there's any output to parse, add a pure parser enum + a parser test.

2. **Coordinator (`RepoActionCoordinator`):** add a method following the
   begin→run→report→refresh shape. It's **destructive**, so confirm the precondition
   and recheck state; the actual confirmation dialog is the UI's job.
   ```swift
   func discardChanges(_ repo: Repo, in account: Account? = nil) async {
       guard let context = beginRepoAction(repo, in: account) else { return }
       defer { finishRepoAction(context) }
       let account = context.account, path = context.path
       logStore.append("Discarding changes in \(repo.name)…")
       let res = await runBlocking { GitHub.discardChanges(at: path) }
       logStore.report(res, ok: "discarded changes in \(repo.name)")
       await repoManager.refreshStatuses(for: account)
   }
   ```
   It's local-only → **no `GhChain`**. (If it touched `gh`, it would need it.)

3. **Facade (`AppModel+RepoActions.swift`):** add the one-line proxy.
   ```swift
   func discardChanges(_ repo: Repo, in account: Account? = nil) async {
       await repoActionCoordinator.discardChanges(repo, in: account)
   }
   ```

4. **View (`RepoRowView` / its menu):** add the button, gated on `isCloned` and
   `!model.isRepoActionBusy(repo)`, with a `.tooltip`, theme styling, and — because
   it's destructive — a confirmation sheet/alert wired the way `deleteTarget` /
   `pushTarget` are in `ContentView`. Call `Task { await model.discardChanges(repo) }`.

5. **Tests:** parser test if you parse anything; a coordinator test via the injection
   seam (or a temp-repo integration test) asserting it runs and refreshes. Run
   `swift build && swift test`.

This is the same spine every existing action follows. Stay on it.

---

## 12. Checklist before you call a change done

- [ ] `swift build` is clean (no new warnings) and `swift test` is green.
- [ ] Code lives in the right layer; dependencies point only downward.
- [ ] Anything touching `gh`'s active account goes through `GhChain`; anything
      blocking goes through `runBlocking`; state is re-validated after every `await`.
- [ ] New parser → has a test. New orchestration → has a test via the injection seam.
- [ ] No `!` / `try!` / IUO; errors are `Result`/`ShellResult` with friendly messages.
- [ ] No shell string interpolation; user input validated before reaching `git`/`gh`.
- [ ] Config edits are backed up + reversible; deletes go to Trash; keys never overwritten.
- [ ] UI uses `Theme` tokens, shared button styles, `.tooltip`, and writes through
      `AppModel` (not mirror-mutation).
- [ ] Comments explain the *why* of any non-obvious safeguard; existing load-bearing
      comments preserved.
- [ ] `README.md` updated if user-facing behavior or a documented command changed.

When in doubt, find the closest existing feature, read it top to bottom, and mirror it.
```
