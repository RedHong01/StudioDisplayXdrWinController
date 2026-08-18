[CmdletBinding()]
param(
    [string]$InstallRoot = $PSScriptRoot,
    [int]$SafeSdrWhiteNits = 240,
    [int]$TriggerWindowSeconds = 25,
    [int]$MaxCaptureWaitSeconds = 15,
    [int]$PrintScreenWaitSeconds = 5,
    [int]$PollMilliseconds = 750,
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$advancedColorScript = Join-Path $InstallRoot "Get-StudioDisplayAdvancedColorState.ps1"
$logPath = Join-Path $InstallRoot "SystemBrightnessMirror.log"
$pidPath = Join-Path $InstallRoot "HdrScreenshotGuard.pid"
$mutexName = "StudioDisplayHdrScreenshotGuard"
$powershellExe = if (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")) { Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe" } else { Join-Path $PSHOME "powershell.exe" }

function Write-GuardLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $logPath -Value "$timestamp HDR screenshot guard: $Message" -ErrorAction SilentlyContinue
}

Add-Type -ReferencedAssemblies @("System.Drawing.dll", "System.Windows.Forms.dll") -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class StudioDisplayClipboardNative {
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}

public static class StudioDisplayScreenshotHotkeyNative {
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int VK_SNAPSHOT = 0x2C;
    private const int VK_S = 0x53;
    private const int VK_SHIFT = 0x10;
    private const int VK_LSHIFT = 0xA0;
    private const int VK_RSHIFT = 0xA1;
    private const int VK_LWIN = 0x5B;
    private const int VK_RWIN = 0x5C;
    private const int VK_MENU = 0x12;
    private const int VK_ESCAPE = 0x1B;

    public static long LastScreenshotHotkeyTicksUtc = 0;
    public static long LastScreenshotCancelTicksUtc = 0;
    public static string LastScreenshotHotkeyName = "";
    public static bool Installed = false;

    private static LowLevelKeyboardProc proc = HookCallback;
    private static IntPtr hookId = IntPtr.Zero;

    public static bool Install() {
        if (hookId != IntPtr.Zero) {
            Installed = true;
            return true;
        }

        using (Process currentProcess = Process.GetCurrentProcess())
        using (ProcessModule currentModule = currentProcess.MainModule) {
            hookId = SetWindowsHookEx(WH_KEYBOARD_LL, proc, GetModuleHandle(currentModule.ModuleName), 0);
        }

        Installed = hookId != IntPtr.Zero;
        return Installed;
    }

    public static void Uninstall() {
        if (hookId != IntPtr.Zero) {
            UnhookWindowsHookEx(hookId);
            hookId = IntPtr.Zero;
        }
        Installed = false;
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && (wParam == (IntPtr)WM_KEYDOWN || wParam == (IntPtr)WM_SYSKEYDOWN)) {
            KBDLLHOOKSTRUCT info = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            int vk = (int)info.vkCode;
            bool shiftDown = IsKeyDown(VK_SHIFT) || IsKeyDown(VK_LSHIFT) || IsKeyDown(VK_RSHIFT);
            bool winDown = IsKeyDown(VK_LWIN) || IsKeyDown(VK_RWIN);
            bool altDown = IsKeyDown(VK_MENU);

            if (vk == VK_SNAPSHOT) {
                MarkScreenshotHotkey(altDown ? "Alt+PrintScreen" : "PrintScreen");
            }
            else if (vk == VK_S && shiftDown && winDown) {
                MarkScreenshotHotkey("Win+Shift+S");
            }
            else if (vk == VK_ESCAPE) {
                LastScreenshotCancelTicksUtc = DateTime.UtcNow.Ticks;
            }
        }

        return CallNextHookEx(hookId, nCode, wParam, lParam);
    }

    private static void MarkScreenshotHotkey(string name) {
        LastScreenshotHotkeyTicksUtc = DateTime.UtcNow.Ticks;
        LastScreenshotHotkeyName = name;
    }

    private static bool IsKeyDown(int virtualKey) {
        return (GetAsyncKeyState(virtualKey) & 0x8000) != 0;
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
}

public static class StudioDisplayScreenshotToneMapper {
    public static Bitmap ApplyUiScreenshotToneMap(Image image, double contrastBoost, int whiteFloor) {
        Bitmap source = new Bitmap(image);
        Bitmap bitmap = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(bitmap)) {
            graphics.DrawImage(source, 0, 0, source.Width, source.Height);
        }
        source.Dispose();

        Rectangle rect = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        BitmapData data = bitmap.LockBits(rect, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        try {
            int stride = data.Stride;
            int bytes = Math.Abs(stride) * bitmap.Height;
            byte[] buffer = new byte[bytes];
            Marshal.Copy(data.Scan0, buffer, 0, bytes);

            for (int y = 0; y < bitmap.Height; y++) {
                int row = y * stride;
                if (stride < 0) {
                    row = (bitmap.Height - 1 - y) * Math.Abs(stride);
                }

                for (int x = 0; x < bitmap.Width; x++) {
                    int index = row + (x * 4);
                    byte b = buffer[index + 0];
                    byte g = buffer[index + 1];
                    byte r = buffer[index + 2];
                    byte a = buffer[index + 3];

                    if (a == 0) {
                        continue;
                    }

                    bool nearWhite = r >= whiteFloor && g >= whiteFloor && b >= whiteFloor;
                    if (nearWhite) {
                        continue;
                    }

                    buffer[index + 0] = ExpandDistanceFromWhite(b, contrastBoost);
                    buffer[index + 1] = ExpandDistanceFromWhite(g, contrastBoost);
                    buffer[index + 2] = ExpandDistanceFromWhite(r, contrastBoost);
                }
            }

            Marshal.Copy(buffer, 0, data.Scan0, bytes);
        }
        finally {
            bitmap.UnlockBits(data);
        }

        return bitmap;
    }

    public static double MeanLuma(Image image, int step) {
        using (Bitmap bitmap = new Bitmap(image)) {
            if (step < 1) {
                step = 1;
            }

            double sum = 0.0;
            long count = 0;
            for (int y = 0; y < bitmap.Height; y += step) {
                for (int x = 0; x < bitmap.Width; x += step) {
                    Color c = bitmap.GetPixel(x, y);
                    sum += 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B;
                    count++;
                }
            }

            return count == 0 ? 0.0 : sum / count;
        }
    }

    private static byte ExpandDistanceFromWhite(byte value, double contrastBoost) {
        double distance = 255.0 - value;
        double mapped = 255.0 - (distance * contrastBoost);
        if (mapped < 0.0) {
            mapped = 0.0;
        }
        if (mapped > 255.0) {
            mapped = 255.0;
        }

        return (byte)Math.Round(mapped);
    }
}

public static class StudioDisplaySdrWhiteLevelNative {
    public const UInt32 QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO_2 = 15;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL = 11;
    public const UInt32 DISPLAYCONFIG_DEVICE_INFO_SET_SDR_WHITE_LEVEL = 0xFFFFFFEE;

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
        ref DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 requestPacket);

    [DllImport("user32.dll")]
    public static extern Int32 DisplayConfigGetDeviceInfo(
        ref DISPLAYCONFIG_SDR_WHITE_LEVEL requestPacket);

    [DllImport("user32.dll")]
    public static extern Int32 DisplayConfigSetDeviceInfo(
        ref DISPLAYCONFIG_SET_SDR_WHITE_LEVEL requestPacket);

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

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SET_SDR_WHITE_LEVEL {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public UInt32 SDRWhiteLevel;
        public Byte finalValue;
    }

    public struct SdrWhiteSetResult {
        public Int32 PathIndex;
        public Int32 QueryAdvancedColorResult;
        public Int32 QuerySdrWhiteResult;
        public Int32 SetSdrWhiteResult;
        public Boolean HdrActive;
        public UInt32 PreviousSdrWhiteLevel;
        public UInt32 TargetSdrWhiteLevel;
    }

    public static SdrWhiteSetResult[] SetHdrActiveTargets(Int32 targetNits, Boolean onlyLower) {
        UInt32 pathCount;
        UInt32 modeCount;
        Int32 result = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
        if (result != 0) {
            return new SdrWhiteSetResult[] { NewErrorResult(-1, result, -1, -1) };
        }

        DISPLAYCONFIG_PATH_INFO[] paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        DISPLAYCONFIG_MODE_INFO[] modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
        result = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        if (result != 0) {
            return new SdrWhiteSetResult[] { NewErrorResult(-1, result, -1, -1) };
        }

        UInt32 targetLevel = NitsToSdrWhiteLevel(targetNits);
        SdrWhiteSetResult[] output = new SdrWhiteSetResult[pathCount];
        for (Int32 i = 0; i < pathCount; i++) {
            DISPLAYCONFIG_PATH_INFO path = paths[i];
            DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 color = NewAdvancedColorRequest(path);
            Int32 colorResult = DisplayConfigGetDeviceInfo(ref color);
            Boolean hdrActive = colorResult == 0 && (((color.value & 0x20) != 0) || color.activeColorMode == 2);

            DISPLAYCONFIG_SDR_WHITE_LEVEL current = NewSdrWhiteRequest(path);
            Int32 currentResult = DisplayConfigGetDeviceInfo(ref current);
            Int32 setResult = -2;

            if (hdrActive && currentResult == 0 && (!onlyLower || current.SDRWhiteLevel > targetLevel)) {
                DISPLAYCONFIG_SET_SDR_WHITE_LEVEL setPacket = NewSetSdrWhiteRequest(path, targetLevel);
                setResult = DisplayConfigSetDeviceInfo(ref setPacket);
            }

            output[i] = new SdrWhiteSetResult {
                PathIndex = i,
                QueryAdvancedColorResult = colorResult,
                QuerySdrWhiteResult = currentResult,
                SetSdrWhiteResult = setResult,
                HdrActive = hdrActive,
                PreviousSdrWhiteLevel = currentResult == 0 ? current.SDRWhiteLevel : 0,
                TargetSdrWhiteLevel = targetLevel
            };
        }

        return output;
    }

    public static Double SdrWhiteLevelToNits(UInt32 level) {
        return ((Double)level / 1000.0) * 80.0;
    }

    private static UInt32 NitsToSdrWhiteLevel(Int32 nits) {
        if (nits < 80) {
            nits = 80;
        }

        return (UInt32)Math.Round(((Double)nits / 80.0) * 1000.0);
    }

    private static SdrWhiteSetResult NewErrorResult(Int32 pathIndex, Int32 colorResult, Int32 currentResult, Int32 setResult) {
        return new SdrWhiteSetResult {
            PathIndex = pathIndex,
            QueryAdvancedColorResult = colorResult,
            QuerySdrWhiteResult = currentResult,
            SetSdrWhiteResult = setResult,
            HdrActive = false,
            PreviousSdrWhiteLevel = 0,
            TargetSdrWhiteLevel = 0
        };
    }

    private static DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 NewAdvancedColorRequest(DISPLAYCONFIG_PATH_INFO path) {
        DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2 request = new DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2();
        request.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO_2;
        request.header.size = (UInt32)Marshal.SizeOf(typeof(DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO_2));
        request.header.adapterId = path.targetInfo.adapterId;
        request.header.id = path.targetInfo.id;
        return request;
    }

    private static DISPLAYCONFIG_SDR_WHITE_LEVEL NewSdrWhiteRequest(DISPLAYCONFIG_PATH_INFO path) {
        DISPLAYCONFIG_SDR_WHITE_LEVEL request = new DISPLAYCONFIG_SDR_WHITE_LEVEL();
        request.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL;
        request.header.size = (UInt32)Marshal.SizeOf(typeof(DISPLAYCONFIG_SDR_WHITE_LEVEL));
        request.header.adapterId = path.targetInfo.adapterId;
        request.header.id = path.targetInfo.id;
        return request;
    }

    private static DISPLAYCONFIG_SET_SDR_WHITE_LEVEL NewSetSdrWhiteRequest(DISPLAYCONFIG_PATH_INFO path, UInt32 level) {
        DISPLAYCONFIG_SET_SDR_WHITE_LEVEL request = new DISPLAYCONFIG_SET_SDR_WHITE_LEVEL();
        request.header.type = DISPLAYCONFIG_DEVICE_INFO_SET_SDR_WHITE_LEVEL;
        request.header.size = (UInt32)Marshal.SizeOf(typeof(DISPLAYCONFIG_SET_SDR_WHITE_LEVEL));
        request.header.adapterId = path.targetInfo.adapterId;
        request.header.id = path.targetInfo.id;
        request.SDRWhiteLevel = level;
        request.finalValue = 1;
        return request;
    }
}
"@

function Get-HdrScreenshotGuardDisplayState {
    $result = [pscustomobject]@{
        Known = $false
        HdrActive = $false
        SdrWhiteNits = $null
        Raw = ""
    }

    if (-not (Test-Path -LiteralPath $advancedColorScript)) {
        return $result
    }

    try {
        $stateText = (@(& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $advancedColorScript -SkipDxDiagFallback 2>&1) -join "`n")
        $result.Raw = $stateText
        $result.Known = $true
        $result.HdrActive = [bool]($stateText -match '(?m)^\s*ActiveColorMode\s*:\s*DISPLAYCONFIG_ADVANCED_COLOR_MODE_HDR\s*$')
        if ($stateText -match '(?m)^\s*SdrWhiteLevelNits\s*:\s*([0-9.]+)\s*$') {
            $result.SdrWhiteNits = [double]$Matches[1]
        }
    }
    catch {
        Write-GuardLog "advanced color probe failed: $($_.Exception.Message)"
    }

    return $result
}

function Get-LastScreenshotHotkeyInfo {
    $ticks = [StudioDisplayScreenshotHotkeyNative]::LastScreenshotHotkeyTicksUtc
    if ($ticks -le 0) {
        return [pscustomobject]@{
            Seen = $false
            AgeSeconds = [double]::PositiveInfinity
            Name = ""
        }
    }

    $last = [DateTime]::SpecifyKind([DateTime]::new($ticks), [DateTimeKind]::Utc).ToLocalTime()
    return [pscustomobject]@{
        Seen = $true
        AgeSeconds = ((Get-Date) - $last).TotalSeconds
        Name = [StudioDisplayScreenshotHotkeyNative]::LastScreenshotHotkeyName
    }
}

function Get-ScreenshotToneMapBoost {
    param(
        [double]$CurrentSdrWhiteNits,
        [int]$TargetSdrWhiteNits
    )

    if ($CurrentSdrWhiteNits -le 0 -or $TargetSdrWhiteNits -le 0) {
        return 1.0
    }

    $boost = $CurrentSdrWhiteNits / [double]$TargetSdrWhiteNits
    if ($boost -lt 1.10) {
        $boost = 1.10
    }
    if ($boost -gt 2.20) {
        $boost = 2.20
    }

    return $boost
}

function Convert-SdrWhiteLevelToNits {
    param([UInt32]$Level)

    return [Math]::Round([StudioDisplaySdrWhiteLevelNative]::SdrWhiteLevelToNits($Level), 1)
}

function Invoke-SdrWhiteLevelSet {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TargetNits,
        [switch]$OnlyLower
    )

    try {
        return @([StudioDisplaySdrWhiteLevelNative]::SetHdrActiveTargets($TargetNits, [bool]$OnlyLower))
    }
    catch {
        Write-GuardLog "SDR white set call failed: $($_.Exception.Message)"
        return @()
    }
}

function Start-ScreenshotSafeSdrWhite {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HotkeyInfo
    )

    if (-not $HotkeyInfo.Seen -or $HotkeyInfo.AgeSeconds -gt 2.5) {
        return $false
    }

    $ticks = [StudioDisplayScreenshotHotkeyNative]::LastScreenshotHotkeyTicksUtc
    if ($script:lastPreparedHotkeyTicks -eq $ticks) {
        return $script:sdrWhiteTemporarilyLowered
    }
    $script:lastPreparedHotkeyTicks = $ticks

    $state = Get-HdrScreenshotGuardDisplayState
    $script:displayState = $state
    $script:lastDisplayStateProbeAt = Get-Date

    if (-not $state.HdrActive) {
        return $false
    }

    if ($null -eq $state.SdrWhiteNits -or $state.SdrWhiteNits -le $SafeSdrWhiteNits) {
        return $false
    }

    $setResults = Invoke-SdrWhiteLevelSet -TargetNits $SafeSdrWhiteNits -OnlyLower
    $successful = @($setResults | Where-Object { $_.HdrActive -and $_.QuerySdrWhiteResult -eq 0 -and $_.SetSdrWhiteResult -eq 0 })
    if (-not $successful) {
        $details = (($setResults | ForEach-Object {
            "path=$($_.PathIndex),hdr=$($_.HdrActive),queryColor=$($_.QueryAdvancedColorResult),querySdr=$($_.QuerySdrWhiteResult),set=$($_.SetSdrWhiteResult),prev=$($_.PreviousSdrWhiteLevel),target=$($_.TargetSdrWhiteLevel)"
        }) -join "; ")
        Write-GuardLog "pre-capture SDR white lowering did not apply for $($HotkeyInfo.Name). details=$details"
        return $false
    }

    $previousNits = Convert-SdrWhiteLevelToNits -Level ([UInt32]($successful | Select-Object -First 1).PreviousSdrWhiteLevel)
    $script:sdrWhiteRestoreNits = [int][Math]::Round($previousNits)
    $script:sdrWhiteTemporarilyLowered = $true
    $waitSeconds = if ($HotkeyInfo.Name -eq "Win+Shift+S") { $MaxCaptureWaitSeconds } else { $PrintScreenWaitSeconds }
    $script:sdrWhiteRestoreDueAt = (Get-Date).AddSeconds([Math]::Max(2, $waitSeconds))
    Write-GuardLog "pre-capture SDR white lowered for $($HotkeyInfo.Name): $previousNits nits -> $SafeSdrWhiteNits nits; restore deadline=$($script:sdrWhiteRestoreDueAt.ToString('HH:mm:ss'))."
    return $true
}

function Test-ScreenshotCancelledAfterPrepare {
    if (-not $script:sdrWhiteTemporarilyLowered -or $script:lastPreparedHotkeyTicks -le 0) {
        return $false
    }

    $cancelTicks = [StudioDisplayScreenshotHotkeyNative]::LastScreenshotCancelTicksUtc
    return [bool]($cancelTicks -gt $script:lastPreparedHotkeyTicks)
}

function Restore-ScreenshotSdrWhite {
    param([string]$Reason = "screenshot complete")

    if (-not $script:sdrWhiteTemporarilyLowered -or -not $script:sdrWhiteRestoreNits) {
        return $false
    }

    $target = [int]$script:sdrWhiteRestoreNits
    $restoreResults = Invoke-SdrWhiteLevelSet -TargetNits $target
    $successful = @($restoreResults | Where-Object { $_.HdrActive -and $_.SetSdrWhiteResult -eq 0 })
    if ($successful) {
        Write-GuardLog "restored SDR white after ${Reason}: target=$target nits."
        $script:sdrWhiteTemporarilyLowered = $false
        $script:sdrWhiteRestoreNits = $null
        $script:sdrWhiteRestoreDueAt = [DateTime]::MinValue
        $script:displayState = Get-HdrScreenshotGuardDisplayState
        $script:lastDisplayStateProbeAt = Get-Date
        return $true
    }

    $details = (($restoreResults | ForEach-Object {
        "path=$($_.PathIndex),hdr=$($_.HdrActive),queryColor=$($_.QueryAdvancedColorResult),querySdr=$($_.QuerySdrWhiteResult),set=$($_.SetSdrWhiteResult),prev=$($_.PreviousSdrWhiteLevel),target=$($_.TargetSdrWhiteLevel)"
    }) -join "; ")
    Write-GuardLog "failed to restore SDR white after $Reason. target=$target nits details=$details"
    return $false
}

function Repair-ClipboardScreenshotIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$DisplayState,
        [Parameter(Mandatory = $true)]
        [pscustomobject]$HotkeyInfo,
        [switch]$PreCaptureSdrWhiteLowered
    )

    if ($PreCaptureSdrWhiteLowered) {
        Write-GuardLog "clipboard screenshot captured after pre-capture SDR white lowering; skipped post tone-map to avoid double-processing."
        return $false
    }

    if (-not $DisplayState.HdrActive) {
        return $false
    }

    if ($null -eq $DisplayState.SdrWhiteNits -or $DisplayState.SdrWhiteNits -le $SafeSdrWhiteNits) {
        return $false
    }

    if (-not $HotkeyInfo.Seen -or $HotkeyInfo.AgeSeconds -gt $TriggerWindowSeconds) {
        return $false
    }

    if (-not [System.Windows.Forms.Clipboard]::ContainsImage()) {
        return $false
    }

    $image = $null
    $fixed = $null
    try {
        $image = [System.Windows.Forms.Clipboard]::GetImage()
        if (-not $image) {
            return $false
        }

        if ($image.Width -lt 200 -or $image.Height -lt 120) {
            return $false
        }

        $sampleStep = [Math]::Max(1, [Math]::Min($image.Width, $image.Height) / 80)
        $beforeLuma = [StudioDisplayScreenshotToneMapper]::MeanLuma($image, [int]$sampleStep)
        $boost = Get-ScreenshotToneMapBoost -CurrentSdrWhiteNits $DisplayState.SdrWhiteNits -TargetSdrWhiteNits $SafeSdrWhiteNits
        $fixed = [StudioDisplayScreenshotToneMapper]::ApplyUiScreenshotToneMap($image, $boost, 248)
        $afterLuma = [StudioDisplayScreenshotToneMapper]::MeanLuma($fixed, [int]$sampleStep)

        [System.Windows.Forms.Clipboard]::SetImage($fixed)
        $script:ignoreNextClipboardSequence = $true
        Write-GuardLog ("optimized clipboard screenshot from {0}; size={1}x{2}; sdrWhite={3}nits target={4}nits boost={5:n2}; meanLuma {6:n1}->{7:n1}" -f $HotkeyInfo.Name, $image.Width, $image.Height, $DisplayState.SdrWhiteNits, $SafeSdrWhiteNits, $boost, $beforeLuma, $afterLuma)
        return $true
    }
    catch {
        Write-GuardLog "clipboard screenshot optimization failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($image) {
            $image.Dispose()
        }
        if ($fixed) {
            $fixed.Dispose()
        }
    }
}

if ($SelfTest) {
    $state = Get-HdrScreenshotGuardDisplayState
    $setProbe = @()
    $restoreProbe = @()
    if ($state.HdrActive -and $state.SdrWhiteNits -gt $SafeSdrWhiteNits) {
        $setProbe = Invoke-SdrWhiteLevelSet -TargetNits $SafeSdrWhiteNits -OnlyLower
        Start-Sleep -Milliseconds 300
        $restoreProbe = Invoke-SdrWhiteLevelSet -TargetNits ([int][Math]::Round($state.SdrWhiteNits))
    }
    [pscustomobject]@{
        HotkeyHookTypeReady = ([type]"StudioDisplayScreenshotHotkeyNative" -ne $null)
        ClipboardSequence = [StudioDisplayClipboardNative]::GetClipboardSequenceNumber()
        HdrActive = $state.HdrActive
        SdrWhiteNits = $state.SdrWhiteNits
        SafeSdrWhiteNits = $SafeSdrWhiteNits
        SdrWhiteSetProbe = (($setProbe | ForEach-Object { "path=$($_.PathIndex),hdr=$($_.HdrActive),querySdr=$($_.QuerySdrWhiteResult),set=$($_.SetSdrWhiteResult),prev=$($_.PreviousSdrWhiteLevel),target=$($_.TargetSdrWhiteLevel)" }) -join "; ")
        SdrWhiteRestoreProbe = (($restoreProbe | ForEach-Object { "path=$($_.PathIndex),hdr=$($_.HdrActive),querySdr=$($_.QuerySdrWhiteResult),set=$($_.SetSdrWhiteResult),prev=$($_.PreviousSdrWhiteLevel),target=$($_.TargetSdrWhiteLevel)" }) -join "; ")
    }
    exit 0
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

$context = $null
$timer = $null
$lastClipboardSequence = [StudioDisplayClipboardNative]::GetClipboardSequenceNumber()
$lastDisplayStateProbeAt = [DateTime]::MinValue
$displayState = [pscustomobject]@{
    Known = $false
    HdrActive = $false
    SdrWhiteNits = $null
    Raw = ""
}
$ignoreNextClipboardSequence = $false
$lastPreparedHotkeyTicks = 0
$sdrWhiteTemporarilyLowered = $false
$sdrWhiteRestoreNits = $null
$sdrWhiteRestoreDueAt = [DateTime]::MinValue

try {
    Set-Content -LiteralPath $pidPath -Value $PID -Encoding ascii -ErrorAction Stop
    Write-GuardLog "started with PID $PID."

    if (-not [StudioDisplayScreenshotHotkeyNative]::Install()) {
        Write-GuardLog "low-level screenshot hotkey hook could not be installed; clipboard guard will stay running but only hotkey-marked screenshots can be optimized."
    }
    else {
        Write-GuardLog "low-level screenshot hotkey hook installed."
    }

    $context = New-Object System.Windows.Forms.ApplicationContext
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(250, $PollMilliseconds)
    $timer.add_Tick({
        try {
            $now = Get-Date
            if ($script:sdrWhiteTemporarilyLowered -and (Test-ScreenshotCancelledAfterPrepare)) {
                Restore-ScreenshotSdrWhite -Reason "screenshot cancelled with Esc" | Out-Null
            }
            elseif ($script:sdrWhiteTemporarilyLowered -and $script:sdrWhiteRestoreDueAt -ne [DateTime]::MinValue -and $now -ge $script:sdrWhiteRestoreDueAt) {
                Restore-ScreenshotSdrWhite -Reason "screenshot timeout without clipboard image" | Out-Null
            }

            if (($now - $script:lastDisplayStateProbeAt).TotalSeconds -ge 20) {
                $script:displayState = Get-HdrScreenshotGuardDisplayState
                $script:lastDisplayStateProbeAt = $now
            }

            $hotkeyInfo = Get-LastScreenshotHotkeyInfo
            $preCaptureLowered = Start-ScreenshotSafeSdrWhite -HotkeyInfo $hotkeyInfo
            $sequence = [StudioDisplayClipboardNative]::GetClipboardSequenceNumber()
            if ($sequence -ne $script:lastClipboardSequence) {
                $script:lastClipboardSequence = $sequence
                if ($script:ignoreNextClipboardSequence) {
                    $script:ignoreNextClipboardSequence = $false
                    return
                }

                Repair-ClipboardScreenshotIfNeeded -DisplayState $script:displayState -HotkeyInfo $hotkeyInfo -PreCaptureSdrWhiteLowered:$preCaptureLowered | Out-Null
                if ($script:sdrWhiteTemporarilyLowered) {
                    Restore-ScreenshotSdrWhite -Reason "clipboard image ready" | Out-Null
                }
            }
        }
        catch {
            Write-GuardLog "timer tick failed: $($_.Exception.Message)"
        }
    })

    $timer.Start()
    [System.Windows.Forms.Application]::Run($context)
}
finally {
    Write-GuardLog "stopped."

    if ($timer) {
        $timer.Stop()
        $timer.Dispose()
    }

    [StudioDisplayScreenshotHotkeyNative]::Uninstall()
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue

    if ($mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
