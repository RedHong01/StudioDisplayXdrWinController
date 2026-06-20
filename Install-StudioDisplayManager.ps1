[CmdletBinding()]
param(
    [switch]$SkipAutoStart,
    [switch]$SkipStartNow
)

$ErrorActionPreference = "Stop"

$sourceRoot = $PSScriptRoot
$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager"
$legacyInstallRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\SystemBrightnessMirror"

$managerSource = Join-Path $sourceRoot "StudioDisplayManager.ps1"
$managerTarget = Join-Path $installRoot "StudioDisplayManager.ps1"
$starterSource = Join-Path $sourceRoot "Start-StudioDisplayManager.ps1"
$starterTarget = Join-Path $installRoot "Start-StudioDisplayManager.ps1"
$stopperSource = Join-Path $sourceRoot "Stop-StudioDisplayManager.ps1"
$stopperTarget = Join-Path $installRoot "Stop-StudioDisplayManager.ps1"
$micRepairSource = Join-Path $sourceRoot "Repair-DiscordStudioDisplayMic.ps1"
$micRepairTarget = Join-Path $installRoot "Repair-DiscordStudioDisplayMic.ps1"
$externalModeRepairSource = Join-Path $sourceRoot "Repair-StudioDisplayExternalMode.ps1"
$externalModeRepairTarget = Join-Path $installRoot "Repair-StudioDisplayExternalMode.ps1"
$overwatchProfileSource = Join-Path $sourceRoot "Set-OverwatchExclusiveFullscreenProfile.ps1"
$overwatchProfileTarget = Join-Path $installRoot "Set-OverwatchExclusiveFullscreenProfile.ps1"
$mirrorSource = Join-Path $sourceRoot "SystemBrightnessMirror.ps1"
$mirrorTarget = Join-Path $installRoot "SystemBrightnessMirror.ps1"
$hidHelperSource = Join-Path $sourceRoot "StudioDisplayHid.ps1"
$hidHelperTarget = Join-Path $installRoot "StudioDisplayHid.ps1"

$startupRoot = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$startupShortcut = Join-Path $startupRoot "Studio Display Manager.lnk"
$legacyStartupShortcut = Join-Path $startupRoot "Studio Display System Brightness Mirror.lnk"
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValueName = "Studio Display Manager"
$legacyRunValueName = "Studio Display System Brightness Mirror"
$startupTaskName = "Studio Display Manager"
$powershellExe = Join-Path $PSHOME "powershell.exe"

$managerPidFile = Join-Path $installRoot "StudioDisplayManager.pid"
$mirrorPidFile = Join-Path $installRoot "SystemBrightnessMirror.pid"
$legacyTrayPidFile = Join-Path $legacyInstallRoot "SystemBrightnessMirrorTray.pid"
$legacyManagerPidFile = Join-Path $legacyInstallRoot "StudioDisplayManager.pid"
$legacyMirrorPidFile = Join-Path $legacyInstallRoot "SystemBrightnessMirror.pid"

function Stop-ExistingProcess {
    param([string]$PidPath)

    if (-not (Test-Path $PidPath)) {
        return
    }

    $existingPid = Get-Content -LiteralPath $PidPath | Select-Object -First 1
    if ($existingPid -match '^\d+$') {
        $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    $shortcut.IconLocation = "$TargetPath,0"
    $shortcut.Save()
}

function Register-ManagerAutoStart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StarterPath
    )

    $arguments = "-Sta -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$StarterPath`""
    $runCommand = "`"$powershellExe`" $arguments"

    New-Shortcut -Path $startupShortcut -TargetPath $powershellExe -Arguments $arguments -WorkingDirectory $installRoot
    New-Item -Path $runKeyPath -Force | Out-Null
    Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value $runCommand

    Remove-ItemProperty -Path $runKeyPath -Name $legacyRunValueName -ErrorAction SilentlyContinue
}

foreach ($pidPath in @($managerPidFile, $mirrorPidFile, $legacyTrayPidFile, $legacyManagerPidFile, $legacyMirrorPidFile)) {
    Stop-ExistingProcess -PidPath $pidPath
}

New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
Copy-Item -LiteralPath $managerSource -Destination $managerTarget -Force
Copy-Item -LiteralPath $starterSource -Destination $starterTarget -Force
Copy-Item -LiteralPath $stopperSource -Destination $stopperTarget -Force
Copy-Item -LiteralPath $micRepairSource -Destination $micRepairTarget -Force
Copy-Item -LiteralPath $externalModeRepairSource -Destination $externalModeRepairTarget -Force
Copy-Item -LiteralPath $overwatchProfileSource -Destination $overwatchProfileTarget -Force
Copy-Item -LiteralPath $mirrorSource -Destination $mirrorTarget -Force
Copy-Item -LiteralPath $hidHelperSource -Destination $hidHelperTarget -Force

if (-not $SkipAutoStart) {
    foreach ($shortcut in @($startupShortcut, $legacyStartupShortcut)) {
        if (Test-Path $shortcut) {
            Remove-Item -LiteralPath $shortcut -Force
        }
    }

    Register-ManagerAutoStart -StarterPath $starterTarget
    Write-Host "Studio Display Manager auto-start entries created."
} else {
    Write-Host "Skipped Studio Display Manager auto-start creation."
}

if (-not $SkipStartNow) {
    Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
        "-Sta",
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $managerTarget
    )
    Start-Sleep -Seconds 5
}

if (Test-Path $managerPidFile) {
    Write-Host "Studio Display Manager is running."
} else {
    Write-Warning "Studio Display Manager was installed, but it is not confirmed running yet."
}
