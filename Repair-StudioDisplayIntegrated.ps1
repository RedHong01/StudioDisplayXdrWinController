[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Elevate,
    [switch]$ForceLinkRefresh,
    [switch]$RestartAppleUsb4Router,
    [switch]$EnsureBootCampMonitorDriver,
    [switch]$AllowWcgFallback,
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
$hdrStateScript = Join-Path $scriptRoot "Set-StudioDisplayHdrState.ps1"
$advancedColorScript = Join-Path $scriptRoot "Get-StudioDisplayAdvancedColorState.ps1"
$brightnessHidScript = Join-Path $scriptRoot "StudioDisplayHid.ps1"
$powershellExe = Join-Path $PSHOME "powershell.exe"
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
    $safeLabel = ($Label -replace '[^A-Za-z0-9._-]', '_')
    $captureId = [Guid]::NewGuid().ToString("N")
    $stdoutPath = Join-Path $env:TEMP ("StudioDisplay-{0}-{1}-{2}.out.log" -f $safeLabel, $PID, $captureId)
    $stderrPath = Join-Path $env:TEMP ("StudioDisplay-{0}-{1}-{2}.err.log" -f $safeLabel, $PID, $captureId)
    $output = @()
    $exitCode = 1
    $timedOut = $false

    try {
        $process = Start-Process -FilePath $powershellExe -ArgumentList $Arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
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
            $process.Refresh()
            $exitCode = $process.ExitCode
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

function Invoke-LinkRefreshIfNeeded {
    param([object]$InitialState)

    if ($SkipHdr -and $SkipBrightness -and -not $ForceLinkRefresh) {
        return $InitialState
    }

    $needsRefresh = $ForceLinkRefresh -or $script:effectiveEnsureBootCampMonitorDriver -or -not $InitialState.Has5K60
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

    if ($RestartAppleUsb4Router -or $script:effectiveEnsureBootCampMonitorDriver -or -not $InitialState.Has5K60) {
        $refreshArgs += "-RestartAppleUsb4Router"
    }

    Invoke-Tool -Label "Studio Display XDR link refresh" -Arguments $refreshArgs | Out-Null
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
    ) | Out-Null
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

    return Invoke-Tool -Label "Apple USB/HID interface repair" -Arguments $usbArgs
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

    return Invoke-Tool -Label "HDR state repair" -Arguments $hdrArgs
}

function Format-HdrRuntimeState {
    param([object]$State)

    if (-not $State -or -not $State.Known) {
        return "HDR state unknown"
    }

    return "active=$($State.HdrActive), supported=$($State.HdrSupported), unsupported=$($State.HdrUnsupported), wcg=$($State.WcgActive)"
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
    )
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
        $output = @(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $brightnessHidScript -GetPercent 2>&1)
        $joined = ($output -join "`n")
        return [bool]($LASTEXITCODE -eq 0 -and $joined -match '(?m)^\s*\d+\s*$')
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
    )

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
    )

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
        "-IncludeDxDiag"
    ) | Out-Null
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

try {
    $initialState = Get-ResolutionLadderState
    Write-RepairLog "Initial resolution state: $($initialState.Summary)"

    $bootCampFallbackState = Get-BootCampStyleMonitorFallbackState
    Write-RepairLog "Boot Camp-style monitor fallback preflight: $($bootCampFallbackState.Summary)"
    if (-not $script:effectiveEnsureBootCampMonitorDriver -and $bootCampFallbackState.NeedsBootCampRefresh) {
        $script:effectiveEnsureBootCampMonitorDriver = $true
        Write-RepairLog "Boot Camp-style monitor driver refresh enabled automatically because active MS_0001 must use the Boot Camp-style identity before HDR."
    }
    elseif (-not $script:effectiveEnsureBootCampMonitorDriver -and $bootCampFallbackState.ActiveMs0001 -and $bootCampFallbackState.BootCampStyleReady -and -not $initialState.Has5K60Enumerated) {
        $script:effectiveEnsureBootCampMonitorDriver = $true
        Write-RepairLog "Boot Camp-style monitor driver refresh enabled because active MS_0001 is bound to the Boot Camp-style identity but Windows still has no enumerated 5K60 mode table. Rebuilding the monitor INF transaction before USB4 retraining instead of keeping the fast visible fallback state."
    }
    elseif ($bootCampFallbackState.ActiveMs0001 -and $bootCampFallbackState.BootCampStyleReady) {
        Write-RepairLog "Boot Camp-style monitor identity is already installed and bound; the generic monitor.inf fallback will not be used as an HDR path."
    }

    $brightnessState = Suspend-BrightnessServicesForRepair

    Invoke-BootCampDriverIfRequested
    $externalOnlyAlreadyReady = [bool]($initialState.HasCurrent5K -and $initialState.Has5K60Enumerated -and (Test-ExternalOnlyScreenTopologyReady))
    if ($externalOnlyAlreadyReady -and -not $ForceLinkRefresh -and -not $script:effectiveEnsureBootCampMonitorDriver) {
        $externalOnlyReady = $true
        Write-RepairLog "External-only topology and 5K60 are already ready. Skipping external-only topology repair to avoid unnecessary black-screen/display-mode churn."
    }
    else {
        $externalOnlyReady = Invoke-ExternalOnlyTopologyRepair
    }

    $postRefreshState = Invoke-LinkRefreshIfNeeded -InitialState $initialState
    Write-RepairLog "Post-refresh resolution state: $($postRefreshState.Summary)"
    $bootCampIdentityState = Wait-BootCampStyleMonitorIdentity
    $postRefreshState = Invoke-BootCampModeTableRebindIfNeeded -ResolutionState $postRefreshState -IdentityState $bootCampIdentityState
    if ($script:bootCampModeTableRebindAttempted) {
        $bootCampIdentityState = Wait-BootCampStyleMonitorIdentity
    }
    $postRefreshState = Invoke-ModeTableRegistryNudgeIfNeeded -ResolutionState $postRefreshState -IdentityState $bootCampIdentityState
    if ($postRefreshState.HasCurrent5K -and -not $postRefreshState.Has5K60Enumerated -and $postRefreshState.Has5K60Accepted) {
        Write-RepairLog "Current display is already 5K60 and CDS_TEST accepts 5K60, but 5K60 is not enumerated in the mode table. Treating this as unstable for HDR/game mode lists; run the elevated USB4/monitor restart path before HDR repair."
    }

    if (-not $externalOnlyReady -and $postRefreshState.Has5K60Enumerated) {
        Write-RepairLog "5K60 is now enumerated after link refresh. Re-running external-only topology repair before HDR."
        $externalOnlyReady = Invoke-ExternalOnlyTopologyRepair
    }

    $bootCampIdentityReadyForHdr = [bool](-not $bootCampIdentityState.ActiveMs0001 -or $bootCampIdentityState.BootCampStyleReady)
    $shouldRunHdrRepair = [bool]($externalOnlyReady -and $postRefreshState.Has5K60Enumerated -and $bootCampIdentityReadyForHdr)
    $shouldValidateBrightness = [bool]($postRefreshState.Has5K60Enumerated -or $postRefreshState.HasCurrent5K)

    if ($shouldRunHdrRepair) {
        $hdrPreflightState = Get-HdrRuntimeState
        Write-RepairLog "HDR preflight: $(Format-HdrRuntimeState -State $hdrPreflightState)"

        if ($hdrPreflightState.HdrUnsupported) {
            Write-RepairLog "HDR gate is closed even though the Boot Camp-style MS_0001 identity is ready. Keeping the single Boot Camp-style pipeline and not falling back to Generic/Digital Flat Panel or WCG."
            Write-AppleDisplayUsbProblemSummary
        }

        $brightnessHidReadyBeforeRepair = Test-BrightnessHidReadyQuiet
        $needsAppleUsbRepair = [bool](-not $hdrPreflightState.HdrActive -or -not $brightnessHidReadyBeforeRepair)

        if ($needsAppleUsbRepair) {
            $appleUsbRepair = Invoke-AppleUsbInterfaceRepair
            if ($appleUsbRepair.ExitCode -ne 0) {
                Write-RepairLog "Apple USB/HID interface repair returned exit code $($appleUsbRepair.ExitCode). HDR will still be attempted when needed, but Windows may keep HighDynamicRangeSupported=False until the failed XDR USB control interface is fixed."
            }
        }
        else {
            Write-RepairLog "Apple USB/HID interface repair skipped because HDR is already active and brightness HID is readable."
        }

        if ($hdrPreflightState.HdrActive) {
            Write-RepairLog "HDR state repair skipped because HDR is already active."
        }
        else {
            $hdrRepair = Invoke-HdrRepair -RestoreWcgFallback:([bool]$hdrPreflightState.HdrUnsupported)
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
        Resume-BrightnessServicesAfterRepair -State $brightnessState
    }
    catch {
        Write-RepairLog "Brightness service resume failed: $($_.Exception.Message)"
    }

    try {
        if ($shouldValidateBrightness) {
            $brightnessValidationOk = Invoke-BrightnessValidation
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

$finalState = Get-ResolutionLadderState
Write-RepairLog "Final resolution state: $($finalState.Summary)"

if ($exitCode -eq 0) {
    $finalHdrState = $null
    if (-not $SkipHdr) {
        $finalHdrState = Get-HdrRuntimeState
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

exit $exitCode
