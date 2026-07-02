#!/usr/bin/env bash
# Pattern B bridge (CodeBuild が EventBridge から起動): AgentCore Runtime を呼んで triage から fix PR を作る。git/push/PR は idempotent (PR-B 移植)。
set -euo pipefail

: "${TRIAGE_BUCKET:?TRIAGE_BUCKET 未設定}"
: "${TRIAGE_S3_KEY:?TRIAGE_S3_KEY 未設定 (EventBridge override)}"
: "${AGENT_RUNTIME_ARN:?AGENT_RUNTIME_ARN 未設定}"
: "${TARGET_REPO:?TARGET_REPO 未設定}"
: "${TARGET_BRANCH:?TARGET_BRANCH 未設定}"
: "${PR_BASE:?PR_BASE 未設定}"

aws s3 cp "s3://$TRIAGE_BUCKET/$TRIAGE_S3_KEY" /tmp/triage.json --only-show-errors
TRIAGE_BYTES=$(wc -c </tmp/triage.json | tr -d ' ')
[ "$TRIAGE_BYTES" -le 8192 ] || { echo "ERROR: triage が大きすぎます (${TRIAGE_BYTES}B > 8192)" >&2; exit 1; }
if grep -qiE -- '-----BEGIN|aws_secret_access_key|PRIVATE KEY' /tmp/triage.json; then
  echo "ERROR: triage に secret らしき内容を検出" >&2; exit 1
fi
INCIDENT_ID=$(python3 - /tmp/triage.json <<'PY'
import json, sys, re
allowed = {"schema_version", "_note", "incident", "constraints"}
d = json.load(open(sys.argv[1]))
extra = set(d) - allowed
if extra: sys.exit(f"ERROR: triage 未知 top-level: {sorted(extra)}")
if "schema_version" not in d: sys.exit("ERROR: schema_version 無し")
inc = d.get("incident")
if not isinstance(inc, dict) or "signature" not in inc:
  sys.exit("ERROR: incident.signature 無し")
# incident/constraints 配下の想定外フィールドも nested allowlist で拒否する (sanitized handoff 境界の維持)。
allowed_incident = {"service", "signature", "http_status", "failing_path", "external_call", "evidence", "first_seen", "count_5xx_window"}
inc_extra = set(inc) - allowed_incident
if inc_extra: sys.exit(f"ERROR: incident 未知キー: {sorted(inc_extra)}")
con = d.get("constraints", {})
if not isinstance(con, dict): sys.exit("ERROR: constraints が object でない")
con_extra = set(con) - {"scope", "no_raw_logs", "no_secrets", "fixer_inputs"}
if con_extra: sys.exit(f"ERROR: constraints 未知キー: {sorted(con_extra)}")
raw = f"{inc.get('service','svc')}-{inc.get('signature','')}"
slug = re.sub(r"[^a-z0-9]+", "-", raw.lower()).strip("-")[:48].strip("-")
print(slug or "incident")
PY
)

gh auth setup-git
git clone "https://github.com/$TARGET_REPO.git" /work
git -C /work checkout "$TARGET_BRANCH"

# agent input token を絞るため apps/ / packages/ の source dir 配下のみ抽出 (failing_path 対応 file が含まれていれば agent は修正可能)。
INPUT_JSON=$(python3 - /tmp/triage.json /work <<'PY'
import json, os, sys
triage = json.load(open(sys.argv[1]))
work = sys.argv[2]
files = {}
total_bytes = 0
# 集める対象: apps/*/src/**/*.ts(x) と packages/*/src/**/*.ts。1 ファイル 50KB + 総量 900KB 上限 (agent server の 1MiB request cap に収める)。
exts = (".ts", ".tsx", ".js", ".mjs")
prefixes = ("apps/", "packages/")
top_level = ("apps", "packages")  # os.path.relpath は trailing slash を付けないため prefixes とは別に top-level dir 名を許可する
MAX_TOTAL_BYTES = 900_000
for root, dirs, names in os.walk(work):
    rel = os.path.relpath(root, work)
    if any(seg in dirs for seg in ("node_modules", ".git", "dist", "build")):
        dirs[:] = [d for d in dirs if d not in ("node_modules", ".git", "dist", "build")]
    if not (rel == "." or rel in top_level or rel.startswith(prefixes)):
        dirs[:] = []  # apps/ packages/ 以外の subtree は探索自体を打ち切る (不要 I/O 削減)
        continue
    for n in names:
        if not n.endswith(exts):
            continue
        p = os.path.join(root, n)
        rp = os.path.relpath(p, work)
        if "src" not in rp.split(os.sep):
            continue
        try:
            size = os.path.getsize(p)
        except OSError:
            continue
        if size > 50_000:
            continue
        try:
            content = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        # JSON エスケープ後の実サイズ (raw UTF-8 byte ではなく json.dumps 後の長さ) で payload 寄与分を見積もる。
        encoded_size = len(json.dumps(content)) + len(json.dumps(rp)) + 4  # +4: ":" "," 等の punctuation 概算
        if total_bytes + encoded_size > MAX_TOTAL_BYTES:
            continue
        files[rp] = content
        total_bytes += encoded_size
print(json.dumps({"triage": triage, "files": files}))
PY
)
echo "$INPUT_JSON" > /tmp/agent-input.json
INPUT_BYTES=$(wc -c </tmp/agent-input.json | tr -d ' ')
echo ">> agent input: ${INPUT_BYTES}B"
# server (agent/server.js) の 1MiB request cap を超えていたら invoke 前に fail-fast する (round-trip を無駄にしない)。
[ "$INPUT_BYTES" -le 1048576 ] || { echo "ERROR: agent input が 1MiB を超過 (${INPUT_BYTES}B)。triage の対象 file 数/サイズを見直してください。" >&2; exit 1; }

# 入力 file keys を allowlist として保存 (runtime patch が .github/workflows/ 等 入力外パスを書けないよう塞ぐ defense-in-depth)。
python3 -c "
import json
with open('/tmp/agent-input.json') as f:
    d = json.load(f)
with open('/tmp/agent-input-keys.json', 'w') as g:
    json.dump(sorted(d['files'].keys()), g)
"

# AgentCore Runtime を invoke。session-id は UUID で per-invocation 独立 (前回 state を引きずらない)。
# uuidgen は CodeBuild standard image に無いことがあるため kernel 提供の /proc 経由で生成 (追加パッケージ不要)。
# --cli-read-timeout 0 で AWS CLI 既定 60s の socket read timeout を解除 (Bedrock 推論が長引いても CodeBuild 20分 timeout までは待つ)。
RUNTIME_SESSION_ID="$(cat /proc/sys/kernel/random/uuid)"
aws bedrock-agentcore invoke-agent-runtime \
  --cli-read-timeout 0 \
  --agent-runtime-arn "$AGENT_RUNTIME_ARN" \
  --runtime-session-id "$RUNTIME_SESSION_ID" \
  --payload "fileb:///tmp/agent-input.json" \
  /tmp/agent-output.bin

# CLI は binary でレスポンスを書く (HTTP body そのまま)。content-type は agent server が application/json で返している。
RESPONSE=$(cat /tmp/agent-output.bin)
echo "$RESPONSE" | jq .

# error body ({error: ...}) や schema 違反を 0 patches として握り潰さないよう構造を厳密に検証してから件数判定する。
if ! echo "$RESPONSE" | jq -e 'has("patches") and (.patches | type) == "array"' >/dev/null; then
  echo "ERROR: agent response が patches: array を含まない (schema 違反 or error)。bridge を fail させる。" >&2
  exit 1
fi
PATCH_COUNT=$(echo "$RESPONSE" | jq '.patches | length')
if [ "$PATCH_COUNT" = "0" ]; then
  echo ">> agent returned 0 patches (修正不能 or 既に修正済み)。PR は作らない。"
  exit 0
fi

# runtime patch を信頼境界外として扱い、path ∈ input.files allowlist + 既存 symlink 拒否 + realpath 解決後の境界保持を強制する。
python3 - /tmp/agent-output.bin /work /tmp/agent-input-keys.json <<'PY'
import json, os, sys
data = json.load(open(sys.argv[1]))
work_abs = os.path.realpath(sys.argv[2])
allowed = set(json.load(open(sys.argv[3])))
applied = 0
for p in data.get("patches", []):
    path_v = p.get("path")
    content = p.get("newContent")
    if not isinstance(path_v, str) or not isinstance(content, str):
        print(f"REJECT: invalid types (path={type(path_v).__name__}, newContent={type(content).__name__})", file=sys.stderr)
        continue
    if path_v not in allowed:
        print(f"REJECT: path not in input.files allowlist: {path_v}", file=sys.stderr)
        continue
    candidate = os.path.normpath(os.path.join(work_abs, path_v))
    if not candidate.startswith(work_abs + os.sep):
        print(f"REJECT: lexical escape: {path_v}", file=sys.stderr)
        continue
    if os.path.lexists(candidate) and os.path.islink(candidate):
        print(f"REJECT: existing symlink: {path_v}", file=sys.stderr)
        continue
    parent = os.path.dirname(candidate)
    os.makedirs(parent, exist_ok=True)
    if not os.path.realpath(parent).startswith(work_abs):
        print(f"REJECT: parent dir escapes work after realpath: {path_v}", file=sys.stderr)
        continue
    with open(candidate, "w", encoding="utf-8") as f:
        f.write(content)
    applied += 1
    print(f">> applied: {path_v}")
print(f">> total applied: {applied}")
if applied == 0:
    sys.exit("ERROR: no patches applied (全件 reject されたため bridge を fail させる)")
PY

git -C /work add -A
if git -C /work diff --cached --quiet; then
  echo ">> 変更なし (patches は空 or 既に同内容)。PR は作らない。"
  exit 0
fi

git config --global user.email "sre-fixer-pattern-b@users.noreply.github.com"
git config --global user.name "SRE Fixer Pattern B (AgentCore Runtime)"

echo; echo "===== fix diff ====="; git -C /work --no-pager diff --cached

FIX_BRANCH="${FIX_BRANCH:-sre-fix-pattern-b/$INCIDENT_ID}"
git check-ref-format "refs/heads/$FIX_BRANCH" || { echo "ERROR: 不正な branch 名: $FIX_BRANCH" >&2; exit 1; }
git -C /work switch -c "$FIX_BRANCH" 2>/dev/null || git -C /work switch "$FIX_BRANCH"
git -C /work commit -q -m "fix(sre/pattern-b): ${INCIDENT_ID} の最小修正 (AgentCore Runtime / Agent SDK)"

git -C /work fetch origin "+refs/heads/${FIX_BRANCH}:refs/remotes/origin/${FIX_BRANCH}" 2>/dev/null || true
(cd /work && git push -u origin "$FIX_BRANCH" 2>/dev/null) \
  || git -C /work push --force-with-lease -u origin "$FIX_BRANCH"

SHORT_SHA=$(git -C /work rev-parse --short HEAD)
PR_BODY_BASE="観測段の sanitized triage を起点に **Pattern B (Claude Agent SDK on AgentCore Runtime)** SRE agent が作成した最小 fix。**merge は人間レビュー後**（承認ゲート）。

incident: \`${INCIDENT_ID}\`
fixer: パターン B (AgentCore Runtime + Bedrock InvokeModel / 修正 identity・AWS read なし)
head: \`${SHORT_SHA}\`"

EXISTING_PR_NUM=$(gh pr list --repo "$TARGET_REPO" --head "$FIX_BRANCH" --base "$PR_BASE" --state open --json number,isCrossRepository --jq '[.[] | select(.isCrossRepository == false)][0].number // empty')
if [ -n "$EXISTING_PR_NUM" ]; then
  echo ">> existing open PR #${EXISTING_PR_NUM} を head=${SHORT_SHA} で superseded note 付きに更新"
  gh pr edit "$EXISTING_PR_NUM" --repo "$TARGET_REPO" --body "${PR_BODY_BASE}

---
⚠️ 本 PR は新しい fixer run で **force-push 更新** されました。前 commit の fix は最新 head (\`${SHORT_SHA}\`) で superseded されています。"
else
  echo ">> 新規 PR を作成"
  # --head を明示: cwd が /work (git 操作先) と異なり git repo でないため、暗黙の current branch 検出が失敗する。
  gh pr create --repo "$TARGET_REPO" --head "$FIX_BRANCH" --base "$PR_BASE" --title "fix(sre/pattern-b): ${INCIDENT_ID}" --body "$PR_BODY_BASE"
fi
