[CmdletBinding()]
param(
    [switch]$RestartDiscord,
    [switch]$EnableDesktopMicrophoneAccess,
    [string]$PreferredNamePattern = "Studio Display"
)

$ErrorActionPreference = "Stop"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public enum EDataFlow {
    eRender = 0,
    eCapture = 1,
    eAll = 2
}

public enum ERole {
    eConsole = 0,
    eMultimedia = 1,
    eCommunications = 2
}

[Flags]
public enum DEVICE_STATE {
    ACTIVE = 0x00000001,
    DISABLED = 0x00000002,
    NOTPRESENT = 0x00000004,
    UNPLUGGED = 0x00000008,
    MASK_ALL = 0x0000000F
}

[ComImport]
[Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

[ComImport]
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    [PreserveSig]
    int EnumAudioEndpoints(EDataFlow dataFlow, DEVICE_STATE dwStateMask, out IMMDeviceCollection ppDevices);
    [PreserveSig]
    int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppEndpoint);
    [PreserveSig]
    int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string pwstrId, out IMMDevice ppDevice);
    [PreserveSig]
    int RegisterEndpointNotificationCallback(IntPtr pClient);
    [PreserveSig]
    int UnregisterEndpointNotificationCallback(IntPtr pClient);
}

[ComImport]
[Guid("0BD7A1BE-7A1A-44DB-8397-C0B4BA6048A8")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceCollection {
    [PreserveSig]
    int GetCount(out uint pcDevices);
    [PreserveSig]
    int Item(uint nDevice, out IMMDevice ppDevice);
}

[ComImport]
[Guid("D666063F-1587-4E43-81F1-B948E807363F")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    [PreserveSig]
    int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, out IntPtr ppInterface);
    [PreserveSig]
    int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
    [PreserveSig]
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
    [PreserveSig]
    int GetState(out DEVICE_STATE pdwState);
}

[ComImport]
[Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropertyStore {
    [PreserveSig]
    int GetCount(out uint cProps);
    [PreserveSig]
    int GetAt(uint iProp, out PROPERTYKEY pkey);
    [PreserveSig]
    int GetValue(ref PROPERTYKEY key, out PROPVARIANT pv);
    [PreserveSig]
    int SetValue(ref PROPERTYKEY key, ref PROPVARIANT propvar);
    [PreserveSig]
    int Commit();
}

[StructLayout(LayoutKind.Sequential)]
public struct PROPERTYKEY {
    public Guid fmtid;
    public uint pid;
}

[StructLayout(LayoutKind.Sequential)]
public struct PROPVARIANT {
    public ushort vt;
    public ushort wReserved1;
    public ushort wReserved2;
    public ushort wReserved3;
    public IntPtr p;
    public int p2;
}

[ComImport]
[Guid("F8679F50-850A-41CF-9C72-430F290290C8")]
[InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPolicyConfig {
    [PreserveSig]
    int GetMixFormat([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, IntPtr ppFormat);
    [PreserveSig]
    int GetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int bDefault, IntPtr ppFormat);
    [PreserveSig]
    int ResetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName);
    [PreserveSig]
    int SetDeviceFormat([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, IntPtr pEndpointFormat, IntPtr pMixFormat);
    [PreserveSig]
    int GetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int bDefault, IntPtr pmftDefaultPeriod, IntPtr pmftMinimumPeriod);
    [PreserveSig]
    int SetProcessingPeriod([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, IntPtr pmftPeriod);
    [PreserveSig]
    int GetShareMode([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, IntPtr pMode);
    [PreserveSig]
    int SetShareMode([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, IntPtr mode);
    [PreserveSig]
    int GetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, ref PROPERTYKEY key, out PROPVARIANT pv);
    [PreserveSig]
    int SetPropertyValue([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, ref PROPERTYKEY key, ref PROPVARIANT pv);
    [PreserveSig]
    int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, ERole role);
    [PreserveSig]
    int SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)] string pszDeviceName, int bVisible);
}

[ComImport]
[Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")]
public class PolicyConfigClient { }

public static class StudioDisplayAudio {
    public static readonly PROPERTYKEY PKEY_Device_FriendlyName = new PROPERTYKEY {
        fmtid = new Guid("A45C254E-DF1C-4EFD-8020-67D146A850E0"),
        pid = 14
    };

    public static string PropVariantToString(PROPVARIANT pv) {
        if (pv.vt == 31 && pv.p != IntPtr.Zero) {
            return Marshal.PtrToStringUni(pv.p);
        }
        return "";
    }

    public static AudioEndpointInfo[] GetCaptureEndpoints() {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDeviceCollection collection;
        enumerator.EnumAudioEndpoints(EDataFlow.eCapture, DEVICE_STATE.ACTIVE, out collection);

        uint count;
        collection.GetCount(out count);
        AudioEndpointInfo[] endpoints = new AudioEndpointInfo[count];

        for (uint i = 0; i < count; i++) {
            IMMDevice device;
            collection.Item(i, out device);

            string id;
            device.GetId(out id);

            DEVICE_STATE state;
            device.GetState(out state);

            IPropertyStore store;
            device.OpenPropertyStore(0, out store);

            PROPVARIANT prop;
            PROPERTYKEY key = PKEY_Device_FriendlyName;
            store.GetValue(ref key, out prop);

            endpoints[i] = new AudioEndpointInfo {
                Id = id,
                Name = PropVariantToString(prop),
                State = state.ToString()
            };
        }

        return endpoints;
    }

    public static void SetDefaultCaptureEndpoint(string endpointId) {
        IPolicyConfig policy = (IPolicyConfig)(new PolicyConfigClient());
        policy.SetDefaultEndpoint(endpointId, ERole.eConsole);
        policy.SetDefaultEndpoint(endpointId, ERole.eMultimedia);
        policy.SetDefaultEndpoint(endpointId, ERole.eCommunications);
    }
}

public class AudioEndpointInfo {
    public string Id { get; set; }
    public string Name { get; set; }
    public string State { get; set; }
}
"@

function Get-AudioEndpoint {
    $captureRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture"

    foreach ($endpointKey in Get-ChildItem -LiteralPath $captureRoot -ErrorAction Stop) {
        $state = (Get-ItemProperty -LiteralPath $endpointKey.PSPath -ErrorAction SilentlyContinue).DeviceState
        $propertiesPath = Join-Path $endpointKey.PSPath "Properties"
        $properties = Get-ItemProperty -LiteralPath $propertiesPath -ErrorAction SilentlyContinue
        $friendlyName = $properties.'{a45c254e-df1c-4efd-8020-67d146a850e0},14'
        $deviceDescription = $properties.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
        $name = @($friendlyName, $deviceDescription) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -First 1

        [pscustomobject]@{
            Id = "{0.0.1.00000000}.$($endpointKey.PSChildName)"
            Name = $name
            DataFlow = "eCapture"
            State = $state
        }
    }
}

function Set-DefaultCaptureEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EndpointId
    )

    [StudioDisplayAudio]::SetDefaultCaptureEndpoint($EndpointId)
}

if ($EnableDesktopMicrophoneAccess) {
    $consentRoot = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"
    New-Item -Path $consentRoot -Force | Out-Null
    Set-ItemProperty -Path $consentRoot -Name "Value" -Value "Allow"
}

$captureEndpoints = @(Get-AudioEndpoint)
$preferred = $captureEndpoints |
    Where-Object { ($_.State -band 1) -eq 1 -and $_.Name -like "*$PreferredNamePattern*" } |
    Select-Object -First 1

if (-not $preferred) {
    Write-Host "Active capture endpoints:"
    $captureEndpoints | Format-Table Name, State, Id -AutoSize
    throw "No active capture endpoint matched '*$PreferredNamePattern*'. Reconnect Studio Display and try again."
}

Set-DefaultCaptureEndpoint -EndpointId $preferred.Id

if ($RestartDiscord) {
    $discordProcesses = @(Get-Process -Name Discord -ErrorAction SilentlyContinue)
    if ($discordProcesses.Count -gt 0) {
        $discordPath = ($discordProcesses | Where-Object { $_.Path } | Select-Object -First 1).Path
        $discordProcesses | Stop-Process -Force
        Start-Sleep -Seconds 2
        if ($discordPath -and (Test-Path $discordPath)) {
            Start-Process -FilePath $discordPath | Out-Null
        }
    }
}

Write-Host "Studio Display microphone selected as default input and default communications input:"
Write-Host $preferred.Name
