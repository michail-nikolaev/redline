#!/usr/bin/env bash
# UserPromptSubmit: compare this session's end-of-last-turn snapshot against the
# current worktree. The difference is the user's manual edits between turns.
# This hook's stdout (exit 0) is added to Claude's context.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

cc_require_jq
cc_read_input

# UserPromptSubmit also fires inside subagents (Task tool); those are not real
# user-edit boundaries and a subagent's own edits land at the main agent's Stop.
# Do nothing here so we never inject into a subagent or disturb the baseline.
cc_is_subagent && exit 0

PROJ="$(cc_project_dir)"
cc_in_git "$PROJ" || exit 0

SID="$(cc_session_id)"
STATE="$(cc_state_dir)"
SNAP="$STATE/$SID.snap"
cc_object_env "$PROJ" "$STATE/$SID.objects" || true

# A turn is starting => the (main) agent is now working. Mark it busy; Stop /
# SessionStart clear it. The status line uses this to hide the file list while
# the agent runs, since the worktree delta during a turn is the agent's own
# in-progress edits, not your manual ones. (Subagents were excluded above, so
# this only ever tracks the top-level agent.)
: > "$STATE/$SID.busy" 2>/dev/null || true

# Drop the PostToolUse hook's persistent per-turn index so it re-seeds from the
# repo's real index on the first tool call of this turn. This bounds any drift
# between its tracked-file set and the real one to a single turn.
rm -f "$STATE/$SID.turn.idx" 2>/dev/null || true

# No baseline yet (e.g. the plugin was enabled mid-session): set the baseline
# now and stay silent — diffing starts working from the next turn.
if [ ! -f "$SNAP" ]; then
  cc_write_snapshot "$PROJ" "$SNAP" "$STATE/$SID.idx" || true
  exit 0
fi

OLD_HEAD="$(sed -n '1p' "$SNAP")"
OLD_TREE="$(sed -n '2p' "$SNAP")"
[ -n "$OLD_TREE" ] || exit 0

CUR_HEAD="$(cc_head "$PROJ")"
NEW_TREE="$(cc_snapshot_tree "$PROJ" "$STATE/$SID.now.idx")"
[ -n "$NEW_TREE" ] || exit 0

# HEAD moved => branch switch / reset / pull / rebase / commit.
# That is not a manual edit. Reset the baseline and stay silent so Claude does
# not receive the whole inter-branch delta as if it were hand edits.
if [ "$OLD_HEAD" != "$CUR_HEAD" ]; then
  printf '%s\n%s\n' "$CUR_HEAD" "$NEW_TREE" > "$SNAP"
  exit 0
fi

STAT="$(cd "$PROJ" && git diff --stat "$OLD_TREE" "$NEW_TREE" 2>/dev/null)"
[ -n "$STAT" ] || exit 0   # the user changed nothing — stay silent

# Cap the diff we inject. Read one byte past the cap so "fits exactly" and
# "was cut" are distinguishable, and mark the diff as truncated ONLY when it
# actually was — a permanent "(truncated)" label makes the model assume context
# is missing. When we do cut, drop the partial last line too, so the model
# never sees a mangled hunk or a split multi-byte character; the --stat list
# above the diff stays complete either way.
MAX_BYTES="${REDLINE_MAX_BYTES:-20000}"
FULL="$(cd "$PROJ" && git diff "$OLD_TREE" "$NEW_TREE" 2>/dev/null | head -c "$((MAX_BYTES + 1))")"
if [ "$(printf '%s' "$FULL" | wc -c)" -gt "$MAX_BYTES" ]; then
  FULL="$(printf '%s' "$FULL" | head -c "$MAX_BYTES")"
  CUT="${FULL%$'\n'*}"           # cut at the last complete line…
  [ -n "$CUT" ] && FULL="$CUT"   # …unless the cap landed inside the first line
  DIFF_HEAD="Diff (truncated at ${MAX_BYTES} bytes; the file list above is complete):"
else
  DIFF_HEAD="Diff:"
fi

# What Claude receives. Stated as plain fact, no imperative — otherwise
# prompt-injection defenses can trigger and Claude surfaces this to the user
# instead of using it as context.
CONTEXT="$(printf '[redline] The user manually edited files in the working tree since the assistant'\''s previous turn.\n\nChanged files:\n%s\n\n%s\n```diff\n%s\n```' "$STAT" "$DIFF_HEAD" "$FULL")"

# Display mode controls what the *user* sees in the Claude Code interface:
#   banner (default) — emit JSON: the full diff goes to Claude discreetly via
#     additionalContext, and the user sees a short systemMessage summary banner
#     (so you always get visible confirmation, without the whole diff scrolling
#     your transcript).
#   inline — print to stdout. For UserPromptSubmit, stdout is BOTH added to
#     context AND shown as hook output in the transcript, so you see exactly the
#     bytes Claude received. Maximum transparency, but noisier.
MODE="${REDLINE_DISPLAY:-banner}"

if [ "$MODE" = "banner" ]; then
  SUMMARY="$(printf '%s' "$STAT" | tail -n1 | sed 's/^[[:space:]]*//')"
  jq -nc --arg ctx "$CONTEXT" \
         --arg msg "[redline] added your manual edits to context — ${SUMMARY}" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx},systemMessage:$msg}'
  exit 0
fi

printf '%s\n' "$CONTEXT"
exit 0
