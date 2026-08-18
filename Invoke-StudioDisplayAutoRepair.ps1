[CmdletBinding()]
param(
    [string]$Reason = "scheduled hot-plug HDR repair",
    [switch]$ValidateOnly
)

$ErrorActionPreference = "Continue"

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

$scriptRoot = $PSScriptRoot
$reportsRoot = Join-Path $scriptRoot "reports"
$integratedRepairScript = Join-Path $scriptRoot "Repair-StudioDisplayIntegrated.ps1"
$resolutionLadderScript = Join-Path $scriptRoot "Test-StudioDisplayResolutionLadder.ps1"
$advancedColorScript = Join-Path $scriptRoot "Get-StudioDisplayAdvancedColorState.ps1"
$brightnessHidScript = Join-Path $scriptRoot "StudioDisplayHid.ps1"
$logPath = Join-Path $reportsRoot ("StudioDisplayAutoIntegratedRepair-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$launcherLog = Join-Path $reportsRoot "StudioDisplayAutoRepairTask.log"
$knownGoodStateFile = Join-Path $scriptRoot "StudioDisplayKnownGoodState.json"
$lastFailureStateFile = Join-Path $scriptRoot "StudioDisplayLastFailureState.json"
$hdrGateBlockStateFile = Join-Path $scriptRoot "StudioDisplayHdrGateBlockState.json"
$automationMaintenanceStateFile = Join-Path $scriptRoot "StudioDisplayAutomationMaintenanceState.json"
$powershellExe = Resolve-StudioDisplayPowerShellExe

New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null

function Write-AutoRepairLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Add-Content -LiteralPath $launcherLog -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
}

function Get-AutoRepairSystemBootTime {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os -and $os.LastBootUpTime) {
            return [DateTime]$os.LastBootUpTime
        }
    }
    catch {
        Write-AutoRepairLog "Could not read system boot time: $($_.Exception.Message)"
    }

    return [DateTime]::MinValue
}

function Save-AutoRepairMaintenanceState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [string]$Detail = "",
        [object]$State = $null,
        [object]$GateState = $null
    )

    try {
        $maintenanceState = [ordered]@{
            Version = 1
            UpdatedAt = (Get-Date).ToString("o")
            Stage = $Stage
            Action = $Action
            Detail = $Detail
            Gate = if ($GateState) {
                [ordered]@{
                    RequiresPhysicalReenumeration = [bool]$GateState.RequiresPhysicalReenumeration
                    BlockedUntil = [string]$GateState.BlockedUntil
                    Reason = [string]$GateState.Reason
                    UpdatedAt = [string]$GateState.UpdatedAt
                }
            } else { $null }
            Current = if ($State) {
                [ordered]@{
                    Current5K = [bool]$State.Current5K
                    FiveK60Enumerated = [bool]$State.FiveK60Enumerated
                    HdrSupported = [bool]$State.HdrSupported
                    HdrActive = [bool]$State.HdrActive
                    BrightnessOk = [bool]$State.BrightnessOk
                    Detail = [string]$State.Detail
                }
            } else { $null }
            SuccessPrerequisites = @(
                "Do not run disruptive repair when stable 5K60 is already present and Windows still says HighDynamicRangeSupported=False after Apple USB failed-start evidence.",
                "Wait for reconnect, resume, reboot, or a later probe where HighDynamicRangeSupported=True before SET_HDR_STATE.",
                "Keep brightness and 5K visible state intact while the HDR capability gate is closed."
            )
        }

        $maintenanceState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $automationMaintenanceStateFile -Encoding ascii -ErrorAction Stop
    }
    catch {
        Write-AutoRepairLog "Could not save auto repair maintenance state: $($_.Exception.Message)"
    }
}

function Test-AutoRepairPhysicalReenumerationGateActive {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    try {
        $gateState = $null
        if (Test-Path -LiteralPath $hdrGateBlockStateFile) {
            $gateState = Get-Content -LiteralPath $hdrGateBlockStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        }

        if (-not $gateState -or -not [bool]$gateState.RequiresPhysicalReenumeration) {
            $lastFailure = $null
            if (Test-Path -LiteralPath $lastFailureStateFile) {
                $lastFailure = Get-Content -LiteralPath $lastFailureStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
            }

            $classification = if ($lastFailure) { [string]$lastFailure.Classification } else { "" }
            $lastFailureRequiresPhysical = [bool](
                $lastFailure -and
                (
                    [bool]$lastFailure.AppleUsbReferenceModeFailedStart -or
                    $classification -match 'AppleUsbReferenceModeFailedStart'
                )
            )

            if (-not $lastFailureRequiresPhysical) {
                return $false
            }

            $gateState = [pscustomobject]@{
                Version = 1
                BlockedUntil = (Get-Date).AddHours(12).ToString("o")
                Count = 1
                RequiresPhysicalReenumeration = $true
                Reason = "auto repair restored physical gate from last failure"
                UpdatedAt = (Get-Date).ToString("o")
            }
            $gateState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $hdrGateBlockStateFile -Encoding ascii -ErrorAction SilentlyContinue
            Write-AutoRepairLog "Restored HDR physical re-enumeration gate from last failure state before running disruptive repair. classification=$classification"
        }

        $updatedAt = [DateTime]::MinValue
        [void][DateTime]::TryParse([string]$gateState.UpdatedAt, [ref]$updatedAt)
        $bootTime = Get-AutoRepairSystemBootTime
        if ($bootTime -gt [DateTime]::MinValue -and $updatedAt -gt [DateTime]::MinValue -and $updatedAt -lt $bootTime) {
            Remove-Item -LiteralPath $hdrGateBlockStateFile -Force -ErrorAction SilentlyContinue
            Write-AutoRepairLog "Cleared HDR physical re-enumeration gate because the machine rebooted after it was recorded."
            return $false
        }

        if ($State.HdrSupported -or $State.HdrActive) {
            Remove-Item -LiteralPath $hdrGateBlockStateFile -Force -ErrorAction SilentlyContinue
            Write-AutoRepairLog "Cleared HDR physical re-enumeration gate because HDR support/active state is now visible."
            return $false
        }

        $gateStillMatches = [bool](
            $State.Current5K -and
            $State.FiveK60Enumerated -and
            -not $State.HdrSupported -and
            -not $State.HdrActive
        )

        if ($gateStillMatches) {
            Save-AutoRepairMaintenanceState -Stage "HdrGateWaitingForPhysicalReenumeration" -Action "SkipDeepRepair" -Detail "Preflight still matches the last HDR physical gate: 5K60 is stable, but HighDynamicRangeSupported=False." -State $State -GateState $gateState
            return $true
        }
    }
    catch {
        Write-AutoRepairLog "Could not evaluate HDR physical re-enumeration gate: $($_.Exception.Message)"
    }

    return $false
}

function Get-AutoRepairAppleUsbState {
    $state = [ordered]@{
        QueryOk = $false
        Error = $null
        DeviceCount = 0
        FailedCount = 0
        FailedMi08Mi09Count = 0
        FailedMi08Mi09 = @()
    }

    try {
        $devices = @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.InstanceId -match 'VID_05AC&PID_1116' } |
            Select-Object Class, FriendlyName, Status, Problem, ConfigManagerErrorCode, InstanceId)

        $failed = @($devices | Where-Object {
            $statusNotOk = [bool]($_.Status -and $_.Status -ne "OK")
            $problemText = [string]$_.Problem
            $problemNotOk = [bool]($problemText -and $problemText -ne "CM_PROB_NONE")
            $configText = [string]$_.ConfigManagerErrorCode
            $configNotOk = [bool]($configText -and $configText -notin @("0", "CM_PROB_NONE"))
            $statusNotOk -or $problemNotOk -or $configNotOk
        })
        $failedMi08Mi09 = @($failed | Where-Object { $_.InstanceId -match 'MI_08|MI_09' })

        $state.QueryOk = $true
        $state.DeviceCount = $devices.Count
        $state.FailedCount = $failed.Count
        $state.FailedMi08Mi09Count = $failedMi08Mi09.Count
        $state.FailedMi08Mi09 = @($failedMi08Mi09 | ForEach-Object {
            [pscustomobject]@{
                Class = $_.Class
                FriendlyName = $_.FriendlyName
                Status = $_.Status
                Problem = $_.Problem
                ConfigManagerErrorCode = $_.ConfigManagerErrorCode
                InstanceId = $_.InstanceId
            }
        })
    }
    catch {
        $state.Error = $_.Exception.Message
    }

    return [pscustomobject]$state
}

function Test-AutoRepairCodeZeroState {
    $resolutionOutput = @()
    $hdrOutput = @()
    $brightnessOutput = @()

    if (-not (Test-Path -LiteralPath $resolutionLadderScript)) {
        return [pscustomobject]@{
            Ready = $false
            Detail = "resolution ladder script missing"
        }
    }

    if (-not (Test-Path -LiteralPath $advancedColorScript)) {
        return [pscustomobject]@{
            Ready = $false
            Detail = "advanced color script missing"
        }
    }

    if (-not (Test-Path -LiteralPath $brightnessHidScript)) {
        return [pscustomobject]@{
            Ready = $false
            Detail = "brightness HID script missing"
        }
    }

    $resolutionOutput = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $resolutionLadderScript 2>&1)
    $resolutionExitCode = $LASTEXITCODE
    $resolutionText = ($resolutionOutput -join "`n")
    $hasCurrent5K = [bool]($resolutionText -match '(?m)^Current mode:[^\S\r\n]+5120x2880@')
    $has5K60Enumerated = [bool](
        $resolutionText -match '(?m)^5K 60Hz legacy Studio Display fallback[^\r\n]*[^\S\r\n]+5120[^\S\r\n]+2880[^\S\r\n]+60[^\S\r\n]+True(?:[^\S\r\n]|$)' -or
        $resolutionText -match '(?m)^Best enumerated mode:[^\S\r\n]+5120x2880@60Hz[^\S\r\n]*$'
    )

    $hdrOutput = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $advancedColorScript -SkipDxDiagFallback 2>&1)
    $hdrExitCode = $LASTEXITCODE
    $hdrText = ($hdrOutput -join "`n")
    $hdrActive = [bool](
        $hdrText -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR[^\S\r\n]*$' -or
        $hdrText -match '(?m)^[^\S\r\n]*HighDynamicRangeUserEnabled[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$'
    )
    $hdrSupported = [bool]($hdrText -match '(?m)^[^\S\r\n]*HighDynamicRangeSupported[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$')

    $brightnessOutput = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $brightnessHidScript -GetPercent 2>&1)
    $brightnessExitCode = $LASTEXITCODE
    $brightnessText = ($brightnessOutput -join "`n")
    $brightnessOk = [bool]($brightnessExitCode -eq 0 -and $brightnessText -match '(?m)^\s*\d+\s*$')
    $brightnessPercent = $null
    if ($brightnessOk -and $brightnessText -match '(?m)^\s*(\d+)\s*$') {
        $brightnessPercent = [int]$Matches[1]
    }

    $appleUsbState = Get-AutoRepairAppleUsbState

    $ready = [bool](
        $resolutionExitCode -eq 0 -and
        $hasCurrent5K -and
        $has5K60Enumerated -and
        $hdrExitCode -eq 0 -and
        $hdrSupported -and
        $hdrActive -and
        $brightnessOk
    )

    return [pscustomobject]@{
        Ready = $ready
        Detail = "resolutionExit=$resolutionExitCode,current5K=$hasCurrent5K,5K60Enumerated=$has5K60Enumerated,hdrExit=$hdrExitCode,hdrSupported=$hdrSupported,hdrActive=$hdrActive,brightnessExit=$brightnessExitCode,brightnessOk=$brightnessOk,appleUsbQueryOk=$($appleUsbState.QueryOk),appleUsbFailedMi08Mi09=$($appleUsbState.FailedMi08Mi09Count)"
        ResolutionExitCode = $resolutionExitCode
        Current5K = $hasCurrent5K
        FiveK60Enumerated = $has5K60Enumerated
        HdrExitCode = $hdrExitCode
        HdrSupported = $hdrSupported
        HdrActive = $hdrActive
        BrightnessExitCode = $brightnessExitCode
        BrightnessOk = $brightnessOk
        BrightnessPercent = $brightnessPercent
        AppleUsb = $appleUsbState
    }
}

function Save-AutoRepairKnownGoodState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [string]$Reason = "",
        [string]$RepairLog = ""
    )

    if (-not $State.Ready) {
        return
    }

    try {
        $knownGoodState = [pscustomobject]@{
            Version = 1
            UpdatedAt = (Get-Date).ToString("o")
            Reason = $Reason
            RepairLog = $RepairLog
            CodeZeroReady = [bool]$State.Ready
            Current5K = [bool]$State.Current5K
            FiveK60Enumerated = [bool]$State.FiveK60Enumerated
            HdrSupported = [bool]$State.HdrSupported
            HdrActive = [bool]$State.HdrActive
            BrightnessOk = [bool]$State.BrightnessOk
            BrightnessPercent = $State.BrightnessPercent
            AppleUsb = $State.AppleUsb
            ValidationDetail = $State.Detail
            SuccessRecipe = @(
                "Detect active MS_0001 monitor identity inside integrated repair.",
                "Use the Boot Camp-style monitor INF as the single default MS_0001 HDR identity; Generic/Digital Flat Panel fallback is diagnostic-only.",
                "Refresh Boot Camp-style monitor INF when MS_0001 uses monitor.inf, the generated driver package is missing, the current binding is not this project's oem*.inf, or the active EDID cache lacks HDR static metadata.",
                "Wait for the Boot Camp-style MS_0001 identity to settle before HDR, then retrain the Apple Studio Display XDR USB4 router when needed.",
                "Require current 5120x2880 and an enumerated 5120x2880@60 mode table entry.",
                "Require HighDynamicRangeSupported=True and ActiveColorMode=HDR or HighDynamicRangeUserEnabled=True.",
                "Require Studio Display HID brightness readback before returning code=0.",
                "Record Apple USB MI_08/MI_09 failures for diagnostics, but do not block code=0 when 5K60, HDR active, and brightness HID all validate."
            )
        }

        $knownGoodState |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $knownGoodStateFile -Encoding ascii
        Write-AutoRepairLog "Saved known-good Studio Display recovery state. File=$knownGoodStateFile"
    }
    catch {
        Write-AutoRepairLog "Could not save known-good Studio Display recovery state: $($_.Exception.Message)"
    }
}

function Save-AutoRepairFailureState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,
        [int]$ExitCode,
        [string]$Reason = "",
        [string]$RepairLog = ""
    )

    try {
        $repairLogText = ""
        if (-not [string]::IsNullOrWhiteSpace($RepairLog) -and (Test-Path -LiteralPath $RepairLog)) {
            $repairLogText = Get-Content -LiteralPath $RepairLog -Raw -ErrorAction SilentlyContinue
        }

        $modeTableBlocked = [bool](-not $State.FiveK60Enumerated)
        $hdrGateClosed = [bool](
            -not $State.HdrSupported -and
            -not $State.HdrActive
        )
        $hdrGateBlocked = [bool](
            $State.Current5K -and
            $State.FiveK60Enumerated -and
            $hdrGateClosed
        )
        $appleUsbReferenceModeFailedStart = [bool](
            ($State.AppleUsb -and $State.AppleUsb.QueryOk -and [int]$State.AppleUsb.FailedMi08Mi09Count -gt 0) -or
            (
                $repairLogText -match 'CM_PROB_FAILED_START' -and
                (
                    $repairLogText -match 'VID_05AC&PID_1116&MI_08' -or
                    $repairLogText -match 'VID_05AC&PID_1116&MI_09'
                )
            )
        )
        $classification = if ($modeTableBlocked -and $hdrGateClosed -and $appleUsbReferenceModeFailedStart) {
            "ResolutionModeTableAndHdrGateBlockedWithAppleUsbReferenceModeFailedStart"
        }
        elseif ($modeTableBlocked -and $hdrGateClosed) {
            "ResolutionModeTableAndHdrGateBlocked"
        }
        elseif ($hdrGateBlocked -and $appleUsbReferenceModeFailedStart) {
            "HdrGateBlockedWithAppleUsbReferenceModeFailedStart"
        }
        elseif ($hdrGateBlocked) {
            "HdrGateBlockedWithStable5K60"
        }
        elseif ($modeTableBlocked) {
            "ResolutionModeTableBlocked"
        }
        elseif (-not $State.BrightnessOk) {
            "BrightnessHidReadbackBlocked"
        }
        else {
            "Unknown"
        }

        $failureState = [pscustomobject]@{
            Version = 1
            UpdatedAt = (Get-Date).ToString("o")
            Reason = $Reason
            ExitCode = $ExitCode
            Classification = $classification
            RepairLog = $RepairLog
            Current5K = [bool]$State.Current5K
            FiveK60Enumerated = [bool]$State.FiveK60Enumerated
            HdrSupported = [bool]$State.HdrSupported
            HdrActive = [bool]$State.HdrActive
            BrightnessOk = [bool]$State.BrightnessOk
            BrightnessPercent = $State.BrightnessPercent
            AppleUsb = $State.AppleUsb
            AppleUsbReferenceModeFailedStart = $appleUsbReferenceModeFailedStart
            ValidationDetail = $State.Detail
            NextAction = if ($modeTableBlocked -and $hdrGateClosed -and $appleUsbReferenceModeFailedStart) {
                "Do not keep sending HDR packets against this state. Preserve the current visible desktop, then use a fresh Boot Camp-style USB4/router re-enumeration on the next physical reconnect or controlled repair round; verify 5K60 mode table first, then HDR."
            }
            elseif ($modeTableBlocked -and $hdrGateClosed) {
                "Treat this as a mode-table/link identity failure before HDR. Rebuild Boot Camp-style identity and USB4 link, then re-check HDR only after 5K60 is enumerated."
            }
            elseif ($appleUsbReferenceModeFailedStart) {
                "Stop repeating HDR packets. Keep 5K60 and brightness, back off deep repair, and wait for a fresh Thunderbolt/USB4 physical re-enumeration or power-resume event before retrying."
            }
            elseif ($hdrGateBlocked) {
                "Stop repeating HDR packets. Keep 5K60 and brightness, and retry only after reconnect, resume, or a controlled identity/link refresh."
            }
            else {
                "Review the repair log before retrying disruptive topology, USB4, or HDR stages."
            }
        }

        $failureState |
            ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath $lastFailureStateFile -Encoding ascii
        Write-AutoRepairLog "Saved last failure state. classification=$classification File=$lastFailureStateFile"
    }
    catch {
        Write-AutoRepairLog "Could not save last failure state: $($_.Exception.Message)"
    }
}

function Wait-AutoRepairCodeZeroState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InitialState,
        [string]$RepairLog = "",
        [int]$TimeoutSeconds = 210,
        [int]$PollSeconds = 5
    )

    $state = $InitialState
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $waitReasonLogged = $false

    while (-not $state.Ready -and (Get-Date) -lt $deadline) {
        $shouldKeepWaiting = $true
        if ($RepairLog -and (Test-Path -LiteralPath $RepairLog)) {
            try {
                $tail = (Get-Content -LiteralPath $RepairLog -Tail 80 -ErrorAction Stop) -join "`n"
                if ($tail -match 'Integrated repair finished, but|Integrated repair finished successfully') {
                    $shouldKeepWaiting = $false
                }
                elseif ($tail -match 'Elevated integrated repair was launched|Running Studio Display XDR link refresh|Running external-only topology repair|Running advanced color validation|Running brightness HID get') {
                    $shouldKeepWaiting = $true
                }
            }
            catch {
                $shouldKeepWaiting = $true
            }
        }

        if (-not $shouldKeepWaiting) {
            break
        }

        if (-not $waitReasonLogged) {
            Write-AutoRepairLog "Child repair returned before final probes were ready; waiting for the elevated/in-progress repair transaction to settle before overriding the exit code. Current: $($state.Detail)"
            $waitReasonLogged = $true
        }

        Start-Sleep -Seconds $PollSeconds
        $state = Test-AutoRepairCodeZeroState
    }

    return $state
}

if ($ValidateOnly) {
    $codeZeroState = Test-AutoRepairCodeZeroState
    $exitCode = if ($codeZeroState.Ready) { 0 } else { 6 }
    if ($codeZeroState.Ready) {
        Save-AutoRepairKnownGoodState -State $codeZeroState -Reason "$Reason validate-only"
    }
    else {
        Save-AutoRepairFailureState -State $codeZeroState -ExitCode $exitCode -Reason "$Reason validate-only"
    }
    Write-AutoRepairLog "Scheduled auto repair validate-only finished with exit code $exitCode. $($codeZeroState.Detail)"
    exit $exitCode
}

Write-AutoRepairLog "Scheduled auto repair started. Reason=$Reason Log=$logPath"

if (-not (Test-Path -LiteralPath $integratedRepairScript)) {
    Write-AutoRepairLog "Integrated repair script is missing: $integratedRepairScript"
    exit 1
}

$preRepairState = Test-AutoRepairCodeZeroState
if ($preRepairState.Ready) {
    Save-AutoRepairKnownGoodState -State $preRepairState -Reason "$Reason preflight already healthy"
    Write-AutoRepairLog "Scheduled auto repair skipped disruptive repair because preflight is already code=0. $($preRepairState.Detail)"
    exit 0
}

if (Test-AutoRepairPhysicalReenumerationGateActive -State $preRepairState) {
    Save-AutoRepairFailureState -State $preRepairState -ExitCode 7 -Reason "$Reason physical-reenumeration-gate"
    Write-AutoRepairLog "Scheduled auto repair skipped disruptive repair because success prerequisites are not present: previous HDR failure requires a fresh Thunderbolt/USB physical re-enumeration. $($preRepairState.Detail)"
    exit 7
}

& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $integratedRepairScript -Apply -RestartAppleUsb4Router -LogPath $logPath
$exitCode = $LASTEXITCODE

$failureStateSaved = $false
if ($exitCode -eq 0) {
    $codeZeroState = Test-AutoRepairCodeZeroState
    if ($codeZeroState.Ready) {
        Save-AutoRepairKnownGoodState -State $codeZeroState -Reason $Reason -RepairLog $logPath
        Write-AutoRepairLog "Scheduled auto repair code=0 final validation passed. $($codeZeroState.Detail)"
    }
    else {
        $codeZeroState = Wait-AutoRepairCodeZeroState -InitialState $codeZeroState -RepairLog $logPath
        if ($codeZeroState.Ready) {
            Save-AutoRepairKnownGoodState -State $codeZeroState -Reason $Reason -RepairLog $logPath
            Write-AutoRepairLog "Scheduled auto repair code=0 final validation passed after waiting for the elevated/in-progress transaction. $($codeZeroState.Detail)"
        }
        else {
            Write-AutoRepairLog "Scheduled auto repair child returned code=0, but final validation failed after waiting. Overriding to exit code 6. $($codeZeroState.Detail)"
            $exitCode = 6
        }
    }
}
else {
    $failureState = Test-AutoRepairCodeZeroState
    Save-AutoRepairFailureState -State $failureState -ExitCode $exitCode -Reason $Reason -RepairLog $logPath
    $failureStateSaved = $true
}

if ($exitCode -ne 0 -and -not $failureStateSaved) {
    $failureState = if ($codeZeroState) { $codeZeroState } else { Test-AutoRepairCodeZeroState }
    Save-AutoRepairFailureState -State $failureState -ExitCode $exitCode -Reason $Reason -RepairLog $logPath
}

Write-AutoRepairLog "Scheduled auto repair finished with exit code $exitCode. Log=$logPath"
exit $exitCode
