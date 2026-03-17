# wt shell integration — sources into .zshrc
# Handles cd, background init, and disown after wt binary emits a directive.
#
# Directive protocol (emitted on stdout by the wt binary):
#   cd:<path>          — cd to path
#   cd+init:<path>     — cd to path, then run init script in background
#   rm:<removed>:<dest> — cd to dest if cwd is inside removed path
#   pr:<path>|<url>    — cd to path, launch Claude with /review-pr <url> (no init)

_wt_run_init() {
  local worktree="$1"
  local common_dir is_bare repo_name init_script log
  common_dir=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null) || return
  [[ "$common_dir" != /* ]] && common_dir="$(cd "$worktree/$common_dir" && pwd)"
  is_bare=$(git --git-dir="$common_dir" rev-parse --is-bare-repository 2>/dev/null || echo "false")
  if [[ "$is_bare" == "true" ]]; then
    repo_name=$(basename "$common_dir")
  else
    repo_name=$(basename "$(dirname "$common_dir")")
  fi
  init_script="$HOME/.config/wt/init/$repo_name.sh"
  if [[ -f "$init_script" ]]; then
    log="$worktree/.wt-init.log"
    echo "Running $init_script in background → $log" >&2
    (cd "$worktree" && bash "$init_script" > "$log" 2>&1) &!
  fi
}

_wt_handle_directive() {
  local directive="$1"
  local action="${directive%%:*}"
  local rest="${directive#*:}"

  case "$action" in
    cd)
      cd "$rest"
      ;;
    cd+init)
      cd "$rest"
      _wt_run_init "$rest"
      ;;
    rm)
      local removed="${rest%%:*}"
      local dest="${rest#*:}"
      if [[ "$(pwd)" == "$removed"* ]]; then
        echo "cd $dest" >&2
        cd "$dest"
      fi
      ;;
    pr)
      local worktree="${rest%%|*}"
      local pr_url="${rest#*|}"
      cd "$worktree"
      claude "/review-pr $pr_url"
      ;;
  esac
}

wt() {
  # Pass-through for commands that write their real output to stdout.
  # These can't go through the directive-capture path (`directive=$(command wt "$@")`)
  # because that swallows stdout — the user would see nothing.
  if [[ "${1:-}" == "ls" || "${1:-}" == "" || "${1:-}" == "branches" ]]; then
    command wt "$@"
    return
  fi

  # init: purely shell-side, no binary interaction needed
  if [[ "${1:-}" == "init" ]]; then
    local worktree
    if [[ -n "${2:-}" ]]; then
      local out
      out=$(command wt cd "$2") || return $?
      worktree="${out#cd:}"
    else
      worktree=$(pwd)
    fi
    _wt_run_init "$worktree"
    return
  fi

  # All other commands: run binary, parse directive, act on it
  local directive
  directive=$(command wt "$@") || return $?
  [[ -n "$directive" ]] && _wt_handle_directive "$directive"
}
