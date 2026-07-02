# host-bridge transport primitives (PowerShell pair of host-bridge.sh). ASCII only for Windows PowerShell 5.1.
# box<->host file-based async RPC (.claude/host-bridge/) race-prone plumbing centralized here:
# req/ans/sentinel numbering, ordering, and the poll string. Skills call this and keep naming / Monitor /
# validation on their side (transport primitives only; see host-bridge.sh header for the full rationale).
#
# sentinel contract: ans body = <ans-path>, done sentinel = <ans-path>.done. finalize touches the sentinel
# only after the ans body is fully written, so "sentinel present => body complete" holds (race-free).
#
# subcommands:
#   next-seq <bridge-dir> <req-prefix>   max seq +1 as 3-digit zero-padded (001 if none)
#   prep-req <bridge-dir> <ans-path>     mkdir bridge-dir + remove stale ans/done for this seq (box, pre req write)
#   prep-ans <ans-path>                  mkdir ans dir + remove stale done (host, pre ans body write)
#   finalize <ans-path>                  touch <ans-path>.done (host, after ans body write)
#   poll     <ans-path>                  emit the "until done; sleep; cat ans" string for Monitor

param(
    [Parameter(Mandatory=$true, Position=0)][string]$Sub,
    [Parameter(Mandatory=$false, Position=1)][string]$Arg1,
    [Parameter(Mandatory=$false, Position=2)][string]$Arg2
)

$ErrorActionPreference = "Stop"

function Reject-BadPath([string]$p) {
    if ($p -match "`n") {
        [Console]::Error.WriteLine("host-bridge: newline in path argument is not allowed")
        exit 2
    }
}

function Usage-Exit {
    [Console]::Error.WriteLine("usage: host-bridge.ps1 <next-seq|prep-req|prep-ans|finalize|poll> ...")
    exit 2
}

switch ($Sub) {
    "next-seq" {
        if ([string]::IsNullOrEmpty($Arg1) -or [string]::IsNullOrEmpty($Arg2)) { Usage-Exit }
        $dir = $Arg1; $prefix = $Arg2
        Reject-BadPath $dir; Reject-BadPath $prefix
        $max = 0
        if (Test-Path $dir) {
            # anchored 3-digit match avoids prefix collision (topic "port" glob must not pick up "port-80").
            $rx = "^" + [regex]::Escape($prefix) + "-([0-9][0-9][0-9])\.md$"
            Get-ChildItem -Path $dir -Filter "$prefix-*.md" -ErrorAction SilentlyContinue | ForEach-Object {
                $m = [regex]::Match($_.Name, $rx)
                if ($m.Success) {
                    # base-10 parse so 008/009 are not read as octal
                    $n = [int]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
                    if ($n -gt $max) { $max = $n }
                }
            }
        }
        $next = $max + 1
        # >999 becomes 4 digits, no longer matching the anchored [0-9][0-9][0-9] glob, so every later call
        # keeps reissuing the same seq (regression). Sequential low-volume use never reaches this; fail loud.
        if ($next -gt 999) {
            [Console]::Error.WriteLine("host-bridge next-seq: seq exhausted (>999) for prefix '$prefix'; clean up old bridge files")
            exit 4
        }
        [Console]::Out.Write(("{0:D3}" -f $next))
    }
    "prep-req" {
        if ([string]::IsNullOrEmpty($Arg1) -or [string]::IsNullOrEmpty($Arg2)) { Usage-Exit }
        $dir = $Arg1; $ans = $Arg2
        Reject-BadPath $dir; Reject-BadPath $ans
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # remove stale ans/done for this seq so poll does not cat an old body (-Force: absent = no-op, idempotent)
        Remove-Item -Force -ErrorAction SilentlyContinue $ans, "$ans.done"
    }
    "prep-ans" {
        if ([string]::IsNullOrEmpty($Arg1)) { Usage-Exit }
        $ans = $Arg1
        Reject-BadPath $ans
        $ansDir = Split-Path -Parent $ans
        if ($ansDir -and -not (Test-Path $ansDir)) { New-Item -ItemType Directory -Path $ansDir -Force | Out-Null }
        # Remove the ans body too (not just the sentinel): if the untrusted box pre-planted a symlink at the ans
        # path, the later Write would follow it and overwrite a host file. Remove-Item unlinks the link itself.
        Remove-Item -Force -ErrorAction SilentlyContinue $ans, "$ans.done"
    }
    "finalize" {
        if ([string]::IsNullOrEmpty($Arg1)) { Usage-Exit }
        $ans = $Arg1
        Reject-BadPath $ans
        if (-not (Test-Path $ans)) {
            [Console]::Error.WriteLine("host-bridge finalize: ans body '$ans' does not exist; write it before finalizing")
            exit 3
        }
        # Unlink any pre-planted symlink at the sentinel path before creating it (avoid touching a host file).
        Remove-Item -Force -ErrorAction SilentlyContinue "$ans.done"
        New-Item -ItemType File -Path "$ans.done" -Force | Out-Null
    }
    "poll" {
        if ([string]::IsNullOrEmpty($Arg1)) { Usage-Exit }
        $ans = $Arg1
        Reject-BadPath $ans
        # Monitor waits on this. Emitted for a POSIX shell (the box), since the poll runs inside the box.
        # Embed the path as a single-quoted POSIX literal so any "/`/$()/space in a checkout path neither
        # breaks the generated command nor expands when the box shell runs it. A literal ' becomes '\''.
        $qAns = $ans -replace "'", "'\''"
        [Console]::Out.Write("until [ -f '$qAns.done' ]; do sleep 30; done; cat '$qAns'")
    }
    default {
        [Console]::Error.WriteLine("host-bridge: unknown subcommand '$Sub'")
        Usage-Exit
    }
}
