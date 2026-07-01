#!/usr/bin/env bash
# Shared helpers for the redline test suite.
# Pure bash + git + jq + coreutils — no test framework dependency.
#
# A test file sources this, runs assert_* calls, and ends with `t_summary`,
# whose exit status (0 = all passed) becomes the file's exit status. The runner
# (run.sh) executes each test file as its own process and aggregates.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
PLUGIN="$REPO_ROOT/plugins/redline"
HOOKS="$PLUGIN/hooks"
# shellcheck disable=SC2034  # used by test files that source this
SCRIPTS="$PLUGIN/scripts"

T_PASS=0
T_FAIL=0
T_NAME="$(basename "${0:-suite}")"

_c(){ # _c COLOR TEXT  (color only when stdout is a tty)
  if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

pass(){ T_PASS=$((T_PASS+1)); printf '  %s %s\n' "$(_c 32 ok)" "$1"; }
fail(){ T_FAIL=$((T_FAIL+1)); printf '  %s %s\n' "$(_c 31 FAIL)" "$1"
        [ -n "${2:-}" ] && printf '       %s\n' "$2"; return 0; }

assert_eq(){        [ "$1" = "$2" ] && pass "$3" || fail "$3" "expected [$1], got [$2]"; }
assert_empty(){     [ -z "$1" ]    && pass "$2" || fail "$2" "expected empty, got [$1]"; }
assert_nonempty(){  [ -n "$1" ]    && pass "$2" || fail "$2" "expected non-empty"; }
assert_contains(){     case "$1" in *"$2"*) pass "$3";; *) fail "$3" "[$1] lacks [$2]";; esac; }
assert_not_contains(){ case "$1" in *"$2"*) fail "$3" "[$1] unexpectedly has [$2]";; *) pass "$3";; esac; }
assert_file(){      [ -f "$1" ]    && pass "$2" || fail "$2" "missing file: $1"; }
assert_no_file(){   [ ! -e "$1" ]  && pass "$2" || fail "$2" "file should not exist: $1"; }
assert_status(){ # expected_rc actual_rc msg
  [ "$1" = "$2" ] && pass "$3" || fail "$3" "expected exit $1, got $2"; }

t_summary(){
  printf '%s: %s passed, %s failed\n' "$T_NAME" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}

# ---- fixtures (auto-cleaned on EXIT) ----------------------------------------
# Track temp dirs via a registry FILE, not a shell array: new_repo is often
# called inside $( ... ), and an array assignment there would not survive the
# subshell, whereas appends to a file (path inherited by the subshell) do.
_TMP_REG="$(mktemp)"
_track(){ printf '%s\n' "$1" >> "$_TMP_REG"; }
# shellcheck disable=SC2317
_cleanup(){ [ -f "$_TMP_REG" ] && { while IFS= read -r d; do [ -n "$d" ] && rm -rf "$d"; done < "$_TMP_REG"; rm -f "$_TMP_REG"; }; }
trap _cleanup EXIT

# Sets the global STATE and exports REDLINE_STATE_DIR. Call it directly (NOT in
# a $() subshell) or the export will not reach the test shell.
new_state(){ STATE="$(mktemp -d)"; _track "$STATE"; export REDLINE_STATE_DIR="$STATE"; }

new_repo(){ # [dir] -> path to an initialised repo with a test identity
  local d; d="${1:-$(mktemp -d)}"; _track "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name  "Test"
  git -C "$d" config commit.gpgsign false
  printf '%s' "$d"
}

# payload SID CWD [EXTRA_JSON]  -> hook/statusLine JSON on stdout
payload(){
  local sid="$1" cwd="$2" extra="${3:-}"
  if [ -n "$extra" ]; then
    jq -nc --arg s "$sid" --arg c "$cwd" --argjson e "$extra" '{session_id:$s,cwd:$c}+$e'
  else
    jq -nc --arg s "$sid" --arg c "$cwd" '{session_id:$s,cwd:$c}'
  fi
}

run_snapshot(){ payload "$1" "$2" "${3:-}" | bash "$HOOKS/snapshot-worktree.sh"; }
run_diff(){     payload "$1" "$2" "${3:-}" | bash "$HOOKS/diff-since-last-turn.sh"; }
run_status(){   payload "$1" "$2" "${3:-}" | bash "$HOOKS/statusline.sh"; }
run_cleanup(){  payload "$1" "$2" "${3:-}" | bash "$HOOKS/cleanup-session.sh"; }

# strip ANSI escapes (for content assertions on the coloured status line)
strip_ansi(){ sed $'s/\x1b\\[[0-9;]*m//g'; }
run_status_plain(){ run_status "$@" | strip_ansi; }

commit_all(){ # dir msg
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

# Set a file's mtime to N seconds in the past. Portable across GNU and BSD/macOS
# touch: GNU accepts `-d @epoch`; BSD rejects it and needs `-t CCYYMMDDhhmm.SS`.
backdate(){ # file seconds_ago
  local f="$1" epoch; epoch=$(( $(date +%s) - $2 ))
  touch -d "@$epoch" "$f" 2>/dev/null && return       # GNU coreutils
  touch -t "$(date -r "$epoch" +%Y%m%d%H%M.%S)" "$f"  # BSD/macOS
}
