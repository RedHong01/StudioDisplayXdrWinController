[CmdletBinding()]
param(
    [switch]$Enable,
    [switch]$Disable,
    [switch]$EnableAdvancedColorFallback,
    [switch]$ForcePacketWhenUnsupported,
    [switch]$SkipVerification
)

$ErrorActionPreference = "Stop"

if (-not $Enable -and -not $Disable) {
    $Enable = $true
}

if ($Enable -and $Disable) {
    throw "Use either -Enable or -Disable, not both."
}

$scriptRoot = $PSScriptRoot
$advancedColorProbe = Join-Path $scriptRoot "Get-StudioDisplayAdvancedColorState.ps1"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class StudioDisplayHdrStateNative {
    public const UInt32 QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE = 10;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_SET_HDR_STATE = 16;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_SET_WCG_STATE = 17;

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
    public static extern Int32 DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE requestPacket);

    [DllImport("user32.dll")]
    public static extern Int32 DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SET_HDR_STATE requestPacket);

    [DllImport("user32.dll")]
    public static extern Int32 DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SET_WCG_STATE requestPacket);

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
    public struct DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public UInt32 enableAdvancedColor;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SET_HDR_STATE {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public UInt32 enableHdr;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SET_WCG_STATE {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public UInt32 enableWcg;
    }

    public static DISPLAYCONFIG_PATH_INFO[] QueryActivePaths(out Int32 error) {
        UInt32 pathCount;
        UInt32 modeCount;
        error = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
        if (error != 0) {
            return new DISPLAYCONFIG_PATH_INFO[0];
        }

        DISPLAYCONFIG_PATH_INFO[] paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        DISPLAYCONFIG_MODE_INFO[] modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
        error = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        if (error != 0) {
            return new DISPLAYCONFIG_PATH_INFO[0];
        }

        return paths;
    }

    public static Int32 SetAdvancedColor(DISPLAYCONFIG_PATH_INFO path, Boolean enabled, out UInt32 packetSize) {
        DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE packet = new DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE();
        packet.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_ADVANCED_COLOR_STATE;
        packet.header.size = (UInt32)Marshal.SizeOf(typeof(DISPLAYCONFIG_SET_ADVANCED_COLOR_STATE));
        packet.header.adapterId = path.targetInfo.adapterId;
        packet.header.id = path.targetInfo.id;
        packet.enableAdvancedColor = enabled ? 1U : 0U;
        packetSize = packet.header.size;
        return DisplayConfigSetDeviceInfo(ref packet);
    }

    public static Int32 SetHdr(DISPLAYCONFIG_PATH_INFO path, Boolean enabled, out UInt32 packetSize) {
        DISPLAYCONFIG_SET_HDR_STATE packet = new DISPLAYCONFIG_SET_HDR_STATE();
        packet.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_HDR_STATE;
        packet.header.size = (UInt32)Marshal.SizeOf(typeof(DISPLAYCONFIG_SET_HDR_STATE));
        packet.header.adapterId = path.targetInfo.adapterId;
        packet.header.id = path.targetInfo.id;
        packet.enableHdr = enabled ? 1U : 0U;
        packetSize = packet.header.size;
        return DisplayConfigSetDeviceInfo(ref packet);
    }

    public static Int32 SetWcg(DISPLAYCONFIG_PATH_INFO path, Boolean enabled, out UInt32 packetSize) {
        DISPLAYCONFIG_SET_WCG_STATE packet = new DISPLAYCONFIG_SET_WCG_STATE();
        packet.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_WCG_STATE;
        packet.header.size = (UInt32)Marshal.SizeOf(typeof(DISPLAYCONFIG_SET_WCG_STATE));
        packet.header.adapterId = path.targetInfo.adapterId;
        packet.header.id = path.targetInfo.id;
        packet.enableWcg = enabled ? 1U : 0U;
        packetSize = packet.header.size;
        return DisplayConfigSetDeviceInfo(ref packet);
    }
}
"@

function Convert-LuidToString {
    param([StudioDisplayHdrStateNative+LUID]$Luid)

    return ("{0:x8}:{1:x8}" -f $Luid.HighPart, $Luid.LowPart)
}

function Invoke-AdvancedColorProbe {
    if (-not (Test-Path -LiteralPath $advancedColorProbe)) {
        return $null
    }

    try {
        return @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $advancedColorProbe -IncludeDxDiag 2>$null)
    }
    catch {
        return $null
    }
}

function Convert-Win32ResultName {
    param([AllowNull()][object]$Code)

    if ($null -eq $Code) {
        return $null
    }

    switch ([int]$Code) {
        0 { return "ERROR_SUCCESS" }
        5 { return "ERROR_ACCESS_DENIED" }
        31 { return "ERROR_GEN_FAILURE" }
        50 { return "ERROR_NOT_SUPPORTED" }
        87 { return "ERROR_INVALID_PARAMETER" }
        122 { return "ERROR_INSUFFICIENT_BUFFER" }
        default { return "WIN32_$Code" }
    }
}

function Get-AdvancedColorPreflight {
    $probe = @(Invoke-AdvancedColorProbe)
    if (-not $probe) {
        return [pscustomobject]@{
            Output = @()
            HdrSupportKnown = $false
            HdrSupported = $false
            HdrActive = $false
            WcgActive = $false
        }
    }

    $text = ($probe -join "`n")
    $hdrSupportedTrue = ($text -match 'HighDynamicRangeSupported\s*:\s*True' -or $text -match 'HdrSupport\s*:\s*(Supported|HDR Supported)')
    $hdrSupportedFalse = ($text -match 'HighDynamicRangeSupported\s*:\s*False' -or $text -match 'HdrSupport\s*:\s*Not Supported')
    return [pscustomobject]@{
        Output = $probe
        HdrSupportKnown = [bool]($hdrSupportedTrue -or $hdrSupportedFalse)
        HdrSupported = [bool]$hdrSupportedTrue
        HdrActive = [bool]($text -match 'ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR' -or $text -match 'HighDynamicRangeUserEnabled\s*:\s*True')
        WcgActive = [bool]($text -match 'ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG' -or $text -match 'WideColorUserEnabled\s*:\s*True')
    }
}

$desiredState = [bool]$Enable
$queryError = 0
$paths = @([StudioDisplayHdrStateNative]::QueryActivePaths([ref]$queryError))
if ($queryError -ne 0) {
    throw "QueryDisplayConfig failed with Win32 error $queryError."
}

if (-not $paths) {
    throw "No active display paths were returned by QueryDisplayConfig."
}

$preflight = Get-AdvancedColorPreflight
$skipHdrPacketBecauseUnsupported = [bool](
    $desiredState -and
    $preflight.HdrSupportKnown -and
    -not $preflight.HdrSupported -and
    -not $ForcePacketWhenUnsupported
)

$results = New-Object System.Collections.Generic.List[object]
for ($index = 0; $index -lt $paths.Count; $index++) {
    $path = $paths[$index]
    $hdrPacketSize = 0
    $advancedPacketSize = 0
    $wcgPacketSize = 0
    $hdrResult = $null
    $advancedResult = $null
    $wcgResult = $null
    $skippedReason = $null

    if ($skipHdrPacketBecauseUnsupported) {
        $skippedReason = "DisplayConfig reports HighDynamicRangeSupported=False on the active target path; skipping SET_HDR_STATE to avoid a known ERROR_NOT_SUPPORTED packet rejection."
        if ($EnableAdvancedColorFallback) {
            $advancedResult = [StudioDisplayHdrStateNative]::SetAdvancedColor($path, $true, [ref]$advancedPacketSize)
            $wcgResult = [StudioDisplayHdrStateNative]::SetWcg($path, $true, [ref]$wcgPacketSize)
        }
    }
    else {
        $hdrResult = [StudioDisplayHdrStateNative]::SetHdr($path, $desiredState, [ref]$hdrPacketSize)

        if ($hdrResult -ne 0 -and $EnableAdvancedColorFallback) {
            $advancedResult = [StudioDisplayHdrStateNative]::SetAdvancedColor($path, $desiredState, [ref]$advancedPacketSize)
            $wcgResult = [StudioDisplayHdrStateNative]::SetWcg($path, $desiredState, [ref]$wcgPacketSize)
        }
        elseif (-not $desiredState) {
            $advancedResult = [StudioDisplayHdrStateNative]::SetAdvancedColor($path, $false, [ref]$advancedPacketSize)
            $wcgResult = [StudioDisplayHdrStateNative]::SetWcg($path, $false, [ref]$wcgPacketSize)
        }
    }

    $results.Add([pscustomobject]@{
            PathIndex = $index
            TargetAdapter = Convert-LuidToString -Luid $path.targetInfo.adapterId
            TargetId = $path.targetInfo.id
            RequestedState = if ($desiredState) { "Enable" } else { "Disable" }
            PreflightHdrSupported = if ($preflight.HdrSupportKnown) { $preflight.HdrSupported } else { $null }
            PreflightHdrActive = $preflight.HdrActive
            PreflightWcgActive = $preflight.WcgActive
            SkippedReason = $skippedReason
            HdrSetResult = $hdrResult
            HdrSetResultName = Convert-Win32ResultName -Code $hdrResult
            HdrPacketSize = $hdrPacketSize
            AdvancedColorFallbackResult = $advancedResult
            AdvancedColorFallbackResultName = Convert-Win32ResultName -Code $advancedResult
            AdvancedColorPacketSize = $advancedPacketSize
            WcgFallbackResult = $wcgResult
            WcgFallbackResultName = Convert-Win32ResultName -Code $wcgResult
            WcgPacketSize = $wcgPacketSize
        }) | Out-Null
}

$results

$exitCode = 0
if ($desiredState -and $skipHdrPacketBecauseUnsupported) {
    Write-Warning "HDR state request was not sent because Windows reports HighDynamicRangeSupported=False for the active path. This is a capability gate (monitor EDID/driver/reference-mode/link), not a brightness-control conflict."
    if ($EnableAdvancedColorFallback) {
        Write-Warning "WCG fallback was explicitly requested and attempted, but WCG is not HDR."
        $exitCode = 3
    }
    else {
        $exitCode = 4
    }
}
elseif ($desiredState -and @($results | Where-Object { $null -ne $_.HdrSetResult -and $_.HdrSetResult -ne 0 }).Count -gt 0) {
    $failedCodes = (($results | Where-Object { $null -ne $_.HdrSetResult -and $_.HdrSetResult -ne 0 } | Select-Object -ExpandProperty HdrSetResult -Unique) -join ",")
    $failedNames = (($results | Where-Object { $null -ne $_.HdrSetResult -and $_.HdrSetResult -ne 0 } | Select-Object -ExpandProperty HdrSetResultName -Unique) -join ",")
    Write-Warning "HDR state request was rejected by Windows. HdrSetResult=$failedCodes. Do not treat WCG fallback as HDR unless -EnableAdvancedColorFallback was explicitly requested."
    if ($failedNames) {
        Write-Warning "HDR state rejection names: $failedNames"
    }
    $exitCode = 2
}

if (-not $SkipVerification) {
    Start-Sleep -Seconds 2
    $verification = @(Invoke-AdvancedColorProbe)
    if ($verification) {
        Write-Host ""
        Write-Host "Verification:"
        $verification

        $verificationText = $verification -join "`n"
        if ($desiredState -and $verificationText -match 'ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_WCG') {
            Write-Warning "Verification shows WCG active color mode, not HDR. The display path is advanced-color enabled, but Windows did not enter HDR mode."
            if ($exitCode -eq 0) {
                $exitCode = 3
            }
        }

        if ($desiredState -and $verificationText -match 'HighDynamicRangeSupported\s*:\s*False') {
            Write-Warning "Verification shows HighDynamicRangeSupported=False. Windows will not accept SET_HDR_STATE until the active monitor path is re-enumerated as HDR-capable."
            if ($exitCode -eq 0) {
                $exitCode = 4
            }
        }
    }
    else {
        Write-Warning "Could not run advanced color verification probe."
    }
}

exit $exitCode
