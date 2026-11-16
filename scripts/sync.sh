#!/bin/bash
# Optional SSH sync through a Linux checkout that has its own origin credentials.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit or stash local changes first.' >&2
  exit 1
fi
host="${REMOTE_STATS_HOST:-$(git config --get remote-stats.host || true)}"
remote="${REMOTE_STATS_GIT_REMOTE:-$(git config --get remote-stats.gitRemote || echo server)}"
path="${REMOTE_STATS_PATH:-$(git config --get remote-stats.path || echo remote-stats)}"
branch="$(git branch --show-current)"
if [[ -z "$host" || -z "$branch" ]]; then
  echo 'Set REMOTE_STATS_HOST (or git config remote-stats.host) and check out a branch.' >&2
  exit 1
fi
# All pushes/merges reject divergence and dirty checkout overwrites.
printf -v fetch_command 'cd %q && git fetch origin && git merge --ff-only %q' "$path" "origin/$branch"
printf -v push_command 'cd %q && git push origin %q' "$path" "$branch"
ssh -- "$host" "$fetch_command"
git fetch "$remote"
git merge --ff-only "$remote/$branch"
git push "$remote" "HEAD:$branch"
ssh -- "$host" "$push_command"
echo 'Local, Linux, and origin repositories are synchronized.'
