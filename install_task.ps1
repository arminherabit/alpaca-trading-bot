# install_task.ps1
# Registers the scheduled task that keeps the Public Desktop copy of the
# dashboard fresh. Run this ON Mike-hp, once.
#
# Why it runs here rather than on the dev PC: Mike-hp writes to its OWN local
# C:\Users\Public\Desktop, so the task needs no network credential and the
# refresh does not depend on any other machine being awake.
#
# The task runs as the invoking user, interactive-only -- so it needs no stored
# password. It therefore refreshes while someone is logged on, which is the only
# time a file on the Desktop is being looked at anyway.
#
# Usage (on Mike-hp):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\Public\AlpacaDashboard\install_task.ps1"

[CmdletBinding()]
param(
    [string]$TaskName    = 'AK Swing Trader Dashboard',
    [string]$ScriptPath  = 'C:\Users\Public\AlpacaDashboard\publish_to_share.ps1',
    [string]$Destination = 'C:\Users\Public\Desktop',
    [int]   $Minutes     = 10
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "Publisher not found: $ScriptPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path -LiteralPath $Destination)) {
    Write-Host "Destination not found: $Destination" -ForegroundColor Red
    exit 1
}

$argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Destination "{1}"' -f $ScriptPath, $Destination

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine

# -Once + RepetitionInterval with an indefinite duration is the combination that
# survives reboots and keeps repeating; a bare MINUTE trigger expires after a day
# on some Windows builds.
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
             -RepetitionInterval (New-TimeSpan -Minutes $Minutes) `
             -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
              -MultipleInstances IgnoreNew

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Force `
        -Description 'Refreshes the AK Stocks Swing Trader dashboard on the Public Desktop from GitHub.' | Out-Null
} catch {
    Write-Host "Could not register the task: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "Task registered: $TaskName (every $Minutes minutes)" -ForegroundColor Green

# Publish once now so the Desktop is current immediately rather than in 10 minutes.
Write-Host "Running it once now..." -ForegroundColor Cyan
& $ScriptPath -Destination $Destination

$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $t) {
    Write-Host ("State: {0}" -f $t.State) -ForegroundColor Green
    Write-Host "To remove it later:  Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false" -ForegroundColor DarkGray
}
