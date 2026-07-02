#!/usr/bin/env bash
# ADR cloud-unattended-sre.md パターン A の fixer entrypoint（参照実装）。
# CodeBuild/Fargate（修正 identity）が走らせる本体: sanitized triage + 壊れた repo だけを入力に
# claude -p on Bedrock で最小 fix を作り、無人で PR を開く（merge は人間）。spike harness の
# 検証済み起動形（--safe-mode --permission-mode acceptEdits --tools Edit Read Grep --strict-mcp-config）を流用し、
# 「答え合わせ」の代わりに commit→push→gh pr create を行う。AWS/実 repo 部は DRY_RUN で切れる。
#
# 実行前提（fixer-identity-iam.json の権限）: Bedrock invoke / triage 1 件 GET / 自分の GH token / app data read は不可。
# cwd は **修正対象 repo の壊れた状態の checkout**（CodeBuild source）。entrypoint はその場で fix branch を切る。
#
# env:
#   TRIAGE_PATH     sanitized triage JSON のローカルパス（TRIAGE_S3_URI 指定時は不要）
#   TRIAGE_S3_URI   s3://bucket/triage/<incident-id>.json（観測が event で渡す唯一の入力。aws s3 cp で取得）
#   BACKEND         bedrock（既定・本番）/ anthropic（直 key・検証用）
#   AWS_REGION      bedrock 用（既定 us-east-1）
#   ANTHROPIC_MODEL bedrock=inference profile id（既定 us.anthropic.claude-opus-4-8）/ anthropic=直 ID（claude-opus-4-8）
#   FIX_BRANCH      作る fix branch 名（既定 sre-fix/<incident-id|epoch>）
#   PR_BASE         PR の base branch（既定: origin の default branch）
#   DRY_RUN         1 なら diff を出して commit/push/PR をしない（AWS/実 repo 無しの検証用）
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
BACKEND="${BACKEND:-bedrock}"

command -v claude >/dev/null || { echo "ERROR: claude CLI が PATH にありません" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: triage 検証に python3 が必要です" >&2; exit 1; }
# PR を作る経路（非 DRY_RUN）では gh を最初に確認する。高コストな claude -p の後で gh 不在に気づくと、
# branch だけ push されて PR 無しになる。生成だけ見たいなら DRY_RUN=1 で gh 不要。
[ "${DRY_RUN:-}" = 1 ] || command -v gh >/dev/null || { echo "ERROR: gh CLI が無い（PR 作成に必要）。生成のみは DRY_RUN=1。" >&2; exit 1; }
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "ERROR: cwd が git repo ではありません（修正対象 checkout で実行する）" >&2; exit 1; }
# clean な checkout で始める前提を enforce（後段の git add -A が agent の fix だけを拾い、既存 dirty を巻き込まないため）。
[ -z "$(git status --porcelain)" ] || { echo "ERROR: checkout が dirty です（clean な修正対象 checkout で実行する）" >&2; exit 1; }

# triage の取得。S3 指定時のみ aws s3 cp（観測が書いた検証済みオブジェクトを唯一の入力として読む）。
CLEAN_TRIAGE=""
cleanup() { [ -n "$CLEAN_TRIAGE" ] && rm -f "$CLEAN_TRIAGE" 2>/dev/null || true; }
trap cleanup EXIT
if [ -n "${TRIAGE_S3_URI:-}" ]; then
  command -v aws >/dev/null || { echo "ERROR: TRIAGE_S3_URI 指定には aws CLI が必要です" >&2; exit 1; }
  CLEAN_TRIAGE="$(mktemp)"; TRIAGE_PATH="$CLEAN_TRIAGE"
  aws s3 cp "$TRIAGE_S3_URI" "$TRIAGE_PATH" --only-show-errors || { echo "ERROR: triage の S3 取得に失敗: $TRIAGE_S3_URI" >&2; exit 1; }
fi
[ -n "${TRIAGE_PATH:-}" ] && [ -f "$TRIAGE_PATH" ] || { echo "ERROR: TRIAGE_PATH も TRIAGE_S3_URI も有効でない" >&2; exit 1; }

# sanitized handoff の制約を fixer 側でも enforce（size 上限 / 固定 schema / raw log・secret 禁止）。
# spike の検証を踏襲しつつ、無人 cloud 実行の fixer では incident/constraints の nested key も allowlist して
# 想定外フィールドがそのまま prompt に載るのを防ぐ（sanitize gate を spike より一段厳格にする）。検証 NG は処理しない。
TRIAGE_BYTES="$(wc -c < "$TRIAGE_PATH" | tr -d ' ')"
[ "${TRIAGE_BYTES:-0}" -le 8192 ] || { echo "ERROR: triage が大きすぎます (${TRIAGE_BYTES}B > 8192)" >&2; exit 1; }
if grep -qiE -- '-----BEGIN|aws_secret_access_key|PRIVATE KEY' "$TRIAGE_PATH"; then echo "ERROR: triage に secret らしき内容を検出" >&2; exit 1; fi
INCIDENT_ID="$(python3 - "$TRIAGE_PATH" <<'PY'
import json, sys
allowed = {"schema_version", "_note", "incident", "constraints"}
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit("ERROR: triage が valid JSON でない: %s" % e)
if not isinstance(d, dict): sys.exit("ERROR: triage の top-level が object でない")
extra = set(d) - allowed
if extra: sys.exit("ERROR: triage に未知の top-level キー: %s" % sorted(extra))
if "schema_version" not in d: sys.exit("ERROR: triage に schema_version がない")
inc = d.get("incident")
if not isinstance(inc, dict) or "signature" not in inc: sys.exit("ERROR: triage に incident.signature がない")
allowed_incident = {"service", "signature", "http_status", "failing_path", "external_call", "evidence", "first_seen", "count_5xx_window"}
inc_extra = set(inc) - allowed_incident
if inc_extra: sys.exit("ERROR: incident に未知のキー: %s" % sorted(inc_extra))
con = d.get("constraints", {})
if not isinstance(con, dict): sys.exit("ERROR: constraints が object でない")
con_extra = set(con) - {"scope", "no_raw_logs", "no_secrets", "fixer_inputs"}
if con_extra: sys.exit("ERROR: constraints に未知のキー: %s" % sorted(con_extra))
# fix branch / PR 件名用の安定 id。signature ベースだが triage 由来の自由文字列なので、
# [a-z0-9-] 以外を - に畳んで slug 化し、空白/改行/`..`/`:` 等が branch 名や metadata に漏れないようにする
# （`.`/`_` も落とすことで `..` 等の不正 refname を構造的に作らない＝weird signature でも fail せず通す）。
import re as _re
raw = "%s-%s" % (inc.get("service", "svc"), inc.get("signature", ""))
slug = _re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")[:48].strip("-")
print(slug or "incident")
PY
)" || exit 1

FIX_BRANCH="${FIX_BRANCH:-sre-fix/${INCIDENT_ID}}"
# slug 後も FIX_BRANCH override 等を考慮し、git の refname 形式として妥当か最終確認する。
git check-ref-format "refs/heads/$FIX_BRANCH" || { echo "ERROR: FIX_BRANCH が不正な branch 名: $FIX_BRANCH" >&2; exit 1; }

# backend dispatch（spike と同形）。anthropic は user の Bedrock settings 再注入を隔離 config で塞ぐ。
case "$BACKEND" in
  bedrock)
    MODEL="${ANTHROPIC_MODEL:-us.anthropic.claude-opus-4-8}"
    export CLAUDE_CODE_USE_BEDROCK=1; export AWS_REGION="$REGION"; export ANTHROPIC_MODEL="$MODEL"
    ;;
  anthropic)
    [ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "ERROR: BACKEND=anthropic には ANTHROPIC_API_KEY が要ります" >&2; exit 1; }
    MODEL="${ANTHROPIC_MODEL:-claude-opus-4-8}"
    case "$MODEL" in *anthropic.*) echo "ERROR: 直 mode に Bedrock 形式 model ID ($MODEL)。'claude-opus-4-8' 等を指定" >&2; exit 1 ;; esac
    CLAUDE_CONFIG_TMP="$(mktemp -d)"; export CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_TMP"
    trap 'cleanup; rm -rf "$CLAUDE_CONFIG_TMP" 2>/dev/null || true' EXIT
    unset CLAUDE_CODE_USE_BEDROCK; export ANTHROPIC_MODEL="$MODEL"
    ;;
  *) echo "ERROR: BACKEND は bedrock | anthropic（指定: ${BACKEND}）" >&2; exit 1 ;;
esac

git switch -c "$FIX_BRANCH" >/dev/null 2>&1 || git switch "$FIX_BRANCH" >/dev/null

PROMPT="あなたは本番インシデントを最小修正する SRE agent。下記は観測段から渡された sanitized triage（生ログ/secret なし。repo と本 triage だけが入力で、AWS や network には出られない）。triage の failure signature を repo 内で特定し、最小の fix を施せ。無関係な変更・refactor はしない。修正後は変更点を一言で述べよ。
--- triage ---
$(cat "$TRIAGE_PATH")"

# spike で検証済みの起動形をそのまま使う: --safe-mode（hook/customization 自動実行を塞ぐ）+
# --permission-mode acceptEdits（headless で Edit を適用）+ --tools 限定 + --strict-mcp-config。
echo ">> claude -p で fix 生成（backend=${BACKEND}）..."
if ! claude -p "$PROMPT" --tools Edit Read Grep --safe-mode --permission-mode acceptEdits --strict-mcp-config; then
  echo "ERROR: claude -p の実行に失敗（model access / 資格情報を確認）" >&2; exit 1
fi

# 変更検出は untracked も含める（git diff --quiet は新規ファイルを見落とすため stage して --cached で見る）。
# 開始時に clean を確認済みなので、staged = agent の fix だけ。
git add -A
if git diff --cached --quiet; then echo ">> 変更なし（fix 不能 or 既に修正済み）。PR は作らない。"; exit 0; fi

echo; echo "===== fix diff ====="; git --no-pager diff --cached

if [ "${DRY_RUN:-}" = 1 ]; then echo; echo ">> DRY_RUN: commit/push/PR はしない。"; exit 0; fi

# PR の base は明示する（省略すると gh が default branch を暗黙採用し、別 branch に向く事故になりうる）。
# 未指定なら対象 repo の default branch を解決して使う。
PR_BASE="${PR_BASE:-$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)}"
[ -n "$PR_BASE" ] || { echo "ERROR: PR_BASE を解決できません（gh repo view 失敗）。PR_BASE を明示してください。" >&2; exit 1; }

git commit -q -m "fix(sre): ${INCIDENT_ID} の最小修正（無人 SRE agent）"

# 冪等化: 同 incident_id の再 trigger でも新 PR を量産せず、既存 open PR を最新 fix で update する。
# force-with-lease で concurrent fixer run の push を clobber しないよう保護する (生 --force より安全)。
# unattended な CodeBuild 運用で黙って force-with-lease に倒れると原因追跡できないため、stderr を分類してログに残す。
if ! FETCH_ERR="$(git fetch origin "+refs/heads/${FIX_BRANCH}:refs/remotes/origin/${FIX_BRANCH}" 2>&1)"; then
  case "$FETCH_ERR" in
    *"couldn't find remote ref"*)
      echo ">> intended fallback: origin/${FIX_BRANCH} が未作成（初回 run）" >&2
      ;;
    *)
      echo ">> [WARN] git fetch が想定外の理由で失敗:" >&2
      printf '%s\n' "$FETCH_ERR" >&2
      ;;
  esac
fi
if ! PUSH_ERR="$(git push -u origin "$FIX_BRANCH" 2>&1)"; then
  case "$PUSH_ERR" in
    *"non-fast-forward"*)
      echo ">> intended fallback: plain push が non-FF（force-with-lease に倒す）" >&2
      ;;
    *)
      echo ">> [WARN] plain push が想定外の理由で失敗（force-with-lease に倒すが root cause を確認）:" >&2
      printf '%s\n' "$PUSH_ERR" >&2
      ;;
  esac
  git push --force-with-lease -u origin "$FIX_BRANCH"
fi

SHORT_SHA="$(git rev-parse --short HEAD)"
PR_BODY_BASE="観測段の sanitized triage を起点に無人 SRE agent が作成した最小 fix。**merge は人間レビュー後**（承認ゲート）。

incident: \`${INCIDENT_ID}\`
fixer: パターン A（claude -p on Bedrock / 修正 identity・AWS read なし）
head: \`${SHORT_SHA}\`"

# 既存 open PR があれば body 更新 (新規 PR は作らない)。closed PR は無視 (=新規 PR 作成側に倒す)。
# --base に加えて isCrossRepository == false で fork 由来の同名 head PR を排除する
# (gh pr list --head は同 repo / fork を区別しないため post-filter で絞る)。これで PR_BASE 契約 + repo 境界の両方を守る。
EXISTING_PR_NUM="$(gh pr list --head "$FIX_BRANCH" --base "$PR_BASE" --state open --json number,isCrossRepository --jq '[.[] | select(.isCrossRepository == false)][0].number // empty')"
if [ -n "$EXISTING_PR_NUM" ]; then
  echo ">> existing open PR #${EXISTING_PR_NUM} を head=${SHORT_SHA} で superseded note 付きに更新"
  gh pr edit "$EXISTING_PR_NUM" --body "${PR_BODY_BASE}

---
⚠️ 本 PR は新しい fixer run で **force-push 更新** されました。前 commit の fix は最新 head (\`${SHORT_SHA}\`) で superseded されています。"
else
  echo ">> 新規 PR を作成"
  gh pr create --base "$PR_BASE" --title "fix(sre): ${INCIDENT_ID}" --body "$PR_BODY_BASE"
fi
