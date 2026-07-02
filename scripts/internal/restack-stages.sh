#!/usr/bin/env bash
# main の基盤変更を stage 連鎖 (stage/01 → 02 → … → 末尾) へ cascade merge で伝播する
# (docs/decisions/stage-stacked-branches.md 決定 2。明示で叩く — 常駐同期はしない)。
# app/ (project 本体) と基盤 (root) はパスが重ならないため merge は自動解決する。
# main checkout の branch を変えないため、一時 worktree の中で merge する。
set -euo pipefail

# --git-common-dir 起点: worktree 内から実行しても main checkout root に解決するため
cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

stages=$(git for-each-ref --format='%(refname:short)' 'refs/heads/stage/' | sort)
if [ -z "$stages" ]; then
  echo "error: local stage/* branches が無い (git fetch origin '+refs/heads/stage/*:refs/heads/stage/*' で取得)" >&2
  exit 1
fi

wt=".worktrees/.restack-tmp"

# 前回 conflict の temp worktree が残っている場合の再実行パス:
# 未解決 (dirty) なら案内して停止、解決済み (clean) なら除去して続行する
if [ -d "$wt" ]; then
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    echo "error: $wt に未解決の merge が残っています。$wt で解決して commit 後、再実行してください" >&2
    exit 1
  fi
  git worktree remove --force "$wt" 2>/dev/null || true
fi

# merge は branch の checkout を伴うため、対象 stage が既存 worktree に展開済みだと衝突する
# (temp worktree は上で除去済みなのでここには現れない)
for br in $stages; do
  if git worktree list --porcelain | grep -qxF "branch refs/heads/$br"; then
    echo "error: $br が worktree に checkout 済み。先に 'git worktree remove' してから再実行" >&2
    exit 1
  fi
done

trap 'git worktree remove --force "$wt" 2>/dev/null || true' EXIT

first=$(printf '%s\n' "$stages" | head -1)
git worktree add --relative-paths "$wt" "$first" >/dev/null

prev="main"
for br in $stages; do
  git -C "$wt" switch -q "$br"
  if ! git -C "$wt" merge --no-edit -q "$prev"; then
    echo "error: $br への merge が conflict しました (app/ と基盤はパスが重ならない前提が崩れている)。" >&2
    echo "       $wt で解決して commit 後、再実行してください" >&2
    trap - EXIT
    exit 1
  fi
  echo "restacked: $br <= $prev"
  prev="$br"
done

echo "done. origin へ反映するには:"
echo "  git push origin $(printf '%s ' $stages)"
