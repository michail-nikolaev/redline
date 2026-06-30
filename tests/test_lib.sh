#!/usr/bin/env bash
# Unit tests for lib.sh helpers.
# shellcheck disable=SC2034  # CC_INPUT is consumed by sourced cc_* functions
. "$(dirname "$0")/helpers.sh"
. "$HOOKS/lib.sh"

# cc_json / cc_json_path
CC_INPUT='{"session_id":"abc","cwd":"/x","workspace":{"current_dir":"/ws"}}'
assert_eq "abc" "$(cc_json session_id)"               "cc_json reads top-level"
assert_eq "/ws" "$(cc_json_path '.workspace.current_dir')" "cc_json_path reads nested"
assert_empty "$(cc_json missing)"                     "cc_json empty for missing key"

# cc_project_dir precedence: cwd > workspace.current_dir > CLAUDE_PROJECT_DIR > PWD
CC_INPUT='{"cwd":"/from/cwd","workspace":{"current_dir":"/from/ws"}}'
assert_eq "/from/cwd" "$(CLAUDE_PROJECT_DIR=/env cc_project_dir)" "cwd wins over env (worktree-safety)"
CC_INPUT='{"workspace":{"current_dir":"/from/ws"}}'
assert_eq "/from/ws"  "$(CLAUDE_PROJECT_DIR=/env cc_project_dir)" "workspace.current_dir before env"
CC_INPUT='{}'
assert_eq "/env"      "$(CLAUDE_PROJECT_DIR=/env cc_project_dir)" "env is the fallback"

# cc_session_id: from payload, else stable project-path hash
CC_INPUT='{"session_id":"sess-1"}'
assert_eq "sess-1" "$(cc_session_id)" "session_id from payload"
CC_INPUT='{"cwd":"/some/proj"}'
A="$(cc_session_id)"; B="$(cc_session_id)"
assert_nonempty "$A" "fallback session id is non-empty"
assert_eq "$A" "$B"  "fallback session id is stable"

# cc_state_dir honours REDLINE_STATE_DIR and ends in /sessions
assert_eq "/tmp/xyz/sessions" "$(REDLINE_STATE_DIR=/tmp/xyz cc_state_dir)" "state dir override"
# default path is per-user (contains the uid) so shared /tmp can't collide
DEFAULT_SD="$(unset REDLINE_STATE_DIR; cc_state_dir)"
assert_contains "$DEFAULT_SD" "$(id -u)" "default state dir is per-user (contains uid)"
assert_contains "$DEFAULT_SD" "/sessions" "default state dir ends in /sessions"

# cc_in_git
NONREPO="$(mktemp -d)"; _track "$NONREPO"
cc_in_git "$NONREPO" && fail "cc_in_git false outside repo" || pass "cc_in_git false outside repo"
GITREPO="$(new_repo)"; cc_in_git "$GITREPO" && pass "cc_in_git true inside repo" || fail "cc_in_git true inside repo"

# cc_is_subagent keys on agent_id only
CC_INPUT='{"agent_id":"a1"}';                 cc_is_subagent && pass "subagent: agent_id present" || fail "subagent: agent_id present"
CC_INPUT='{"agent_type":"reviewer"}';         cc_is_subagent && fail "agent_type alone is NOT a subagent" || pass "agent_type alone is NOT a subagent"
CC_INPUT='{}';                                cc_is_subagent && fail "no agent fields => not subagent" || pass "no agent fields => not subagent"

# snapshot tree helpers agree on the same clean worktree
R="$(new_repo)"; printf 'a\n' > "$R/f.txt"; commit_all "$R" init
IDXA="$(mktemp -u)"; IDXB="$(mktemp -u)"; _track "$IDXA"; _track "$IDXB"
TA="$(cc_snapshot_tree "$R" "$IDXA")"
TB="$(cc_snapshot_tree_warm "$R" "$IDXB")"
assert_nonempty "$TA" "cc_snapshot_tree returns a tree"
assert_eq "$TA" "$TB" "throwaway and warm snapshots agree on a clean tree"

t_summary
