#!/usr/bin/env bash
# Working-state detection: UserPromptSubmit marks busy, Stop clears it, the
# status line hides the file list while busy. Subagent prompts must not flip it.
. "$(dirname "$0")/helpers.sh"

new_state
R="$(new_repo)"; printf 'x\n' > "$R/f.txt"; commit_all "$R" init
SID="s"

run_snapshot "$SID" "$R" >/dev/null          # SessionStart/Stop baseline
printf 'x\ny\n' > "$R/f.txt"                  # idle manual edit

# idle: shows the diff
assert_contains "$(run_status_plain "$SID" "$R")" "f.txt" "idle: shows manual edit"
assert_no_file "$STATE/sessions/$SID.busy" "no busy marker while idle"

# UserPromptSubmit -> busy, status switches to working marker
run_diff "$SID" "$R" >/dev/null
assert_file "$STATE/sessions/$SID.busy" "UserPromptSubmit set busy marker"
WORK="$(run_status "$SID" "$R")"
assert_contains "$WORK" "working" "working: shows working marker"
assert_not_contains "$WORK" "f.txt" "working: file list hidden"

# REDLINE_STATUS_WORKING override (empty hides entirely)
assert_empty "$(REDLINE_STATUS_WORKING='' run_status "$SID" "$R")" "empty STATUS_WORKING hides while busy"
assert_eq "BUSY" "$(REDLINE_STATUS_WORKING='BUSY' run_status "$SID" "$R")" "custom STATUS_WORKING honoured"

# Stop -> clears busy, re-baselines; status shows manual diff again
run_snapshot "$SID" "$R" >/dev/null
assert_no_file "$STATE/sessions/$SID.busy" "Stop cleared busy marker"
# after re-baseline the edit is folded in, so it's clean now
assert_empty "$(run_status "$SID" "$R")" "after Stop re-baseline: clean"

# A subagent UserPromptSubmit (agent_id present) must NOT set busy or emit a diff
run_snapshot "$SID" "$R" >/dev/null
SUBOUT="$(run_diff "$SID" "$R" '{"agent_id":"sub-1"}')"
assert_no_file "$STATE/sessions/$SID.busy" "subagent prompt does not set busy"
assert_empty "$SUBOUT" "subagent prompt emits no diff"

# --- interrupt handling via the cost.total_api_duration_ms activity signal -----
# The status line refreshes the marker when API time advances, and treats a
# marker that hasn't advanced within the TTL as idle (interrupted: no Stop fires).
run_snapshot "$SID" "$R" >/dev/null
printf 'x\ny\nz\n' > "$R/f.txt"
run_diff "$SID" "$R" >/dev/null               # busy created (empty)
BUSY="$STATE/sessions/$SID.busy"

# first tick with some API time -> working; marker records that api duration
W1="$(run_status "$SID" "$R" '{"cost":{"total_api_duration_ms":1000}}')"
assert_contains "$W1" "working" "api activity: working on first tick"
assert_eq "1000" "$(head -n1 "$BUSY")" "marker records last api duration"

# marker is stale, but API time ADVANCED -> refresh -> still working
backdate "$BUSY" 600
W2="$(run_status "$SID" "$R" '{"cost":{"total_api_duration_ms":2000}}')"
assert_contains "$W2" "working" "api advanced: marker refreshed, still working"

# marker stale and API time UNCHANGED (interrupted) -> idle, manual diff returns
backdate "$BUSY" 600
IDLE="$(run_status_plain "$SID" "$R" '{"cost":{"total_api_duration_ms":2000}}')"
assert_not_contains "$IDLE" "working" "api frozen (interrupt): not stuck on working"
assert_contains "$IDLE" "f.txt" "api frozen (interrupt): manual diff shown again"

# TTL is configurable
backdate "$BUSY" 3
assert_contains "$(REDLINE_STATUS_BUSY_TTL=1 run_status_plain "$SID" "$R" '{"cost":{"total_api_duration_ms":2000}}')" "f.txt" "low TTL expires busy quickly"
assert_contains "$(REDLINE_STATUS_BUSY_TTL=60 run_status "$SID" "$R" '{"cost":{"total_api_duration_ms":2000}}')" "working" "high TTL keeps busy active"

t_summary
