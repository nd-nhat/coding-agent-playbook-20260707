#!/usr/bin/env bash
# host 側ヘルパー: sbx box 内の Claude Code session transcript を host にコピーして
# context として参照可能にする (box-primary 運用の HOTL 監視用)。

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/internal/box-session-context.sh <session_id> [<box_name>]
  session_id: UUID or 8+ hex short prefix
  box_name:   sbx box name (running). omit -> auto-detect when exactly one running claude box exists
exit codes:
  0=success, 1=arg error, 2=sbx not found,
  3=transcript not found, 4=ambiguous (full UUID needed),
  5=running inside an sbx box (this skill is host-only),
  6=sbx command failure (.ps1 only; .sh は set -e で sbx exit code をそのまま伝播)
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
  exit 1
fi

session_id="$1"
box="${2:-}"

# UUID hex / dash 以外を弾く: $session_id は後段で box 内 bash -lc の string に挿入されるため
if ! [[ "$session_id" =~ ^[a-fA-F0-9-]{8,36}$ ]]; then
  echo "invalid session_id (expected UUID or 8+ hex prefix): '${session_id}'" >&2
  exit 1
fi

# host-only guard: $SANDBOX_VM_ID は box 内のみ set される asymmetry を使い、box 内 Claude が
# 汎用 `sbx not found` 経由で install 迂回に走るのを止めるため明示メッセージで fail する
if [[ -n "${SANDBOX_VM_ID:-}" ]]; then
  cat >&2 <<EOF
This skill is host-only but \$SANDBOX_VM_ID=${SANDBOX_VM_ID} is set, indicating you are inside an sbx box.
- To inspect THIS session's transcript from inside the box, use the user-scope /session-context skill.
- To inspect ANOTHER box's transcript, exit this box and run from the host.
EOF
  exit 5
fi

if ! command -v sbx >/dev/null 2>&1; then
  echo "sbx command not found. Install Docker Sandboxes first." >&2
  exit 2
fi

# box_name 省略時の auto-detect: running claude box が exactly 1 個なら採用、0 / 複数なら明示要求 error
# (誤検出を避けるため strict に 1 個ヒット要件)
if [[ -z "$box" ]]; then
  candidates=()
  # macOS stock Bash 3.2 は mapfile を持たないため while-read で互換実装
  while IFS= read -r name; do
    [[ -n "$name" ]] && candidates+=("$name")
  done < <(sbx ls 2>/dev/null | awk 'NR>1 && $2=="claude" && $3=="running" {print $1}')
  case "${#candidates[@]}" in
    0)
      echo "no running claude box found. Specify <box_name> explicitly (check 'sbx ls')" >&2
      exit 1
      ;;
    1)
      box="${candidates[0]}"
      echo "auto-detected box='${box}' (running claude agent box is exactly one)" >&2
      ;;
    *)
      echo "multiple running claude boxes (${candidates[*]}). Specify <box_name> explicitly" >&2
      exit 1
      ;;
  esac
fi

# sbx 公式 box 名規約 (letters/numbers/hyphens/periods/plus signs/underscores) 以外を弾く: $box は sbx exec / sbx cp に渡される
if ! [[ "$box" =~ ^[a-zA-Z0-9._+-]+$ ]]; then
  echo "invalid box_name (expected sbx name grammar: letters/numbers/dot/plus/dash/underscore): '${box}'" >&2
  exit 1
fi

short="${session_id:0:8}"

# `timeout` は stock macOS には無く GNU coreutils 依存。利用可能なら hang 防止に使い、無ければ素のまま実行
# (workshop 既定環境では coreutils 想定だが、bare macOS の受講者がこのスクリプトを叩いて即死しないため)
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_60=(timeout 60)
else
  TIMEOUT_60=()
fi

# belt-and-suspenders: session_id を positional arg で渡し sh -c string への splice を回避
# (`sh -c` は login profile skip で box 起動 overhead 削減、`timeout` は sbx exec 応答不能時の hang 防止)
matched=$(${TIMEOUT_60[@]+"${TIMEOUT_60[@]}"} sbx exec "$box" sh -c 'ls /home/agent/.claude/projects/*/"$1"*.jsonl 2>/dev/null || true' _ "$session_id")

if [[ -z "$matched" ]]; then
  echo "transcript not found for session_id='${session_id}' in box='${box}'" >&2
  echo "Try: sbx exec ${box} ls /home/agent/.claude/projects/" >&2
  exit 3
fi

# macOS の stock Bash 3.2 は mapfile/readarray を持たないため while-read で互換実装する
filtered=()
while IFS= read -r p; do
  [[ -n "$p" ]] && filtered+=("$p")
done <<< "$matched"

count=${#filtered[@]}

if [[ $count -gt 1 ]]; then
  echo "multiple transcripts match session_id='${session_id}' in box='${box}':" >&2
  printf '  %s\n' "${filtered[@]}" >&2
  echo "Pass the full UUID instead." >&2
  exit 4
fi

src_path="${filtered[0]}"

dest_dir=".claude/tmp"
mkdir -p "$dest_dir"
dest_path="${dest_dir}/box-session-${short}.jsonl"

# sbx 0.33.0 の data plane buffer (~4MB) で `sbx cp` / `sbx exec ... cat > host_file` が hang する
# (live append 中の jsonl だけでなく静的 snapshot でも再現)。bind-mount dev box (scripts/dev.sh 起動) なら
# box 内 cp で host と同一絶対 path に書けば sbx data plane を完全に bypass できる。clone box (dev.sh sandbox の
# `--clone .`、host checkout 非 mount) と Windows host (host path 形式が box の Linux path と非互換) では
# bind が成立しないため、probe (`test -d -a -w`) で判定して fallback に sbx cp を使う (clone box は通常
# 小さい transcript で sbx cp の ~4MB hang を踏みにくく、踏んだ場合のみ既存の hang を引き継ぐ trade-off)
abs_dest="${PWD}/${dest_path}"
abs_dest_dir="${PWD}/${dest_dir}"
if ${TIMEOUT_60[@]+"${TIMEOUT_60[@]}"} sbx exec "$box" sh -c 'test -d "$1" -a -w "$1"' _ "$abs_dest_dir" 2>/dev/null; then
  ${TIMEOUT_60[@]+"${TIMEOUT_60[@]}"} sbx exec "$box" cp "$src_path" "$abs_dest"
else
  echo "box='${box}' does not bind-mount '${abs_dest_dir}' (clone box / cross-OS host path)。sbx cp に fallback (>4MB file は data plane buffer で hang する可能性あり)" >&2
  sbx cp "${box}:${src_path}" "$dest_path"
fi

echo "$dest_path"
