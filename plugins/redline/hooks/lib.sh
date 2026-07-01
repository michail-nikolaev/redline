#!/usr/bin/env bash
# Shared helpers for the redline plugin.
# Single source of truth for paths, session id, and worktree snapshots.

# jq is a hard requirement — we parse the hook/statusLine JSON with it and use
# no string-munging fallback. Call this right after sourcing lib.sh. If jq is
# missing we announce it on stderr and stop with exit 0, so the host session and
# the status bar are never broken or spammed — the plugin simply goes inactive.
cc_require_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  printf '[redline] jq is required but was not found in PATH; the plugin is inactive until jq is installed.\n' >&2
  exit 0
}

# Read the hook's JSON payload from stdin exactly once.
cc_read_input() { CC_INPUT="$(cat 2>/dev/null || true)"; }

# Extract a top-level string field from CC_INPUT.
cc_json() {
  printf '%s' "${CC_INPUT:-}" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
}

# Extract a nested field via a jq path expression (e.g. '.workspace.current_dir').
cc_json_path() {
  printf '%s' "${CC_INPUT:-}" | jq -r "$1 // empty" 2>/dev/null
}

# Project root. We resolve it from the payload's cwd FIRST, on purpose: both the
# hooks and the statusLine command carry cwd, so they always agree on the same
# directory. This is essential in a git worktree — where CLAUDE_PROJECT_DIR can
# point at the original checkout while the session actually operates inside the
# worktree — and after the agent cd's. The statusLine command never receives
# CLAUDE_PROJECT_DIR, so keying on that would make the two contexts disagree and
# compare trees from different working directories. CLAUDE_PROJECT_DIR is only a
# fallback for the rare payload with no cwd; then PWD.
# Order: top-level cwd -> workspace.current_dir (statusLine nests it there) ->
# CLAUDE_PROJECT_DIR -> current directory.
cc_project_dir() {
  local c; c="$(cc_json cwd)"
  [ -n "$c" ] || c="$(cc_json_path '.workspace.current_dir')"
  [ -n "$c" ] || c="${CLAUDE_PROJECT_DIR:-}"
  [ -n "$c" ] && printf '%s' "$c" || printf '%s' "$PWD"
}

# State directory. MUST resolve identically from a plugin hook AND from a
# settings.json statusLine command. The statusLine command does not receive the
# plugin env vars (CLAUDE_PLUGIN_DATA / CLAUDE_PLUGIN_ROOT are documented for
# hooks only), so we deliberately do NOT key off CLAUDE_PLUGIN_DATA here — that
# would make the two contexts look in different directories and the status line
# would never find the snapshot. Snapshots are transient (cleaned at SessionEnd
# and after 24h), so they don't need a persistent location.
#
# Default is a fixed temp path (always outside the repo, so snapshots never
# capture our own state files). The user id is in the path so that on a shared
# machine with TMPDIR=/tmp two users don't race for one directory — whoever
# created it would own it 0755 and the other's writes would silently fail. The
# uid is identical in the hook and statusLine contexts (same user), so both
# still resolve the same path. Override with REDLINE_STATE_DIR if you need to
# relocate it — but then set that SAME value in both environments.
cc_state_dir() {
  local base="${REDLINE_STATE_DIR:-${TMPDIR:-/tmp}/redline-${UID:-$(id -u 2>/dev/null || echo 0)}}"
  mkdir -p "$base/sessions" 2>/dev/null || true
  printf '%s/sessions' "$base"
}

# Age in seconds of a file (now - mtime). Prints a large number if the file is
# missing or its mtime can't be read, so callers treat "unknown" as stale.
# Handles both GNU (stat -c) and BSD/macOS (stat -f) stat.
cc_file_age() {
  local f="$1" m now
  m="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null)"
  [ -n "$m" ] || { printf '999999'; return; }
  now="$(date +%s 2>/dev/null)"
  [ -n "$now" ] || { printf '0'; return; }   # no clock -> assume fresh, not stuck
  printf '%s' "$(( now - m ))"
}

# Is a Bash *tool* command currently running for THIS session? Claude Code runs
# each Bash tool command as a direct child of the session's process (our $PPID)
# that sources a shell snapshot; hooks and the status line are invoked as plain
# `bash <script>` and lack that signature, so they never self-match. Used by the
# status line to stay "working" during a long command that makes no model calls
# (so cost.total_api_duration_ms is frozen and the heartbeat alone would expire).
#
# Fail-safe: if pgrep is missing this returns non-zero and the caller falls back
# to the heartbeat/TTL (today's behavior). The snapshot-bash signature is a
# Claude Code internal; override REDLINE_BUSY_CMD_PATTERN if it ever changes.
# Keep any override a plain literal (it is a pgrep -f regex).
cc_command_running() {
  command -v pgrep >/dev/null 2>&1 || return 1
  pgrep -P "$PPID" -f "${REDLINE_BUSY_CMD_PATTERN:-shell-snapshots/snapshot-bash}" >/dev/null 2>&1
}

# Session id — the basis for multi-session safety. Every Claude Code session
# gets its own session_id, so snapshots from different sessions never clobber
# each other. Fallback (if the field is missing) is a hash of the project path.
cc_session_id() {
  local s; s="$(cc_json session_id)"
  [ -n "$s" ] && { printf '%s' "$s"; return; }
  printf '%s' "$(cc_project_dir)" | cksum | cut -d' ' -f1
}

# Seed an index file from the repo's REAL index when it is empty/missing. Run
# inside the project dir. This matters for consistency: an empty index makes
# `git add -A` treat tracked-but-gitignored files (e.g. a committed .idea/ that
# is also listed in .gitignore) as ignored untracked files and DROP them, while
# a seeded index keeps them as the tracked files they are. Every snapshot we take
# must agree, or those files surface as spurious "added" entries on a clean tree.
# Seeding makes the result match what git actually tracks, in every code path.
cc_seed_index() {
  local idx="$1" real
  [ -s "$idx" ] && return 0
  real="$(git rev-parse --git-path index 2>/dev/null)"
  [ -n "$real" ] && [ -f "$real" ] && cp "$real" "$idx" 2>/dev/null || true
}

# Snapshot the entire worktree into a git tree object WITHOUT touching the repo's
# index, stash, or working files (via a separate GIT_INDEX_FILE). The index is
# seeded from the real index (see cc_seed_index) then thrown away. One-shot use
# (SessionStart / Stop / UserPromptSubmit).
# $1 = project root, $2 = absolute path to a temp index.
# Prints the tree SHA to stdout (empty if not a git repo).
cc_snapshot_tree() {
  local proj="$1" idx="$2"
  ( cd "$proj" 2>/dev/null || exit 0
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    rm -f "$idx"
    cc_seed_index "$idx"
    GIT_INDEX_FILE="$idx" git add -A 2>/dev/null || exit 0
    GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null
  )
  rm -f "$idx" "$idx.lock" 2>/dev/null || true
}

# Like cc_snapshot_tree, but reuses a PERSISTENT index file across calls so git's
# stat cache lets it skip re-hashing unchanged files. This is for the status
# line, which runs every few seconds: a throwaway index would re-hash the ENTIRE
# worktree on every tick (no cache to reuse), which is the main cost. With a
# persistent index only files whose stat changed are re-hashed. The index is
# seeded from the real index on first use — the SAME seeding cc_snapshot_tree
# uses, so the trees this produces are directly comparable to the baseline.
# Does NOT delete the index. If another call holds the index lock, git fails and
# we print nothing — the caller falls back to its cached frame.
# $1 = project root, $2 = absolute path to the persistent index.
cc_snapshot_tree_warm() {
  local proj="$1" idx="$2"
  ( cd "$proj" 2>/dev/null || exit 0
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    cc_seed_index "$idx"
    GIT_INDEX_FILE="$idx" git add -A 2>/dev/null || exit 0
    GIT_INDEX_FILE="$idx" git write-tree 2>/dev/null
  )
}

# Current HEAD (commit sha). Lets us tell manual edits apart from operations
# that move history: branch switch / reset / pull / rebase / commit.
# Prints "NOHEAD" if there are no commits yet.
cc_head() {
  local h
  h="$(cd "$1" 2>/dev/null && git rev-parse HEAD 2>/dev/null)"
  [ -n "$h" ] && printf '%s' "$h" || printf 'NOHEAD'
}

# Write the session baseline: line 1 = HEAD, line 2 = tree.
# $1 = project, $2 = snapshot file path, $3 = temp index path.
cc_write_snapshot() {
  local proj="$1" snap="$2" idx="$3" tree
  tree="$(cc_snapshot_tree "$proj" "$idx")"
  [ -n "$tree" ] || return 1
  printf '%s\n%s\n' "$(cc_head "$proj")" "$tree" > "$snap"
}

# Are we running inside a subagent (Task tool)? Only agent_id is reliable here:
# it is present ONLY when the hook fires inside a subagent call. agent_type is
# NOT used, because it is also set for a top-level `claude --agent <name>`
# session, which is not a subagent — keying on it would wrongly silence the
# plugin for that whole session. UserPromptSubmit is known to also fire on
# subagent completion, so the diff hook uses this to stay top-level scoped.
cc_is_subagent() {
  [ -n "$(cc_json agent_id)" ]
}

# Quick check: are we inside a git repository?
cc_in_git() {
  ( cd "$1" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 )
}
