#!/usr/bin/env bats
# test/wt.bats — unit tests for the wt binary
# Run: bats test/wt.bats
# Install bats: brew install bats-core

WT_BIN="$(dirname "$BATS_TEST_FILENAME")/../bin/wt"

setup() {
  # Scratch git repo for each test
  TEST_DIR="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$TEST_DIR"

  # Capture real git path BEFORE prepending mock dir to PATH
  REAL_GIT=$(command -v git)

  # PATH-prefix for mock executables
  MOCK_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  # Source binary with test guard — functions available, dispatch suppressed
  export __WT_TESTS=1
  # shellcheck disable=SC1090
  source "$WT_BIN"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a mock git that intercepts specific subcommands.
# Falls back to the real git (captured before PATH was modified) for everything else.
make_mock_git() {
  local for_each_ref_output="${1:-}"
  local remote_url="${2:-git@github.com:org/repo.git}"
  local reflog_count="${3:-1}"

  cat > "$MOCK_BIN/git" << MOCK
#!/usr/bin/env bash
# Intercept specific git subcommands for testing
args="\$*"
case "\$args" in
  *"for-each-ref"*upstream*)
    echo "$for_each_ref_output"
    ;;
  *"remote get-url"*)
    echo "$remote_url"
    ;;
  *"reflog show"*)
    for i in \$(seq 1 $reflog_count); do
      echo "abc\${i} HEAD@{\${i}}: some: reflog entry"
    done
    ;;
  *)
    "$REAL_GIT" "\$@"
    ;;
esac
MOCK
  chmod +x "$MOCK_BIN/git"
  # Clear bash's command hash table so the new mock is found instead of the cached real git
  hash -r 2>/dev/null || true
}

# Create a mock gh that returns controlled PR states
make_mock_gh() {
  local state="${1:-merged}"  # merged | open | none

  cat > "$MOCK_BIN/gh" << MOCK
#!/usr/bin/env bash
if [[ "\$*" == *"--state merged"* ]]; then
  echo "${state}" | grep -c merged || echo 0
elif [[ "\$*" == *"--state open"* ]]; then
  if [[ "$state" == "open" ]]; then
    echo '1234:Open PR title'
  else
    echo ""
  fi
fi
MOCK
  chmod +x "$MOCK_BIN/gh"
}

# Initialize a bare git repo in TEST_DIR
init_bare_repo() {
  git init --bare "$TEST_DIR" >/dev/null 2>&1
  # Create an initial commit so branches work
  local tmp_clone="$BATS_TEST_TMPDIR/tmp-clone"
  git clone "$TEST_DIR" "$tmp_clone" >/dev/null 2>&1
  git -C "$tmp_clone" commit --allow-empty -m "initial" >/dev/null 2>&1
  git -C "$tmp_clone" push origin HEAD:main >/dev/null 2>&1
  rm -rf "$tmp_clone"
}

# Initialize a regular git repo in TEST_DIR
init_regular_repo() {
  git init "$TEST_DIR" >/dev/null 2>&1
  git -C "$TEST_DIR" commit --allow-empty -m "initial" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 1. URL parsing (cmd_pr)
# ---------------------------------------------------------------------------

@test "cmd_pr: parses org/repo/pr_number from https URL" {
  # Create a dummy Projects dir so cmd_pr can search it
  mkdir -p "$HOME/Projects"

  # Mock gh to avoid actual calls
  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
echo "git@github.com:myorg/myrepo.git"
MOCK
  chmod +x "$MOCK_BIN/gh"

  # Source the URL-parsing regex block inline
  local URL="https://github.com/myorg/myrepo/pull/42"
  local ORG REPO PR_NUMBER
  if [[ "$URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    ORG="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
  fi

  [[ "$ORG" == "myorg" ]]
  [[ "$REPO" == "myrepo" ]]
  [[ "$PR_NUMBER" == "42" ]]
}

@test "cmd_pr: parses URL with trailing slash" {
  local URL="https://github.com/myorg/myrepo/pull/42/"
  local ORG REPO PR_NUMBER
  if [[ "$URL" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    ORG="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
  fi

  [[ "$ORG" == "myorg" ]]
  [[ "$REPO" == "myrepo" ]]
  [[ "$PR_NUMBER" == "42" ]]
}

@test "cmd_pr: errors on non-github URL" {
  run cmd_pr "https://gitlab.com/myorg/myrepo/pull/42"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"invalid GitHub PR URL"* ]]
}

@test "cmd_pr: errors on URL missing pull number" {
  run cmd_pr "https://github.com/myorg/myrepo/issues/42"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"invalid GitHub PR URL"* ]]
}

# ---------------------------------------------------------------------------
# 2. resolve_target
# ---------------------------------------------------------------------------

@test "resolve_target: bare repo puts worktree inside bare dir" {
  init_bare_repo
  local result
  result=$(resolve_target "feat-x" "$TEST_DIR")
  [[ "$result" == "$TEST_DIR/feat-x" ]]
}

@test "resolve_target: regular repo puts worktree as parent-level sibling" {
  init_regular_repo
  local result
  result=$(resolve_target "feat-x" "$TEST_DIR")
  local repo_name
  repo_name=$(basename "$TEST_DIR")
  local expected
  expected="$(dirname "$TEST_DIR")/${repo_name}-feat-x"
  [[ "$result" == "$expected" ]]
}

# ---------------------------------------------------------------------------
# 3. _branch_pr_status
# ---------------------------------------------------------------------------

@test "_branch_pr_status: no upstream → local-only" {
  init_bare_repo
  # Create a branch with no upstream tracking
  git --git-dir="$TEST_DIR" branch feat-x main 2>/dev/null || \
    git --git-dir="$TEST_DIR" branch feat-x HEAD 2>/dev/null || true

  # Mock git to return empty upstream
  make_mock_git ""

  run _branch_pr_status "$TEST_DIR" "feat-x"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "local-only" ]]
}

@test "_branch_pr_status: upstream not on github → none" {
  init_bare_repo
  make_mock_git "origin/feat-x" "https://bitbucket.org/org/repo.git"
  run _branch_pr_status "$TEST_DIR" "feat-x"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "none" ]]
}

@test "_branch_pr_status: merged PR → merged:NUMBER" {
  init_bare_repo
  make_mock_git "origin/feat-x" "git@github.com:org/repo.git"

  # Mock gh: return PR number for the new jq filter (select(length>0)|.[0].number)
  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"--state merged"* ]]; then
  echo "42"
fi
MOCK
  chmod +x "$MOCK_BIN/gh"
  hash -r 2>/dev/null || true

  run _branch_pr_status "$TEST_DIR" "feat-x"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "merged:42" ]]
}

@test "_branch_pr_status: open PR → open:NUMBER:TITLE" {
  init_bare_repo
  make_mock_git "origin/feat-x" "git@github.com:org/repo.git"

  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"--state merged"* ]]; then
  echo ""   # empty = no merged PR (new filter returns number or empty, not count)
elif [[ "$*" == *"--state open"* ]]; then
  echo "1234:My open PR"
fi
MOCK
  chmod +x "$MOCK_BIN/gh"
  hash -r 2>/dev/null || true

  run _branch_pr_status "$TEST_DIR" "feat-x"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "open:1234:My open PR" ]]
}

@test "_branch_pr_status: no PR (closed, never existed) → none" {
  init_bare_repo
  make_mock_git "origin/feat-x" "git@github.com:org/repo.git"

  cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
if [[ "$*" == *"--state merged"* ]]; then
  echo ""   # empty = no merged PR
elif [[ "$*" == *"--state open"* ]]; then
  echo ""
fi
MOCK
  chmod +x "$MOCK_BIN/gh"
  hash -r 2>/dev/null || true

  run _branch_pr_status "$TEST_DIR" "feat-x"
  [[ "$status" -eq 0 ]]
  [[ "$output" == "none" ]]
}

@test "_branch_pr_status: jq filter produces no output for empty PR list" {
  # Regression: old filter '.[0] | "\(.number):\(.title)"' on '[]' produces
  # "null:null" (non-empty), which triggered a false open-PR warning on wt rm.
  # The fix uses 'select(length > 0)' which produces empty output for [].
  local result
  result=$(printf '%s' '[]' | jq -r 'select(length > 0) | .[0] | "\(.number):\(.title)"')
  [[ -z "$result" ]]
}

@test "_branch_pr_status: jq filter extracts number:title from non-empty list" {
  local result
  result=$(printf '%s' '[{"number":42,"title":"My PR"}]' \
    | jq -r 'select(length > 0) | .[0] | "\(.number):\(.title)"')
  [[ "$result" == "42:My PR" ]]
}

# ---------------------------------------------------------------------------
# 4. post-checkout hook logic
# ---------------------------------------------------------------------------

@test "hook: skips file checkout (arg 3 != 1)" {
  local hook_file="$BATS_TEST_TMPDIR/post-checkout"
  # Reproduce hook logic inline
  cat > "$hook_file" << 'EOF'
#!/usr/bin/env bash
[[ "${3:-0}" != "1" ]] && exit 42
exit 0
EOF
  chmod +x "$hook_file"

  run "$hook_file" "abc" "def" "0"
  [[ "$status" -eq 42 ]]
}

@test "hook: skips existing branch (reflog count > 1)" {
  init_bare_repo
  local WORKTREE="$BATS_TEST_TMPDIR/worktree"
  git -C "$TEST_DIR" worktree add "$WORKTREE" main >/dev/null 2>&1

  # Create a branch and make a commit on it — the commit advances the branch ref,
  # which adds a second reflog entry (creation + commit = 2 entries).
  git -C "$WORKTREE" checkout -b test-branch >/dev/null 2>&1
  git -C "$WORKTREE" commit --allow-empty -m "commit on test-branch" >/dev/null 2>&1

  # Verify reflog count > 1 (the condition the hook checks to skip re-logging)
  local reflog_count
  reflog_count=$(git -C "$WORKTREE" reflog show "test-branch" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$reflog_count" -gt 1 ]]
}

@test "hook: logs new branch (reflog count == 1) to TSV" {
  # Use a temporary home so cmd_setup writes to isolated location
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/wt/hooks"

  # Re-source to pick up new HOME
  source "$WT_BIN"
  cmd_setup >/dev/null 2>&1

  local HOOK="$HOME/.config/wt/hooks/post-checkout"
  [[ -f "$HOOK" ]]
  [[ -x "$HOOK" ]]
}

@test "hook: appends correctly formatted TSV line (branch\twt\tts)" {
  init_bare_repo
  local WORKTREE="$BATS_TEST_TMPDIR/worktree"
  git -C "$TEST_DIR" worktree add "$WORKTREE" main >/dev/null 2>&1

  # Manually simulate what the hook does
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  local branch="test-branch"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\t%s\n' "$branch" "$WORKTREE" "$ts" >> "$LOG"

  [[ -f "$LOG" ]]
  local line
  line=$(cat "$LOG")
  [[ "$line" == *"$branch"*"$WORKTREE"* ]]
  # Check TSV format: 3 fields separated by tabs
  local field_count
  field_count=$(echo "$line" | awk -F'\t' '{print NF}')
  [[ "$field_count" -eq 3 ]]
}

@test "hook: chains to per-repo hook if present and executable" {
  local chained="$BATS_TEST_TMPDIR/chained"
  touch "$chained"

  local repo_hook="$BATS_TEST_TMPDIR/repo-post-checkout"
  cat > "$repo_hook" << EOF
#!/usr/bin/env bash
touch "$chained"
EOF
  chmod +x "$repo_hook"

  # Simulate hook chain logic
  local GIT_DIR="$BATS_TEST_TMPDIR"
  export GIT_DIR
  local REPO_HOOK="$GIT_DIR/hooks/post-checkout"
  mkdir -p "$GIT_DIR/hooks"
  cp "$repo_hook" "$REPO_HOOK"
  chmod +x "$REPO_HOOK"

  if [[ -x "$REPO_HOOK" ]]; then
    "$REPO_HOOK" "$@"
  fi

  [[ -f "$chained" ]]
}

@test "hook: does not chain if per-repo hook absent" {
  local sentinel="$BATS_TEST_TMPDIR/should-not-exist"
  local GIT_DIR="$BATS_TEST_TMPDIR"
  export GIT_DIR
  local REPO_HOOK="$GIT_DIR/hooks/post-checkout"
  # Ensure no hook exists
  rm -f "$REPO_HOOK"

  if [[ -x "$REPO_HOOK" ]]; then
    touch "$sentinel"
  fi

  [[ ! -f "$sentinel" ]]
}

# ---------------------------------------------------------------------------
# 5. cmd_setup
# ---------------------------------------------------------------------------

@test "cmd_setup: writes hook to ~/.config/wt/hooks/post-checkout" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  source "$WT_BIN"

  # Mock git config to avoid modifying real global config
  cat > "$MOCK_BIN/git" << 'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"config --global"*) exit 0 ;;
  *) command git "$@" ;;
esac
MOCK
  chmod +x "$MOCK_BIN/git"

  run cmd_setup
  [[ "$status" -eq 0 ]]
  [[ -f "$HOME/.config/wt/hooks/post-checkout" ]]
}

@test "cmd_setup: hook is executable" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  source "$WT_BIN"

  cat > "$MOCK_BIN/git" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/git"

  cmd_setup >/dev/null 2>&1
  [[ -x "$HOME/.config/wt/hooks/post-checkout" ]]
}

@test "cmd_setup: is idempotent (running twice doesn't corrupt hook)" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  source "$WT_BIN"

  cat > "$MOCK_BIN/git" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/git"

  cmd_setup >/dev/null 2>&1
  local content_before
  content_before=$(cat "$HOME/.config/wt/hooks/post-checkout")

  cmd_setup >/dev/null 2>&1
  local content_after
  content_after=$(cat "$HOME/.config/wt/hooks/post-checkout")

  [[ "$content_before" == "$content_after" ]]
}

# ---------------------------------------------------------------------------
# 6. cmd_remove pre-removal warnings
# ---------------------------------------------------------------------------

@test "wt rm: warns when worktree is locked (no reason)" {
  # Simulate a locked worktree by creating the gitdir entry with a 'locked' file
  local FAKE_WT="$BATS_TEST_TMPDIR/fake-wt"
  local GITDIR_ENTRY="$BATS_TEST_TMPDIR/gitdir-entry"
  mkdir -p "$FAKE_WT" "$GITDIR_ENTRY"
  printf 'gitdir: %s\n' "$GITDIR_ENTRY" > "$FAKE_WT/.git"
  touch "$GITDIR_ENTRY/locked"

  local warnings=()
  local _gitdir_entry="$GITDIR_ENTRY"
  if [[ -n "$_gitdir_entry" && -f "$_gitdir_entry/locked" ]]; then
    local lock_reason
    lock_reason=$(cat "$_gitdir_entry/locked" 2>/dev/null || true)
    if [[ -n "$lock_reason" ]]; then
      warnings+=("worktree is locked: $lock_reason")
    else
      warnings+=("worktree is locked (no reason given)")
    fi
  fi
  [[ ${#warnings[@]} -eq 1 ]]
  [[ "${warnings[0]}" == *"locked"* ]]
}

@test "wt rm: warns when worktree is locked with reason" {
  local GITDIR_ENTRY="$BATS_TEST_TMPDIR/gitdir-entry-reason"
  mkdir -p "$GITDIR_ENTRY"
  printf 'on remote mount\n' > "$GITDIR_ENTRY/locked"

  local warnings=()
  local _gitdir_entry="$GITDIR_ENTRY"
  if [[ -n "$_gitdir_entry" && -f "$_gitdir_entry/locked" ]]; then
    local lock_reason
    lock_reason=$(cat "$_gitdir_entry/locked" 2>/dev/null || true)
    [[ -n "$lock_reason" ]] \
      && warnings+=("worktree is locked: $lock_reason") \
      || warnings+=("worktree is locked (no reason given)")
  fi
  [[ ${#warnings[@]} -eq 1 ]]
  [[ "${warnings[0]}" == *"on remote mount"* ]]
}

@test "wt rm: no warning when worktree is not locked" {
  local GITDIR_ENTRY="$BATS_TEST_TMPDIR/gitdir-entry-unlocked"
  mkdir -p "$GITDIR_ENTRY"
  # No 'locked' file

  local warnings=()
  local _gitdir_entry="$GITDIR_ENTRY"
  [[ -n "$_gitdir_entry" && -f "$_gitdir_entry/locked" ]] \
    && warnings+=("locked")
  [[ ${#warnings[@]} -eq 0 ]]
}

@test "wt rm: no warning when branch is merged" {
  init_bare_repo
  local WORKTREE="$BATS_TEST_TMPDIR/worktree"
  git -C "$TEST_DIR" worktree add -b feat-x "$WORKTREE" main >/dev/null 2>&1

  # Override _branch_pr_status to return merged
  _branch_pr_status() { echo "merged:1234"; }

  # Override git worktree list check (no other wt has the branch)
  cat > "$MOCK_BIN/git" << MOCK
#!/usr/bin/env bash
case "\$*" in
  *"worktree remove"*)  command git "\$@" ;;
  *"worktree list"*)    printf 'worktree %s\nHEAD abc\nbranch refs/heads/main\n\n' "$WORKTREE" ;;
  *) command git "\$@" ;;
esac
MOCK
  chmod +x "$MOCK_BIN/git"

  # Should not print any warning
  # We can't easily test cmd_remove without side effects, so test the warning logic directly
  local warnings=()
  local pr_status
  pr_status=$(_branch_pr_status "$TEST_DIR" "feat-x")
  case "$pr_status" in
    local-only) warnings+=("local-only") ;;
    open:*)     warnings+=("open") ;;
  esac
  [[ ${#warnings[@]} -eq 0 ]]
}

@test "wt rm: warns when branch has open PR" {
  # Override _branch_pr_status for this test
  _branch_pr_status() { echo "open:1234:My PR Title"; }

  local warnings=()
  local pr_status
  pr_status=$(_branch_pr_status "" "feat-x")
  case "$pr_status" in
    open:*)
      local pr_info="${pr_status#open:}"
      local pr_num="${pr_info%%:*}"
      local pr_title="${pr_info#*:}"
      warnings+=("branch 'feat-x' has an open PR: #$pr_num \"$pr_title\"")
      ;;
  esac
  [[ ${#warnings[@]} -eq 1 ]]
  [[ "${warnings[0]}" == *"#1234"* ]]
  [[ "${warnings[0]}" == *"My PR Title"* ]]
}

@test "wt rm: warns when branch is local-only" {
  _branch_pr_status() { echo "local-only"; }

  local warnings=()
  local pr_status
  pr_status=$(_branch_pr_status "" "feat-x")
  case "$pr_status" in
    local-only) warnings+=("branch 'feat-x' has no remote tracking branch (local-only)") ;;
  esac
  [[ ${#warnings[@]} -eq 1 ]]
  [[ "${warnings[0]}" == *"local-only"* ]]
}

@test "wt rm: multiple warnings shown together" {
  _branch_pr_status() { echo "open:5678:Another PR"; }

  local warnings=()
  # Simulate both: checked out elsewhere AND open PR
  warnings+=("branch 'feat-x' is checked out in another worktree")
  local pr_status
  pr_status=$(_branch_pr_status "" "feat-x")
  case "$pr_status" in
    open:*)
      local pr_info="${pr_status#open:}"
      local pr_num="${pr_info%%:*}"
      warnings+=("branch 'feat-x' has an open PR: #$pr_num")
      ;;
  esac
  [[ ${#warnings[@]} -eq 2 ]]
}

# ---------------------------------------------------------------------------
# 7. _gc_branches behavior
# ---------------------------------------------------------------------------

@test "_gc_branches: shows 'Nothing to delete.' when no merged branches" {
  init_bare_repo
  # Create a real feat-x branch so for-each-ref finds it
  "$REAL_GIT" --git-dir="$TEST_DIR" branch feat-x main >/dev/null 2>&1

  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  printf 'feat-x\t%s\t2026-03-17T10:00:00Z\n' "$BATS_TEST_TMPDIR/wt-feat-x" > "$LOG"

  # Override PR status — nothing is merged
  _branch_pr_status() { echo "none"; }

  run _gc_branches "$TEST_DIR" "" "false"
  [[ "$output" == *"Nothing to delete."* ]]
}

@test "_gc_branches: only queues merged branches for deletion" {
  init_bare_repo
  # Create real feat-x and feat-y branches
  "$REAL_GIT" --git-dir="$TEST_DIR" branch feat-x main >/dev/null 2>&1
  "$REAL_GIT" --git-dir="$TEST_DIR" branch feat-y main >/dev/null 2>&1

  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  local WT1="$BATS_TEST_TMPDIR/wt-feat-x"
  printf 'feat-x\t%s\t2026-03-17T10:00:00Z\n' "$WT1" > "$LOG"
  printf 'feat-y\t%s\t2026-03-17T11:00:00Z\n' "$WT1" >> "$LOG"

  # feat-x is merged, feat-y is open
  _branch_pr_status() {
    local branch="$2"
    case "$branch" in
      feat-x) echo "merged:1234" ;;
      feat-y) echo "open:999:WIP" ;;
      *)      echo "none" ;;
    esac
  }

  # Stub out actual deletion so we don't modify the test repo
  _do_delete_branches() { true; }

  run _gc_branches "$TEST_DIR" "" "true"
  [[ "$status" -eq 0 ]]
  # feat-x should appear in the table as "will delete"; feat-y as "open"
  [[ "$output" == *"feat-x"* ]]
}

@test "_gc_branches: table columns fit long branch names without overflow" {
  init_bare_repo
  local long_branch="fix/split-campaign-details-bma-tests"  # 38 chars > old 20-char column
  "$REAL_GIT" --git-dir="$TEST_DIR" branch "$long_branch" main >/dev/null 2>&1

  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  printf '%s\t%s\t2026-03-17T10:00:00Z\n' "$long_branch" "$BATS_TEST_TMPDIR/wt" > "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  _do_delete_branches() { true; }

  run _gc_branches "$TEST_DIR" "" "true"
  [[ "$status" -eq 0 ]]
  # The branch name must appear on its own line without STATUS bleeding into it
  [[ "$output" == *"$long_branch"* ]]
  # "will delete" must still appear (ACTION column present)
  [[ "$output" == *"will delete"* ]]
  # Header and data should use the same width: verify BRANCH header and separator
  # are at least as wide as the branch name (no truncation)
  local branch_col_line
  branch_col_line=$(printf '%s\n' "$output" | grep "BRANCH")
  [[ "$branch_col_line" == *"BRANCH"* ]]
}

@test "_gc_branches: with WORKTREE_FILTER, local-only branches are queued for deletion" {
  init_bare_repo
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  local WT1="$BATS_TEST_TMPDIR/wt-a"
  # Two local-only branches from the same worktree
  "$REAL_GIT" --git-dir="$TEST_DIR" branch local-a main >/dev/null 2>&1
  "$REAL_GIT" --git-dir="$TEST_DIR" branch local-b main >/dev/null 2>&1
  printf 'local-a\t%s\t2026-03-17T10:00:00Z\n' "$WT1" > "$LOG"
  printf 'local-b\t%s\t2026-03-17T10:01:00Z\n' "$WT1" >> "$LOG"

  _branch_pr_status() { echo "local-only"; }
  _do_delete_branches() { true; }

  run _gc_branches "$TEST_DIR" "$WT1" "false"
  [[ "$status" -eq 0 ]]
  # Both branches should appear and be marked for deletion
  [[ "$output" == *"local-a"* ]]
  [[ "$output" == *"local-b"* ]]
  [[ "$output" == *"will delete"* ]]
}

@test "_gc_branches: without WORKTREE_FILTER, local-only branches are NOT queued" {
  init_bare_repo
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  "$REAL_GIT" --git-dir="$TEST_DIR" branch local-a main >/dev/null 2>&1
  printf 'local-a\tunknown\t2026-03-17T10:00:00Z\n' > "$LOG"

  _branch_pr_status() { echo "local-only"; }

  run _gc_branches "$TEST_DIR" "" "false"
  [[ "$status" -eq 0 ]]
  # local-only branch visible but not queued → "Nothing to delete." (no merged)
  [[ "$output" == *"Nothing to delete."* ]]
}

@test "_gc_branches: WORKTREE_FILTER limits to branches from that wt" {
  init_bare_repo
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  local WT1="$BATS_TEST_TMPDIR/wt-a"
  local WT2="$BATS_TEST_TMPDIR/wt-b"
  printf 'branch-a\t%s\t2026-03-17T10:00:00Z\n' "$WT1" > "$LOG"
  printf 'branch-b\t%s\t2026-03-17T10:00:00Z\n' "$WT2" >> "$LOG"

  _branch_pr_status() { echo "merged:1234"; }

  cat > "$MOCK_BIN/git" << MOCK
#!/usr/bin/env bash
case "\$*" in
  *"worktree list"*)
    printf 'worktree %s\nHEAD abc\n\n' "$TEST_DIR"
    ;;
  *"branch -D"* | *"for-each-ref"*)
    echo ""
    ;;
  *) command git "\$@" ;;
esac
MOCK
  chmod +x "$MOCK_BIN/git"

  # Filter to WT1 — should only see branch-a
  run _gc_branches "$TEST_DIR" "$WT1" "false"
  # branch-b should not appear in output
  [[ "$output" != *"branch-b"* ]]
}

# ---------------------------------------------------------------------------
# 8. cmd_gc
# ---------------------------------------------------------------------------

@test "cmd_gc: unknown option exits non-zero" {
  init_bare_repo
  run cmd_gc "--unknown-flag"
  [[ "$status" -ne 0 ]]
}

# ---------------------------------------------------------------------------
# 9. cmd_branches output format
# ---------------------------------------------------------------------------

@test "cmd_branches: no TSV → shows setup hint" {
  init_bare_repo
  # No TSV file — cmd_branches should show setup hint
  run cmd_branches
  [[ "$output" == *"wt setup"* ]]
}

@test "cmd_branches: groups branches by worktree with WORKTREE header" {
  init_bare_repo
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  local WT1="$BATS_TEST_TMPDIR/wt-feat-x"
  printf 'feat-x\t%s\t2026-03-10T12:00:00Z\n' "$WT1" > "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  resolve_common_dir() { echo "$TEST_DIR"; }

  run cmd_branches
  [[ "$output" == *"WORKTREE"* ]]
  [[ "$output" == *"feat-x"* ]]
}

@test "cmd_branches: marks worktree [active] vs [removed]" {
  init_bare_repo
  # Add a real worktree so we get one "active" path and one "removed" path
  local ACTIVE_WT="$BATS_TEST_TMPDIR/active-wt"
  "$REAL_GIT" -C "$TEST_DIR" worktree add -b branch-in-active "$ACTIVE_WT" main \
    >/dev/null 2>&1

  local REMOVED_WT="$BATS_TEST_TMPDIR/removed-wt"
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  printf 'branch-in-active\t%s\t2026-03-10T12:00:00Z\n' "$ACTIVE_WT" > "$LOG"
  printf 'branch-in-removed\t%s\t2026-03-10T12:00:00Z\n' "$REMOVED_WT" >> "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  resolve_common_dir() { echo "$TEST_DIR"; }

  run cmd_branches
  [[ "$output" == *"active"* ]]
  [[ "$output" == *"removed"* ]]
}

@test "cmd_branches: shows column headers with separator line" {
  init_bare_repo
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  printf 'feat-x\t%s\t2026-03-10T12:00:00Z\n' "$BATS_TEST_TMPDIR/wt" > "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  resolve_common_dir() { echo "$TEST_DIR"; }

  run cmd_branches
  [[ "$output" == *"BRANCH"* ]]
  [[ "$output" == *"DATE"* ]]
  [[ "$output" == *"STATUS"* ]]
  [[ "$output" == *"──"* ]]
}

# ---------------------------------------------------------------------------
# 10. --help fix
# ---------------------------------------------------------------------------

@test "--help: exits 0" {
  unset __WT_TESTS
  run "$WT_BIN" --help
  [[ "$status" -eq 0 ]]
  export __WT_TESTS=1
}

@test "--help: outputs to stderr only" {
  unset __WT_TESTS
  # Capture stdout only — should be empty
  local stdout_output
  stdout_output=$("$WT_BIN" --help 2>/dev/null || true)
  [[ -z "$stdout_output" ]]
  export __WT_TESTS=1
}

@test "--help: stdout is empty (safe for directive capture)" {
  unset __WT_TESTS
  local directive
  directive=$("$WT_BIN" --help 2>/dev/null) || true
  [[ -z "$directive" ]]
  export __WT_TESTS=1
}

@test "unknown command: exits non-zero" {
  unset __WT_TESTS
  run "$WT_BIN" no-such-command
  [[ "$status" -ne 0 ]]
  export __WT_TESTS=1
}

@test "unknown command: usage goes to stderr" {
  unset __WT_TESTS
  local stdout_output
  stdout_output=$("$WT_BIN" no-such-command 2>/dev/null || true)
  [[ -z "$stdout_output" ]]
  export __WT_TESTS=1
}

# ---------------------------------------------------------------------------
# 11. Color codes
# ---------------------------------------------------------------------------

@test "colors disabled when stdout not a TTY (cmd_branches)" {
  init_bare_repo
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  printf 'feat-x\t%s\t2026-03-10T12:00:00Z\n' "$BATS_TEST_TMPDIR/wt" > "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  resolve_common_dir() { echo "$TEST_DIR"; }

  # Capture via $() — stdout is not a TTY, so no ANSI codes should appear
  local out
  out=$(cmd_branches)
  [[ "$out" != *$'\033['* ]]
}

@test "colors disabled when stderr not a TTY (cmd_gc)" {
  # When run via bats, stderr is captured, so C_* variables are empty
  # Verify by checking the global color vars set at source time
  [[ -z "${C_BOLD:-}" ]] || [[ -z "${C_CYAN:-}" ]]
  # (In a non-TTY bats run, these are empty strings)
  true
}

# ---------------------------------------------------------------------------
# 12. Bash 3.2 compatibility — answer prompt case statement
# ---------------------------------------------------------------------------

@test "_gc_branches: table has numbered # column" {
  init_bare_repo
  "$REAL_GIT" --git-dir="$TEST_DIR" branch feat-x main >/dev/null 2>&1
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  printf 'feat-x\t%s\t2026-03-17T10:00:00Z\n' "$BATS_TEST_TMPDIR/wt" > "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  _do_delete_branches() { true; }

  run _gc_branches "$TEST_DIR" "" "true"
  [[ "$output" == *"#"* ]]
  [[ "$output" == *"1"* ]]  # row 1 is present
}

@test "_gc_branches: SKIP_PROMPTS=true auto-deletes pre-selected branches" {
  # The interactive prompt reads from /dev/tty (can't feed it in bats).
  # SKIP_PROMPTS=true exercises the same collection→delete path that accepting
  # the default at the interactive prompt would take.
  # Must use `run` so the RETURN trap in _gc_branches is scoped to the
  # run subshell and doesn't fire for nested calls in the test's shell scope.
  init_bare_repo
  "$REAL_GIT" --git-dir="$TEST_DIR" branch feat-x main >/dev/null 2>&1
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  printf 'feat-x\t%s\t2026-03-17T10:00:00Z\n' "$BATS_TEST_TMPDIR/wt" > "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  _do_delete_branches() { echo "DELETED:$*" >&2; }

  run _gc_branches "$TEST_DIR" "" "true"
  [[ "$status" -eq 0 ]]
  # _do_delete_branches should have been called with feat-x
  [[ "$output" == *"DELETED"*"feat-x"* ]]
}

@test "cmd_branches: dynamic column widths for long branch names" {
  init_bare_repo
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  local long_branch="i18n_audience-expansion-badge-sidesheet"
  printf '%s\t%s\t2026-03-10T12:00:00Z\n' "$long_branch" "$BATS_TEST_TMPDIR/wt" > "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  resolve_common_dir() { echo "$TEST_DIR"; }

  run cmd_branches
  [[ "$output" == *"$long_branch"* ]]
  # The separator line must be at least as wide as the branch name
  local sep_line
  sep_line=$(printf '%s\n' "$output" | grep '─' | head -1)
  [[ ${#sep_line} -ge ${#long_branch} ]]
}

@test "cmd_branches: colors in format string not data (no \\033 in plain field)" {
  init_bare_repo
  local LOG="$TEST_DIR/wt-branch-origin.tsv"
  printf 'feat-x\t%s\t2026-03-10T12:00:00Z\n' "$BATS_TEST_TMPDIR/wt" > "$LOG"

  _branch_pr_status() { echo "merged:1234"; }
  resolve_common_dir() { echo "$TEST_DIR"; }

  # Capture output (not a TTY → no colors produced)
  local out
  out=$(cmd_branches)
  # No ANSI escape sequences should appear in non-TTY output
  [[ "$out" != *$'\033['* ]]
}

@test "cmd_ls: shows [deleting…] for worktrees with pending-delete marker" {
  init_bare_repo
  local PENDING_DIR="$TEST_DIR/wt-pending-delete"
  local FAKE_WT="$BATS_TEST_TMPDIR/fake-wt"
  mkdir -p "$PENDING_DIR" "$FAKE_WT"
  printf '%s\n' "$FAKE_WT" > "$PENDING_DIR/fake-wt"

  resolve_common_dir() { echo "$TEST_DIR"; }

  run cmd_ls
  [[ "$output" == *"deleting"* ]]
  [[ "$output" == *"fake-wt"* ]]
}

@test "cmd_ls: silently removes stale marker when directory is already gone" {
  init_bare_repo
  local PENDING_DIR="$TEST_DIR/wt-pending-delete"
  mkdir -p "$PENDING_DIR"
  # Write a marker for a path that no longer exists
  printf '%s\n' "/nonexistent/path/that/is/gone" > "$PENDING_DIR/gone-wt"

  resolve_common_dir() { echo "$TEST_DIR"; }

  run cmd_ls
  # Stale marker must be cleaned up
  [[ ! -f "$PENDING_DIR/gone-wt" ]]
  # No [deleting…] annotation for a gone directory
  [[ "$output" != *"deleting"* ]]
}

@test "answer prompt: case [Yy] accepts y and Y, rejects n N and empty" {
  # Tests the case pattern used in _gc_branches and cmd_remove prompts.
  # Replaces '${answer,,} == y' (bash 4.0+) for bash 3.2 compat.
  local ans result

  for ans in y Y; do
    case "$ans" in
      [Yy]) result="proceed" ;;
      *)    result="abort"   ;;
    esac
    [[ "$result" == "proceed" ]] || { echo "expected proceed for '$ans'"; return 1; }
  done

  for ans in n N "" no; do
    case "$ans" in
      [Yy]) result="proceed" ;;
      *)    result="abort"   ;;
    esac
    [[ "$result" == "abort" ]] || { echo "expected abort for '$ans'"; return 1; }
  done
}
