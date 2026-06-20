[CmdletBinding()]
param(
    [ValidateSet("Apply", "Restore")]
    [string]$Action = "Apply",
    [switch]$WaitForGameExit,
    [int]$FullScreenWidth = 5120,
    [int]$FullScreenHeight = 2880,
    [int]$FullScreenRefresh = 60,
    [string]$UserSid,
    [string]$OverwatchPath,
    [string]$SettingsPath = "$env:USERPROFILE\Documents\Overwatch\Settings\Settings_v0.ini"
)

$ErrorActionPreference = "Stop"

$backupRoot = Join-Path $PSScriptRoot "backups"
$gpuPrefBackup = Join-Path $backupRoot "OverwatchUserGpuPreferences.before-exclusive-fullscreen.txt"
$compatBackup = Join-Path $backupRoot "OverwatchAppCompatLayers.before-exclusive-fullscreen.txt"
$settingsBackup = Join-Path $backupRoot "Settings_v0.before-exclusive-fullscreen.ini"

function Get-CurrentUserSid {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Resolve-OverwatchExecutablePath {
    param([string]$Path)

    if ($Path) {
        if (Test-Path -LiteralPath $Path) {
            return (Resolve-Path -LiteralPath $Path).Path
        }

        throw "Overwatch executable not found: $Path"
    }

    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} "Steam\steamapps\common\Overwatch\Overwatch.exe"),
        (Join-Path $env:ProgramFiles "Steam\steamapps\common\Overwatch\Overwatch.exe"),
        "C:\Steam\steamapps\common\Overwatch\Overwatch.exe",
        "D:\Steam\steamapps\common\Overwatch\Overwatch.exe"
    ) | Where-Object { $_ }

    $match = $candidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1

    if ($match) {
        return (Resolve-Path -LiteralPath $match).Path
    }

    throw "Overwatch.exe could not be found automatically. Re-run with -OverwatchPath."
}

function Set-SemicolonToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$TokenName,
        [Parameter(Mandatory = $true)]
        [string]$TokenValue
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $found = $false

    foreach ($part in ($Value -split ';')) {
        if ([string]::IsNullOrWhiteSpace($part)) {
            continue
        }

        if ($part -like "$TokenName=*") {
            $parts.Add("$TokenName=$TokenValue")
            $found = $true
        }
        else {
            $parts.Add($part)
        }
    }

    if (-not $found) {
        $parts.Add("$TokenName=$TokenValue")
    }

    return (($parts -join ';') + ';')
}

function Add-AppCompatToken {
    param(
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "~ $Token"
    }

    $normalized = $Value.Trim()
    if ($normalized -notmatch '(^|\s)~(\s|$)') {
        $normalized = "~ $normalized"
    }

    if ($normalized -notmatch "(^|\s)$([regex]::Escape($Token))(\s|$)") {
        $normalized = "$normalized $Token"
    }

    return $normalized
}

function Set-IniValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$SectionPattern,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $sectionStart = -1
    $sectionEnd = $Lines.Count

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match "^\[$SectionPattern\]$") {
            $sectionStart = $i
            break
        }
    }

    if ($sectionStart -lt 0) {
        return @($Lines + "" + "[Render.13]" + "$Key = `"$Value`"")
    }

    for ($i = $sectionStart + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\[.+\]$') {
            $sectionEnd = $i
            break
        }
    }

    for ($i = $sectionStart + 1; $i -lt $sectionEnd; $i++) {
        if ($Lines[$i] -match "^\s*$([regex]::Escape($Key))\s*=") {
            $Lines[$i] = "$Key = `"$Value`""
            return $Lines
        }
    }

    $before = if ($sectionEnd -gt 0) { $Lines[0..($sectionEnd - 1)] } else { @() }
    $after = if ($sectionEnd -lt $Lines.Count) { $Lines[$sectionEnd..($Lines.Count - 1)] } else { @() }
    return @($before + "$Key = `"$Value`"" + $after)
}

function Wait-ForOverwatchExit {
    $process = Get-Process -Name Overwatch -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $process) {
        return
    }

    Write-Host "Overwatch is running. Waiting for it to exit before editing Settings_v0.ini..."
    Wait-Process -Id $process.Id
}

function Backup-TextValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowNull()]
        [string]$Value
    )

    if (-not (Test-Path $Path)) {
        Set-Content -LiteralPath $Path -Value ([string]$Value) -Encoding ascii
    }
}

if (-not $UserSid) {
    $UserSid = Get-CurrentUserSid
}

$OverwatchPath = Resolve-OverwatchExecutablePath -Path $OverwatchPath

$gpuPrefRegistryPath = "Registry::HKEY_USERS\$UserSid\Software\Microsoft\DirectX\UserGpuPreferences"
$compatRegistryPath = "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"

New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

if ($Action -eq "Restore") {
    if (Test-Path $gpuPrefBackup) {
        $value = (Get-Content -LiteralPath $gpuPrefBackup -Raw).TrimEnd("`r", "`n")
        New-Item -Path $gpuPrefRegistryPath -Force | Out-Null
        Set-ItemProperty -LiteralPath $gpuPrefRegistryPath -Name $OverwatchPath -Value $value
        Write-Host "Restored UserGpuPreferences."
    }

    if (Test-Path $compatBackup) {
        $value = (Get-Content -LiteralPath $compatBackup -Raw).TrimEnd("`r", "`n")
        New-Item -Path $compatRegistryPath -Force | Out-Null
        if ([string]::IsNullOrEmpty($value)) {
            Remove-ItemProperty -LiteralPath $compatRegistryPath -Name $OverwatchPath -ErrorAction SilentlyContinue
        }
        else {
            Set-ItemProperty -LiteralPath $compatRegistryPath -Name $OverwatchPath -Value $value
        }
        Write-Host "Restored AppCompat Layers."
    }

    if (Test-Path $settingsBackup) {
        Copy-Item -LiteralPath $settingsBackup -Destination $SettingsPath -Force
        Write-Host "Restored Settings_v0.ini."
    }

    exit 0
}

$gpuKey = New-Item -Path $gpuPrefRegistryPath -Force
$currentGpuPref = [string]$gpuKey.GetValue($OverwatchPath, "")
Backup-TextValue -Path $gpuPrefBackup -Value $currentGpuPref

if ([string]::IsNullOrWhiteSpace($currentGpuPref)) {
    $currentGpuPref = "AppStatus=0;"
}

$newGpuPref = Set-SemicolonToken -Value $currentGpuPref -TokenName "GpuPreference" -TokenValue "2"
$newGpuPref = Set-SemicolonToken -Value $newGpuPref -TokenName "AutoHDREnable" -TokenValue "2096"
Set-ItemProperty -LiteralPath $gpuPrefRegistryPath -Name $OverwatchPath -Value $newGpuPref

$compatKey = New-Item -Path $compatRegistryPath -Force
$currentCompat = [string]$compatKey.GetValue($OverwatchPath, "")
Backup-TextValue -Path $compatBackup -Value $currentCompat

$newCompat = Add-AppCompatToken -Value $currentCompat -Token "DISABLEDXMAXIMIZEDWINDOWEDMODE"
Set-ItemProperty -LiteralPath $compatRegistryPath -Name $OverwatchPath -Value $newCompat

$settingsEdited = $false
$gameRunning = [bool](Get-Process -Name Overwatch -ErrorAction SilentlyContinue)
if ($gameRunning -and $WaitForGameExit) {
    Wait-ForOverwatchExit
    $gameRunning = $false
}

if ($gameRunning) {
    Write-Warning "Skipped Settings_v0.ini because Overwatch is currently running. Re-run with -WaitForGameExit or close the game first."
}
elseif (Test-Path $SettingsPath) {
    if (-not (Test-Path $settingsBackup)) {
        Copy-Item -LiteralPath $SettingsPath -Destination $settingsBackup -Force
    }

    $item = Get-Item -LiteralPath $SettingsPath
    $wasReadOnly = [bool]($item.Attributes -band [System.IO.FileAttributes]::ReadOnly)
    if ($wasReadOnly) {
        $item.Attributes = $item.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
    }

    $lines = Get-Content -LiteralPath $SettingsPath
    $renderSectionPattern = "Render\.\d+"
    $settings = [ordered]@{
        FullScreenWidth = [string]$FullScreenWidth
        FullScreenHeight = [string]$FullScreenHeight
        FullScreenRefresh = [string]$FullScreenRefresh
        FullscreenWindow = "0"
        FullscreenWindowEnabled = "0"
        WindowMode = "0"
        VerticalSyncEnabled = "0"
    }

    foreach ($entry in $settings.GetEnumerator()) {
        $lines = Set-IniValue -Lines $lines -SectionPattern $renderSectionPattern -Key $entry.Key -Value $entry.Value
    }

    Set-Content -LiteralPath $SettingsPath -Value $lines -Encoding ascii
    if ($wasReadOnly) {
        (Get-Item -LiteralPath $SettingsPath).Attributes = (Get-Item -LiteralPath $SettingsPath).Attributes -bor [System.IO.FileAttributes]::ReadOnly
    }
    $settingsEdited = $true
}
else {
    Write-Warning "Settings file not found: $SettingsPath"
}

Write-Host "Applied Overwatch exclusive fullscreen profile."
Write-Host "Target fullscreen mode: ${FullScreenWidth}x${FullScreenHeight}@${FullScreenRefresh}Hz"
Write-Host "UserGpuPreferences: $newGpuPref"
Write-Host "AppCompat Layers: $newCompat"
Write-Host "Settings_v0.ini edited: $settingsEdited"
Write-Host "Backups: $backupRoot"
