#!/usr/bin/env bash
# host-bridge transport primitives: box↔host の file-based async RPC (.claude/host-bridge/) の
# 「間違えると race になる配管」だけを 1 箇所に集約する。host-ask/host-answer/box-session-resume(-grant)/
# host-fetch(-grant) の各 skill がこれを呼び、req/ans/sentinel の採番・順序・poll 文字列を共有する。
#
# 意図的に含めない: req/ans 本文の Write (agent が Write tool で書く)、Monitor 起動
# (Claude の tool であって shell では起動できない)、SSRF/injection の validation、naming の prefix 決定。
# これらは各 skill 側に残す (transport primitive に限定し leaf の責務を滲ませない)。
#
# sentinel 契約: ans 本体 = <ans-path>、done sentinel = <ans-path>.done で固定。sentinel は ans 本体の
# Write 完了後に別 step で touch する serialization で「sentinel 出現 = 本体完成」を保証する (race-free)。
#
# subcommands:
#   next-seq   <bridge-dir> <req-prefix>   同 prefix の最大 seq +1 を 3 桁ゼロ埋めで返す (無ければ 001)
#   prep-req   <bridge-dir> <ans-path>     bridge-dir を mkdir + 自 seq の stale ans/done を予防削除 (box: req Write 前)
#   prep-ans   <ans-path>                  ans の dir を mkdir + stale done を予防削除 (host: ans 本体 Write 前)
#   finalize   <ans-path>                  <ans-path>.done を touch (host: ans 本体 Write 完了後)
#   poll       <ans-path>                  Monitor に渡す "until done; sleep; cat ans" 文字列を出力

set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage: bash scripts/internal/host-bridge.sh <subcommand> ...
  next-seq <bridge-dir> <req-prefix>
  prep-req <bridge-dir> <ans-path>
  prep-ans <ans-path>
  finalize <ans-path>
  poll     <ans-path>
USAGE
}

# path 引数に改行や NUL が紛れると後段の file 操作が崩れるため軽く弾く (box/topic は上流で validation 済み
# だが、transport は防御的に最低限チェックする)。$() 等の metacharacter は eval しないので path として無害。
reject_bad_path() {
  case "$1" in
    *$'\n'*) echo "host-bridge: newline in path argument is not allowed" >&2; exit 2 ;;
  esac
}

sub="${1:-}"
[[ -z "$sub" ]] && { usage; exit 2; }
shift || true

case "$sub" in
  next-seq)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    dir="$1"; prefix="$2"
    reject_bad_path "$dir"; reject_bad_path "$prefix"
    # anchored [0-9][0-9][0-9] で prefix 衝突 (例: topic "port" の glob が "port-80" を拾う) を回避。
    # <seq> は 3 桁ゼロ埋めなので plain sort の辞書順 = 数値順 (GNU 拡張 sort -V は macOS/BSD 非対応で不使用)。
    last=$(ls "${dir}/${prefix}-"[0-9][0-9][0-9].md 2>/dev/null | sort | tail -1 || true)
    if [[ -z "$last" ]]; then
      printf '001'
    else
      # 末尾 NNN.md から NNN を取り出す。10 進固定 (08/09 が 8 進扱いにならないよう 10# を付ける)
      base="${last##*/}"
      num="${base%.md}"; num="${num##*-}"
      n=$((10#${num} + 1))
      # 999 を超えると 4 桁になり anchored [0-9][0-9][0-9] glob に載らず以降ずっと同じ seq を返す退行になる。
      # bridge は 1 topic あたり少数の逐次 request 前提でここに達しないはずなので、silent wrap でなく loud に落とす。
      if [[ "$n" -gt 999 ]]; then
        echo "host-bridge next-seq: seq exhausted (>999) for prefix '${prefix}'; clean up old bridge files" >&2
        exit 4
      fi
      printf '%03d' "$n"
    fi
    ;;
  prep-req)
    [[ $# -eq 2 ]] || { usage; exit 2; }
    dir="$1"; ans="$2"
    reject_bad_path "$dir"; reject_bad_path "$ans"
    mkdir -p "$dir"
    # 自 seq に対応する stale ans/done を削除 (前回 lifecycle cleanup 漏れや seq 衝突で残った sentinel を
    # poll が即 true 判定して旧 body を cat する race を予防)。-f なので遺物無しは no-op で冪等。
    rm -f "$ans" "${ans}.done"
    ;;
  prep-ans)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    ans="$1"
    reject_bad_path "$ans"
    mkdir -p "$(dirname "$ans")"
    # ans 本体 / 旧 done を消す。ans 本体も消すのは、untrusted box が ans path に host file への symlink を
    # 先回りで仕込んだ場合、後段の Write がそれを追って host file を上書きするのを防ぐため (rm -f は symlink
    # 自身を unlink し target を追わない)。rm→Write 間の再仕込み TOCTOU は残るが trivial な pre-plant は塞ぐ。
    rm -f "$ans" "${ans}.done"
    ;;
  finalize)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    ans="$1"
    reject_bad_path "$ans"
    [[ -f "$ans" ]] || { echo "host-bridge finalize: ans body '$ans' does not exist; write it before finalizing" >&2; exit 3; }
    # sentinel path に box が仕込んだ symlink を追って host file の mtime を触らないよう、touch の前に unlink する。
    rm -f "${ans}.done"
    touch "${ans}.done"
    ;;
  poll)
    [[ $# -eq 1 ]] || { usage; exit 2; }
    ans="$1"
    reject_bad_path "$ans"
    # Monitor(persistent) / Bash(run_in_background) に渡す待受コマンド。done sentinel 出現で 1 度だけ cat。
    # until [ -f X ] は POSIX shell (box image の bash/busybox 両方) で portable。sleep 30 で 30 秒粒度待受。
    # path は single-quote literal で埋め込む (double-quote だと path 内の "/`/$() が生成コマンドを壊す・展開する。
    # single-quote 内は全 metacharacter が不活性なので、空白でも $ でも安全)。埋め込む path 中の ' は '\'' で閉じ直す。
    q_ans=${ans//\'/\'\\\'\'}
    printf "until [ -f '%s.done' ]; do sleep 30; done; cat '%s'" "$q_ans" "$q_ans"
    ;;
  *)
    echo "host-bridge: unknown subcommand '$sub'" >&2
    usage
    exit 2
    ;;
esac
