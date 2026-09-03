# Renders a reviewer verdict (JSON from the VERDICT_SCHEMA) as Markdown.
# Usage: jq -r --arg phase P --arg round N --arg when TS -f verdict.jq verdict.json

def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
def sev: ascii_upcase;

"# Review — \($phase) — \(.verdict)\n\n_\($when) · fix round \($round)_\n\n\(.summary)\n\n" +
"## Definition of Done\n\n| Item | Verdict | Evidence |\n|---|---|---|\n" +
([ .dod[]? | "| \(.item | cell) | \(.verdict) | \(.evidence | cell) |" ] | join("\n")) +
"\n\n## Findings\n\n" +
(if (.findings | length) == 0 then "None."
 else ([ .findings[] |
   "- **\(.severity | sev)** `\(.file)\(if .line then ":\(.line)" else "" end)` — \(.what)\n  Fix: \(.fix)" ]
   | join("\n"))
 end) + "\n"
