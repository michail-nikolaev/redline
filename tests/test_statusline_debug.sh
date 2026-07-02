#!/usr/bin/env bash
# Status line debug mode (REDLINE_STATUS_DEBUG): a per-call random "tick" number
# plus a dump of the received stdin payload, short-circuiting the normal render.
. "$(dirname "$0")/helpers.sh"

new_state
R="$(new_repo)"
printf 'a\n' > "$R/f.txt"
commit_all "$R" init
SID="s"

# --- off by default -----------------------------------------------------------
# With a clean baseline and no debug env, the bar stays silent (existing
# behaviour) and never leaks debug output.
run_snapshot "$SID" "$R" >/dev/null
OFF="$(run_status "$SID" "$R")"
assert_empty "$OFF" "debug off: clean tree still silent"
assert_not_contains "$OFF" "redline debug" "debug off: no debug header"

# --- on: header + derived values + received params ----------------------------
# Wide COLUMNS so the (temp) paths and payload aren't clipped out from under the
# content assertions — clipping itself is exercised separately below.
ON="$(COLUMNS=200 REDLINE_STATUS_DEBUG=1 run_status "$SID" "$R")"
assert_contains "$ON" "redline debug"        "debug on: prints header"
assert_contains "$ON" "tick #"               "debug on: prints a tick number"
assert_contains "$ON" "dir=$R"               "debug on: reports resolved project dir"
assert_contains "$ON" "sid=$SID"             "debug on: reports session id"
assert_contains "$ON" "snap:present"         "debug on: detects the existing baseline"

# The received stdin JSON is echoed back — a field we injected shows up verbatim.
WITH_EXTRA="$(COLUMNS=200 REDLINE_STATUS_DEBUG=1 run_status "$SID" "$R" '{"model":{"display_name":"probe-9000"}}')"
assert_contains "$WITH_EXTRA" "probe-9000"   "debug on: echoes received params"
assert_contains "$WITH_EXTRA" "$SID"         "debug on: params include session_id"

# --- sizes every row to COLUMNS -----------------------------------------------
# Claude Code exports the bar width as COLUMNS. The summary/paths rows are clipped
# (tail-marked …); the payload wraps onto extra rows so no field is lost.
WIDE="$(COLUMNS=200 REDLINE_STATUS_DEBUG=1 run_status "$SID" "$R")"
assert_contains "$WIDE" "$STATE/sessions" "wide COLUMNS: full state path shown"
NARROW="$(COLUMNS=40 REDLINE_STATUS_DEBUG=1 run_status "$SID" "$R")"
assert_not_contains "$NARROW" "$STATE/sessions" "narrow COLUMNS: long paths row is clipped"
assert_contains "$NARROW" "…" "narrow COLUMNS: clipped rows are marked with an ellipsis"

# Payload WRAPS instead of clipping: a field that lands past the width in the
# compact JSON must still survive. Joining the rows back (dropping the wrap
# newlines) reproduces the payload, so the marker reappears contiguously.
WRAP="$(COLUMNS=40 REDLINE_STATUS_DEBUG=1 run_status "$SID" "$R" '{"model":{"display_name":"tail-marker-zzz"}}')"
assert_contains "$(printf '%s' "$WRAP" | tr -d '\n')" "tail-marker-zzz" \
  "narrow COLUMNS: payload wraps without losing trailing fields"
WRAP_LINES="$(printf '%s\n' "$WRAP" | grep -c .)"
[ "$WRAP_LINES" -ge 4 ] && pass "narrow COLUMNS: payload spills onto extra rows ($WRAP_LINES rows)" \
                        || fail "narrow COLUMNS: payload did not wrap" "rows: $WRAP_LINES"

# --- works before any baseline exists -----------------------------------------
# Normal render bails out when there is no snapshot; debug must still report,
# since its whole point is diagnosing a status line that shows nothing.
R2="$(new_repo)"; SID2="fresh"
printf 'x\n' > "$R2/x.txt"; commit_all "$R2" init
NOBASE="$(REDLINE_STATUS_DEBUG=1 run_status "$SID2" "$R2")"
assert_contains "$NOBASE" "redline debug"    "debug on: reports even with no baseline"
assert_contains "$NOBASE" "snap:none"        "debug on: flags the missing baseline"

# --- the tick number actually changes between calls ---------------------------
# "each call shows a random number" — collect the tick across several invocations
# and assert we see more than one distinct value (collision odds are negligible).
ticks="$(for _ in 1 2 3 4 5 6; do
           REDLINE_STATUS_DEBUG=1 run_status "$SID" "$R" | sed -n 's/.*tick #\([0-9][0-9]*\).*/\1/p'
         done)"
distinct="$(printf '%s\n' "$ticks" | sort -u | grep -c .)"
[ "$distinct" -gt 1 ] && pass "debug on: tick number varies between calls ($distinct distinct)" \
                      || fail "debug on: tick number never changed" "values: $ticks"

t_summary
