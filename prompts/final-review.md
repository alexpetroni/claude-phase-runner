{{ENTRY}}

---

# Runner instructions for this run

FINAL ADVERSARIAL REVIEW — every planned phase is complete and committed:

{{PHASE_LIST}}

{{REVIEW_BODY}}

This is a read-only pass: edit tools are disabled and a hook blocks git mutations. Do not change the project in any way — not code, config, docs, or git; not even small fixes. Every improvement, however safe it looks, goes into the report as a recommendation for the human to approve. Ground every claim in the code: cite `file:line`, run the tests and the gate, and verify against the running stack where the entry prompt describes how.

Return the review as the `report` field, in Markdown: a short headline of the most important themes, then a prioritized list where each item states what, where, why it matters, severity (critical / high / medium / low), and the concrete fix you would make. Each accepted item should be turnable into a self-contained phase file with its own Definition of Done.
