[claude-phase-runner](../README.md) · [Documentation](README.md)

# Commands

| Command | What it does |
|---|---|
| `phase-runner install` | Once per machine: link the CLI into `~/.local/bin` and the `/phase-runner` skill into `~/.claude/skills`, create `~/.config/claude-phase-runner/credentials.env` from the template. Symlinks, so `git pull` in the kit updates both; re-run only after moving the kit. |
| `phase-runner init` | Create `.phase-runner/` in the project from the templates, exclude it from git, print the next steps. Idempotent. |
| `phase-runner build` | Run every pending phase (the default command). `--dry-run` validates everything, prints the first pending phase's builder prompt and exits. |
| `phase-runner preflight` | Read-only tooling assessment of the whole plan → `.phase-runner/state/TOOLING.md`. |
| `phase-runner review` | Read-only adversarial review of the finished project → `.phase-runner/state/REVIEW.md`. |
| `phase-runner status` | Table of phases: status (`pending`, `partial`, `done`, `BLOCKED`, `missing`), last verdict, fix rounds, cost, minutes — and the next step. No container. |
| `phase-runner logs [PHASE] [-f]` | Readable transcript of the latest agent or gate log, or the newest log matching PHASE. `-f` follows. |
| `phase-runner logs driver [-f]` | The runner's own log (`state/logs/driver.log`): every start, retry, wait, verdict and stop, as plain text. `-f` follows. |
| `phase-runner reset [--yes]` | Delete `.phase-runner/state`. Config, phases and the agent home stay. |

All commands take `--project DIR` (default: the git repository containing the
current directory). `phase-runner help` prints the usage and the absolute paths
of this documentation and of the plan-writing guide. Every setting the commands
read is in [Configuration](configuration.md); what `build` does per phase is in
[What happens in a phase](how-it-works.md).

