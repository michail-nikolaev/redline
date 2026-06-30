#!/usr/bin/env bash
# Static checks: shell syntax, JSON validity, manifest sanity, exec bits.
. "$(dirname "$0")/helpers.sh"

for f in "$HOOKS"/*.sh "$SCRIPTS"/*.sh "$TESTS_DIR"/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "bash -n $(basename "$f")"
  else fail "bash -n $(basename "$f")" "syntax error"; fi
done

for j in "$REPO_ROOT/.claude-plugin/marketplace.json" \
         "$PLUGIN/.claude-plugin/plugin.json" \
         "$HOOKS/hooks.json"; do
  if jq -e . "$j" >/dev/null 2>&1; then pass "valid JSON $(basename "$j")"
  else fail "valid JSON $(basename "$j")"; fi
done

# plugin.json has the required name/version
assert_eq "redline" "$(jq -r .name "$PLUGIN/.claude-plugin/plugin.json")" "plugin.json name"
assert_nonempty "$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")" "plugin.json version present"

# hooks.json wires the lifecycle events
for ev in SessionStart Stop UserPromptSubmit SessionEnd; do
  assert_eq "true" "$(jq --arg e "$ev" 'has("hooks") and (.hooks|has($e))' "$HOOKS/hooks.json")" "hooks.json wires $ev"
done

# entrypoints are executable
assert_eq "yes" "$([ -x "$HOOKS/statusline.sh" ] && echo yes || echo no)" "statusline.sh is executable"
assert_eq "yes" "$([ -x "$SCRIPTS/manage-statusline.sh" ] && echo yes || echo no)" "manage-statusline.sh is executable"

t_summary
