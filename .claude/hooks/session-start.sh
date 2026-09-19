#!/bin/bash
# SessionStart hook: keeps a fresh Claude Code on the web session from
# silently starting work on a branch that's missing merged commits from the
# repo's actual default branch.
#
# BACKGROUND: this repo had no `main`/default branch for a while, so several
# sessions in a row each created their own branch with no reliable "latest
# work" to inherit from, and the fixes one session made were invisible to
# the next. `main` now exists and is the repo's default branch, but nothing
# stops it from drifting stale again if a session's finished work never gets
# merged back into it. This hook is the safety net: every session, before
# any work happens, checks whether the branch it's on is missing commits
# that are already on origin's default branch, and if so, merges them in
# automatically (a plain merge — never a reset/rebase, so nothing is ever
# discarded). It also flags, as a warning only, any OTHER branch that has a
# newer commit than both the current branch and the default branch, since
# that's exactly the "someone did work and forgot to merge it" pattern that
# caused this in the first place — worth a human's attention, but not
# something this hook should guess at auto-merging on its own.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

# Not a git repo (or git isn't available) — nothing for this hook to do.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

echo "[session-start] Fetching all remote branches..."
if ! git fetch origin --prune --quiet 2>/tmp/session-start-fetch.log; then
  echo "[session-start] WARNING: 'git fetch origin' failed, skipping branch-freshness check:"
  cat /tmp/session-start-fetch.log
  exit 0
fi

# The repo's actual default branch, read live from the remote (not a
# guess/hardcoded "main") — this is exactly the setting that was wrong
# before and is now the real source of truth once it's correct.
default_branch="$(git remote show origin 2>/dev/null | sed -n 's/^[[:space:]]*HEAD branch: //p')"
if [ -z "$default_branch" ]; then
  echo "[session-start] WARNING: couldn't determine origin's default branch — skipping freshness check."
  exit 0
fi

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
default_ref="origin/${default_branch}"

if ! git rev-parse --verify "$default_ref" >/dev/null 2>&1; then
  echo "[session-start] WARNING: ${default_ref} doesn't exist locally after fetch — skipping freshness check."
  exit 0
fi

if [ "$current_branch" = "$default_branch" ]; then
  behind=0
else
  behind="$(git rev-list --count HEAD.."$default_ref" 2>/dev/null || echo 0)"
fi

if [ "$behind" -gt 0 ]; then
  echo "[session-start] '$current_branch' is missing $behind commit(s) already on ${default_ref} — merging them in..."
  if git merge --no-edit "$default_ref" >/tmp/session-start-merge.log 2>&1; then
    echo "[session-start] Merged clean. '$current_branch' now includes everything on ${default_ref}."
  else
    echo "[session-start] MERGE CONFLICT pulling ${default_ref} into '$current_branch' — aborting the merge rather than leaving it half-done. Manual resolution needed:"
    cat /tmp/session-start-merge.log
    git merge --abort >/dev/null 2>&1
  fi
else
  echo "[session-start] '$current_branch' already has everything on ${default_ref}. Good."
fi

# Diagnostic only, never auto-switches: flag any OTHER remote branch with a
# commit newer than both the current branch and the default branch, since
# that's the exact "unmerged work nobody remembered" pattern that caused
# tonight's problem. Sessions come and go under auto-generated names
# (claude/adjective-noun-hash), so this can't assume any particular naming
# scheme still means something — it just compares raw commit timestamps.
newest_other=""
newest_other_time=0
current_time="$(git log -1 --format=%ct HEAD 2>/dev/null || echo 0)"
default_time="$(git log -1 --format=%ct "$default_ref" 2>/dev/null || echo 0)"
baseline_time=$current_time
if [ "$default_time" -gt "$baseline_time" ]; then
  baseline_time=$default_time
fi

for ref in $(git for-each-ref --format='%(refname:short)' refs/remotes/origin | grep -v '^origin/HEAD$'); do
  short="${ref#origin/}"
  if [ "$short" = "$current_branch" ] || [ "$short" = "$default_branch" ]; then
    continue
  fi
  t="$(git log -1 --format=%ct "$ref" 2>/dev/null || echo 0)"
  if [ "$t" -gt "$baseline_time" ] && [ "$t" -gt "$newest_other_time" ]; then
    newest_other_time=$t
    newest_other="$ref"
  fi
done

if [ -n "$newest_other" ]; then
  echo "[session-start] HEADS UP: '$newest_other' has a more recent commit than either '$current_branch' or ${default_ref}. That likely means work landed there and never got merged back to ${default_branch}. Worth checking before assuming this session has the true latest state."
fi
