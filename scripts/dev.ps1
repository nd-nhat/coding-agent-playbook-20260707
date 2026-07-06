# ASCII only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.

# bind-mount dev session entry: auto-name (no arg) or named (idempotent attach-or-create) plus ls / attach / kill / sandbox / observe / shell / route subcommands.
# 'sandbox' is the throwaway clone-mode variant for parallel ad-hoc work; 'observe' is the read-only AWS-observability persona box; 'shell' drops you into a box's interactive bash without going through claude;
# 'route' publishes a box service as <name>.localhost via a Traefik routing layer (name default = web.<branch>.<repo>; verbs: up / add / rm / ls / down / detect).
#
# Lifecycle invariants:
#  - atomic dev lock (.claude/tmp/cdx-dev-<NAME>.lock) keeps 1 NAME = 1 dev session, with stale-pid auto-cleanup
#  - cdx-<NAME> reviewer pair is auto-provisioned only when the openai secret is registered, with a server .venv bootstrap verify
#  - pair-serve runs as a background job and writes to .claude/tmp/cdx-serve-<NAME>.log (so its output cannot bleed into the claude TUI)
#  - claude box TTY exit triggers pair-teardown plus lock/log cleanup
#  - lifecycle responsibility lives in scripts/internal/a2a-review.ps1 so this script stays call-only (avoids the bash-supervisor anti-pattern)

param(
  [Parameter(Position = 0)] [string]$Action = "",
  [Parameter(Position = 1)] [string]$Arg = "",
  # `-Yes` switch for `prune -Yes` (PowerShell parses `-Yes` as a named parameter, not as $Arg, so a top-level switch is required for confirmed pruning to work on Windows).
  [switch]$Yes,
  # `-All` switch for `prune -All` (adds CDX=none dev boxes as candidates, Docker `image prune --all` analog, active-lock guard reused).
  [switch]$All,
  # `-Quiet` / `-q` switch for `ls -q` (name-only output, Docker `docker ps -aq` compatible). Must be a top-level switch because PowerShell parses `-q` as a named parameter (same reason as -Yes / -All).
  [Alias('q')] [switch]$Quiet,
  # `route` subcommand needs >2 positional args (verb + box / name [+port [+name]]). Without ValueFromRemainingArguments,
  # PowerShell rejects positional args beyond Position 1 with "A positional parameter cannot be found that accepts argument".
  # Other subcommands assert this is empty (see dispatcher) to preserve the existing fail-fast contract.
  [Parameter(ValueFromRemainingArguments = $true)] [string[]]$RemainingArgs = @()
)

# PS 5.1 decodes native command output with the ANSI codepage; force UTF-8 so non-ASCII repo paths survive.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Template = "coding-agent-playbook-sbx"
$Kit = "./sbx/playbook-kit"
$KitKimi = "./sbx/playbook-kit-kimi"
$NameRe = '\A[A-Za-z0-9][A-Za-z0-9-]*\z'
$AppIdentityMarkerEnv = "APP_IDENTITY_ENABLE"
# Kimi fallback (for Anthropic outages, runbook: docs/guide/kimi-fallback.md): the marker launches new
# boxes' claude on the Kimi backend. The placeholder below is a public routing value, not a secret
# (the proxy swaps it for the real key only in requests to api.moonshot.ai; the key never enters the box).
$KimiMarkerEnv = "PLAYBOOK_KIMI_ENABLE"
$KimiMarkerPlaceholder = "playbook-kimi-enable"
$KimiKeyPlaceholder = "sbx-playbook-kimi-moonshot"
$KimiKeyHost = "api.moonshot.ai"

# Marker secret (an sbx custom secret) presence check, scoped to this box (per-box) or to all boxes
# (global). The value is never read (the host cannot read sbx secret values) - only its presence matters.
# App identity enable: sbx secret set-custom <box> --host app-identity.invalid --env APP_IDENTITY_ENABLE --value 1
function Test-MarkerSecretPresent {
  param([string]$Name, [string]$MarkerEnv)
  # Case-sensitive + exact-field match to mirror the bash awk (PowerShell -eq / -contains are case-insensitive
  # by default, which would cross-match APP_IDENTITY_ENABLE_OLD or a differently-cased box name).
  $lines = & sbx secret ls 2>$null
  if (-not $lines) { return $false }
  foreach ($line in $lines) {
    $fields = $line.Trim() -split '\s+'
    if ($fields.Count -lt 1) { continue }
    $scope = $fields[0]
    if ($scope -cne '(global)' -and $scope -cne $Name) { continue }
    if ($fields -ccontains $MarkerEnv) { return $true }
  }
  return $false
}

function Test-AppIdentityEnabled { param([string]$Name) return (Test-MarkerSecretPresent $Name $AppIdentityMarkerEnv) }
function Test-KimiEnabled        { param([string]$Name) return (Test-MarkerSecretPresent $Name $KimiMarkerEnv) }

# Whether the Kimi key (a global custom secret with the fixed placeholder) is registered. The placeholder
# is a public routing value, not a secret (the real key lives in the sbx store, masked on the host).
# Requires the placeholder AND the target host on the same row: a placeholder registered under a
# different host would pass through the proxy unreplaced.
function Test-KimiKeyRegistered {
  $lines = & sbx secret ls 2>$null
  if (-not $lines) { return $false }
  foreach ($line in $lines) {
    $fields = $line.Trim() -split '\s+'
    if ($fields.Count -lt 1) { continue }
    if ($fields[0] -cne '(global)') { continue }
    if (-not ($fields -ccontains $KimiKeyPlaceholder)) { continue }
    foreach ($f in $fields) {
      # The TARGETS column may hold comma-joined hosts; split and compare exactly (a substring
      # test would falsely accept a different host like notapi.moonshot.ai).
      foreach ($h in ($f -split ',')) {
        if ($h -ceq $KimiKeyHost -or $h -ceq "${KimiKeyHost}:443") { return $true }
      }
    }
  }
  return $false
}

# Creating a Kimi box without the key registered yields a box whose claude cannot authenticate anywhere
# (the placeholder is never replaced), so fail closed instead of the fail-open used for the openai skip:
# there the box still serves its main purpose, here it would not.
function Invoke-KimiPreflight {
  param([string]$Name)
  if (Test-KimiKeyRegistered) {
    Write-Host "info: box '$Name' will launch on the Kimi backend (kimi-k2.7-code) ($KimiMarkerEnv marker)." -ForegroundColor Cyan
    return
  }
  Write-Host "error: the $KimiMarkerEnv marker is set but the Moonshot API key (custom secret) is not registered (or was registered under a host other than $KimiKeyHost)." -ForegroundColor Red
  Write-Host "       register: sbx secret set-custom -g --host $KimiKeyHost --placeholder $KimiKeyPlaceholder --value <MOONSHOT_API_KEY>" -ForegroundColor Red
  Write-Host "       remove marker (global): sbx secret rm -g --placeholder $KimiMarkerPlaceholder -f" -ForegroundColor Red
  Write-Host "       remove marker (per-box): sbx secret rm $Name --placeholder $KimiMarkerPlaceholder -f  (details: docs/guide/kimi-fallback.md)" -ForegroundColor Red
  exit 1
}

# git-common-dir based: resolves to the main checkout root even when invoked from inside a stage worktree.
$gitCommonDir = git rev-parse --path-format=absolute --git-common-dir
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
# Capture the caller worktree branch BEFORE chdir (after Set-Location, git-common-dir resolves to the main
# checkout root and we lose the caller's feature-branch context). Used by the route subcommand's default
# name = web.<branch>.<repo>; other subcommands ignore it.
$DevCallerBranch = (git rev-parse --abbrev-ref HEAD 2>$null)
Set-Location -LiteralPath (Split-Path -Parent $gitCommonDir)

function Show-Usage {
  Write-Host @"
usage:
  pwsh scripts/dev.ps1                       start a new bind-mount box with an auto-generated name (workshop default)
  pwsh scripts/dev.ps1 <NAME>                idempotent attach-or-create against <NAME>
  pwsh scripts/dev.ps1 ls [-q]               list dev boxes (-q for name only, xargs-friendly)
  pwsh scripts/dev.ps1 attach [<NAME|N>]     attach to an existing dev box (no arg = picker)
  pwsh scripts/dev.ps1 kill <NAME|N>         stop a dev box (and its cdx-<NAME> reviewer pair)
  pwsh scripts/dev.ps1 prune [-Yes] [-All]   sweep orphan cdx pairs / stale leases / stale locks (-All also sweeps dev boxes: CDX=none plus leaked pairs)
                                             (-All adds CDX=none dev boxes themselves; no arg = dry-run)
  pwsh scripts/dev.ps1 sandbox [<NAME>]      throwaway clone box (no arg = sbx-<basename>-<hex6>,
                                             host checkout is NOT bind-mounted = parallel-safe)
  pwsh scripts/dev.ps1 observe [<NAME>]      read-only observe box for AWS observability (no arg = obs-<basename>-<hex6>,
                                             clone copy; inject AWS read-only cred / network allow on the host.
                                             steps: examples/observe/runbook.md, rules: rules/box-personas.md)
  pwsh scripts/dev.ps1 shell <NAME>          drop into the box's interactive bash without going through claude
                                             (thin wrapper around 'sbx exec -it <NAME> bash')
  pwsh scripts/dev.ps1 route <verb> [args]   publish a box service as <name>.localhost via Traefik
                                             (verb: up / add / rm / ls / down / detect; help with 'route help')
"@
}

function Test-NameValid {
  param([string]$Name)
  if ($Name -notmatch $NameRe) {
    Write-Error "name '$Name' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only)."
    exit 1
  }
  # All-digit names are rejected because attach/kill cannot disambiguate them from row indices (creating `dev.ps1 2` would cause `attach 2` to resolve to the second row from ls instead).
  if ($Name -match '\A\d+\z') {
    Write-Error "name '$Name' is purely numeric and ambiguous with attach/kill row indices. Include at least one non-digit character (a-z / A-Z / -)."
    exit 1
  }
  if ($Name -clike 'cdx-*') {
    Write-Error "name 'cdx-*' is reserved for the cdx-<NAME> reviewer box prefix. Pick another name."
    exit 1
  }
  if ($Name -clike 'sbx-*') {
    Write-Error "name 'sbx-*' is reserved for sandbox auto-name prefix (used by pwsh scripts/dev.ps1 sandbox). Pick another name."
    exit 1
  }
  if ($Name -clike 'obs-*') {
    Write-Error "name 'obs-*' is reserved for the observe box prefix (used by pwsh scripts/dev.ps1 observe). Pick another name."
    exit 1
  }
}

function New-DevName {
  $base = Split-Path -Leaf (Get-Location)
  $cleanBase = $base -replace '[^A-Za-z0-9-]', '-'
  $cleanBase = $cleanBase -replace '^-+|-+$', ''
  # Reserved-prefix collision guard: replace the basename with the fallback `box` when it matches a reserved prefix (cdx / cdx-* / sbx / sbx-*). One-pass stripping leaves nested cases like `cdx-sbx-playbook` still starting with `sbx-`, where the final candidate would fail validate / be hidden by discovery. The fallback approach handles all nested cases in a single check; the trade-off (basename <-> generated-name relation is lost) is acceptable since reserved-prefix basenames are rare.
  if ($cleanBase -clike 'cdx' -or $cleanBase -clike 'cdx-*' -or $cleanBase -clike 'sbx' -or $cleanBase -clike 'sbx-*' -or $cleanBase -clike 'obs' -or $cleanBase -clike 'obs-*') {
    $cleanBase = 'box'
  }
  if (-not $cleanBase) { $cleanBase = "box" }
  $existing = @(sbx ls -q 2>$null)
  if ($LASTEXITCODE -ne 0) { $existing = @() }
  # XOR the random suffix with the PID so two concurrent processes seeded the same way still pick different names (shrinks the TOCTOU window to effectively zero).
  $suffix = '{0:x6}' -f (((Get-Random -Maximum 16777216) -bxor $PID) -band 0xffffff)
  $candidate = "$cleanBase-$suffix"
  # -ccontains is case-sensitive; sbx box names are case-sensitive too. Refetch the sbx ls snapshot per iteration to mirror the bash version (avoids stale-snapshot races during retry).
  while ($existing -ccontains $candidate) {
    $suffix = '{0:x6}' -f (((Get-Random -Maximum 16777216) -bxor $PID) -band 0xffffff)
    $candidate = "$cleanBase-$suffix"
    $existing = @(sbx ls -q 2>$null)
    if ($LASTEXITCODE -ne 0) { $existing = @() }
  }
  return $candidate
}

# Dev box discovery derives from `sbx ls` minus the reserved prefixes (cdx-* reviewer pairs, sbx-* sandboxes). Avoids sbx label semantics and registry SSoT split-brain by relying on the naming convention only.
# Critical: do NOT key dev-box identity off cdx pair presence - fail-open dev boxes (openai secret absent or pair-setup failed) must still appear in ls/attach/kill. CDX state is derived separately in Invoke-Ls.
function Get-DevBoxNames {
  $all = @(sbx ls -q 2>$null)
  if ($LASTEXITCODE -ne 0) { return @() }
  $result = @()
  # -cnotlike is the case-sensitive wildcard negate (bare -notlike is case-insensitive in PowerShell). Without -c, a checkout named SBX-playbook or an explicit `dev.ps1 SBX-task` would create a box that Test-NameValid lets through (Test-NameValid uses -clike) but Get-DevBoxNames hides as a sandbox, breaking ls / picker attach / kill consistency.
  foreach ($n in $all) {
    if ($n -cnotlike 'cdx-*' -and $n -cnotlike 'sbx-*' -and $n -cnotlike 'obs-*') { $result += $n }
  }
  return $result
}

function Get-CdxBoxNames {
  $all = @(sbx ls -q 2>$null)
  if ($LASTEXITCODE -ne 0) { return @() }
  $result = @()
  foreach ($n in $all) {
    if ($n -clike 'cdx-*') { $result += $n.Substring(4) }
  }
  return $result
}

# Returns $true if the lease start_time indicates PID reuse (process identity changed).
# Compares only when start_time_kind is "ticks" (this script's format); cross-language leases
# (bash proc/lstart) fall back to pid-only to avoid false "reused" reports.
function Test-LeaseStartTimeReused($proc, $leaseSt, $leaseKind) {
  if (-not $leaseSt) { return $false }
  if ($leaseKind -ne 'ticks') { return $false }
  $curSt = try { $proc.StartTime.Ticks.ToString() } catch { "" }
  if (-not $curSt) { return $false }
  return ($curSt -ne $leaseSt)
}

# CDX status per dev box: none / orphan / ok (lease + pid alive + start_time match) / stale (pid dead or PID reused).
function Get-CdxStatus {
  param([string]$Name, [string[]]$CdxSet)
  if ($CdxSet -cnotcontains $Name) { return "none" }
  $lease = ".claude/tmp/cdx-serve-$Name.lease"
  if (-not (Test-Path -LiteralPath $lease)) { return "orphan" }
  $pidStr = ""; $leaseSt = ""; $leaseKind = ""
  # lease is JSON (written by scripts/internal/a2a-review.sh pair-serve); match fields with optional whitespace around colon.
  foreach ($line in (Get-Content -LiteralPath $lease -ErrorAction SilentlyContinue)) {
    if ($line -match '"pid"\s*:\s*(\d+)') { $pidStr = $matches[1] }
    if ($line -match '"start_time"\s*:\s*"([^"]*)"') { $leaseSt = $matches[1] }
    if ($line -match '"start_time_kind"\s*:\s*"([^"]*)"') { $leaseKind = $matches[1] }
  }
  if (-not $pidStr) { return "stale" }
  $proc = Get-Process -Id ([int]$pidStr) -ErrorAction SilentlyContinue
  if (-not $proc) { return "stale" }
  # PID alive: verify start_time to detect PID reuse (Get-Process succeeds for recycled PIDs).
  if (Test-LeaseStartTimeReused $proc $leaseSt $leaseKind) { return "stale" }
  return "ok"
}

function Invoke-Ls {
  param([switch]$Quiet)
  $names = @(Get-DevBoxNames)
  if ($names.Count -eq 0) {
    if (-not $Quiet) {
      Write-Host "(no dev box. Run 'pwsh scripts/dev.ps1' to start a new one.)"
    }
    return
  }
  # -q: name only (Docker `docker ps -aq` compatible, xargs-friendly). Use Write-Output (success stream) so external callers can capture / pipe / redirect the result; Write-Host would bypass the pipeline and make the quiet contract useless.
  if ($Quiet) {
    foreach ($n in $names) { Write-Output $n }
    return
  }
  $cdxSet = @(Get-CdxBoxNames)
  ("{0,-3}  {1,-32}  {2,-8}" -f "#", "NAME", "CDX") | Write-Host
  for ($i = 0; $i -lt $names.Count; $i++) {
    $status = Get-CdxStatus -Name $names[$i] -CdxSet $cdxSet
    ("{0,-3}  {1,-32}  {2,-8}" -f ($i + 1), $names[$i], $status) | Write-Host
  }
}

function Resolve-Target {
  param([string]$ArgValue)
  if ($ArgValue -match '^\d+$') {
    $names = @(Get-DevBoxNames)
    $idx = [int]$ArgValue - 1
    if ($idx -lt 0 -or $idx -ge $names.Count) {
      Write-Error "index $ArgValue is out of range (use 'pwsh scripts/dev.ps1 ls' to list)."
      exit 1
    }
    return $names[$idx]
  } else {
    Test-NameValid -Name $ArgValue
    return $ArgValue
  }
}

function Invoke-Attach {
  param([string]$ArgValue)
  if (-not $ArgValue) {
    $names = @(Get-DevBoxNames)
    switch ($names.Count) {
      0 {
        Write-Host "(no dev box. starting a new one with an auto-generated name)"
        Start-DevBox -Name ""
        return
      }
      1 {
        AttachOrStart -Name $names[0]
        return
      }
      default {
        Invoke-Ls
        $pick = Read-Host "select # to attach"
        if ($pick -notmatch '^\d+$') {
          Write-Error "numeric index required."
          exit 1
        }
        AttachOrStart -Name (Resolve-Target -ArgValue $pick)
        return
      }
    }
  }
  AttachOrStart -Name (Resolve-Target -ArgValue $ArgValue)
}

# Detect an active lock holder up front so the picker / numeric attach path returns a clear "session already attached" error (with a dev.ps1 shell hint) instead of falling through to Start-DevBox's later lock-acquire failure.
function AttachOrStart {
  param([string]$Name)
  $lockFile = ".claude/tmp/cdx-dev-$Name.lock"
  if (Test-Path -LiteralPath $lockFile) {
    $lockPidStr = Get-Content -LiteralPath $lockFile -Raw -ErrorAction SilentlyContinue
    $lockPid = 0
    if ($lockPidStr -and [int]::TryParse($lockPidStr.Trim(), [ref]$lockPid) -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
      Write-Error "dev box '$Name' is already active in another session (pid=$lockPid). claude TUI multi-client attach is not supported (render contention). For an observation shell alongside the active session, run: pwsh scripts/dev.ps1 shell $Name"
      exit 1
    }
  }
  Start-DevBox -Name $Name
}

function Invoke-Kill {
  param([string]$ArgValue)
  if (-not $ArgValue) {
    Write-Error "usage: pwsh scripts/dev.ps1 kill <NAME|N>"
    exit 1
  }
  $name = Resolve-Target -ArgValue $ArgValue
  Write-Host "stopping dev box '$name' (and cdx-$name reviewer pair if present)..."
  # Order: sbx rm first, then pair-teardown only on success. Reversed order would tear down the reviewer pair before the dev box is removed; if sbx rm then fails, the early-exit message ("leaving lease/lock intact") would misrepresent the state because the reviewer is already gone and the user has to manually re-provision.
  & sbx rm -f $name 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Error "failed to stop dev box '$name' (sbx rm -f returned $LASTEXITCODE). Leaving reviewer pair / lease / lock intact; retry with 'sbx rm -f $name'."
    exit $LASTEXITCODE
  }
  # R7 changed a2a-review.ps1 Invoke-PairTeardown to preserve the lease and exit non-zero on policy/cdx-rm failure. Honor that exit code here too -- unconditionally removing the lease on failure throws away the port anchor and breaks prune retry (R8 W/X). R9 AA/BB: also warn when there is no lease to preserve (orphan teardown failure) and exit non-zero at the end so the user is not told "done" while the reviewer pair survived.
  & scripts/internal/a2a-review.ps1 pair-teardown $name 2>$null | Out-Null
  $teardownFailed = ($LASTEXITCODE -ne 0)
  $lease = ".claude/tmp/cdx-serve-$name.lease"
  if (-not $teardownFailed) {
    if (Test-Path -LiteralPath $lease) { Remove-Item -LiteralPath $lease -Force -ErrorAction SilentlyContinue }
  } elseif (Test-Path -LiteralPath $lease) {
    Write-Warning "pair-teardown failed for '$name' -- lease preserved at $lease for retry. Cleanup: pwsh scripts/dev.ps1 prune -Yes (later) or check 'sbx policy ls' / 'sbx ls' manually."
  } else {
    Write-Warning "pair-teardown failed for '$name' (no lease to preserve; cdx-$name may still exist). Cleanup: pwsh scripts/dev.ps1 prune -Yes or 'sbx rm -f cdx-$name' manually."
  }
  # Skip lock removal while the owner PID is alive: `sbx rm -f` returns before the owning dev.ps1 process unwinds, so deleting the lock immediately lets a fresh `dev.ps1 <name>` start, acquire a new lock, and provision a new cdx pair - at which point the old owner's finally block runs and tears down the new session's reviewer + lock. Let the owner's own teardown clear the lock when its PID dies.
  $lock = ".claude/tmp/cdx-dev-$name.lock"
  if (Test-Path -LiteralPath $lock) {
    $lockPidStr = Get-Content -LiteralPath $lock -Raw -ErrorAction SilentlyContinue
    $lockPid = 0
    if ($lockPidStr -and [int]::TryParse($lockPidStr.Trim(), [ref]$lockPid) -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
      Write-Host "info: leaving dev lock for owner pid=$lockPid (the owner's finally block will remove it)."
    } else {
      Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
  }
  if ($teardownFailed) {
    Write-Host "done (with warnings -- pair-teardown failed; see above)."
    exit 1
  }
  Write-Host "done."
}

# cleanup targets: orphan cdx-<NAME> reviewer pair (dev box gone but reviewer left) / stale lease (.claude/tmp/cdx-serve-*.lease whose pid is dead) / stale lock (.claude/tmp/cdx-dev-*.lock whose pid is dead). With -All, also includes dev box bodies as a Docker `image prune --all` style opt-in: unpaired dev boxes (CDX=none, no active dev lock, not running) and leaked paired dev boxes (cdx pair still present but dev session dead, not running -- the CDX=ok/stale/orphan leak left when dev.ps1 crashed before its EXIT trap tore down box+pair).
# Default is dry-run (list-only); pass -Yes to actually remove. Consolidates the manual `sbx rm -f cdx-<NAME>` + `Remove-Item .claude/tmp/cdx-*` cleanup pattern into one verb.
# Orphan cdx / stale-lease cleanup is routed through scripts/internal/a2a-review.ps1 pair-teardown so the host port recorded in the lease is read and the matching `sbx policy allow network` rule is revoked too; deleting the lease alone leaves the policy stale.
function Invoke-Prune {
  param([switch]$Yes, [switch]$All)

  $sbxAll = @(sbx ls -q 2>$null)
  if ($LASTEXITCODE -ne 0) { $sbxAll = @() }
  $cdxNames = @()
  $devNames = @()
  foreach ($n in $sbxAll) {
    if ($n -clike 'cdx-*') { $cdxNames += $n.Substring(4) }
    elseif ($n -cnotlike 'sbx-*' -and $n -cnotlike 'obs-*') { $devNames += $n }
  }

  # Possibly-active dev box name set (-All only, protects lockless active sessions and cold-start transients from destructive delete). Parse sbx ls --json status as SSoT (side-effect free / format-stable via JSON schema).
  # Treat only an explicit "stopped" status as safe to delete; anything else (running / starting / stopping / unknown transient) is maybe-running and protected. This matches scripts/cdp-bridge.sh box_running_or_unknown -- looking only at status == "running" would delete a box mid-transition (sbx/README.md "cold-start transient"). The variable is named runningNames but its meaning is "not stopped = possibly-active".
  # NOTE: sbx exec is NOT a safe idle test (sbx auto-starts stopped boxes on exec, waking prune candidates). Computed before the stale-lease scan because the stale-lease delegation check below also references it.
  # Fail-closed: any failure (non-zero sbx exit / empty output / ConvertFrom-Json throw / missing or non-array sandboxes property) refuses -All instead of degrading to a filter-less run, since silent degrade could delete active boxes. -cnotmatch is used because -notmatch is case-insensitive while box names are case-sensitive (uppercase prefixes like SBX- / CDX- would otherwise be filtered out incorrectly).
  $runningNames = @()
  if ($All) {
    $sbxJsonText = (& sbx ls --json 2>$null | Out-String)
    $sbxJsonExit = $LASTEXITCODE
    if ($sbxJsonExit -ne 0) {
      Write-Error "-All requires 'sbx ls --json' to succeed for the running-state safety check; sbx exited with code $sbxJsonExit. Aborting to avoid unsafe delete."
      exit 1
    }
    if (-not $sbxJsonText) {
      Write-Error "-All requires 'sbx ls --json' to succeed for the running-state safety check; sbx returned empty output. Aborting to avoid unsafe delete."
      exit 1
    }
    try {
      $sbxParsed = $sbxJsonText | ConvertFrom-Json
    } catch {
      Write-Error ("-All requires 'sbx ls --json' output to be parseable JSON; ConvertFrom-Json failed: " + $_.Exception.Message + ". Aborting to avoid unsafe delete.")
      exit 1
    }
    # Missing 'sandboxes' property (e.g. error payload {"errors": [...]} or empty object {}) or a non-array value ({"sandboxes": null} / {"sandboxes": "err"}) is fail-closed: piped to Where-Object it yields an empty or garbage set, silently disabling the running filter (dev.sh gets this for free: jq errors when iterating a non-array). A legitimate empty list [] stays an array and passes.
    if (-not ($sbxParsed.PSObject.Properties.Name -contains 'sandboxes')) {
      Write-Error "-All requires 'sbx ls --json' payload to include a 'sandboxes' field; the property is missing. Aborting to avoid unsafe delete."
      exit 1
    }
    if ($sbxParsed.sandboxes -isnot [array]) {
      Write-Error "-All requires the 'sandboxes' value in 'sbx ls --json' payload to be a JSON array; got null or a non-array value. Aborting to avoid unsafe delete."
      exit 1
    }
    $runningNames = @($sbxParsed.sandboxes | Where-Object { $_.status -ne 'stopped' -and $_.name -cnotmatch '^(cdx-|sbx-|obs-)' } | ForEach-Object { $_.name })
  }

  # Orphan cdx pair: cdx-<X> exists, dev box <X> does not, AND no active dev lock for <X>.
  # Active-lock check: during dev.ps1 startup (after lock acquisition + pair-setup, before sbx run creates the dev box), cdx-<X> already exists but <X> itself does not. A concurrent `prune -Yes` in that window would treat the cdx as orphan and break the in-flight startup. Skip when the lock holder PID is alive.
  $orphanCdx = @()
  foreach ($c in $cdxNames) {
    if ($devNames -ccontains $c) { continue }
    $cdxLock = ".claude/tmp/cdx-dev-$c.lock"
    if (Test-Path -LiteralPath $cdxLock) {
      $lockPidStr = (Get-Content -LiteralPath $cdxLock -Raw -ErrorAction SilentlyContinue)
      if ($lockPidStr) { $lockPidStr = $lockPidStr.Trim() }
      $lockPid = 0
      if ($lockPidStr -and [int]::TryParse($lockPidStr, [ref]$lockPid) -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
        continue
      }
    }
    $orphanCdx += "cdx-$c"
  }

  # Stale lease: pid is dead/unparseable, or start_time mismatch (PID reuse: Get-Process succeeds for recycled PIDs).
  # Active-lock check (mirror of orphan-cdx branch): if dev.ps1 <NAME> is restarting with an old stale lease still on disk, the new cdx-dev-<NAME>.lock is acquired before pair-serve rewrites the lease (lock -> pair-setup -> pair-serve fork -> lease rewrite). Treating the old dead pid as stale and calling pair-teardown would remove the in-flight cdx-<NAME>. Skip when the lock holder PID is alive.
  $staleLeases = @()
  $staleLeaseNames = @()
  $leaseFiles = @(Get-ChildItem -LiteralPath '.claude/tmp' -Filter 'cdx-serve-*.lease' -File -ErrorAction SilentlyContinue)
  foreach ($lf in $leaseFiles) {
    $pidStr = ''; $leaseSt = ''; $leaseKind = ''
    foreach ($line in (Get-Content -LiteralPath $lf.FullName -ErrorAction SilentlyContinue)) {
      if ($line -match '"pid"\s*:\s*(\d+)') { $pidStr = $matches[1] }
      if ($line -match '"start_time"\s*:\s*"([^"]*)"') { $leaseSt = $matches[1] }
      if ($line -match '"start_time_kind"\s*:\s*"([^"]*)"') { $leaseKind = $matches[1] }
    }
    $isStale = $false
    if (-not $pidStr) {
      $isStale = $true
    } else {
      $proc = Get-Process -Id ([int]$pidStr) -ErrorAction SilentlyContinue
      if (-not $proc) {
        $isStale = $true
      } elseif (Test-LeaseStartTimeReused $proc $leaseSt $leaseKind) {
        $isStale = $true
      }
    }
    if ($isStale) {
      $leaseName = $lf.Name -replace '^cdx-serve-', '' -replace '\.lease$', ''
      $leaseLock = ".claude/tmp/cdx-dev-$leaseName.lock"
      $skipForActiveLock = $false
      if (Test-Path -LiteralPath $leaseLock) {
        $lockPidStr = (Get-Content -LiteralPath $leaseLock -Raw -ErrorAction SilentlyContinue)
        if ($lockPidStr) { $lockPidStr = $lockPidStr.Trim() }
        $lockPid = 0
        if ($lockPidStr -and [int]::TryParse($lockPidStr, [ref]$lockPid) -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
          $skipForActiveLock = $true
        }
      }
      # In -All mode, hand off to the leakedPairedDev branch ONLY when the dev box body AND its cdx pair still exist AND the box is stopped (not possibly-active): that branch removes the dev box body together with the pair via sbx rm + pair-teardown, whereas tearing down only the pair here would leave the dev box body behind. Keep it in staleLeases (so pair-teardown revokes the lease/policy as before) when delegation would otherwise drop the cleanup:
      #   (a) the cdx pair is already gone but the dev box body remains -- leakedPairedDev (which requires a cdx pair) cannot pick it up, and unpairedDev would sbx rm only the box body, leaking the stale lease/policy (regression)
      #   (b) the box is possibly-active (running/transient) -- leakedPairedDev skips it under the running guard, so the stale lease/policy would never be cleaned
      # Without -All, runningNames is empty and every stale lease is swept as reviewer residue (legacy behavior).
      if (-not $skipForActiveLock) {
        if ($All -and ($devNames -ccontains $leaseName) -and ($cdxNames -ccontains $leaseName) -and (-not ($runningNames -ccontains $leaseName))) {
          continue
        }
        $staleLeases += $lf.FullName
        $staleLeaseNames += $leaseName
      }
    }
  }

  $staleLocks = @()
  $lockFiles = @(Get-ChildItem -LiteralPath '.claude/tmp' -Filter 'cdx-dev-*.lock' -File -ErrorAction SilentlyContinue)
  foreach ($lf in $lockFiles) {
    $pidStr = (Get-Content -LiteralPath $lf.FullName -Raw -ErrorAction SilentlyContinue)
    if ($pidStr) { $pidStr = $pidStr.Trim() }
    $lockPid = 0
    $alive = $false
    if ($pidStr -and [int]::TryParse($pidStr, [ref]$lockPid) -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
      $alive = $true
    }
    if (-not $alive) { $staleLocks += $lf.FullName }
  }

  # Unpaired dev box (-All only): dev boxes with no cdx pair AND no active dev lock AND not running. Docker `image prune --all` style opt-in for sweeping accumulated CDX=none stopped boxes. Active-lock check guards in-flight startup like the other branches; running check guards lockless attached sessions (dev.ps1 shell / direct sbx exec).
  $unpairedDev = @()
  $runningSkipped = @()
  if ($All -and $devNames.Count -gt 0) {
    foreach ($dev in $devNames) {
      if ($cdxNames -ccontains $dev) { continue }
      $cdxLockDev = ".claude/tmp/cdx-dev-$dev.lock"
      if (Test-Path -LiteralPath $cdxLockDev) {
        $lockPidStrDev = (Get-Content -LiteralPath $cdxLockDev -Raw -ErrorAction SilentlyContinue)
        if ($lockPidStrDev) { $lockPidStrDev = $lockPidStrDev.Trim() }
        $lockPidDev = 0
        if ($lockPidStrDev -and [int]::TryParse($lockPidStrDev, [ref]$lockPidDev) -and (Get-Process -Id $lockPidDev -ErrorAction SilentlyContinue)) {
          continue
        }
      }
      if ($runningNames -ccontains $dev) {
        $runningSkipped += $dev
        continue
      }
      $unpairedDev += $dev
    }
  }

  # Leaked paired dev box (-All only): a dev box that still has a cdx pair (CDX=ok/stale/orphan) but whose dev session is dead (lock dead/absent) and which is not running. The plain prune categories (orphan_cdx / stale_lease) only catch reviewer residue left after the dev box is already gone; a dev box body that survives while only its pair-serve leaked (CDX=ok, e.g. dev.ps1 crashed before its EXIT trap ran the teardown) fell through every branch. Catch the dev box body here and tear the pair down on delete (same as kill). Protection axis mirrors unpairedDev (skip when lock alive / running).
  $leakedPairedDev = @()
  if ($All -and $devNames.Count -gt 0) {
    foreach ($dev in $devNames) {
      # Only dev boxes that DO have a cdx pair (CDX=none is handled by unpairedDev).
      if (-not ($cdxNames -ccontains $dev)) { continue }
      $leakedLockDev = ".claude/tmp/cdx-dev-$dev.lock"
      if (Test-Path -LiteralPath $leakedLockDev) {
        $leakedLockPidStr = (Get-Content -LiteralPath $leakedLockDev -Raw -ErrorAction SilentlyContinue)
        if ($leakedLockPidStr) { $leakedLockPidStr = $leakedLockPidStr.Trim() }
        $leakedLockPid = 0
        if ($leakedLockPidStr -and [int]::TryParse($leakedLockPidStr, [ref]$leakedLockPid) -and (Get-Process -Id $leakedLockPid -ErrorAction SilentlyContinue)) {
          continue
        }
      }
      if ($runningNames -ccontains $dev) {
        $runningSkipped += $dev
        continue
      }
      $leakedPairedDev += $dev
    }
  }

  $total = $orphanCdx.Count + $staleLeases.Count + $staleLocks.Count + $unpairedDev.Count + $leakedPairedDev.Count
  if ($total -eq 0) {
    # When every CDX=none box was filtered out as running, surface the protected count so users can tell "0 candidates" from "everything skipped".
    if ($runningSkipped.Count -gt 0) {
      Write-Host ("(nothing to prune; " + $runningSkipped.Count + " running box(es) protected, see below)")
      Write-Host ""
      Write-Host "skipped (possibly-active, -All mode):"
      foreach ($item in $runningSkipped) { Write-Host "  $item  (sbx ls reports status != stopped -- running or transient/attached via dev.ps1 shell / sbx exec; use 'pwsh scripts/dev.ps1 kill $item' to delete explicitly)" }
    } else {
      Write-Host "(nothing to prune)"
    }
    return
  }

  Write-Host "prune candidates ($total):"
  foreach ($item in $orphanCdx) { Write-Host "  $item  (orphan cdx pair: dev box not found, no active dev lock)" }
  foreach ($item in $staleLeases) { Write-Host "  $item  (stale lease: pid dead -- pair-teardown will revoke sbx policy + cleanup)" }
  foreach ($item in $staleLocks) { Write-Host "  $item  (stale lock: pid dead)" }
  foreach ($item in $unpairedDev) { Write-Host "  $item  (unpaired dev box: CDX=none, no active dev lock -- -All mode)" }
  foreach ($item in $leakedPairedDev) { Write-Host "  $item  (leaked paired dev box: dev session dead but cdx pair still present -- -All mode)" }

  if ($runningSkipped.Count -gt 0) {
    Write-Host ""
    Write-Host "skipped (possibly-active, -All mode):"
    foreach ($item in $runningSkipped) { Write-Host "  $item  (sbx ls reports status != stopped -- running or transient/attached via dev.ps1 shell / sbx exec; use 'pwsh scripts/dev.ps1 kill $item' to delete explicitly)" }
  }

  if (-not $Yes) {
    Write-Host ""
    if ($All) {
      Write-Host "dry-run mode (-All). To actually prune, run: pwsh scripts/dev.ps1 prune -Yes -All"
    } else {
      Write-Host "dry-run mode. To actually prune, run: pwsh scripts/dev.ps1 prune -Yes"
    }
    return
  }

  Write-Host ""
  Write-Host "pruning..."
  $failed = 0
  # Re-check helper: shrinks the scan -> delete TOCTOU window to effectively zero by re-reading the lock just before each destructive call.
  $isDevLockAlive = {
    param([string]$n)
    $lockPathCheck = ".claude/tmp/cdx-dev-$n.lock"
    if (-not (Test-Path -LiteralPath $lockPathCheck)) { return $false }
    $lockPidStr = (Get-Content -LiteralPath $lockPathCheck -Raw -ErrorAction SilentlyContinue)
    if ($lockPidStr) { $lockPidStr = $lockPidStr.Trim() }
    $lockPid = 0
    return ($lockPidStr -and [int]::TryParse($lockPidStr, [ref]$lockPid) -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue))
  }
  # Re-snapshot the possibly-active set just before destructive delete (TOCTOU mitigation for dev.ps1 shell / sbx exec attaches that woke the box after the initial scan). Returns @{ Ok = bool; Items = string[] }; failure forces fail-closed exit at the call site. Uses -cnotmatch (case-sensitive) to stay aligned with Get-DevBoxNames. Mirrors the entry-time -All fail-closed checks (non-zero sbx exit / empty output / parse failure / missing or non-array sandboxes property).
  # Like the entry-time runningNames, treat status != "stopped" as possibly-active (protect transient/unknown from destructive delete, cdp-bridge.sh convention).
  $captureRunningSet = {
    $jsonText = (& sbx ls --json 2>$null | Out-String)
    $exitLocal = $LASTEXITCODE
    if ($exitLocal -ne 0) { return @{ Ok = $false; Items = @() } }
    if (-not $jsonText) { return @{ Ok = $false; Items = @() } }
    try {
      $parsed = $jsonText | ConvertFrom-Json
    } catch {
      return @{ Ok = $false; Items = @() }
    }
    if (-not ($parsed.PSObject.Properties.Name -contains 'sandboxes')) { return @{ Ok = $false; Items = @() } }
    if ($parsed.sandboxes -isnot [array]) { return @{ Ok = $false; Items = @() } }
    $names = @($parsed.sandboxes | Where-Object { $_.status -ne 'stopped' -and $_.name -cnotmatch '^(cdx-|sbx-|obs-)' } | ForEach-Object { $_.name })
    return @{ Ok = $true; Items = $names }
  }
  # sbx ls exit code helper: distinguishes a transient sbx CLI failure from a successful listing that lacks the item, so a failed listing is treated as a verification failure (not as silent success).
  $captureSbxLs = {
    $current = @(sbx ls -q 2>$null)
    $okLocal = ($LASTEXITCODE -eq 0)
    if (-not $okLocal) { $current = @() }
    return @{ Ok = $okLocal; Items = $current }
  }
  # Orphan cdx pair: re-check active lock -> pair-teardown (R7 a2a-review.ps1 semantics: success = lease + cdx + policy all OK / failure = lease preserved + something left). Fall back to direct sbx rm only when pair-teardown fails.
  foreach ($item in $orphanCdx) {
    $cdxName = $item.Substring(4)
    if (& $isDevLockAlive $cdxName) {
      Write-Host "  skipped $item (active dev lock acquired since scan)"
      continue
    }
    & scripts/internal/a2a-review.ps1 pair-teardown $cdxName 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  removed $item (via pair-teardown)"
      continue
    }
    # pair-teardown failure: verify via sbx ls and fall back to direct sbx rm if cdx still present.
    $ls = & $captureSbxLs
    if (-not $ls.Ok) {
      Write-Warning "pair-teardown failed for $item and sbx ls verify also failed (retry: pwsh scripts/dev.ps1 prune -Yes)"
      $failed += 1
      continue
    }
    if ($ls.Items -cnotcontains $item) {
      Write-Warning "$item removed but sbx policy revoke may have failed (check 'sbx policy ls' for stale localhost:* rules)"
      $failed += 1
    } elseif (& $isDevLockAlive $cdxName) {
      # R10 GG/HH: recheck live lock immediately before fallback sbx rm (avoids the scan->fallback startup window where a fresh dev session bootstrap-verifies and recycles cdx-<NAME>).
      Write-Host "  skipped fallback sbx rm for $item (active dev lock acquired since scan)"
      continue
    } else {
      & sbx rm -f $item 2>$null | Out-Null
      $ls = & $captureSbxLs
      if ($ls.Ok -and $ls.Items -cnotcontains $item) {
        # R9 EE/FF: clean up the preserved lease here. When orphan_cdx scan saw an alive lease pid (lease was NOT queued in $staleLeases) but pair-teardown later failed, the lease is still on disk; re-invoke pair-teardown so the policy revoke + lease delete is retried (cdx is already gone -> idempotent).
        # R10 GG/HH: also recheck the live lock immediately before the retry pair-teardown (another startup window between fallback rm and retry teardown).
        $fbLease = ".claude/tmp/cdx-serve-$cdxName.lease"
        if (Test-Path -LiteralPath $fbLease) {
          if (& $isDevLockAlive $cdxName) {
            Write-Warning "removed $item but retry pair-teardown skipped (active dev lock acquired; lease preserved for new session's teardown to handle)"
          } else {
            & scripts/internal/a2a-review.ps1 pair-teardown $cdxName 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
              Write-Warning "removed $item (fallback sbx rm + retry pair-teardown for lease/policy cleanup)"
            } else {
              Write-Warning "$item removed but $fbLease + sbx policy may remain (check 'sbx policy ls')"
              $failed += 1
            }
          }
        } else {
          Write-Warning "removed $item (fallback sbx rm after pair-teardown reported failure)"
        }
      } else {
        Write-Warning "failed to remove $item (still present after pair-teardown + fallback sbx rm)"
        $failed += 1
      }
    }
  }
  # Stale lease: re-check active lock -> pair-teardown (R7 semantics: success = lease + cdx + policy all OK / failure = lease preserved to keep the port anchor). On failure, the lease should still be on disk for the next retry; count as failed and guide the user.
  for ($i = 0; $i -lt $staleLeaseNames.Count; $i++) {
    $name = $staleLeaseNames[$i]
    $leasePath = $staleLeases[$i]
    if (& $isDevLockAlive $name) {
      Write-Host "  skipped $leasePath (active dev lock acquired since scan)"
      continue
    }
    & scripts/internal/a2a-review.ps1 pair-teardown $name 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  removed $leasePath (via pair-teardown, cdx-$name and policy revoked)"
      continue
    }
    # pair-teardown failure: the a2a-review.ps1 R7 semantics keeps the lease so the port anchor survives.
    if (Test-Path -LiteralPath $leasePath) {
      Write-Warning "$leasePath NOT removed -- pair-teardown failed (sbx policy revoke or cdx rm transient failure; lease preserved for retry). Retry: pwsh scripts/dev.ps1 prune -Yes (later) or check 'sbx policy ls' / 'sbx ls' manually."
      $failed += 1
    } else {
      Write-Warning "$leasePath was removed despite pair-teardown failure (unexpected -- possibly concurrent prune). Check 'sbx ls' / 'sbx policy ls' for leftover state."
      $failed += 1
    }
  }
  # Stale lock: re-read + re-check pid just before delete (avoids the window where dev.ps1 re-acquired the same-name lock after the initial scan).
  foreach ($item in $staleLocks) {
    if (Test-Path -LiteralPath $item) {
      $revalidatePidStr = (Get-Content -LiteralPath $item -Raw -ErrorAction SilentlyContinue)
      if ($revalidatePidStr) { $revalidatePidStr = $revalidatePidStr.Trim() }
      $revalidatePid = 0
      if ($revalidatePidStr -and [int]::TryParse($revalidatePidStr, [ref]$revalidatePid) -and (Get-Process -Id $revalidatePid -ErrorAction SilentlyContinue)) {
        Write-Host "  skipped $item (re-acquired by alive pid=$revalidatePid since scan)"
        continue
      }
    }
    try {
      Remove-Item -LiteralPath $item -Force -ErrorAction Stop
      Write-Host "  removed $item"
    } catch [System.Management.Automation.ItemNotFoundException] {
      # Idempotent semantics aligned with bash `rm -f`: a file disappearing between enumeration and Remove-Item is treated as success.
      Write-Host "  removed $item (already gone)"
    } catch {
      Write-Warning "failed to remove $item"
      $failed += 1
    }
  }
  # Unpaired dev box (-All only): sbx rm of the dev box itself (no cdx pair / no lease / no policy expected). Per-item recheck of both lock and running state just before delete -- a single pre-loop snapshot would let a box flipped to running via dev.ps1 shell / sbx exec between the snapshot and a later iteration's sbx rm slip through. Mirrors the existing per-item is_dev_lock_alive pattern.
  foreach ($item in $unpairedDev) {
    if (& $isDevLockAlive $item) {
      Write-Host "  skipped $item (active dev lock acquired since scan)"
      continue
    }
    $rrItem = & $captureRunningSet
    if (-not $rrItem.Ok) {
      Write-Warning "skipped $item -- failed to re-snapshot running state via 'sbx ls --json' before delete (transient sbx error; retry: pwsh scripts/dev.ps1 prune -Yes -All)"
      $failed += 1
      continue
    }
    if ($rrItem.Items -ccontains $item) {
      Write-Host "  skipped $item (status != stopped since last snapshot; not deleted -- likely dev.ps1 shell / sbx exec attached or transient, use 'pwsh scripts/dev.ps1 kill $item' to delete explicitly)"
      continue
    }
    & sbx rm -f $item 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  removed $item (unpaired dev box, -All)"
    } else {
      Write-Warning "failed to remove $item (sbx rm returned non-zero)"
      $failed += 1
    }
  }
  # Leaked paired dev box (-All only): sbx rm of the dev box body -> pair-teardown only on success (same order as kill; the reverse would leave the reviewer torn down while the dev box rm failed). pair-teardown idempotently cleans lease + cdx + policy. Per-item recheck of lock and running state just before delete, mirroring the unpairedDev branch.
  foreach ($item in $leakedPairedDev) {
    if (& $isDevLockAlive $item) {
      Write-Host "  skipped $item (active dev lock acquired since scan)"
      continue
    }
    $rrItem = & $captureRunningSet
    if (-not $rrItem.Ok) {
      Write-Warning "skipped $item -- failed to re-snapshot running state via 'sbx ls --json' before delete (transient sbx error; retry: pwsh scripts/dev.ps1 prune -Yes -All)"
      $failed += 1
      continue
    }
    if ($rrItem.Items -ccontains $item) {
      Write-Host "  skipped $item (status != stopped since last snapshot; not deleted -- likely dev.ps1 shell / sbx exec attached or transient, use 'pwsh scripts/dev.ps1 kill $item' to delete explicitly)"
      continue
    }
    & sbx rm -f $item 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "failed to remove $item (sbx rm returned non-zero; cdx-$item pair left intact for retry)"
      $failed += 1
      continue
    }
    & scripts/internal/a2a-review.ps1 pair-teardown $item 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      Write-Host "  removed $item (leaked paired dev box + cdx-$item pair, -All)"
    } else {
      Write-Warning "removed $item but pair-teardown failed (cdx-$item / lease / sbx policy may remain; retry: pwsh scripts/dev.ps1 prune -Yes)"
      $failed += 1
    }
  }
  if ($failed -gt 0) {
    Write-Error "done ($failed failures)."
    exit 1
  }
  Write-Host "done."
}

# ---------------- preflight: bootstrap fallback for Start-DevBox / Invoke-Sandbox ----------------
# Rescues users who run `pwsh scripts/dev.ps1` without first running `pwsh scripts/build-image.ps1`
# (image not loaded) or `pwsh scripts/check-setup.ps1` (env not verified). The standalone entry points
# stay available; preflight is a thin idempotent fallback that short-circuits when everything is in place.
# Not invoked from ls / attach / kill / prune / shell / route (those operate on existing boxes / metadata).
function Test-ImageLoaded {
  # Mirrors check-setup.ps1: accept both `docker.io/library/<name>` and bare `<name>` (varies by sbx version).
  $lines = @(& sbx template ls 2>$null)
  for ($i = 1; $i -lt $lines.Count; $i++) {
    $cols = $lines[$i] -split '\s+'
    if ($cols.Count -ge 1 -and ($cols[0] -ceq "docker.io/library/$Template" -or $cols[0] -ceq $Template)) {
      return $true
    }
  }
  return $false
}

function Get-SbxDockerfileCommit {
  (git log --format="%H" -n1 -- sbx/Dockerfile 2>$null) -join ""
}

function Get-TemplateStampCommit {
  # First stamp line = Dockerfile commit (line 2 = build time, used by check-setup's age WARN).
  # stamp absent (pre-feature build) also treated as stale.
  $stamp = ".claude/tmp/sbx-template-commit.stamp"
  if (Test-Path -LiteralPath $stamp) {
    $lines = @(Get-Content -LiteralPath $stamp -ErrorAction SilentlyContinue)
    if ($lines.Count -ge 1) { $lines[0].Trim() } else { "" }
  } else { "" }
}

function Test-ImageCurrent {
  if (-not (Test-ImageLoaded)) { return $false }
  $cur = Get-TemplateStampCommit
  $exp = Get-SbxDockerfileCommit
  return ($cur -ne "" -and $exp -ne "" -and $cur -eq $exp)
}

function Invoke-Preflight {
  # Reuse the same PowerShell host that invoked this script (powershell.exe for 5.1 / pwsh for 7+) so the
  # README's `powershell -ExecutionPolicy Bypass -File scripts/dev.ps1` recipe works without requiring pwsh 7
  # as a new prerequisite. (Get-Process -Id $PID).Path returns the absolute executable path of the current host.
  $psHost = (Get-Process -Id $PID).Path
  # Image template absent or sbx/Dockerfile updated -> auto-rebuild.
  # check-setup.ps1 is NOT invoked from preflight: it exits 1 when the openai secret is unregistered,
  # which would regress the "I'll set up openai later, just want a claude box now" flow (Start-DevBox's
  # existing `sbx secret ls | openai` branch falls back to a degraded fail-open path). check-setup stays
  # a doctor for users to invoke explicitly (pwsh scripts/check-setup.ps1).
  # Serialize concurrent preflight invocations with a repo-wide lock + double-check so two simultaneous dev.ps1
  # cannot race build-image.ps1's shared cap-sbx.tar (write/load/rm overlap can corrupt template load).
  if (-not (Test-ImageCurrent)) {
    New-Item -ItemType Directory -Force -Path .claude/tmp | Out-Null
    $imageLock = ".claude/tmp/preflight-image.lock"
    $waited = 0
    while ($true) {
      try {
        New-Item -ItemType File -Path $imageLock -Value "$PID" -ErrorAction Stop | Out-Null
        break
      } catch {
        # Only treat the failure as lock contention if the file actually exists. Other New-Item failures
        # (e.g. .claude/tmp not writable, disk full, permission denied) must surface as real errors;
        # otherwise the loop would treat them as stale-lock and `continue` forever, hanging preflight.
        if (-not (Test-Path -LiteralPath $imageLock)) {
          Write-Error "[preflight] failed to create image lock '$imageLock': $($_.Exception.Message)"
          exit 1
        }
        # Read the PID written by the lock holder. Distinguish three states so we don't race:
        #   parsed + alive  -> another dev.ps1 is mid-build; wait for it
        #   parsed + dead   -> stale lock from a crashed process; safe to remove and retry
        #   empty / unparseable -> lock file created but PID not yet written (TOCTOU between
        #     New-Item creating the file and writing the value); wait instead of deleting
        #     (deleting would race the in-progress lock holder).
        $lockPidStr = Get-Content -LiteralPath $imageLock -Raw -ErrorAction SilentlyContinue
        $lockPidInt = 0
        $pidParsed = $false
        if ($lockPidStr) {
          try { $lockPidInt = [int]$lockPidStr.Trim(); $pidParsed = $true } catch {}
        }
        $lockAlive = $false
        if ($pidParsed) {
          try { Get-Process -Id $lockPidInt -ErrorAction Stop | Out-Null; $lockAlive = $true } catch {}
        }
        if ($pidParsed -and -not $lockAlive) {
          Write-Host "[preflight] removing stale image lock (pid=$lockPidInt dead)..." -ForegroundColor Yellow
          Remove-Item -LiteralPath $imageLock -Force -ErrorAction SilentlyContinue
          continue
        }
        if ($waited -eq 0) {
          if ($pidParsed) {
            Write-Host "[preflight] another dev.ps1 is building the image (pid=$lockPidInt). Waiting..." -ForegroundColor Yellow
          } else {
            Write-Host "[preflight] image lock present (PID not yet written; another invocation may be initializing). Waiting..." -ForegroundColor Yellow
          }
        }
        Start-Sleep -Seconds 5
        $waited += 5
        if ($waited -ge 600) {
          Write-Error "[preflight] image build lock waited > 10 min. Remove manually and retry: Remove-Item -LiteralPath '$imageLock' -Force"
          exit 1
        }
      }
    }
    # Lock acquired; another process may have finished building while we waited, so re-check.
    if (Test-ImageCurrent) {
      Remove-Item -LiteralPath $imageLock -Force -ErrorAction SilentlyContinue
    } else {
      if (Test-ImageLoaded) {
        Write-Host "[preflight] sbx/Dockerfile has been updated. Running scripts/build-image.ps1 to rebuild..." -ForegroundColor Yellow
      } else {
        Write-Host "[preflight] sbx template '$Template' is not loaded. Running scripts/build-image.ps1 (~5 min)..." -ForegroundColor Yellow
      }
      & $psHost -NoProfile -ExecutionPolicy Bypass -File scripts/build-image.ps1
      $buildRc = $LASTEXITCODE
      Remove-Item -LiteralPath $imageLock -Force -ErrorAction SilentlyContinue
      if ($buildRc -ne 0) {
        Write-Error "[preflight] build-image failed. Run scripts/build-image.ps1 manually to diagnose, then retry dev.ps1."
        exit 1
      }
    }
  }
}

# Throwaway clone-mode sandbox box (sbx run --clone .). The host checkout is NOT bind-mounted, so multiple
# concurrent invocations cannot race on host files (parallel-safe). No cdx reviewer pair is attached, so
# /a2a-review and /pr-codex-ci are unavailable; use this for PR-pre exploration / verification only.
function Invoke-Sandbox {
  param([string]$Name = "")

  if ($Name) {
    if ($Name -notmatch $NameRe) {
      Write-Error "name '$Name' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only)."
      exit 1
    }
    # Namespace separation: sandbox explicit names MUST use the `sbx-` prefix to stay disjoint from dev boxes (prefix-less).
    if ($Name -clike 'cdx-*') {
      Write-Error "name 'cdx-*' is reserved for the cdx-<NAME> reviewer box prefix. Pick another name."
      exit 1
    }
    if ($Name -cnotlike 'sbx-*') {
      Write-Error "sandbox explicit names must use the 'sbx-' prefix (to stay disjoint from the dev box namespace). Example: pwsh scripts/dev.ps1 sandbox sbx-$Name . Run with no argument for auto-naming (sbx-<basename>-<hex6>)."
      exit 1
    }
  } else {
    # sbx- prefix on auto-names so dev box discovery can exclude sandboxes structurally.
    $base = Split-Path -Leaf (Get-Location)
    $cleanBase = $base -replace '[^A-Za-z0-9-]', '-'
    $cleanBase = $cleanBase -replace '^-+|-+$', ''
    if (-not $cleanBase) { $cleanBase = "box" }
    $suffix = '{0:x6}' -f (((Get-Random -Maximum 16777216) -bxor $PID) -band 0xffffff)
    $Name = "sbx-$cleanBase-$suffix"
    $existing = @(sbx ls -q 2>$null)
    if ($LASTEXITCODE -ne 0) { $existing = @() }
    while ($existing -ccontains $Name) {
      $suffix = '{0:x6}' -f (((Get-Random -Maximum 16777216) -bxor $PID) -band 0xffffff)
      $Name = "sbx-$cleanBase-$suffix"
      $existing = @(sbx ls -q 2>$null)
      if ($LASTEXITCODE -ne 0) { $existing = @() }
    }
    Write-Host "Creating new sandbox (clone) box: $Name (re-attach with 'pwsh scripts/dev.ps1 sandbox $Name')" -ForegroundColor Yellow
  }

  $existing = @(sbx ls -q 2>$null)
  if ($LASTEXITCODE -ne 0) { $existing = @() }
  if ($existing -ccontains $Name) {
    # Re-attach: skip preflight (an existing box already has image / setup in place).
    & sbx run --name $Name
  } else {
    # New sandbox creation: run preflight (rescues missed image build / setup check).
    Invoke-Preflight
    if (Test-KimiEnabled $Name) {
      Invoke-KimiPreflight $Name
      & sbx run --name $Name claude -t $Template --kit $Kit --kit $KitKimi --clone .
    } else {
      & sbx run --name $Name claude -t $Template --kit $Kit --clone .
    }
  }
  exit $LASTEXITCODE
}

# Observe box for read-only AWS observability investigation (the observe persona in rules/box-personas.md).
# Same throwaway clone-mode box as sandbox, but the namespace is the `obs-` prefix and it is excluded from dev box
# discovery. Clone copy keeps the host checkout untouched (read-only equivalent) and the committed runbook is in the
# clone. The AWS read-only credentials (host mints via assume-role and injects) and the network allow
# (sbx policy allow --sandbox <obs-box>) are host-side steps; this launcher only starts the box (see examples/observe/runbook.md).
function Invoke-Observe {
  param([string]$Name = "")

  if ($Name) {
    if ($Name -notmatch $NameRe) {
      Write-Error "name '$Name' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only)."
      exit 1
    }
    # Observe explicit names MUST use the `obs-` prefix to stay disjoint from dev / sandbox / cdx namespaces.
    if ($Name -clike 'cdx-*' -or $Name -clike 'sbx-*') {
      Write-Error "name '$Name' uses another persona's reserved prefix. Observe boxes must use the 'obs-' prefix."
      exit 1
    }
    if ($Name -cnotlike 'obs-*') {
      Write-Error "observe explicit names must use the 'obs-' prefix (to separate the persona namespace). Example: pwsh scripts/dev.ps1 observe obs-$Name . Run with no argument for auto-naming (obs-<basename>-<hex6>)."
      exit 1
    }
  } else {
    $base = Split-Path -Leaf (Get-Location)
    $cleanBase = $base -replace '[^A-Za-z0-9-]', '-'
    $cleanBase = $cleanBase -replace '^-+|-+$', ''
    if (-not $cleanBase) { $cleanBase = "box" }
    $suffix = '{0:x6}' -f (((Get-Random -Maximum 16777216) -bxor $PID) -band 0xffffff)
    $Name = "obs-$cleanBase-$suffix"
    $existing = @(sbx ls -q 2>$null)
    if ($LASTEXITCODE -ne 0) { $existing = @() }
    while ($existing -ccontains $Name) {
      $suffix = '{0:x6}' -f (((Get-Random -Maximum 16777216) -bxor $PID) -band 0xffffff)
      $Name = "obs-$cleanBase-$suffix"
      $existing = @(sbx ls -q 2>$null)
      if ($LASTEXITCODE -ne 0) { $existing = @() }
    }
    Write-Host "Creating observe box: $Name (read-only AWS investigation; inject cred/network on the host -> examples/observe/runbook.md)" -ForegroundColor Yellow
  }

  $existing = @(sbx ls -q 2>$null)
  if ($LASTEXITCODE -ne 0) { $existing = @() }
  if ($existing -ccontains $Name) {
    & sbx run --name $Name
  } else {
    Invoke-Preflight
    if (Test-KimiEnabled $Name) {
      Invoke-KimiPreflight $Name
      & sbx run --name $Name claude -t $Template --kit $Kit --kit $KitKimi --clone .
    } else {
      & sbx run --name $Name claude -t $Template --kit $Kit --clone .
    }
  }
  exit $LASTEXITCODE
}

# Open an interactive shell inside a box without going through claude (thin wrapper around `sbx exec -it <box> bash`).
# Pass the box name (dev box / sandbox box / cdx-<NAME> reviewer box). Use 'pwsh scripts/dev.ps1 ls' to list dev boxes.
function Invoke-Shell {
  param([string]$Name = "")
  if (-not $Name) {
    Write-Error "usage: pwsh scripts/dev.ps1 shell <NAME>  (use 'pwsh scripts/dev.ps1 ls' / 'sbx ls' to list available boxes)"
    exit 1
  }
  # Reject metachar input up front; leading alphanumeric required (mirrors $NameRe).
  if ($Name -notmatch $NameRe) {
    Write-Error "name '$Name' must match ^[A-Za-z0-9][A-Za-z0-9-]*$ (start with alphanumeric, then alphanumeric or hyphen only). Pass a valid name as the first argument."
    exit 1
  }
  # -i (keep stdin) + -t (allocate pseudo-TTY) are both required to get a working interactive shell with PS1 / readline / colors (sbx exec mirrors docker exec semantics).
  & sbx exec -it $Name bash
  exit $LASTEXITCODE
}

# ---------------- route subcommand: publish a box service as <name>.localhost via Traefik ----------------
# Routing layer for parallel box (dev / sandbox) services. For the name contract (full label chain /
# default web.<branch>.<repo> / no fixed service-type prefix) see Show-RouteUsage. Box create/run is handled
# by dev.ps1 itself (Start-DevBox / Invoke-Sandbox); the route subcommand only touches the routing layer.
# Verbs: up (start Traefik) / add <box> [port] [name] (add route) / rm <name> (remove route) /
#        ls (list routes) / down (stop Traefik + sweep all routes) / detect (show shared Traefik detection result)

$RouteCompose = "tools/parallel-dev/box-routing/proxy.compose.yml"
$RouteStoreImg = "alpine"  # Used to read/write the route file via a throwaway container when piggybacking on a named volume.
# Strict DNS label sequence: each label alnum start/end, hyphen inside, <=63. \A/\z (not ^/$) to reject trailing \n.
$RouteNameRe = '\A[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\z'
$RouteReserved = @('con','prn','aux','nul') + (1..9 | ForEach-Object { "com$_" }) + (1..9 | ForEach-Object { "lpt$_" })

# Auto-detect a shared Traefik bound to host :80 and return its file-provider source:
#   "volume:<name>" / "dir:<path>" / "" (none / no docker / config-file based).
function Get-RouteSharedTarget {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return "" }
  $rows = @(docker ps --filter publish=80 --format '{{.ID}}|{{.Image}}|{{.Label "com.docker.compose.project"}}|{{.Ports}}' 2>$null)
  $cands = @()
  foreach ($r in $rows) {
    if (-not $r) { continue }
    $p = $r -split '\|'
    if ($p[2] -eq 'box-routing') { continue }          # own Traefik is not a piggyback target
    if ($p[3] -notmatch ':80->') { continue }          # host :80 only (exclude ephemeral host ports)
    if ($p[1] -match 'traefik') { $cands += $p[0] }
  }
  if ($cands.Count -ne 1) { return "" }                 # 0=none / 2+=ambiguous => fail-closed
  $cid = $cands[0]
  # flag value: both '--flag=val' and '--flag val' forms
  $toks = @(docker inspect $cid --format '{{range .Config.Entrypoint}}{{println .}}{{end}}{{range .Config.Cmd}}{{println .}}{{end}}{{range .Args}}{{println .}}{{end}}' 2>$null)
  $filedir = ""
  for ($i = 0; $i -lt $toks.Count; $i++) {
    if ($toks[$i] -like '--providers.file.directory=*') { $filedir = $toks[$i] -replace '^--providers\.file\.directory=', ''; break }
    if ($toks[$i] -eq '--providers.file.directory' -and ($i + 1) -lt $toks.Count) { $filedir = $toks[$i + 1]; break }
  }
  if (-not $filedir) { return "" }
  # exact or parent-prefix mount match (do NOT embed filedir into the go-template).
  $mounts = @(docker inspect $cid --format '{{range .Mounts}}{{.Destination}}|{{.Name}}|{{.Source}}{{"\n"}}{{end}}' 2>$null)
  $best = $null; $bestlen = -1
  foreach ($ml in $mounts) {
    if (-not $ml) { continue }
    $mp = $ml -split '\|'; $d = $mp[0]
    if ($filedir -eq $d) { $best = @{ name = $mp[1]; src = $mp[2]; sub = "" }; break }
    if ($filedir.StartsWith("$d/") -and $d.Length -gt $bestlen) { $best = @{ name = $mp[1]; src = $mp[2]; sub = $filedir.Substring($d.Length + 1) }; $bestlen = $d.Length }
  }
  if (-not $best) { return "" }
  if ($best.name) { if (-not $best.sub) { return "volume:$($best.name)" } else { return "" } }   # volume subpath unsupported
  elseif ($best.src) { if ($best.sub) { return "dir:$($best.src)/$($best.sub)" } else { return "dir:$($best.src)" } }
  return ""
}

# Windows reserved device names; rejected per dot-label so $RouteDyn/<name>.yml never hits a reserved path.
function Test-RouteReservedName($n) { foreach ($label in $n.Split('.')) { if ($RouteReserved -contains $label.ToLower()) { return $true } } return $false }

# Route file read/write abstracted over the store target (dir / named volume).
# Volume mode uses a throwaway container (stdin cp / cat / rm) so it never bind-mounts a host
# path (avoids Docker Desktop file-sharing config). $name is already validated.
# Caller passes the route store state ($Dynvol / $Dyn) since these helpers do not own that state.
function Set-RouteStoreEntry { param($Name, $Content, $Dynvol, $Dyn)
  if ($Dynvol) {
    $Content | docker run --rm -i -v "${Dynvol}:/d" $RouteStoreImg sh -c "cat > /d/$Name.yml"
    if ($LASTEXITCODE -ne 0) { Write-Error "failed to write route '$Name' to volume '$Dynvol'"; exit 1 }
  } else {
    New-Item -ItemType Directory -Force -Path $Dyn | Out-Null
    Set-Content -LiteralPath "$Dyn/$Name.yml" -Value $Content -Encoding UTF8 -ErrorAction Stop
  }
}
function Read-RouteStoreEntry { param($Name, $Dynvol, $Dyn)
  if ($Dynvol) { docker run --rm -v "${Dynvol}:/d" $RouteStoreImg sh -c "cat /d/$Name.yml 2>/dev/null" 2>$null }
  else { if (Test-Path -LiteralPath "$Dyn/$Name.yml") { Get-Content -Raw -LiteralPath "$Dyn/$Name.yml" } }
}
function Remove-RouteStoreEntry { param($Name, $Dynvol, $Dyn)
  if ($Dynvol) {
    docker run --rm -v "${Dynvol}:/d" $RouteStoreImg rm -f "/d/$Name.yml" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error "failed to remove route '$Name' from volume '$Dynvol'"; exit 1 }
  } else {
    try {
      Remove-Item -LiteralPath "$Dyn/$Name.yml" -ErrorAction Stop
    } catch [System.Management.Automation.ItemNotFoundException] {
      # Idempotent: a route disappearing between Get-RouteStoreEntry verification and this delete is fine
      # (route rm already checks existence; this catch handles the rare TOCTOU race).
    } catch {
      Write-Error "failed to remove route '$Name' from '$Dyn': $($_.Exception.Message)"
      exit 1
    }
  }
}
# Returns @{ rc; names }; rc: 0=success (incl. empty store) / 2=backend error. The inner '; exit 0'
# keeps a final failed test on an empty store from surfacing as docker's rc, so nonzero rc means
# backend error only (the conflict scan relies on that for its fail-closed decision).
function Get-RouteStoreNames { param($Dynvol, $Dyn)
  if ($Dynvol) {
    $n = docker run --rm -v "${Dynvol}:/d" $RouteStoreImg sh -c 'for f in /d/*.yml; do [ -e "$f" ] && basename "$f" .yml; done; exit 0' 2>$null
    if ($LASTEXITCODE -ne 0) { return @{ rc = 2; names = @() } }
    return @{ rc = 0; names = @($n | Where-Object { $_ }) }
  } else {
    # Missing dir = empty store (rc 0); a real listing failure must surface as rc 2, not an empty list
    # (an empty-looking store would let the Host-conflict scan proceed unchecked).
    if (-not (Test-Path -LiteralPath $Dyn)) { return @{ rc = 0; names = @() } }
    try {
      return @{ rc = 0; names = @(Get-ChildItem -LiteralPath $Dyn -Filter *.yml -File -ErrorAction Stop | ForEach-Object { $_.BaseName }) }
    } catch {
      return @{ rc = 2; names = @() }
    }
  }
}
# Existence + content. Does NOT collapse read errors into "absent" (that would let the ownership/
# conflict guard fall through on backend failure). Returns @{ rc; content }; rc: 0=exists / 1=absent / 2=backend error.
function Get-RouteStoreEntry { param($Name, $Dynvol, $Dyn)
  if ($Dynvol) {
    # explicit if (so a failing cat is an error, not mistaken for absent). Join multi-line stdout
    # into a single raw string so regex/-notmatch behave like local Get-Content -Raw.
    $c = docker run --rm -v "${Dynvol}:/d" $RouteStoreImg sh -c "if [ -e /d/$Name.yml ]; then cat /d/$Name.yml; else exit 3; fi" 2>$null
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { return @{ rc = 0; content = ($c -join "`n") } }
    elseif ($rc -eq 3) { return @{ rc = 1; content = $null } }
    else { return @{ rc = 2; content = $null } }
  } else {
    if (Test-Path -LiteralPath "$Dyn/$Name.yml") { return @{ rc = 0; content = (Get-Content -Raw -LiteralPath "$Dyn/$Name.yml") } }
    else { return @{ rc = 1; content = $null } }
  }
}

function Show-RouteUsage {
  Write-Host @"
usage: pwsh scripts/dev.ps1 route <verb> [args]
  up                          start standing Traefik (once)
  add <box> [port] [name]     publish box dev port to an ephemeral host port and add <name>.localhost route
                              name default = web.<branch>.<repo> (from checkout); name is the full hostname
                              as dot-separated DNS labels (e.g. api.myapp -> api.myapp.localhost)
  rm <name>                   remove the <name> route
  ls                          list current routes
  down                        stop Traefik + clean all routes (boxes are left alone)
  detect                      show detected shared Traefik (add uses it automatically)

piggyback (use an existing shared Traefik / do not start own):
  A file-provider Traefik on :80 is auto-detected and piggybacked. No 'up' needed;
  just 'add' (up/down are no-ops while piggybacking). Use 'detect' to inspect.
  Override (config-file Traefik etc.) via env:
    BOX_ROUTING_DYNAMIC_DIR=<dir>     shared Traefik watches this bind-mounted dir
    BOX_ROUTING_DYNAMIC_VOLUME=<vol>  shared Traefik watches this named volume
"@
}

function Invoke-Route {
  param([string]$Verb = "help", [string[]]$RouteArgs = @())

  # The dispatcher always passes $Arg verbatim (possibly the empty string when the user types `pwsh dev.ps1 route`
  # with no verb), so the param default only fires when this function is called programmatically without -Verb.
  # Re-default here to match the old route.ps1 / route.sh contract where `route` with no verb prints help.
  if (-not $Verb) { $Verb = "help" }

  # Per-verb positional arity guard. Old route.ps1 had explicit param([string]$Box, [string]$Port = "3000", [string]$Name),
  # so a 4th positional triggered PowerShell's built-in "A positional parameter cannot be found" reject. After moving
  # to $RouteArgs we have to re-assert that arity ourselves (otherwise extras would be silently ignored).
  $maxArity = @{ "up" = 0; "add" = 3; "rm" = 1; "ls" = 0; "down" = 0; "detect" = 0; "help" = 0; "-h" = 0; "--help" = 0 }
  if ($maxArity.ContainsKey($Verb) -and $RouteArgs.Count -gt $maxArity[$Verb]) {
    Write-Error "'route $Verb' takes at most $($maxArity[$Verb]) positional argument(s); got $($RouteArgs.Count): $($RouteArgs -join ' ')"
    exit 1
  }

  # Route store target: explicit env > auto-detect > own (standalone) Traefik (repo dir).
  # Explicit env (override when detection fails): BOX_ROUTING_DYNAMIC_VOLUME / BOX_ROUTING_DYNAMIC_DIR.
  $dynvol = ""; $dyn = ""; $piggyback = $false; $detectSrc = ""
  if ($env:BOX_ROUTING_DYNAMIC_VOLUME -or $env:BOX_ROUTING_DYNAMIC_DIR) {
    if ($env:BOX_ROUTING_DYNAMIC_VOLUME -and $env:BOX_ROUTING_DYNAMIC_DIR) { Write-Error "BOX_ROUTING_DYNAMIC_DIR and BOX_ROUTING_DYNAMIC_VOLUME cannot both be set (choose one)."; exit 1 }
    $dynvol = $env:BOX_ROUTING_DYNAMIC_VOLUME
    if ($env:BOX_ROUTING_DYNAMIC_DIR) { $dyn = $env:BOX_ROUTING_DYNAMIC_DIR }
    $piggyback = $true; $detectSrc = "env"
  } else {
    $d = Get-RouteSharedTarget
    if ($d -like "volume:*") { $dynvol = $d.Substring(7); $piggyback = $true; $detectSrc = "auto" }
    elseif ($d -like "dir:*") { $dyn = $d.Substring(4); $piggyback = $true; $detectSrc = "auto" }
  }
  if (-not $piggyback) { $dyn = "tools/parallel-dev/box-routing/dynamic" }

  switch ($Verb) {
    "up" {
      if ($piggyback) {
        $via = if ($detectSrc -eq "auto") { "auto-detected" } else { "env" }
        if ($dynvol) { Write-Host "Piggyback mode ($via): using the existing shared Traefik, not starting own (target: named volume '$dynvol')." }
        else { Write-Host "Piggyback mode ($via): using the existing shared Traefik, not starting own (target: dir '$dyn')." }
        Write-Host "Just 'add' (the shared Traefik serves the routes)."
        exit 0
      }
      docker compose -f $RouteCompose up -d
      if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "Failed to start Traefik (port 80 may be in use). Options:"
        Write-Host "  - Piggyback an existing shared Traefik: set BOX_ROUTING_DYNAMIC_DIR=<dir> or BOX_ROUTING_DYNAMIC_VOLUME=<vol>, then add (no 'up' needed)."
        Write-Host "  - No named URL needed: sbx ports <box> --publish <port>:<port> then open http://127.0.0.1:<port> (localhost may fail: on macOS and similar it resolves to ::1 first and the sbx IPv6 forward resets the connection)."
        exit 1
      }
      Write-Host "Traefik up. Routed boxes are reachable at <name>.localhost."
    }
    "add" {
      $Box = $RouteArgs[0]; $Port = if ($RouteArgs.Count -ge 2 -and $RouteArgs[1]) { $RouteArgs[1] } else { "3000" }; $Name = if ($RouteArgs.Count -ge 3) { $RouteArgs[2] } else { "" }
      if (-not $Box) { Write-Error "route add <box> [port] [name]"; exit 1 }
      # name is the full hostname (<name>.localhost); default = web.<branch>.<repo> (web preview of current checkout).
      # $DevCallerBranch was captured BEFORE chdir at the top of this script (see comment there).
      if (-not $Name) {
        $branch = (($DevCallerBranch -replace '/','-') -replace '[^A-Za-z0-9-]','')
        $branch = ($branch -replace '^-+','' -replace '-+$','')
        $repo = ((Split-Path -Leaf (Get-Location).Path) -replace '[^A-Za-z0-9-]','')
        $repo = ($repo -replace '^-+','' -replace '-+$','')
        if ($branch) { $Name = "web.$branch.$repo" } else { $Name = "web.$repo" }
      }
      # Hostnames are case-insensitive (DNS / Traefik); normalize to lowercase so case-variant names
      # cannot become "different routes" depending on FS / backend case sensitivity.
      $Name = $Name.ToLowerInvariant()
      if ($Name -notmatch $RouteNameRe) { Write-Error "name '$Name' must be dot-separated DNS labels (each label: alnum start/end, hyphen inside, <=63)"; exit 1 }
      if (Test-RouteReservedName $Name) { Write-Error "name '$Name' contains a Windows reserved device name (con/prn/aux/nul/com1-9/lpt1-9)"; exit 1 }
      # .localhost is appended when generating the rule; a name carrying it would produce ...localhost.localhost.
      if ($Name -eq "localhost" -or $Name.EndsWith(".localhost")) { Write-Error "name '$Name' must not include .localhost (it is appended automatically; e.g. api.myapp -> api.myapp.localhost)"; exit 1 }
      # host port omitted = ephemeral; tolerate re-publish so add is idempotent.
      sbx ports $Box --publish $Port *> $null
      # Capture first and empty-check: ConvertFrom-Json throws on empty stdin.
      $json = sbx ports $Box --json
      if (-not $json) { Write-Error "could not resolve host port for ${Box}:${Port} (box running?)"; exit 1 }
      $hostport = ($json | ConvertFrom-Json | Where-Object { $_.host_ip -eq "127.0.0.1" -and $_.sandbox_port -eq [int]$Port } | Select-Object -First 1).host_port
      if (-not $hostport) { Write-Error "could not resolve host port for ${Box}:${Port} (box running?)"; exit 1 }
      # Fail-closed if a same-name route already exists and is not ours (different box OR no marker).
      # Re-adding the same box stays idempotent. Shared targets may hold foreign/hand-written .yml.
      $g = Get-RouteStoreEntry -Name $Name -Dynvol $dynvol -Dyn $dyn
      if ($g.rc -eq 2) { Write-Error "cannot verify route store (backend error); aborting."; exit 1 }
      if ($g.rc -eq 0) {
        $prev = ""
        $mm = [regex]::Match($g.content, '(?m)^# box:\s*(\S+)'); if ($mm.Success) { $prev = $mm.Groups[1].Value }
        # -cne (case-sensitive): -ne is case-insensitive in PowerShell and would treat box='Api' as the
        # same owner as 'api', diverging from the case-sensitive bash pair.
        if ($prev -cne $Box) { Write-Error "route '$Name' already exists (box='$prev'; markerless=possibly foreign); not overwriting. Use an explicit name: pwsh scripts/dev.ps1 route add $Box $Port <unique.name>"; exit 1 }
      }
      # Also scan other filenames for the same Host (a filename match alone cannot prevent duplicate routers
      # for one Host; typical case: an old default-name <branch>.<repo> file carrying Host web.... re-added
      # after upgrade). Same-box entries migrate (replace); other boxes / unmanaged entries fail closed.
      # 1st pass only detects (deleting mid-scan would destroy the old route when a later entry fails closed).
      # Listing is fail-closed too (a backend error collapsing into an empty list would skip the scan entirely).
      $ol = Get-RouteStoreNames -Dynvol $dynvol -Dyn $dyn
      if ($ol.rc -ne 0) { Write-Error "cannot list route store (backend error); aborting."; exit 1 }
      $migrate = @()
      foreach ($o in $ol.names) {
        if ($o -ceq $Name) { continue }
        # Fail-closed reader: collapsing a backend read error into "absent" would let the Host-conflict
        # guard pass on a transient failure and write a duplicate router.
        $og = Get-RouteStoreEntry -Name $o -Dynvol $dynvol -Dyn $dyn
        if ($og.rc -eq 2) { Write-Error "cannot verify route store entry '$o' (backend error); aborting."; exit 1 }
        if ($og.rc -ne 0 -or -not $og.content) { continue }
        # Conflict = an entry carrying the same Host, or a case-variant basename (hostnames are
        # case-insensitive; skipping a case-variant unchecked would bypass the ownership guard for a
        # foreign entry with the same effective hostname).
        $conflict = ($o -eq $Name)
        if (-not $conflict) {
          # Check every Host matcher (hand-written rules may combine hosts with ||; matching only the
          # first one would let the conflict scan miss the rest).
          foreach ($m in [regex]::Matches($og.content, 'Host\(`([^`]+)`\)')) {
            if ($m.Groups[1].Value -eq "$Name.localhost") { $conflict = $true; break }
          }
        }
        if (-not $conflict) { continue }
        $obox = ""; $obm = [regex]::Match($og.content, '(?m)^# box:\s*(\S+)'); if ($obm.Success) { $obox = $obm.Groups[1].Value }
        if ($obox -ceq $Box) {
          $migrate += $o
        } else {
          Write-Error "Host '$Name.localhost' is already used by route '$o' (box='$obox'); not overwriting."; exit 1
        }
      }
      # Double backticks emit a literal backtick (Traefik rule needs Host(`...`)).
      $yaml = @"
# box: $Box
http:
  routers:
    ${Name}:
      rule: "Host(``$Name.localhost``)"
      service: $Name
      entryPoints: [web]
  services:
    ${Name}:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:$hostport"
"@
      Set-RouteStoreEntry -Name $Name -Content $yaml -Dynvol $dynvol -Dyn $dyn
      # Delete old routes only after the new one is written (a transient write failure would otherwise
      # leave the box with no route at all). The momentary duplicate Host is harmless (same box, same
      # hostport), and a failed removal is retried by the scan on the next add (idempotent).
      foreach ($o in $migrate) {
        # On a case-insensitive FS a case-variant basename can be the SAME file as the just-written
        # entry; re-read it and skip deletion when it now holds the new yaml (deleting would remove
        # the new route itself).
        $g2 = Get-RouteStoreEntry -Name $o -Dynvol $dynvol -Dyn $dyn
        if ($g2.rc -eq 2) { Write-Error "cannot verify route store entry '$o' before deletion (backend error); the old route '$o' may remain."; exit 1 }
        if ($g2.rc -eq 1) { continue }
        if ($g2.content.TrimEnd() -ceq $yaml.TrimEnd()) { continue }
        Remove-RouteStoreEntry -Name $o -Dynvol $dynvol -Dyn $dyn
        Write-Host "migrated: replaced old route '$o' carrying the same Host with '$Name'"
      }
      if ($piggyback) { $tag = if ($detectSrc -eq "auto") { "piggyback/auto" } else { "piggyback" }; Write-Host "routed: http://$Name.localhost -> host:$hostport -> ${Box}:${Port} ($tag)" }
      else { Write-Host "routed: http://$Name.localhost -> host:$hostport -> ${Box}:${Port}" }
    }
    "rm" {
      $TargetName = $RouteArgs[0]
      if (-not $TargetName) { Write-Error "route rm <name>"; exit 1 }
      if ($TargetName -notmatch $RouteNameRe) { Write-Error "name '$TargetName' must be dot-separated DNS labels (each label: alnum start/end, hyphen inside, <=63)"; exit 1 }
      if (Test-RouteReservedName $TargetName) { Write-Error "name '$TargetName' contains a Windows reserved device name (con/prn/aux/nul/com1-9/lpt1-9)"; exit 1 }
      # Ownership check: only delete subcommand-managed routes (# box marker). Avoid removing foreign/
      # hand-written configs that may live in a shared piggyback target.
      $g = Get-RouteStoreEntry -Name $TargetName -Dynvol $dynvol -Dyn $dyn
      if ($g.rc -eq 2) { Write-Error "cannot verify route store (backend error); aborting."; exit 1 }
      if ($g.rc -eq 1) { Write-Host "route rm: '$TargetName' not found"; exit 0 }
      if ($g.content -notmatch '(?m)^# box:') { Write-Error "route '$TargetName' is not managed by this subcommand (no # box marker); refusing to delete."; exit 1 }
      Remove-RouteStoreEntry -Name $TargetName -Dynvol $dynvol -Dyn $dyn
      Write-Host "unrouted: $TargetName (publish remains; fully remove with sbx ports <box> --unpublish)"
    }
    "ls" {
      $names = (Get-RouteStoreNames -Dynvol $dynvol -Dyn $dyn).names
      if ($names) {
        foreach ($n in $names) {
          $c = Read-RouteStoreEntry -Name $n -Dynvol $dynvol -Dyn $dyn
          $u = ""; $h = ""
          if ($c) {
            $um = [regex]::Match($c, 'url:\s*"([^"]+)"'); if ($um.Success) { $u = $um.Groups[1].Value }
            # Read the hostname from the actual rule; store entries (hand-written / older format) may not match <name>.localhost.
            $hm = [regex]::Match($c, 'Host\(`([^`]+)`\)'); if ($hm.Success) { $h = $hm.Groups[1].Value }
          }
          if (-not $h) { $h = "$n.localhost" }
          Write-Host "http://$h -> $u"
        }
      } else {
        Write-Host "(no routes)"
      }
    }
    "down" {
      if ($piggyback) {
        Write-Host "Piggyback mode: shared Traefik is not managed here. Remove routes individually with 'route rm <name>'."
        exit 0
      }
      docker compose -f $RouteCompose down 2>$null
      # -Path (not -LiteralPath) so the *.yml wildcard is expanded.
      Remove-Item -Path "$dyn/*.yml" -ErrorAction SilentlyContinue
      Write-Host "Routing layer cleaned (boxes are managed by sbx)."
    }
    "detect" {
      if ($piggyback) {
        if ($dynvol) { Write-Host "target: named volume '$dynvol' ($detectSrc)" }
        else { Write-Host "target: dir '$dyn' ($detectSrc)" }
        Write-Host "=> piggyback mode (add uses the existing shared Traefik; no 'up' needed)."
      } else {
        Write-Host "No shared Traefik detected => own Traefik mode (pwsh scripts/dev.ps1 route up)."
        Write-Host "(Override with BOX_ROUTING_DYNAMIC_VOLUME / BOX_ROUTING_DYNAMIC_DIR.)"
      }
    }
    "help" { Show-RouteUsage }
    "-h" { Show-RouteUsage }
    "--help" { Show-RouteUsage }
    default { Write-Error "unknown route verb: $Verb"; Show-RouteUsage; exit 1 }
  }
}

function Start-DevBox {
  param([string]$Name)

  if (-not $Name) {
    $Name = New-DevName
    Write-Host "Creating new dev box: $Name (list: 'pwsh scripts/dev.ps1 ls', re-attach: 'pwsh scripts/dev.ps1 $Name')" -ForegroundColor Yellow
  } else {
    Test-NameValid -Name $Name
  }

  # Re-attach to an existing box (idempotent attach-or-create with the box already present) -> skip preflight.
  # An existing box already has image / setup in place; do not let an NG check-setup abort the attach.
  # Preflight runs only on the create path (rescues missed image build / setup check).
  $existingBoxes = @(sbx ls -q 2>$null)
  if ($LASTEXITCODE -ne 0) { $existingBoxes = @() }
  if (-not ($existingBoxes -ccontains $Name)) {
    Invoke-Preflight
  }

  # Acquire the lock before pair-setup so two concurrent invocations cannot race on `sbx create` and have the loser's failure cleanup wipe out the winner's box. New-Item with -ErrorAction Stop is the PS atomic-create guard; stale (dead pid) entries are removed and retried once.
  $LockFile = ".claude/tmp/cdx-dev-$Name.lock"
  if (-not (Test-Path -LiteralPath ".claude/tmp")) {
    New-Item -ItemType Directory -Path ".claude/tmp" -Force | Out-Null
  }
  $lockAcquired = $false
  try {
    New-Item -ItemType File -Path $LockFile -ErrorAction Stop -Value "$PID" | Out-Null
    $lockAcquired = $true
  } catch {}
  if (-not $lockAcquired) {
    $lockPidStr = Get-Content -LiteralPath $LockFile -Raw -ErrorAction SilentlyContinue
    $lockPid = 0
    if ($lockPidStr -and [int]::TryParse($lockPidStr.Trim(), [ref]$lockPid) -and (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
      Write-Error "another dev session '$Name' is active (pid=$lockPid). For parallel work, run pwsh scripts/dev.ps1 with no argument (auto-name) or pick a different <NAME>. For shell observation, run pwsh scripts/dev.ps1 shell $Name."
      exit 1
    }
    Write-Host "info: stale dev lock detected (pid=$lockPid dead); removing" -ForegroundColor Yellow
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    try {
      New-Item -ItemType File -Path $LockFile -ErrorAction Stop -Value "$PID" | Out-Null
    } catch {
      Write-Error "failed to acquire dev lock (race with another dev.ps1)"
      exit 1
    }
  }

  # Auto-provision cdx-<NAME> reviewer pair. openai secret absence / pair-setup failure is fail-open (claude box still starts; downstream skills surface a graceful-degrade message).
  # Bootstrap verify (server .venv) guards against treating a half-provisioned cdx box as ready.
  $existing = @(sbx ls -q 2>$null)
  if ($LASTEXITCODE -ne 0) { $existing = @() }
  $secrets = sbx secret ls -g 2>$null
  $hasOpenai = $false
  if ($LASTEXITCODE -eq 0) {
    foreach ($line in ($secrets -split "`r?`n")) {
      $tokens = $line.Trim() -split '\s+'
      if ($tokens.Count -ge 2 -and $tokens[0] -eq '(global)') {
        for ($i = 1; $i -lt $tokens.Count; $i++) {
          if ($tokens[$i] -ceq 'openai') { $hasOpenai = $true; break }
        }
        if ($hasOpenai) { break }
      }
    }
  }

  $pairReady = $false
  if ($hasOpenai) {
    $cdxExists = $existing -ccontains "cdx-$Name"
    $cdxReady = $false
    if ($cdxExists) {
      & sbx exec "cdx-$Name" test -x tools/a2a-review/codex-a2a-server/.venv/bin/python 2>$null
      if ($LASTEXITCODE -eq 0) { $cdxReady = $true }
    }
    if ($cdxReady) {
      $pairReady = $true
    } else {
      if ($cdxExists) {
        Write-Host "cdx-$Name is not bootstrapped; removing and re-provisioning..." -ForegroundColor Yellow
        & sbx rm -f "cdx-$Name" 2>$null | Out-Null
      }
      Write-Host "auto-provisioning cdx-$Name reviewer box from openai secret (takes ~30s)..." -ForegroundColor Yellow
      # In-process invoke (no `& powershell -File ...`) so the current host executable is reused: pwsh-only hosts would otherwise silently fail to provision.
      & scripts/internal/a2a-review.ps1 pair-setup $Name
      if ($LASTEXITCODE -eq 0) {
        $pairReady = $true
      } else {
        Write-Host "warning: cdx-$Name pair-setup failed. Removing partial box (will be re-provisioned on next 'pwsh scripts/dev.ps1 $Name')." -ForegroundColor Yellow
        & scripts/internal/a2a-review.ps1 pair-teardown $Name 2>$null | Out-Null
        Write-Host "warning: /a2a-review / /pr-codex-ci will not work, but the claude box will still start. If failures persist, debug with: pwsh scripts/internal/a2a-review.ps1 pair-setup $Name" -ForegroundColor Yellow
      }
    }
  } else {
    Write-Host "info: openai secret not registered; skipping cdx-$Name reviewer provision (/a2a-review / /pr-codex-ci will not work)." -ForegroundColor Yellow
    Write-Host "      To enable: sbx secret set -g openai --oauth  (after registration, re-run 'pwsh scripts/dev.ps1 $Name' to provision)" -ForegroundColor Yellow
  }

  # Fork pair-serve as a child job: keeps the host-resident daemon path off the table while still tearing down per-pair when the claude box TTY exits. Tied to this script's PID so no install.ps1 / scheduled task is required (workshop premise: "clone and go").
  # PS 5.1 cannot reliably kill the external children of Start-Job, so the teardown step also runs pair-teardown which pkills server.py inside the cdx box as a belt-and-suspenders.
  # Tee pair-serve output to a per-NAME log file (Start-Job already keeps the terminal clean by capturing to the job, but the file mirrors the bash side and provides a post-mortem artifact).
  $serveJob = $null
  $PairServeLog = ".claude/tmp/cdx-serve-$Name.log"
  if ($pairReady) {
    # PS 5.1 Start-Job uses $HOME\Documents as cwd regardless of caller (Windows-only quirk), so resolve the relative script path against the repo root before invoking.
    $repoRoot = (Get-Location).Path
    $serveJob = Start-Job -ScriptBlock {
      param($n, $root, $log)
      Set-Location -LiteralPath $root
      & scripts/internal/a2a-review.ps1 pair-serve $n *>&1 | Out-File -FilePath $log -Encoding utf8
    } -ArgumentList $Name, $repoRoot, $PairServeLog
  }

  # App identity broker: only boxes carrying the APP_IDENTITY_ENABLE marker (an sbx custom secret, per-box or
  # global scope) start the broker, which mints a repo-scoped App installation token and live-updates the box's
  # per-box github secret (~50min refresh), so the box's git/gh (still seeing only the sentinel) author PRs as
  # the App bot. No marker = the global PAT (clone-and-go / forks unchanged). Marker present but config file /
  # node missing = warning skip. Broker failure never blocks the dev box (the finally block kills it).
  # Start-Process (not Start-Job) so the node child has a real handle that Stop-Process can reliably kill on PS 5.1.
  $AppBrokerConfig = ".claude/app-broker.local.json"
  $brokerProc = $null
  $brokerLog = ".claude/tmp/app-broker-$Name.log"
  if (Test-AppIdentityEnabled $Name) {
    if (-not (Test-Path -LiteralPath $AppBrokerConfig)) {
      Write-Host "warning: APP_IDENTITY marker present but $AppBrokerConfig (appId/keyPath) is missing; skipping app-broker (github stays on the global PAT)." -ForegroundColor Yellow
    } elseif (-not (Get-Command node -ErrorAction SilentlyContinue)) {
      Write-Host "warning: APP_IDENTITY marker present but node was not found; skipping app-broker (github stays on the global PAT)." -ForegroundColor Yellow
    } else {
      $brokerProc = Start-Process -FilePath "node" `
        -ArgumentList @("scripts/internal/app-token-broker.js", "--box", $Name) `
        -WorkingDirectory (Get-Location).Path -NoNewWindow -PassThru `
        -RedirectStandardOutput $brokerLog -RedirectStandardError "$brokerLog.err"
      Write-Host "info: app-broker started (box '$Name' github identity -> App bot, pid=$($brokerProc.Id), log $brokerLog)." -ForegroundColor Cyan
    }
  }

  # Capture sbx run's exit code before the finally block so the teardown does not overwrite $LASTEXITCODE (a failed sbx run would otherwise be reported as success once pair-teardown succeeded).
  $runExit = 0
  try {
    if ($existing -ccontains $Name) {
      & sbx run --name $Name
    } elseif (Test-KimiEnabled $Name) {
      Invoke-KimiPreflight $Name
      & sbx run --name $Name claude -t $Template --kit $Kit --kit $KitKimi .
    } else {
      & sbx run --name $Name claude -t $Template --kit $Kit .
    }
    $runExit = $LASTEXITCODE
  } finally {
    if ($serveJob) {
      Stop-Job $serveJob -ErrorAction SilentlyContinue
      Remove-Job $serveJob -Force -ErrorAction SilentlyContinue
      & scripts/internal/a2a-review.ps1 pair-teardown $Name 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $LockFile) {
      Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $PairServeLog) {
      Remove-Item -LiteralPath $PairServeLog -Force -ErrorAction SilentlyContinue
    }
    if ($brokerProc) {
      Stop-Process -Id $brokerProc.Id -Force -ErrorAction SilentlyContinue
      # Revert to the global PAT: drop the per-box github App token so a later run without the marker does
      # not keep injecting a now-expired App token.
      & sbx secret rm $Name github -f 2>$null | Out-Null
    }
    Remove-Item -LiteralPath $brokerLog -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$brokerLog.err" -Force -ErrorAction SilentlyContinue
  }

  exit $runExit
}

# Pre-dispatch guards: -Yes / -All are only meaningful for `prune`, -Quiet / -q is only meaningful for `ls`. Without these, `pwsh scripts/dev.ps1 kill boxA -Yes` / `ls -All` / `kill -q` etc bind the script-level switches and silently fall through to the subcommand with no effect and no warning. Reject explicitly so misuse fails fast.
# -cne (not -ne) so the guards agree with the case-sensitive dispatch below: `Prune -Yes` dispatches to default (box launch), not 'prune', so it must be rejected here.
if ($Yes -and $Action -cne 'prune') {
  Write-Error "-Yes is only supported for 'prune' (got '$Action')."
  exit 1
}
if ($All -and $Action -cne 'prune') {
  Write-Error "-All is only supported for 'prune' (got '$Action')."
  exit 1
}
if ($Quiet -and $Action -cne 'ls') {
  Write-Error "-Quiet / -q is only supported for 'ls' (got '$Action')."
  exit 1
}

# subcommand dispatch
# Reject extra positional args for non-route subcommands. ValueFromRemainingArguments above swallows >2 positional
# (otherwise PowerShell would reject them itself), so we have to re-assert fail-fast here for everything except route.
# $null check instead of truthiness: a lone empty-string arg (@('')) unwraps to $false and would slip through.
if ($null -ne $RemainingArgs -and $RemainingArgs.Count -gt 0 -and $Action -cne 'route') {
  Write-Error "'$Action' takes no extra positional arguments (got: $($RemainingArgs -join ' '))"
  exit 1
}

switch -CaseSensitive ($Action) {
  '' {
    # ContainsKey instead of truthiness: an explicit empty-string arg binds $Arg but evaluates falsy, and it must be rejected too.
    if ($PSBoundParameters.ContainsKey('Arg')) {
      Write-Error "'' takes no extra positional arguments (got: $Arg)"
      exit 1
    }
    Start-DevBox -Name ""
    break
  }
  '-h' { Show-Usage; exit 0 }
  '--help' { Show-Usage; exit 0 }
  'help' { Show-Usage; exit 0 }
  'ls' {
    # ContainsKey instead of truthiness: an explicit empty-string arg binds $Arg but evaluates falsy, and it must be rejected too.
    if ($PSBoundParameters.ContainsKey('Arg')) { Write-Error "'ls' takes no positional arguments (use -q / -Quiet for name-only output)"; exit 1 }
    Invoke-Ls -Quiet:$Quiet
    break
  }
  'attach' { Invoke-Attach -ArgValue $Arg; break }
  'kill' { Invoke-Kill -ArgValue $Arg; break }
  'prune' {
    # ContainsKey instead of truthiness: an explicit empty-string arg binds $Arg but evaluates falsy, and it must be rejected too.
    if ($PSBoundParameters.ContainsKey('Arg')) { Write-Error "'prune' takes no positional arguments (use -Yes / -All for switches)"; exit 1 }
    Invoke-Prune -Yes:$Yes -All:$All
    break
  }
  'sandbox' { Invoke-Sandbox -Name $Arg; break }
  'observe' { Invoke-Observe -Name $Arg; break }
  'shell' { Invoke-Shell -Name $Arg; break }
  'route' { Invoke-Route -Verb $Arg -RouteArgs $RemainingArgs; break }
  'rm' { Invoke-Kill -ArgValue $Arg; break }
  'stop' { Invoke-Kill -ArgValue $Arg; break }
  default {
    if ($Action.StartsWith('-')) {
      Write-Error "unknown flag '$Action'"
      Show-Usage
      exit 1
    }
    # ContainsKey instead of truthiness: an explicit empty-string arg binds $Arg but evaluates falsy, and it must be rejected too.
    if ($PSBoundParameters.ContainsKey('Arg')) {
      Write-Error "'$Action' takes no extra positional arguments (got: $Arg)"
      exit 1
    }
    Start-DevBox -Name $Action
  }
}
