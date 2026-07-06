# Host helper: auto-locates a Claude Code session transcript (in a box or on the host) and injects it into
# the dest's ~/.claude/projects/<encoded>/ under the original UUID name so `claude --resume` re-opens the
# same session. Covers box->host / box->another box / host->box from one entry point. The .sh sibling is the
# reference impl; this mirrors its logic for Windows PowerShell 5.1.
#
# Windows note: on a Windows host the box mounts the repo at a Linux path, not C:\..., so the bind-mount
# bypass never matches and box transfers always use `sbx cp`. The <encoded> dir is derived from the source
# box's Linux path; when dest=host on Windows that name may differ from the host's own encoding (the host
# repo path is C:\...), so box->box is the reliable Windows path and a warning is emitted for box->host.

param(
    [Parameter(Mandatory=$true, Position=0)][string]$SessionId,
    [Parameter(Mandatory=$false, Position=1)][string]$Dest,
    [Parameter(Mandatory=$false, Position=2)][string]$SourceArg
)

$ErrorActionPreference = "Stop"

# Reject anything but UUID hex / dash to keep $SessionId safe to embed in the in-box sh -c string.
if ($SessionId -notmatch '^[a-fA-F0-9-]{8,36}$') {
    [Console]::Error.WriteLine("invalid session_id (expected UUID or 8+ hex prefix): '$SessionId'")
    exit 1
}

# host-only guard: SANDBOX_VM_ID is set only inside a box. A box cannot sbx-reach sibling boxes, so the raw
# script does not work in a box. From a box, the /box-session-resume skill delegates to the host; point users
# at the skill rather than at running the script directly (the ! prefix runs in the box shell and fails too).
if (-not [string]::IsNullOrEmpty($env:SANDBOX_VM_ID)) {
    [Console]::Error.WriteLine("This script is host-only but `$SANDBOX_VM_ID=$($env:SANDBOX_VM_ID) is set (you are inside an sbx box).")
    [Console]::Error.WriteLine("Do not run this script directly here. Instead:")
    [Console]::Error.WriteLine("- Use the /box-session-resume skill from this box: it delegates to the host via the host-bridge")
    [Console]::Error.WriteLine("  (the user grants it on the host with /box-session-resume-grant). Don't use the ! prefix.")
    [Console]::Error.WriteLine("- Or run from a host shell where `$SANDBOX_VM_ID is empty.")
    exit 5
}

if (-not (Get-Command sbx -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("sbx command not found. Install Docker Sandboxes first.")
    exit 2
}

# Reject anything but the upstream sbx name grammar (letters/numbers/dot/plus/dash/underscore). A leading
# dash is rejected too: quoting does not stop CLI option injection (e.g. -it / --help parsed as sbx flags).
function Test-BoxName {
    param([string]$Name)
    # "host" collides with the local-machine sentinel; reserve it (case-insensitive) so a box named host
    # is not mistaken for the host target.
    if ($Name -ieq 'host') {
        [Console]::Error.WriteLine("'host' is reserved as the local-machine sentinel; omit <dest> to target the host.")
        exit 1
    }
    if ($Name -notmatch '^[a-zA-Z0-9._+][a-zA-Z0-9._+-]*$') {
        [Console]::Error.WriteLine("invalid box name (expected sbx grammar: letters/numbers/dot/plus/dash/underscore): '$Name'")
        exit 1
    }
}

# "host" (lowercase) is the host sentinel, not a box name, so it skips box-name validation (dest omitted =
# host; source = host means "the session is on the host"). Case variants like 'Host' are rejected as reserved.
if (-not [string]::IsNullOrEmpty($Dest) -and $Dest -cne 'host') { Test-BoxName $Dest }
if (-not [string]::IsNullOrEmpty($SourceArg) -and $SourceArg -cne 'host') { Test-BoxName $SourceArg }

# Find the transcript in one location ("host" or a box name). Returns a single path or "", exits 4 on multiple.
function Find-InLocation {
    param([string]$Loc)
    # -ceq: box names are case-sensitive (sbx grammar), and a box literally named "Host" must not collide
    # with the "host" sentinel; PowerShell -eq is case-insensitive by default.
    if ($Loc -ceq 'host') {
        $Glob = Join-Path $env:USERPROFILE ".claude\projects\*\$SessionId*.jsonl"
        $Found = @(Get-ChildItem -Path $Glob -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    } else {
        # Defense in depth: pass $SessionId as a positional arg to avoid splicing it into the sh -c string.
        $LsScript = 'ls /home/agent/.claude/projects/*/"$1"*.jsonl 2>/dev/null || true'
        $Raw = & sbx exec $Loc sh -c $LsScript '_' $SessionId 2>$null
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("sbx exec failed (exit=$LASTEXITCODE) for box='$Loc'. Box may be stopped or missing.")
            exit 6
        }
        if ($null -eq $Raw) { $Raw = "" }
        $Found = @($Raw -split "`n" | Where-Object { $_ -ne "" })
    }
    if ($Found.Count -gt 1) {
        [Console]::Error.WriteLine("multiple transcripts match session_id='$SessionId' in '$Loc':")
        foreach ($f in $Found) { [Console]::Error.WriteLine("  $f") }
        [Console]::Error.WriteLine("Pass the full UUID instead.")
        exit 4
    }
    if ($Found.Count -eq 1) { return $Found[0] }
    return ""
}

# Resolve source location. Explicit -> only there; otherwise scan host + running claude boxes and require
# exactly one location to hold the transcript (multiple -> ask for explicit source).
$SrcLoc = ""
$SrcPath = ""
if (-not [string]::IsNullOrEmpty($SourceArg)) {
    $SrcLoc = $SourceArg
    $SrcPath = Find-InLocation $SrcLoc
    if ([string]::IsNullOrEmpty($SrcPath)) {
        [Console]::Error.WriteLine("transcript not found for session_id='$SessionId' in source='$SrcLoc'")
        exit 3
    }
} else {
    $Locations = @('host')
    $LsLines = & sbx ls 2>$null
    # fail-closed: treating an sbx ls failure as "no boxes" would silently scan host only and miss a box transcript
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("sbx ls failed (exit=$LASTEXITCODE); cannot enumerate running boxes for source auto-detect. Pass <source> explicitly.")
        exit 6
    }
    if ($null -eq $LsLines) { $LsLines = @() } else { $LsLines = @($LsLines) }
    for ($i = 1; $i -lt $LsLines.Count; $i++) {
        $fields = $LsLines[$i] -split '\s+' | Where-Object { $_ -ne '' }
        if ($fields.Count -ge 3 -and $fields[1] -eq 'claude' -and $fields[2] -eq 'running') {
            $Locations += $fields[0]
        }
    }

    $Hits = @()
    foreach ($Loc in $Locations) {
        $p = Find-InLocation $Loc
        if (-not [string]::IsNullOrEmpty($p)) {
            $Hits += $Loc
            $SrcLoc = $Loc
            $SrcPath = $p
        }
    }

    if ($Hits.Count -eq 0) {
        [Console]::Error.WriteLine("transcript not found for session_id='$SessionId' in host or any running claude box")
        [Console]::Error.WriteLine("Check: sbx ls / dir `$env:USERPROFILE\.claude\projects")
        exit 3
    }
    if ($Hits.Count -gt 1) {
        [Console]::Error.WriteLine("session_id='$SessionId' exists in multiple locations: $($Hits -join ', ')")
        [Console]::Error.WriteLine("Pass <source> explicitly to disambiguate.")
        exit 4
    }
}

# Normalize dest (empty = host)
$DestLoc = if ([string]::IsNullOrEmpty($Dest)) { 'host' } else { $Dest }

# Derive full UUID and encoded project dir name from the matched path. Both boxes and the host bind-mount the
# repo at the same absolute path on macOS/Linux, so the source's encoded dir name is reusable at the dest
# (no re-implementing the encoding). Split on / and \ so box (Linux) and host (Windows) paths both parse.
$Parts = $SrcPath -split '[/\\]'
$UuidFile = $Parts[-1]
$Encoded = $Parts[-2]
$Uuid = $UuidFile -replace '\.jsonl$', ''

# source==dest: transcript already in place, just print the resume command.
# -ceq: box names are case-sensitive, so 'Box' and 'box' are different locations and must not skip the copy.
if ($SrcLoc -ceq $DestLoc) {
    [Console]::Error.WriteLine("transcript already present in '$DestLoc' (source==dest); no copy needed")
    if ($DestLoc -ceq 'host') { Write-Output "claude --resume $Uuid" }
    else { Write-Output "In box ${DestLoc}: claude --resume $Uuid" }
    exit 0
}

# Shared staging under the main checkout root's .claude/tmp (the path all dev boxes bind-mount) to relay
# box<->box / box<->host while avoiding the sbx ~4MB data-plane hang. clone box / Windows host do not
# bind-mount, detected by probe, and fall back to sbx cp. Resolve from the git common dir parent (not the
# cwd) so a worktree / subdir / absolute-path invocation does not drop to the sbx cp fallback.
$GitCommonDir = (& git rev-parse --path-format=absolute --git-common-dir 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($GitCommonDir)) {
    [Console]::Error.WriteLine("git rev-parse failed; run from inside the repository.")
    exit 1
}
$MountRoot = Split-Path -Parent ($GitCommonDir.Trim())
$StageDir = Join-Path $MountRoot ".claude\tmp"
if (-not (Test-Path -LiteralPath $StageDir)) { New-Item -ItemType Directory -Path $StageDir -Force | Out-Null }
$StageAbs = Join-Path $StageDir "resume-$Uuid.jsonl"
$StageAbsDir = $StageDir

# Run sbx and surface a non-zero exit as 6 (PowerShell 5.1 does not fail the script on native non-zero exit).
function Invoke-Sbx {
    param([string[]]$SbxArgs, [string]$What)
    & sbx @SbxArgs
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("sbx $What failed (exit=$LASTEXITCODE)")
        exit 6
    }
}

# Does the box bind-mount the staging dir at the same absolute path? (false on clone box / Windows host)
function Test-BoxMount {
    param([string]$Box)
    & sbx exec $Box sh -c 'test -d "$1" -a -w "$1"' '_' $StageAbsDir 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

try {
    # --- source -> staging ---
    if ($SrcLoc -ceq 'host') {
        Copy-Item -LiteralPath $SrcPath -Destination $StageAbs -Force
    } elseif (Test-BoxMount $SrcLoc) {
        Invoke-Sbx @('exec', $SrcLoc, 'cp', $SrcPath, $StageAbs) "exec cp (source->staging)"
    } else {
        [Console]::Error.WriteLine("source box '$SrcLoc' does not bind-mount '$StageAbsDir' (clone box / Windows host). falling back to sbx cp (>4MB may hang).")
        Invoke-Sbx @('cp', "${SrcLoc}:${SrcPath}", $StageAbs) "cp (source->staging)"
    }

    # --- staging -> dest projects dir as <uuid>.jsonl ---
    if ($DestLoc -ceq 'host') {
        if ($SrcLoc -cne 'host') {
            # On Windows the host's own encoding (C:\ path) may not match the box-derived $Encoded.
            [Console]::Error.WriteLine("note: writing to host projects dir '$Encoded' derived from the source box; if 'claude --resume' cannot find it on a Windows host, check `$env:USERPROFILE\.claude\projects for the host's own dir name.")
        }
        $DestDir = Join-Path $env:USERPROFILE ".claude\projects\$Encoded"
        if (-not (Test-Path -LiteralPath $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
        Copy-Item -LiteralPath $StageAbs -Destination (Join-Path $DestDir $UuidFile) -Force
    } else {
        $DestBoxDir = "/home/agent/.claude/projects/$Encoded"
        if ($SrcLoc -ceq 'host') {
            # Symmetric to the box->host note: on Windows the host's C:\ encoding will not match the box's
            # Linux-cwd encoding, so the injected dir may not be where dest's `claude --resume` looks.
            [Console]::Error.WriteLine("note: dest box projects dir '$Encoded' is derived from the host path; on a Windows host it may not match the box's own encoding, so 'claude --resume' may miss it. box->box is the reliable Windows path.")
        }
        if (Test-BoxMount $DestLoc) {
            Invoke-Sbx @('exec', $DestLoc, 'sh', '-c', 'mkdir -p "$1" && cp "$2" "$1/$3"', '_', $DestBoxDir, $StageAbs, $UuidFile) "exec cp (staging->dest)"
        } else {
            [Console]::Error.WriteLine("dest box '$DestLoc' does not bind-mount '$StageAbsDir' (clone box / Windows host). falling back to sbx cp (>4MB may hang).")
            Invoke-Sbx @('exec', $DestLoc, 'mkdir', '-p', $DestBoxDir) "exec mkdir (dest)"
            Invoke-Sbx @('cp', $StageAbs, "${DestLoc}:${DestBoxDir}/${UuidFile}") "cp (staging->dest)"
        }
    }
} finally {
    Remove-Item -LiteralPath $StageAbs -ErrorAction SilentlyContinue
}

if ($DestLoc -ceq 'host') { Write-Output "claude --resume $Uuid" }
else { Write-Output "In box ${DestLoc}: claude --resume $Uuid" }
