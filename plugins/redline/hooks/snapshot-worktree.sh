#!/usr/bin/env bash
# Snapshot the worktree into the session baseline (HEAD + tree). Fires at:
#   SessionStart — the baseline for the first turn. Skipped for source=compact:
#                  compaction is not a turn boundary, and re-baselining there
#                  would silently swallow manual edits pending since the last
#                  Stop (they would never be injected).
#   Stop         — end of every agent turn (the state it stopped at).
#   PostToolUse  — after every file-touching tool call DURING a turn, so the
#                  baseline follows the agent's own edits as it works. If the
#                  turn is then interrupted (Esc — Stop never fires), the next
#                  UserPromptSubmit diffs against the last tool call instead of
#                  the previous turn's end, so the agent's edits cannot be
#                  misattributed to the user.
# Prints NOTHING to stdout (SessionStart/PostToolUse stdout could reach context).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

cc_require_jq
cc_read_input

# Never (re-)baseline from subagent context: a subagent can run in a different
# cwd/worktree while sharing our session id, so its snapshot could replace the
# baseline with a tree from another directory. Its edits are captured anyway —
# by the main agent's PostToolUse for the Task tool, and at Stop.
cc_is_subagent && exit 0

EVENT="$(cc_json hook_event_name)"

# /compact and auto-compact fire SessionStart with source=compact mid-session.
# Not a turn boundary: keep the baseline (pending manual edits must survive to
# the next UserPromptSubmit) and the busy marker (auto-compact happens mid-turn)
# exactly as they are.
[ "$EVENT" = "SessionStart" ] && [ "$(cc_json source)" = "compact" ] && exit 0

PROJ="$(cc_project_dir)"
cc_in_git "$PROJ" || exit 0

SID="$(cc_session_id)"
STATE="$(cc_state_dir)"
cc_object_env "$PROJ" "$STATE/$SID.objects" || true

# Mid-turn snapshot: move the baseline forward but keep the busy marker — the
# turn is still running. Uses a persistent per-turn index so every tool call
# stays cheap; UserPromptSubmit drops that index once per turn.
if [ "$EVENT" = "PostToolUse" ]; then
  cc_write_snapshot_warm "$PROJ" "$STATE/$SID.snap" "$STATE/$SID.turn.idx" || true
  exit 0
fi

# Turn ended (Stop) or session begun (SessionStart): the agent is idle, waiting
# for you. Clear the busy marker that UserPromptSubmit set, so the status line
# resumes showing your manual-edit diff.
rm -f "$STATE/$SID.busy" 2>/dev/null || true

cc_write_snapshot "$PROJ" "$STATE/$SID.snap" "$STATE/$SID.idx" || true
exit 0
