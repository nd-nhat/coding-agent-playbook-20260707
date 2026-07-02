#!/usr/bin/env bash
# bind-mount box + cdx-<NAME> reviewer pair を auto-provision して起動する dev session 管理エントリ。
# 引数なし: 自動命名 (<basename>-<hex6>) で新規 start。引数 <NAME>: idempotent attach-or-create。
# subcommand: ls / attach [<NAME|N>] / kill <NAME|N> / sandbox [<NAME>] (throwaway clone 隔離) /
# shell <NAME> (claude を介さず box 内対話 shell に入る) /
# route <verb> [args] (Traefik で box の service を <name>.localhost で公開。name 既定 = web.<branch>.<repo>)。
#
# lifecycle 不変条件:
#  - atomic dev lock (.claude/tmp/cdx-dev-<NAME>.lock) で 1 NAME = 1 dev session、stale PID は自動 cleanup
#  - cdx-<NAME> reviewer pair (openai secret 登録時のみ) を pair-setup で auto-provision、bootstrap verify (server .venv) 付き
#  - pair-serve を子プロセスとして bg fork、出力は .claude/tmp/cdx-serve-<NAME>.log (TUI 干渉防止)
#  - claude box TTY 終了時に trap で pair-teardown + lock/log cleanup
#  - lifecycle 責務は scripts/internal/a2a-review.sh に集約 (本 script は call only、bash supervisor anti-pattern 回避)
set -euo pipefail

TEMPLATE="coding-agent-playbook-sbx"
KIT="./sbx/playbook-kit"
NAME_RE='^[A-Za-z0-9][A-Za-z0-9-]*$'
# App identity broker: 有効化は sbx marker secret (APP_IDENTITY_ENABLE) の presence で per-box / global に
# 切り分け、appId/keyPath は下記 config file (gitignore・per-machine) が供給する (owner/repo は broker が
# origin remote から自動導出)。marker 無し = 現行 global PAT (clone-and-go / fork 無改修)。有効化:
#   sbx secret set-custom <box> --host app-identity.invalid --env APP_IDENTITY_ENABLE --value 1
_APP_BROKER_CONFIG=".claude/app-broker.local.json"
_APP_IDENTITY_MARKER_ENV="APP_IDENTITY_ENABLE"

# marker (sbx custom secret、上記 env 名) が この box (per-box scope) か 全 box (global scope) に立って
# いるか。値は読まない (host は sbx secret の値を読めない) — presence だけ見る。
_app_identity_enabled() {
  local name="$1"
  sbx secret ls 2>/dev/null | awk -v box="$name" -v env="$_APP_IDENTITY_MARKER_ENV" '
    ($1 == "(global)" || $1 == box) {
      for (i = 1; i <= NF; i++) if ($i == env) found = 1
    }
    END { exit !found }
  '
}

# cd 前に caller worktree の branch を捕捉する (cd 後だと git-common-dir 経由で main checkout root の
# branch になり「呼び出し元の feature branch を web URL に埋めたい」用途 (route subcommand の default
# name = web.<branch>.<repo>) が壊れる)。route 以外の subcommand では未使用。
__DEV_CALLER_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)

cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

usage() {
  cat >&2 <<EOF
usage:
  bash scripts/dev.sh                       新規 bind-mount box を自動命名で start (workshop default)
  bash scripts/dev.sh <NAME>                明示名 <NAME> に idempotent attach-or-create
  bash scripts/dev.sh ls [-q]               dev box 一覧 (-q で name only、xargs friendly)
  bash scripts/dev.sh attach [<NAME|N>]     既存 dev box に attach (引数なしは picker)
  bash scripts/dev.sh kill <NAME|N>         dev box を停止 (cdx-<NAME> pair も同時破棄)
  bash scripts/dev.sh prune [--yes] [--all] orphan cdx / stale lease / stale lock を一括 cleanup
                                            (--all で dev box 本体も対象: CDX=none に加え pair 残存の leak も。引数なしは dry-run)
  bash scripts/dev.sh sandbox [<NAME>]      throwaway clone box を起動 (NAME 省略で sbx-<basename>-<hex6>、
                                            host checkout を mount しない private copy = parallel-safe)
  bash scripts/dev.sh observe [<NAME>]      AWS 可観測性調査用の read-only observe box を起動 (NAME 省略で
                                            obs-<basename>-<hex6>、clone copy。AWS の read-only cred / network 許可は
                                            host 側で注入する。手順: examples/observe/runbook.md、規約: rules/box-personas.md)
  bash scripts/dev.sh shell <NAME>          claude を介さず box 内の対話 shell に入る
                                            (\`sbx exec -it <NAME> bash\` の薄い wrapper)
  bash scripts/dev.sh route <verb> [args]   Traefik で box の service を <name>.localhost で公開
                                            (verb: up / add / rm / ls / down / detect、help は 'route help')
EOF
}

validate_name() {
  local n="$1"
  if ! [[ "$n" =~ $NAME_RE ]]; then
    echo "error: name '$n' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only)." >&2
    exit 1
  fi
  # 全数字の name は attach/kill の <NAME|N> 引数で row index と区別できないため reject (dev box `2` を作って `attach 2` すると ls 2 行目が解決されて誤 attach する)。
  if [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "error: name '$n' は全数字のため reject (attach/kill の row index と曖昧)。最低 1 文字は数字以外 (a-z / A-Z / -) を含めてください。" >&2
    exit 1
  fi
  case "$n" in
    cdx-*)
      echo "error: name 'cdx-*' は cdx-<NAME> reviewer box の予約 prefix です。別の name を選んでください。" >&2
      exit 1 ;;
    sbx-*)
      echo "error: name 'sbx-*' は sandbox auto-name の予約 prefix です (bash scripts/dev.sh sandbox が使用)。別の name を選んでください。" >&2
      exit 1 ;;
    obs-*)
      echo "error: name 'obs-*' は observe box の予約 prefix です (bash scripts/dev.sh observe が使用)。別の name を選んでください。" >&2
      exit 1 ;;
  esac
}

generate_name() {
  local base clean_base candidate existing
  base="$(basename "$PWD")"
  clean_base="${base//[^A-Za-z0-9-]/-}"
  clean_base="${clean_base#"${clean_base%%[!-]*}"}"
  clean_base="${clean_base%"${clean_base##*[!-]}"}"
  # 予約 prefix 衝突回避: basename が `cdx-` / `sbx-` (= 予約 prefix) で始まる or 完全一致なら fallback name `box` に置換する (1 回 strip 方式は `cdx-sbx-playbook` のような nested prefix で結局予約 prefix を残してしまう edge case があり、最終 candidate が validate_name / discovery を pass しなくなる)。fallback 化で 1 回判定の安全側に倒す trade-off は basename と generated NAME の関連消失だが、reserved 衝突する basename 自体が稀なので許容。
  case "$clean_base" in
    cdx|cdx-*|sbx|sbx-*|obs|obs-*) clean_base="box" ;;
  esac
  [ -z "$clean_base" ] && clean_base="box"
  # 24-bit hex を PID で XOR して per-process entropy を確保 (同時起動 2 本が同 RANDOM seed を引いても異なる NAME)
  existing="$(sbx ls -q 2>/dev/null || true)"
  candidate="${clean_base}-$(printf '%06x' $((((RANDOM * 32768 + RANDOM) ^ $$) & 0xffffff)))"
  while printf '%s\n' "$existing" | grep -Fxq -- "$candidate"; do
    candidate="${clean_base}-$(printf '%06x' $((((RANDOM * 32768 + RANDOM) ^ $$) & 0xffffff)))"
  done
  printf '%s' "$candidate"
}

# lease の start_time が現 pid のものと一致するかで PID 再利用を判定。1 = 再利用 (stale)、0 = 一致 or 判定不能 (alive 扱い)。
# start_time_kind が現 host の kind と一致する時だけ比較し、不一致 (PowerShell 製 lease 等の cross-language) は pid-only に倒す。
lease_pid_reused() {
  local pid=$1 lease_st=$2 lease_kind=$3 cur_kind cur_st
  [ -n "$lease_st" ] || return 1
  if [ -r "/proc/$pid/stat" ]; then cur_kind=proc; else cur_kind=lstart; fi
  [ "$lease_kind" = "$cur_kind" ] || return 1
  if [ "$cur_kind" = proc ]; then
    cur_st=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  else
    cur_st=$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ *//' || true)
  fi
  [ -n "$cur_st" ] || return 1
  [ "$cur_st" != "$lease_st" ]
}

# dev box discovery は sbx ls から予約 prefix (cdx-* reviewer pair / sbx-* sandbox) を除外して導出 (sbx label 機能依存と registry SSoT split-brain を避ける、命名規約で完全分離)。
# 重要: cdx pair の有無で dev box を識別しないこと — pair-setup 失敗 / openai 未登録の fail-open 経路で起動した unpaired dev box も ls/attach/kill で見えるべき (CDX 状態は cmd_ls で別 column として derive)。
list_dev_box_names() {
  local all
  all="$(sbx ls -q 2>/dev/null || true)"
  [ -z "$all" ] && return 0
  printf '%s\n' "$all" | grep -Ev '^(cdx-|sbx-|obs-)' || true
}

cmd_ls() {
  local quiet=0
  case "${1:-}" in
    -q|--quiet) quiet=1; shift ;;
    "") ;;
    *) echo "error: unknown arg '$1' for ls (only -q / --quiet supported)" >&2; exit 1 ;;
  esac
  if [ "$#" -gt 0 ]; then
    echo "error: unexpected extra arguments: $*" >&2
    echo "usage: bash scripts/dev.sh ls [-q]" >&2
    exit 1
  fi

  local all dev_names cdx_set name i lease pid lease_st lease_kind cdx_status
  all="$(sbx ls -q 2>/dev/null || true)"
  dev_names="$(printf '%s\n' "$all" | grep -Ev '^(cdx-|sbx-|obs-)' || true)"
  if [ -z "$dev_names" ]; then
    if [ "$quiet" = 0 ]; then
      echo "(no dev box. 'bash scripts/dev.sh' で新規起動)"
    fi
    return 0
  fi
  # -q: name only (Docker `docker ps -aq` 互換、xargs friendly)
  if [ "$quiet" = 1 ]; then
    printf '%s\n' "$dev_names"
    return 0
  fi
  cdx_set="$(printf '%s\n' "$all" | grep '^cdx-' | sed 's/^cdx-//' || true)"
  printf '%-3s  %-32s  %-8s\n' "#" "NAME" "CDX"
  i=0
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    i=$((i + 1))
    # CDX 列は dev box 存在から独立して derive (fail-open dev box = cdx pair 無しも表示できるようにする)。
    # 4 状態: none (cdx-<NAME> box 不在 = fail-open dev box) / orphan (cdx box 残存だが lease 無し) / ok (lease + pid alive) / stale (lease あるが pid dead or reused)
    cdx_status="none"
    if printf '%s\n' "$cdx_set" | grep -Fxq -- "$name"; then
      lease=".claude/tmp/cdx-serve-${name}.lease"
      if [ -f "$lease" ]; then
        # lease は a2a-review.sh の pair-serve が書く JSON 形式。"pid":N と "pid" : N の両形式に対応 (JSON 仕様は colon 周辺 whitespace を許容)。
        pid="$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$lease" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true)"
        lease_st="$(grep -oE '"start_time"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null | head -1 | sed -E 's/^"start_time"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)"
        lease_kind="$(grep -oE '"start_time_kind"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null | head -1 | sed -E 's/^"start_time_kind"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
          # PID alive: also verify start_time to detect PID reuse (kill -0 succeeds for recycled PIDs).
          if lease_pid_reused "$pid" "$lease_st" "$lease_kind"; then
            cdx_status="stale"
          else
            cdx_status="ok"
          fi
        else
          cdx_status="stale"
        fi
      else
        cdx_status="orphan"
      fi
    fi
    printf '%-3s  %-32s  %-8s\n' "$i" "$name" "$cdx_status"
  done <<<"$dev_names"
}

# macOS のシステム bash 3.2 には mapfile builtin が無いため while-read loop で読む (scripts/internal/box-session-context.sh 等と同パターン)。
resolve_target() {
  local arg="$1" names=() n
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    while IFS= read -r n; do
      [ -n "$n" ] && names+=("$n")
    done < <(list_dev_box_names)
    local idx=$((arg - 1))
    if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#names[@]}" ]; then
      echo "error: index $arg is out of range (use 'bash scripts/dev.sh ls' to list)." >&2
      exit 1
    fi
    printf '%s' "${names[$idx]}"
  else
    validate_name "$arg"
    printf '%s' "$arg"
  fi
}

cmd_attach() {
  local arg="${1:-}" names=() n
  if [ -z "$arg" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] && names+=("$n")
    done < <(list_dev_box_names)
    case "${#names[@]}" in
      0)
        echo "(no dev box. 自動命名で新規起動します)" >&2
        start_box ""
        return ;;
      1)
        attach_or_start "${names[0]}"
        return ;;
      *)
        cmd_ls
        local pick
        read -r -p "select # to attach: " pick
        if [ -z "$pick" ] || ! [[ "$pick" =~ ^[0-9]+$ ]]; then
          echo "error: numeric index required." >&2
          exit 1
        fi
        local resolved
        resolved="$(resolve_target "$pick")"
        attach_or_start "$resolved"
        return ;;
    esac
  fi
  local resolved
  resolved="$(resolve_target "$arg")"
  attach_or_start "$resolved"
}

# attach 経路で先に active lock holder を検出し、別 session への重複 attach を明示エラーで止める (start_box の lock 取得 fail より早く、dev.sh shell 案内付きで返す)。stale lock や未起動状態は通常の start_box 経路に委ねる。
attach_or_start() {
  local name="$1"
  local lock_file=".claude/tmp/cdx-dev-${name}.lock"
  if [ -f "$lock_file" ]; then
    local lock_pid
    lock_pid=$(cat "$lock_file" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "error: dev box '$name' は別 session が active で attach 済みです (pid=$lock_pid)。" >&2
      echo "       claude TUI への multi-client attach は描画競合のため未対応。観察 shell が必要なら:" >&2
      echo "         bash scripts/dev.sh shell $name" >&2
      exit 1
    fi
  fi
  start_box "$name"
}

cmd_kill() {
  local arg="${1:-}" name lease lock lock_pid
  if [ -z "$arg" ]; then
    echo "usage: bash scripts/dev.sh kill <NAME|N>" >&2
    exit 1
  fi
  name="$(resolve_target "$arg")"
  echo "stopping dev box '$name' (and cdx-$name reviewer pair if present)..." >&2
  # 順序: sbx rm を先 → 成功時のみ pair-teardown。逆順だと sbx rm fail 時に reviewer pair が既に teardown 済で「lease/lock 残す」message と実態 (reviewer 復活不能) が乖離する。dev box が無事消えた後の pair-teardown は idempotent (cdx-<NAME> sbx rm + lease + policy 全部)。
  if ! sbx rm -f "$name" >/dev/null 2>&1; then
    echo "error: failed to stop dev box '$name' (sbx rm -f returned non-zero)." >&2
    echo "       reviewer pair / lease / lock 全て残します。手動で 'sbx rm -f $name' を再試行してください。" >&2
    exit 1
  fi
  # R7 で a2a-review.sh の pair-teardown が「policy revoke / cdx rm 失敗時に lease を残して非 0 exit」semantics になったため、cmd_kill 側も exit code を見て lease 保護を honor する。失敗時に lease を unconditional rm すると port anchor が消えて prune も retry できなくなる (R8 W/X)。R9 AA/BB: lease 不在ケース (orphan で元から lease 無し) の teardown failure も明示報告 + 最終 exit 1 (success と誤報告しない)。
  local teardown_failed=0
  bash scripts/internal/a2a-review.sh pair-teardown "$name" >/dev/null 2>&1 || teardown_failed=1
  lease=".claude/tmp/cdx-serve-${name}.lease"
  if [ "$teardown_failed" = 0 ]; then
    rm -f "$lease" 2>/dev/null || true
  elif [ -f "$lease" ]; then
    echo "warning: pair-teardown failed for '$name' — lease preserved at $lease for retry. Cleanup: bash scripts/dev.sh prune --yes (later) or check 'sbx policy ls' / 'sbx ls' manually." >&2
  else
    echo "warning: pair-teardown failed for '$name' (no lease to preserve; cdx-$name may still exist). Cleanup: bash scripts/dev.sh prune --yes or 'sbx rm -f cdx-$name' manually." >&2
  fi
  # lock 削除は owner PID dead 確認後に限る: sbx rm -f は owning dev.sh process を非同期に unwind させるだけで即時 exit を待たない。即削除すると、kill 直後の同名 dev.sh 起動が新 lock を取り cdx pair を再 provision した後で、旧 owner の EXIT trap が走って新 session の reviewer pair と lock を一緒に teardown する race が起きる。owner alive の場合は本人の trap に任せて削除しない。
  lock=".claude/tmp/cdx-dev-${name}.lock"
  if [ -f "$lock" ]; then
    lock_pid=$(cat "$lock" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "info: dev lock を owner pid=$lock_pid に残します (owner の EXIT trap が削除します)。" >&2
    else
      rm -f "$lock" 2>/dev/null || true
    fi
  fi
  if [ "$teardown_failed" = 1 ]; then
    echo "done (with warnings — pair-teardown failed; see above)." >&2
    exit 1
  fi
  echo "done." >&2
}

# cleanup 対象: orphan cdx-<NAME> reviewer pair (dev box が消えたが reviewer が残った) / stale lease (.claude/tmp/cdx-serve-*.lease で pid dead) / stale lock (.claude/tmp/cdx-dev-*.lock で pid dead)。
# --all では更に dev box 本体も対象にする: unpaired dev box (CDX=none・active lock 無し・not running) と leaked paired dev box (cdx pair 残存だが dev session 死亡・not running = dev.sh 異常終了で box+pair が orphan 生存した CDX=ok/stale/orphan leak)。
# default は dry-run (削除候補のみ表示)、`--yes` で実行。手動 `sbx rm -f cdx-<NAME>` + `rm .claude/tmp/cdx-*` の組み合わせを 1 verb に集約する。
# orphan cdx / stale lease の削除は scripts/internal/a2a-review.sh pair-teardown 経由で行い、lease に記録された host port から sbx policy allow rule の revoke もまとめて行う (lease 単独削除では stale policy が残る)。
cmd_prune() {
  local yes=0 all_flag=0
  # arg parse: --yes / --all の任意順序、組み合わせ可。destructive command なので未知 flag は明示 reject (`prune --yes foo` のような誤入力で全 candidate を destructive 実行するのを防ぐ)。
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1; shift ;;
      --all|-a) all_flag=1; shift ;;
      *) echo "error: unexpected argument: $1" >&2; echo "usage: bash scripts/dev.sh prune [--yes] [--all]" >&2; exit 1 ;;
    esac
  done

  local sbx_all cdx_names dev_names cdx orphan_cdx=() lease lock pid stale_leases=() stale_lease_names=() stale_locks=() lock_pid cdx_lock
  sbx_all="$(sbx ls -q 2>/dev/null || true)"
  cdx_names="$(printf '%s\n' "$sbx_all" | grep '^cdx-' | sed 's/^cdx-//' || true)"
  dev_names="$(printf '%s\n' "$sbx_all" | grep -Ev '^(cdx-|sbx-|obs-)' || true)"

  # possibly-active な dev box の name 集合 (--all 時のみ取得、lockless active session / cold-start transient の誤削除防止)。sbx ls --json の status を SSoT として parse する (side-effect 無し / format-stable)。
  # 「明確に stopped」のものだけ削除安全とみなし、それ以外 (running / starting / stopping / unknown 等の transient) は maybe-running 扱いで protect する。これは scripts/cdp-bridge.sh の box_running_or_unknown と同じ convention で、status=="running" だけ見ると transient 中の box を誤削除しうるため (sbx/README.md「コールド起動の transient」)。変数名は running_names だが意味は「stopped でない = possibly-active」。
  # 注意: `sbx exec` での probe は不可 (sbx は stopped box を exec で auto-start するため prune 対象を起こす)。stale lease 委譲判定 (下) でも参照するため stale lease scan より前に取得する。
  # fail-closed: jq 不在 / sbx ls --json 失敗 / jq parse fail のいずれかで --all を refuse + exit (degrade して filter なしで進めると active な box を誤削除しうるため、安全側に倒す)。
  local running_names=""
  if [ "$all_flag" = 1 ]; then
    if ! command -v jq >/dev/null 2>&1; then
      echo "error: --all requires jq (used to parse 'sbx ls --json' for the running-state safety check). Install jq, or run 'bash scripts/dev.sh prune' (without --all) which does not need it." >&2
      exit 1
    fi
    local sbx_json_all
    if ! sbx_json_all="$(sbx ls --json 2>/dev/null)" || [ -z "$sbx_json_all" ]; then
      echo "error: --all requires 'sbx ls --json' to succeed for the running-state safety check; sbx invocation failed or returned empty. Aborting to avoid unsafe delete." >&2
      exit 1
    fi
    if ! running_names="$(printf '%s' "$sbx_json_all" | jq -r '.sandboxes[] | select(.status != "stopped") | .name' 2>/dev/null)"; then
      echo "error: --all requires 'sbx ls --json' output to be parseable; jq parse failed. Aborting to avoid unsafe delete." >&2
      exit 1
    fi
    running_names="$(printf '%s\n' "$running_names" | grep -Ev '^(cdx-|sbx-|obs-)' || true)"
  fi

  # orphan cdx pair: cdx-<X> はあるが、対応する dev box <X> は無い、かつ active dev lock も持っていない。
  # active lock check: dev.sh の startup window (lock 取得後 → pair-setup 完了 → sbx run 直前) で cdx-<X> は存在するが dev box <X> はまだ作られていない状態がある。その時の prune 実行が cdx を「orphan」として削除すると、active な dev.sh が起動失敗する。lock holder PID が alive なら in-flight 起動として skip。
  if [ -n "$cdx_names" ]; then
    while IFS= read -r cdx; do
      [ -z "$cdx" ] && continue
      if printf '%s\n' "$dev_names" | grep -Fxq -- "$cdx"; then continue; fi
      cdx_lock=".claude/tmp/cdx-dev-${cdx}.lock"
      if [ -f "$cdx_lock" ]; then
        lock_pid=$(cat "$cdx_lock" 2>/dev/null || true)
        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
          continue
        fi
      fi
      orphan_cdx+=("cdx-$cdx")
    done <<<"$cdx_names"
  fi

  # stale lease: pid が dead / 取得不能、または PID 再利用 (kill -0 は再利用 PID を alive と誤判定するため start_time で同一性を確認)。
  # lease 名から NAME を抽出して pair-teardown 経由で削除する (policy revoke 付き)。
  # active dev lock check: dev.sh <NAME> が起動中で旧 stale lease が残っている場合、新しい lock 取得は pair-serve の lease rewrite より早く起きる (lock → pair-setup → pair-serve fork → lease rewrite の順)。その window で prune が古い lease の dead pid を見て stale 判定 + pair-teardown を呼ぶと、in-flight な cdx-<NAME> が削除されてしまう。orphan cdx と同じく active lock 持ちは skip する。
  local lease_lock lock_pid_lease lease_st lease_kind _is_stale
  for lease in .claude/tmp/cdx-serve-*.lease; do
    [ -f "$lease" ] || continue
    pid="$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$lease" 2>/dev/null | head -1 | grep -oE '[0-9]+$' || true)"
    lease_st="$(grep -oE '"start_time"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null | head -1 | sed -E 's/^"start_time"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)"
    lease_kind="$(grep -oE '"start_time_kind"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null | head -1 | sed -E 's/^"start_time_kind"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)"
    _is_stale=0
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      _is_stale=1
    elif lease_pid_reused "$pid" "$lease_st" "$lease_kind"; then
      _is_stale=1
    fi
    if [ "$_is_stale" = 1 ]; then
      local lease_name="${lease#.claude/tmp/cdx-serve-}"
      lease_name="${lease_name%.lease}"
      lease_lock=".claude/tmp/cdx-dev-${lease_name}.lock"
      if [ -f "$lease_lock" ]; then
        lock_pid_lease=$(cat "$lease_lock" 2>/dev/null || true)
        if [ -n "$lock_pid_lease" ] && kill -0 "$lock_pid_lease" 2>/dev/null; then
          continue
        fi
      fi
      # --all モードで「dev box 本体 + cdx pair が両方残存」かつ「box が stopped (possibly-active でない)」な stale lease (CDX=stale leak) のみ leaked_paired_dev 経路に委ねる
      # (そちらが dev box 本体ごと sbx rm + pair-teardown する)。ここで pair だけ teardown すると dev box 本体が残って leak が閉じない。
      # 委譲しないケースは stale_leases に残して従来どおり pair-teardown で lease/policy を revoke する (委譲しっぱなしだと cleanup が漏れる):
      #   (a) cdx pair が既に消えて dev box だけ残存 → leaked_paired_dev (cdx pair 前提) が拾えない
      #   (b) box が possibly-active (running/transient) → leaked_paired_dev が running protect で skip する
      # 非 --all では running_names は空なので従来どおり全 stale lease を reviewer 残骸として掃除。
      if [ "$all_flag" = 1 ] \
        && printf '%s\n' "$dev_names" | grep -Fxq -- "$lease_name" \
        && printf '%s\n' "$cdx_names" | grep -Fxq -- "$lease_name" \
        && ! printf '%s\n' "$running_names" | grep -Fxq -- "$lease_name"; then
        continue
      fi
      stale_leases+=("$lease")
      stale_lease_names+=("$lease_name")
    fi
  done

  # stale lock: pid が dead / 取得不能 (lock は dev.sh が書く plain text、行頭 PID)
  for lock in .claude/tmp/cdx-dev-*.lock; do
    [ -f "$lock" ] || continue
    pid=$(cat "$lock" 2>/dev/null || true)
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      stale_locks+=("$lock")
    fi
  done

  # unpaired dev box (--all 時のみ): cdx pair も持たず active dev lock も無く running でもない「停止中の dev box 本体」を candidate に追加 (Docker `image prune --all` 類比の拡張対象、CDX=none の蓄積を一掃するための明示 opt-in)。orphan cdx pair / stale lease 経路と重複しないよう「cdx-<X> 不在 = CDX=none」のみを対象にする。
  local unpaired_dev=() leaked_paired_dev=() running_skipped=() dev cdx_lock_dev lock_pid_dev
  if [ "$all_flag" = 1 ] && [ -n "$dev_names" ]; then
    while IFS= read -r dev; do
      [ -z "$dev" ] && continue
      # CDX=ok / orphan / stale (= cdx pair 存在) は leaked_paired_dev 経路で扱う / 重複削除回避
      if printf '%s\n' "$cdx_names" | grep -Fxq -- "$dev"; then continue; fi
      # active dev lock check (in-flight 起動中の box は --all でも触らない)
      cdx_lock_dev=".claude/tmp/cdx-dev-${dev}.lock"
      if [ -f "$cdx_lock_dev" ]; then
        lock_pid_dev=$(cat "$cdx_lock_dev" 2>/dev/null || true)
        if [ -n "$lock_pid_dev" ] && kill -0 "$lock_pid_dev" 2>/dev/null; then
          continue
        fi
      fi
      # running check (sbx ls --json 経由): dev.sh shell attached / 直接 sbx exec attached 等で lock 不在でも box が active なケースを保護
      if [ -n "$running_names" ] && printf '%s\n' "$running_names" | grep -Fxq -- "$dev"; then
        running_skipped+=("$dev")
        continue
      fi
      unpaired_dev+=("$dev")
    done <<<"$dev_names"
  fi

  # leaked paired dev box (--all のみ): cdx pair を持つ (CDX=ok/stale/orphan) が dev session は死亡 (lock dead/不在) かつ running でもない dev box 本体。
  # 通常 prune の orphan_cdx / stale_lease は「dev box が既に消えた後の reviewer 残骸」しか拾えず、dev box 本体が生き残ったまま pair-serve だけ orphan 生存している (CDX=ok) leak はどの経路にも掛からなかった (dev session 異常終了で dev.sh の EXIT trap teardown が走らなかったケース)。ここで dev box 本体を拾い、削除時に pair も teardown する (cmd_kill と同等)。protect 軸は unpaired_dev と対称 (lock alive / running なら skip)。
  local leaked_lock_dev leaked_lock_pid
  if [ "$all_flag" = 1 ] && [ -n "$dev_names" ]; then
    while IFS= read -r dev; do
      [ -z "$dev" ] && continue
      # cdx pair を持つ dev box だけ対象 (CDX=none は unpaired_dev が担当)
      if ! printf '%s\n' "$cdx_names" | grep -Fxq -- "$dev"; then continue; fi
      # active dev lock check (使用中 / in-flight 起動中の box は触らない)
      leaked_lock_dev=".claude/tmp/cdx-dev-${dev}.lock"
      if [ -f "$leaked_lock_dev" ]; then
        leaked_lock_pid=$(cat "$leaked_lock_dev" 2>/dev/null || true)
        if [ -n "$leaked_lock_pid" ] && kill -0 "$leaked_lock_pid" 2>/dev/null; then
          continue
        fi
      fi
      # running check (lockless attached session 保護)
      if [ -n "$running_names" ] && printf '%s\n' "$running_names" | grep -Fxq -- "$dev"; then
        running_skipped+=("$dev")
        continue
      fi
      leaked_paired_dev+=("$dev")
    done <<<"$dev_names"
  fi

  local total=$((${#orphan_cdx[@]} + ${#stale_leases[@]} + ${#stale_locks[@]} + ${#unpaired_dev[@]} + ${#leaked_paired_dev[@]}))
  if [ "$total" -eq 0 ]; then
    # 全 CDX=none box が running で除外された場合、ユーザーに「保護した box が何件あるか」を表示しないと「prune 対象 0 件」と「すべて running で skip した」の判別が付かない。
    if [ "${#running_skipped[@]}" -gt 0 ]; then
      echo "(nothing to prune; ${#running_skipped[@]} running box(es) protected, see below)"
      echo
      echo "skipped (possibly-active, --all mode):"
      local item
      for item in "${running_skipped[@]}"; do echo "  $item  (sbx ls reports status != stopped — running or transient/attached via dev.sh shell / sbx exec; use 'bash scripts/dev.sh kill $item' to delete explicitly)"; done
    else
      echo "(nothing to prune)"
    fi
    return 0
  fi

  echo "prune candidates ($total):"
  local item
  for item in "${orphan_cdx[@]}"; do echo "  $item  (orphan cdx pair: dev box not found, no active dev lock)"; done
  for item in "${stale_leases[@]}"; do echo "  $item  (stale lease: pid dead — pair-teardown will revoke sbx policy + cleanup)"; done
  for item in "${stale_locks[@]}"; do echo "  $item  (stale lock: pid dead)"; done
  for item in "${unpaired_dev[@]}"; do echo "  $item  (unpaired dev box: CDX=none, no active dev lock — --all mode)"; done
  for item in "${leaked_paired_dev[@]}"; do echo "  $item  (leaked paired dev box: dev session dead but cdx pair still present — --all mode)"; done

  if [ "${#running_skipped[@]}" -gt 0 ]; then
    echo
    echo "skipped (possibly-active, --all mode):"
    for item in "${running_skipped[@]}"; do echo "  $item  (sbx ls reports status != stopped — running or transient/attached via dev.sh shell / sbx exec; use 'bash scripts/dev.sh kill $item' to delete explicitly)"; done
  fi

  if [ "$yes" = 0 ]; then
    echo
    if [ "$all_flag" = 1 ]; then
      echo "dry-run mode (--all). To actually prune, run: bash scripts/dev.sh prune --yes --all"
    else
      echo "dry-run mode. To actually prune, run: bash scripts/dev.sh prune --yes"
    fi
    return 0
  fi

  echo
  echo "pruning..."
  local failed=0 i name lease_path revalidate_pid cdx_name lock_path sbx_ls_output sbx_ls_ok
  # delete 直前の lock 再 check helper (scan 後に dev.sh が起動した TOCTOU window を実用上ゼロまで縮める)
  is_dev_lock_alive() {
    local n="$1" lock_pid_check
    local lock_path_check=".claude/tmp/cdx-dev-${n}.lock"
    [ -f "$lock_path_check" ] || return 1
    lock_pid_check=$(cat "$lock_path_check" 2>/dev/null || true)
    [ -n "$lock_pid_check" ] && kill -0 "$lock_pid_check" 2>/dev/null
  }
  # delete 直前の possibly-active 再 snapshot helper (scan → delete window で dev.sh shell / 直接 sbx exec attached により box が起き上がった race を防ぐ、scan 時の running_names と並列の TOCTOU mitigation)。失敗は fail-closed で呼び出し側が exit する規範。
  # scan 時の running_names と同じく status != "stopped" を possibly-active 扱いにする (transient/unknown を destructive delete から守る、cdp-bridge.sh convention)。
  capture_running_set() {
    local _json _names
    if ! _json="$(sbx ls --json 2>/dev/null)" || [ -z "$_json" ]; then
      return 1
    fi
    if ! _names="$(printf '%s' "$_json" | jq -r '.sandboxes[] | select(.status != "stopped") | .name' 2>/dev/null)"; then
      return 1
    fi
    printf '%s\n' "$_names" | grep -Ev '^(cdx-|sbx-|obs-)' || true
  }
  # sbx ls の exit code を立てて取得する helper (`sbx ls -q 2>/dev/null` の失敗を空出力 degrade で「box 不在」と誤判定するのを防ぐ)。sbx_ls_output と sbx_ls_ok を set。
  capture_sbx_ls() {
    if sbx_ls_output=$(sbx ls -q 2>/dev/null); then
      sbx_ls_ok=1
    else
      sbx_ls_ok=0
      sbx_ls_output=""
    fi
  }
  # orphan cdx pair: 直前 lock 再 check → pair-teardown (a2a-review.sh の R7 修正後 semantics: 成功 = lease + cdx + policy 全部 OK / 失敗 = lease 保持 + 何か残ってる)。失敗時のみ fallback sbx rm を試行。
  for item in "${orphan_cdx[@]}"; do
    cdx_name="${item#cdx-}"
    if is_dev_lock_alive "$cdx_name"; then
      echo "  skipped $item (active dev lock acquired since scan)"
      continue
    fi
    if bash scripts/internal/a2a-review.sh pair-teardown "$cdx_name" >/dev/null 2>&1; then
      echo "  removed $item (via pair-teardown)"
      continue
    fi
    # pair-teardown 失敗: sbx ls で実態 verify、cdx 残存なら fallback sbx rm を試行
    capture_sbx_ls
    if [ "$sbx_ls_ok" = 0 ]; then
      echo "  warning: pair-teardown failed for $item and sbx ls verify also failed (retry: bash scripts/dev.sh prune --yes)" >&2
      failed=$((failed + 1))
      continue
    fi
    if ! printf '%s\n' "$sbx_ls_output" | grep -Fxq -- "$item"; then
      # cdx は消えてる → policy revoke 失敗で pair-teardown が非 0 終了した可能性
      echo "  warning: $item removed but sbx policy revoke may have failed (check 'sbx policy ls' for stale localhost:* rules)" >&2
      failed=$((failed + 1))
    # R10 GG/HH: fallback sbx rm の直前にも live lock recheck (scan→fallback の startup window で別 session が cdx-<NAME> を bootstrap verify + recycle する race を防ぐ)
    elif is_dev_lock_alive "$cdx_name"; then
      echo "  skipped fallback sbx rm for $item (active dev lock acquired since scan)"
      continue
    elif sbx rm -f "$item" >/dev/null 2>&1; then
      capture_sbx_ls
      if [ "$sbx_ls_ok" = 1 ] && ! printf '%s\n' "$sbx_ls_output" | grep -Fxq -- "$item"; then
        # R9 EE/FF: pair-teardown が preserved した lease をここで掃除する。orphan_cdx scan 時に lease pid が alive だった (= 初期 scan で stale_leases に入らなかった) ケースで、pair-teardown 後に lease が残っているなら再度 pair-teardown を呼んで policy revoke + lease 削除を試みる (cdx は既に消えてるので idempotent)。
        # R10 GG/HH: retry teardown の直前にも live lock recheck (fallback rm と retry teardown の間でさらに startup window がある race を防ぐ)
        local fb_lease=".claude/tmp/cdx-serve-${cdx_name}.lease"
        if [ -f "$fb_lease" ]; then
          if is_dev_lock_alive "$cdx_name"; then
            echo "  removed $item but retry pair-teardown skipped (active dev lock acquired; lease preserved for new session's teardown to handle)" >&2
          elif bash scripts/internal/a2a-review.sh pair-teardown "$cdx_name" >/dev/null 2>&1; then
            echo "  removed $item (fallback sbx rm + retry pair-teardown for lease/policy cleanup)" >&2
          else
            echo "  warning: $item removed but $fb_lease + sbx policy may remain (check 'sbx policy ls')" >&2
            failed=$((failed + 1))
          fi
        else
          echo "  removed $item (fallback sbx rm after pair-teardown reported failure)" >&2
        fi
      else
        echo "  warning: failed to remove $item (still present after pair-teardown + fallback sbx rm)" >&2
        failed=$((failed + 1))
      fi
    else
      echo "  warning: failed to remove $item (sbx rm fallback returned non-zero)" >&2
      failed=$((failed + 1))
    fi
  done
  # stale lease: 直前 lock 再 check → pair-teardown (R7 修正後: 成功 = lease + cdx + policy 全部 OK / 失敗 = lease 保持 で port 情報を保護)。失敗時は lease が残っているはずなので「次回 retry できる」状態として failed カウント + 案内。
  for i in "${!stale_lease_names[@]}"; do
    name="${stale_lease_names[$i]}"
    lease_path="${stale_leases[$i]}"
    if is_dev_lock_alive "$name"; then
      echo "  skipped $lease_path (active dev lock acquired since scan)"
      continue
    fi
    if bash scripts/internal/a2a-review.sh pair-teardown "$name" >/dev/null 2>&1; then
      echo "  removed $lease_path (via pair-teardown, cdx-$name and policy revoked)"
      continue
    fi
    # pair-teardown 失敗: lease は a2a-review.sh の R7 semantics で残されているはず (port 情報保護)。
    if [ -f "$lease_path" ]; then
      echo "  warning: $lease_path NOT removed — pair-teardown failed (sbx policy revoke or cdx rm transient failure; lease preserved for retry). Retry: bash scripts/dev.sh prune --yes (later) or check 'sbx policy ls' / 'sbx ls' 手動." >&2
      failed=$((failed + 1))
    else
      # 想定外: pair-teardown 失敗なのに lease 削除済 = a2a-review.sh の semantics と乖離 / 並行 prune による race
      echo "  warning: $lease_path was removed despite pair-teardown failure (unexpected — possibly concurrent prune). Check 'sbx ls' / 'sbx policy ls' for leftover state." >&2
      failed=$((failed + 1))
    fi
  done
  # stale lock: delete 直前に再 read + pid 再 check (scan 後に dev.sh が同名 lock を re-acquire した window を防ぐ)
  for lock_path in "${stale_locks[@]}"; do
    if [ -f "$lock_path" ]; then
      revalidate_pid=$(cat "$lock_path" 2>/dev/null || true)
      if [ -n "$revalidate_pid" ] && kill -0 "$revalidate_pid" 2>/dev/null; then
        echo "  skipped $lock_path (re-acquired by alive pid=$revalidate_pid since scan)"
        continue
      fi
    fi
    rm -f "$lock_path" 2>/dev/null && echo "  removed $lock_path" || { echo "  warning: failed to remove $lock_path" >&2; failed=$((failed + 1)); }
  done
  # unpaired dev box (--all 時のみ): cdx pair も lease も持たない box 本体を sbx rm で削除。各 iter で直前 lock 再 check + 直前 running 再 snapshot (per-item) — loop 直前 1 回 snapshot だと「snapshot 取得 → 最後の sbx rm」までの window で dev.sh shell / sbx exec attach され box が running 化すると残りの iter で誤削除しうる。per-item snapshot で window を「single iter snapshot → sbx rm」まで縮小する (既存 is_dev_lock_alive の per-item pattern と対称)。pair-teardown 不要 (cdx-<NAME> 不在前提)。
  local item_running
  for item in "${unpaired_dev[@]}"; do
    if is_dev_lock_alive "$item"; then
      echo "  skipped $item (active dev lock acquired since scan)"
      continue
    fi
    if ! item_running="$(capture_running_set)"; then
      echo "  warning: skipped $item — failed to re-snapshot running state via 'sbx ls --json' before delete (transient sbx error; retry: bash scripts/dev.sh prune --yes --all)" >&2
      failed=$((failed + 1))
      continue
    fi
    if [ -n "$item_running" ] && printf '%s\n' "$item_running" | grep -Fxq -- "$item"; then
      echo "  skipped $item (status != stopped since last snapshot; not deleted — likely dev.sh shell / sbx exec attached or transient, use 'bash scripts/dev.sh kill $item' to delete explicitly)"
      continue
    fi
    if sbx rm -f "$item" >/dev/null 2>&1; then
      echo "  removed $item (unpaired dev box, --all)"
    else
      echo "  warning: failed to remove $item (sbx rm returned non-zero)" >&2
      failed=$((failed + 1))
    fi
  done
  # leaked paired dev box (--all のみ): dev box 本体を sbx rm → 成功時のみ pair-teardown (cmd_kill と同順。逆順だと sbx rm fail 時に reviewer pair が既に teardown 済で実態と乖離する)。pair-teardown が lease + cdx + policy を idempotent に掃除する。各 iter で直前 lock 再 check + running 再 snapshot (unpaired_dev と対称の TOCTOU mitigation)。
  for item in "${leaked_paired_dev[@]}"; do
    if is_dev_lock_alive "$item"; then
      echo "  skipped $item (active dev lock acquired since scan)"
      continue
    fi
    if ! item_running="$(capture_running_set)"; then
      echo "  warning: skipped $item — failed to re-snapshot running state via 'sbx ls --json' before delete (transient sbx error; retry: bash scripts/dev.sh prune --yes --all)" >&2
      failed=$((failed + 1))
      continue
    fi
    if [ -n "$item_running" ] && printf '%s\n' "$item_running" | grep -Fxq -- "$item"; then
      echo "  skipped $item (status != stopped since last snapshot; not deleted — likely dev.sh shell / sbx exec attached or transient, use 'bash scripts/dev.sh kill $item' to delete explicitly)"
      continue
    fi
    if ! sbx rm -f "$item" >/dev/null 2>&1; then
      echo "  warning: failed to remove $item (sbx rm returned non-zero; cdx-$item pair left intact for retry)" >&2
      failed=$((failed + 1))
      continue
    fi
    if bash scripts/internal/a2a-review.sh pair-teardown "$item" >/dev/null 2>&1; then
      echo "  removed $item (leaked paired dev box + cdx-$item pair, --all)"
    else
      echo "  warning: removed $item but pair-teardown failed (cdx-$item / lease / sbx policy may remain; retry: bash scripts/dev.sh prune --yes)" >&2
      failed=$((failed + 1))
    fi
  done
  if [ "$failed" -gt 0 ]; then
    echo "done ($failed failures)." >&2
    exit 1
  fi
  echo "done."
}

# ---------------- preflight: 新規 box 起動経路 (start_box / cmd_sandbox) の冒頭で呼ぶ ----------------
# 受講者が `bash scripts/dev.sh` を最初に叩いた時に「image build を忘れた」「setup check を忘れた」
# 状態を救済する。明示的に `bash scripts/build-image.sh` / `bash scripts/check-setup.sh` を叩く既存
# entry point は残し、preflight はそれらを内部で呼ぶ薄い fallback (idempotent: 既に揃っていれば short-circuit)。
# ls / attach / kill / prune / shell / route は既存 box / メタ操作で preflight 不要のため呼ばない。
_image_loaded() {
  # check-setup.sh と同じ check: docker.io/library/<name> / bare <name> の両表記を許容
  sbx template ls 2>/dev/null | awk 'NR > 1 && ($1 == "docker.io/library/'"$TEMPLATE"'" || $1 == "'"$TEMPLATE"'") { found=1 } END { exit !found }'
}

_sbx_dockerfile_commit() {
  git log --format=%H -n1 -- sbx/Dockerfile 2>/dev/null
}

# sbx template load 成功後に build-image.sh が書くスタンプの 1 行目 = Dockerfile commit
# (docker inspect は sbx template store と乖離しうるため使わない。2 行目 build 時刻は check-setup の age WARN 用)。
_template_stamp_commit() {
  sed -n '1p' .claude/tmp/sbx-template-commit.stamp 2>/dev/null
}

# stamp 不在 (本機能導入前の古い build) も不一致扱いとして rebuild を促す。
_image_current() {
  _image_loaded || return 1
  local cur exp
  cur=$(_template_stamp_commit)
  exp=$(_sbx_dockerfile_commit)
  [ -n "$cur" ] && [ -n "$exp" ] && [ "$cur" = "$exp" ]
}

preflight_setup() {
  # check-setup は preflight から呼ばない: check-setup.sh が openai secret 不在で NG (exit 1) を返すため、
  # preflight に組み込むと「openai は後で登録、まず claude box だけ動かしたい」フローを regression する
  # (start_box の `sbx secret ls | grep openai` 分岐で degraded path に倒れる fail-open 経路が活きなくなる)。
  # check-setup は doctor として独立 script で明示的に叩く位置づけ (bash scripts/check-setup.sh)。
  # 複数 dev.sh が同時に preflight に入った場合 build-image.sh が共有 cap-sbx.tar を並列で write/load/rm して
  # template load を壊す race を防ぐため、repo-wide lock で直列化 + 待機後に re-check (double-check pattern)。
  if ! _image_current; then
    mkdir -p .claude/tmp
    local image_lock=".claude/tmp/preflight-image.lock"
    local waited=0
    while ! ( set -C; echo $$ > "$image_lock" ) 2>/dev/null; do
      local lock_pid
      lock_pid=$(cat "$image_lock" 2>/dev/null || true)
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        echo "[preflight] stale image lock (pid=$lock_pid dead) を削除して再取得..." >&2
        rm -f "$image_lock"
        continue
      fi
      if [ "$waited" = 0 ]; then
        echo "[preflight] 他の dev.sh が image build 中 (pid=$lock_pid)。完了を待ちます..." >&2
      fi
      sleep 5
      waited=$((waited + 5))
      if [ "$waited" -ge 600 ]; then
        echo "[preflight] image build lock の待機が 10 分を超えました。手動で削除してから再実行してください: rm $image_lock" >&2
        exit 1
      fi
    done
    # lock 取得済み: 待っている間に他方が build を完了している可能性があるため re-check。
    if _image_current; then
      rm -f "$image_lock"
    else
      if _image_loaded; then
        echo "[preflight] sbx/Dockerfile が更新されています。bash scripts/build-image.sh を自動実行します..." >&2
      else
        echo "[preflight] sbx template '$TEMPLATE' が未登録です。bash scripts/build-image.sh を自動実行します (~5 分)..." >&2
      fi
      if bash scripts/build-image.sh; then
        rm -f "$image_lock"
      else
        rm -f "$image_lock"
        echo "[preflight] build-image が失敗しました。手動で 'bash scripts/build-image.sh' を叩いて原因を確認してから dev.sh を再実行してください。" >&2
        exit 1
      fi
    fi
  fi
}

# throwaway 隔離 sandbox box (`sbx run --clone .`)。host checkout を mount しない private copy として起動するので
# 並列に複数走らせても host のファイルを取り合わない (parallel-safe)。`/a2a-review` / `/pr-codex-ci` の reviewer pair は
# 付かないため、PR 化前の ad-hoc 探索 / 検証目的に限定する (workshop の本番作業は引数なし / 明示名の dev box 系統)。
cmd_sandbox() {
  local NAME="${1:-}"
  if [ -n "$NAME" ]; then
    if ! [[ "$NAME" =~ $NAME_RE ]]; then
      echo "error: name '$NAME' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only)." >&2
      exit 1
    fi
    # namespace 分離: dev box (prefix なし) と完全に切り離すため、明示名は **`sbx-*` prefix を強制** する。
    # - `cdx-*`: reviewer pair の予約 prefix で常に reject
    # - `sbx-*`: sandbox 用 prefix。既存 box への reattach は無条件許可、新規作成も許可
    # - それ以外 (prefix なし or 他 prefix): dev box namespace と衝突するため reject (sandbox `task-a` が dev box 扱いされ `/a2a-review` が stale diff を見る regression を防ぐ)
    case "$NAME" in
      cdx-*)
        echo "error: name 'cdx-*' は cdx-<NAME> reviewer box の予約 prefix です。別の name を選んでください。" >&2
        exit 1 ;;
      obs-*)
        echo "error: name 'obs-*' は observe box の予約 prefix です (bash scripts/dev.sh observe が使用)。別の name を選んでください。" >&2
        exit 1 ;;
      sbx-*) ;;
      *)
        echo "error: sandbox 明示名は 'sbx-' prefix が必須です (dev box namespace と完全分離するため)。" >&2
        echo "       例: bash scripts/dev.sh sandbox sbx-${NAME}" >&2
        echo "       引数なしで呼ぶと自動命名 (sbx-<basename>-<hex6>) で起動します。" >&2
        exit 1 ;;
    esac
  else
    # No-arg: sbx-<sanitized-project-basename>-<random hex 6> で衝突回避ループ。
    local base clean_base
    base="$(basename "$PWD")"
    clean_base="${base//[^A-Za-z0-9-]/-}"
    clean_base="${clean_base#"${clean_base%%[!-]*}"}"
    clean_base="${clean_base%"${clean_base##*[!-]}"}"
    [ -z "$clean_base" ] && clean_base="box"
    NAME="sbx-${clean_base}-$(printf '%06x' $((((RANDOM * 32768 + RANDOM) ^ $$) & 0xffffff)))"
    while sbx ls -q 2>/dev/null | grep -Fxq -- "$NAME"; do
      NAME="sbx-${clean_base}-$(printf '%06x' $((((RANDOM * 32768 + RANDOM) ^ $$) & 0xffffff)))"
    done
    echo "Creating new sandbox (clone) box: $NAME (sbx ls で名前確認、再 attach は 'bash scripts/dev.sh sandbox $NAME')" >&2
  fi

  if sbx ls -q 2>/dev/null | grep -Fxq -- "$NAME"; then
    # 既存 box への reattach: preflight skip (box が既にあるなら image / setup は揃っている前提)。
    exec sbx run --name "$NAME"
  else
    # 新規 box 作成: preflight 実行 (image build 忘れ / setup check 忘れの救済)。
    preflight_setup
    exec sbx run --name "$NAME" claude -t "$TEMPLATE" --kit "$KIT" --clone .
  fi
}

# AWS 可観測性調査用の observe box を起動する (rules/box-personas.md の observe persona)。
# sandbox と同型の throwaway clone box だが namespace は `obs-*` で分離し、dev box discovery から除外する。
# clone copy なので host checkout を汚さず (= read-only 相当)、committed runbook はクローンに含まれる。
# AWS read-only cred (host が assume-role で mint→注入) と network 許可 (sbx policy allow --sandbox <obs-box>)
# は host 側の手順で、本 launcher は box の起動だけを担う (examples/observe/runbook.md 参照)。
cmd_observe() {
  local NAME="${1:-}"
  if [ -n "$NAME" ]; then
    if ! [[ "$NAME" =~ $NAME_RE ]]; then
      echo "error: name '$NAME' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only)." >&2
      exit 1
    fi
    # 明示名は `obs-*` prefix を強制 (dev box / sandbox / cdx pair の namespace と完全分離)。
    case "$NAME" in
      obs-*) ;;
      cdx-*|sbx-*)
        echo "error: name '$NAME' は別 persona の予約 prefix です。observe box は 'obs-' prefix を使ってください。" >&2
        exit 1 ;;
      *)
        echo "error: observe 明示名は 'obs-' prefix が必須です (persona namespace を分離するため)。" >&2
        echo "       例: bash scripts/dev.sh observe obs-${NAME}" >&2
        echo "       引数なしで呼ぶと自動命名 (obs-<basename>-<hex6>) で起動します。" >&2
        exit 1 ;;
    esac
  else
    local base clean_base
    base="$(basename "$PWD")"
    clean_base="${base//[^A-Za-z0-9-]/-}"
    clean_base="${clean_base#"${clean_base%%[!-]*}"}"
    clean_base="${clean_base%"${clean_base##*[!-]}"}"
    [ -z "$clean_base" ] && clean_base="box"
    NAME="obs-${clean_base}-$(printf '%06x' $((((RANDOM * 32768 + RANDOM) ^ $$) & 0xffffff)))"
    while sbx ls -q 2>/dev/null | grep -Fxq -- "$NAME"; do
      NAME="obs-${clean_base}-$(printf '%06x' $((((RANDOM * 32768 + RANDOM) ^ $$) & 0xffffff)))"
    done
    echo "Creating observe box: $NAME (read-only AWS 調査用。cred/network は host で注入 → examples/observe/runbook.md)" >&2
  fi

  if sbx ls -q 2>/dev/null | grep -Fxq -- "$NAME"; then
    exec sbx run --name "$NAME"
  else
    preflight_setup
    exec sbx run --name "$NAME" claude -t "$TEMPLATE" --kit "$KIT" --clone .
  fi
}

# claude を経由せず box 内の対話 shell に入る (`sbx exec -it <box> bash` の薄い wrapper)。
# dev box の中で claude セッションと並走させたり、stage worktree の再展開 / debugging 等で
# 「claude を介さず直接何かしたい」時の経路。NAME は dev box / sandbox box / cdx-<NAME>
# reviewer box のいずれも可 (sbx ls / dev.sh ls で確認)。
cmd_shell() {
  local NAME="${1:-}"
  if [ -z "$NAME" ]; then
    echo "usage: bash scripts/dev.sh shell <NAME>" >&2
    echo "       <NAME> は 'bash scripts/dev.sh ls' / 'sbx ls' で確認できる box 名" >&2
    exit 1
  fi
  # 先頭は英数字、Docker container 名規則と整合 (regex metachar の混入で誤 attach を防ぐ)
  case "$NAME" in
    -*|*[^A-Za-z0-9-]*)
      echo "error: name '$NAME' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only). Pass a valid name as the first argument." >&2
      exit 1 ;;
  esac
  # -i (stdin 維持) + -t (pseudo-TTY 割り当て) を明示。両方ないと PS1 / readline / 色つき出力が効かず「shell 感」が無くなる (sbx exec は docker exec と同じ semantics)。
  exec sbx exec -it "$NAME" bash
}

# ---------------- route subcommand: Traefik で box の service を <name>.localhost で公開 ----------------
# 並列 box (dev / sandbox) の service を名前 (<name>.localhost) でルーティングする host 側機能。
# name 契約 (full label 列 / 既定 web.<branch>.<repo> / service 種別 prefix は固定しない) は _route_usage 参照。
# box 作成/起動は dev.sh 本体 (start_box / cmd_sandbox)。route subcommand は routing 層のみ扱う (box lifecycle と分離)。
# verb: up (Traefik 起動) / add <box> [port] [name] (経路追加) / rm <name> (経路削除) /
#       ls (経路一覧) / down (Traefik 停止 + 全経路掃除) / detect (共有 Traefik 検出結果)

_route_compose=tools/parallel-dev/box-routing/proxy.compose.yml
_route_store_img=alpine  # 経路ファイル CRUD で named volume を一時 container 経由で読み書きするのに使う

# :80 を持つ共有 Traefik を自動検出し、その file provider 供給先を返す:
#   "volume:<name>"（named volume）/ "dir:<path>"（bind mount）/ 空（未検出・docker 無し）。
# 検出できれば相乗り、できなければ自前 Traefik にフォールバックする。
_route_detect_shared() {
  command -v docker >/dev/null 2>&1 || return 0
  local rows id img proj ports cands="" filedir best="" bestlen=0 d n s sub
  # :80 publish の container を列挙。自前(box-routing)除外 + host :80 実確認 + image 名 traefik を候補に。
  rows=$(docker ps --filter publish=80 \
    --format '{{.ID}}|{{.Image}}|{{.Label "com.docker.compose.project"}}|{{.Ports}}' 2>/dev/null) || true
  while IFS='|' read -r id img proj ports; do
    [ -n "$id" ] || continue
    [ "$proj" = "box-routing" ] && continue            # 自前 Traefik は相乗り対象にしない
    printf '%s' "$ports" | grep -q ':80->' || continue # ephemeral host port を除外し host :80 のみ
    printf '%s' "$img" | grep -qi traefik && cands="$cands $id"
  done <<< "$rows"
  # shellcheck disable=SC2086
  set -- $cands
  [ "$#" -eq 1 ] || return 0                            # 0=未検出 / 2+=曖昧 は fail-closed（env/自前に委ねる）
  # CLI 引数から file provider dir を拾う（= 形 / 空白形の両対応。config file 指定は拾えない→env で）。
  filedir=$(docker inspect "$1" --format '{{range .Config.Entrypoint}}{{println .}}{{end}}{{range .Config.Cmd}}{{println .}}{{end}}{{range .Args}}{{println .}}{{end}}' 2>/dev/null \
    | awk '/^--providers\.file\.directory=/{sub(/^--providers\.file\.directory=/,"");print;exit} p=="--providers.file.directory"{print;exit} {p=$0}') || true
  [ -n "${filedir:-}" ] || return 0
  # filedir に exact 一致 or 親 prefix な mount を探す（filedir を go-template に埋めない＝injection 回避）。
  while IFS='|' read -r d n s; do
    [ -n "$d" ] || continue
    case "$filedir" in
      "$d") best="$n|$s|"; break ;;                                  # exact
      "$d"/*) [ "${#d}" -gt "$bestlen" ] && { best="$n|$s|${filedir#"$d"/}"; bestlen=${#d}; } ;;  # parent
    esac
  done <<< "$(docker inspect "$1" --format '{{range .Mounts}}{{.Destination}}|{{.Name}}|{{.Source}}{{"\n"}}{{end}}' 2>/dev/null)"
  [ -n "$best" ] || return 0
  n=$(printf '%s' "$best" | cut -d'|' -f1); s=$(printf '%s' "$best" | cut -d'|' -f2); sub=$(printf '%s' "$best" | cut -d'|' -f3)
  if [ -n "$n" ]; then
    # named volume: exact のみ対応（volume 内 subpath は未対応。env で供給先を明示してもらう）。
    [ -z "$sub" ] && echo "volume:$n" || return 0
  elif [ -n "$s" ]; then
    echo "dir:$s${sub:+/$sub}"                          # bind mount は host path なので親 mount + subpath で解決
  fi
  return 0
}

# Traefik 経路名 = 厳密な DNS ラベル列（各ラベル: 英数字で始まり英数字で終わる / 内部にハイフン可 / <=63）。
# 先頭末尾ハイフン・'/'・'..'・先頭末尾ドットを弾き、不正 Host / dynamic ファイル名を防ぐ。
_route_valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

# Windows 予約デバイス名 (con/nul/com1 等) を含むラベルを弾く。cross-platform 一貫のため .sh でも拒否する
# (Windows では $dyn/<name>.yml 作成が失敗するため)。
_route_reserved_name() {
  local IFS=. label
  for label in $1; do
    case "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" in
      con|prn|aux|nul|com[1-9]|lpt[1-9]) return 0 ;;
    esac
  done
  return 1
}

# 経路ファイルの読み書きを供給先 (dir / named volume) で抽象化する。
# volume モードは Traefik 設定を触らず、一時 container で stdin 経由 cp / cat / rm する
# (host path を bind しないので Docker Desktop の共有設定に依存しない)。name は呼出側で検証済み。
# $dynvol / $dyn は cmd_route の caller scope に存在することを前提とする (function 内 local)。
_route_store_write() { # $1=name, yaml は stdin
  if [ -n "$dynvol" ]; then
    docker run --rm -i -v "$dynvol":/d "$_route_store_img" sh -c "cat > /d/$1.yml"
  else
    mkdir -p "$dyn"; cat > "$dyn/$1.yml"
  fi
}
_route_store_read() { # $1=name -> stdout (無ければ空)
  if [ -n "$dynvol" ]; then
    docker run --rm -v "$dynvol":/d "$_route_store_img" sh -c "cat /d/$1.yml 2>/dev/null" 2>/dev/null || true
  else
    cat "$dyn/$1.yml" 2>/dev/null || true
  fi
}
_route_store_rm() { # $1=name
  if [ -n "$dynvol" ]; then
    if ! docker run --rm -v "$dynvol":/d "$_route_store_img" rm -f "/d/$1.yml" >/dev/null; then
      echo "error: failed to remove route '$1' from volume '$dynvol'" >&2; exit 1
    fi
  else
    # `rm -f` は missing でも exit 0 (idempotent)、real I/O error (permission 等) のみ非ゼロ。
    if ! rm -f "$dyn/$1.yml"; then
      echo "error: failed to remove route '$1' from '$dyn'" >&2; exit 1
    fi
  fi
}
_route_store_list() { # -> name 一覧 (.yml を除いた basename)。rc: 0=成功 (空 store 含む) / 非0=backend エラー
  # inner の `; exit 0` は空 store 時に最終 test の rc 1 が docker の rc に化けるのを吸収する
  # (rc 非0 を backend エラーに限定し、衝突走査側の fail-closed 判定を成立させる)
  if [ -n "$dynvol" ]; then
    docker run --rm -v "$dynvol":/d "$_route_store_img" sh -c 'for f in /d/*.yml; do [ -e "$f" ] && basename "$f" .yml; done; exit 0' 2>/dev/null
  else
    for f in "$dyn"/*.yml; do [ -e "$f" ] && basename "$f" .yml; done 2>/dev/null
    return 0
  fi
}
# 経路の存在確認 + 内容取得。読み取り「失敗」を「不在」に潰さない (潰すと所有/衝突 guard が
# backend 不調時に素通りして上書きしてしまう)。rc: 0=存在(stdout=内容) / 1=不在 / 2=backend エラー。
_route_store_get() { # $1=name
  if [ -n "$dynvol" ]; then
    local out rc=0
    # explicit if (&&/|| 連鎖だと cat 失敗も exit 3=不在に化ける)。set -e で落ちないよう || で rc 受け。
    out=$(docker run --rm -v "$dynvol":/d "$_route_store_img" \
      sh -c "if [ -e /d/$1.yml ]; then cat /d/$1.yml; else exit 3; fi" 2>/dev/null) || rc=$?
    case "$rc" in
      0) printf '%s' "$out"; return 0 ;;
      3) return 1 ;;          # 不在
      *) return 2 ;;          # docker 起動/接続失敗 や cat 失敗 = backend エラー
    esac
  else
    if [ -f "$dyn/$1.yml" ]; then cat "$dyn/$1.yml"; return 0; else return 1; fi
  fi
}

# stdin の yaml から全 Host(`...`) の中身を 1 行ずつ返す (無ければ空)。手書き rule は `Host(a) || Host(b)` の
# 複合を持ちうるため最初の 1 個に限定しない (衝突走査が 2 個目以降を見逃す)。PathPrefix 等は拾わない。
_route_rule_host() {
  awk '{ s = $0
         while (match(s, /Host\(`[^`]+`\)/)) {
           print substr(s, RSTART + 6, RLENGTH - 8)
           s = substr(s, RSTART + RLENGTH)
         } }'
}

_route_usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/dev.sh route <verb> [args]
  up                          standing Traefik を起動 (一度だけ)
  add <box> [port] [name]     box の dev port (default 3000) を ephemeral host port で publish し
                              <name>.localhost に経路を追加 (Traefik hot-reload)
                              name 既定 = web.<branch>.<repo> (現 checkout 由来) -> web.<branch>.<repo>.localhost
                              name はドット区切りの DNS ラベル列で hostname 全体を指定
                              (例 slides.coding-agent-playbook / api.myapp -> api.myapp.localhost)
  rm <name>                   <name> の経路を削除
  ls                          現在の経路一覧
  down                        Traefik 停止 + 全経路を掃除 (box は消さない)
  detect                      :80 の共有 Traefik 検出結果を表示 (add が自動で使う)

相乗り (既存の共有 Traefik を使う / 自前 Traefik を立てない):
  :80 に file provider 付き Traefik が居れば **自動検出して相乗り**する。up は不要、そのまま add
  すればよい (up/down は相乗り時 no-op)。検出内容は 'detect' で確認できる。
  自動検出できない構成 (config file 指定など) は env で供給先を明示:
    BOX_ROUTING_DYNAMIC_DIR=<dir>      共有 Traefik が bind mount で watch する dynamic dir
    BOX_ROUTING_DYNAMIC_VOLUME=<vol>   共有 Traefik が named volume で watch する場合
USAGE
}

cmd_route() {
  local verb=${1:-help}
  shift || true

  # verb ごとの positional arity guard。PowerShell 側 (Invoke-Route) と挙動差を作らないため
  # bash 側でも余剰 args を fail-fast する (旧 route.sh は silent ignore だったが cross-platform 整合性のため stricter にする)。
  local max_args
  case "$verb" in
    up|ls|down|detect|help|-h|--help) max_args=0 ;;
    add) max_args=3 ;;
    rm) max_args=1 ;;
    *) max_args=-1 ;;  # unknown verb は dispatcher で error 出すので skip
  esac
  if [ "$max_args" -ge 0 ] && [ "$#" -gt "$max_args" ]; then
    echo "error: 'route $verb' takes at most $max_args positional argument(s); got $#: $*" >&2
    exit 1
  fi

  # 経路の供給先決定 (cmd_route invoke ごとに毎回評価): 明示 env > 自動検出 > 自前 Traefik (リポ内 dir / スタンドアロン)。
  # cmd_route 関数 local の dynvol / dyn を _route_store_* helper が参照する (top-level global より scope 安全)。
  local dynvol="" dyn="" piggyback=0 detect_src=""
  if [ -n "${BOX_ROUTING_DYNAMIC_VOLUME:-}" ] || [ -n "${BOX_ROUTING_DYNAMIC_DIR:-}" ]; then
    [ -n "${BOX_ROUTING_DYNAMIC_VOLUME:-}" ] && [ -n "${BOX_ROUTING_DYNAMIC_DIR:-}" ] && {
      echo "error: BOX_ROUTING_DYNAMIC_DIR と BOX_ROUTING_DYNAMIC_VOLUME は同時指定できません（一方のみ）。" >&2; exit 1; }
    dynvol=${BOX_ROUTING_DYNAMIC_VOLUME:-}
    [ -n "${BOX_ROUTING_DYNAMIC_DIR:-}" ] && dyn=${BOX_ROUTING_DYNAMIC_DIR}
    piggyback=1; detect_src="env"
  else
    local detected
    detected=$(_route_detect_shared) || true
    case "${detected:-}" in
      volume:*) dynvol=${detected#volume:}; piggyback=1; detect_src="auto" ;;
      dir:*)    dyn=${detected#dir:};       piggyback=1; detect_src="auto" ;;
    esac
  fi
  [ "$piggyback" = 1 ] || dyn=tools/parallel-dev/box-routing/dynamic

  case "$verb" in
    up)
      if [ "$piggyback" = 1 ]; then
        local via
        via=$([ "$detect_src" = auto ] && echo "自動検出" || echo "env 指定")
        if [ -n "$dynvol" ]; then
          echo "相乗りモード（${via}）: 既存の共有 Traefik を使うので自前 Traefik は起動しません（供給先: named volume '$dynvol'）。" >&2
        else
          echo "相乗りモード（${via}）: 既存の共有 Traefik を使うので自前 Traefik は起動しません（供給先: dir '$dyn'）。" >&2
        fi
        echo "そのまま 'add' してください（経路は共有 Traefik が配信します）。" >&2
        exit 0
      fi
      if docker compose -f "$_route_compose" up -d; then
        echo "Traefik up。add した box が <name>.localhost で見えます。"
      else
        echo "" >&2
        echo "Traefik 起動に失敗しました（:80 が既に使用中の可能性）。対処:" >&2
        echo "  - 既存の共有 Traefik に相乗り: その dynamic 供給先を" >&2
        echo "      BOX_ROUTING_DYNAMIC_DIR=<dir> または BOX_ROUTING_DYNAMIC_VOLUME=<vol>" >&2
        echo "    に設定して add してください（up は不要）" >&2
        echo "  - 名前付き URL が不要なら: sbx ports <box> --publish <port>:<port> で http://127.0.0.1:<port> を直接開く (localhost は macOS 等で ::1 に先に解決され sbx の IPv6 forward が reset して開けないことがある)" >&2
        exit 1
      fi
      ;;
    add)
      local box=${1:?route add <box> [port] [name]}
      local port=${2:-3000}
      # name は hostname 全体 (<name>.localhost)。既定は web.<branch>.<repo> (呼び出し元 checkout 由来の web preview)。
      # '/' は '-' へ、非 DNS 文字は除去し、ラベル端のハイフンも trim する。
      # __DEV_CALLER_BRANCH は cd 前に捕捉済み (本 script 冒頭参照)。
      local branch repo name
      branch=$(printf '%s' "${__DEV_CALLER_BRANCH:-}" | tr '/' '-' | tr -cd 'A-Za-z0-9-' | sed -E 's/^-+//; s/-+$//')
      repo=$(basename "$PWD" | tr -cd 'A-Za-z0-9-' | sed -E 's/^-+//; s/-+$//')
      name=${3:-web.${branch:+$branch.}$repo}
      # hostname は case-insensitive (DNS / Traefik) のため小文字に正規化する。case 違いの同名 entry が
      # FS / backend の case 感度差で「別 route」扱いになり store 操作が破綻する経路を根元で塞ぐ
      name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
      _route_valid_name "$name" || { echo "error: name '$name' must be dot-separated DNS labels (each label: alnum start/end, hyphen inside, <=63)" >&2; exit 1; }
      _route_reserved_name "$name" && { echo "error: name '$name' contains a Windows reserved device name (con/prn/aux/nul/com1-9/lpt1-9)" >&2; exit 1; }
      # .localhost は rule 生成時に自動付与されるため name に含めると Host が …localhost.localhost に化ける
      case "$name" in
        localhost|*.localhost)
          echo "error: name '$name' に .localhost を含めない (自動付与される。例: api.myapp -> api.myapp.localhost)" >&2; exit 1 ;;
      esac
      # host port を省略 = ephemeral 自動採番。再 add でも冪等にするため失敗は握りつぶす
      sbx ports "$box" --publish "$port" >/dev/null 2>&1 || true
      # pipefail で sbx 失敗時にこの代入が非ゼロ終了し set -e で abort するのを防ぎ、次行の friendly error に渡す
      local hostport
      hostport=$(sbx ports "$box" | awk -v p="$port" '$1=="127.0.0.1" && $3==p {print $2; exit}') || true
      [ -n "$hostport" ] || { echo "error: $box:$port の host port を解決できず (box は起動中?)" >&2; exit 1; }
      # 同名の既存経路があれば fail-closed (silent 上書き回避)。同 box の再 add のみ冪等に通す。
      # 相乗り供給先には他ツール/手書きの同名 .yml がありうるため、marker 無し (所有不明) も拒否する。
      local getrc=0 existing
      existing=$(_route_store_get "$name") || getrc=$?   # set -e で不在(rc=1)時に落ちないよう || 受け
      if [ "$getrc" = 2 ]; then
        echo "error: 経路ストアを確認できません（backend エラー）。安全のため中断します。" >&2; exit 1
      fi
      if [ "$getrc" = 0 ]; then
        local prev
        prev=$(printf '%s' "$existing" | awk '/^# box:/{print $3; exit}')
        if [ "$prev" != "$box" ]; then
          echo "error: route '$name' は既に存在します (box='${prev:-unknown}'。marker 無しは他ツール由来の可能性)。上書きしません。別の明示名を:" >&2
          echo "       bash scripts/dev.sh route add $box $port <unique.name>" >&2
          exit 1
        fi
      fi
      # 同一 Host を持つ別ファイル名の経路も走査する (filename 一致だけでは同一 Host の router 重複を防げない。
      # 典型は旧 default 名 <branch>.<repo> のファイルが Host web.… を持つ upgrade 後の再 add)。
      # 同 box 所有なら置換移行、他 box / 管理外は fail-closed。1st pass は検出のみで削除しない
      # (走査途中で削除すると、後続で fail-closed になった場合に旧経路だけ消える部分破壊が起きる)。
      # 一覧取得も fail-closed (backend エラーで空一覧に潰れると走査自体が素通りする)
      local others
      others=$(_route_store_list) \
        || { echo "error: 経路ストアの一覧を取得できません（backend エラー）。安全のため中断します。" >&2; exit 1; }
      local other other_lc ocontent ohosts obox orc conflict migrate=""
      for other in $others; do
        [ "$other" = "$name" ] && continue
        # fail-closed reader (_route_store_get) を使う: read 失敗を「不在」に潰すと同一 Host の
        # 衝突検出が transient エラーで素通りし router 重複を書いてしまう
        orc=0; ocontent=$(_route_store_get "$other") || orc=$?
        if [ "$orc" = 2 ]; then
          echo "error: 経路ストアを確認できません（'$other' の読み取りで backend エラー）。安全のため中断します。" >&2; exit 1
        fi
        [ "$orc" = 0 ] || continue
        # 衝突 = 同一 Host を持つ entry、または basename が case 違いで一致する entry
        # (hostname は case-insensitive。case 違い basename を無検査 skip すると、別 box 所有 entry の
        # fail-closed guard を bypass して同一 hostname の router 重複を書けてしまう)
        conflict=0
        other_lc=$(printf '%s' "$other" | tr '[:upper:]' '[:lower:]')
        [ "$other_lc" = "$name" ] && conflict=1
        if [ "$conflict" = 0 ]; then
          # membership 照合は全読みの command substitution + case で行う (`| grep -q` は match 時の早期 close で
          # 上流 awk が SIGPIPE 141 になり pipefail 下で「一致したのに不一致」の偽陰性を生む)
          ohosts=$(printf '%s' "$ocontent" | _route_rule_host | tr '[:upper:]' '[:lower:]')
          case $'\n'"$ohosts"$'\n' in
            *$'\n'"$name.localhost"$'\n'*) conflict=1 ;;
          esac
        fi
        [ "$conflict" = 1 ] || continue
        obox=$(printf '%s' "$ocontent" | awk '/^# box:/{print $3; exit}')
        if [ "$obox" = "$box" ]; then
          migrate="$migrate $other"
        else
          echo "error: Host '$name.localhost' は既存経路 '$other' (box='${obox:-unknown}') が使用中。上書きしません。" >&2
          exit 1
        fi
      done
      local route_yaml
      route_yaml=$(cat <<EOF
# box: $box
http:
  routers:
    $name:
      rule: "Host(\`$name.localhost\`)"
      service: $name
      entryPoints: [web]
  services:
    $name:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:$hostport"
EOF
      )
      printf '%s\n' "$route_yaml" | _route_store_write "$name"
      # 旧経路の削除は新経路の write 成功後 (write が transient 失敗すると旧経路まで失い無経路になる。
      # 一時的な同一 Host 重複は同 box・同 hostport で無害、rm 失敗時も次回 add の走査が再移行して冪等)
      local occheck
      for other in $migrate; do
        # case-insensitive FS では case 違い basename が今書いた新経路と同一ファイルでありうる。
        # 内容を再読して新経路そのもの (今書いた yaml) なら削除しない (消すと新経路ごと消える)
        orc=0; occheck=$(_route_store_get "$other") || orc=$?
        if [ "$orc" = 2 ]; then
          echo "error: 経路ストアを確認できません（'$other' の削除前確認で backend エラー）。旧経路 '$other' が残っている可能性があります。" >&2; exit 1
        fi
        [ "$orc" = 1 ] && continue
        [ "$occheck" = "$route_yaml" ] && continue
        _route_store_rm "$other"
        echo "migrated: 同一 Host の旧経路 '$other' を '$name' に置換" >&2
      done
      if [ "$piggyback" = 1 ]; then
        local tag
        tag=$([ "$detect_src" = auto ] && echo "相乗り/自動検出" || echo "相乗り")
        echo "routed: http://$name.localhost -> host:$hostport -> $box:$port ($tag)"
      else
        echo "routed: http://$name.localhost -> host:$hostport -> $box:$port"
      fi
      ;;
    rm)
      # rm は exact-match (正規化しない): 正規化すると case-sensitive な volume backend 上の
      # legacy / 手書き mixed-case entry を指定できなくなる。名前は ls の表示どおりに渡す
      local name=${1:?route rm <name>}
      _route_valid_name "$name" || { echo "error: name '$name' must be dot-separated DNS labels (each label: alnum start/end, hyphen inside, <=63)" >&2; exit 1; }
      _route_reserved_name "$name" && { echo "error: name '$name' contains a Windows reserved device name (con/prn/aux/nul/com1-9/lpt1-9)" >&2; exit 1; }
      # 所有確認: 本 subcommand 由来 (# box marker あり) のみ削除する。相乗り供給先の他ツール/手書き
      # config を誤って消さないため、marker 無し/読み取り不能は拒否する。
      local getrc=0 existing
      existing=$(_route_store_get "$name") || getrc=$?
      if [ "$getrc" = 2 ]; then echo "error: 経路ストアを確認できません（backend エラー）。中断します。" >&2; exit 1; fi
      if [ "$getrc" = 1 ]; then echo "route rm: '$name' は存在しません" >&2; exit 0; fi
      if ! printf '%s' "$existing" | grep -q '^# box:'; then
        echo "error: route '$name' は本 subcommand 管理外（# box marker 無し）。安全のため削除しません。" >&2
        exit 1
      fi
      _route_store_rm "$name"
      echo "unrouted: $name (publish は残る。完全に外すなら sbx ports <box> --unpublish)"
      ;;
    ls)
      # hostname は name から再構築せず yaml の実 rule を読む (store には手書き/旧形式の経路もあり name と一致するとは限らない)
      local found=0 n c u h
      for n in $(_route_store_list); do
        found=1
        c=$(_route_store_read "$n")
        u=$(printf '%s' "$c" | awk -F'"' '/url:/ {print $2; exit}')
        # awk 'NR == 1' は入力を最後まで読む (head -n 1 の早期 close だと multi-Host entry で上流が SIGPIPE 141
        # になり set -e が ls を中断する)
        h=$(printf '%s' "$c" | _route_rule_host | awk 'NR == 1')
        echo "http://${h:-$n.localhost} -> $u"
      done
      [ "$found" = 1 ] || echo "(経路なし)"
      ;;
    down)
      if [ "$piggyback" = 1 ]; then
        echo "相乗りモードでは共有 Traefik は管理しません。各経路は 'route rm <name>' で個別に外してください。" >&2
        exit 0
      fi
      docker compose -f "$_route_compose" down 2>/dev/null || true
      rm -f "$dyn"/*.yml 2>/dev/null || true
      echo "routing 層を片付けました (box は sbx 側で管理)。"
      ;;
    detect)
      # 検出結果を表示 (デバッグ/確認用)。add はこれを自動で使う。
      if [ "$piggyback" = 1 ]; then
        if [ -n "$dynvol" ]; then echo "供給先: named volume '$dynvol' ($detect_src)"
        else echo "供給先: dir '$dyn' ($detect_src)"; fi
        echo "→ 相乗りモード（add で既存の共有 Traefik を使う。up 不要）"
      else
        echo "共有 Traefik を検出できませんでした → 自前 Traefik モード（bash scripts/dev.sh route up）。"
        echo "（手動指定するなら BOX_ROUTING_DYNAMIC_VOLUME / BOX_ROUTING_DYNAMIC_DIR）"
      fi
      ;;
    help|-h|--help) _route_usage ;;
    *) echo "unknown route verb: $verb" >&2; _route_usage; exit 1 ;;
  esac
}

start_box() {
  local NAME="${1:-}"
  if [ -z "$NAME" ]; then
    NAME="$(generate_name)"
    echo "Creating new dev box: $NAME (sbx ls / 'bash scripts/dev.sh ls' で確認、再 attach は 'bash scripts/dev.sh $NAME')" >&2
  else
    validate_name "$NAME"
  fi

  # 既存 box への reattach (= idempotent attach-or-create で box が既にある) は preflight skip。
  # 既存なら image / setup は揃っている前提なので、attach を NG な check-setup で abort させない。
  # 新規 create 経路でのみ preflight 実行 (image build 忘れ / setup check 忘れの救済)。
  if ! sbx ls -q 2>/dev/null | grep -Fxq -- "$NAME"; then
    preflight_setup
  fi

  # 1 NAME = 1 dev session 規約: lock は pair-setup より前で取る (pair-setup の前 race で sbx create 衝突 → 敗者の cleanup が勝者の box を pair-teardown で消す regression を避けるため)。
  # set -C (noclobber) で `>` の atomic-create を利用。stale PID は除去して 1 度だけ retry。
  local LOCK_FILE=".claude/tmp/cdx-dev-${NAME}.lock"
  # broker child pid (下の trap で teardown)。EXIT trap は start_box return 後に global scope で発火するため、
  # local だと trap 発火時に unbound で set -u が trap を abort させる (下の pair_serve_pid も同様)。global にする。
  BROKER_PID=
  mkdir -p .claude/tmp
  if ! ( set -C; echo $$ > "$LOCK_FILE" ) 2>/dev/null; then
    local lock_pid
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "error: 別の dev session '$NAME' が active です (pid=$lock_pid)。" >&2
      echo "       並列で複数 box を起動するには別の <NAME> を指定するか引数なしで起動してください (例: bash scripts/dev.sh)。" >&2
      echo "       既存 box の中で shell 観察したい場合は 'bash scripts/dev.sh shell $NAME' を使用してください。" >&2
      exit 1
    fi
    echo "info: stale dev lock を検出して削除しました (pid=$lock_pid が dead)。" >&2
    rm -f "$LOCK_FILE"
    if ! ( set -C; echo $$ > "$LOCK_FILE" ) 2>/dev/null; then
      echo "error: dev lock 取得に失敗しました (race with another dev.sh)。" >&2
      exit 1
    fi
  fi
  trap 'if [ -n "$BROKER_PID" ]; then kill "$BROKER_PID" 2>/dev/null || true; sbx secret rm "'"$NAME"'" github -f >/dev/null 2>&1 || true; fi; rm -f "'"$LOCK_FILE"'" ".claude/tmp/app-broker-'"$NAME"'.log" 2>/dev/null || true' EXIT INT TERM

  # cdx-<NAME> reviewer pair の auto-provision。openai secret 未登録 / pair-setup 失敗は fail-open (claude box は起動するが /a2a-review は使えない、後続 skill が graceful degrade で案内)。
  # bootstrap verify (server .venv の存在 check) を入れて、pair-setup が uv pip install 途中で中断した box を「existing = ready」と誤判定するのを防ぐ。
  # secret 列の hard-code を避け awk で global 行から探す (sbx version 間の column 差を吸収)。
  local pair_ready=0
  if sbx secret ls -g 2>/dev/null | awk 'NR > 1 && $1 == "(global)" { for (i = 2; i <= NF; i++) if ($i == "openai") { f = 1; exit } } END { exit !f }'; then
    local cdx_exists=0
    sbx ls -q 2>/dev/null | grep -Fxq -- "cdx-$NAME" && cdx_exists=1
    if [ "$cdx_exists" = 1 ] && sbx exec "cdx-$NAME" test -x tools/a2a-review/codex-a2a-server/.venv/bin/python 2>/dev/null; then
      pair_ready=1
    else
      if [ "$cdx_exists" = 1 ]; then
        echo "cdx-$NAME が bootstrap 未完了のため破棄して再 provision します..." >&2
        sbx rm -f "cdx-$NAME" >/dev/null 2>&1 || true
      fi
      echo "cdx-$NAME reviewer box を auto-provision します (openai secret から、~数十秒)..." >&2
      if bash scripts/internal/a2a-review.sh pair-setup "$NAME"; then
        pair_ready=1
      else
        echo "warning: cdx-$NAME pair-setup に失敗。partial box を削除します (次回 bash scripts/dev.sh $NAME で再 provision)。" >&2
        bash scripts/internal/a2a-review.sh pair-teardown "$NAME" >/dev/null 2>&1 || true
        echo "warning: /a2a-review / /pr-codex-ci は使えませんが、claude box は起動します。失敗が続く場合は手動診断: bash scripts/internal/a2a-review.sh pair-setup $NAME" >&2
      fi
    fi
  else
    echo "info: openai secret 未登録のため cdx-$NAME reviewer box は skip (/a2a-review / /pr-codex-ci は使えません)。" >&2
    echo "      使う場合: sbx secret set -g openai --oauth  ※登録後、再度 bash scripts/dev.sh $NAME で auto-provision されます" >&2
  fi

  # host 常駐 daemon を avoid しつつ TTY 終了で trap teardown する per-pair lifecycle (install.sh / launchd / systemd を持ち込まないため、子プロセス fork のみで完結)。
  # pair-serve 子の stdout/stderr は log file に redirect (terminal 継承だと claude TUI と重なって描画崩れする)。
  # global (local 不可): 下の EXIT trap が start_box return 後に参照するため (BROKER_PID と同じ理由)。
  pair_serve_pid=
  local PAIR_SERVE_LOG=".claude/tmp/cdx-serve-${NAME}.log"
  if [ "$pair_ready" = 1 ]; then
    bash scripts/internal/a2a-review.sh pair-serve "$NAME" > "$PAIR_SERVE_LOG" 2>&1 &
    pair_serve_pid=$!
    # 各 cleanup step に `|| true` を付けて set -e 下でも残り step が必ず走る (wait は kill された pid を待つので exit 143 になりうるが、それで trap が中断すると cdx orphan を残す)。
    trap '
      kill "$pair_serve_pid" 2>/dev/null || true
      wait "$pair_serve_pid" 2>/dev/null || true
      kill "$BROKER_PID" 2>/dev/null || true
      wait "$BROKER_PID" 2>/dev/null || true
      [ -n "$BROKER_PID" ] && sbx secret rm "'"$NAME"'" github -f >/dev/null 2>&1 || true
      bash scripts/internal/a2a-review.sh pair-teardown "'"$NAME"'" >/dev/null 2>&1 || true
      rm -f "'"$LOCK_FILE"'" "'"$PAIR_SERVE_LOG"'" ".claude/tmp/app-broker-'"$NAME"'.log" 2>/dev/null || true
    ' EXIT INT TERM
  fi

  # marker (APP_IDENTITY_ENABLE) が立つ box だけ broker を bg 起動 (box の per-box github secret を App token に
  # live 更新 → author=bot、設計は上の _APP_BROKER_CONFIG 参照)。marker あり + config/node 不在は warning skip。
  # teardown (上の trap) で broker の per-box github secret を除去して PAT に戻す (期限切れ App token の残留防止)。
  if _app_identity_enabled "$NAME"; then
    if [ ! -f "$_APP_BROKER_CONFIG" ]; then
      echo "warning: APP_IDENTITY marker はあるが $_APP_BROKER_CONFIG (appId/keyPath) が無いため app-broker skip (github は global PAT のまま)。" >&2
    elif ! command -v node >/dev/null 2>&1; then
      echo "warning: APP_IDENTITY marker はあるが node 不在のため app-broker skip (github は global PAT のまま)。" >&2
    else
      node scripts/internal/app-token-broker.js --box "$NAME" > ".claude/tmp/app-broker-${NAME}.log" 2>&1 &
      BROKER_PID=$!
      echo "info: app-broker 起動 (box '$NAME' の github identity を App bot に切替、pid=${BROKER_PID}、log .claude/tmp/app-broker-${NAME}.log)。" >&2
    fi
  fi

  # trap を生かすため exec は使わず sbx run の return を待つ。
  if sbx ls -q 2>/dev/null | grep -Fxq -- "$NAME"; then
    sbx run --name "$NAME"
  else
    sbx run --name "$NAME" claude -t "$TEMPLATE" --kit "$KIT" .
  fi
}

# subcommand dispatch
case "${1:-}" in
  -h|--help|help)
    usage; exit 0 ;;
  ls)
    shift
    cmd_ls "$@" ;;
  attach)
    shift
    cmd_attach "${1:-}" ;;
  kill|rm|stop)
    shift
    cmd_kill "${1:-}" ;;
  prune)
    shift
    cmd_prune "$@" ;;
  sandbox)
    shift
    cmd_sandbox "${1:-}" ;;
  observe)
    shift
    cmd_observe "${1:-}" ;;
  shell)
    shift
    cmd_shell "${1:-}" ;;
  route)
    shift
    cmd_route "$@" ;;
  -*)
    echo "error: unknown flag '$1'" >&2
    usage; exit 1 ;;
  "")
    start_box "" ;;
  *)
    start_box "$1" ;;
esac
