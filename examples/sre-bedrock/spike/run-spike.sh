#!/usr/bin/env bash
# ADR cloud-unattended-sre.md の核心仮説 spike: claude -p が
# sanitized triage + 壊れた repo だけから妥当な fix を導けるかを、インフラ無しで測る。
# backend は BACKEND=bedrock（既定・本番 auth track）/ BACKEND=anthropic（直 Anthropic key・
# gate を AWS 承認待ちから decouple）の 2 経路。前提は spike/README.md を参照。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# repo root は worktree でも効くよう git に解決させる（committed script は別パス mount でも動く）
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"

TARGET_BRANCH="${TARGET_BRANCH:-stage/06-readings-drift-broken}"
ANSWER_BRANCH="${ANSWER_BRANCH:-stage/07-readings-drift-fixed}"
TRIAGE="${TRIAGE:-$HERE/triage.json}"
REGION="${AWS_REGION:-us-east-1}"
# backend: bedrock（既定）= AWS IAM 課金 / anthropic = 直 Anthropic key（ANTHROPIC_API_KEY 必須）。
# spike が測る「agent が直せるか」は backend 非依存なので、AWS 承認待ちの間も直 key で gate を回せる。
BACKEND="${BACKEND:-bedrock}"
# model 既定は backend で異なる（Bedrock は inference profile ID / 直 key は Anthropic model ID）ので
# backend dispatch 内で解決する。明示の ANTHROPIC_MODEL があれば両 backend ともそれを優先する。

command -v claude >/dev/null || { echo "ERROR: claude CLI が PATH にありません" >&2; exit 1; }
[ -f "$TRIAGE" ] || { echo "ERROR: triage が見つかりません: $TRIAGE" >&2; exit 1; }

# ADR の sanitized handoff 制約（size-limited / 固定 schema / raw log・secret 禁止）を harness 側でも
# enforce する。TRIAGE override で任意ファイルを raw 投入できると ADR の境界の再現が崩れるため。
TRIAGE_BYTES="$(wc -c < "$TRIAGE" | tr -d ' ')"
[ "${TRIAGE_BYTES:-0}" -le 8192 ] || { echo "ERROR: triage が大きすぎます (${TRIAGE_BYTES}B > 8192)。sanitized handoff は size-limited。" >&2; exit 1; }
if grep -qiE -- '-----BEGIN|aws_secret_access_key|PRIVATE KEY' "$TRIAGE"; then echo "ERROR: triage に secret らしき内容を検出 (raw log / secret 禁止)。" >&2; exit 1; fi
# 固定 schema: substring でなく実際に JSON parse して top-level shape を検証する（malformed JSON や
# 余計な payload を弾く）。python3 を必須とし fail fast する（不在時に grep へ degrade すると
# sanitized handoff 境界の確認が緩む）。
command -v python3 >/dev/null 2>&1 || { echo "ERROR: triage の schema 検証に python3 が必要です。" >&2; exit 1; }
python3 - "$TRIAGE" <<'PY' || exit 1
import json, sys
allowed = {"schema_version", "_note", "incident", "constraints"}
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("ERROR: triage が valid JSON でない: %s" % e)
if not isinstance(d, dict):
    sys.exit("ERROR: triage の top-level が object でない")
extra = set(d) - allowed
if extra:
    sys.exit("ERROR: triage に未知の top-level キー: %s" % sorted(extra))
if "schema_version" not in d:
    sys.exit("ERROR: triage に schema_version がない")
inc = d.get("incident")
if not isinstance(inc, dict) or "signature" not in inc:
    sys.exit("ERROR: triage に incident.signature がない")
PY

# backend を検証して model を解決（fail-fast、副作用なし）。env 設定と config 隔離は trap 確立後に行う。
case "$BACKEND" in
  bedrock)
    MODEL="${ANTHROPIC_MODEL:-us.anthropic.claude-opus-4-8}"
    BACKEND_LABEL="Bedrock ($MODEL @ $REGION)"
    FAIL_HINT="Bedrock の model access / AWS 資格情報 / region を確認してください。"
    ;;
  anthropic)
    [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "ERROR: BACKEND=anthropic には ANTHROPIC_API_KEY が要ります。" >&2; exit 1; }
    MODEL="${ANTHROPIC_MODEL:-claude-opus-4-8}"
    # 既存 Bedrock 用に export 済みの ANTHROPIC_MODEL（*.anthropic.* の inference profile ID）が直 API に漏れると
    # invalid model で落ちるため弾く（直 ID は 'claude-opus-4-8' のような形）。
    case "$MODEL" in
      *anthropic.*) echo "ERROR: BACKEND=anthropic に Bedrock 形式の model ID ($MODEL) が渡されています。直 API は 'claude-opus-4-8' のような ID を使います。ANTHROPIC_MODEL を unset するか直 ID を指定してください。" >&2; exit 1 ;;
    esac
    BACKEND_LABEL="Anthropic API ($MODEL)"
    FAIL_HINT="ANTHROPIC_API_KEY / model ID ($MODEL) を確認してください。"
    ;;
  *)
    echo "ERROR: BACKEND は bedrock | anthropic のいずれか（指定: ${BACKEND}）" >&2; exit 1
    ;;
esac

# 壊れた stage を detached worktree に展開（同名 branch の二重 checkout を避けるため detached）。
# clone 直後は stage が local ref に無い（origin/<branch> のみ）ことがあるため commit-ish を解決する。
resolve_ref() {
  # 同名 tag 等を拾わないよう refs/heads → refs/remotes/origin を明示修飾で解決する。
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/heads/$1^{commit}" >/dev/null 2>&1; then printf '%s' "refs/heads/$1"
  elif git -C "$REPO_ROOT" rev-parse --verify --quiet "refs/remotes/origin/$1^{commit}" >/dev/null 2>&1; then printf '%s' "refs/remotes/origin/$1"
  else return 1; fi
}
TARGET_REF="$(resolve_ref "$TARGET_BRANCH")" || { echo "ERROR: $TARGET_BRANCH を local にも origin にも解決できません。clone 直後なら 'bash scripts/internal/setup-worktrees.sh' で stage を展開してください。" >&2; exit 1; }
ANSWER_REF="$(resolve_ref "$ANSWER_BRANCH")" || { echo "ERROR: $ANSWER_BRANCH を local にも origin にも解決できません。" >&2; exit 1; }

WORK="$(mktemp -d)"
CLAUDE_CONFIG_TMP=""
# worktree remove に加え temp dir 自体も消す（add 失敗時に空/部分 dir が残らないよう）。anthropic の隔離 config dir も。
cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$WORK" >/dev/null 2>&1 || true
  rm -rf "$WORK" 2>/dev/null || true
  [ -n "$CLAUDE_CONFIG_TMP" ] && rm -rf "$CLAUDE_CONFIG_TMP" 2>/dev/null || true
}
trap cleanup EXIT
git -C "$REPO_ROOT" worktree add --detach "$WORK" "$TARGET_REF" >/dev/null

PROMPT="あなたは本番インシデントを最小修正する SRE agent。下記は観測段から渡された sanitized triage（生ログ/secret なし。repo と本 triage だけが入力で、AWS や network には出られない）。triage の failure signature を repo 内で特定し、最小の fix を施せ。無関係な変更・refactor はしない。修正後は変更点を一言で述べよ。
--- triage ---
$(cat "$TRIAGE")"

# backend env を設定（trap 確立後）。anthropic は user の Bedrock settings.json が CLAUDE_CODE_USE_BEDROCK を
# 再注入して直 key 経路を Bedrock に戻すのを防ぐため、隔離した空 CLAUDE_CONFIG_DIR で起動する（process env の
# unset だけでは settings.json の env override で覆される既知挙動があるため config 自体を読ませない）。
if [ "$BACKEND" = bedrock ]; then
  # Bedrock バックエンド（subscription/Anthropic key でなく AWS IAM で課金）。
  export CLAUDE_CODE_USE_BEDROCK=1
  export AWS_REGION="$REGION"
  export ANTHROPIC_MODEL="$MODEL"
else
  CLAUDE_CONFIG_TMP="$(mktemp -d)"
  export CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_TMP"
  unset CLAUDE_CODE_USE_BEDROCK
  export ANTHROPIC_MODEL="$MODEL"
fi

echo ">> claude -p on $BACKEND_LABEL を $TARGET_BRANCH に対して実行..."
# --tools で利用可能ツールを Edit/Read/Grep に限定（--allowedTools は auto-approve のみで制限にならない）。
# --permission-mode acceptEdits: headless -p は Edit が承認待ちで適用されず agent が直せても fix が落ちるため自動承認する。
# --safe-mode: ただし自動承認下では 環境の Edit/Write hook（Bash を --tools から外しても hook 経由で shell が走りうる）や
# settings の additionalDirectories で worktree 外へ手が伸びうるので、hooks/plugins/customizations を読ませず塞ぐ
# （auth/model/permission は通常どおり効く）。sandbox は --tools + safe-mode + worktree 隔離で担保。
# --strict-mcp-config で project の MCP を読まない（egress 面を増やさない）。AWS/network には出さない意図。
if ! ( cd "$WORK" && claude -p "$PROMPT" --tools Edit Read Grep --safe-mode --permission-mode acceptEdits --strict-mcp-config ); then
  echo "ERROR: claude -p の実行に失敗。$FAIL_HINT" >&2
  exit 1
fi

echo
echo "===== agent の fix diff ====="
AGENT_DIFF="$(git -C "$WORK" diff)"
echo "${AGENT_DIFF:-（変更なし）}"

# 答え合わせ: 既知 fix（TARGET..ANSWER）が触るファイルと突き合わせる。
ANSWER_FILES="$(git -C "$REPO_ROOT" diff --name-only "$TARGET_REF" "$ANSWER_REF")"
AGENT_FILES="$(git -C "$WORK" diff --name-only)"

echo
echo "===== 答え合わせ（目安・最終判定は人間） ====="
echo "既知 fix が触るファイル:"; echo "$ANSWER_FILES" | sed 's/^/  /'
echo "agent が触ったファイル:"; echo "${AGENT_FILES:-  （なし）}" | sed 's/^/  /'

# 既知 fix ファイルを agent が全て触ったか（網羅）。
files_match=1
while IFS= read -r f; do
  [ -z "$f" ] && continue
  printf '%s\n' "$AGENT_FILES" | grep -qxF "$f" || files_match=0
done <<EOF
$ANSWER_FILES
EOF

# agent が既知 fix 外のファイルを触っていないか（最小性。subset 判定だけだと過剰修正を見逃すため）。
extra_files=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  printf '%s\n' "$ANSWER_FILES" | grep -qxF "$f" || extra_files="$extra_files $f"
done <<EOF
$AGENT_FILES
EOF

# 本バグの fix キーは readings を data でラップする形（data.readings）への是正。
if printf '%s' "$AGENT_DIFF" | grep -q 'data\.readings\|data:'; then key_found=1; else key_found=0; fi

echo
echo "既知 fix ファイル網羅: $([ "$files_match" = 1 ] && echo OK || echo NG)"
echo "最小性(余計な変更なし): $([ -z "$extra_files" ] && echo "OK" || echo "NG (余計:${extra_files} )")"
echo "fix キー(data.readings 系)検出: $([ "$key_found" = 1 ] && echo 検出 || echo 未検出)"
echo
echo "※ 既知 fix と読み比べて最終判定すること:"
echo "   git diff $TARGET_REF $ANSWER_REF"
