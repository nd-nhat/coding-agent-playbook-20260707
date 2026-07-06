# Host helper: copies a Claude Code session transcript out of an sbx box for HOTL monitoring on the host.

param(
    [Parameter(Mandatory=$true, Position=0)][string]$SessionId,
    [Parameter(Mandatory=$false, Position=1)][string]$BoxName
)

$ErrorActionPreference = "Stop"

# Reject anything but UUID hex / dash to keep $SessionId safe to embed in the in-box sh -c string.
if ($SessionId -notmatch '^[a-fA-F0-9-]{8,36}$') {
    [Console]::Error.WriteLine("invalid session_id (expected UUID or 8+ hex prefix): '$SessionId'")
    exit 1
}

# host-only guard: SANDBOX_VM_ID is set only inside a box (asymmetry) - fail fast with an explicit
# message so the in-box Claude does not detour into "install sbx" via the generic not-found path.
if (-not [string]::IsNullOrEmpty($env:SANDBOX_VM_ID)) {
    [Console]::Error.WriteLine("This skill is host-only but `$SANDBOX_VM_ID=$($env:SANDBOX_VM_ID) is set, indicating you are inside an sbx box.")
    [Console]::Error.WriteLine("- To inspect THIS session's transcript from inside the box, use the user-scope /session-context skill.")
    [Console]::Error.WriteLine("- To inspect ANOTHER box's transcript, exit this box and run from the host.")
    exit 5
}

if (-not (Get-Command sbx -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine("sbx command not found. Install Docker Sandboxes first.")
    exit 2
}

# When $BoxName is omitted, auto-detect a single running claude box; reject 0 / multiple to avoid mispick.
if ([string]::IsNullOrEmpty($BoxName)) {
    $LsLines = & sbx ls 2>$null
    if ($null -eq $LsLines) { $LsLines = @() } else { $LsLines = @($LsLines) }
    $Candidates = @()
    # Skip header line (first line "SANDBOX AGENT STATUS ..."); split each subsequent line on whitespace.
    for ($i = 1; $i -lt $LsLines.Count; $i++) {
        $fields = $LsLines[$i] -split '\s+' | Where-Object { $_ -ne '' }
        if ($fields.Count -ge 3 -and $fields[1] -eq 'claude' -and $fields[2] -eq 'running') {
            $Candidates += $fields[0]
        }
    }
    if ($Candidates.Count -eq 0) {
        [Console]::Error.WriteLine("no running claude box found. Specify <box_name> explicitly (check 'sbx ls')")
        exit 1
    } elseif ($Candidates.Count -gt 1) {
        [Console]::Error.WriteLine("multiple running claude boxes ($($Candidates -join ', ')). Specify <box_name> explicitly")
        exit 1
    } else {
        $BoxName = $Candidates[0]
        [Console]::Error.WriteLine("auto-detected box='$BoxName' (running claude agent box is exactly one)")
    }
}

# Reject anything but the upstream sbx name grammar (letters/numbers/dot/plus/dash/underscore).
if ($BoxName -notmatch '^[a-zA-Z0-9._+-]+$') {
    [Console]::Error.WriteLine("invalid box_name (expected sbx name grammar: letters/numbers/dot/plus/dash/underscore): '$BoxName'")
    exit 1
}

$Short = $SessionId.Substring(0, [Math]::Min(8, $SessionId.Length))

# Defense in depth: pass the validated $SessionId as a positional arg to avoid splicing it into the sh -c string.
# `sh -c` (not `bash -lc`) skips login profile sourcing so the in-box startup is lighter.
$LsScript = 'ls /home/agent/.claude/projects/*/"$1"*.jsonl 2>/dev/null || true'
$Raw = & sbx exec $BoxName sh -c $LsScript '_' $SessionId 2>$null
# PowerShell 5.1: $ErrorActionPreference=Stop does not fail the script on native command non-zero exit. Check sbx exec separately so a stopped/missing box surfaces as exit 6 instead of being misreported as "transcript not found".
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine("sbx exec failed (exit=$LASTEXITCODE) for box='$BoxName'. Box may be stopped or missing.")
    exit 6
}
if ($null -eq $Raw) { $Raw = "" }

$Paths = @($Raw -split "`n" | Where-Object { $_ -ne "" })

if ($Paths.Count -eq 0) {
    [Console]::Error.WriteLine("transcript not found for session_id='$SessionId' in box='$BoxName'")
    [Console]::Error.WriteLine("Try: sbx exec $BoxName ls /home/agent/.claude/projects/")
    exit 3
}

if ($Paths.Count -gt 1) {
    [Console]::Error.WriteLine("multiple transcripts match session_id='$SessionId' in box='$BoxName':")
    foreach ($P in $Paths) { [Console]::Error.WriteLine("  $P") }
    [Console]::Error.WriteLine("Pass the full UUID instead.")
    exit 4
}

$SrcPath = $Paths[0]

$DestDir = ".claude/tmp"
if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
}

$DestPath = "$DestDir/box-session-$Short.jsonl"

# sbx 0.33.0 data plane buffer (~4MB) makes `sbx cp` / `sbx exec ... cat > host_file` hang, so prefer the
# bind-mount bypass: in a dev box (scripts/dev.sh, --kit ... .) the project root is mounted at the same
# absolute host path, so an in-box cp into ${PWD}/${DestPath} appears on host without the sbx data plane.
# In a clone box (dev.sh sandbox, --clone .) the host checkout is not mounted, and on Windows the host
# path is C:\... which the Linux box's cp cannot resolve; both cases are detected by probing `test -d -a -w`
# in the box and we fall back to `sbx cp` (subject to the original ~4MB hang only when triggered).
# Start-Process + WaitForExit caps the bypass-path hang because PowerShell 5.1 lacks a portable timeout.
$AbsDest = Join-Path (Get-Location).Path $DestPath
$AbsDestDir = Split-Path -Parent $AbsDest

& sbx exec $BoxName sh -c 'test -d "$1" -a -w "$1"' '_' $AbsDestDir 2>$null | Out-Null
$IsMounted = ($LASTEXITCODE -eq 0)

if ($IsMounted) {
    $ProcArgs = @('exec', $BoxName, 'cp', $SrcPath, $AbsDest)
    $Proc = Start-Process -FilePath sbx -ArgumentList $ProcArgs -NoNewWindow -PassThru
    if (-not $Proc.WaitForExit(60000)) {
        # Surface Kill() failures instead of swallowing them: a thrown exception here means the hung sbx
        # process may keep running after the script exits, and a silent catch would hide that diagnostic.
        try { $Proc.Kill() } catch {
            [Console]::Error.WriteLine("failed to kill timed-out sbx exec cp process: $($_.Exception.Message)")
        }
        [Console]::Error.WriteLine("sbx exec cp timed out (>60s) for ${BoxName}:${SrcPath} -> $AbsDest")
        exit 6
    }
    if ($Proc.ExitCode -ne 0) {
        [Console]::Error.WriteLine("sbx exec cp failed (exit=$($Proc.ExitCode)) for ${BoxName}:${SrcPath} -> $AbsDest")
        exit 6
    }
} else {
    [Console]::Error.WriteLine("box='$BoxName' does not bind-mount '$AbsDestDir' (clone box / Windows host). falling back to sbx cp (files >4MB may hang).")
    & sbx cp "${BoxName}:${SrcPath}" $DestPath
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("sbx cp failed (exit=$LASTEXITCODE) for ${BoxName}:${SrcPath} -> $DestPath")
        exit 6
    }
}

Write-Output $DestPath
