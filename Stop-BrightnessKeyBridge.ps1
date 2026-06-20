[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\BrightnessKeyBridge"
$pidFile = Join-Path $installRoot "BrightnessKeyBridge.pid"

if (-not (Test-Path $pidFile)) {
    Write-Host "Brightness key bridge is not running."
    exit 0
}

$pid = Get-Content -LiteralPath $pidFile | Select-Object -First 1
if ($pid) {
    try {
        Stop-Process -Id ([int]$pid) -Force -ErrorAction Stop
    }
    catch {
    }
}

Start-Sleep -Seconds 1

if (Test-Path $pidFile) {
    Remove-Item -LiteralPath $pidFile -Force
}

Write-Host "Brightness key bridge stopped."
