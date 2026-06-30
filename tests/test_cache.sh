#!/usr/bin/env bash
# Status line render cache: reuse on unchanged tree, invalidate on content
# change (content-addressed key), repaint last frame when the index is locked.
. "$(dirname "$0")/helpers.sh"

new_state
R="$(new_repo)"; printf 'a\nb\nc\n' > "$R/f.txt"; commit_all "$R" init
SID="s"
run_snapshot "$SID" "$R" >/dev/null

printf 'a\nb\nc\nd\ne\n' > "$R/f.txt"           # +2
OUT1="$(run_status "$SID" "$R")"
assert_file "$STATE/sessions/$SID.status.cache" "render cache written"
KEY="$(head -n1 "$STATE/sessions/$SID.status.cache")"
assert_contains "$KEY" " " "cache key is '<old_tree> <new_tree>'"

# unchanged tree -> identical output (cache hit)
OUT2="$(run_status "$SID" "$R")"
assert_eq "$OUT1" "$OUT2" "unchanged tree: cache hit yields identical output"

# CONTENT change to an already-modified file -> must recompute, not stay stale
printf 'a\nb\nc\nd\ne\nf\ng\n' > "$R/f.txt"      # now +4
OUT3="$(run_status_plain "$SID" "$R")"
assert_contains "$OUT3" "+4" "content change invalidates cache (no stale counts)"

# index lock -> tree can't be built -> repaint last cached frame, not blank
: > "$STATE/sessions/$SID.status.idx.lock"
OUT4="$(run_status "$SID" "$R")"
rm -f "$STATE/sessions/$SID.status.idx.lock"
assert_nonempty "$OUT4" "locked index: repaints last frame instead of blank"

t_summary
