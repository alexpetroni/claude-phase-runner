# PHASE-6 — Follow-ups from the reviews of phases 2 and 4

## Problem

The reviewers of this batch passed every phase and left twelve low findings. Four of
them are worth closing, plus one piece of advice that misled the human during this very
batch. Each is small; none changes a default.

**1. The push check can sit on a prompt, and its advice breaks working setups.**
`check_push_access` in `docker/driver.sh` runs `git ls-remote` with the driver's
terminal attached and without `GIT_TERMINAL_PROMPT=0`. Under `docker compose run` the
driver has a TTY, so an HTTPS remote without a usable token waits on git's
`Username for ...` prompt until the 30-second timeout kills it. The warning arrives
late and `logs/push.log` records a kill instead of the authentication error.
`run_gate` already closes stdin for the same reason.

The warning text, the host CLI's warning in `bin/phase-runner` and the README's Pushing
section all tell the reader to run `eval $(ssh-agent); ssh-add`. On a desktop whose
keyring already provides an agent, that replaces a working agent with an empty one.
During this batch it made every push fail with `Permission denied (publickey)` until
the terminal was pointed back at the keyring agent.

**2. The SSH guard only sees the client at a command position.** These pass today:
`/usr/bin/ssh git@github.com`, `bash -c 'ssh host'`, `xargs ssh host` and
`rsync -e ssh a host:b`. None of them can authenticate, because the agent runs without
`SSH_AUTH_SOCK` and every mention of the socket is blocked, so the layered defence
holds. The guard should still say no at the first layer.

**3. `LIMIT_WAIT_GRACE` exists in one of the five required places.** `run_agent` in
`docker/lib/claude.sh` adds it to every usage-window wait, default 60 seconds, and the
tests set it to 0. It is not passed through `docker-compose.yml`, not in
`templates/runner.env` and not in the README, so no project can change it.

**4. Two limit scenarios race the clock.** The fake's five-hour outcomes in
`tests/bin/claude` put the reset 3 seconds ahead. If the driver reads the event later
than that on a slow machine, it takes the "window reset already" branch and the
assertions on "resets at ... — waiting" fail, although the phase still completes.

## Deliverables

1. **Push check.** `git ls-remote` runs with stdin closed and `GIT_TERMINAL_PROMPT=0`,
   so a remote without usable credentials fails at once and `logs/push.log` holds
   git's own error. The check's outcomes and its 30-second cap stay as they are.
2. **Advice that cannot break a working agent**, in all three places: the driver's
   warning, the host CLI's warning about a missing SSH agent, and the README's Pushing
   section and Troubleshooting row. First check with `ssh-add -l` in the terminal that
   launches the run. Start a new agent only when there is none at all, and say that a
   newly started agent is empty and replaces the keyring's agent for that terminal.
3. **Guard.** The SSH rule also blocks: the client named with a path
   (`/usr/bin/ssh`, `./ssh`); the client as the command of `bash -c`, `sh -c` and
   `xargs`; and `rsync` with `-e ssh`, `--rsh=ssh` or `--rsh ssh`. The existing allow
   cases must keep passing, in particular reading and grepping for the word.
4. **`LIMIT_WAIT_GRACE` becomes a real setting**: passed through
   `docker-compose.yml`, documented in `templates/runner.env` next to
   `LIMIT_WAIT_MAX`, in the README configuration table, validated as a non-negative
   integer when set explicitly, and covered by a test. Default 60, unchanged.
5. **The limit scenarios do not depend on timing.** No assertion may flip because the
   machine is slow. Raise the fake's offset and make it configurable from the scenario,
   or assert only what the scenario is about; say in the commit message which.

## Out of scope

- The other eight low findings.
- Running the driver and the agent as different users.
- Any change to when the push check runs or to what happens when it fails.

## Definition of Done

- [ ] With a remote that needs credentials it does not have, the push check returns in
      well under the 30-second cap and `logs/push.log` contains git's error rather than
      a kill. A scenario proves it without the network, for example with a credential
      helper or an `askpass` that would block if git prompted.
- [ ] `grep -rn 'ssh-agent' bin docker README.md` shows no instruction to start an
      agent that is not preceded by the `ssh-add -l` check and the warning about an
      empty agent. The driver's and the CLI's warnings are asserted by scenarios.
- [ ] `tests/guard.sh` has block cases, for a builder and for a read-only role, for:
      `/usr/bin/ssh git@github.com`, `./ssh host`, `bash -c 'ssh host'`,
      `sh -c "scp a host:b"`, `find . | xargs ssh host`, `rsync -e ssh a host:b`,
      `rsync --rsh=ssh a host:b`.
- [ ] `tests/guard.sh` has allow cases for: `rsync -a src/ dest/`,
      `bash -c 'echo ssh'`, `cat /etc/ssh/ssh_config`, `ls ~/.ssh`. No existing guard
      case changed its expected result.
- [ ] `LIMIT_WAIT_GRACE` is in `docker-compose.yml`, `templates/runner.env` and the
      README table; `LIMIT_WAIT_GRACE=abc` and `LIMIT_WAIT_GRACE=-1` stop the run
      before any agent is launched; a scenario shows a non-default value changing the
      wait the driver announces.
- [ ] The two five-hour scenarios pass when the driver is delayed by 5 seconds between
      the fake's exit and the classification. The report says how that was checked.
- [ ] `shellcheck` stays clean: the lint scenario passes.
- [ ] Gate green.
