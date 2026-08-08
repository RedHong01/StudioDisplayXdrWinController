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
        [string[]]$Arguments
    )

    Write-RepairLog "Running $Label."
    $output = & $powershellExe @Arguments 2>&1
    foreach ($line in $output) {
        Write-RepairLog "${Label}: $line"
    }

    Write-RepairLog "$Label exit code: $LASTEXITCODE"
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
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

    Start-Process -FilePath $powershellExe -WorkingDirectory $installedManagerRoot -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $installedMirrorScript,
        "-EnableLogging"
    )

    Start-Sleep -Seconds 2
    $running = Test-ManagedPidRunning -PidPath $installedMirrorPidFile
    Write-RepairLog "SystemBrightnessMirror restart result: $running"
    return $running
}

function Start-InstalledBrightnessBridge {
    if (-not (Test-Path -LiteralPath $installedBridgeScript)) {
        Write-RepairLog "Cannot restart BrightnessKeyBridge because script is missing: $installedBridgeScript"
        return $false
    }

    Start-Process -FilePath $powershellExe -WorkingDirectory $installedBrightnessBridgeRoot -WindowStyle Hidden -ArgumentList @(
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
        MirrorWasRunning = Test-ManagedPidRunning -PidPath $installedMirrorPidFile
        BridgeWasRunning = Test-ManagedPidRunning -PidPath $installedBridgePidFile
        Suspended = $false
    }

    Write-RepairLog "Brightness preflight: mirrorRunning=$($state.MirrorWasRunning), bridgeRunning=$($state.BridgeWasRunning)"

    if (-not $Apply) {
        Write-RepairLog "Dry run: brightness services would be paused before display/HDR repair and restored at the end."
        return $state
    }

    if ($state.BridgeWasRunning) {
        Stop-ManagedPid -Label "BrightnessKeyBridge" -PidPath $installedBridgePidFile
        $state.Suspended = $true
    }

    if ($state.MirrorWasRunning) {
        Stop-ManagedPid -Label "SystemBrightnessMirror" -PidPath $installedMirrorPidFile
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
    $has5K60Enumerated = ($joined -match '5120\s+2880\s+60\s+True' -or $joined -match 'Best enumerated mode:\s+5120x2880@60Hz')
    $has5K60Accepted = ($joined -match '5120\s+2880\s+60\s+(True|False)\s+SUCCESS')
    return [pscustomobject]@{
        HasCurrent5K = ($joined -match 'Current mode:\s+5120x2880@')
        Has5K60 = $has5K60Enumerated
        Has5K60Enumerated = $has5K60Enumerated
        Has5K60Accepted = $has5K60Accepted
        Has5K120 = ($joined -match '5120\s+2880\s+120\s+True' -or $joined -match 'Best enumerated mode:\s+5120x2880@120Hz')
        Summary = ($result.Output | Select-String -Pattern 'Current mode:|Best enumerated mode:' | ForEach-Object { $_.Line }) -join '; '
    }
}

function Invoke-LinkRefreshIfNeeded {
    param([object]$InitialState)

    if ($SkipHdr -and $SkipBrightness -and -not $ForceLinkRefresh) {
        return $InitialState
    }

    $needsRefresh = $ForceLinkRefresh -or $EnsureBootCampMonitorDriver -or -not $InitialState.Has5K60
    if (-not $needsRefresh) {
        Write-RepairLog "5K60 is already enumerated. Skipping USB4 link refresh."
        return $InitialState
    }

    if (-not $Apply) {
        if (-not $InitialState.Has5K60) {
            Write-RepairLog "Dry run: 5K60 is missing but -Apply was not passed, so USB4 link refresh was not started."
        }
        elseif ($EnsureBootCampMonitorDriver) {
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

    if ($RestartAppleUsb4Router -or $EnsureBootCampMonitorDriver -or -not $InitialState.Has5K60) {
        $refreshArgs += "-RestartAppleUsb4Router"
    }

    Invoke-Tool -Label "Studio Display XDR link refresh" -Arguments $refreshArgs | Out-Null
    Start-Sleep -Seconds 3
    return Get-ResolutionLadderState
}

function Invoke-BootCampDriverIfRequested {
    if (-not $EnsureBootCampMonitorDriver) {
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

    return Invoke-Tool -Label "HDR state repair" -Arguments $hdrArgs
}

function Invoke-BrightnessValidation {
    if ($SkipBrightness) {
        Write-RepairLog "Brightness validation skipped."
        return
    }

    if (-not (Test-Path -LiteralPath $brightnessHidScript)) {
        Write-RepairLog "Brightness HID script is missing: $brightnessHidScript"
        return
    }

    $getResult = Invoke-Tool -Label "brightness HID get" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $brightnessHidScript,
        "-GetPercent"
    )

    if ($getResult.ExitCode -eq 0) {
        return
    }

    if (-not $Apply) {
        return
    }

    Write-RepairLog "Brightness HID read failed; restarting controller-owned brightness workers instead of reinstalling a standalone bridge."
    [void](Start-InstalledMirrorService)
    [void](Start-InstalledBrightnessBridge)
    Start-Sleep -Seconds 1

    Invoke-Tool -Label "brightness HID get after worker restart" -Arguments @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $brightnessHidScript,
        "-GetPercent"
    ) | Out-Null
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

if ($Elevate -and -not (Test-IsAdministrator)) {
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

try {
    $initialState = Get-ResolutionLadderState
    Write-RepairLog "Initial resolution state: $($initialState.Summary)"

    $brightnessState = Suspend-BrightnessServicesForRepair

    Invoke-BootCampDriverIfRequested
    $externalOnlyReady = Invoke-ExternalOnlyTopologyRepair

    $postRefreshState = Invoke-LinkRefreshIfNeeded -InitialState $initialState
    Write-RepairLog "Post-refresh resolution state: $($postRefreshState.Summary)"
    if ($postRefreshState.HasCurrent5K -and -not $postRefreshState.Has5K60Enumerated -and $postRefreshState.Has5K60Accepted) {
        Write-RepairLog "Current display is already 5K60 and CDS_TEST accepts 5K60, but 5K60 is not enumerated in the mode table. Treating this as unstable for HDR/game mode lists; run the elevated USB4/monitor restart path before HDR repair."
    }

    if (-not $externalOnlyReady -and $postRefreshState.Has5K60Enumerated) {
        Write-RepairLog "5K60 is now enumerated after link refresh. Re-running external-only topology repair before HDR."
        $externalOnlyReady = Invoke-ExternalOnlyTopologyRepair
    }

    $shouldRunHdrRepair = [bool]($externalOnlyReady -and $postRefreshState.Has5K60Enumerated)
    $shouldValidateBrightness = [bool]($postRefreshState.Has5K60Enumerated -or $postRefreshState.HasCurrent5K)

    if ($shouldRunHdrRepair) {
        $appleUsbRepair = Invoke-AppleUsbInterfaceRepair
        if ($appleUsbRepair.ExitCode -ne 0) {
            Write-RepairLog "Apple USB/HID interface repair returned exit code $($appleUsbRepair.ExitCode). HDR will still be attempted, but Windows may keep HighDynamicRangeSupported=False until the failed XDR USB control interface is fixed."
        }

        $hdrRepair = Invoke-HdrRepair
        if ($hdrRepair.ExitCode -ne 0) {
            $hdrRepairFailed = $true
            Write-RepairLog "HDR state repair did not reach HDR mode. Exit code $($hdrRepair.ExitCode). If the log shows HighDynamicRangeSupported=False, this is the Windows/driver capability gate and not a brightness-service conflict."
        }
    }
    elseif (-not $externalOnlyReady) {
        Write-RepairLog "HDR repair skipped because external-only topology was not verified."
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
finally {
    try {
        Resume-BrightnessServicesAfterRepair -State $brightnessState
    }
    catch {
        Write-RepairLog "Brightness service resume failed: $($_.Exception.Message)"
    }

    try {
        if ($shouldValidateBrightness) {
            Invoke-BrightnessValidation
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

if (-not $finalState.Has5K60) {
    Write-RepairLog "Integrated repair finished, but 5K60 is still not enumerated. Check Thunderbolt/USB4 cable, port routing, and graphics/USB4 drivers."
    $exitCode = 2
}
elseif ($hdrRepairFailed -and -not $SkipHdr) {
    Write-RepairLog "Integrated repair finished with 5K60 enumerated, but HDR is still blocked by Windows/driver capability state. Keep WCG/brightness working and inspect the HDR state repair log above for HighDynamicRangeSupported and SET_HDR_STATE details."
    $exitCode = 3
}
else {
    Write-RepairLog "Integrated repair finished successfully with 5K60 enumerated. Log: $LogPath"
}

exit $exitCode
