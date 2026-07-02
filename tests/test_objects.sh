#!/usr/bin/env bash
# Private object store: snapshots must not write blob/tree objects into the
# repo's .git/objects. They go to a per-session dir under the state dir
# (GIT_OBJECT_DIRECTORY, with the repo as an alternate for reads), which
# SessionEnd removes — while the injected diff and the status line keep
# working across the two stores.
. "$(dirname "$0")/helpers.sh"

new_state
R="$(new_repo)"; printf 'a\n' > "$R/f.txt"; commit_all "$R" init
SID="s"
OBJDIR="$STATE/sessions/$SID.objects"

count_repo_objects(){ find "$R/.git/objects" -type f 2>/dev/null | wc -l | tr -d ' '; }

BEFORE="$(count_repo_objects)"
run_snapshot "$SID" "$R" >/dev/null                    # baseline (writes a tree)
printf 'a\nedited\n' > "$R/f.txt"                      # manual edit (new blob)
STATUS="$(run_status_plain "$SID" "$R")"               # warm snapshot + render
BANNER="$(run_diff "$SID" "$R")"                       # trees + full diff (sets busy)
POST='{"hook_event_name":"PostToolUse","tool_name":"Edit"}'
run_snapshot "$SID" "$R" "$POST" >/dev/null            # warm mid-turn snapshot

assert_eq "$BEFORE" "$(count_repo_objects)" "repo .git/objects untouched by snapshots"
assert_nonempty "$(find "$OBJDIR" -type f 2>/dev/null)" "objects land in the private per-session store"
assert_contains "$(printf '%s' "$BANNER" | jq -r '.hookSpecificOutput.additionalContext')" \
  "f.txt" "injected diff still correct across the two stores"
assert_contains "$STATUS" "f.txt" "status line still renders across the two stores"

run_cleanup "$SID" "$R" >/dev/null
assert_no_file "$OBJDIR" "SessionEnd removes the object store"

t_summary
