[CmdletBinding()]
param(
    [string]$TaskName = "Studio Display XDR Win Controller Auto Repair",
    [string]$AppName = "Studio Display XDR Win Controller",
    [string]$InstallRoot = $PSScriptRoot,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$autoRepairPath = Join-Path $InstallRoot "Invoke-StudioDisplayAutoRepair.ps1"
$reportsRoot = Join-Path $InstallRoot "reports"
$logPath = Join-Path $reportsRoot "StudioDisplayAutoRepairTaskRegistration.log"

function Resolve-StudioDisplayPowerShellExe {
    $candidates = @(
        (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"),
        (Join-Path $PSHOME "powershell.exe")
    )

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($command -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    return "powershell.exe"
}

$powershellExe = Resolve-StudioDisplayPowerShellExe

New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null

function Write-RegistrationLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    if (-not $Quiet) {
        Write-Host $line
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-RegistrationLog "Auto repair task registration started. TaskName=$TaskName InstallRoot=$InstallRoot Elevated=$(Test-IsAdministrator)"

if (-not (Test-Path -LiteralPath $autoRepairPath)) {
    Write-RegistrationLog "Auto repair launcher is missing: $autoRepairPath"
    exit 1
}

if (-not (Test-IsAdministrator)) {
    Write-RegistrationLog "Registration requires administrator token. Launch this script through UAC or an elevated PowerShell window."
    exit 5
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$taskArguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$autoRepairPath`""
$action = New-ScheduledTaskAction -Execute $powershellExe -Argument $taskArguments -WorkingDirectory $InstallRoot
$principal = New-ScheduledTaskPrincipal -UserId $currentIdentity -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Principal $principal `
    -Settings $settings `
    -Description "$AppName on-demand elevated repair for Thunderbolt hot-plug 5K/HDR/brightness recovery." `
    -Force | Out-Null

Write-RegistrationLog "Auto repair task registered successfully."

exit 0
