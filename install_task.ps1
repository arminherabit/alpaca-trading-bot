# install_task.ps1
# Registers the scheduled task that keeps the Public Desktop copy of the
# dashboard fresh. Run this ON Mike-hp, once.
#
# Why it runs here rather than on the dev PC: Mike-hp writes to its OWN local
# C:\Users\Public\Desktop, so the task needs no network credential and the
# refresh does not depend on any other machine being awake.
#
# POWERSHELL 2.0 COMPATIBLE. Mike-hp is a Windows 7-era box running PowerShell
# 2.0, where the entire ScheduledTasks module (New-ScheduledTaskAction,
# Register-ScheduledTask, Get-ScheduledTask) does not exist -- it arrived in
# PowerShell 3.0. This uses schtasks.exe, which ships with Windows itself.
#
# The task command lives in a small .cmd wrapper rather than being passed inline
# to schtasks: /TR values need nested quoting that is painful to get right and
# silently truncates at the first space when wrong.
#
# Usage (on Mike-hp):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Public\AlpacaDashboard\install_task.ps1"

param(
    [string]$TaskName    = 'AK Swing Trader Dashboard',
    [string]$ScriptPath  = 'C:\Users\Public\AlpacaDashboard\publish_to_share.ps1',
    [string]$Destination = 'C:\Users\Public\Desktop',
    [int]   $Minutes     = 10
)

$ErrorActionPreference = 'Stop'

Write-Host ("PowerShell {0} on {1}" -f $PSVersionTable.PSVersion, (Get-WmiObject Win32_OperatingSystem).Caption) -ForegroundColor DarkGray

if (-not (Test-Path $ScriptPath))  { Write-Host "Publisher not found: $ScriptPath" -ForegroundColor Red; exit 1 }
if (-not (Test-Path $Destination)) { Write-Host "Destination not found: $Destination" -ForegroundColor Red; exit 1 }

# ── Wrapper ───────────────────────────────────────────────────────────────────
$dir = Split-Path $ScriptPath -Parent
$cmd = Join-Path $dir 'refresh.cmd'

# COMPLUS_version is the whole trick on this machine.
#
# Mike-hp has .NET 4.7 installed, so the framework CAN negotiate TLS 1.2 -- but
# PowerShell 2.0 hosts on the CLR 2.0 runtime, whose SecurityProtocolType enum
# only defines Ssl3 and Tls (1.0). GitHub dropped TLS 1.0 in 2018, so every
# fetch died with "The underlying connection was closed."
#
# Setting COMPLUS_version for the child process makes that same powershell.exe
# load the v4.0.30319 runtime instead, where Tls12 exists. It is per-process and
# leaves nothing behind: no registry edit, no system-wide powershell.exe.config,
# no security setting changed. Unset it and the machine behaves exactly as before.
$body = "@echo off`r`n" +
        "REM Host PowerShell 2.0 on the .NET 4 runtime so TLS 1.2 is available.`r`n" +
        "REM Without this, GitHub refuses the connection (CLR 2.0 tops out at TLS 1.0).`r`n" +
        "set COMPLUS_version=v4.0.30319`r`n" +
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
        $ScriptPath + '" -Destination "' + $Destination + '"' + "`r`n"
[System.IO.File]::WriteAllText($cmd, $body, (New-Object System.Text.ASCIIEncoding))
Write-Host "Wrapper written: $cmd" -ForegroundColor Green

# ── Register ──────────────────────────────────────────────────────────────────
# /SC MINUTE /MO n is a true recurring trigger and does not expire. (The 24-hour
# expiry trap belongs to /RI, the repetition modifier, which is not used here.)
# No /RU or /RP: the task runs as the invoking user, so Windows never asks to
# store a password.
Write-Host "Registering scheduled task..." -ForegroundColor Cyan
$out = & schtasks.exe /Create /TN $TaskName /TR $cmd /SC MINUTE /MO $Minutes /F 2>&1
$rc  = $LASTEXITCODE
$out | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
if ($rc -ne 0) {
    Write-Host "schtasks failed (exit $rc). The task was NOT created." -ForegroundColor Red
    exit 1
}
Write-Host "Task registered: $TaskName (every $Minutes minutes)" -ForegroundColor Green

# ── Publish once now ──────────────────────────────────────────────────────────
# Invoked through refresh.cmd, not directly, so this first run exercises exactly
# what the scheduled task will run -- COMPLUS_version included. Running the .ps1
# straight from here would test a different code path and could pass while the
# task fails.
Write-Host "Running it once now (via refresh.cmd, same as the task will)..." -ForegroundColor Cyan
& cmd.exe /c "`"$cmd`""
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "The task is registered, but this first run failed -- see the error above." -ForegroundColor Yellow
    Write-Host "If it is still a TLS error, the .NET 4 runtime did not take effect." -ForegroundColor Yellow
    exit 1
}

Write-Host ""
& schtasks.exe /Query /TN $TaskName /FO LIST 2>&1 | Select-String 'TaskName|Status|Next Run' |
    ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
Write-Host "To remove it later:  schtasks /Delete /TN `"$TaskName`" /F" -ForegroundColor DarkGray
