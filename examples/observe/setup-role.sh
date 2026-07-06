#!/usr/bin/env bash
# observe box (rules/box-personas.md US3) が assume する read-only IAM role を冪等に作成/更新する
# (--log-group を変えて再実行すれば調査対象を repoint できる)。
set -euo pipefail

git_common_dir=$(git rev-parse --path-format=absolute --git-common-dir) || exit
cd "$(dirname "$git_common_dir")" || exit 1

usage() {
  cat <<'EOF'
Usage: bash examples/observe/setup-role.sh \
  --profile <aws-profile> --region <region> --log-group <log-group-name> \
  [--account-id <id>] [--role-name <name>] [--stack-name <name>] [--distribution-id <id>]

examples/observe/readonly-iam-policy.json のテンプレを埋めて read-only IAM role を作成/更新する。
--stack-name / --distribution-id を省略すると、対応する CloudFormation / CloudFront の
read ステートメントごと外して apply する (ARN が未確定のまま broad scope で適用する事故を防ぐ)。

  --profile          host 側 AWS profile (iam:CreateRole 等の権限が必要)
  --region           対象リージョン (例: ap-northeast-1)
  --log-group        調査対象の CloudWatch Logs ロググループ名 (例: /ecs/diag-api)
  --account-id       省略時は aws sts get-caller-identity から自動取得
  --role-name        省略時は sre-observe-readonly
  --stack-name       指定時のみ CloudFormation describe を許可
  --distribution-id  指定時のみ CloudFront GetDistribution を許可
EOF
}

PROFILE=""
REGION=""
ACCOUNT_ID=""
ROLE_NAME="sre-observe-readonly"
LOG_GROUP=""
STACK_NAME=""
DISTRIBUTION_ID=""

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
    --account-id) require_value "$1" "${2:-}"; ACCOUNT_ID="$2"; shift 2 ;;
    --role-name) require_value "$1" "${2:-}"; ROLE_NAME="$2"; shift 2 ;;
    --log-group) require_value "$1" "${2:-}"; LOG_GROUP="$2"; shift 2 ;;
    --stack-name) require_value "$1" "${2:-}"; STACK_NAME="$2"; shift 2 ;;
    --distribution-id) require_value "$1" "${2:-}"; DISTRIBUTION_ID="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$PROFILE" ] || { echo "error: --profile is required" >&2; usage; exit 2; }
[ -n "$REGION" ] || { echo "error: --region is required" >&2; usage; exit 2; }
[ -n "$LOG_GROUP" ] || { echo "error: --log-group is required" >&2; usage; exit 2; }

# jq は README §1 の host 前提条件に含まれないため明示検査する (policy テンプレの JSON 加工に使用)。
command -v jq >/dev/null 2>&1 || { echo "error: jq is required by this script (not in README section 1 host prerequisites; install via your package manager, e.g. brew install jq / apt install jq)" >&2; exit 1; }

# role は常に PROFILE の実アカウントに作られる。--account-id の値が実アカウントと食い違うと
# ARN が全て不一致になり壊れた policy を apply してしまうため、常に実アカウントで検証する。
REAL_ACCOUNT_ID="$(aws sts get-caller-identity --profile "$PROFILE" --region "$REGION" --query Account --output text)"
if [ -z "$ACCOUNT_ID" ]; then
  ACCOUNT_ID="$REAL_ACCOUNT_ID"
elif [ "$ACCOUNT_ID" != "$REAL_ACCOUNT_ID" ]; then
  echo "error: --account-id $ACCOUNT_ID does not match the authenticated profile's account ($REAL_ACCOUNT_ID)." >&2
  exit 1
fi

POLICY_JSON="$(cat examples/observe/readonly-iam-policy.json)"
POLICY_JSON="${POLICY_JSON//REGION/$REGION}"
POLICY_JSON="${POLICY_JSON//ACCOUNT_ID/$ACCOUNT_ID}"
POLICY_JSON="${POLICY_JSON//LOG_GROUP_NAME/$LOG_GROUP}"

if [ -n "$STACK_NAME" ]; then
  POLICY_JSON="${POLICY_JSON//STACK_NAME/$STACK_NAME}"
else
  echo ">> --stack-name 省略: CloudFormationDescribeScopedToStack を外します" >&2
  POLICY_JSON="$(echo "$POLICY_JSON" | jq 'del(.Statement[] | select(.Sid == "CloudFormationDescribeScopedToStack"))')"
fi

if [ -n "$DISTRIBUTION_ID" ]; then
  POLICY_JSON="${POLICY_JSON//DISTRIBUTION_ID/$DISTRIBUTION_ID}"
else
  echo ">> --distribution-id 省略: CloudFrontReadDistribution を外します" >&2
  POLICY_JSON="$(echo "$POLICY_JSON" | jq 'del(.Statement[] | select(.Sid == "CloudFrontReadDistribution"))')"
fi

# 置換漏れのまま apply すると無効な ARN で put-role-policy が fail するか、意図せず broad scope に
# なる恐れがあるため明示検査する。
if echo "$POLICY_JSON" | grep -qE 'REGION|ACCOUNT_ID|LOG_GROUP_NAME|STACK_NAME|DISTRIBUTION_ID'; then
  echo "error: unresolved placeholder remains in policy document:" >&2
  echo "$POLICY_JSON" | grep -E 'REGION|ACCOUNT_ID|LOG_GROUP_NAME|STACK_NAME|DISTRIBUTION_ID' >&2
  exit 1
fi

# file:// 経由で渡す (inline 引数だと Windows 側の twin でネストした二重引用符のエスケープが壊れやすいため、
# bash/PowerShell 両方でこの temp file 方式に統一する)。
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
echo "$POLICY_JSON" > "$TMP_DIR/policy.json"
jq -n --arg account "$ACCOUNT_ID" '{
  Version: "2012-10-17",
  Statement: [{
    Effect: "Allow",
    Principal: { AWS: ("arn:aws:iam::" + $account + ":root") },
    Action: "sts:AssumeRole"
  }]
}' > "$TMP_DIR/trust.json"

if GET_ROLE_OUTPUT="$(aws iam get-role --profile "$PROFILE" --region "$REGION" --role-name "$ROLE_NAME" 2>&1)"; then
  # 既存 role に本スクリプト管理外の policy が付いていると、trust/inline policy だけ更新しても
  # read-only の保証が崩れる (write 権限が残ったまま observe box に渡る)。fail-fast で検出する。
  ATTACHED="$(aws iam list-attached-role-policies --profile "$PROFILE" --region "$REGION" \
    --role-name "$ROLE_NAME" --query 'AttachedPolicies[].PolicyName' --output text)"
  if [ -n "$ATTACHED" ]; then
    echo "error: role '$ROLE_NAME' has attached managed policies ($ATTACHED) not managed by this script." >&2
    echo "       read-only は保証できません。手動で detach するか別の --role-name を使ってください。" >&2
    exit 1
  fi
  INLINE_NAMES="$(aws iam list-role-policies --profile "$PROFILE" --region "$REGION" \
    --role-name "$ROLE_NAME" --query 'PolicyNames' --output text)"
  UNEXPECTED_INLINE="$(printf '%s\n' "$INLINE_NAMES" | tr '\t' '\n' | grep -v '^observe-readonly$' | grep -v '^$' || true)"
  if [ -n "$UNEXPECTED_INLINE" ]; then
    echo "error: role '$ROLE_NAME' has inline policies not managed by this script ($UNEXPECTED_INLINE)." >&2
    echo "       read-only は保証できません。手動で削除するか別の --role-name を使ってください。" >&2
    exit 1
  fi

  echo ">> role '$ROLE_NAME' already exists, updating trust policy" >&2
  aws iam update-assume-role-policy --profile "$PROFILE" --region "$REGION" \
    --role-name "$ROLE_NAME" --policy-document "file://$TMP_DIR/trust.json"
else
  # get-role の失敗は auth/throttling/network 等でも起きうる。role 不在 (NoSuchEntity) のみ
  # create に進み、それ以外は元のエラーを見せて止める (誤って create-role を試みない)。
  if ! printf '%s' "$GET_ROLE_OUTPUT" | grep -q 'NoSuchEntity'; then
    echo "$GET_ROLE_OUTPUT" >&2
    exit 1
  fi
  echo ">> creating role '$ROLE_NAME'" >&2
  aws iam create-role --profile "$PROFILE" --region "$REGION" \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://$TMP_DIR/trust.json" \
    --description "sre-bedrock observe box read-only role (examples/observe/runbook.md)" >/dev/null
fi

echo ">> applying inline policy 'observe-readonly'" >&2
aws iam put-role-policy --profile "$PROFILE" --region "$REGION" \
  --role-name "$ROLE_NAME" --policy-name observe-readonly --policy-document "file://$TMP_DIR/policy.json"

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo ">> role ready: $ROLE_ARN" >&2
echo "$ROLE_ARN"
