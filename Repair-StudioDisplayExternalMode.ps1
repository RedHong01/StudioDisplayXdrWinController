[CmdletBinding()]
param(
    [ValidateSet("External", "Extend", "Clone", "Internal")]
    [string]$Topology = "External",
    [Nullable[int]]$Width,
    [Nullable[int]]$Height,
    [Nullable[int]]$RefreshRate,
    [int]$SafeWidth = 2560,
    [int]$SafeHeight = 1440,
    [int]$SafeRefreshRate = 60,
    [int]$TopologySettleDelayMs = 1500,
    [int]$PreferredModeDelayMs = 2000,
    [switch]$SkipSafetyMode,
    [switch]$AllowDisplaySwitchFallback
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

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
            throw "Requested display mode ${RequestedWidth}x${RequestedHeight} is not available on $DeviceName."
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

function Invoke-StagedExternalDisplayModeRepair {
    param(
        [Parameter(Mandatory = $true)]
        [int]$FallbackWidth,
        [Parameter(Mandatory = $true)]
        [int]$FallbackHeight,
        [Parameter(Mandatory = $true)]
        [int]$FallbackRefreshRate,
        [Parameter(Mandatory = $true)]
        [int]$PreferredDelayMs
    )

    $deviceName = [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
    $preferredMode = Resolve-TargetDisplayMode -DeviceName $deviceName -RequestedWidth $null -RequestedHeight $null -RequestedRefreshRate $RefreshRate
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

$shouldRepairPrimaryDisplayMode = (
    $Topology -eq "External" -or
    $null -ne $Width -or
    $null -ne $Height -or
    $null -ne $RefreshRate
)

if ($shouldRepairPrimaryDisplayMode) {
    if ($topologyApplied) {
        Start-Sleep -Milliseconds $TopologySettleDelayMs
    }

    $shouldUseStagedExternalRepair = (
        $Topology -eq "External" -and
        $null -eq $Width -and
        $null -eq $Height -and
        -not $SkipSafetyMode
    )

    if ($shouldUseStagedExternalRepair) {
        if (Invoke-StagedExternalDisplayModeRepair -FallbackWidth $SafeWidth -FallbackHeight $SafeHeight -FallbackRefreshRate $SafeRefreshRate -PreferredDelayMs $PreferredModeDelayMs) {
            exit 0
        }
    } else {
        try {
            Invoke-PrimaryDisplayModeRepair -TargetWidth $Width -TargetHeight $Height -TargetRefreshRate $RefreshRate
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
