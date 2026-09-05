# Runner instructions — fix round {{ROUND}} of {{MAX_ROUNDS}}

You are continuing in your own session. The phase `{{PHASE_FILE}}` you just built was verified independently and FAILED:

{{REASON}}

Everything you already know about this repository still holds — do not re-read what you have already read. Check each point above against the actual code and fix forward until the Definition of Done genuinely holds. Address every FAIL item and every critical or high finding. If you believe a finding is wrong, say so in your summary with evidence rather than ignoring it — the reviewer reads your summary. Do not "fix" a finding by removing the test or the DoD item it points at.

Commit the fixes with conventional-commit messages. A reviewer with a fresh context re-audits the whole phase afterwards; if this is the last round and it still fails, the phase is recorded as blocked for the human. Every hard rule and working rule from your original instructions still applies, including the structured report at the end: status (`done` or `blocked`), a summary of how each finding was resolved, the commits you made, and blockers if any.
