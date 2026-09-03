# shellcheck shell=bash
# Git helpers for the phase driver. Sourced by driver.sh.

# Keep .phase-runner/ out of the project's history without touching its
# tracked .gitignore: .git/info/exclude is local and never committed.
ensure_exclude() {
  local f
  f="$(git rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  mkdir -p "$(dirname "$f")"
  grep -qxF '.phase-runner/' "$f" 2>/dev/null || echo '.phase-runner/' >> "$f"
}

# The agent should commit its own work; this makes sure nothing in flight is
# ever lost between roles or phases.
checkpoint_commit() {  # checkpoint_commit MESSAGE
  git add -A
  if ! git diff --cached --quiet; then
    git commit -q -m "$1" || die "checkpoint commit failed"
    log "Checkpoint commit: $1"
  fi
}

tree_is_clean() { [[ -z "$(git status --porcelain)" ]]; }

# Read-only roles run on a fully committed tree, so anything they leave behind
# (a stray edit, test artefacts) can be discarded without losing work.
restore_tree() {  # restore_tree WHO
  tree_is_clean && return 0
  warn "$1 left changes in the working tree — discarding them:"
  git status --short | sed 's/^/    /' >&2
  git reset -q --hard HEAD && git clean -qfd
}

has_unpushed() {
  [[ -n "$(git log --oneline "$GIT_REMOTE/$GIT_BRANCH..HEAD" 2>/dev/null)" ]]
}

# push_branch → 0 pushed (or PUSH=0), 1 failed after 3 attempts. Caller decides
# whether that is fatal.
push_branch() {
  [[ "$PUSH" == "1" ]] || { log "PUSH=0 — skipping push"; return 0; }
  local try t0
  t0=$(date +%s)
  for try in 1 2 3; do
    if git push -u "$GIT_REMOTE" "$GIT_BRANCH" >>"$LOGS/push.log" 2>&1; then
      log "Pushed $GIT_BRANCH to $GIT_REMOTE"
      record_run "-" push 0 ok "" "" $(( $(date +%s) - t0 ))
      return 0
    fi
    warn "Push failed (attempt $try/3) — retrying in 30s"
    sleep 30
  done
  record_run "-" push 0 failed "" "see logs/push.log" $(( $(date +%s) - t0 ))
  return 1
}
