[CmdletBinding()]
param(
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

$toolsRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools"
$managerRoot = Join-Path $toolsRoot "StudioDisplayManager"
$startupRoot = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"

$legacyPidFiles = @(
    (Join-Path $toolsRoot "BrightnessKeyBridge\BrightnessKeyBridge.pid"),
    (Join-Path $toolsRoot "SystemBrightnessMirror\SystemBrightnessMirror.pid"),
    (Join-Path $toolsRoot "SystemBrightnessMirror\SystemBrightnessMirrorTray.pid"),
    (Join-Path $toolsRoot "SystemBrightnessMirror\StudioDisplayManager.pid")
)

$legacyProcessNames = @(
    "studio-brightness"
)

$legacyDirectories = @(
    (Join-Path $toolsRoot "BrightnessKeyBridge"),
    (Join-Path $toolsRoot "SystemBrightnessMirror"),
    (Join-Path $toolsRoot "studio-brightness"),
    (Join-Path $toolsRoot "DisabledStartupShortcuts")
)

$legacyManagerFiles = @(
    "Invoke-StudioDisplayHotPlugHdrRecovery.ps1",
    "Register-StudioDisplayHotPlugHdrWatcher.ps1",
    "Repair-GpuRendering.ps1",
    "Repair-ResidentEvilHdr.ps1",
    "Repair-StudioDisplayGamingPipeline.ps1",
    "Repair-StudioDisplayHdr.ps1",
    "Repair-TheAltersResolution.ps1",
    "Repair-ZenlessZoneZeroResolution.ps1",
    "Set-OverwatchExclusiveFullscreenProfile.ps1",
    "Set-SpiderManGamingProfile.ps1"
) | ForEach-Object { Join-Path $managerRoot $_ }

$legacyLogs = @(
    (Join-Path $toolsRoot "OverwatchExclusiveFullscreenProfile.err.log"),
    (Join-Path $toolsRoot "OverwatchExclusiveFullscreenProfile.out.log")
)

$legacyShortcuts = @(
    "Studio Display Brightness Keys.lnk",
    "Studio Display Brightness.lnk",
    "Studio Display Manager.lnk",
    "Studio Display System Brightness Mirror.lnk"
) | ForEach-Object { Join-Path $startupRoot $_ }

function Write-Step {
    param([string]$Message)
    Write-Host $Message
}

function Assert-UnderPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside expected root. Path=$fullPath Root=$fullRoot"
    }
}

function Stop-PidFileProcess {
    param([string]$PidPath)

    if (-not (Test-Path -LiteralPath $PidPath)) {
        return
    }

    Assert-UnderPath -Path $PidPath -Root $toolsRoot
    $pidText = Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pidText -match '^\d+$') {
        $process = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
        if ($process) {
            Write-Step "Stopping legacy process PID $($process.Id) from $PidPath"
            if ($Apply) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
        }
    }

    if ($Apply) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    }
}

function Stop-LegacyProcessName {
    param([string]$Name)

    $processes = Get-Process -Name $Name -ErrorAction SilentlyContinue
    foreach ($process in $processes) {
        Write-Step "Stopping legacy process $Name PID $($process.Id)"
        if ($Apply) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }
}

function Remove-SafePath {
    param(
        [string]$Path,
        [string]$Root,
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Assert-UnderPath -Path $Path -Root $Root
    Write-Step "$(if ($Apply) { 'Removing' } else { 'Would remove' }): $Path"
    if ($Apply) {
        if ($Recurse) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Step "Studio Display legacy cleanup started. Apply=$Apply"
Write-Step "Keeping current integrated root: $managerRoot"

foreach ($pidFile in $legacyPidFiles) {
    Stop-PidFileProcess -PidPath $pidFile
}

foreach ($processName in $legacyProcessNames) {
    Stop-LegacyProcessName -Name $processName
}

foreach ($file in ($legacyManagerFiles + $legacyLogs)) {
    Remove-SafePath -Path $file -Root $toolsRoot
}

foreach ($directory in $legacyDirectories) {
    Remove-SafePath -Path $directory -Root $toolsRoot -Recurse
}

foreach ($shortcut in $legacyShortcuts) {
    Remove-SafePath -Path $shortcut -Root $startupRoot
}

if ($Apply) {
    Write-Step "Legacy cleanup finished."
}
else {
    Write-Step "Legacy cleanup dry run finished. Re-run with -Apply to make changes."
}
