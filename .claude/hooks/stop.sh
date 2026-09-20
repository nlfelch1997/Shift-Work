#!/bin/bash
# Stop hook: the other half of session-start.sh's staleness check. That hook
# catches a session that STARTS behind the default branch; this one catches
# the opposite failure mode that actually happened once already — a session
# FINISHES real work on its own branch, and nothing ever gets that work back
# into the default branch, so the next session (and its own staleness check)
# has no idea it exists. Concretely: this repo had a branch
# (claude/stoic-tesla-pu4pa3) with a real playtest-bugfix commit — including
# the fix that made the customer lifetime budget dynamic instead of a fixed
# constant — that sat unmerged until a LATER session's SessionStart hook
# happened to notice it was newer than both the working branch and main.
# That worked out, but only by luck of timing; nothing made it happen.
#
# WHY Stop AND NOT SessionEnd: SessionEnd exists as a hook event, but nothing
# in this project's tooling confirms its exact firing/payload guarantees for
# a remote/web session specifically (e.g. whether it fires when a container
# is reclaimed after sitting idle, vs. only on a clean exit) — building this
# safety net on an event whose remote behavior is unverified risks it simply
# never firing, silently, which is worse than not having it. Stop is fully
# documented and fires after every single response Claude gives, which is
# more often than "the session ended," but this script is written to be a
# cheap, idempotent no-op on every turn that didn't add anything new to
# push (see the local-ref check below) — so paying that cost every turn is
# fine, and it means the branch is never more than one turn away from being
# pushed and PR'd, not just "eventually, if a session happens to run its
# real SessionEnd before disappearing."
#
# WHY PUSH+PR AND NOT AN AUTO-MERGE INTO main: session-start.sh auto-merges
# unconditionally, but that's safe there ONLY because it merges the
# ALREADY-REVIEWED default branch INTO a working branch — it can only add
# commits, and aborts cleanly on conflict. Doing the reverse — merging a
# working branch INTO main — is a fundamentally different risk, especially
# fired from Stop: it would run after EVERY turn, including mid-task with
# half-written code, and every other session's SessionStart hook trusts and
# auto-merges FROM main. Landing broken or incomplete work there on every
# turn would be worse than the original "forgot to merge" problem. Pushing
# the branch and ensuring a PR exists keeps a human click as the actual gate
# on main, while still guaranteeing the work is never sitting ONLY on this
# container's local disk where a reclaimed session would lose it for good.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
if [ -z "$current_branch" ] || [ "$current_branch" = "HEAD" ]; then
  # Detached HEAD (mid-rebase, etc.) — nothing sensible to push as a branch.
  exit 0
fi

# Reuses whatever origin/<default> already knows locally (from
# session-start.sh's fetch, or any git command since) rather than fetching
# again here — this runs on every single turn, so an extra network round
# trip just to answer "is there anything new to even consider" would be
# wasteful on the overwhelming majority of turns where the answer is no.
default_branch="$(git remote show origin 2>/dev/null | sed -n 's/^[[:space:]]*HEAD branch: //p')"
if [ -z "$default_branch" ]; then
  exit 0
fi

if [ "$current_branch" = "$default_branch" ]; then
  # On the default branch itself — nothing to open a PR against.
  exit 0
fi

default_ref="origin/${default_branch}"
if ! git rev-parse --verify "$default_ref" >/dev/null 2>&1; then
  exit 0
fi

ahead="$(git rev-list --count "$default_ref".."$current_branch" 2>/dev/null || echo 0)"
if [ "$ahead" -eq 0 ]; then
  # Nothing on this branch that isn't already on the default branch — the
  # common case for a turn that only read files or ran tests. Silent no-op.
  exit 0
fi

# Cheap, no-network check: does this branch's local HEAD already match what
# we last knew origin/<branch> to be? If so, and we've already confirmed a
# PR exists for this exact commit, skip the network calls below entirely —
# without this, a long multi-turn session where nothing new gets committed
# after the first push would still hit the GitHub API every single turn.
marker_file=".git/CLAUDE_STOP_HOOK_LAST_SYNCED_$(echo -n "$current_branch" | tr -c 'A-Za-z0-9_' '_')"
local_head="$(git rev-parse HEAD 2>/dev/null)"
last_synced_head=""
if [ -f "$marker_file" ]; then
  last_synced_head="$(cat "$marker_file" 2>/dev/null || true)"
fi
if [ "$local_head" = "$last_synced_head" ]; then
  exit 0
fi

upstream_ref="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
need_push=true
if [ -n "$upstream_ref" ]; then
  remote_head="$(git rev-parse "$upstream_ref" 2>/dev/null || echo "")"
  if [ "$local_head" = "$remote_head" ]; then
    need_push=false
  fi
fi

if [ "$need_push" = true ]; then
  echo "[stop] '$current_branch' has $ahead commit(s) not on ${default_ref} and isn't fully pushed — pushing..."
  if ! git push -u origin "$current_branch" >/tmp/stop-hook-push.log 2>&1; then
    echo "[stop] WARNING: push failed, leaving this session's work only on local disk. Manual push needed:"
    cat /tmp/stop-hook-push.log
    exit 0
  fi
  echo "[stop] Pushed. '$current_branch' is now on origin."
fi

# Everything past this point talks to the GitHub API, so it needs a token.
# git push above doesn't (it went through the repo's own credential helper),
# but the REST API calls below authenticate explicitly.
token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$token" ]; then
  echo "[stop] No GITHUB_TOKEN/GH_TOKEN available — branch is pushed, but couldn't check or open a PR. Open one manually: https://github.com/$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')/pull/new/${current_branch}"
  exit 0
fi

owner_repo="$(git remote get-url origin | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
api="https://api.github.com/repos/${owner_repo}"

existing_pr_url="$(curl -sS \
  -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.github+json" \
  "${api}/pulls?head=${owner_repo%%/*}:${current_branch}&state=open" \
  2>/dev/null | jq -r '.[0].html_url // empty')"

if [ -n "$existing_pr_url" ]; then
  echo "[stop] PR already open for '$current_branch': $existing_pr_url"
  echo "$local_head" > "$marker_file"
  exit 0
fi

pr_title="$(git log -1 --format=%s "$current_branch")"
pr_body_commits="$(git log "$default_ref".."$current_branch" --format='- %s' | jq -Rs .)"
pr_payload="$(jq -n \
  --arg title "$pr_title" \
  --arg head "$current_branch" \
  --arg base "$default_branch" \
  --argjson body_commits "$pr_body_commits" \
  '{title: $title, head: $head, base: $base, body: ("Opened automatically by the Stop hook — this branch had commits not yet on " + $base + ".\n\nCommits:\n" + $body_commits)}')"

create_response="$(curl -sS -X POST \
  -H "Authorization: Bearer ${token}" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  -d "$pr_payload" \
  "${api}/pulls" 2>/dev/null)"

created_url="$(echo "$create_response" | jq -r '.html_url // empty')"
if [ -n "$created_url" ]; then
  echo "[stop] Opened PR for '$current_branch' -> ${default_branch}: $created_url"
  echo "$local_head" > "$marker_file"
else
  error_msg="$(echo "$create_response" | jq -r '.message // "unknown error"')"
  echo "[stop] WARNING: branch is pushed, but PR creation failed: $error_msg"
  echo "$create_response" | head -c 500
fi
