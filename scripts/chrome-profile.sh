#!/usr/bin/env bash
# chrome-profile: host session の claude (chrome-profile MCP) が接続する、ログイン状態を
# 保持する専用 profile の headful Chrome を上げ下げする helper。用途は WebFetch / curl で
# 取れないページ (ログイン必須・bot 判定等) の取得・操作。
#
# host session 専用。profile は persistent (down しても残る = ログインの持続が目的)。
# box から host の見える Chrome を操作したい場合は cdp-bridge.sh (docs/guide/headful-bridge.md) を使う。
#
# == SECURITY (必読) ==
# CDP はこのブラウザの全権 (任意 JS 実行 / cookie・session 読取 / navigate) を agent に渡す。
# この profile でログインしてよいのは**検証用アカウントだけ**。実アカウント・機微サイト
# (銀行 / 個人メール等) にはログインしない。詳細: docs/guide/chrome-profile.md
set -euo pipefail

PORT="${CHROME_PROFILE_PORT:-9335}"

in_box() { [ -n "${SANDBOX_VM_ID:-}" ]; }

# profile は port ごとに分離 (--port で 2 個目の profile を並走できる)。box に bind-mount
# されない host-only の cache 配下に置き、down では削除しない (ログイン状態の永続が目的)。
profile_dir() { echo "${XDG_CACHE_HOME:-$HOME/.cache}/coding-agent-playbook/chrome-profile-$PORT"; }

# pkill/pgrep -f は pattern を ERE として解釈するため、path 中の regex メタ文字を literal 化する
escape_ere() { printf '%s' "$1" | sed 's/[][^$.*+?(){}|\\]/\\&/g'; }

# HTTP 成功だけだと 404 や /json/version に 2xx を返す非 CDP サービスを誤判定するため、
# CDP 固有フィールド (webSocketDebuggerUrl) の存在まで検証する。
port_speaks_cdp() {
  curl -fsS --noproxy '*' --max-time 1 "http://localhost:$PORT/json/version" 2>/dev/null \
    | grep -q webSocketDebuggerUrl
}

# 127.0.0.1:$PORT に listener が無い (connect 拒否) なら free。/dev/tcp は bash 組込み。
port_free() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 1 || return 0; }

find_chrome() {
  local c win_local=""
  # Git Bash (Windows) の per-user install は $LOCALAPPDATA 配下。cygpath で POSIX path に変換
  if [ -n "${LOCALAPPDATA:-}" ] && command -v cygpath >/dev/null 2>&1; then
    win_local="$(cygpath -u "$LOCALAPPDATA")/Google/Chrome/Application/chrome.exe"
  fi
  for c \
    in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
       "/c/Program Files/Google/Chrome/Application/chrome.exe" \
       "/c/Program Files (x86)/Google/Chrome/Application/chrome.exe" \
       ${win_local:+"$win_local"} \
       google-chrome google-chrome-stable chromium chromium-browser chrome; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

wait_chrome_ready() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if port_speaks_cdp; then return 0; fi
    sleep 0.5
  done
  return 1
}

up() {
  local dir; dir=$(profile_dir)
  if port_speaks_cdp; then
    # 応答者が本 helper の profile で起動した Chrome か cmdline で確認する (launch 引数の
    # 隣接順に依存)。別プロセス (実 profile の Chrome かもしれない) なら、そのブラウザへ
    # MCP を繋がせないため中止する
    if command -v pgrep >/dev/null 2>&1 \
      && pgrep -f -- "--remote-debugging-port=$PORT --user-data-dir=$(escape_ere "$dir")( |\$)" >/dev/null 2>&1; then
      echo "localhost:$PORT は既に本 helper の Chrome が応答しています (起動済み)。"
      echo "profile: $dir"
      exit 0
    fi
    echo "error: localhost:$PORT で別プロセスが CDP を listen しています (実 profile の Chrome の可能性)。" >&2
    echo "       そのブラウザへ MCP を繋がせないため中止します。閉じるか --port <別 port> を指定してください。" >&2
    exit 1
  fi
  if ! port_free; then
    echo "error: localhost:$PORT は CDP 以外のプロセスが使用中です。--port <別 port> を指定してください。" >&2
    exit 1
  fi
  local chrome; chrome=$(find_chrome) || { echo "error: Chrome/Chromium が見つかりません。" >&2; exit 1; }
  mkdir -p "$dir"
  "$chrome" --remote-debugging-port="$PORT" --user-data-dir="$dir" \
    --no-first-run --no-default-browser-check about:blank >/dev/null 2>&1 &
  local chrome_pid=$!
  if ! wait_chrome_ready; then
    # 起動した process を放置すると persistent profile の Chrome が debug port を開いたまま残る
    kill "$chrome_pid" 2>/dev/null || true
    echo "error: Chrome が localhost:$PORT で応答しません (起動した process は停止しました)。" >&2
    exit 1
  fi
  cat <<EOF
chrome-profile Chrome 起動 (port=$PORT, profile=$dir)。
  - ログインが要るサイトは、この Chrome の窓で人間が**検証用アカウント**でログインしておく (profile に永続)
  - claude からは chrome-profile MCP (committed .mcp.json) で操作できる (MCP は session 起動時に load)
終了時: bash scripts/chrome-profile.sh down (profile は残る)
EOF
}

down() {
  local dir; dir=$(profile_dir)
  if command -v pkill >/dev/null 2>&1; then
    # profile dir で自分の起動した Chrome だけに match する (他の Chrome は殺さない)。末尾の
    # ( |$) 境界は port 違いの姉妹 profile (chrome-profile-933 vs -9335) への prefix 誤 match 防止
    pkill -f -- "--user-data-dir=$(escape_ere "$dir")( |\$)" 2>/dev/null || true
  fi
  echo "chrome-profile Chrome (profile=$dir) を停止しました (profile は保持、ログイン状態は次回 up で復元)。"
}

status() {
  local ok=no
  port_speaks_cdp && ok=yes
  echo "chrome-profile Chrome CDP (localhost:$PORT): $ok"
  echo "profile: $(profile_dir)"
}

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/chrome-profile.sh <up|down|status> [--port N]
  up      ログイン用 persistent profile の headful Chrome を remote-debugging 付きで起動
  down    その Chrome を停止 (profile は削除しない = ログイン状態が残る)
  status  CDP の応答確認
options: --port N (=CHROME_PROFILE_PORT, 9335)。profile は port ごとに分離
SECURITY: 検証用アカウント限定。実アカウント・機微サイトにはログインしない。
host session 専用 (box から host の Chrome を使うなら docs/guide/headful-bridge.md)。
詳細: docs/guide/chrome-profile.md
USAGE
}

verb="${1:-help}"
if [ $# -gt 0 ]; then shift; fi
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: $1 に値がありません" >&2; usage; exit 1; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --port)   need_value "$@"; PORT="$2"; shift 2 ;;
    --port=*) PORT="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# 空・非数値・範囲外の port は URL / /dev/tcp / --remote-debugging-port が壊れた値で走るため先に弾く
case "$PORT" in
  ''|*[!0-9]*) echo "error: --port は 1-65535 の数値で指定してください (got: '$PORT')" >&2; exit 1 ;;
esac
# 桁数 check を先に置く: shell integer 範囲外の巨大 digit 列は [ -lt/-gt ] が "integer
# expression expected" (status 2) になり、if 条件内では false 扱いで検証をすり抜けるため
if [ "${#PORT}" -gt 5 ] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "error: --port は 1-65535 の数値で指定してください (got: $PORT)" >&2
  exit 1
fi

if in_box; then
  echo "error: 本 script は host 専用です (box 内では chrome-profile MCP は使えません)。" >&2
  echo "       box から host の見える Chrome を操作したい場合は docs/guide/headful-bridge.md (cdp-bridge) を使ってください。" >&2
  exit 5
fi

case "$verb" in
  up)     up ;;
  down)   down ;;
  status) status ;;
  help|-h|--help) usage ;;
  *) echo "unknown verb: $verb" >&2; usage; exit 1 ;;
esac
