[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager"
$legacyInstallRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\SystemBrightnessMirror"
$appName = "Studio Display XDR Win Controller"
$pidFiles = @(
    (Join-Path $installRoot "StudioDisplayManager.pid"),
    (Join-Path $installRoot "SystemBrightnessMirror.pid"),
    (Join-Path $installRoot "BrightnessKeyBridge.pid"),
    (Join-Path $legacyInstallRoot "SystemBrightnessMirrorTray.pid"),
    (Join-Path $legacyInstallRoot "StudioDisplayManager.pid"),
    (Join-Path $legacyInstallRoot "SystemBrightnessMirror.pid")
)

function Stop-ManagedProcess {
    param([string]$PidPath)

    if (-not (Test-Path $PidPath)) {
        return $false
    }

    $managedPid = Get-Content -LiteralPath $PidPath | Select-Object -First 1
    if ($managedPid -match '^\d+$') {
        Stop-Process -Id ([int]$managedPid) -Force -ErrorAction SilentlyContinue
    }

    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    return $true
}

$stoppedAny = $false
foreach ($pidFile in $pidFiles) {
    if (Stop-ManagedProcess -PidPath $pidFile) {
        $stoppedAny = $true
    }
}

if ($stoppedAny) {
    Write-Host "$appName stopped."
} else {
    Write-Host "$appName is not running."
}
