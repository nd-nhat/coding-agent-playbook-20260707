# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# Host helper: lifecycle for the per-NAME pair (claude box `<NAME>` + reviewer box `cdx-<NAME>`) plus the A2A client call.
# Design: dev.ps1 stays call-only and lifecycle responsibility lives here (debate 2026-06-27 decision; avoids the bash-supervisor anti-pattern).
#   Startup order: pair-setup (create + bootstrap) -> pair-serve (publish + policy + lease + foreground hold) -> pair-teardown (kill + rm + lease delete)

param(
  [Parameter(Position = 0)][string]$Command = "help",
  [Parameter(Position = 1)][string]$Arg1,
  [Parameter(Position = 2)][string]$Arg2
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$CdxBoxPrefix = "cdx"
$ServerPortInBox = "9999"
$ExampleDir = "tools/a2a-review"

# main checkout root: resolves even from a worktree (box direct-mounts the main root so .worktrees/<NN>/ is visible too).
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

function Get-CdxBoxName($name) { return "$CdxBoxPrefix-$name" }
function Get-LeasePath($name) { return ".claude/tmp/cdx-serve-$name.lease" }

# Validate the claude box NAME (same convention as dev.ps1) so pair-* can refuse malformed input early.
function Test-Name($name) {
  if (-not $name) { Write-Error "NAME is empty"; exit 1 }
  if ($name -notmatch '\A[A-Za-z0-9][A-Za-z0-9-]*\z') {
    Write-Error "NAME '$name' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only)"
    exit 1
  }
}

# start_time alongside pid for PID reuse detection (kill-0/Get-Process succeeds after PID recycling; start_time disambiguates).
# start_time_kind=ticks tags the .NET format so a bash reader (proc/lstart) skips comparison instead of false-flagging reuse.
# Project-root relative path so the same path is visible from a bind-mounted box.
function Write-Lease($leasePath, $pid_, $port_, $claudeBox_, $cdxBox_, $advertise_, $repoRoot_) {
  $dir = Split-Path -Parent $leasePath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $epoch = [int]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  $st = Get-ProcStartTime ([int]$pid_)
  $json = '{"pid":' + $pid_ + ',"start_time":"' + $st + '","start_time_kind":"ticks","port":' + $port_ + ',"claude_box":"' + $claudeBox_ + '","cdx_box":"' + $cdxBox_ + '","advertise":"' + $advertise_ + '","started_at":' + $epoch + ',"repo_root":"' + ($repoRoot_ -replace '\\', '/') + '"}'
  Set-Content -LiteralPath $leasePath -Value $json -Encoding ASCII
}

function Remove-Lease($leasePath) {
  if (Test-Path $leasePath) { Remove-Item -LiteralPath $leasePath -Force -ErrorAction SilentlyContinue }
}

function Show-Usage {
  Write-Host "usage: powershell -ExecutionPolicy Bypass -File scripts/internal/a2a-review.ps1 <command> [args]"
  Write-Host "  pair-setup <NAME> [workspace]   create cdx-<NAME> reviewer box + bootstrap (once; dev.ps1 auto-calls)"
  Write-Host "  pair-serve <NAME>               start the cdx-<NAME> A2A server, publish the port, allow egress, write the lease, hold foreground (dev.ps1 bg-fork)"
  Write-Host "  pair-teardown <NAME>            kill the cdx-<NAME> server, remove the box, delete the lease (dev.ps1 trap)"
  Write-Host "  ask <instruction> [url]         call the codex reviewer from inside a claude box. URL default = `$A2A_CODEX_URL or host.docker.internal:9999"
  Write-Host "  help"
  Write-Host "codex box needs the openai OAuth secret (sbx secret set -g openai --oauth). See tools/a2a-review/README.md"
}

# Throws on `sbx ls` failure so callers distinguish "not found" from "cannot determine" (transient daemon error; do not treat as "box gone").
function Test-BoxExists($name) {
  $rows = sbx ls 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "'sbx ls' failed (exit $LASTEXITCODE) -- transient daemon error; cannot determine whether '$name' exists"
  }
  foreach ($line in $rows) {
    $first = ($line.Trim() -split '\s+')[0]
    if ($first -eq $name) { return $true }
  }
  return $false
}

# Falls back to "" on any error; callers treat "" as unknown and skip the start_time check.
function Get-ProcStartTime([int]$pid_) {
  try {
    $proc = Get-Process -Id $pid_ -ErrorAction Stop
    return $proc.StartTime.Ticks.ToString()
  } catch { return "" }
}

function Test-ServerUp($cdxBox) {
  sbx exec $cdxBox sh -lc "curl -fsS http://127.0.0.1:$ServerPortInBox/.well-known/agent-card.json >/dev/null 2>&1"
  return ($LASTEXITCODE -eq 0)
}

function Wait-ServerDown($cdxBox) {
  for ($i = 0; $i -lt 10; $i++) {
    if (-not (Test-ServerUp $cdxBox)) { return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

function Initialize-CdxBox($cdxBox, $workspace) {
  $boxExists = $false
  try { $boxExists = Test-BoxExists $cdxBox } catch {
    Write-Error "sbx ls failed (transient daemon error); cannot determine whether '$cdxBox' exists. Retry."
    exit 1
  }
  if ($boxExists) {
    Write-Host "box '$cdxBox' exists."
  } else {
    sbx create --name $cdxBox codex -t coding-agent-playbook-sbx $workspace
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
  # .venv lives in the host bind-mount under `tools/a2a-review/...`, so it is shared across every cdx-<NAME> box.
  # Serialize parallel `dev.ps1 foo` / `dev.ps1 bar` bootstrap via a directory lock (`New-Item -ItemType Directory` is the atomic-create primitive).
  # Wait indefinitely while the holding pid is alive (codex R9 finding: force-take after 120s would mid-install corrupt the venv when uv pip install takes longer than that). Stale (dead pid) entries are removed and retried immediately. A 10-minute alive-lock timeout reports an error and exits, prompting manual cleanup, instead of corrupting the install.
  $venvLockDir = ".claude/tmp/cdx-venv-bootstrap.lock.d"
  if (-not (Test-Path -LiteralPath ".claude/tmp")) {
    New-Item -ItemType Directory -Path ".claude/tmp" -Force | Out-Null
  }
  $acquired = $false
  for ($attempt = 0; $attempt -lt 600; $attempt++) {
    try {
      New-Item -ItemType Directory -Path $venvLockDir -ErrorAction Stop | Out-Null
      $acquired = $true
      break
    } catch {}
    $heldPidStr = Get-Content -LiteralPath "$venvLockDir/pid" -Raw -ErrorAction SilentlyContinue
    $heldPid = 0
    if ($heldPidStr -and [int]::TryParse($heldPidStr.Trim(), [ref]$heldPid) -and -not (Get-Process -Id $heldPid -ErrorAction SilentlyContinue)) {
      Write-Host "info: stale venv bootstrap lock (pid=$heldPid dead) removed" -ForegroundColor Yellow
      Remove-Item -LiteralPath $venvLockDir -Recurse -Force -ErrorAction SilentlyContinue
      continue
    }
    Start-Sleep -Seconds 1
  }
  if (-not $acquired) {
    Write-Error "venv bootstrap lock held for 10 minutes by an alive pid; suspecting hang. Manually verify and run 'Remove-Item -LiteralPath $venvLockDir -Recurse -Force' before retrying."
    exit 1
  }
  Set-Content -LiteralPath "$venvLockDir/pid" -Value "$PID" -ErrorAction SilentlyContinue
  try {
    if (-not (Test-Path "$ExampleDir/codex-a2a-server/.venv/bin/python")) {
      sbx exec $cdxBox sh -lc 'cd "$1" && uv venv && uv pip install -e .' "_" "$ExampleDir/codex-a2a-server"
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    if (-not (Test-Path "$ExampleDir/client-demo/.venv/bin/python")) {
      sbx exec $cdxBox sh -lc 'cd "$1" && uv venv && uv pip install -e .' "_" "$ExampleDir/client-demo"
      if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
  } finally {
    Remove-Item -LiteralPath $venvLockDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-PairSetup($name, $workspace) {
  Test-Name $name
  if (-not $workspace) { $workspace = (Get-Location).Path }
  Initialize-CdxBox (Get-CdxBoxName $name) $workspace
  Write-Host "pair-setup complete: $(Get-CdxBoxName $name). Start the server with: powershell -File scripts/internal/a2a-review.ps1 pair-serve $name"
}

# dev.ps1 bg-forks pair-serve, so this function holds the server in the foreground (Wait-Job-equivalent) until dev.ps1's trap kills it (debate 2026-06-27).
# Ports use kernel ephemeral allocation (`sbx ports --publish 9999`) and we read the assigned host port back from `sbx ports <box>`; no hash / registry (debate Antigravity proposal, collision-free).
function Invoke-PairServe($name) {
  $cdxBox = Get-CdxBoxName $name
  $leasePath = Get-LeasePath $name

  $boxExists = $false
  try { $boxExists = Test-BoxExists $cdxBox } catch {
    Write-Error "sbx ls failed (transient daemon error); cannot determine whether '$cdxBox' exists. Retry."
    exit 1
  }
  if (-not $boxExists) {
    Write-Error "cdx box '$cdxBox' not found. Run pair-setup first: powershell -File scripts/internal/a2a-review.ps1 pair-setup $name"
    exit 1
  }

  # Kill any stale server (re-serve). [s] char class so pkill does not match itself.
  sbx exec $cdxBox sh -lc 'pkill -f "[s]erver.py" 2>/dev/null; true' 2>$null
  if (-not (Wait-ServerDown $cdxBox)) {
    Write-Error "the old server did not exit within 10s. box log: sbx exec $cdxBox cat /tmp/a2a-server.log"
    exit 1
  }

  # Unpublish a stale mapping if one is still around (idempotent re-serve).
  $oldHostport = ""
  $portRows = sbx ports $cdxBox 2>$null
  if ($LASTEXITCODE -eq 0) {
    foreach ($row in $portRows) {
      $cols = $row.Trim() -split '\s+'
      if ($cols.Count -ge 4 -and $cols[0] -eq '127.0.0.1' -and $cols[2] -eq "$ServerPortInBox" -and $cols[3] -eq 'tcp') {
        $oldHostport = $cols[1]
        break
      }
    }
  }
  if ($oldHostport) {
    sbx ports $cdxBox --unpublish ("$oldHostport`:$ServerPortInBox") 2>$null | Out-Null
  }

  # Publish first so the advertise URL can include the kernel-assigned host port. The cdx box keeps itself alive while the server runs inside it.
  sbx ports $cdxBox --publish $ServerPortInBox
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  $hostport = ""
  $portRows = sbx ports $cdxBox 2>$null
  if ($LASTEXITCODE -eq 0) {
    foreach ($row in $portRows) {
      $cols = $row.Trim() -split '\s+'
      if ($cols.Count -ge 4 -and $cols[0] -eq '127.0.0.1' -and $cols[2] -eq "$ServerPortInBox" -and $cols[3] -eq 'tcp') {
        $hostport = $cols[1]
        break
      }
    }
  }
  if (-not $hostport) {
    Write-Error "could not resolve the cdx-$name host port (publish failed?)"
    sbx ports $cdxBox 2>&1 | Write-Host
    exit 1
  }
  $advertise = "http://host.docker.internal:$hostport"

  # dev.ps1 bg-forks Invoke-PairServe while concurrently `sbx run`-creating the claude box; the policy fails with "sandbox not found" if the box has not appeared yet, so retry for up to 60s.
  $policyOk = $false
  for ($i = 0; $i -lt 60; $i++) {
    sbx policy allow network --sandbox $name "localhost:$hostport" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $policyOk = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $policyOk) {
    Write-Error "claude box '$name' did not appear within 60s; policy allocation failed"
    exit 1
  }

  Write-Host "starting+holding codex server (advertise=$advertise, SIGTERM to stop)..."
  $serverScript = 'cd "$1" && A2A_ADVERTISE_URL="$2" exec .venv/bin/python server.py >/tmp/a2a-server.log 2>&1'
  # Start-Job (not Start-Process -ArgumentList, which mangles the spaced sh -lc script on PS 5.1) so each argv is passed atomically.
  $job = Start-Job -ScriptBlock {
    param($b, $script, $path, $adv)
    sbx exec $b sh -lc $script "_" $path $adv
  } -ArgumentList $cdxBox, $serverScript, "$ExampleDir/codex-a2a-server", $advertise

  try {
    $up = $false
    for ($i = 0; $i -lt 30; $i++) {
      if (Test-ServerUp $cdxBox) { $up = $true; break }
      if ($job.State -ne "Running") {
        Write-Error "server process exited. box log: sbx exec $cdxBox cat /tmp/a2a-server.log"
        exit 1
      }
      Start-Sleep -Seconds 1
    }
    if (-not $up) {
      Write-Error "server did not come up. box log: sbx exec $cdxBox cat /tmp/a2a-server.log"
      exit 1
    }
    Write-Lease $leasePath $PID $hostport $name $cdxBox $advertise (Get-Location).Path
    Write-Host "codex reviewer ready (box=$cdxBox, $advertise). From inside box '$name': bash scripts/internal/a2a-review.sh ask `"<instruction>`""
    Wait-Job $job | Out-Null
  } finally {
    # Stop-Job does not reliably kill the job's external children on PS 5.1, so also pkill the box server directly.
    sbx exec $cdxBox sh -lc 'pkill -f "[s]erver.py" 2>/dev/null; true' 2>$null
    Stop-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    # Revoke the per-port allow rule before destroying the lease (codex review 2026-06-27 finding: stale ephemeral host-port rules accumulate and may leak when the OS recycles the port).
    sbx policy rm network --sandbox $name --resource "localhost:$hostport" 2>$null | Out-Null
    Remove-Lease $leasePath
  }
}

# Safe to invoke multiple times (pair-serve's own finally and dev.ps1's trap both call it).
# pair-serve's finally already revokes the policy in the normal path; we re-read the lease here to also handle orphan boxes left by a crashed dev.ps1.
function Invoke-PairTeardown($name) {
  Test-Name $name
  $cdxBox = Get-CdxBoxName $name
  $leasePath = Get-LeasePath $name
  $teardownFailed = $false
  if (Test-Path -LiteralPath $leasePath) {
    try {
      $lease = Get-Content -LiteralPath $leasePath -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($lease.port) {
        # policy rm failure: keep the lease so the host port (the only anchor for sbx policy revoke) survives for a retry.
        sbx policy rm network --sandbox $name --resource ("localhost:" + $lease.port) 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { $teardownFailed = $true }
      }
    } catch {}
  }
  $boxCheck = $false
  $sbxLsFailed = $false
  try { $boxCheck = Test-BoxExists $cdxBox } catch { $sbxLsFailed = $true }
  if ($sbxLsFailed) {
    Write-Host "warning: sbx ls failed (transient); teardown aborted (lease preserved for retry)." -ForegroundColor Yellow
    $teardownFailed = $true
  } elseif ($boxCheck) {
    sbx exec $cdxBox sh -lc 'pkill -f "[s]erver.py" 2>/dev/null; true' 2>$null
    & sbx rm -f $cdxBox 2>$null | Out-Null
    # `sbx rm` exit code is not always reliable (silent suppression cases), so re-list to verify the box is actually gone.
    $rmCheck = $false
    $rmLsFailed = $false
    try { $rmCheck = Test-BoxExists $cdxBox } catch { $rmLsFailed = $true }
    if ($rmLsFailed) {
      Write-Host "warning: sbx ls failed after sbx rm; cannot verify removal (lease preserved)." -ForegroundColor Yellow
      $teardownFailed = $true
    } elseif ($rmCheck) { $teardownFailed = $true }
    # else: box is gone = success
  }
  if ($teardownFailed) {
    # Preserve the lease and exit non-zero so callers that care (e.g. prune) can detect the partial failure.
    # Existing callers (cmd_kill / dev.ps1 trap teardown) already swallow the exit code, so this change only affects exit-code-aware callers.
    exit 1
  }
  Remove-Lease $leasePath
}

# The NO_PROXY bracket-IPv6 httpx crash is sanitized in client.py.
# URL resolution order: explicit arg -> $A2A_CODEX_URL -> per-NAME lease (`.claude/tmp/cdx-serve-$SANDBOX_VM_ID.lease`) advertise field -> legacy fallback 9999 (warn).
function Invoke-Ask($instruction, $url) {
  if (-not $instruction) { Write-Error "ask needs an instruction"; Show-Usage; exit 1 }
  if (-not $url) {
    if ($env:A2A_CODEX_URL) {
      $url = $env:A2A_CODEX_URL
    } elseif ($env:SANDBOX_VM_ID) {
      $leasePath = Get-LeasePath $env:SANDBOX_VM_ID
      if (Test-Path -LiteralPath $leasePath) {
        try {
          $lease = Get-Content -LiteralPath $leasePath -Raw -ErrorAction Stop | ConvertFrom-Json
          if ($lease.advertise) { $url = $lease.advertise }
        } catch {}
      }
    }
    if (-not $url) {
      $url = "http://host.docker.internal:9999"
      Write-Host "warning: URL could not be resolved, falling back to legacy default $url (per-NAME pair lease missing)"
    }
  }
  $clientDir = "$ExampleDir/client-demo"
  $py = $null
  if (Test-Path "$clientDir/.venv/bin/python") { $py = "$clientDir/.venv/bin/python" }
  elseif (Test-Path "$clientDir/.venv/Scripts/python.exe") { $py = "$clientDir/.venv/Scripts/python.exe" }
  if (-not $py) {
    Write-Host "installing client..."
    Push-Location $clientDir
    uv venv; if ($LASTEXITCODE -ne 0) { Pop-Location; exit $LASTEXITCODE }
    uv pip install -e .; if ($LASTEXITCODE -ne 0) { Pop-Location; exit $LASTEXITCODE }
    Pop-Location
    if (Test-Path "$clientDir/.venv/bin/python") { $py = "$clientDir/.venv/bin/python" } else { $py = "$clientDir/.venv/Scripts/python.exe" }
  }
  & $py "$clientDir/client.py" --server $url --review $instruction
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

switch ($Command) {
  "pair-setup"    { Invoke-PairSetup $Arg1 $Arg2 }
  "pair-serve"    { Test-Name $Arg1; Invoke-PairServe $Arg1 }
  "pair-teardown" { Invoke-PairTeardown $Arg1 }
  "ask" { Invoke-Ask $Arg1 $Arg2 }
  "help" { Show-Usage }
  default {
    Write-Error "unknown command '$Command' (try help)"
    Show-Usage
    exit 1
  }
}
