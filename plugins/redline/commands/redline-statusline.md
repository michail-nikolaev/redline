---
description: Install/remove the redline status line (shows your between-turn edits in the status bar)
argument-hint: "[install|uninstall|status] [--user|--project] [--refresh N] [--force]"
allowed-tools: Bash(bash:*)
---

The redline plugin cannot register the main status line itself (a
plugin's bundled `settings.json` only supports `agent` and `subagentStatusLine`),
so this command writes it into a user or project `settings.json` for the user.

Run the management script, passing the user's arguments through verbatim. If the
user gave **no** arguments, default the action to `install` (user scope,
`--refresh 2`). The script defaults scope to `--user` and refresh to `2` already.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/manage-statusline.sh" $ARGUMENTS
```

User arguments: `$ARGUMENTS`

After it runs, report concisely to the user:
- which `settings.json` was changed (or inspected),
- the `command` and `refreshInterval` that were set,
- that a backup (`*.redline.bak`) was written next to it,
- and that they should start a new session if the bar doesn't appear on the next refresh.

If the script refused to overwrite an existing foreign status line, surface that
clearly and tell them they can re-run with `--force` to replace it. Do not edit
`settings.json` yourself by hand — only use the script.
