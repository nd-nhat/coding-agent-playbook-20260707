# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

# Sets up a read-only AWS session for the observe box (rules/box-personas.md US3) in one command
# (mint + inject the credential into the box + allow AWS endpoints on its network).

param(
  [string]$Profile = "",
  [string]$Region = "",
  [string]$RoleArn = "",
  [string]$Box = "",
  [int]$Duration = 3600,
  [string]$Endpoints = "",
  [switch]$Help
)

function Show-Usage {
  @"
Usage: pwsh examples/observe/start-session.ps1 -Profile <aws-profile> -Region <region> ``
  -RoleArn <role-arn> -Box <obs-box-name> [-Duration <seconds>] [-Endpoints <comma-separated-hosts>]

Assumes the role created by examples/observe/setup-role.ps1 and injects the credential into
the observe box (obs- prefix required), then allows the box's network to reach AWS API endpoints.
Start the box first with pwsh scripts/dev.ps1 observe (this script does not create a box).
Note: sbx network policy is allow-only and cannot remove existing allow rules, so this does not
block non-AWS reachability (the effective read-only boundary is IAM). See runbook.md.

  -Profile    host AWS profile (needs sts:AssumeRole)
  -Region     target region (e.g. ap-northeast-1)
  -RoleArn    role ARN output by setup-role.ps1
  -Box        observe box name (obs- prefix required; output of scripts/dev.ps1 observe [<NAME>])
  -Duration   session lifetime in seconds (default 3600)
  -Endpoints  comma-separated AWS API endpoints (default: the 6 endpoints from runbook.md, built from -Region)
"@
}

if ($Help) { Show-Usage; exit 0 }

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

if (-not $Profile) { Write-Error "-Profile is required"; Show-Usage; exit 2 }
if (-not $Region) { Write-Error "-Region is required"; Show-Usage; exit 2 }
if (-not $RoleArn) { Write-Error "-RoleArn is required"; Show-Usage; exit 2 }
if (-not $Box) { Write-Error "-Box is required"; Show-Usage; exit 2 }

# -notlike is case-insensitive by default; the bash twin's case match is case-sensitive, so
# -cnotlike keeps both twins consistent (e.g. rejects "OBS-x" which is not a real observe box).
if ($Box -cnotlike "obs-*") {
  Write-Error "-Box must start with 'obs-' (observe box namespace; see rules/box-personas.md / scripts/dev.ps1 observe)"
  exit 2
}

# If an arbitrary role ARN is passed, verify it matches the policy shape setup-role.ps1 produces
# before minting (an unverified role's real permissions would otherwise get injected into the box).
# list-*-role-policies resolves -role-name in the caller's own account, so a cross-account ARN
# would silently validate an unrelated same-named role in this account instead.
$callerAccount = & aws sts get-caller-identity --profile $Profile --region $Region --query Account --output text
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$roleArnAccount = $RoleArn.Split(":")[4]
if ($roleArnAccount -ne $callerAccount) {
  Write-Error "-RoleArn account ($roleArnAccount) does not match the profile's account ($callerAccount). Cross-account role ARNs are not supported."
  exit 1
}
$roleNameFromArn = $RoleArn.Split("/")[-1]
$attached = & aws iam list-attached-role-policies --profile $Profile --region $Region --role-name $roleNameFromArn --query 'AttachedPolicies[].PolicyName' --output text
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($attached) {
  Write-Error "role '$roleNameFromArn' has attached managed policies ($attached). Refusing to mint credentials from an unverified role; use the ARN output by setup-role.ps1."
  exit 1
}
$inlineNames = & aws iam list-role-policies --profile $Profile --region $Region --role-name $roleNameFromArn --query 'PolicyNames' --output text
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($inlineNames -ne "observe-readonly") {
  Write-Error "role '$roleNameFromArn' inline policies ($inlineNames) do not match the expected 'observe-readonly' only. Refusing to mint credentials from an unverified role; use the ARN output by setup-role.ps1."
  exit 1
}
# Name match alone cannot detect a same-named policy with different content (list-role-policies
# returns names only); check the real document for the DenyAssumeRoleNoCredentialBroker marker.
$policyDoc = & aws iam get-role-policy --profile $Profile --region $Region --role-name $roleNameFromArn --policy-name observe-readonly --query 'PolicyDocument' --output json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$policyObjCheck = $policyDoc | ConvertFrom-Json
$hasDenyMarker = $policyObjCheck.Statement | Where-Object { $_.Sid -eq "DenyAssumeRoleNoCredentialBroker" -and $_.Effect -eq "Deny" }
if (-not $hasDenyMarker) {
  Write-Error "role '$roleNameFromArn' inline policy 'observe-readonly' does not match the expected template (missing DenyAssumeRoleNoCredentialBroker deny statement). Refusing to mint credentials from an unverified role; use the ARN output by setup-role.ps1."
  exit 1
}

Write-Host ">> minting session credential (role=$RoleArn, duration=${Duration}s)"
$credsJson = & aws sts assume-role --profile $Profile --region $Region `
  --role-arn $RoleArn --role-session-name observe --duration-seconds $Duration `
  --query Credentials --output json
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# PowerShell captures multi-line native command output as a string array, not one string;
# join before parsing or ConvertFrom-Json treats each line as a separate (invalid) JSON document.
$creds = ($credsJson -join "`n") | ConvertFrom-Json

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
  $credsPath = Join-Path $tmpDir "credentials"
  @(
    "[default]"
    "aws_access_key_id = $($creds.AccessKeyId)"
    "aws_secret_access_key = $($creds.SecretAccessKey)"
    "aws_session_token = $($creds.SessionToken)"
  ) | Set-Content -LiteralPath $credsPath -Encoding ascii

  # Same injection pattern as sbx/README.md's ~/.codex/auth.json transfer: root creates/owns the
  # dir, then cp, then chown. The box's agent user is fixed at uid/gid 1000.
  Write-Host ">> injecting credentials into box '$Box' (~/.aws/credentials)"
  & sbx exec $Box sudo install -d -o 1000 -g 1000 /home/agent/.aws
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & sbx cp $credsPath "${Box}:/home/agent/.aws/credentials"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & sbx exec $Box sudo chown 1000:1000 /home/agent/.aws/credentials
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & sbx exec $Box sudo chmod 600 /home/agent/.aws/credentials
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

if (-not $Endpoints) {
  $Endpoints = "logs.$Region.amazonaws.com,monitoring.$Region.amazonaws.com,cloudformation.$Region.amazonaws.com,ecs.$Region.amazonaws.com,elasticloadbalancing.$Region.amazonaws.com,cloudfront.amazonaws.com"
}

# --sandbox is mandatory (omitting it adds the allow to every sandbox, leaking AWS egress into dev boxes, P2).
# Existing allow rules cannot be removed, so this does not block non-AWS egress (read-only boundary is IAM. known limitation: https://github.com/kanka-jp/coding-agent-playbook/issues/161).
Write-Host ">> allowing AWS API endpoints for the box (does not block other existing egress; see issues/161)"
& sbx policy allow network --sandbox $Box $Endpoints
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ">> session ready (expires: $($creds.Expiration))"
Write-Host ">> smoke test inside the box: aws logs describe-log-streams --region $Region --log-group-name <LOG_GROUP> --max-items 1"
