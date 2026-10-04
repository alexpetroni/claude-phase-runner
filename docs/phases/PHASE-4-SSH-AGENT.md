# PHASE-4 — The agent no longer holds the push credentials

## Problem

For SSH remotes the host's SSH agent is forwarded into the container so that the runner
can push after each verified phase. `docker/bootstrap.sh` exports `SSH_AUTH_SOCK` to the
driver, and every child of the driver inherits it: the `claude` process of every role,
and the gate command, which executes code the builder has just written.

The guard blocks `git push`, but it has no rule for anything else that uses that
socket. For as long as a run lasts, an agent can authenticate as the human to every host
the loaded keys open: `ssh`, `scp`, a `git fetch` or `git clone` of any private
repository. Now that the Docker socket is optional, this is the largest capability a
careless or misled agent holds.

It is not hypothetical that agents reach for it. In the real logs one read-only pass ran
`ssh-add -l` and `ssh -o BatchMode=yes ... git@github.com` to find out whether pushing
would work. No builder ever needed SSH: every other remote git command in the logs used
public HTTPS URLs (`git clone https://...`, `git ls-remote https://...`).

Be precise about what this phase can and cannot achieve. The agent and the driver run as
the same user, so the socket file at `/ssh-agent` stays reachable for an agent that
deliberately points `SSH_AUTH_SOCK` at it. This phase removes the accidental path and
makes the deliberate one a guard violation. A hard boundary needs the driver and the
agent to run as different users, which is a larger change and not part of this batch.

## Deliverables

1. **Only the runner's own git network calls see the SSH agent.** The `claude` process
   of every role and the gate command run without `SSH_AUTH_SOCK` in their environment.
   `push_branch`, and the check in deliverable 2, still authenticate through the
   forwarded agent exactly as before.
2. **The runner checks push access itself, early.** In `build` and `preflight` mode with
   `PUSH=1`, before the first agent is launched, the driver contacts the push remote
   read-only with a timeout of about 30 seconds (`git ls-remote` is enough). Success is
   one quiet log line. Failure is a `warn` that names the remote and the two usual
   causes, no SSH agent forwarded or a bad token in an HTTPS remote URL, and the run
   continues: the work is committed locally either way and the backlog is pushed by the
   next run. This replaces what agents used to probe by hand, and it turns "push failed
   3 times" after the first hour into a warning in the first minute.
3. **Guard rules for every role**, each with cases in `tests/guard.sh`:
   - block the SSH client family at a command position: `ssh`, `scp`, `sftp`,
     `ssh-add`, `ssh-agent`, including after `timeout N`, `env VAR=...`, `&&`, `;`, `|`
     and inside `$( )`;
   - block any command that mentions `SSH_AUTH_SOCK` or the socket path `/ssh-agent`;
   - block git commands that carry their own SSH transport: a `git@host:` or `ssh://`
     URL, `core.sshCommand`, `GIT_SSH`, `GIT_SSH_COMMAND`.

   The message says why (the runner holds the push credentials) and what to do instead
   (public sources over HTTPS; report `blocked` if the phase needs authenticated access
   to another host). Must stay allowed: `git clone https://...`, `git ls-remote
   https://...`, `git fetch` and `git log` on the existing remote, reading files and
   grepping for the word, for example `grep -rn ssh README.md` and
   `cat docs/ssh-notes.md`.
4. **Prompts.** `prompts/rules.md` gains one hard rule: no SSH and no use of the agent
   socket, because the runner holds the push credentials; public sources over HTTPS are
   fine; authenticated access to another host is a blocker to report.
   `prompts/preflight.md` says that push access is checked by the runner, so the
   assessment must not probe SSH itself.
5. **README.** The security model states what is closed and what remains, honestly, as
   in the Problem section. The guard section lists the new rules. The Pushing section
   and the "push failed 3 times" Troubleshooting row mention the early check.

## Out of scope

- Running the driver and the agent as different users, or pushing from the host.
- Any change to how the SSH agent is forwarded into the container, to host-key
  handling, or to HTTPS remotes with an embedded token.
- A setting that gives the agent the socket back. If a project turns out to need it,
  that is a new decision for the human.

## Definition of Done

- [ ] With `SSH_AUTH_SOCK` set in the driver's environment, the fake `claude` records
      an environment without it for build, fix, review, preflight and final-review.
- [ ] The gate command runs without it: a scenario whose gate is
      `test -z "${SSH_AUTH_SOCK:-}"` is green while the driver itself has the variable.
- [ ] Pushing still authenticates: with `PUSH=1`, a local bare repository as the remote
      and `SSH_AUTH_SOCK` set for the driver, a `pre-push` hook in the test project
      observes the variable with its original value, and the push succeeds.
- [ ] The early check: with a reachable remote there is one log line and no warning;
      with an unreachable remote in `preflight` mode there is a warning naming the
      remote, the pass still completes, and no push is attempted. With `PUSH=0` the
      remote is never contacted.
- [ ] `tests/guard.sh` has block cases for: `ssh git@github.com`,
      `timeout 20 ssh -o BatchMode=yes git@github.com`, `cd x && scp a host:b`,
      `ssh-add -l`, `SSH_AUTH_SOCK=/ssh-agent git fetch`, `ls -l /ssh-agent`,
      `git clone git@github.com:o/r.git`, `git fetch ssh://git@host/o/r.git`,
      `git -c core.sshCommand="ssh -i k" fetch`, `GIT_SSH_COMMAND="ssh -v" git pull`;
      each for a builder and for a read-only role.
- [ ] `tests/guard.sh` has allow cases for: `git clone https://github.com/o/r.git /tmp/r`,
      `git ls-remote https://github.com/o/r.git`, `git fetch origin`,
      `grep -rn ssh README.md`, `cat docs/ssh-notes.md`, `echo "use ssh keys"`.
- [ ] The builder and fix prompts contain the new hard rule; the preflight prompt
      contains the sentence about push access. Scenarios assert both.
- [ ] The README states, in the security model, that the socket file remains reachable
      by a deliberate agent and that separate users would be the hard fix.
- [ ] No existing guard case changed its expected result.
- [ ] Gate green.
