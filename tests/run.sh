#!/usr/bin/env bash
# Test runner for the redline plugin. Runs every tests/test_*.sh
# as its own process and aggregates pass/fail. Exit non-zero if any file fails.
#
#   bash tests/run.sh            # run all
#   bash tests/run.sh test_lib   # run a subset (prefix match)
set -uo pipefail
cd "$(dirname "$0")" || exit 2

for tool in bash git jq awk sed; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done

filter="${1:-}"
files=()
for t in test_*.sh; do
  [ -f "$t" ] || continue
  [ -n "$filter" ] && case "$t" in *"$filter"*) ;; *) continue;; esac
  files+=("$t")
done
[ "${#files[@]}" -gt 0 ] || { echo "no test files matched '${filter}'"; exit 2; }

failed=()
for t in "${files[@]}"; do
  printf '\n=== %s ===\n' "$t"
  if bash "$t"; then :; else failed+=("$t"); fi
done

printf '\n────────────────────────────\n'
if [ "${#failed[@]}" -eq 0 ]; then
  printf 'ALL %d test files passed\n' "${#files[@]}"
else
  printf '%d of %d test files FAILED: %s\n' "${#failed[@]}" "${#files[@]}" "${failed[*]}"
  exit 1
fi
