# chrome-profile (PowerShell pair of chrome-profile.sh).
# Start/stop the headful Chrome (persistent, login-keeping dedicated profile) that the
# chrome-profile MCP in the committed .mcp.json connects to on the HOST session. Used to
# let the agent fetch/drive pages WebFetch/curl cannot reach (login-required, bot-gated).
#
# Host-session only. The profile PERSISTS across down -- staying logged in is the point.
# To drive a visible host Chrome from a box, use cdp-bridge.ps1 (docs/guide/headful-bridge.md).
#
# == SECURITY (read this) ==
# CDP = full control of that browser (arbitrary JS / read cookies+sessions / navigate).
# Only log into TEST accounts in this profile. Never real accounts or sensitive sites
# (banking / personal mail). See docs/guide/chrome-profile.md.
param(
  [Parameter(Position=0)][string]$Verb = "help",
  [string]$Port
)
$ErrorActionPreference = "Stop"

# Fall back to env/default only when -Port was truly omitted: an explicit empty string
# must reach the validation below (not silently become the default).
if (-not $PSBoundParameters.ContainsKey('Port')) {
  $Port = if ($env:CHROME_PROFILE_PORT) { $env:CHROME_PROFILE_PORT } else { "9335" }
}
# An empty / non-numeric / out-of-range port would flow into URLs, TCP probes and
# --remote-debugging-port as a broken value (and Port-Free would treat the cast error as
# "free"), so reject it up front. The length check runs before the [int] casts so an
# int-overflowing digit string fails cleanly instead of throwing.
if ($Port -notmatch '^[0-9]+$' -or $Port.Length -gt 5 -or [int]$Port -lt 1 -or [int]$Port -gt 65535) {
  [Console]::Error.WriteLine("error: -Port must be a number in 1-65535 (got: '$Port')")
  exit 1
}

function In-Box { return [bool]$env:SANDBOX_VM_ID }

# Profile is keyed by port (-Port runs a second parallel profile). Lives under the
# host-only cache (not bind-mounted into boxes) and is never auto-deleted: keeping the
# login state across up/down cycles is the purpose.
function Profile-Dir {
  $base = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME }
    elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA }
    else { Join-Path $HOME ".cache" }
  return (Join-Path $base "coding-agent-playbook/chrome-profile-$Port")
}

# PowerShell 6+ has -NoProxy; Windows PS 5.1 does not. Without it, HTTP_PROXY/system proxy
# can route localhost CDP probes away from the local Chrome and break detection.
$script:IwrNoProxySupported = (Get-Command Invoke-WebRequest).Parameters.ContainsKey('NoProxy')

# HTTP success alone would misidentify a 404 or any non-CDP service answering 2xx on
# /json/version, so also require the CDP-specific webSocketDebuggerUrl field in the body.
function Port-SpeaksCdp {
  try {
    $params = @{ Uri = "http://localhost:$Port/json/version"; UseBasicParsing = $true; TimeoutSec = 1 }
    if ($script:IwrNoProxySupported) { $params.NoProxy = $true }
    $resp = Invoke-WebRequest @params
    return ($resp.Content -match 'webSocketDebuggerUrl')
  } catch { return $false }
}

# True when 127.0.0.1:$Port has no listener (connection refused). Checks TCP occupancy
# regardless of CDP so a non-CDP service is not mistaken for "free".
function Port-Free {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $t = $c.ConnectAsync("127.0.0.1", [int]$Port)
    $occupied = ($t.Wait(300) -and $c.Connected)
    $c.Close()
    return (-not $occupied)
  } catch { return $true }
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
    if (Port-SpeaksCdp) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

# Kill only the Chrome we launched, matched by the profile dir in its command line.
# Windows uses Win32_Process (full CommandLine); macOS/Linux pwsh falls back to pkill -f
# because Get-Process.CommandLine is null there. $IsWindows is $null on Windows PS 5.1,
# so `-eq $false` correctly routes 5.1 to the CIM branch.
# pkill/pgrep -f interpret the pattern as an ERE, so regex metacharacters in the path
# must be literalized before matching.
function Escape-Ere([string]$s) { return ($s -replace '([][^$.*+?(){}|\\])', '\$1') }

# True when the CDP responder on $Port is a Chrome launched by this helper (its command
# line carries our profile dir; relies on the adjacency of our launch args). Guards
# against attaching the MCP to an unrelated (possibly real-profile) browser on the port.
function Port-OwnedByOurProfile([string]$dir) {
  if ($IsWindows -eq $false) {
    # Trailing ( |$) bounds the dir so a sibling profile (chrome-profile-933 vs -9335)
    # cannot prefix-match; the port token is bounded by the adjacent literal that follows.
    & pgrep -f -- ("--remote-debugging-port=$Port --user-data-dir=" + (Escape-Ere $dir) + '( |$)') *> $null
    return ($LASTEXITCODE -eq 0)
  }
  # Regex with explicit token boundaries: a -like "*...$Port*" prefix match would accept
  # port 933 against 9335 and misjudge an unrelated CDP browser as ours.
  $portRe = '--remote-debugging-port=' + [regex]::Escape($Port) + '(\s|$)'
  $dirRe  = '--user-data-dir="?' + [regex]::Escape($dir) + '("|\s|$)'
  $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match $portRe -and $_.CommandLine -match $dirRe }
  return [bool]$procs
}

function Stop-ChromeByProfile([string]$dir) {
  if (-not $dir) { return }
  # Bound the dir token so a sibling profile (chrome-profile-933 vs -9335) cannot
  # prefix-match and get its Chrome killed.
  if ($IsWindows -eq $false) {
    & pkill -f -- ("--user-data-dir=" + (Escape-Ere $dir) + '( |$)') 2>$null
  } else {
    $dirRe = '--user-data-dir="?' + [regex]::Escape($dir) + '("|\s|$)'
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match $dirRe } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  }
}

function Do-Up {
  $dir = Profile-Dir
  if (Port-SpeaksCdp) {
    # Idempotent only when the responder is our own Chrome; anything else (possibly a
    # real-profile browser) must not become the MCP's target.
    if (Port-OwnedByOurProfile $dir) {
      Write-Host "localhost:$Port already serves CDP from this helper's Chrome (already up)."
      Write-Host "profile: $dir"
      return
    }
    [Console]::Error.WriteLine("error: another process (possibly a real-profile Chrome) is serving CDP on localhost:$Port. Refusing to attach the MCP to it. Close it or pass -Port <other>.")
    exit 1
  }
  if (-not (Port-Free)) { Write-Error "localhost:$Port is in use by a non-CDP process. Pass -Port <other>." }
  $chrome = Find-Chrome
  if (-not $chrome) { Write-Error "Chrome/Chromium not found." }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  # Quote --user-data-dir: Start-Process joins ArgumentList with spaces without auto-quoting,
  # so a path containing a space would be truncated and down's command-line match would miss it.
  $proc = Start-Process -FilePath $chrome -ArgumentList @(
    "--remote-debugging-port=$Port","--user-data-dir=`"$dir`"",
    "--no-first-run","--no-default-browser-check","about:blank"
  ) -PassThru
  if (-not (Wait-ChromeReady)) {
    # Do not leave the launched process behind (a persistent-profile Chrome would keep the
    # debug port open).
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Write-Error "Chrome did not respond on localhost:$Port (launched process was stopped)."
  }
  Write-Host "chrome-profile Chrome started (port=$Port, profile=$dir)."
  Write-Host "  - For login-required sites, a human logs in with a TEST account in this window (persisted in the profile)"
  Write-Host "  - claude drives it via the chrome-profile MCP (committed .mcp.json; MCP loads at session start)"
  Write-Host "Teardown: pwsh scripts/chrome-profile.ps1 down (the profile is kept)"
}

function Do-Down {
  $dir = Profile-Dir
  Stop-ChromeByProfile $dir
  Write-Host "chrome-profile Chrome (profile=$dir) stopped (profile kept; login state survives the next up)."
}

function Do-Status {
  $ok = if (Port-SpeaksCdp) { "yes" } else { "no" }
  Write-Host "chrome-profile Chrome CDP (localhost:$Port): $ok"
  Write-Host "profile: $(Profile-Dir)"
}

function Usage {
  Write-Host "usage: pwsh scripts/chrome-profile.ps1 <up|down|status> [-Port N]"
  Write-Host "  up      launch the headful Chrome with a persistent login profile + remote debugging"
  Write-Host "  down    stop that Chrome (the profile is NOT deleted; login state survives)"
  Write-Host "  status  check CDP responsiveness"
  Write-Host "  options: -Port N (=CHROME_PROFILE_PORT, 9335). Profiles are keyed by port."
  Write-Host "  SECURITY: test accounts only; never log into real accounts or sensitive sites."
  Write-Host "  Host-session only (to drive a host Chrome from a box, see docs/guide/headful-bridge.md)."
  Write-Host "  details: docs/guide/chrome-profile.md"
}

# Exit 5 keeps parity with chrome-profile.sh's in-box guard (Write-Error would exit 1).
if (In-Box) {
  [Console]::Error.WriteLine("This script is host-only (the chrome-profile MCP does not work inside a box). To drive a visible host Chrome from a box, use docs/guide/headful-bridge.md (cdp-bridge).")
  exit 5
}

switch ($Verb) {
  "up"     { Do-Up }
  "down"   { Do-Down }
  "status" { Do-Status }
  "help"   { Usage }
  default  { Usage; exit 1 }
}
