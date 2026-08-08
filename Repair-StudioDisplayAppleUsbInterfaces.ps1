[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Elevate,
    [switch]$IncludeHealthy,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Continue"

$appleDisplayUsbPattern = 'VID_05AC&PID_1114|VID_05AC&PID_1116'
$powershellExe = Join-Path $PSHOME "powershell.exe"

function Write-UsbRepairLog {
    param([string]$Message)

    Write-Host $Message
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $parent = Split-Path -Parent $LogPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -LiteralPath $LogPath -Value "$timestamp $Message" -Encoding UTF8
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedSelf {
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`""
    )

    if ($Apply) {
        $arguments += "-Apply"
    }

    if ($IncludeHealthy) {
        $arguments += "-IncludeHealthy"
    }

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $arguments += "-LogPath"
        $arguments += "`"$LogPath`""
    }

    Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
}

function Get-AppleDisplayUsbDeviceState {
    try {
        return @(
            Get-PnpDevice -PresentOnly -ErrorAction Stop |
                Where-Object { $_.InstanceId -match $appleDisplayUsbPattern } |
                Sort-Object InstanceId |
                ForEach-Object {
                    [pscustomobject]@{
                        Class = $_.Class
                        FriendlyName = $_.FriendlyName
                        InstanceId = $_.InstanceId
                        Status = $_.Status
                        Problem = $_.Problem
                        ConfigManagerErrorCode = $_.ConfigManagerErrorCode
                        NeedsRestart = ($_.Status -ne "OK" -or $_.Problem -and $_.Problem -ne "CM_PROB_NONE")
                    }
                }
        )
    }
    catch {
        Write-UsbRepairLog "Get-PnpDevice failed: $($_.Exception.Message)"
        return @()
    }
}

Write-UsbRepairLog "Studio Display Apple USB interface repair started. Apply=$Apply Elevated=$(Test-IsAdministrator)"

if ($Elevate -and -not (Test-IsAdministrator)) {
    try {
        Start-ElevatedSelf
        Write-UsbRepairLog "Elevated Apple USB interface repair was launched."
        exit 0
    }
    catch {
        Write-UsbRepairLog "Could not launch elevated Apple USB interface repair: $($_.Exception.Message)"
        exit 1
    }
}

$devices = @(Get-AppleDisplayUsbDeviceState)
if (-not $devices) {
    Write-UsbRepairLog "No present Apple Studio Display USB/HID interfaces were found."
    exit 2
}

$targets = @($devices | Where-Object { $IncludeHealthy -or $_.NeedsRestart })
Write-UsbRepairLog "Apple USB interface summary:"
$devices |
    Select-Object Class, FriendlyName, Status, Problem, ConfigManagerErrorCode, InstanceId |
    Format-Table -AutoSize |
    Out-String |
    ForEach-Object { $_.TrimEnd() } |
    Where-Object { $_ } |
    ForEach-Object { Write-UsbRepairLog $_ }

if (-not $targets) {
    Write-UsbRepairLog "No failed Apple Studio Display USB/HID interfaces require restart."
    exit 0
}

if (-not $Apply) {
    Write-UsbRepairLog "Dry run only. Re-run with -Apply -Elevate to restart the failed Apple USB/HID interfaces."
    exit 0
}

if (-not (Test-IsAdministrator)) {
    Write-UsbRepairLog "Apply requires administrator rights because pnputil /restart-device is protected."
    exit 3
}

$restartFailures = 0
foreach ($device in $targets) {
    Write-UsbRepairLog "Restarting Apple USB/HID interface: $($device.InstanceId)"
    $output = & pnputil.exe /restart-device $device.InstanceId 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        Write-UsbRepairLog "pnputil: $line"
    }

    Write-UsbRepairLog "Restart result for $($device.InstanceId): exitCode=$exitCode"
    if ($exitCode -ne 0) {
        $restartFailures++
    }
}

Start-Sleep -Seconds 3
$after = @(Get-AppleDisplayUsbDeviceState)
Write-UsbRepairLog "Apple USB interface state after restart:"
$after |
    Select-Object Class, FriendlyName, Status, Problem, ConfigManagerErrorCode, InstanceId |
    Format-Table -AutoSize |
    Out-String |
    ForEach-Object { $_.TrimEnd() } |
    Where-Object { $_ } |
    ForEach-Object { Write-UsbRepairLog $_ }

$remainingFailures = @($after | Where-Object { $_.NeedsRestart })
if ($restartFailures -gt 0 -or $remainingFailures.Count -gt 0) {
    Write-UsbRepairLog "Apple USB interface repair finished with unresolved failed interfaces. Boot Camp USB/reference-mode support may still be missing."
    exit 4
}

Write-UsbRepairLog "Apple USB interface repair finished successfully."
exit 0
