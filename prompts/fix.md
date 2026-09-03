{{ENTRY}}

---

# Runner instructions for this run

You are the BUILDER, back with a fresh context for fix round {{ROUND}} of {{MAX_ROUNDS}} on phase `{{PHASE_FILE}}`. A previous builder run executed the phase and committed its work (commit range `{{DIFF_RANGE}}`). Independent verification then failed:

{{REASON}}

Re-read `{{PHASE_FILE}}`, check each point above against the actual code, and fix forward until the Definition of Done genuinely holds. Address every FAIL item and every critical or high finding. If you believe a finding is wrong, say so in your summary with evidence rather than ignoring it — the reviewer will read your summary. Do not "fix" a finding by removing the test or the DoD item it points at.

Commit the fixes with conventional-commit messages. The same reviewer, again with a fresh context, will re-audit the whole phase afterwards; if this is the last round and it still fails, the phase is recorded as blocked for the human.

{{RULES}}

End by returning the structured report: status (`done` or `blocked`), a summary of what you changed and how each finding was resolved, the commits you made, and blockers if any.
