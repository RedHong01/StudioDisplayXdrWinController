[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager"),
    [int]$DurationMinutes = 20,
    [int]$PollSeconds = 3,
    [int]$CompletionQuietSeconds = 75,
    [switch]$ExitAfterTaskCompletes,
    [string]$RunLabel = "passive hot-plug observer",
    [string]$TaskName = "Studio Display XDR Win Controller Auto Repair"
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

$installRoot = $InstallRoot
$reportsRoot = Join-Path $installRoot "reports"
$sessionId = Get-Date -Format "yyyyMMdd-HHmmss"
$jsonlPath = Join-Path $reportsRoot ("StudioDisplayPassiveHotplugObserver-{0}.jsonl" -f $sessionId)
$summaryPath = Join-Path $reportsRoot ("StudioDisplayPassiveHotplugObserver-{0}.summary.json" -f $sessionId)
$pidPath = Join-Path $installRoot "StudioDisplayPassiveHotplugObserver.pid"
$powershellExe = Resolve-StudioDisplayPowerShellExe
$schtasksExe = Join-Path $env:SystemRoot "System32\schtasks.exe"
$resolutionLadderScript = Join-Path $installRoot "Test-StudioDisplayResolutionLadder.ps1"
$advancedColorScript = Join-Path $installRoot "Get-StudioDisplayAdvancedColorState.ps1"

New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null
Set-Content -LiteralPath $pidPath -Value $PID -Encoding ascii -ErrorAction SilentlyContinue

if (-not ([System.Management.Automation.PSTypeName]'StudioDisplayObserverUser32').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class StudioDisplayObserverUser32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@ -ErrorAction SilentlyContinue
}

$script:offsets = @{}
$script:lastStage = "observer-started"
$script:sawTaskRunning = $false
$script:lastTaskState = $null
$script:lastLogWriteAt = Get-Date
$script:lastAnyLogReadAt = Get-Date
$script:lastSnapshotAt = [DateTime]::MinValue
$script:lastStallEventAt = [DateTime]::MinValue
$script:lastUserOverlapAt = [DateTime]::MinValue
$script:userOverlapCount = 0
$script:issueCounts = @{}
$script:stageTimeline = New-Object System.Collections.Generic.List[object]
$script:latestIssue = $null

function Add-Issue {
    param([string]$Issue)

    if ([string]::IsNullOrWhiteSpace($Issue)) {
        return
    }

    if (-not $script:issueCounts.ContainsKey($Issue)) {
        $script:issueCounts[$Issue] = 0
    }
    $script:issueCounts[$Issue]++
    $script:latestIssue = $Issue
}

function Write-ObserverEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,
        [string]$Stage = $script:lastStage,
        [string]$Message = "",
        [object]$Data = $null
    )

    $event = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Kind = $Kind
        Stage = $Stage
        Message = $Message
        Data = $Data
    }

    $event | ConvertTo-Json -Depth 8 -Compress | Add-Content -LiteralPath $jsonlPath -Encoding utf8 -ErrorAction SilentlyContinue
    if ($Kind -in @("stage", "issue", "stall", "complete", "observer")) {
        Write-Host ("[{0}] {1} {2}" -f (Get-Date -Format "HH:mm:ss"), $Kind, $Message)
    }
}

function Set-ObserverStage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,
        [string]$Message = ""
    )

    if ($script:lastStage -ne $Stage) {
        $script:lastStage = $Stage
        $entry = [pscustomobject]@{
            At = (Get-Date).ToString("o")
            Stage = $Stage
            Message = $Message
        }
        $script:stageTimeline.Add($entry) | Out-Null
        Write-ObserverEvent -Kind "stage" -Stage $Stage -Message $Message
    }
}

function Initialize-LogOffset {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $script:offsets[$Path] = [int64]$item.Length
    }
    catch {
    }
}

function Read-NewLogLines {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $start = 0L
        if ($script:offsets.ContainsKey($Path)) {
            $start = [int64]$script:offsets[$Path]
        }

        if ($item.Length -lt $start) {
            $start = 0L
        }

        if ($item.Length -eq $start) {
            return @()
        }

        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $stream.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
            $text = $reader.ReadToEnd()
        }
        finally {
            if ($reader) { $reader.Dispose() }
            $stream.Dispose()
        }

        $script:offsets[$Path] = [int64]$item.Length
        if ([string]::IsNullOrWhiteSpace($text)) {
            return @()
        }

        $script:lastAnyLogReadAt = Get-Date
        return @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    catch {
        return @()
    }
}

function Get-LatestLogPath {
    param([string]$Pattern)

    try {
        return (Get-ChildItem -LiteralPath $reportsRoot -Filter $Pattern -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1).FullName
    }
    catch {
        return $null
    }
}

function Get-TaskState {
    $state = [ordered]@{
        Found = $false
        State = "Unknown"
        LastRunTime = $null
        LastTaskResult = $null
        QuerySource = $null
        QueryError = $null
    }

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        $state.Found = $true
        $state.State = [string]$task.State
        $state.QuerySource = "Get-ScheduledTask"
        if ($info) {
            $state.LastRunTime = $info.LastRunTime
            $state.LastTaskResult = $info.LastTaskResult
        }
        return [pscustomobject]$state
    }
    catch {
        $state.QueryError = $_.Exception.Message
    }

    if (Test-Path -LiteralPath $schtasksExe) {
        try {
            $output = @(& $schtasksExe /Query /TN $TaskName /V /FO LIST 2>&1)
            if ($LASTEXITCODE -eq 0) {
                $text = $output -join "`n"
                $state.Found = $true
                $state.QuerySource = "schtasks"
                if ($text -match '(?im)^\s*(?:Status|状态)\s*:\s*(.+?)\s*$') {
                    $state.State = $Matches[1].Trim()
                }
                if ($text -match '(?im)^\s*(?:Last Result|上次运行结果|上次结果)\s*:\s*([0-9]+)\s*$') {
                    $state.LastTaskResult = [int]$Matches[1]
                }
            }
            else {
                $state.QueryError = "schtasks query failed: $($output -join ' ')"
            }
        }
        catch {
            $state.QueryError = "schtasks query threw: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$state
}

function Test-StudioDisplayRepairProcessRunning {
    try {
        $processes = @(
            Get-CimInstance Win32_Process -ErrorAction Stop |
                Where-Object {
                    $_.ProcessId -ne $PID -and
                    $_.CommandLine -match 'Repair-StudioDisplayIntegrated|Repair-StudioDisplayHdrIdentityRollback|Repair-StudioDisplayAppleUsbInterfaces|Refresh-StudioDisplayXdrLink|Install-StudioDisplayBootCampStyleMonitorDriver'
                }
        )

        return [bool]($processes.Count -gt 0)
    }
    catch {
        return $false
    }
}

function Get-UserActivityState {
    $idleSeconds = $null
    $foregroundProcess = $null

    try {
        $info = New-Object StudioDisplayObserverUser32+LASTINPUTINFO
        $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
        if ([StudioDisplayObserverUser32]::GetLastInputInfo([ref]$info)) {
            $tick = [Environment]::TickCount
            $elapsed = $tick - [int]$info.dwTime
            if ($elapsed -lt 0) {
                $elapsed += [int64][uint32]::MaxValue
            }
            $idleSeconds = [math]::Round($elapsed / 1000.0, 1)
        }

        $pidValue = [uint32]0
        $handle = [StudioDisplayObserverUser32]::GetForegroundWindow()
        [void][StudioDisplayObserverUser32]::GetWindowThreadProcessId($handle, [ref]$pidValue)
        if ($pidValue -gt 0) {
            $process = Get-Process -Id ([int]$pidValue) -ErrorAction SilentlyContinue
            if ($process) {
                $foregroundProcess = $process.ProcessName
            }
        }
    }
    catch {
    }

    return [pscustomobject]@{
        IdleSeconds = $idleSeconds
        ForegroundProcess = $foregroundProcess
        UserActiveLikely = [bool]($null -ne $idleSeconds -and $idleSeconds -lt 5)
    }
}

function Get-ManagedPidState {
    param([string]$FileName)

    $path = Join-Path $installRoot $FileName
    $pidValue = $null
    $process = $null
    if (Test-Path -LiteralPath $path) {
        $raw = Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Select-Object -First 1
        $parsed = 0
        if ([int]::TryParse([string]$raw, [ref]$parsed)) {
            $pidValue = $parsed
            $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        Pid = $pidValue
        Running = [bool]$process
    }
}

function Invoke-ReadOnlyScript {
    param([string[]]$Arguments)

    try {
        $output = @(& $powershellExe @Arguments 2>&1)
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text = ($output -join "`n")
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = 999
            Text = $_.Exception.Message
        }
    }
}

function Get-ResolutionSnapshot {
    if (-not (Test-Path -LiteralPath $resolutionLadderScript)) {
        return $null
    }

    $result = Invoke-ReadOnlyScript -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolutionLadderScript)
    $text = [string]$result.Text
    $current5K = [bool]($text -match '(?m)^Current mode:\s+5120x2880@')
    $fiveK60 = [bool](
        $text -match '(?m)^5K 60Hz legacy Studio Display fallback[^\r\n]*\s5120\s+2880\s+60\s+True(?:\s|$)' -or
        $text -match '(?m)^Best enumerated mode:\s+5120x2880@60Hz\s*$'
    )
    $desktop5KButModeTableLow = [bool]($text -match '(?m)^Current mode:\s+5120x2880@' -and $text -match '(?m)^Best enumerated mode:\s+1920x1080@')

    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        Current5K = $current5K
        FiveK60Enumerated = $fiveK60
        Desktop5KButModeTableLow = $desktop5KButModeTableLow
    }
}

function Get-HdrSnapshot {
    if (-not (Test-Path -LiteralPath $advancedColorScript)) {
        return $null
    }

    $result = Invoke-ReadOnlyScript -Arguments @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $advancedColorScript, "-SkipDxDiagFallback")
    $text = [string]$result.Text
    $supported = [bool]($text -match '(?m)^\s*HighDynamicRangeSupported\s*:\s*True\s*$')
    $unsupported = [bool]($text -match '(?m)^\s*HighDynamicRangeSupported\s*:\s*False\s*$')
    $active = [bool](
        $text -match '(?m)^\s*ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR\s*$' -or
        $text -match '(?m)^\s*HighDynamicRangeUserEnabled\s*:\s*True\s*$'
    )
    $wcg = [bool]($text -match '(?m)^\s*ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG\s*$')

    return [pscustomobject]@{
        ExitCode = $result.ExitCode
        HdrSupported = $supported
        HdrUnsupported = $unsupported
        HdrActive = $active
        WcgActive = $wcg
    }
}

function Get-AppleUsbSnapshot {
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
        return [pscustomobject]@{
            QueryOk = $true
            DeviceCount = $devices.Count
            FailedCount = $failed.Count
            FailedMi08Mi09Count = $failedMi08Mi09.Count
            FailedMi08Mi09 = @($failedMi08Mi09 | ForEach-Object {
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
    }
    catch {
        return [pscustomobject]@{
            QueryOk = $false
            Error = $_.Exception.Message
        }
    }
}

function Classify-LogLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line,
        [Parameter(Mandatory = $true)]
        [string]$Source
    )

    $stage = $null
    $issue = $null
    $message = $Line

    switch -Regex ($Line) {
        'Scheduled auto repair started|Started scheduled integrated Studio Display auto repair' { $stage = "ScheduledTaskStarted"; break }
        'Boot Camp-style monitor driver refresh enabled|Running Boot Camp-style monitor driver' { $stage = "BootCampStyleIdentityRefresh"; break }
        'Boot Camp-style monitor identity is ready before HDR' { $stage = "BootCampStyleIdentityReady"; break }
        'Running external-only topology repair' { $stage = "ExternalOnlyTopologyRepair"; break }
        'Running Studio Display XDR link refresh' { $stage = "XdrLinkRefresh"; break }
        'Restarting fallback monitor device' { $stage = "FallbackMonitorRestart"; break }
        'Restarting Apple Studio Display XDR USB4 router' { $stage = "AppleUsb4RouterRestart"; break }
        'Studio Display 5K fallback mode is now enumerated|Best enumerated mode:\s+5120x2880@60Hz' { $stage = "FiveK60ModeTableRecovered"; break }
        'Running advanced color preflight' { $stage = "HdrPreflight"; break }
        'Running Apple USB/HID interface repair|Studio Display Apple USB interface repair started' { $stage = "AppleUsbHidInterfaceRepair"; break }
        'Running HDR state repair' { $stage = "HdrStateRepair"; break }
        'SystemBrightnessMirror restart result|BrightnessKeyBridge restart result|brightness HID get' { $stage = "BrightnessRestore"; break }
        'Scheduled auto repair finished with exit code 0|code=0 final validation passed|Integrated repair finished successfully' { $stage = "CompleteCode0"; break }
        'Scheduled auto repair finished with exit code [1-9]|Integrated repair finished, but 5K60 is still not enumerated|Integrated repair finished with 5K60 enumerated, but HDR is still blocked' { $stage = "CompleteWithFailure"; break }
    }

    if ($Line -match 'Current mode:\s+5120x2880@60Hz.*Best enumerated mode:\s+1920x1080@60Hz|max=1920x1080@60Hz') {
        $issue = "Desktop5KButModeTableDegraded"
    }
    elseif ($Line -match 'HighDynamicRangeSupported\s+:\s+False|HighDynamicRangeSupported=False') {
        $issue = "HdrCapabilityGateClosed"
    }
    elseif ($Line -match 'ActiveColorMode\s+:\s+DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG|WCG/Advanced Color fallback') {
        $issue = "WcgIsNotHdr"
    }
    elseif ($Line -match 'CM_PROB_FAILED_START.*(MI_08|MI_09)|(MI_08|MI_09).*(CM_PROB_FAILED_START)') {
        $issue = "AppleUsbMi08Mi09FailedStart"
    }
    elseif ($Line -match 'APPLE_USB_REBOOT_REQUIRED=True|System reboot is needed to complete configuration operations|exitCode=3010') {
        $issue = "AppleUsbRestartRequiresReboot"
    }
    elseif ($Line -match 'Apple USB interface repair finished with unresolved failed interfaces') {
        $issue = "AppleUsbReferenceModeStillFailedAfterRestart"
    }
    elseif ($Line -match 'HDR state request was not sent because Windows reports HighDynamicRangeSupported=False') {
        $issue = "HdrPacketBlockedBeforeSend"
    }

    if ($stage) {
        Set-ObserverStage -Stage $stage -Message $message
    }

    if ($issue) {
        Add-Issue -Issue $issue
        Write-ObserverEvent -Kind "issue" -Stage $script:lastStage -Message $issue -Data @{
            Source = $Source
            Line = $Line
        }
    }

    if ($stage -or $issue) {
        $script:lastLogWriteAt = Get-Date
    }
}

function Write-Snapshot {
    $task = Get-TaskState
    $user = Get-UserActivityState
    $manager = Get-ManagedPidState -FileName "StudioDisplayManager.pid"
    $mirror = Get-ManagedPidState -FileName "SystemBrightnessMirror.pid"
    $bridge = Get-ManagedPidState -FileName "BrightnessKeyBridge.pid"
    $resolution = Get-ResolutionSnapshot
    $hdr = Get-HdrSnapshot
    $usb = Get-AppleUsbSnapshot

    if ($task.State -match 'Running') {
        $script:sawTaskRunning = $true
    }

    if ($resolution -and $resolution.Desktop5KButModeTableLow) {
        Add-Issue -Issue "Desktop5KButModeTableDegraded"
    }
    if ($hdr -and $hdr.WcgActive -and -not $hdr.HdrActive) {
        Add-Issue -Issue "WcgIsNotHdr"
    }
    if ($hdr -and $hdr.HdrUnsupported) {
        Add-Issue -Issue "HdrCapabilityGateClosed"
    }
    if ($usb -and $usb.QueryOk -and $usb.FailedMi08Mi09Count -gt 0 -and (
            (-not $hdr) -or
            (-not $hdr.HdrActive) -or
            $hdr.HdrUnsupported -or
            ($resolution -and -not $resolution.FiveK60Enumerated)
        )) {
        Add-Issue -Issue "AppleUsbMi08Mi09FailedStart"
    }

    $sensitiveStage = [bool]($script:lastStage -match 'Topology|Refresh|Router|Hdr|AppleUsb|BootCamp')
    if ($task.State -match 'Running' -and $sensitiveStage -and $user.UserActiveLikely) {
        $now = Get-Date
        if (($now - $script:lastUserOverlapAt).TotalSeconds -ge 15) {
            $script:lastUserOverlapAt = $now
            $script:userOverlapCount++
            Write-ObserverEvent -Kind "user-overlap" -Stage $script:lastStage -Message "User input overlapped a sensitive display repair stage. This is correlation only, not proof of cause." -Data $user
        }
    }

    $latestLogAge = ((Get-Date) - $script:lastLogWriteAt).TotalSeconds
    if ($task.State -match 'Running' -and $latestLogAge -gt 90) {
        $now = Get-Date
        if (($now - $script:lastStallEventAt).TotalSeconds -ge 60) {
            $script:lastStallEventAt = $now
            Write-ObserverEvent -Kind "stall" -Stage $script:lastStage -Message "Task is still running, but no relevant log progress was observed for more than 90 seconds." -Data @{
                LastRelevantLogAgeSeconds = [math]::Round($latestLogAge, 1)
                User = $user
            }
        }
    }

    Write-ObserverEvent -Kind "snapshot" -Stage $script:lastStage -Message "periodic state" -Data @{
        Task = $task
        Controller = @{
            Manager = $manager
            SystemBrightnessMirror = $mirror
            BrightnessKeyBridge = $bridge
        }
        Resolution = $resolution
        Hdr = $hdr
        AppleUsb = $usb
        User = $user
        LatestIssue = $script:latestIssue
    }

    $script:lastTaskState = $task.State
    return $task
}

function Write-FinalSummary {
    param([string]$Reason)

    $task = Get-TaskState
    $resolution = Get-ResolutionSnapshot
    $hdr = Get-HdrSnapshot
    $usb = Get-AppleUsbSnapshot
    $manager = Get-ManagedPidState -FileName "StudioDisplayManager.pid"
    $mirror = Get-ManagedPidState -FileName "SystemBrightnessMirror.pid"
    $bridge = Get-ManagedPidState -FileName "BrightnessKeyBridge.pid"

    $knownConclusion = "A hot-plug chain is actionable only after separating the gates: 5K60 mode-table recovery, HDR capability support, active HDR state, brightness HID readback, and VID_05AC&PID_1116 MI_08/MI_09 Apple USB control-interface health. MI_08/MI_09 failures are correlation evidence only when HDR/5K gates are still failing; they are not fatal after code=0."
    $possibleUserOverlap = [bool]($script:userOverlapCount -gt 0)
    $summary = [ordered]@{
        Version = 1
        FinishedAt = (Get-Date).ToString("o")
        Reason = $Reason
        RunLabel = $RunLabel
        InstallRoot = $installRoot
        Jsonl = $jsonlPath
        CompletionQuietSeconds = $CompletionQuietSeconds
        LastStage = $script:lastStage
        SawTaskRunning = $script:sawTaskRunning
        Task = $task
        Resolution = $resolution
        Hdr = $hdr
        AppleUsb = $usb
        Controller = @{
            Manager = $manager
            SystemBrightnessMirror = $mirror
            BrightnessKeyBridge = $bridge
        }
        IssueCounts = $script:issueCounts
        UserActivityOverlapCount = $script:userOverlapCount
        PossibleUserInteractionOverlap = $possibleUserOverlap
        UserInteractionCausality = if ($possibleUserOverlap) {
            "User input overlapped one or more sensitive repair stages. Treat as a correlation signal only; the observer cannot prove it caused the failure."
        }
        else {
            "No user input overlap was observed during sampled sensitive repair stages."
        }
        KnownConclusion = $knownConclusion
        SuggestedAutomationImprovements = @(
            "Keep the observer passive: record stage, gate, and user-idle evidence without changing display state.",
            "Treat desktop 5K with a 1080p/low enumerated mode table as degraded until 5K60 is enumerated.",
            "Treat WCG as not HDR; never record WCG as code=0.",
            "When Boot Camp-style MS_0001 is ready but HighDynamicRangeSupported=False, classify the active failure as an HDR capability gate, not brightness conflict.",
            "If pnputil returns 3010 while restarting the Apple USB composite/upstream parent, classify the round as reboot-required and skip HDR identity rollback until reboot/resume/full re-enumeration.",
            "If MI_08/MI_09 remain CM_PROB_FAILED_START while HDR is still inactive/unsupported, back off repeated HDR packets and record the USB/reference-mode gate for the next reconnect.",
            "If MI_08/MI_09 remain failed but 5K60, HDR active, and brightness HID all validate, record them as non-fatal diagnostics instead of blocking code=0.",
            "If current desktop is 5K but 5K60 is absent from the enumerated mode table, classify the round as a mode-table/link failure before blaming HDR.",
            "Only suspect user interference when input overlaps topology, USB4 router, Apple USB/HID, or HDR stages; never assert causality from input alone."
        )
    }

    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding ascii -ErrorAction SilentlyContinue
    Write-ObserverEvent -Kind "observer" -Stage $script:lastStage -Message "summary written" -Data @{ SummaryPath = $summaryPath }
}

Initialize-LogOffset -Path (Join-Path $reportsRoot "StudioDisplayAutoRepairTask.log")
Initialize-LogOffset -Path (Join-Path $installRoot "SystemBrightnessMirror.log")
Initialize-LogOffset -Path (Join-Path $installRoot "BrightnessKeyBridge.log")
$initialIntegrated = Get-LatestLogPath -Pattern "StudioDisplayAutoIntegratedRepair-*.log"
$initialLink = Get-LatestLogPath -Pattern "StudioDisplayXdrLinkRefresh-*.log"
if ($initialIntegrated) { Initialize-LogOffset -Path $initialIntegrated }
if ($initialLink) { Initialize-LogOffset -Path $initialLink }

Write-ObserverEvent -Kind "observer" -Stage "observer-started" -Message "Passive hot-plug observer started. It will not run repairs or modify display state." -Data @{
    InstallRoot = $installRoot
    Jsonl = $jsonlPath
    Summary = $summaryPath
    DurationMinutes = $DurationMinutes
    PollSeconds = $PollSeconds
}

$deadline = (Get-Date).AddMinutes($DurationMinutes)
$completedAfterRunning = $false
$completedAfterQuiet = $false
$taskLeftRunningAt = [DateTime]::MinValue

try {
    while ((Get-Date) -lt $deadline) {
        $staticLogs = @(
            (Join-Path $reportsRoot "StudioDisplayAutoRepairTask.log"),
            (Join-Path $installRoot "SystemBrightnessMirror.log"),
            (Join-Path $installRoot "BrightnessKeyBridge.log")
        )
        $dynamicLogs = @(
            (Get-LatestLogPath -Pattern "StudioDisplayAutoIntegratedRepair-*.log"),
            (Get-LatestLogPath -Pattern "StudioDisplayXdrLinkRefresh-*.log")
        ) | Where-Object { $_ }

        $allLogs = @($staticLogs + $dynamicLogs) | Select-Object -Unique
        foreach ($logPath in $allLogs) {
            foreach ($line in (Read-NewLogLines -Path $logPath)) {
                Classify-LogLine -Line $line -Source ([System.IO.Path]::GetFileName($logPath))
            }
        }

        if (((Get-Date) - $script:lastSnapshotAt).TotalSeconds -ge 10) {
            $script:lastSnapshotAt = Get-Date
            $task = Write-Snapshot
            if ($ExitAfterTaskCompletes -and $script:sawTaskRunning -and $task.State -notmatch 'Running') {
                if (-not $completedAfterRunning) {
                    $completedAfterRunning = $true
                    $taskLeftRunningAt = Get-Date
                    Write-ObserverEvent -Kind "complete" -Stage $script:lastStage -Message "Observed task leave Running state; waiting for repair logs to become quiet before writing summary." -Data $task
                }

                $now = Get-Date
                $latestActivityAt = $script:lastAnyLogReadAt
                if ($script:lastLogWriteAt -gt $latestActivityAt) {
                    $latestActivityAt = $script:lastLogWriteAt
                }
                if ($taskLeftRunningAt -gt $latestActivityAt) {
                    $latestActivityAt = $taskLeftRunningAt
                }

                $quietSeconds = ($now - $latestActivityAt).TotalSeconds
                $repairProcessRunning = Test-StudioDisplayRepairProcessRunning
                if ($quietSeconds -ge $CompletionQuietSeconds -and -not $repairProcessRunning) {
                    $completedAfterQuiet = $true
                    Write-ObserverEvent -Kind "complete" -Stage $script:lastStage -Message "Observed task complete and repair logs quiet for $([int]$quietSeconds)s." -Data @{
                        Task = $task
                        QuietSeconds = [math]::Round($quietSeconds, 1)
                        CompletionQuietSeconds = $CompletionQuietSeconds
                    }
                    break
                }
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    $finishReason = if ($completedAfterQuiet) {
        "task-completed-after-log-quiescence"
    }
    elseif ($completedAfterRunning) {
        "task-completed-but-log-quiescence-timeout"
    }
    else {
        "timeout-or-stopped"
    }
    Write-FinalSummary -Reason $finishReason
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
}
