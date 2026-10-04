# PHASE-3 — The runner's own account of a run is kept

## Problem

The driver narrates everything that matters about a run: which phase started, a retry
and why, a wait for a usage window and until when, a stall kill, a red gate, a verdict,
a push, the reason it stopped. `log`, `warn` and `die` in `docker/lib/common.sh` print
that to the terminal and nowhere else. `SUMMARY.md` holds only the final state, and the
per-role logs hold only what the agents said.

For an unattended run that lasts hours, the terminal is a tmux scrollback that is gone
or truncated by the time someone looks. While preparing this batch it was impossible to
tell from a project's state directory whether a usage-limit wait had ever happened, or
how long a run had spent retrying.

## Deliverables

1. **`.phase-runner/state/logs/driver.log`.** Every `log`, `warn` and `die` call appends
   one physical line: a UTC timestamp (`2026-10-04T15:09:11Z`), a level (`INFO`,
   `WARN`, `FAIL`) and the message, without colour codes. A message that contains
   newlines stays on one line. The file is appended to across runs and survives
   everything except `phase-runner reset`.
2. **A header line at every driver start** with the mode, the branch, the Claude Code
   version and the process id, so that consecutive runs can be told apart.
3. **The terminal output does not change.** Same text, same colours, same streams. The
   scenarios that assert on the driver's output keep passing untouched.
4. **Logging can never fail a run.** A missing directory, a read-only file or a full
   disk must not change the driver's exit status or stop a phase.
5. **CLI.**
   - `phase-runner logs` with no phase argument shows the latest *agent or gate* log as
     before. It must never pick `driver.log`, which is now always the most recently
     written file while a run is active.
   - `phase-runner logs driver` prints the driver log as plain text, and
     `phase-runner logs driver -f` follows it.
   - `phase-runner status` names the driver log in its last line.
   - The usage text lists `logs driver`.
6. **README.** The contents tree (`state/logs/`), the Monitoring section and the
   Troubleshooting rows that tell the reader to look at the terminal.

## Out of scope

- Capturing output that does not go through `log`, `warn` or `die`, such as the dry-run
  prompt or the bootstrap lines.
- Rotation or size limits.
- Recording waits or retries in `runs.tsv`, and any change to `status` columns.
- The host CLI's own banner.

## Definition of Done

- [ ] After a build, `driver.log` holds a line for each of the driver's `log` messages
      of that run, in order. A scenario checks a normal run, and one run each with a
      transient retry, a red gate and a failure that ends in `die`: the corresponding
      `INFO`, `WARN` and `FAIL` lines are present.
- [ ] Every line starts with a UTC timestamp of the stated form and a level, and the
      file contains no escape character. A scenario asserts both with patterns.
- [ ] Two consecutive runs in the same project leave two header lines and both runs'
      messages.
- [ ] The driver's terminal output for an identical scenario is unchanged: no existing
      assertion on `$OUT` was modified.
- [ ] With `driver.log` impossible to write (a directory in its place, for example,
      which also defeats a root user), a build still completes with status 0 and its
      phase recorded as done.
- [ ] `phase-runner logs` without arguments, on a project whose newest file is
      `driver.log`, shows an agent log; `phase-runner logs driver` prints the driver
      log; `status` names it. A CLI scenario proves all three.
- [ ] `phase-runner reset --yes` removes it together with the rest of the state.
- [ ] README updated as in deliverable 6; the usage text lists `logs driver`.
- [ ] Gate green.
