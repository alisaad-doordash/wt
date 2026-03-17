# wt — git worktree manager

A shell tool for managing git worktrees with bare-clone support, auto-init, and PR review workflows.

## Problem

Working across multiple branches simultaneously with `git stash` / `git checkout` is lossy and slow. Native `git worktree` solves this but has rough edges:

- **`cd` doesn't work from a subprocess.** `git worktree add` creates the directory, but switching into it requires a shell function — a raw binary can't `cd` the parent shell.
- **No auto-init.** Fresh worktrees need `npm install`, `brew bundle`, environment setup, etc. There's no hook for this, and running it in the foreground blocks you from working while it runs.
- **Bare-clone layout is manual.** The idiomatic worktree setup (one bare repo, all worktrees as siblings) requires knowing the right `git clone --bare` flags, fetch config, and worktree path conventions. There's no single command for it.
- **Stale branches accumulate.** After `wt rm`, branches remain locally even when their PRs are merged. With stacked PRs or frequent branch iteration, this builds up fast and `git branch` becomes noise.
- **Branch history is lost.** Once a worktree is removed, there's no record of which branches were worked on there, making retrospective cleanup harder.
- **PR review context-switches.** Opening a PR for review means stashing or switching branches in your current worktree, losing your place. There's no "just open this PR in isolation" command.

## Solution

`wt` wraps git worktree with conventions that remove all of the above friction:

- A **shell wrapper + directive protocol** lets the binary tell the shell to `cd`, run init, or launch Claude — solving the subprocess limitation cleanly.
- **Background init** runs `~/.config/wt/init/<repo>.sh` after creating a worktree, so `npm install` happens while you start working.
- **`wt clone` and `wt migrate`** set up the bare-clone layout in one command, with the right fetch config and initial worktree.
- **`wt gc`** queries GitHub via `gh` and bulk-deletes local+remote branches whose PRs are merged, with a confirmation prompt.
- **`wt setup`** installs a global `post-checkout` hook that logs new branches (name, worktree, timestamp) to a per-repo TSV, enabling `wt branches` to show full branch history grouped by originating worktree.
- **`wt pr`** finds or clones the repo, creates an isolated worktree for the PR, and launches a Claude review session — one command from URL to review.

## Installation

```zsh
# Symlink so edits to the repo take effect immediately
ln -sf "$(pwd)/bin/wt" ~/.local/bin/wt
ln -sf "$(pwd)/zsh/wt.zsh" ~/.config/wt/wt.zsh

# Shell integration (add to .zshrc)
source ~/.config/wt/wt.zsh

# Enable branch tracking
wt setup
```

## Commands

| Command | Description |
|---------|-------------|
| `wt new <name>` | Create a worktree and cd into it |
| `wt rm [--yes] [name]` | Remove a worktree; warns on open PRs or local-only branches |
| `wt cd <name>` | cd into an existing worktree |
| `wt ls` | List all worktrees |
| `wt init [name]` | Run init script for a worktree |
| `wt clone <url> [name]` | Bare clone + initial worktree, cd into it |
| `wt migrate` | Convert current regular repo to bare structure |
| `wt pr <github-pr-url>` | Open a PR review worktree and launch Claude |
| `wt setup` | Install global post-checkout hook for branch tracking |
| `wt gc [--yes] [--wt <name>]` | Delete branches for merged PRs |
| `wt branches` | Show branch history grouped by originating worktree |

## How it works

The `wt` binary emits a directive on stdout (e.g. `cd+init:/path`) which the `wt.zsh` shell wrapper intercepts to perform `cd`, background init, and Claude launch — actions that can't happen in a subprocess.

### Init scripts

Per-repo init scripts live at `~/.config/wt/init/<repo-name>.sh` and run in the background on `wt new` / `wt clone`.

### Branch tracking

`wt setup` installs a global `post-checkout` hook (via `core.hooksPath`) that appends a TSV entry to `<git-common-dir>/wt-branch-origin.tsv` whenever a new branch is created. `wt branches` reads this log to show branch history per worktree; `wt gc` uses it to scope cleanup to a specific worktree.

### PR review (`wt pr`)

`wt pr <github-pr-url>` finds or clones the repo under `~/Projects`, creates a detached worktree named `pr-<number>`, cds into it, and launches a Claude session with `/review-pr <url>` pre-loaded.
