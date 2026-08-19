[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager"),
    [string]$SourceRoot = $PSScriptRoot,
    [string]$ReportPath
)

$ErrorActionPreference = "Continue"

$reportsRoot = Join-Path $InstallRoot "reports"
if (-not $ReportPath) {
    $ReportPath = Join-Path $reportsRoot ("StudioDisplayOfflineMaintenanceGuards-{0}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null

function New-GuardResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [bool]$Passed,
        [string]$Detail = "",
        [object]$Data = $null
    )

    return [pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Detail = $Detail
        Data = $Data
    }
}

function Test-PowerShellSyntax {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return New-GuardResult -Name ("syntax:" + [System.IO.Path]::GetFileName($Path)) -Passed $false -Detail "file missing" -Data @{ Path = $Path }
    }

    try {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors) | Out-Null
        if ($errors) {
            return New-GuardResult -Name ("syntax:" + [System.IO.Path]::GetFileName($Path)) -Passed $false -Detail "parse errors" -Data $errors
        }

        return New-GuardResult -Name ("syntax:" + [System.IO.Path]::GetFileName($Path)) -Passed $true -Detail "parser OK" -Data @{ Path = $Path }
    }
    catch {
        return New-GuardResult -Name ("syntax:" + [System.IO.Path]::GetFileName($Path)) -Passed $false -Detail $_.Exception.Message -Data @{ Path = $Path }
    }
}

function Test-FileContains {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Pattern,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$Detail = ""
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return New-GuardResult -Name $Name -Passed $false -Detail "file missing" -Data @{ Path = $Path; Pattern = $Pattern }
    }

    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $passed = [bool]($text -match $Pattern)
        $resultDetail = if ($passed) { $Detail } else { "pattern not found" }
        return New-GuardResult -Name $Name -Passed $passed -Detail $resultDetail -Data @{ Path = $Path; Pattern = $Pattern }
    }
    catch {
        return New-GuardResult -Name $Name -Passed $false -Detail $_.Exception.Message -Data @{ Path = $Path; Pattern = $Pattern }
    }
}

function Test-InstalledFileHashMatches {
    param([string]$FileName)

    $sourcePath = Join-Path $SourceRoot $FileName
    $installPath = Join-Path $InstallRoot $FileName

    if (-not (Test-Path -LiteralPath $sourcePath) -or -not (Test-Path -LiteralPath $installPath)) {
        return New-GuardResult -Name "hash:$FileName" -Passed $false -Detail "source or installed file missing" -Data @{
            Source = $sourcePath
            Installed = $installPath
        }
    }

    try {
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $installHash = (Get-FileHash -LiteralPath $installPath -Algorithm SHA256 -ErrorAction Stop).Hash
        return New-GuardResult -Name "hash:$FileName" -Passed ([bool]($sourceHash -eq $installHash)) -Detail "source and installed SHA256 compared" -Data @{
            Source = $sourcePath
            Installed = $installPath
            SourceHash = $sourceHash
            InstalledHash = $installHash
        }
    }
    catch {
        return New-GuardResult -Name "hash:$FileName" -Passed $false -Detail $_.Exception.Message -Data @{
            Source = $sourcePath
            Installed = $installPath
        }
    }
}

function Get-ManagedPidState {
    param([string]$FileName)

    $path = Join-Path $InstallRoot $FileName
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
        PidFile = $path
        Pid = $pidValue
        Running = [bool]$process
        ProcessName = if ($process) { $process.ProcessName } else { $null }
        StartTime = if ($process) { $process.StartTime.ToString("o") } else { $null }
    }
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Get-LatestObserverSnapshot {
    try {
        $latest = Get-ChildItem -LiteralPath $reportsRoot -Filter "StudioDisplayPassiveHotplugObserver-*.jsonl" -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $latest) {
            return $null
        }

        $lines = @(Get-Content -LiteralPath $latest.FullName -Tail 200 -ErrorAction Stop)
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $event = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                continue
            }

            if ($event.Kind -eq "snapshot") {
                return [pscustomobject]@{
                    Path = $latest.FullName
                    Event = $event
                }
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

$integratedRepair = Join-Path $SourceRoot "Repair-StudioDisplayIntegrated.ps1"
$watcher = Join-Path $SourceRoot "Watch-StudioDisplayHotplugAutomation.ps1"
$manager = Join-Path $SourceRoot "StudioDisplayManager.ps1"
$autoRepair = Join-Path $SourceRoot "Invoke-StudioDisplayAutoRepair.ps1"
$offlineGuard = Join-Path $SourceRoot "Test-StudioDisplayOfflineMaintenanceGuards.ps1"

$results = New-Object System.Collections.Generic.List[object]

foreach ($path in @($integratedRepair, $watcher, $manager, $autoRepair, $offlineGuard)) {
    $results.Add((Test-PowerShellSyntax -Path $path)) | Out-Null
}

foreach ($file in @(
        "Repair-StudioDisplayIntegrated.ps1",
        "Watch-StudioDisplayHotplugAutomation.ps1",
        "StudioDisplayManager.ps1",
        "Invoke-StudioDisplayAutoRepair.ps1",
        "Test-StudioDisplayOfflineMaintenanceGuards.ps1"
    )) {
    $results.Add((Test-InstalledFileHashMatches -FileName $file)) | Out-Null
}

$results.Add((Test-FileContains -Path $integratedRepair -Pattern 'AllowHdrIdentityRollback' -Name "guard:hdr-identity-rollback-opt-in" -Detail "HDR identity rollback is explicit opt-in")) | Out-Null
$results.Add((Test-FileContains -Path $integratedRepair -Pattern 'HDR identity rollback skipped by default' -Name "guard:hdr-identity-rollback-default-skip" -Detail "default path avoids monitor-INF churn")) | Out-Null
$results.Add((Test-FileContains -Path $integratedRepair -Pattern 'Existing Apple USB reboot-required HDR gate is active' -Name "guard:persisted-apple-usb-gate-skip" -Detail "persisted reboot-required gate skips repeated USB repair")) | Out-Null
$results.Add((Test-FileContains -Path $integratedRepair -Pattern 'Apple USB/HID interface repair skipped because \$appleUsbRepairSkipReason' -Name "guard:accurate-apple-usb-skip-reason" -Detail "skip logging preserves the true gate reason")) | Out-Null
$results.Add((Test-FileContains -Path $watcher -Pattern 'skipped because an existing Apple USB reboot-required HDR gate is active' -Name "guard:observer-classifies-persisted-gate-skip" -Detail "observer classifies persisted gate skips as reboot-required")) | Out-Null
$results.Add((Test-FileContains -Path $manager -Pattern 'Clear-StudioDisplayLastFailureState' -Name "guard:clear-stale-last-failure-function" -Detail "manager can clear stale failure evidence after physical re-enumeration")) | Out-Null
$results.Add((Test-FileContains -Path $manager -Pattern 'physical re-enumeration observed' -Name "guard:reconnect-invalidates-stale-last-failure" -Detail "reconnect path invalidates stale Apple USB reboot-required failures before retry")) | Out-Null
$results.Add((Test-FileContains -Path $manager -Pattern 'Studio Display disconnected' -Name "guard:disconnect-invalidates-stale-last-failure" -Detail "disconnect path invalidates stale Apple USB reboot-required failures")) | Out-Null
$results.Add((Test-FileContains -Path $manager -Pattern 'Save-StudioDisplayPhysicalReenumerationState' -Name "guard:manager-records-physical-reenumeration-marker" -Detail "manager persists true disconnect/reconnect/resume evidence for offline repair workers")) | Out-Null
$results.Add((Test-FileContains -Path $autoRepair -Pattern 'StudioDisplayPhysicalReenumerationState\.json' -Name "guard:auto-repair-reads-physical-reenumeration-marker" -Detail "scheduled repair can clear stale gates after a newer physical re-enumeration marker")) | Out-Null
$results.Add((Test-FileContains -Path $autoRepair -Pattern 'marker is newer than the persisted gate/failure' -Name "guard:auto-repair-clears-stale-physical-gate" -Detail "auto repair refuses to reuse stale Apple USB reboot-required gates after real hot-plug")) | Out-Null
$results.Add((Test-FileContains -Path $integratedRepair -Pattern 'Ignoring persisted .*physical re-enumeration marker is newer' -Name "guard:integrated-repair-ignores-stale-persisted-gate" -Detail "integrated repair allows one fresh pass after true physical re-enumeration")) | Out-Null

$maintenanceStatePath = Join-Path $InstallRoot "StudioDisplayAutomationMaintenanceState.json"
$maintenanceState = Read-JsonFile -Path $maintenanceStatePath
$managerPid = Get-ManagedPidState -FileName "StudioDisplayManager.pid"
$mirrorPid = Get-ManagedPidState -FileName "SystemBrightnessMirror.pid"
$bridgePid = Get-ManagedPidState -FileName "BrightnessKeyBridge.pid"
$observerSnapshot = Get-LatestObserverSnapshot

if ($maintenanceState) {
    $gateIsSafe = [bool](
        $maintenanceState.Stage -eq "HdrGateWaitingForPhysicalReenumeration" -and
        $maintenanceState.RequiresPhysicalReenumeration -and
        $maintenanceState.Resolution.Current5K -and
        $maintenanceState.Resolution.FiveK60Enumerated -and
        $maintenanceState.Hdr.HdrUnsupported -and
        -not $maintenanceState.Hdr.HdrActive -and
        $maintenanceState.Failure.AppleUsbRebootRequired
    )
    $results.Add((New-GuardResult -Name "runtime:physical-gate-preserves-5k60" -Passed $gateIsSafe -Detail "maintenance state is waiting for physical re-enumeration while preserving 5K60" -Data $maintenanceState)) | Out-Null
}
else {
    $results.Add((New-GuardResult -Name "runtime:physical-gate-preserves-5k60" -Passed $false -Detail "maintenance state missing" -Data @{ Path = $maintenanceStatePath })) | Out-Null
}

$brightnessWorkersReady = [bool]($managerPid.Running -and $mirrorPid.Running -and $bridgePid.Running)
$results.Add((New-GuardResult -Name "runtime:brightness-workers-running" -Passed $brightnessWorkersReady -Detail "manager, mirror, and brightness bridge PID files point to live processes" -Data @{
    Manager = $managerPid
    SystemBrightnessMirror = $mirrorPid
    BrightnessKeyBridge = $bridgePid
})) | Out-Null

if ($observerSnapshot) {
    $snapshot = $observerSnapshot.Event.Data
    $observerControllerReady = [bool](
        $snapshot.Controller.Manager.Running -and
        $snapshot.Controller.SystemBrightnessMirror.Running -and
        $snapshot.Controller.BrightnessKeyBridge.Running
    )
    $controllerReady = [bool]($observerControllerReady -or $brightnessWorkersReady)
    $observerShowsStableHold = [bool](
        $snapshot.Resolution.Current5K -and
        $snapshot.Resolution.FiveK60Enumerated -and
        $snapshot.Hdr.HdrUnsupported -and
        -not $snapshot.Hdr.HdrActive -and
        $controllerReady
    )
    $observerDetail = if ($observerControllerReady) {
        "latest observer snapshot confirms stable 5K60/brightness during HDR gate hold"
    }
    elseif ($brightnessWorkersReady) {
        "latest observer snapshot confirms stable 5K60/HDR gate hold; current PID files confirm brightness workers recovered after the snapshot"
    }
    else {
        "latest observer snapshot did not confirm brightness worker readiness"
    }
    $results.Add((New-GuardResult -Name "runtime:latest-observer-stable-hold" -Passed $observerShowsStableHold -Detail $observerDetail -Data @{
        Observer = $observerSnapshot
        CurrentPidState = @{
            Manager = $managerPid
            SystemBrightnessMirror = $mirrorPid
            BrightnessKeyBridge = $bridgePid
        }
    })) | Out-Null
}
else {
    $results.Add((New-GuardResult -Name "runtime:latest-observer-stable-hold" -Passed $false -Detail "no observer snapshot found" -Data @{ ReportsRoot = $reportsRoot })) | Out-Null
}

$resultArray = @()
foreach ($result in $results) {
    $resultArray += $result
}

$failed = @($resultArray | Where-Object { -not $_.Passed })
$failedArray = @()
foreach ($result in $failed) {
    $failedArray += $result
}

$report = New-Object psobject
$report | Add-Member -NotePropertyName Version -NotePropertyValue 1
$report | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue ((Get-Date).ToString("o"))
$report | Add-Member -NotePropertyName Passed -NotePropertyValue ([bool]($failedArray.Count -eq 0))
$report | Add-Member -NotePropertyName InstallRoot -NotePropertyValue $InstallRoot
$report | Add-Member -NotePropertyName SourceRoot -NotePropertyValue $SourceRoot
$report | Add-Member -NotePropertyName ReportPath -NotePropertyValue $ReportPath
$report | Add-Member -NotePropertyName Results -NotePropertyValue $resultArray
$report | Add-Member -NotePropertyName Failed -NotePropertyValue $failedArray

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $ReportPath -Encoding ascii -ErrorAction SilentlyContinue

Write-Host ("Offline maintenance guard report: {0}" -f $ReportPath)
foreach ($result in $results) {
    $status = if ($result.Passed) { "PASS" } else { "FAIL" }
    Write-Host ("[{0}] {1} - {2}" -f $status, $result.Name, $result.Detail)
}

if ($failedArray.Count -gt 0) {
    exit 1
}

exit 0
