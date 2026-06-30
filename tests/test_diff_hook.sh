#!/usr/bin/env bash
# UserPromptSubmit hook: banner (default) vs inline output, no-baseline
# self-heal, and silent re-baseline on history moves.
. "$(dirname "$0")/helpers.sh"

new_state
R="$(new_repo)"; printf 'a\n' > "$R/f.txt"; commit_all "$R" init
SID="s"

# No baseline yet: first UserPromptSubmit creates it and stays silent
assert_empty "$(run_diff "$SID" "$R")" "no baseline: first prompt is silent (self-heals)"

# Establish a baseline, make a manual edit
run_snapshot "$SID" "$R" >/dev/null
printf 'a\nb\nc\n' > "$R/f.txt"

# Default mode = banner: valid JSON with additionalContext + systemMessage
BANNER="$(run_diff "$SID" "$R")"
assert_eq "object" "$(printf '%s' "$BANNER" | jq -r 'type' 2>/dev/null)" "banner: emits a JSON object"
assert_eq "string" "$(printf '%s' "$BANNER" | jq -r '.hookSpecificOutput.additionalContext|type' 2>/dev/null)" "banner: additionalContext is a string"
assert_contains "$(printf '%s' "$BANNER" | jq -r '.systemMessage')" "redline" "banner: systemMessage names the plugin"
assert_eq "UserPromptSubmit" "$(printf '%s' "$BANNER" | jq -r '.hookSpecificOutput.hookEventName')" "banner: correct hookEventName"

# inline mode: plain text diff, not JSON
run_snapshot "$SID" "$R" >/dev/null
printf 'a\nb\nc\nd\n' > "$R/f.txt"
INLINE="$(REDLINE_DISPLAY=inline run_diff "$SID" "$R")"
assert_contains "$INLINE" "[redline]" "inline: human-readable header"
assert_contains "$INLINE" '```diff' "inline: contains a diff block"
printf '%s' "$INLINE" | jq -e . >/dev/null 2>&1 && fail "inline: not JSON" || pass "inline: not JSON"

# History move (commit) between turns -> silent re-baseline, no diff injected
run_snapshot "$SID" "$R" >/dev/null
printf 'a\nb\nc\nd\ne\n' > "$R/f.txt"; commit_all "$R" c2      # HEAD moves
assert_empty "$(run_diff "$SID" "$R")" "HEAD move: silent (no inter-branch delta injected)"

t_summary
