# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# Expand stage/* branches as worktrees under .worktrees/ (an instructor / parallel-work tool,
# not required for attendees: stages open with 'git switch stage/NN';
# see docs/decisions/stage-stacked-branches.md).

# PS 5.1 decodes native command output with the ANSI codepage; force UTF-8 so non-ASCII repo paths survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# git-common-dir based: resolves to the main checkout root even when invoked from inside a stage worktree.
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

# prune stale registrations so manually deleted worktrees can be recreated
git worktree prune

git fetch origin --prune
if ($LASTEXITCODE -ne 0) { Write-Warning "fetch failed (offline?), using local refs only" }

$localBranches = @(git for-each-ref --format='%(refname:short)' 'refs/heads/stage/')
$remoteBranches = @(git for-each-ref --format='%(refname:short)' 'refs/remotes/origin/stage/') |
  ForEach-Object { $_ -replace '^origin/', '' }
$branches = @($localBranches) + @($remoteBranches) | Where-Object { $_ } | Sort-Object -Unique

if (-not $branches) {
  Write-Host "no stage/* branches found"
  exit 0
}

foreach ($branch in $branches) {
  $slug = $branch -replace '^stage/', ''
  $path = ".worktrees/$slug"
  if (Test-Path -LiteralPath $path) {
    Write-Host "skip: $path already exists"
    continue
  }
  git show-ref --verify --quiet "refs/heads/$branch"
  if ($LASTEXITCODE -eq 0) {
    git worktree add --relative-paths $path $branch
  } else {
    git worktree add --relative-paths --track -b $branch $path "origin/$branch"
  }
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

git worktree list
