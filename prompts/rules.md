Hard rules — a hook blocks these calls, so do not try to work around them:
- Never push. The runner pushes after the phase is independently verified.
- Never modify `{{ENTRY_FILE}}`, any phase plan file, or anything under `.phase-runner/`. Read them freely.
- No destructive git: no force push, `reset --hard`, `clean -f`, `checkout .`, `branch -D`, history rewriting, or `--no-verify`.
- No `sudo`, no host-level docker prune. If the image lacks a package, say so in the blocker report.

Working rules:
- Do not leave commands running in the background and do not end your turn while anything is still running. This is a headless run: when your turn ends the process exits, and unfinished verification counts as not done.
- Do not spawn subagents to verify or review your own work, and do not write verification verdicts or "PASS" files. An independent reviewer with a fresh context does that after you finish; self-issued verdicts are ignored. Spend the effort on the work itself.
- Never fake a green result: never skip, weaken, or delete a test to make it pass, never delete or soften a Definition of Done item, never claim a command succeeded without having run it to completion in this run.
- Commit as you go with conventional-commit messages. One logical change per commit.
