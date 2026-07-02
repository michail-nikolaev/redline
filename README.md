# redline

A Claude Code plugin that feeds the agent your **manual working-tree edits made
between its turns**, as a `git diff`. Most coding agents only notice your hand
edits when they happen to re-read a file — redline makes it explicit and
proactive: whenever you edit files yourself between the agent's turns, the next
prompt carries a diff of exactly what you changed into Claude's context.

<img width="746" height="348" alt="image" src="https://github.com/user-attachments/assets/c0517a14-859a-47ac-a865-4ceadd8f2a4b" />

<img width="1891" height="548" alt="image" src="https://github.com/user-attachments/assets/0023d24b-1a16-4314-9322-8c2470f7b288" />



## Install

```bash
/plugin marketplace add michail-nikolaev/redline
/plugin install redline@redline
```

To enable/disable later, open `/plugin` and toggle it.

**Optional: status line.** The hooks work on their own, but a bundled command
can also add a status-bar view of your pending manual edits:

```bash
/redline:redline-statusline install
```
or in case of local installation
```bash
/redline-statusline install
```

Run `/redline-statusline` for the full set of options (project scope, refresh
rate, uninstall).

### Requirements

`git`, `bash`, and `jq`. If `jq` is missing the plugin announces it once on
stderr and goes inactive — it never breaks your session.

## How it works

An agent turn is one "tick". The plugin hooks the boundaries of each tick:

- **`SessionStart`** — snapshot the working tree (baseline for the first turn).
  Compaction (`source: compact`) is deliberately ignored — it is not a turn
  boundary, so edits pending at that moment survive it.
- **`Stop`** — snapshot at the end of every agent turn (the state it stopped at).
- **`PostToolUse`** — re-snapshot after each file-touching tool call, so the
  baseline follows the agent *through* the turn. If you interrupt a turn with
  Esc (which fires no `Stop`), the agent's own edits are still baselined and
  never come back misattributed as yours.
- **`UserPromptSubmit`** — before the next turn, compare the current tree with
  the snapshot and put the difference into Claude's context. Silent if you
  changed nothing.
- **`SessionEnd`** — clean up this session's snapshot.

Snapshots are taken as a git tree object through a private `GIT_INDEX_FILE`,
so your index, stash, and working files are never touched, and `.gitignore` is
honored. The objects a snapshot creates are routed to a private per-session
store under the state directory (`GIT_OBJECT_DIRECTORY`, with your repo as a
read-only alternate) — nothing is ever written into your `.git/objects`, and
the store is deleted with the session. The comparison is against the snapshot
from the **end of the agent's turn**, so the diff contains your edits, not
Claude's — a branch switch, `reset`, or `commit` moves `HEAD` instead, which
the plugin detects and treats as a re-baseline rather than a manual edit.

On large repositories the recurring snapshots use git's untracked cache to
skip full directory walks (disable with `REDLINE_UNTRACKED_CACHE=false` if
your filesystem has unreliable directory mtimes); set `REDLINE_FSMONITOR=1`
to additionally use git's builtin filesystem monitor daemon (git ≥ 2.37).

The status line reuses this same snapshot read-only, so it always shows the
same delta the next prompt would carry.

## License

MIT — see [LICENSE](LICENSE).
