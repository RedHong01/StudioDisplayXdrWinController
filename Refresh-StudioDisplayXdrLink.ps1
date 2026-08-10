[CmdletBinding()]
param(
    [switch]$Elevate,
    [switch]$SkipGraphicsHotkey,
    [switch]$AllowGraphicsHotkey,
    [switch]$AllowDisplaySwitchRefresh,
    [switch]$RestartFallbackMonitor,
    [switch]$RestartAppleUsb4Router,
    [int]$SettleSeconds = 5,
    [string]$LogPath
)

$ErrorActionPreference = "Continue"

$scriptRoot = $PSScriptRoot
$repairScript = Join-Path $scriptRoot "Repair-StudioDisplayExternalMode.ps1"
$reportsRoot = Join-Path $scriptRoot "reports"

if (-not $LogPath) {
    New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null
    $LogPath = Join-Path $reportsRoot ("StudioDisplayXdrLinkRefresh-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

function Write-RefreshLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedRefresh {
    $powershellExe = Join-Path $PSHOME "powershell.exe"
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-LogPath", "`"$LogPath`""
    )

    if ($SkipGraphicsHotkey) {
        $arguments += "-SkipGraphicsHotkey"
    }

    if ($AllowGraphicsHotkey) {
        $arguments += "-AllowGraphicsHotkey"
    }

    if ($AllowDisplaySwitchRefresh) {
        $arguments += "-AllowDisplaySwitchRefresh"
    }

    if ($RestartFallbackMonitor) {
        $arguments += "-RestartFallbackMonitor"
    }

    if ($RestartAppleUsb4Router) {
        $arguments += "-RestartAppleUsb4Router"
    }

    if ($SettleSeconds -ne 5) {
        $arguments += "-SettleSeconds"
        $arguments += [string]$SettleSeconds
    }

    Write-RefreshLog "Launching elevated refresh through UAC. Approve the prompt to run the PnP rescan."
    Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
}

if (-not (Test-IsAdministrator) -and $Elevate) {
    try {
        Start-ElevatedRefresh
        Write-RefreshLog "Elevated refresh was launched. Log will continue at: $LogPath"
        exit 0
    }
    catch {
        Write-RefreshLog "Could not launch elevated refresh: $($_.Exception.Message)"
        exit 1
    }
}

Add-Type -AssemblyName System.Windows.Forms

if (-not ("StudioDisplayLinkRefreshModeEnum" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct StudioDisplayLinkRefreshDevMode {
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

public static class StudioDisplayLinkRefreshModeEnum {
    public const int ENUM_CURRENT_SETTINGS = -1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref StudioDisplayLinkRefreshDevMode devMode);
}
"@
}

if (-not ("StudioDisplayLinkRefreshKeyboard" -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class StudioDisplayLinkRefreshKeyboard {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}
"@
}

function Get-DisplayModes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName
    )

    $modes = New-Object System.Collections.Generic.List[object]
    $modeIndex = 0

    while ($true) {
        $devMode = New-Object StudioDisplayLinkRefreshDevMode
        $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayLinkRefreshDevMode])

        if (-not [StudioDisplayLinkRefreshModeEnum]::EnumDisplaySettings($DeviceName, $modeIndex, [ref]$devMode)) {
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

    return $modes | Sort-Object Width, Height, RefreshRate -Unique
}

function Get-CurrentDisplayMode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeviceName
    )

    $devMode = New-Object StudioDisplayLinkRefreshDevMode
    $devMode.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][StudioDisplayLinkRefreshDevMode])

    if (-not [StudioDisplayLinkRefreshModeEnum]::EnumDisplaySettings(
            $DeviceName,
            [StudioDisplayLinkRefreshModeEnum]::ENUM_CURRENT_SETTINGS,
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

function Get-CurrentModeSummary {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    if (-not $screen) {
        return "unknown"
    }

    $current = Get-CurrentDisplayMode -DeviceName $screen.DeviceName
    $currentText = if ($current) { "$($current.Width)x$($current.Height)@$($current.RefreshRate)Hz" } else { "unknown" }
    $modes = @(Get-DisplayModes -DeviceName $screen.DeviceName)
    if (-not $modes) {
        return "$($screen.DeviceName) current=$currentText current-bounds=$($screen.Bounds.ToString()) max=none"
    }

    $best = $modes |
        Sort-Object `
            @{ Expression = { -($_.Width * $_.Height) } }, `
            @{ Expression = { -$_.RefreshRate } } |
        Select-Object -First 1

    return "$($screen.DeviceName) current=$currentText current-bounds=$($screen.Bounds.ToString()) max=$($best.Width)x$($best.Height)@$($best.RefreshRate)Hz mode-count=$($modes.Count)"
}

function Test-NativeXdrModeEnumerated {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    if (-not $screen) {
        return $false
    }

    $modes = @(Get-DisplayModes -DeviceName $screen.DeviceName)
    return [bool]($modes | Where-Object {
            $_.Width -eq 5120 -and
            $_.Height -eq 2880 -and
            $_.RefreshRate -eq 120
        } | Select-Object -First 1)
}

function Test-StudioDisplayEvidencePresent {
    $applePattern = "Studio Display XDR|Studio Display|StudioDisplay|Pro Display XDR|Display XDR|DISPLAY\\APPA|VID_05AC&PID_1114|VID_05AC&PID_1116|USB4\\VID_8087&PID_5786"
    $presentEvidence = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -match $applePattern -or
            $_.FriendlyName -match $applePattern
        } |
        Select-Object -First 1)

    return [bool]$presentEvidence
}

function Test-ActiveMsFallbackMonitor {
    try {
        $activeMs = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop |
            Where-Object { $_.Active -and $_.InstanceName -match '^DISPLAY\\MS_0001\\' } |
            Select-Object -First 1

        return [bool]$activeMs
    }
    catch {
        Write-RefreshLog "Could not check whether DISPLAY\\MS_0001 is the active monitor identity: $($_.Exception.Message)"
        return $false
    }
}

function Test-Studio5KModeEnumerated {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    if (-not $screen) {
        return $false
    }

    $modes = @(Get-DisplayModes -DeviceName $screen.DeviceName)
    return [bool]($modes | Where-Object {
            $_.Width -eq 5120 -and
            $_.Height -eq 2880 -and
            $_.RefreshRate -ge 30
        } | Select-Object -First 1)
}

function Test-CurrentStudio5KModeActive {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    if (-not $screen) {
        return $false
    }

    $current = Get-CurrentDisplayMode -DeviceName $screen.DeviceName
    return [bool]($current -and $current.Width -eq 5120 -and $current.Height -eq 2880)
}

function Invoke-DisplaySwitchRefresh {
    $displaySwitch = Join-Path $env:WINDIR "System32\DisplaySwitch.exe"

    foreach ($argument in @("/external", "/extend", "/external")) {
        Write-RefreshLog "Running DisplaySwitch.exe $argument"
        Start-Process -FilePath $displaySwitch -ArgumentList $argument -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        Start-Sleep -Seconds $SettleSeconds
        Write-RefreshLog "Display state after ${argument}: $(Get-CurrentModeSummary)"

        if (Test-NativeXdrModeEnumerated -or Test-Studio5KModeEnumerated) {
            Write-RefreshLog "Studio Display 5K mode appeared after DisplaySwitch $argument."
            return $true
        }
    }

    return $false
}

function Invoke-GraphicsHotkeyRefresh {
    if ($SkipGraphicsHotkey) {
        Write-RefreshLog "Skipping graphics hotkey refresh."
        return
    }

    if (-not $AllowGraphicsHotkey) {
        Write-RefreshLog "Skipping graphics hotkey refresh because -AllowGraphicsHotkey was not passed."
        return
    }

    Write-RefreshLog "Sending Win+Ctrl+Shift+B graphics refresh hotkey. A brief screen blink is expected."
    $keyUp = 0x0002
    $vkWin = 0x5B
    $vkControl = 0x11
    $vkShift = 0x10
    $vkB = 0x42

    [StudioDisplayLinkRefreshKeyboard]::keybd_event($vkWin, 0, 0, [UIntPtr]::Zero)
    [StudioDisplayLinkRefreshKeyboard]::keybd_event($vkControl, 0, 0, [UIntPtr]::Zero)
    [StudioDisplayLinkRefreshKeyboard]::keybd_event($vkShift, 0, 0, [UIntPtr]::Zero)
    [StudioDisplayLinkRefreshKeyboard]::keybd_event($vkB, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 100
    [StudioDisplayLinkRefreshKeyboard]::keybd_event($vkB, 0, $keyUp, [UIntPtr]::Zero)
    [StudioDisplayLinkRefreshKeyboard]::keybd_event($vkShift, 0, $keyUp, [UIntPtr]::Zero)
    [StudioDisplayLinkRefreshKeyboard]::keybd_event($vkControl, 0, $keyUp, [UIntPtr]::Zero)
    [StudioDisplayLinkRefreshKeyboard]::keybd_event($vkWin, 0, $keyUp, [UIntPtr]::Zero)

    Start-Sleep -Seconds $SettleSeconds
    Write-RefreshLog "Display state after graphics hotkey: $(Get-CurrentModeSummary)"
}

function Invoke-PnpRescan {
    if (-not (Test-IsAdministrator)) {
        Write-RefreshLog "Skipping PnP rescan because this process is not elevated. Re-run with -Elevate or as administrator."
        return
    }

    Write-RefreshLog "Running pnputil /scan-devices"
    $output = & pnputil /scan-devices 2>&1
    foreach ($line in $output) {
        Write-RefreshLog "pnputil: $line"
    }
    Write-RefreshLog "pnputil exit code: $LASTEXITCODE"
    Start-Sleep -Seconds $SettleSeconds
    Write-RefreshLog "Display state after PnP rescan: $(Get-CurrentModeSummary)"
}

function Invoke-FallbackMonitorRestart {
    if (-not $RestartFallbackMonitor) {
        Write-RefreshLog "Skipping fallback monitor restart. Pass -RestartFallbackMonitor to restart DISPLAY\\MS_0001."
        return
    }

    if (-not (Test-IsAdministrator)) {
        Write-RefreshLog "Skipping fallback monitor restart because this process is not elevated."
        return
    }

    if (-not (Test-ActiveMsFallbackMonitor)) {
        Write-RefreshLog "Skipping DISPLAY\\MS_0001 fallback monitor restart because MS_0001 is not the active monitor identity. Preserving the Apple/APPA identity avoids pushing a potentially HDR-capable path back onto the Boot Camp fallback during hot-plug recovery."
        return
    }

    $fallbackMonitor = Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match '^DISPLAY\\MS_0001\\' } |
        Select-Object -First 1

    if (-not $fallbackMonitor) {
        Write-RefreshLog "No present DISPLAY\\MS_0001 fallback monitor device was found."
        return
    }

    Write-RefreshLog "Restarting fallback monitor device: $($fallbackMonitor.InstanceId)"
    $output = & pnputil /restart-device "$($fallbackMonitor.InstanceId)" 2>&1
    foreach ($line in $output) {
        Write-RefreshLog "pnputil restart: $line"
    }
    Write-RefreshLog "pnputil restart exit code: $LASTEXITCODE"

    Start-Sleep -Seconds $SettleSeconds
    Invoke-PnpRescan
    Write-RefreshLog "Display state after fallback monitor restart: $(Get-CurrentModeSummary)"
}

function Invoke-AppleUsb4RouterRestart {
    if (-not $RestartAppleUsb4Router) {
        return
    }

    if (-not (Test-IsAdministrator)) {
        Write-RefreshLog "Skipping Apple USB4 router restart because this process is not elevated."
        return
    }

    $router = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $_.InstanceId -match '^USB4\\VID_8087&PID_5786\\' -or
            $_.FriendlyName -match 'Studio Display XDR'
        } |
        Sort-Object @{ Expression = { if ($_.InstanceId -match '^USB4\\VID_8087&PID_5786\\') { 0 } else { 1 } } } |
        Select-Object -First 1

    if (-not $router) {
        Write-RefreshLog "No present Apple Studio Display XDR USB4 router was found."
        return
    }

    Write-RefreshLog "Restarting Apple Studio Display XDR USB4 router: $($router.InstanceId)"
    Write-RefreshLog "A temporary display/audio/camera disconnect is expected during USB4 link retraining."
    $output = & pnputil /restart-device "$($router.InstanceId)" 2>&1
    foreach ($line in $output) {
        Write-RefreshLog "pnputil usb4 restart: $line"
    }
    Write-RefreshLog "pnputil usb4 restart exit code: $LASTEXITCODE"

    Start-Sleep -Seconds ([Math]::Max($SettleSeconds + 5, 10))
    Invoke-PnpRescan
    Write-RefreshLog "Display state after Apple USB4 router restart: $(Get-CurrentModeSummary)"
}

function Invoke-NativeModeRepair {
    if (-not (Test-Path -LiteralPath $repairScript)) {
        Write-RefreshLog "Repair script not found: $repairScript"
        return
    }

    if (-not (Test-StudioDisplayEvidencePresent) -and -not (Test-Studio5KModeEnumerated) -and -not (Test-CurrentStudio5KModeActive)) {
        Write-RefreshLog "Skipping native mode repair because no present Apple display evidence or 5K target is visible. This avoids applying display repair to the internal panel."
        return
    }

    Write-RefreshLog "Running native mode repair guard."
    $repairArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $repairScript,
        "-Topology", "External",
        "-ExpectedWidth", "5120",
        "-ExpectedHeight", "2880",
        "-ExpectedRefreshRate", "60",
        "-RefreshRate", "60",
        "-SkipSafetyMode",
        "-RequireExternalOnly",
        "-PreserveActiveHdr"
    )
    if ($AllowDisplaySwitchRefresh) {
        $repairArgs += "-AllowDisplaySwitchFallback"
    }

    $output = & powershell.exe @repairArgs 2>&1
    foreach ($line in $output) {
        Write-RefreshLog "repair: $line"
    }
    Write-RefreshLog "repair exit code: $LASTEXITCODE"
}

Write-RefreshLog "Studio Display XDR link refresh started. Elevated=$(Test-IsAdministrator)"
Write-RefreshLog "Initial display state: $(Get-CurrentModeSummary)"

if (Test-NativeXdrModeEnumerated) {
    Write-RefreshLog "Native Studio Display XDR mode is already enumerated."
    Invoke-NativeModeRepair
    exit 0
}

if (Test-Studio5KModeEnumerated) {
    Write-RefreshLog "Studio Display 5K fallback mode is already enumerated."
    Invoke-NativeModeRepair
    exit 0
}

if (-not (Test-IsAdministrator)) {
    Write-RefreshLog "Mode table is missing the Studio Display 5K target, and this process is not elevated. Skipping DisplaySwitch-only refresh; re-run with -Elevate for PnP rescan/router restart."
    exit 3
}

if ($AllowDisplaySwitchRefresh) {
    [void](Invoke-DisplaySwitchRefresh)
}
else {
    Write-RefreshLog "Skipping DisplaySwitch refresh because -AllowDisplaySwitchRefresh was not passed. Automatic repair will prefer PnP/USB4 paths to avoid showing the Windows projection UI."
}

if (-not (Test-NativeXdrModeEnumerated) -and -not (Test-Studio5KModeEnumerated)) {
    Invoke-GraphicsHotkeyRefresh
}

if (-not (Test-NativeXdrModeEnumerated) -and -not (Test-Studio5KModeEnumerated)) {
    Invoke-PnpRescan
}

if (-not (Test-NativeXdrModeEnumerated) -and -not (Test-Studio5KModeEnumerated)) {
    Invoke-FallbackMonitorRestart
}

if (-not (Test-NativeXdrModeEnumerated) -and -not (Test-Studio5KModeEnumerated)) {
    Invoke-AppleUsb4RouterRestart
}

Invoke-NativeModeRepair

if (Test-NativeXdrModeEnumerated) {
    Write-RefreshLog "Studio Display XDR native 5120x2880@120 is now enumerated."
    exit 0
}

if (Test-Studio5KModeEnumerated) {
    Write-RefreshLog "Studio Display 5K fallback mode is now enumerated."
    exit 0
}

Write-RefreshLog "Boot Camp-style 5120x2880@60 mode is still missing from the Windows mode table. Current state: $(Get-CurrentModeSummary)"
Write-RefreshLog "Next step: use -RestartAppleUsb4Router, reconnect the display on a direct Thunderbolt 5/USB4 port, or power-cycle the display to force a USB4/EDID retrain. 5120x2880@120 remains diagnostic-only and is not required for the stable HDR pipeline."
exit 2
