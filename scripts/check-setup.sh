#!/usr/bin/env bash
# README §1 の setup (sbx CLI / Docker / secret / image / stage worktree) が完了しているか確認する。
# 受講者が clone 直後に `bash scripts/check-setup.sh` を叩いて、足りない物だけが残るようにするための doctor。
#
# 確認層:
#   - 存在チェック (即時): secret が登録されているか / image が load されているか 等
#   - 有効性チェック (runtime probe): ephemeral box を起動して中で `gh auth status` を実行し、
#     github PAT が実際に valid か (expired / revoke されていないか) を確認する。
#     `--quick` で skip 可能。anthropic OAuth は probe に API credit を消費するため runtime probe には含めない
#     (workshop 開始時に `bash scripts/dev.sh` を叩いた時点で実機検証される)。
# 失敗があれば非ゼロ exit + 個別の対処案内を出す。
set -uo pipefail

OK=0
NG=0
WARN=0

ok()   { printf '  \033[32mOK\033[0m   %s\n' "$1"; OK=$((OK + 1)); }
ng()   { printf '  \033[31mNG\033[0m   %s\n      -> %s\n' "$1" "$2"; NG=$((NG + 1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n      -> %s\n' "$1" "$2"; WARN=$((WARN + 1)); }

# git check は cd より前に行う (cd は git rev-parse に依存するため、git 不在/古いと
# install/upgrade hint を出さずに exit する経路を塞ぐ)。NG 時は意図された hint を
# 表示してから early exit。
echo "Setup check (README §1):"
echo

# 0. git v2.48+ (README §1 で要件: git worktree add --relative-paths を使うため。未満だと setup-worktrees が機能せず stage worktree が作れない)
if command -v git >/dev/null 2>&1; then
  # `git --version` は `git version 2.48.1 (Apple Git-...)` / `git version 2.40.1` を返す。括弧以降を切って major.minor.patch を抽出
  git_ver=$(git --version 2>/dev/null | awk '{print $3}' | awk -F. '{print $1"."$2"."($3+0)}')
  if [ -z "$git_ver" ]; then
    ng "git version 取得失敗" "'git --version' の出力形式が想定外"
    echo
    printf '\033[31m1 failed\033[0m, 0 warn, 0 ok. subsequent checks depend on git, aborting\n'
    exit 1
  elif awk -v cur="$git_ver" -v req="2.48.0" 'BEGIN { split(cur, c, "."); split(req, r, "."); for (i = 1; i <= 3; i++) { ci = c[i] + 0; ri = r[i] + 0; if (ci > ri) exit 0; if (ci < ri) exit 1 } exit 0 }'; then
    ok "git v$git_ver (>= 2.48)"
  else
    ng "git v$git_ver (>= 2.48 が必要)" "git を upgrade してください (README §1 の要件、git worktree add --relative-paths を使用)"
    echo
    printf '\033[31m1 failed\033[0m, 0 warn, 0 ok. subsequent checks depend on git 2.48+, aborting\n'
    exit 1
  fi
else
  ng "git CLI が PATH に無い" "git 2.48+ を install してください (README §1 の要件)"
  echo
  printf '\033[31m1 failed\033[0m, 0 warn, 0 ok. subsequent checks depend on git, aborting\n'
  exit 1
fi

# git OK が確定したので cd で project root に移動 (worktree 配下からの呼出も main checkout root を base にする)
cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")" || exit 1

QUICK=0
case "${1:-}" in
  --quick) QUICK=1 ;;
  "") ;;
  -h|--help)
    cat <<'EOF'
Usage: bash scripts/check-setup.sh [--quick]

README §1 setup の存在チェック + runtime probe (ephemeral box で gh auth status を実行) を行う。

  --quick   ephemeral box を起こさず存在チェックのみ (~1s。auth が valid かは不明)
EOF
    exit 0 ;;
  *)
    echo "error: unknown arg '$1' (try --help)" >&2; exit 2 ;;
esac

# 1. sbx CLI が PATH にあるか + v0.31+ (--clone は v0.31 で導入)
if command -v sbx >/dev/null 2>&1; then
  # `sbx version` は `sbx version: v0.33.0 <commit>` を返す
  ver=$(sbx version 2>/dev/null | awk '{print $3}' | sed 's/^v//')
  if [ -z "$ver" ]; then
    ng "sbx CLI version 取得失敗" "'sbx version' の出力形式が想定外: $(sbx version 2>&1 | head -1)"
  elif awk -v cur="$ver" -v req="0.31.0" 'BEGIN { split(cur, c, "."); split(req, r, "."); for (i = 1; i <= 3; i++) { ci = c[i] + 0; ri = r[i] + 0; if (ci > ri) exit 0; if (ci < ri) exit 1 } exit 0 }'; then
    ok "sbx CLI v$ver (>= 0.31)"
    # サブスクの「最初の box で /login → 以降自動 provision」は v0.34.0+ のみ (v0.33 以前は box ごと /login か API key 経路 — README §1)
    if ! awk -v cur="$ver" -v req="0.34.0" 'BEGIN { split(cur, c, "."); split(req, r, "."); for (i = 1; i <= 3; i++) { ci = c[i] + 0; ri = r[i] + 0; if (ci > ri) exit 0; if (ci < ri) exit 1 } exit 0 }'; then
      warn "sbx v$ver はサブスク /login の自動 provision (v0.34.0+) 非対応" "box ごとに /login するか API key 経路にする (README §1)。v0.34.0+ への upgrade 推奨"
    fi
  else
    ng "sbx CLI v$ver (>= 0.31 が必要)" "sbx を upgrade してください: https://docs.docker.com/ai/sandboxes/"
  fi
else
  ng "sbx CLI が PATH に無い" "README §1-1 を参照して Docker Desktop の Sandboxes (sbx) を install してください"
fi

# 2. Docker daemon 動作中 (sbx は docker daemon に依存)
if docker info >/dev/null 2>&1; then
  ok "Docker daemon"
else
  ng "Docker daemon に接続できない" "Docker Desktop を起動してください (sbx は docker daemon を使う)"
fi

# secret list は sbx version によって column 構成が変わりうる (旧: SCOPE SERVICE SECRET / 新: SCOPE TYPE NAME SECRET) ため、
# scope == "(global)" 行で name field を hard-code せず全 column から探す。1 回だけ取得してキャッシュ。
SECRETS=$(sbx secret ls -g 2>/dev/null)
has_secret() {
  printf '%s\n' "$SECRETS" | awk -v target="$1" 'NR > 1 && $1 == "(global)" { for (i = 2; i <= NF; i++) if ($i == target) { found = 1; exit } } END { exit !found }'
}
# SECRET 列が "(oauth configured)" の行は /login seeding / --oauth 由来 (API key / setup-token 登録はマスク表示になる)
secret_is_oauth() {
  printf '%s\n' "$SECRETS" | awk -v target="$1" 'NR > 1 && $1 == "(global)" && index($0, "(oauth configured)") { for (i = 2; i <= NF; i++) if ($i == target) { found = 1; exit } } END { exit !found }'
}

# 3. anthropic secret (global): サブスク (Pro/Max) は未登録が正 (最初の box で /login すれば v0.34.0 で自動 provision)。
#    登録が要るのは API 課金経路のみで、サブスクで setup-token を登録すると apikey mode 化で claude -p が壊れる (docs/guide/setup.md「認証 secret の詳細」)
if secret_is_oauth anthropic; then
  ok "sbx secret 'anthropic' (global) は oauth configured (/login seeding 済み。sbx secret rm しないこと — 既存 box の認証が壊れる)"
elif has_secret anthropic; then
  warn "sbx secret 'anthropic' (global) に API key / setup-token 型が登録済 — API key 経路なら OK" "サブスク (Pro/Max) の場合は apikey mode 化で 'claude -p' が壊れる: sbx secret rm -g anthropic して box を作り直し、最初の box で /login (要 sbx v0.34.0+。docs/guide/setup.md)"
else
  ok "sbx secret 'anthropic' (global) 未登録 (サブスクは最初の box で /login — 自動 provision は sbx v0.34.0+。API 課金なら sbx secret set -g anthropic に API key)"
fi

# 4. github secret (global) 登録済み (有効性は §8 の runtime probe で検証)
if has_secret github; then
  ok "sbx secret 'github' (global) 登録済"
  GITHUB_SECRET_PRESENT=1
else
  ng "sbx secret 'github' (global) 未登録" "https://github.com/settings/personal-access-tokens/new で fine-grained PAT を発行し sbx secret set -g github (README §1-2)"
  GITHUB_SECRET_PRESENT=0
fi

# 5. openai secret (global) 登録済み (codex review = /a2a-review / /pr-codex-ci で必要)
if has_secret openai; then
  ok "sbx secret 'openai' (global) 登録済 (cdx-<NAME> pair reviewer box で codex CLI が使用。secret rotate 時は bash scripts/dev.sh 再起動で auto-provision されます)"
else
  ng "sbx secret 'openai' (global) 未登録" "sbx secret set -g openai --oauth で ChatGPT サブスク認証 (README §1-2)"
fi

# 6. image template が取り込み済み + sbx/Dockerfile との整合 + build age (sbx version によって REPOSITORY 列が docker.io/library/<name> か <name> 単体になる差分を吸収)
if sbx template ls 2>/dev/null | awk 'NR > 1 && ($1 == "docker.io/library/coding-agent-playbook-sbx" || $1 == "coding-agent-playbook-sbx") { found=1 } END { exit !found }'; then
  IMAGE_PRESENT=1
  # A/B: staleness + build age を build-image.sh が書くスタンプ 1 ファイルで判定 (1 行目 commit / 2 行目 build 時刻)。
  # docker inspect (local image) は sbx template store と乖離しうる (load 失敗時に local image だけ新しくなる) ため使わない。
  _img_commit=$(sed -n '1p' .claude/tmp/sbx-template-commit.stamp 2>/dev/null || true)
  _df_commit=$(git log --format=%H -n1 -- sbx/Dockerfile 2>/dev/null || true)
  if [ -z "$_img_commit" ]; then
    warn "image template は存在するが staleness スタンプが無い (本機能導入前の古い build)" "bash scripts/build-image.sh で rebuild してください"
  elif [ -n "$_df_commit" ] && [ "$_img_commit" != "$_df_commit" ]; then
    warn "image template の sbx/Dockerfile が更新されています (image が古い、${_df_commit:0:7} != ${_img_commit:0:7})" "bash scripts/build-image.sh で rebuild してください"
  else
    ok "image template 'coding-agent-playbook-sbx' loaded (sbx/Dockerfile: ${_df_commit:0:7})"
  fi
  # B: build age — 30 日以上経過していたら claude / codex の update を促す (スタンプ 2 行目)。
  #    date -d は Linux、date -j -f は macOS (BSD date)。どちらも失敗したら age check を skip。
  _build_time=$(sed -n '2p' .claude/tmp/sbx-template-commit.stamp 2>/dev/null || true)
  if [ -n "$_build_time" ]; then
    _build_epoch=$(date -d "$_build_time" "+%s" 2>/dev/null \
      || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$_build_time" "+%s" 2>/dev/null \
      || true)
    if [ -n "$_build_epoch" ]; then
      _age_days=$(( ($(date +%s) - _build_epoch) / 86400 ))
      if [ "$_age_days" -ge 30 ]; then
        warn "image が ${_age_days} 日前のビルドです (claude / codex が古い可能性)" "bash scripts/build-image.sh で rebuild してください (claude / codex を最新版に更新します)"
      fi
    fi
  fi
else
  ng "image template 'coding-agent-playbook-sbx' 未取込" "bash scripts/build-image.sh で build + load (README §1-1)"
  IMAGE_PRESENT=0
fi

# 7. per-NAME pair reviewer boxes (cdx-*): debate 2026-06-27 以降は singleton cdx-review を廃止し
#    bind-mount dev.sh の起動ごとに cdx-<NAME> が auto-provision される。check-setup では「pair-setup が動く前提条件」(openai secret + image)
#    までを検証し、特定の cdx-<NAME> 存在は判定しない (受講者の作業 box 名を doctor は知らない)。
#    既存の cdx-* box は info としてリスト表示するだけにする (orphan か running 判定は dev.sh trap に任せる)。
existing_cdx=$(sbx ls -q 2>/dev/null | grep -E '^cdx-' || true)
if [ -n "$existing_cdx" ]; then
  count=$(printf '%s\n' "$existing_cdx" | wc -l | tr -d ' ')
  ok "cdx-* reviewer boxes 既存 ($count 件): $(printf '%s\n' "$existing_cdx" | tr '\n' ' ')"
else
  ok "cdx-* reviewer boxes 未作成 (bash scripts/dev.sh 初回起動時に cdx-<NAME> として auto-provision されます)"
fi

# 8. stage/* branches 取得済み (warn 扱い: 任意。stage を使う時に必要。git switch stage/NN で開ける)
count=$(git for-each-ref --format='x' 'refs/heads/stage/' 'refs/remotes/origin/stage/' | wc -l | tr -d ' ')
if [ "${count:-0}" -gt 0 ]; then
  ok "stage branches available ($count ref(s))"
else
  warn "stage/* branches が見つからない" "git fetch origin で取得 (fork の場合は 'Copy the main branch only' を外して全ブランチごと fork)"
fi

# 9. runtime probe (ephemeral box の中で repo-scoped API call を実行して github PAT 有効性を verify)
#    skip 条件: --quick / 前提 (image + github secret) のいずれかが NG / Docker NG
if [ "$QUICK" = 1 ]; then
  :
elif [ "$IMAGE_PRESENT" = 1 ] && [ "$GITHUB_SECRET_PRESENT" = 1 ]; then
  echo
  echo "Runtime probe (ephemeral box で auth chain を検証。--quick で skip 可):"
  # gh auth status は account 認証 state のみ判定し PAT の repository access / scope 不足 (Pull requests RW 等) を検出できない。
  # gh pr list <slug> --limit 1 は (a) PAT 認証 (b) Repository access に対象 repo を含む (c) Pull requests scope を持つ、を 1 回で verify する。
  # slug は host gh ではなく git remote から抽出する (README §1 は host 側に gh CLI を要求しない契約)。
  remote_url=$(git remote get-url origin 2>/dev/null)
  repo_slug=$(printf '%s' "$remote_url" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
  if [ -z "$repo_slug" ] || ! printf '%s' "$repo_slug" | grep -Eq '^[^/]+/[^/]+$'; then
    ng "対象 repo slug 取得失敗 (git remote get-url origin が GitHub URL を返さない)" "現 cwd が github.com origin 紐付きの git repo であることを確認 (取得値: '$remote_url')"
  else
    probe_box="check-setup-$(printf '%06x' $((((RANDOM * 32768 + RANDOM) ^ $$) & 0xffffff)))"
    echo "  starting ephemeral box '$probe_box' (~15s)..."
    # workshop の dev.sh と同じ agent + image + kit で起こす (built-in claude agent の時だけ sbx の secret proxy 注入が確実に effect する、sbx/README.md 「なぜ built-in claude agent + codex mixin か」参照。shell agent で probe しても実機では pass しうるが、agent type 違いで proxy 動作が変わる env では偽 OK / 偽 NG リスク)
    if sbx create --clone claude . --name "$probe_box" -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit >/dev/null 2>&1; then
      # cleanup は trap で EXIT に bind。`set -e` ではないので途中 fail でも到達する。
      trap 'sbx rm -f "'"$probe_box"'" >/dev/null 2>&1 || true' EXIT
      # (a) Pull requests RO + Repository access (gh pr create が後で書き込み権限 fail することは destructive probe 無しでは検出不能なので RO で代替し、workshop 序盤の gh pr create での発覚を許容)
      if sbx exec "$probe_box" gh pr list -R "$repo_slug" --limit 1 >/dev/null 2>&1; then
        # (b) Actions RO (/pr-codex-ci の gh pr checks 経路で必須。docs/guide/setup.md が明示要求)
        if sbx exec "$probe_box" gh api "repos/$repo_slug/actions/runs?per_page=1" >/dev/null 2>&1; then
          ok "github PAT が valid ($repo_slug の Pull requests RO + Actions RO + Repository access OK)"
        else
          err=$(sbx exec "$probe_box" gh api "repos/$repo_slug/actions/runs?per_page=1" 2>&1 | tail -3 | tr '\n' ' ' | sed 's/  */ /g')
          ng "github PAT の Actions: Read-only scope 不足 (/pr-codex-ci の gh pr checks で fail する)" "PAT permissions に Actions: Read-only を追加 (docs/guide/setup.md)。詳細: $err"
        fi
      else
        err=$(sbx exec "$probe_box" gh pr list -R "$repo_slug" --limit 1 2>&1 | tail -3 | tr '\n' ' ' | sed 's/  */ /g')
        ng "github PAT 認証失敗 (expired / revoke / Repository access に '$repo_slug' 未指定 / Pull requests scope 不足の疑い)" "PAT を再発行して sbx secret set -g github で登録し直す (詳細: $err)"
      fi
    else
      ng "ephemeral box の起動失敗" "sbx create --clone claude . --name $probe_box -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit が失敗。image / kit が壊れているか docker daemon に問題"
    fi
  fi
fi

# 10. a2a-doctor (per-NAME pair reviewer serve の死活: lease file + TCP probe)
#     /pr-codex-ci が chain 末尾で初めて reviewer 未到達に気づくのを避けるため、session 開始時に doctor を回せるようにする。
#     skip 条件: --quick (host TCP は network 依存で時間がかかりうるため明示 skip 可)
#     per-NAME pair lease は `.claude/tmp/cdx-serve-<NAME>.lease` 形式 (dev.sh が起動した bg pair-serve が書く)。
#     statusline は file stat のみで hot path を汚さず、本 doctor / /pr-codex-ci preflight が readiness 担保 = TCP probe を行う (役割分担)。
if [ "$QUICK" = 1 ]; then
  :
else
  echo
  echo "a2a-doctor (per-NAME pair reviewer 死活。--quick で skip 可):"
  probe_serve_tcp() {
    # /dev/tcp は bash 組込で外部依存ゼロ + cross-platform (Git Bash も対応)、nc 非依存
    (exec 3<>/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1 && exec 3>&- 3<&-
  }
  lease_count=0
  for lease in .claude/tmp/cdx-serve-*.lease; do
    [ -f "$lease" ] || continue
    lease_count=$((lease_count + 1))
    # jq は README §1 host 必須に含まれないため lease parse は grep/sed で済ませる。colon 周辺 whitespace を許容 (.ps1 の ConvertFrom-Json と挙動を揃える)。
    cdx_pid=$(grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' "$lease" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    cdx_lease_st=$(grep -oE '"start_time"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null | head -1 | sed -E 's/^"start_time"[[:space:]]*:[[:space:]]*"//;s/"$//')
    cdx_lease_kind=$(grep -oE '"start_time_kind"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null | head -1 | sed -E 's/^"start_time_kind"[[:space:]]*:[[:space:]]*"//;s/"$//')
    cdx_port=$(grep -oE '"port"[[:space:]]*:[[:space:]]*[0-9]+' "$lease" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    cdx_claude_box=$(grep -oE '"claude_box"[[:space:]]*:[[:space:]]*"[^"]*"' "$lease" 2>/dev/null | head -1 | sed -E 's/^"claude_box"[[:space:]]*:[[:space:]]*"//;s/"$//')
    if [ -n "$cdx_pid" ] && kill -0 "$cdx_pid" 2>/dev/null; then
      # PID alive: verify start_time to detect PID reuse (kill -0 succeeds for recycled PIDs).
      # bash/PowerShell で start_time format が異なるため kind が現 host と一致する時だけ比較 (不一致は pid-only に倒す)。
      _pid_reused=0
      if [ -n "$cdx_lease_st" ]; then
        if [ -r "/proc/$cdx_pid/stat" ]; then _cur_kind=proc; else _cur_kind=lstart; fi
        if [ "$cdx_lease_kind" = "$_cur_kind" ]; then
          if [ "$_cur_kind" = proc ]; then
            _cur_st=$(awk '{print $22}' "/proc/$cdx_pid/stat" 2>/dev/null || true)
          else
            _cur_st=$(ps -o lstart= -p "$cdx_pid" 2>/dev/null | tr -s ' ' | sed 's/^ *//' || true)
          fi
          if [ -n "$_cur_st" ] && [ "$_cur_st" != "$cdx_lease_st" ]; then
            _pid_reused=1
          fi
        fi
      fi
      if [ "$_pid_reused" = 1 ]; then
        ng "lease の PID が再利用されています (claude_box='$cdx_claude_box', pid=${cdx_pid}、pair-serve は dead)" "rm $lease してから host で bash scripts/dev.sh $cdx_claude_box を再起動"
      elif probe_serve_tcp "$cdx_port"; then
        ok "pair reviewer up (claude_box='$cdx_claude_box', pid=$cdx_pid, port=$cdx_port)"
      else
        ng "lease は alive (claude_box='$cdx_claude_box', pid=$cdx_pid) だが TCP $cdx_port が応答しない (serve 起動中 / port 競合 / proxy ブロックの疑い)" "host で bash scripts/dev.sh $cdx_claude_box を再起動 (pair-serve が再 fork されます)"
      fi
    else
      ng "lease は残っているが PID alive 不能 (claude_box='$cdx_claude_box'、dev.sh が異常終了し trap が走らなかった可能性)" "rm $lease してから host で bash scripts/dev.sh $cdx_claude_box を再起動"
    fi
  done
  if [ "$lease_count" = 0 ]; then
    warn "per-NAME pair reviewer 未起動 (lease 不在)" "/pr-codex-ci / /a2a-review を box 内から使う場合は host で bash scripts/dev.sh を起動 (dev.sh が cdx-<NAME> pair を auto-provision + pair-serve を bg fork します)"
  fi
fi

echo
if [ "$NG" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  printf '\033[32mAll checks passed\033[0m (%d ok). README §2 へ進めます (bash scripts/dev.sh)\n' "$OK"
  exit 0
elif [ "$NG" -eq 0 ]; then
  printf '\033[32m%d ok\033[0m, \033[33m%d warn\033[0m. workshop main flow は OK (WARN は optional)\n' "$OK" "$WARN"
  exit 0
else
  printf '\033[31m%d failed\033[0m, \033[33m%d warn\033[0m, %d ok. NG の対処案内に従って再実行してください\n' "$NG" "$WARN" "$OK"
  exit 1
fi
