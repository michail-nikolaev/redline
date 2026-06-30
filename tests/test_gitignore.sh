#!/usr/bin/env bash
# Tracked-but-gitignored files (e.g. a committed .idea/ later added to
# .gitignore) must not appear as phantom diffs on a clean tree, but real edits
# to them must be reported. Truly untracked + ignored files stay excluded.
. "$(dirname "$0")/helpers.sh"

new_state
R="$(new_repo)"
mkdir "$R/.idea"; printf '<x/>\n' > "$R/.idea/cfg.xml"; printf 'code\n' > "$R/main.py"
commit_all "$R" init
printf '.idea/\n' > "$R/.gitignore"; commit_all "$R" ignore   # .idea now tracked AND ignored
SID="s"

run_snapshot "$SID" "$R" >/dev/null
assert_empty "$(run_status "$SID" "$R")" "clean tree: no phantom tracked-ignored entries"

# editing a tracked-ignored file is a real change -> reported
printf '<x/>\n<y/>\n' > "$R/.idea/cfg.xml"
assert_contains "$(run_status_plain "$SID" "$R")" ".idea/cfg.xml" "tracked-ignored edit is reported"

# a brand-new untracked file inside the ignored dir must NOT be reported
printf 'log\n' > "$R/.idea/junk.log"
assert_not_contains "$(run_status_plain "$SID" "$R")" "junk.log" "untracked + ignored file excluded"

t_summary
