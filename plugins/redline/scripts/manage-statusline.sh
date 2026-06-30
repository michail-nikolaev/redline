#!/usr/bin/env bash
# Install / uninstall the redline status line in a Claude Code
# settings.json.
#
# Why a script instead of shipping it in the plugin: a plugin's own bundled
# settings.json may only declare the `agent` and `subagentStatusLine` keys — NOT
# the main `statusLine` (see code.claude.com/docs/en/plugins-reference, "Standard
# plugin layout"). So the status line must be written into the USER or PROJECT
# settings file. This does that edit with jq: surgically (every other key is
# preserved), with a backup, and it refuses to clobber a status line that isn't
# ours.
#
# Usage:
#   manage-statusline.sh install   [--user | --project] [--refresh N] [--force]
#   manage-statusline.sh uninstall [--user | --project]
#   manage-statusline.sh status    [--user | --project]
#
# Scope defaults to --user (~/.claude/settings.json). --project targets
# ./.claude/settings.json under the current directory. --refresh defaults to 2s
# (the status line caches between ticks, so a tight interval is cheap).
set -uo pipefail

err()  { printf '%s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }

command -v jq >/dev/null 2>&1 || { err "jq is required but was not found in PATH."; exit 1; }

# Resolve the plugin root (and thus the status line script) from CLAUDE_PLUGIN_ROOT
# when present, otherwise from this script's own location. The absolute path of
# statusline.sh is what we write into settings.json, so it must be stable.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATUSLINE="$PLUGIN_ROOT/hooks/statusline.sh"
CMD="bash \"$STATUSLINE\""

ACTION="${1:-}"
[ $# -gt 0 ] && shift || true

SCOPE="user"
REFRESH=2
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --user)        SCOPE="user" ;;
    --project)     SCOPE="project" ;;
    --refresh)     shift; REFRESH="${1:-}" ;;
    --refresh=*)   REFRESH="${1#*=}" ;;
    --force)       FORCE=1 ;;
    *)             err "unknown argument: $1"; exit 1 ;;
  esac
  shift
done

case "$SCOPE" in
  user)    SETTINGS="$HOME/.claude/settings.json" ;;
  project) SETTINGS="$PWD/.claude/settings.json" ;;
esac

# Is a currently-configured statusLine command one of ours?
is_ours() { case "$1" in *redline*statusline.sh*) return 0 ;; *) return 1 ;; esac; }

current_cmd() {
  [ -f "$SETTINGS" ] || { printf ''; return; }
  jq -r '.statusLine.command // empty' "$SETTINGS" 2>/dev/null
}

case "$ACTION" in
  install)
    [ -f "$STATUSLINE" ] || { err "status line script not found at: $STATUSLINE"; exit 1; }
    case "$REFRESH" in
      ''|*[!0-9]*) err "--refresh must be a positive integer (got: '$REFRESH')"; exit 1 ;;
    esac
    [ "$REFRESH" -ge 1 ] || { err "--refresh must be >= 1"; exit 1; }

    mkdir -p "$(dirname "$SETTINGS")" 2>/dev/null || true
    [ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
    jq -e . "$SETTINGS" >/dev/null 2>&1 || { err "$SETTINGS is not valid JSON; not touching it."; exit 1; }

    existing="$(current_cmd)"
    if [ -n "$existing" ] && ! is_ours "$existing"; then
      err "A different statusLine is already configured in $SETTINGS:"
      err "    $existing"
      if [ "$FORCE" != 1 ]; then
        err "Refusing to overwrite it. Re-run with --force to replace it."
        exit 1
      fi
      err "(--force given — replacing it.)"
    fi

    cp "$SETTINGS" "$SETTINGS.redline.bak" 2>/dev/null || true
    tmp="$(mktemp)"
    jq --arg cmd "$CMD" --argjson refresh "$REFRESH" \
       '.statusLine = {type:"command", command:$cmd, padding:0, refreshInterval:$refresh}' \
       "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

    note "Installed redline status line."
    note "  settings file : $SETTINGS"
    note "  command       : $CMD"
    note "  refreshInterval: ${REFRESH}s"
    note "  backup        : $SETTINGS.redline.bak"
    note ""
    note "It appears on the next status refresh. If it doesn't show up, start a new session."
    ;;

  uninstall)
    [ -f "$SETTINGS" ] || { note "No settings file at $SETTINGS — nothing to remove."; exit 0; }
    existing="$(current_cmd)"
    if [ -z "$existing" ]; then
      note "No statusLine configured in $SETTINGS — nothing to remove."
      exit 0
    fi
    if ! is_ours "$existing"; then
      err "The statusLine in $SETTINGS is not ours:"
      err "    $existing"
      err "Leaving it untouched."
      exit 1
    fi
    cp "$SETTINGS" "$SETTINGS.redline.bak" 2>/dev/null || true
    tmp="$(mktemp)"
    jq 'del(.statusLine)' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
    note "Removed the redline status line from $SETTINGS."
    note "Backup: $SETTINGS.redline.bak"
    ;;

  status|"")
    existing="$(current_cmd)"
    note "settings file : $SETTINGS"
    if [ -z "$existing" ]; then
      note "statusLine    : (none configured)"
    elif is_ours "$existing"; then
      note "statusLine    : $existing  (redline)"
      note "refreshInterval: $(jq -r '.statusLine.refreshInterval // "unset"' "$SETTINGS" 2>/dev/null)s"
    else
      note "statusLine    : $existing  (NOT redline)"
    fi
    ;;

  *)
    err "usage: manage-statusline.sh {install|uninstall|status} [--user|--project] [--refresh N] [--force]"
    exit 1
    ;;
esac
