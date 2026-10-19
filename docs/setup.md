[claude-phase-runner](../README.md) · [Documentation](README.md)

# Setup and the first run

The [README](../README.md) has the short version: install once, then talk the
project through, say "write the phases for claude-phase-runner", build. This
page is the same path with the details, and the way to walk it by hand.

## Install

```bash
git clone git@github.com:alexpetroni/claude-phase-runner.git ~/work/claude-phase-runner
~/work/claude-phase-runner/bin/phase-runner install
```

`install` creates three things and names each one:

- `~/.local/bin/phase-runner`, a symlink to the clone's `bin/phase-runner`. If
  `~/.local/bin` is not on your `PATH` it says so; add the directory, or link
  the CLI into one that is.
- `~/.claude/skills/phase-runner`, a symlink to the clone's
  `skills/phase-runner/`. That is the `/phase-runner` skill: a personal Claude
  Code skill, so every session on the machine has it, and Claude loads it on
  its own when you ask for phases or a plan for the runner. The agents inside a
  run never see it; their home is the project's `.phase-runner/home`.
- `~/.config/claude-phase-runner/credentials.env` from
  `templates/credentials.env`, mode 600, when there is none yet.

Symlinks, so `git pull` in the clone updates the CLI and the skill in place;
re-run `install` only after moving the clone. A file or directory already
sitting where a link would go is left alone and named in the output.

## Credentials

Exactly one of:

- `CLAUDE_CODE_OAUTH_TOKEN`, a subscription token from `claude setup-token`;
- `ANTHROPIC_API_KEY`, for API billing.

The file is looked up at `$PHASE_RUNNER_CREDENTIALS`, then at
`~/.config/claude-phase-runner/credentials.env` (`$XDG_CONFIG_HOME` is
honoured). It is the agent's own secret store and lives deliberately outside
every project: the agent manages the project's `.env` files and must never see
its own token. Inside the container the values are environment variables; the
project never sees the file.

## Prerequisites

- Docker with the compose plugin on the host. The first `build` builds the
  image, a few minutes; later runs reuse it.
- `jq` on the host, for `status` and `logs`.
- A target project that is a git repository with at least one commit. The
  runner pushes every verified phase to `origin`: see [Pushing](pushing.md) for
  SSH agents and HTTPS tokens, or set `PUSH=0`.
- Claude Code on the host, for the conversation that produces the plan.

## The same by hand

What the skill does, as commands. Use it to see the moving parts, or when you
prefer to write the plan yourself.

```bash
cd ~/work/my-project
phase-runner init                    # .phase-runner/{runner.env,phases}; prints these steps
$EDITOR .phase-runner/runner.env     # GATE_CMD; ENTRY_FILE, models, push, DOCKER_SOCKET
# the plan: skills/phase-runner/WRITING-PHASES.md in the kit explains it; ENTRY.md and PHASE.md next to it are skeletons
$EDITOR docs/ENTRY.md docs/phases/PHASE-0-SCAFFOLD.md   # the entry file and one file per phase
$EDITOR .phase-runner/phases         # the phase files, one per line, in order
git add docs && git commit -m "docs: build plan"        # before the first run
phase-runner build --dry-run         # prints the exact first builder prompt, launches nothing
phase-runner preflight               # optional: what tooling/credentials the plan needs
phase-runner build                   # in tmux; Ctrl-C is safe at any time — never kill the window
phase-runner status                  # any time, from another terminal
phase-runner logs -f                 # follow the live agent transcript
phase-runner review                  # after the build: adversarial review → REVIEW.md
```

The guide is [Writing the plan](../skills/phase-runner/WRITING-PHASES.md); the
settings are in [Configuration](configuration.md); the commands are in
[Commands](commands.md).

## What `init` creates, and what a run writes

```
<project>/.phase-runner/  created by `phase-runner init`, excluded via .git/info/exclude
  runner.env              per-project configuration
  phases                  phase plan files, one per line, in order, with optional per-phase model/effort
  home/                   the agent's ~/.claude (skills, agents, plugins, sessions)
  state/phases-done       resume marker, one line per completed phase
  state/progress/         per-phase "builder finished" markers, so an interrupted run resumes at the gate
  state/blocked           phases the run gave up on, with the reason
  state/runs.tsv          one row per agent run / gate / push: outcome, seconds, cost, turns
  state/reviews/          <phase>.md + .json verdicts (latest), <phase>.r<N>.* per round
  state/logs/             <phase>.build.log (+ .txt transcript), .fix.rN, .review.rN, .gate.rN
  state/logs/driver.log   the runner's own account: one timestamped INFO/WARN/FAIL line per message, across runs
  state/SUMMARY.md · TOOLING.md · REVIEW.md
```

The directory is excluded from git through `.git/info/exclude`, so none of it
is committed. The plan itself, `docs/ENTRY.md` and `docs/phases/`, is part of
the repository.

## The first run

1. **Commit the plan.** The runner's checkpoint commits add everything in the
   tree, so an uncommitted plan would land in the builder's first commit.
2. **`phase-runner build --dry-run`.** Validates the configuration (a missing
   entry file or phase file fails at once), prints the resolved model and
   effort per role and phase, and prints the exact first builder prompt. No
   agent is launched. Read the prompt as the builder will: together with the
   repository, it is everything the builder gets.
3. **`phase-runner preflight`**, optional before a long build: a read-only
   agent lists what the plan needs (packages, skills, MCP servers, credentials)
   and how to provision each; see
   [Preflight and final review](how-it-works.md#preflight-and-final-review).
4. **`phase-runner build`, in tmux.** Ctrl-C stops it cleanly at any point;
   never kill the window, see [Stopping a run](resume.md#stopping-a-run). From
   another terminal, `status` and `logs`: [Monitoring](monitoring.md).

A run ends when every phase is done, when a phase is blocked after its fix
rounds, or when the runner stops honestly: a usage window that resets too far
away, an authentication error, a budget cap. In each case the terminal and
`phase-runner status` say what to do next, and `phase-runner logs driver` keeps
what the terminal said. [Resume](resume.md) covers starting again.
