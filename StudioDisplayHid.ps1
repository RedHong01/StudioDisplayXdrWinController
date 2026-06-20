[CmdletBinding()]
param(
    [ValidateRange(0,100)]
    [int]$SetPercent,
    [switch]$GetPercent
)

$ErrorActionPreference = "Stop"

if (-not ("StudioDisplayHid" -as [type])) {
    $hidTypeDefinition = @"
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class StudioDisplayHid
{
    private const uint DIGCF_PRESENT = 0x00000002;
    private const uint DIGCF_DEVICEINTERFACE = 0x00000010;
    private const uint SPDRP_HARDWAREID = 0x00000001;
    private const int HIDP_STATUS_SUCCESS = 0x00110000;

    private const uint GENERIC_READ = 0x80000000;
    private const uint GENERIC_WRITE = 0x40000000;
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint OPEN_EXISTING = 3;

    private static readonly string VidString = "VID_05AC";
    private static readonly string PidString = "PID_1114";
    private static readonly string InterfaceString = "MI_07";
    private static readonly string CollectionString = "Col";

    private static SafeFileHandle deviceHandle;
    private static IntPtr preparsedData = IntPtr.Zero;
    private static ushort inputReportLength;
    private static ushort featureReportLength;
    private static ushort inputUsagePage;
    private static ushort inputUsage;
    private static byte inputReportId;
    private static ushort featureUsagePage;
    private static ushort featureUsage;
    private static byte featureReportId;

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public uint cbSize;
        public Guid ClassGuid;
        public uint DevInst;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA
    {
        public uint cbSize;
        public Guid InterfaceClassGuid;
        public uint Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct SP_DEVICE_INTERFACE_DETAIL_DATA
    {
        public uint cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1024)]
        public string DevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HIDP_CAPS
    {
        public short Usage;
        public short UsagePage;
        public short InputReportByteLength;
        public short OutputReportByteLength;
        public short FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)]
        public short[] Reserved;
        public short NumberLinkCollectionNodes;
        public short NumberInputButtonCaps;
        public short NumberInputValueCaps;
        public short NumberInputDataIndices;
        public short NumberOutputButtonCaps;
        public short NumberOutputValueCaps;
        public short NumberOutputDataIndices;
        public short NumberFeatureButtonCaps;
        public short NumberFeatureValueCaps;
        public short NumberFeatureDataIndices;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HIDP_RANGE_CAPS
    {
        public ushort UsageMin;
        public ushort UsageMax;
        public ushort StringMin;
        public ushort StringMax;
        public ushort DesignatorMin;
        public ushort DesignatorMax;
        public ushort DataIndexMin;
        public ushort DataIndexMax;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HIDP_NOTRANGE_CAPS
    {
        public ushort Usage;
        public ushort Reserved1;
        public ushort StringIndex;
        public ushort Reserved2;
        public ushort DesignatorIndex;
        public ushort Reserved3;
        public ushort DataIndex;
        public ushort Reserved4;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct HIDP_CAPS_UNION
    {
        [FieldOffset(0)]
        public HIDP_RANGE_CAPS Range;
        [FieldOffset(0)]
        public HIDP_NOTRANGE_CAPS NotRange;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct HIDP_VALUE_CAPS
    {
        public ushort UsagePage;
        public byte ReportID;
        [MarshalAs(UnmanagedType.U1)]
        public bool IsAlias;
        public ushort BitField;
        public ushort LinkCollection;
        public ushort LinkUsage;
        public ushort LinkUsagePage;
        [MarshalAs(UnmanagedType.U1)]
        public bool IsRange;
        [MarshalAs(UnmanagedType.U1)]
        public bool IsStringRange;
        [MarshalAs(UnmanagedType.U1)]
        public bool IsDesignatorRange;
        [MarshalAs(UnmanagedType.U1)]
        public bool IsAbsolute;
        [MarshalAs(UnmanagedType.U1)]
        public bool HasNull;
        public byte Reserved;
        public ushort BitSize;
        public ushort ReportCount;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 5)]
        public ushort[] Reserved2;
        public uint UnitsExp;
        public uint Units;
        public int LogicalMin;
        public int LogicalMax;
        public int PhysicalMin;
        public int PhysicalMax;
        public HIDP_CAPS_UNION Caps;
    }

    private enum HIDP_REPORT_TYPE
    {
        HidP_Input = 0,
        HidP_Output = 1,
        HidP_Feature = 2
    }

    [DllImport("hid.dll")]
    private static extern void HidD_GetHidGuid(out Guid hidGuid);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetPreparsedData(SafeFileHandle hObject, out IntPtr preparsedData);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_FreePreparsedData(IntPtr preparsedData);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetInputReport(SafeFileHandle hidDeviceObject, byte[] reportBuffer, int reportBufferLength);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_GetFeature(SafeFileHandle hidDeviceObject, byte[] reportBuffer, int reportBufferLength);

    [DllImport("hid.dll", SetLastError = true)]
    private static extern bool HidD_SetFeature(SafeFileHandle hidDeviceObject, byte[] reportBuffer, int reportBufferLength);

    [DllImport("hid.dll")]
    private static extern int HidP_GetCaps(IntPtr preparsedData, out HIDP_CAPS capabilities);

    [DllImport("hid.dll")]
    private static extern int HidP_GetValueCaps(HIDP_REPORT_TYPE reportType, [Out] HIDP_VALUE_CAPS[] valueCaps, ref ushort valueCapsLength, IntPtr preparsedData);

    [DllImport("hid.dll")]
    private static extern int HidP_GetUsageValue(HIDP_REPORT_TYPE reportType, ushort usagePage, ushort linkCollection, ushort usage, out uint usageValue, IntPtr preparsedData, byte[] report, ushort reportLength);

    [DllImport("hid.dll")]
    private static extern int HidP_SetUsageValue(HIDP_REPORT_TYPE reportType, ushort usagePage, ushort linkCollection, ushort usage, uint usageValue, IntPtr preparsedData, byte[] report, ushort reportLength);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, IntPtr enumerator, IntPtr hwndParent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInfo(IntPtr deviceInfoSet, uint memberIndex, ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool SetupDiGetDeviceRegistryProperty(IntPtr deviceInfoSet, ref SP_DEVINFO_DATA deviceInfoData, uint property, out uint propertyRegDataType, byte[] propertyBuffer, uint propertyBufferSize, out uint requiredSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr deviceInfoSet, IntPtr deviceInfoData, ref Guid interfaceClassGuid, uint memberIndex, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr deviceInfoSet, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData, ref SP_DEVICE_INTERFACE_DETAIL_DATA deviceInterfaceDetailData, uint deviceInterfaceDetailDataSize, out uint requiredSize, IntPtr deviceInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    private static void CleanupState()
    {
        if (preparsedData != IntPtr.Zero)
        {
            HidD_FreePreparsedData(preparsedData);
            preparsedData = IntPtr.Zero;
        }

        if (deviceHandle != null)
        {
            if (!deviceHandle.IsClosed)
            {
                deviceHandle.Close();
            }

            deviceHandle.Dispose();
            deviceHandle = null;
        }

        inputReportLength = 0;
        featureReportLength = 0;
        inputUsagePage = 0;
        inputUsage = 0;
        inputReportId = 0;
        featureUsagePage = 0;
        featureUsage = 0;
        featureReportId = 0;
    }

    public static void Reset()
    {
        CleanupState();
    }

    public static void EnsureInitialized()
    {
        if (deviceHandle != null && !deviceHandle.IsInvalid && !deviceHandle.IsClosed)
        {
            return;
        }

        CleanupState();

        Guid hidGuid;
        HidD_GetHidGuid(out hidGuid);

        IntPtr infoSet = SetupDiGetClassDevs(ref hidGuid, IntPtr.Zero, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (infoSet == IntPtr.Zero || infoSet.ToInt64() == -1)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetClassDevs failed.");
        }

        try
        {
            for (uint index = 0; ; index++)
            {
                SP_DEVINFO_DATA deviceInfo = new SP_DEVINFO_DATA();
                deviceInfo.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVINFO_DATA));

                if (!SetupDiEnumDeviceInfo(infoSet, index, ref deviceInfo))
                {
                    int lastError = Marshal.GetLastWin32Error();
                    if (lastError == 259)
                    {
                        break;
                    }

                    throw new Win32Exception(lastError, "SetupDiEnumDeviceInfo failed.");
                }

                uint propertyType;
                uint requiredSize;
                byte[] propertyBuffer = new byte[1024];
                if (!SetupDiGetDeviceRegistryProperty(infoSet, ref deviceInfo, SPDRP_HARDWAREID, out propertyType, propertyBuffer, (uint)propertyBuffer.Length, out requiredSize))
                {
                    continue;
                }

                string hardwareId = System.Text.Encoding.Unicode.GetString(propertyBuffer).ToUpperInvariant();
                if (hardwareId.IndexOf(VidString, StringComparison.OrdinalIgnoreCase) < 0 ||
                    hardwareId.IndexOf(PidString, StringComparison.OrdinalIgnoreCase) < 0 ||
                    hardwareId.IndexOf(InterfaceString, StringComparison.OrdinalIgnoreCase) < 0 ||
                    hardwareId.IndexOf(CollectionString, StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    continue;
                }

                SP_DEVICE_INTERFACE_DATA interfaceData = new SP_DEVICE_INTERFACE_DATA();
                interfaceData.cbSize = (uint)Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA));
                if (!SetupDiEnumDeviceInterfaces(infoSet, IntPtr.Zero, ref hidGuid, index, ref interfaceData))
                {
                    continue;
                }

                SP_DEVICE_INTERFACE_DETAIL_DATA detailData = new SP_DEVICE_INTERFACE_DETAIL_DATA();
                detailData.cbSize = (uint)(IntPtr.Size == 8 ? 8 : 5);

                if (!SetupDiGetDeviceInterfaceDetail(infoSet, ref interfaceData, ref detailData, (uint)Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DETAIL_DATA)), out requiredSize, IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "SetupDiGetDeviceInterfaceDetail failed.");
                }

                try
                {
                    deviceHandle = CreateFile(detailData.DevicePath, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
                    if (deviceHandle == null || deviceHandle.IsInvalid)
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "CreateFile failed.");
                    }

                    if (!HidD_GetPreparsedData(deviceHandle, out preparsedData))
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error(), "HidD_GetPreparsedData failed.");
                    }

                    HIDP_CAPS caps;
                    int capsStatus = HidP_GetCaps(preparsedData, out caps);
                    if (capsStatus != HIDP_STATUS_SUCCESS)
                    {
                        throw new InvalidOperationException("HidP_GetCaps failed.");
                    }

                    inputReportLength = (ushort)caps.InputReportByteLength;
                    featureReportLength = (ushort)caps.FeatureReportByteLength;

                    HIDP_VALUE_CAPS[] inputCaps = new HIDP_VALUE_CAPS[4];
                    ushort inputCapsLength = (ushort)inputCaps.Length;
                    int inputStatus = HidP_GetValueCaps(HIDP_REPORT_TYPE.HidP_Input, inputCaps, ref inputCapsLength, preparsedData);
                    if (inputStatus != HIDP_STATUS_SUCCESS || inputCapsLength == 0 || inputCaps[0].ReportCount != 1)
                    {
                        throw new InvalidOperationException("Input value caps are not valid.");
                    }

                    inputReportId = inputCaps[0].ReportID;
                    inputUsagePage = inputCaps[0].UsagePage;
                    inputUsage = inputCaps[0].Caps.NotRange.Usage;

                    HIDP_VALUE_CAPS[] featureCaps = new HIDP_VALUE_CAPS[4];
                    ushort featureCapsLength = (ushort)featureCaps.Length;
                    int featureStatus = HidP_GetValueCaps(HIDP_REPORT_TYPE.HidP_Feature, featureCaps, ref featureCapsLength, preparsedData);
                    if (featureStatus != HIDP_STATUS_SUCCESS || featureCapsLength == 0 || featureCaps[0].ReportCount != 1)
                    {
                        throw new InvalidOperationException("Feature value caps are not valid.");
                    }

                    featureReportId = featureCaps[0].ReportID;
                    featureUsagePage = featureCaps[0].UsagePage;
                    featureUsage = featureCaps[0].Caps.NotRange.Usage;
                    return;
                }
                catch
                {
                    CleanupState();
                    throw;
                }
            }

            throw new InvalidOperationException("Apple Studio Display HID brightness interface was not found.");
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(infoSet);
        }
    }

    public static uint GetBrightnessRaw()
    {
        EnsureInitialized();
        byte[] buffer = new byte[Math.Max(100, (int)inputReportLength)];
        buffer[0] = inputReportId;

        if (!HidD_GetInputReport(deviceHandle, buffer, buffer.Length))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "HidD_GetInputReport failed.");
        }

        uint value;
        int status = HidP_GetUsageValue(HIDP_REPORT_TYPE.HidP_Input, inputUsagePage, 0, inputUsage, out value, preparsedData, buffer, inputReportLength);
        if (status != HIDP_STATUS_SUCCESS)
        {
            throw new InvalidOperationException("HidP_GetUsageValue failed.");
        }

        return value;
    }

    public static void SetBrightnessRaw(uint rawValue)
    {
        EnsureInitialized();
        byte[] buffer = new byte[Math.Max(100, (int)featureReportLength)];
        buffer[0] = featureReportId;

        if (!HidD_GetFeature(deviceHandle, buffer, buffer.Length))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "HidD_GetFeature failed.");
        }

        int status = HidP_SetUsageValue(HIDP_REPORT_TYPE.HidP_Feature, featureUsagePage, 0, featureUsage, rawValue, preparsedData, buffer, featureReportLength);
        if (status != HIDP_STATUS_SUCCESS)
        {
            throw new InvalidOperationException("HidP_SetUsageValue failed.");
        }

        if (!HidD_SetFeature(deviceHandle, buffer, featureReportLength))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "HidD_SetFeature failed.");
        }
    }

    public static int GetBrightnessPercent()
    {
        uint raw = GetBrightnessRaw();
        double percent = ((double)raw / 60000.0) * 100.0;
        int rounded = (int)Math.Round(percent, MidpointRounding.AwayFromZero);
        if (rounded < 0) rounded = 0;
        if (rounded > 100) rounded = 100;
        return rounded;
    }

    public static void SetBrightnessPercent(int percent)
    {
        if (percent < 0) percent = 0;
        if (percent > 100) percent = 100;

        uint raw = (uint)Math.Round((percent / 100.0) * 60000.0, MidpointRounding.AwayFromZero);
        SetBrightnessRaw(raw);
    }
}
"@

    Add-Type -TypeDefinition $hidTypeDefinition
}

function Get-StudioDisplayBrightnessPercent {
    Invoke-StudioDisplayHidOperation -Operation {
        [StudioDisplayHid]::GetBrightnessPercent()
    }
}

function Set-StudioDisplayBrightnessPercent {
    param([int]$Percent)
    Invoke-StudioDisplayHidOperation -Operation {
        [StudioDisplayHid]::SetBrightnessPercent($Percent)
    }
}

function Reset-StudioDisplayHidConnection {
    [StudioDisplayHid]::Reset()
}

function Invoke-StudioDisplayHidOperation {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Operation
    )

    try {
        & $Operation
    }
    catch {
        $firstError = $_.Exception.Message

        try {
            [StudioDisplayHid]::Reset()
        }
        catch {
        }

        try {
            & $Operation
        }
        catch {
            throw "Studio Display HID operation failed after reconnect attempt. Initial error: $firstError. Retry error: $($_.Exception.Message)"
        }
    }
}

if ($PSBoundParameters.ContainsKey("SetPercent")) {
    Set-StudioDisplayBrightnessPercent -Percent $SetPercent
}

if ($GetPercent) {
    Get-StudioDisplayBrightnessPercent
}
