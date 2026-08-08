[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$installRoot = $PSScriptRoot
$mirrorScript = Join-Path $installRoot "SystemBrightnessMirror.ps1"
$brightnessBridgeScript = Join-Path $installRoot "BrightnessKeyBridge.ps1"
$micRepairScript = Join-Path $installRoot "Repair-DiscordStudioDisplayMic.ps1"
$externalModeRepairScript = Join-Path $installRoot "Repair-StudioDisplayExternalMode.ps1"
$linkRefreshScript = Join-Path $installRoot "Refresh-StudioDisplayXdrLink.ps1"
$integratedRepairScript = Join-Path $installRoot "Repair-StudioDisplayIntegrated.ps1"
$autoRepairScript = Join-Path $installRoot "Invoke-StudioDisplayAutoRepair.ps1"
$autoRepairTaskRegistrarScript = Join-Path $installRoot "Register-StudioDisplayAutoRepairTask.ps1"
$repairProgressScript = Join-Path $installRoot "Show-StudioDisplayRepairProgress.ps1"
$advancedColorScript = Join-Path $installRoot "Get-StudioDisplayAdvancedColorState.ps1"
$hdrStateScript = Join-Path $installRoot "Set-StudioDisplayHdrState.ps1"
$resolutionLadderScript = Join-Path $installRoot "Test-StudioDisplayResolutionLadder.ps1"
$brightnessInputTraceScript = Join-Path $installRoot "Trace-StudioDisplayBrightnessInput.ps1"
$hidHelperScript = Join-Path $installRoot "StudioDisplayHid.ps1"
$mirrorPidFile = Join-Path $installRoot "SystemBrightnessMirror.pid"
$brightnessBridgePidFile = Join-Path $installRoot "BrightnessKeyBridge.pid"
$trayPidFile = Join-Path $installRoot "StudioDisplayManager.pid"
$logPath = Join-Path $installRoot "SystemBrightnessMirror.log"
$powershellExe = Join-Path $PSHOME "powershell.exe"
$schtasksExe = Join-Path $env:SystemRoot "System32\schtasks.exe"
$appName = "Studio Display XDR Win Controller"
$autoRepairTaskName = "$appName Auto Repair"
$mutexName = "StudioDisplayManager"
$statusTooltipRunning = "${appName}: Running"
$statusTooltipStopped = "${appName}: Brightness control stopped"
$studioDisplayMonitorPattern = "DISPLAY\\APPA|Studio Display|StudioDisplay|Pro Display XDR|Display XDR"
$studioDisplayUsbPattern = "VID_05AC&PID_1114|VID_05AC&PID_1116|USB4\\VID_8087&PID_5786|Studio Display|Studio Display XDR|Pro Display XDR|Apple.*Studio Display"
$studioDisplayPnpCheckCooldownSeconds = 15
$displayRepairCooldownSeconds = 45
$hdrActivationCooldownSeconds = 45
$integratedRepairCooldownSeconds = 45
$integratedRepairSettleSeconds = 15
$integratedRepairWatchdogSeconds = 150
$integratedRepairMissingTaskBackoffSeconds = 300
$autoRepairTaskRegistrationPromptBackoffSeconds = 1800
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

function Test-ManagedProcessRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PidPath
    )

    if (-not (Test-Path $PidPath)) {
        return $false
    }

    $existingPid = Get-Content -LiteralPath $PidPath | Select-Object -First 1
    if (-not $existingPid) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
    if ($process) {
        return $true
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    return $false
}

function Stop-ManagedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PidPath
    )

    if (-not (Test-Path $PidPath)) {
        return
    }

    $existingPid = Get-Content -LiteralPath $PidPath | Select-Object -First 1
    if ($existingPid) {
        $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Start-MirrorService {
    if (Test-ManagedProcessRunning -PidPath $mirrorPidFile) {
        return $true
    }

    Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $mirrorScript,
        "-EnableLogging"
    )

    Start-Sleep -Seconds 2
    return (Test-ManagedProcessRunning -PidPath $mirrorPidFile)
}

function Start-BrightnessKeyBridge {
    if (Test-ManagedProcessRunning -PidPath $brightnessBridgePidFile) {
        return $true
    }

    if (-not (Test-Path $brightnessBridgeScript)) {
        Write-AppLog "Brightness key bridge script is missing: $brightnessBridgeScript"
        return $false
    }

    Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
        "-Sta",
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $brightnessBridgeScript,
        "-EnableLogging",
        "-StepPercent", "10"
    )

    Start-Sleep -Seconds 2
    return (Test-ManagedProcessRunning -PidPath $brightnessBridgePidFile)
}

function Start-BrightnessServices {
    $mirrorStarted = Start-MirrorService
    $bridgeStarted = Start-BrightnessKeyBridge
    return [bool]($mirrorStarted -and $bridgeStarted)
}

function Stop-BrightnessServices {
    Stop-ManagedProcess -PidPath $mirrorPidFile
    Stop-ManagedProcess -PidPath $brightnessBridgePidFile
}

function Restart-BrightnessServices {
    Stop-BrightnessServices
    return (Start-BrightnessServices)
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

function Invoke-StudioDisplayExternalTopology {
    param(
        [string]$Reason = "manual",
        [switch]$AllowDuringFullscreen,
        [switch]$SkipSafetyMode,
        [switch]$AllowDisplaySwitchFallback
    )

    if (-not (Test-StudioDisplayConnected)) {
        Write-AppLog "Skipped external display topology repair for $Reason because Studio Display is not connected."
        return $false
    }

    $blockReason = if ($AllowDuringFullscreen) { $null } else { Get-DisplayRepairBlockReason }
    if ($blockReason) {
        $script:pendingDisplayRepair = $true
        Write-AppLog "Deferred external display topology repair for $Reason because $blockReason."
        return $false
    }

    if (-not (Test-Path $externalModeRepairScript)) {
        Write-AppLog "Skipped silent external display topology repair for $Reason because repair script is missing."
        return $false
    }

    try {
        $repairArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $externalModeRepairScript,
            "-Topology", "External",
            "-RequireExternalOnly",
            "-PreserveActiveHdr"
        )
        if ($SkipSafetyMode) {
            $repairArgs += "-SkipSafetyMode"
        }
        if ($AllowDisplaySwitchFallback) {
            $repairArgs += "-AllowDisplaySwitchFallback"
        }

        $repairOutput = & $powershellExe @repairArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:pendingDisplayRepair = $false
            Write-AppLog "Applied silent external display topology repair for $Reason. $($repairOutput -join ' ')"
            return $true
        }

        Write-AppLog "Silent external display topology repair for $Reason failed with exit code $LASTEXITCODE. $($repairOutput -join ' ')"
        return $false
    }
    catch {
        Write-AppLog "Silent external display topology repair for $Reason failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-StudioDisplayMicRepair {
    param(
        [string]$Reason = "manual"
    )

    if (-not (Test-Path $micRepairScript)) {
        Write-AppLog "Skipped Studio Display microphone repair for $Reason because repair script is missing."
        return $false
    }

    if (-not (Test-StudioDisplayConnected)) {
        Write-AppLog "Skipped Studio Display microphone repair for $Reason because Studio Display is not connected."
        return $false
    }

    try {
        Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass",
            "-File", $micRepairScript,
            "-EnableDesktopMicrophoneAccess"
        )
        Write-AppLog "Started Studio Display microphone repair for $Reason."
        return $true
    }
    catch {
        Write-AppLog "Studio Display microphone repair for $Reason failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-StudioDisplayLinkRefresh {
    param(
        [string]$Reason = "manual",
        [switch]$Elevate,
        [switch]$RestartFallbackMonitor,
        [switch]$RestartAppleUsb4Router
    )

    if (-not (Test-Path $linkRefreshScript)) {
        Write-AppLog "Skipped Studio Display XDR link refresh for $Reason because refresh script is missing."
        return $false
    }

    try {
        $refreshArgs = @(
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass",
            "-File", $linkRefreshScript
        )

        if ($Elevate) {
            $refreshArgs += "-Elevate"
        }

        if ($RestartFallbackMonitor) {
            $refreshArgs += "-RestartFallbackMonitor"
        }

        if ($RestartAppleUsb4Router) {
            $refreshArgs += "-RestartAppleUsb4Router"
        }

        Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList $refreshArgs
        Write-AppLog "Started Studio Display XDR link refresh for $Reason."
        return $true
    }
    catch {
        Write-AppLog "Studio Display XDR link refresh for $Reason failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-StudioDisplayIntegratedRepair {
    param(
        [string]$Reason = "manual",
        [switch]$Automatic
    )

    if (-not (Test-Path $integratedRepairScript)) {
        Write-AppLog "Skipped integrated Studio Display repair for $Reason because repair script is missing."
        return $false
    }

    $blockReason = Get-DisplayRepairBlockReason
    if ($blockReason) {
        Write-AppLog "Deferred integrated Studio Display repair for $Reason because $blockReason."
        return $false
    }

    try {
        if ($Automatic) {
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
            Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -Verb RunAs -WindowStyle Hidden -ArgumentList $repairArgs
        }
        else {
            Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -ArgumentList $repairArgs
        }

        Write-AppLog "Started integrated Studio Display repair for $Reason without refreshing the Boot Camp-style fallback driver."
        return $true
    }
    catch {
        Write-AppLog "Integrated Studio Display repair for $Reason failed: $($_.Exception.Message)"
        return $false
    }
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
            HasCurrent5K = [bool]($probeText -match 'Current mode:\s+5120x2880@')
            Has5K60Enumerated = [bool]($probeText -match '5K 60Hz legacy Studio Display fallback\s+5120\s+2880\s+60\s+True' -or $probeText -match 'Best enumerated mode:\s+5120x2880@60Hz')
            Has5K120Enumerated = [bool]($probeText -match '5K 120Hz native XDR target\s+5120\s+2880\s+120\s+True' -or $probeText -match 'Best enumerated mode:\s+5120x2880@120Hz')
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
            HdrActive = [bool]($probeText -match 'ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR' -or $probeText -match 'HighDynamicRangeUserEnabled\s*:\s*True')
            HdrSupported = [bool]($probeText -match 'HighDynamicRangeSupported\s*:\s*True')
            HdrUnsupported = [bool]($probeText -match 'HighDynamicRangeSupported\s*:\s*False')
            WcgActive = [bool]($probeText -match 'ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG' -or $probeText -match 'WideColorUserEnabled\s*:\s*True')
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
        return ""
    }
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

    if (Test-StudioDisplayPipelineStable -ResolutionState $resolutionState -HdrState $hdrState) {
        $script:integratedRepairInFlight = $false
        $script:pendingHdrRepair = $false
        Write-AppLog "Integrated display pipeline restore verified for $Reason. Gate: current5K=$($resolutionState.HasCurrent5K), 5K60Enumerated=$($resolutionState.Has5K60Enumerated), hdrActive=$($hdrState.HdrActive)."
        return "Restored"
    }

    $gateText = "taskState=$taskState, current5K=$($resolutionState.HasCurrent5K), 5K60Enumerated=$($resolutionState.Has5K60Enumerated), hdrSupported=$($hdrState.HdrSupported), hdrActive=$($hdrState.HdrActive)"

    if ($elapsedSeconds -ge $integratedRepairWatchdogSeconds) {
        $script:integratedRepairInFlight = $false
        $script:pendingHdrRepair = $true
        $script:lastIntegratedRepairAt = [DateTime]::MinValue
        Write-AppLog "Integrated display pipeline restore watchdog expired for $Reason after $([int]$elapsedSeconds)s. Releasing cooldown for retry. Gate: $gateText."
        return "Retry"
    }

    if ($taskState -eq "Running" -or $elapsedSeconds -lt $integratedRepairSettleSeconds) {
        $script:pendingHdrRepair = $true
        if (($now - $script:lastIntegratedRepairWaitLogAt).TotalSeconds -ge 15) {
            $script:lastIntegratedRepairWaitLogAt = $now
            Write-AppLog "Waiting for integrated display pipeline restore to finish for $Reason. Gate: $gateText."
        }
        return "Waiting"
    }

    $script:integratedRepairInFlight = $false
    $script:pendingHdrRepair = $true
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
        $script:pendingHdrRepair = $false
        $script:integratedRepairInFlight = $false
        return $false
    }

    $blockReason = Get-DisplayRepairBlockReason
    if ($blockReason) {
        $script:pendingHdrRepair = $true
        Write-AppLog "Deferred display pipeline restore for $Reason because $blockReason."
        return $false
    }

    $repairMonitorState = Update-StudioDisplayIntegratedRepairMonitor -Reason $Reason
    if ($repairMonitorState -eq "Restored") {
        return $true
    }
    elseif ($repairMonitorState -eq "Waiting") {
        return $false
    }

    $now = Get-Date
    if ($script:integratedRepairUnavailableUntil -and $now -lt $script:integratedRepairUnavailableUntil) {
        $script:pendingHdrRepair = $true
        if (($now - $script:lastIntegratedRepairCooldownLogAt).TotalSeconds -ge 60) {
            $script:lastIntegratedRepairCooldownLogAt = $now
            Write-AppLog "Deferred deep display pipeline restore for $Reason because the elevated auto repair task is still unavailable until $($script:integratedRepairUnavailableUntil.ToString('HH:mm:ss'))."
        }
        return $false
    }

    $resolutionState = Get-StudioDisplayResolutionRuntimeState
    $resolutionNeedsDeepRepair = (
        -not $resolutionState.Known -or
        -not $resolutionState.HasCurrent5K -or
        -not $resolutionState.Has5K60Enumerated
    )

    if ($resolutionNeedsDeepRepair) {
        if (($now - $script:lastIntegratedRepairAt).TotalSeconds -lt $integratedRepairCooldownSeconds) {
            $script:pendingHdrRepair = $true
            if (($now - $script:lastIntegratedRepairCooldownLogAt).TotalSeconds -ge 15) {
                $script:lastIntegratedRepairCooldownLogAt = $now
                $resolutionText = if ($resolutionState.Known) { "current5K=$($resolutionState.HasCurrent5K), 5K60Enumerated=$($resolutionState.Has5K60Enumerated)" } else { "resolution state unknown" }
                Write-AppLog "Deferred deep display pipeline restore for $Reason because integrated repair cooldown is still active. Gate: $resolutionText."
            }
            return $false
        }

        $started = Invoke-StudioDisplayIntegratedRepair -Reason "$Reason (resolution/HDR ladder restore)" -Automatic:$Automatic
        if ($started) {
            $script:lastIntegratedRepairAt = $now
            $script:lastIntegratedRepairStartedAt = $now
            $script:lastIntegratedRepairWaitLogAt = [DateTime]::MinValue
            $script:integratedRepairInFlight = $true
            $script:pendingHdrRepair = $true
            Write-AppLog "Started deep integrated display pipeline restore for $Reason because the 5K ladder is not stable; HDR will stay pending until verification succeeds."
        }
        else {
            $script:lastIntegratedRepairAt = $now
            $script:pendingHdrRepair = $true
        }

        return $started
    }

    $state = Get-StudioDisplayHdrRuntimeState
    if ($state.HdrActive) {
        $script:pendingHdrRepair = $false
        Write-AppLog "Display pipeline restore skipped for $Reason because 5K60 is stable and HDR is already active."
        return $true
    }

    if ($state.Known -and $state.HdrSupported) {
        if (-not (Test-Path $hdrStateScript)) {
            Write-AppLog "Skipped lightweight HDR restore for $Reason because HDR state script is missing."
            return $false
        }

        if (($now - $script:lastHdrActivationAt).TotalSeconds -lt $hdrActivationCooldownSeconds) {
            $script:pendingHdrRepair = $true
            Write-AppLog "Deferred lightweight HDR restore for $Reason because HDR activation cooldown is still active."
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
            return $true
        }
        catch {
            Write-AppLog "Lightweight HDR restore for $Reason failed: $($_.Exception.Message)"
            return $false
        }
    }

    if (($now - $script:lastIntegratedRepairAt).TotalSeconds -lt $integratedRepairCooldownSeconds) {
        $script:pendingHdrRepair = $true
        if (($now - $script:lastIntegratedRepairCooldownLogAt).TotalSeconds -ge 15) {
            $script:lastIntegratedRepairCooldownLogAt = $now
            $gateText = if ($state.HdrUnsupported) { "HighDynamicRangeSupported=False" } elseif ($state.Known) { "HDR state is known but not supported" } else { "HDR state is unknown" }
            Write-AppLog "Deferred deep display pipeline restore for $Reason because integrated repair cooldown is still active. Gate: $gateText."
        }
        return $false
    }

    $started = Invoke-StudioDisplayIntegratedRepair -Reason "$Reason (HDR gate restore)" -Automatic:$Automatic
    if ($started) {
        $script:lastIntegratedRepairAt = $now
        $script:lastIntegratedRepairStartedAt = $now
        $script:lastIntegratedRepairWaitLogAt = [DateTime]::MinValue
        $script:integratedRepairInFlight = $true
        $script:pendingHdrRepair = $true
        $gateText = if ($state.HdrUnsupported) { "HighDynamicRangeSupported=False" } elseif ($state.Known) { "HDR state known but inactive" } else { "HDR state unknown" }
        Write-AppLog "Started deep integrated display pipeline restore for $Reason. Gate: $gateText. HDR will stay pending until verification succeeds."
    }
    else {
        $script:lastIntegratedRepairAt = $now
        $script:pendingHdrRepair = $true
    }

    return $started
}

function Show-StudioDisplayHdrBrightnessContext {
    $hdrText = "HDR 状态：未知"
    $sdrWhiteText = "SDR 内容亮度：未知"
    $hardwareBrightnessText = "Studio Display 硬件亮度：未知"

    try {
        if (Test-Path $advancedColorScript) {
            $stateText = (@(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $advancedColorScript -SkipDxDiagFallback 2>&1) -join "`n")
            if ($stateText -match 'ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR') {
                $hdrText = "HDR 状态：已开启"
            }
            elseif ($stateText -match 'ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG') {
                $hdrText = "HDR 状态：WCG/Advanced Color，不是真 HDR"
            }
            elseif ($stateText -match 'ActiveColorMode\s*:\s*(.+)') {
                $hdrText = "HDR 状态：$($Matches[1].Trim())"
            }

            if ($stateText -match 'SdrWhiteLevelNits\s*:\s*([0-9.]+)') {
                $sdrWhiteText = "SDR 内容亮度：$($Matches[1]) nits paper-white"
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

    $messageLines = @(
        $hdrText,
        $hardwareBrightnessText,
        $sdrWhiteText,
        "",
        "HDR 开启后，Windows 的 'SDR 内容亮度' 是 SDR white/paper-white 映射，不是外接显示器背光。",
        "Studio Display XDR 的真实背光仍由 Apple HID/参考模式控制；某些 Apple reference mode 下亮度控制可能被锁定或弱化。"
    )

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

Set-Content -LiteralPath $trayPidFile -Value $PID -Encoding ascii
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
$pendingDisplayRepair = $false
$pendingPowerResumeRepair = $false
$pendingHdrRepair = $false
$lastHdrActivationAt = [DateTime]::MinValue
$lastIntegratedRepairAt = [DateTime]::MinValue
$lastIntegratedRepairStartedAt = [DateTime]::MinValue
$lastIntegratedRepairWaitLogAt = [DateTime]::MinValue
$lastIntegratedRepairCooldownLogAt = [DateTime]::MinValue
$integratedRepairUnavailableUntil = [DateTime]::MinValue
$integratedRepairInFlight = $false
$lastAutoRepairTaskRegistrationPromptAt = [DateTime]::MinValue
$lastStudioDisplayPnpCheckAt = [DateTime]::MinValue
$lastStudioDisplayPnpCheckResult = $false

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
            $script:pendingDisplayRepair = $true
            $script:pendingHdrRepair = $true
            $script:lastStudioDisplayPnpCheckAt = [DateTime]::MinValue
            $script:lastDisplayRepairAt = [DateTime]::MinValue
            Write-AppLog "Power resume detected; scheduling Studio Display XDR external-only topology and HDR restore."
        }
    }
    [Microsoft.Win32.SystemEvents]::add_PowerModeChanged($powerModeHandler)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    $statusItem.Text = "状态：正在检查"

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem "亮度控制：启动"
    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem "亮度控制：重启"
    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem "亮度控制：停止"
    $repairDisplayItem = New-Object System.Windows.Forms.ToolStripMenuItem "外屏唯一：立即修复"
    $refreshDisplayItem = New-Object System.Windows.Forms.ToolStripMenuItem "外屏唯一：刷新链路并修复"
    $refreshDisplayElevatedItem = New-Object System.Windows.Forms.ToolStripMenuItem "外屏唯一：管理员刷新链路"
    $integratedRepairItem = New-Object System.Windows.Forms.ToolStripMenuItem "统一修复：5K/HDR/亮度"
    $registerAutoRepairTaskItem = New-Object System.Windows.Forms.ToolStripMenuItem "自动修复权限：注册/修复"
    $hdrBrightnessContextItem = New-Object System.Windows.Forms.ToolStripMenuItem "HDR 亮度：查看当前语境"
    $openHdrSettingsItem = New-Object System.Windows.Forms.ToolStripMenuItem "HDR 亮度：打开 Windows 设置"
    $brightnessInputTraceItem = New-Object System.Windows.Forms.ToolStripMenuItem "亮度输入：监听鼠标按键"
    $repairMicItem = New-Object System.Windows.Forms.ToolStripMenuItem "Discord 麦克风：立即修复"
    $openLogItem = New-Object System.Windows.Forms.ToolStripMenuItem "打开日志"
    $openFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem "打开安装目录"
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem "退出"

    [void]$menu.Items.Add($statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($startItem)
    [void]$menu.Items.Add($restartItem)
    [void]$menu.Items.Add($stopItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($repairDisplayItem)
    [void]$menu.Items.Add($refreshDisplayItem)
    [void]$menu.Items.Add($refreshDisplayElevatedItem)
    [void]$menu.Items.Add($integratedRepairItem)
    [void]$menu.Items.Add($registerAutoRepairTaskItem)
    [void]$menu.Items.Add($hdrBrightnessContextItem)
    [void]$menu.Items.Add($openHdrSettingsItem)
    [void]$menu.Items.Add($brightnessInputTraceItem)
    [void]$menu.Items.Add($repairMicItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($openLogItem)
    [void]$menu.Items.Add($openFolderItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($exitItem)

    $notifyIcon.ContextMenuStrip = $menu

    $updateUi = {
        $mirrorRunning = Test-ManagedProcessRunning -PidPath $mirrorPidFile
        $bridgeRunning = Test-ManagedProcessRunning -PidPath $brightnessBridgePidFile
        $brightnessRunning = [bool]($mirrorRunning -and $bridgeRunning)

        if ($script:integratedRepairInFlight) {
            $statusItem.Text = "状态：正在自动验证/恢复 5K、HDR 和亮度管线"
            $startItem.Enabled = -not $mirrorRunning
            $restartItem.Enabled = $brightnessRunning
            $stopItem.Enabled = $brightnessRunning
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "${appName}: Auto repair"
        }
        elseif ($brightnessRunning) {
            $statusItem.Text = "状态：亮度镜像和按键桥运行中；外屏管线监控中"
            $startItem.Enabled = $false
            $restartItem.Enabled = $true
            $stopItem.Enabled = $true
            $notifyIcon.Icon = $runningIcon
            $notifyIcon.Text = $statusTooltipRunning
        } else {
            $statusItem.Text = "状态：亮度控制未完整运行；外屏管线监控中"
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

    $repairDisplayItem.add_Click({
        Invoke-StudioDisplayExternalTopology -Reason "tray menu" -AllowDuringFullscreen | Out-Null
    })

    $refreshDisplayItem.add_Click({
        Invoke-StudioDisplayLinkRefresh -Reason "tray menu" | Out-Null
    })

    $refreshDisplayElevatedItem.add_Click({
        Invoke-StudioDisplayLinkRefresh -Reason "tray menu elevated" -Elevate -RestartFallbackMonitor | Out-Null
    })

    $integratedRepairItem.add_Click({
        $result = [System.Windows.Forms.MessageBox]::Show(
            "这会按顺序执行：强制 Studio Display XDR 成为唯一活动显示器；保留已激活的 HDR；检查 5K 模式表；暂停亮度镜像/按键桥；管理员重启 MS_0001/Apple USB4 链路并修复失败的 Apple USB/HID 控制接口；尝试 HDR；最后恢复亮度组件。默认不会刷新 Boot Camp-style monitor fallback。屏幕可能短暂黑屏/闪烁。是否继续？",
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
                '已经请求 Windows 弹出 UAC。请点击“是”完成一次性授权；之后 Thunderbolt 热插拔就可以后台自动运行 5K/HDR 修复。',
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

    $hdrBrightnessContextItem.add_Click({
        Show-StudioDisplayHdrBrightnessContext
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

    $repairMicItem.add_Click({
        Invoke-StudioDisplayMicRepair -Reason "tray menu" | Out-Null
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
        if (-not (Test-ManagedProcessRunning -PidPath $mirrorPidFile) -or -not (Test-ManagedProcessRunning -PidPath $brightnessBridgePidFile)) {
            Start-BrightnessServices | Out-Null
            & $updateUi
        } else {
            Start-Process -FilePath "explorer.exe" -ArgumentList @($installRoot)
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.add_Tick({
        $studioDisplayConnected = Test-StudioDisplayConnected
        $currentDisplayTopologySignature = Get-DisplayTopologySignature
        $repairDueToReconnect = $studioDisplayConnected -and -not $script:lastStudioDisplayConnected
        $repairDueToStartup = $studioDisplayConnected -and $script:lastDisplayRepairAt -eq [DateTime]::MinValue
        $repairDueToDeferredFullscreen = $studioDisplayConnected -and $script:pendingDisplayRepair
        $repairDueToPowerResume = $studioDisplayConnected -and $script:pendingPowerResumeRepair
        $repairDueToTopologyChange = (
            $studioDisplayConnected -and
            $script:lastStudioDisplayConnected -and
            $script:lastDisplayTopologySignature -and
            $currentDisplayTopologySignature -ne $script:lastDisplayTopologySignature
        )
        $repairCooldownElapsed = ((Get-Date) - $script:lastDisplayRepairAt).TotalSeconds -ge $displayRepairCooldownSeconds
        $topologyRepairCooldownElapsed = ((Get-Date) - $script:lastDisplayRepairAt).TotalSeconds -ge 8

        $shouldRepairNow = (
            $repairDueToReconnect -or
            $repairDueToStartup -or
            $repairDueToPowerResume -or
            ($repairDueToDeferredFullscreen -and $repairCooldownElapsed) -or
            ($repairDueToTopologyChange -and $topologyRepairCooldownElapsed)
        )

        if ($shouldRepairNow) {
            $script:pendingHdrRepair = $true
            if ($repairDueToReconnect -or $repairDueToPowerResume -or $repairDueToTopologyChange) {
                $script:integratedRepairInFlight = $false
                $script:lastIntegratedRepairAt = [DateTime]::MinValue
                $script:lastHdrActivationAt = [DateTime]::MinValue
                $script:integratedRepairUnavailableUntil = [DateTime]::MinValue
                $script:lastAutoRepairTaskRegistrationPromptAt = [DateTime]::MinValue
            }
            $script:lastDisplayRepairAt = Get-Date
            $repairReason = if ($repairDueToPowerResume) {
                "power resume or sleep-time hot-plug detection"
            } elseif ($repairDueToTopologyChange) {
                "display topology changed while Studio Display is connected"
            } elseif ($repairDueToDeferredFullscreen) {
                "deferred repair after fullscreen ended"
            } else {
                "Studio Display connect/startup detection"
            }
            if (Invoke-StudioDisplayExternalTopology -Reason $repairReason -SkipSafetyMode:($repairDueToDeferredFullscreen -or $repairDueToTopologyChange)) {
                $script:pendingPowerResumeRepair = $false
                $currentDisplayTopologySignature = Get-DisplayTopologySignature
            }
        }

        if ($repairDueToReconnect -or $repairDueToStartup) {
            $script:pendingHdrRepair = $true
            Invoke-StudioDisplayMicRepair -Reason "Studio Display connect/startup detection" | Out-Null
        }

        if ($studioDisplayConnected -and $script:pendingHdrRepair) {
            Invoke-StudioDisplayHdrActivation -Reason "automatic Thunderbolt hot-plug/resume restore" -Automatic | Out-Null
        }

        if (-not $studioDisplayConnected) {
            $script:pendingHdrRepair = $false
            $script:integratedRepairInFlight = $false
        }

        $script:lastStudioDisplayConnected = $studioDisplayConnected
        $script:lastDisplayTopologySignature = $currentDisplayTopologySignature
        & $updateUi
    })

    Start-BrightnessServices | Out-Null
    if (Test-StudioDisplayConnected) {
        $script:lastDisplayRepairAt = Get-Date
        Invoke-StudioDisplayExternalTopology -Reason "tray startup" | Out-Null
        Invoke-StudioDisplayMicRepair -Reason "tray startup" | Out-Null
        $script:pendingHdrRepair = $true
        Invoke-StudioDisplayHdrActivation -Reason "tray startup HDR restore" -Automatic | Out-Null
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
