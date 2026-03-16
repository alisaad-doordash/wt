# wt — git worktree manager

A shell tool for managing git worktrees with bare-clone support, auto-init, and PR review workflows.

## Installation

```zsh
# Binary
cp bin/wt ~/.local/bin/wt
chmod +x ~/.local/bin/wt

# Shell integration (add to .zshrc)
source ~/.config/wt/wt.zsh
# or copy zsh/wt.zsh to ~/.config/wt/wt.zsh
```

## Commands

| Command | Description |
|---------|-------------|
| `wt new <name>` | Create a worktree (new branch) |
| `wt rm [name]` | Remove a worktree (default: current) |
| `wt cd <name>` | cd into an existing worktree |
| `wt ls` | List all worktrees |
| `wt init [name]` | Run init script for a worktree |
| `wt clone <url> [name]` | Bare clone + initial worktree, cd into it |
| `wt migrate` | Convert current regular repo to bare structure |
| `wt pr <github-pr-url>` | Open a PR review worktree and launch Claude |

## How it works

The `wt` binary emits a directive on stdout (e.g. `cd+init:/path`) which the `wt.zsh` shell wrapper intercepts to perform `cd`, background init, and Claude launch — actions that can't happen in a subprocess.

### Init scripts

Per-repo init scripts live at `~/.config/wt/init/<repo-name>.sh` and run in the background on `wt new` / `wt clone`.

### PR review (`wt pr`)

`wt pr <github-pr-url>` finds or clones the repo under `~/Projects`, creates a detached worktree named `pr-<number>`, cds into it, and launches a Claude session with `/review-pr <url>` pre-loaded.
