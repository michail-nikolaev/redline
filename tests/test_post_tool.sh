#!/usr/bin/env bash
# PostToolUse mid-turn snapshots: the baseline follows the agent's own edits so
# an interrupted turn (Esc — Stop never fires) cannot misattribute them to the
# user. And SessionStart(source=compact) must NOT re-baseline: manual edits
# pending since the last Stop have to survive compaction.
. "$(dirname "$0")/helpers.sh"

new_state
R="$(new_repo)"; printf 'a\n' > "$R/f.txt"; commit_all "$R" init
SID="s"
POST='{"hook_event_name":"PostToolUse","tool_name":"Edit"}'

# ── interrupted turn ─────────────────────────────────────────────────────────
run_snapshot "$SID" "$R" >/dev/null                    # turn N ends (baseline)
assert_empty "$(run_diff "$SID" "$R")" "clean tree: prompt is silent"   # turn N+1 starts

# the agent edits mid-turn; PostToolUse moves the baseline but keeps busy
T0="$(sed -n 2p "$STATE/sessions/$SID.snap")"
printf 'a\nagent-edit\n' > "$R/f.txt"
run_snapshot "$SID" "$R" "$POST" >/dev/null
T1="$(sed -n 2p "$STATE/sessions/$SID.snap")"
[ "$T0" != "$T1" ] && pass "PostToolUse moves the baseline" \
                   || fail "PostToolUse moves the baseline" "tree unchanged"
assert_file "$STATE/sessions/$SID.busy" "PostToolUse keeps the busy marker"
assert_file "$STATE/sessions/$SID.turn.idx" "PostToolUse uses the per-turn index"

# turn is interrupted here (no Stop). Next prompt: the agent's own edit must
# NOT come back as a "manual user edit".
assert_empty "$(run_diff "$SID" "$R")" "interrupt: agent edits not misattributed to the user"
assert_no_file "$STATE/sessions/$SID.turn.idx" "UserPromptSubmit drops the per-turn index"

# a user edit made AFTER the last tool call of an interrupted turn IS reported
printf 'a\nagent-edit\n' > "$R/f.txt"                  # unchanged agent state
run_snapshot "$SID" "$R" "$POST" >/dev/null            # agent's last tool call
printf 'user-edit\n' > "$R/u.txt"                      # user edits, then prompts
CTX="$(run_diff "$SID" "$R" | jq -r '.hookSpecificOutput.additionalContext')"
assert_contains     "$CTX" "u.txt" "interrupt: user's own late edit still reported"
assert_not_contains "$CTX" "agent-edit" "interrupt: agent's edit absent from the diff"

# subagent PostToolUse never touches the baseline (may run in another worktree)
run_snapshot "$SID" "$R" >/dev/null
BEFORE="$(cat "$STATE/sessions/$SID.snap")"
printf 'sub\n' > "$R/sub.txt"
run_snapshot "$SID" "$R" '{"hook_event_name":"PostToolUse","agent_id":"a1"}' >/dev/null
assert_eq "$BEFORE" "$(cat "$STATE/sessions/$SID.snap")" "subagent PostToolUse leaves the baseline alone"
rm -f "$R/sub.txt"

# ── compaction ───────────────────────────────────────────────────────────────
run_snapshot "$SID" "$R" >/dev/null                    # clean baseline, busy cleared
printf 'a\nagent-edit\nmanual\n' > "$R/f.txt"          # user edits between turns
: > "$STATE/sessions/$SID.busy"                        # pretend auto-compact mid-turn
run_snapshot "$SID" "$R" '{"hook_event_name":"SessionStart","source":"compact"}' >/dev/null
assert_file "$STATE/sessions/$SID.busy" "compact keeps the busy marker"
CTX="$(run_diff "$SID" "$R" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)"
assert_contains "$CTX" "f.txt" "manual edit survives compaction and is injected"

# a real SessionStart (startup) still re-baselines and clears busy
printf 'a\nagent-edit\nmanual\nmore\n' > "$R/f.txt"
run_snapshot "$SID" "$R" '{"hook_event_name":"SessionStart","source":"startup"}' >/dev/null
assert_no_file "$STATE/sessions/$SID.busy" "startup clears the busy marker"
assert_empty "$(run_diff "$SID" "$R")" "startup re-baselines (next prompt silent)"

t_summary
