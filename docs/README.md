[claude-phase-runner](../README.md) · Documentation

# Documentation

Start with the [README](../README.md): install once, talk the project through
with Claude Code, say "write the phases for claude-phase-runner", build. The
pages here are the rest.

## Setting up

- [Setup and the first run](setup.md) — what `install` does, credentials,
  prerequisites, the same steps by hand, what `init` creates, the first run.
- [Commands](commands.md) — the CLI reference.
- [Configuration](configuration.md) — every `runner.env` setting, the phases
  manifest and its per-phase overrides, the entry file and the phase files.
- [Writing the plan](../skills/phase-runner/WRITING-PHASES.md) — cutting a
  project into phases, the entry file, a Definition of Done a reviewer can
  check. It is what the `/phase-runner` skill follows.

## How a run works

- [What happens in a phase](how-it-works.md) — builder, checkpoint, gate,
  reviewer, fix rounds, done; why the reviewer is a separate process; preflight
  and the final review.
- [Cost](cost.md) — where a run's money goes and the levers, in order of impact.
- [Enforcement — the guard hook](guard.md) — what every role cannot do, and
  what the read-only roles cannot do on top.
- [Retries](retries.md) — transient errors, stalls, usage windows; what is never
  retried.
- [Resume and stopping a run](resume.md) — what a re-run does after any
  interruption; how to stop a run and what to do after killing the window.
- [Monitoring](monitoring.md) — `status`, `logs`, the driver log.
- [Pushing](pushing.md) — the SSH agent, HTTPS tokens, the early push check.
- [Security model](security.md) — the container, the Docker socket, the SSH
  agent. Read it once.

## When something is off

- [Troubleshooting](troubleshooting.md) — symptom, cause, fix.

## The kit itself

- [Developing the kit](development.md) — layout, iterating, the test suite,
  CI, lint, the container smoke test, building the kit with the kit (the
  kit's own build plan lives in [`self-build/`](../self-build/README.md)).
