#!/usr/bin/env bash
# SessionEnd: remove this session's snapshot and clean up stale orphans (in case
# of abnormal exits where SessionEnd did not fire).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

cc_require_jq
cc_read_input
SID="$(cc_session_id)"
STATE="$(cc_state_dir)"

# status.idx / status.cache are the status line's persistent index and render
# cache; turn.idx is the PostToolUse hook's per-turn index; the .status.<pid>.idx
# and .snap.tmp.* globs mop up throwaway/orphaned files from older runs.
rm -f "$STATE/$SID.snap" "$STATE/$SID.idx" "$STATE/$SID.now.idx" \
      "$STATE/$SID.turn.idx" \
      "$STATE/$SID.status.idx" "$STATE/$SID.status.cache" "$STATE/$SID.busy" \
      "$STATE/$SID".status.*.idx "$STATE/$SID".snap.tmp.* 2>/dev/null || true
# The session's private object store (see cc_object_env in lib.sh).
rm -rf "$STATE/$SID.objects" 2>/dev/null || true
# Anything older than 24h -> drop (also prunes object files of dead sessions);
# then remove the empty directory skeletons that leaves behind.
find "$STATE" -type f -mmin +1440 -delete 2>/dev/null || true
find "$STATE" -mindepth 1 -type d -empty -delete 2>/dev/null || true
exit 0
