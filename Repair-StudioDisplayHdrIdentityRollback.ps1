[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Elevate,
    [switch]$AllowMonitorDeviceRemoval,
    [switch]$RollbackOnResolutionLoss = $true,
    [switch]$RestoreBootCampOnHdrFailure,
    [string]$LogPath
)

$ErrorActionPreference = "Continue"

$scriptRoot = $PSScriptRoot
$reportsRoot = Join-Path $scriptRoot "reports"
$resolutionLadderScript = Join-Path $scriptRoot "Test-StudioDisplayResolutionLadder.ps1"
$advancedColorScript = Join-Path $scriptRoot "Get-StudioDisplayAdvancedColorState.ps1"
$hdrStateScript = Join-Path $scriptRoot "Set-StudioDisplayHdrState.ps1"
$bootCampDriverScript = Join-Path $scriptRoot "Install-StudioDisplayBootCampStyleMonitorDriver.ps1"
$linkRefreshScript = Join-Path $scriptRoot "Refresh-StudioDisplayXdrLink.ps1"
$powershellExe = Join-Path $PSHOME "powershell.exe"
$customMonitorOriginalName = "studiodisplayxdrbootcampstylemonitor.inf"

if (-not $LogPath) {
    New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null
    $LogPath = Join-Path $reportsRoot ("StudioDisplayHdrIdentityRollback-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

function Write-RollbackLog {
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

    foreach ($switchName in @("Apply", "AllowMonitorDeviceRemoval", "RollbackOnResolutionLoss", "RestoreBootCampOnHdrFailure")) {
        if ((Get-Variable -Name $switchName -ValueOnly)) {
            $arguments += "-$switchName"
        }
    }

    Write-RollbackLog "Launching elevated HDR identity rollback through UAC. Approve the prompt to let Windows rebind the monitor driver."
    Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
}

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$SuppressOutputLog
    )

    Write-RollbackLog "Running $Label."
    $output = & $FilePath @Arguments 2>&1
    if (-not $SuppressOutputLog) {
        foreach ($line in $output) {
            Write-RollbackLog "${Label}: $line"
        }
    }

    Write-RollbackLog "$Label exit code: $LASTEXITCODE"
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
    }
}

function Invoke-PowerShellTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $toolArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ScriptPath
    ) + $Arguments

    return Invoke-LoggedProcess -Label $Label -FilePath $powershellExe -Arguments $toolArgs
}

function Get-ResolutionState {
    if (-not (Test-Path -LiteralPath $resolutionLadderScript)) {
        return [pscustomobject]@{
            Known = $false
            HasCurrent5K = $false
            Has5K60Enumerated = $false
            Has5K60Accepted = $false
            RawText = "resolution ladder script missing"
        }
    }

    $result = Invoke-PowerShellTool -Label "resolution ladder probe" -ScriptPath $resolutionLadderScript
    $text = ($result.Output -join "`n")
    return [pscustomobject]@{
        Known = [bool]($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($text))
        HasCurrent5K = [bool]($text -match '(?m)^Current mode:[^\S\r\n]+5120x2880@')
        Has5K60Enumerated = [bool](
            $text -match '(?m)^5K 60Hz legacy Studio Display fallback[^\r\n]*[^\S\r\n]+5120[^\S\r\n]+2880[^\S\r\n]+60[^\S\r\n]+True(?:[^\S\r\n]|$)' -or
            $text -match '(?m)^Best enumerated mode:[^\S\r\n]+5120x2880@60Hz[^\S\r\n]*$'
        )
        Has5K60Accepted = [bool]($text -match '(?m)^5K 60Hz legacy Studio Display fallback[^\r\n]*[^\S\r\n]+5120[^\S\r\n]+2880[^\S\r\n]+60[^\S\r\n]+True[^\S\r\n]+True[^\S\r\n]+SUCCESS[^\S\r\n]+0(?:[^\S\r\n]|$)')
        RawText = $text
    }
}

function Get-HdrState {
    if (-not (Test-Path -LiteralPath $advancedColorScript)) {
        return [pscustomobject]@{
            Known = $false
            HdrActive = $false
            HdrSupported = $false
            HdrUnsupported = $false
            WcgActive = $false
            MonitorName = ""
            MonitorId = ""
            RawText = "advanced color script missing"
        }
    }

    $result = Invoke-PowerShellTool -Label "advanced color probe" -ScriptPath $advancedColorScript -Arguments @("-IncludeDxDiag")
    $text = ($result.Output -join "`n")
    return [pscustomobject]@{
        Known = [bool]($result.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($text))
        HdrActive = [bool]($text -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR[^\S\r\n]*$' -or $text -match '(?m)^[^\S\r\n]*HighDynamicRangeUserEnabled[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$')
        HdrSupported = [bool]($text -match '(?m)^[^\S\r\n]*HighDynamicRangeSupported[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$')
        HdrUnsupported = [bool]($text -match '(?m)^[^\S\r\n]*HighDynamicRangeSupported[^\S\r\n]*:[^\S\r\n]*False[^\S\r\n]*$')
        WcgActive = [bool]($text -match '(?m)^[^\S\r\n]*ActiveColorMode[^\S\r\n]*:[^\S\r\n]*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG[^\S\r\n]*$' -or $text -match '(?m)^[^\S\r\n]*WideColorUserEnabled[^\S\r\n]*:[^\S\r\n]*True[^\S\r\n]*$')
        MonitorName = if ($text -match '(?m)^[^\S\r\n]*MonitorName[^\S\r\n]*:[^\S\r\n]*(.*?)[^\S\r\n]*$') { $Matches[1].Trim() } else { "" }
        MonitorId = if ($text -match '(?m)^[^\S\r\n]*MonitorId[^\S\r\n]*:[^\S\r\n]*(.*?)[^\S\r\n]*$') { $Matches[1].Trim() } else { "" }
        RawText = $text
    }
}

function Format-ResolutionState {
    param([object]$State)
    return "known=$($State.Known), current5K=$($State.HasCurrent5K), 5K60Enumerated=$($State.Has5K60Enumerated), 5K60Accepted=$($State.Has5K60Accepted)"
}

function Format-HdrState {
    param([object]$State)
    return "known=$($State.Known), hdrSupported=$($State.HdrSupported), hdrActive=$($State.HdrActive), wcg=$($State.WcgActive), monitorId='$($State.MonitorId)', monitorName='$($State.MonitorName)'"
}

function Test-StableResolutionState {
    param(
        [object]$ResolutionState,
        [object]$HdrState
    )

    return [bool](
        $ResolutionState.Known -and
        $ResolutionState.HasCurrent5K -and
        $ResolutionState.Has5K60Enumerated -and
        ($ResolutionState.Has5K60Accepted -or ($HdrState -and $HdrState.HdrActive))
    )
}

function Get-CustomMonitorDriverPackages {
    $result = Invoke-LoggedProcess -Label "pnputil enum drivers" -FilePath "pnputil.exe" -Arguments @("/enum-drivers") -SuppressOutputLog
    $packages = New-Object System.Collections.Generic.List[object]
    $current = @{}

    foreach ($line in $result.Output) {
        $text = [string]$line
        if ($text -match '^\s*(Published Name|发布名称)\s*:\s*(.+?)\s*$') {
            if ($current.Count -gt 0) {
                $packages.Add([pscustomobject]$current) | Out-Null
            }
            $current = @{
                PublishedName = $Matches[2].Trim()
            }
            continue
        }

        if ($text -match '^\s*(Original Name|原始名称)\s*:\s*(.+?)\s*$') {
            $current.OriginalName = $Matches[2].Trim()
            continue
        }

        if ($text -match '^\s*(Provider Name|提供程序名称)\s*:\s*(.+?)\s*$') {
            $current.ProviderName = $Matches[2].Trim()
            continue
        }

        if ($text -match '^\s*(Class Name|类名)\s*:\s*(.+?)\s*$') {
            $current.ClassName = $Matches[2].Trim()
            continue
        }

        if ($text -match '^\s*(Driver Version|驱动程序版本)\s*:\s*(.+?)\s*$') {
            $current.DriverVersion = $Matches[2].Trim()
            continue
        }
    }

    if ($current.Count -gt 0) {
        $packages.Add([pscustomobject]$current) | Out-Null
    }

    return @(
        $packages |
            Where-Object {
                $_.OriginalName -ieq $customMonitorOriginalName -or
                ($_.ProviderName -eq "StudioDIsplayWithWindows" -and $_.ClassName -eq "Monitor")
            } |
            Sort-Object PublishedName -Descending
    )
}

function Restart-MsFallbackMonitor {
    try {
        $targets = @(
            Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction Stop |
                Where-Object { $_.InstanceId -match '^DISPLAY\\MS_0001\\' }
        )
    }
    catch {
        Write-RollbackLog "Could not enumerate present MS_0001 monitor devices for restart: $($_.Exception.Message)"
        return
    }

    if (-not $targets) {
        Write-RollbackLog "No present DISPLAY\\MS_0001 monitor device was found to restart."
        return
    }

    foreach ($target in $targets) {
        Invoke-LoggedProcess -Label "pnputil restart $($target.InstanceId)" -FilePath "pnputil.exe" -Arguments @("/restart-device", $target.InstanceId) | Out-Null
    }
}

function Remove-MsFallbackMonitorDevice {
    if (-not $AllowMonitorDeviceRemoval) {
        Write-RollbackLog "Skipping monitor device removal. Pass -AllowMonitorDeviceRemoval for the stronger MS_0001 remove/rescan identity test."
        return
    }

    try {
        $targets = @(
            Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction Stop |
                Where-Object { $_.InstanceId -match '^DISPLAY\\MS_0001\\' }
        )
    }
    catch {
        Write-RollbackLog "Could not enumerate present MS_0001 monitor devices for removal: $($_.Exception.Message)"
        return
    }

    if (-not $targets) {
        Write-RollbackLog "No present DISPLAY\\MS_0001 monitor device was found to remove."
        return
    }

    foreach ($target in $targets) {
        Write-RollbackLog "Removing fallback monitor device instance for full re-enumeration: $($target.InstanceId)"
        Invoke-LoggedProcess -Label "pnputil remove $($target.InstanceId)" -FilePath "pnputil.exe" -Arguments @(
            "/remove-device",
            $target.InstanceId
        ) | Out-Null
    }
}

function Invoke-PnpRescanAndSettle {
    Invoke-LoggedProcess -Label "pnputil scan devices" -FilePath "pnputil.exe" -Arguments @("/scan-devices") | Out-Null
    Start-Sleep -Seconds 8
}

function Remove-CustomMonitorDriverPackages {
    param([object[]]$Packages)

    foreach ($package in $Packages) {
        if ([string]::IsNullOrWhiteSpace($package.PublishedName)) {
            continue
        }

        Invoke-LoggedProcess -Label "delete custom monitor driver $($package.PublishedName)" -FilePath "pnputil.exe" -Arguments @(
            "/delete-driver",
            $package.PublishedName,
            "/uninstall",
            "/force"
        ) | Out-Null
    }
}

function Restore-BootCampStyleFallback {
    if (-not (Test-Path -LiteralPath $bootCampDriverScript)) {
        Write-RollbackLog "Cannot restore Boot Camp-style fallback because the installer script is missing: $bootCampDriverScript"
        return $false
    }

    $driverResult = Invoke-PowerShellTool -Label "restore Boot Camp-style monitor fallback" -ScriptPath $bootCampDriverScript -Arguments @(
        "-Apply",
        "-EnableHdrMetadata",
        "-SignWithLocalCertificate",
        "-TrustLocalSigningCertificate"
    )

    if ($driverResult.ExitCode -ne 0) {
        Write-RollbackLog "Boot Camp-style fallback reinstall returned exit code $($driverResult.ExitCode)."
    }

    if (Test-Path -LiteralPath $linkRefreshScript) {
        Invoke-PowerShellTool -Label "post-rollback USB4 link refresh" -ScriptPath $linkRefreshScript -Arguments @(
            "-RestartFallbackMonitor",
            "-RestartAppleUsb4Router"
        ) | Out-Null
    }
    else {
        Invoke-PnpRescanAndSettle
    }

    $restoredResolution = Get-ResolutionState
    Write-RollbackLog "Resolution after Boot Camp-style fallback restore: $(Format-ResolutionState -State $restoredResolution)"
    return [bool]($restoredResolution.Known -and $restoredResolution.HasCurrent5K -and $restoredResolution.Has5K60Enumerated -and $restoredResolution.Has5K60Accepted)
}

function Restore-WcgFallbackIfNeeded {
    param([object]$HdrState)

    if ($HdrState -and ($HdrState.HdrActive -or $HdrState.WcgActive)) {
        return $HdrState
    }

    if (-not (Test-Path -LiteralPath $hdrStateScript)) {
        Write-RollbackLog "Cannot restore WCG fallback because HDR state script is missing: $hdrStateScript"
        return $HdrState
    }

    Write-RollbackLog "HDR identity rollback did not reach HDR and WCG is not active; restoring WCG/Advanced Color fallback so the display is not left in SDR/8bpc."
    Invoke-PowerShellTool -Label "restore WCG fallback after identity rollback" -ScriptPath $hdrStateScript -Arguments @(
        "-Enable",
        "-EnableAdvancedColorFallback"
    ) | Out-Null

    Start-Sleep -Seconds 2
    $updatedHdr = Get-HdrState
    Write-RollbackLog "HDR after WCG fallback restore: $(Format-HdrState -State $updatedHdr)"
    return $updatedHdr
}

Write-RollbackLog "Studio Display HDR identity rollback started. Apply=$Apply Elevated=$(Test-IsAdministrator) AllowMonitorDeviceRemoval=$AllowMonitorDeviceRemoval RollbackOnResolutionLoss=$RollbackOnResolutionLoss RestoreBootCampOnHdrFailure=$RestoreBootCampOnHdrFailure"

if ($Apply -and -not (Test-IsAdministrator)) {
    if ($Elevate) {
        try {
            Start-ElevatedSelf
            Write-RollbackLog "Elevated HDR identity rollback was launched. Log will continue at: $LogPath"
            exit 0
        }
        catch {
            Write-RollbackLog "Could not launch elevated HDR identity rollback: $($_.Exception.Message)"
            exit 1
        }
    }

    Write-RollbackLog "Apply requires administrator rights. Re-run with -Apply -Elevate or from an elevated PowerShell."
    exit 1
}

$initialResolution = Get-ResolutionState
$initialHdr = Get-HdrState
Write-RollbackLog "Initial resolution: $(Format-ResolutionState -State $initialResolution)"
Write-RollbackLog "Initial HDR: $(Format-HdrState -State $initialHdr)"

$packages = @(Get-CustomMonitorDriverPackages)
if (-not $packages) {
    Write-RollbackLog "No StudioDIsplayWithWindows Boot Camp-style monitor driver packages are currently staged. Windows may already be using the generic monitor path."
}
else {
    Write-RollbackLog "Custom monitor driver packages staged: $(@($packages | ForEach-Object { $_.PublishedName }) -join ', ')"
}

if (-not $Apply) {
    Write-RollbackLog "Dry run only. Re-run with -Apply -Elevate to remove the custom monitor INF packages and test Windows Generic PnP HDR identity."
    exit 0
}

if ($packages) {
    Remove-CustomMonitorDriverPackages -Packages $packages
}

Restart-MsFallbackMonitor
Invoke-PnpRescanAndSettle

$postResolution = Get-ResolutionState
$postHdr = Get-HdrState
Write-RollbackLog "Post-identity-rollback resolution: $(Format-ResolutionState -State $postResolution)"
Write-RollbackLog "Post-identity-rollback HDR: $(Format-HdrState -State $postHdr)"

if ((Test-StableResolutionState -ResolutionState $postResolution -HdrState $postHdr) -and -not $postHdr.HdrActive -and $postHdr.HdrUnsupported) {
    Write-RollbackLog "Monitor-INF rollback preserved 5K60 but HDR gate is still closed."
    if ($AllowMonitorDeviceRemoval) {
        Write-RollbackLog "Trying stronger identity rollback by removing the present MS_0001 monitor instance and rescanning."
        Remove-MsFallbackMonitorDevice
        Invoke-PnpRescanAndSettle
        $postResolution = Get-ResolutionState
        $postHdr = Get-HdrState
        Write-RollbackLog "Post-monitor-device-removal resolution: $(Format-ResolutionState -State $postResolution)"
        Write-RollbackLog "Post-monitor-device-removal HDR: $(Format-HdrState -State $postHdr)"
    }
    else {
        Write-RollbackLog "Stronger MS_0001 remove/rescan stage was not requested, so the tool will not disturb the active monitor instance further."
    }
}

if (-not (Test-StableResolutionState -ResolutionState $postResolution -HdrState $postHdr)) {
    Write-RollbackLog "HDR identity rollback lost the stable 5K60 mode table/current 5K mode, or 5K60 is enumerated but rejected by CDS_TEST while HDR is not active."
    if ($RollbackOnResolutionLoss) {
        Write-RollbackLog "Rolling back to the existing Boot Camp-style 5K60 fallback."
        if (Restore-BootCampStyleFallback) {
            Write-RollbackLog "Rollback restored 5K60. HDR identity rollback did not reach code=0."
            exit 2
        }

        Write-RollbackLog "Rollback failed to restore 5K60. Manual Thunderbolt/USB4 intervention is required."
        exit 4
    }

    exit 2
}

if ($postHdr.HdrSupported -and -not $postHdr.HdrActive -and (Test-Path -LiteralPath $hdrStateScript)) {
    Invoke-PowerShellTool -Label "enable HDR after identity rollback" -ScriptPath $hdrStateScript -Arguments @("-Enable") | Out-Null
    Start-Sleep -Seconds 3
    $postHdr = Get-HdrState
    Write-RollbackLog "HDR after enable attempt: $(Format-HdrState -State $postHdr)"
}

if ($postHdr.HdrActive) {
    Write-RollbackLog "HDR identity rollback succeeded: 5K60 is stable and ActiveColorMode=HDR."
    exit 0
}

if ($RestoreBootCampOnHdrFailure) {
    Write-RollbackLog "HDR identity rollback did not reopen the HDR gate. Restoring the Boot Camp-style monitor fallback before returning failure so later hot-plug cycles keep the known 5K60 fallback available."
    if (Restore-BootCampStyleFallback) {
        Write-RollbackLog "Boot Camp-style fallback restored after HDR identity rollback failure."
        exit 3
    }

    Write-RollbackLog "Boot Camp-style fallback restore failed after HDR identity rollback failure."
    exit 4
}

$postHdr = Restore-WcgFallbackIfNeeded -HdrState $postHdr
Write-RollbackLog "HDR identity rollback preserved 5K60 but did not reopen the HDR gate. Leaving the current identity in place because resolution did not regress."
exit 3
