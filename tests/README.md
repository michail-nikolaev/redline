# Tests

Pure bash + git + jq. No framework to install.

```bash
bash tests/run.sh            # run all test files
bash tests/run.sh worktree   # run only files whose name matches "worktree"
```

Each `test_*.sh` is a standalone script: it sources `helpers.sh` (assertions +
fixtures), runs `assert_*` calls, and ends with `t_summary`, whose exit status
(0 = all passed) becomes the file's exit status. `run.sh` executes every file in
its own process and aggregates the results.

| File | Area |
| --- | --- |
| `test_static.sh` | `bash -n` syntax, JSON validity, manifest + hooks wiring |
| `test_lib.sh` | `lib.sh` units: dir/session/state resolution, snapshot trees |
| `test_statusline.sh` | rendering, colours, binary, multi-line, `MAXFILES` cap |
| `test_busy.sh` | working-state marker, subagent guard, overrides |
| `test_gitignore.sh` | tracked-but-gitignored consistency |
| `test_cache.sh` | render cache reuse, invalidation, locked-index repaint |
| `test_diff_hook.sh` | `UserPromptSubmit` banner/inline, self-heal, HEAD move |
| `test_worktree.sh` | git worktree correctness, multi-session state |
| `test_manage_statusline.sh` | the `settings.json` installer |
| `test_jq.sh` | graceful inactivity when `jq` is missing |

Fixtures create throwaway git repos and an isolated `REDLINE_STATE_DIR`, all
cleaned up on exit. Tests never touch your real `~/.claude` settings (the
installer test runs against a fake `$HOME`).
