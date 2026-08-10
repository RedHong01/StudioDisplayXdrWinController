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

function Get-DevicePropertyData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstanceId,
        [Parameter(Mandatory = $true)]
        [string]$KeyName
    )

    try {
        $property = Get-PnpDeviceProperty -InstanceId $InstanceId -KeyName $KeyName -ErrorAction Stop
        return $property.Data
    }
    catch {
        return $null
    }
}

function Get-AppleDisplayUsbDeviceState {
    try {
        return @(
            Get-PnpDevice -PresentOnly -ErrorAction Stop |
                Where-Object { $_.InstanceId -match $appleDisplayUsbPattern } |
                Sort-Object InstanceId |
                ForEach-Object {
                    $parent = Get-DevicePropertyData -InstanceId $_.InstanceId -KeyName "DEVPKEY_Device_Parent"
                    $driverProblem = Get-DevicePropertyData -InstanceId $_.InstanceId -KeyName "DEVPKEY_Device_DriverProblemDesc"
                    $driverInf = Get-DevicePropertyData -InstanceId $_.InstanceId -KeyName "DEVPKEY_Device_DriverInfPath"
                    $service = Get-DevicePropertyData -InstanceId $_.InstanceId -KeyName "DEVPKEY_Device_Service"
                    [pscustomobject]@{
                        Class = $_.Class
                        FriendlyName = $_.FriendlyName
                        InstanceId = $_.InstanceId
                        Status = $_.Status
                        Problem = $_.Problem
                        ConfigManagerErrorCode = $_.ConfigManagerErrorCode
                        Parent = $parent
                        Service = $service
                        DriverInfPath = $driverInf
                        DriverProblemDesc = $driverProblem
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

function Write-AppleUsbDeviceTable {
    param([object[]]$Devices)

    $Devices |
        Select-Object Class, FriendlyName, Status, Problem, ConfigManagerErrorCode, Service, DriverInfPath, InstanceId |
        Format-Table -AutoSize |
        Out-String |
        ForEach-Object { $_.TrimEnd() } |
        Where-Object { $_ } |
        ForEach-Object { Write-UsbRepairLog $_ }

    foreach ($device in @($Devices | Where-Object { $_.NeedsRestart -and -not [string]::IsNullOrWhiteSpace($_.DriverProblemDesc) })) {
        Write-UsbRepairLog "Driver problem for $($device.InstanceId): $($device.DriverProblemDesc)"
    }
}

function Invoke-PnpRestart {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$InstanceId
    )

    Write-UsbRepairLog "Restarting ${Label}: $InstanceId"
    $output = & pnputil.exe /restart-device $InstanceId 2>&1
    $exitCode = $LASTEXITCODE
    foreach ($line in $output) {
        Write-UsbRepairLog "pnputil: $line"
    }

    Write-UsbRepairLog "Restart result for ${Label} $InstanceId`: exitCode=$exitCode"
    return $exitCode
}

function Invoke-PnpScanAndSettle {
    param([int]$Seconds = 8)

    $scanOutput = & pnputil.exe /scan-devices 2>&1
    foreach ($line in $scanOutput) {
        Write-UsbRepairLog "pnputil: $line"
    }

    Start-Sleep -Seconds $Seconds
}

function Get-UpstreamAppleUsbParentTargets {
    param([object[]]$Devices)

    $targets = New-Object System.Collections.Generic.List[object]
    $composites = @(
        $Devices |
            Where-Object {
                $_.Class -eq "USB" -and
                $_.InstanceId -match '^USB\\VID_05AC&PID_(1114|1116)\\' -and
                -not $_.NeedsRestart
            }
    )

    foreach ($composite in $composites) {
        if ([string]::IsNullOrWhiteSpace($composite.Parent)) {
            continue
        }

        if ($composite.Parent -notmatch '^USB\\VID_05AC&PID_') {
            continue
        }

        try {
            $parentDevice = Get-PnpDevice -PresentOnly -InstanceId $composite.Parent -ErrorAction Stop
            $targets.Add([pscustomobject]@{
                InstanceId = $parentDevice.InstanceId
                FriendlyName = $parentDevice.FriendlyName
                Status = $parentDevice.Status
                Problem = $parentDevice.Problem
                SourceComposite = $composite.InstanceId
            }) | Out-Null
        }
        catch {
            Write-UsbRepairLog "Could not resolve upstream Apple USB parent $($composite.Parent) for $($composite.InstanceId): $($_.Exception.Message)"
        }
    }

    return @($targets | Sort-Object InstanceId -Unique)
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
Write-AppleUsbDeviceTable -Devices $devices

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
    $exitCode = Invoke-PnpRestart -Label "Apple USB/HID interface" -InstanceId $device.InstanceId
    if ($exitCode -ne 0) {
        $restartFailures++
    }
}

Start-Sleep -Seconds 3
$after = @(Get-AppleDisplayUsbDeviceState)
Write-UsbRepairLog "Apple USB interface state after restart:"
Write-AppleUsbDeviceTable -Devices $after

$remainingFailures = @($after | Where-Object { $_.NeedsRestart })
if ($remainingFailures.Count -gt 0) {
    $compositeTargets = @(
        $after |
            Where-Object {
                $_.Class -eq "USB" -and
                $_.InstanceId -match '^USB\\VID_05AC&PID_(1114|1116)\\' -and
                -not $_.NeedsRestart
            } |
            Sort-Object InstanceId -Unique
    )

    if ($compositeTargets.Count -gt 0) {
        Write-UsbRepairLog "Failed Apple USB/HID child interfaces remain after direct restart. Restarting the parent Apple USB Composite Device once to force a full interface re-enumeration."
        foreach ($device in $compositeTargets) {
            $exitCode = Invoke-PnpRestart -Label "Apple USB composite parent" -InstanceId $device.InstanceId
            if ($exitCode -eq 50) {
                Write-UsbRepairLog "Composite restart returned exit code 50. Windows reports this device needs a pending operation/reboot or the restart verb is unsupported for this composite parent; escalating to the upstream Apple USB parent if one is available."
            }
            if ($exitCode -ne 0) {
                $restartFailures++
            }
        }

        Invoke-PnpScanAndSettle -Seconds 8
        $after = @(Get-AppleDisplayUsbDeviceState)
        Write-UsbRepairLog "Apple USB interface state after composite restart/rescan:"
        Write-AppleUsbDeviceTable -Devices $after

        $remainingFailures = @($after | Where-Object { $_.NeedsRestart })
    }
    else {
        Write-UsbRepairLog "Failed Apple USB/HID child interfaces remain, but no healthy Apple USB Composite Device parent was found to restart."
    }
}

if ($remainingFailures.Count -gt 0) {
    $upstreamTargets = @(Get-UpstreamAppleUsbParentTargets -Devices $after)
    if ($upstreamTargets.Count -gt 0) {
        Write-UsbRepairLog "Failed Apple USB/HID child interfaces remain after composite handling. Restarting the upstream Apple USB parent once to rebuild the XDR USB interface collection."
        foreach ($device in $upstreamTargets) {
            Write-UsbRepairLog "Upstream parent candidate: $($device.InstanceId) friendlyName='$($device.FriendlyName)' status=$($device.Status) problem=$($device.Problem) sourceComposite=$($device.SourceComposite)"
            $exitCode = Invoke-PnpRestart -Label "upstream Apple USB parent" -InstanceId $device.InstanceId
            if ($exitCode -ne 0) {
                $restartFailures++
            }
        }

        Invoke-PnpScanAndSettle -Seconds 12
        $after = @(Get-AppleDisplayUsbDeviceState)
        Write-UsbRepairLog "Apple USB interface state after upstream parent restart/rescan:"
        Write-AppleUsbDeviceTable -Devices $after
        $remainingFailures = @($after | Where-Object { $_.NeedsRestart })
    }
    else {
        Write-UsbRepairLog "Failed Apple USB/HID child interfaces remain, but no upstream Apple USB parent could be resolved from the current composite device."
    }
}

if ($restartFailures -gt 0 -or $remainingFailures.Count -gt 0) {
    Write-UsbRepairLog "Apple USB interface repair finished with unresolved failed interfaces. Boot Camp USB/reference-mode support may still be missing."
    exit 4
}

Write-UsbRepairLog "Apple USB interface repair finished successfully."
exit 0
