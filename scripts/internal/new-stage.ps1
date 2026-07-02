# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# Create a new stage branch. stage/* is a stacked chain based on main; the project
# body lives under app/ (docs/decisions/stage-stacked-branches.md).
# When -Base is omitted, branch off the tail of the chain (highest NN).
param(
  [Parameter(Mandatory = $true)][string]$Name,
  [string]$Base
)

# PS 5.1 decodes native command output with the ANSI codepage; force UTF-8 so non-ASCII repo paths survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# git-common-dir based: resolves to the main checkout root even when invoked from inside a worktree.
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

$Name = $Name -replace '^stage/', ''
if ($Name -eq '' -or $Name -match '[/\\]' -or $Name.StartsWith('.')) {
  Write-Error "invalid stage name '$Name' (use NN-slug like 09-next)"
  exit 1
}

$branch = "stage/$Name"

git show-ref --verify --quiet "refs/heads/$branch"
if ($LASTEXITCODE -ne 0) {
  git show-ref --verify --quiet "refs/remotes/origin/$branch"
}
if ($LASTEXITCODE -eq 0) {
  Write-Error "branch $branch already exists (local or origin)"
  exit 1
}

if ($Base) {
  $baseIn = $Base -replace '^stage/', ''
  if ($baseIn -eq 'main') { $baseBranch = 'main' } else { $baseBranch = "stage/$baseIn" }
} else {
  # fresh clones often have only origin/stage/* (no local stage/*), so resolve the tail from both
  $localStages = @(git for-each-ref --format='%(refname:short)' 'refs/heads/stage/')
  $remoteStages = @(git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/stage/') |
    ForEach-Object { $_ -replace '^origin/', '' }
  $baseBranch = @($localStages) + @($remoteStages) | Where-Object { $_ } |
    Sort-Object -Unique | Select-Object -Last 1
  if (-not $baseBranch) { $baseBranch = 'main' }
}

git show-ref --verify --quiet "refs/heads/$baseBranch"
if ($LASTEXITCODE -eq 0) {
  git branch $branch $baseBranch
} else {
  git show-ref --verify --quiet "refs/remotes/origin/$baseBranch"
  if ($LASTEXITCODE -eq 0) {
    # --no-track: tracking the base branch would make plain git push/pull target the base
    git branch --no-track $branch "origin/$baseBranch"
  } else {
    Write-Error "base branch '$baseBranch' not found (local or origin)"
    exit 1
  }
}
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "created: $branch (base: $baseBranch)"
Write-Host "next: git switch $branch, then edit under app/ (base tooling changes go to main via PR -> restack-stages.ps1)"
