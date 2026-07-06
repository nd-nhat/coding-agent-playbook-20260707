# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

# Creates/updates (idempotently) the read-only IAM role the observe box assumes (US3).
# Re-running with a different -LogGroup repoints it at a new investigation target.

param(
  [string]$Profile = "",
  [string]$Region = "",
  [string]$LogGroup = "",
  [string]$AccountId = "",
  [string]$RoleName = "sre-observe-readonly",
  [string]$StackName = "",
  [string]$DistributionId = "",
  [switch]$Help
)

function Show-Usage {
  @"
Usage: pwsh examples/observe/setup-role.ps1 -Profile <aws-profile> -Region <region> -LogGroup <log-group-name> ``
  [-AccountId <id>] [-RoleName <name>] [-StackName <name>] [-DistributionId <id>]

Fills examples/observe/readonly-iam-policy.json and creates/updates the observe box read-only IAM role.
Omitting -StackName / -DistributionId drops the corresponding CloudFormation / CloudFront read
statement entirely, instead of applying it with an unresolved ARN placeholder.

  -Profile          host AWS profile (needs iam:CreateRole etc.)
  -Region           target region (e.g. ap-northeast-1)
  -LogGroup         CloudWatch Logs log group name to investigate (e.g. /ecs/diag-api)
  -AccountId        defaults to the output of aws sts get-caller-identity
  -RoleName         defaults to sre-observe-readonly
  -StackName        include the CloudFormation describe statement only when given
  -DistributionId   include the CloudFront GetDistribution statement only when given
"@
}

if ($Help) { Show-Usage; exit 0 }

# PS 5.1 decodes native command output with the ANSI codepage; force UTF-8 so non-ASCII repo paths survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# git-common-dir based: resolves to the main checkout root even from inside a stage worktree.
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

if (-not $Profile) { Write-Error "-Profile is required"; Show-Usage; exit 2 }
if (-not $Region) { Write-Error "-Region is required"; Show-Usage; exit 2 }
if (-not $LogGroup) { Write-Error "-LogGroup is required"; Show-Usage; exit 2 }

# The role is always created in the profile's real account. A mismatched -AccountId would
# produce ARNs that never match the real account, so always verify against the real one.
$realAccountId = & aws sts get-caller-identity --profile $Profile --region $Region --query Account --output text
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if (-not $AccountId) {
  $AccountId = $realAccountId
} elseif ($AccountId -ne $realAccountId) {
  Write-Error "-AccountId $AccountId does not match the authenticated profile's account ($realAccountId)."
  exit 1
}

$policyObj = Get-Content -Raw examples/observe/readonly-iam-policy.json | ConvertFrom-Json

if (-not $StackName) {
  Write-Host ">> -StackName omitted: dropping CloudFormationDescribeScopedToStack"
  $policyObj.Statement = @($policyObj.Statement | Where-Object { $_.Sid -ne "CloudFormationDescribeScopedToStack" })
}
if (-not $DistributionId) {
  Write-Host ">> -DistributionId omitted: dropping CloudFrontReadDistribution"
  $policyObj.Statement = @($policyObj.Statement | Where-Object { $_.Sid -ne "CloudFrontReadDistribution" })
}

$policyJson = $policyObj | ConvertTo-Json -Depth 10
$policyJson = $policyJson.Replace("REGION", $Region).Replace("ACCOUNT_ID", $AccountId).Replace("LOG_GROUP_NAME", $LogGroup)
if ($StackName) { $policyJson = $policyJson.Replace("STACK_NAME", $StackName) }
if ($DistributionId) { $policyJson = $policyJson.Replace("DISTRIBUTION_ID", $DistributionId) }

# -cmatch (case-sensitive): case-insensitive -match would false-positive on the fixed IAM
# condition key "aws:RequestedRegion", which always contains "Region" as a substring.
if ($policyJson -cmatch "REGION|ACCOUNT_ID|LOG_GROUP_NAME|STACK_NAME|DISTRIBUTION_ID") {
  Write-Error "unresolved placeholder remains in policy document"
  exit 1
}

$trustPolicy = @{
  Version = "2012-10-17"
  Statement = @(@{
    Effect = "Allow"
    Principal = @{ AWS = "arn:aws:iam::${AccountId}:root" }
    Action = "sts:AssumeRole"
  })
} | ConvertTo-Json -Depth 10

# file:// avoids passing JSON with nested double quotes as a native-command argument (unreliable
# re-escaping under PowerShell's argument marshalling); bash twin uses the same temp-file pattern.
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $tmpDir | Out-Null
try {
  $policyPath = Join-Path $tmpDir "policy.json"
  $trustPath = Join-Path $tmpDir "trust.json"
  Set-Content -LiteralPath $policyPath -Value $policyJson -Encoding ascii
  Set-Content -LiteralPath $trustPath -Value $trustPolicy -Encoding ascii

  $getRoleOutput = & aws iam get-role --profile $Profile --region $Region --role-name $RoleName 2>&1
  if ($LASTEXITCODE -eq 0) {
    # An existing role may carry policies this script does not manage; updating trust/inline policy
    # alone would leave any write permission intact, breaking the read-only guarantee. Fail fast.
    $attached = & aws iam list-attached-role-policies --profile $Profile --region $Region --role-name $RoleName --query 'AttachedPolicies[].PolicyName' --output text
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    if ($attached) {
      Write-Error "role '$RoleName' has attached managed policies ($attached) not managed by this script."
      Write-Error "Read-only cannot be guaranteed. Detach them manually or use a different -RoleName."
      exit 1
    }
    $inlineNames = & aws iam list-role-policies --profile $Profile --region $Region --role-name $RoleName --query 'PolicyNames' --output text
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $unexpectedInline = ($inlineNames -split "`t") | Where-Object { $_ -and $_ -ne "observe-readonly" }
    if ($unexpectedInline) {
      Write-Error "role '$RoleName' has inline policies not managed by this script ($($unexpectedInline -join ', '))."
      Write-Error "Read-only cannot be guaranteed. Remove them manually or use a different -RoleName."
      exit 1
    }

    Write-Host ">> role '$RoleName' already exists, updating trust policy"
    & aws iam update-assume-role-policy --profile $Profile --region $Region --role-name $RoleName --policy-document "file://$trustPath"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  } else {
    # get-role failure can also mean auth/throttling/network issues, not just a missing role.
    # Only proceed to create on NoSuchEntity; otherwise surface the original error and stop.
    if (($getRoleOutput -join "`n") -notmatch "NoSuchEntity") {
      Write-Error ($getRoleOutput -join "`n")
      exit 1
    }
    Write-Host ">> creating role '$RoleName'"
    & aws iam create-role --profile $Profile --region $Region --role-name $RoleName --assume-role-policy-document "file://$trustPath" --description "sre-bedrock observe box read-only role (examples/observe/runbook.md)" *> $null
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  Write-Host ">> applying inline policy 'observe-readonly'"
  & aws iam put-role-policy --profile $Profile --region $Region --role-name $RoleName --policy-name observe-readonly --policy-document "file://$policyPath"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

$roleArn = "arn:aws:iam::${AccountId}:role/${RoleName}"
Write-Host ">> role ready: $roleArn"
Write-Output $roleArn
