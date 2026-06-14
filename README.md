# GitNest
![GitHub watchers](https://img.shields.io/github/watchers/chencyberlab/GitNest) 
![GitHub Repo stars](https://img.shields.io/github/stars/chencyberlab/GitNest) 


A tiny native macOS (SwiftUI) GUI for a local multi-account GitHub setup. It
shows your configured accounts, which account each SSH key authenticates as,
and lets you browse, clone, initialize, commit, push, and clean up repos from a
single window.

## What it shows / does (important)

- **Accounts** (left): discovered automatically from `~/.gitconfig` `includeIf`
  rules plus the per-account `~/.gitconfig-<account>` files. Shows name, email,
  SSH host alias, and an `ssh -T` auth check (`Hi <account>!`). A globe button on
  each account opens its GitHub profile (`github.com/<account>`) in your default
  browser.
- **Add account** (the ＋ in the ACCOUNTS header): a step-by-step wizard that sets
  up a new account for you instead of editing config by hand — sign in (device
  code), pick the local repo folder, generate a **dedicated** SSH key, guide its
  public key onto GitHub (shown in a click-to-copy field so you can verify exactly
  what you paste), then write the config and verify. It automates the manual
  "Prerequisites / new device setup" steps below, takes **timestamped backups** of
  `~/.ssh/config` and `~/.gitconfig` before editing, stores portable `~/…` paths,
  and never overwrites an existing key.
- **gh auth status** (on demand): click the **gh auth status** button in the
  Output panel header to dump the full `gh auth status` (which accounts `gh` is
  logged into) into the log when you want it. Day-to-day the per-account cards
  already show ready / login-required, so the raw text is there only when needed.
- **Repos** (main): click **Load repos** to list everything that account can
  reach via `gh` — both the repos it **owns** and repos it has been added to as a
  **collaborator** (owned by another account). Each row shows the repo
  name/description, visibility, a last-updated date and time, and whether it is
  remote-only or cloned locally. Collaborator repos get a grey two-people icon
  (`person.2`) next to the name, with the owner login in its tooltip, so you can
  tell your own repos from ones shared with you at a glance. The **Updated**
  column is formatted with your Mac's locale and time zone, so the field order,
  separators, and 12/24-hour clock follow your region (e.g. `2/6/2026, 4:40 pm`
  in AU vs `6/2/2026, 4:40 PM` in the US).
- **Auto-refresh** (sidebar, bottom): optionally re-lists repos in the background
  on a set interval — Off / 30s / 2m / 5m / 10m, remembered across launches
  (`@AppStorage("repoAutoRefreshSeconds")`). It refreshes **every account you've
  loaded at least once**: the visible account updates on screen, the others update
  silently in their cache so they're ready the moment you switch. The cadence
  **adapts to stay light on the GitHub API**:
  - the account you're **viewing** uses your chosen interval;
  - accounts you're **not** viewing refresh at most **once every 5 minutes** (and
    immediately on switch if they've gone stale), so adding accounts doesn't
    multiply background traffic; and
  - **large repo lists stretch their interval** (~1× per 500 repos, i.e. a
    ~2,000-repo account refreshes ~4× less often), so the request rate per account
    stays roughly flat no matter how big the list grows.

  Each account has its own `gh` token and therefore its own ~5,000-request/hour
  budget, so the accounts never share a limit. A failed refresh keeps the cached
  list and simply retries next interval — it never stops on its own. Repo-list
  refreshes use paginated `gh api user/repos` calls plus local `git status`, and
  for cloned repos they also run a safe `git fetch` against the upstream remote
  so ahead/behind badges reflect current GitHub state. Fetch updates
  remote-tracking refs only; it does not merge or touch your working files.
- **Search** (above the repo list): a wild-search box filters the loaded repos as
  you type. It matches across the repo name, owner/name, and description and
  supports plain substrings, fuzzy subsequence matches (e.g. `mgm` →
  `multi-git-manager`), and glob wildcards (`*`, `?`, e.g. `m*ger`). Multiple
  space-separated terms are all required. A counter shows matches vs total, and
  each account keeps its own search text while you switch between accounts.
- **Remote-only repos**: clone into the selected account folder.
- **Cloned repos**: use the **Open...** menu to open the local folder in Finder,
  the GitHub repo in your browser, your configured GUI editor, or your configured
  terminal. You can also pull, commit all, push after confirmation, or move the
  local folder to Trash after confirmation. Local delete does not touch GitHub.
- **Status indicators**: each cloned row shows, at a glance, whether it has work
  pending — an amber `✎` with a count for uncommitted/untracked files, a purple
  `↑` for local commits not yet pushed, an amber `↓` for commits behind the
  remote, and a green check when the clone is current after a live upstream fetch.
  If local and remote both have commits, a warning badge marks the repo as
  diverged. The drive icon also turns amber whenever there is anything to commit,
  pull, push, or fix before treating the clone as current. Statuses refresh after
  every in-app action and automatically every 10 seconds, so changes you make in
  another editor or terminal appear on their own within ~10s. The 10-second scan
  stays local-only; repo-list loads and repo-list auto-refreshes perform the
  upstream fetch check.
- **Init project**: choose a local folder, copy it into the selected account's
  GitHub folder if needed, create a private/public GitHub repo, push it, then
  refresh the repo list. Optional cleanup can move the original selected folder
  to Trash after a successful upload.

Every action button has a tooltip explaining what it does. All command output
appears in the **Output** pane at the bottom.

The UI uses shared adaptive colors and typography from `Theme.swift`, so light
and dark modes both read correctly. The appearance switcher in the sidebar header (next to
"ACCOUNTS") is remembered across launches via `@AppStorage("appearancePreference")`.

## How it works under the hood

It shells out to tools you already have:

| Action | Command run |
| --- | --- |
| List repos | `gh api user/repos?affiliation=owner&per_page=100 --paginate --slurp` after `gh auth switch -u <account>`, merged with `gh api user/repos?affiliation=collaborator&per_page=100 --paginate --slurp` for shared repos — also run automatically on the repo auto-refresh interval |
| Auth check | `ssh -T git@github-<account>` |
| Clone | `git clone https://github.com/OWNER/REPO.git <account-folder>/REPO` |
| Init project | `gh auth switch -u <account>`, verify active `gh` login, `git init`, `gh repo create`, `git push -u origin <branch>` |
| Pull | `git -C <local-path> pull` |
| Status check | `git --no-optional-locks -C <local-path> status --porcelain --branch`; repo-list loads also run `git --no-optional-locks -C <local-path> fetch --prune --quiet <upstream-remote>` first so ahead/behind is compared with current GitHub state. The frequent 10-second scan remains local-only. |
| Open local folder/editor/terminal | Finder uses `NSWorkspace.open`; configured editors and terminals use `/usr/bin/open -a <app> <local-path>` |
| Commit | `git -C <local-path> add -A && git -C <local-path> commit -m "<msg>"` |
| Push | `git -C <local-path> push` after confirmation |
| Delete local | Moves `<local-path>` to Trash via `FileManager.trashItem` |

For Init project, the app refuses to create a remote repo unless `gh api user
--jq .login` matches the selected account. New init remotes use the selected
account's SSH alias, for example:

```text
git@github-work:work-user/GitNest.git
```

### Auto-refresh scheduling

A single background timer wakes every interval you pick (Off / 30s / 2m / 5m /
10m). It is anchored to app launch — or to the last time you changed the interval —
**not** to when you press **Load repos**. On each wake it considers **every account
you have loaded at least once** (loading an account via **Load repos** is what opts
it into auto-refresh) and refreshes only the accounts that are *due*, one at a time,
with the account you're currently viewing refreshed **last** so `gh`'s active
account ends up back on the one you're looking at.

Whether an account is "due" is decided by its **effective interval** — the minimum
gap enforced between refreshes of *that* account:

```text
effective interval = base × ceil(repoCount / 500)

base = your chosen interval              ← the account you're viewing
     = max(your interval, 5 minutes)     ← every other ("background") account
```

So two rules stack on top of the interval you pick:

1. **Background floor — 5 minutes.** Any account you are *not* currently viewing is
   refreshed at most once every 5 minutes, no matter how short an interval you set.
   That's why a 30-second setting still only polls your *other* accounts every
   5 minutes, so adding accounts never multiplies background traffic. The account on
   screen is unaffected and keeps your chosen interval. (This 5-minute *floor* is a
   different thing from the picker's 5-minute *default* value — they just happen to
   be the same number.)
2. **Size backoff — ~1× per 500 repos.** An account's interval is stretched in
   proportion to its repo count, so the request rate per account stays roughly flat
   regardless of list size:

   | Repo count | Multiplier |
   | --- | --- |
   | ≤ 500 | ×1 |
   | ≤ 1,000 | ×2 |
   | ≤ 1,500 | ×3 |
   | ≤ 2,000 | ×4 |

A **background refresh updates only that account's cache** — the on-screen list, the
"Refreshing…/refreshed just now" status line, and the cloned/status badges all
belong to the *visible* account, so other accounts refresh with no visible flicker.
When you **switch** to an account it is treated as visible and refreshed immediately
if it has gone stale past its (now visible) effective interval, so you always land
on fresh data.

**Worked example** — two loaded accounts, interval set to **30s**:

- **Account A** (on screen, 120 repos): effective interval = 30s × 1 = **30s**, so
  it refreshes on every wake (~30s) and you watch it update live.
- **Account B** (in the background, 800 repos): effective interval =
  `max(30s, 5m) × 2` = **10 minutes**, so it quietly refreshes its cache about every
  10 minutes. Switch to B and — if its last refresh was more than 60s ago (30s × 2)
  — it refreshes instantly on switch.

A failed background refresh keeps the cached list, logs the error to the **Output**
pane, and tries again at the next interval; it never stops the timer. Refreshes do
not merge or edit working files: repo-list loads use paginated `gh api user/repos`
calls, local `git status`, and upstream `git fetch` for cloned repos. The two
tuning constants live in `AppModel.swift`: `backgroundRefreshFloorSeconds` (the
5-minute floor) and the `ceil(repoCount / 500)` size step in
`effectiveRefreshInterval`.

## Build & run

Requires macOS 13 or later, the Swift toolchain, and `gh`, `git`, and `ssh` on
`PATH`. Installing Xcode or the Xcode command-line tools is enough for Swift:

```bash
xcode-select --install
```

Build the app for the Mac you are currently using:

```bash
./build.sh
open ./GitNest.app
```

`build.sh` compiles into `~/Library/Caches/GitNest` and only assembles the final
`.app` in the project folder. The scratch path is deliberately outside iCloud:
SQLite `build.db` locking fails on iCloud-synced folders such as `~/Desktop` with
a "disk I/O error". Override it when needed:

```bash
SCRATCH_PATH=/tmp/gitnest-build ./build.sh
```

### Architecture builds

By default, `./build.sh` uses `BUILD_ARCH=native`, which matches the Mac running
the build. On Apple Silicon that produces an `arm64` app; on Intel that produces
an `x86_64` app.

Use `BUILD_ARCH` to choose the release target:

```bash
BUILD_ARCH=arm64 ./build.sh       # Apple Silicon only
BUILD_ARCH=x86_64 ./build.sh      # Intel only
BUILD_ARCH=universal ./build.sh   # Apple Silicon + Intel in one app
```

Confirm what you built:

```bash
lipo -archs GitNest.app/Contents/MacOS/GitNest
```

### Package a release zip

Attach a zip to a GitHub release, not the raw `.app` folder:

```bash
BUILD_ARCH=universal SCRATCH_PATH=/tmp/gitnest-build ./build.sh
ditto -c -k --keepParent GitNest.app GitNest-v1.0.0-macos-universal.zip
shasum -a 256 GitNest-v1.0.0-macos-universal.zip > GitNest-v1.0.0-macos-universal.zip.sha256
```

The local build is ad-hoc signed. It is fine for local testing and small manual
releases, but downloaded copies may show macOS Gatekeeper warnings. A polished
public release should use Developer ID signing, notarization, and a real reverse
DNS bundle identifier, for example:

```bash
BUNDLE_IDENTIFIER=com.example.GitNest BUILD_ARCH=universal ./build.sh
```

### Users building from source

Users can clone the repository and run the same local build:

```bash
git clone https://github.com/OWNER/GitNest.git
cd GitNest
./build.sh
open ./GitNest.app
```

They should build `native` unless they specifically need to produce a release
for a different Mac architecture. A universal build is useful for maintainers who
want to publish a single zip that works on both Apple Silicon and Intel Macs.

## Prerequisites / new device setup

This app depends on your local multi-account Git/SSH setup. On a new Mac or
fresh device, set these up before launching the app.

> **Tip:** Most of the per-account work below is now automated by the in-app
> **Add account** wizard (the ＋ in the ACCOUNTS header) — once the CLI tools in
> step 1 are installed, the wizard handles the SSH key, `~/.ssh/config`, the
> `includeIf` rule, the per-account gitconfig, the folder, and verification. The
> manual steps below remain as reference and for understanding what it writes.

### 1. Install command-line tools

```bash
xcode-select --install       # if Swift/git tools are not installed yet
brew install gh              # if GitHub CLI is missing
gh --version
git --version
ssh -V
```

### 2. Create or copy one SSH key per GitHub account

Example accounts:

| Account | SSH key | SSH host alias | Local dev folder |
| --- | --- | --- | --- |
| `work-user` | `~/.ssh/id_ed25519_work` | `github-work` | `~/Developer/github-work/` |
| `personal-user` | `~/.ssh/id_ed25519_personal` | `github-personal` | `~/Developer/github-personal/` |

Create fresh keys if needed:

```bash
ssh-keygen -t ed25519 -C "work-user no-reply email" -f ~/.ssh/id_ed25519_work
ssh-keygen -t ed25519 -C "personal-user no-reply email" -f ~/.ssh/id_ed25519_personal
```

Add each `.pub` key to the matching GitHub account:

```text
GitHub -> Settings -> SSH and GPG keys -> New SSH key
```

### 3. Add SSH host aliases

Create or update `~/.ssh/config`:

```sshconfig
Host github-work
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_work
    IdentitiesOnly yes
    AddKeysToAgent yes
    UseKeychain yes

Host github-personal
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519_personal
    IdentitiesOnly yes
    AddKeysToAgent yes
    UseKeychain yes
```

Verify both accounts:

```bash
ssh -T git@github-work
ssh -T git@github-personal
```

Each command should greet the matching GitHub username.

### 4. Create the account dev folders

```bash
mkdir -p ~/Developer/github-work
mkdir -p ~/Developer/github-personal
```

The folder decides which Git identity and SSH key are used. Clone or initialize
repos under the folder for the account that owns them.

### 5. Configure global Git include rules

Add account-folder rules to `~/.gitconfig`:

```ini
[user]
    name = personal-user
    email = 654321+personal-user@users.noreply.github.com

[includeIf "gitdir:~/Developer/github-work/"]
    path = ~/.gitconfig-work

[includeIf "gitdir:~/Developer/github-personal/"]
    path = ~/.gitconfig-personal
```

### 6. Create per-account Git config files

`~/.gitconfig-work`:

```ini
[user]
    name = work-user
    email = 123456+work-user@users.noreply.github.com

[url "git@github-work:"]
    insteadOf = https://github.com/
    insteadOf = git@github.com:
```

`~/.gitconfig-personal`:

```ini
[user]
    name = personal-user
    email = 654321+personal-user@users.noreply.github.com

[url "git@github-personal:"]
    insteadOf = https://github.com/
    insteadOf = git@github.com:
```

These `insteadOf` rules are what let plain GitHub URLs route through the correct
SSH key when a repo lives in the matching account folder.

### 7. Log in to GitHub CLI for each account

```bash
gh auth login          # complete as work-user
gh auth login          # run again, complete as personal-user
gh auth status
```

The app runs `gh auth switch -u <account>` before account-specific operations.
For Init project, it also verifies that `gh api user --jq .login` matches the
selected account before creating any remote repo.

### 8. Final sanity checks

From a repo inside an account folder:

```bash
git config user.email
git config --show-origin user.email
git ls-remote --get-url origin
ssh -T git@github-personal      # or github-work
```

Expected:

- `user.email` comes from the matching `~/.gitconfig-<account>` file.
- Remote URLs resolve to `github-<account>`.
- SSH greets the same account that owns that folder.

## Scope

List + search + clone + init project + pull + commit + push + local/remote status
indicators + local folder cleanup. It does not manage branches or tokens. Auth is
delegated to `gh` and your SSH setup.

Notes:

- **Commit** stages everything (`git add -A`) and needs a message.
- **Push** asks for confirmation first, then runs a plain `git push`.
- **Init project** creates the remote repo and runs the first `git push -u`
  automatically.
- **Delete local** moves the local clone to Trash only; it does not delete the
  GitHub repo.
- **Status badges** (`✎` changes / `↑` ahead / `↓` behind / green check) come
  from `git status`. Repo-list loads first run `git fetch` for cloned repos with
  an upstream, so behind/diverged state reflects current GitHub state. The
  10-second status scan stays local-only and adds no network or rate-limit cost.
- **Repo auto-refresh** (sidebar) keeps every loaded account current in the
  background; the picker defaults to a **5-minute interval** (choose **Off** to
  disable). The account you're viewing honors the chosen interval; background
  accounts (floored to once per 5 minutes) and large repo lists back off
  automatically, keeping it well within GitHub's per-account API limits. It never
  merges or edits working files, so it won't create merge conflicts. See
  [Auto-refresh scheduling](#auto-refresh-scheduling) for the full logic.
- Any error shows in the Output pane.

## License

GitNest is free for personal, non-commercial use. Commercial use, redistribution,
or redevelopment based on this project requires a separate paid license from the
project owner. See [LICENSE](LICENSE) for details.
