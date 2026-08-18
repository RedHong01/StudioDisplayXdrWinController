[CmdletBinding()]
param(
    [ValidateRange(5,120)]
    [int]$DurationSeconds = 25,
    [string]$LogPath
)

$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
if (-not $LogPath) {
    $reportsRoot = Join-Path $scriptRoot "reports"
    New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
    $LogPath = Join-Path $reportsRoot ("StudioDisplayBrightnessInputTrace-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$typeDefinition = @"
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public sealed class StudioDisplayBrightnessInputTraceWindow : NativeWindow, IDisposable
{
    private const int WM_INPUT = 0x00FF;
    private const int WH_KEYBOARD_LL = 13;
    private const int WH_MOUSE_LL = 14;
    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const int WM_LBUTTONDOWN = 0x0201;
    private const int WM_LBUTTONUP = 0x0202;
    private const int WM_RBUTTONDOWN = 0x0204;
    private const int WM_RBUTTONUP = 0x0205;
    private const int WM_MBUTTONDOWN = 0x0207;
    private const int WM_MBUTTONUP = 0x0208;
    private const int WM_MOUSEWHEEL = 0x020A;
    private const int WM_XBUTTONDOWN = 0x020B;
    private const int WM_XBUTTONUP = 0x020C;
    private const int WM_MOUSEHWHEEL = 0x020E;
    private const uint RID_INPUT = 0x10000003;
    private const uint RIDI_PREPARSEDDATA = 0x20000005;
    private const uint RIDI_DEVICENAME = 0x20000007;
    private const uint RIM_TYPEMOUSE = 0;
    private const uint RIM_TYPEKEYBOARD = 1;
    private const uint RIM_TYPEHID = 2;
    private const uint RIDEV_INPUTSINK = 0x00000100;
    private const ushort RI_KEY_BREAK = 0x0001;

    private const ushort USAGE_PAGE_GENERIC_DESKTOP = 0x01;
    private const ushort USAGE_MOUSE = 0x02;
    private const ushort USAGE_KEYBOARD = 0x06;
    private const ushort USAGE_PAGE_CONSUMER = 0x0C;
    private const ushort USAGE_CONSUMER_CONTROL = 0x01;
    private const ushort USAGE_BRIGHTNESS_INCREMENT = 0x006F;
    private const ushort USAGE_BRIGHTNESS_DECREMENT = 0x0070;

    private const ushort RI_MOUSE_LEFT_BUTTON_DOWN = 0x0001;
    private const ushort RI_MOUSE_LEFT_BUTTON_UP = 0x0002;
    private const ushort RI_MOUSE_RIGHT_BUTTON_DOWN = 0x0004;
    private const ushort RI_MOUSE_RIGHT_BUTTON_UP = 0x0008;
    private const ushort RI_MOUSE_MIDDLE_BUTTON_DOWN = 0x0010;
    private const ushort RI_MOUSE_MIDDLE_BUTTON_UP = 0x0020;
    private const ushort RI_MOUSE_BUTTON_4_DOWN = 0x0040;
    private const ushort RI_MOUSE_BUTTON_4_UP = 0x0080;
    private const ushort RI_MOUSE_BUTTON_5_DOWN = 0x0100;
    private const ushort RI_MOUSE_BUTTON_5_UP = 0x0200;
    private const ushort RI_MOUSE_WHEEL = 0x0400;
    private const ushort RI_MOUSE_HWHEEL = 0x0800;

    private readonly string logPath;
    private readonly Action<string> onEvent;
    private readonly Dictionary<IntPtr, IntPtr> preparsedDataCache = new Dictionary<IntPtr, IntPtr>();
    private readonly Dictionary<IntPtr, string> deviceNameCache = new Dictionary<IntPtr, string>();
    private readonly LowLevelKeyboardProc keyboardProc;
    private readonly LowLevelMouseProc mouseProc;
    private IntPtr keyboardHook = IntPtr.Zero;
    private IntPtr mouseHook = IntPtr.Zero;

    public StudioDisplayBrightnessInputTraceWindow(string logPath, Action<string> onEvent)
    {
        this.logPath = logPath;
        this.onEvent = onEvent;
        keyboardProc = KeyboardHookCallback;
        mouseProc = MouseHookCallback;
        CreateHandle(new CreateParams());
        RegisterRawInput();
        keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, keyboardProc, IntPtr.Zero, 0);
        mouseHook = SetWindowsHookEx(WH_MOUSE_LL, mouseProc, IntPtr.Zero, 0);
        Log("Trace started. Press the mouse brightness up/down buttons now.");
        Log("Hooks: keyboard=" + (keyboardHook != IntPtr.Zero).ToString() + " mouse=" + (mouseHook != IntPtr.Zero).ToString());
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
        if (keyboardHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(keyboardHook);
            keyboardHook = IntPtr.Zero;
        }
        if (mouseHook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(mouseHook);
            mouseHook = IntPtr.Zero;
        }
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
                usUsagePage = USAGE_PAGE_GENERIC_DESKTOP,
                usUsage = USAGE_MOUSE,
                dwFlags = RIDEV_INPUTSINK,
                hwndTarget = Handle
            },
            new RAWINPUTDEVICE
            {
                usUsagePage = USAGE_PAGE_GENERIC_DESKTOP,
                usUsage = USAGE_KEYBOARD,
                dwFlags = RIDEV_INPUTSINK,
                hwndTarget = Handle
            },
            new RAWINPUTDEVICE
            {
                usUsagePage = USAGE_PAGE_CONSUMER,
                usUsage = USAGE_CONSUMER_CONTROL,
                dwFlags = RIDEV_INPUTSINK,
                hwndTarget = Handle
            }
        };

        if (!RegisterRawInputDevices(devices, (uint)devices.Length, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE))))
        {
            throw new InvalidOperationException("RegisterRawInputDevices failed.");
        }
    }

    private IntPtr KeyboardHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int message = wParam.ToInt32();
            if (message == WM_KEYDOWN || message == WM_KEYUP || message == WM_SYSKEYDOWN || message == WM_SYSKEYUP)
            {
                KBDLLHOOKSTRUCT keyboard = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
                string state = (message == WM_KEYUP || message == WM_SYSKEYUP) ? "UP" : "DOWN";
                string hint = "";
                if (keyboard.vkCode == 0x70)
                {
                    hint = " hint=F1 possible-brightness-down";
                }
                else if (keyboard.vkCode == 0x71)
                {
                    hint = " hint=F2 possible-brightness-up";
                }
                else if (keyboard.vkCode == 0x7D)
                {
                    hint = " hint=F14 brightness-down";
                }
                else if (keyboard.vkCode == 0x7E)
                {
                    hint = " hint=F15 brightness-up";
                }

                Log("HOOK_KEYBOARD " + state + " VKey=0x" + keyboard.vkCode.ToString("X4") + " ScanCode=0x" + keyboard.scanCode.ToString("X4") + " Flags=0x" + keyboard.flags.ToString("X4") + hint);
            }
        }

        return CallNextHookEx(keyboardHook, nCode, wParam, lParam);
    }

    private IntPtr MouseHookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int message = wParam.ToInt32();
            if (
                message == WM_LBUTTONDOWN || message == WM_LBUTTONUP ||
                message == WM_RBUTTONDOWN || message == WM_RBUTTONUP ||
                message == WM_MBUTTONDOWN || message == WM_MBUTTONUP ||
                message == WM_XBUTTONDOWN || message == WM_XBUTTONUP ||
                message == WM_MOUSEWHEEL || message == WM_MOUSEHWHEEL)
            {
                MSLLHOOKSTRUCT mouse = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                string action = DescribeHookMouseMessage(message, mouse.mouseData);
                Log("HOOK_MOUSE " + action + " mouseData=0x" + mouse.mouseData.ToString("X8") + " flags=0x" + mouse.flags.ToString("X4") + " pt=(" + mouse.pt.x.ToString() + "," + mouse.pt.y.ToString() + ")");
            }
        }

        return CallNextHookEx(mouseHook, nCode, wParam, lParam);
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
            string deviceName = GetDeviceName(header.hDevice);

            if (header.dwType == RIM_TYPEMOUSE)
            {
                IntPtr mousePointer = IntPtr.Add(buffer, Marshal.SizeOf(typeof(RAWINPUTHEADER)));
                RAWMOUSE mouse = (RAWMOUSE)Marshal.PtrToStructure(mousePointer, typeof(RAWMOUSE));
                HandleMouse(mouse, deviceName);
                return;
            }

            if (header.dwType == RIM_TYPEKEYBOARD)
            {
                IntPtr keyboardPointer = IntPtr.Add(buffer, Marshal.SizeOf(typeof(RAWINPUTHEADER)));
                RAWKEYBOARD keyboard = (RAWKEYBOARD)Marshal.PtrToStructure(keyboardPointer, typeof(RAWKEYBOARD));
                HandleKeyboard(keyboard, deviceName);
                return;
            }

            if (header.dwType == RIM_TYPEHID)
            {
                HandleHid(buffer, header, deviceName);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private void HandleMouse(RAWMOUSE mouse, string deviceName)
    {
        if (mouse.usButtonFlags == 0)
        {
            return;
        }

        string actions = DescribeMouseButtons(mouse.usButtonFlags, mouse.usButtonData);
        Log("MOUSE " + actions + " flags=0x" + mouse.usButtonFlags.ToString("X4") + " data=" + unchecked((short)mouse.usButtonData).ToString() + " device=" + deviceName);
    }

    private void HandleKeyboard(RAWKEYBOARD keyboard, string deviceName)
    {
        bool isKeyUp = (keyboard.Flags & RI_KEY_BREAK) == RI_KEY_BREAK;
        string keyState = isKeyUp ? "UP" : "DOWN";
        string hint = "";
        if (keyboard.VKey == 0x70)
        {
            hint = " hint=F1 possible-brightness-down";
        }
        else if (keyboard.VKey == 0x71)
        {
            hint = " hint=F2 possible-brightness-up";
        }
        else if (keyboard.VKey == 0x7D)
        {
            hint = " hint=F14 brightness-down";
        }
        else if (keyboard.VKey == 0x7E)
        {
            hint = " hint=F15 brightness-up";
        }

        Log("KEYBOARD " + keyState + " VKey=0x" + keyboard.VKey.ToString("X4") + " MakeCode=0x" + keyboard.MakeCode.ToString("X4") + " Flags=0x" + keyboard.Flags.ToString("X4") + " Message=0x" + keyboard.Message.ToString("X4") + hint + " device=" + deviceName);
    }

    private void HandleHid(IntPtr buffer, RAWINPUTHEADER header, string deviceName)
    {
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
            ushort[] usages = new ushort[32];
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

            if (status < 0 || usageLength == 0)
            {
                continue;
            }

            for (int usageIndex = 0; usageIndex < usageLength; usageIndex++)
            {
                ushort usage = usages[usageIndex];
                string hint = "";
                if (usage == USAGE_BRIGHTNESS_INCREMENT)
                {
                    hint = " hint=brightness-up";
                }
                else if (usage == USAGE_BRIGHTNESS_DECREMENT)
                {
                    hint = " hint=brightness-down";
                }

                Log("CONSUMER usage=0x" + usage.ToString("X4") + hint + " device=" + deviceName);
            }
        }
    }

    private string DescribeMouseButtons(ushort flags, ushort data)
    {
        List<string> parts = new List<string>();
        if ((flags & RI_MOUSE_LEFT_BUTTON_DOWN) != 0) parts.Add("LeftDown");
        if ((flags & RI_MOUSE_LEFT_BUTTON_UP) != 0) parts.Add("LeftUp");
        if ((flags & RI_MOUSE_RIGHT_BUTTON_DOWN) != 0) parts.Add("RightDown");
        if ((flags & RI_MOUSE_RIGHT_BUTTON_UP) != 0) parts.Add("RightUp");
        if ((flags & RI_MOUSE_MIDDLE_BUTTON_DOWN) != 0) parts.Add("MiddleDown");
        if ((flags & RI_MOUSE_MIDDLE_BUTTON_UP) != 0) parts.Add("MiddleUp");
        if ((flags & RI_MOUSE_BUTTON_4_DOWN) != 0) parts.Add("Button4Down/XButton1");
        if ((flags & RI_MOUSE_BUTTON_4_UP) != 0) parts.Add("Button4Up/XButton1");
        if ((flags & RI_MOUSE_BUTTON_5_DOWN) != 0) parts.Add("Button5Down/XButton2");
        if ((flags & RI_MOUSE_BUTTON_5_UP) != 0) parts.Add("Button5Up/XButton2");
        if ((flags & RI_MOUSE_WHEEL) != 0) parts.Add("Wheel(" + unchecked((short)data).ToString() + ")");
        if ((flags & RI_MOUSE_HWHEEL) != 0) parts.Add("HWheel(" + unchecked((short)data).ToString() + ")");
        if (parts.Count == 0) parts.Add("Unknown");
        return String.Join(",", parts.ToArray());
    }

    private string DescribeHookMouseMessage(int message, uint mouseData)
    {
        int highWord = unchecked((short)((mouseData >> 16) & 0xFFFF));
        switch (message)
        {
            case WM_LBUTTONDOWN: return "LeftDown";
            case WM_LBUTTONUP: return "LeftUp";
            case WM_RBUTTONDOWN: return "RightDown";
            case WM_RBUTTONUP: return "RightUp";
            case WM_MBUTTONDOWN: return "MiddleDown";
            case WM_MBUTTONUP: return "MiddleUp";
            case WM_XBUTTONDOWN: return "XButton" + highWord.ToString() + "Down";
            case WM_XBUTTONUP: return "XButton" + highWord.ToString() + "Up";
            case WM_MOUSEWHEEL: return "Wheel(" + highWord.ToString() + ")";
            case WM_MOUSEHWHEEL: return "HWheel(" + highWord.ToString() + ")";
            default: return "MouseMessage0x" + message.ToString("X4");
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

    private string GetDeviceName(IntPtr deviceHandle)
    {
        if (deviceHandle == IntPtr.Zero)
        {
            return "(none)";
        }

        string cached;
        if (deviceNameCache.TryGetValue(deviceHandle, out cached))
        {
            return cached;
        }

        uint size = 0;
        uint result = GetRawInputDeviceInfo(deviceHandle, RIDI_DEVICENAME, IntPtr.Zero, ref size);
        if (result == 0xFFFFFFFF || size == 0)
        {
            return "(unknown)";
        }

        StringBuilder builder = new StringBuilder((int)size);
        result = GetRawInputDeviceInfo(deviceHandle, RIDI_DEVICENAME, builder, ref size);
        if (result == 0xFFFFFFFF)
        {
            return "(unknown)";
        }

        cached = builder.ToString();
        deviceNameCache[deviceHandle] = cached;
        return cached;
    }

    private void Log(string message)
    {
        string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message;
        File.AppendAllText(logPath, line + Environment.NewLine, Encoding.UTF8);
        onEvent(line);
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
    private struct RAWMOUSE
    {
        public ushort usFlags;
        public ushort usReserved;
        public ushort usButtonFlags;
        public ushort usButtonData;
        public uint ulRawButtons;
        public int lLastX;
        public int lLastY;
        public uint ulExtraInformation;
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

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public POINT pt;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private enum HIDP_REPORT_TYPE
    {
        HidP_Input = 0,
        HidP_Output = 1,
        HidP_Feature = 2
    }

    private delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    private delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

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

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetRawInputDeviceInfo(
        IntPtr hDevice,
        uint uiCommand,
        [Out] StringBuilder pData,
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

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook,
        LowLevelKeyboardProc lpfn,
        IntPtr hMod,
        uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(
        int idHook,
        LowLevelMouseProc lpfn,
        IntPtr hMod,
        uint dwThreadId);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
}
"@

Add-Type -TypeDefinition $typeDefinition -ReferencedAssemblies @("System.Windows.Forms.dll", "System.Drawing.dll")

$form = New-Object System.Windows.Forms.Form
$form.Text = "Studio Display Brightness Input Trace"
$form.Size = New-Object System.Drawing.Size(760, 420)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.TopMost = $true

$label = New-Object System.Windows.Forms.Label
$label.Dock = [System.Windows.Forms.DockStyle]::Top
$label.Height = 58
$label.Text = "请现在按鼠标上的亮度增加/减少键。监听会在 $DurationSeconds 秒后自动结束。`r`n日志：$LogPath"

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Multiline = $true
$textBox.ReadOnly = $true
$textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$textBox.Font = New-Object System.Drawing.Font("Consolas", 9)

$form.Controls.Add($textBox)
$form.Controls.Add($label)

$events = New-Object System.Collections.Generic.List[string]
$callback = [System.Action[string]]{
    param($line)
    $events.Add($line) | Out-Null
    if (-not $textBox.IsDisposed) {
        $textBox.AppendText($line + [Environment]::NewLine)
    }
}

$traceWindow = New-Object StudioDisplayBrightnessInputTraceWindow($LogPath, $callback)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $DurationSeconds * 1000
$timer.Add_Tick({
    $timer.Stop()
    $form.Close()
})

$form.Add_Shown({
    $timer.Start()
})

try {
    [System.Windows.Forms.Application]::Run($form)
}
finally {
    $timer.Dispose()
    $traceWindow.Dispose()
    $form.Dispose()
}

Write-Host "Trace log: $LogPath"
Get-Content -LiteralPath $LogPath -Tail 80
