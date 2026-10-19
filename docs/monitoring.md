[claude-phase-runner](../README.md) · [Documentation](README.md)

# Monitoring

```bash
phase-runner status            # per phase: done/BLOCKED/partial/pending, verdict, rounds, $, min
phase-runner logs -f           # live transcript of the newest log
phase-runner logs A.md.review  # newest log whose name contains that
phase-runner logs driver -f    # the runner's own log: what the terminal said, kept on disk
cat .phase-runner/state/reviews/<phase>.md
```

Logs are stream-json (`*.log`); a rendered transcript (`*.txt`) is written
next to each when the role ends, and `logs` renders live with jq.

The terminal is not the only record of a run. Everything the driver prints
with `▶`, `⚠` or `✗` — phase starts, retries and why, usage-limit waits and
until when, stall kills, red gates, verdicts, pushes, the reason it stopped —
is also appended to `state/logs/driver.log` as one line per message: UTC
timestamp, level (`INFO`, `WARN`, `FAIL`), message, no colour. Each start adds
a header with the mode, branch, Claude Code version and pid, so consecutive
runs can be told apart; the file survives everything except `phase-runner
reset`. Writing it can never fail a run: an unwritable file is ignored.
`phase-runner logs` without a phase keeps showing the latest agent or gate log,
never this one.

