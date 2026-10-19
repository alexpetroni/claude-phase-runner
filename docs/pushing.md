[claude-phase-runner](../README.md) · [Documentation](README.md)

# Pushing

The runner pushes after every verified phase (and after a blocked one, so the
work is never only local). The agent itself cannot push — the guard blocks it.

- **SSH remote**: the agent of the terminal that launches the run is
  forwarded into the container, and host keys are accepted automatically.
  First check that it holds your key: `ssh-add -l` in that terminal. A
  desktop keyring usually provides an agent already, and a newly started
  agent is empty and replaces the keyring's agent for that terminal, so start
  one (`eval $(ssh-agent); ssh-add`) only when `ssh-add -l` finds no agent
  at all. The CLI warns if the remote is SSH and no agent is running.
- **HTTPS remote with embedded token**
  (`https://x-access-token:<TOKEN>@github.com/you/repo.git`): needs nothing.

Only the runner's own git calls see the forwarded agent: every agent process
and the gate command run without `SSH_AUTH_SOCK`, and the guard blocks the
SSH client family and git-over-SSH for every role (see [Security model](security.md)).

With `PUSH=1`, `build` and `preflight` check push access before the first
agent is launched: one read-only `git ls-remote` against the push remote,
capped at 30 seconds. Success is one log line (`Push remote origin (…) is
reachable`); failure is a warning naming the remote and the two usual causes
(no SSH agent forwarded, a bad token in an HTTPS URL), and the run continues,
because the work is committed locally either way. The output of that contact
is appended to `logs/push.log`. The contact runs with git's terminal prompts
disabled and stdin closed (like the gate): a remote without usable credentials
fails at once with git's own error (`could not read Username for …: terminal
prompts disabled`) instead of sitting on a `Username for …` prompt until the
cap kills it.

Push failures retry 3× and then abort without losing the phase record; fix
the auth and re-run — the backlog is pushed first. `PUSH=0` disables pushing
(and the early check).

