#!/usr/bin/env bash
# statusLine command: print a compact one-line summary of the user's MANUAL edits
# since the assistant's previous turn — the same delta the UserPromptSubmit hook
# would inject — so you can SEE pending edits in the status bar between prompts.
#
# This is NOT a plugin hook: Claude Code only reads statusLine from user/project
# settings.json, and that command does not receive the plugin env vars
# (CLAUDE_PLUGIN_ROOT / CLAUDE_PLUGIN_DATA / CLAUDE_PROJECT_DIR). So this script
# is fully self-locating (it sources lib.sh from its own directory) and reads the
# project dir from the stdin JSON's `cwd`. Wire it up with an absolute path; see
# the README ("Status line").
#
# READ-ONLY by contract: it must NEVER write or move the snapshot. The snapshot
# is owned by the Stop / SessionStart hooks; if the status line re-baselined, it
# would erase the very edits the next UserPromptSubmit is supposed to report.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$DIR/lib.sh"

cc_require_jq
cc_read_input

# ── Debug mode ───────────────────────────────────────────────────────────────
# When REDLINE_STATUS_DEBUG is set to anything non-empty, short-circuit the
# normal render and print diagnostics instead. Two purposes:
#   1. A fresh random number every invocation ("tick #NNNNN"), so you can SEE the
#      status line is actually being called, and how often — the real output is
#      usually empty (clean tree) or served from cache, so a live status line is
#      otherwise indistinguishable from a dead/misconfigured one.
#   2. A dump of the exact stdin payload Claude Code handed us, plus the values we
#      derive from it (project dir, session id, state paths, whether the snapshot
#      / busy markers exist), so you can see why it renders what it does.
# Kept DENSE — a summary line, the derived paths, then the whole payload compacted
# onto one line (jq -c). All rows are sized to COLUMNS (which Claude Code exports
# to the script; see the main render below): the summary/paths rows are CLIPPED,
# tail-marked with … (their tails are decorative or derivable), while the payload
# is WRAPPED onto as many COLUMNS-wide rows as it needs, so no field is ever lost.
# This runs before any git or snapshot work, so it reports even outside a repo or
# before the first baseline exists. Everything is printed as ordinary status rows.
if [ -n "${REDLINE_STATUS_DEBUG:-}" ]; then
  _PROJ="$(cc_project_dir)"
  _SID="$(cc_session_id)"
  _STATE="$(cc_state_dir)"
  _COLS="${COLUMNS:-80}"; case "$_COLS" in ''|*[!0-9]*) _COLS=80 ;; esac
  [ "$_COLS" -ge 10 ] || _COLS=10
  # Clip to _COLS chars, appending … when truncated (so the row is at most _COLS).
  _clip() { local s="$1"; if [ "${#s}" -gt "$_COLS" ]; then printf '%s…\n' "${s:0:_COLS-1}"; else printf '%s\n' "$s"; fi; }
  # Wrap onto successive _COLS-wide rows instead of truncating — loses no data.
  _fold() { local s="$1"; while [ "${#s}" -gt "$_COLS" ]; do printf '%s\n' "${s:0:_COLS}"; s="${s:_COLS}"; done; printf '%s\n' "$s"; }
  _clip "$(printf '🔎 redline debug · tick #%s · git:%s snap:%s busy:%s' \
    "$RANDOM" \
    "$(cc_in_git "$_PROJ" && echo yes || echo no)" \
    "$([ -f "$_STATE/$_SID.snap" ] && echo present || echo none)" \
    "$([ -f "$_STATE/$_SID.busy" ] && echo present || echo none)")"
  _clip "sid=$_SID dir=$_PROJ state=$_STATE"
  _fold "$(printf '%s' "${CC_INPUT:-}" | jq -c . 2>/dev/null || printf '%s' "${CC_INPUT:-(empty)}")"
  exit 0
fi

PROJ="$(cc_project_dir)"
cc_in_git "$PROJ" || exit 0

SID="$(cc_session_id)"
STATE="$(cc_state_dir)"
SNAP="$STATE/$SID.snap"

# No baseline yet (session predates the plugin, or no turn has ended). Stay
# silent rather than creating one — only the snapshot hooks may write it.
[ -f "$SNAP" ] || exit 0

# Is the agent working? UserPromptSubmit creates a busy marker at turn start;
# Stop / SessionStart / SessionEnd remove it. While the agent works the worktree
# delta is its own in-progress edits, not yours, so we hide the file list and
# show a minimal marker instead.
#
# Telling "working" from "interrupted" is the hard part: a user interrupt (Esc)
# ends the turn WITHOUT firing Stop, so the marker would otherwise stay set and
# the bar would be stuck on "working…" forever. There is no interrupt hook and no
# "is working" flag in the params (and OpenTelemetry only exports remotely), so
# we use a signal from our own params: cost.total_api_duration_ms is cumulative
# and only advances while the agent is waiting on the model, so it grows during a
# turn and freezes the moment the agent goes idle. Each tick we refresh the
# marker's mtime when that counter advances (and on the first tick of a turn). If
# the marker then hasn't been refreshed within REDLINE_STATUS_BUSY_TTL seconds
# (default 40), the turn is idle/interrupted and we fall through to the diff.
# Set REDLINE_STATUS_WORKING="" to show nothing at all while working.
#
# That heartbeat freezes during a long-running Bash command (a build, test run,
# clone) because no model calls happen — so we ALSO treat a live Bash tool
# command as activity (cc_command_running): while one runs we keep the marker
# fresh, and when it is interrupted the killed process vanishes so we self-heal
# via the same TTL. See lib.sh for how that command is detected.
#
# Tracking issue for a first-class interrupt/turn-end signal:
#   https://github.com/anthropics/claude-code/issues/9516
BUSY="$STATE/$SID.busy"
if [ -f "$BUSY" ]; then
  API="$(cc_json_path '.cost.total_api_duration_ms')"; API="${API%%.*}"
  case "$API" in ''|*[!0-9]*) API=0 ;; esac
  PREV="$(head -n1 "$BUSY" 2>/dev/null)"
  case "$PREV" in ''|*[!0-9]*) PREV=-1 ;; esac     # empty => freshly created -> init
  # Refresh the marker on activity: either the API heartbeat advanced, OR a Bash
  # tool command is still running (a long command => heartbeat frozen but not
  # idle). touch (not rewrite) in the command case so we don't disturb the
  # recorded counter on line 1 that the API-advance check above depends on.
  if   [ "$API" -gt "$PREV" ]; then printf '%s\n' "$API" > "$BUSY"   # activity (or init)
  elif cc_command_running;      then touch "$BUSY" 2>/dev/null || :   # long command still running
  fi
  if [ "$(cc_file_age "$BUSY")" -lt "${REDLINE_STATUS_BUSY_TTL:-40}" ]; then
    printf '%s' "${REDLINE_STATUS_WORKING-⏳ agent turn…}"
    exit 0
  fi
fi

OLD_HEAD="$(sed -n '1p' "$SNAP")"
OLD_TREE="$(sed -n '2p' "$SNAP")"
[ -n "$OLD_TREE" ] || exit 0

# HEAD moved (branch switch / reset / pull / rebase / commit). The stored tree
# belongs to a different point in history, so a diff against it would be the
# whole inter-branch delta, not your edits. Show nothing and let the next
# UserPromptSubmit re-baseline. (We must not re-baseline here — read-only.)
CUR_HEAD="$(cc_head "$PROJ")"
[ "$OLD_HEAD" = "$CUR_HEAD" ] || exit 0

# Snapshot the current tree using a PERSISTENT, warm index (see lib.sh) so this
# stays cheap when it runs every few seconds. CACHE holds the last render keyed
# by "<old_tree> <new_tree>"; if the tree is unchanged since the last tick we
# reuse it and skip the (more expensive) diff + render below.
IDX="$STATE/$SID.status.idx"
CACHE="$STATE/$SID.status.cache"

# Keep the persistent index in step with the baseline. The index remembers which
# files are tracked; if that set drifts from the snapshot's (a new turn was
# snapshotted, or the user staged/untracked files), drop the index so the warm
# helper re-seeds it from the real index. The snapshot file is rewritten every
# turn, so "snap newer than index" re-seeds once per turn and the rest of the
# turn's ticks stay warm. This bounds any drift to a single turn.
[ -f "$IDX" ] && [ "$SNAP" -nt "$IDX" ] && rm -f "$IDX"
NEW_TREE="$(cc_snapshot_tree_warm "$PROJ" "$IDX")"

# Couldn't compute a tree (e.g. the index was momentarily locked by an
# overlapping tick): repaint the last frame instead of flickering to blank.
if [ -z "$NEW_TREE" ]; then
  [ -f "$CACHE" ] && tail -n +2 "$CACHE"
  exit 0
fi

# Identical tree => no manual edits. Print the configurable "clean" string
# (empty by default, so the status line stays quiet when there is nothing).
if [ "$OLD_TREE" = "$NEW_TREE" ]; then
  printf '%s' "${REDLINE_STATUS_CLEAN:-}"
  exit 0
fi

# Display settings that affect the rendered text. They are part of the cache key
# so a change (e.g. toggling NO_COLOR or REDLINE_STATUS_MAXFILES) takes effect
# on the next tick even when the tree itself is unchanged.
#   Colours are ON by default — Claude Code renders ANSI in the status line.
#   Disable with REDLINE_STATUS_COLOR=never or by exporting NO_COLOR.
COLOR=1
[ "${REDLINE_STATUS_COLOR:-}" = "never" ] && COLOR=0
[ -n "${NO_COLOR:-}" ] && COLOR=0
PREFIX="${REDLINE_STATUS_PREFIX:-✎}"
MAXF="${REDLINE_STATUS_MAXFILES:-10}"
# Terminal width. Claude Code captures our stdout (so tput/ioctl can't read the
# size), but it exports COLUMNS/LINES to the script — read those. Default to 80
# when unset (older Claude Code, or a non-interactive run). We size to width
# only; row count is bounded by REDLINE_STATUS_MAXFILES, so LINES is not used.
COLS="${COLUMNS:-80}"

# Cache hit: same baseline + worktree tree + display settings as last time.
KEY="$OLD_TREE $NEW_TREE c=$COLOR m=$MAXF w=$COLS p=$PREFIX"
if [ -f "$CACHE" ] && [ "$(head -n1 "$CACHE")" = "$KEY" ]; then
  tail -n +2 "$CACHE"
  exit 0
fi

# Per-file, git-coloured summary. We pull two views of the same diff:
#   --name-status : the change letter per file (A/M/D/R/C)
#   --numstat     : added / deleted line counts per file ("-" for binary)
# core.quotePath=false keeps non-ASCII paths literal instead of \xxx-escaped.
NS="$(cd "$PROJ" && git -c core.quotePath=false diff --name-status "$OLD_TREE" "$NEW_TREE" 2>/dev/null)"
NUM="$(cd "$PROJ" && git -c core.quotePath=false diff --numstat   "$OLD_TREE" "$NEW_TREE" 2>/dev/null)"
[ -n "$NUM" ] || exit 0

# Build a MULTI-LINE display in awk (each printed line is a separate status row,
# per the Claude Code docs). Layout, git-style:
#   <prefix> N files +A -B          <- summary header
#     M path/to/file.ts   +12 -3    <- one row per file: change letter, path,
#     A new.go            +5            line counts. Letter A=green M=yellow
#     D old.txt              -8         D=red R/C=cyan; +adds green, -dels red.
#     +K more                       <- only if the list is capped
# Paths are padded to a common width so the count columns line up like git, and
# truncated (keeping the tail, e.g. ".../Button.tsx") so no row exceeds COLS.
RENDER="$(awk -F'\t' \
    -v prefix="$PREFIX" -v color="$COLOR" -v maxf="$MAXF" -v cols="$COLS" '
BEGIN {
  R="\033[31m"; G="\033[32m"; Y="\033[33m"; B="\033[34m"; C="\033[36m"; DIM="\033[2m"; X="\033[0m"
  if (!color) { R=G=Y=B=C=DIM=X="" }
  n=0; totA=0; totD=0
}
# pass 1 — name-status: remember the change letter for each path
FNR==NR {
  if ($1=="") next
  l=substr($1,1,1); p=$2
  if ((l=="R"||l=="C") && NF>=3) p=$3   # use the new name for renames/copies
  st[p]=l
  next
}
# pass 2 — numstat: the authoritative file list, with counts
{
  if (NF<3) next
  n++; add[n]=$1; del[n]=$2; files[n]=$3
  l=st[$3]; type[n]=(l==""?"M":l)
  if ($1!="-") totA+=$1
  if ($2!="-") totD+=$2
}
END {
  if (n==0) exit
  if (cols+0 < 1) cols = 80
  cap  = (maxf+0>0 ? maxf+0 : n)
  show = (n<cap ? n : cap)

  # Build the count cell per row (coloured) and measure its VISIBLE width, and
  # track the widest path. Both feed the width math below.
  maxlen=0; maxcnt=0
  for (i=1;i<=show;i++) {
    if (add[i]=="-" || del[i]=="-") { cnt[i]=DIM "(bin)" X; cw=5 }
    else {
      s=""; cw=0
      if (add[i]+0>0) { s=G "+" add[i] X; cw=1+length(add[i]) }
      if (del[i]+0>0) { s=s (s!=""?" ":"") R "-" del[i] X; cw=cw+(cw>0?1:0)+1+length(del[i]) }
      if (s=="") { s=DIM "." X; cw=1 }
      cnt[i]=s
    }
    cwv[i]=cw
    if (cw>maxcnt) maxcnt=cw
    if (length(files[i])>maxlen) maxlen=length(files[i])
  }

  # Path column width, bounded so the widest row fits COLS. A row is:
  #   2 (indent) + 1 (letter) + 1 (space) + pathcol + 2 (gap) + counts
  avail = cols - (6 + maxcnt)
  pathcol = maxlen
  if (avail >= 1 && pathcol > avail) pathcol = avail
  if (pathcol < 1) pathcol = 1

  # summary header (short by construction; not truncated)
  printf "%s%s%s %d file%s %s+%d%s %s-%d%s\n", \
    C, prefix, X, n, (n==1?"":"s"), G, totA, X, R, totD, X

  # one row per file, path left-truncated to pathcol (keep the tail)
  for (i=1;i<=show;i++) {
    p=files[i]
    if (length(p) > pathcol) {
      if (pathcol > 3) p = "..." substr(p, length(p)-(pathcol-3)+1)
      else             p = substr(p, length(p)-pathcol+1)
    }
    l=type[i]
    lc = (l=="A"?G : l=="D"?R : (l=="R"||l=="C")?C : Y)
    printf "  %s%s%s %-*s  %s\n", lc, l, X, pathcol, p, cnt[i]
  }

  if (n>show) printf "  %s+%d more%s\n", DIM, n-show, X
}
' <(printf '%s\n' "$NS") <(printf '%s\n' "$NUM"))"

# Store the render keyed by the tree pair so the next tick can reuse it, then
# print it. ($() stripped trailing newlines; we re-add exactly one.)
printf '%s\n%s\n' "$KEY" "$RENDER" > "$CACHE" 2>/dev/null || true
printf '%s\n' "$RENDER"
exit 0
