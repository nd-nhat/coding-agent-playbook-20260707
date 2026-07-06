#!/usr/bin/env bash
# stage/* ブランチを .worktrees/ 配下に worktree として展開する (instructor / 並列作業用の道具)。
# 受講者の必修ではない: stage は `git switch stage/NN` で開ける (docs/decisions/stage-stacked-branches.md)。
# broken/fixed の並置比較や、複数 box で同一 checkout を共有する並列作業のときに使う。
set -euo pipefail

# --git-common-dir 起点: stage worktree 内から実行しても main checkout root に解決するため
git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir) || exit
cd "$(dirname "$git_common_dir")" || exit 1

# 手動削除された worktree の stale 登録を掃除し、再作成を可能にする
git worktree prune

git fetch origin --prune || echo "warn: fetch failed (offline?), using local refs only" >&2

branches=$(
  {
    git for-each-ref --format='%(refname:short)' 'refs/heads/stage/'
    git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/stage/' | sed 's#^origin/##'
  } | sort -u
)

if [ -z "$branches" ]; then
  echo "no stage/* branches found"
  exit 0
fi

for branch in $branches; do
  slug=${branch#stage/}
  path=".worktrees/$slug"
  if [ -e "$path" ]; then
    echo "skip: $path already exists"
    continue
  fi
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git worktree add --relative-paths "$path" "$branch"
  else
    git worktree add --relative-paths --track -b "$branch" "$path" "origin/$branch"
  fi
done

git worktree list
