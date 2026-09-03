# Renders a stream-json agent log as a readable transcript.
# Usage: jq -R -r -f render.jq agent.log      (-R: raw lines; non-JSON lines are skipped)

def short: tostring | gsub("\n"; " ⏎ ") | .[0:220];

fromjson? |
if .type == "system" and .subtype == "init" then
  "▷ session \(.session_id // "?") · model \(.model // "?") · claude \(.claude_code_version // "?") · mcp servers \((.mcp_servers // []) | length)"
elif .type == "assistant" then
  (.message.content[]? |
    if .type == "text" then "\n\(.text)"
    elif .type == "tool_use" then
      "  → \(.name) \((.input.command // .input.file_path // .input.description // .input.prompt // .input.pattern // .input.skill // "") | short)"
    else empty end)
elif .type == "user" then
  (.message.content[]? | select(.type == "tool_result" and .is_error == true) |
    "  ✗ \((.content | if type == "array" then map(.text // "") | join(" ") else tostring end) | short)")
elif .type == "result" then
  "\n■ \(.subtype // "result") · \(((.duration_ms // 0) / 60000) | floor) min · $\(.total_cost_usd // "?") · \(.num_turns // "?") turns" +
  (if .structured_output then "\n  structured: \(.structured_output | tostring | .[0:400])" else "" end)
else empty end
