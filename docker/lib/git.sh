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

tree_status() { git status --porcelain --untracked-files=all | LC_ALL=C sort; }

# Read-only roles must leave the tree as they found it. The tree is not
# necessarily clean when they start: `preflight` may run while a failed builder's
# uncommitted files sit in it. So restore_tree discards only what appeared
# since snapshot_tree, never the work that was already there.
snapshot_tree() { TREE_SNAPSHOT="$(tree_status)"; }

restore_tree() {  # restore_tree WHO
  local now new line path
  now="$(tree_status)"
  [[ "$now" == "${TREE_SNAPSHOT-}" ]] && return 0
  new="$(LC_ALL=C comm -13 <(printf '%s\n' "${TREE_SNAPSHOT-}") <(printf '%s\n' "$now"))"
  [[ -n "$new" ]] || return 0
  warn "$1 left changes in the working tree — discarding them:"
  printf '%s\n' "$new" | sed 's/^/    /' >&2
  while IFS= read -r line; do
    path="${line:3}"; path="${path##* -> }"
    if [[ "${line:0:2}" == "??" ]]; then
      rm -rf -- "$path"
    else
      git reset -q -- "$path" 2>/dev/null || true
      if git cat-file -e "HEAD:$path" 2>/dev/null; then git checkout -q -- "$path"; else rm -rf -- "$path"; fi
    fi
  done <<<"$new"
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
