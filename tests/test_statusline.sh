#!/usr/bin/env bash
# Status line rendering: clean/edit, per-file rows, colours, binary, cap.
. "$(dirname "$0")/helpers.sh"

new_state
R="$(new_repo)"
printf 'a\nb\nc\n' > "$R/mod.txt"
printf 'x\ny\n'     > "$R/del.txt"
commit_all "$R" init
SID="s"

# baseline, then a clean tree -> empty
run_snapshot "$SID" "$R" >/dev/null
assert_empty "$(run_status "$SID" "$R")" "clean tree shows nothing"

# make varied edits
printf 'a\nB\nc\nd\ne\n' > "$R/mod.txt"   # modify (+2 -1 vs baseline... +2)
rm "$R/del.txt"                            # delete
printf 'new\n' > "$R/new.txt"              # add
printf '\x00\x01\x02' > "$R/img.bin"       # add binary

PLAIN="$(run_status_plain "$SID" "$R")"
assert_contains "$PLAIN" "4 files"        "header counts files"
assert_contains "$PLAIN" "M mod.txt"      "modified file row"
assert_contains "$PLAIN" "D del.txt"      "deleted file row"
assert_contains "$PLAIN" "A new.txt"      "added file row"
assert_contains "$PLAIN" "(bin)"          "binary file shows (bin)"

# colours present by default, absent with NO_COLOR / never
RAW="$(run_status "$SID" "$R")"
assert_contains "$RAW" "$(printf '\033[')" "ANSI colour present by default"
assert_not_contains "$(NO_COLOR=1 run_status "$SID" "$R")" "$(printf '\033[')" "NO_COLOR strips colour"
assert_not_contains "$(REDLINE_STATUS_COLOR=never run_status "$SID" "$R")" "$(printf '\033[')" "STATUS_COLOR=never strips colour"

# multi-line: header + one row per shown file
LINES="$(run_status_plain "$SID" "$R" | grep -c .)"
assert_eq "5" "$LINES" "one header + four file rows"

# MAXFILES cap adds a '+N more' row
CAP="$(REDLINE_STATUS_MAXFILES=2 run_status_plain "$SID" "$R")"
assert_contains "$CAP" "more" "capped list ends with '+N more'"

# custom clean string
printf 'a\nB\nc\nd\ne\n' > "$R/mod.txt"; rm -f "$R/new.txt" "$R/img.bin"; printf 'x\ny\n' > "$R/del.txt"
# revert everything to baseline content
printf 'a\nb\nc\n' > "$R/mod.txt"
assert_eq "clean!" "$(REDLINE_STATUS_CLEAN='clean!' run_status "$SID" "$R")" "custom clean string honoured"

# ---- COLUMNS-based width sizing (Claude Code exports COLUMNS to the script) ----
R2="$(new_repo)"; SID2="w"
mkdir -p "$R2/src/components/very/deeply/nested"
LONG="src/components/very/deeply/nested/SuperLongComponentName.tsx"
printf 'x\n' > "$R2/$LONG"; commit_all "$R2" init
run_snapshot "$SID2" "$R2" >/dev/null
printf 'x\ny\n' > "$R2/$LONG"   # one modified file with a long path

# wide terminal: full path, untruncated
WIDE="$(COLUMNS=120 run_status_plain "$SID2" "$R2")"
assert_contains "$WIDE" "$LONG" "wide COLUMNS: full path shown"

# narrow terminal: every row fits within COLUMNS, path truncated keeping the tail
NARROW="$(COLUMNS=40 run_status_plain "$SID2" "$R2")"
WIDEST="$(printf '%s\n' "$NARROW" | awk '{ if (length>m) m=length } END{ print m+0 }')"
[ "$WIDEST" -le 40 ] && pass "narrow COLUMNS: no row exceeds width ($WIDEST<=40)" \
                      || fail "narrow COLUMNS: a row exceeds width" "widest=$WIDEST"
assert_contains "$NARROW" "..." "narrow COLUMNS: long path truncated with ellipsis"
assert_contains "$NARROW" "SuperLongComponentName.tsx" "narrow COLUMNS: keeps the path tail (filename)"

# COLUMNS participates in the cache key (changing it re-renders, not stale-cached)
assert_not_contains "$NARROW" "$LONG" "narrow render differs from wide (COLUMNS busts the cache)"

t_summary
