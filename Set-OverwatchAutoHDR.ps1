[CmdletBinding()]
param(
    [ValidateSet("Disable", "Restore")]
    [string]$Action = "Disable",
    [string]$UserSid,
    [string]$OverwatchPath
)

$ErrorActionPreference = "Stop"

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

if (-not $UserSid) {
    $UserSid = Get-CurrentUserSid
}

$OverwatchPath = Resolve-OverwatchExecutablePath -Path $OverwatchPath

$registryPath = "Registry::HKEY_USERS\$UserSid\Software\Microsoft\DirectX\UserGpuPreferences"
$backupRoot = Join-Path $PSScriptRoot "backups"
$backupPath = Join-Path $backupRoot "OverwatchAutoHDR.backup.txt"

function Set-TokenValue {
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

if (-not (Test-Path $registryPath)) {
    throw "Registry path not found: $registryPath"
}

$key = Get-Item -LiteralPath $registryPath
$currentValue = [string]$key.GetValue($OverwatchPath, "")

if ($Action -eq "Restore") {
    if (-not (Test-Path $backupPath)) {
        throw "Backup not found: $backupPath"
    }

    $originalValue = Get-Content -LiteralPath $backupPath -Raw
    $originalValue = $originalValue.TrimEnd("`r", "`n")
    Set-ItemProperty -LiteralPath $registryPath -Name $OverwatchPath -Value $originalValue
    Write-Host "Restored Overwatch Auto HDR registry value:"
    Write-Host $originalValue
    exit 0
}

New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

if (-not (Test-Path $backupPath)) {
    Set-Content -LiteralPath $backupPath -Value $currentValue -Encoding ascii
}

if ([string]::IsNullOrWhiteSpace($currentValue)) {
    $currentValue = "AppStatus=4096;"
}

$newValue = Set-TokenValue -Value $currentValue -TokenName "AutoHDREnable" -TokenValue "2096"
Set-ItemProperty -LiteralPath $registryPath -Name $OverwatchPath -Value $newValue

$verifiedValue = [string](Get-Item -LiteralPath $registryPath).GetValue($OverwatchPath, "")

Write-Host "Overwatch Auto HDR disabled."
Write-Host "Before: $currentValue"
Write-Host "After : $verifiedValue"
Write-Host "Backup: $backupPath"
