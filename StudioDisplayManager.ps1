[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Resolve-StudioDisplayPowerShellExe {
    $candidates = @(
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"),
        (Join-Path $PSHOME "powershell.exe")
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($command -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    return "powershell.exe"
}

$installRoot = $PSScriptRoot
$mirrorScript = Join-Path $installRoot "SystemBrightnessMirror.ps1"
$brightnessBridgeScript = Join-Path $installRoot "BrightnessKeyBridge.ps1"
$hdrScreenshotGuardScript = Join-Path $installRoot "HdrScreenshotGuard.ps1"
$integratedRepairScript = Join-Path $installRoot "Repair-StudioDisplayIntegrated.ps1"
$autoRepairScript = Join-Path $installRoot "Invoke-StudioDisplayAutoRepair.ps1"
$autoRepairTaskRegistrarScript = Join-Path $installRoot "Register-StudioDisplayAutoRepairTask.ps1"
$hotplugAutomationTestScript = Join-Path $installRoot "Test-StudioDisplayHotplugAutomation.ps1"
$passiveHotplugObserverScript = Join-Path $installRoot "Watch-StudioDisplayHotplugAutomation.ps1"
$repairProgressScript = Join-Path $installRoot "Show-StudioDisplayRepairProgress.ps1"
$advancedColorScript = Join-Path $installRoot "Get-StudioDisplayAdvancedColorState.ps1"
$hdrStateScript = Join-Path $installRoot "Set-StudioDisplayHdrState.ps1"
$resolutionLadderScript = Join-Path $installRoot "Test-StudioDisplayResolutionLadder.ps1"
$brightnessInputTraceScript = Join-Path $installRoot "Trace-StudioDisplayBrightnessInput.ps1"
$hidHelperScript = Join-Path $installRoot "StudioDisplayHid.ps1"
$mirrorPidFile = Join-Path $installRoot "SystemBrightnessMirror.pid"
$brightnessBridgePidFile = Join-Path $installRoot "BrightnessKeyBridge.pid"
$hdrScreenshotGuardPidFile = Join-Path $installRoot "HdrScreenshotGuard.pid"
$trayPidFile = Join-Path $installRoot "StudioDisplayManager.pid"
$passiveHotplugObserverPidFile = Join-Path $installRoot "StudioDisplayPassiveHotplugObserver.pid"
$logPath = Join-Path $installRoot "SystemBrightnessMirror.log"
$reportsRoot = Join-Path $installRoot "reports"
$pipelineDecisionFile = Join-Path $installRoot "StudioDisplayHotplugPipelineDecision.json"
$hdrGateBlockStateFile = Join-Path $installRoot "StudioDisplayHdrGateBlockState.json"
$lastFailureStateFile = Join-Path $installRoot "StudioDisplayLastFailureState.json"
$physicalReenumerationStateFile = Join-Path $installRoot "StudioDisplayPhysicalReenumerationState.json"
$automationMaintenanceStateFile = Join-Path $installRoot "StudioDisplayAutomationMaintenanceState.json"
$resolutionModeTableBlockStateFile = Join-Path $installRoot "StudioDisplayResolutionModeTableBlockState.json"
$fastFallbackStateFile = Join-Path $installRoot "StudioDisplayFastVisibleFallbackState.json"
$powershellExe = Resolve-StudioDisplayPowerShellExe
$schtasksExe = Join-Path $env:SystemRoot "System32\schtasks.exe"
$appName = "Studio Display XDR Win Controller"
$autoRepairTaskName = "$appName Auto Repair"
$mutexName = "StudioDisplayManager"
$mirrorMutexName = "StudioDisplaySystemBrightnessMirror"
$brightnessBridgeMutexName = "StudioDisplayBrightnessKeyBridge"
$hdrScreenshotGuardMutexName = "StudioDisplayHdrScreenshotGuard"
$statusTooltipRunning = "${appName}: Running"
$statusTooltipStopped = "${appName}: Brightness control stopped"
$studioDisplayMonitorPattern = "DISPLAY\\APPA|Studio Display|StudioDisplay|Pro Display XDR|Display XDR"
$studioDisplayUsbPattern = "VID_05AC&PID_1114|VID_05AC&PID_1116|USB4\\VID_8087&PID_5786|Studio Display|Studio Display XDR|Pro Display XDR|Apple.*Studio Display"
$studioDisplayPnpCheckCooldownSeconds = 15
$hdrActivationCooldownSeconds = 45
$integratedRepairCooldownSeconds = 45
$integratedRepairSettleSeconds = 15
$integratedRepairWatchdogSeconds = 150
$integratedRepairHardWatchdogSeconds = 600
$integratedRepairLogProgressGraceSeconds = 120
$integratedRepairNoProcessGraceSeconds = 20
$integratedRepairWaitLogCooldownSeconds = 30
$integratedRepairCooldownLogSeconds = 30
$integratedRepairMissingTaskBackoffSeconds = 300
$hdrGateBlockedBackoffSeconds = 90
$hdrGateBlockedRetryLimit = 4
$hdrGateBlockedLogCooldownSeconds = 60
$hdrGatePhysicalReenumWaitHours = 12
$resolutionModeTableBlockedBackoffSeconds = 600
$resolutionModeTableBlockedRetryLimit = 1
$resolutionModeTableStaleBackoffSeconds = 90
$resolutionModeTableStaleRetryLimit = 3
$resolutionModeTableBlockedLogCooldownSeconds = 60
$hdrActiveResolutionSettleSeconds = 30
$brightnessServiceRecoveryCooldownSeconds = 20
$autoRepairTaskRegistrationPromptBackoffSeconds = 1800
$hdrScreenshotSafeSdrWhiteNits = 240
$hdrScreenshotGuardStartBackoffSeconds = 30
$displayRepairBlockedProcessNames = @()

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class StudioDisplayUser32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

function Write-AppLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $logPath -Value "$timestamp $Message" -ErrorAction SilentlyContinue
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-NamedMutexHeld {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $mutex = $null
    $acquired = $false
    try {
        $mutex = [System.Threading.Mutex]::OpenExisting($Name)
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] {
        return $false
    }
    catch {
        Write-AppLog "Named mutex probe failed for $Name`: $($_.Exception.Message)"
        return $false
    }

    try {
        try {
            $acquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if ($acquired) {
            return $false
        }

        return $true
    }
    catch {
        Write-AppLog "Named mutex probe failed for $Name`: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($mutex) {
            if ($acquired) {
                try {
                    $mutex.ReleaseMutex() | Out-Null
                }
                catch {
                }
            }
            $mutex.Dispose()
        }
    }
}

function Get-ManagedProcessFromPidPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PidPath
    )

    if (-not (Test-Path $PidPath)) {
        return $null
    }

    $existingPid = Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $existingPid) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    if ($existingPid -notmatch '^\d+$') {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
    if ($process) {
        return $process
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    return $null
}

function Test-ManagedProcessRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PidPath
    )

    return [bool](Get-ManagedProcessFromPidPath -PidPath $PidPath)
}

function Get-StudioDisplayWorkerProcessCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [switch]$Quiet
    )

    $scriptLeaf = [System.IO.Path]::GetFileName($ScriptPath)
    if ([string]::IsNullOrWhiteSpace($scriptLeaf)) {
        return @()
    }

    $scriptPathLower = $ScriptPath.ToLowerInvariant()
    $scriptLeafLower = $scriptLeaf.ToLowerInvariant()
    $installRootLower = $installRoot.ToLowerInvariant()
    $legacyInstallRootLower = (Join-Path $env:LOCALAPPDATA "StudioDisplayTools\SystemBrightnessMirror").ToLowerInvariant()
    $legacyBrightnessRootLower = (Join-Path $env:LOCALAPPDATA "StudioDisplayTools\BrightnessKeyBridge").ToLowerInvariant()

    $processes = @()
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop)
    }
    catch {
        try {
            $processes = @(Get-WmiObject Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop)
        }
        catch {
            if (-not $Quiet) {
                Write-AppLog "Could not inspect PowerShell command lines for $scriptLeaf worker adoption: $($_.Exception.Message)"
            }
            return @()
        }
    }

    $matches = @()
    foreach ($processInfo in $processes) {
        if ([int]$processInfo.ProcessId -eq $PID) {
            continue
        }

        $commandLine = [string]$processInfo.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }

        $commandLineLower = $commandLine.ToLowerInvariant()
        $exactScriptMatch = $commandLineLower.Contains($scriptPathLower)
        $sameInstallRootScriptMatch = ($commandLineLower.Contains($installRootLower) -and $commandLineLower.Contains($scriptLeafLower))
        $legacyScriptMatch = (
            ($commandLineLower.Contains($legacyInstallRootLower) -and $commandLineLower.Contains($scriptLeafLower)) -or
            ($commandLineLower.Contains($legacyBrightnessRootLower) -and $commandLineLower.Contains($scriptLeafLower))
        )
        if (-not ($exactScriptMatch -or $sameInstallRootScriptMatch -or $legacyScriptMatch)) {
            continue
        }

        $process = Get-Process -Id ([int]$processInfo.ProcessId) -ErrorAction SilentlyContinue
        if ($process) {
            $matches += [pscustomobject]@{
                Id = [int]$processInfo.ProcessId
                Process = $process
                CommandLine = $commandLine
            }
        }
    }

    return @($matches)
}

function Set-ManagedPidFileForProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PidPath,
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    try {
        Set-Content -LiteralPath $PidPath -Value $Process.Id -Encoding ascii -ErrorAction Stop
        Write-AppLog "$Label worker adopted with managed PID=$($Process.Id)."
        return $true
    }
    catch {
        Write-AppLog "$Label worker is running as PID=$($Process.Id), but the controller could not write $PidPath`: $($_.Exception.Message)"
        return $false
    }
}

function Adopt-StudioDisplayWorkerProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$PidPath,
        [switch]$Quiet
    )

    $candidates = @(Get-StudioDisplayWorkerProcessCandidates -ScriptPath $ScriptPath -Quiet:$Quiet)
    if ($candidates.Count -eq 1) {
        return (Set-ManagedPidFileForProcess -PidPath $PidPath -Process $candidates[0].Process -Label $Label)
    }

    if ($candidates.Count -gt 1 -and -not $Quiet) {
        Write-AppLog "$Label worker adoption skipped because multiple candidate processes were found: $(@($candidates | ForEach-Object { $_.Id }) -join ', ')."
    }

    return $false
}

function Stop-OrphanStudioDisplayWorkerProcesses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $candidates = @(Get-StudioDisplayWorkerProcessCandidates -ScriptPath $ScriptPath)
    foreach ($candidate in $candidates) {
        try {
            Write-AppLog "Stopping orphaned $Label worker PID=$($candidate.Id)."
            Stop-Process -Id $candidate.Id -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 500
        }
        catch {
            Write-AppLog "Could not stop orphaned $Label worker PID=$($candidate.Id): $($_.Exception.Message)"
        }
    }
}

function Test-BrightnessWorkerAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$PidPath,
        [Parameter(Mandatory = $true)]
        [string]$MutexName
    )

    if (Test-ManagedProcessRunning -PidPath $PidPath) {
        return $true
    }

    if (Adopt-StudioDisplayWorkerProcess -Label $Label -ScriptPath $ScriptPath -PidPath $PidPath -Quiet) {
        return $true
    }

    if (Test-NamedMutexHeld -Name $MutexName) {
        return $false
    }

    return $false
}

function Get-StudioDisplayFastFallbackState {
    if (-not (Test-Path -LiteralPath $fastFallbackStateFile)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $fastFallbackStateFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $null
        }

        $state = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $state.Status) {
            return $null
        }

        return $state
    }
    catch {
        Write-AppLog "Fast visible fallback state could not be read: $($_.Exception.Message)"
        return $null
    }
}

function Clear-StudioDisplayFastFallbackState {
    try {
        if (Test-Path -LiteralPath $fastFallbackStateFile) {
            Remove-Item -LiteralPath $fastFallbackStateFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-AppLog "Fast visible fallback state could not be cleared: $($_.Exception.Message)"
    }
}

function Stop-ManagedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PidPath
    )

    if (-not (Test-Path $PidPath)) {
        return
    }

    $existingPid = Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    $removePidFile = $true
    if ($existingPid -match '^\d+$') {
        $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $deadline = (Get-Date).AddSeconds(4)
            do {
                Start-Sleep -Milliseconds 250
                $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
            } while ($process -and (Get-Date) -lt $deadline)

            if ($process) {
                Write-AppLog "Could not stop managed worker PID=$existingPid for $PidPath; keeping pid file so the controller does not lose ownership while the mutex is still held."
                $removePidFile = $false
            }
        }
    }

    if ($removePidFile) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-MirrorService {
    if (Test-ManagedProcessRunning -PidPath $mirrorPidFile) {
        return $true
    }

    if (Adopt-StudioDisplayWorkerProcess -Label "SystemBrightnessMirror" -ScriptPath $mirrorScript -PidPath $mirrorPidFile) {
        return $true
    }

    if (Test-NamedMutexHeld -Name $mirrorMutexName) {
        Write-AppLog "SystemBrightnessMirror mutex is held without a managed pid file and no unique adoptable worker was found; treating brightness mirror as unhealthy instead of reporting a false success."
        return $false
    }

    $process = Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -PassThru -ArgumentList @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $mirrorScript,
        "-EnableLogging"
    )

    Start-Sleep -Seconds 2
    $running = Test-ManagedProcessRunning -PidPath $mirrorPidFile
    if (-not $running) {
        if ($process -and -not $process.HasExited) {
            return (Set-ManagedPidFileForProcess -PidPath $mirrorPidFile -Process $process -Label "SystemBrightnessMirror")
        }

        $exitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { "still-running-without-pid" }
        $mutexHeld = Test-NamedMutexHeld -Name $mirrorMutexName
        Write-AppLog "SystemBrightnessMirror did not create a managed pid file after startup. exitCode=$exitCode mutexHeld=$mutexHeld pidFile=$mirrorPidFile"
        if ($mutexHeld) {
            if (Adopt-StudioDisplayWorkerProcess -Label "SystemBrightnessMirror" -ScriptPath $mirrorScript -PidPath $mirrorPidFile) {
                return $true
            }

            Write-AppLog "SystemBrightnessMirror mutex is held but no managed/adoptable worker was found; leaving brightness mirror unhealthy so the controller can surface the problem instead of hiding a stale/no-pid worker."
            return $false
        }
    }
    return $running
}

function Start-BrightnessKeyBridge {
    if (Test-ManagedProcessRunning -PidPath $brightnessBridgePidFile) {
        return $true
    }

    if (Adopt-StudioDisplayWorkerProcess -Label "BrightnessKeyBridge" -ScriptPath $brightnessBridgeScript -PidPath $brightnessBridgePidFile) {
        return $true
    }

    if (Test-NamedMutexHeld -Name $brightnessBridgeMutexName) {
        Write-AppLog "BrightnessKeyBridge mutex is held without a managed pid file and no unique adoptable worker was found; treating brightness key bridge as unhealthy instead of reporting a false success."
        return $false
    }

    if (-not (Test-Path $brightnessBridgeScript)) {
        Write-AppLog "Brightness key bridge script is missing: $brightnessBridgeScript"
        return $false
    }

    $process = Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -PassThru -ArgumentList @(
        "-Sta",
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $brightnessBridgeScript,
        "-EnableLogging",
        "-StepPercent", "10"
    )

    Start-Sleep -Seconds 2
    $running = Test-ManagedProcessRunning -PidPath $brightnessBridgePidFile
    if (-not $running) {
        if ($process -and -not $process.HasExited) {
            return (Set-ManagedPidFileForProcess -PidPath $brightnessBridgePidFile -Process $process -Label "BrightnessKeyBridge")
        }

        $exitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { "still-running-without-pid" }
        $mutexHeld = Test-NamedMutexHeld -Name $brightnessBridgeMutexName
        Write-AppLog "BrightnessKeyBridge did not create a managed pid file after startup. exitCode=$exitCode mutexHeld=$mutexHeld pidFile=$brightnessBridgePidFile"
        if ($mutexHeld) {
            if (Adopt-StudioDisplayWorkerProcess -Label "BrightnessKeyBridge" -ScriptPath $brightnessBridgeScript -PidPath $brightnessBridgePidFile) {
                return $true
            }

            Write-AppLog "BrightnessKeyBridge mutex is held but no managed/adoptable worker was found; leaving brightness key bridge unhealthy so the controller can surface the problem instead of hiding a stale/no-pid worker."
            return $false
        }
    }
    return $running
}

function Test-StudioDisplayDeepRepairActive {
    if ($script:integratedRepairInFlight) {
        return $true
    }

    try {
        if ((Get-StudioDisplayAutoRepairTaskState) -ne "Running") {
            return $false
        }

        if (Test-StudioDisplayIntegratedRepairProcessRunning) {
            return $true
        }

        $repairLogInfo = Get-StudioDisplayLatestIntegratedRepairLogInfo
        return [bool]($repairLogInfo -and $repairLogInfo.AgeSeconds -le $integratedRepairNoProcessGraceSeconds)
    }
    catch {
        return $false
    }
}

function Start-BrightnessServices {
    param([switch]$Force)

    if (-not $Force -and (Test-StudioDisplayDeepRepairActive)) {
        Write-AppLog "Brightness service start skipped because the integrated 5K/HDR repair task is still active. Brightness will be restored by the integrated pipeline after display/HDR gates finish."
        return $false
    }

    $mirrorStarted = Start-MirrorService
    $bridgeStarted = Start-BrightnessKeyBridge
    return [bool]($mirrorStarted -and $bridgeStarted)
}

function Test-BrightnessServicesRunning {
    $mirrorRunning = Test-BrightnessWorkerAvailable -Label "SystemBrightnessMirror" -ScriptPath $mirrorScript -PidPath $mirrorPidFile -MutexName $mirrorMutexName
    $bridgeRunning = Test-BrightnessWorkerAvailable -Label "BrightnessKeyBridge" -ScriptPath $brightnessBridgeScript -PidPath $brightnessBridgePidFile -MutexName $brightnessBridgeMutexName
    return [bool]($mirrorRunning -and $bridgeRunning)
}

function Restore-BrightnessServicesWhenSafe {
    param([string]$Reason = "automatic brightness service recovery")

    if (Test-BrightnessServicesRunning) {
        return $true
    }

    if (Test-StudioDisplayDeepRepairActive) {
        return $false
    }

    $now = Get-Date
    if (($now - $script:lastBrightnessServiceRecoveryAttemptAt).TotalSeconds -lt $brightnessServiceRecoveryCooldownSeconds) {
        return $false
    }

    $script:lastBrightnessServiceRecoveryAttemptAt = $now
    $started = Start-BrightnessServices
    if ($started) {
        Write-AppLog "Brightness services restored for $Reason after the display pipeline was no longer actively repairing."
    }
    else {
        Write-AppLog "Brightness services are still unavailable for $Reason even though no active integrated repair host was detected."
    }

    return [bool]$started
}

function Stop-BrightnessServices {
    Stop-ManagedProcess -PidPath $mirrorPidFile
    Stop-ManagedProcess -PidPath $brightnessBridgePidFile
    Stop-OrphanStudioDisplayWorkerProcesses -Label "SystemBrightnessMirror" -ScriptPath $mirrorScript
    Stop-OrphanStudioDisplayWorkerProcesses -Label "BrightnessKeyBridge" -ScriptPath $brightnessBridgeScript
}

function Restart-BrightnessServices {
    Stop-BrightnessServices
    return (Start-BrightnessServices)
}

function Test-HdrScreenshotGuardRunning {
    return (Test-BrightnessWorkerAvailable -Label "HdrScreenshotGuard" -ScriptPath $hdrScreenshotGuardScript -PidPath $hdrScreenshotGuardPidFile -MutexName $hdrScreenshotGuardMutexName)
}

function Start-HdrScreenshotGuard {
    if (Test-ManagedProcessRunning -PidPath $hdrScreenshotGuardPidFile) {
        return $true
    }

    if (Adopt-StudioDisplayWorkerProcess -Label "HdrScreenshotGuard" -ScriptPath $hdrScreenshotGuardScript -PidPath $hdrScreenshotGuardPidFile) {
        return $true
    }

    if (Test-NamedMutexHeld -Name $hdrScreenshotGuardMutexName) {
        Write-AppLog "HdrScreenshotGuard mutex is held without a managed pid file and no unique adoptable worker was found; treating screenshot guard as unhealthy instead of starting a duplicate."
        return $false
    }

    if (-not (Test-Path -LiteralPath $hdrScreenshotGuardScript)) {
        Write-AppLog "HDR screenshot guard script is missing: $hdrScreenshotGuardScript"
        return $false
    }

    $process = Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -PassThru -ArgumentList @(
        "-Sta",
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $hdrScreenshotGuardScript,
        "-InstallRoot", "`"$installRoot`"",
        "-SafeSdrWhiteNits", ([string]$hdrScreenshotSafeSdrWhiteNits)
    )

    Start-Sleep -Seconds 2
    $running = Test-ManagedProcessRunning -PidPath $hdrScreenshotGuardPidFile
    if (-not $running) {
        if ($process -and -not $process.HasExited) {
            return (Set-ManagedPidFileForProcess -PidPath $hdrScreenshotGuardPidFile -Process $process -Label "HdrScreenshotGuard")
        }

        $exitCode = if ($process -and $process.HasExited) { $process.ExitCode } else { "still-running-without-pid" }
        $mutexHeld = Test-NamedMutexHeld -Name $hdrScreenshotGuardMutexName
        Write-AppLog "HdrScreenshotGuard did not create a managed pid file after startup. exitCode=$exitCode mutexHeld=$mutexHeld pidFile=$hdrScreenshotGuardPidFile"
        if ($mutexHeld) {
            if (Adopt-StudioDisplayWorkerProcess -Label "HdrScreenshotGuard" -ScriptPath $hdrScreenshotGuardScript -PidPath $hdrScreenshotGuardPidFile) {
                return $true
            }

            Write-AppLog "HdrScreenshotGuard mutex is held but no managed/adoptable worker was found; leaving screenshot guard unhealthy so the controller can surface the problem."
            return $false
        }
    }

    return $running
}

function Stop-HdrScreenshotGuard {
    Stop-ManagedProcess -PidPath $hdrScreenshotGuardPidFile
    Stop-OrphanStudioDisplayWorkerProcesses -Label "HdrScreenshotGuard" -ScriptPath $hdrScreenshotGuardScript
}

function Restart-HdrScreenshotGuard {
    Stop-HdrScreenshotGuard
    return (Start-HdrScreenshotGuard)
}

function Ensure-HdrScreenshotGuard {
    if (Test-HdrScreenshotGuardRunning) {
        return $true
    }

    $now = Get-Date
    if (($now - $script:lastHdrScreenshotGuardStartAttemptAt).TotalSeconds -lt $hdrScreenshotGuardStartBackoffSeconds) {
        return $false
    }

    $script:lastHdrScreenshotGuardStartAttemptAt = $now
    return (Start-HdrScreenshotGuard)
}

function Test-StudioDisplayPassiveObserverRunning {
    if (-not (Test-Path -LiteralPath $passiveHotplugObserverPidFile)) {
        return $false
    }

    $observerPid = Get-Content -LiteralPath $passiveHotplugObserverPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($observerPid -notmatch '^\d+$') {
        Remove-Item -LiteralPath $passiveHotplugObserverPidFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    $process = Get-Process -Id ([int]$observerPid) -ErrorAction SilentlyContinue
    if ($process) {
        return $true
    }

    Remove-Item -LiteralPath $passiveHotplugObserverPidFile -Force -ErrorAction SilentlyContinue
    return $false
}

function Start-StudioDisplayPassiveHotplugObserver {
    param(
        [string]$Reason = "hot-plug"
    )

    if (-not (Test-Path -LiteralPath $passiveHotplugObserverScript)) {
        Write-AppLog "Passive hot-plug observer skipped for $Reason because script is missing: $passiveHotplugObserverScript"
        return $false
    }

    if (Test-StudioDisplayPassiveObserverRunning) {
        Write-AppLog "Passive hot-plug observer already running for $Reason; not starting another observer."
        return $true
    }

    try {
        Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass",
            "-File", $passiveHotplugObserverScript,
            "-InstallRoot", "`"$installRoot`"",
            "-DurationMinutes", "20",
            "-PollSeconds", "3",
            "-ExitAfterTaskCompletes",
            "-RunLabel", "`"$Reason`""
        ) | Out-Null
        Write-AppLog "Passive hot-plug observer started for $Reason. It records repair stages and gates without changing display state."
        return $true
    }
    catch {
        Write-AppLog "Passive hot-plug observer failed to start for $Reason`: $($_.Exception.Message)"
        return $false
    }
}

function Save-StudioDisplayPipelineDecision {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason,
        [Parameter(Mandatory = $true)]
        [string]$Stage,
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string]$Detail = "",
        [object]$ResolutionState = $null,
        [object]$HdrState = $null
    )

    try {
        $now = Get-Date
        $decision = [ordered]@{
            Version = 1
            UpdatedAt = $now.ToString("o")
            Reason = $Reason
            Stage = $Stage
            Action = $Action
            Detail = $Detail
            Resolution = if ($ResolutionState) {
                [ordered]@{
                    Known = [bool]$ResolutionState.Known
                    Current5K = [bool]$ResolutionState.HasCurrent5K
                    FiveK60Enumerated = [bool]$ResolutionState.Has5K60Enumerated
                    FiveK120Enumerated = [bool]$ResolutionState.Has5K120Enumerated
                }
            } else { $null }
            Hdr = if ($HdrState) {
                [ordered]@{
                    Known = [bool]$HdrState.Known
                    HdrSupported = [bool]$HdrState.HdrSupported
                    HdrUnsupported = [bool]$HdrState.HdrUnsupported
                    HdrActive = [bool]$HdrState.HdrActive
                    WcgActive = [bool]$HdrState.WcgActive
                }
            } else { $null }
            KnownHdrGateConclusion = "If Boot Camp-style MS_0001 identity and 5K60 are ready but HDR remains blocked, record VID_05AC&PID_1116 MI_08/MI_09 Apple USB control-interface failures as correlation evidence. They are not a code=0 blocker when 5K60, HDR active, and brightness HID all validate."
        }

        if (Test-Path -LiteralPath $pipelineDecisionFile) {
            try {
                $previous = Get-Content -LiteralPath $pipelineDecisionFile -Raw -ErrorAction Stop | ConvertFrom-Json
                $previousUpdatedAt = [DateTime]::MinValue
                [void][DateTime]::TryParse([string]$previous.UpdatedAt, [ref]$previousUpdatedAt)
                $separator = [string][char]31
                $currentFingerprint = @(
                    $Reason,
                    $Stage,
                    $Action,
                    $Detail,
                    ($decision.Resolution | ConvertTo-Json -Depth 6 -Compress),
                    ($decision.Hdr | ConvertTo-Json -Depth 6 -Compress)
                ) -join $separator
                $previousFingerprint = @(
                    [string]$previous.Reason,
                    [string]$previous.Stage,
                    [string]$previous.Action,
                    [string]$previous.Detail,
                    ($previous.Resolution | ConvertTo-Json -Depth 6 -Compress),
                    ($previous.Hdr | ConvertTo-Json -Depth 6 -Compress)
                ) -join $separator

                if ($currentFingerprint -eq $previousFingerprint -and ($now - $previousUpdatedAt).TotalSeconds -lt 60) {
                    return
                }
            }
            catch {
                Write-AppLog "Pipeline decision de-duplication could not read the previous decision: $($_.Exception.Message)"
            }
        }

        $decision | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pipelineDecisionFile -Encoding ascii -ErrorAction Stop
        Write-AppLog "Pipeline decision for $Reason`: stage=$Stage action=$Action detail=$Detail"
    }
    catch {
        Write-AppLog "Could not save pipeline decision for $Reason`: $($_.Exception.Message)"
    }
}

function Get-StudioDisplaySystemBootTime {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os -and $os.LastBootUpTime) {
            return [DateTime]$os.LastBootUpTime
        }
    }
    catch {
        Write-AppLog "Could not read system boot time: $($_.Exception.Message)"
    }

    return [DateTime]::MinValue
}

function Get-StudioDisplayLastFailureState {
    if (-not (Test-Path -LiteralPath $lastFailureStateFile)) {
        return $null
    }

    try {
        $failureState = Get-Content -LiteralPath $lastFailureStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $updatedAt = [DateTime]::MinValue
        [void][DateTime]::TryParse([string]$failureState.UpdatedAt, [ref]$updatedAt)
        $bootTime = Get-StudioDisplaySystemBootTime
        if ($bootTime -gt [DateTime]::MinValue -and $updatedAt -gt [DateTime]::MinValue -and $updatedAt -lt $bootTime) {
            Write-AppLog "Ignoring stale Studio Display failure state from before current boot. UpdatedAt=$($updatedAt.ToString('o')) boot=$($bootTime.ToString('o'))."
            return $null
        }

        return $failureState
    }
    catch {
        Write-AppLog "Could not read Studio Display last failure state: $($_.Exception.Message)"
        return $null
    }
}

function Clear-StudioDisplayLastFailureState {
    param([string]$Reason = "automatic")

    try {
        if (Test-Path -LiteralPath $lastFailureStateFile) {
            Remove-Item -LiteralPath $lastFailureStateFile -Force -ErrorAction SilentlyContinue
            Write-AppLog "Cleared stale Studio Display last failure state for $Reason."
        }
    }
    catch {
        Write-AppLog "Could not clear Studio Display last failure state for $Reason`: $($_.Exception.Message)"
    }
}

function Save-StudioDisplayPhysicalReenumerationState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Event,
        [string]$Reason = "automatic"
    )

    try {
        $state = [ordered]@{
            Version = 1
            UpdatedAt = (Get-Date).ToString("o")
            Event = $Event
            Reason = $Reason
            DisplayTopologySignature = [string]$script:lastDisplayTopologySignature
        }

        $state |
            ConvertTo-Json -Depth 4 |
            Set-Content -LiteralPath $physicalReenumerationStateFile -Encoding ascii -ErrorAction Stop
        Write-AppLog "Recorded Studio Display physical re-enumeration marker. event=$Event reason=$Reason."
    }
    catch {
        Write-AppLog "Could not record Studio Display physical re-enumeration marker for $Reason`: $($_.Exception.Message)"
    }
}

function Test-StudioDisplayFailureNeedsPhysicalReenumeration {
    param([object]$FailureState)

    if (-not $FailureState) {
        return $false
    }

    $classification = [string]$FailureState.Classification
    return [bool](
        [bool]$FailureState.AppleUsbRebootRequired -or
        [bool]$FailureState.AppleUsbReferenceModeFailedStart -or
        $classification -match 'AppleUsbReferenceModeFailedStart|AppleUsbRebootRequired|RebootRequired'
    )
}

function Save-StudioDisplayAutomationMaintenanceState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string]$Detail = "",
        [object]$ResolutionState = $null,
        [object]$HdrState = $null,
        [object]$FailureState = $null
    )

    try {
        $state = [ordered]@{
            Version = 1
            UpdatedAt = (Get-Date).ToString("o")
            Stage = $Stage
            Action = $Action
            Detail = $Detail
            RequiresPhysicalReenumeration = [bool]$script:hdrGateRequiresPhysicalReenumeration
            HdrGateBlockedUntil = if ($script:hdrGateBlockedUntil -and $script:hdrGateBlockedUntil -gt [DateTime]::MinValue) { $script:hdrGateBlockedUntil.ToString("o") } else { $null }
            Resolution = if ($ResolutionState) {
                [ordered]@{
                    Known = [bool]$ResolutionState.Known
                    Current5K = [bool]$ResolutionState.HasCurrent5K
                    FiveK60Enumerated = [bool]$ResolutionState.Has5K60Enumerated
                    FiveK120Enumerated = [bool]$ResolutionState.Has5K120Enumerated
                }
            } else { $null }
            Hdr = if ($HdrState) {
                [ordered]@{
                    Known = [bool]$HdrState.Known
                    HdrSupported = [bool]$HdrState.HdrSupported
                    HdrUnsupported = [bool]$HdrState.HdrUnsupported
                    HdrActive = [bool]$HdrState.HdrActive
                    WcgActive = [bool]$HdrState.WcgActive
                }
            } else { $null }
            Failure = if ($FailureState) {
                [ordered]@{
                    UpdatedAt = [string]$FailureState.UpdatedAt
                    Classification = [string]$FailureState.Classification
                    AppleUsbReferenceModeFailedStart = [bool]$FailureState.AppleUsbReferenceModeFailedStart
                    AppleUsbRebootRequired = [bool]$FailureState.AppleUsbRebootRequired
                    RepairLog = [string]$FailureState.RepairLog
                }
            } else { $null }
            SuccessPrerequisites = @(
                "Studio Display evidence is present.",
                "Current desktop is 5120x2880 and 5120x2880@60 is enumerated.",
                "Windows reports HighDynamicRangeSupported=True before SET_HDR_STATE is attempted.",
                "HDR is active after the setter, not merely WCG/Advanced Color.",
                "Studio Display brightness HID readback succeeds.",
                "If Apple VID_05AC PID_1116 MI_08/MI_09 failed-start is paired with HdrSupported=False, wait for Thunderbolt/USB physical re-enumeration instead of repeating deep repair.",
                "If pnputil returns 3010 for the Apple USB composite/upstream parent, preserve 5K60/brightness and wait for reboot or full Thunderbolt/USB re-enumeration."
            )
        }

        $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $automationMaintenanceStateFile -Encoding ascii -ErrorAction Stop
    }
    catch {
        Write-AppLog "Could not save automation maintenance state: $($_.Exception.Message)"
    }
}

function Test-StudioDisplayConnected {
    try {
        $studioDisplay = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop |
            Where-Object {
                $friendlyName = if ($_.UserFriendlyName) { [string]::new([char[]]$_.UserFriendlyName).Trim([char]0) } else { "" }
                $_.InstanceName -match $studioDisplayMonitorPattern -or
                $friendlyName -match $studioDisplayMonitorPattern
            } |
            Select-Object -First 1

        if ($studioDisplay) {
            return $true
        }
    }
    catch {
        Write-AppLog "Studio Display WMI monitor check failed: $($_.Exception.Message)"
    }

    try {
        $studioDisplay = Get-CimInstance Win32_DesktopMonitor -ErrorAction Stop |
            Where-Object {
                $_.PNPDeviceID -match $studioDisplayMonitorPattern -or
                $_.Name -match $studioDisplayMonitorPattern
            } |
            Select-Object -First 1

        if ($studioDisplay) {
            return $true
        }
    }
    catch {
        Write-AppLog "Studio Display desktop monitor check failed: $($_.Exception.Message)"
    }

    if ($script:lastStudioDisplayPnpCheckAt -and
        ((Get-Date) - $script:lastStudioDisplayPnpCheckAt).TotalSeconds -lt $studioDisplayPnpCheckCooldownSeconds) {
        return $script:lastStudioDisplayPnpCheckResult
    }

    $script:lastStudioDisplayPnpCheckAt = Get-Date
    $script:lastStudioDisplayPnpCheckResult = $false

    try {
        $studioDisplay = Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object {
                $_.FriendlyName -match $studioDisplayUsbPattern -or
                $_.InstanceId -match $studioDisplayUsbPattern
            } |
            Select-Object -First 1

        $script:lastStudioDisplayPnpCheckResult = [bool]$studioDisplay
        return $script:lastStudioDisplayPnpCheckResult
    }
    catch {
        Write-AppLog "Studio Display PnP connection check failed: $($_.Exception.Message)"
        try {
            $pnpEntities = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
                Where-Object {
                    $_.Name -match $studioDisplayUsbPattern -or
                    $_.DeviceID -match $studioDisplayUsbPattern
                } |
                Select-Object -First 1

            $script:lastStudioDisplayPnpCheckResult = [bool]$pnpEntities
            return $script:lastStudioDisplayPnpCheckResult
        }
        catch {
            Write-AppLog "Studio Display CIM PnP connection check failed: $($_.Exception.Message)"
            return $false
        }
    }
}

function Test-ForegroundFullscreenWindow {
    try {
        $handle = [StudioDisplayUser32]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero -or -not [StudioDisplayUser32]::IsWindowVisible($handle)) {
            return $false
        }

        $rect = New-Object StudioDisplayUser32+RECT
        if (-not [StudioDisplayUser32]::GetWindowRect($handle, [ref]$rect)) {
            return $false
        }

        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $windowWidth = $rect.Right - $rect.Left
        $windowHeight = $rect.Bottom - $rect.Top
        $tolerance = 3

        return (
            [Math]::Abs($rect.Left - $screen.Left) -le $tolerance -and
            [Math]::Abs($rect.Top - $screen.Top) -le $tolerance -and
            [Math]::Abs($windowWidth - $screen.Width) -le $tolerance -and
            [Math]::Abs($windowHeight - $screen.Height) -le $tolerance
        )
    }
    catch {
        Write-AppLog "Fullscreen foreground check failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-DisplayTopologySignature {
    try {
        $screens = @([System.Windows.Forms.Screen]::AllScreens)
        if (-not $screens) {
            return "screens=0"
        }

        $screenText = $screens |
            Sort-Object DeviceName |
            ForEach-Object {
                "{0}|primary={1}|bounds={2}|work={3}|bpp={4}" -f $_.DeviceName, $_.Primary, $_.Bounds.ToString(), $_.WorkingArea.ToString(), $_.BitsPerPixel
            }

        return "screens=$($screens.Count); " + ($screenText -join "; ")
    }
    catch {
        Write-AppLog "Display topology signature check failed: $($_.Exception.Message)"
        return "unknown"
    }
}

function Get-DisplayRepairBlockReason {
    if ($displayRepairBlockedProcessNames.Count -gt 0) {
        $blockingProcess = Get-Process -Name $displayRepairBlockedProcessNames -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($blockingProcess) {
            return "game process '$($blockingProcess.ProcessName)' is running"
        }
    }

    if (Test-ForegroundFullscreenWindow) {
        return "a fullscreen foreground window is active"
    }

    return $null
}

function Invoke-StudioDisplayIntegratedRepair {
    param(
        [string]$Reason = "manual",
        [switch]$Automatic,
        [switch]$AllowForegroundCriticalRepair
    )

    $script:integratedRepairAttachedToExisting = $false

    if (-not (Test-Path $integratedRepairScript)) {
        Write-AppLog "Skipped integrated Studio Display repair for $Reason because repair script is missing."
        return $false
    }

    $blockReason = Get-DisplayRepairBlockReason
    if ($blockReason -and -not $AllowForegroundCriticalRepair) {
        Write-AppLog "Deferred integrated Studio Display repair for $Reason because $blockReason."
        return $false
    }
    elseif ($blockReason -and $AllowForegroundCriticalRepair) {
        Write-AppLog "Foreground repair block '$blockReason' is being bypassed for $Reason because this is a hot-plug critical recovery and 5K/HDR is not yet stable."
    }

    try {
        if ($Automatic) {
            $existingTaskState = Get-StudioDisplayAutoRepairTaskState
            if ($existingTaskState -eq "Running") {
                $now = Get-Date
                Set-StudioDisplayIntegratedRepairActive -StartedAt $now -Attached
                Write-AppLog "Reattached to already-running scheduled integrated Studio Display auto repair for $Reason instead of submitting another task run."
                return $true
            }

            if (Test-Path -LiteralPath $schtasksExe) {
                $previousErrorActionPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    $taskOutput = & $schtasksExe /Run /TN $autoRepairTaskName 2>&1
                    $taskExitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $previousErrorActionPreference
                }

                if ($taskExitCode -eq 0) {
                    $script:integratedRepairAttachedToExisting = $false
                    Write-AppLog "Started scheduled integrated Studio Display auto repair for $Reason through task '$autoRepairTaskName'."
                    return $true
                }

                Write-AppLog "Scheduled integrated Studio Display auto repair task '$autoRepairTaskName' could not be started for $Reason. ExitCode=$taskExitCode Output=$($taskOutput -join ' ')"
            }
            else {
                Write-AppLog "Scheduled integrated Studio Display auto repair could not start because schtasks.exe is missing: $schtasksExe"
            }

            $promptLaunched = Invoke-StudioDisplayAutoRepairTaskRegistrationPrompt -Reason $Reason
            $backoffSeconds = if ($promptLaunched) { 45 } else { $integratedRepairMissingTaskBackoffSeconds }
            $script:integratedRepairUnavailableUntil = (Get-Date).AddSeconds($backoffSeconds)
            $nextAction = if ($promptLaunched) { "UAC prompt launched; will retry after it has time to register" } else { "no UAC prompt launched" }
            Write-AppLog "Automatic integrated Studio Display repair for $Reason was not started because the elevated scheduled task is not registered. $nextAction. Backing off until $($script:integratedRepairUnavailableUntil.ToString('HH:mm:ss'))."
            return $false
        }

        $repairHostScript = if (Test-Path $repairProgressScript) { $repairProgressScript } else { $integratedRepairScript }
        $repairArgs = @(
            "-Sta",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $repairHostScript,
            "-Apply",
            "-RestartAppleUsb4Router",
            "-Reason", "`"$Reason`""
        )
        if (-not (Test-Path $repairProgressScript)) {
            $repairArgs = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $integratedRepairScript,
                "-Apply",
                "-RestartAppleUsb4Router"
            )
            $startParams = @{
                FilePath = $powershellExe
                WorkingDirectory = $installRoot
                WindowStyle = "Hidden"
                ArgumentList = $repairArgs
            }
            if (-not (Test-IsAdministrator)) {
                $startParams.Verb = "RunAs"
            }
            Start-Process @startParams
        }
        else {
            $startParams = @{
                FilePath = $powershellExe
                WorkingDirectory = $installRoot
                ArgumentList = $repairArgs
            }
            if (-not (Test-IsAdministrator)) {
                $startParams.Verb = "RunAs"
            }
            Start-Process @startParams
        }

        Write-AppLog "Started integrated Studio Display repair for $Reason. Active MS_0001 sessions use the Boot Camp-style monitor identity as the single default HDR pipeline; Generic/Digital Flat Panel fallback is diagnostic-only."
        return $true
    }
    catch {
        Write-AppLog "Integrated Studio Display repair for $Reason failed: $($_.Exception.Message)"
        return $false
    }
}

function Set-StudioDisplayIntegratedRepairActive {
    param(
        [DateTime]$StartedAt,
        [switch]$Attached
    )

    $script:integratedRepairInFlight = $true
    $script:pendingHdrRepair = $true
    $script:integratedRepairAttachedToExisting = [bool]$Attached

    if ($Attached) {
        if ($script:lastIntegratedRepairStartedAt -eq [DateTime]::MinValue) {
            $script:lastIntegratedRepairStartedAt = $StartedAt
        }
        if ($script:lastIntegratedRepairAt -eq [DateTime]::MinValue) {
            $script:lastIntegratedRepairAt = $StartedAt
        }
        return
    }

    $script:lastIntegratedRepairAt = $StartedAt
    $script:lastIntegratedRepairStartedAt = $StartedAt
    $script:lastIntegratedRepairWaitLogAt = [DateTime]::MinValue
}

function Set-StudioDisplayIntegratedRepairIdle {
    param(
        [switch]$KeepPendingHdr
    )

    $script:integratedRepairInFlight = $false
    $script:integratedRepairAttachedToExisting = $false
    if ($KeepPendingHdr) {
        $script:pendingHdrRepair = $true
    }
    else {
        $script:pendingHdrRepair = $false
    }
}

function Invoke-StudioDisplayDeepIntegratedRepair {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskReason,
        [Parameter(Mandatory = $true)]
        [string]$LogDetail,
        [switch]$Automatic,
        [switch]$AllowForegroundCriticalRepair
    )

    $now = Get-Date
    $started = Invoke-StudioDisplayIntegratedRepair -Reason $TaskReason -Automatic:$Automatic -AllowForegroundCriticalRepair:$AllowForegroundCriticalRepair
    if ($started) {
        Set-StudioDisplayIntegratedRepairActive -StartedAt $now -Attached:$script:integratedRepairAttachedToExisting
        $repairAction = if ($script:integratedRepairAttachedToExisting) { "Attached to the already-running deep integrated display pipeline restore" } else { "Started deep integrated display pipeline restore" }
        Write-AppLog "$repairAction for $TaskReason. $LogDetail"
    }
    else {
        $script:lastIntegratedRepairAt = $now
        $script:pendingHdrRepair = $true
        $script:integratedRepairAttachedToExisting = $false
    }

    return $started
}

function Get-StudioDisplayResolutionRuntimeState {
    if (-not (Test-Path $resolutionLadderScript)) {
        Write-AppLog "Resolution ladder probe skipped because script is missing."
        return [pscustomobject]@{
            Known = $false
            HasCurrent5K = $false
            Has5K60Enumerated = $false
            Has5K120Enumerated = $false
            RawText = ""
        }
    }

    try {
        $probeOutput = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $resolutionLadderScript 2>&1)
        $probeExitCode = $LASTEXITCODE
        $probeText = ($probeOutput -join "`n")
        if ($probeExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probeText)) {
            Write-AppLog "Resolution ladder probe returned exit code $probeExitCode. $probeText"
            return [pscustomobject]@{
                Known = $false
                HasCurrent5K = $false
                Has5K60Enumerated = $false
                Has5K120Enumerated = $false
                RawText = $probeText
            }
        }

        return [pscustomobject]@{
            Known = $true
            HasCurrent5K = [bool]($probeText -match '(?m)^Current mode:[^\S\r\n]+5120x2880@')
            Has5K60Enumerated = [bool](
                $probeText -match '(?m)^5K 60Hz legacy Studio Display fallback[^\r\n]*[^\S\r\n]+5120[^\S\r\n]+2880[^\S\r\n]+60[^\S\r\n]+True(?:[^\S\r\n]|$)' -or
                $probeText -match '(?m)^Best enumerated mode:[^\S\r\n]+5120x2880@60Hz[^\S\r\n]*$'
            )
            Has5K120Enumerated = [bool](
                $probeText -match '(?m)^5K 120Hz native XDR target[^\r\n]*[^\S\r\n]+5120[^\S\r\n]+2880[^\S\r\n]+120[^\S\r\n]+True(?:[^\S\r\n]|$)' -or
                $probeText -match '(?m)^Best enumerated mode:[^\S\r\n]+5120x2880@120Hz[^\S\r\n]*$'
            )
            RawText = $probeText
        }
    }
    catch {
        Write-AppLog "Resolution ladder probe failed: $($_.Exception.Message)"
        return [pscustomobject]@{
            Known = $false
            HasCurrent5K = $false
            Has5K60Enumerated = $false
            Has5K120Enumerated = $false
            RawText = ""
        }
    }
}

function Get-StudioDisplayHdrRuntimeState {
    if (-not (Test-Path $advancedColorScript)) {
        Write-AppLog "HDR runtime probe skipped because advanced color script is missing."
        return [pscustomobject]@{
            Known = $false
            HdrActive = $false
            HdrSupported = $false
            HdrUnsupported = $false
            WcgActive = $false
            RawText = ""
        }
    }

    try {
        $probeOutput = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $advancedColorScript -SkipDxDiagFallback 2>&1)
        $probeExitCode = $LASTEXITCODE
        $probeText = ($probeOutput -join "`n")
        if ($probeExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($probeText)) {
            Write-AppLog "HDR runtime probe returned exit code $probeExitCode. $probeText"
            return [pscustomobject]@{
                Known = $false
                HdrActive = $false
                HdrSupported = $false
                HdrUnsupported = $false
                WcgActive = $false
                RawText = $probeText
            }
        }

        return [pscustomobject]@{
            Known = $true
            HdrActive = [bool](
                $probeText -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR[^\S\r\n]*$' -or
                $probeText -match '(?m)^[^\S\r\n]*HighDynamicRangeUserEnabled[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$'
            )
            HdrSupported = [bool]($probeText -match '(?m)^[^\S\r\n]*HighDynamicRangeSupported[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$')
            HdrUnsupported = [bool]($probeText -match '(?m)^[^\S\r\n]*HighDynamicRangeSupported[^\S\r\n]*:[^\S\r\n]*False[^\S\r\n]*$')
            WcgActive = [bool](
                $probeText -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG[^\S\r\n]*$' -or
                $probeText -match '(?m)^[^\S\r\n]*WideColorUserEnabled[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$'
            )
            RawText = $probeText
        }
    }
    catch {
        Write-AppLog "HDR runtime probe failed: $($_.Exception.Message)"
        return [pscustomobject]@{
            Known = $false
            HdrActive = $false
            HdrSupported = $false
            HdrUnsupported = $false
            WcgActive = $false
            RawText = ""
        }
    }
}

function Get-StudioDisplayAutoRepairTaskState {
    try {
        $task = Get-ScheduledTask -TaskName $autoRepairTaskName -ErrorAction Stop
        return [string]$task.State
    }
    catch {
        if (-not (Test-Path -LiteralPath $schtasksExe)) {
            return ""
        }

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $queryOutput = @(& $schtasksExe /Query /TN $autoRepairTaskName /FO LIST 2>&1)
            if ($LASTEXITCODE -ne 0) {
                return ""
            }

            $queryText = ($queryOutput -join "`n")
            if ($queryText -match '(?im)^\s*(Status|状态)\s*:\s*(.+?)\s*$') {
                $statusText = $Matches[2].Trim()
                if ($statusText -match 'Running|正在运行') {
                    return "Running"
                }
                if ($statusText -match 'Ready|就绪') {
                    return "Ready"
                }
                if ($statusText -match 'Disabled|已禁用') {
                    return "Disabled"
                }
                return $statusText
            }
        }
        catch {
            return ""
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        return ""
    }
}

function Test-StudioDisplayIntegratedRepairProcessRunning {
    try {
        $repairScriptNames = @(
            "Invoke-StudioDisplayAutoRepair.ps1",
            "Repair-StudioDisplayIntegrated.ps1",
            "Show-StudioDisplayRepairProgress.ps1",
            "Refresh-StudioDisplayXdrLink.ps1",
            "Repair-StudioDisplayExternalMode.ps1"
        )

        $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop)
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            if ([string]::IsNullOrWhiteSpace($commandLine)) {
                continue
            }

            foreach ($scriptName in $repairScriptNames) {
                if ($commandLine.IndexOf($scriptName, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    return $true
                }
            }
        }
    }
    catch {
        Write-AppLog "Could not inspect integrated repair process list: $($_.Exception.Message)"
    }

    return $false
}

function Invoke-StudioDisplayAutoRepairTaskRegistrationPrompt {
    param(
        [string]$Reason = "automatic"
    )

    $now = Get-Date
    if (($now - $script:lastAutoRepairTaskRegistrationPromptAt).TotalSeconds -lt $autoRepairTaskRegistrationPromptBackoffSeconds) {
        return $false
    }

    if (-not (Test-Path -LiteralPath $autoRepairTaskRegistrarScript)) {
        Write-AppLog "Cannot launch auto repair task registration prompt for $Reason because registrar script is missing: $autoRepairTaskRegistrarScript"
        return $false
    }

    $script:lastAutoRepairTaskRegistrationPromptAt = $now

    try {
        Write-AppLog "Requesting Windows UAC prompt to register elevated auto repair task for $Reason."
        Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -Verb RunAs -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$autoRepairTaskRegistrarScript`"",
            "-TaskName", "`"$autoRepairTaskName`"",
            "-AppName", "`"$appName`"",
            "-InstallRoot", "`"$installRoot`"",
            "-Quiet"
        )

        Write-AppLog "Launched UAC prompt to register elevated auto repair task for $Reason. Approve it once to allow future Thunderbolt hot-plug HDR/5K repairs to run automatically."
        return $true
    }
    catch {
        Write-AppLog "Auto repair task registration prompt for $Reason was not completed: $($_.Exception.Message)"
        return $false
    }
}

function Test-StudioDisplayPipelineStable {
    param(
        [object]$ResolutionState,
        [object]$HdrState
    )

    if (-not $ResolutionState) {
        $ResolutionState = Get-StudioDisplayResolutionRuntimeState
    }

    if (-not $HdrState) {
        $HdrState = Get-StudioDisplayHdrRuntimeState
    }

    return [bool](
        $ResolutionState.Known -and
        $ResolutionState.HasCurrent5K -and
        $ResolutionState.Has5K60Enumerated -and
        $HdrState.Known -and
        $HdrState.HdrActive
    )
}

function Test-StudioDisplayBrightnessHidReady {
    if (-not (Test-Path $hidHelperScript)) {
        Write-AppLog "Brightness HID preflight skipped because helper script is missing."
        return $false
    }

    try {
        $probeOutput = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $hidHelperScript -GetPercent 2>&1)
        $probeText = ($probeOutput -join "`n")
        return [bool]($LASTEXITCODE -eq 0 -and $probeText -match '(?m)^\s*\d+\s*$')
    }
    catch {
        Write-AppLog "Brightness HID preflight failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-StudioDisplayOneClickRepairPreflight {
    $connected = Test-StudioDisplayConnected
    $mirrorRunning = Test-BrightnessWorkerAvailable -Label "SystemBrightnessMirror" -ScriptPath $mirrorScript -PidPath $mirrorPidFile -MutexName $mirrorMutexName
    $bridgeRunning = Test-BrightnessWorkerAvailable -Label "BrightnessKeyBridge" -ScriptPath $brightnessBridgeScript -PidPath $brightnessBridgePidFile -MutexName $brightnessBridgeMutexName
    $brightnessWorkersReady = [bool]($mirrorRunning -and $bridgeRunning)
    $brightnessHidReady = $false
    $resolutionState = [pscustomobject]@{
        Known = $false
        HasCurrent5K = $false
        Has5K60Enumerated = $false
        Has5K120Enumerated = $false
    }
    $hdrState = [pscustomobject]@{
        Known = $false
        HdrActive = $false
        HdrSupported = $false
        HdrUnsupported = $false
        WcgActive = $false
    }
    $issues = New-Object System.Collections.Generic.List[string]

    if (-not $connected) {
        $issues.Add("未检测到 Studio Display XDR") | Out-Null
    }
    else {
        $resolutionState = Get-StudioDisplayResolutionRuntimeState
        $hdrState = Get-StudioDisplayHdrRuntimeState
        $brightnessHidReady = Test-StudioDisplayBrightnessHidReady

        if (-not $resolutionState.Known) {
            $issues.Add("无法读取 5K/刷新率模式表") | Out-Null
        }
        else {
            if (-not $resolutionState.HasCurrent5K) {
                $issues.Add("当前桌面不是 5120x2880") | Out-Null
            }
            if (-not $resolutionState.Has5K60Enumerated) {
                $issues.Add("Windows 模式表未枚举 5K60") | Out-Null
            }
        }

        if (-not $hdrState.Known) {
            $issues.Add("无法读取 Windows HDR/Advanced Color 状态") | Out-Null
        }
        elseif (-not $hdrState.HdrActive) {
            if ($hdrState.HdrUnsupported) {
                $issues.Add("Windows HDR gate=False，当前只到 WCG/Advanced Color") | Out-Null
            }
            else {
                $issues.Add("HDR 未处于 active 状态") | Out-Null
            }
        }

        if (-not $brightnessWorkersReady) {
            $issues.Add("亮度镜像或亮度按键桥未完整运行") | Out-Null
        }
        if (-not $brightnessHidReady) {
            $issues.Add("Studio Display 硬件亮度 HID 读取失败") | Out-Null
        }
    }

    $displayReady = [bool]($connected -and $resolutionState.Known -and $resolutionState.HasCurrent5K -and $resolutionState.Has5K60Enumerated)
    $hdrReady = [bool]($connected -and $hdrState.Known -and $hdrState.HdrActive)
    $brightnessReady = [bool]($connected -and $brightnessWorkersReady -and $brightnessHidReady)
    $needsBrightnessOnly = [bool]($connected -and $displayReady -and $hdrReady -and -not $brightnessWorkersReady -and $brightnessHidReady)
    $needsDeepRepair = [bool]($connected -and (-not $displayReady -or -not $hdrReady -or -not $brightnessHidReady))
    $fullyReady = [bool]($connected -and $displayReady -and $hdrReady -and $brightnessReady)
    $summary = if ($issues.Count -gt 0) { ($issues -join "；") } else { "5K60、HDR active、亮度 HID 和亮度服务均满足" }

    return [pscustomobject]@{
        Connected = $connected
        ResolutionState = $resolutionState
        HdrState = $hdrState
        MirrorRunning = $mirrorRunning
        BridgeRunning = $bridgeRunning
        BrightnessWorkersReady = $brightnessWorkersReady
        BrightnessHidReady = $brightnessHidReady
        DisplayReady = $displayReady
        HdrReady = $hdrReady
        BrightnessReady = $brightnessReady
        NeedsBrightnessOnly = $needsBrightnessOnly
        NeedsDeepRepair = $needsDeepRepair
        NeedsAdministrator = [bool]($needsDeepRepair -and -not (Test-IsAdministrator))
        FullyReady = $fullyReady
        Issues = @($issues.ToArray())
        Summary = $summary
    }
}

function Test-StudioDisplayHdrGateBlocked {
    param(
        [object]$ResolutionState,
        [object]$HdrState
    )

    return [bool](
        $ResolutionState -and
        $ResolutionState.Known -and
        $ResolutionState.HasCurrent5K -and
        $ResolutionState.Has5K60Enumerated -and
        $HdrState -and
        $HdrState.Known -and
        $HdrState.HdrUnsupported -and
        -not $HdrState.HdrActive
    )
}

function Test-StudioDisplayEdidHasHdrStaticMetadata {
    param([AllowNull()][byte[]]$Edid)

    if (-not $Edid -or $Edid.Length -lt 256) {
        return $false
    }

    for ($index = 128; $index -lt ($Edid.Length - 1); $index++) {
        $tagAndLength = [int]$Edid[$index]
        if (($tagAndLength -band 0xE0) -eq 0xE0 -and [int]$Edid[$index + 1] -eq 0x06) {
            return $true
        }
    }

    return $false
}

function Test-StudioDisplayBootCampFallbackRefreshNeeded {
    $activeMs0001Ids = @()
    try {
        $activeMs0001Ids = @(
            Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop |
                Where-Object { $_.Active -and $_.InstanceName -match '^DISPLAY\\MS_0001\\' } |
                ForEach-Object { ([string]$_.InstanceName) -replace '_\d+$', '' }
        )
        if (-not $activeMs0001Ids) {
            return $false
        }
    }
    catch {
        Write-AppLog "Boot Camp-style fallback backoff bypass check could not read active monitor identity: $($_.Exception.Message)"
        return $false
    }

    $driverPackagePresent = $false
    try {
        $driverStoreText = ((& pnputil.exe /enum-drivers /class Monitor 2>&1) -join "`n")
        $driverPackagePresent = [bool]($driverStoreText -match 'StudioDisplayXdrBootCampStyleMonitor|StudioDIsplayWithWindows')
    }
    catch {
        Write-AppLog "Boot Camp-style fallback backoff bypass check could not read monitor driver store: $($_.Exception.Message)"
    }

    $usesMicrosoftMonitorInf = $false
    $boundCustomMonitorInf = $false
    $currentDriverBindings = @()
    foreach ($instanceId in $activeMs0001Ids) {
        try {
            $bindingText = ((& pnputil.exe /enum-devices /instanceid $instanceId /drivers 2>&1) -join "`n")
            $currentDriverName = $null
            if ($bindingText -match '(?m)^Driver Name:\s*([^\r\n]+?)\s*$') {
                $currentDriverName = $Matches[1].Trim()
                $currentDriverBindings += "$instanceId=$currentDriverName"
            }

            $currentDriverIsCustom = [bool](
                $currentDriverName -and
                $currentDriverName -match '^oem\d+\.inf$' -and
                (
                    $bindingText -match '(?m)^Manufacturer Name:\s*StudioDIsplayWithWindows\s*$' -or
                    $bindingText -match '(?m)^Device Description:\s*Studio Display XDR Boot Camp Style Monitor\s*$'
                )
            )

            if ($currentDriverName -ieq 'monitor.inf') {
                $usesMicrosoftMonitorInf = $true
            }
            if ($currentDriverIsCustom) {
                $boundCustomMonitorInf = $true
            }
        }
        catch {
            Write-AppLog "Boot Camp-style fallback backoff bypass check could not read monitor binding for $instanceId`: $($_.Exception.Message)"
        }
    }

    $edidBytes = 0
    $hasHdrMetadata = $false
    $basePath = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\MS_0001"
    try {
        if (Test-Path -LiteralPath $basePath) {
            foreach ($instanceKey in Get-ChildItem -LiteralPath $basePath -ErrorAction Stop) {
                $deviceParamsPath = Join-Path $instanceKey.PSPath "Device Parameters"
                try {
                    $edid = [byte[]](Get-ItemProperty -LiteralPath $deviceParamsPath -Name EDID -ErrorAction Stop).EDID
                    $edidBytes = [Math]::Max($edidBytes, $edid.Length)
                    if (Test-StudioDisplayEdidHasHdrStaticMetadata -Edid $edid) {
                        $hasHdrMetadata = $true
                    }
                }
                catch {
                    continue
                }
            }
        }
    }
    catch {
        Write-AppLog "Boot Camp-style fallback backoff bypass check could not read MS_0001 EDID cache: $($_.Exception.Message)"
    }

    $needsRefresh = [bool](
        -not $driverPackagePresent -or
        -not $boundCustomMonitorInf -or
        $usesMicrosoftMonitorInf -or
        $edidBytes -le 128 -or
        -not $hasHdrMetadata
    )
    if ($needsRefresh) {
        Write-AppLog "Boot Camp-style monitor identity refresh is needed on active MS_0001. driverPackagePresent=$driverPackagePresent, boundCustomMonitorInf=$boundCustomMonitorInf, usesMicrosoftMonitorInf=$usesMicrosoftMonitorInf, currentDrivers=$($currentDriverBindings -join ';'), edidBytes=$edidBytes, hdrMetadata=$hasHdrMetadata."
    }

    return $needsRefresh
}

function Save-StudioDisplayHdrGateBlockState {
    param(
        [string]$Reason = "automatic"
    )

    try {
        $failureState = Get-StudioDisplayLastFailureState
        $state = [pscustomobject]@{
            Version = 1
            BlockedUntil = $script:hdrGateBlockedUntil.ToString("o")
            Count = [int]$script:hdrGateBlockedCount
            RequiresPhysicalReenumeration = [bool]$script:hdrGateRequiresPhysicalReenumeration
            AppleUsbRebootRequired = if ($failureState) { [bool]$failureState.AppleUsbRebootRequired } else { $false }
            Reason = $Reason
            UpdatedAt = (Get-Date).ToString("o")
        }
        $state | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $hdrGateBlockStateFile -Encoding ascii
    }
    catch {
        Write-AppLog "Could not persist HDR gate blocked state for $Reason`: $($_.Exception.Message)"
    }
}

function Clear-StudioDisplayHdrGateBlockState {
    param(
        [string]$Reason = "automatic"
    )

    try {
        if (Test-Path -LiteralPath $hdrGateBlockStateFile) {
            Remove-Item -LiteralPath $hdrGateBlockStateFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-AppLog "Could not clear HDR gate blocked state for $Reason`: $($_.Exception.Message)"
    }
}

function Restore-StudioDisplayHdrGateBlockState {
    param(
        [string]$Reason = "automatic"
    )

    if (-not (Test-Path -LiteralPath $hdrGateBlockStateFile)) {
        return
    }

    try {
        $savedState = Get-Content -LiteralPath $hdrGateBlockStateFile -Raw | ConvertFrom-Json
        $blockedUntil = [DateTime]::Parse([string]$savedState.BlockedUntil)
        $now = Get-Date
        $requiresPhysicalReenumeration = [bool]$savedState.RequiresPhysicalReenumeration
        $updatedAt = [DateTime]::MinValue
        [void][DateTime]::TryParse([string]$savedState.UpdatedAt, [ref]$updatedAt)
        $bootTime = Get-StudioDisplaySystemBootTime
        if ($requiresPhysicalReenumeration -and $bootTime -gt [DateTime]::MinValue -and $updatedAt -gt [DateTime]::MinValue -and $updatedAt -lt $bootTime) {
            Clear-StudioDisplayHdrGateBlockState -Reason "$Reason stale after reboot"
            Write-AppLog "Cleared persisted HDR physical re-enumeration gate for $Reason because the machine has rebooted since it was recorded."
            return
        }

        if (-not $requiresPhysicalReenumeration -and $blockedUntil -le $now) {
            Clear-StudioDisplayHdrGateBlockState -Reason "$Reason expired"
            return
        }

        $script:hdrGateBlockedUntil = $blockedUntil
        $script:hdrGateBlockedCount = [Math]::Min($hdrGateBlockedRetryLimit, [Math]::Max(1, [int]$savedState.Count))
        $script:hdrGateRequiresPhysicalReenumeration = $requiresPhysicalReenumeration
        $script:lastHdrGateBlockedLogAt = $now
        $script:pendingHdrRepair = $true
        $gateMode = if ([bool]$savedState.AppleUsbRebootRequired) { "Apple USB reboot required" } elseif ($script:hdrGateRequiresPhysicalReenumeration) { "physical re-enumeration required" } else { "time backoff" }
        Write-AppLog "Restored persisted HDR gate backoff for $Reason. mode=$gateMode attempt=$($script:hdrGateBlockedCount)/$hdrGateBlockedRetryLimit until=$($script:hdrGateBlockedUntil.ToString('HH:mm:ss')) savedReason=$($savedState.Reason)."
    }
    catch {
        Clear-StudioDisplayHdrGateBlockState -Reason "$Reason unreadable"
        Write-AppLog "Ignored unreadable HDR gate blocked state for $Reason`: $($_.Exception.Message)"
    }
}

function Reset-StudioDisplayHdrGateBlock {
    param(
        [string]$Reason = "automatic"
    )

    $now = Get-Date
    $hadBlock = [bool](
        $script:hdrGateBlockedCount -gt 0 -or
        ($script:hdrGateBlockedUntil -and $now -lt $script:hdrGateBlockedUntil)
    )

    $script:hdrGateBlockedUntil = [DateTime]::MinValue
    $script:hdrGateBlockedCount = 0
    $script:hdrGateRequiresPhysicalReenumeration = $false
    $script:lastHdrGateBlockedLogAt = [DateTime]::MinValue
    Clear-StudioDisplayHdrGateBlockState -Reason $Reason

    if ($hadBlock) {
        Write-AppLog "Cleared HDR gate blocked backoff for $Reason."
    }
}

function Set-StudioDisplayHdrGateBlockedBackoff {
    param(
        [string]$Reason = "automatic",
        [object]$ResolutionState,
        [object]$HdrState,
        [switch]$IncrementAttempt
    )

    $now = Get-Date
    if ($IncrementAttempt) {
        $script:hdrGateBlockedCount = [Math]::Min($hdrGateBlockedRetryLimit, [Math]::Max(1, $script:hdrGateBlockedCount + 1))
    }
    elseif ($script:hdrGateBlockedCount -lt 1) {
        $script:hdrGateBlockedCount = 1
    }
    elseif ($script:hdrGateBlockedCount -gt $hdrGateBlockedRetryLimit) {
        $script:hdrGateBlockedCount = $hdrGateBlockedRetryLimit
    }

    $failureState = Get-StudioDisplayLastFailureState
    $script:hdrGateRequiresPhysicalReenumeration = Test-StudioDisplayFailureNeedsPhysicalReenumeration -FailureState $failureState
    if ($script:hdrGateRequiresPhysicalReenumeration) {
        $script:hdrGateBlockedUntil = $now.AddHours($hdrGatePhysicalReenumWaitHours)
    }
    else {
        $script:hdrGateBlockedUntil = $now.AddSeconds($hdrGateBlockedBackoffSeconds)
    }
    $script:pendingHdrRepair = $true
    $script:lastHdrGateBlockedLogAt = $now
    Save-StudioDisplayHdrGateBlockState -Reason $Reason

    $resolutionText = if ($ResolutionState -and $ResolutionState.Known) {
        "current5K=$($ResolutionState.HasCurrent5K), 5K60Enumerated=$($ResolutionState.Has5K60Enumerated)"
    }
    else {
        "resolution state unknown"
    }
    $hdrText = if ($HdrState -and $HdrState.Known) {
        "hdrSupported=$($HdrState.HdrSupported), hdrUnsupported=$($HdrState.HdrUnsupported), hdrActive=$($HdrState.HdrActive), wcgActive=$($HdrState.WcgActive)"
    }
    else {
        "HDR state unknown"
    }

    if ($script:hdrGateRequiresPhysicalReenumeration) {
        $failureText = if ($failureState) { "lastFailure=$($failureState.Classification)" } else { "lastFailure=unknown" }
        $physicalGateDetail = if ($failureState -and [bool]$failureState.AppleUsbRebootRequired) {
            "Stable 5K60 but HighDynamicRangeSupported=False after Apple USB parent restart returned pnputil 3010/reboot-required."
        }
        else {
            "Stable 5K60 but HighDynamicRangeSupported=False with Apple USB MI_08/MI_09 failed-start evidence."
        }
        Write-AppLog "HDR gate blocked for $Reason while 5K60 is stable. $resolutionText; $hdrText; $failureText. Apple USB control-interface evidence says this round needs reboot/resume or fresh Thunderbolt/USB physical re-enumeration before another deep repair. Holding automatic deep repair instead of looping."
        Save-StudioDisplayAutomationMaintenanceState -Stage "HdrGateRequiresPhysicalReenumeration" -Action "HoldDeepRepair" -Detail $physicalGateDetail -ResolutionState $ResolutionState -HdrState $HdrState -FailureState $failureState
    }
    else {
        Write-AppLog "HDR gate blocked for $Reason while 5K60 is stable. $resolutionText; $hdrText. Automatic deep repair attempt $($script:hdrGateBlockedCount)/$hdrGateBlockedRetryLimit did not make Windows expose HighDynamicRangeSupported=True. Backing off until $($script:hdrGateBlockedUntil.ToString('HH:mm:ss')) instead of looping; a fresh Thunderbolt reconnect, power resume, or successful HDR probe will clear this gate."
        Save-StudioDisplayAutomationMaintenanceState -Stage "HdrGateTimedBackoff" -Action "DeferDeepRepair" -Detail "Stable 5K60 but HighDynamicRangeSupported=False; short HDR gate backoff is active." -ResolutionState $ResolutionState -HdrState $HdrState -FailureState $failureState
    }
}

function Test-StudioDisplayResolutionModeTableBlocked {
    param(
        [object]$ResolutionState
    )

    return [bool](
        $ResolutionState -and
        $ResolutionState.Known -and
        (-not $ResolutionState.HasCurrent5K -or -not $ResolutionState.Has5K60Enumerated)
    )
}

function Test-StudioDisplayModeTableStaleButVisible {
    param(
        [object]$ResolutionState
    )

    return [bool](
        $ResolutionState -and
        $ResolutionState.Known -and
        $ResolutionState.HasCurrent5K -and
        -not $ResolutionState.Has5K60Enumerated
    )
}

function Get-StudioDisplayResolutionModeTableBackoffSeconds {
    param(
        [object]$ResolutionState
    )

    if (Test-StudioDisplayModeTableStaleButVisible -ResolutionState $ResolutionState) {
        return $resolutionModeTableStaleBackoffSeconds
    }

    return $resolutionModeTableBlockedBackoffSeconds
}

function Get-StudioDisplayResolutionModeTableRetryLimit {
    param(
        [object]$ResolutionState
    )

    if (Test-StudioDisplayModeTableStaleButVisible -ResolutionState $ResolutionState) {
        return $resolutionModeTableStaleRetryLimit
    }

    return $resolutionModeTableBlockedRetryLimit
}

function Save-StudioDisplayResolutionModeTableBlockState {
    param(
        [string]$Reason = "automatic"
    )

    try {
        $state = [pscustomobject]@{
            Version = 1
            BlockedUntil = $script:resolutionModeTableBlockedUntil.ToString("o")
            Count = [int]$script:resolutionModeTableBlockedCount
            Reason = $Reason
            UpdatedAt = (Get-Date).ToString("o")
        }
        $state | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $resolutionModeTableBlockStateFile -Encoding ascii
    }
    catch {
        Write-AppLog "Could not persist 5K mode-table blocked state for $Reason`: $($_.Exception.Message)"
    }
}

function Clear-StudioDisplayResolutionModeTableBlockState {
    param(
        [string]$Reason = "automatic"
    )

    try {
        if (Test-Path -LiteralPath $resolutionModeTableBlockStateFile) {
            Remove-Item -LiteralPath $resolutionModeTableBlockStateFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-AppLog "Could not clear 5K mode-table blocked state for $Reason`: $($_.Exception.Message)"
    }
}

function Restore-StudioDisplayResolutionModeTableBlockState {
    param(
        [string]$Reason = "automatic"
    )

    if (-not (Test-Path -LiteralPath $resolutionModeTableBlockStateFile)) {
        return
    }

    try {
        $savedState = Get-Content -LiteralPath $resolutionModeTableBlockStateFile -Raw | ConvertFrom-Json
        $blockedUntil = [DateTime]::Parse([string]$savedState.BlockedUntil)
        $now = Get-Date
        if ($blockedUntil -le $now) {
            Clear-StudioDisplayResolutionModeTableBlockState -Reason "$Reason expired"
            return
        }

        $script:resolutionModeTableBlockedUntil = $blockedUntil
        $script:resolutionModeTableBlockedCount = [Math]::Max(1, [int]$savedState.Count)
        $script:lastResolutionModeTableBlockedLogAt = $now
        $script:pendingHdrRepair = $true
        Write-AppLog "Restored persisted 5K mode-table backoff for $Reason. attempt=$($script:resolutionModeTableBlockedCount)/$resolutionModeTableBlockedRetryLimit until=$($script:resolutionModeTableBlockedUntil.ToString('HH:mm:ss')) savedReason=$($savedState.Reason)."
    }
    catch {
        Clear-StudioDisplayResolutionModeTableBlockState -Reason "$Reason unreadable"
        Write-AppLog "Ignored unreadable 5K mode-table blocked state for $Reason`: $($_.Exception.Message)"
    }
}

function Reset-StudioDisplayResolutionModeTableBlock {
    param(
        [string]$Reason = "automatic"
    )

    $now = Get-Date
    $hadBlock = [bool](
        $script:resolutionModeTableBlockedCount -gt 0 -or
        ($script:resolutionModeTableBlockedUntil -and $now -lt $script:resolutionModeTableBlockedUntil)
    )

    $script:resolutionModeTableBlockedUntil = [DateTime]::MinValue
    $script:resolutionModeTableBlockedCount = 0
    $script:lastResolutionModeTableBlockedLogAt = [DateTime]::MinValue
    Clear-StudioDisplayResolutionModeTableBlockState -Reason $Reason

    if ($hadBlock) {
        Write-AppLog "Cleared 5K mode-table blocked backoff for $Reason."
    }
}

function Set-StudioDisplayResolutionModeTableBlockedBackoff {
    param(
        [string]$Reason = "automatic",
        [object]$ResolutionState,
        [switch]$IncrementAttempt
    )

    $now = Get-Date
    if ($IncrementAttempt) {
        $script:resolutionModeTableBlockedCount++
    }
    elseif ($script:resolutionModeTableBlockedCount -lt 1) {
        $script:resolutionModeTableBlockedCount = 1
    }

    $backoffSeconds = Get-StudioDisplayResolutionModeTableBackoffSeconds -ResolutionState $ResolutionState
    $retryLimit = Get-StudioDisplayResolutionModeTableRetryLimit -ResolutionState $ResolutionState
    $script:resolutionModeTableBlockedUntil = $now.AddSeconds($backoffSeconds)
    $script:pendingHdrRepair = $true
    $script:lastResolutionModeTableBlockedLogAt = $now
    Save-StudioDisplayResolutionModeTableBlockState -Reason $Reason

    $resolutionText = if ($ResolutionState -and $ResolutionState.Known) {
        "current5K=$($ResolutionState.HasCurrent5K), 5K60Enumerated=$($ResolutionState.Has5K60Enumerated), 5K120Enumerated=$($ResolutionState.Has5K120Enumerated)"
    }
    else {
        "resolution state unknown"
    }
    $blockKind = if (Test-StudioDisplayModeTableStaleButVisible -ResolutionState $ResolutionState) { "visible-5K stale mode table" } else { "hard degraded mode table" }

    Write-AppLog "5K mode table blocked for $Reason ($blockKind). $resolutionText. Automatic deep repair attempt $($script:resolutionModeTableBlockedCount)/$retryLimit did not make Windows expose 5120x2880 in the game-visible mode table. Backing off ${backoffSeconds}s until $($script:resolutionModeTableBlockedUntil.ToString('HH:mm:ss')); a fresh Thunderbolt reconnect, power resume, or successful 5K probe will clear this gate."
}

function Clear-StudioDisplayExpiredRepairBackoffs {
    param(
        [string]$Reason = "automatic"
    )

    $now = Get-Date
    if (
        $script:resolutionModeTableBlockedUntil -and
        $script:resolutionModeTableBlockedUntil -gt [DateTime]::MinValue -and
        $now -ge $script:resolutionModeTableBlockedUntil
    ) {
        Reset-StudioDisplayResolutionModeTableBlock -Reason "$Reason 5K mode-table backoff expired"
        $script:lastIntegratedRepairAt = [DateTime]::MinValue
        Write-AppLog "5K mode-table backoff expired for $Reason. Resetting retry state so the next automatic pass performs a real Boot Camp-style rebuild instead of extending the failure."
    }

    if (
        $script:hdrGateBlockedUntil -and
        $script:hdrGateBlockedUntil -gt [DateTime]::MinValue -and
        $now -ge $script:hdrGateBlockedUntil
    ) {
        if ($script:hdrGateRequiresPhysicalReenumeration) {
            $script:hdrGateBlockedUntil = $now.AddHours($hdrGatePhysicalReenumWaitHours)
            Save-StudioDisplayHdrGateBlockState -Reason "$Reason physical re-enumeration still required"
            if (($now - $script:lastHdrGateBlockedLogAt).TotalSeconds -ge $hdrGateBlockedLogCooldownSeconds) {
                $script:lastHdrGateBlockedLogAt = $now
                Write-AppLog "HDR physical re-enumeration gate is still active for $Reason. Not expiring it by time; reconnect, resume, reboot, or verified HDR support must clear it."
            }
            return
        }

        Reset-StudioDisplayHdrGateBlock -Reason "$Reason HDR gate backoff expired"
        $script:lastIntegratedRepairAt = [DateTime]::MinValue
        $script:lastHdrActivationAt = [DateTime]::MinValue
        Write-AppLog "HDR gate backoff expired for $Reason. Resetting retry state so HDR remains success-critical and the next automatic pass performs a real repair attempt."
    }
}

function Get-StudioDisplayLatestIntegratedRepairLogInfo {
    try {
        if (-not (Test-Path -LiteralPath $reportsRoot)) {
            return $null
        }

        $latest = Get-ChildItem -LiteralPath $reportsRoot -Filter "StudioDisplayAutoIntegratedRepair-*.log" -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if (-not $latest) {
            return $null
        }

        return [pscustomobject]@{
            FullName = $latest.FullName
            Name = $latest.Name
            LastWriteTime = $latest.LastWriteTime
            AgeSeconds = [Math]::Max(0, ((Get-Date) - $latest.LastWriteTime).TotalSeconds)
        }
    }
    catch {
        Write-AppLog "Could not inspect latest integrated repair log: $($_.Exception.Message)"
        return $null
    }
}

function Update-StudioDisplayIntegratedRepairMonitor {
    param(
        [string]$Reason = "automatic"
    )

    if (-not $script:integratedRepairInFlight) {
        return "Ready"
    }

    $now = Get-Date
    $elapsedSeconds = ($now - $script:lastIntegratedRepairStartedAt).TotalSeconds
    $resolutionState = Get-StudioDisplayResolutionRuntimeState
    $hdrState = Get-StudioDisplayHdrRuntimeState
    $taskState = Get-StudioDisplayAutoRepairTaskState
    $repairProcessRunning = Test-StudioDisplayIntegratedRepairProcessRunning
    $repairLogInfo = Get-StudioDisplayLatestIntegratedRepairLogInfo
    $repairLogFresh = [bool]($repairLogInfo -and $repairLogInfo.AgeSeconds -le $integratedRepairLogProgressGraceSeconds)
    $repairLogText = if ($repairLogInfo) {
        "repairLog=$($repairLogInfo.Name), repairLogAge=$([int]$repairLogInfo.AgeSeconds)s"
    }
    else {
        "repairLog=none"
    }

    if (Test-StudioDisplayPipelineStable -ResolutionState $resolutionState -HdrState $hdrState) {
        Set-StudioDisplayIntegratedRepairIdle
        Reset-StudioDisplayResolutionModeTableBlock -Reason "$Reason verified"
        Reset-StudioDisplayHdrGateBlock -Reason "$Reason verified"
        Clear-StudioDisplayFastFallbackState
        Write-AppLog "Integrated display pipeline restore verified for $Reason. Gate: current5K=$($resolutionState.HasCurrent5K), 5K60Enumerated=$($resolutionState.Has5K60Enumerated), hdrActive=$($hdrState.HdrActive)."
        return "Restored"
    }

    $gateText = "taskState=$taskState, repairProcessRunning=$repairProcessRunning, $repairLogText, current5K=$($resolutionState.HasCurrent5K), 5K60Enumerated=$($resolutionState.Has5K60Enumerated), hdrSupported=$($hdrState.HdrSupported), hdrActive=$($hdrState.HdrActive)"

    if ($taskState -eq "Running" -and $repairProcessRunning -and ($elapsedSeconds -lt $integratedRepairHardWatchdogSeconds -or $repairLogFresh)) {
        $script:pendingHdrRepair = $true
        if (($now - $script:lastIntegratedRepairWaitLogAt).TotalSeconds -ge $integratedRepairWaitLogCooldownSeconds) {
            $script:lastIntegratedRepairWaitLogAt = $now
            Write-AppLog "Waiting for integrated display pipeline restore to finish for $Reason. The elevated task is still running, so watchdog will not mark it blocked while the repair log is fresh. Gate: $gateText."
        }
        return "Waiting"
    }

    if ($taskState -eq "Running" -and -not $repairProcessRunning) {
        if ($elapsedSeconds -lt $integratedRepairNoProcessGraceSeconds) {
            $script:pendingHdrRepair = $true
            if (($now - $script:lastIntegratedRepairWaitLogAt).TotalSeconds -ge $integratedRepairWaitLogCooldownSeconds) {
                $script:lastIntegratedRepairWaitLogAt = $now
                Write-AppLog "Waiting briefly for the scheduled integrated display repair host process to appear for $Reason. Gate: $gateText."
            }
            return "Waiting"
        }

        Write-AppLog "Scheduled integrated display repair still reports Running for $Reason, but no repair host PowerShell process is visible after $([int]$elapsedSeconds)s. Treating the current display/HDR probe as authoritative so the offline controller can recover instead of waiting on a stale task state. Gate: $gateText."
    }

    if ($elapsedSeconds -ge $integratedRepairWatchdogSeconds) {
        if (Test-StudioDisplayResolutionModeTableBlocked -ResolutionState $resolutionState) {
            Set-StudioDisplayIntegratedRepairIdle -KeepPendingHdr
            Set-StudioDisplayResolutionModeTableBlockedBackoff -Reason "$Reason watchdog" -ResolutionState $resolutionState -IncrementAttempt
            Write-AppLog "Integrated display pipeline restore watchdog reached the missing-5K mode-table state for $Reason after $([int]$elapsedSeconds)s. Not restarting USB4 immediately. Gate: $gateText."
            return "Blocked"
        }

        if (Test-StudioDisplayHdrGateBlocked -ResolutionState $resolutionState -HdrState $hdrState) {
            Set-StudioDisplayIntegratedRepairIdle -KeepPendingHdr
            Set-StudioDisplayHdrGateBlockedBackoff -Reason "$Reason watchdog" -ResolutionState $resolutionState -HdrState $hdrState -IncrementAttempt
            Write-AppLog "Integrated display pipeline restore watchdog reached the stable-5K HDR-gate state for $Reason after $([int]$elapsedSeconds)s. Not starting another deep repair immediately. Gate: $gateText."
            return "Blocked"
        }

        Set-StudioDisplayIntegratedRepairIdle -KeepPendingHdr
        $script:lastIntegratedRepairAt = [DateTime]::MinValue
        Write-AppLog "Integrated display pipeline restore watchdog expired for $Reason after $([int]$elapsedSeconds)s. Releasing cooldown for retry. Gate: $gateText."
        return "Retry"
    }

    if ($elapsedSeconds -lt $integratedRepairSettleSeconds) {
        $script:pendingHdrRepair = $true
        if (($now - $script:lastIntegratedRepairWaitLogAt).TotalSeconds -ge $integratedRepairWaitLogCooldownSeconds) {
            $script:lastIntegratedRepairWaitLogAt = $now
            Write-AppLog "Waiting for integrated display pipeline restore to finish for $Reason. Gate: $gateText."
        }
        return "Waiting"
    }

    Set-StudioDisplayIntegratedRepairIdle -KeepPendingHdr
    if (Test-StudioDisplayResolutionModeTableBlocked -ResolutionState $resolutionState) {
        Set-StudioDisplayResolutionModeTableBlockedBackoff -Reason "$Reason completed" -ResolutionState $resolutionState -IncrementAttempt
        Write-AppLog "Integrated display pipeline restore completed but Windows still exposes only a degraded/non-5K mode table for $Reason. Gate: $gateText."
        return "Blocked"
    }

    if (Test-StudioDisplayHdrGateBlocked -ResolutionState $resolutionState -HdrState $hdrState) {
        Set-StudioDisplayHdrGateBlockedBackoff -Reason "$Reason completed" -ResolutionState $resolutionState -HdrState $hdrState -IncrementAttempt
        Write-AppLog "Integrated display pipeline restore completed but Windows still reports the HDR capability gate as closed for $Reason. Gate: $gateText."
        return "Blocked"
    }

    Write-AppLog "Integrated display pipeline restore is no longer running but verification is still incomplete for $Reason; returning to retry logic. Gate: $gateText."
    return "Retry"
}

function Invoke-StudioDisplayHdrActivation {
    param(
        [string]$Reason = "automatic",
        [switch]$Automatic
    )

    if (-not (Test-StudioDisplayConnected)) {
        Write-AppLog "Skipped display pipeline restore for $Reason because Studio Display is not connected."
        Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "Disconnected" -Action "Skip" -Detail "Studio Display evidence is absent; refusing to repair a non-Apple target."
        $script:pendingHdrRepair = $false
        Set-StudioDisplayIntegratedRepairIdle
        return $false
    }

    $repairMonitorState = Update-StudioDisplayIntegratedRepairMonitor -Reason $Reason
    if ($repairMonitorState -eq "Restored") {
        Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "ExistingRepairVerified" -Action "Complete" -Detail "An in-flight integrated repair reached current 5K, enumerated 5K60, and active HDR."
        return $true
    }
    elseif ($repairMonitorState -eq "Waiting" -or $repairMonitorState -eq "Blocked") {
        Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "ExistingRepairMonitor" -Action $repairMonitorState -Detail "Attached to or evaluated an existing integrated repair task."
        return $false
    }

    $now = Get-Date
    Clear-StudioDisplayExpiredRepairBackoffs -Reason $Reason
    $now = Get-Date

    if ($script:integratedRepairUnavailableUntil -and $now -lt $script:integratedRepairUnavailableUntil) {
        $script:pendingHdrRepair = $true
        if (($now - $script:lastIntegratedRepairCooldownLogAt).TotalSeconds -ge 60) {
            $script:lastIntegratedRepairCooldownLogAt = $now
            Write-AppLog "Deferred deep display pipeline restore for $Reason because the elevated auto repair task is still unavailable until $($script:integratedRepairUnavailableUntil.ToString('HH:mm:ss'))."
        }
        Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "ElevatedTaskUnavailable" -Action "Defer" -Detail "The elevated auto-repair task is unavailable or registration is cooling down."
        return $false
    }

    $resolutionState = Get-StudioDisplayResolutionRuntimeState
    $state = Get-StudioDisplayHdrRuntimeState
    $pipelineAlreadyStable = Test-StudioDisplayPipelineStable -ResolutionState $resolutionState -HdrState $state
    $allowForegroundCriticalRepair = [bool](
        $Automatic -and
        $Reason -match 'hot-plug|resume|connect|startup|Thunderbolt' -and
        -not $pipelineAlreadyStable
    )
    $blockReason = Get-DisplayRepairBlockReason
    if ($blockReason -and -not $allowForegroundCriticalRepair) {
        $script:pendingHdrRepair = $true
        Write-AppLog "Deferred display pipeline restore for $Reason because $blockReason."
        Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "BlockedByForegroundPolicy" -Action "Defer" -Detail $blockReason
        return $false
    }
    elseif ($blockReason -and $allowForegroundCriticalRepair) {
        Write-AppLog "Continuing hot-plug critical display pipeline restore for $Reason despite foreground block '$blockReason' because current 5K/HDR is not stable. This keeps HDR success above speed/comfort during recovery tests."
    }

    $resolutionNeedsDeepRepair = (
        -not $resolutionState.Known -or
        -not $resolutionState.HasCurrent5K -or
        -not $resolutionState.Has5K60Enumerated
    )

    if ($resolutionNeedsDeepRepair) {
        $hdrGateOpenDuringResolutionSettle = [bool](
            $state -and
            $state.Known -and
            (
                $state.HdrActive -or
                ($state.HdrSupported -and -not $state.HdrUnsupported)
            )
        )

        if ($hdrGateOpenDuringResolutionSettle) {
            $hdrOpenedGateReason = "$Reason HDR support visible while 5K mode table is settling"
            if (
                $script:hdrGateRequiresPhysicalReenumeration -or
                (Test-Path -LiteralPath $hdrGateBlockStateFile) -or
                (Test-Path -LiteralPath $lastFailureStateFile)
            ) {
                Reset-StudioDisplayHdrGateBlock -Reason $hdrOpenedGateReason
                Clear-StudioDisplayLastFailureState -Reason $hdrOpenedGateReason
                Save-StudioDisplayPhysicalReenumerationState -Event "HdrGateOpened" -Reason $hdrOpenedGateReason
            }

            if (-not $script:hdrActiveResolutionSettleUntil -or $script:hdrActiveResolutionSettleUntil -le [DateTime]::MinValue) {
                $script:hdrActiveResolutionSettleUntil = $now.AddSeconds($hdrActiveResolutionSettleSeconds)
                $resolutionText = if ($resolutionState.Known) { "current5K=$($resolutionState.HasCurrent5K), 5K60Enumerated=$($resolutionState.Has5K60Enumerated)" } else { "resolution state unknown" }
                Write-AppLog "HDR gate is already open during $Reason, but the 5K mode table is still settling. $resolutionText; hdrSupported=$($state.HdrSupported), hdrActive=$($state.HdrActive). Waiting up to ${hdrActiveResolutionSettleSeconds}s before any Boot Camp-style rebuild so a fresh hot-plug does not destroy a recovered HDR state."
            }

            if ($now -lt $script:hdrActiveResolutionSettleUntil) {
                $script:pendingHdrRepair = $true
                Start-BrightnessServices | Out-Null
                Save-StudioDisplayAutomationMaintenanceState -Stage "HdrOpenResolutionSettle" -Action "WaitForModeTable" -Detail "HDR is already supported/active after hot-plug, but the 5K mode table has not settled yet; delaying destructive rebuild." -ResolutionState $resolutionState -HdrState $state
                Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "HdrOpenResolutionSettle" -Action "WaitForModeTable" -Detail "HDR is already supported/active, so the controller is waiting for Windows to finish rebuilding the Studio Display 5K mode table before deciding whether a deep repair is actually needed." -ResolutionState $resolutionState -HdrState $state
                return $false
            }

            Write-AppLog "HDR-preserving 5K mode-table settle window expired for $Reason; continuing with the normal deep repair decision because the resolution ladder is still degraded."
        }
        else {
            $script:hdrActiveResolutionSettleUntil = [DateTime]::MinValue
        }

        if (Test-StudioDisplayBootCampFallbackRefreshNeeded) {
            Reset-StudioDisplayResolutionModeTableBlock -Reason "$Reason Boot Camp-style fallback refresh"
            $script:lastIntegratedRepairAt = [DateTime]::MinValue
            Write-AppLog "Bypassing 5K mode-table backoff for $Reason because active MS_0001 is not yet on the Boot Camp-style monitor identity and needs a driver/EDID refresh."
        }

        if ($script:resolutionModeTableBlockedUntil -and $now -lt $script:resolutionModeTableBlockedUntil) {
            $script:pendingHdrRepair = $true
            if (($now - $script:lastResolutionModeTableBlockedLogAt).TotalSeconds -ge $resolutionModeTableBlockedLogCooldownSeconds) {
                $script:lastResolutionModeTableBlockedLogAt = $now
                $resolutionText = if ($resolutionState.Known) { "current5K=$($resolutionState.HasCurrent5K), 5K60Enumerated=$($resolutionState.Has5K60Enumerated), 5K120Enumerated=$($resolutionState.Has5K120Enumerated)" } else { "resolution state unknown" }
                Write-AppLog "Deferred deep display pipeline restore for $Reason because the 5K mode-table backoff is still active until $($script:resolutionModeTableBlockedUntil.ToString('HH:mm:ss')). Gate: $resolutionText."
            }
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "ResolutionModeTableBackoff" -Action "Defer" -Detail "5K60 is not safely enumerated, but the mode-table retry backoff is active." -ResolutionState $resolutionState
            return $false
        }

        $resolutionRetryLimit = Get-StudioDisplayResolutionModeTableRetryLimit -ResolutionState $resolutionState
        if ($script:resolutionModeTableBlockedCount -ge $resolutionRetryLimit) {
            Set-StudioDisplayResolutionModeTableBlockedBackoff -Reason "$Reason retry limit" -ResolutionState $resolutionState
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "ResolutionModeTableRetryLimit" -Action "Backoff" -Detail "5K60 mode table is still degraded after retry limit." -ResolutionState $resolutionState
            return $false
        }

        if (($now - $script:lastIntegratedRepairAt).TotalSeconds -lt $integratedRepairCooldownSeconds) {
            $script:pendingHdrRepair = $true
            if (($now - $script:lastIntegratedRepairCooldownLogAt).TotalSeconds -ge $integratedRepairCooldownLogSeconds) {
                $script:lastIntegratedRepairCooldownLogAt = $now
                $resolutionText = if ($resolutionState.Known) { "current5K=$($resolutionState.HasCurrent5K), 5K60Enumerated=$($resolutionState.Has5K60Enumerated)" } else { "resolution state unknown" }
                Write-AppLog "Deferred deep display pipeline restore for $Reason because integrated repair cooldown is still active. Gate: $resolutionText."
            }
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "IntegratedRepairCooldown" -Action "Defer" -Detail "5K ladder is degraded, but integrated repair cooldown is active." -ResolutionState $resolutionState
            return $false
        }

        Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "ResolutionOrModeTableDegraded" -Action "RunBootCampStyleIntegratedRebuild" -Detail "Current 5K and enumerated 5K60 are not both true; rebuilding Boot Camp-style identity, USB4 link, HDR gate, and brightness in one transaction." -ResolutionState $resolutionState
        return Invoke-StudioDisplayDeepIntegratedRepair `
            -TaskReason "$Reason (resolution/HDR ladder restore)" `
            -LogDetail "The 5K ladder is not stable; HDR will stay pending until verification succeeds." `
            -Automatic:$Automatic `
            -AllowForegroundCriticalRepair:$allowForegroundCriticalRepair
    }

    Reset-StudioDisplayResolutionModeTableBlock -Reason "$Reason 5K mode table recovered"
    $script:hdrActiveResolutionSettleUntil = [DateTime]::MinValue

    if ($state.HdrActive) {
        $script:pendingHdrRepair = $false
        Reset-StudioDisplayHdrGateBlock -Reason "$Reason HDR active"
        Write-AppLog "Display pipeline restore skipped for $Reason because 5K60 is stable and HDR is already active."
        Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "CodeZeroAlreadyHealthy" -Action "Skip" -Detail "5K60 is stable and HDR is already active." -ResolutionState $resolutionState -HdrState $state
        return $true
    }

    if ($state.Known -and $state.HdrSupported) {
        Reset-StudioDisplayHdrGateBlock -Reason "$Reason HDR supported"
        if (-not (Test-Path $hdrStateScript)) {
            Write-AppLog "Skipped lightweight HDR restore for $Reason because HDR state script is missing."
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "HdrSupportedButSetterMissing" -Action "Defer" -Detail "HDR is supported but the HDR state setter script is missing." -ResolutionState $resolutionState -HdrState $state
            return $false
        }

        if (($now - $script:lastHdrActivationAt).TotalSeconds -lt $hdrActivationCooldownSeconds) {
            $script:pendingHdrRepair = $true
            Write-AppLog "Deferred lightweight HDR restore for $Reason because HDR activation cooldown is still active."
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "LightweightHdrCooldown" -Action "Defer" -Detail "HDR is supported but inactive; waiting for lightweight HDR cooldown." -ResolutionState $resolutionState -HdrState $state
            return $false
        }

        try {
            $script:lastHdrActivationAt = $now
            Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
                "-NoProfile",
                "-WindowStyle", "Hidden",
                "-ExecutionPolicy", "Bypass",
                "-File", $hdrStateScript,
                "-Enable"
            )
            $script:pendingHdrRepair = $true
            Write-AppLog "Started lightweight HDR restore for $Reason because 5K60 is stable and HighDynamicRangeSupported=True but HDR is not active; HDR will stay pending until the next probe verifies it."
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "HdrSupportedInactive" -Action "RunLightweightHdrEnable" -Detail "5K60 is stable and Windows reports HDR-capable, so only SET_HDR_STATE is needed." -ResolutionState $resolutionState -HdrState $state
            return $true
        }
        catch {
            Write-AppLog "Lightweight HDR restore for $Reason failed: $($_.Exception.Message)"
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "LightweightHdrLaunchFailed" -Action "RetryLater" -Detail $_.Exception.Message -ResolutionState $resolutionState -HdrState $state
            return $false
        }
    }

    if (Test-StudioDisplayHdrGateBlocked -ResolutionState $resolutionState -HdrState $state) {
        if (-not $script:hdrGateRequiresPhysicalReenumeration) {
            $failureStateForGate = Get-StudioDisplayLastFailureState
            if (Test-StudioDisplayFailureNeedsPhysicalReenumeration -FailureState $failureStateForGate) {
                Set-StudioDisplayHdrGateBlockedBackoff -Reason "$Reason last failure physical gate" -ResolutionState $resolutionState -HdrState $state
            }
        }

        if ($script:hdrGateRequiresPhysicalReenumeration -and $script:hdrGateBlockedUntil -and $now -lt $script:hdrGateBlockedUntil) {
            $script:pendingHdrRepair = $true
            $failureState = Get-StudioDisplayLastFailureState
            $requiresUsbReboot = [bool]($failureState -and [bool]$failureState.AppleUsbRebootRequired)
            $waitDetail = if ($requiresUsbReboot) {
                "5K60 is stable, Windows reports HighDynamicRangeSupported=False, and the last Apple USB parent restart returned pnputil 3010/reboot-required."
            }
            else {
                "5K60 is stable, Windows reports HighDynamicRangeSupported=False, and the last failure indicates Apple USB MI_08/MI_09 failed-start."
            }
            $decisionDetail = if ($requiresUsbReboot) {
                "5K60 is stable but HDR support is blocked after Apple USB parent reconfiguration returned pnputil 3010; waiting for reboot, resume, or full Thunderbolt/USB re-enumeration."
            }
            else {
                "5K60 is stable but HDR support is blocked by a previous Apple USB control-interface failed-start; waiting for physical Thunderbolt/USB re-enumeration."
            }
            if (($now - $script:lastHdrGateBlockedLogAt).TotalSeconds -ge $hdrGateBlockedLogCooldownSeconds) {
                $script:lastHdrGateBlockedLogAt = $now
                Write-AppLog "Deferred HDR deep repair for $Reason because the previous failure requires reboot/resume or fresh Thunderbolt/USB physical re-enumeration. Stable 5K60 is preserved instead of looping."
            }
            Save-StudioDisplayAutomationMaintenanceState -Stage "HdrGateWaitingForPhysicalReenumeration" -Action "WaitForReconnectOrResume" -Detail $waitDetail -ResolutionState $resolutionState -HdrState $state -FailureState $failureState
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "HdrCapabilityGateWaitingForPhysicalReenumeration" -Action "Defer" -Detail $decisionDetail -ResolutionState $resolutionState -HdrState $state
            return $false
        }

        if ($script:hdrGateBlockedUntil -and $now -lt $script:hdrGateBlockedUntil) {
            $script:pendingHdrRepair = $true
            if (($now - $script:lastHdrGateBlockedLogAt).TotalSeconds -ge $hdrGateBlockedLogCooldownSeconds) {
                $script:lastHdrGateBlockedLogAt = $now
                Write-AppLog "Deferred HDR gate deep repair for $Reason because Windows still reports HighDynamicRangeSupported=False with stable 5K60. Backoff remains active until $($script:hdrGateBlockedUntil.ToString('HH:mm:ss'))."
            }
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "HdrCapabilityGateBackoff" -Action "Defer" -Detail "5K60 is stable but HighDynamicRangeSupported=False; backing off repeated HDR packet attempts." -ResolutionState $resolutionState -HdrState $state
            return $false
        }

        if ($script:hdrGateBlockedCount -ge $hdrGateBlockedRetryLimit) {
            Set-StudioDisplayHdrGateBlockedBackoff -Reason "$Reason retry limit" -ResolutionState $resolutionState -HdrState $state
            Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "HdrCapabilityGateRetryLimit" -Action "Backoff" -Detail "5K60 is stable but Windows keeps HighDynamicRangeSupported=False after retry limit." -ResolutionState $resolutionState -HdrState $state
            return $false
        }
    }

    if (($now - $script:lastIntegratedRepairAt).TotalSeconds -lt $integratedRepairCooldownSeconds) {
        $script:pendingHdrRepair = $true
        if (($now - $script:lastIntegratedRepairCooldownLogAt).TotalSeconds -ge $integratedRepairCooldownLogSeconds) {
            $script:lastIntegratedRepairCooldownLogAt = $now
            $gateText = if ($state.HdrUnsupported) { "HighDynamicRangeSupported=False" } elseif ($state.Known) { "HDR state is known but not supported" } else { "HDR state is unknown" }
            Write-AppLog "Deferred deep display pipeline restore for $Reason because integrated repair cooldown is still active. Gate: $gateText."
        }
        Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "IntegratedRepairCooldown" -Action "Defer" -Detail "HDR gate is not ready, but integrated repair cooldown is active." -ResolutionState $resolutionState -HdrState $state
        return $false
    }

    $gateText = if ($state.HdrUnsupported) { "HighDynamicRangeSupported=False" } elseif ($state.Known) { "HDR state known but inactive" } else { "HDR state unknown" }
    Save-StudioDisplayPipelineDecision -Reason $Reason -Stage "HdrGateNeedsRebuild" -Action "RunBootCampStyleIntegratedRebuild" -Detail "5K60 is stable but HDR is not active/supported; running Boot Camp-style integrated rebuild rather than Generic fallback or WCG downgrade." -ResolutionState $resolutionState -HdrState $state
    return Invoke-StudioDisplayDeepIntegratedRepair `
        -TaskReason "$Reason (HDR gate restore)" `
        -LogDetail "Gate: $gateText. HDR will stay pending until verification succeeds." `
        -Automatic:$Automatic `
        -AllowForegroundCriticalRepair:$allowForegroundCriticalRepair
}

function Show-StudioDisplayHdrBrightnessContext {
    $hdrText = "HDR 状态：未知"
    $sdrWhiteText = "SDR 内容亮度：未知"
    $hardwareBrightnessText = "Studio Display 硬件亮度：未知"
    $screenshotGuardText = "HDR 截图防过曝：未知"
    $screenshotGuardHint = "截图防过曝会监听 PrintScreen / Alt+PrintScreen / Win+Shift+S；当 HDR 已开启且 SDR white 高于 $hdrScreenshotSafeSdrWhiteNits nits 时，会自动修正刚进入剪贴板的截图。"
    $sdrWhiteWarningText = $null

    try {
        if (Test-Path $advancedColorScript) {
            $stateText = (@(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $advancedColorScript -SkipDxDiagFallback 2>&1) -join "`n")
            if ($stateText -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR[^\S\r\n]*$') {
                $hdrText = "HDR 状态：已开启"
            }
            elseif ($stateText -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG[^\S\r\n]*$') {
                $hdrText = "HDR 状态：WCG/Advanced Color，不是真 HDR"
            }
            elseif ($stateText -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*(.+?)[^\S\r\n]*$') {
                $hdrText = "HDR 状态：$($Matches[1].Trim())"
            }

            if ($stateText -match '(?m)^[^\S\r\n]*SdrWhiteLevelNits[^\S\r\n]*:[^\S\r\n]*([0-9.]+)[^\S\r\n]*$') {
                $sdrWhiteText = "SDR 内容亮度：$($Matches[1]) nits paper-white"
                $sdrWhiteNits = [double]$Matches[1]
                if ($sdrWhiteNits -gt $hdrScreenshotSafeSdrWhiteNits) {
                    $sdrWhiteWarningText = "当前 SDR white 高于截图安全阈值；普通 SDR PNG/剪贴板截图可能发白，截图防过曝会对新截图做剪贴板 tone-map。"
                }
            }
        }
    }
    catch {
        $hdrText = "HDR 状态读取失败：$($_.Exception.Message)"
    }

    try {
        if (Test-Path $hidHelperScript) {
            $brightness = (& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $hidHelperScript -GetPercent 2>$null | Select-Object -First 1)
            if ($brightness -match '^\d+$') {
                $hardwareBrightnessText = "Studio Display 硬件亮度：$brightness%"
            }
        }
    }
    catch {
        $hardwareBrightnessText = "Studio Display 硬件亮度读取失败：$($_.Exception.Message)"
    }

    try {
        if (Test-HdrScreenshotGuardRunning) {
            $screenshotGuardText = "HDR 截图防过曝：运行中"
        }
        else {
            $screenshotGuardText = "HDR 截图防过曝：未运行"
        }
    }
    catch {
        $screenshotGuardText = "HDR 截图防过曝：状态读取失败"
    }

    $messageLines = @(
        $hdrText,
        $hardwareBrightnessText,
        $sdrWhiteText,
        $screenshotGuardText,
        "",
        "HDR 开启后，Windows 的 'SDR 内容亮度' 是 SDR white/paper-white 映射，不是外接显示器背光。",
        "Studio Display XDR 的真实背光仍由 Apple HID/参考模式控制；某些 Apple reference mode 下亮度控制可能被锁定或弱化。",
        $screenshotGuardHint
    )
    if ($sdrWhiteWarningText) {
        $messageLines += $sdrWhiteWarningText
    }

    [System.Windows.Forms.MessageBox]::Show(
        ($messageLines -join "`n"),
        "$appName HDR 亮度语境",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
}

function New-StatusIcon {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$Color
    )

    $bitmap = New-Object System.Drawing.Bitmap 16, 16
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 0, 0, 0))
    $fillBrush = New-Object System.Drawing.SolidBrush $Color
    $outlinePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(210, 255, 255, 255), 1)

    $graphics.FillEllipse($shadowBrush, 3, 3, 10, 10)
    $graphics.FillEllipse($fillBrush, 2, 2, 10, 10)
    $graphics.DrawEllipse($outlinePen, 2, 2, 10, 10)

    $iconHandle = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($iconHandle)

    $shadowBrush.Dispose()
    $fillBrush.Dispose()
    $outlinePen.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()

    return $icon
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

try {
    Set-Content -LiteralPath $trayPidFile -Value $PID -Encoding ascii -ErrorAction Stop
}
catch {
    $message = "$appName cannot write its pid file: $trayPidFile`n$($_.Exception.Message)`n`nStart it from the installed shortcut or rerun the installer so the controller uses the normal user token."
    Write-AppLog "Tray pid file write failed: $($_.Exception.Message)"
    try {
        [System.Windows.Forms.MessageBox]::Show(
            $message,
            $appName,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
    catch {
    }
    exit 1
}
Write-AppLog "$appName tray started with PID $PID."

$context = $null
$notifyIcon = $null
$timer = $null
$powerModeHandler = $null
$runningIcon = $null
$stoppedIcon = $null
$degradedIcon = $null
$lastStudioDisplayConnected = $false
$lastDisplayRepairAt = [DateTime]::MinValue
$lastDisplayTopologySignature = ""
$pendingPowerResumeRepair = $false
$pendingHdrRepair = $false
$lastHdrActivationAt = [DateTime]::MinValue
$lastIntegratedRepairAt = [DateTime]::MinValue
$lastIntegratedRepairStartedAt = [DateTime]::MinValue
$lastIntegratedRepairWaitLogAt = [DateTime]::MinValue
$lastIntegratedRepairCooldownLogAt = [DateTime]::MinValue
$integratedRepairUnavailableUntil = [DateTime]::MinValue
$integratedRepairInFlight = $false
$integratedRepairAttachedToExisting = $false
$hdrGateBlockedUntil = [DateTime]::MinValue
$hdrGateBlockedCount = 0
$hdrGateRequiresPhysicalReenumeration = $false
$lastHdrGateBlockedLogAt = [DateTime]::MinValue
$resolutionModeTableBlockedUntil = [DateTime]::MinValue
$resolutionModeTableBlockedCount = 0
$lastResolutionModeTableBlockedLogAt = [DateTime]::MinValue
$hdrActiveResolutionSettleUntil = [DateTime]::MinValue
$lastAutoRepairTaskRegistrationPromptAt = [DateTime]::MinValue
$lastStudioDisplayPnpCheckAt = [DateTime]::MinValue
$lastStudioDisplayPnpCheckResult = $false
$lastHdrScreenshotGuardStartAttemptAt = [DateTime]::MinValue
$lastBrightnessServiceRecoveryAttemptAt = [DateTime]::MinValue

Restore-StudioDisplayHdrGateBlockState -Reason "tray startup"
Restore-StudioDisplayResolutionModeTableBlockState -Reason "tray startup"

try {
    $runningIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(60, 179, 113))
    $stoppedIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(130, 130, 130))
    $degradedIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(255, 140, 0))

    $context = New-Object System.Windows.Forms.ApplicationContext
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Visible = $true
    $notifyIcon.Icon = $stoppedIcon
    $notifyIcon.Text = $statusTooltipStopped
    $notifyIcon.BalloonTipTitle = $appName
    $notifyIcon.BalloonTipText = "亮度同步和外屏模式修复正在后台运行。"
    $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info

    $powerModeHandler = [Microsoft.Win32.PowerModeChangedEventHandler]{
        param($sender, $eventArgs)

        if ($eventArgs.Mode -eq [Microsoft.Win32.PowerModes]::Resume) {
            $script:pendingPowerResumeRepair = $true
            $script:pendingHdrRepair = $true
            $script:lastStudioDisplayPnpCheckAt = [DateTime]::MinValue
            $script:lastDisplayRepairAt = [DateTime]::MinValue
            $script:hdrActiveResolutionSettleUntil = [DateTime]::MinValue
            Reset-StudioDisplayResolutionModeTableBlock -Reason "power resume"
            Write-AppLog "Power resume detected; scheduling the unified Studio Display XDR topology/5K/HDR/brightness pipeline."
        }
    }
    [Microsoft.Win32.SystemEvents]::add_PowerModeChanged($powerModeHandler)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    $statusItem.Text = "状态：正在检查"

    $brightnessMenu = New-Object System.Windows.Forms.ToolStripMenuItem "亮度控制"
    $hdrMenu = New-Object System.Windows.Forms.ToolStripMenuItem "HDR/亮度"
    $advancedMenu = New-Object System.Windows.Forms.ToolStripMenuItem "高级/诊断"

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem "启动亮度控制"
    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem "重启亮度控制"
    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem "停止亮度控制"
    $integratedRepairItem = New-Object System.Windows.Forms.ToolStripMenuItem "重建 Boot Camp-style 5K60 HDR 管线"
    $registerAutoRepairTaskItem = New-Object System.Windows.Forms.ToolStripMenuItem "自动修复权限：注册/修复"
    $hdrBrightnessContextItem = New-Object System.Windows.Forms.ToolStripMenuItem "查看 HDR/亮度语境"
    $hdrScreenshotGuardRestartItem = New-Object System.Windows.Forms.ToolStripMenuItem "截图防过曝：重启"
    $hdrScreenshotGuardStopItem = New-Object System.Windows.Forms.ToolStripMenuItem "截图防过曝：停止"
    $openHdrSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem "打开 Windows HDR 设置"
    $hotplugAutomationTestItem = New-Object System.Windows.Forms.ToolStripMenuItem "验证热插拔自动化"
    $brightnessInputTraceItem = New-Object System.Windows.Forms.ToolStripMenuItem "监听亮度按键"
    $openLogItem = New-Object System.Windows.Forms.ToolStripMenuItem "打开日志"
    $openFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem "打开安装目录"
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem "退出"

    [void]$brightnessMenu.DropDownItems.Add($startItem)
    [void]$brightnessMenu.DropDownItems.Add($restartItem)
    [void]$brightnessMenu.DropDownItems.Add($stopItem)

    [void]$hdrMenu.DropDownItems.Add($hdrBrightnessContextItem)
    [void]$hdrMenu.DropDownItems.Add($hdrScreenshotGuardRestartItem)
    [void]$hdrMenu.DropDownItems.Add($hdrScreenshotGuardStopItem)
    [void]$hdrMenu.DropDownItems.Add($openHdrSettingsItem)

    [void]$advancedMenu.DropDownItems.Add($registerAutoRepairTaskItem)
    [void]$advancedMenu.DropDownItems.Add($hotplugAutomationTestItem)
    [void]$advancedMenu.DropDownItems.Add($brightnessInputTraceItem)
    [void]$advancedMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$advancedMenu.DropDownItems.Add($openLogItem)
    [void]$advancedMenu.DropDownItems.Add($openFolderItem)

    [void]$menu.Items.Add($statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($integratedRepairItem)
    [void]$menu.Items.Add($brightnessMenu)
    [void]$menu.Items.Add($hdrMenu)
    [void]$menu.Items.Add($advancedMenu)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($exitItem)

    $notifyIcon.ContextMenuStrip = $menu

    $updateUi = {
        $mirrorRunning = Test-BrightnessWorkerAvailable -Label "SystemBrightnessMirror" -ScriptPath $mirrorScript -PidPath $mirrorPidFile -MutexName $mirrorMutexName
        $bridgeRunning = Test-BrightnessWorkerAvailable -Label "BrightnessKeyBridge" -ScriptPath $brightnessBridgeScript -PidPath $brightnessBridgePidFile -MutexName $brightnessBridgeMutexName
        $brightnessRunning = [bool]($mirrorRunning -and $bridgeRunning)
        $screenshotGuardRunning = Test-HdrScreenshotGuardRunning
        $fastFallbackState = Get-StudioDisplayFastFallbackState
        $fastFallbackActive = [bool]($fastFallbackState -and $fastFallbackState.Status -match '^(Requested|Running|Completed)$')

        if ($fastFallbackActive) {
            $integratedRepairItem.Text = "从 fallback 重建 Boot Camp-style 5K60 HDR 管线"
        }
        else {
            $integratedRepairItem.Text = "重建 Boot Camp-style 5K60 HDR 管线"
        }

        $hdrScreenshotGuardRestartItem.Text = if ($screenshotGuardRunning) { "截图防过曝：重启" } else { "截图防过曝：启动" }
        $hdrScreenshotGuardStopItem.Enabled = $screenshotGuardRunning

        if ($script:integratedRepairInFlight) {
            $statusItem.Text = "状态：自动修复中（5K/HDR/亮度）"
            $startItem.Enabled = -not $mirrorRunning
            $restartItem.Enabled = $brightnessRunning
            $stopItem.Enabled = $brightnessRunning
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "${appName}: Auto repair"
        }
        elseif ($script:hdrGateBlockedUntil -and (Get-Date) -lt $script:hdrGateBlockedUntil) {
            $statusItem.Text = "状态：5K60 稳定；HDR gate 退避中"
            $startItem.Enabled = -not $mirrorRunning
            $restartItem.Enabled = $brightnessRunning
            $stopItem.Enabled = $brightnessRunning
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "${appName}: HDR gate"
        }
        elseif ($script:resolutionModeTableBlockedUntil -and (Get-Date) -lt $script:resolutionModeTableBlockedUntil) {
            $statusItem.Text = "状态：5K 模式表缺失；等待重连/恢复后再修复"
            $startItem.Enabled = -not $mirrorRunning
            $restartItem.Enabled = $brightnessRunning
            $stopItem.Enabled = $brightnessRunning
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "${appName}: 5K mode gate"
        }
        elseif ($fastFallbackActive) {
            $statusItem.Text = "状态：快速 fallback 已启用；点击重建 5K60 HDR 管线"
            $startItem.Enabled = -not $mirrorRunning
            $restartItem.Enabled = $brightnessRunning
            $stopItem.Enabled = $brightnessRunning
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "${appName}: fallback active"
        }
        elseif ($brightnessRunning) {
            $statusItem.Text = "状态：亮度运行；外屏监控中"
            $startItem.Enabled = $false
            $restartItem.Enabled = $true
            $stopItem.Enabled = $true
            $notifyIcon.Icon = $runningIcon
            $notifyIcon.Text = $statusTooltipRunning
        } else {
            $statusItem.Text = "状态：亮度未完整运行；外屏监控中"
            $startItem.Enabled = $true
            $restartItem.Enabled = $false
            $stopItem.Enabled = $false
            $notifyIcon.Icon = $stoppedIcon
            $notifyIcon.Text = $statusTooltipStopped
        }
    }

    $startItem.add_Click({
        if (Start-BrightnessServices) {
            & $updateUi
        } else {
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "${appName}: Error"
            [System.Windows.Forms.MessageBox]::Show(
                "亮度控制启动失败。你可以先检查 Studio Display 是否已经重新连上，然后再试一次。",
                $appName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            & $updateUi
        }
    })

    $restartItem.add_Click({
        if (Restart-BrightnessServices) {
            & $updateUi
        } else {
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "${appName}: Error"
            [System.Windows.Forms.MessageBox]::Show(
                "亮度控制重启失败。请确认 Studio Display 已连接，然后再重试。",
                $appName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            & $updateUi
        }
    })

    $stopItem.add_Click({
        Stop-BrightnessServices
        & $updateUi
    })

    $integratedRepairItem.add_Click({
        $preflight = Get-StudioDisplayOneClickRepairPreflight
        $fastFallbackState = Get-StudioDisplayFastFallbackState
        $fastFallbackActive = [bool]($fastFallbackState -and $fastFallbackState.Status -match '^(Requested|Running|Completed)$')

        if ($preflight.FullyReady) {
            Clear-StudioDisplayFastFallbackState
            & $updateUi
            [System.Windows.Forms.MessageBox]::Show(
                "当前已经满足一键修复条件：Studio Display XDR 已连接，5K60 当前模式和模式表正常，HDR 已 active，亮度镜像/按键桥运行中，并且硬件亮度 HID 可读。已跳过修复。",
                "$appName 一键修复",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
            return
        }

        if (-not $preflight.Connected) {
            [System.Windows.Forms.MessageBox]::Show(
                "当前没有检测到 Studio Display XDR。为避免把显示管线修复误应用到内屏，已跳过一键修复。请重新插入 Thunderbolt 后再试。",
                "$appName 一键修复",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        if ($preflight.NeedsBrightnessOnly) {
            $brightnessRecovered = Restart-BrightnessServices
            Start-Sleep -Milliseconds 800
            $hidRecovered = Test-StudioDisplayBrightnessHidReady
            $message = if ($brightnessRecovered -and $hidRecovered) {
                "显示管线和 HDR 已经满足条件，这次只重启了亮度镜像/按键桥。亮度 HID 已恢复，未执行会黑屏的 5K/HDR 深度修复。"
            }
            else {
                "显示管线和 HDR 已经满足条件，但亮度组件重启后仍未完整恢复。下一次一键修复会进入管理员 Apple USB/HID 深度修复路径。"
            }
            $icon = if ($brightnessRecovered -and $hidRecovered) { [System.Windows.Forms.MessageBoxIcon]::Information } else { [System.Windows.Forms.MessageBoxIcon]::Warning }
            [System.Windows.Forms.MessageBox]::Show(
                $message,
                "$appName 一键修复",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                $icon
            ) | Out-Null
            & $updateUi
            return
        }

        $issuesText = (($preflight.Issues | ForEach-Object { "- $_" }) -join "`r`n")
        $fallbackText = if ($fastFallbackActive) {
            "`r`n`r`n当前检测到你之前选择过快速 fallback。继续后会主动放弃 fallback 状态，重新走完整 Boot Camp-style 5K60 HDR 身份/模式表/HDR/亮度管线。"
        }
        else {
            ""
        }
        $permissionText = if ($preflight.NeedsAdministrator) {
            "`r`n`r`n接下来会立刻弹出 Windows UAC 管理员权限请求；请在 UAC 中确认允许。批准后会打开进度窗口并只修复缺失项。"
        }
        else {
            "`r`n`r`n当前托盘已经是管理员或只需要用户态修复，不需要额外 UAC。"
        }
        $result = [System.Windows.Forms.MessageBox]::Show(
            "当前还不满足一键修复条件：`r`n$issuesText$fallbackText`r`n`r`n修复器会保留已满足的项目，尽量跳过不需要的拓扑/5K/HDR/亮度步骤。活动显示为 MS_0001 时会统一走 Boot Camp-style monitor identity；Generic/Digital Flat Panel fallback 只保留诊断，不作为 HDR 修复路线。屏幕只有在确实需要显示链路修复时才可能短暂黑屏/闪烁。$permissionText`r`n`r`n是否继续？",
            "$appName 一键修复",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
            Invoke-StudioDisplayIntegratedRepair -Reason "tray menu integrated repair" | Out-Null
        }
    })

    $registerAutoRepairTaskItem.add_Click({
        $script:lastAutoRepairTaskRegistrationPromptAt = [DateTime]::MinValue
        $script:integratedRepairUnavailableUntil = [DateTime]::MinValue
        if (Invoke-StudioDisplayAutoRepairTaskRegistrationPrompt -Reason "tray menu auto repair task registration") {
            [System.Windows.Forms.MessageBox]::Show(
                '已经请求 Windows 弹出 UAC。请确认允许以完成一次性授权；之后 Thunderbolt 热插拔就可以后台自动运行 5K/HDR 修复。',
                $appName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "没有成功启动 UAC 注册窗口。请检查安装目录里是否存在 Register-StudioDisplayAutoRepairTask.ps1。",
                $appName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    $hotplugAutomationTestItem.add_Click({
        if (Test-Path $hotplugAutomationTestScript) {
            Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-NoExit",
                "-File", $hotplugAutomationTestScript
            )
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "热插拔自动化验证脚本不存在，请重新安装 Studio Display XDR Win Controller。",
                $appName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    $hdrBrightnessContextItem.add_Click({
        Show-StudioDisplayHdrBrightnessContext
    })

    $hdrScreenshotGuardRestartItem.add_Click({
        if (Restart-HdrScreenshotGuard) {
            [System.Windows.Forms.MessageBox]::Show(
                "截图防过曝已启动。它会监听 PrintScreen / Alt+PrintScreen / Win+Shift+S，并在 HDR + 高 SDR white 时自动修正刚进入剪贴板的截图。",
                "$appName HDR 截图防过曝",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "截图防过曝启动失败。请打开日志查看 HdrScreenshotGuard 相关记录。",
                "$appName HDR 截图防过曝",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
        & $updateUi
    })

    $hdrScreenshotGuardStopItem.add_Click({
        Stop-HdrScreenshotGuard
        & $updateUi
    })

    $openHdrSettingsItem.add_Click({
        Start-Process "ms-settings:display"
    })

    $brightnessInputTraceItem.add_Click({
        if (Test-Path $brightnessInputTraceScript) {
            Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -ArgumentList @(
                "-Sta",
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", $brightnessInputTraceScript,
                "-DurationSeconds", "45"
            )
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                "亮度输入监听脚本不存在，请重新安装 Studio Display XDR Win Controller。",
                $appName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    $openLogItem.add_Click({
        if (Test-Path $logPath) {
            Start-Process -FilePath "notepad.exe" -ArgumentList @($logPath)
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "日志文件还没有生成。",
                $appName,
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    })

    $openFolderItem.add_Click({
        Start-Process -FilePath "explorer.exe" -ArgumentList @($installRoot)
    })

    $exitItem.add_Click({
        Stop-BrightnessServices
        Stop-HdrScreenshotGuard
        if ($timer) {
            $timer.Stop()
        }
        if ($notifyIcon) {
            $notifyIcon.Visible = $false
        }
        if ($context) {
            $context.ExitThread()
        }
    })

    $notifyIcon.add_DoubleClick({
        $mirrorAvailable = Test-BrightnessWorkerAvailable -Label "SystemBrightnessMirror" -ScriptPath $mirrorScript -PidPath $mirrorPidFile -MutexName $mirrorMutexName
        $bridgeAvailable = Test-BrightnessWorkerAvailable -Label "BrightnessKeyBridge" -ScriptPath $brightnessBridgeScript -PidPath $brightnessBridgePidFile -MutexName $brightnessBridgeMutexName
        if (-not $mirrorAvailable -or -not $bridgeAvailable) {
            Start-BrightnessServices | Out-Null
            & $updateUi
        } else {
            Start-Process -FilePath "explorer.exe" -ArgumentList @($installRoot)
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.add_Tick({
        Ensure-HdrScreenshotGuard | Out-Null

        $studioDisplayConnected = Test-StudioDisplayConnected
        $currentDisplayTopologySignature = Get-DisplayTopologySignature
        $repairDueToReconnect = $studioDisplayConnected -and -not $script:lastStudioDisplayConnected
        $repairDueToStartup = $studioDisplayConnected -and $script:lastDisplayRepairAt -eq [DateTime]::MinValue
        $repairDueToPowerResume = $studioDisplayConnected -and $script:pendingPowerResumeRepair
        $repairDueToTopologyChange = (
            $studioDisplayConnected -and
            $script:lastStudioDisplayConnected -and
            $script:lastDisplayTopologySignature -and
            $currentDisplayTopologySignature -ne $script:lastDisplayTopologySignature
        )
        $topologyRepairCooldownElapsed = ((Get-Date) - $script:lastDisplayRepairAt).TotalSeconds -ge 8

        $shouldRepairNow = (
            $repairDueToReconnect -or
            $repairDueToStartup -or
            $repairDueToPowerResume -or
            ($repairDueToTopologyChange -and $topologyRepairCooldownElapsed)
        )

        if ($shouldRepairNow) {
            $script:pendingHdrRepair = $true
            $repairReason = if ($repairDueToPowerResume) {
                "power resume or sleep-time hot-plug detection"
            } elseif ($repairDueToTopologyChange) {
                "display topology changed while Studio Display is connected"
            } else {
                "Studio Display connect/startup detection"
            }

            Save-StudioDisplayPipelineDecision -Reason $repairReason -Stage "HotplugEventDetected" -Action "ProbeAndDecide" -Detail "A reconnect/startup/resume/topology event was detected; the controller will probe current 5K/HDR/brightness gates before deciding whether to rebuild."
            Start-StudioDisplayPassiveHotplugObserver -Reason $repairReason | Out-Null

            $autoRepairTaskState = Get-StudioDisplayAutoRepairTaskState
            if ($script:integratedRepairInFlight -or $autoRepairTaskState -eq "Running") {
                $now = Get-Date
                Set-StudioDisplayIntegratedRepairActive -StartedAt $now -Attached
                Save-StudioDisplayPipelineDecision -Reason $repairReason -Stage "ExistingRepairRunning" -Action "AttachAndWait" -Detail "An elevated integrated repair is already running, so this event is coalesced instead of launching a second topology/HDR transaction."
                if (($now - $script:lastIntegratedRepairWaitLogAt).TotalSeconds -ge $integratedRepairWaitLogCooldownSeconds) {
                    $script:lastIntegratedRepairWaitLogAt = $now
                    Write-AppLog "Coalesced $repairReason into the already-running integrated display pipeline restore. Skipping extra topology repair/task start so the current HDR/5K transaction can finish cleanly. taskState=$autoRepairTaskState."
                }
            }
            else {
                if ($repairDueToReconnect -or $repairDueToPowerResume) {
                    $script:integratedRepairInFlight = $false
                    $script:lastIntegratedRepairAt = [DateTime]::MinValue
                    $script:lastHdrActivationAt = [DateTime]::MinValue
                    $script:integratedRepairUnavailableUntil = [DateTime]::MinValue
                    $script:lastAutoRepairTaskRegistrationPromptAt = [DateTime]::MinValue
                    $script:hdrActiveResolutionSettleUntil = [DateTime]::MinValue
                    Reset-StudioDisplayResolutionModeTableBlock -Reason $repairReason
                    Reset-StudioDisplayHdrGateBlock -Reason $repairReason
                    $physicalEvent = if ($repairDueToPowerResume) { "PowerResume" } else { "Reconnected" }
                    Save-StudioDisplayPhysicalReenumerationState -Event $physicalEvent -Reason "$repairReason physical re-enumeration observed"
                    Clear-StudioDisplayLastFailureState -Reason "$repairReason physical re-enumeration observed"
                }
                elseif ($repairDueToTopologyChange) {
                    $script:lastHdrActivationAt = [DateTime]::MinValue
                    if ($script:hdrGateRequiresPhysicalReenumeration) {
                        Write-AppLog "Display topology changed while the HDR physical re-enumeration gate is active. Keeping the gate because SetDisplayConfig/topology churn is not proof of a fresh Thunderbolt/USB physical reconnect."
                        Save-StudioDisplayAutomationMaintenanceState -Stage "TopologyChangedButHdrGateHeld" -Action "KeepPhysicalGate" -Detail "Topology changed, but the previous HDR failure still requires physical Thunderbolt/USB re-enumeration." -ResolutionState (Get-StudioDisplayResolutionRuntimeState) -HdrState (Get-StudioDisplayHdrRuntimeState) -FailureState (Get-StudioDisplayLastFailureState)
                    }
                    else {
                        Reset-StudioDisplayHdrGateBlock -Reason $repairReason
                    }
                }

                $script:lastDisplayRepairAt = Get-Date
                $script:pendingPowerResumeRepair = $false
                Write-AppLog "Queued unified display pipeline restore for $repairReason. Topology, 5K ladder, HDR, and brightness will be validated in one transaction instead of running a separate external-only repair first."
            }
        }

        if ($repairDueToReconnect -or $repairDueToStartup) {
            $script:pendingHdrRepair = $true
        }

        if ($studioDisplayConnected -and $script:pendingHdrRepair) {
            Invoke-StudioDisplayHdrActivation -Reason "automatic Thunderbolt hot-plug/resume restore" -Automatic | Out-Null
        }

        if ($studioDisplayConnected) {
            Restore-BrightnessServicesWhenSafe -Reason "automatic Thunderbolt hot-plug/resume restore" | Out-Null
        }

        if (-not $studioDisplayConnected) {
            $wasConnectedBeforeTick = [bool]$script:lastStudioDisplayConnected
            $script:pendingHdrRepair = $false
            Set-StudioDisplayIntegratedRepairIdle
            $script:lastIntegratedRepairStartedAt = [DateTime]::MinValue
            $script:hdrActiveResolutionSettleUntil = [DateTime]::MinValue
            Reset-StudioDisplayResolutionModeTableBlock -Reason "Studio Display disconnected"
            Reset-StudioDisplayHdrGateBlock -Reason "Studio Display disconnected"
            if ($wasConnectedBeforeTick) {
                Save-StudioDisplayPhysicalReenumerationState -Event "Disconnected" -Reason "Studio Display disconnected"
            }
            Clear-StudioDisplayLastFailureState -Reason "Studio Display disconnected"
        }

        $script:lastStudioDisplayConnected = $studioDisplayConnected
        $script:lastDisplayTopologySignature = $currentDisplayTopologySignature
        & $updateUi
    })

    Start-HdrScreenshotGuard | Out-Null

    $startupStudioDisplayConnected = Test-StudioDisplayConnected
    if (-not $startupStudioDisplayConnected) {
        Start-BrightnessServices | Out-Null
    }

    if ($startupStudioDisplayConnected) {
        $script:lastDisplayRepairAt = Get-Date
        $script:pendingHdrRepair = $true
        Save-StudioDisplayPipelineDecision -Reason "tray startup HDR restore" -Stage "StartupProbe" -Action "ProbeAndDecide" -Detail "The tray started while Studio Display evidence is present; probing current gates before deciding whether to rebuild."
        Start-StudioDisplayPassiveHotplugObserver -Reason "tray startup HDR restore" | Out-Null
        $startupRepairReady = Invoke-StudioDisplayHdrActivation -Reason "tray startup HDR restore" -Automatic
        if ($startupRepairReady -and -not (Test-StudioDisplayDeepRepairActive)) {
            Start-BrightnessServices | Out-Null
        }
        elseif ($script:hdrGateRequiresPhysicalReenumeration -and -not (Test-StudioDisplayDeepRepairActive)) {
            Start-BrightnessServices | Out-Null
            Write-AppLog "Startup brightness services started while HDR waits for physical Thunderbolt/USB re-enumeration. Stable 5K and brightness stay usable during the HDR gate hold."
        }
        else {
            Write-AppLog "Startup brightness service start deferred because Studio Display is connected and the 5K/HDR pipeline is still pending. The integrated repair will restore brightness after HDR/5K gates finish."
        }
        $script:lastStudioDisplayConnected = $true
        $script:lastDisplayTopologySignature = Get-DisplayTopologySignature
    }

    & $updateUi
    $notifyIcon.ShowBalloonTip(3000)
    $timer.Start()
    [System.Windows.Forms.Application]::Run($context)
}
finally {
    Write-AppLog "$appName tray stopped."

    Stop-HdrScreenshotGuard

    if ($timer) {
        $timer.Stop()
        $timer.Dispose()
    }

    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }

    if ($powerModeHandler) {
        [Microsoft.Win32.SystemEvents]::remove_PowerModeChanged($powerModeHandler)
    }

    foreach ($icon in @($runningIcon, $stoppedIcon, $degradedIcon)) {
        if ($icon) {
            $icon.Dispose()
        }
    }

    if (Test-Path $trayPidFile) {
        Remove-Item -LiteralPath $trayPidFile -Force -ErrorAction SilentlyContinue
    }

    if ($mutex) {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}
