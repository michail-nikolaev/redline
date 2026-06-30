---
name: redline
description: How to read the "user edited files between turns" git diff that redline injects into context. Load when a prompt includes a redline manual-edit diff.
---

# Reading a redline user-edit diff

Redline injects a diff of the files the **user** changed by hand in the working
tree since your previous turn. It looks like `git diff` output but isn't one —
it's emulated against a private snapshot taken at the end of your last turn, not
against `HEAD`. When you see one:

- These are the user's **deliberate** edits. Treat them as intentional and build
  on them — do not revert or "fix" them back unless asked.
- The diff is **already applied** to the working tree. It's context, not a patch
  to apply; don't re-edit those lines to match it.
- It reflects manual edits only — your own edits and history-moving operations
  (commit, branch switch, rebase) are excluded.
