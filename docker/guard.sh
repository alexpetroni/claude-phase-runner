#!/usr/bin/env bash
# PreToolUse guard — "prompts steer, hooks enforce".
#
# Claude Code pipes the pending tool call as JSON on stdin. Exit 2 blocks the
# call and feeds stderr back to the model so it can route around the rule;
# exit 0 allows. Unparseable input fails OPEN (allow), so a guard bug can never
# brick a multi-hour run.
#
# Environment (set by the driver for every claude process, inherited by hooks):
#   PHASE_RUNNER_ROLE       build | fix | review | preflight | final-review
#   PHASE_RUNNER_PROTECTED  ':'-separated project-relative paths the agent may
#                           read but never modify (entry file, phase plans,
#                           .phase-runner/)
#   PROJECT_DIR             absolute project root (to normalise absolute paths)
#
# Every role:   no git push, no destructive git, no history rewriting, no sudo,
#               no rm -rf on root/home/.git, no docker prune (the socket is the
#               host's), no curl|sh, no modifying protected paths.
# Read-only roles (review, preflight, final-review): additionally no edit tools,
#               no git mutations at all, no publishing.
set -uo pipefail

input="$(cat 2>/dev/null)" || exit 0
tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)" || exit 0
[[ -n "$tool" ]] || exit 0

role="${PHASE_RUNNER_ROLE:-build}"
project="${PROJECT_DIR:-$PWD}"; project="${project%/}"
readonly_role=0
case "$role" in review|preflight|final-review) readonly_role=1 ;; esac

block() {
  printf 'phase-runner guard (%s role) BLOCKED this call: %s\n' "$role" "$1" >&2
  exit 2
}

normalize_path() {
  local p="$1"
  p="${p#"$project"/}"
  p="${p#./}"
  printf '%s' "$p"
}

# protected_hit PATH → 0 when PATH is (inside) a protected entry
protected_hit() {
  local p e
  p="$(normalize_path "$1")"
  local IFS=':'
  for e in ${PHASE_RUNNER_PROTECTED:-}; do
    [[ -z "$e" ]] && continue
    e="${e%/}"
    [[ "$p" == "$e" || "$p" == "$e/"* ]] && return 0
  done
  return 1
}

# protected_in_cmd CMD → prints the first protected path mentioned, 0 if any
protected_in_cmd() {
  local e
  local IFS=':'
  for e in ${PHASE_RUNNER_PROTECTED:-}; do
    [[ -z "$e" ]] && continue
    if [[ "$1" == *"$e"* ]]; then printf '%s' "$e"; return 0; fi
  done
  return 1
}

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    (( readonly_role )) && block "this role is read-only: it produces findings and reports, never edits (tool: $tool)."
    path="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input" 2>/dev/null)"
    if [[ -n "$path" ]] && protected_hit "$path"; then
      block "'$path' belongs to the human/runner (entry prompt, phase plans, .phase-runner/). Read it; never modify it."
    fi
    ;;

  Bash)
    cmd="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)"
    [[ -n "$cmd" ]] || exit 0

    # `git`, possibly prefixed by a separator and global options (-C dir, -c k=v, --flag)
    g='(^|[;&|(`]|\$\()[[:space:]]*(command[[:space:]]+)?git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--[a-z-]+(=[^[:space:]]*)?))*[[:space:]]+'

    grep -qE "${g}push([[:space:]]|$)" <<<"$cmd" \
      && block "git push. The runner pushes after the phase is independently verified; the agent never pushes."
    grep -qE "${g}reset([[:space:]]+[^[:space:]]+)*[[:space:]]+--(hard|merge)([[:space:]]|$)" <<<"$cmd" \
      && block "git reset --hard/--merge destroys uncommitted work. Commit or stash instead."
    grep -qE "${g}clean([[:space:]]+-[a-zA-Z]*[fdxX][a-zA-Z]*)" <<<"$cmd" \
      && block "git clean -f deletes untracked work."
    grep -qE "${g}(checkout|restore)([[:space:]]+[^[:space:].][^[:space:]]*)*[[:space:]]+(--[[:space:]]+)?\.([[:space:]]|$)" <<<"$cmd" \
      && block "git checkout/restore . discards every working-tree change. Revert specific files by name if you must."
    grep -qE "${g}checkout([[:space:]]+[^[:space:]]+)*[[:space:]]+(-f|--force)([[:space:]]|$)" <<<"$cmd" \
      && block "git checkout --force discards work."
    grep -qE "${g}branch([[:space:]]+[^[:space:]]+)*[[:space:]]+(-D|--delete[[:space:]]+--force)([[:space:]]|$)" <<<"$cmd" \
      && block "git branch -D."
    grep -qE "${g}(rebase|filter-branch|filter-repo|reflog[[:space:]]+expire|update-ref[[:space:]]+-d)([[:space:]]|$)" <<<"$cmd" \
      && block "history rewriting (rebase/filter-branch/reflog expire) is not allowed in an unattended run."
    grep -qE "${g}remote[[:space:]]+(set-url|remove|rm)([[:space:]]|$)" <<<"$cmd" \
      && block "changing git remotes."
    grep -qE "${g}(commit|merge|push|cherry-pick|revert)([[:space:]]+[^[:space:]]+)*[[:space:]]+(--no-verify|-n)([[:space:]]|$)" <<<"$cmd" \
      && block "--no-verify bypasses the project's own git hooks. Fix what the hook complains about instead."

    grep -qE '(^|[;&|[:space:]])sudo([[:space:]]|$)' <<<"$cmd" \
      && block "sudo. Ask for the package in EXTRA_APT_PACKAGES via the blocker report instead."
    grep -qE '(^|[;&|[:space:]])rm[[:space:]]+(-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+|--recursive[[:space:]]+|--force[[:space:]]+)+("?\$HOME"?|~|/|/\*|\.git|\*)/?([[:space:]]|$)' <<<"$cmd" \
      && block "recursive delete of home, root, .git or '*'."
    grep -qE '(^|[;&|[:space:]])(mkfs(\.[a-z0-9]+)?|dd[[:space:]]+if=|shutdown|reboot|halt|poweroff)([[:space:]]|$)' <<<"$cmd" \
      && block "host-level destructive command."
    grep -qE '(^|[;&|[:space:]])docker[[:space:]]+(system|image|volume|container|network|builder)[[:space:]]+prune' <<<"$cmd" \
      && block "docker prune acts on the HOST daemon (the socket is the host's). Remove only this project's resources by name."
    grep -qiE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh([[:space:]]|$)' <<<"$cmd" \
      && block "piping a download straight into a shell."

    if p="$(protected_in_cmd "$cmd")"; then
      grep -qE '(>|\bsed[[:space:]]+-[a-zA-Z]*i|\btee\b|\brm\b|\bmv\b|\bcp\b|\btruncate\b|\bperl[[:space:]]+-[a-zA-Z]*i|\bpatch\b|\bgit[[:space:]]+(checkout|restore|rm|mv)\b|\bchmod\b|\bln\b)' <<<"$cmd" \
        && block "'$p' belongs to the human/runner (entry prompt, phase plans, .phase-runner/). Commands that could modify it are refused; read it with cat or the Read tool."
    fi

    if (( readonly_role )); then
      grep -qE "${g}(add|commit|stash|checkout|switch|merge|cherry-pick|apply|am|tag|mv|rm|revert|reset|restore|rebase|worktree|notes|clean)([[:space:]]|$)" <<<"$cmd" \
        && block "this role is read-only: no git mutations. Report what you would change as a finding."
      grep -qE '(^|[;&|[:space:]])(npm|pnpm|yarn)[[:space:]]+publish([[:space:]]|$)' <<<"$cmd" \
        && block "publishing packages."
    fi
    ;;
esac

exit 0
