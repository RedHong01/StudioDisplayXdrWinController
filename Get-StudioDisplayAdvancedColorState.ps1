[CmdletBinding()]
param(
    [switch]$IncludeDxDiag,
    [switch]$SkipDxDiagFallback
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class StudioDisplayAdvancedColorNative {
    public const UInt32 QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO = 9;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL = 11;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO_2 = 15;

    [DllImport("user32.dll")]
    public static extern Int32 GetDisplayConfigBufferSizes(
        UInt32 flags,
        out UInt32 numPathArrayElements,
        out UInt32 numModeInfoArrayElements);

    [DllImport("user32.dll")]
    public static extern Int32 QueryDisplayConfig(
        UInt32 flags,
        ref UInt32 numPathArrayElements,
        [Out] DISPLAYCONFIG_PATH_INFO[] pathArray,
        ref UInt32 numModeInfoArrayElements,
        [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
        IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    public static extern Int32 DisplayConfigGetDeviceInfo(
        ref DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO requestPacket);

    [DllImport("user32.dll")]
    public static extern Int32 DisplayConfigGetDeviceInfo(
        ref DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 requestPacket);

    [DllImport("user32.dll")]
    public static extern Int32 DisplayConfigGetDeviceInfo(
        ref DISPLAYCONFIG_SDR_WHITE_LEVEL requestPacket);

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID {
        public UInt32 LowPart;
        public Int32 HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL {
        public UInt32 Numerator;
        public UInt32 Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO {
        public LUID adapterId;
        public UInt32 id;
        public UInt32 modeInfoIdx;
        public UInt32 statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO {
        public LUID adapterId;
        public UInt32 id;
        public UInt32 modeInfoIdx;
        public UInt32 outputTechnology;
        public UInt32 rotation;
        public UInt32 scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public UInt32 scanLineOrdering;
        [MarshalAs(UnmanagedType.Bool)]
        public Boolean targetAvailable;
        public UInt32 statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public UInt32 flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL {
        public Int32 x;
        public Int32 y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_2DREGION {
        public UInt32 cx;
        public UInt32 cy;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO {
        public UInt64 pixelRate;
        public DISPLAYCONFIG_RATIONAL hSyncFreq;
        public DISPLAYCONFIG_RATIONAL vSyncFreq;
        public DISPLAYCONFIG_2DREGION activeSize;
        public DISPLAYCONFIG_2DREGION totalSize;
        public UInt32 videoStandard;
        public UInt32 scanLineOrdering;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_TARGET_MODE {
        public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_MODE {
        public UInt32 width;
        public UInt32 height;
        public UInt32 pixelFormat;
        public POINTL position;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct DISPLAYCONFIG_MODE_UNION {
        [FieldOffset(0)]
        public DISPLAYCONFIG_TARGET_MODE targetMode;
        [FieldOffset(0)]
        public DISPLAYCONFIG_SOURCE_MODE sourceMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_MODE_INFO {
        public UInt32 infoType;
        public UInt32 id;
        public LUID adapterId;
        public DISPLAYCONFIG_MODE_UNION modeInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER {
        public UInt32 type;
        public UInt32 size;
        public LUID adapterId;
        public UInt32 id;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public UInt32 value;
        public UInt32 colorEncoding;
        public UInt32 bitsPerColorChannel;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public UInt32 value;
        public UInt32 colorEncoding;
        public UInt32 bitsPerColorChannel;
        public UInt32 activeColorMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SDR_WHITE_LEVEL {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public UInt32 SDRWhiteLevel;
    }
}
"@

function Convert-LuidToString {
    param([StudioDisplayAdvancedColorNative+LUID]$Luid)

    return ("{0:x8}:{1:x8}" -f $Luid.HighPart, $Luid.LowPart)
}

function Convert-RationalToDouble {
    param([StudioDisplayAdvancedColorNative+DISPLAYCONFIG_RATIONAL]$Rational)

    if ($Rational.Denominator -eq 0) {
        return 0
    }

    return [Math]::Round(($Rational.Numerator / $Rational.Denominator), 3)
}

function Convert-AdvancedColorModeName {
    param([UInt32]$Mode)

    switch ($Mode) {
        0 { return "DISPLAYCONFIG_ADVANCED_COLOR_MODE_SDR" }
        1 { return "DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG" }
        2 { return "DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR" }
        default { return "DISPLAYCONFIG_ADVANCED_COLOR_MODE_UNKNOWN_$Mode" }
    }
}

function Get-DxDiagDisplaySummary {
    $dxdiag = Join-Path $env:WINDIR "System32\dxdiag.exe"
    if (-not (Test-Path -LiteralPath $dxdiag)) {
        return $null
    }

    $outputPath = Join-Path $env:TEMP ("StudioDisplayDxDiag-{0}.txt" -f ([Guid]::NewGuid().ToString("N")))
    Start-Process -FilePath $dxdiag -ArgumentList @("/whql:off", "/t", $outputPath) -Wait -WindowStyle Hidden
    if (-not (Test-Path -LiteralPath $outputPath)) {
        return $null
    }

    $sections = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in Get-Content -LiteralPath $outputPath) {
        if ($line -match '^\s*Card name:\s*(.+)$') {
            if ($current) {
                $sections.Add([pscustomobject]$current) | Out-Null
            }

            $current = [ordered]@{
                CardName = $Matches[1].Trim()
            }
            continue
        }

        if (-not $current) {
            continue
        }

        if ($line -match '^\s*Current Mode:\s*(.+)$') { $current.CurrentMode = $Matches[1].Trim(); continue }
        if ($line -match '^\s*HDR Support:\s*(.+)$') { $current.HdrSupport = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Display Color Space:\s*(.+)$') { $current.DisplayColorSpace = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Display Luminance:\s*(.+)$') { $current.DisplayLuminance = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Monitor Name:\s*(.+)$') { $current.MonitorName = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Monitor Model:\s*(.+)$') { $current.MonitorModel = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Monitor Id:\s*(.+)$') { $current.MonitorId = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Native Mode:\s*(.+)$') { $current.NativeMode = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Output Type:\s*(.+)$') { $current.OutputType = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Monitor Capabilities:\s*(.+)$') { $current.MonitorCapabilities = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Advanced Color:\s*(.+)$') { $current.AdvancedColor = $Matches[1].Trim(); continue }
        if ($line -match '^\s*Active Color Mode:\s*(.+)$') { $current.ActiveColorMode = $Matches[1].Trim(); continue }
    }

    if ($current) {
        $sections.Add([pscustomobject]$current) | Out-Null
    }

    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue

    return @($sections |
        Where-Object {
            $_.MonitorId -match '^(APPA|MS_)' -or
            $_.MonitorModel -match 'StudioDisplay|Studio Display|Display XDR' -or
            $_.CurrentMode -match '5120 x 2880'
        } |
        Select-Object -First 1)
}

$pathCount = 0
$modeCount = 0
$result = [StudioDisplayAdvancedColorNative]::GetDisplayConfigBufferSizes(
    [StudioDisplayAdvancedColorNative]::QDC_ONLY_ACTIVE_PATHS,
    [ref]$pathCount,
    [ref]$modeCount
)
if ($result -ne 0) {
    throw "GetDisplayConfigBufferSizes failed with Win32 error $result."
}

$paths = New-Object "StudioDisplayAdvancedColorNative+DISPLAYCONFIG_PATH_INFO[]" $pathCount
$modes = New-Object "StudioDisplayAdvancedColorNative+DISPLAYCONFIG_MODE_INFO[]" $modeCount
$result = [StudioDisplayAdvancedColorNative]::QueryDisplayConfig(
    [StudioDisplayAdvancedColorNative]::QDC_ONLY_ACTIVE_PATHS,
    [ref]$pathCount,
    $paths,
    [ref]$modeCount,
    $modes,
    [IntPtr]::Zero
)
if ($result -ne 0) {
    throw "QueryDisplayConfig failed with Win32 error $result."
}

for ($index = 0; $index -lt $pathCount; $index++) {
    $path = $paths[$index]
    $sdrWhiteLevel = $null
    $sdrWhiteLevelNits = $null
    $sdrWhiteLevelQueryError = $null

    try {
        $sdrRequest = New-Object "StudioDisplayAdvancedColorNative+DISPLAYCONFIG_SDR_WHITE_LEVEL"
        $sdrHeader = New-Object "StudioDisplayAdvancedColorNative+DISPLAYCONFIG_DEVICE_INFO_HEADER"
        $sdrHeader.type = [StudioDisplayAdvancedColorNative]::DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL
        $sdrHeader.size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"StudioDisplayAdvancedColorNative+DISPLAYCONFIG_SDR_WHITE_LEVEL")
        $sdrHeader.adapterId = $path.targetInfo.adapterId
        $sdrHeader.id = $path.targetInfo.id
        $sdrRequest.header = $sdrHeader
        $sdrWhiteLevelQueryError = [StudioDisplayAdvancedColorNative]::DisplayConfigGetDeviceInfo([ref]$sdrRequest)
        if ($sdrWhiteLevelQueryError -eq 0) {
            $sdrWhiteLevel = [UInt32]$sdrRequest.SDRWhiteLevel
            $sdrWhiteLevelNits = [Math]::Round(($sdrWhiteLevel / 1000.0) * 80.0, 1)
        }
    }
    catch {
        $sdrWhiteLevelQueryError = $_.Exception.Message
    }

    $request2 = New-Object "StudioDisplayAdvancedColorNative+DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2"
    $header2 = New-Object "StudioDisplayAdvancedColorNative+DISPLAYCONFIG_DEVICE_INFO_HEADER"
    $header2.type = [StudioDisplayAdvancedColorNative]::DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO_2
    $header2.size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"StudioDisplayAdvancedColorNative+DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2")
    $header2.adapterId = $path.targetInfo.adapterId
    $header2.id = $path.targetInfo.id
    $request2.header = $header2

    $advancedColor2Result = [StudioDisplayAdvancedColorNative]::DisplayConfigGetDeviceInfo([ref]$request2)
    if ($advancedColor2Result -eq 0) {
        $raw2 = [UInt32]($request2.value -band 0xffffffff)
        [pscustomobject]@{
            PathIndex = $index
            SourceAdapter = Convert-LuidToString -Luid $path.sourceInfo.adapterId
            SourceId = $path.sourceInfo.id
            TargetAdapter = Convert-LuidToString -Luid $path.targetInfo.adapterId
            TargetId = $path.targetInfo.id
            RefreshRate = Convert-RationalToDouble -Rational $path.targetInfo.refreshRate
            OutputTechnology = $path.targetInfo.outputTechnology
            StateSource = "DisplayConfig"
            QueryApi = "GET_ADVANCED_COLOR_INFO_2"
            QueryError = $advancedColor2Result
            RawFlags = ("0x{0:x8}" -f $raw2)
            AdvancedColorSupported = (($raw2 -band 0x1) -ne 0)
            AdvancedColorEnabled = (($raw2 -band 0x2) -ne 0)
            AdvancedColorLimitedByPolicy = (($raw2 -band 0x8) -ne 0)
            HighDynamicRangeSupported = (($raw2 -band 0x10) -ne 0)
            HighDynamicRangeUserEnabled = (($raw2 -band 0x20) -ne 0)
            WideColorSupported = (($raw2 -band 0x40) -ne 0)
            WideColorUserEnabled = (($raw2 -band 0x80) -ne 0)
            ColorEncoding = $request2.colorEncoding
            BitsPerColorChannel = $request2.bitsPerColorChannel
            ActiveColorMode = Convert-AdvancedColorModeName -Mode $request2.activeColorMode
            SdrWhiteLevel = $sdrWhiteLevel
            SdrWhiteLevelNits = $sdrWhiteLevelNits
            SdrWhiteLevelQueryError = $sdrWhiteLevelQueryError
            LegacyQueryError = $null
        }
        continue
    }

    $request = New-Object "StudioDisplayAdvancedColorNative+DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO"
    $header = New-Object "StudioDisplayAdvancedColorNative+DISPLAYCONFIG_DEVICE_INFO_HEADER"
    $header.type = [StudioDisplayAdvancedColorNative]::DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO
    $header.size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]"StudioDisplayAdvancedColorNative+DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO")
    $header.adapterId = $path.targetInfo.adapterId
    $header.id = $path.targetInfo.id
    $request.header = $header

    $advancedColorResult = [StudioDisplayAdvancedColorNative]::DisplayConfigGetDeviceInfo([ref]$request)
    $raw = $request.value

    $dxdiagSummary = $null
    if ($advancedColorResult -ne 0 -and -not $SkipDxDiagFallback) {
        $dxdiagSummary = Get-DxDiagDisplaySummary
    }

    if ($advancedColorResult -ne 0 -and $dxdiagSummary) {
        [pscustomobject]@{
            PathIndex = $index
            SourceAdapter = Convert-LuidToString -Luid $path.sourceInfo.adapterId
            SourceId = $path.sourceInfo.id
            TargetAdapter = Convert-LuidToString -Luid $path.targetInfo.adapterId
            TargetId = $path.targetInfo.id
            RefreshRate = Convert-RationalToDouble -Rational $path.targetInfo.refreshRate
            OutputTechnology = $path.targetInfo.outputTechnology
            StateSource = "DxDiagFallback"
            QueryApi = "GET_ADVANCED_COLOR_INFO_2, GET_ADVANCED_COLOR_INFO"
            QueryError = $advancedColorResult
            AdvancedColorInfo2QueryError = $advancedColor2Result
            AdvancedColorSupported = ($dxdiagSummary.AdvancedColor -match 'AdvancedColorSupported')
            AdvancedColorEnabled = ($dxdiagSummary.AdvancedColor -match 'AdvancedColorEnabled')
            HighDynamicRangeSupported = ($dxdiagSummary.HdrSupport -match '^Supported$|HDR Supported')
            HighDynamicRangeUserEnabled = ($dxdiagSummary.ActiveColorMode -match 'HDR')
            WideColorSupported = ($dxdiagSummary.AdvancedColor -match 'WCG|Wide' -or $dxdiagSummary.MonitorCapabilities -match 'BT2020')
            DisplayColorSpace = $dxdiagSummary.DisplayColorSpace
            ActiveColorMode = $dxdiagSummary.ActiveColorMode
            SdrWhiteLevel = $sdrWhiteLevel
            SdrWhiteLevelNits = $sdrWhiteLevelNits
            SdrWhiteLevelQueryError = $sdrWhiteLevelQueryError
            MonitorId = $dxdiagSummary.MonitorId
            MonitorModel = $dxdiagSummary.MonitorModel
            MonitorCapabilities = $dxdiagSummary.MonitorCapabilities
            CurrentMode = $dxdiagSummary.CurrentMode
            NativeMode = $dxdiagSummary.NativeMode
            DisplayLuminance = $dxdiagSummary.DisplayLuminance
            RawFlags = $null
            ColorEncoding = $null
            BitsPerColorChannel = $null
        }
        continue
    }

    [pscustomobject]@{
        PathIndex = $index
        SourceAdapter = Convert-LuidToString -Luid $path.sourceInfo.adapterId
        SourceId = $path.sourceInfo.id
        TargetAdapter = Convert-LuidToString -Luid $path.targetInfo.adapterId
        TargetId = $path.targetInfo.id
        RefreshRate = Convert-RationalToDouble -Rational $path.targetInfo.refreshRate
        OutputTechnology = $path.targetInfo.outputTechnology
        StateSource = "DisplayConfig"
        QueryApi = "GET_ADVANCED_COLOR_INFO"
        QueryError = $advancedColorResult
        RawFlags = ("0x{0:x8}" -f $raw)
        AdvancedColorSupported = (($raw -band 0x1) -ne 0)
        AdvancedColorEnabled = (($raw -band 0x2) -ne 0)
        WideColorEnforced = (($raw -band 0x4) -ne 0)
        AdvancedColorForceDisabled = (($raw -band 0x8) -ne 0)
        AdvancedColorInfo2QueryError = $advancedColor2Result
        ColorEncoding = $request.colorEncoding
        BitsPerColorChannel = $request.bitsPerColorChannel
        SdrWhiteLevel = $sdrWhiteLevel
        SdrWhiteLevelNits = $sdrWhiteLevelNits
        SdrWhiteLevelQueryError = $sdrWhiteLevelQueryError
    }
}

if ($IncludeDxDiag -and -not $SkipDxDiagFallback) {
    $dxdiagSummary = Get-DxDiagDisplaySummary
    if ($dxdiagSummary) {
        [pscustomobject]@{
            PathIndex = $null
            StateSource = "DxDiag"
            QueryApi = "dxdiag /t"
            AdvancedColor = $dxdiagSummary.AdvancedColor
            AdvancedColorSupported = ($dxdiagSummary.AdvancedColor -match 'AdvancedColorSupported')
            AdvancedColorEnabled = ($dxdiagSummary.AdvancedColor -match 'AdvancedColorEnabled')
            HighDynamicRangeSupported = ($dxdiagSummary.HdrSupport -match '^Supported$|HDR Supported')
            HighDynamicRangeUserEnabled = ($dxdiagSummary.ActiveColorMode -match 'HDR')
            DisplayColorSpace = $dxdiagSummary.DisplayColorSpace
            ActiveColorMode = $dxdiagSummary.ActiveColorMode
            HdrSupport = $dxdiagSummary.HdrSupport
            MonitorId = $dxdiagSummary.MonitorId
            MonitorName = $dxdiagSummary.MonitorName
            MonitorModel = $dxdiagSummary.MonitorModel
            MonitorCapabilities = $dxdiagSummary.MonitorCapabilities
            CurrentMode = $dxdiagSummary.CurrentMode
            NativeMode = $dxdiagSummary.NativeMode
            DisplayLuminance = $dxdiagSummary.DisplayLuminance
        }
    }
    else {
        Write-Warning "DxDiag summary was requested but no matching Studio Display section was found."
    }
}
