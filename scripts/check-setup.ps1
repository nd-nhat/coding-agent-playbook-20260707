# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

# README section 1 setup (sbx CLI / Docker / secret / image / stage branches) verifier.
# Run `pwsh scripts/check-setup.ps1` (or `powershell -ExecutionPolicy Bypass -File scripts/check-setup.ps1`) right after clone so only missing pieces remain.
#
# Layers:
#   - Existence (~1s): is each secret registered, is the image loaded, etc.
#   - Runtime probe: spin up an ephemeral box and run `gh auth status` inside to verify the github PAT is actually valid (not expired/revoked).
#     Pass `-Quick` to skip. anthropic OAuth validity is NOT probed (would consume API credit); it surfaces naturally when `pwsh scripts/dev.ps1` starts the workshop box.
# Exits non-zero on any NG with per-check guidance.

param([switch]$Quick, [switch]$Help)

if ($Help) {
  @"
Usage: pwsh scripts/check-setup.ps1 [-Quick]

Verify README section 1 setup (existence + optional runtime probe via ephemeral box gh auth status).

  -Quick    skip the ephemeral box probe (~1s total, validity unverified)
"@
  exit 0
}

# PS 5.1 decodes native command output with the ANSI codepage; force UTF-8 so non-ASCII repo paths survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:OK = 0
$script:NG = 0
$script:WARN = 0

function Write-Ok($msg) {
  Write-Host "  " -NoNewline
  Write-Host "OK  " -ForegroundColor Green -NoNewline
  Write-Host " $msg"
  $script:OK++
}
function Write-Ng($msg, $hint) {
  Write-Host "  " -NoNewline
  Write-Host "NG  " -ForegroundColor Red -NoNewline
  Write-Host " $msg"
  Write-Host "      -> $hint"
  $script:NG++
}
function Write-Warn($msg, $hint) {
  Write-Host "  " -NoNewline
  Write-Host "WARN" -ForegroundColor Yellow -NoNewline
  Write-Host " $msg"
  Write-Host "      -> $hint"
  $script:WARN++
}

Write-Host "Setup check (README section 1):"
Write-Host ""

# 0. git v2.48+ (must come BEFORE git rev-parse below; otherwise on systems with missing/old git the script exits without giving the right install/upgrade hint).
# README section 1 requires git worktree add --relative-paths; older versions break setup-worktrees and leave stage worktrees absent.
$gitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $gitCmd) {
  Write-Ng "git CLI not in PATH" "Install git 2.48+ (README section 1 requirement)"
  Write-Host ""
  Write-Host "1 failed, 0 warn, 0 ok. Subsequent checks depend on git, aborting" -ForegroundColor Red
  exit 1
}
$gitVerLine = (& git --version 2>$null) -join ' '
$gitVerMatch = [regex]::Match($gitVerLine, '(\d+\.\d+\.\d+)')
if (-not $gitVerMatch.Success) {
  Write-Ng "git version detection failed" "Unexpected 'git --version' output: $gitVerLine"
  Write-Host ""
  Write-Host "1 failed, 0 warn, 0 ok. Subsequent checks depend on git, aborting" -ForegroundColor Red
  exit 1
}
$gitVer = $gitVerMatch.Groups[1].Value
try {
  if ([version]$gitVer -ge [version]"2.48") {
    Write-Ok "git v$gitVer (>= 2.48)"
  } else {
    Write-Ng "git v$gitVer (>= 2.48 required)" "Upgrade git (README section 1 requirement; git worktree add --relative-paths is used)"
    Write-Host ""
    Write-Host "1 failed, 0 warn, 0 ok. Subsequent checks depend on git 2.48+, aborting" -ForegroundColor Red
    exit 1
  }
} catch {
  Write-Ng "git version parse failed (got '$gitVer')" "Unexpected 'git --version' output"
  Write-Host ""
  Write-Host "1 failed, 0 warn, 0 ok. Subsequent checks depend on git, aborting" -ForegroundColor Red
  exit 1
}

# git OK; now resolve repo root (git-common-dir based: handles stage worktrees too).
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

# 1. sbx CLI in PATH + v0.31+ (--clone added in v0.31)
$sbxCmd = Get-Command sbx -ErrorAction SilentlyContinue
if ($sbxCmd) {
  # `sbx version` returns `sbx version: vX.Y.Z <commit>`
  $verLine = (& sbx version 2>$null) -join ' '
  $verMatch = [regex]::Match($verLine, 'v(\d+\.\d+\.\d+)')
  if ($verMatch.Success) {
    $ver = $verMatch.Groups[1].Value
    try {
      if ([version]$ver -ge [version]"0.31") {
        Write-Ok "sbx CLI v$ver (>= 0.31)"
      } else {
        Write-Ng "sbx CLI v$ver (>= 0.31 required)" "Upgrade sbx: https://docs.docker.com/ai/sandboxes/"
      }
    } catch {
      Write-Ng "sbx CLI version parse failed (got '$ver')" "Unexpected 'sbx version' output"
    }
  } else {
    Write-Ng "sbx CLI version detection failed" "Unexpected 'sbx version' output: $verLine"
  }
} else {
  Write-Ng "sbx CLI not in PATH" "Install Docker Desktop with Sandboxes (sbx) per README section 1-1"
}

# 2. Docker daemon reachable
# Guard with Get-Command first: when docker.exe is absent, `& docker info` raises CommandNotFoundException without touching $LASTEXITCODE,
# which would otherwise inherit the prior native command's success and false-OK.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-Ng "docker CLI not in PATH" "Install Docker Desktop (sbx depends on the docker daemon)"
} else {
  & docker info > $null 2>&1
  if ($LASTEXITCODE -eq 0) {
    Write-Ok "Docker daemon"
  } else {
    Write-Ng "Docker daemon unreachable" "Start Docker Desktop (sbx depends on the docker daemon)"
  }
}

# 3. anthropic / github / openai secrets (global). column layout differs across sbx versions
# (old: SCOPE SERVICE SECRET / new: SCOPE TYPE NAME SECRET), so probe every column on (global) rows instead of hard-coding column index.
$secretsRaw = & sbx secret ls -g 2>$null
$secrets = @($secretsRaw)
$hasAnthropic = $false
$hasGithub = $false
$hasOpenai = $false
foreach ($line in $secrets) {
  $cols = ($line -split '\s+') | Where-Object { $_ -ne '' }
  if ($cols.Count -lt 2 -or $cols[0] -ne '(global)') { continue }
  for ($i = 1; $i -lt $cols.Count; $i++) {
    if ($cols[$i] -ceq 'anthropic') { $hasAnthropic = $true }
    if ($cols[$i] -ceq 'github')    { $hasGithub    = $true }
    if ($cols[$i] -ceq 'openai')    { $hasOpenai    = $true }
  }
}
if ($hasAnthropic) {
  Write-Ok "sbx secret 'anthropic' (global) registered (OAuth validity verified when pwsh scripts/dev.ps1 starts)"
} else {
  Write-Ng "sbx secret 'anthropic' (global) missing" "Run: claude setup-token | sbx secret set -g anthropic (README section 1-2)"
}
if ($hasGithub) {
  Write-Ok "sbx secret 'github' (global) registered"
} else {
  Write-Ng "sbx secret 'github' (global) missing" "Mint a fine-grained PAT at https://github.com/settings/personal-access-tokens/new and run: sbx secret set -g github (README section 1-2)"
}
if ($hasOpenai) {
  Write-Ok "sbx secret 'openai' (global) registered (codex CLI in cdx-<NAME> reviewer boxes; recreate via 'pwsh scripts/dev.ps1' after rotating this secret)"
} else {
  Write-Ng "sbx secret 'openai' (global) missing" "Run: sbx secret set -g openai --oauth (README section 1-2)"
}

# 5. image template loaded + Dockerfile staleness + build age
$templateLines = @(& sbx template ls 2>$null)
$hasImage = $false
foreach ($line in $templateLines) {
  $cols = ($line -split '\s+') | Where-Object { $_ -ne '' }
  # Accept both `docker.io/library/coding-agent-playbook-sbx` and bare `coding-agent-playbook-sbx` (varies by sbx version)
  if ($cols.Count -ge 1 -and ($cols[0] -ceq 'docker.io/library/coding-agent-playbook-sbx' -or $cols[0] -ceq 'coding-agent-playbook-sbx')) {
    $hasImage = $true
    break
  }
}
if ($hasImage) {
  # A/B: staleness + build age from the stamp file written by build-image.ps1 after a successful sbx template load
  # (line 1 = Dockerfile commit, line 2 = build time). docker inspect (local image) can diverge from the sbx
  # template store (build/save ok, load fails -> only local is fresh), so the stamp is authoritative.
  $stampPath  = ".claude/tmp/sbx-template-commit.stamp"
  $stampLines = if (Test-Path -LiteralPath $stampPath) { @(Get-Content -LiteralPath $stampPath -ErrorAction SilentlyContinue) } else { @() }
  $imgCommit  = if ($stampLines.Count -ge 1) { $stampLines[0].Trim() } else { "" }
  $buildTime  = if ($stampLines.Count -ge 2) { $stampLines[1].Trim() } else { "" }
  $dfCommit   = (git log --format="%H" -n1 -- sbx/Dockerfile 2>$null) -join ""
  # Guard Substring: a corrupt/truncated stamp or a failed git resolve must still emit a WARN, not throw
  # (bash's ${x:0:7} degrades gracefully; .Substring throws on short input, so guard to keep the pair aligned).
  $dfShort  = if ($dfCommit.Length  -ge 7) { $dfCommit.Substring(0,7) }  else { "<unknown>" }
  $imgShort = if ($imgCommit.Length -ge 7) { $imgCommit.Substring(0,7) } else { "<invalid>" }
  if (-not $imgCommit) {
    Write-Warn "image template exists but staleness stamp is missing (pre-feature build)" "Run: pwsh scripts/build-image.ps1"
  } elseif (-not $dfCommit) {
    Write-Warn "could not resolve sbx/Dockerfile commit (git log returned empty)" "Verify sbx/Dockerfile is tracked, then rerun setup check"
  } elseif ($imgCommit -ne $dfCommit) {
    Write-Warn "sbx/Dockerfile has been updated (image is stale, $dfShort != $imgShort)" "Run: pwsh scripts/build-image.ps1"
  } else {
    Write-Ok "image template 'coding-agent-playbook-sbx' loaded (sbx/Dockerfile: $dfShort)"
  }
  # B: build age -- warn when image is 30+ days old (claude / codex may be outdated).
  #    ParseExact with InvariantCulture avoids non-Gregorian calendar issues.
  if ($buildTime) {
    try {
      $buildDt = [DateTimeOffset]::ParseExact($buildTime, "yyyy-MM-ddTHH:mm:ssZ", [System.Globalization.CultureInfo]::InvariantCulture)
      $ageDays = ([DateTimeOffset]::UtcNow - $buildDt).Days
      if ($ageDays -ge 30) {
        Write-Warn "image is $ageDays days old (claude / codex may be outdated)" "Run: pwsh scripts/build-image.ps1 to update to the latest versions"
      }
    } catch {}
  }
} else {
  Write-Ng "image template 'coding-agent-playbook-sbx' not loaded" "Run: pwsh scripts/build-image.ps1 (README section 1-1)"
}

# 6. per-NAME pair reviewer boxes (cdx-*): debate 2026-06-27 onwards the singleton cdx-review is gone; each bind-mount `dev.ps1 <NAME>` auto-provisions its own cdx-<NAME>.
#    check-setup only verifies the prerequisites (openai secret + image) above; it does not know a particular workshop NAME. List existing cdx-* boxes as info; orphan/running detection lives in the dev.ps1 trap.
$existingBoxes = @(& sbx ls -q 2>$null)
$cdxBoxes = @($existingBoxes | Where-Object { $_ -clike 'cdx-*' })
if ($cdxBoxes.Count -gt 0) {
  Write-Ok "cdx-* reviewer boxes present ($($cdxBoxes.Count) box(es)): $($cdxBoxes -join ' ')"
} else {
  Write-Ok "cdx-* reviewer boxes absent (auto-provisioned as cdx-<NAME> on first 'pwsh scripts/dev.ps1')"
}

# 7. stage/* branches available (warn level; only needed when you actually want to open a stage - 'git switch stage/NN')
$stageRefs = @(git for-each-ref --format='x' 'refs/heads/stage/' 'refs/remotes/origin/stage/')
if ($stageRefs.Count -gt 0) {
  Write-Ok "stage branches available ($($stageRefs.Count) ref(s))"
} else {
  Write-Warn "no stage/* branches found" "Run: git fetch origin (when forking, uncheck 'Copy the main branch only' so all branches are forked)"
}

# 8. runtime probe (ephemeral box -> repo-scoped gh pr list). Skip when -Quick, prerequisites missing, or docker NG.
# gh auth status only checks account auth state, missing repository access / scope (Pull requests RW etc) shortfalls;
# `gh pr list -R <slug> --limit 1` verifies (a) PAT auth (b) Repository access includes target repo (c) Pull requests scope in one call.
if (-not $Quick -and $hasImage -and $hasGithub) {
  Write-Host ""
  Write-Host "Runtime probe (verify auth chain inside an ephemeral box; -Quick to skip):"
  # Derive slug from git remote (README section 1 does not require host gh CLI; git is a section 1 prerequisite).
  $remoteUrl = (& git remote get-url origin 2>$null) -join ''
  $repoSlug = $remoteUrl -replace '^.*github\.com[:/]', '' -replace '\.git$', ''
  if ([string]::IsNullOrWhiteSpace($repoSlug) -or ($repoSlug -notmatch '^[^/]+/[^/]+$')) {
    Write-Ng "Failed to resolve target repo slug (git remote get-url origin did not return a GitHub URL)" "Ensure CWD is a git repo with a github.com origin (got: '$remoteUrl')"
  } else {
    # Docker container name convention (leading alphanumeric, then alphanumeric/hyphen). PID XOR mitigates concurrent-invocation TOCTOU.
    $rand = (Get-Random -Maximum 0xffffff) -bxor ($PID -band 0xffffff)
    $probeBox = "check-setup-$('{0:x6}' -f $rand)"
    Write-Host "  starting ephemeral box '$probeBox' (~15s)..."
    # Same agent + image + kit as dev.ps1: sbx's secret proxy injection is guaranteed only under the built-in claude agent (see sbx/README.md). Probing with shell may pass in some envs but risks false OK/NG when agent-type changes proxy behavior.
    & sbx create --clone claude . --name $probeBox -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
      try {
        # (a) Pull requests RO + Repository access (RW probe would require destructive PR/commit creation; rely on workshop's gh pr create surfacing RW shortfall)
        & sbx exec $probeBox gh pr list -R $repoSlug --limit 1 > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
          # (b) Actions RO (required by /pr-codex-ci's gh pr checks; docs/setup.md lists it as mandatory)
          & sbx exec $probeBox gh api "repos/$repoSlug/actions/runs?per_page=1" > $null 2>&1
          if ($LASTEXITCODE -eq 0) {
            Write-Ok "github PAT is valid (Pull requests RO + Actions RO + repository access for $repoSlug)"
          } else {
            $errOut = (& sbx exec $probeBox gh api "repos/$repoSlug/actions/runs?per_page=1" 2>&1) -join ' '
            Write-Ng "github PAT missing Actions: Read-only scope (/pr-codex-ci's gh pr checks will fail)" "Add Actions: Read-only to PAT permissions (docs/setup.md). Detail: $errOut"
          }
        } else {
          $errOut = (& sbx exec $probeBox gh pr list -R $repoSlug --limit 1 2>&1) -join ' '
          Write-Ng "github PAT auth failed (expired / revoked / Repository access missing '$repoSlug' / insufficient Pull requests scope)" "Re-mint the PAT and re-register via sbx secret set -g github (detail: $errOut)"
        }
      } finally {
        # Cleanup ephemeral box even on probe failure
        & sbx rm -f $probeBox > $null 2>&1
      }
    } else {
      Write-Ng "ephemeral box creation failed" "sbx create --clone claude . --name $probeBox -t coding-agent-playbook-sbx --kit ./sbx/playbook-kit failed; image / kit broken or docker daemon issue"
    }
  }
}

# 9. a2a-doctor (per-NAME pair reviewer serve liveness: lease file + TCP probe). Mirrors scripts/check-setup.sh.
#    Goal: surface missing reviewers at session start instead of letting /pr-codex-ci fail at the end of the chain.
#    per-NAME pair leases live at `.claude/tmp/cdx-serve-<NAME>.lease` (written by the bg pair-serve started by dev.ps1).
#    Skip with -Quick (host TCP can take time on locked-down networks).
if (-not $Quick) {
  Write-Host ""
  Write-Host "a2a-doctor (per-NAME pair reviewer liveness; -Quick to skip):"
  function Test-CdxTcp($p) {
    try {
      $client = New-Object System.Net.Sockets.TcpClient
      $iar = $client.BeginConnect('127.0.0.1', [int]$p, $null, $null)
      $success = $iar.AsyncWaitHandle.WaitOne(1000)
      if ($success -and $client.Connected) { $client.EndConnect($iar); $client.Close(); return $true }
      $client.Close()
      return $false
    } catch { return $false }
  }
  $leaseFiles = @(Get-ChildItem -LiteralPath '.claude/tmp' -Filter 'cdx-serve-*.lease' -File -ErrorAction SilentlyContinue)
  if ($leaseFiles.Count -eq 0) {
    Write-Warn "per-NAME pair reviewer not running (no lease)" "For /pr-codex-ci or /a2a-review inside a box: start 'pwsh scripts/dev.ps1' on host (dev.ps1 auto-provisions cdx-<NAME> and bg-forks pair-serve)"
  } else {
    foreach ($lf in $leaseFiles) {
      try { $lease = Get-Content -LiteralPath $lf.FullName -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $lease = $null }
      if ($null -eq $lease) {
        Write-Ng "lease file unreadable: $($lf.Name)" "Remove-Item $($lf.FullName) ; then restart host: pwsh scripts/dev.ps1 <NAME-from-file>"
        continue
      }
      $cdxPid = [int]$lease.pid
      $cdxLeaseSt = if ($lease.start_time) { $lease.start_time } else { "" }
      $cdxLeaseKind = if ($lease.start_time_kind) { $lease.start_time_kind } else { "" }
      $cdxPort = if ($lease.port) { $lease.port } else { 9999 }
      $cdxClaudeBox = if ($lease.claude_box) { $lease.claude_box } else { "" }
      $proc = Get-Process -Id $cdxPid -ErrorAction SilentlyContinue
      if ($null -ne $proc) {
        # PID alive: verify start_time to detect PID reuse (Get-Process succeeds for recycled PIDs).
        # Compare only when start_time_kind is "ticks" (this script's format); cross-language leases (bash proc/lstart) fall back to pid-only.
        $pidReused = $false
        if ($cdxLeaseSt -and $cdxLeaseKind -eq 'ticks') {
          $curSt = try { $proc.StartTime.Ticks.ToString() } catch { "" }
          if ($curSt -and $curSt -ne $cdxLeaseSt) { $pidReused = $true }
        }
        if ($pidReused) {
          Write-Ng "lease PID reused (claude_box='$cdxClaudeBox', pid=$cdxPid; pair-serve is dead)" "Remove-Item $($lf.FullName) ; then restart host: pwsh scripts/dev.ps1 $cdxClaudeBox"
        } elseif (Test-CdxTcp $cdxPort) {
          Write-Ok "pair reviewer up (claude_box='$cdxClaudeBox', pid=$cdxPid, port=$cdxPort)"
        } else {
          Write-Ng "lease alive (claude_box='$cdxClaudeBox', pid=$cdxPid) but TCP $cdxPort unresponsive (serve starting / port conflict / proxy block)" "Restart on host: pwsh scripts/dev.ps1 $cdxClaudeBox (re-forks pair-serve)"
        }
      } else {
        Write-Ng "lease present but PID is dead (claude_box='$cdxClaudeBox'; dev.ps1 crashed without trap cleanup)" "Remove the stale lease: Remove-Item $($lf.FullName) ; then restart host: pwsh scripts/dev.ps1 $cdxClaudeBox"
      }
    }
  }
}

Write-Host ""
if ($script:NG -eq 0 -and $script:WARN -eq 0) {
  Write-Host "All checks passed" -ForegroundColor Green -NoNewline
  Write-Host " ($script:OK ok). README section 2 is reachable (pwsh scripts/dev.ps1)"
  exit 0
} elseif ($script:NG -eq 0) {
  Write-Host "$script:OK ok" -ForegroundColor Green -NoNewline
  Write-Host ", " -NoNewline
  Write-Host "$script:WARN warn" -ForegroundColor Yellow -NoNewline
  Write-Host ". Workshop main flow is OK (WARN is optional)"
  exit 0
} else {
  Write-Host "$script:NG failed" -ForegroundColor Red -NoNewline
  Write-Host ", " -NoNewline
  Write-Host "$script:WARN warn" -ForegroundColor Yellow -NoNewline
  Write-Host ", $script:OK ok. Follow the NG hints and rerun"
  exit 1
}
