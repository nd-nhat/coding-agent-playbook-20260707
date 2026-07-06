#!/usr/bin/env bash
# claude / codex を最新版に更新する (image rebuild + sbx template 再 load)。
set -euo pipefail

git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir) || exit
cd "$(dirname "$git_common_dir")" || exit 1

# host 専用 (box の中には sbx CLI が無く、これは host で動かす意味しかない)
if ! command -v sbx >/dev/null 2>&1; then
  echo "error: sbx CLI not found. Run this on the host (not inside a box)." >&2
  exit 1
fi

# AGENT_CACHEBUST 経由で installer 行の cache を破棄して claude / codex の最新版を取りに行く。
# 上流の apt / Chromium レイヤーは値が変わらないため cache 再利用される。
# --load は default の docker driver では no-op だが、BUILDX_BUILDER=docker-container/kubernetes/remote
# 設定下では結果を local image store に入れるために必須 (省くと後続の docker save が stale image を拾う)。
docker build --load --build-arg "AGENT_CACHEBUST=$(date +%s)" -t coding-agent-playbook-sbx sbx/

# sbx は host の local image を共有せず registry pull する仕様のため save + template load が必要。
tar="cap-sbx.tar"
trap 'rm -f "$tar"' EXIT
docker save coding-agent-playbook-sbx -o "$tar"
sbx template load "$tar"
# staleness 判定の single source of truth。load 成功後にのみ書く (load 失敗なら古い stamp が残り、
# 次回 preflight が古い template を current と誤認しない)。docker inspect (local image) は sbx template
# store と乖離しうる (build/save 成功・load 失敗で local だけ新しくなる) ため判定に使わない。
# 1 行目 = sbx/Dockerfile commit (rebuild trigger)、2 行目 = build 時刻 (claude/codex の build-age WARN 用)。
# このスタンプは「この checkout から最後に load した template」を表す repo-local 記録 (worktree は
# git-common-dir 親に解決されるため同一 clone 内では共有。別 clone と global template 名を共有する稀な
# 構成では global template が単一名で本質的に 1 つしか持てない既知の制約は解消しない)。
mkdir -p .claude/tmp
{ git log --format=%H -n1 -- sbx/Dockerfile; date -u +%Y-%m-%dT%H:%M:%SZ; } > .claude/tmp/sbx-template-commit.stamp

cat <<'EOF'

image refreshed. To use the new version:
  bash scripts/dev.sh ls            # 旧 image で立てた dev box の一覧
  bash scripts/dev.sh kill <NAME|N> # 旧 dev box を破棄 (cdx-<NAME> pair も同時破棄、state は失われる)
  bash scripts/dev.sh               # 新 image で再作成 (引数なし = 自動命名)
EOF
