[CmdletBinding()]
param(
    [switch]$SkipAutoStart,
    [switch]$SkipStartNow
)

$ErrorActionPreference = "Stop"

$sourceRoot = $PSScriptRoot
$appName = "Studio Display XDR Win Controller"
$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager"
$legacyInstallRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\SystemBrightnessMirror"

$managerSource = Join-Path $sourceRoot "StudioDisplayManager.ps1"
$managerTarget = Join-Path $installRoot "StudioDisplayManager.ps1"
$brightnessBridgeSource = Join-Path $sourceRoot "BrightnessKeyBridge.ps1"
$brightnessBridgeTarget = Join-Path $installRoot "BrightnessKeyBridge.ps1"
$starterSource = Join-Path $sourceRoot "Start-StudioDisplayManager.ps1"
$starterTarget = Join-Path $installRoot "Start-StudioDisplayManager.ps1"
$stopperSource = Join-Path $sourceRoot "Stop-StudioDisplayManager.ps1"
$stopperTarget = Join-Path $installRoot "Stop-StudioDisplayManager.ps1"
$micRepairSource = Join-Path $sourceRoot "Repair-DiscordStudioDisplayMic.ps1"
$micRepairTarget = Join-Path $installRoot "Repair-DiscordStudioDisplayMic.ps1"
$externalModeRepairSource = Join-Path $sourceRoot "Repair-StudioDisplayExternalMode.ps1"
$externalModeRepairTarget = Join-Path $installRoot "Repair-StudioDisplayExternalMode.ps1"
$linkRefreshSource = Join-Path $sourceRoot "Refresh-StudioDisplayXdrLink.ps1"
$linkRefreshTarget = Join-Path $installRoot "Refresh-StudioDisplayXdrLink.ps1"
$edidOverrideSource = Join-Path $sourceRoot "Apply-StudioDisplayEdidOverride.ps1"
$edidOverrideTarget = Join-Path $installRoot "Apply-StudioDisplayEdidOverride.ps1"
$bootCampMonitorDriverSource = Join-Path $sourceRoot "Install-StudioDisplayBootCampStyleMonitorDriver.ps1"
$bootCampMonitorDriverTarget = Join-Path $installRoot "Install-StudioDisplayBootCampStyleMonitorDriver.ps1"
$resolutionLadderSource = Join-Path $sourceRoot "Test-StudioDisplayResolutionLadder.ps1"
$resolutionLadderTarget = Join-Path $installRoot "Test-StudioDisplayResolutionLadder.ps1"
$advancedColorSource = Join-Path $sourceRoot "Get-StudioDisplayAdvancedColorState.ps1"
$advancedColorTarget = Join-Path $installRoot "Get-StudioDisplayAdvancedColorState.ps1"
$hdrStateSource = Join-Path $sourceRoot "Set-StudioDisplayHdrState.ps1"
$hdrStateTarget = Join-Path $installRoot "Set-StudioDisplayHdrState.ps1"
$brightnessInputTraceSource = Join-Path $sourceRoot "Trace-StudioDisplayBrightnessInput.ps1"
$brightnessInputTraceTarget = Join-Path $installRoot "Trace-StudioDisplayBrightnessInput.ps1"
$integratedRepairSource = Join-Path $sourceRoot "Repair-StudioDisplayIntegrated.ps1"
$integratedRepairTarget = Join-Path $installRoot "Repair-StudioDisplayIntegrated.ps1"
$autoRepairSource = Join-Path $sourceRoot "Invoke-StudioDisplayAutoRepair.ps1"
$autoRepairTarget = Join-Path $installRoot "Invoke-StudioDisplayAutoRepair.ps1"
$autoRepairTaskRegistrarSource = Join-Path $sourceRoot "Register-StudioDisplayAutoRepairTask.ps1"
$autoRepairTaskRegistrarTarget = Join-Path $installRoot "Register-StudioDisplayAutoRepairTask.ps1"
$repairProgressSource = Join-Path $sourceRoot "Show-StudioDisplayRepairProgress.ps1"
$repairProgressTarget = Join-Path $installRoot "Show-StudioDisplayRepairProgress.ps1"
$appleUsbInterfaceRepairSource = Join-Path $sourceRoot "Repair-StudioDisplayAppleUsbInterfaces.ps1"
$appleUsbInterfaceRepairTarget = Join-Path $installRoot "Repair-StudioDisplayAppleUsbInterfaces.ps1"
$mirrorSource = Join-Path $sourceRoot "SystemBrightnessMirror.ps1"
$mirrorTarget = Join-Path $installRoot "SystemBrightnessMirror.ps1"
$hidHelperSource = Join-Path $sourceRoot "StudioDisplayHid.ps1"
$hidHelperTarget = Join-Path $installRoot "StudioDisplayHid.ps1"

$startupRoot = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$startupShortcut = Join-Path $startupRoot "$appName.lnk"
$legacyManagerStartupShortcut = Join-Path $startupRoot "Studio Display Manager.lnk"
$legacyStartupShortcut = Join-Path $startupRoot "Studio Display System Brightness Mirror.lnk"
$runValueName = $appName
$legacyManagerRunValueName = "Studio Display Manager"
$legacyRunValueName = "Studio Display System Brightness Mirror"
$startupTaskName = $appName
$autoRepairTaskName = "$appName Auto Repair"
$powershellExe = Join-Path $PSHOME "powershell.exe"
$regExe = Join-Path $env:SystemRoot "System32\reg.exe"
$runKeyRegPath = "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"

$managerPidFile = Join-Path $installRoot "StudioDisplayManager.pid"
$mirrorPidFile = Join-Path $installRoot "SystemBrightnessMirror.pid"
$bridgePidFile = Join-Path $installRoot "BrightnessKeyBridge.pid"
$legacyTrayPidFile = Join-Path $legacyInstallRoot "SystemBrightnessMirrorTray.pid"
$legacyManagerPidFile = Join-Path $legacyInstallRoot "StudioDisplayManager.pid"
$legacyMirrorPidFile = Join-Path $legacyInstallRoot "SystemBrightnessMirror.pid"
$legacyBridgePidFile = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\BrightnessKeyBridge\BrightnessKeyBridge.pid"

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
    try {
        $runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        New-Item -Path $runKeyPath -Force | Out-Null
        Set-ItemProperty -Path $runKeyPath -Name $runValueName -Value $runCommand
        Remove-ItemProperty -Path $runKeyPath -Name $legacyManagerRunValueName -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $runKeyPath -Name $legacyRunValueName -ErrorAction SilentlyContinue
        Write-Host "$appName Run-key auto-start entry created."
    }
    catch {
        Write-Warning "$appName Run-key auto-start entry could not be created: $($_.Exception.Message)"
    }
}

function Register-AutoRepairTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AutoRepairPath
    )

    if (-not (Test-Path -LiteralPath $AutoRepairPath)) {
        Write-Warning "$appName auto repair task could not be registered because the launcher is missing: $AutoRepairPath"
        return
    }

    try {
        $registrationOutput = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $autoRepairTaskRegistrarTarget -TaskName $autoRepairTaskName -AppName $appName -InstallRoot $installRoot -Quiet 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ($registrationOutput -join " ")
        }

        Write-Host "$appName on-demand auto repair task registered: $autoRepairTaskName"
    }
    catch {
        Write-Warning "$appName on-demand auto repair task could not be registered: $($_.Exception.Message)"
        Write-Warning "Hot-plug monitoring will still run, but automatic USB4/HDR repair may require running the installer from an elevated PowerShell window."
    }
}

foreach ($pidPath in @($managerPidFile, $mirrorPidFile, $bridgePidFile, $legacyTrayPidFile, $legacyManagerPidFile, $legacyMirrorPidFile, $legacyBridgePidFile)) {
    Stop-ExistingProcess -PidPath $pidPath
}

New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
Copy-Item -LiteralPath $managerSource -Destination $managerTarget -Force
Copy-Item -LiteralPath $brightnessBridgeSource -Destination $brightnessBridgeTarget -Force
Copy-Item -LiteralPath $starterSource -Destination $starterTarget -Force
Copy-Item -LiteralPath $stopperSource -Destination $stopperTarget -Force
Copy-Item -LiteralPath $micRepairSource -Destination $micRepairTarget -Force
Copy-Item -LiteralPath $externalModeRepairSource -Destination $externalModeRepairTarget -Force
Copy-Item -LiteralPath $linkRefreshSource -Destination $linkRefreshTarget -Force
Copy-Item -LiteralPath $edidOverrideSource -Destination $edidOverrideTarget -Force
Copy-Item -LiteralPath $bootCampMonitorDriverSource -Destination $bootCampMonitorDriverTarget -Force
Copy-Item -LiteralPath $resolutionLadderSource -Destination $resolutionLadderTarget -Force
Copy-Item -LiteralPath $advancedColorSource -Destination $advancedColorTarget -Force
Copy-Item -LiteralPath $hdrStateSource -Destination $hdrStateTarget -Force
Copy-Item -LiteralPath $brightnessInputTraceSource -Destination $brightnessInputTraceTarget -Force
Copy-Item -LiteralPath $integratedRepairSource -Destination $integratedRepairTarget -Force
Copy-Item -LiteralPath $autoRepairSource -Destination $autoRepairTarget -Force
Copy-Item -LiteralPath $autoRepairTaskRegistrarSource -Destination $autoRepairTaskRegistrarTarget -Force
Copy-Item -LiteralPath $repairProgressSource -Destination $repairProgressTarget -Force
Copy-Item -LiteralPath $appleUsbInterfaceRepairSource -Destination $appleUsbInterfaceRepairTarget -Force
Copy-Item -LiteralPath $mirrorSource -Destination $mirrorTarget -Force
Copy-Item -LiteralPath $hidHelperSource -Destination $hidHelperTarget -Force

Register-AutoRepairTask -AutoRepairPath $autoRepairTarget

if (-not $SkipAutoStart) {
    foreach ($shortcut in @($startupShortcut, $legacyManagerStartupShortcut, $legacyStartupShortcut)) {
        if (Test-Path $shortcut) {
            Remove-Item -LiteralPath $shortcut -Force
        }
    }

    Register-ManagerAutoStart -StarterPath $starterTarget
    Write-Host "$appName Startup shortcut created."
} else {
    Write-Host "Skipped $appName auto-start creation."
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
    Write-Host "$appName is running."
} else {
    Write-Warning "$appName was installed, but it is not confirmed running yet."
}
