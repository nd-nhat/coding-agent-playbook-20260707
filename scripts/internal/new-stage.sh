#!/usr/bin/env bash
# 新しい stage ブランチを作る。stage/* は main を base にした stacked 連鎖で、
# project 本体は app/ 配下に置く (docs/decisions/stage-stacked-branches.md)。
# base 省略時は連鎖の末尾 (最大の NN) から分岐する。
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  echo "usage: $0 <NN-slug> [<base NN-slug>|main]" >&2
  echo "  e.g. $0 09-next                        # 連鎖末尾の stage から分岐" >&2
  echo "  e.g. $0 09-next 08-server-500-broken   # base を明示" >&2
  exit 1
fi

# --git-common-dir 起点: worktree 内から実行しても main checkout root に解決するため
cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

name=${1#stage/}
case "$name" in
  */*|.*|"")
    echo "error: invalid stage name '$1' (use NN-slug like 09-next)" >&2
    exit 1
    ;;
esac
branch="stage/$name"

if git show-ref --verify --quiet "refs/heads/$branch" \
  || git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  echo "error: branch $branch already exists (local or origin)" >&2
  exit 1
fi

if [ $# -eq 2 ]; then
  base_in=${2#stage/}
  if [ "$base_in" = "main" ]; then base="main"; else base="stage/$base_in"; fi
else
  # fresh clone では local に stage/* が無く origin/stage/* だけのことがあるため両方から末尾を解決する
  base=$(
    {
      git for-each-ref --format='%(refname:short)' 'refs/heads/stage/'
      git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/stage/' | sed 's#^origin/##'
    } | sort -u | tail -1
  )
  [ -n "$base" ] || base="main"
fi

if git show-ref --verify --quiet "refs/heads/$base"; then
  git branch "$branch" "$base"
elif git show-ref --verify --quiet "refs/remotes/origin/$base"; then
  # --no-track: 新 stage の upstream が base branch を向くと plain な git push/pull が base を壊すため
  git branch --no-track "$branch" "origin/$base"
else
  echo "error: base branch '$base' not found (local or origin)" >&2
  exit 1
fi

echo "created: $branch (base: $base)"
echo "next: git switch $branch して app/ 配下を編集する (基盤 root の変更は main への PR -> restack-stages.sh で伝播)"
