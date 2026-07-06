# headful CDP bridge (PowerShell pair of cdp-bridge.sh).
# Drive the host's VISIBLE Chrome from inside a box via CDP.
#
# Same command, context-aware:
#   - HOST (no $env:SANDBOX_VM_ID): launch a throwaway-profile visible Chrome with
#     remote debugging + open box egress to it.
#   - BOX  ($env:SANDBOX_VM_ID set): run a socat relay tunnelling
#     localhost:<relay> -> sbx proxy(CONNECT) -> host:<port>.
#     (Boxes are Linux; in practice the box side is invoked via cdp-bridge.sh.
#      This branch is kept for parity.)
#
# == SECURITY (read this) ==
# CDP = full control of that browser (arbitrary JS / read cookies+sessions / navigate).
# The host side FORCES a dedicated throwaway profile and REFUSES the real profile.
# Treat the bridged Chrome as agent-controlled: do NOT log into real accounts in it.
# Path is loopback-only (127.0.0.1) with a tight policy allow (localhost:<port>).
# See docs/guide/headful-bridge.md.
param(
  [Parameter(Position=0)][string]$Verb = "help",
  [string]$Port,
  [string]$RelayPort,
  [string]$Box,
  [string]$ProfileDir,
  [switch]$NoConnect
)
$ErrorActionPreference = "Stop"

# Flags override env, env overrides default. Track whether the port was set explicitly: when it
# was, an occupied port aborts (preflight); when not, host up auto-scans a free port.
$PortExplicit = [bool]($Port -or $env:CDP_PORT)
if (-not $Port)      { $Port      = if ($env:CDP_PORT) { $env:CDP_PORT } else { "9222" } }
if (-not $RelayPort) { $RelayPort = if ($env:CDP_RELAY_PORT) { $env:CDP_RELAY_PORT } else { "9333" } }
if (-not $Box -and $env:CDP_BOX) { $Box = $env:CDP_BOX }
# If CDP_PROFILE_DIR / -ProfileDir is set, use it and do not auto-delete. Otherwise create a fresh
# temp dir on each up and remove it on down (true throwaway). The resolved dir is finalized in
# Resolve-ProfileDir-Up (this $ProfileDir is then reset to "" to hold that resolved value).
$ProfileDirExplicit = if ($ProfileDir) { $ProfileDir } else { $env:CDP_PROFILE_DIR }
$ProfileDir = ""

function In-Box { return [bool]$env:SANDBOX_VM_ID }

function Repo-Root {
  $d = git rev-parse --path-format=absolute --git-common-dir 2>$null
  if ($d) { return (Split-Path -Parent $d) } else { return "." }
}
$TmpDir = Join-Path (Repo-Root) ".claude/tmp"
# Host-only state dir for cleanup handles (profile path / policy id / scope). Storing these on
# the bind-mounted repo (.claude/tmp) lets a box agent rm them before host runs `down`, which
# would skip the Chrome kill and lose the policy id needed to revoke the rule (P1 security).
# Use $XDG_CACHE_HOME (or $HOME/.cache) which is not bind-mounted into the box. Relay pidfile
# stays under .claude/tmp because the box needs to see its own relay state.
function Host-StateDir {
  $base = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } else { Join-Path $HOME ".cache" }
  return (Join-Path $base "coding-agent-playbook/cdp-bridge")
}
$HostStateDir = Host-StateDir
# relay state is box-side; .claude/tmp is shared across boxes (same bind-mounted repo), so
# namespace it by box ($env:SANDBOX_VM_ID) to stop parallel dev boxes clobbering each other's
# relay pidfile.
function Relay-BoxTag     { if ($env:SANDBOX_VM_ID) { return $env:SANDBOX_VM_ID } else { return "host" } }
function Relay-PidFile    { return (Join-Path $TmpDir ("cdp-relay-" + (Relay-BoxTag) + "-$RelayPort.pid")) }
function Policy-IdFile    { return (Join-Path $HostStateDir "cdp-policy-$Port.id") }
# Persist the CDP_BOX scope alongside the rule id so down can match --sandbox even when the
# env var is not set in the down shell (rule is otherwise unremovable without the right scope).
function Policy-ScopeFile { return (Join-Path $HostStateDir "cdp-policy-$Port.scope") }
function Profile-PathFile { return (Join-Path $HostStateDir "cdp-profile-$Port.path") }
# host up records the chosen port here (single pointer, not port-keyed) so down/status can find it without -Port.
function Last-PortFile    { return (Join-Path $HostStateDir "cdp-last-port") }
# up-time relay port, so down without -RelayPort can still stop the box relay (keyed by RelayPort).
function Last-RelayFile   { return (Join-Path $HostStateDir "cdp-last-relay") }

# Validate a path before rm-rf: must be an existing dir whose canonical basename matches
# the mktemp pattern (cdp-bridge-profile-<8 hex>) and whose parent equals the canonical
# temp root we created it under. Defends against pathfile tampering via the repo bind-mount.
function Is-SafeThrowawayProfile([string]$p) {
  if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Container)) { return $false }
  $canon = Canonical-Path $p
  $base  = Split-Path -Leaf $canon
  $parent = Split-Path -Parent $canon
  if ($base -notmatch '^cdp-bridge-profile-[0-9a-fA-F]{8}$') { return $false }
  $allowed = @()
  if ($env:TEMP) { $allowed += (Canonical-Path $env:TEMP) }
  $allowed += (Canonical-Path ([System.IO.Path]::GetTempPath().TrimEnd([char]'\', [char]'/')))
  foreach ($a in $allowed) { if ($a -and $parent -eq $a) { return $true } }
  return $false
}

function Resolve-ProfileDir-Up {
  if ($script:ProfileDirExplicit) { $script:ProfileDir = $script:ProfileDirExplicit; return }
  # implicit mode is always fresh per the throwaway contract (reuse after preflight would
  # carry stale session/cookies). Sweep the dir an old pathfile points at via the safety check.
  $pf = Profile-PathFile
  if ((Test-Path $pf) -and ((Get-Item $pf).Length -gt 0)) {
    $stale = (Get-Content $pf -Raw).Trim()
    if (Is-SafeThrowawayProfile $stale) {
      Remove-Item -Recurse -Force -LiteralPath $stale -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue
  }
  New-Item -ItemType Directory -Force -Path $HostStateDir | Out-Null
  $base = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
  $script:ProfileDir = Join-Path $base ("cdp-bridge-profile-" + [System.Guid]::NewGuid().ToString("N").Substring(0,8))
  New-Item -ItemType Directory -Force -Path $script:ProfileDir | Out-Null
  $script:ProfileDir | Out-File -Encoding ascii $pf
}

function Resolve-ProfileDir-Down {
  if ($script:ProfileDirExplicit) { $script:ProfileDir = $script:ProfileDirExplicit; return }
  $pf = Profile-PathFile
  if ((Test-Path $pf) -and ((Get-Item $pf).Length -gt 0)) {
    $script:ProfileDir = (Get-Content $pf -Raw).Trim()
  } else { $script:ProfileDir = "" }
}

# ---- host side --------------------------------------------------------------

# Canonicalize a path component-by-component so a symlink at ANY level (not just the leaf)
# is resolved. Required because ResolveLinkTarget on the leaf alone misses parent symlinks:
# e.g. CDP_PROFILE_DIR=/tmp/chrome-link/Default where /tmp/chrome-link points at a real
# profile and Default already exists as a directory. Resolve-Path also does not chase reparse
# points reliably on macOS/Linux (/tmp -> /private/tmp is not followed). Strategy: when the
# path exists, recurse on the parent to canonicalize ancestors, then re-append the leaf;
# follow any symlink target before recursing. When the path does not exist, walk up to the
# longest existing prefix, canonicalize that, then re-append the not-yet-existing tail.
function Canonical-Path([string]$p) {
  if (-not $p) { return $p }
  try {
    if (Test-Path -LiteralPath $p) {
      $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop
      $full = $item.FullName
      $target = $null
      if ($item.PSObject.Methods['ResolveLinkTarget']) {
        try { $r = $item.ResolveLinkTarget($true); if ($r) { $target = $r.FullName } } catch {}
      }
      if (-not $target -and $item.PSObject.Properties['LinkTarget'] -and $item.LinkTarget) {
        $t = $item.LinkTarget; if ($t -is [array]) { $t = $t[0] }
        if (-not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $full) $t }
        $target = $t
      } elseif (-not $target -and $item.PSObject.Properties['Target'] -and $item.Target) {
        $t = $item.Target; if ($t -is [array]) { $t = $t[0] }
        if (-not [System.IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path -Parent $full) $t }
        $target = $t
      }
      if ($target -and $target -ne $full) { return (Canonical-Path $target) }
      $parent = Split-Path -Parent $full
      $leaf = Split-Path -Leaf $full
      if ($parent -and $parent -ne $full) {
        $cparent = Canonical-Path $parent
        return (Join-Path $cparent $leaf)
      }
      return $full
    }
    $tail = ""
    $cur = $p
    while ($cur -and -not (Test-Path -LiteralPath $cur)) {
      $leaf = Split-Path -Leaf $cur
      $tail = if ($tail) { Join-Path $leaf $tail } else { $leaf }
      $parent = Split-Path -Parent $cur
      if (-not $parent -or $parent -eq $cur) { return $p }
      $cur = $parent
    }
    $cbase = Canonical-Path $cur
    if ($tail) { return (Join-Path $cbase $tail) }
    return $cbase
  } catch { return $p }
}

function Guard-Profile {
  $canon = Canonical-Path $script:ProfileDir
  # Windows roots only when LOCALAPPDATA is set: on macOS/Linux pwsh it is undefined and an
  # eager Join-Path $env:LOCALAPPDATA would throw (null-arg), crashing the host `up` path.
  $real = @()
  if ($env:LOCALAPPDATA) {
    $real += @(
      (Join-Path $env:LOCALAPPDATA "Google/Chrome/User Data"),
      (Join-Path $env:LOCALAPPDATA "Google/Chrome Beta/User Data"),
      (Join-Path $env:LOCALAPPDATA "Google/Chrome SxS/User Data"),
      (Join-Path $env:LOCALAPPDATA "Chromium/User Data"),
      (Join-Path $env:LOCALAPPDATA "Microsoft/Edge/User Data"),
      (Join-Path $env:LOCALAPPDATA "BraveSoftware/Brave-Browser/User Data")
    )
  }
  # Linux Chromium honors $CHROME_CONFIG_HOME / $XDG_CONFIG_HOME for the default profile root
  # ( https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md ). Include the
  # XDG-resolved root and the hard-coded `~/.config` fallback so guard catches the actual default
  # even when env points elsewhere.
  $linuxChromeRoot = if ($env:CHROME_CONFIG_HOME) { $env:CHROME_CONFIG_HOME }
    elseif ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME }
    else { Join-Path $HOME ".config" }
  $real += @(
    (Join-Path $HOME "Library/Application Support/Google/Chrome"),
    (Join-Path $HOME "Library/Application Support/Google/Chrome Beta"),
    (Join-Path $HOME "Library/Application Support/Google/Chrome Canary"),
    (Join-Path $HOME "Library/Application Support/Chromium"),
    (Join-Path $HOME "Library/Application Support/Microsoft Edge"),
    (Join-Path $HOME "Library/Application Support/BraveSoftware/Brave-Browser"),
    (Join-Path $linuxChromeRoot "google-chrome"),
    (Join-Path $linuxChromeRoot "google-chrome-beta"),
    (Join-Path $linuxChromeRoot "google-chrome-unstable"),
    (Join-Path $linuxChromeRoot "chromium"),
    (Join-Path $linuxChromeRoot "microsoft-edge"),
    (Join-Path $linuxChromeRoot "BraveSoftware/Brave-Browser"),
    (Join-Path $HOME ".config/google-chrome"),
    (Join-Path $HOME ".config/google-chrome-beta"),
    (Join-Path $HOME ".config/google-chrome-unstable"),
    (Join-Path $HOME ".config/chromium"),
    (Join-Path $HOME ".config/microsoft-edge"),
    (Join-Path $HOME ".config/BraveSoftware/Brave-Browser")
  )
  # OrdinalIgnoreCase: Windows/macOS filesystems are case-insensitive, so a case-variant of a
  # real profile path must still be caught. Comparing case-insensitively everywhere only risks
  # over-rejecting on case-sensitive Linux (safe direction for a guard), never under-rejecting.
  $ci = [System.StringComparison]::OrdinalIgnoreCase
  $sep = [System.IO.Path]::DirectorySeparatorChar
  foreach ($r in $real) {
    if (-not $r) { continue }
    $rc = Canonical-Path $r
    # Match the .sh boundary ("$rc" exactly OR "$rc/<...>"): a bare StartsWith would also reject
    # legitimate sibling throwaways like google-chrome-test, which is a usability regression.
    if ($canon.Equals($rc, $ci) -or $canon.StartsWith($rc + $sep, $ci)) {
      Write-Error "CDP_PROFILE_DIR points at a real browser profile ($script:ProfileDir -> $canon). The bridge requires a throwaway profile; choose another dir."
    }
  }
}

# Cache the -NoProxy support detection once: PowerShell 6+ has the parameter, Windows PS 5.1
# does not. Without bypassing, HTTP_PROXY/system proxy can route localhost CDP probes through
# the proxy instead of the local Chrome and break preflight/readiness/status detection.
$script:IwrNoProxySupported = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('NoProxy')
function Probe-Localhost([string]$url, [int]$timeoutSec) {
  $params = @{ Uri = $url; UseBasicParsing = $true; TimeoutSec = $timeoutSec }
  if ($script:IwrNoProxySupported) { $params.NoProxy = $true }
  Invoke-WebRequest @params | Out-Null
}

# If the port already speaks CDP before we launch, another process owns it (possibly a
# real-profile Chrome). Proceeding would let Wait-ChromeReady succeed against that existing
# browser and policy-allow would expose it to the box, breaking the throwaway guarantee.
# Detect occupation up front and refuse.
function Preflight-PortFree {
  $occupied = $false
  try { Probe-Localhost "http://localhost:$Port/json/version" 1; $occupied = $true } catch {}
  if ($occupied) {
    Write-Error "localhost:$Port is already serving CDP (another process owns it). Refusing to start: a throwaway Chrome cannot be guaranteed and policy-allow would expose the existing browser (possibly a real profile) to the box. Close it or pass -Port <other>."
  }
}

# True when 127.0.0.1:$p has no listener (connection refused). Checks TCP occupancy regardless of
# CDP, so a non-CDP service holding the port is not mistaken for "free" (which would make Chrome
# fail to bind). ConnectAsync + a short wait stays fast on a refused/free port.
function Port-Free([string]$p) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $t = $c.ConnectAsync("127.0.0.1", [int]$p)
    $occupied = ($t.Wait(300) -and $c.Connected)
    $c.Close()
    return (-not $occupied)
  } catch { return $true }
}
# Finalize $Port: when explicit (-Port/CDP_PORT) abort if occupied; when not, auto-scan from the
# default for a TCP-free port. We only launch our throwaway Chrome on a FREE port and never
# policy-allow an occupied one, so the security invariant is unchanged.
function Resolve-Port {
  if ($PortExplicit) {
    Preflight-PortFree   # CDP-speaking existing browser -> security abort
    if (-not (Port-Free $Port)) { Write-Error "localhost:$Port is already in use (non-CDP listener). Pass -Port <other>." }
    return
  }
  $start = [int]$Port
  for ($p = $start; $p -le ($start + 40); $p++) {
    if (Port-Free $p) { $script:Port = "$p"; return }
  }
  Write-Error "No free port found in $start..$($start + 40). Pass -Port <port>."
}

function Find-Chrome {
  $cands = @(
    "C:/Program Files/Google/Chrome/Application/chrome.exe",
    "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "google-chrome","chromium","chrome"
  )
  foreach ($c in $cands) {
    if (Test-Path $c) { return $c }
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
  }
  return $null
}

function Wait-ChromeReady {
  for ($i = 0; $i -lt 10; $i++) {
    try { Probe-Localhost "http://localhost:$Port/json/version" 1; return $true } catch {}
    Start-Sleep -Milliseconds 500
  }
  return $false
}

# Kill the Chrome we launched, matched by its throwaway profile dir in the command line.
# Windows uses Get-CimInstance / Win32_Process (gives full CommandLine). On macOS/Linux pwsh
# 7.x, Get-Process.CommandLine is null (verified macOS pwsh 7.5.4) so it cannot match by profile
# path: fall back to the system `pkill -f` (parity with cdp-bridge.sh). $IsWindows is $null on
# Windows PowerShell 5.1, so `-eq $false` correctly routes 5.1 to the CIM branch.
# Match on the profile path itself (not "--user-data-dir=$dir"): the launch quotes the value
# (--user-data-dir="...") and Windows keeps that quote in the command line, so an unquoted
# "=$dir" pattern would miss it. Escape the path so [ ] etc. in it are not treated as -like
# wildcards.
function Stop-ChromeByProfile([string]$dir) {
  if (-not $dir) { return }
  if ($IsWindows -eq $false) {
    # pkill -f matches against the full argv (parity with cdp-bridge.sh). The `--user-data-dir=`
    # prefix narrows the match so unrelated processes containing the path elsewhere are skipped.
    & pkill -f -- "--user-data-dir=$dir" 2>$null
  } else {
    $pat = "*" + [System.Management.Automation.WildcardPattern]::Escape($dir) + "*"
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -like $pat } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
}

function Host-Rollback {
  # Gate the kill matcher behind the safety check too (a tampered pathfile reaching this path
  # via stale state must not cause unrelated Chrome instances to be killed).
  if ($script:ProfileDirExplicit -or (Is-SafeThrowawayProfile $script:ProfileDir)) {
    Stop-ChromeByProfile $script:ProfileDir
  }
  $idf = Policy-IdFile; $scopef = Policy-ScopeFile
  if (Test-Path $idf) {
    $id = (Get-Content $idf -Raw).Trim()
    $scope = if ((Test-Path $scopef) -and ((Get-Item $scopef).Length -gt 0)) { (Get-Content $scopef -Raw).Trim() } else { "" }
    # sbx v0.33+ contract: `sbx policy rm network --id <id>` (sandbox-scoped rules also need
    # --sandbox). The previous `sbx policy rm $id` form fails with unknown-command, leaving the
    # allow rule in place and exposing port re-use as a security regression.
    if ($scope) {
      sbx policy rm network --sandbox $scope --id $id 2>$null | Out-Null
    } else {
      sbx policy rm network --id $id 2>$null | Out-Null
    }
    # Keep the idfile/scope on failure so a later `down` can retry; deleting them leaks the
    # only handle to the rule and accumulates stale allows on port re-use.
    if ($LASTEXITCODE -eq 0) {
      Remove-Item $idf -ErrorAction SilentlyContinue
      Remove-Item $scopef -ErrorAction SilentlyContinue
    }
  }
  # implicit only: auto-delete behind the safety check (prevents deleting an arbitrary host dir).
  if (-not $script:ProfileDirExplicit -and (Is-SafeThrowawayProfile $script:ProfileDir)) {
    Remove-Item -Recurse -Force -LiteralPath $script:ProfileDir -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Profile-PathFile) -ErrorAction SilentlyContinue
  }
}

function Host-Up {
  # If an earlier down kept the idfile/scope (sbx policy rm failed), a fresh up would overwrite
  # those handles and leak the previous rule (no way to retry-revoke it later). Require explicit
  # cleanup first.
  # With auto-port a previous bridge may be on a different port than this $Port, so scan all
  # cdp-policy-*.id rather than the default-keyed file (checking only 9222 before port resolution
  # would miss a leftover rule on another port -> double bridge / leak).
  $prevIdf = Get-ChildItem -Path (Join-Path $HostStateDir "cdp-policy-*.id") -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($prevIdf -and $prevIdf.Length -gt 0) {
    $prevId = (Get-Content $prevIdf.FullName -Raw).Trim()
    $prevScopef = $prevIdf.FullName -replace '\.id$', '.scope'
    $prevScope = if ((Test-Path $prevScopef) -and ((Get-Item $prevScopef).Length -gt 0)) { (Get-Content $prevScopef -Raw).Trim() } else { "(global)" }
    Write-Error "Previous up's egress rule ($prevId, scope=$prevScope) is still un-revoked. New up would overwrite the handle and leak the old rule. Run 'pwsh scripts/cdp-bridge.ps1 down' first, or manually 'sbx policy rm network --id $prevId [--sandbox $prevScope]' before re-up."
  }
  # finalize port before mktemp: detecting/avoiding an occupied port first avoids creating a throwaway dir for nothing.
  Resolve-Port
  Resolve-ProfileDir-Up
  Guard-Profile
  if (-not (Get-Command sbx -ErrorAction SilentlyContinue)) { Write-Error "sbx not found (run on host?)" }
  $chrome = Find-Chrome
  if (-not $chrome) { Write-Error "Chrome/Chromium not found." }
  New-Item -ItemType Directory -Force -Path $script:ProfileDir,$HostStateDir | Out-Null

  # Restrict --remote-allow-origins to the relay origin only (avoid the broad `*` bypass).
  # Quote --user-data-dir: Start-Process joins ArgumentList with spaces without auto-quoting, so a
  # profile path containing a space (e.g. a Windows home like "C:\Users\John Doe\...") would be
  # truncated and `down`'s command-line match would miss it. Embed quotes around the value.
  $allowOrigins = "http://localhost:$RelayPort,http://127.0.0.1:$RelayPort"
  Start-Process -FilePath $chrome -ArgumentList @(
    "--remote-debugging-port=$Port","--remote-allow-origins=$allowOrigins",
    "--user-data-dir=`"$script:ProfileDir`"","--no-first-run","--no-default-browser-check","about:blank"
  ) | Out-Null
  Write-Host "host Chrome started (port=$Port, profile=$script:ProfileDir)."

  if (-not (Wait-ChromeReady)) {
    Write-Warning "host Chrome did not respond on localhost:$Port. Rolling back."
    Host-Rollback
    Write-Error "host Chrome failed to start."
  }

  # Scope the egress to CDP_BOX when given (same --sandbox pattern as a2a-review.sh); otherwise any
  # box on the host could attach to the visible Chrome while the bridge is up, so warn.
  if ($Box) {
    $out = (sbx policy allow network --sandbox $Box "localhost:$Port" 2>&1 | Out-String)
  } else {
    Write-Warning "-Box/CDP_BOX unset: allowing localhost:$Port egress for ALL boxes on this host (pass -Box <box-name> to scope to one)."
    $out = (sbx policy allow network "localhost:$Port" 2>&1 | Out-String)
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Warning $out
    Write-Warning "sbx policy allow failed. Rolling back."
    Host-Rollback
    Write-Error "sbx policy allow failed."
  }
  Write-Host $out
  $m = [regex]::Match($out, "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
  if ($m.Success) {
    $m.Value | Out-File -Encoding ascii (Policy-IdFile)
  } else {
    # Capturing the rule id is mandatory: without it down cannot revoke (leak), and the
    # "idfile absent == revoked" assumption used for pointer cleanup breaks. Roll back loudly.
    Host-Rollback
    Write-Error "egress rule was allowed but its rule id could not be parsed from output (cannot revoke). Rolled back. Check/remove manually: sbx policy ls (localhost:$Port)."
  }
  # Persist scope (empty = global) so down knows whether to add --sandbox.
  $scopeVal = if ($Box) { $Box } else { "" }
  $scopeVal | Out-File -Encoding ascii -NoNewline (Policy-ScopeFile)
  # Record the chosen port / relay port so down/status can find them without flags.
  "$Port" | Out-File -Encoding ascii (Last-PortFile)
  "$RelayPort" | Out-File -Encoding ascii (Last-RelayFile)

  if ($Box -and -not $NoConnect) {
    # One host command sets up the box relay too: sbx exec runs the box-side bash script (boxes are
    # Linux). sbx exec's cwd is the repo root, so a relative path works (same as dev.sh).
    Write-Host ""
    Write-Host "Starting box ($Box) relay via sbx exec..."
    sbx exec $Box bash scripts/cdp-bridge.sh up --port $Port --relay-port $RelayPort
    if ($LASTEXITCODE -eq 0) {
      # Register the MCP server in the box config for the NEXT box session (best-effort). MCP only
      # loads at session start, so the current box session drives via the relay directly.
      $mcpJson = '{"command":"npx","args":["chrome-devtools-mcp@latest","--browser-url","http://localhost:' + $RelayPort + '"]}'
      sbx exec $Box claude mcp add-json chrome-devtools-host $mcpJson 2>$null | Out-Null
      Write-Host ""
      Write-Host "bridge ready: host Chrome(:$Port) <- relay(box localhost:$RelayPort) <- box agent"
      Write-Host "  current box session: drive via relay (CDP at http://localhost:$RelayPort)"
      Write-Host "  next box session: chrome-devtools-host MCP available"
      Write-Host "Teardown on host: pwsh scripts/cdp-bridge.ps1 down"
    } else {
      Write-Warning "Failed to auto-start the box relay. Start it manually inside the box:"
      Write-Warning "  bash scripts/cdp-bridge.sh up --port $Port --relay-port $RelayPort"
    }
  } else {
    Write-Host ""
    Write-Host "Next, INSIDE the box:"
    Write-Host "  bash scripts/cdp-bridge.sh up --port $Port --relay-port $RelayPort   # socat relay localhost:$RelayPort -> host:$Port"
    Write-Host "Then point chrome-devtools MCP at --browser-url http://localhost:$RelayPort"
    Write-Host "(pass -Box <name> to have host up auto-start the box relay)"
    Write-Host "Teardown on host: pwsh scripts/cdp-bridge.ps1 down"
  }
}

# Call before box relay teardown. sbx exec cold-starts a stopped box (sbx/README.md), so only skip
# teardown when the box is clearly stopped/absent. When status is undeterminable (sbx fails / bad
# json), fall to the safe side (treat as "maybe running" -> do not skip). True = running/unknown.
function Box-RunningOrUnknown([string]$b) {
  # Keep the sbx call inside try: with $ErrorActionPreference=Stop an sbx error outside it could abort
  # Host-Down before local cleanup. Treat any failure as unknown (= running -> do not skip teardown).
  try {
    $json = sbx ls --json 2>$null
    if (-not $json) { return $true }
    $match = (($json | ConvertFrom-Json).sandboxes | Where-Object { $_.name -eq $b })
    if (-not $match) { return $false }
    # Skip only for a definitively "stopped" box; transient/unknown statuses count as maybe-running.
    return ([string]$match.status -ne "stopped")
  } catch { return $true }
}

function Host-Down {
  # Restore the up-chosen port when not explicit (state files are keyed by $Port).
  if (-not $PortExplicit -and (Test-Path (Last-PortFile)) -and ((Get-Item (Last-PortFile)).Length -gt 0)) {
    $script:Port = (Get-Content (Last-PortFile) -Raw).Trim()
  }
  Resolve-ProfileDir-Down
  # Tear down the box relay too: target box is -Box, else the up-time scope (Policy-ScopeFile).
  $boxTd = $Box
  if (-not $boxTd -and (Test-Path (Policy-ScopeFile)) -and ((Get-Item (Policy-ScopeFile)).Length -gt 0)) {
    $boxTd = (Get-Content (Policy-ScopeFile) -Raw).Trim()
  }
  if ($boxTd -and (Box-RunningOrUnknown $boxTd)) {
    # Pass the up-time relay port so a non-default relay is not missed as default 9333.
    $relayArg = @()
    if ((Test-Path (Last-RelayFile)) -and ((Get-Item (Last-RelayFile)).Length -gt 0)) {
      $relayArg = @("--relay-port", (Get-Content (Last-RelayFile) -Raw).Trim())
    }
    sbx exec $boxTd bash scripts/cdp-bridge.sh down @relayArg 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "box ($boxTd) relay stopped." }
    else { Write-Warning "Failed to auto-stop the box relay (run 'bash scripts/cdp-bridge.sh down' inside the box)." }
  }
  if (-not $script:ProfileDir) {
    Write-Host "no profile info (not running or already down?)."
  } else {
    # Gate the kill matcher behind the safety check: a box-tampered pathfile (e.g. "*" or "C:\")
    # must not let down kill unrelated Chrome / processes on the host. Explicit dir is the user's
    # own contract; implicit must pass Is-SafeThrowawayProfile to be eligible for stop/delete.
    $canTouch = $script:ProfileDirExplicit -or (Is-SafeThrowawayProfile $script:ProfileDir)
    if ($canTouch) {
      Stop-ChromeByProfile $script:ProfileDir
      Write-Host "host Chrome (profile=$script:ProfileDir) stopped."
      if (-not $script:ProfileDirExplicit) {
        Remove-Item -Recurse -Force -LiteralPath $script:ProfileDir -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Profile-PathFile) -ErrorAction SilentlyContinue
        Write-Host "throwaway profile dir removed."
      }
    } else {
      Write-Warning "pathfile points at $script:ProfileDir which is not in the expected throwaway form; skipping kill/delete. Possible tampering. Stop the target Chrome manually and remove $(Profile-PathFile)."
    }
  }
  $idf = Policy-IdFile; $scopef = Policy-ScopeFile
  if (Test-Path $idf) {
    $id = (Get-Content $idf -Raw).Trim()
    $scope = if ((Test-Path $scopef) -and ((Get-Item $scopef).Length -gt 0)) { (Get-Content $scopef -Raw).Trim() } else { "" }
    # sbx v0.33+ contract: `sbx policy rm network --id <id>` (+ --sandbox for scoped rules).
    if ($scope) {
      sbx policy rm network --sandbox $scope --id $id 2>$null
    } else {
      sbx policy rm network --id $id 2>$null
    }
    if ($LASTEXITCODE -eq 0) {
      $scopeMsg = if ($scope) { " on $scope" } else { "" }
      Write-Host "egress rule ($id$scopeMsg) removed."
      Remove-Item $idf -ErrorAction SilentlyContinue
      Remove-Item $scopef -ErrorAction SilentlyContinue
    } else {
      # Keep the idfile/scope on failure: the egress is still open, so a later `down` must be
      # able to retry (deleting them loses the only handle and leaks/accumulates stale rules).
      Write-Warning "Could not auto-remove egress rule; keeping idfile/scope. Re-run down, or remove manually: sbx policy ls (localhost:$Port)."
    }
  } else {
    Write-Warning "egress rule may remain. Check/remove: sbx policy ls (localhost:$Port)."
  }
  # Only clear the unkeyed pointers when the port just cleaned matches the recorded one and its rule
  # is revoked. A mismatched down (-Port 9222 while the live bridge is auto-port 9223) must not delete
  # another bridge's pointers; policy rm failure (idfile retained) also keeps them for retry.
  $savedPort = if ((Test-Path (Last-PortFile)) -and ((Get-Item (Last-PortFile)).Length -gt 0)) { (Get-Content (Last-PortFile) -Raw).Trim() } else { "" }
  if (($Port -eq $savedPort) -and (-not (Test-Path (Policy-IdFile)))) {
    Remove-Item (Last-PortFile) -ErrorAction SilentlyContinue
    Remove-Item (Last-RelayFile) -ErrorAction SilentlyContinue
  }
}

function Host-Status {
  if (-not $PortExplicit -and (Test-Path (Last-PortFile)) -and ((Get-Item (Last-PortFile)).Length -gt 0)) {
    $script:Port = (Get-Content (Last-PortFile) -Raw).Trim()
  }
  Resolve-ProfileDir-Down
  $ok = "no"
  try { Probe-Localhost "http://localhost:$Port/json/version" 3; $ok = "yes" } catch {}
  Write-Host "host Chrome CDP (localhost:$Port): $ok"
  if ($script:ProfileDir) { Write-Host "profile: $script:ProfileDir" } else { Write-Host "profile: (unresolved / not running)" }
}

# ---- box side (parity; boxes are Linux so this is rarely used from PS) -------

function Proxy-HostPort {
  $p = if ($env:http_proxy) { $env:http_proxy } elseif ($env:HTTP_PROXY) { $env:HTTP_PROXY } else { "" }
  $p = $p -replace '^https?://','' -replace '/$',''
  if ($p) { return $p } else { return "gateway.docker.internal:3128" }
}

# Boxes are Linux in this project; the canonical box-side path is cdp-bridge.sh. The previous
# PowerShell parity used Start-Process socat without setsid, so Box-Down could not kill the
# `TCP-LISTEN ...,fork` child sockets (an active CDP/WebSocket would survive `down`, leaving
# the host Chrome reachable from the box). Re-implementing the process-group dance in PS for
# a path nobody uses in practice is risk without benefit; route users to the bash script.
function Box-Up {
  Write-Error "Box-side PowerShell path is unsupported (would leak forked socat children that keep CDP open after down). Boxes are Linux; run: bash scripts/cdp-bridge.sh up"
}

function Box-Down {
  Write-Error "Box-side PowerShell path is unsupported. Boxes are Linux; run: bash scripts/cdp-bridge.sh down"
}

function Box-Status {
  Write-Error "Box-side PowerShell path is unsupported. Boxes are Linux; run: bash scripts/cdp-bridge.sh status"
}

function Usage {
  Write-Host "usage: pwsh scripts/cdp-bridge.ps1 <up|down|status> [options]"
  Write-Host "  host (no SANDBOX_VM_ID):"
  Write-Host "    up      launch throwaway Chrome + open egress. With -Box, sbx exec also starts the box relay."
  Write-Host "            Without -Port, auto-selects a free port if the default is occupied."
  Write-Host "    down    stop Chrome + remove rule (+ stop box relay when -Box/scope is known)"
  Write-Host "    status  check host Chrome CDP"
  Write-Host "  box  (SANDBOX_VM_ID set): UNSUPPORTED in PowerShell. Boxes are Linux; use bash scripts/cdp-bridge.sh"
  Write-Host "  options (env also ok): -Port N (=CDP_PORT,9222) / -RelayPort N (=CDP_RELAY_PORT,9333)"
  Write-Host "           -Box NAME (=CDP_BOX; host up auto-starts relay + scopes egress) / -ProfileDir DIR (=CDP_PROFILE_DIR)"
  Write-Host "           -NoConnect (host up: do not auto-start the box relay)"
  Write-Host "  SECURITY: never use the real Chrome profile; do not log into real accounts in the bridged Chrome."
  Write-Host "  details: docs/guide/headful-bridge.md"
}

switch ($Verb) {
  "up"     { if (In-Box) { Box-Up }     else { Host-Up } }
  "down"   { if (In-Box) { Box-Down }   else { Host-Down } }
  "status" { if (In-Box) { Box-Status } else { Host-Status } }
  default  { Usage }
}
