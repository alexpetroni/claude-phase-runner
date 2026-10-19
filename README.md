# claude-phase-runner

Autonomous, phase-by-phase project builder. It runs Claude Code with
`--dangerously-skip-permissions` inside a sandboxed Docker container against a
target git repository, **one builder run per phase plan file**, and then has an
**independent reviewer** with a fresh context and no edit tools audit the phase
before it counts. Transient API errors and hangs are retried on an escalating
schedule, a killed run resumes where it stopped, and every verified phase is
committed and pushed.

```
phase-runner build  (host)  →  docker compose run  →  driver.sh, per phase file:
┌────────────────────────────────────────────────────────────────────────────┐
│ 1. BUILDER   fresh context, edit tools, guard hook   → structured report    │
│ 2. checkpoint commit (nothing in flight is ever lost)                       │
│ 3. GATE      your command, e.g. lint && typecheck && test                   │
│ 4. REVIEWER  fresh context, read-only, gets the diff → PASS / FAIL verdict  │
│      FAIL or red gate → FIX round (builder, fresh context, the findings)    │
│      ≤ MAX_FIX_ROUNDS, then the phase is BLOCKED and the run stops          │
│ 5. record phase done → git push                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

The plan comes out of a conversation: you talk the project through with Claude
Code, say *"write the phases for claude-phase-runner"*, and the `/phase-runner`
skill that ships with the kit writes the entry file, the phase files and the
manifest into the project. Everything per project (configuration, manifest,
state, verdicts, logs) lives in the project under `.phase-runner/`, excluded
from git; the plan is committed with the code. The kit directory holds code
only. Credentials are user-level.

**Prompts steer, hooks enforce.** The builder is told not to push and not to
verify itself; a `PreToolUse` guard hook makes sure it *cannot* push, cannot
rewrite history, cannot touch the plan files, and that the reviewer cannot edit
anything.

## Install, once per machine

```bash
git clone git@github.com:alexpetroni/claude-phase-runner.git ~/work/claude-phase-runner
~/work/claude-phase-runner/bin/phase-runner install
$EDITOR ~/.config/claude-phase-runner/credentials.env   # one token: `claude setup-token`, or an API key
```

`install` links the CLI into `~/.local/bin`, links the `/phase-runner` skill
into `~/.claude/skills` (that is how Claude Code knows how to write a plan for
the runner) and creates the credentials file from the template.

You need Docker with the compose plugin, `jq`, Claude Code on the host for the
conversation, and a Claude Code credential: a subscription OAuth token from
`claude setup-token` or an `ANTHROPIC_API_KEY`. For an SSH push remote, an
`ssh-agent` holding the key. Details: [Setup and the first run](docs/setup.md).

## Use, per project

1. **Talk the project through** with Claude Code, in the project directory:
   what to build, the stack, what "done" means, the decisions you do not want
   revisited.
2. **Say "write the phases for claude-phase-runner."** The skill takes over: it
   runs `phase-runner init`, writes `docs/ENTRY.md` and one
   `docs/phases/PHASE-N-<slug>.md` per phase with a Definition of Done a
   reviewer can check, fills `.phase-runner/phases` and the gate command in
   `.phase-runner/runner.env`, and ends with the steps that follow. Read the
   plan (it is the one part of the loop no reviewer checks) and commit it.
3. **`phase-runner build`**, in tmux. Ctrl-C stops it cleanly at any point and
   the next `build` resumes. From another terminal, `phase-runner status` says
   where it is and what to do next, and `phase-runner logs -f` follows the
   agent.

A blocked phase stops the run: read `.phase-runner/state/reviews/<phase>.md`,
ask Claude to revise the plan, build again. Completed phases are skipped.

## Documentation

The index is [docs/README.md](docs/README.md); `phase-runner help` prints the
paths.

Setting up

- [Setup and the first run](docs/setup.md) — `install` in detail, credentials,
  the same steps by hand, what `init` creates, the first run.
- [Commands](docs/commands.md) — the CLI reference.
- [Configuration](docs/configuration.md) — every `runner.env` setting, the
  phases manifest, the entry file and the phase files.
- [Writing the plan](skills/phase-runner/WRITING-PHASES.md) — cutting phases,
  the entry file, a checkable Definition of Done; what the skill follows.

How a run works

- [What happens in a phase](docs/how-it-works.md) — builder, checkpoint, gate,
  reviewer, fix rounds; preflight and the final review.
- [Cost](docs/cost.md) — where the money goes and the levers.
- [Enforcement — the guard hook](docs/guard.md)
- [Retries](docs/retries.md) — transient errors, stalls, usage windows.
- [Resume and stopping a run](docs/resume.md)
- [Monitoring](docs/monitoring.md) — `status`, `logs`, the driver log.
- [Pushing](docs/pushing.md) — the SSH agent, HTTPS tokens, the early push check.
- [Security model](docs/security.md) — read this once.

When something is off

- [Troubleshooting](docs/troubleshooting.md)

The kit itself

- [Developing the kit](docs/development.md) — layout, tests, CI, lint, the
  smoke test, building the kit with the kit.
