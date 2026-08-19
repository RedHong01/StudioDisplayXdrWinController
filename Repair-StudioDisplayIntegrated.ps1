[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Elevate,
    [switch]$ForceLinkRefresh,
    [switch]$RestartAppleUsb4Router,
    [switch]$EnsureBootCampMonitorDriver,
    [switch]$AllowWcgFallback,
    [switch]$AllowHdrIdentityRollback,
    [switch]$SkipHdr,
    [switch]$SkipAppleUsbRepair,
    [switch]$SkipBrightness,
    [string]$LogPath
)

$ErrorActionPreference = "Continue"

$scriptRoot = $PSScriptRoot
$reportsRoot = Join-Path $scriptRoot "reports"
$resolutionLadderScript = Join-Path $scriptRoot "Test-StudioDisplayResolutionLadder.ps1"
$externalModeRepairScript = Join-Path $scriptRoot "Repair-StudioDisplayExternalMode.ps1"
$linkRefreshScript = Join-Path $scriptRoot "Refresh-StudioDisplayXdrLink.ps1"
$bootCampDriverScript = Join-Path $scriptRoot "Install-StudioDisplayBootCampStyleMonitorDriver.ps1"
$appleUsbInterfaceRepairScript = Join-Path $scriptRoot "Repair-StudioDisplayAppleUsbInterfaces.ps1"
$hdrIdentityRollbackScript = Join-Path $scriptRoot "Repair-StudioDisplayHdrIdentityRollback.ps1"
$hdrStateScript = Join-Path $scriptRoot "Set-StudioDisplayHdrState.ps1"
$advancedColorScript = Join-Path $scriptRoot "Get-StudioDisplayAdvancedColorState.ps1"
$brightnessHidScript = Join-Path $scriptRoot "StudioDisplayHid.ps1"
$lastFailureStateFile = Join-Path $scriptRoot "StudioDisplayLastFailureState.json"
$hdrGateBlockStateFile = Join-Path $scriptRoot "StudioDisplayHdrGateBlockState.json"
$physicalReenumerationStateFile = Join-Path $scriptRoot "StudioDisplayPhysicalReenumerationState.json"
$powershellExe = if (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")) { Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe" } else { Join-Path $PSHOME "powershell.exe" }
$installedToolsRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools"
$installedManagerRoot = Join-Path $installedToolsRoot "StudioDisplayManager"
$installedBrightnessBridgeRoot = $installedManagerRoot
$installedMirrorScript = Join-Path $installedManagerRoot "SystemBrightnessMirror.ps1"
$installedMirrorPidFile = Join-Path $installedManagerRoot "SystemBrightnessMirror.pid"
$installedBridgeScript = Join-Path $installedBrightnessBridgeRoot "BrightnessKeyBridge.ps1"
$installedBridgePidFile = Join-Path $installedBrightnessBridgeRoot "BrightnessKeyBridge.pid"
$installedMirrorMutexName = "StudioDisplaySystemBrightnessMirror"
$installedBridgeMutexName = "StudioDisplayBrightnessKeyBridge"

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

$script:effectiveEnsureBootCampMonitorDriver = [bool]$EnsureBootCampMonitorDriver
$script:bootCampModeTableRebindAttempted = $false
$script:modeTableRegistryNudgeAttempted = $false
$script:nativeIdentityRefreshAttempted = $false
$script:bootCampDriverSkippedBecauseIdentityReady = $false
$script:bootCampDriverSuccessFallbackAttempted = $false
$script:stageTimings = New-Object System.Collections.Generic.List[object]
$script:overallStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$modeTableRecoveryWaitSeconds = 60
$modeTableRecoveryPollSeconds = 5

if (-not $LogPath) {
    New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null
    $LogPath = Join-Path $reportsRoot ("StudioDisplayIntegratedRepair-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

function Write-RepairLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
}

function Add-RepairStageTiming {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [string]$Kind = "stage",
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Elapsed,
        [AllowNull()][object]$ExitCode = $null,
        [bool]$TimedOut = $false,
        [string]$Result = ""
    )

    $entry = [ordered]@{
        Timestamp = (Get-Date).ToString("o")
        Label = $Label
        Kind = $Kind
        DurationMs = [int][Math]::Round($Elapsed.TotalMilliseconds)
        DurationSec = [Math]::Round($Elapsed.TotalSeconds, 3)
        ExitCode = $ExitCode
        TimedOut = $TimedOut
        Result = $Result
    }

    $script:stageTimings.Add([pscustomobject]$entry) | Out-Null
    Write-RepairLog ("TIMING label=`"{0}`" kind={1} durationMs={2} durationSec={3} exitCode={4} timedOut={5} result={6}" -f $Label, $Kind, $entry.DurationMs, $entry.DurationSec, $ExitCode, $TimedOut, $Result)
}

function Invoke-RepairStage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock
    )

    $stageStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = $null
    $stageResult = "completed"
    try {
        $result = & $ScriptBlock
        return $result
    }
    catch {
        $stageResult = "error: $($_.Exception.Message)"
        throw
    }
    finally {
        $stageStopwatch.Stop()
        Add-RepairStageTiming -Label $Label -Kind "stage" -Elapsed $stageStopwatch.Elapsed -Result $stageResult
    }
}

function Write-RepairTimingSummary {
    param([int]$FinalExitCode)

    try {
        if ($script:overallStopwatch.IsRunning) {
            $script:overallStopwatch.Stop()
        }

        $timingPath = [System.IO.Path]::ChangeExtension($LogPath, ".timings.json")
        $summary = [ordered]@{
            Version = 1
            FinishedAt = (Get-Date).ToString("o")
            FinalExitCode = $FinalExitCode
            TotalDurationMs = [int][Math]::Round($script:overallStopwatch.Elapsed.TotalMilliseconds)
            TotalDurationSec = [Math]::Round($script:overallStopwatch.Elapsed.TotalSeconds, 3)
            Stages = @($script:stageTimings.ToArray())
        }

        $summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $timingPath -Encoding utf8 -ErrorAction Stop
        $slowest = @($script:stageTimings.ToArray() | Sort-Object DurationMs -Descending | Select-Object -First 5)
        if ($slowest.Count -gt 0) {
            Write-RepairLog "Timing summary written to $timingPath. Slowest stages: $((@($slowest | ForEach-Object { '{0}={1}s' -f $_.Label, $_.DurationSec }) -join '; '))"
        }
        else {
            Write-RepairLog "Timing summary written to $timingPath."
        }
    }
    catch {
        Write-RepairLog "Could not write timing summary: $($_.Exception.Message)"
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedSelf {
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-LogPath", "`"$LogPath`""
    )

    foreach ($switchName in @(
            "Apply",
            "ForceLinkRefresh",
            "RestartAppleUsb4Router",
            "EnsureBootCampMonitorDriver",
            "AllowWcgFallback",
            "AllowHdrIdentityRollback",
            "SkipHdr",
            "SkipAppleUsbRepair",
            "SkipBrightness"
        )) {
        if ((Get-Variable -Name $switchName -ValueOnly)) {
            $arguments += "-$switchName"
        }
    }

    Write-RepairLog "Launching elevated integrated repair through UAC. Approve the Windows UAC prompt; otherwise USB4/monitor re-enumeration and HDR repair will not run."
    Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 180
    )

    Write-RepairLog "Running $Label."
    $toolStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '_')
    $captureId = [Guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $env:TEMP ("StudioDisplay-{0}-{1}-{2}.out.log" -f $safeLabel, $PID, $captureId)
    $stderrPath = Join-Path $env:TEMP ("StudioDisplay-{0}-{1}-{2}.err.log" -f $safeLabel, $PID, $captureId)
    $exitCodePath = Join-Path $env:TEMP ("StudioDisplay-{0}-{1}-{2}.exit" -f $safeLabel, $PID, $captureId)
    $wrapperPath = Join-Path $env:TEMP ("StudioDisplay-{0}-{1}-{2}.wrapper.ps1" -f $safeLabel, $PID, $captureId)
    $output = @()
    $exitCode = 1
    $timedOut = $false

    try {
        $escapedPowerShellExe = $powershellExe.Replace("'", "''")
        $escapedExitCodePath = $exitCodePath.Replace("'", "''")
        $argumentLiteralBlock = (($Arguments | ForEach-Object {
            "    '{0}'" -f ([string]$_).Replace("'", "''")
        }) -join ",`r`n")
        $wrapper = @"
`$ErrorActionPreference = 'Continue'
`$toolArguments = @(
$argumentLiteralBlock
)
& '$escapedPowerShellExe' @toolArguments
`$toolExitCode = if (`$null -ne `$global:LASTEXITCODE) { [int]`$global:LASTEXITCODE } elseif (`$?) { 0 } else { 1 }
Set-Content -LiteralPath '$escapedExitCodePath' -Value ([string]`$toolExitCode) -Encoding ascii
exit `$toolExitCode
"@
        Set-Content -LiteralPath $wrapperPath -Value $wrapper -Encoding ascii -ErrorAction Stop

        $process = Start-Process -FilePath $powershellExe -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $wrapperPath
        ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        $startedAt = Get-Date
        $lastHeartbeatAt = $startedAt

        while (-not $process.HasExited) {
            Start-Sleep -Seconds 2
            $now = Get-Date
            $elapsedSeconds = ($now - $startedAt).TotalSeconds

            if ($TimeoutSeconds -gt 0 -and $elapsedSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                Write-RepairLog "$Label timed out after $TimeoutSeconds seconds; stopping child PowerShell PID $($process.Id) so the hot-plug pipeline can release its single-repair lock."
                try {
                    $process.Kill()
                }
                catch {
                    Write-RepairLog "$Label timeout kill failed for PID $($process.Id): $($_.Exception.Message)"
                }

                try {
                    $process.WaitForExit(5000) | Out-Null
                }
                catch {
                    Write-RepairLog "$Label timeout wait-after-kill failed: $($_.Exception.Message)"
                }

                break
            }

            if (($now - $lastHeartbeatAt).TotalSeconds -ge 15) {
                $lastHeartbeatAt = $now
                $timeoutText = if ($TimeoutSeconds -gt 0) { "timeout=${TimeoutSeconds}s" } else { "timeout=none" }
                Write-RepairLog "$Label is still running after $([int]$elapsedSeconds)s ($timeoutText)."
            }
        }

        if ($timedOut) {
            $exitCode = 124
        }
        else {
            try {
                $process.WaitForExit() | Out-Null
            }
            catch {
                Write-RepairLog "$Label final WaitForExit failed: $($_.Exception.Message)"
            }

            $sidecarExitCode = $null
            if (Test-Path -LiteralPath $exitCodePath) {
                $sidecarText = (Get-Content -LiteralPath $exitCodePath -ErrorAction SilentlyContinue | Select-Object -First 1)
                if ($sidecarText -match '^-?\d+$') {
                    $sidecarExitCode = [int]$sidecarText
                }
            }

            $process.Refresh()
            $rawExitCode = $null
            try {
                $rawExitCode = $process.ExitCode
            }
            catch {
                Write-RepairLog "$Label completed, but process ExitCode could not be read: $($_.Exception.Message)"
            }

            if ($null -ne $sidecarExitCode) {
                $exitCode = $sidecarExitCode
                if ($null -eq $rawExitCode -or [string]::IsNullOrWhiteSpace([string]$rawExitCode)) {
                    Write-RepairLog "$Label completed without a readable Start-Process exit code; using child-reported exit code $exitCode from the wrapper sidecar."
                }
                elseif ([int]$rawExitCode -ne $exitCode) {
                    Write-RepairLog "$Label Start-Process exit code $rawExitCode differed from child-reported exit code $exitCode; using the child-reported value for repair gating."
                }
            }
            elseif ($null -eq $rawExitCode -or [string]::IsNullOrWhiteSpace([string]$rawExitCode)) {
                $exitCode = 1
                Write-RepairLog "$Label completed but did not expose a process exit code and no child-reported sidecar was written; treating this as failure so HDR/USB gates are not accidentally accepted."
            }
            else {
                $exitCode = [int]$rawExitCode
            }
        }

        if (Test-Path -LiteralPath $stdoutPath) {
            $output += @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue)
        }

        if (Test-Path -LiteralPath $stderrPath) {
            $output += @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue)
        }
    }
    catch {
        $output += "Launch failed: $($_.Exception.Message)"
        $exitCode = 1
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $exitCodePath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $wrapperPath -Force -ErrorAction SilentlyContinue
    }

    foreach ($line in $output) {
        Write-RepairLog "${Label}: $line"
    }

    if ($timedOut) {
        Write-RepairLog "$Label exit code: $exitCode (timed out)"
    }
    else {
        Write-RepairLog "$Label exit code: $exitCode"
    }

    $toolStopwatch.Stop()
    $resultText = if ($timedOut) { "timeout" } elseif ($exitCode -eq 0) { "ok" } else { "exit-$exitCode" }
    Add-RepairStageTiming -Label $Label -Kind "tool" -Elapsed $toolStopwatch.Elapsed -ExitCode $exitCode -TimedOut $timedOut -Result $resultText

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
        TimedOut = $timedOut
    }
}

function Test-EdidHasHdrStaticMetadata {
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

function Get-BootCampStyleMonitorFallbackState {
    $activeMs0001Ids = @()
    try {
        $activeMs0001Ids = @(
            Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop |
                Where-Object { $_.Active -and $_.InstanceName -match '^DISPLAY\\MS_0001\\' } |
                ForEach-Object { ([string]$_.InstanceName) -replace '_\d+$', '' }
        )
    }
    catch {
        Write-RepairLog "Boot Camp-style fallback preflight could not read active monitor identity: $($_.Exception.Message)"
    }

    $driverPackagePresent = $false
    try {
        $driverStoreText = ((& pnputil.exe /enum-drivers /class Monitor 2>&1) -join "`n")
        $driverPackagePresent = [bool]($driverStoreText -match 'StudioDisplayXdrBootCampStyleMonitor|StudioDIsplayWithWindows')
    }
    catch {
        Write-RepairLog "Boot Camp-style fallback preflight could not read monitor driver store: $($_.Exception.Message)"
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
            Write-RepairLog "Boot Camp-style fallback preflight could not read monitor binding for $instanceId`: $($_.Exception.Message)"
        }
    }

    $effectiveEdidBytes = 0
    $effectiveHasHdrMetadata = $false
    $ms0001RegistryPresent = $false
    $basePath = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\MS_0001"
    try {
        if (Test-Path -LiteralPath $basePath) {
            $activeLookup = @{}
            foreach ($instanceId in $activeMs0001Ids) {
                $activeLookup[$instanceId.ToUpperInvariant()] = $true
            }

            foreach ($instanceKey in Get-ChildItem -LiteralPath $basePath -ErrorAction Stop) {
                $instanceId = "DISPLAY\MS_0001\$($instanceKey.PSChildName)"
                if ($activeLookup.Count -gt 0 -and -not $activeLookup.ContainsKey($instanceId.ToUpperInvariant())) {
                    continue
                }

                $ms0001RegistryPresent = $true
                $deviceParamsPath = Join-Path $instanceKey.PSPath "Device Parameters"
                $edid = $null
                try {
                    $edid = [byte[]](Get-ItemProperty -LiteralPath $deviceParamsPath -Name EDID -ErrorAction Stop).EDID
                }
                catch {
                    $edid = $null
                }

                if ($edid) {
                    $effectiveEdidBytes = [Math]::Max($effectiveEdidBytes, $edid.Length)
                    if (Test-EdidHasHdrStaticMetadata -Edid $edid) {
                        $effectiveHasHdrMetadata = $true
                    }
                }
            }
        }
    }
    catch {
        Write-RepairLog "Boot Camp-style fallback preflight could not read MS_0001 EDID cache: $($_.Exception.Message)"
    }

    $activeMs0001 = [bool]($activeMs0001Ids.Count -gt 0)
    $bootCampStyleReady = [bool](
        -not $activeMs0001 -or
        (
            $driverPackagePresent -and
            $boundCustomMonitorInf -and
            $effectiveEdidBytes -gt 128 -and
            $effectiveHasHdrMetadata
        )
    )
    $needsBootCampRefresh = [bool]($activeMs0001 -and -not $bootCampStyleReady)

    return [pscustomobject]@{
        ActiveMs0001 = $activeMs0001
        ActiveInstanceIds = @($activeMs0001Ids)
        DriverPackagePresent = $driverPackagePresent
        UsesMicrosoftMonitorInf = $usesMicrosoftMonitorInf
        BoundCustomMonitorInf = $boundCustomMonitorInf
        Ms0001RegistryPresent = $ms0001RegistryPresent
        EffectiveEdidBytes = $effectiveEdidBytes
        EffectiveHasHdrMetadata = $effectiveHasHdrMetadata
        BootCampStyleReady = $bootCampStyleReady
        NeedsBootCampRefresh = $needsBootCampRefresh
        Summary = "activeMs0001=$activeMs0001, bootCampStyleReady=$bootCampStyleReady, driverPackagePresent=$driverPackagePresent, usesMicrosoftMonitorInf=$usesMicrosoftMonitorInf, boundCustomMonitorInf=$boundCustomMonitorInf, currentDrivers=$($currentDriverBindings -join ';'), edidBytes=$effectiveEdidBytes, hdrMetadata=$effectiveHasHdrMetadata"
    }
}

function Test-ManagedPidRunning {
    param([string]$PidPath)

    if (-not (Test-Path -LiteralPath $PidPath)) {
        return $false
    }

    $processIdText = Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($processIdText -notmatch '^\d+$') {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    $process = Get-Process -Id ([int]$processIdText) -ErrorAction SilentlyContinue
    if ($process) {
        return $true
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    return $false
}

function Test-NamedMutexHeld {
    param([string]$Name)

    $createdNew = $false
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($true, $Name, [ref]$createdNew)
        return [bool](-not $createdNew)
    }
    catch {
        Write-RepairLog "Named mutex probe failed for $Name`: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($mutex) {
            if ($createdNew) {
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
    $installRootLower = $installedManagerRoot.ToLowerInvariant()
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
                Write-RepairLog "Could not inspect PowerShell command lines for $scriptLeaf worker recovery: $($_.Exception.Message)"
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
        if (-not ($exactScriptMatch -or $sameInstallRootScriptMatch)) {
            continue
        }

        $process = Get-Process -Id ([int]$processInfo.ProcessId) -ErrorAction SilentlyContinue
        if ($process) {
            $matches += [pscustomobject]@{
                Id = [int]$processInfo.ProcessId
                Process = $process
            }
        }
    }

    return @($matches)
}

function Set-ManagedPidFileForWorker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$PidPath,
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    try {
        Set-Content -LiteralPath $PidPath -Value $Process.Id -Encoding ascii -ErrorAction Stop
        Write-RepairLog "$Label worker adopted with managed PID=$($Process.Id)."
        return $true
    }
    catch {
        Write-RepairLog "$Label worker is running as PID=$($Process.Id), but its pid file could not be written: $($_.Exception.Message)"
        return $false
    }
}

function Adopt-InstalledBrightnessWorker {
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
        return (Set-ManagedPidFileForWorker -Label $Label -PidPath $PidPath -Process $candidates[0].Process)
    }

    if ($candidates.Count -gt 1 -and -not $Quiet) {
        Write-RepairLog "$Label worker adoption skipped because multiple candidates were found: $(@($candidates | ForEach-Object { $_.Id }) -join ', ')."
    }

    return $false
}

function Test-InstalledBrightnessWorkerAvailable {
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

    if (Test-ManagedPidRunning -PidPath $PidPath) {
        return $true
    }

    if (Adopt-InstalledBrightnessWorker -Label $Label -ScriptPath $ScriptPath -PidPath $PidPath -Quiet) {
        return $true
    }

    return (Test-NamedMutexHeld -Name $MutexName)
}

function Stop-OrphanInstalledBrightnessWorkers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $candidates = @(Get-StudioDisplayWorkerProcessCandidates -ScriptPath $ScriptPath)
    foreach ($candidate in $candidates) {
        try {
            Write-RepairLog "Stopping orphaned $Label worker PID=$($candidate.Id)."
            Stop-Process -Id $candidate.Id -Force -ErrorAction Stop
            Start-Sleep -Milliseconds 500
        }
        catch {
            Write-RepairLog "Could not stop orphaned $Label worker PID=$($candidate.Id): $($_.Exception.Message)"
        }
    }
}

function Test-ExternalOnlyScreenTopologyReady {
    try {
        return [bool](@([System.Windows.Forms.Screen]::AllScreens).Count -eq 1)
    }
    catch {
        Write-RepairLog "External-only topology preflight failed: $($_.Exception.Message)"
        return $false
    }
}

function Stop-ManagedPid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$PidPath
    )

    if (-not (Test-Path -LiteralPath $PidPath)) {
        Write-RepairLog "$Label was not running."
        return
    }

    $processIdText = Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($processIdText -match '^\d+$') {
        $process = Get-Process -Id ([int]$processIdText) -ErrorAction SilentlyContinue
        if ($process) {
            Write-RepairLog "Stopping $Label before display/HDR repair. PID=$($process.Id)"
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
        }
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Start-InstalledMirrorService {
    if (-not (Test-Path -LiteralPath $installedMirrorScript)) {
        Write-RepairLog "Cannot restart SystemBrightnessMirror because script is missing: $installedMirrorScript"
        return $false
    }

    if (Test-ManagedPidRunning -PidPath $installedMirrorPidFile) {
        Write-RepairLog "SystemBrightnessMirror restart skipped because an existing managed worker is already running."
        return $true
    }

    if (Adopt-InstalledBrightnessWorker -Label "SystemBrightnessMirror" -ScriptPath $installedMirrorScript -PidPath $installedMirrorPidFile) {
        return $true
    }

    if (Test-NamedMutexHeld -Name $installedMirrorMutexName) {
        Write-RepairLog "SystemBrightnessMirror mutex is held without a managed pid file and no unique adoptable worker was found; not launching a duplicate mirror."
        return $true
    }

    $process = Start-Process -FilePath $powershellExe -WorkingDirectory $installedManagerRoot -WindowStyle Hidden -PassThru -ArgumentList @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $installedMirrorScript,
        "-EnableLogging"
    )

    Start-Sleep -Seconds 2
    $running = Test-ManagedPidRunning -PidPath $installedMirrorPidFile
    if (-not $running -and $process -and -not $process.HasExited) {
        $running = Set-ManagedPidFileForWorker -Label "SystemBrightnessMirror" -PidPath $installedMirrorPidFile -Process $process
    }
    if (-not $running -and (Test-NamedMutexHeld -Name $installedMirrorMutexName)) {
        $running = Adopt-InstalledBrightnessWorker -Label "SystemBrightnessMirror" -ScriptPath $installedMirrorScript -PidPath $installedMirrorPidFile
        if (-not $running) {
            Write-RepairLog "SystemBrightnessMirror mutex owner was treated as running to avoid launching duplicates."
            $running = $true
        }
    }
    Write-RepairLog "SystemBrightnessMirror restart result: $running"
    return $running
}

function Start-InstalledBrightnessBridge {
    if (-not (Test-Path -LiteralPath $installedBridgeScript)) {
        Write-RepairLog "Cannot restart BrightnessKeyBridge because script is missing: $installedBridgeScript"
        return $false
    }

    if (Test-ManagedPidRunning -PidPath $installedBridgePidFile) {
        Write-RepairLog "BrightnessKeyBridge restart skipped because an existing managed worker is already running."
        return $true
    }

    if (Adopt-InstalledBrightnessWorker -Label "BrightnessKeyBridge" -ScriptPath $installedBridgeScript -PidPath $installedBridgePidFile) {
        return $true
    }

    if (Test-NamedMutexHeld -Name $installedBridgeMutexName) {
        Write-RepairLog "BrightnessKeyBridge mutex is held without a managed pid file and no unique adoptable worker was found; not launching a duplicate key bridge."
        return $true
    }

    $process = Start-Process -FilePath $powershellExe -WorkingDirectory $installedBrightnessBridgeRoot -WindowStyle Hidden -PassThru -ArgumentList @(
        "-Sta",
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $installedBridgeScript,
        "-EnableLogging",
        "-StepPercent", "10"
    )

    Start-Sleep -Seconds 2
    $running = Test-ManagedPidRunning -PidPath $installedBridgePidFile
    if (-not $running -and $process -and -not $process.HasExited) {
        $running = Set-ManagedPidFileForWorker -Label "BrightnessKeyBridge" -PidPath $installedBridgePidFile -Process $process
    }
    if (-not $running -and (Test-NamedMutexHeld -Name $installedBridgeMutexName)) {
        $running = Adopt-InstalledBrightnessWorker -Label "BrightnessKeyBridge" -ScriptPath $installedBridgeScript -PidPath $installedBridgePidFile
        if (-not $running) {
            Write-RepairLog "BrightnessKeyBridge mutex owner was treated as running to avoid launching duplicates."
            $running = $true
        }
    }
    Write-RepairLog "BrightnessKeyBridge restart result: $running"
    return $running
}

function Suspend-BrightnessServicesForRepair {
    if ($SkipBrightness) {
        Write-RepairLog "Brightness service suspend skipped because -SkipBrightness was passed."
        return [pscustomobject]@{
            MirrorWasRunning = $false
            BridgeWasRunning = $false
            Suspended = $false
        }
    }

    $state = [pscustomobject]@{
        MirrorWasRunning = Test-InstalledBrightnessWorkerAvailable -Label "SystemBrightnessMirror" -ScriptPath $installedMirrorScript -PidPath $installedMirrorPidFile -MutexName $installedMirrorMutexName
        BridgeWasRunning = Test-InstalledBrightnessWorkerAvailable -Label "BrightnessKeyBridge" -ScriptPath $installedBridgeScript -PidPath $installedBridgePidFile -MutexName $installedBridgeMutexName
        Suspended = $false
    }

    Write-RepairLog "Brightness preflight: mirrorRunning=$($state.MirrorWasRunning), bridgeRunning=$($state.BridgeWasRunning)"

    if (-not $Apply) {
        Write-RepairLog "Dry run: brightness services would be paused before display/HDR repair and restored at the end."
        return $state
    }

    if ($state.BridgeWasRunning) {
        Stop-ManagedPid -Label "BrightnessKeyBridge" -PidPath $installedBridgePidFile
        Stop-OrphanInstalledBrightnessWorkers -Label "BrightnessKeyBridge" -ScriptPath $installedBridgeScript
        $state.Suspended = $true
    }

    if ($state.MirrorWasRunning) {
        Stop-ManagedPid -Label "SystemBrightnessMirror" -PidPath $installedMirrorPidFile
        Stop-OrphanInstalledBrightnessWorkers -Label "SystemBrightnessMirror" -ScriptPath $installedMirrorScript
        $state.Suspended = $true
    }

    return $state
}

function Resume-BrightnessServicesAfterRepair {
    param([object]$State)

    if ($SkipBrightness) {
        Write-RepairLog "Brightness service resume skipped because -SkipBrightness was passed."
        return
    }

    if (-not $State) {
        Write-RepairLog "Brightness service resume skipped because no preflight state was captured."
        return
    }

    if (-not $Apply) {
        Write-RepairLog "Dry run: brightness services would now be restored to their original running state."
        return
    }

    Start-Sleep -Seconds 2

    if ($State.MirrorWasRunning) {
        [void](Start-InstalledMirrorService)
    }
    else {
        Write-RepairLog "SystemBrightnessMirror was not running before repair; leaving it stopped."
    }

    if ($State.BridgeWasRunning) {
        [void](Start-InstalledBrightnessBridge)
    }
    else {
        Write-RepairLog "BrightnessKeyBridge was not running before repair; leaving it stopped."
    }
}

function Get-ResolutionLadderState {
    if (-not (Test-Path -LiteralPath $resolutionLadderScript)) {
        return [pscustomobject]@{
            Has5K60 = $false
            Has5K120 = $false
            Summary = "resolution ladder script missing"
        }
    }

    $result = Invoke-Tool -Label "resolution ladder" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $resolutionLadderScript
    )

    $joined = ($result.Output -join "`n")
    $has5K60Enumerated = (
        $joined -match '(?m)^5K 60Hz legacy Studio Display fallback[^\r\n]*[^\S\r\n]+5120[^\S\r\n]+2880[^\S\r\n]+60[^\S\r\n]+True(?:[^\S\r\n]|$)' -or
        $joined -match '(?m)^Best enumerated mode:[^\S\r\n]+5120x2880@60Hz[^\S\r\n]*$'
    )
    $has5K60Accepted = ($joined -match '(?m)^5K 60Hz legacy Studio Display fallback[^\r\n]*[^\S\r\n]+5120[^\S\r\n]+2880[^\S\r\n]+60[^\S\r\n]+(True|False)[^\S\r\n]+SUCCESS(?:[^\S\r\n]|$)')
    return [pscustomobject]@{
        HasCurrent5K = ($joined -match '(?m)^Current mode:[^\S\r\n]+5120x2880@')
        Has5K60 = $has5K60Enumerated
        Has5K60Enumerated = $has5K60Enumerated
        Has5K60Accepted = $has5K60Accepted
        Has5K120 = (
            $joined -match '(?m)^5K 120Hz native XDR target[^\r\n]*[^\S\r\n]+5120[^\S\r\n]+2880[^\S\r\n]+120[^\S\r\n]+True(?:[^\S\r\n]|$)' -or
            $joined -match '(?m)^Best enumerated mode:[^\S\r\n]+5120x2880@120Hz[^\S\r\n]*$'
        )
        Summary = ($result.Output | Select-String -Pattern 'Current mode:|Best enumerated mode:' | ForEach-Object { $_.Line }) -join '; '
    }
}

function Wait-For5K60ModeTableRecovery {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolutionState,
        [string]$Reason = "mode-table recovery",
        [int]$TimeoutSeconds = $modeTableRecoveryWaitSeconds,
        [int]$PollSeconds = $modeTableRecoveryPollSeconds
    )

    if ($ResolutionState.Has5K60Enumerated) {
        return $ResolutionState
    }

    if (-not $ResolutionState.HasCurrent5K) {
        Write-RepairLog "5K60 mode-table settle wait skipped for $Reason because the current Studio Display mode is not 5K. $($ResolutionState.Summary)"
        return $ResolutionState
    }

    if ($TimeoutSeconds -le 0) {
        return $ResolutionState
    }

    $lastState = $ResolutionState
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-RepairLog "5K60 is still missing from the Windows mode table after $Reason. Success-first mode will wait up to ${TimeoutSeconds}s for delayed USB4/EDID enumeration before allowing the pipeline to fail."

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds ([Math]::Max(1, $PollSeconds))
        $lastState = Get-ResolutionLadderState
        Write-RepairLog "5K60 mode-table settle poll: $($lastState.Summary)"

        if ($lastState.Has5K60Enumerated) {
            Write-RepairLog "5K60 mode table recovered during settle wait after $Reason. Continuing to external-only/HDR gates."
            return $lastState
        }

        if (-not $lastState.HasCurrent5K) {
            Write-RepairLog "5K60 mode-table settle wait stopped because the active 5K display mode disappeared. $($lastState.Summary)"
            return $lastState
        }
    }

    Write-RepairLog "5K60 mode table did not recover during the ${TimeoutSeconds}s settle wait after $Reason. Final validation will keep exit code non-zero; automation must continue observing/retrying instead of accepting WCG/1080 fallback."
    return $lastState
}

function Invoke-LinkRefreshIfNeeded {
    param(
        [object]$InitialState,
        [switch]$Force
    )

    if ($SkipHdr -and $SkipBrightness -and -not $ForceLinkRefresh -and -not $Force) {
        return $InitialState
    }

    $needsRefresh = $Force -or $ForceLinkRefresh -or $script:effectiveEnsureBootCampMonitorDriver -or -not $InitialState.Has5K60
    if (-not $needsRefresh) {
        Write-RepairLog "5K60 is already enumerated. Skipping USB4 link refresh."
        return $InitialState
    }

    if (-not $Apply) {
        if (-not $InitialState.Has5K60) {
            Write-RepairLog "Dry run: 5K60 is missing but -Apply was not passed, so USB4 link refresh was not started."
        }
        elseif ($script:effectiveEnsureBootCampMonitorDriver) {
            Write-RepairLog "Dry run: Boot Camp-style monitor driver refresh would be followed by USB4 link retraining."
        }
        elseif ($ForceLinkRefresh) {
            Write-RepairLog "Dry run: forced USB4 link refresh was requested but -Apply was not passed."
        }
        elseif ($Force) {
            Write-RepairLog "Dry run: native identity USB4 link refresh was requested but -Apply was not passed."
        }
        else {
            Write-RepairLog "Dry run: USB4 link refresh would be started, but -Apply was not passed."
        }
        return $InitialState
    }

    if (-not (Test-IsAdministrator)) {
        Write-RepairLog "USB4 link refresh skipped because this process is not elevated. Re-run with -Elevate so PnP rescan/router restart can run; non-elevated DisplaySwitch-only refresh is skipped to avoid leaving the session on an internal display when the external mode table is missing."
        return $InitialState
    }

    if (-not (Test-Path -LiteralPath $linkRefreshScript)) {
        Write-RepairLog "Link refresh script is missing: $linkRefreshScript"
        return $InitialState
    }

    $refreshArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $linkRefreshScript,
        "-RestartFallbackMonitor"
    )

    if ($RestartAppleUsb4Router -or $script:effectiveEnsureBootCampMonitorDriver -or $Force -or -not $InitialState.Has5K60) {
        $refreshArgs += "-RestartAppleUsb4Router"
    }

    Invoke-Tool -Label "Studio Display XDR link refresh" -Arguments $refreshArgs -TimeoutSeconds 240 | Out-Null
    Start-Sleep -Seconds 3
    return Get-ResolutionLadderState
}

function Invoke-BootCampDriverIfRequested {
    if (-not $script:effectiveEnsureBootCampMonitorDriver) {
        Write-RepairLog "Boot Camp-style monitor driver install skipped. Pass -EnsureBootCampMonitorDriver to reinstall it."
        return
    }

    if (-not $Apply) {
        Write-RepairLog "Dry run: Boot Camp-style monitor driver would be installed with HDR metadata."
        return
    }

    if (-not (Test-Path -LiteralPath $bootCampDriverScript)) {
        Write-RepairLog "Boot Camp-style monitor driver script is missing: $bootCampDriverScript"
        return
    }

    $driverOutputDirectory = Join-Path $scriptRoot "drivers\StudioDisplayXdrBootCampStyleMonitor"
    $driverLogPath = Join-Path $driverOutputDirectory "install.log"
    Invoke-Tool -Label "Boot Camp-style monitor driver" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $bootCampDriverScript,
        "-EnableHdrMetadata",
        "-SignWithLocalCertificate",
        "-TrustLocalSigningCertificate",
        "-Apply",
        "-OutputDirectory", $driverOutputDirectory,
        "-LogPath", $driverLogPath
    ) -TimeoutSeconds 240 | Out-Null
}

function Wait-BootCampStyleMonitorIdentity {
    param([int]$TimeoutSeconds = 24)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastState = $null

    while ($true) {
        $lastState = Get-BootCampStyleMonitorFallbackState
        if (-not $lastState.ActiveMs0001) {
            Write-RepairLog "Boot Camp-style monitor identity gate skipped because the active display is not DISPLAY\\MS_0001."
            return $lastState
        }

        if ($lastState.BootCampStyleReady) {
            Write-RepairLog "Boot Camp-style monitor identity is ready before HDR. $($lastState.Summary)"
            return $lastState
        }

        if ((Get-Date) -ge $deadline) {
            break
        }

        Write-RepairLog "Waiting for Boot Camp-style monitor identity to beat the generic fallback before HDR. $($lastState.Summary)"
        Start-Sleep -Seconds 2
    }

    Write-RepairLog "Boot Camp-style monitor identity did not become ready before HDR timeout. $($lastState.Summary)"
    return $lastState
}

function Invoke-HdrCapabilityNativeIdentityRefreshIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolutionState,
        [Parameter(Mandatory = $true)]
        [object]$IdentityState,
        [Parameter(Mandatory = $true)]
        [object]$HdrState,
        [bool]$ExternalOnlyReady,
        [object]$PersistedAppleUsbRebootGate
    )

    $currentResult = {
        param([bool]$Attempted = $false)

        [pscustomobject]@{
            ResolutionState = $ResolutionState
            IdentityState = $IdentityState
            HdrState = $HdrState
            ExternalOnlyReady = $ExternalOnlyReady
            Attempted = $Attempted
        }
    }

    if ($script:nativeIdentityRefreshAttempted) {
        return & $currentResult
    }

    $needsNativeIdentityRefresh = [bool](
        $ResolutionState.Has5K60Enumerated -and
        $IdentityState.ActiveMs0001 -and
        $IdentityState.BootCampStyleReady -and
        $HdrState.HdrUnsupported -and
        -not $HdrState.HdrActive
    )

    if (-not $needsNativeIdentityRefresh) {
        return & $currentResult
    }

    if ($PersistedAppleUsbRebootGate -and [bool]$PersistedAppleUsbRebootGate.Active) {
        Write-RepairLog "Native APPA identity refresh skipped because an existing Apple USB reboot-required HDR gate is active (source=$($PersistedAppleUsbRebootGate.Source), updatedAt=$($PersistedAppleUsbRebootGate.UpdatedAt)). Waiting for reboot/resume/full Thunderbolt re-enumeration instead of causing extra topology churn."
        return & $currentResult
    }

    if (-not $Apply) {
        Write-RepairLog "Dry run: HDR is unsupported while stable 5K60 is exposed through active MS_0001; would run one protected Boot Camp-style monitor driver gate followed by one non-destructive native APPA identity USB4/link refresh before Apple USB deep repair."
        return & $currentResult
    }

    if (-not (Test-IsAdministrator)) {
        Write-RepairLog "Native APPA identity refresh skipped because this process is not elevated."
        return & $currentResult
    }

    $script:nativeIdentityRefreshAttempted = $true
    Write-RepairLog "HDR is unsupported while stable 5K60 is exposed through active MS_0001. Replaying the exact known-good a07bebe recovery shape: run one protected Boot Camp-style monitor driver gate, then one non-destructive monitor/router USB4 refresh to give Windows a chance to re-activate the native APPA Studio Display identity before Apple USB/HID deep repair."

    $previousEnsure = $script:effectiveEnsureBootCampMonitorDriver
    $script:effectiveEnsureBootCampMonitorDriver = $true
    try {
        Invoke-RepairStage -Label "Native APPA Boot Camp-style monitor driver gate" -ScriptBlock { Invoke-BootCampDriverIfRequested } | Out-Null
        Invoke-RepairStage -Label "Boot Camp-style identity settle before native APPA refresh" -ScriptBlock { Wait-BootCampStyleMonitorIdentity -TimeoutSeconds 20 } | Out-Null
        $afterRefreshState = Invoke-RepairStage -Label "Native APPA identity USB4/link refresh" -ScriptBlock { Invoke-LinkRefreshIfNeeded -InitialState $ResolutionState -Force }
    }
    finally {
        $script:effectiveEnsureBootCampMonitorDriver = $previousEnsure
    }
    Write-RepairLog "Resolution state after native APPA identity refresh: $($afterRefreshState.Summary)"

    $afterIdentityState = Invoke-RepairStage -Label "Boot Camp-style identity settle after native APPA refresh" -ScriptBlock { Wait-BootCampStyleMonitorIdentity -TimeoutSeconds 24 }
    $afterExternalOnlyReady = $ExternalOnlyReady
    if ($afterRefreshState.Has5K60Enumerated) {
        $afterExternalOnlyReady = Invoke-RepairStage -Label "External-only topology preflight after native APPA refresh" -ScriptBlock { Test-ExternalOnlyScreenTopologyReady }
        if (-not $afterExternalOnlyReady) {
            Write-RepairLog "External-only topology was not verified after native APPA refresh. Re-running external-only topology repair before HDR/Apple USB gates."
            $afterExternalOnlyReady = Invoke-RepairStage -Label "External-only topology repair after native APPA refresh" -ScriptBlock { Invoke-ExternalOnlyTopologyRepair }
        }
    }

    $afterHdrState = Invoke-RepairStage -Label "HDR preflight after native APPA refresh" -ScriptBlock { Get-HdrRuntimeState }
    Write-RepairLog "HDR state after native APPA identity refresh: $(Format-HdrRuntimeState -State $afterHdrState)"

    if (-not $afterIdentityState.ActiveMs0001 -and ($afterHdrState.HdrSupported -or $afterHdrState.HdrActive)) {
        Write-RepairLog "Native APPA identity refresh reopened the HDR capability path: active display is no longer DISPLAY\\MS_0001 and Windows reports HDR support/active state."
    }
    elseif ($afterIdentityState.ActiveMs0001 -and $afterHdrState.HdrUnsupported) {
        Write-RepairLog "Native APPA identity refresh did not move the active display off DISPLAY\\MS_0001; continuing to Apple USB/HID evidence collection instead of deleting or reinstalling the monitor driver."
    }

    return [pscustomobject]@{
        ResolutionState = $afterRefreshState
        IdentityState = $afterIdentityState
        HdrState = $afterHdrState
        ExternalOnlyReady = [bool]$afterExternalOnlyReady
        Attempted = $true
    }
}

function Invoke-BootCampModeTableRebindIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolutionState,
        [Parameter(Mandatory = $true)]
        [object]$IdentityState
    )

    if ($script:bootCampModeTableRebindAttempted) {
        return $ResolutionState
    }

    if (-not $Apply) {
        return $ResolutionState
    }

    if (-not (Test-IsAdministrator)) {
        return $ResolutionState
    }

    $needsModeTableRebind = [bool](
        $ResolutionState.HasCurrent5K -and
        -not $ResolutionState.Has5K60Enumerated -and
        $IdentityState.ActiveMs0001 -and
        $IdentityState.BootCampStyleReady
    )

    if (-not $needsModeTableRebind) {
        return $ResolutionState
    }

    $script:bootCampModeTableRebindAttempted = $true
    Write-RepairLog "Boot Camp-style MS_0001 identity is ready, but Windows still exposes a degraded non-5K mode table. Rebinding the Boot Camp-style monitor INF once after MS_0001 becomes active, then retraining USB4/monitor enumeration."

    $previousEnsure = $script:effectiveEnsureBootCampMonitorDriver
    $script:effectiveEnsureBootCampMonitorDriver = $true
    Invoke-BootCampDriverIfRequested
    $afterRebindIdentity = Wait-BootCampStyleMonitorIdentity -TimeoutSeconds 20
    Write-RepairLog "Boot Camp-style identity after mode-table rebind: $($afterRebindIdentity.Summary)"

    $afterRebindState = Get-ResolutionLadderState
    Write-RepairLog "Resolution state after Boot Camp-style monitor rebind: $($afterRebindState.Summary)"

    $afterSecondRefreshState = Invoke-LinkRefreshIfNeeded -InitialState $afterRebindState
    Write-RepairLog "Resolution state after post-rebind link refresh: $($afterSecondRefreshState.Summary)"

    $script:effectiveEnsureBootCampMonitorDriver = $previousEnsure
    return $afterSecondRefreshState
}

function Invoke-ModeTableRegistryNudgeIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolutionState,
        [Parameter(Mandatory = $true)]
        [object]$IdentityState
    )

    if ($script:modeTableRegistryNudgeAttempted) {
        return $ResolutionState
    }

    if (-not $Apply) {
        return $ResolutionState
    }

    if (-not (Test-IsAdministrator)) {
        return $ResolutionState
    }

    if (-not (Test-Path -LiteralPath $resolutionLadderScript)) {
        return $ResolutionState
    }

    $needsNudge = [bool](
        $ResolutionState.HasCurrent5K -and
        -not $ResolutionState.Has5K60Enumerated -and
        $ResolutionState.Has5K60Accepted -and
        $IdentityState.ActiveMs0001 -and
        $IdentityState.BootCampStyleReady
    )

    if (-not $needsNudge) {
        return $ResolutionState
    }

    $script:modeTableRegistryNudgeAttempted = $true
    Write-RepairLog "Current display is already 5K60 and CDS_TEST accepts 5120x2880@60, but Windows has not published 5K60 into the mode table. Nudging the current 5K60 mode into the display registry once without using 2K/1080 fallback or DisplaySwitch UI."

    $nudgeResult = Invoke-Tool -Label "5K60 display-mode registry nudge" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $resolutionLadderScript,
        "-ApplyWidth", "5120",
        "-ApplyHeight", "2880",
        "-ApplyRefreshRate", "60"
    )

    if ($nudgeResult.ExitCode -ne 0) {
        Write-RepairLog "5K60 display-mode registry nudge returned exit code $($nudgeResult.ExitCode)."
    }

    Start-Sleep -Seconds 4
    $afterNudgeState = Get-ResolutionLadderState
    Write-RepairLog "Resolution state after 5K60 display-mode registry nudge: $($afterNudgeState.Summary)"
    return $afterNudgeState
}

function Invoke-ExternalOnlyTopologyRepair {
    if (-not (Test-Path -LiteralPath $externalModeRepairScript)) {
        Write-RepairLog "External-only topology repair script is missing: $externalModeRepairScript"
        return $false
    }

    if (-not $Apply) {
        Write-RepairLog "Dry run: Studio Display XDR would be forced to external-only topology before USB4/HDR repair."
        return $true
    }

    $result = Invoke-Tool -Label "external-only topology repair" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $externalModeRepairScript,
        "-Topology", "External",
        "-ExpectedWidth", "5120",
        "-ExpectedHeight", "2880",
        "-ExpectedRefreshRate", "60",
        "-RefreshRate", "60",
        "-SkipSafetyMode",
        "-RequireExternalOnly",
        "-PreserveActiveHdr"
    )

    if ($result.ExitCode -ne 0) {
        Write-RepairLog "External-only topology repair failed with exit code $($result.ExitCode); HDR repair will be skipped to avoid writing color state to the wrong topology."
        return $false
    }

    return $true
}

function Invoke-AppleUsbInterfaceRepair {
    if ($SkipAppleUsbRepair) {
        Write-RepairLog "Apple USB/HID interface repair skipped."
        return [pscustomobject]@{
            ExitCode = 0
            Output = @()
        }
    }

    if (-not (Test-Path -LiteralPath $appleUsbInterfaceRepairScript)) {
        Write-RepairLog "Apple USB/HID interface repair script is missing: $appleUsbInterfaceRepairScript"
        return [pscustomobject]@{
            ExitCode = 1
            Output = @()
        }
    }

    if (-not $Apply) {
        Write-RepairLog "Dry run: failed Apple Studio Display XDR USB/HID interfaces would be restarted before HDR repair."
        return [pscustomobject]@{
            ExitCode = 0
            Output = @()
        }
    }

    $usbArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $appleUsbInterfaceRepairScript,
        "-Apply",
        "-LogPath", $LogPath
    )

    if (-not (Test-IsAdministrator)) {
        $usbArgs += "-Elevate"
    }

    # Parent Apple USB re-enumeration can report pnputil 3010 after child
    # interface restarts; avoid racing failure-state classification.
    return Invoke-Tool -Label "Apple USB/HID interface repair" -Arguments $usbArgs -TimeoutSeconds 210
}

function Invoke-HdrIdentityRollbackRepair {
    if ($SkipHdr) {
        Write-RepairLog "HDR identity rollback skipped because HDR repair is disabled."
        return [pscustomobject]@{
            ExitCode = 0
            Output = @()
        }
    }

    if (-not $AllowHdrIdentityRollback) {
        Write-RepairLog "HDR identity rollback skipped by default. It removes/rebinds the monitor INF and may trigger display re-enumeration; pass -AllowHdrIdentityRollback only for an explicit diagnostic round."
        return [pscustomobject]@{
            ExitCode = 0
            Output = @()
        }
    }

    if (-not (Test-Path -LiteralPath $hdrIdentityRollbackScript)) {
        Write-RepairLog "HDR identity rollback script is missing: $hdrIdentityRollbackScript"
        return [pscustomobject]@{
            ExitCode = 1
            Output = @()
        }
    }

    if (-not $Apply) {
        Write-RepairLog "Dry run: HDR identity rollback would test APPA/Generic PnP rebinding after MS_0001 keeps HighDynamicRangeSupported=False."
        return [pscustomobject]@{
            ExitCode = 0
            Output = @()
        }
    }

    $rollbackArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $hdrIdentityRollbackScript,
        "-Apply",
        "-AllowMonitorDeviceRemoval",
        "-RestoreBootCampOnHdrFailure",
        "-LogPath", $LogPath
    )

    if (-not (Test-IsAdministrator)) {
        $rollbackArgs += "-Elevate"
    }

    return Invoke-Tool -Label "HDR identity rollback" -Arguments $rollbackArgs -TimeoutSeconds 360
}

function Invoke-HdrRepair {
    param([switch]$RestoreWcgFallback)

    if ($SkipHdr) {
        Write-RepairLog "HDR repair skipped."
        return [pscustomobject]@{
            ExitCode = 0
            Output = @()
        }
    }

    if (-not (Test-Path -LiteralPath $hdrStateScript)) {
        Write-RepairLog "HDR state script is missing: $hdrStateScript"
        return [pscustomobject]@{
            ExitCode = 1
            Output = @()
        }
    }

    if (-not $Apply) {
        Write-RepairLog "Dry run: HDR/WCG enable would be attempted after link repair."
        return [pscustomobject]@{
            ExitCode = 0
            Output = @()
        }
    }

    $hdrArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $hdrStateScript,
        "-Enable"
    )

    if ($AllowWcgFallback) {
        $hdrArgs += "-EnableAdvancedColorFallback"
    }
    elseif ($RestoreWcgFallback) {
        Write-RepairLog "HDR gate is still closed; WCG/Advanced Color fallback was not requested because default repair must not downgrade HDR intent. Pass -AllowWcgFallback only for explicit WCG diagnostics."
    }

    return Invoke-Tool -Label "HDR state repair" -Arguments $hdrArgs -TimeoutSeconds 90
}

function Format-HdrRuntimeState {
    param([object]$State)

    if (-not $State -or -not $State.Known) {
        return "HDR state unknown"
    }

    return "active=$($State.HdrActive), supported=$($State.HdrSupported), unsupported=$($State.HdrUnsupported), wcg=$($State.WcgActive)"
}

function Get-RepairSystemBootTime {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return [datetime]$os.LastBootUpTime
    }
    catch {
        return $null
    }
}

function Read-PersistedRepairState {
    param([string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-RepairLog "Could not read persisted repair state '$Path': $($_.Exception.Message)"
        return $null
    }
}

function Test-RepairStateFreshForBoot {
    param(
        [object]$State,
        [AllowNull()][object]$BootTime
    )

    if (-not $State -or -not $BootTime) {
        return $true
    }

    $updatedAt = $null
    foreach ($propertyName in @("UpdatedAt", "Timestamp")) {
        if ($State.PSObject.Properties.Name -contains $propertyName -and $State.$propertyName) {
            $updatedAt = [string]$State.$propertyName
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($updatedAt)) {
        return $true
    }

    try {
        $stateTime = [datetimeoffset]::Parse($updatedAt)
        return ($stateTime.LocalDateTime -ge $BootTime.AddMinutes(-2))
    }
    catch {
        return $true
    }
}

function Test-StateMarksAppleUsbRebootRequired {
    param([object]$State)

    if (-not $State) {
        return $false
    }

    $classification = ""
    $detail = ""
    if ($State.PSObject.Properties.Name -contains "Classification") {
        $classification = [string]$State.Classification
    }
    if ($State.PSObject.Properties.Name -contains "Detail") {
        $detail = [string]$State.Detail
    }

    if (
        ($State.PSObject.Properties.Name -contains "AppleUsbRebootRequired" -and [bool]$State.AppleUsbRebootRequired) -or
        $classification -match 'RebootRequired|AppleUsbRebootRequired' -or
        $detail -match '3010|reboot-required|reboot required'
    ) {
        return $true
    }

    if ($State.PSObject.Properties.Name -contains "Failure") {
        return Test-StateMarksAppleUsbRebootRequired -State $State.Failure
    }

    return $false
}

function Get-RepairStateRepairLogPath {
    param([object]$State)

    if (-not $State) {
        return ""
    }

    if ($State.PSObject.Properties.Name -contains "RepairLog" -and -not [string]::IsNullOrWhiteSpace([string]$State.RepairLog)) {
        return [string]$State.RepairLog
    }

    if ($State.PSObject.Properties.Name -contains "Failure" -and $State.Failure) {
        return Get-RepairStateRepairLogPath -State $State.Failure
    }

    return ""
}

function Test-RepairLogMarksAppleUsbRebootRequired {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        return [bool](
            $text -match 'APPLE_USB_REBOOT_REQUIRED=True' -or
            $text -match 'System reboot is needed to complete configuration operations' -or
            $text -match 'exitCode=3010'
        )
    }
    catch {
        Write-RepairLog "Could not inspect repair log for Apple USB reboot-required evidence: $($_.Exception.Message)"
        return $false
    }
}

function Get-RepairStateUpdatedAt {
    param([object]$State)

    if (-not $State) {
        return [DateTime]::MinValue
    }

    $updatedAt = [DateTime]::MinValue
    if ($State.PSObject.Properties.Name -contains "UpdatedAt") {
        [void][DateTime]::TryParse([string]$State.UpdatedAt, [ref]$updatedAt)
    }

    if ($updatedAt -eq [DateTime]::MinValue -and $State.PSObject.Properties.Name -contains "Failure" -and $State.Failure) {
        return Get-RepairStateUpdatedAt -State $State.Failure
    }

    return $updatedAt
}

function Get-RepairPhysicalReenumerationMarker {
    param([DateTime]$BootTime)

    if (-not (Test-Path -LiteralPath $physicalReenumerationStateFile)) {
        return $null
    }

    try {
        $marker = Get-Content -LiteralPath $physicalReenumerationStateFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $updatedAt = Get-RepairStateUpdatedAt -State $marker
        if ($updatedAt -eq [DateTime]::MinValue) {
            return $null
        }
        if ($BootTime -gt [DateTime]::MinValue -and $updatedAt -lt $BootTime) {
            return $null
        }

        $event = [string]$marker.Event
        if ($event -notmatch 'Disconnected|Reconnected|PowerResume') {
            return $null
        }

        return [pscustomobject]@{
            UpdatedAt = $updatedAt
            Event = $event
            Reason = [string]$marker.Reason
        }
    }
    catch {
        Write-RepairLog "Could not read Studio Display physical re-enumeration marker: $($_.Exception.Message)"
        return $null
    }
}

function Get-PersistedAppleUsbRebootRequiredGate {
    $bootTime = Get-RepairSystemBootTime
    $physicalReenumerationMarker = Get-RepairPhysicalReenumerationMarker -BootTime $bootTime
    $candidates = @(
        [pscustomobject]@{ Path = $hdrGateBlockStateFile; Name = "HDR gate block state"; RequiresGate = $true },
        [pscustomobject]@{ Path = $lastFailureStateFile; Name = "last failure state"; RequiresGate = $false }
    )

    foreach ($candidate in $candidates) {
        $state = Read-PersistedRepairState -Path $candidate.Path
        if (-not $state) {
            continue
        }
        if (-not (Test-RepairStateFreshForBoot -State $state -BootTime $bootTime)) {
            continue
        }
        if ($physicalReenumerationMarker) {
            $stateUpdatedAt = Get-RepairStateUpdatedAt -State $state
            if ($stateUpdatedAt -gt [DateTime]::MinValue -and $physicalReenumerationMarker.UpdatedAt -gt $stateUpdatedAt) {
                Write-RepairLog "Ignoring persisted $($candidate.Name) Apple USB reboot-required gate because a Studio Display physical re-enumeration marker is newer. markerEvent=$($physicalReenumerationMarker.Event) markerUpdatedAt=$($physicalReenumerationMarker.UpdatedAt.ToString('o')) stateUpdatedAt=$($stateUpdatedAt.ToString('o'))"
                continue
            }
        }
        $stateMarksRebootRequired = Test-StateMarksAppleUsbRebootRequired -State $state
        if (-not $stateMarksRebootRequired) {
            $repairLogPath = Get-RepairStateRepairLogPath -State $state
            $stateMarksRebootRequired = Test-RepairLogMarksAppleUsbRebootRequired -Path $repairLogPath
            if ($stateMarksRebootRequired) {
                Write-RepairLog "Persisted $($candidate.Name) did not mark AppleUsbRebootRequired=True, but its repair log contains pnputil 3010/reboot-required evidence. Treating the gate as reboot-required for this pass."
            }
        }

        if (-not $stateMarksRebootRequired) {
            continue
        }

        $requiresPhysicalGate = $true
        if ($candidate.RequiresGate) {
            $requiresPhysicalGate = [bool](
                ($state.PSObject.Properties.Name -contains "RequiresPhysicalReenumeration" -and [bool]$state.RequiresPhysicalReenumeration) -or
                ($state.PSObject.Properties.Name -contains "AppleUsbRebootRequired" -and [bool]$state.AppleUsbRebootRequired) -or
                ($state.PSObject.Properties.Name -contains "Failure" -and (Test-StateMarksAppleUsbRebootRequired -State $state.Failure))
            )
        }

        if (-not $requiresPhysicalGate) {
            continue
        }

        $classification = ""
        if ($state.PSObject.Properties.Name -contains "Classification") {
            $classification = [string]$state.Classification
        }
        elseif ($state.PSObject.Properties.Name -contains "Failure" -and $state.Failure -and $state.Failure.PSObject.Properties.Name -contains "Classification") {
            $classification = [string]$state.Failure.Classification
        }

        $updatedAt = ""
        if ($state.PSObject.Properties.Name -contains "UpdatedAt") {
            $updatedAt = [string]$state.UpdatedAt
        }

        return [pscustomobject]@{
            Active = $true
            Source = $candidate.Name
            Path = $candidate.Path
            UpdatedAt = $updatedAt
            Classification = $classification
        }
    }

    return [pscustomobject]@{
        Active = $false
        Source = ""
        Path = ""
        UpdatedAt = ""
        Classification = ""
    }
}

function Test-AppleUsbRepairRebootRequired {
    param([object]$Result)

    if (-not $Result) {
        return $false
    }

    $outputText = (@($Result.Output) -join "`n")
    return [bool](
        [int]$Result.ExitCode -in @(6, 3010) -or
        $outputText -match 'APPLE_USB_REBOOT_REQUIRED=True|System reboot is needed to complete configuration operations|exitCode=3010'
    )
}

function Write-AppleDisplayUsbProblemSummary {
    try {
        $problemDevices = @(
            Get-PnpDevice -PresentOnly -ErrorAction Stop |
                Where-Object {
                    $_.InstanceId -match 'VID_05AC&PID_1114|VID_05AC&PID_1116' -and
                    ($_.Status -ne "OK" -or ($_.Problem -and $_.Problem -ne "CM_PROB_NONE"))
                } |
                Sort-Object InstanceId
        )

        if (-not $problemDevices) {
            Write-RepairLog "No failed Apple Studio Display USB/HID interfaces were found during HDR gate diagnostics."
            return
        }

        Write-RepairLog "Apple Studio Display USB/HID interfaces still have problems during HDR gate diagnostics:"
        $problemDevices |
            Select-Object Class, FriendlyName, Status, Problem, ConfigManagerErrorCode, InstanceId |
            Format-Table -AutoSize |
            Out-String |
            ForEach-Object { $_.TrimEnd() } |
            Where-Object { $_ } |
            ForEach-Object { Write-RepairLog $_ }
    }
    catch {
        Write-RepairLog "Could not inspect Apple USB/HID problem devices during HDR gate diagnostics: $($_.Exception.Message)"
    }
}

function Get-HdrRuntimeState {
    if (-not (Test-Path -LiteralPath $advancedColorScript)) {
        Write-RepairLog "HDR preflight skipped because advanced color script is missing."
        return [pscustomobject]@{
            Known = $false
            HdrActive = $false
            HdrSupported = $false
            HdrUnsupported = $false
            WcgActive = $false
            RawText = ""
        }
    }

    $result = Invoke-Tool -Label "advanced color preflight" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $advancedColorScript,
        "-SkipDxDiagFallback"
    ) -TimeoutSeconds 60
    $joined = ($result.Output -join "`n")
    return [pscustomobject]@{
        Known = [bool]($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($joined))
        HdrActive = [bool](
            $joined -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR[^\S\r\n]*$' -or
            $joined -match '(?m)^[^\S\r\n]*HighDynamicRangeUserEnabled[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$'
        )
        HdrSupported = [bool]($joined -match '(?m)^[^\S\r\n]*HighDynamicRangeSupported[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$')
        HdrUnsupported = [bool]($joined -match '(?m)^[^\S\r\n]*HighDynamicRangeSupported[^\S\r\n]*:[^\S\r\n]*False[^\S\r\n]*$')
        WcgActive = [bool](
            $joined -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG[^\S\r\n]*$' -or
            $joined -match '(?m)^[^\S\r\n]*WideColorUserEnabled[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$'
        )
        RawText = $joined
    }
}

function Test-BrightnessHidReadyQuiet {
    if (-not (Test-Path -LiteralPath $brightnessHidScript)) {
        return $false
    }

    try {
        $result = Invoke-Tool -Label "brightness HID quiet get" -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $brightnessHidScript,
            "-GetPercent"
        ) -TimeoutSeconds 30
        $output = @($result.Output)
        $joined = ($output -join "`n")
        return [bool]($result.ExitCode -eq 0 -and $joined -match '(?m)^\s*\d+\s*$')
    }
    catch {
        return $false
    }
}

function Invoke-BrightnessValidation {
    if ($SkipBrightness) {
        Write-RepairLog "Brightness validation skipped."
        return $true
    }

    if (-not (Test-Path -LiteralPath $brightnessHidScript)) {
        Write-RepairLog "Brightness HID script is missing: $brightnessHidScript"
        return $false
    }

    $getResult = Invoke-Tool -Label "brightness HID get" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $brightnessHidScript,
        "-GetPercent"
    ) -TimeoutSeconds 30

    if ($getResult.ExitCode -eq 0) {
        return $true
    }

    if (-not $Apply) {
        return $false
    }

    Write-RepairLog "Brightness HID read failed; restarting controller-owned brightness workers instead of reinstalling a standalone bridge."
    Stop-ManagedPid -Label "BrightnessKeyBridge" -PidPath $installedBridgePidFile
    Stop-OrphanInstalledBrightnessWorkers -Label "BrightnessKeyBridge" -ScriptPath $installedBridgeScript
    Stop-ManagedPid -Label "SystemBrightnessMirror" -PidPath $installedMirrorPidFile
    Stop-OrphanInstalledBrightnessWorkers -Label "SystemBrightnessMirror" -ScriptPath $installedMirrorScript
    [void](Start-InstalledMirrorService)
    [void](Start-InstalledBrightnessBridge)
    Start-Sleep -Seconds 1

    $retryResult = Invoke-Tool -Label "brightness HID get after worker restart" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $brightnessHidScript,
        "-GetPercent"
    ) -TimeoutSeconds 30

    return [bool]($retryResult.ExitCode -eq 0)
}

function Invoke-AdvancedColorValidation {
    if (-not (Test-Path -LiteralPath $advancedColorScript)) {
        return
    }

    Invoke-Tool -Label "advanced color validation" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $advancedColorScript,
        "-SkipDxDiagFallback"
    ) -TimeoutSeconds 75 | Out-Null
}

Write-RepairLog "Studio Display integrated repair started. Apply=$Apply Elevated=$(Test-IsAdministrator)"

if (($Apply -or $Elevate) -and -not (Test-IsAdministrator)) {
    try {
        Start-ElevatedSelf
        Write-RepairLog "Elevated integrated repair was launched. Log will continue at: $LogPath"
        exit 0
    }
    catch {
        Write-RepairLog "Could not launch elevated integrated repair: $($_.Exception.Message)"
        exit 1
    }
}

$exitCode = 0
$brightnessState = $null
$shouldValidateBrightness = $false
$hdrRepairFailed = $false
$brightnessValidationFailed = $false
$appleUsbRepairRequiresReboot = $false

try {
    $initialState = Invoke-RepairStage -Label "Initial resolution state probe" -ScriptBlock { Get-ResolutionLadderState }
    Write-RepairLog "Initial resolution state: $($initialState.Summary)"

    $bootCampFallbackState = Invoke-RepairStage -Label "Boot Camp-style identity preflight" -ScriptBlock { Get-BootCampStyleMonitorFallbackState }
    Write-RepairLog "Boot Camp-style monitor fallback preflight: $($bootCampFallbackState.Summary)"
    if (-not $script:effectiveEnsureBootCampMonitorDriver -and $bootCampFallbackState.NeedsBootCampRefresh) {
        $script:effectiveEnsureBootCampMonitorDriver = $true
        Write-RepairLog "Boot Camp-style monitor driver refresh enabled automatically because active MS_0001 must use the Boot Camp-style identity before HDR."
    }
    elseif (-not $script:effectiveEnsureBootCampMonitorDriver -and $bootCampFallbackState.ActiveMs0001 -and $bootCampFallbackState.BootCampStyleReady -and -not $initialState.Has5K60Enumerated) {
        $script:bootCampDriverSkippedBecauseIdentityReady = $true
        Write-RepairLog "Boot Camp-style monitor identity is already bound with HDR metadata, but Windows has not published 5K60 into the mode table. Treating this as a link/mode-table problem and going straight to USB4 retraining instead of reinstalling the monitor INF again."
    }
    elseif ($bootCampFallbackState.ActiveMs0001 -and $bootCampFallbackState.BootCampStyleReady) {
        Write-RepairLog "Boot Camp-style monitor identity is already installed and bound; the generic monitor.inf fallback will not be used as an HDR path."
    }

    $brightnessState = Invoke-RepairStage -Label "Suspend brightness services" -ScriptBlock { Suspend-BrightnessServicesForRepair }

    Invoke-RepairStage -Label "Boot Camp-style monitor driver gate" -ScriptBlock { Invoke-BootCampDriverIfRequested } | Out-Null
    $externalOnlyAlreadyReady = [bool]($initialState.HasCurrent5K -and $initialState.Has5K60Enumerated -and (Invoke-RepairStage -Label "External-only topology preflight" -ScriptBlock { Test-ExternalOnlyScreenTopologyReady }))
    if (-not $initialState.Has5K60Enumerated) {
        $externalOnlyReady = $false
        Write-RepairLog "External-only topology repair deferred because 5K60 is not enumerated yet. USB4/link refresh is required first; running topology repair before the mode table is restored only repeats a known unstable-display failure path."
    }
    elseif ($externalOnlyAlreadyReady -and -not $ForceLinkRefresh -and -not $script:effectiveEnsureBootCampMonitorDriver) {
        $externalOnlyReady = $true
        Write-RepairLog "External-only topology and 5K60 are already ready. Skipping external-only topology repair to avoid unnecessary black-screen/display-mode churn."
    }
    else {
        $externalOnlyReady = Invoke-RepairStage -Label "External-only topology repair gate" -ScriptBlock { Invoke-ExternalOnlyTopologyRepair }
    }

    $postRefreshState = Invoke-RepairStage -Label "USB4/link refresh gate" -ScriptBlock { Invoke-LinkRefreshIfNeeded -InitialState $initialState }
    Write-RepairLog "Post-refresh resolution state: $($postRefreshState.Summary)"
    if (-not $postRefreshState.Has5K60Enumerated -and $script:bootCampDriverSkippedBecauseIdentityReady -and -not $script:bootCampDriverSuccessFallbackAttempted) {
        $script:bootCampDriverSuccessFallbackAttempted = $true
        $previousEnsure = $script:effectiveEnsureBootCampMonitorDriver
        $script:effectiveEnsureBootCampMonitorDriver = $true
        Write-RepairLog "Success-first fallback: 5K60 is still missing after the fast USB4 retrain, so the skipped Boot Camp-style monitor INF reinstall will now run before one more link refresh. Speed never overrides the recovery gate."
        try {
            Invoke-RepairStage -Label "Boot Camp-style monitor driver success fallback" -ScriptBlock { Invoke-BootCampDriverIfRequested } | Out-Null
            Invoke-RepairStage -Label "Boot Camp-style identity settle after success fallback" -ScriptBlock { Wait-BootCampStyleMonitorIdentity -TimeoutSeconds 20 } | Out-Null
            $postRefreshState = Invoke-RepairStage -Label "USB4/link refresh after Boot Camp fallback" -ScriptBlock { Invoke-LinkRefreshIfNeeded -InitialState $postRefreshState }
            Write-RepairLog "Post-success-fallback resolution state: $($postRefreshState.Summary)"

            if (-not $postRefreshState.Has5K60Enumerated) {
                $script:bootCampModeTableRebindAttempted = $true
                Write-RepairLog "Boot Camp-style monitor INF and USB4 link refresh have already been retried in the success-first fallback for this transaction. Skipping the duplicate mode-table rebind pass and moving to the settle/validation gate."
            }
        }
        finally {
            $script:effectiveEnsureBootCampMonitorDriver = $previousEnsure
        }
    }

    $bootCampIdentityState = Invoke-RepairStage -Label "Boot Camp-style identity settle" -ScriptBlock { Wait-BootCampStyleMonitorIdentity }
    $postRefreshState = Invoke-RepairStage -Label "Boot Camp-style mode-table rebind gate" -ScriptBlock { Invoke-BootCampModeTableRebindIfNeeded -ResolutionState $postRefreshState -IdentityState $bootCampIdentityState }
    if ($script:bootCampModeTableRebindAttempted) {
        $bootCampIdentityState = Invoke-RepairStage -Label "Boot Camp-style identity settle after rebind" -ScriptBlock { Wait-BootCampStyleMonitorIdentity }
    }
    $postRefreshState = Invoke-RepairStage -Label "5K60 mode-table registry nudge gate" -ScriptBlock { Invoke-ModeTableRegistryNudgeIfNeeded -ResolutionState $postRefreshState -IdentityState $bootCampIdentityState }
    if ($postRefreshState.HasCurrent5K -and -not $postRefreshState.Has5K60Enumerated -and $postRefreshState.Has5K60Accepted) {
        Write-RepairLog "Current display is already 5K60 and CDS_TEST accepts 5K60, but 5K60 is not enumerated in the mode table. Treating this as unstable for HDR/game mode lists; run the elevated USB4/monitor restart path before HDR repair."
    }

    $postRefreshState = Invoke-RepairStage -Label "5K60 mode-table settle wait" -ScriptBlock { Wait-For5K60ModeTableRecovery -ResolutionState $postRefreshState -Reason "Boot Camp-style USB4 refresh" }

    if (-not $externalOnlyReady -and $postRefreshState.Has5K60Enumerated) {
        $postLinkHdrState = Invoke-RepairStage -Label "Post-link HDR active preflight" -ScriptBlock { Get-HdrRuntimeState }
        $postLinkExternalOnlyReady = Invoke-RepairStage -Label "Post-link external-only topology preflight" -ScriptBlock { Test-ExternalOnlyScreenTopologyReady }
        if ($postLinkExternalOnlyReady) {
            $externalOnlyReady = $true
            $hdrText = if ($postLinkHdrState.HdrActive) { "HDR is already active" } else { "HDR still needs repair" }
            Write-RepairLog "5K60 is enumerated after link refresh and external-only topology is already verified; $hdrText. Skipping the second external-only topology repair to avoid unnecessary display churn."
        }
        else {
            Write-RepairLog "5K60 is now enumerated after link refresh. Re-running external-only topology repair before HDR."
            $externalOnlyReady = Invoke-RepairStage -Label "External-only topology repair after link refresh" -ScriptBlock { Invoke-ExternalOnlyTopologyRepair }
        }
    }

    $bootCampIdentityReadyForHdr = [bool](-not $bootCampIdentityState.ActiveMs0001 -or $bootCampIdentityState.BootCampStyleReady)
    $shouldRunHdrRepair = [bool]($externalOnlyReady -and $postRefreshState.Has5K60Enumerated -and $bootCampIdentityReadyForHdr)
    $shouldValidateBrightness = [bool]($postRefreshState.Has5K60Enumerated -or $postRefreshState.HasCurrent5K)

    if ($shouldRunHdrRepair) {
        $hdrPreflightState = Invoke-RepairStage -Label "HDR preflight" -ScriptBlock { Get-HdrRuntimeState }
        Write-RepairLog "HDR preflight: $(Format-HdrRuntimeState -State $hdrPreflightState)"
        $persistedAppleUsbRebootGate = Get-PersistedAppleUsbRebootRequiredGate

        if ($hdrPreflightState.HdrUnsupported) {
            Write-RepairLog "HDR gate is closed even though the Boot Camp-style MS_0001 identity is ready. Trying the known-good native APPA identity refresh path before Apple USB/HID deep repair; Generic/Digital Flat Panel and monitor-INF rollback remain diagnostic-only."
            $nativeIdentityRefresh = Invoke-HdrCapabilityNativeIdentityRefreshIfNeeded -ResolutionState $postRefreshState -IdentityState $bootCampIdentityState -HdrState $hdrPreflightState -ExternalOnlyReady:$externalOnlyReady -PersistedAppleUsbRebootGate $persistedAppleUsbRebootGate
            $postRefreshState = $nativeIdentityRefresh.ResolutionState
            $bootCampIdentityState = $nativeIdentityRefresh.IdentityState
            $hdrPreflightState = $nativeIdentityRefresh.HdrState
            $externalOnlyReady = [bool]$nativeIdentityRefresh.ExternalOnlyReady
            if ($hdrPreflightState.HdrUnsupported) {
                Write-AppleDisplayUsbProblemSummary
            }
        }

        $brightnessHidReadyBeforeRepair = Invoke-RepairStage -Label "Brightness HID preflight" -ScriptBlock { Test-BrightnessHidReadyQuiet }
        $needsAppleUsbRepair = [bool](-not $hdrPreflightState.HdrActive -or -not $brightnessHidReadyBeforeRepair)
        $hdrStateAfterAppleUsbRepair = $hdrPreflightState
        $appleUsbRepairSkipReason = ""

        if (
            $needsAppleUsbRepair -and
            $persistedAppleUsbRebootGate.Active -and
            $postRefreshState.Has5K60Enumerated -and
            $hdrPreflightState.HdrUnsupported -and
            -not $hdrPreflightState.HdrActive
        ) {
            $appleUsbRepairRequiresReboot = $true
            $needsAppleUsbRepair = $false
            $appleUsbRepairSkipReason = "an existing Apple USB reboot-required HDR gate is active"
            Write-RepairLog "Existing Apple USB reboot-required HDR gate is active after 5K60 recovery (source=$($persistedAppleUsbRebootGate.Source), updatedAt=$($persistedAppleUsbRebootGate.UpdatedAt), classification=$($persistedAppleUsbRebootGate.Classification)). Skipping Apple USB/HID interface repair for this pass; Windows must complete USB configuration through reboot, resume, or full Thunderbolt/USB physical re-enumeration."
        }

        if ($needsAppleUsbRepair) {
            $appleUsbRepair = Invoke-RepairStage -Label "Apple USB/HID interface repair gate" -ScriptBlock { Invoke-AppleUsbInterfaceRepair }
            $appleUsbRepairRequiresReboot = Test-AppleUsbRepairRebootRequired -Result $appleUsbRepair
            if ($appleUsbRepair.ExitCode -ne 0) {
                Write-RepairLog "Apple USB/HID interface repair returned exit code $($appleUsbRepair.ExitCode). HDR will still be attempted when needed, but Windows may keep HighDynamicRangeSupported=False until the failed XDR USB control interface is fixed."
            }
            if ($appleUsbRepairRequiresReboot) {
                Write-RepairLog "Apple USB/HID interface repair reported APPLE_USB_REBOOT_REQUIRED. Skipping disruptive HDR identity rollback and SET_HDR_STATE for this pass; retry after reboot, resume, or a full Thunderbolt/USB physical re-enumeration."
            }
            $hdrStateAfterAppleUsbRepair = Invoke-RepairStage -Label "HDR preflight after Apple USB/HID repair" -ScriptBlock { Get-HdrRuntimeState }
            Write-RepairLog "HDR state after Apple USB/HID repair: $(Format-HdrRuntimeState -State $hdrStateAfterAppleUsbRepair)"
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($appleUsbRepairSkipReason)) {
                Write-RepairLog "Apple USB/HID interface repair skipped because $appleUsbRepairSkipReason."
            }
            else {
                Write-RepairLog "Apple USB/HID interface repair skipped because HDR is already active and brightness HID is readable."
            }
        }

        if ($hdrStateAfterAppleUsbRepair.HdrUnsupported -and -not $hdrStateAfterAppleUsbRepair.HdrActive) {
            if ($appleUsbRepairRequiresReboot) {
                Write-RepairLog "HDR gate is still closed, but Apple USB parent reconfiguration is reboot-required. HDR identity rollback is intentionally skipped because monitor-INF churn cannot reopen HighDynamicRangeSupported=False while USB configuration is pending."
            }
            elseif (-not $AllowHdrIdentityRollback) {
                Write-RepairLog "HDR gate is still closed after Apple USB/HID repair. Skipping HDR identity rollback by default because it removes/reinstalls the Boot Camp-style monitor INF and can disturb stable 5K60/brightness. Pass -AllowHdrIdentityRollback for an explicit diagnostic round."
            }
            else {
                Write-RepairLog "HDR gate is still closed after Apple USB/HID repair. Running guarded HDR identity rollback once: test APPA/Generic PnP HDR-capable identity, then restore Boot Camp-style 5K60 fallback automatically if HDR does not open."
                $identityRollback = Invoke-RepairStage -Label "HDR identity rollback gate" -ScriptBlock { Invoke-HdrIdentityRollbackRepair }
                if ($identityRollback.ExitCode -ne 0) {
                    Write-RepairLog "HDR identity rollback returned exit code $($identityRollback.ExitCode). Continuing to final validation; success still requires ActiveColorMode=HDR."
                }

                $hdrStateAfterAppleUsbRepair = Invoke-RepairStage -Label "HDR preflight after identity rollback" -ScriptBlock { Get-HdrRuntimeState }
                Write-RepairLog "HDR state after identity rollback: $(Format-HdrRuntimeState -State $hdrStateAfterAppleUsbRepair)"
                $postIdentityResolutionState = Invoke-RepairStage -Label "Resolution probe after identity rollback" -ScriptBlock { Get-ResolutionLadderState }
                Write-RepairLog "Resolution state after identity rollback: $($postIdentityResolutionState.Summary)"
                if ($postIdentityResolutionState.HasCurrent5K -or $postIdentityResolutionState.Has5K60Enumerated) {
                    $postRefreshState = $postIdentityResolutionState
                }
            }
        }

        if ($hdrStateAfterAppleUsbRepair.HdrActive) {
            Write-RepairLog "HDR state repair skipped because HDR is already active."
        }
        elseif ($hdrStateAfterAppleUsbRepair.HdrUnsupported) {
            $hdrRepairFailed = $true
            if ($appleUsbRepairRequiresReboot) {
                Write-RepairLog "HDR state repair skipped because Windows still reports HighDynamicRangeSupported=False and Apple USB repair is reboot-required. SET_HDR_STATE cannot open this capability gate until Windows completes USB device configuration."
            }
            else {
                Write-RepairLog "HDR state repair skipped because Windows still reports HighDynamicRangeSupported=False after Apple USB/HID repair. SET_HDR_STATE cannot open this capability gate; final validation will keep exit code non-zero without spending another packet/diagnostic cycle."
            }
        }
        else {
            $hdrRepair = Invoke-RepairStage -Label "HDR state repair gate" -ScriptBlock { Invoke-HdrRepair -RestoreWcgFallback:([bool]$hdrStateAfterAppleUsbRepair.HdrUnsupported) }
            if ($hdrRepair.ExitCode -ne 0) {
                $hdrRepairFailed = $true
                Write-RepairLog "HDR state repair did not reach HDR mode. Exit code $($hdrRepair.ExitCode). If the log shows HighDynamicRangeSupported=False, this is the Windows/driver capability gate and not a brightness-service conflict."
            }
        }
    }
    elseif (-not $externalOnlyReady) {
        Write-RepairLog "HDR repair skipped because external-only topology was not verified."
    }
    elseif (-not $bootCampIdentityReadyForHdr) {
        Write-RepairLog "HDR repair skipped because active DISPLAY\\MS_0001 has not settled on the Boot Camp-style monitor identity. Avoiding the faster generic fallback path that cannot open the HDR gate."
    }
    else {
        Write-RepairLog "HDR repair skipped because Studio Display 5K60 is not enumerated in the mode table. Avoiding WCG-only fallback and waiting for elevated USB4/monitor re-enumeration."
    }

    if ($shouldValidateBrightness) {
        Invoke-AdvancedColorValidation
    }
    else {
        Write-RepairLog "Advanced color validation skipped because no Studio Display 5K target is currently active or enumerated."
    }
}
catch {
    $exitCode = 1
    Write-RepairLog "Integrated repair hit a terminating error: $($_.Exception.Message)"
}
finally {
    try {
        Invoke-RepairStage -Label "Resume brightness services" -ScriptBlock { Resume-BrightnessServicesAfterRepair -State $brightnessState } | Out-Null
    }
    catch {
        Write-RepairLog "Brightness service resume failed: $($_.Exception.Message)"
    }

    try {
        if ($shouldValidateBrightness) {
            $brightnessValidationOk = Invoke-RepairStage -Label "Brightness HID final validation" -ScriptBlock { Invoke-BrightnessValidation }
            if (-not $brightnessValidationOk) {
                $brightnessValidationFailed = $true
            }
        }
        else {
            Write-RepairLog "Brightness validation skipped because no Studio Display 5K target is currently active or enumerated."
        }
    }
    catch {
        Write-RepairLog "Brightness validation failed: $($_.Exception.Message)"
    }
}

$finalState = Invoke-RepairStage -Label "Final resolution state probe" -ScriptBlock { Get-ResolutionLadderState }
Write-RepairLog "Final resolution state: $($finalState.Summary)"

if ($exitCode -eq 0) {
    $finalHdrState = $null
    if (-not $SkipHdr) {
        $finalHdrState = Invoke-RepairStage -Label "Final HDR state probe" -ScriptBlock { Get-HdrRuntimeState }
        Write-RepairLog "Final HDR state: $(Format-HdrRuntimeState -State $finalHdrState)"
    }

    if (-not $finalState.Has5K60) {
        Write-RepairLog "Integrated repair finished, but 5K60 is still not enumerated. Check Thunderbolt/USB4 cable, port routing, and graphics/USB4 drivers."
        $exitCode = 2
    }
    elseif (-not $SkipHdr -and (-not $finalHdrState -or -not $finalHdrState.Known -or -not $finalHdrState.HdrActive)) {
        if ($finalHdrState -and $finalHdrState.HdrUnsupported) {
            Write-RepairLog "Integrated repair finished with 5K60 enumerated, but HDR is still blocked by Windows/driver capability state. Keeping WCG/brightness working, but refusing exit code 0 until HighDynamicRangeSupported=True and ActiveColorMode=HDR."
        }
        else {
            Write-RepairLog "Integrated repair finished with 5K60 enumerated, but final HDR verification did not show ActiveColorMode=HDR. Refusing exit code 0 so automation keeps HDR pending."
        }
        $exitCode = 3
    }
    elseif (-not $SkipBrightness -and $shouldValidateBrightness -and $brightnessValidationFailed) {
        Write-RepairLog "Integrated repair finished with display state ready, but Studio Display HID brightness validation failed. Refusing exit code 0 so the controller can keep brightness repair pending."
        $exitCode = 5
    }
    else {
        $successDetail = if ($SkipHdr) { "5K60 enumerated" } else { "5K60 enumerated and HDR active" }
        Write-RepairLog "Integrated repair finished successfully with $successDetail. Log: $LogPath"
    }
}
else {
    Write-RepairLog "Integrated repair is exiting with prior failure code $exitCode. Final state was still recorded for diagnostics, but it will not be converted to success."
}

Write-RepairTimingSummary -FinalExitCode $exitCode
exit $exitCode
