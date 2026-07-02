#!/usr/bin/env bash
# host 側ヘルパー: per-NAME pair (claude box `<NAME>` + reviewer box `cdx-<NAME>`) の lifecycle と A2A 通信。
# 設計: lifecycle 責務はこの script に集約し dev.sh は call only (debate 2026-06-27 結論、bash supervisor anti-pattern 回避)。
#       reviewer 起動順: pair-setup (create + bootstrap) → pair-serve (publish + policy + lease + foreground hold) → pair-teardown (kill + rm + lease 削除)
set -euo pipefail

CDX_BOX_PREFIX=cdx
SERVER_PORT_IN_BOX=9999
EXAMPLE_DIR=tools/a2a-review

# main checkout root から実行 (box / worktree のどこから呼んでも解決。box は main root を direct mount する想定で
# .worktrees/<NN>/ も box から見える)
cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

cdx_box_of() { printf '%s-%s' "$CDX_BOX_PREFIX" "$1"; }
lease_path_of() { printf '.claude/tmp/cdx-serve-%s.lease' "$1"; }

# claude box NAME の syntax validation (dev.sh と同じ規約)。pair-* で誤った name を受け取らないようにする。
validate_name() {
  case "$1" in
    "") echo "error: NAME が空です" >&2; exit 1 ;;
    -*|*[^A-Za-z0-9-]*)
      echo "error: NAME '$1' must match ^[A-Za-z0-9][A-Za-z0-9-]*\$ (start with alphanumeric, then alphanumeric or hyphen only)" >&2
      exit 1 ;;
  esac
}

# /proc/<pid>/stat field 22 (Linux/MSYS2) / ps -o lstart= (macOS/BSD)。
# 空文字は未取得 (非致命的: 呼び出し元は kill -0 のみで判定する旧来動作に fallback する)。
get_proc_start_time() {
  local pid=$1
  if [ -r "/proc/$pid/stat" ]; then
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true
  else
    ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ *//' || true
  fi
}

# start_time の取得方式タグ (proc|lstart)。bash と PowerShell (ticks) で format が異なるため、
# reader は kind 一致時のみ start_time を比較し不一致 (cross-language lease) は pid-only に倒す。
get_proc_start_kind() {
  if [ -r "/proc/$1/stat" ]; then printf 'proc'; else printf 'lstart'; fi
}

# start_time は PID 再利用検証用 (kill -0 は再利用 PID を alive と誤判定するため)。lease path は project-root 相対で box からも同じ path で見える (bind-mount 経由)。
write_lease() {
  lease=$1; shift
  mkdir -p .claude/tmp
  local st st_kind
  st=$(get_proc_start_time "$1") || st=""
  st_kind=$(get_proc_start_kind "$1") || st_kind=""
  printf '{"pid":%d,"start_time":"%s","start_time_kind":"%s","port":%d,"claude_box":"%s","cdx_box":"%s","advertise":"%s","started_at":%d,"repo_root":"%s"}\n' \
    "$1" "$st" "$st_kind" "$2" "$3" "$4" "$5" "$6" "$7" > "$lease"
}

cleanup_lease() {
  rm -f "$1" 2>/dev/null || true
}

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/internal/a2a-review.sh <command> [args]
  pair-setup <NAME> [workspace]   reviewer box cdx-<NAME> を作成 + bootstrap (一度だけ。dev.sh が auto call)
  pair-serve <NAME>               cdx-<NAME> の A2A server を起動・publish・policy・lease 書き込み + foreground 保持 (dev.sh が bg fork で call)
  pair-teardown <NAME>            cdx-<NAME> の server kill + box 削除 + lease 削除 (dev.sh が trap で call)
  ask <instruction> [url]         box の中から codex reviewer に A2A client を投げる。url 既定 = $A2A_CODEX_URL or host.docker.internal:9999
  help
codex box は openai OAuth secret が要る (sbx secret set -g openai --oauth)。詳細: tools/a2a-review/README.md
USAGE
}

# exit 2 = sbx ls 失敗 (transient daemon error)。2 を不在と同一視禁止: pair-teardown が誤判定して cdx box が残ったまま port anchor (lease) を失う silent leak になる。
box_exists() {
  local out ec
  out=$(sbx ls 2>/dev/null)
  ec=$?
  if [ "$ec" -ne 0 ]; then return 2; fi
  printf '%s\n' "$out" | awk -v b="$1" '$1==b {found=1} END {exit !found}'
}

server_up_in() {
  sbx exec "$1" sh -lc 'curl -fsS "http://127.0.0.1:'"$SERVER_PORT_IN_BOX"'/.well-known/agent-card.json" >/dev/null 2>&1'
}

# pkill 後の async race を避ける: endpoint が落ちる (= server_up_in=false) まで polling で待つ
wait_for_server_down_in() {
  i=0
  while [ "$i" -lt 10 ]; do
    if ! server_up_in "$1"; then return 0; fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

bootstrap_cdx_box() {
  cdx_box=$1
  workspace=$2
  local brc=0
  box_exists "$cdx_box" || brc=$?
  if [ "$brc" = 2 ]; then
    echo "error: 'sbx ls' が失敗しました (transient failure)。box '$cdx_box' の存在確認ができません。再試行してください。" >&2
    exit 1
  fi
  if [ "$brc" = 0 ]; then
    echo "box '$cdx_box' は既存。" >&2
  else
    sbx create --name "$cdx_box" codex -t coding-agent-playbook-sbx "$workspace"
  fi
  # .venv は host bind-mount の `tools/a2a-review/...` 配下に作られる = 全 cdx-<NAME> box で共有される共有資源。
  # parallel dev.sh foo / dev.sh bar が同時に uv venv + uv pip install を叩くと race で corrupt するため、
  # `mkdir` (POSIX atomic) で directory lock を取って serialize する (codex review 2026-06-27 finding)。
  # alive holding pid は無制限に待つ (codex R9 finding: slow first install で >120s かかる場合に force-take すると mid-install corrupt の regression)。
  # stale (pid dead) は即除去して retry。10 min 経って alive のままなら hang 疑いで error exit (force-take しない、user 介入を促す)。
  VENV_LOCK_DIR=".claude/tmp/cdx-venv-bootstrap.lock.d"
  mkdir -p .claude/tmp
  attempts=0
  while ! mkdir "$VENV_LOCK_DIR" 2>/dev/null; do
    held_pid=$(cat "$VENV_LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$held_pid" ] && ! kill -0 "$held_pid" 2>/dev/null; then
      echo "info: stale venv bootstrap lock (pid=$held_pid dead) を除去します" >&2
      rm -rf "$VENV_LOCK_DIR"
      continue
    fi
    attempts=$((attempts + 1))
    if [ "$attempts" -gt 600 ]; then
      echo "error: venv bootstrap lock を 10 min 保持中 (pid=$held_pid alive)、hang を疑います。手動で 'rm -rf $VENV_LOCK_DIR' (確認後) してから再試行してください。" >&2
      exit 1
    fi
    sleep 1
  done
  echo $$ > "$VENV_LOCK_DIR/pid" 2>/dev/null || true
  # Function-level trap で abnormal exit でも lock release (parent dev.sh の trap には影響しない、本 function は subprocess で run)
  trap 'rm -rf "'"$VENV_LOCK_DIR"'" 2>/dev/null || true' EXIT INT TERM
  if [ ! -x "$EXAMPLE_DIR/codex-a2a-server/.venv/bin/python" ]; then
    sbx exec "$cdx_box" sh -lc 'cd "$1" && uv venv && uv pip install -e .' _ "$EXAMPLE_DIR/codex-a2a-server"
  fi
  if [ ! -x "$EXAMPLE_DIR/client-demo/.venv/bin/python" ]; then
    sbx exec "$cdx_box" sh -lc 'cd "$1" && uv venv && uv pip install -e .' _ "$EXAMPLE_DIR/client-demo"
  fi
  rm -rf "$VENV_LOCK_DIR" 2>/dev/null || true
  trap - EXIT INT TERM
}

do_pair_setup() {
  validate_name "$1"
  bootstrap_cdx_box "$(cdx_box_of "$1")" "${2:-$PWD}"
  echo "pair-setup 完了: cdx-$(printf '%s' "$1")。pair-serve で起動: bash scripts/internal/a2a-review.sh pair-serve $1" >&2
}

# dev.sh が pair-serve を bg fork するため foreground で server を保持し、dev.sh の trap が kill する設計 (debate 2026-06-27)。
# port は `sbx ports --publish <port>` (hostport 省略 = kernel ephemeral) + `sbx ports <box>` 読み返しで取得。hash / registry は使わない (debate Antigravity 案、衝突確率 0%)。
serve_codex_for() {
  claude_box=$1
  cdx_box=$(cdx_box_of "$claude_box")
  lease=$(lease_path_of "$claude_box")

  local brc=0
  box_exists "$cdx_box" || brc=$?
  if [ "$brc" = 2 ]; then
    echo "error: 'sbx ls' が失敗しました (transient failure)。box '$cdx_box' の存在確認ができません。再試行してください。" >&2
    exit 1
  fi
  if [ "$brc" != 0 ]; then
    echo "error: cdx box '$cdx_box' がありません。先に pair-setup: bash scripts/internal/a2a-review.sh pair-setup $claude_box" >&2
    exit 1
  fi

  # 旧 server を kill (再 serve 対策)。[s] char class で pkill 自身に当たらない。
  sbx exec "$cdx_box" sh -lc 'pkill -f "[s]erver.py" 2>/dev/null; true'
  if ! wait_for_server_down_in "$cdx_box"; then
    echo "error: 旧 server が 10 秒以内に終了しません。box 内 log: sbx exec $cdx_box cat /tmp/a2a-server.log" >&2
    exit 1
  fi

  # 再 serve で前回の publish が残っていると 409 になるため事前に unpublish (idempotent)。
  # awk が一致行を 1 つ出した場合のみ unpublish。pipefail 下で grep -E がマッチなし exit 1 にならないよう awk 一発で取得。
  old_hostport=$(sbx ports "$cdx_box" 2>/dev/null \
    | awk -v p="$SERVER_PORT_IN_BOX" '$1=="127.0.0.1" && $3==p {print $2; exit}' || true)
  if [ -n "$old_hostport" ]; then
    sbx ports "$cdx_box" --unpublish "${old_hostport}:${SERVER_PORT_IN_BOX}" 2>/dev/null || true
  fi

  # advertise URL を先に書きたいが host port が ephemeral なので server 起動前に publish しておく必要がある。
  # box は idle 停止対策で server を中で foreground 保持するため、publish は先行で OK (server 起動完了は curl probe で待つ)。
  sbx ports "$cdx_box" --publish "$SERVER_PORT_IN_BOX"
  # `sbx ports <box>` 出力例 (header + space-separated): `127.0.0.1  32768  9999  tcp`。$3 == 9999 の host 列 ($2) を抽出する。
  hostport=$(sbx ports "$cdx_box" \
    | awk -v p="$SERVER_PORT_IN_BOX" '$1=="127.0.0.1" && $3==p {print $2; exit}')
  if [ -z "$hostport" ]; then
    echo "error: cdx-$claude_box の host port を解決できませんでした (publish 失敗?)" >&2
    sbx ports "$cdx_box" >&2 || true
    exit 1
  fi
  advertise="http://host.docker.internal:$hostport"

  # claude box の egress 許可 (cdx-<NAME> reviewer に届くように)。dev.sh は本 function を bg fork する一方で並行して claude box を `sbx run` で create するため、box 作成完了前に policy を発行すると "sandbox not found" で fail する。box 出現まで最大 60s retry する。
  i=0
  while [ "$i" -lt 60 ]; do
    if sbx policy allow network --sandbox "$claude_box" "localhost:$hostport" 2>/dev/null; then
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ "$i" = 60 ]; then
    echo "error: 60s 経過しても claude box '$claude_box' が出現せず policy 発行に失敗しました" >&2
    exit 1
  fi

  echo "codex server を advertise=$advertise で起動・保持します (foreground、SIGTERM で停止)..." >&2
  sbx exec "$cdx_box" sh -lc 'cd "$1" && A2A_ADVERTISE_URL="$2" exec .venv/bin/python server.py >/tmp/a2a-server.log 2>&1' \
    _ "$EXAMPLE_DIR/codex-a2a-server" "$advertise" &
  server_pid=$!

  # EXIT trap: server kill + 自分が発行した sbx policy allow rule の revoke (codex review 2026-06-27 finding: ephemeral host port が dead 後も stale rule として残ると OS が同 port を別 service に再利用した際に egress が漏れるため即時 revoke) + lease 削除。各 step に `|| true` を付けて set -e 下で残り step が必ず走るようにする。
  trap '
    kill "$server_pid" 2>/dev/null || true
    sbx policy rm network --sandbox "'"$claude_box"'" --resource "localhost:'"$hostport"'" >/dev/null 2>&1 || true
    cleanup_lease "'"$lease"'"
    true
  ' EXIT INT TERM

  i=0
  while [ "$i" -lt 30 ]; do
    if server_up_in "$cdx_box"; then break; fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      echo "error: server プロセスが終了しました。box log: sbx exec $cdx_box cat /tmp/a2a-server.log" >&2
      exit 1
    fi
    i=$((i + 1))
    sleep 1
  done
  server_up_in "$cdx_box" || { echo "error: server が起動しません。box log: sbx exec $cdx_box cat /tmp/a2a-server.log" >&2; exit 1; }

  write_lease "$lease" "$server_pid" "$hostport" "$claude_box" "$cdx_box" "$advertise" "$(date +%s)" "$PWD"
  echo "codex reviewer ready (box=$cdx_box, $advertise)。box '$claude_box' 内から: bash scripts/internal/a2a-review.sh ask \"<指示>\"" >&2
  wait "$server_pid"
}

# 多重 call (pair-serve の EXIT trap と dev.sh の EXIT trap) でも idempotent。
# pair-serve の trap が既に policy revoke + lease 削除を実行している通常経路では本 function の policy 読み取り = no-op だが、
# orphan box (crashed dev.sh で trap 未実行) を後から掃除する経路では lease から hostport を読んで policy も revoke する。
do_pair_teardown() {
  validate_name "$1"
  cdx_box=$(cdx_box_of "$1")
  lease=$(lease_path_of "$1")
  local teardown_failed=0
  if [ -f "$lease" ]; then
    hostport=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$lease" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    if [ -n "$hostport" ]; then
      # policy rm 失敗時は lease を消さずに残す (port 情報を保持し再試行可能に保つ。lease を消すと唯一の port anchor が失われる)。
      sbx policy rm network --sandbox "$1" --resource "localhost:$hostport" >/dev/null 2>&1 || teardown_failed=1
    fi
  fi
  local brc=0
  box_exists "$cdx_box" || brc=$?
  if [ "$brc" = 2 ]; then
    echo "error: 'sbx ls' が失敗しました (transient failure)。teardown を中断します (lease は port anchor 保持のため残します)。" >&2
    teardown_failed=1
  elif [ "$brc" = 0 ]; then
    sbx exec "$cdx_box" sh -lc 'pkill -f "[s]erver.py" 2>/dev/null; true' 2>/dev/null || true
    sbx rm -f "$cdx_box" >/dev/null 2>&1 || true
    # sbx rm の exit code は信頼できないため (suppress 含む)、box 再 list で実体 verify。
    local rm_brc=0
    box_exists "$cdx_box" || rm_brc=$?
    if [ "$rm_brc" = 2 ]; then
      echo "warning: 'sbx ls' が失敗しました。'sbx rm' の完了を確認できません (lease は残します)。" >&2
      teardown_failed=1
    elif [ "$rm_brc" = 0 ]; then
      teardown_failed=1
    fi
    # rm_brc=1 = box が消えた = 成功
  fi
  if [ "$teardown_failed" = 1 ]; then
    # lease を残して non-zero exit。次回 pair-teardown / prune での再試行を可能にする。
    # 既存呼び出し元 (cmd_kill / dev.sh の trap teardown) は `|| true` で suppress しているため、本変更は exit code を意識する prune 等の新経路のみに影響する。
    return 1
  fi
  cleanup_lease "$lease"
}

# NO_PROXY の bracket IPv6 で httpx が落ちる件は client.py 側で sanitize 済み。
# URL 解決順: 明示引数 → $A2A_CODEX_URL → 現 box の per-NAME lease (`.claude/tmp/cdx-serve-$SANDBOX_VM_ID.lease`) の advertise → 旧 fallback 9999 (warn)。
ask_codex() {
  instruction=$1
  url=$2
  [ -n "$instruction" ] || { echo "error: ask には指示が要る" >&2; usage; exit 1; }
  if [ -z "$url" ]; then
    if [ -n "${A2A_CODEX_URL:-}" ]; then
      url="$A2A_CODEX_URL"
    elif [ -n "${SANDBOX_VM_ID:-}" ] && [ -f "$(lease_path_of "$SANDBOX_VM_ID")" ]; then
      url=$(grep -oE '"advertise"[[:space:]]*:[[:space:]]*"[^"]*"' "$(lease_path_of "$SANDBOX_VM_ID")" | head -1 | sed -E 's/^"advertise"[[:space:]]*:[[:space:]]*"//;s/"$//')
    fi
    if [ -z "$url" ]; then
      url="http://host.docker.internal:9999"
      echo "warning: URL を解決できず legacy default $url を使用します (per-NAME pair lease 不在)" >&2
    fi
  fi
  if [ ! -x "$EXAMPLE_DIR/client-demo/.venv/bin/python" ]; then
    echo "client を install します..." >&2
    ( cd "$EXAMPLE_DIR/client-demo" && uv venv && uv pip install -e . )
  fi
  "$EXAMPLE_DIR/client-demo/.venv/bin/python" "$EXAMPLE_DIR/client-demo/client.py" --server "$url" --review "$instruction"
}

cmd=${1:-help}
case "$cmd" in
  pair-setup)
    do_pair_setup "${2:-}" "${3:-}"
    ;;
  pair-serve)
    name=${2:-}
    validate_name "$name"
    serve_codex_for "$name"
    ;;
  pair-teardown)
    do_pair_teardown "${2:-}"
    ;;
  ask)
    ask_codex "${2:-}" "${3:-}"
    ;;
  help | -h | --help)
    usage
    ;;
  *)
    echo "error: unknown command '$cmd' (try help)" >&2
    usage
    exit 1
    ;;
esac
