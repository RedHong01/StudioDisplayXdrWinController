[CmdletBinding()]
param(
    [switch]$DisplaySettings,
    [switch]$ColorManagement,
    [switch]$Calibration,
    [switch]$All
)

$ErrorActionPreference = "Stop"

if (-not ($DisplaySettings -or $ColorManagement -or $Calibration -or $All)) {
    $All = $true
}

if ($All -or $DisplaySettings) {
    Start-Process "ms-settings:display"
}

if ($All -or $ColorManagement) {
    Start-Process (Join-Path $env:WINDIR "System32\colorcpl.exe")
}

if ($All -or $Calibration) {
    Start-Process (Join-Path $env:WINDIR "System32\dccw.exe")
}

Write-Host "Opened the requested Windows color tools."
