#!/usr/bin/env bash
# jq is a hard requirement: when it is missing the plugin goes inactive cleanly
# (empty stdout, a one-line stderr notice, exit 0) rather than breaking the host.
. "$(dirname "$0")/helpers.sh"

# Build a PATH shim that contains the usual tools but NOT jq.
SHIM="$(mktemp -d)"; _track "$SHIM"
for b in bash sh git awk sed cat tr cut head tail cksum mkdir rm find dirname printf grep sleep cp mktemp ls; do
  p="$(command -v "$b" 2>/dev/null)" && ln -s "$p" "$SHIM/$b" 2>/dev/null
done

JSON='{"session_id":"s","cwd":"/tmp"}'   # built without jq on purpose

OUT="$(printf '%s' "$JSON" | PATH="$SHIM" bash "$HOOKS/statusline.sh" 2>/dev/null)"
RC=$?
assert_empty "$OUT" "statusline: no stdout when jq is missing"
assert_status 0 "$RC" "statusline: exits 0 when jq is missing (does not break host)"

ERR="$(printf '%s' "$JSON" | PATH="$SHIM" bash "$HOOKS/statusline.sh" 2>&1 1>/dev/null)"
assert_contains "$ERR" "jq is required" "statusline: explains jq requirement on stderr"

# the snapshot hook is equally safe without jq
printf '%s' "$JSON" | PATH="$SHIM" bash "$HOOKS/snapshot-worktree.sh" >/dev/null 2>&1
assert_status 0 "$?" "snapshot hook: exits 0 when jq is missing"

t_summary
