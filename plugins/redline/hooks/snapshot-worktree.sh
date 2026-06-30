#!/usr/bin/env bash
# Snapshot the worktree at the end of an agent turn (Stop) and at the start of a
# session (SessionStart — the baseline for the first turn). The snapshot file
# stores HEAD and tree. Prints NOTHING to stdout (SessionStart stdout would be
# injected into context).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

cc_require_jq
cc_read_input

# Defensive: Stop/SessionStart are top-level events and don't fire inside a
# subagent, but if that ever changes we must not re-baseline from subagent
# context. The main agent's own Stop will snapshot correctly.
cc_is_subagent && exit 0

PROJ="$(cc_project_dir)"
cc_in_git "$PROJ" || exit 0

SID="$(cc_session_id)"
STATE="$(cc_state_dir)"

# Turn ended (Stop) or session begun (SessionStart): the agent is idle, waiting
# for you. Clear the busy marker that UserPromptSubmit set, so the status line
# resumes showing your manual-edit diff.
rm -f "$STATE/$SID.busy" 2>/dev/null || true

cc_write_snapshot "$PROJ" "$STATE/$SID.snap" "$STATE/$SID.idx" || true
exit 0
