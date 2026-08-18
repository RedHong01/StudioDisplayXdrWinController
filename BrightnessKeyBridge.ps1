[CmdletBinding()]
param(
    [switch]$EnableLogging,
    [switch]$VerboseConsumerLog,
    [switch]$CaptureF1F2BrightnessKeys,
    [switch]$SelfTestUp,
    [switch]$SelfTestDown,
    [ValidateRange(1,100)]
    [int]$StepPercent = 10
)

$ErrorActionPreference = "Stop"

$bridgeRoot = $PSScriptRoot
$pidFile = Join-Path $bridgeRoot "BrightnessKeyBridge.pid"
$logPath = Join-Path $bridgeRoot "BrightnessKeyBridge.log"
$mutexName = "StudioDisplayBrightnessKeyBridge"
$coordinationRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\Shared"
$suppressionFile = Join-Path $coordinationRoot "BrightnessKeySuppression.txt"
$hidHelperPath = Join-Path $bridgeRoot "StudioDisplayHid.ps1"

Add-Type -AssemblyName System.Windows.Forms
. $hidHelperPath

function Write-BridgeLog {
    param([string]$Message)

    if (-not $EnableLogging) {
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $logPath -Value "$timestamp $Message"
}

function Sync-ManagedPidFile {
    try {
        $existingPid = $null
        if (Test-Path $pidFile) {
            $existingPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        }

        if ([string]$existingPid -ne [string]$PID) {
            Set-Content -LiteralPath $pidFile -Value $PID -Encoding ascii -ErrorAction Stop
            Write-BridgeLog "Brightness key bridge refreshed managed pid file with PID=$PID."
        }
    }
    catch {
        Write-BridgeLog "Brightness key bridge could not refresh managed pid file: $($_.Exception.Message)"
    }
}

function Get-ClampedPercent {
    param([int]$Value)

    if ($Value -lt 0) { return 0 }
    if ($Value -gt 100) { return 100 }
    return $Value
}

function Apply-BrightnessStep {
    param([bool]$Increase)

    $current = Get-StudioDisplayBrightnessPercent
    $target = if ($Increase) {
        Get-ClampedPercent ($current + $StepPercent)
    } else {
        Get-ClampedPercent ($current - $StepPercent)
    }

    if (-not (Test-Path $coordinationRoot)) {
        New-Item -ItemType Directory -Force -Path $coordinationRoot | Out-Null
    }

    $direction = if ($Increase) { "up" } else { "down" }
    $stamp = [DateTime]::UtcNow.ToString("o")
    Set-Content -LiteralPath $suppressionFile -Value "$stamp|$direction" -Encoding ascii
    Set-StudioDisplayBrightnessPercent -Percent $target
    Write-BridgeLog ("Applied fixed brightness step {0}%: {1}% -> {2}%." -f $StepPercent, $current, $target)
}

$typeDefinition = @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public sealed class BrightnessKeyBridge : NativeWindow, IDisposable
{
    private const int WM_INPUT = 0x00FF;
    private const uint RID_INPUT = 0x10000003;
    private const uint RIDI_PREPARSEDDATA = 0x20000005;
    private const uint RIM_TYPEKEYBOARD = 1;
    private const uint RIM_TYPEHID = 2;
    private const uint RIDEV_INPUTSINK = 0x00000100;
    private const ushort RI_KEY_BREAK = 0x0001;

    private const ushort USAGE_PAGE_GENERIC_DESKTOP = 0x01;
    private const ushort USAGE_KEYBOARD = 0x06;
    private const ushort USAGE_PAGE_CONSUMER = 0x0C;
    private const ushort USAGE_CONSUMER_CONTROL = 0x01;
    private const ushort USAGE_BRIGHTNESS_INCREMENT = 0x006F;
    private const ushort USAGE_BRIGHTNESS_DECREMENT = 0x0070;
    private const ushort VK_F1 = 0x70;
    private const ushort VK_F2 = 0x71;
    private const ushort VK_F14 = 0x7D;
    private const ushort VK_F15 = 0x7E;

    private readonly Dictionary<IntPtr, IntPtr> preparsedDataCache = new Dictionary<IntPtr, IntPtr>();
    private readonly Action<bool> onBrightnessUsage;
    private readonly string logPath;
    private readonly bool loggingEnabled;
    private readonly bool verboseConsumerLog;
    private readonly bool captureF1F2BrightnessKeys;

    private bool consumerIncreaseActive = false;
    private bool consumerDecreaseActive = false;
    private bool keyboardF1Active = false;
    private bool keyboardF2Active = false;
    private bool keyboardF14Active = false;
    private bool keyboardF15Active = false;

    public BrightnessKeyBridge(Action<bool> onBrightnessUsage, string logPath, bool loggingEnabled, bool verboseConsumerLog, bool captureF1F2BrightnessKeys)
    {
        this.onBrightnessUsage = onBrightnessUsage;
        this.logPath = logPath;
        this.loggingEnabled = loggingEnabled;
        this.verboseConsumerLog = verboseConsumerLog;
        this.captureF1F2BrightnessKeys = captureF1F2BrightnessKeys;

        CreateHandle(new CreateParams());
        RegisterRawInput();
        Log("Brightness key bridge started.");
    }

    public void Dispose()
    {
        foreach (IntPtr pointer in preparsedDataCache.Values)
        {
            if (pointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(pointer);
            }
        }

        preparsedDataCache.Clear();

        if (Handle != IntPtr.Zero)
        {
            DestroyHandle();
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_INPUT)
        {
            try
            {
                ProcessRawInput(m.LParam);
            }
            catch (Exception ex)
            {
                Log("Raw input processing error: " + ex.Message);
            }
        }

        base.WndProc(ref m);
    }

    private void RegisterRawInput()
    {
        RAWINPUTDEVICE[] devices = new RAWINPUTDEVICE[]
        {
            new RAWINPUTDEVICE
            {
                usUsagePage = USAGE_PAGE_CONSUMER,
                usUsage = USAGE_CONSUMER_CONTROL,
                dwFlags = RIDEV_INPUTSINK,
                hwndTarget = Handle
            },
            new RAWINPUTDEVICE
            {
                usUsagePage = USAGE_PAGE_GENERIC_DESKTOP,
                usUsage = USAGE_KEYBOARD,
                dwFlags = RIDEV_INPUTSINK,
                hwndTarget = Handle
            }
        };

        if (!RegisterRawInputDevices(devices, (uint)devices.Length, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE))))
        {
            throw new InvalidOperationException("RegisterRawInputDevices failed.");
        }
    }

    private void ProcessRawInput(IntPtr rawInputHandle)
    {
        uint size = 0;
        uint headerSize = (uint)Marshal.SizeOf(typeof(RAWINPUTHEADER));
        uint result = GetRawInputData(rawInputHandle, RID_INPUT, IntPtr.Zero, ref size, headerSize);
        if (result == 0xFFFFFFFF || size == 0)
        {
            return;
        }

        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        try
        {
            result = GetRawInputData(rawInputHandle, RID_INPUT, buffer, ref size, headerSize);
            if (result == 0xFFFFFFFF)
            {
                return;
            }

            RAWINPUTHEADER header = (RAWINPUTHEADER)Marshal.PtrToStructure(buffer, typeof(RAWINPUTHEADER));
            if (header.dwType == RIM_TYPEKEYBOARD)
            {
                IntPtr keyboardPointer = IntPtr.Add(buffer, Marshal.SizeOf(typeof(RAWINPUTHEADER)));
                RAWKEYBOARD keyboard = (RAWKEYBOARD)Marshal.PtrToStructure(keyboardPointer, typeof(RAWKEYBOARD));
                HandleKeyboardUsage(keyboard);
                return;
            }

            if (header.dwType != RIM_TYPEHID)
            {
                return;
            }

            IntPtr hidHeader = IntPtr.Add(buffer, Marshal.SizeOf(typeof(RAWINPUTHEADER)));
            int sizeHid = Marshal.ReadInt32(hidHeader, 0);
            int count = Marshal.ReadInt32(hidHeader, 4);
            IntPtr rawData = IntPtr.Add(hidHeader, 8);
            IntPtr preparsedData = GetPreparsedData(header.hDevice);

            if (preparsedData == IntPtr.Zero || sizeHid <= 0 || count <= 0)
            {
                return;
            }

            for (int index = 0; index < count; index++)
            {
                IntPtr report = IntPtr.Add(rawData, index * sizeHid);
                ushort[] usages = new ushort[16];
                uint usageLength = (uint)usages.Length;

                int status = HidP_GetUsages(
                    HIDP_REPORT_TYPE.HidP_Input,
                    USAGE_PAGE_CONSUMER,
                    0,
                    usages,
                    ref usageLength,
                    preparsedData,
                    report,
                    (uint)sizeHid);

                if (status < 0)
                {
                    continue;
                }

                bool sawBrightnessUsage = false;
                for (int usageIndex = 0; usageIndex < usageLength; usageIndex++)
                {
                    if (HandleConsumerUsage(usages[usageIndex]))
                    {
                        sawBrightnessUsage = true;
                    }
                }

                if (!sawBrightnessUsage)
                {
                    ReleaseConsumerBrightnessKeys();
                }
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private IntPtr GetPreparsedData(IntPtr deviceHandle)
    {
        if (deviceHandle == IntPtr.Zero)
        {
            return IntPtr.Zero;
        }

        IntPtr cached;
        if (preparsedDataCache.TryGetValue(deviceHandle, out cached))
        {
            return cached;
        }

        uint size = 0;
        uint result = GetRawInputDeviceInfo(deviceHandle, RIDI_PREPARSEDDATA, IntPtr.Zero, ref size);
        if (result == 0xFFFFFFFF || size == 0)
        {
            return IntPtr.Zero;
        }

        IntPtr buffer = Marshal.AllocHGlobal((int)size);
        result = GetRawInputDeviceInfo(deviceHandle, RIDI_PREPARSEDDATA, buffer, ref size);
        if (result == 0xFFFFFFFF)
        {
            Marshal.FreeHGlobal(buffer);
            return IntPtr.Zero;
        }

        preparsedDataCache[deviceHandle] = buffer;
        return buffer;
    }

    private bool HandleConsumerUsage(ushort usage)
    {
        if (verboseConsumerLog)
        {
            Log("Consumer usage 0x" + usage.ToString("X4"));
        }

        if (usage == USAGE_BRIGHTNESS_INCREMENT)
        {
            consumerDecreaseActive = false;
            if (!consumerIncreaseActive)
            {
                consumerIncreaseActive = true;
                onBrightnessUsage(true);
                Log("Brightness increment recognized as one 10% press.");
            }
            return true;
        }

        if (usage == USAGE_BRIGHTNESS_DECREMENT)
        {
            consumerIncreaseActive = false;
            if (!consumerDecreaseActive)
            {
                consumerDecreaseActive = true;
                onBrightnessUsage(false);
                Log("Brightness decrement recognized as one 10% press.");
            }
            return true;
        }

        return false;
    }

    private void ReleaseConsumerBrightnessKeys()
    {
        consumerIncreaseActive = false;
        consumerDecreaseActive = false;
    }

    private void HandleKeyboardUsage(RAWKEYBOARD keyboard)
    {
        bool isKeyUp = (keyboard.Flags & RI_KEY_BREAK) == RI_KEY_BREAK;
        if (verboseConsumerLog)
        {
            Log("Keyboard raw input VKey=0x" + keyboard.VKey.ToString("X4") + " MakeCode=0x" + keyboard.MakeCode.ToString("X4") + " Flags=0x" + keyboard.Flags.ToString("X4") + " Message=0x" + keyboard.Message.ToString("X4"));
        }

        if (keyboard.VKey == VK_F14)
        {
            if (isKeyUp)
            {
                keyboardF14Active = false;
                return;
            }

            if (!keyboardF14Active)
            {
                keyboardF14Active = true;
                onBrightnessUsage(false);
                Log("Brightness decrement recognized from keyboard F14 as one 10% press.");
            }
            return;
        }

        if (keyboard.VKey == VK_F15)
        {
            if (isKeyUp)
            {
                keyboardF15Active = false;
                return;
            }

            if (!keyboardF15Active)
            {
                keyboardF15Active = true;
                onBrightnessUsage(true);
                Log("Brightness increment recognized from keyboard F15 as one 10% press.");
            }
            return;
        }

        if (!captureF1F2BrightnessKeys)
        {
            return;
        }

        if (keyboard.VKey == VK_F1)
        {
            if (isKeyUp)
            {
                keyboardF1Active = false;
                return;
            }

            if (!keyboardF1Active)
            {
                keyboardF1Active = true;
                onBrightnessUsage(false);
                Log("Brightness decrement recognized from keyboard F1 as one 10% press.");
            }
            return;
        }

        if (keyboard.VKey == VK_F2)
        {
            if (isKeyUp)
            {
                keyboardF2Active = false;
                return;
            }

            if (!keyboardF2Active)
            {
                keyboardF2Active = true;
                onBrightnessUsage(true);
                Log("Brightness increment recognized from keyboard F2 as one 10% press.");
            }
        }
    }

    private void Log(string message)
    {
        if (!loggingEnabled)
        {
            return;
        }

        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine;
        File.AppendAllText(logPath, line);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTDEVICE
    {
        public ushort usUsagePage;
        public ushort usUsage;
        public uint dwFlags;
        public IntPtr hwndTarget;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWINPUTHEADER
    {
        public uint dwType;
        public uint dwSize;
        public IntPtr hDevice;
        public IntPtr wParam;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RAWKEYBOARD
    {
        public ushort MakeCode;
        public ushort Flags;
        public ushort Reserved;
        public ushort VKey;
        public uint Message;
        public uint ExtraInformation;
    }

    private enum HIDP_REPORT_TYPE
    {
        HidP_Input = 0,
        HidP_Output = 1,
        HidP_Feature = 2
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterRawInputDevices(
        [In] RAWINPUTDEVICE[] pRawInputDevices,
        uint uiNumDevices,
        uint cbSize);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputData(
        IntPtr hRawInput,
        uint uiCommand,
        IntPtr pData,
        ref uint pcbSize,
        uint cbSizeHeader);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetRawInputDeviceInfo(
        IntPtr hDevice,
        uint uiCommand,
        IntPtr pData,
        ref uint pcbSize);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern int HidP_GetUsages(
        HIDP_REPORT_TYPE ReportType,
        ushort UsagePage,
        ushort LinkCollection,
        [Out] ushort[] UsageList,
        ref uint UsageLength,
        IntPtr PreparsedData,
        IntPtr Report,
        uint ReportLength);
}
"@

Add-Type -TypeDefinition $typeDefinition -ReferencedAssemblies @("System.Windows.Forms.dll")

if ($SelfTestUp -or $SelfTestDown) {
    Apply-BrightnessStep -Increase:$SelfTestUp
    exit 0
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-BridgeLog "Another brightness key bridge instance is already running; exiting this duplicate instance."
    exit 2
}

Set-Content -LiteralPath $pidFile -Value $PID -Encoding ascii

try {
    $callback = [System.Action[bool]]{
        param($increase)
        try {
            Apply-BrightnessStep -Increase:$increase
        }
        catch {
            Write-BridgeLog ("Brightness step error: " + $_.Exception.Message)
        }
    }

    $pidRefreshTimer = New-Object System.Windows.Forms.Timer
    $pidRefreshTimer.Interval = 5000
    $pidRefreshTimer.add_Tick({ Sync-ManagedPidFile })
    $pidRefreshTimer.Start()

    $bridge = New-Object BrightnessKeyBridge($callback, $logPath, $EnableLogging.IsPresent, $VerboseConsumerLog.IsPresent, $CaptureF1F2BrightnessKeys.IsPresent)
    try {
        [System.Windows.Forms.Application]::Run()
    }
    finally {
        if ($pidRefreshTimer) {
            $pidRefreshTimer.Stop()
            $pidRefreshTimer.Dispose()
        }
        $bridge.Dispose()
    }
}
finally {
    if (Test-Path $pidFile) {
        Remove-Item -LiteralPath $pidFile -Force
    }

    if ($mutex) {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}
