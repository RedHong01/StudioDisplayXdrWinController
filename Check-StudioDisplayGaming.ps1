[CmdletBinding()]
param(
    [string]$UserSid
)

$ErrorActionPreference = "Continue"

function Get-CurrentUserSid {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

if (-not $UserSid) {
    $UserSid = Get-CurrentUserSid
}

function Write-Section {
    param([string]$Name)

    Write-Output ""
    Write-Output "===== $Name ====="
}

function Read-RegKeyValues {
    param([string]$Path)

    Write-Output "[$Path]"
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        $values = foreach ($name in $key.GetValueNames()) {
            [pscustomobject]@{
                Name  = $name
                Value = $key.GetValue($name)
            }
        }

        if ($values) {
            $values | Sort-Object Name | Format-Table -AutoSize
        }
        else {
            Write-Output "(no values)"
        }
    }
    catch {
        Write-Output "read failed: $($_.Exception.Message)"
    }
}

$appleDisplayPattern = "Studio Display XDR|Studio Display|StudioDisplay|Pro Display XDR|Display XDR|DISPLAY\\APPA|VID_05AC&PID_1114|VID_05AC&PID_1116|USB4\\VID_8087&PID_5786"

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct StudioDisplayGamingDevMode {
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

public static class StudioDisplayGamingModeEnum {
    public const int ENUM_CURRENT_SETTINGS = -1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref StudioDisplayGamingDevMode devMode);
}
"@

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

function Get-CurrentDisplayModeForDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName
    )

    $devMode = New-Object StudioDisplayGamingDevMode
    $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayGamingDevMode])

    if (-not [StudioDisplayGamingModeEnum]::EnumDisplaySettings(
            $DeviceName,
            [StudioDisplayGamingModeEnum]::ENUM_CURRENT_SETTINGS,
            [ref]$devMode
        )) {
        return $null
    }

    return [pscustomobject]@{
        Width = $devMode.dmPelsWidth
        Height = $devMode.dmPelsHeight
        RefreshRate = $devMode.dmDisplayFrequency
    }
}

function Get-AvailableDisplayModesForDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName
    )

    $modes = New-Object System.Collections.Generic.List[object]
    $modeIndex = 0

    while ($true) {
        $devMode = New-Object StudioDisplayGamingDevMode
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayGamingDevMode])

        if (-not [StudioDisplayGamingModeEnum]::EnumDisplaySettings($DeviceName, $modeIndex, [ref]$devMode)) {
            break
        }

        if ($devMode.dmPelsWidth -gt 0 -and $devMode.dmPelsHeight -gt 0 -and $devMode.dmDisplayFrequency -gt 0) {
            $modes.Add([pscustomobject]@{
                    Width = $devMode.dmPelsWidth
                    Height = $devMode.dmPelsHeight
                    RefreshRate = $devMode.dmDisplayFrequency
                    PixelCount = $devMode.dmPelsWidth * $devMode.dmPelsHeight
                }) | Out-Null
        }

        $modeIndex++
    }

    return $modes |
        Sort-Object Width, Height, RefreshRate -Unique
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

function Get-EdidHdrSummary {
    param([AllowNull()][object]$Edid)

    $summary = [ordered]@{
        HdrStaticMetadata = $false
        EotfByte = ""
        Eotf2084 = $false
        Hlg = $false
        Bt2020Rgb = $false
        Bt2020Ycc = $false
    }

    if (-not $Edid) {
        return [pscustomobject]$summary
    }

    $bytes = [byte[]]$Edid
    if ($bytes.Length -lt 256) {
        return [pscustomobject]$summary
    }

    for ($blockOffset = 128; $blockOffset -lt $bytes.Length; $blockOffset += 128) {
        if ($bytes[$blockOffset] -ne 0x02) {
            continue
        }

        $dtdStart = $bytes[$blockOffset + 2]
        if ($dtdStart -eq 0 -or $dtdStart -gt 127) {
            $dtdStart = 127
        }

        $offset = $blockOffset + 4
        while ($offset -lt ($blockOffset + $dtdStart)) {
            $header = $bytes[$offset]
            $tag = ($header -shr 5) -band 0x07
            $length = $header -band 0x1F
            if ($length -le 0) {
                $offset += 1
                continue
            }

            $payloadOffset = $offset + 1
            if (($payloadOffset + $length) -gt ($blockOffset + 127)) {
                break
            }

            if ($tag -eq 7) {
                $extendedTag = $bytes[$payloadOffset]
                if ($extendedTag -eq 0x06 -and $length -ge 3) {
                    $eotf = $bytes[$payloadOffset + 1]
                    $summary.HdrStaticMetadata = $true
                    $summary.EotfByte = ("0x{0:x2}" -f $eotf)
                    $summary.Eotf2084 = (($eotf -band 0x04) -ne 0)
                    $summary.Hlg = (($eotf -band 0x08) -ne 0)
                }
                elseif ($extendedTag -eq 0x05 -and $length -ge 2) {
                    $colorimetry = $bytes[$payloadOffset + 1]
                    $summary.Bt2020Rgb = (($colorimetry -band 0x80) -ne 0)
                    $summary.Bt2020Ycc = (($colorimetry -band 0x40) -ne 0)
                }
            }

            $offset += 1 + $length
        }
    }

    return [pscustomobject]$summary
}

function Get-AppleDisplayConnectionEvidence {
    $evidence = @()

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
        Write-Output "WmiMonitorID evidence failed: $($_.Exception.Message)"
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
        Write-Output "Win32_DesktopMonitor evidence failed: $($_.Exception.Message)"
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
        Write-Output "Get-PnpDevice evidence failed: $($_.Exception.Message)"
    }

    return $evidence
}

function Resolve-AppleDisplayProfileFromEvidence {
    param([object[]]$Evidence)

    $evidenceText = ($Evidence | ForEach-Object { $_.Text }) -join " "

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

function Get-ExpectedAppleDisplayMode {
    param([string]$Profile)

    switch ($Profile) {
        "StudioDisplayXDR" {
            return [pscustomobject]@{ Width = 5120; Height = 2880; RefreshRate = 120; Label = "Studio Display XDR native 5K 120Hz" }
        }
        "StudioDisplay" {
            return [pscustomobject]@{ Width = 5120; Height = 2880; RefreshRate = 60; Label = "Studio Display native 5K 60Hz" }
        }
        "ProDisplayXDR" {
            return [pscustomobject]@{ Width = 6016; Height = 3384; RefreshRate = 60; Label = "Pro Display XDR native 6K 60Hz" }
        }
        default {
            return [pscustomobject]@{ Width = $null; Height = $null; RefreshRate = $null; Label = "Generic display" }
        }
    }
}

$appleEvidence = @(Get-AppleDisplayConnectionEvidence)
$appleDisplayProfile = Resolve-AppleDisplayProfileFromEvidence -Evidence $appleEvidence
$expectedAppleMode = Get-ExpectedAppleDisplayMode -Profile $appleDisplayProfile

Write-Section "Processes"
Get-Process -Name StudioDisplayManager,powershell -ErrorAction SilentlyContinue |
    Select-Object Id,ProcessName,MainWindowTitle,StartTime |
    Format-Table -AutoSize

Write-Section "Active Screens"
try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Screen]::AllScreens |
        ForEach-Object {
            [pscustomobject]@{
                DeviceName   = $_.DeviceName
                Primary      = $_.Primary
                Bounds       = $_.Bounds.ToString()
                WorkingArea  = $_.WorkingArea.ToString()
                BitsPerPixel = $_.BitsPerPixel
            }
        } |
        Format-Table -AutoSize
}
catch {
    Write-Output "screen query failed: $($_.Exception.Message)"
}

Write-Section "Display Modes"
try {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Screen]::AllScreens |
        ForEach-Object {
            $modes = @(Get-AvailableDisplayModesForDiagnostics -DeviceName $_.DeviceName)
            $current = Get-CurrentDisplayModeForDiagnostics -DeviceName $_.DeviceName
            $expectedResolutionEnumerated = if ($null -ne $expectedAppleMode.Width -and $null -ne $expectedAppleMode.Height) {
                [bool]($modes | Where-Object { $_.Width -eq $expectedAppleMode.Width -and $_.Height -eq $expectedAppleMode.Height } | Select-Object -First 1)
            }
            else {
                $null
            }
            $expectedRefreshEnumerated = if ($null -ne $expectedAppleMode.Width -and $null -ne $expectedAppleMode.Height -and $null -ne $expectedAppleMode.RefreshRate) {
                [bool]($modes | Where-Object { $_.Width -eq $expectedAppleMode.Width -and $_.Height -eq $expectedAppleMode.Height -and $_.RefreshRate -eq $expectedAppleMode.RefreshRate } | Select-Object -First 1)
            }
            else {
                $null
            }

            [pscustomobject]@{
                DeviceName = $_.DeviceName
                Primary = $_.Primary
                Current = if ($current) { "$($current.Width)x$($current.Height)@$($current.RefreshRate)Hz" } else { "unknown" }
                MaximumEnumerated = Get-MaxDisplayModeSummary -Modes $modes
                ModeCount = $modes.Count
                ExpectedNative = $expectedAppleMode.Label
                ExpectedResolutionEnumerated = $expectedResolutionEnumerated
                ExpectedRefreshEnumerated = $expectedRefreshEnumerated
            }
        } |
        Format-Table -AutoSize
}
catch {
    Write-Output "display mode query failed: $($_.Exception.Message)"
}

Write-Section "Video Controllers"
Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Select-Object Name, DriverVersion, DriverDate, VideoModeDescription, Status |
    Format-List

Write-Section "Monitor Identity"
Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue |
    ForEach-Object {
        $name = Convert-MonitorByteArrayToString -Values $_.UserFriendlyName
        $manufacturer = Convert-MonitorByteArrayToString -Values $_.ManufacturerName
        [pscustomobject]@{
            InstanceName = $_.InstanceName
            Manufacturer = $manufacturer
            Name = $name
            Serial = Convert-MonitorByteArrayToString -Values $_.SerialNumberID
            AppleDisplayMatch = ("$($_.InstanceName) $manufacturer $name" -match $appleDisplayPattern)
            MicrosoftFallbackIdentity = ($_.InstanceName -match "DISPLAY\\MS_0001")
        }
    } |
    Format-Table -AutoSize

Write-Section "Boot Camp-Style HDR Stack"
try {
    $bootCampService = Get-Service -Name "BootCampService" -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Component = "BootCampService"
        Present = [bool]$bootCampService
        State = if ($bootCampService) { $bootCampService.Status } else { "" }
    } | Format-List

    $driverStore = Join-Path $env:WINDIR "System32\DriverStore\FileRepository"
    if (Test-Path -LiteralPath $driverStore) {
        Get-ChildItem -LiteralPath $driverStore -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "apple(display|null|prodisplay|studio|bootcamp)" } |
            Select-Object -First 20 Name, FullName |
            Format-Table -AutoSize
    }

    $generatedInf = Join-Path $PSScriptRoot "drivers\StudioDisplayXdrBootCampStyleMonitor\StudioDisplayXdrBootCampStyleMonitor.inf"
    [pscustomobject]@{
        Component = "Generated Boot Camp-style Monitor INF"
        Present = Test-Path -LiteralPath $generatedInf
        Path = $generatedInf
    } | Format-List

    $msFallbackMonitors = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match "DISPLAY\\MS_0001" })
    if ($msFallbackMonitors.Count -gt 0) {
        foreach ($monitor in $msFallbackMonitors) {
            Write-Output "pnputil binding for $($monitor.InstanceId):"
            & pnputil.exe /enum-devices /instanceid $monitor.InstanceId /drivers
        }
    }
    else {
        Write-Output "No DISPLAY\MS_0001 monitor instances were found."
    }
}
catch {
    Write-Output "Boot Camp-style HDR stack query failed: $($_.Exception.Message)"
}

Write-Section "Apple Display / USB4 Evidence"
Write-Output "Detected profile: $appleDisplayProfile"
Write-Output "Expected native mode: $($expectedAppleMode.Label)"
if ($appleEvidence) {
    $appleEvidence | Sort-Object Source, Text | Format-Table -AutoSize
}
else {
    Write-Output "No Apple Studio Display evidence was found in WMI, DesktopMonitor, or present PnP devices."
}

Write-Section "Display EDID Registry Cache"
try {
    $displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
    $edidRows = foreach ($monitorKey in Get-ChildItem -LiteralPath $displayRoot -ErrorAction Stop) {
        foreach ($instanceKey in Get-ChildItem -LiteralPath $monitorKey.PSPath -ErrorAction SilentlyContinue) {
            $deviceParametersPath = Join-Path $instanceKey.PSPath "Device Parameters"
            if (-not (Test-Path -LiteralPath $deviceParametersPath)) {
                continue
            }

            $key = Get-Item -LiteralPath $deviceParametersPath -ErrorAction SilentlyContinue
            if (-not $key) {
                continue
            }

            $edid = $key.GetValue("EDID")
            $hdr = Get-EdidHdrSummary -Edid $edid
            [pscustomobject]@{
                MonitorId = $monitorKey.PSChildName
                InstanceId = $instanceKey.PSChildName
                EdidBytes = if ($edid) { $edid.Length } else { 0 }
                AppleLike = ($monitorKey.PSChildName -match "APPA" -or $instanceKey.PSChildName -match "APPA")
                MicrosoftFallbackIdentity = ($monitorKey.PSChildName -eq "MS_0001")
                HdrStaticMetadata = $hdr.HdrStaticMetadata
                EotfByte = $hdr.EotfByte
                Eotf2084 = $hdr.Eotf2084
                Hlg = $hdr.Hlg
                Bt2020Rgb = $hdr.Bt2020Rgb
                Bt2020Ycc = $hdr.Bt2020Ycc
                EffectiveCachePatched = [bool]$key.GetValue("EDID_STUDIO_TOOLS_LAST_PATCH_UTC")
            }
        }
    }

    $edidRows |
        Sort-Object MicrosoftFallbackIdentity, AppleLike, MonitorId, InstanceId -Descending |
        Format-Table -AutoSize
}
catch {
    Write-Output "EDID registry query failed: $($_.Exception.Message)"
}

Write-Section "Advanced Color DisplayConfig State"
$advancedColorScript = Join-Path $PSScriptRoot "Get-StudioDisplayAdvancedColorState.ps1"
if (Test-Path -LiteralPath $advancedColorScript) {
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $advancedColorScript |
            Format-List
    }
    catch {
        Write-Output "Advanced Color DisplayConfig query failed: $($_.Exception.Message)"
    }
}
else {
    Write-Output "not found: $advancedColorScript"
}

Write-Section "NVIDIA SMI"
try {
    & nvidia-smi --query-gpu=name,driver_version,display_mode,display_active,pstate,temperature.gpu,power.draw,utilization.gpu,memory.used,memory.total --format=csv,noheader
}
catch {
    Write-Output "nvidia-smi failed: $($_.Exception.Message)"
}

Write-Section "Registry: User GPU / Game Settings"
Read-RegKeyValues -Path "Registry::HKEY_USERS\$UserSid\Software\Microsoft\DirectX\UserGpuPreferences"
Read-RegKeyValues -Path "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
Read-RegKeyValues -Path "Registry::HKEY_USERS\$UserSid\System\GameConfigStore"
Read-RegKeyValues -Path "Registry::HKEY_USERS\$UserSid\Software\Microsoft\GameBar"

Write-Section "Registry: GraphicsDrivers"
Read-RegKeyValues -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"

Write-Section "Controller Log"
$managerLog = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager\SystemBrightnessMirror.log"
if (Test-Path $managerLog) {
    Get-Content -LiteralPath $managerLog -Tail 160
}
else {
    Write-Output "not found: $managerLog"
}

Write-Section "Recent Display / GPU Events"
$startTime = (Get-Date).AddDays(-14)
Get-WinEvent -FilterHashtable @{ LogName = "System"; StartTime = $startTime } -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProviderName -match "nvlddmkm|Display|Kernel-PnP|WHEA" -or
        $_.Message -match "TDR|Display driver|nvlddmkm|WUDFRd|Studio Display|Studio Display XDR|Display XDR|APPAE3A|VID_05AC|USB4"
    } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 80 TimeCreated, ProviderName, Id, LevelDisplayName, Message |
    Format-List
