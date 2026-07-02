# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# Propagate main-side tooling changes through the stage chain (stage/01 -> 02 -> ... -> tail)
# via cascade merges (docs/decisions/stage-stacked-branches.md decision 2; run explicitly,
# no resident sync). app/ (project body) and the tooling root never overlap by path,
# so the merges auto-resolve. Merging happens inside a temporary worktree so the
# main checkout branch is never switched.

# PS 5.1 decodes native command output with the ANSI codepage; force UTF-8 so non-ASCII repo paths survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# git-common-dir based: resolves to the main checkout root even when invoked from inside a worktree.
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

$stages = @(git for-each-ref --format='%(refname:short)' 'refs/heads/stage/') | Sort-Object
if (-not $stages) {
  Write-Error "no local stage/* branches (fetch with: git fetch origin '+refs/heads/stage/*:refs/heads/stage/*')"
  exit 1
}

$wt = '.worktrees/.restack-tmp'

# rerun path when a previous conflict left the temp worktree behind:
# stop with guidance if unresolved (dirty); remove and continue if resolved (clean)
if (Test-Path -LiteralPath $wt) {
  $dirty = @(git -C $wt status --porcelain 2>$null)
  if ($dirty.Count -gt 0) {
    Write-Error "unresolved merge remains in $wt. Resolve and commit there, then rerun."
    exit 1
  }
  git worktree remove --force $wt 2>$null
}

# merging checks branches out; refuse if any target stage is already checked out in a worktree
# (the temp worktree was removed above, so it never trips this check)
$worktreeBranches = @(git worktree list --porcelain) | Where-Object { $_ -like 'branch refs/heads/stage/*' }
foreach ($br in $stages) {
  if ($worktreeBranches -contains "branch refs/heads/$br") {
    Write-Error "$br is checked out in a worktree. Run 'git worktree remove' first."
    exit 1
  }
}
$first = $stages[0]
git worktree add --relative-paths $wt $first | Out-Null
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$failed = $false
$prev = 'main'
foreach ($br in $stages) {
  git -C $wt switch -q $br
  if ($LASTEXITCODE -ne 0) { $failed = $true; break }
  git -C $wt merge --no-edit -q $prev
  if ($LASTEXITCODE -ne 0) {
    Write-Error "merge into $br conflicted (app/ vs tooling root should never overlap). Resolve in $wt, commit, then rerun."
    $failed = $true
    break
  }
  Write-Host "restacked: $br <= $prev"
  $prev = $br
}

if (-not $failed) {
  git worktree remove --force $wt 2>$null
  Write-Host "done. Push with:"
  Write-Host ("  git push origin " + ($stages -join ' '))
} else {
  exit 1
}
