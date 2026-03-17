# wt tests

Unit tests for the `wt` binary using [bats-core](https://github.com/bats-core/bats-core).

## Setup

```bash
brew install bats-core
```

## Running

```bash
# All tests (from repo root)
bats test/wt.bats

# Single test by name substring
bats test/wt.bats --filter "resolve_target"

# Show output of passing tests
bats test/wt.bats --show-output-of-passing-tests

# TAP output for CI
bats test/wt.bats --formatter tap
```

## Coverage

| Area | Tests |
|------|-------|
| URL parsing (`wt pr`) | parses org/repo/number, trailing slash, invalid URL, missing PR number |
| `resolve_target` | bare repo (sibling inside bare dir), regular repo (parent-level sibling) |
| `_branch_pr_status` | no upstream → local-only, non-GitHub remote → none, merged PR, open PR, no PR |
| `post-checkout` hook | skips file checkout, skips existing branch (reflog > 1), logs new branch, TSV format, hook chaining |
| `wt setup` | writes hook, sets executable bit, sets `core.hooksPath`, idempotent |
| `wt rm` warnings | merged (no warn), open PR, local-only, multiple warnings, `--yes` skip, abort on N, proceed on y |
| `_gc_branches` | nothing to delete, merged vs open queuing, `--wt` filter |
| `cmd_gc` | unknown option |
| `cmd_branches` | no TSV hint, WORKTREE header, active vs removed label, column headers |
| `--help` | exits 0, stderr only, stdout empty for directive capture |
| Unknown command | non-zero exit, stderr only |
| Colors | disabled when stdout/stderr not a TTY |

## How it works

Tests source `bin/wt` with `__WT_TESTS=1`, which suppresses the top-level dispatch so all functions load without executing.

**Mock executables** — created in `$BATS_TEST_TMPDIR/bin` (prepended to `$PATH`) to intercept `git for-each-ref`, `git remote get-url`, and `gh pr list` with controlled outputs. `hash -r` is called after creating each mock to flush bash's command cache.

**Function overrides** — `_branch_pr_status`, `_do_delete_branches`, and `resolve_common_dir` are overridden inline in individual tests to isolate the function under test from external calls.

**Real git repos** — `init_bare_repo` creates an actual bare git repo for tests that exercise path resolution, branch creation, or worktree registration.

## Notes

- The macOS system bash (`/bin/bash`) is version 3.2, which bats uses for test subprocesses. The binary avoids `declare -A` for this reason; tests do too.
- `REAL_GIT` is captured in `setup()` before `$MOCK_BIN` is prepended to `$PATH` so mock fallbacks can invoke the real git without recursing into themselves.
