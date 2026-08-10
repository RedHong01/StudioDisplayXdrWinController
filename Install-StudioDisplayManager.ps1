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
$hotplugAutomationTestSource = Join-Path $sourceRoot "Test-StudioDisplayHotplugAutomation.ps1"
$hotplugAutomationTestTarget = Join-Path $installRoot "Test-StudioDisplayHotplugAutomation.ps1"
$passiveHotplugObserverSource = Join-Path $sourceRoot "Watch-StudioDisplayHotplugAutomation.ps1"
$passiveHotplugObserverTarget = Join-Path $installRoot "Watch-StudioDisplayHotplugAutomation.ps1"
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
$schtasksExe = Join-Path $env:SystemRoot "System32\schtasks.exe"
$regExe = Join-Path $env:SystemRoot "System32\reg.exe"
$runKeyRegPath = "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"

$managerPidFile = Join-Path $installRoot "StudioDisplayManager.pid"
$mirrorPidFile = Join-Path $installRoot "SystemBrightnessMirror.pid"
$bridgePidFile = Join-Path $installRoot "BrightnessKeyBridge.pid"
$legacyTrayPidFile = Join-Path $legacyInstallRoot "SystemBrightnessMirrorTray.pid"
$legacyManagerPidFile = Join-Path $legacyInstallRoot "StudioDisplayManager.pid"
$legacyMirrorPidFile = Join-Path $legacyInstallRoot "SystemBrightnessMirror.pid"
$legacyBridgePidFile = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\BrightnessKeyBridge\BrightnessKeyBridge.pid"
$obsoleteInstalledFiles = @(
    "Repair-DiscordStudioDisplayMic.ps1",
    "Repair-StudioDisplayHdrIdentityRollback.ps1"
)

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

function Stop-OrphanStudioDisplayPowerShellProcesses {
    param(
        [string[]]$ScriptPaths
    )

    $normalizedScriptPaths = @(
        $ScriptPaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToLowerInvariant() }
    )

    if (-not $normalizedScriptPaths) {
        return
    }

    $processes = @()
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop)
    }
    catch {
        try {
            $processes = @(Get-WmiObject Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop)
        }
        catch {
            Write-Warning "$appName could not inspect PowerShell command lines for orphan cleanup: $($_.Exception.Message)"
            return
        }
    }

    foreach ($processInfo in $processes) {
        if ([int]$processInfo.ProcessId -eq $PID) {
            continue
        }

        $commandLine = [string]$processInfo.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }

        $commandLineLower = $commandLine.ToLowerInvariant()
        $isControllerWorker = [bool]($normalizedScriptPaths | Where-Object { $commandLineLower.Contains($_) } | Select-Object -First 1)
        if (-not $isControllerWorker) {
            continue
        }

        $process = Get-Process -Id ([int]$processInfo.ProcessId) -ErrorAction SilentlyContinue
        if ($process) {
            Write-Host "$appName stopping orphaned controller PowerShell worker PID=$($process.Id)."
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }
}

function Test-InstalledManagerRunning {
    if (-not (Test-Path -LiteralPath $managerPidFile)) {
        return $false
    }

    $managerPidText = Get-Content -LiteralPath $managerPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($managerPidText -notmatch '^\d+$') {
        Remove-Item -LiteralPath $managerPidFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    $process = Get-Process -Id ([int]$managerPidText) -ErrorAction SilentlyContinue
    if ($process) {
        return $true
    }

    Remove-Item -LiteralPath $managerPidFile -Force -ErrorAction SilentlyContinue
    return $false
}

function Wait-InstalledManagerRunning {
    param([int]$TimeoutSeconds = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-InstalledManagerRunning) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
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

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AutoRepairTask {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedAutoRepairPath
    )

    $result = [pscustomobject]@{
        Found = $false
        PathMatches = $false
        Detail = ""
    }

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $actionText = (($task.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join " ")
        $result.Found = $true
        $result.PathMatches = [bool]($actionText -like "*$ExpectedAutoRepairPath*")
        $result.Detail = "Get-ScheduledTask state=$($task.State) action=$actionText"
        return $result
    }
    catch {
        $result.Detail = "Get-ScheduledTask failed: $($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $schtasksExe) {
        try {
            $queryOutput = @(& $schtasksExe /Query /TN $TaskName /V /FO LIST 2>&1)
            if ($LASTEXITCODE -eq 0) {
                $queryText = ($queryOutput -join " ")
                $result.Found = $true
                $result.PathMatches = [bool]($queryText -like "*$ExpectedAutoRepairPath*")
                $result.Detail = "schtasks query succeeded"
            }
            else {
                $result.Detail = "schtasks query failed: $($queryOutput -join ' ')"
            }
        }
        catch {
            $result.Detail = "schtasks query threw: $($_.Exception.Message)"
        }
    }

    return $result
}

function Test-RecentAutoRepairTaskRegistrationSuccess {
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$StartedAt
    )

    $registrationLog = Join-Path (Join-Path $installRoot "reports") "StudioDisplayAutoRepairTaskRegistration.log"
    if (-not (Test-Path -LiteralPath $registrationLog)) {
        return $false
    }

    try {
        $successCutoff = $StartedAt.AddSeconds(-5)
        foreach ($line in (Get-Content -LiteralPath $registrationLog -Tail 80)) {
            if ($line -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+(.+)$') {
                continue
            }

            $timestamp = [DateTime]::ParseExact($Matches[1], "yyyy-MM-dd HH:mm:ss.fff", [Globalization.CultureInfo]::InvariantCulture)
            if ($timestamp -ge $successCutoff -and $Matches[2] -like "*Auto repair task registered successfully*") {
                return $true
            }
        }
    }
    catch {
        Write-Warning "$appName could not parse auto repair task registration log: $($_.Exception.Message)"
    }

    return $false
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

    $existingTask = Test-AutoRepairTask -TaskName $autoRepairTaskName -ExpectedAutoRepairPath $AutoRepairPath
    if ($existingTask.Found -and $existingTask.PathMatches) {
        Write-Host "$appName on-demand auto repair task already registered: $autoRepairTaskName"
        return
    }

    $registrationStartedAt = Get-Date
    $registrarArguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$autoRepairTaskRegistrarTarget`"",
        "-TaskName", "`"$autoRepairTaskName`"",
        "-AppName", "`"$appName`"",
        "-InstallRoot", "`"$installRoot`"",
        "-Quiet"
    )

    try {
        if (Test-IsAdministrator) {
            $registrationOutput = & $powershellExe @registrarArguments 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ($registrationOutput -join " ")
            }
        }
        else {
            Write-Host "$appName needs one UAC approval to register the elevated hot-plug auto-repair task."
            $registrationProcess = Start-Process -FilePath $powershellExe `
                -WorkingDirectory $installRoot `
                -Verb RunAs `
                -WindowStyle Hidden `
                -ArgumentList $registrarArguments `
                -Wait `
                -PassThru

            if ($null -ne $registrationProcess.ExitCode -and $registrationProcess.ExitCode -ne 0) {
                throw "UAC elevated registrar exited with code $($registrationProcess.ExitCode)."
            }
        }

        $registeredTask = Test-AutoRepairTask -TaskName $autoRepairTaskName -ExpectedAutoRepairPath $AutoRepairPath
        $recentRegistrationSucceeded = Test-RecentAutoRepairTaskRegistrationSuccess -StartedAt $registrationStartedAt
        if (-not ($registeredTask.Found -or $recentRegistrationSucceeded)) {
            throw "registration finished but the task could not be verified. $($registeredTask.Detail)"
        }

        if ($registeredTask.Found -and -not $registeredTask.PathMatches) {
            Write-Warning "$appName auto repair task exists but the query did not confirm the expected launcher path. $($registeredTask.Detail)"
        }

        Write-Host "$appName on-demand auto repair task registered or verified: $autoRepairTaskName"
    }
    catch {
        Write-Warning "$appName on-demand auto repair task could not be registered: $($_.Exception.Message)"
        Write-Warning "Hot-plug monitoring will still run, but automatic USB4/HDR repair requires approving the UAC prompt from the tray entry '自动修复权限：注册/修复' or rerunning this installer and accepting UAC."
    }
}

foreach ($pidPath in @($managerPidFile, $mirrorPidFile, $bridgePidFile, $legacyTrayPidFile, $legacyManagerPidFile, $legacyMirrorPidFile, $legacyBridgePidFile)) {
    Stop-ExistingProcess -PidPath $pidPath
}

Stop-OrphanStudioDisplayPowerShellProcesses -ScriptPaths @(
    $managerTarget,
    $mirrorTarget,
    $brightnessBridgeTarget,
    $integratedRepairTarget,
    $autoRepairTarget,
    $linkRefreshTarget,
    $externalModeRepairTarget,
    (Join-Path $legacyInstallRoot "StudioDisplayManager.ps1"),
    (Join-Path $legacyInstallRoot "SystemBrightnessMirror.ps1"),
    (Join-Path $legacyInstallRoot "BrightnessKeyBridge.ps1"),
    (Join-Path $env:LOCALAPPDATA "StudioDisplayTools\BrightnessKeyBridge\BrightnessKeyBridge.ps1")
)

New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
foreach ($obsoleteFile in $obsoleteInstalledFiles) {
    $obsoletePath = Join-Path $installRoot $obsoleteFile
    if (Test-Path -LiteralPath $obsoletePath) {
        Remove-Item -LiteralPath $obsoletePath -Force -ErrorAction SilentlyContinue
    }
}
Copy-Item -LiteralPath $managerSource -Destination $managerTarget -Force
Copy-Item -LiteralPath $brightnessBridgeSource -Destination $brightnessBridgeTarget -Force
Copy-Item -LiteralPath $starterSource -Destination $starterTarget -Force
Copy-Item -LiteralPath $stopperSource -Destination $stopperTarget -Force
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
Copy-Item -LiteralPath $hotplugAutomationTestSource -Destination $hotplugAutomationTestTarget -Force
Copy-Item -LiteralPath $passiveHotplugObserverSource -Destination $passiveHotplugObserverTarget -Force
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

if (Wait-InstalledManagerRunning -TimeoutSeconds 15) {
    Write-Host "$appName is running."
} else {
    Write-Warning "$appName was installed, but it is not confirmed running yet."
}
