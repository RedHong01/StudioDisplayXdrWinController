[CmdletBinding()]
param(
    [ValidateSet("External", "Extend", "Clone", "Internal")]
    [string]$Topology = "External",
    [Nullable[int]]$Width,
    [Nullable[int]]$Height,
    [Nullable[int]]$RefreshRate,
    [ValidateSet("Auto", "StudioDisplay", "StudioDisplayXDR", "ProDisplayXDR", "Generic")]
    [string]$AppleDisplayProfile = "Auto",
    [Nullable[int]]$ExpectedWidth,
    [Nullable[int]]$ExpectedHeight,
    [Nullable[int]]$ExpectedRefreshRate,
    [int]$MinimumNativeWidth = 0,
    [int]$MinimumNativeHeight = 0,
    [int]$SafeWidth = 2560,
    [int]$SafeHeight = 1440,
    [int]$SafeRefreshRate = 60,
    [int]$TopologySettleDelayMs = 1500,
    [int]$PreferredModeDelayMs = 2000,
    [switch]$SkipSafetyMode,
    [bool]$RescanWhenNativeMissing = $true,
    [switch]$DisableNativeRefreshFallback,
    [switch]$AllowCdsTestOnlyNativeMode,
    [switch]$AllowLowResolutionFallback,
    [switch]$AllowDisplaySwitchFallback,
    [switch]$RequireExternalOnly,
    [switch]$PreserveActiveHdr,
    [int]$ExternalOnlyVerifyRetries = 6,
    [int]$ExternalOnlyVerifyDelayMs = 500
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

$advancedColorProbeScript = Join-Path $PSScriptRoot "Get-StudioDisplayAdvancedColorState.ps1"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class StudioDisplaySetDisplayConfig {
    public const UInt32 SDC_TOPOLOGY_INTERNAL = 0x00000001;
    public const UInt32 SDC_TOPOLOGY_CLONE = 0x00000002;
    public const UInt32 SDC_TOPOLOGY_EXTEND = 0x00000004;
    public const UInt32 SDC_TOPOLOGY_EXTERNAL = 0x00000008;
    public const UInt32 SDC_APPLY = 0x00000080;
    public const UInt32 SDC_ALLOW_CHANGES = 0x00000400;
    public const UInt32 SDC_PATH_PERSIST_IF_REQUIRED = 0x00000800;

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetDisplayConfig(
        UInt32 numPathArrayElements,
        IntPtr pathArray,
        UInt32 numModeInfoArrayElements,
        IntPtr modeInfoArray,
        UInt32 flags
    );
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct StudioDisplayDevMode {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string dmDeviceName;
    public short dmSpecVersion;
    public short dmDriverVersion;
    public short dmSize;
    public short dmDriverExtra;
    public int dmFields;
    public int dmPositionX;
    public int dmPositionY;
    public int dmDisplayOrientation;
    public int dmDisplayFixedOutput;
    public short dmColor;
    public short dmDuplex;
    public short dmYResolution;
    public short dmTTOption;
    public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
    public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel;
    public int dmPelsWidth;
    public int dmPelsHeight;
    public int dmDisplayFlags;
    public int dmDisplayFrequency;
    public int dmICMMethod;
    public int dmICMIntent;
    public int dmMediaType;
    public int dmDitherType;
    public int dmReserved1;
    public int dmReserved2;
    public int dmPanningWidth;
    public int dmPanningHeight;
}

public static class StudioDisplayChangeDisplaySettings {
    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int DM_PELSWIDTH = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;
    public const int DM_DISPLAYFREQUENCY = 0x00400000;
    public const int CDS_UPDATEREGISTRY = 0x00000001;
    public const int CDS_TEST = 0x00000002;
    public const int DISP_CHANGE_SUCCESSFUL = 0;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref StudioDisplayDevMode devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(
        string deviceName,
        ref StudioDisplayDevMode devMode,
        IntPtr hwnd,
        int flags,
        IntPtr lParam
    );
}
"@

function Invoke-PrimaryDisplayModeRepair {
    param(
        [Nullable[int]]$TargetWidth,
        [Nullable[int]]$TargetHeight,
        [Nullable[int]]$TargetRefreshRate
    )

    $deviceName = [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
    $targetMode = Resolve-TargetDisplayMode -DeviceName $deviceName -RequestedWidth $TargetWidth -RequestedHeight $TargetHeight -RequestedRefreshRate $TargetRefreshRate
    $devMode = New-Object StudioDisplayDevMode
    $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayDevMode])

    if (-not [StudioDisplayChangeDisplaySettings]::EnumDisplaySettings(
            $deviceName,
            [StudioDisplayChangeDisplaySettings]::ENUM_CURRENT_SETTINGS,
            [ref]$devMode
        )) {
        throw "EnumDisplaySettings failed for $deviceName."
    }

    $devMode.dmPelsWidth = $targetMode.Width
    $devMode.dmPelsHeight = $targetMode.Height
    $devMode.dmDisplayFrequency = $targetMode.RefreshRate
    $devMode.dmFields = (
        [StudioDisplayChangeDisplaySettings]::DM_PELSWIDTH -bor
        [StudioDisplayChangeDisplaySettings]::DM_PELSHEIGHT -bor
        [StudioDisplayChangeDisplaySettings]::DM_DISPLAYFREQUENCY
    )

    $testResult = [StudioDisplayChangeDisplaySettings]::ChangeDisplaySettingsEx(
        $deviceName,
        [ref]$devMode,
        [IntPtr]::Zero,
        [StudioDisplayChangeDisplaySettings]::CDS_TEST,
        [IntPtr]::Zero
    )

    if ($testResult -ne [StudioDisplayChangeDisplaySettings]::DISP_CHANGE_SUCCESSFUL) {
        throw "Display mode test failed for $deviceName with code $testResult."
    }

    $applyResult = [StudioDisplayChangeDisplaySettings]::ChangeDisplaySettingsEx(
        $deviceName,
        [ref]$devMode,
        [IntPtr]::Zero,
        [StudioDisplayChangeDisplaySettings]::CDS_UPDATEREGISTRY,
        [IntPtr]::Zero
    )

    if ($applyResult -ne [StudioDisplayChangeDisplaySettings]::DISP_CHANGE_SUCCESSFUL) {
        throw "Display mode apply failed for $deviceName with code $applyResult."
    }

    Write-Host "Applied primary display mode silently: $deviceName $($targetMode.Width)x$($targetMode.Height)@$($targetMode.RefreshRate)Hz."
}

function Get-CurrentDisplayMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName
    )

    $devMode = New-Object StudioDisplayDevMode
    $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayDevMode])

    if (-not [StudioDisplayChangeDisplaySettings]::EnumDisplaySettings(
            $DeviceName,
            [StudioDisplayChangeDisplaySettings]::ENUM_CURRENT_SETTINGS,
            [ref]$devMode
        )) {
        throw "EnumDisplaySettings failed for $DeviceName."
    }

    return [pscustomobject]@{
        Width = $devMode.dmPelsWidth
        Height = $devMode.dmPelsHeight
        RefreshRate = $devMode.dmDisplayFrequency
        PixelCount = $devMode.dmPelsWidth * $devMode.dmPelsHeight
    }
}

function Get-AvailableDisplayModes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName
    )

    $modes = New-Object System.Collections.Generic.List[object]
    $modeIndex = 0

    while ($true) {
        $devMode = New-Object StudioDisplayDevMode
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayDevMode])

        if (-not [StudioDisplayChangeDisplaySettings]::EnumDisplaySettings($DeviceName, $modeIndex, [ref]$devMode)) {
            break
        }

        if ($devMode.dmPelsWidth -gt 0 -and $devMode.dmPelsHeight -gt 0 -and $devMode.dmDisplayFrequency -gt 0) {
            $modes.Add([pscustomobject]@{
                    Width = $devMode.dmPelsWidth
                    Height = $devMode.dmPelsHeight
                    RefreshRate = $devMode.dmDisplayFrequency
                    PixelCount = $devMode.dmPelsWidth * $devMode.dmPelsHeight
                })
        }

        $modeIndex++
    }

    return $modes |
        Sort-Object Width, Height, RefreshRate -Unique
}

function Convert-MonitorByteArrayToString {
    param([AllowNull()][object]$Values)

    if (-not $Values) {
        return ""
    }

    try {
        return [string]::new([char[]]$Values).Trim([char]0)
    }
    catch {
        return ""
    }
}

function Get-AppleDisplayProfileEvidence {
    $evidence = @()
    $appleDisplayPattern = "Studio Display XDR|Studio Display|StudioDisplay|Pro Display XDR|Display XDR|DISPLAY\\APPA|VID_05AC&PID_1114|VID_05AC&PID_1116|USB4\\VID_8087&PID_5786"

    try {
        $evidence += Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop |
            ForEach-Object {
                $name = Convert-MonitorByteArrayToString -Values $_.UserFriendlyName
                $manufacturer = Convert-MonitorByteArrayToString -Values $_.ManufacturerName
                [pscustomobject]@{
                    Source = "WmiMonitorID"
                    Text = "$($_.InstanceName) $manufacturer $name"
                }
            } |
            Where-Object { $_.Text -match $appleDisplayPattern }
    }
    catch {
        Write-Warning "WmiMonitorID check failed: $($_.Exception.Message)"
    }

    try {
        $evidence += Get-CimInstance Win32_DesktopMonitor -ErrorAction Stop |
            ForEach-Object {
                [pscustomobject]@{
                    Source = "Win32_DesktopMonitor"
                    Text = "$($_.PNPDeviceID) $($_.Name)"
                }
            } |
            Where-Object { $_.Text -match $appleDisplayPattern }
    }
    catch {
        Write-Warning "Win32_DesktopMonitor check failed: $($_.Exception.Message)"
    }

    try {
        $evidence += Get-PnpDevice -PresentOnly -ErrorAction Stop |
            ForEach-Object {
                [pscustomobject]@{
                    Source = "Get-PnpDevice"
                    Text = "$($_.Class) $($_.FriendlyName) $($_.InstanceId)"
                }
            } |
            Where-Object { $_.Text -match $appleDisplayPattern }
    }
    catch {
        Write-Warning "Get-PnpDevice check failed: $($_.Exception.Message)"
    }

    return $evidence
}

function Resolve-AppleDisplayProfile {
    param([string]$RequestedProfile)

    if ($RequestedProfile -ne "Auto") {
        return $RequestedProfile
    }

    $evidence = @(Get-AppleDisplayProfileEvidence)
    $evidenceText = ($evidence | ForEach-Object { $_.Text }) -join " "

    if ($evidenceText -match "Studio Display XDR|VID_05AC&PID_1116|USB4\\VID_8087&PID_5786") {
        return "StudioDisplayXDR"
    }

    if ($evidenceText -match "Pro Display XDR") {
        return "ProDisplayXDR"
    }

    if ($evidenceText -match "Studio Display|StudioDisplay|DISPLAY\\APPA|VID_05AC&PID_1114") {
        return "StudioDisplay"
    }

    return "Generic"
}

function Get-AppleDisplayExpectedMode {
    param([string]$Profile)

    switch ($Profile) {
        "StudioDisplayXDR" {
            return [pscustomobject]@{
                Width = 5120
                Height = 2880
                RefreshRate = 120
                Description = "Studio Display XDR native 5K 120Hz"
            }
        }
        "StudioDisplay" {
            return [pscustomobject]@{
                Width = 5120
                Height = 2880
                RefreshRate = 60
                Description = "Studio Display native 5K 60Hz"
            }
        }
        "ProDisplayXDR" {
            return [pscustomobject]@{
                Width = 6016
                Height = 3384
                RefreshRate = 60
                Description = "Pro Display XDR native 6K 60Hz"
            }
        }
        default {
            return [pscustomobject]@{
                Width = $null
                Height = $null
                RefreshRate = $null
                Description = "Generic display"
            }
        }
    }
}

function Get-MaxDisplayModeSummary {
    param([object[]]$Modes)

    if (-not $Modes) {
        return "none"
    }

    $best = $Modes |
        Sort-Object `
            @{ Expression = { -($_.Width * $_.Height) } }, `
            @{ Expression = { -$_.RefreshRate } } |
        Select-Object -First 1

    return "$($best.Width)x$($best.Height)@$($best.RefreshRate)Hz"
}

function Test-ExpectedResolutionAvailable {
    param(
        [object[]]$Modes,
        [Nullable[int]]$TargetWidth,
        [Nullable[int]]$TargetHeight
    )

    if ($null -eq $TargetWidth -or $null -eq $TargetHeight) {
        return $true
    }

    $match = $Modes |
        Where-Object { $_.Width -eq $TargetWidth -and $_.Height -eq $TargetHeight } |
        Select-Object -First 1

    return [bool]$match
}

function Test-DisplayModeAccepted {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName,
        [Parameter(Mandatory = $true)]
        [int]$TargetWidth,
        [Parameter(Mandatory = $true)]
        [int]$TargetHeight,
        [Parameter(Mandatory = $true)]
        [int]$TargetRefreshRate
    )

    $devMode = New-Object StudioDisplayDevMode
    $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayDevMode])

    if (-not [StudioDisplayChangeDisplaySettings]::EnumDisplaySettings(
            $DeviceName,
            [StudioDisplayChangeDisplaySettings]::ENUM_CURRENT_SETTINGS,
            [ref]$devMode
        )) {
        return $false
    }

    $devMode.dmPelsWidth = $TargetWidth
    $devMode.dmPelsHeight = $TargetHeight
    $devMode.dmDisplayFrequency = $TargetRefreshRate
    $devMode.dmFields = (
        [StudioDisplayChangeDisplaySettings]::DM_PELSWIDTH -bor
        [StudioDisplayChangeDisplaySettings]::DM_PELSHEIGHT -bor
        [StudioDisplayChangeDisplaySettings]::DM_DISPLAYFREQUENCY
    )

    $testResult = [StudioDisplayChangeDisplaySettings]::ChangeDisplaySettingsEx(
        $DeviceName,
        [ref]$devMode,
        [IntPtr]::Zero,
        [StudioDisplayChangeDisplaySettings]::CDS_TEST,
        [IntPtr]::Zero
    )

    return ($testResult -eq [StudioDisplayChangeDisplaySettings]::DISP_CHANGE_SUCCESSFUL)
}

function Get-NativeRefreshCandidates {
    param(
        [Nullable[int]]$PreferredRefreshRate,
        [string]$Profile
    )

    $candidates = New-Object System.Collections.Generic.List[int]

    if ($null -ne $PreferredRefreshRate -and -not $candidates.Contains([int]$PreferredRefreshRate)) {
        $candidates.Add([int]$PreferredRefreshRate)
    }

    if (-not $DisableNativeRefreshFallback) {
        $fallbackRates = if ($Profile -eq "StudioDisplayXDR") {
            @(120, 60, 30)
        }
        else {
            @(60, 30)
        }

        foreach ($rate in $fallbackRates) {
            if (-not $candidates.Contains([int]$rate)) {
                $candidates.Add([int]$rate)
            }
        }
    }

    if ($candidates.Count -eq 0) {
        $candidates.Add(60)
    }

    return $candidates.ToArray()
}

function Invoke-PnpDeviceRescan {
    try {
        $output = & pnputil /scan-devices 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "PnP device rescan completed."
        }
        else {
            Write-Warning ("PnP device rescan failed with exit code {0}. {1}" -f $LASTEXITCODE, (($output | Out-String).Trim()))
        }
    }
    catch {
        Write-Warning "PnP device rescan failed: $($_.Exception.Message)"
    }
}

function Assert-ExpectedNativeModeAvailable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName,
        [string]$Profile,
        [Nullable[int]]$TargetWidth,
        [Nullable[int]]$TargetHeight,
        [Nullable[int]]$TargetRefreshRate,
        [int]$MinimumWidth,
        [int]$MinimumHeight
    )

    if ($null -eq $TargetWidth -or $null -eq $TargetHeight) {
        return
    }

    $modes = @(Get-AvailableDisplayModes -DeviceName $DeviceName)
    if (Test-ExpectedResolutionAvailable -Modes $modes -TargetWidth $TargetWidth -TargetHeight $TargetHeight) {
        return [pscustomobject]@{
            Width = [int]$TargetWidth
            Height = [int]$TargetHeight
            RefreshRate = if ($null -ne $TargetRefreshRate) { [int]$TargetRefreshRate } else { 60 }
            ModeSource = "Enumerated"
        }
    }

    $refreshCandidates = @(Get-NativeRefreshCandidates -PreferredRefreshRate $TargetRefreshRate -Profile $Profile)
    foreach ($refreshCandidate in $refreshCandidates) {
        if (Test-DisplayModeAccepted -DeviceName $DeviceName -TargetWidth ([int]$TargetWidth) -TargetHeight ([int]$TargetHeight) -TargetRefreshRate ([int]$refreshCandidate)) {
            if ($AllowCdsTestOnlyNativeMode) {
                Write-Host "Expected native resolution is not enumerated, but CDS_TEST accepts ${TargetWidth}x${TargetHeight}@${refreshCandidate}Hz."
                return [pscustomobject]@{
                    Width = [int]$TargetWidth
                    Height = [int]$TargetHeight
                    RefreshRate = [int]$refreshCandidate
                    ModeSource = "CDS_TEST"
                }
            }

            Write-Warning "Expected native resolution is not enumerated, although CDS_TEST accepts ${TargetWidth}x${TargetHeight}@${refreshCandidate}Hz. Treating this as an unstable mode-table state for HDR and game resolution lists."
            break
        }
    }

    if ($RescanWhenNativeMissing) {
        Write-Warning ("Expected native mode {0}x{1}@{2}Hz for {3} is not currently enumerated on {4}. Current maximum is {5}. Trying a PnP rescan." -f $TargetWidth, $TargetHeight, $TargetRefreshRate, $Profile, $DeviceName, (Get-MaxDisplayModeSummary -Modes $modes))
        Invoke-PnpDeviceRescan
        Start-Sleep -Milliseconds 1500
        $modes = @(Get-AvailableDisplayModes -DeviceName $DeviceName)
        if (Test-ExpectedResolutionAvailable -Modes $modes -TargetWidth $TargetWidth -TargetHeight $TargetHeight) {
            Write-Host "Expected native mode appeared after PnP rescan."
            return [pscustomobject]@{
                Width = [int]$TargetWidth
                Height = [int]$TargetHeight
                RefreshRate = if ($null -ne $TargetRefreshRate) { [int]$TargetRefreshRate } else { 60 }
                ModeSource = "EnumeratedAfterRescan"
            }
        }

        foreach ($refreshCandidate in $refreshCandidates) {
            if (Test-DisplayModeAccepted -DeviceName $DeviceName -TargetWidth ([int]$TargetWidth) -TargetHeight ([int]$TargetHeight) -TargetRefreshRate ([int]$refreshCandidate)) {
                if ($AllowCdsTestOnlyNativeMode) {
                    Write-Host "Expected native resolution appeared as a CDS_TEST-accepted mode after PnP rescan: ${TargetWidth}x${TargetHeight}@${refreshCandidate}Hz."
                    return [pscustomobject]@{
                        Width = [int]$TargetWidth
                        Height = [int]$TargetHeight
                        RefreshRate = [int]$refreshCandidate
                        ModeSource = "CDS_TEST_AFTER_RESCAN"
                    }
                }

                Write-Warning "Expected native resolution is still absent from the enumerated mode table after PnP rescan, although CDS_TEST accepts ${TargetWidth}x${TargetHeight}@${refreshCandidate}Hz. Refusing to treat it as stable."
                break
            }
        }
    }

    $maxMode = Get-MaxDisplayModeSummary -Modes $modes
    $triedRefreshRates = ($refreshCandidates -join ",")
    $minimumMessage = if ($MinimumWidth -gt 0 -and $MinimumHeight -gt 0) {
        " Minimum expected native resolution is ${MinimumWidth}x${MinimumHeight}."
    }
    else {
        ""
    }

    $message = "Native Apple display mode is missing. Profile=$Profile; expected=${TargetWidth}x${TargetHeight}@${TargetRefreshRate}Hz; tried refresh rates=$triedRefreshRates; current maximum=$maxMode on $DeviceName.$minimumMessage Windows is not exposing or accepting the high-bandwidth EDID/mode list, so this script will not force a low-resolution fallback unless -AllowLowResolutionFallback is passed. Check the Thunderbolt 5/USB4 port, cable, GPU routing, and Intel/NVIDIA/USB4 drivers."

    if ($AllowLowResolutionFallback) {
        Write-Warning $message
        return
    }

    throw $message
}

function Select-PreferredRefreshMode {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Modes,
        [Nullable[int]]$RequestedRefreshRate,
        [Nullable[int]]$CurrentRefreshRate
    )

    if ($null -ne $RequestedRefreshRate) {
        $exactMatch = $Modes |
            Where-Object { $_.RefreshRate -eq $RequestedRefreshRate } |
            Select-Object -First 1
        if ($exactMatch) {
            return $exactMatch
        }

        return $Modes |
            Sort-Object `
                @{ Expression = { [Math]::Abs($_.RefreshRate - $RequestedRefreshRate) } }, `
                @{ Expression = { -$_.RefreshRate } } |
            Select-Object -First 1
    }

    if ($null -ne $CurrentRefreshRate) {
        $currentMatch = $Modes |
            Where-Object { $_.RefreshRate -eq $CurrentRefreshRate } |
            Select-Object -First 1
        if ($currentMatch) {
            return $currentMatch
        }
    }

    return $Modes |
        Sort-Object `
            @{ Expression = { [Math]::Abs($_.RefreshRate - 60) } }, `
            @{ Expression = { -$_.RefreshRate } } |
        Select-Object -First 1
}

function Resolve-TargetDisplayMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName,
        [Nullable[int]]$RequestedWidth,
        [Nullable[int]]$RequestedHeight,
        [Nullable[int]]$RequestedRefreshRate
    )

    if (($null -ne $RequestedWidth) -xor ($null -ne $RequestedHeight)) {
        throw "Width and Height must be provided together."
    }

    $availableModes = @(Get-AvailableDisplayModes -DeviceName $DeviceName)
    if (-not $availableModes) {
        throw "No available display modes were enumerated for $DeviceName."
    }

    $currentMode = Get-CurrentDisplayMode -DeviceName $DeviceName

    if ($null -ne $RequestedWidth -and $null -ne $RequestedHeight) {
        $matchingModes = @(
            $availableModes |
                Where-Object {
                    $_.Width -eq $RequestedWidth -and
                    $_.Height -eq $RequestedHeight
                }
        )

        if (-not $matchingModes) {
            $refreshCandidates = @(Get-NativeRefreshCandidates -PreferredRefreshRate $RequestedRefreshRate -Profile $resolvedAppleDisplayProfile)
            foreach ($refreshCandidate in $refreshCandidates) {
                if (Test-DisplayModeAccepted -DeviceName $DeviceName -TargetWidth ([int]$RequestedWidth) -TargetHeight ([int]$RequestedHeight) -TargetRefreshRate ([int]$refreshCandidate)) {
                    return [pscustomobject]@{
                        Width = [int]$RequestedWidth
                        Height = [int]$RequestedHeight
                        RefreshRate = [int]$refreshCandidate
                        PixelCount = [int]$RequestedWidth * [int]$RequestedHeight
                    }
                }
            }

            throw "Requested display mode ${RequestedWidth}x${RequestedHeight} is not available or accepted on $DeviceName."
        }

        return Select-PreferredRefreshMode -Modes $matchingModes -RequestedRefreshRate $RequestedRefreshRate -CurrentRefreshRate $currentMode.RefreshRate
    }

    $highestPixelCount = ($availableModes | Measure-Object -Property PixelCount -Maximum).Maximum
    $highestResolutionModes = @(
        $availableModes |
            Where-Object { $_.PixelCount -eq $highestPixelCount }
    )

    if (-not $highestResolutionModes) {
        throw "Unable to resolve the highest available display mode for $DeviceName."
    }

    return Select-PreferredRefreshMode -Modes $highestResolutionModes -RequestedRefreshRate $RequestedRefreshRate -CurrentRefreshRate $currentMode.RefreshRate
}

function Test-DisplayModeMatches {
    param(
        [Parameter(Mandatory = $true)]
        [object]$CurrentMode,
        [Parameter(Mandatory = $true)]
        [object]$TargetMode
    )

    return (
        $CurrentMode.Width -eq $TargetMode.Width -and
        $CurrentMode.Height -eq $TargetMode.Height -and
        $CurrentMode.RefreshRate -eq $TargetMode.RefreshRate
    )
}

function Get-ActiveScreenSummary {
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    if (-not $screens) {
        return "none"
    }

    return (($screens |
            Sort-Object DeviceName |
            ForEach-Object {
                "{0} primary={1} bounds={2}" -f $_.DeviceName, $_.Primary, $_.Bounds.ToString()
            }) -join "; ")
}

function Test-ExternalOnlyScreenTopology {
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    if ($screens.Count -ne 1) {
        Write-Warning "External-only topology is not settled yet. Active screens=$($screens.Count): $(Get-ActiveScreenSummary)"
        return $false
    }

    Write-Host "External-only topology verified: $(Get-ActiveScreenSummary)"
    return $true
}

function Wait-ExternalOnlyScreenTopology {
    for ($attempt = 1; $attempt -le $ExternalOnlyVerifyRetries; $attempt++) {
        if (Test-ExternalOnlyScreenTopology) {
            return $true
        }

        Start-Sleep -Milliseconds $ExternalOnlyVerifyDelayMs
    }

    return $false
}

function Invoke-DisplaySwitchExternalFallback {
    Start-Process -FilePath (Join-Path $env:WINDIR "System32\DisplaySwitch.exe") -ArgumentList "/external" -WindowStyle Hidden
    Write-Host "DisplaySwitch.exe fallback started with /external."
    Start-Sleep -Milliseconds $TopologySettleDelayMs
}

function Test-ActiveHdrMode {
    if (-not (Test-Path -LiteralPath $advancedColorProbeScript)) {
        return $false
    }

    try {
        $probe = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $advancedColorProbeScript -IncludeDxDiag 2>$null)
        $probeText = $probe -join "`n"
        return [bool]($probeText -match 'ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR')
    }
    catch {
        Write-Warning "HDR preservation probe failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-CurrentModeMeetsTarget {
    param(
        [Nullable[int]]$TargetWidth,
        [Nullable[int]]$TargetHeight
    )

    if ($null -eq $TargetWidth -or $null -eq $TargetHeight) {
        return $true
    }

    try {
        $deviceName = [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
        $currentMode = Get-CurrentDisplayMode -DeviceName $deviceName
        return ($currentMode.Width -eq [int]$TargetWidth -and $currentMode.Height -eq [int]$TargetHeight)
    }
    catch {
        Write-Warning "Current mode check for HDR preservation failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-StagedExternalDisplayModeRepair {
    param(
        [Parameter(Mandatory = $true)]
        [int]$FallbackWidth,
        [Parameter(Mandatory = $true)]
        [int]$FallbackHeight,
        [Parameter(Mandatory = $true)]
        [int]$FallbackRefreshRate,
        [Nullable[int]]$PreferredRefreshRate,
        [Parameter(Mandatory = $true)]
        [int]$PreferredDelayMs
    )

    $deviceName = [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
    $preferredMode = Resolve-TargetDisplayMode -DeviceName $deviceName -RequestedWidth $null -RequestedHeight $null -RequestedRefreshRate $PreferredRefreshRate
    $fallbackMode = $null
    $fallbackApplied = $false

    try {
        $fallbackMode = Resolve-TargetDisplayMode -DeviceName $deviceName -RequestedWidth $FallbackWidth -RequestedHeight $FallbackHeight -RequestedRefreshRate $FallbackRefreshRate
        Invoke-PrimaryDisplayModeRepair -TargetWidth $fallbackMode.Width -TargetHeight $fallbackMode.Height -TargetRefreshRate $fallbackMode.RefreshRate
        $fallbackApplied = $true
        Write-Host "Applied safety display mode before native restore: $($fallbackMode.Width)x$($fallbackMode.Height)@$($fallbackMode.RefreshRate)Hz."
    }
    catch {
        Write-Warning "Safety display mode repair failed: $($_.Exception.Message)"
    }

    if ($PreferredDelayMs -gt 0) {
        Start-Sleep -Milliseconds $PreferredDelayMs
    }

    $currentModeBeforePreferred = Get-CurrentDisplayMode -DeviceName $deviceName
    if (Test-DisplayModeMatches -CurrentMode $currentModeBeforePreferred -TargetMode $preferredMode) {
        Write-Host "Preferred native display mode is already active: $($preferredMode.Width)x$($preferredMode.Height)@$($preferredMode.RefreshRate)Hz."
        return $true
    }

    try {
        Invoke-PrimaryDisplayModeRepair -TargetWidth $preferredMode.Width -TargetHeight $preferredMode.Height -TargetRefreshRate $preferredMode.RefreshRate
        Write-Host "Restored preferred native display mode after hot-plug stabilization: $($preferredMode.Width)x$($preferredMode.Height)@$($preferredMode.RefreshRate)Hz."
        return $true
    }
    catch {
        Write-Warning "Preferred native display mode restore failed: $($_.Exception.Message)"
        if ($fallbackApplied) {
            Write-Host "Keeping safety display mode after native restore failure."
            return $true
        }

        return $false
    }
}

$resolvedAppleDisplayProfile = Resolve-AppleDisplayProfile -RequestedProfile $AppleDisplayProfile
$profileExpectedMode = Get-AppleDisplayExpectedMode -Profile $resolvedAppleDisplayProfile

$targetWidth = $Width
$targetHeight = $Height
$targetRefreshRate = $RefreshRate
$nativeGuardWidth = $ExpectedWidth
$nativeGuardHeight = $ExpectedHeight
$nativeGuardRefreshRate = $ExpectedRefreshRate
$minimumNativeGuardWidth = $MinimumNativeWidth
$minimumNativeGuardHeight = $MinimumNativeHeight

if ($null -eq $nativeGuardWidth -and $null -ne $profileExpectedMode.Width) {
    $nativeGuardWidth = $profileExpectedMode.Width
}
if ($null -eq $nativeGuardHeight -and $null -ne $profileExpectedMode.Height) {
    $nativeGuardHeight = $profileExpectedMode.Height
}
if ($null -eq $nativeGuardRefreshRate -and $null -ne $profileExpectedMode.RefreshRate) {
    $nativeGuardRefreshRate = $profileExpectedMode.RefreshRate
}
if ($null -eq $targetRefreshRate -and $null -ne $profileExpectedMode.RefreshRate) {
    $targetRefreshRate = $profileExpectedMode.RefreshRate
}
if ($minimumNativeGuardWidth -le 0 -and $null -ne $nativeGuardWidth) {
    $minimumNativeGuardWidth = $nativeGuardWidth
}
if ($minimumNativeGuardHeight -le 0 -and $null -ne $nativeGuardHeight) {
    $minimumNativeGuardHeight = $nativeGuardHeight
}

if ($resolvedAppleDisplayProfile -ne "Generic") {
    Write-Host "Detected Apple display profile: $resolvedAppleDisplayProfile ($($profileExpectedMode.Description))."
}

if ($Topology -eq "External" -and $AppleDisplayProfile -eq "Auto" -and $resolvedAppleDisplayProfile -eq "Generic" -and -not $AllowLowResolutionFallback) {
    Write-Warning "No Apple Studio Display evidence was detected, so external display mode repair is refusing to use the current primary display as a target. This prevents accidentally applying Studio Display repair to the internal panel. Reconnect or power-cycle the Studio Display, or pass an explicit -AppleDisplayProfile only after confirming the external display is active."
    exit 2
}

$activeHdrBeforeRepair = $false
if ($PreserveActiveHdr) {
    $activeHdrBeforeRepair = Test-ActiveHdrMode
    if ($activeHdrBeforeRepair) {
        $externalOnlyAlreadyReady = if ($Topology -eq "External" -or $RequireExternalOnly) {
            (@([System.Windows.Forms.Screen]::AllScreens).Count -eq 1)
        }
        else {
            $true
        }

        $resolutionAlreadyReady = Test-CurrentModeMeetsTarget -TargetWidth $nativeGuardWidth -TargetHeight $nativeGuardHeight
        if ($externalOnlyAlreadyReady -and $resolutionAlreadyReady) {
            Write-Host "HDR is already active and the Studio Display is already the only 5K target. Preserving HDR by skipping topology and display-mode rewrite."
            exit 0
        }

        Write-Warning "HDR is already active, but topology or resolution still needs repair. Continuing, but safety-mode staging will be disabled to avoid unnecessary HDR teardown."
        $SkipSafetyMode = $true
    }
}

$topologyFlag = switch ($Topology) {
    "Internal" { [StudioDisplaySetDisplayConfig]::SDC_TOPOLOGY_INTERNAL }
    "Clone" { [StudioDisplaySetDisplayConfig]::SDC_TOPOLOGY_CLONE }
    "Extend" { [StudioDisplaySetDisplayConfig]::SDC_TOPOLOGY_EXTEND }
    default { [StudioDisplaySetDisplayConfig]::SDC_TOPOLOGY_EXTERNAL }
}

$flags = [uint32](
    $topologyFlag -bor
    [StudioDisplaySetDisplayConfig]::SDC_APPLY
)

$result = [StudioDisplaySetDisplayConfig]::SetDisplayConfig(
    0,
    [IntPtr]::Zero,
    0,
    [IntPtr]::Zero,
    $flags
)

$topologyApplied = $false
if ($result -eq 0) {
    $topologyApplied = $true
    Write-Host "SetDisplayConfig applied $Topology topology silently."
} else {
    Write-Warning ("SetDisplayConfig failed for {0} topology with Win32 error {1}." -f $Topology, $result)
}

if (-not $topologyApplied -and $AllowDisplaySwitchFallback) {
    $switchArg = switch ($Topology) {
        "Internal" { "/internal" }
        "Clone" { "/clone" }
        "Extend" { "/extend" }
        default { "/external" }
    }

    Start-Process -FilePath (Join-Path $env:WINDIR "System32\DisplaySwitch.exe") -ArgumentList $switchArg -WindowStyle Hidden
    $topologyApplied = $true
    Write-Host "DisplaySwitch.exe fallback started with $switchArg."
}

if ($Topology -eq "External" -and $RequireExternalOnly) {
    if ($topologyApplied) {
        Start-Sleep -Milliseconds $TopologySettleDelayMs
    }

    if (-not (Wait-ExternalOnlyScreenTopology)) {
        if ($AllowDisplaySwitchFallback) {
            Write-Warning "SetDisplayConfig did not settle into an external-only screen state; retrying through DisplaySwitch.exe /external."
            Invoke-DisplaySwitchExternalFallback
        }

        if (-not (Wait-ExternalOnlyScreenTopology)) {
            Write-Warning "External-only topology verification failed. Refusing to continue into display-mode/HDR repair until Windows exposes Studio Display as the only active screen."
            exit 4
        }
    }
}

$shouldRepairPrimaryDisplayMode = (
    $Topology -eq "External" -or
    $null -ne $targetWidth -or
    $null -ne $targetHeight -or
    $null -ne $targetRefreshRate
)

if ($shouldRepairPrimaryDisplayMode) {
    if ($topologyApplied) {
        Start-Sleep -Milliseconds $TopologySettleDelayMs
    }

    $primaryDeviceName = [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
    $acceptedNativeMode = Assert-ExpectedNativeModeAvailable `
        -DeviceName $primaryDeviceName `
        -Profile $resolvedAppleDisplayProfile `
        -TargetWidth $nativeGuardWidth `
        -TargetHeight $nativeGuardHeight `
        -TargetRefreshRate $nativeGuardRefreshRate `
        -MinimumWidth $minimumNativeGuardWidth `
        -MinimumHeight $minimumNativeGuardHeight

    if ($acceptedNativeMode -and $acceptedNativeMode.ModeSource -match "CDS_TEST") {
        if ($null -eq $targetWidth -and $null -eq $targetHeight) {
            $targetWidth = $acceptedNativeMode.Width
            $targetHeight = $acceptedNativeMode.Height
            $targetRefreshRate = $acceptedNativeMode.RefreshRate
            Write-Host "Using CDS_TEST-accepted native repair target: ${targetWidth}x${targetHeight}@${targetRefreshRate}Hz."
        }
    }

    $shouldUseStagedExternalRepair = (
        $Topology -eq "External" -and
        $null -eq $targetWidth -and
        $null -eq $targetHeight -and
        -not $SkipSafetyMode -and
        -not ($PreserveActiveHdr -and $activeHdrBeforeRepair)
    )

    if ($shouldUseStagedExternalRepair) {
        if (Invoke-StagedExternalDisplayModeRepair -FallbackWidth $SafeWidth -FallbackHeight $SafeHeight -FallbackRefreshRate $SafeRefreshRate -PreferredRefreshRate $targetRefreshRate -PreferredDelayMs $PreferredModeDelayMs) {
            exit 0
        }
    } else {
        try {
            Invoke-PrimaryDisplayModeRepair -TargetWidth $targetWidth -TargetHeight $targetHeight -TargetRefreshRate $targetRefreshRate
            exit 0
        }
        catch {
            Write-Warning "Primary display mode repair failed: $($_.Exception.Message)"
        }
    }
}

if ($topologyApplied) {
    exit 0
}

exit $result
