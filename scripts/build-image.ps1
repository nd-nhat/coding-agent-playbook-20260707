# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

# PS 5.1 decodes native command output with the ANSI codepage; force UTF-8 so non-ASCII repo paths survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# git-common-dir based: resolves to the main checkout root even when invoked from inside a stage worktree.
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

# Host-only (the box has no sbx CLI; running this inside a box would be a no-op error).
if (-not (Get-Command sbx -ErrorAction SilentlyContinue)) {
  Write-Error "sbx CLI not found. Run this on the host (not inside a box)."
  exit 1
}

# AGENT_CACHEBUST busts only the installer layer so claude / codex pull their latest version.
# Upstream apt / Chromium layers are cache-reused because their inputs are unchanged.
# --load is a no-op for the default docker driver, but required under
# BUILDX_BUILDER=docker-container/kubernetes/remote to put the result into the local image store
# (omitting it would leave docker save reading a stale image).
$cachebust  = [DateTimeOffset]::Now.ToUnixTimeSeconds()
& docker build --load --build-arg "AGENT_CACHEBUST=$cachebust" -t coding-agent-playbook-sbx sbx/
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# sbx does not share host's local image; it pulls from a registry, so save + template load is required.
$tar = "cap-sbx.tar"
try {
  & docker save coding-agent-playbook-sbx -o $tar
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  & sbx template load $tar
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  # staleness single source of truth, written only after a successful load (on failure the old stamp remains,
  # so the next preflight never mistakes a stale template for current). docker inspect (local image) can diverge
  # from the sbx template store (build/save ok, load fails -> only local is fresh), so it is not used for the check.
  # Line 1 = sbx/Dockerfile commit (rebuild trigger); line 2 = build time (claude/codex build-age WARN).
  # InvariantCulture keeps the timestamp Gregorian regardless of session culture.
  $sbxCommit = (git log --format="%H" -n1 -- sbx/Dockerfile) -join ""
  $buildTime = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
  # -ErrorAction Stop so a stamp-write failure (permission / disk) aborts instead of falling through to the
  # "image refreshed" banner (matches build-image.sh, where set -e aborts on the redirect failure).
  $null = New-Item -ItemType Directory -Force -Path ".claude/tmp" -ErrorAction Stop
  Set-Content -LiteralPath ".claude/tmp/sbx-template-commit.stamp" -Value @($sbxCommit, $buildTime) -Encoding ascii -ErrorAction Stop
} finally {
  Remove-Item -LiteralPath $tar -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "image refreshed. To use the new version:"
Write-Host "  powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 ls            # list dev boxes from the old image"
Write-Host "  powershell -ExecutionPolicy Bypass -File scripts/dev.ps1 kill <NAME|N> # discard an old dev box (cdx-<NAME> pair is torn down too, state is lost)"
Write-Host "  powershell -ExecutionPolicy Bypass -File scripts/dev.ps1               # re-create with the new image (auto-named)"
