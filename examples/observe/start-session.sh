#!/usr/bin/env bash
# observe box (rules/box-personas.md US3) の read-only AWS session を 1 コマンドでセットアップする
# (mint + box への credential 注入 + AWS endpoint への network allow 追加。runbook.md 旧 step 0 の手動 3 手順の自動化)。
set -euo pipefail

cd "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"

usage() {
  cat <<'EOF'
Usage: bash examples/observe/start-session.sh \
  --profile <aws-profile> --region <region> --role-arn <role-arn> --box <obs-box-name> \
  [--duration <seconds>] [--endpoints <comma-separated-hosts>]

examples/observe/setup-role.sh で作った role を assume し、observe box (obs-* 命名必須) に
credential を注入して AWS API endpoint への到達を明示的に許可する。box 起動は
bash scripts/dev.sh observe を先に実行しておくこと (本スクリプトは box を作らない)。
注意: sbx の network policy は追加のみで既存 allow を削除できないため、AWS 以外への到達は
遮断されない (read-only の実効境界は IAM 側)。詳細は runbook.md の「network について」参照。

  --profile    host 側 AWS profile (sts:AssumeRole の権限が必要)
  --region     対象リージョン (例: ap-northeast-1)
  --role-arn   setup-role.sh が出力した role ARN
  --box        observe box 名 (obs- prefix 必須。scripts/dev.sh observe [<NAME>] の出力名)
  --duration   session の有効秒数 (省略時 3600)
  --endpoints  カンマ区切りの AWS API endpoint 一覧 (省略時は runbook.md 既定の 6 endpoint を REGION で組み立てる)
EOF
}

PROFILE=""
REGION=""
ROLE_ARN=""
BOX=""
DURATION="3600"
ENDPOINTS=""

# set -u 下で値の無いフラグ (末尾の --profile 等) を "$2" で読むと unbound variable で
# usage を出さずに落ちるため、shift 前に値の有無を検査する。
require_value() {
  if [ $# -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" == --* ]]; then
    echo "error: $1 requires a value" >&2
    usage
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) require_value "$1" "${2:-}"; PROFILE="$2"; shift 2 ;;
    --region) require_value "$1" "${2:-}"; REGION="$2"; shift 2 ;;
    --role-arn) require_value "$1" "${2:-}"; ROLE_ARN="$2"; shift 2 ;;
    --box) require_value "$1" "${2:-}"; BOX="$2"; shift 2 ;;
    --duration) require_value "$1" "${2:-}"; DURATION="$2"; shift 2 ;;
    --endpoints) require_value "$1" "${2:-}"; ENDPOINTS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$PROFILE" ] || { echo "error: --profile is required" >&2; usage; exit 2; }
[ -n "$REGION" ] || { echo "error: --region is required" >&2; usage; exit 2; }
[ -n "$ROLE_ARN" ] || { echo "error: --role-arn is required" >&2; usage; exit 2; }
[ -n "$BOX" ] || { echo "error: --box is required" >&2; usage; exit 2; }

# jq は README §1 の host 前提条件に含まれないため明示検査する (STS credential JSON の parse に使用)。
command -v jq >/dev/null 2>&1 || { echo "error: jq is required by this script (not in README section 1 host prerequisites; install via your package manager, e.g. brew install jq / apt install jq)" >&2; exit 1; }

case "$BOX" in
  obs-*) ;;
  *)
    echo "error: --box must start with 'obs-' (observe box namespace, see rules/box-personas.md / scripts/dev.sh observe)" >&2
    exit 2
    ;;
esac

# 任意の role ARN を渡された場合に備え、setup-role.sh が付けるはずの policy 構成と一致するかを
# mint 前に検証する (誤って別 role の ARN を渡すと、その role の実権限が box に注入されてしまう)。
# list-*-role-policies は role-name を呼び出し元の自アカウント context で解決するため、
# cross-account な ARN では別アカウントの同名 role を誤って検証しうる。先にアカウント部を検証する。
CALLER_ACCOUNT="$(aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" --query Account --output text)"
ROLE_ARN_ACCOUNT="$(printf '%s' "$ROLE_ARN" | cut -d: -f5)"
if [ "$ROLE_ARN_ACCOUNT" != "$CALLER_ACCOUNT" ]; then
  echo "error: --role-arn account ($ROLE_ARN_ACCOUNT) does not match the profile's account ($CALLER_ACCOUNT). Cross-account role ARNs are not supported." >&2
  exit 1
fi
ROLE_NAME_FROM_ARN="${ROLE_ARN##*/}"
ATTACHED="$(aws iam list-attached-role-policies --profile "$PROFILE" --region "$REGION" \
  --role-name "$ROLE_NAME_FROM_ARN" --query 'AttachedPolicies[].PolicyName' --output text)"
if [ -n "$ATTACHED" ]; then
  echo "error: role '$ROLE_NAME_FROM_ARN' has attached managed policies ($ATTACHED). Refusing to mint credentials from an unverified role; use the ARN output by setup-role.sh." >&2
  exit 1
fi
INLINE_NAMES="$(aws iam list-role-policies --profile "$PROFILE" --region "$REGION" \
  --role-name "$ROLE_NAME_FROM_ARN" --query 'PolicyNames' --output text)"
if [ "$INLINE_NAMES" != "observe-readonly" ]; then
  echo "error: role '$ROLE_NAME_FROM_ARN' inline policies ($INLINE_NAMES) do not match the expected 'observe-readonly' only. Refusing to mint credentials from an unverified role; use the ARN output by setup-role.sh." >&2
  exit 1
fi
# 名前の一致だけでは同名の別内容 policy を見抜けない (list-role-policies は名前しか返さない)。
# 実 document を取得し、テンプレ由来の目印として DenyAssumeRoleNoCredentialBroker deny の有無を見る。
POLICY_DOC="$(aws iam get-role-policy --profile "$PROFILE" --region "$REGION" \
  --role-name "$ROLE_NAME_FROM_ARN" --policy-name observe-readonly --query 'PolicyDocument' --output json)"
if ! printf '%s' "$POLICY_DOC" | jq -e '.Statement[] | select(.Sid == "DenyAssumeRoleNoCredentialBroker" and .Effect == "Deny")' >/dev/null 2>&1; then
  echo "error: role '$ROLE_NAME_FROM_ARN' inline policy 'observe-readonly' does not match the expected template (missing DenyAssumeRoleNoCredentialBroker deny statement). Refusing to mint credentials from an unverified role; use the ARN output by setup-role.sh." >&2
  exit 1
fi

echo ">> minting session credential (role=$ROLE_ARN, duration=${DURATION}s)" >&2
CREDS_JSON="$(aws sts assume-role --profile "$PROFILE" --region "$REGION" \
  --role-arn "$ROLE_ARN" --role-session-name observe --duration-seconds "$DURATION" \
  --query Credentials --output json)"

ACCESS_KEY_ID="$(echo "$CREDS_JSON" | jq -r .AccessKeyId)"
SECRET_ACCESS_KEY="$(echo "$CREDS_JSON" | jq -r .SecretAccessKey)"
SESSION_TOKEN="$(echo "$CREDS_JSON" | jq -r .SessionToken)"
EXPIRATION="$(echo "$CREDS_JSON" | jq -r .Expiration)"

TMP_CREDS="$(mktemp)"
trap 'rm -f "$TMP_CREDS"' EXIT
cat > "$TMP_CREDS" <<EOF
[default]
aws_access_key_id = $ACCESS_KEY_ID
aws_secret_access_key = $SECRET_ACCESS_KEY
aws_session_token = $SESSION_TOKEN
EOF

# sbx/README.md の credential 注入パターン (~/.codex/auth.json 転送) と同じ手順: root で dir 作成/所有権
# 設定 → cp → chown。box の agent user は uid/gid 1000 固定。
echo ">> injecting credentials into box '$BOX' (~/.aws/credentials)" >&2
sbx exec "$BOX" sudo install -d -o 1000 -g 1000 /home/agent/.aws
sbx cp "$TMP_CREDS" "$BOX":/home/agent/.aws/credentials
sbx exec "$BOX" sudo chown 1000:1000 /home/agent/.aws/credentials
sbx exec "$BOX" sudo chmod 600 /home/agent/.aws/credentials

if [ -z "$ENDPOINTS" ]; then
  ENDPOINTS="logs.${REGION}.amazonaws.com,monitoring.${REGION}.amazonaws.com,cloudformation.${REGION}.amazonaws.com,ecs.${REGION}.amazonaws.com,elasticloadbalancing.${REGION}.amazonaws.com,cloudfront.amazonaws.com"
fi

# --sandbox 必須 (省くと全 sandbox に allow が付き dev box にも AWS egress が漏れる, P2)。
# 既存 allow は削除できないため AWS 以外への到達は遮断しない (read-only 境界は IAM 側。既知の制約: https://github.com/kanka-jp/coding-agent-playbook/issues/161)。
echo ">> allowing AWS API endpoints for the box (does not block other existing egress; see issues/161)" >&2
sbx policy allow network --sandbox "$BOX" "$ENDPOINTS"

echo ">> session ready (expires: $EXPIRATION)" >&2
echo ">> smoke test inside the box: aws logs describe-log-streams --region $REGION --log-group-name <LOG_GROUP> --max-items 1" >&2
