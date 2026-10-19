[claude-phase-runner](../README.md) · [Documentation](README.md)

# Retries — "the API stopped responding"

Two failure shapes are treated as transient and retried on `RETRY_SCHEDULE`:

- **Errored** — claude exits non-zero and the log tail matches transient
  patterns: HTTP 5xx / 429, `overloaded`, rate limit, connection
  refused/reset, timeouts, `fetch failed`, `socket hang up`.
- **Hung** — no output for `STALL_TIMEOUT` seconds. The watchdog kills the
  process and stamps the log with `RUNNER-STALL`.
- **Usage window** — the CLI's rejected `rate_limit_event` names the window
  (`five_hour`, `seven_day_overage_included`, …) and when it resets. Its
  wording for the same window varies ("You've hit your session limit · resets
  4:10pm", "You're out of usage credits · resets 8:40pm", "You're out of usage
  credits. Switch to another model to continue."), so the event decides, not
  the text. A reset within `LIMIT_WAIT_MAX` is waited out (plus
  `LIMIT_WAIT_GRACE` seconds, 60 by default) and the same session resumed; a reset further away stops the run at once —
  no sleeping towards a certain rejection — with the window, the reset time as
  `YYYY-MM-DD HH:MM UTC`, the CLI's text and how to continue, in the output
  and in `SUMMARY.md`; a reset that has already passed is a plain retry.
  Without a rejected event the wording decides: "hit your … limit" / "usage
  limit" is retried on the schedule, "out of usage credits", "insufficient
  credits" or "credit balance" is an honest stop.

Only what the failed attempt itself appended to the log is judged. Retries and
re-runs append to one `<phase>.<role>.log`, so an event or an error text left
by an earlier attempt or an earlier run never decides a later failure.

Every run gets its own session id; a retry resumes exactly that session, so
in-flight context is preserved and a false stall-kill is cheap. If the session
cannot be resumed the role restarts from its prompt with a new id.

**An honest agent stop is never retried.** Non-zero without transient markers
— an auth error, a budget cap, a CLI failure — aborts the run with the log
path and a hint. A builder that *reports* `blocked` is not a failure at all:
see [What happens in a phase](how-it-works.md).

