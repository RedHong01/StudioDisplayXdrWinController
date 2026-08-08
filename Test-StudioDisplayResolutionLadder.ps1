[CmdletBinding()]
param(
    [string]$DeviceName,
    [string]$ReportPath,
    [switch]$ApplyFirstPassingMode
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

if (-not $DeviceName) {
    $DeviceName = [System.Windows.Forms.Screen]::PrimaryScreen.DeviceName
}

if (-not ("StudioDisplayResolutionLadderApi" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct StudioDisplayResolutionLadderDevMode {
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

public static class StudioDisplayResolutionLadderApi {
    public const int ENUM_CURRENT_SETTINGS = -1;
    public const int DM_PELSWIDTH = 0x00080000;
    public const int DM_PELSHEIGHT = 0x00100000;
    public const int DM_DISPLAYFREQUENCY = 0x00400000;
    public const int CDS_UPDATEREGISTRY = 0x00000001;
    public const int CDS_TEST = 0x00000002;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref StudioDisplayResolutionLadderDevMode devMode);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(
        string deviceName,
        ref StudioDisplayResolutionLadderDevMode devMode,
        IntPtr hwnd,
        int flags,
        IntPtr lParam
    );
}
"@
}

function Convert-DisplayChangeCode {
    param([int]$Code)

    switch ($Code) {
        0 { return "SUCCESS" }
        1 { return "RESTART_REQUIRED" }
        -1 { return "FAILED" }
        -2 { return "BADMODE" }
        -3 { return "NOTUPDATED" }
        -4 { return "BADFLAGS" }
        -5 { return "BADPARAM" }
        -6 { return "BADDUALVIEW" }
        default { return "UNKNOWN_$Code" }
    }
}

function Get-CurrentDisplayMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDeviceName
    )

    $devMode = New-Object StudioDisplayResolutionLadderDevMode
    $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayResolutionLadderDevMode])

    if (-not [StudioDisplayResolutionLadderApi]::EnumDisplaySettings(
            $TargetDeviceName,
            [StudioDisplayResolutionLadderApi]::ENUM_CURRENT_SETTINGS,
            [ref]$devMode
        )) {
        throw "EnumDisplaySettings failed for current mode on $TargetDeviceName."
    }

    return [pscustomobject]@{
        Width = $devMode.dmPelsWidth
        Height = $devMode.dmPelsHeight
        RefreshRate = $devMode.dmDisplayFrequency
        BitsPerPixel = $devMode.dmBitsPerPel
    }
}

function Get-AvailableDisplayModes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDeviceName
    )

    $modes = New-Object System.Collections.Generic.List[object]
    $modeIndex = 0

    while ($true) {
        $devMode = New-Object StudioDisplayResolutionLadderDevMode
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayResolutionLadderDevMode])

        if (-not [StudioDisplayResolutionLadderApi]::EnumDisplaySettings($TargetDeviceName, $modeIndex, [ref]$devMode)) {
            break
        }

        if ($devMode.dmPelsWidth -gt 0 -and $devMode.dmPelsHeight -gt 0 -and $devMode.dmDisplayFrequency -gt 0) {
            $modes.Add([pscustomobject]@{
                    Width = $devMode.dmPelsWidth
                    Height = $devMode.dmPelsHeight
                    RefreshRate = $devMode.dmDisplayFrequency
                    BitsPerPixel = $devMode.dmBitsPerPel
                    PixelCount = $devMode.dmPelsWidth * $devMode.dmPelsHeight
                }) | Out-Null
        }

        $modeIndex++
    }

    return $modes | Sort-Object Width, Height, RefreshRate, BitsPerPixel -Unique
}

function Test-DisplayMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetDeviceName,
        [Parameter(Mandatory = $true)]
        [int]$Width,
        [Parameter(Mandatory = $true)]
        [int]$Height,
        [Parameter(Mandatory = $true)]
        [int]$RefreshRate,
        [switch]$Apply
    )

    $devMode = New-Object StudioDisplayResolutionLadderDevMode
    $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayResolutionLadderDevMode])

    if (-not [StudioDisplayResolutionLadderApi]::EnumDisplaySettings(
            $TargetDeviceName,
            [StudioDisplayResolutionLadderApi]::ENUM_CURRENT_SETTINGS,
            [ref]$devMode
        )) {
        throw "EnumDisplaySettings failed for $TargetDeviceName."
    }

    $devMode.dmPelsWidth = $Width
    $devMode.dmPelsHeight = $Height
    $devMode.dmDisplayFrequency = $RefreshRate
    $devMode.dmFields = (
        [StudioDisplayResolutionLadderApi]::DM_PELSWIDTH -bor
        [StudioDisplayResolutionLadderApi]::DM_PELSHEIGHT -bor
        [StudioDisplayResolutionLadderApi]::DM_DISPLAYFREQUENCY
    )

    $testCode = [StudioDisplayResolutionLadderApi]::ChangeDisplaySettingsEx(
        $TargetDeviceName,
        [ref]$devMode,
        [IntPtr]::Zero,
        [StudioDisplayResolutionLadderApi]::CDS_TEST,
        [IntPtr]::Zero
    )

    $applyCode = $null
    if ($Apply -and $testCode -eq 0) {
        $applyCode = [StudioDisplayResolutionLadderApi]::ChangeDisplaySettingsEx(
            $TargetDeviceName,
            [ref]$devMode,
            [IntPtr]::Zero,
            [StudioDisplayResolutionLadderApi]::CDS_UPDATEREGISTRY,
            [IntPtr]::Zero
        )
    }

    return [pscustomobject]@{
        Width = $Width
        Height = $Height
        RefreshRate = $RefreshRate
        TestCode = $testCode
        TestResult = Convert-DisplayChangeCode -Code $testCode
        ApplyCode = $applyCode
        ApplyResult = if ($null -ne $applyCode) { Convert-DisplayChangeCode -Code $applyCode } else { "not-applied" }
    }
}

$ladder = @(
    [pscustomobject]@{ Width = 5120; Height = 2880; RefreshRate = 120; Label = "5K 120Hz native XDR target" },
    [pscustomobject]@{ Width = 5120; Height = 2880; RefreshRate = 60; Label = "5K 60Hz legacy Studio Display fallback" },
    [pscustomobject]@{ Width = 5120; Height = 2880; RefreshRate = 30; Label = "5K 30Hz bandwidth-reduced probe" },
    [pscustomobject]@{ Width = 4096; Height = 2304; RefreshRate = 60; Label = "DCI-ish 4K+ 60Hz probe" },
    [pscustomobject]@{ Width = 3840; Height = 2160; RefreshRate = 120; Label = "4K 120Hz bandwidth probe" },
    [pscustomobject]@{ Width = 3840; Height = 2160; RefreshRate = 60; Label = "4K 60Hz fallback probe" },
    [pscustomobject]@{ Width = 3200; Height = 1800; RefreshRate = 60; Label = "3.2K 60Hz fallback probe" },
    [pscustomobject]@{ Width = 2560; Height = 1440; RefreshRate = 60; Label = "2K 60Hz safety probe" },
    [pscustomobject]@{ Width = 1920; Height = 1080; RefreshRate = 60; Label = "Current fallback baseline" }
)

$currentMode = Get-CurrentDisplayMode -TargetDeviceName $DeviceName
$availableModes = @(Get-AvailableDisplayModes -TargetDeviceName $DeviceName)
$firstPassingModeApplied = $false

$results = foreach ($candidate in $ladder) {
    $enumerated = [bool]($availableModes |
        Where-Object {
            $_.Width -eq $candidate.Width -and
            $_.Height -eq $candidate.Height -and
            $_.RefreshRate -eq $candidate.RefreshRate
        } |
        Select-Object -First 1)

    $shouldApply = (
        $ApplyFirstPassingMode -and
        -not $firstPassingModeApplied
    )

    $test = Test-DisplayMode `
        -TargetDeviceName $DeviceName `
        -Width $candidate.Width `
        -Height $candidate.Height `
        -RefreshRate $candidate.RefreshRate `
        -Apply:$shouldApply

    if ($ApplyFirstPassingMode -and $test.TestCode -eq 0 -and -not $firstPassingModeApplied) {
        $firstPassingModeApplied = $true
    }

    [pscustomobject]@{
        Label = $candidate.Label
        Width = $candidate.Width
        Height = $candidate.Height
        RefreshRate = $candidate.RefreshRate
        Enumerated = $enumerated
        ModeTableReady = $enumerated
        TestResult = $test.TestResult
        TestCode = $test.TestCode
        ApplyResult = $test.ApplyResult
    }
}

$bestEnumerated = $availableModes |
    Sort-Object `
        @{ Expression = { -($_.Width * $_.Height) } }, `
        @{ Expression = { -$_.RefreshRate } } |
    Select-Object -First 1

Write-Host "Device: $DeviceName"
Write-Host "Current mode: $($currentMode.Width)x$($currentMode.Height)@$($currentMode.RefreshRate)Hz $($currentMode.BitsPerPixel)bpp"
if ($bestEnumerated) {
    Write-Host "Best enumerated mode: $($bestEnumerated.Width)x$($bestEnumerated.Height)@$($bestEnumerated.RefreshRate)Hz"
}
else {
    Write-Host "Best enumerated mode: none"
}
Write-Host ""
$results | Format-Table -AutoSize

$fiveK60 = $results | Where-Object { $_.Width -eq 5120 -and $_.Height -eq 2880 -and $_.RefreshRate -eq 60 } | Select-Object -First 1
if ($fiveK60 -and $fiveK60.Enumerated -and $fiveK60.TestCode -ne 0) {
    Write-Host ""
    Write-Host "Note: 5K60 is present in the Windows mode table. CDS_TEST returned $($fiveK60.TestResult)/$($fiveK60.TestCode), which can happen on active HDR/DDisplay paths and should not by itself invalidate the game mode list."
}

if ($ReportPath) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Studio Display Resolution Ladder Test") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')") | Out-Null
    $lines.Add("- Device: ``$DeviceName``") | Out-Null
    $lines.Add("- Current mode: ``$($currentMode.Width)x$($currentMode.Height)@$($currentMode.RefreshRate)Hz``") | Out-Null
    if ($bestEnumerated) {
        $lines.Add("- Best enumerated mode: ``$($bestEnumerated.Width)x$($bestEnumerated.Height)@$($bestEnumerated.RefreshRate)Hz``") | Out-Null
    }
    else {
        $lines.Add("- Best enumerated mode: ``none``") | Out-Null
    }
    $lines.Add("") | Out-Null
    $lines.Add("| Label | Mode | Enumerated | ModeTableReady | CDS_TEST | TestCode | ApplyResult |") | Out-Null
    $lines.Add("|---|---:|---:|---:|---|---:|---|") | Out-Null

    foreach ($result in $results) {
        $lines.Add("| $($result.Label) | $($result.Width)x$($result.Height)@$($result.RefreshRate) | $($result.Enumerated) | $($result.ModeTableReady) | $($result.TestResult) | $($result.TestCode) | $($result.ApplyResult) |") | Out-Null
    }

    $reportDirectory = Split-Path -Parent $ReportPath
    if ($reportDirectory) {
        New-Item -ItemType Directory -Force -Path $reportDirectory | Out-Null
    }

    Set-Content -LiteralPath $ReportPath -Value $lines -Encoding utf8
    Write-Host ""
    Write-Host "Report written to: $ReportPath"
}
