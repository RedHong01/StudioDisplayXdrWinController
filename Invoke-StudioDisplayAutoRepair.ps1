[CmdletBinding()]
param(
    [string]$Reason = "scheduled hot-plug HDR repair"
)

$ErrorActionPreference = "Continue"

$scriptRoot = $PSScriptRoot
$reportsRoot = Join-Path $scriptRoot "reports"
$integratedRepairScript = Join-Path $scriptRoot "Repair-StudioDisplayIntegrated.ps1"
$logPath = Join-Path $reportsRoot ("StudioDisplayAutoIntegratedRepair-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
$launcherLog = Join-Path $reportsRoot "StudioDisplayAutoRepairTask.log"
$powershellExe = Join-Path $PSHOME "powershell.exe"

New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null

function Write-AutoRepairLog {
    param([string]$Message)

    $line = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Message
    Add-Content -LiteralPath $launcherLog -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
}

Write-AutoRepairLog "Scheduled auto repair started. Reason=$Reason Log=$logPath"

if (-not (Test-Path -LiteralPath $integratedRepairScript)) {
    Write-AutoRepairLog "Integrated repair script is missing: $integratedRepairScript"
    exit 1
}

& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $integratedRepairScript -Apply -RestartAppleUsb4Router -LogPath $logPath
$exitCode = $LASTEXITCODE

Write-AutoRepairLog "Scheduled auto repair finished with exit code $exitCode. Log=$logPath"
exit $exitCode
