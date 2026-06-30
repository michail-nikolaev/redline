#!/usr/bin/env bash
# The installer: writes/removes statusLine in a settings.json surgically, backs
# it up, refuses to clobber a foreign status line, validates input, and supports
# user/project scope.
. "$(dirname "$0")/helpers.sh"

MS="$SCRIPTS/manage-statusline.sh"
export CLAUDE_PLUGIN_ROOT="$PLUGIN"
HOME_T="$(mktemp -d)"; _track "$HOME_T"
SETTINGS="$HOME_T/.claude/settings.json"
mh(){ HOME="$HOME_T" bash "$MS" "$@"; }   # run with fake HOME

# status with no settings file
assert_contains "$(mh status --user)" "none configured" "status: none configured initially"

# install (user scope, default refresh)
mh install --user >/dev/null
assert_eq "command" "$(jq -r .statusLine.type "$SETTINGS")" "install: type=command"
assert_contains "$(jq -r .statusLine.command "$SETTINGS")" "statusline.sh" "install: command points at statusline.sh"
assert_eq "2" "$(jq -r .statusLine.refreshInterval "$SETTINGS")" "install: default refreshInterval=2"
assert_file "$SETTINGS.redline.bak" "install: backup written"

# custom refresh
mh install --user --refresh 5 >/dev/null
assert_eq "5" "$(jq -r .statusLine.refreshInterval "$SETTINGS")" "install: --refresh honoured"

# preserves unrelated keys
tmp="$(mktemp)"; jq '.model="opus" | .env={"K":"v"}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
mh install --user >/dev/null
assert_eq "opus" "$(jq -r .model "$SETTINGS")" "install: preserves other keys (model)"
assert_eq "v"    "$(jq -r .env.K "$SETTINGS")" "install: preserves other keys (env)"

# bad refresh rejected (non-zero exit, settings untouched)
mh install --user --refresh abc >/dev/null 2>&1
assert_status 1 "$?" "install: rejects non-numeric --refresh"

# foreign status line: refuse without --force, replace with --force
tmp="$(mktemp)"; jq '.statusLine={type:"command",command:"other.sh"}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
mh install --user >/dev/null 2>&1
assert_status 1 "$?" "install: refuses to overwrite foreign status line"
assert_eq "other.sh" "$(jq -r .statusLine.command "$SETTINGS")" "install: foreign status line untouched"
mh install --user --force >/dev/null
assert_contains "$(jq -r .statusLine.command "$SETTINGS")" "statusline.sh" "install: --force replaces foreign"

# uninstall removes only our key, leaves the rest
mh uninstall --user >/dev/null
assert_eq "false" "$(jq 'has("statusLine")' "$SETTINGS")" "uninstall: statusLine key removed"
assert_eq "opus"  "$(jq -r .model "$SETTINGS")" "uninstall: other keys preserved"

# uninstall refuses a foreign status line
tmp="$(mktemp)"; jq '.statusLine={type:"command",command:"other.sh"}' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
mh uninstall --user >/dev/null 2>&1
assert_status 1 "$?" "uninstall: refuses foreign status line"

# project scope writes to ./.claude/settings.json
PROJ="$(mktemp -d)"; _track "$PROJ"
( cd "$PROJ" && HOME="$HOME_T" bash "$MS" install --project >/dev/null )
assert_file "$PROJ/.claude/settings.json" "install --project writes ./.claude/settings.json"

t_summary
