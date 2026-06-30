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
# cache; the .status.<pid>.idx glob mops up any throwaway index from older runs.
rm -f "$STATE/$SID.snap" "$STATE/$SID.idx" "$STATE/$SID.now.idx" \
      "$STATE/$SID.status.idx" "$STATE/$SID.status.cache" "$STATE/$SID.busy" \
      "$STATE/$SID".status.*.idx 2>/dev/null || true
# Anything older than 24h -> drop.
find "$STATE" -type f -mmin +1440 -delete 2>/dev/null || true
exit 0
