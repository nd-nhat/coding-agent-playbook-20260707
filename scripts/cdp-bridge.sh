#!/usr/bin/env bash
# headful CDP bridge: box の中の claude (chrome-devtools MCP) から
# host の「見える Chrome」を CDP で操作するための上げ下げヘルパー。
#
# 同じコマンドが context で振る舞いを変える (dev.sh と同じ思想):
#   - HOST 側 ($SANDBOX_VM_ID 無し): 使い捨て profile の見える Chrome を
#     remote-debugging 付きで起動し、box -> host:<port> の egress を許可する。
#   - BOX 側  ($SANDBOX_VM_ID 有り): box localhost:<relay> -> sbx proxy(CONNECT)
#     -> host:<port> をトンネルする socat 中継を立てる。puppeteer
#     (chrome-devtools-mcp --browser-url http://localhost:<relay>) はこの中継に直結する。
#
# == SECURITY (必読) ==
# CDP = そのブラウザの全権 (任意 JS 実行 / cookie・session 読取 / navigate)。
# 本 script は host 側で **実 profile と別の使い捨て profile** を強制し、実 profile を拒否する。
# bridge した Chrome は「agent のブラウザ」とみなし、**実アカウントでログインしない**こと。
# 経路は loopback (127.0.0.1) 限定 + tight な policy allow (localhost:<port> のみ)。
# 詳細と背景は docs/headful-bridge.md 参照。
set -euo pipefail

PORT="${CDP_PORT:-9222}"            # host Chrome の remote-debugging port
RELAY_PORT="${CDP_RELAY_PORT:-9333}" # box 内 relay の listen port
# --port / CDP_PORT が明示されたか。明示時は占有 port を auto 回避せず従来通り abort し、
# 非明示 (既定 9222) なら host up で空き port を自動 scan する (下記 host_resolve_port)。
PORT_EXPLICIT=0; [ -n "${CDP_PORT:-}" ] && PORT_EXPLICIT=1
NO_CONNECT=0                         # host up で box relay の自動起動を抑止 (--no-connect)
# CDP_PROFILE_DIR が明示されればそれを使い auto 削除しない。未指定なら up 時に mktemp で
# 毎回新規作成し down で削除する (真の throwaway)。PROFILE_DIR は resolve_profile_dir で確定する。
PROFILE_DIR_EXPLICIT="${CDP_PROFILE_DIR:-}"
PROFILE_DIR=""

in_box() { [ -n "${SANDBOX_VM_ID:-}" ]; }

# repo root (main checkout root) に解決。box / worktree のどこから呼んでも一定にし、
# box-side state (relay pidfile/log) の置き場を安定させる。
repo_root() { dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; }
TMPDIR_REPO="$(repo_root 2>/dev/null || echo .)/.claude/tmp"
# host 専用 state dir: profile path / policy id+scope は host 側の cleanup handle で、bind-mount
# 上に置くと box agent が事前に rm して host_down の kill/revoke を空振りさせられる (P1 security)。
# $XDG_CACHE_HOME 優先で box から見えない host-only path に分離する。relay は box-side なので
# .claude/tmp に残す (box から自分の relay state を見る必要があるため)。
HOST_STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/coding-agent-playbook/cdp-bridge"
# relay の state は box 側資源。.claude/tmp は全 box が同じ repo を bind-mount するため共有で、
# box 名で namespace しないと並列 dev box が互いの relay pidfile を壊し合う ($SANDBOX_VM_ID を混ぜる)。
relay_box_tag()    { echo "${SANDBOX_VM_ID:-host}"; }
relay_pidfile()    { echo "$TMPDIR_REPO/cdp-relay-$(relay_box_tag)-$RELAY_PORT.pid"; }
relay_logfile()    { echo "$TMPDIR_REPO/cdp-relay-$(relay_box_tag)-$RELAY_PORT.log"; }
policy_idfile()    { echo "$HOST_STATE_DIR/cdp-policy-$PORT.id"; }
# up 時の CDP_BOX scope を保存し、down で `--sandbox` を一致させる (env が消えても rule を消せる)。
policy_scopefile() { echo "$HOST_STATE_DIR/cdp-policy-$PORT.scope"; }
profile_pathfile() { echo "$HOST_STATE_DIR/cdp-profile-$PORT.path"; }
# host up が選んだ port を記録 (port-keyed でない単一 pointer)。down/status が --port 無しで port を引く。
last_port_file()   { echo "$HOST_STATE_DIR/cdp-last-port"; }
# up 時の relay port も記録: down が --relay-port 無しで叩かれても box relay (RELAY_PORT keyed) を畳めるように。
last_relay_file()  { echo "$HOST_STATE_DIR/cdp-last-relay"; }

# implicit mode の使い捨て profile path として安全か検証する。pathfile は repo bind-mount 上にあり
# box の agent が値を書き換えうるため、cleanup の rm -rf 前にこれを通して任意 host dir 削除を阻止する。
# 受理条件: 実存 dir かつ canonical 化後 basename が mktemp 形式 (cdp-bridge-profile-XXXXXX) かつ
# 親 dir が ${TMPDIR:-/tmp} or /tmp の canonical のいずれかと完全一致。
is_safe_throwaway_profile() {
  local p="$1" canon parent base
  [ -d "$p" ] || return 1
  canon=$(canonical_path "$p")
  base=${canon##*/}
  parent=${canon%/*}
  [[ "$base" =~ ^cdp-bridge-profile-[A-Za-z0-9]{6}$ ]] || return 1
  local allowed=()
  [ -n "${TMPDIR:-}" ] && allowed+=("$(canonical_path "${TMPDIR%/}")")
  [ -d /tmp ] && allowed+=("$(canonical_path /tmp)")
  local ap
  for ap in "${allowed[@]}"; do
    [ "$parent" = "$ap" ] && return 0
  done
  return 1
}

# implicit は throwaway 契約により常に fresh mktemp (preflight 後の reuse は stale session/cookie
# を引き継ぐ)。旧 pathfile が指す dir は safety check 経由で掃除。
resolve_profile_dir_up() {
  if [ -n "$PROFILE_DIR_EXPLICIT" ]; then
    PROFILE_DIR="$PROFILE_DIR_EXPLICIT"
    return
  fi
  local pf; pf=$(profile_pathfile)
  if [ -s "$pf" ]; then
    local stale; stale="$(cat "$pf")"
    if [ -n "$stale" ] && is_safe_throwaway_profile "$stale"; then
      rm -rf "$stale" 2>/dev/null || true
    fi
    rm -f "$pf" 2>/dev/null || true
  fi
  mkdir -p "$HOST_STATE_DIR"
  PROFILE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cdp-bridge-profile-XXXXXX")"
  printf '%s\n' "$PROFILE_DIR" > "$pf"
}

# down 時に PROFILE_DIR を解決 (cleanup 対象)。explicit ならそれ、無ければ pathfile 由来。
resolve_profile_dir_down() {
  if [ -n "$PROFILE_DIR_EXPLICIT" ]; then
    PROFILE_DIR="$PROFILE_DIR_EXPLICIT"
    return
  fi
  local pf; pf=$(profile_pathfile)
  if [ -s "$pf" ]; then PROFILE_DIR="$(cat "$pf")"; else PROFILE_DIR=""; fi
}

# ---- host 側 ----------------------------------------------------------------

# symlink / 相対経由で実 profile を指す回避を塞ぐため canonical (絶対・symlink 解決) path を返す。
# 存在する dir は cd -P で実体解決 (realpath 非依存で macOS/Linux/Git Bash 共通)。未作成 path は
# そのまま返す (これから mktemp で作る使い捨ては実 profile ではないため判定対象外で良い)。
canonical_path() {
  local p="$1" tail="" leaf parent base
  # 既存の最長祖先まで遡る (cd -P が途中 component の symlink も解決するよう、未存在 leaf 直下に
  # symlink 親がある CDP_PROFILE_DIR=/tmp/link/Default のケースも canonical 化するため)。未存在の
  # tail は退避して後で再結合する。
  while [ -n "$p" ] && [ ! -e "$p" ]; do
    leaf=$(basename -- "$p")
    if [ -n "$tail" ]; then tail="$leaf/$tail"; else tail="$leaf"; fi
    parent=$(dirname -- "$p")
    [ "$parent" = "$p" ] && { p=""; break; }
    p="$parent"
  done
  [ -n "$p" ] || { printf '%s' "$1"; return; }   # path 上に何も存在しない = これから作る throwaway
  if [ -d "$p" ]; then base=$( cd -- "$p" 2>/dev/null && pwd -P ) || base="$p"
  else base="$p"; fi
  if [ -n "$tail" ]; then printf '%s/%s' "$base" "$tail"; else printf '%s' "$base"; fi
}

# 実 (日常使い) profile を bridge に使わせない。最悪でも creds 無しの空ブラウザだけ触らせる。
# Chrome 系列だけでなく Beta/Canary/Chromium/Edge/Brave の実 profile root も塞ぐ (guard は
# safety net であり網羅は不可能なため、既定の throwaway 運用を崩さないことが第一の防御)。
guard_profile() {
  local canon; canon=$(canonical_path "$PROFILE_DIR")
  # Linux Chromium docs ( https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md )
  # honor $CHROME_CONFIG_HOME / $XDG_CONFIG_HOME for the default profile root. Default to
  # `~/.config` if neither is set. Add both an env-derived path and the hard-coded `~/.config`
  # path so guard catches the actual default even when env points elsewhere.
  local linux_chrome_root="${CHROME_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}"
  local roots=(
    "$HOME/Library/Application Support/Google/Chrome"          # macOS Chrome
    "$HOME/Library/Application Support/Google/Chrome Beta"
    "$HOME/Library/Application Support/Google/Chrome Canary"
    "$HOME/Library/Application Support/Chromium"
    "$HOME/Library/Application Support/Microsoft Edge"
    "$HOME/Library/Application Support/BraveSoftware/Brave-Browser"
    "$linux_chrome_root/google-chrome"                         # Linux Chrome (XDG-aware)
    "$linux_chrome_root/google-chrome-beta"
    "$linux_chrome_root/google-chrome-unstable"
    "$linux_chrome_root/chromium"
    "$linux_chrome_root/microsoft-edge"
    "$linux_chrome_root/BraveSoftware/Brave-Browser"
    "$HOME/.config/google-chrome"                              # Linux Chrome (hard-coded default fallback)
    "$HOME/.config/google-chrome-beta"
    "$HOME/.config/google-chrome-unstable"
    "$HOME/.config/chromium"
    "$HOME/.config/microsoft-edge"
    "$HOME/.config/BraveSoftware/Brave-Browser"
  )
  local r rcanon
  # nocasematch: macOS の case-insensitive FS で case 違いの実 profile 指定も弾く (Linux では
  # over-reject 方向 = 安全。throwaway は mktemp 名なので誤 reject はまず起きない)。
  shopt -s nocasematch
  for r in "${roots[@]}"; do
    rcanon=$(canonical_path "$r")
    case "$canon" in
      "$rcanon"|"$rcanon"/*)
        shopt -u nocasematch
        echo "error: CDP_PROFILE_DIR が実ブラウザ profile ($PROFILE_DIR -> $canon) を指しています。" >&2
        echo "       bridge は使い捨て profile 専用です (実 session 露出を防ぐため)。別 dir を指定してください。" >&2
        exit 1 ;;
    esac
  done
  shopt -u nocasematch
}

# port が起動前から CDP を喋っていたら、それは我々が起動する使い捨て Chrome ではなく別プロセスの
# 占有 (実 profile の Chrome かもしれない)。そのまま進むと wait_chrome_ready が既存ブラウザの応答で
# 成功扱いになり、sbx policy allow が既存ブラウザを box に晒す = throwaway 保証が崩れる。起動前に
# 占有を検出して中止する。
# その port が既に CDP を喋っているか (= 別プロセス占有)。
port_speaks_cdp() { curl -s --noproxy '*' --max-time 1 "http://localhost:$1/json/version" >/dev/null 2>&1; }

preflight_port_free() {
  if port_speaks_cdp "$PORT"; then
    echo "error: localhost:$PORT で既に別プロセスが CDP を listen しています。" >&2
    echo "       使い捨て Chrome を起動できず、既存ブラウザ (実 profile の可能性) を box に晒す危険があるため中止します。" >&2
    echo "       既存の Chrome を閉じるか、--port <別 port> を指定してください。" >&2
    exit 1
  fi
}

# 127.0.0.1:$1 に listener が無い (connect 拒否) なら free。CDP かどうかに依らず TCP 占有を見るので、
# CDP を喋らない別サービスが居る port を「空き」と誤判定して Chrome の bind 失敗で abort するのを防ぐ。
# /dev/tcp は bash 組込み。
port_free() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && return 1 || return 0; }

# port 確定: --port/CDP_PORT 明示時は占有なら abort。非明示時は既定から TCP が空いている port を自動
# scan して PORT を確定する。「自分が立てる使い捨て Chrome の port を空きから選ぶ」だけで、占有 port
# (実 profile の Chrome かもしれない) には一切 policy allow しないため security invariant は不変。
host_resolve_port() {
  if [ "$PORT_EXPLICIT" = "1" ]; then
    preflight_port_free   # CDP を喋る既存ブラウザは security 上 abort
    if ! port_free "$PORT"; then
      echo "error: localhost:$PORT は既に使用中です (非 CDP listener)。別の --port を指定してください。" >&2
      exit 1
    fi
    return
  fi
  local p="$PORT" max=$((PORT + 40))
  while [ "$p" -le "$max" ]; do
    if port_free "$p"; then PORT="$p"; return 0; fi
    p=$((p + 1))
  done
  echo "error: $PORT..$max に空き port が見つかりません。--port <port> を明示してください。" >&2
  exit 1
}

find_chrome() {
  local c
  for c \
    in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
       google-chrome google-chrome-stable chromium chromium-browser chrome; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return 0; }
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

wait_chrome_ready() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -s --noproxy '*' --max-time 1 "http://localhost:$PORT/json/version" >/dev/null 2>&1; then return 0; fi
    sleep 0.5
  done
  return 1
}

host_rollback() {
  # implicit は safety check で gate (改竄 pathfile 経由で無関係 Chrome を kill しない)。
  # rollback は up 直後の経路だが、preflight 後の race で stale pathfile を再認識した状態でも
  # 同じ保護を維持する。
  if command -v pkill >/dev/null 2>&1 && [ -n "$PROFILE_DIR" ]; then
    if [ -n "$PROFILE_DIR_EXPLICIT" ] || is_safe_throwaway_profile "$PROFILE_DIR"; then
      pkill -f -- "--user-data-dir=$PROFILE_DIR" 2>/dev/null || true
    fi
  fi
  local idf scopef; idf=$(policy_idfile); scopef=$(policy_scopefile)
  if [ -s "$idf" ]; then
    local id scope; id=$(cat "$idf"); scope=$([ -s "$scopef" ] && cat "$scopef" || echo "")
    # sbx v0.33+ 仕様: `sbx policy rm network --id <id>` (sandbox scope は `--sandbox` も必須)。
    # 旧形 `sbx policy rm "$id"` は unknown command で fail し rule が残るため、port 再利用時に
    # 実 profile Chrome が box から到達可能になる security 後退になる。
    local rm_rc=0
    if [ -n "$scope" ]; then
      sbx policy rm network --sandbox "$scope" --id "$id" >/dev/null 2>&1 || rm_rc=$?
    else
      sbx policy rm network --id "$id" >/dev/null 2>&1 || rm_rc=$?
    fi
    # 失敗時は idfile/scope を残す: 次回 down で retry できなくなると、port 再利用時に stale allow
    # 経由で box が他プロセスの CDP に到達できてしまうため。
    if [ "$rm_rc" -eq 0 ]; then
      rm -f "$idf" "$scopef" 2>/dev/null || true
    fi
  fi
  # implicit のみ auto 削除 + 改竄阻止 safety check (任意 host dir 削除を防ぐ)。
  if [ -z "$PROFILE_DIR_EXPLICIT" ] && [ -n "$PROFILE_DIR" ] && is_safe_throwaway_profile "$PROFILE_DIR"; then
    rm -rf "$PROFILE_DIR" 2>/dev/null || true
    rm -f "$(profile_pathfile)" 2>/dev/null || true
  fi
}

host_up() {
  # 旧 down が `sbx policy rm` 失敗で idfile/scope を残している場合、ここで新 up を許すと旧 rule
  # の handle が上書きされ、旧 scope (例: 別 CDP_BOX) の allow を retry 不能になり leak する。
  # 既存ハンドルがあれば down 完了を要求する。
  # auto-port では旧 bridge の port が今回の $PORT と異なりうるので、port 固定でなく cdp-policy-*.id を
  # 全 port 走査して未 revoke rule を検出する (port 解決前に default 9222 だけ見ると別 port の旧 rule を
  # 見落とし二重 bridge / leak になる)。
  local prev_idf
  prev_idf=$(ls "$HOST_STATE_DIR"/cdp-policy-*.id 2>/dev/null | head -1 || true)
  if [ -n "$prev_idf" ] && [ -s "$prev_idf" ]; then
    local prev_id prev_scopef prev_scope
    prev_id=$(cat "$prev_idf")
    prev_scopef="${prev_idf%.id}.scope"
    prev_scope=$([ -s "$prev_scopef" ] && cat "$prev_scopef" || echo "(global)")
    echo "error: 旧 up の egress rule ($prev_id, scope=$prev_scope) が未 revoke のまま残っています。" >&2
    echo "       new up は旧 handle を上書きし leak の原因になるため中止します。" >&2
    echo "       先に \`bash scripts/cdp-bridge.sh down\` で旧 rule を revoke するか、手動で sbx policy rm network --id $prev_id [--sandbox $prev_scope] を実行してから再 up してください。" >&2
    exit 1
  fi
  # port 確定は mktemp 前に。占有を先に検出/回避すれば throwaway dir の無駄打ちを避けられる。
  host_resolve_port
  resolve_profile_dir_up
  guard_profile
  command -v sbx >/dev/null 2>&1 || { echo "error: sbx が見つかりません (host で実行していますか?)" >&2; exit 1; }
  local chrome; chrome=$(find_chrome) || { echo "error: Chrome/Chromium が見つかりません。" >&2; exit 1; }
  mkdir -p "$PROFILE_DIR" "$HOST_STATE_DIR"

  # 見える Chrome を remote-debugging 付き・使い捨て profile で起動 (loopback のみ)。
  # --remote-allow-origins は relay の origin だけに絞る (`*` の broad bypass を避ける)。
  local allow_origins="http://localhost:$RELAY_PORT,http://127.0.0.1:$RELAY_PORT"
  "$chrome" --remote-debugging-port="$PORT" "--remote-allow-origins=$allow_origins" \
    --user-data-dir="$PROFILE_DIR" --no-first-run --no-default-browser-check \
    about:blank >/dev/null 2>&1 &
  echo "host Chrome 起動 (port=$PORT, profile=$PROFILE_DIR)。"

  if ! wait_chrome_ready; then
    echo "error: host Chrome が localhost:$PORT で応答しません。rollback します。" >&2
    host_rollback
    exit 1
  fi

  # box -> host:<port> の egress を許可 (default deny を開ける)。失敗なら rollback (best-effort をやめる)。
  # CDP_BOX が指定されればその box だけに scope する (a2a-review.sh と同じ --sandbox パターン)。
  # 未指定だと host 上の全 box が同じ relay を張って可視 Chrome を操作できてしまうため警告する。
  # `out=$(...) || rc=$?`: command substitution の失敗を `|| rc=$?` で捕捉して set -e の即 exit を
  # 防ぐ (素の `out=$(...); rc=$?` は assignment が失敗ステータスを取り set -e が rc 判定・rollback の
  # 前に script を落とす = Chrome/profile が orphan になる)。rc=0 を初期化し成功 path をカバー。
  local out rc=0
  if [ -n "${CDP_BOX:-}" ]; then
    out=$(sbx policy allow network --sandbox "$CDP_BOX" "localhost:$PORT" 2>&1) || rc=$?
  else
    echo "warn: CDP_BOX 未指定。host 上の全 box に localhost:$PORT egress を許可します (単一 box に絞るには CDP_BOX=<box名> を指定)。" >&2
    out=$(sbx policy allow network "localhost:$PORT" 2>&1) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    echo "$out" >&2
    echo "error: sbx policy allow に失敗しました。rollback します。" >&2
    host_rollback
    exit 1
  fi
  echo "$out"
  printf '%s\n' "$out" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1 > "$(policy_idfile)" 2>/dev/null || true
  # rule id 取得は必須: 取れないと down が revoke できず leak し、「idfile 不在 = revoke 済」前提で
  # pointer も誤削除される。空 idfile (grep 無 hit でも `>` で空ファイルが残る) を失敗扱いし rollback。
  if [ ! -s "$(policy_idfile)" ]; then
    echo "error: egress rule は許可されましたが出力から rule id を取得できませんでした (revoke 不能)。" >&2
    echo "       leak を避けるため rollback します。手動確認/削除: sbx policy ls (localhost:$PORT)。" >&2
    rm -f "$(policy_idfile)" 2>/dev/null || true
    host_rollback
    exit 1
  fi
  # scope を保存 (空文字 = global)。down が --sandbox を一致させて確実に revoke する。
  printf '%s' "${CDP_BOX:-}" > "$(policy_scopefile)" 2>/dev/null || true
  # 選んだ port / relay port を記録 (down/status が flag 無しで引けるように)。
  printf '%s\n' "$PORT" > "$(last_port_file)" 2>/dev/null || true
  printf '%s\n' "$RELAY_PORT" > "$(last_relay_file)" 2>/dev/null || true

  if [ -n "${CDP_BOX:-}" ] && [ "$NO_CONNECT" != "1" ]; then
    # host up 一発で box relay まで張る: sbx exec で box 内の box_up を起動する。
    # sbx exec の cwd は repo root なので relative path で叩ける (dev.sh の既存 pattern と同じ)。
    echo
    echo "box ($CDP_BOX) で relay を自動起動します (sbx exec)..."
    if sbx exec "$CDP_BOX" bash scripts/cdp-bridge.sh up --port "$PORT" --relay-port "$RELAY_PORT"; then
      # 次に起動する box セッション用に MCP server を box config へ登録 (best-effort)。
      # MCP は session 起動時しか load されないため、現行セッションは relay 直叩きで操作する。
      sbx exec "$CDP_BOX" claude mcp add-json chrome-devtools-host \
        "{\"command\":\"npx\",\"args\":[\"chrome-devtools-mcp@latest\",\"--browser-url\",\"http://localhost:$RELAY_PORT\"]}" \
        >/dev/null 2>&1 || true
      cat <<EOF

bridge 完了: host Chrome(:$PORT) <- relay(box localhost:$RELAY_PORT) <- box agent
  現行 box セッション: relay 直 (http://localhost:$RELAY_PORT の CDP) で操作可能
  次に起動する box セッション: chrome-devtools-host MCP が使える
終了時は host で: bash scripts/cdp-bridge.sh down
EOF
    else
      echo "warn: box relay の自動起動に失敗。box 内で手動起動してください:" >&2
      echo "  bash scripts/cdp-bridge.sh up --port $PORT --relay-port $RELAY_PORT" >&2
    fi
  else
    cat <<EOF

次は BOX の中で:
  bash scripts/cdp-bridge.sh up --port $PORT --relay-port $RELAY_PORT   # socat 中継 (localhost:$RELAY_PORT -> host:$PORT)
そして chrome-devtools MCP を --browser-url http://localhost:$RELAY_PORT で接続。
(--box <box名> を付ければ host up が box relay まで自動起動します)
終了時は host で: bash scripts/cdp-bridge.sh down
EOF
  fi
}

# box relay teardown 前に呼ぶ。sbx exec は停止 box を cold-start で起こす (sbx/README.md) ため、
# 「明確に停止 / 不在」と判定できた時だけ teardown を skip する。判定不能 (jq 不在 / sbx 失敗) は
# teardown を skip しない安全側 (= 起きているかも扱い) に倒す。running/unknown で 0、停止/不在で 1。
box_running_or_unknown() {
  command -v jq >/dev/null 2>&1 || return 0
  local json; json=$(sbx ls --json 2>/dev/null) || return 0
  printf '%s' "$json" | jq -e --arg b "$1" 'any(.sandboxes[]; .name==$b)' >/dev/null 2>&1 || return 1
  # 明確に "stopped" の時だけ skip (1)。transient/unknown status は maybe-running 扱いで teardown 継続 (0)。
  printf '%s' "$json" | jq -e --arg b "$1" 'any(.sandboxes[]; .name==$b and .status!="stopped")' >/dev/null 2>&1
}

host_down() {
  # --port/CDP_PORT 明示が無ければ up 時に記録した port を復元 (state file は PORT keyed のため必須)。
  if [ "$PORT_EXPLICIT" != "1" ] && [ -s "$(last_port_file)" ]; then PORT="$(cat "$(last_port_file)")"; fi
  command -v sbx >/dev/null 2>&1 || true
  resolve_profile_dir_down
  # box relay も畳む: 対象 box は --box、無ければ up 時 scope (policy_scopefile) から引く。
  local box_td="${CDP_BOX:-}"
  [ -z "$box_td" ] && [ -s "$(policy_scopefile)" ] && box_td="$(cat "$(policy_scopefile)")"
  if [ -n "$box_td" ]; then
    if ! box_running_or_unknown "$box_td"; then
      : # 停止 / 不在 box は live relay 無し + sbx exec が cold-start で起こすので teardown を skip。
    else
      # relay port は up 時保存値を渡す (非 default relay を default 9333 扱いで取り逃さないため)。
      local relay_arg=""
      [ -s "$(last_relay_file)" ] && relay_arg="--relay-port $(cat "$(last_relay_file)")"
      if sbx exec "$box_td" bash scripts/cdp-bridge.sh down $relay_arg >/dev/null 2>&1; then
        echo "box ($box_td) relay を停止しました。"
      else
        echo "warn: box relay の自動停止に失敗 (box 内で bash scripts/cdp-bridge.sh down を実行)。" >&2
      fi
    fi
  fi
  if [ -z "$PROFILE_DIR" ]; then
    echo "profile 情報が見つかりません (未起動 or 既に down 済み?)。"
  else
    # implicit は kill matcher を safety check で gate (box が pathfile を `.*` 等に改竄して
    # 無関係 Chrome を kill させる経路を塞ぐ)。explicit は user 所有契約により kill のみ実施。
    local can_touch=0
    if [ -n "$PROFILE_DIR_EXPLICIT" ]; then can_touch=1
    elif is_safe_throwaway_profile "$PROFILE_DIR"; then can_touch=1
    fi
    if [ "$can_touch" = "1" ]; then
      if command -v pkill >/dev/null 2>&1; then
        pkill -f -- "--user-data-dir=$PROFILE_DIR" 2>/dev/null || true
      fi
      echo "host Chrome (profile=$PROFILE_DIR) を停止しました。"
      if [ -z "$PROFILE_DIR_EXPLICIT" ]; then
        rm -rf "$PROFILE_DIR" 2>/dev/null || true
        rm -f "$(profile_pathfile)" 2>/dev/null || true
        echo "使い捨て profile dir を削除しました。"
      fi
    else
      echo "warn: pathfile が指す profile dir ($PROFILE_DIR) が throwaway 形式ではないため kill/削除を skip します。" >&2
      echo "      改竄の可能性。手動確認後に対象 Chrome を停止し pathfile ($(profile_pathfile)) を削除してください。" >&2
    fi
  fi
  # egress rule を片付ける (控えた id + scope があれば削除、無ければ手動案内)。
  local idf scopef; idf=$(policy_idfile); scopef=$(policy_scopefile)
  if [ -s "$idf" ]; then
    local id scope; id=$(cat "$idf"); scope=$([ -s "$scopef" ] && cat "$scopef" || echo "")
    # sbx v0.33+ 仕様: `sbx policy rm network --id <id>` (sandbox scope は `--sandbox` も必須)。
    local rm_rc=0
    if [ -n "$scope" ]; then
      sbx policy rm network --sandbox "$scope" --id "$id" >/dev/null 2>&1 || rm_rc=$?
    else
      sbx policy rm network --id "$id" >/dev/null 2>&1 || rm_rc=$?
    fi
    if [ "$rm_rc" -eq 0 ]; then
      echo "egress rule ($id$([ -n "$scope" ] && echo " on $scope")) を削除しました。"
      rm -f "$idf" "$scopef" 2>/dev/null || true
    else
      # revoke 失敗時は idfile/scope を残す: egress は開いたままなので、次回 down で再 revoke
      # できるようにする (消すと retry 不能 + 再 up で stale rule が累積する)。
      echo "egress rule の自動削除に失敗 (idfile を保持)。再試行: down を再実行、または手動で sbx policy ls から localhost:$PORT を削除。" >&2
    fi
  else
    echo "egress rule は残っている可能性があります。確認/削除: sbx policy ls (localhost:$PORT)。" >&2
  fi
  # last-* pointer は「今 cleanup した port が記録 port と一致し、その rule が revoke 済み」の時だけ消す。
  # mismatched down (--port 9222 だが実体は auto-port 9223 等) で別 bridge の pointer を誤削除しない
  # (policy rm 失敗で idfile を保持中も残す)。
  local saved_port=""; [ -s "$(last_port_file)" ] && saved_port="$(cat "$(last_port_file)")"
  if [ "$PORT" = "$saved_port" ] && [ ! -s "$(policy_idfile)" ]; then
    rm -f "$(last_port_file)" "$(last_relay_file)" 2>/dev/null || true
  fi
}

host_status() {
  if [ "$PORT_EXPLICIT" != "1" ] && [ -s "$(last_port_file)" ]; then PORT="$(cat "$(last_port_file)")"; fi
  resolve_profile_dir_down
  local chrome_ok=no
  command -v curl >/dev/null 2>&1 && \
    curl -s --noproxy '*' --max-time 3 "http://localhost:$PORT/json/version" >/dev/null 2>&1 && chrome_ok=yes
  echo "host Chrome CDP (localhost:$PORT): $chrome_ok"
  echo "profile: ${PROFILE_DIR:-(未確定 / 未起動)}"
}

# ---- box 側 -----------------------------------------------------------------

# sbx proxy を env から解決 (http_proxy=http://gateway.docker.internal:3128)。fallback も持つ。
proxy_hostport() {
  local p="${http_proxy:-${HTTP_PROXY:-}}"
  p="${p#http://}"; p="${p#https://}"; p="${p%/}"
  [ -n "$p" ] && echo "$p" || echo "gateway.docker.internal:3128"
}

box_up() {
  command -v socat >/dev/null 2>&1 || { echo "error: socat が box にありません。" >&2; exit 1; }
  mkdir -p "$TMPDIR_REPO"
  local ph proxy_h proxy_p pidf
  ph=$(proxy_hostport); proxy_h="${ph%:*}"; proxy_p="${ph##*:}"
  pidf=$(relay_pidfile)

  # 既存中継があれば停止 (冪等)。
  box_down >/dev/null 2>&1 || true

  # box localhost:<relay> -> proxy(CONNECT) -> host:<port>。
  # PROXY アドレスは sbx proxy 経由で host.docker.internal:<port> へ HTTP CONNECT トンネルする。
  setsid socat "TCP-LISTEN:$RELAY_PORT,fork,reuseaddr,bind=127.0.0.1" \
    "PROXY:$proxy_h:host.docker.internal:$PORT,proxyport=$proxy_p" \
    >"$(relay_logfile)" 2>&1 < /dev/null &
  local socat_pid=$!
  sleep 1

  # socat が即死していないことを確認してから pid を記録 (port 既使用で即 exit する経路で
  # dead PID を記録し、別 listener の応答で up 成功と誤判定する → down が dead PID を kill
  # する経路の防止)。
  if ! kill -0 "$socat_pid" 2>/dev/null; then
    echo "error: socat が起動直後に終了しました。localhost:$RELAY_PORT が既に他プロセスに bound されている可能性があります。" >&2
    echo "       log: $(relay_logfile)" >&2
    exit 1
  fi
  echo "$socat_pid" > "$pidf"

  if curl -s --noproxy '*' --max-time 4 "http://localhost:$RELAY_PORT/json/version" >/dev/null 2>&1; then
    echo "relay up: localhost:$RELAY_PORT -> (proxy $ph) -> host:$PORT  [host Chrome 応答 OK]"
  else
    echo "relay 起動。ただし host Chrome に未到達 (host 側 'up' と sbx policy allow localhost:$PORT を確認)。" >&2
    echo "       relay は起動済み (down で掃除可)。CDP が流れないので未完了として exit 1。" >&2
    exit 1
  fi
  cat <<EOF

chrome-devtools MCP をこの relay に向ける (opt-in、committed .mcp.json は変更しない):
  claude mcp add-json chrome-devtools-host '{"command":"npx","args":["chrome-devtools-mcp@latest","--browser-url","http://localhost:$RELAY_PORT"]}'
終了時は box で: bash scripts/cdp-bridge.sh down
EOF
}

box_down() {
  local pidf; pidf=$(relay_pidfile)
  if [ -s "$pidf" ]; then
    local pid; pid=$(cat "$pidf")
    # socat は fork で接続ごとに子を産み、setsid で pgid==pid の process group leader。
    # 親 PID だけ kill すると active な子トンネルが down 後も CDP を転送し続けるため、
    # process group ごと kill する (失敗時のみ親 PID 単体に fallback)。
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    rm -f "$pidf" 2>/dev/null || true
    echo "relay (localhost:$RELAY_PORT) を停止しました。"
  else
    echo "relay の pidfile がありません (未起動?)。"
  fi
}

box_status() {
  local relay_ok=no
  curl -s --noproxy '*' --max-time 4 "http://localhost:$RELAY_PORT/json/version" >/dev/null 2>&1 && relay_ok=yes
  echo "box relay (localhost:$RELAY_PORT -> host:$PORT): $relay_ok"
}

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/cdp-bridge.sh <up|down|status> [options]
  host 側で実行 (SANDBOX_VM_ID 無し):
    up      使い捨て profile の見える Chrome を remote-debugging 付きで起動 + box egress 許可。
            --box <名> 指定時は sbx exec で box relay まで自動起動する (一発接続)。
            --port 未指定なら既定 port が埋まっていても空き port を自動選択する。
    down    その Chrome 停止 + egress rule 削除 (+ --box/scope があれば box relay も停止)
    status  host Chrome CDP の応答確認
  box 側で実行 (SANDBOX_VM_ID 有り):
    up      socat 中継 (localhost:<relay> -> sbx proxy -> host:<port>) を起動
    down    中継停止
    status  中継 -> host Chrome の到達確認

options (env でも可): --port N (=CDP_PORT,9222) / --relay-port N (=CDP_RELAY_PORT,9333)
         --box NAME (=CDP_BOX; host up で relay 自動起動 + egress を絞る) / --profile-dir DIR (=CDP_PROFILE_DIR)
         --no-connect (host up で box relay 自動起動を抑止)
SECURITY: 実 Chrome profile は使わない。bridge した Chrome に実アカウントでログインしない。
詳細: docs/headful-bridge.md
USAGE
}

verb="${1:-help}"
if [ $# -gt 0 ]; then shift; fi
# 値を取る flag は次トークンの存在を検証する (末尾 --port 等で $2 不在のまま落ちるのを防ぐ)。
need_value() { [ $# -ge 2 ] && [ -n "$2" ] || { echo "error: $1 に値がありません" >&2; usage; exit 1; }; }
# flag 引数 (env より優先)。verb の後ろに置く: up --box <名> --port <N> ...
while [ $# -gt 0 ]; do
  case "$1" in
    --port)          need_value "$@"; PORT="$2"; PORT_EXPLICIT=1; shift 2 ;;
    --port=*)        PORT="${1#*=}"; PORT_EXPLICIT=1; shift ;;
    --relay-port)    need_value "$@"; RELAY_PORT="$2"; shift 2 ;;
    --relay-port=*)  RELAY_PORT="${1#*=}"; shift ;;
    --box)           need_value "$@"; CDP_BOX="$2"; shift 2 ;;
    --box=*)         CDP_BOX="${1#*=}"; shift ;;
    --profile-dir)   need_value "$@"; PROFILE_DIR_EXPLICIT="$2"; shift 2 ;;
    --profile-dir=*) PROFILE_DIR_EXPLICIT="${1#*=}"; shift ;;
    --no-connect)    NO_CONNECT=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

case "$verb" in
  up)     if in_box; then box_up;     else host_up;     fi ;;
  down)   if in_box; then box_down;   else host_down;   fi ;;
  status) if in_box; then box_status; else host_status; fi ;;
  help|-h|--help) usage ;;
  *) echo "unknown verb: $verb" >&2; usage; exit 1 ;;
esac
