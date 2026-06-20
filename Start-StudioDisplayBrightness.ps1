[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\studio-brightness"
$exePath = Join-Path $installRoot "studio-brightness.exe"

if (-not (Test-Path $exePath)) {
    throw "studio-brightness is not installed. Run Install-StudioDisplayBrightness.ps1 first."
}

$running = Get-Process -Name "studio-brightness" -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "studio-brightness is already running."
    exit 0
}

Start-Process -FilePath $exePath -WorkingDirectory $installRoot
Start-Sleep -Seconds 2

$running = Get-Process -Name "studio-brightness" -ErrorAction SilentlyContinue
if ($running) {
    Write-Host "studio-brightness started."
} else {
    throw "studio-brightness did not start successfully."
}

