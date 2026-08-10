[CmdletBinding()]
param(
    [switch]$RunScheduledTask,
    [int]$WaitSeconds = 90,
    [string]$TaskName = "Studio Display XDR Win Controller Auto Repair"
)

$ErrorActionPreference = "Continue"

$scriptRoot = $PSScriptRoot
$reportsRoot = Join-Path $scriptRoot "reports"
$reportPath = Join-Path $reportsRoot ("StudioDisplayHotplugAutomationVerification-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$launcherScript = Join-Path $scriptRoot "Invoke-StudioDisplayAutoRepair.ps1"
$knownGoodStateFile = Join-Path $scriptRoot "StudioDisplayKnownGoodState.json"
$schtasksExe = Join-Path $env:SystemRoot "System32\schtasks.exe"
$powershellExe = Join-Path $PSHOME "powershell.exe"

New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null

function Get-ManagedPidState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $pidPath = Join-Path $scriptRoot $FileName
    $pidValue = $null
    $process = $null

    if (Test-Path -LiteralPath $pidPath) {
        $raw = Get-Content -LiteralPath $pidPath -ErrorAction SilentlyContinue | Select-Object -First 1
        $parsed = 0
        if ([int]::TryParse([string]$raw, [ref]$parsed)) {
            $pidValue = $parsed
            $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
        }
    }

    return [pscustomobject]@{
        PidFile = $pidPath
        Pid = $pidValue
        Running = [bool]$process
        ProcessName = if ($process) { $process.ProcessName } else { $null }
        StartTime = if ($process) { $process.StartTime.ToString("o") } else { $null }
    }
}

function Get-AutoRepairTaskState {
    $taskState = [ordered]@{
        Found = $false
        QueryOk = $false
        State = $null
        LastRunTime = $null
        LastTaskResult = $null
        Execute = $null
        Arguments = $null
        WorkingDirectory = $null
        ActionPathMatches = $false
        QueryError = $null
    }

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
        $action = $task.Actions | Select-Object -First 1
        $taskState.Found = $true
        $taskState.QueryOk = $true
        $taskState.State = [string]$task.State
        if ($info) {
            $taskState.LastRunTime = $info.LastRunTime
            $taskState.LastTaskResult = $info.LastTaskResult
        }
        if ($action) {
            $taskState.Execute = [string]$action.Execute
            $taskState.Arguments = [string]$action.Arguments
            $taskState.WorkingDirectory = [string]$action.WorkingDirectory
            $taskState.ActionPathMatches = [bool]($taskState.Arguments -like "*$launcherScript*")
        }
    }
    catch {
        $taskState.QueryError = $_.Exception.Message
    }

    if (-not $taskState.Found -and (Test-Path -LiteralPath $schtasksExe)) {
        try {
            $queryOutput = @(& $schtasksExe /Query /TN $TaskName /V /FO LIST 2>&1)
            if ($LASTEXITCODE -eq 0) {
                $queryText = ($queryOutput -join "`n")
                $taskState.Found = $true
                $taskState.QueryOk = $true
                $taskState.Arguments = $queryText
                $taskState.ActionPathMatches = [bool]($queryText -like "*$launcherScript*")

                if ($queryText -match '(?im)^\s*(?:Status|状态)\s*:\s*(.+?)\s*$') {
                    $taskState.State = $Matches[1].Trim()
                }

                if ($queryText -match '(?im)^\s*(?:Last Result|上次运行结果|上次结果)\s*:\s*([0-9]+)\s*$') {
                    $taskState.LastTaskResult = [int]$Matches[1]
                }
            }
            else {
                $taskState.QueryError = "schtasks query failed: $($queryOutput -join ' ')"
            }
        }
        catch {
            $taskState.QueryError = "schtasks query threw: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]$taskState
}

function Invoke-CodeZeroValidation {
    if (-not (Test-Path -LiteralPath $launcherScript)) {
        return [pscustomobject]@{
            ExitCode = 1
            Output = "launcher missing: $launcherScript"
        }
    }

    $output = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $launcherScript -ValidateOnly -Reason "hot-plug automation verification" 2>&1)
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = ($output -join "`n")
    }
}

function Invoke-ScheduledTaskProbe {
    if (-not $RunScheduledTask) {
        return [pscustomobject]@{
            Requested = $false
            Started = $false
            LastTaskResult = $null
            Detail = "not requested"
        }
    }

    if (-not (Test-Path -LiteralPath $schtasksExe)) {
        return [pscustomobject]@{
            Requested = $true
            Started = $false
            LastTaskResult = $null
            Detail = "schtasks.exe missing"
        }
    }

    $runOutput = @(& $schtasksExe /Run /TN $TaskName 2>&1)
    $runExit = $LASTEXITCODE
    if ($runExit -ne 0) {
        return [pscustomobject]@{
            Requested = $true
            Started = $false
            LastTaskResult = $null
            Detail = "schtasks /Run exit=$runExit output=$($runOutput -join ' ')"
        }
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $lastTaskState = $null
    do {
        Start-Sleep -Seconds 2
        $lastTaskState = Get-AutoRepairTaskState
        if ($lastTaskState.State -and $lastTaskState.State -ne "Running") {
            break
        }
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Requested = $true
        Started = $true
        LastTaskResult = $lastTaskState.LastTaskResult
        Detail = "state=$($lastTaskState.State) lastTaskResult=$($lastTaskState.LastTaskResult)"
    }
}

$beforeTask = Get-AutoRepairTaskState
$scheduledProbe = Invoke-ScheduledTaskProbe
$afterTask = Get-AutoRepairTaskState
$codeZero = Invoke-CodeZeroValidation

$knownGood = $null
if (Test-Path -LiteralPath $knownGoodStateFile) {
    try {
        $knownGood = Get-Content -LiteralPath $knownGoodStateFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $knownGood = $null
    }
}

$manager = Get-ManagedPidState -FileName "StudioDisplayManager.pid"
$mirror = Get-ManagedPidState -FileName "SystemBrightnessMirror.pid"
$bridge = Get-ManagedPidState -FileName "BrightnessKeyBridge.pid"

$bootCampRecipePresent = [bool](
    $knownGood -and
    $knownGood.SuccessRecipe -and
    (($knownGood.SuccessRecipe -join "`n") -match 'Boot Camp-style monitor INF')
)

$passed = [bool](
    $manager.Running -and
    $mirror.Running -and
    $bridge.Running -and
    $afterTask.Found -and
    $afterTask.ActionPathMatches -and
    $codeZero.ExitCode -eq 0 -and
    $knownGood -and
    $knownGood.CodeZeroReady -and
    $knownGood.Current5K -and
    $knownGood.FiveK60Enumerated -and
    $knownGood.HdrSupported -and
    $knownGood.HdrActive -and
    $knownGood.BrightnessOk -and
    $bootCampRecipePresent
)

if ($RunScheduledTask) {
    $passed = [bool]($passed -and $scheduledProbe.Started -and $scheduledProbe.LastTaskResult -eq 0)
}

$report = [ordered]@{
    Version = 1
    UpdatedAt = (Get-Date).ToString("o")
    Passed = $passed
    RunScheduledTask = [bool]$RunScheduledTask
    TaskBefore = $beforeTask
    ScheduledProbe = $scheduledProbe
    TaskAfter = $afterTask
    Controller = $manager
    SystemBrightnessMirror = $mirror
    BrightnessKeyBridge = $bridge
    CodeZeroValidation = $codeZero
    KnownGood = $knownGood
    BootCampStyleRecipePresent = $bootCampRecipePresent
    ExpectedHotplugPath = @(
        "Tray detects reconnect/resume/topology change.",
        "Tray calls the elevated scheduled task instead of local split scripts.",
        "Scheduled task runs Invoke-StudioDisplayAutoRepair.ps1.",
        "Launcher preflights code=0 and skips disruptive repair when already healthy.",
        "If not healthy, integrated repair restores Boot Camp-style MS_0001 identity, 5K60 mode table, HDR, then brightness."
    )
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding ascii

Write-Host "Hot-plug automation verification report: $reportPath"
Write-Host "Passed=$passed"
Write-Host "Controller=$($manager.Running) Mirror=$($mirror.Running) Bridge=$($bridge.Running)"
Write-Host "TaskFound=$($afterTask.Found) TaskActionMatches=$($afterTask.ActionPathMatches) LastTaskResult=$($afterTask.LastTaskResult)"
Write-Host "CodeZeroExit=$($codeZero.ExitCode) BootCampStyleRecipePresent=$bootCampRecipePresent"

if ($RunScheduledTask) {
    Write-Host "ScheduledProbeStarted=$($scheduledProbe.Started) ScheduledProbe=$($scheduledProbe.Detail)"
}

if ($passed) {
    exit 0
}

exit 1
