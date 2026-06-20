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

Write-Section "Processes"
Get-Process -Name Overwatch,StudioDisplayManager,powershell -ErrorAction SilentlyContinue |
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

Write-Section "Video Controllers"
Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
    Select-Object Name, DriverVersion, DriverDate, VideoModeDescription, Status |
    Format-List

Write-Section "Studio Display Monitors"
Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceName -match 'APPAE3A|05AC' -or ($_.UserFriendlyName -and ([string]::new([char[]]$_.UserFriendlyName).Trim([char]0) -match 'Studio')) } |
    ForEach-Object {
        [pscustomobject]@{
            InstanceName = $_.InstanceName
            Manufacturer = [string]::new([char[]]$_.ManufacturerName).Trim([char]0)
            Name = [string]::new([char[]]$_.UserFriendlyName).Trim([char]0)
            Serial = [string]::new([char[]]$_.SerialNumberID).Trim([char]0)
        }
    } |
    Format-Table -AutoSize

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

Write-Section "Overwatch Settings"
$owSettings = Join-Path $env:USERPROFILE "Documents\Overwatch\Settings\Settings_v0.ini"
if (Test-Path $owSettings) {
    Get-Item -LiteralPath $owSettings | Select-Object FullName, LastWriteTime, Length | Format-List
    Get-Content -LiteralPath $owSettings
}
else {
    Write-Output "not found: $owSettings"
}

Write-Section "Latest Overwatch Error Logs"
$owLogRoot = Join-Path $env:USERPROFILE "Documents\Overwatch\Logs"
if (Test-Path $owLogRoot) {
    Get-ChildItem -LiteralPath $owLogRoot -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 20 FullName, LastWriteTime, Length |
        Format-Table -AutoSize
}
else {
    Write-Output "not found: $owLogRoot"
}

Write-Section "Studio Display Manager Log"
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
        $_.Message -match "TDR|Display driver|nvlddmkm|WUDFRd|Studio Display|APPAE3A"
    } |
    Sort-Object TimeCreated -Descending |
    Select-Object -First 80 TimeCreated, ProviderName, Id, LevelDisplayName, Message |
    Format-List
