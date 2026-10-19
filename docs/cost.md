[claude-phase-runner](../README.md) · [Documentation](README.md)

# Cost

Roughly one reviewer run per phase on top of the build, and one builder + one
reviewer run per fix round. From real runs on Fable 5.1 at xhigh: build phases
cost $2–30 and take 8–80 minutes; the reviewer adds 15–30% of the builder's
cost; a fix round with a fresh context costs 30–55% of the build.
`phase-runner status` shows the per-phase totals (cost is the CLI's own
estimate; on a subscription the real constraint is the usage window).
`BUILD_BUDGET_USD` and `REVIEW_BUDGET_USD` cap a single run; hitting a cap is
an honest stop, not a retry.

**Where a builder run's money goes** (from the `result` events of real runs,
Fable 5.1 at xhigh, 1-hour prompt cache):

| Bucket | Share | Driven by |
|---|---|---|
| Output tokens (~40% of them thinking) | ~40% | effort level, number of turns |
| Cache writes: tool output entering the context once | ~40% | test/log dumps, file reads, the agent's own edits |
| Cache reads: the growing context re-read every turn | ~16% | turns × context size |
| Fresh input | <2% | the prompt |

**The levers, in order of impact — all configurable, see [Configuration](configuration.md):**

1. **Model and effort per role and per phase.** The gate and the reviewer are
   a failure signal, so the efficient shape is a cheap first attempt and
   escalation on failure (same pass rate, about half the cost). The template
   ships the builder on Opus 5.5 at `high` (`BUILD_MODEL`, `BUILD_EFFORT`),
   fix rounds on Fable 5.1 at `xhigh` (`FIX_MODEL`, `FIX_EFFORT`) and the
   reviewer on Fable 5.1 at `high` (`REVIEW_EFFORT`; a stronger model that
   differs from the builder's is what makes the cheaper builder safe). The
   `phases` manifest takes `model=claude-fable-5-1` for the hard phases and
   `model=claude-sonnet-5-5 effort=medium` for the trivial ones (a release
   cut, a config-only phase). With nothing set, every role runs Fable 5.1 at
   xhigh; Fable 5.1's own guidance is `high` for most work, `xhigh` only for
   the most capability-sensitive.
2. **Cheaper subagents.** `SUBAGENT_MODEL=claude-sonnet-5-5` routes the
   subagents the builder and reviewer spawn (Explore, general-purpose, test
   audits) to a cheaper model; an agent definition that names its own model
   still wins.
3. **Less tool output in the context.** `BASH_OUTPUT_MAX_CHARS` caps what a
   Bash result puts inline (the rest goes to a file the agent can grep), and
   `prompts/rules.md` tells the builder to iterate on single test files with
   a quiet reporter and run the full gate once, at the end — in one real run
   the builder ran the test suite 57 times. The reviewer is told the gate's
   green output is the runner's own evidence, so it does targeted checks
   instead of re-running the whole suite and build.
4. **No paid re-work.** A run interrupted after the builder finished (usage
   limit, crash, Ctrl-C) resumes at the gate, not the builder — that was a
   $6–11 re-audit per interruption in the logs. Subscription usage windows are
   waited out and the same session resumed instead of aborting the run.
5. **`FIX_CONTEXT=resume`.** The builder's session already holds the whole
   repository context; a resumed fix round pays cache reads instead of
   rebuilding that context, but only while the cache is warm (1 hour on a
   subscription, 5 minutes on an API key unless `CLAUDE_CODE_PROMPT_CACHE_TTL`
   is set). If gate + review take longer, the resume rewrites the whole
   context at the cache-write rate and a fresh context is cheaper — hence
   `fresh` stays the default. Keep `FIX_EFFORT` unset with `resume`: an effort
   change invalidates the cache too.

Measure before and after with `phase-runner status`; the per-run cost there is
the last `result` event of each session (a resumed session reports its total
cumulatively, so summing every event — the previous behaviour — overstated
resumed runs by up to 2×).

