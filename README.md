# redline

A Claude Code plugin that feeds the agent your **manual working-tree edits made
between its turns**, as a `git diff`.

Most coding agents only see your hand edits when they happen to re-read a file.
This plugin makes the awareness explicit and proactive: whenever you edit files
yourself between the agent's turns, the next prompt carries a diff of exactly
what you changed into Claude's context.

## Install

### 1. Install the plugin

**Option A — skills-directory plugin (simplest, has a toggle).** Clone the repo
and drop the plugin folder into your skills directory; it is picked up with no
marketplace step:

```bash
git clone https://github.com/michail-nikolaev/redline.git
cp -r redline/plugins/redline ~/.claude/skills/
```

On the next session it appears in `/plugin` as `redline@skills-dir` and can be
enabled/disabled from there. To remove it, delete the folder.

**Option B — via the marketplace (good for sharing with a team).**

```bash
/plugin marketplace add michail-nikolaev/redline   # straight from GitHub, no clone needed
/plugin install redline@redline
```

(`redline` is the marketplace name from `.claude-plugin/marketplace.json`.)

To enable / disable later, open `/plugin` and toggle it, or edit
`enabledPlugins` in the relevant `settings.json` (user / project / local scope).
Quick test without installing: `claude --plugin-dir ./plugins/redline`.

### 2. Set up the status line (optional)

The hooks work on their own, but the [status line](#status-line) gives you a
live, at-a-glance view of your pending manual edits in the status bar. A plugin
can't register the main status line itself, so run the bundled command once:

```text
/redline-statusline install            # user scope (~/.claude/settings.json)
/redline-statusline install --project  # project scope (./.claude/settings.json)
```

See [Setting it up](#setting-it-up) for the full set of options.

## How it works

An agent turn is one "tick". The plugin hooks the boundaries of each tick:

- **`SessionStart`** — snapshot the working tree (baseline for the first turn).
- **`Stop`** — snapshot at the end of every agent turn (the state it stopped at).
- **`UserPromptSubmit`** — before the next turn, compare the current tree with the
  snapshot and put the difference into Claude's context. Silent if you changed
  nothing.
- **`SessionEnd`** — clean up this session's snapshot.

Snapshots are taken as a git tree object through a throwaway `GIT_INDEX_FILE`, so
your index, stash, and working files are never touched. `.gitignore` is honored.
The comparison is against the snapshot from the **end of the agent's turn**, so
the diff contains your edits, not Claude's. The current `HEAD` is stored next to
each snapshot so manual edits can be told apart from history-moving operations
(see "Edge cases").

## Status line

The diff that `UserPromptSubmit` feeds Claude goes into the model's context, but
Claude Code does not always surface that text to *you*. The optional **status
line** gives you a persistent, at-a-glance view of your pending manual edits
right in the status bar, refreshed every few seconds — a summary header plus
one row per changed file, coloured like git:

```
✎ 4 files +5 -3
  D del.txt              -2
  A image.bin            (bin)
  M src/app.ts           +3 -1
  A src/new_feature.go   +2
```

Each file row is a git-style change letter (`A`dded / `M`odified / `D`eleted /
`R`enamed, coloured green / yellow / red / cyan), the path (padded so the count
columns line up), and the line counts (`+` green, `-` red; binary files show
`(bin)`). The list is capped at `REDLINE_STATUS_MAXFILES` rows (default `10`);
beyond that it ends with a `+N more` row. Multi-line output relies on Claude
Code rendering each printed line as a separate status row.

Rows are sized to the terminal width: a long path is truncated from the left
(keeping the filename, e.g. `...components/Button.tsx`) so no row overflows and
wraps. Claude Code captures the script's stdout, so terminal-size calls like
`tput cols` don't work from inside it; instead it exports the width as the
`COLUMNS` environment variable, which the status line reads (falling back to 80
when unset). Row *count* is bounded by `REDLINE_STATUS_MAXFILES`, so `LINES`
is not used.

It reuses the exact same per-session snapshot as the hooks, so it shows the same
delta the next prompt will carry. It is strictly **read-only** — it never writes
or moves the snapshot, so it can't disturb what the next `UserPromptSubmit`
reports. It stays blank when you have made no edits, and during history-moving
operations (branch switch / reset / commit), where a diff would be misleading.

**While the agent is working** it shows a minimal `⏳ working…` marker instead
of the file list — because between turn start and end the worktree delta is the
*agent's* in-progress edits, not yours. The file list is only shown when the
agent is idle and waiting for you, when the delta is genuinely your manual edits.

There is no "is working" flag in the status line params, and a user interrupt
(Esc) ends the turn *without* firing `Stop`, so a plain flag would get stuck on
`⏳ working…` forever. Instead the plugin uses a **freshness heartbeat**:
`UserPromptSubmit` creates a marker, `Stop` / `SessionStart` / `SessionEnd`
remove it, and the status line keeps it fresh from a signal in its own params —
`cost.total_api_duration_ms`, which is cumulative and only advances while the
agent waits on the model. Each tick, if that counter has advanced, the marker is
refreshed; if it hasn't been refreshed within `REDLINE_STATUS_BUSY_TTL` seconds
(default `20`), the turn is treated as idle (interrupted or ended uncleanly) and
the bar falls back to your manual-edit diff. Lower the TTL for snappier recovery
after an interrupt; raise it to tolerate longer quiet stretches. Customise the
marker with `REDLINE_STATUS_WORKING` (empty string shows nothing while working).

This heuristic exists only because Claude Code has no interrupt/turn-end signal a
plugin can observe directly (no interrupt hook, no "is working" param, and OTEL
is export-only); see
[anthropics/claude-code#9516](https://github.com/anthropics/claude-code/issues/9516).
If that lands, this can be replaced with an exact signal.

### Setting it up

A plugin cannot register the main status line itself: a plugin's bundled
`settings.json` only supports the `agent` and `subagentStatusLine` keys, not the
top-level `statusLine` ([plugins reference][plugref]). So the status line has to
live in your **user** or **project** `settings.json`. The plugin ships a command
that writes it there for you:

```text
/redline-statusline install            # user scope (~/.claude/settings.json)
/redline-statusline install --project  # project scope (./.claude/settings.json)
/redline-statusline install --refresh 3
/redline-statusline status             # show what's configured
/redline-statusline uninstall          # remove it (only if it's ours)
```

The edit is surgical (every other setting is preserved), a `*.redline.bak` backup
is written next to the file, and it refuses to overwrite a status line that isn't
ours unless you pass `--force`. Under the hood it just runs
`scripts/manage-statusline.sh`, which you can also call directly. The resulting
settings entry looks like:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash \"/abs/path/to/redline/hooks/statusline.sh\"",
    "padding": 0,
    "refreshInterval": 2
  }
}
```

`refreshInterval` (seconds, minimum `1`) is what makes it update while the
session is idle — Claude Code otherwise only re-runs the status line on events,
and your between-turn file edits don't raise events. The install default is `2`,
which is cheap to sustain (see *Performance* below). Lower it toward `1` for
snappier reaction, raise it to calm a very large repo. The absolute path is
captured at install time; if you move or reinstall the plugin to a different
location, re-run `install` to refresh it.

### Performance

Running every couple of seconds has to stay cheap. Two things keep it that way:

- **A persistent, warm git index.** The status line diffs the worktree against
  the turn snapshot by building a tree through a private `GIT_INDEX_FILE`. That
  index is kept across ticks (seeded once from the repo's real index), so git's
  stat cache re-hashes only the files whose stat changed — not the whole tree.
  On a ~75 MB repo this is the difference between ~200 ms and ~15 ms per tick.
- **A render cache.** The rendered line is cached keyed by the
  `(snapshot-tree, worktree-tree)` pair plus the display settings (colour,
  prefix, max files). If nothing in that key changed since the last tick, the
  cached output is reprinted and the per-file diff + format step is skipped
  entirely. The tree ids are content-addressed, so the cache can never go stale:
  editing an already-modified file changes the tree and forces a recompute, and
  toggling a display setting takes effect on the next tick too. If a tick ever
  can't build the tree (e.g. a momentary index lock), it repaints the last frame
  instead of flickering to blank.

Both the index and the cache live in the state dir and are removed at
`SessionEnd` (and by the 24h sweep).

[plugref]: https://code.claude.com/docs/en/plugins-reference

## Edge cases

**Branch switches and other history operations.** A branch switch, `reset`,
`pull`, `rebase`, or `commit` moves `HEAD`. The plugin detects this and does not
mistake the change for manual edits: it silently re-baselines to the current
state and injects no diff for that turn, so Claude never receives the entire
inter-branch delta. Normal manual edits are picked up again from the next turn.

**Tracked files that are also gitignored.** Some repos commit a file and *then*
add it to `.gitignore` (a checked-in `.idea/` is the classic case). Such files
are tracked, so git still versions them. Snapshots are built from the repo's real
index, so these files are represented exactly as git sees them, and editing one
is reported like any other tracked change. (Truly untracked, ignored files —
build output, logs — are still excluded.) This consistency is also why a clean
tree shows nothing: every snapshot the plugin takes uses the same index basis, so
tracked-ignored files never appear as phantom "added" entries.

**Subagents.** When the main agent spawns a subagent (Task tool), Claude Code
fires `UserPromptSubmit` inside the subagent too (its task prompt looks like a
prompt), so without care the diff hook would inject a "user edited files" note
into the subagent's own context. The hook detects subagent context via the
`agent_id` field — present only inside a subagent call — and does nothing there.
It deliberately ignores `agent_type`, since that field is also set for a
top-level `claude --agent <name>` session, which must keep working normally. A
synchronous subagent's own file edits are captured at the main agent's `Stop`
(subagents run within the main turn), so they are attributed to Claude, not to
you. `Stop` does not fire for subagents, so no per-subagent baseline is taken.

Limitation: a *background* subagent (`run_in_background: true`) can keep editing
after the main `Stop`, in the gap before your next prompt. Those writes are
indistinguishable from manual edits at the working-tree level, so they may be
reported as user edits. Synchronous subagents — the common case — are unaffected.

**Enabling mid-session.** Two things to know:

1. Claude Code only activates a plugin's *hooks* at session start. If you enable
   the plugin in a running session, its skills/commands load but its hooks do
   not, until you run `/reload-plugins` or (more reliably) start a new session.
   This is a Claude Code limitation, not a plugin bug.
2. Even once the hooks are live, `SessionStart` for this session has already
   passed, so there is no baseline. The plugin self-heals: the first
   `UserPromptSubmit` silently creates the baseline, and diffing works from the
   next turn. Edits you made *before* activation are folded into the baseline and
   not reported — we had no way to observe them.

**Disabling mid-session.** For the same reason, disabling via `/plugin` is not
guaranteed to stop already-registered hooks in the current session (known Claude
Code behavior). The hooks are near-no-ops when idle, but for a hard stop right
now, start a new session.

## Multi-session safety

Every snapshot is keyed by the hook's `session_id`, so multiple concurrent Claude
Code sessions in the same repository never clobber each other's snapshots. State
lives under `${REDLINE_STATE_DIR:-${TMPDIR:-/tmp}/redline-<uid>}/sessions/`
(the `<uid>` keeps the default per-user on a shared machine), and the same path
is computed by both the hooks and the status line (see
*Configuration*).

Note: if two sessions edit the **same working tree** at the same time, one
agent's edits will show up in the other's "user" diff — that is unavoidable with
a shared working directory. For real parallelism use git worktrees (in Claude
Code, the `--worktree` flag) so each session has its own working directory.

**Git worktrees.** The plugin is worktree-correct: it resolves the working
directory from the payload's `cwd` (not `CLAUDE_PROJECT_DIR`, which the status
line never receives and which may point at the original checkout), so the hooks
and the status line always operate on the *same* worktree. Snapshots use the
per-worktree index (via `git rev-parse --git-path index`), and `HEAD`-move
detection reads the worktree's own `HEAD`. Each worktree session has its own
`session_id`, so their state never collides.

## Configuration

All are environment variables (set them where your hooks and status line can see
them — e.g. your shell profile).

- `REDLINE_MAX_BYTES` — max size of the injected diff in bytes (default
  `20000`). Raise it for large edits: `export REDLINE_MAX_BYTES=60000`.
- `REDLINE_DISPLAY` — on-submit display: `banner` (default) injects the diff
  into context discreetly and shows a one-line summary banner; `inline` prints
  the whole diff into the transcript.
- `REDLINE_STATE_DIR` — where per-session snapshots live (default
  `${TMPDIR:-/tmp}/redline-<uid>`). If you set this, set the **same**
  value in both the hook environment and the status line environment, or they will look in
  different places and the status line will never find the snapshot.

Status line only:

- `REDLINE_STATUS_PREFIX` — marker before the file list (default `✎`).
- `REDLINE_STATUS_COLOR` — set to `never` to disable ANSI colours (also honours
  the standard `NO_COLOR`). Colours are on by default.
- `REDLINE_STATUS_MAXFILES` — max number of file rows to show before a
  `+N more` row (default `10`). Each file is its own status row.
- `REDLINE_STATUS_CLEAN` — what the status line prints when there are no edits
  (default empty, i.e. nothing).
- `REDLINE_STATUS_WORKING` — what the status line prints while the agent is
  working (default `⏳ working…`). Set to an empty string to show nothing then.
- `REDLINE_STATUS_BUSY_TTL` — seconds without the agent's API time advancing
  before the "working" state is considered stale and the diff is shown again
  (default `20`). This is what lets the bar recover after a user interrupt, where
  no `Stop` fires.

## Requirements

- `git`, `bash`, and `jq`. `jq` is now **required** — there is no string-parsing
  fallback. If `jq` is missing the plugin announces it once on stderr and goes
  inactive (it never breaks your session or spams the status bar).

## Layout

```
.
├── .claude-plugin/
│   └── marketplace.json          # marketplace catalog (name: "redline")
├── .github/
│   └── workflows/ci.yml          # runs the test suite + shellcheck on push/PR
├── tests/                        # bash test suite (see Development)
│   ├── helpers.sh                # assertions + git/state fixtures
│   ├── run.sh                    # runner: bash tests/run.sh
│   └── test_*.sh                 # one file per area
└── plugins/
    └── redline/
        ├── .claude-plugin/
        │   └── plugin.json        # plugin manifest
        ├── commands/
        │   └── redline-statusline.md   # /redline-statusline setup command
        ├── hooks/
        │   ├── hooks.json         # wires the four lifecycle hooks
        │   ├── lib.sh             # shared helpers
        │   ├── snapshot-worktree.sh   # SessionStart + Stop
        │   ├── diff-since-last-turn.sh # UserPromptSubmit
        │   ├── cleanup-session.sh      # SessionEnd
        │   └── statusline.sh           # read-only status line (not a hook)
        ├── scripts/
        │   └── manage-statusline.sh    # installs statusLine into settings.json
        └── README.md
```

## Development

The plugin is pure bash + git + jq, and so is its test suite — no framework to
install. Run it from the repo root:

```bash
bash tests/run.sh            # everything
bash tests/run.sh worktree   # only files matching "worktree"
```

Each `tests/test_*.sh` is an independent script that sources `tests/helpers.sh`
(assertions plus throwaway-git-repo / isolated-state fixtures) and exits non-zero
if any assertion fails. Coverage includes the status-line rendering, the
busy/idle working state, the render cache, tracked-but-gitignored consistency,
git worktrees, the `UserPromptSubmit` banner/inline output, the `settings.json`
installer, and the jq-missing fallback.

CI (`.github/workflows/ci.yml`) runs the suite and ShellCheck on every push and
pull request. To lint locally: `shellcheck -x plugins/*/hooks/*.sh
plugins/*/scripts/*.sh tests/*.sh`.

## License

MIT — see [LICENSE](LICENSE).
