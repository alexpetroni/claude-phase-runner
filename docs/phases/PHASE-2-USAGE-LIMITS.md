# PHASE-2 — Usage limits: judge by the event, scope it to the attempt, say when it resets

## Problem

Subscription usage windows are the most common reason a real run stops. The driver waits
for a window to reset and resumes the same session, but three things about that path are
wrong or unproven. All shapes below are copied from real logs.

**What the CLI actually emits.** Before the failing result there is a `rate_limit_event`
whose `rate_limit_info.status` is `rejected`:

```json
{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1788538200,"rateLimitType":"five_hour","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":1,"resetsAt":1788538200},"seven_day":{"utilization":0.45,"resetsAt":1788620400},"seven_day_overage_included":{"utilization":0.88,"resetsAt":1788620400}}}}
{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1788620400,"rateLimitType":"seven_day_overage_included","overageStatus":"rejected","overageDisabledReason":"out_of_credits","isUsingOverage":false,"unifiedWindows":{"five_hour":{"utilization":0.55,"resetsAt":1788557400},"seven_day":{"utilization":0.51,"resetsAt":1788620400},"seven_day_overage_included":{"utilization":1,"resetsAt":1788620400}}}}
```

Then a result event with `"subtype":"success","is_error":true` and one of these texts,
and a non-zero exit:

| `rateLimitType` of the rejection | Result text seen |
|---|---|
| `five_hour` | `You've hit your session limit · resets 4:10pm (UTC)` |
| `five_hour` | `You're out of usage credits · resets 8:40pm (UTC)` |
| `seven_day_overage_included` | `You're out of usage credits. Switch to another model to continue.` |
| `seven_day_overage_included` | `You're out of usage credits. /model to switch models.` |

Healthy runs are full of `rate_limit_event`s with `"status":"allowed"` that still carry
`"overageStatus":"rejected"` and `"overageDisabledReason":"out_of_credits"`. Those fields
describe the account, not the request. Only `rate_limit_info.status` says whether the
request was rejected.

**Defect 1: the wording decides, not the event.** `is_transient` in
`docker/lib/claude.sh` returns "not transient" as soon as the text matches
`out of usage credits`. So a five-hour window that the CLI happens to announce as
"You're out of usage credits · resets 8:40pm (UTC)" stops the run, although the event
says exactly when it resets. By the same rule the real weekly stop of 2026-09-04,
replayed through today's code, aborts without mentioning that its window reset the next
afternoon.

**Defect 2: evidence from an earlier attempt is used for a later failure.**
`limit_reset_wait` reads the last rejected event in the whole log file. Retries and
re-runs append to the same file, so that event may belong to an earlier attempt or to a
run from the day before. If its reset time is still in the future, for example a weekly
window that resets tomorrow, an unrelated transient error such as a 529 or a timeout
makes the driver sleep until that reset, up to `LIMIT_WAIT_MAX`, instead of using the
retry schedule.

**Defect 3: a stop does not say when to come back, and a far reset is waited for in
slices.** The abort hint is "the subscription is out of usage credits" with no time.
And when the reset is further away than `LIMIT_WAIT_MAX`, the driver sleeps
`LIMIT_WAIT_MAX`, resumes into the same rejection and repeats until the retry schedule
is exhausted, which is hours of sleeping for a certain failure. The README defines
`LIMIT_WAIT_MAX` as the "longest wait for a subscription usage window to reset before
the run gives up".

The wait-and-resume path has never run for real: every rejection in the logs predates
it. Its tests use a fake event with only three fields and a reset one second ahead.

## Deliverables

1. **Attempt-scoped evidence.** Whatever classifies a failed attempt (transient or not,
   usage window or not, reset time, the hint for the abort message) looks only at what
   that attempt appended to the log. An event or an error text left by an earlier
   attempt or an earlier run never influences it.
2. **The event decides.** For a failed attempt:

   | Evidence from this attempt | Meaning | The driver |
   |---|---|---|
   | A rejected `rate_limit_event` whose `resetsAt` is in the future and at most `LIMIT_WAIT_MAX` seconds away | A usage window that resets soon enough | Waits until the reset plus the grace, then resumes the same session. The log line names the limit type and the reset time. |
   | A rejected event whose `resetsAt` is further away than `LIMIT_WAIT_MAX` | A usage window that resets too late to wait for | Stops at once: no sleeping, no further attempts. |
   | A rejected event whose `resetsAt` has already passed | The window has reset in the meantime | Retries on `RETRY_SCHEDULE`. |
   | No rejected event, text says a limit was hit (`hit your ... limit`, `usage limit`) | A limit with an unknown reset | Retries on `RETRY_SCHEDULE`, as today. |
   | No rejected event, text says `out of usage credits`, `insufficient credits` or `credit balance` | Out of credit, nothing to wait for | Stops, as today. |

   A rejected event without a usable `resetsAt` counts as no event. The result text no
   longer overrides a rejected event that carries a reset time.
3. **A stop for a usage limit tells the human what to do.** The message, which also
   lands in `SUMMARY.md`, contains: the limit type; the reset time as
   `YYYY-MM-DD HH:MM UTC` and how far away it is; the CLI's own result text verbatim;
   and that re-running `phase-runner build` after that time resumes where the run
   stopped, or that raising `LIMIT_WAIT_MAX` makes the runner wait instead.
4. **The fake `claude` speaks the real dialect.** Its limit outcomes emit events with
   the full real shape, including `unifiedWindows` and the overage fields, and the real
   result texts: a five-hour window announced as "hit your session limit"; a five-hour
   window announced as "out of usage credits · resets ..."; a weekly window
   (`seven_day_overage_included`) with a configurable distance to its reset; and an
   out-of-credit failure with no rejected event. The existing scenario "out of usage
   credits is an honest stop, not a retry" currently feeds a `five_hour` rejection with
   a reset one second ahead and expects a stop. Under the new rules that input is a
   window to wait for, so the scenario has to be re-based on the no-event outcome. This
   is the one intended change to an existing scenario.
5. **README.** The "Usage window" bullet under Retries, the `LIMIT_WAIT_MAX` row and the
   two Troubleshooting rows about limits describe the rules above, including the fact
   that the CLI's wording varies.

## Out of scope

- Falling back to another model when a cap is hit. The CLI suggests it; it is a quality
  trade-off the human has not decided.
- The default of `LIMIT_WAIT_MAX` or `RETRY_SCHEDULE`, and whether a wait uses up one of
  the retry attempts.
- Recording waits in `runs.tsv`.

## Definition of Done

- [ ] A five-hour rejection announced as "You're out of usage credits · resets 8:40pm
      (UTC)", with its reset inside `LIMIT_WAIT_MAX`, is waited out and the same session
      is resumed; the phase completes. A scenario proves it with the real event shape.
- [ ] The existing "hit your session limit" scenario still passes, now with the real
      event shape.
- [ ] A weekly rejection whose reset is further away than `LIMIT_WAIT_MAX` stops the run
      with exactly one `claude` invocation and no sleep. The driver output and
      `SUMMARY.md` contain the limit type, the reset time in the format of deliverable
      3, the CLI's text verbatim and the instruction to re-run.
- [ ] The same weekly rejection with `LIMIT_WAIT_MAX` raised above the distance is
      waited out and resumed.
- [ ] An out-of-credit failure with no rejected event stops the run with one invocation
      and the existing hint. This is the re-based scenario.
- [ ] A rejection whose reset time has already passed is retried on `RETRY_SCHEDULE`,
      whatever the result text says.
- [ ] A stale rejection does not leak: with a rejected event whose reset is hours in the
      future already present in the phase's log file from an earlier run, a plain
      transient failure (the fake's 529) is retried on `RETRY_SCHEDULE`, the output says
      "Transient API failure" and not "Usage limit", and the scenario finishes in
      seconds.
- [ ] An `allowed` event that carries `"overageStatus":"rejected"` is never treated as
      a rejection. A scenario or a direct call of the classifying function proves it.
- [ ] The fake's limit outcomes carry `unifiedWindows` and the overage fields, and use
      the four real result texts.
- [ ] The README sections of deliverable 5 match the implemented rules.
- [ ] Gate green.
