#!/usr/bin/env bash
# Git worktree correctness: the hooks and status line must operate on the same
# worktree (resolved from cwd, never from CLAUDE_PROJECT_DIR), use the
# per-worktree index, read the worktree's HEAD, and keep per-session state.
. "$(dirname "$0")/helpers.sh"

new_state
MAIN="$(new_repo)"
printf 'main\n' > "$MAIN/app.py"; commit_all "$MAIN" init

WT="$(mktemp -d)"; rm -rf "$WT"; _track "$WT"     # let git create it
git -C "$MAIN" worktree add -q "$WT" -b feature >/dev/null
git -C "$WT" config user.email test@example.com; git -C "$WT" config user.name Test
printf 'feat\n' > "$WT/feature.py"; commit_all "$WT" feat
SID="wt"

# The crux: hooks may receive CLAUDE_PROJECT_DIR pointing at the ORIGINAL repo,
# while cwd is the worktree. The status line never gets that env. Both must
# still agree on the worktree -> a clean worktree shows nothing.
payload "$SID" "$WT" | CLAUDE_PROJECT_DIR="$MAIN" bash "$HOOKS/snapshot-worktree.sh" >/dev/null
assert_empty "$(run_status "$SID" "$WT")" "worktree clean despite CLAUDE_PROJECT_DIR=original"

# an edit in the worktree is detected
printf 'feat\nedit\n' > "$WT/feature.py"
assert_contains "$(run_status_plain "$SID" "$WT")" "feature.py" "worktree edit detected"

# HEAD-move detection uses the worktree's own HEAD
run_snapshot "$SID" "$WT" >/dev/null
printf 'feat\nedit\nmore\n' > "$WT/feature.py"; commit_all "$WT" c2
assert_empty "$(run_status "$SID" "$WT")" "worktree commit treated as history move (silent)"

# the snapshot used the per-worktree index path
IDXPATH="$(cd "$WT" && git rev-parse --git-path index)"
assert_contains "$IDXPATH" "worktrees" "per-worktree index path resolved"

# two sessions (main + worktree) keep independent state, no clobber
run_snapshot "main-sess" "$MAIN" >/dev/null
run_snapshot "$SID"      "$WT"   >/dev/null
assert_file "$STATE/sessions/main-sess.snap" "main session snapshot exists"
assert_file "$STATE/sessions/$SID.snap"      "worktree session snapshot exists"

t_summary
