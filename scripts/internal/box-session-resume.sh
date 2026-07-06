#!/usr/bin/env bash
# host 側ヘルパー: Claude Code session の transcript を「今ある場所 (box / host)」から自動特定して
# dest (host または別 box) の ~/.claude/projects/<encoded>/ に元 UUID 名で inject し、`claude --resume`
# で同一 session を実再開できる状態にする。box→host / box→別 box / host→box を入口 1 つで賄う
# (box-primary 運用の session 引き継ぎ。box-session-context.sh は参照専用 copy、本 script は resume 仕込み)。

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/internal/box-session-resume.sh <session_id> [<dest>] [<source>]
  session_id: UUID or 8+ hex short prefix
  dest:       omit -> resume on host. box name -> resume in that box.
  source:     explicit source box/host where the transcript currently lives
              (only needed to disambiguate when multiple locations hold it)
exit codes:
  0=success, 1=arg error, 2=sbx not found,
  3=transcript not found, 4=ambiguous (multiple matches; pass full UUID or explicit source),
  5=running inside an sbx box (this skill is host-only),
  6=sbx command failure
USAGE
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
  usage
  exit 1
fi

session_id="$1"
dest="${2:-}"      # 空 = host
source_arg="${3:-}"

# UUID hex / dash 以外を弾く: $session_id は後段で box 内 sh -c の string に挿入されるため
if ! [[ "$session_id" =~ ^[a-fA-F0-9-]{8,36}$ ]]; then
  echo "invalid session_id (expected UUID or 8+ hex prefix): '${session_id}'" >&2
  exit 1
fi

# host-only guard: $SANDBOX_VM_ID は box 内のみ set される asymmetry を使う。box から sibling box へ sbx で
# 到達できないため raw script は box で動かない。box では /box-session-resume skill が host へ委譲するので、
# script 直叩きでなく skill を使うよう案内する (`!` は box 内 shell で実行され同じく失敗するため勧めない)
if [[ -n "${SANDBOX_VM_ID:-}" ]]; then
  cat >&2 <<EOF
This script is host-only but \$SANDBOX_VM_ID=${SANDBOX_VM_ID} is set (you are inside an sbx box).
Do not run this script directly here. Instead:
- Use the /box-session-resume skill from this box: it delegates to the host via the host-bridge
  (the user grants it on the host with /box-session-resume-grant). Don't use the ! prefix — that runs
  in this box's shell and hits the same wall.
- Or run from a host shell where \$SANDBOX_VM_ID is empty (echo \$SANDBOX_VM_ID prints nothing).
EOF
  exit 5
fi

if ! command -v sbx >/dev/null 2>&1; then
  echo "sbx command not found. Install Docker Sandboxes first." >&2
  exit 2
fi

# sbx 公式 box 名規約 (letters/numbers/hyphens/periods/plus signs/underscores) 以外を弾く: box 名は
# sbx exec / sbx cp に渡される。dest / source の両方に適用する。先頭 `-` を弾くのは quote では防げない
# option injection (`-it` / `--help` 等が sbx の flag として解釈される) を断つため
validate_box_name() {
  # "host" は local sentinel と衝突するため box 名として予約 (`host` という box を誤って sentinel 扱い
  # するのを防ぐ)。macOS stock bash 3.2 は ${1,,} 非対応なので tr で小文字化して case-insensitive 比較
  if [[ "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" == "host" ]]; then
    echo "'host' is reserved as the local-machine sentinel; omit <dest> to target the host." >&2
    exit 1
  fi
  if ! [[ "$1" =~ ^[a-zA-Z0-9._+][a-zA-Z0-9._+-]*$ ]]; then
    echo "invalid box name (expected sbx grammar: letters/numbers/dot/plus/dash/underscore): '$1'" >&2
    exit 1
  fi
}

# "host" (小文字) は host sentinel なので box 名 validation を通さない (dest 省略 = host と同義、source = host は
# 「session は host にある」の明示)。'Host' 等の case 変種は validate_box_name 側で reserved として弾かれる
[[ -n "$dest" && "$dest" != "host" ]] && validate_box_name "$dest"
[[ -n "$source_arg" && "$source_arg" != "host" ]] && validate_box_name "$source_arg"

# `timeout` は stock macOS には無く GNU coreutils 依存。利用可能なら sbx exec 応答不能時の hang 防止に使う
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_60=(timeout 60)
else
  TIMEOUT_60=()
fi

# 1 location (box 名 or "host") で transcript path を探す。0 件は空、複数 hit は full UUID 要求で exit 4。
# 出力は単一 path (in-box は /home/agent/...、host は $HOME/...)
find_in_location() {
  local loc="$1" raw
  if [[ "$loc" == "host" ]]; then
    raw=$(ls "$HOME"/.claude/projects/*/"$session_id"*.jsonl 2>/dev/null || true)
  else
    # belt-and-suspenders: session_id を positional arg で渡し sh -c string への splice を回避。
    # sbx exec 自体の失敗 (box 停止/不在) は exit 6 で明示 (set -e 任せだと sbx の生 exit code が漏れ
    # usage の 6=sbx command failure と不一致になる。.ps1 の $LASTEXITCODE チェックと挙動を揃える)
    if ! raw=$(${TIMEOUT_60[@]+"${TIMEOUT_60[@]}"} sbx exec "$loc" sh -c 'ls /home/agent/.claude/projects/*/"$1"*.jsonl 2>/dev/null || true' _ "$session_id"); then
      echo "sbx exec failed for box='${loc}'. Box may be stopped or missing." >&2
      exit 6
    fi
  fi
  local matches=()
  while IFS= read -r p; do
    [[ -n "$p" ]] && matches+=("$p")
  done <<< "$raw"
  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "multiple transcripts match session_id='${session_id}' in '${loc}':" >&2
    printf '  %s\n' "${matches[@]}" >&2
    echo "Pass the full UUID instead." >&2
    exit 4
  fi
  # 0 件は空文字を返す。`[[ ]] && printf` の戻り値 1 が関数末尾で漏れると set -e + $(...) で
  # 呼び出し側が落ちるため、明示 return 0 で「該当無し」を正常終了として返す
  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s' "${matches[0]}"
  fi
  return 0
}

# source location を決める。明示指定があればそこだけ、無ければ running claude box 群 + host を走査して
# transcript を持つ場所を 1 つに確定する (複数 location 該当は source 明示要求で exit 4)
src_loc=""
src_path=""
if [[ -n "$source_arg" ]]; then
  src_loc="$source_arg"
  src_path=$(find_in_location "$src_loc")
  if [[ -z "$src_path" ]]; then
    echo "transcript not found for session_id='${session_id}' in source='${src_loc}'" >&2
    exit 3
  fi
else
  # 走査対象: host + running な claude box (box-session-context.sh と同じ awk 列抽出)。
  # sbx ls 失敗を box 不在と取り違えると host だけ走査して box の transcript を取りこぼすため fail-closed
  locations=("host")
  if ! sbx_ls_out=$(sbx ls 2>/dev/null); then
    echo "sbx ls failed; cannot enumerate running boxes for source auto-detect. Pass <source> explicitly." >&2
    exit 6
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] && locations+=("$name")
  done < <(printf '%s\n' "$sbx_ls_out" | awk 'NR>1 && $2=="claude" && $3=="running" {print $1}')

  hits=()
  for loc in "${locations[@]}"; do
    p=$(find_in_location "$loc")
    if [[ -n "$p" ]]; then
      hits+=("${loc}")
      src_loc="$loc"
      src_path="$p"
    fi
  done

  if [[ ${#hits[@]} -eq 0 ]]; then
    echo "transcript not found for session_id='${session_id}' in host or any running claude box" >&2
    echo "Check: sbx ls / ls \$HOME/.claude/projects/" >&2
    exit 3
  fi
  if [[ ${#hits[@]} -gt 1 ]]; then
    echo "session_id='${session_id}' exists in multiple locations: ${hits[*]}" >&2
    echo "Pass <source> explicitly to disambiguate." >&2
    exit 4
  fi
fi

# 正規 dest を決める (空 = host)
dest_loc="${dest:-host}"

# matched path から full UUID と encoded project dir 名を確定。両 box・host は repo を同一絶対 path に
# bind-mount するので、source 側の実 dir 名 (encoded) を dest でもそのまま使える (エンコード規則は再実装しない)
uuid_file="$(basename "$src_path")"
uuid="${uuid_file%.jsonl}"
encoded="$(basename "$(dirname "$src_path")")"

# source==dest なら transcript は既にそこにある → inject 不要、resume コマンドだけ提示
if [[ "$src_loc" == "$dest_loc" ]]; then
  echo "transcript already present in '${dest_loc}' (source==dest); no copy needed" >&2
  if [[ "$dest_loc" == "host" ]]; then
    echo "claude --resume ${uuid}"
  else
    echo "In box ${dest_loc}: claude --resume ${uuid}"
  fi
  exit 0
fi

# 共有 staging: 全 dev box が bind-mount する main checkout root (= git common dir の親) 直下の .claude/tmp/ を
# 経由して box↔box / box↔host を中継する (sbx 0.33.0 data plane buffer ~4MB の hang を避けるため。bind-mount
# 不成立な clone box / cross-OS は probe して sbx cp に fallback)。$PWD 依存だと worktree / subdir / 絶対パス
# 起動で box_has_mount が外れて fallback に落ちるため、cwd でなく common dir から mount root を解決する
if ! git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  echo "git rev-parse failed; run from inside the repository." >&2
  exit 1
fi
mount_root="$(dirname "$git_common_dir")"
stage_dir="${mount_root}/.claude/tmp"
mkdir -p "$stage_dir"
stage_abs="${stage_dir}/resume-${uuid}.jsonl"
stage_abs_dir="${stage_dir}"

cleanup() { rm -f "$stage_abs" 2>/dev/null || true; }
trap cleanup EXIT

# box が staging dir を同一 path で bind-mount しているか (test -d -a -w)。dev box は true、clone box は false。
# 非 0 は「未 mount」の正常判定なので run_sbx を通さない (失敗 = fallback であり exit 6 ではない)
box_has_mount() {
  ${TIMEOUT_60[@]+"${TIMEOUT_60[@]}"} sbx exec "$1" sh -c 'test -d "$1" -a -w "$1"' _ "$stage_abs_dir" 2>/dev/null
}

# 転送系 sbx 操作の失敗を exit 6 で明示する (set -e 任せだと sbx の生 exit code が漏れ usage の
# 6=sbx command failure と不一致。.ps1 の Invoke-Sbx と挙動を揃える。box_has_mount のような
# 「非 0 が正常判定」の呼び出しはここを通さない)
run_sbx() {
  local what="$1"; shift
  if ! ${TIMEOUT_60[@]+"${TIMEOUT_60[@]}"} sbx "$@"; then
    echo "sbx ${what} failed (box stopped/missing or transfer error): sbx $*" >&2
    exit 6
  fi
}

# --- source → staging ---
if [[ "$src_loc" == "host" ]]; then
  cp "$src_path" "$stage_abs"
elif box_has_mount "$src_loc"; then
  run_sbx "exec cp (source->staging)" exec "$src_loc" cp "$src_path" "$stage_abs"
else
  echo "source box '${src_loc}' does not bind-mount '${stage_abs_dir}' (clone box / cross-OS). falling back to sbx cp (>4MB may hang)" >&2
  run_sbx "cp (source->staging)" cp "${src_loc}:${src_path}" "$stage_abs"
fi

# --- staging → dest の projects dir に <uuid>.jsonl で install ---
if [[ "$dest_loc" == "host" ]]; then
  dest_dir="${HOME}/.claude/projects/${encoded}"
  mkdir -p "$dest_dir"
  cp "$stage_abs" "${dest_dir}/${uuid_file}"
else
  dest_box_dir="/home/agent/.claude/projects/${encoded}"
  if box_has_mount "$dest_loc"; then
    # bind-mount 経由: dest box 内で mkdir + 共有 staging から cp (sbx data plane を bypass)
    run_sbx "exec cp (staging->dest)" exec "$dest_loc" sh -c 'mkdir -p "$1" && cp "$2" "$1/$3"' _ "$dest_box_dir" "$stage_abs" "$uuid_file"
  else
    echo "dest box '${dest_loc}' does not bind-mount '${stage_abs_dir}' (clone box / cross-OS). falling back to sbx cp (>4MB may hang)" >&2
    run_sbx "exec mkdir (dest)" exec "$dest_loc" mkdir -p "$dest_box_dir"
    run_sbx "cp (staging->dest)" cp "$stage_abs" "${dest_loc}:${dest_box_dir}/${uuid_file}"
  fi
fi

# resume コマンドを提示 (interactive claude は script から起動できないため、dest で人/agent が叩く)
if [[ "$dest_loc" == "host" ]]; then
  echo "claude --resume ${uuid}"
else
  echo "In box ${dest_loc}: claude --resume ${uuid}"
fi
