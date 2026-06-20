[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\studio-brightness"
$startupShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\Studio Display Brightness.lnk"

$running = Get-Process -Name "studio-brightness" -ErrorAction SilentlyContinue
if ($running) {
    $running | Stop-Process -Force
}

if (Test-Path $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force
}

if (Test-Path $installRoot) {
    Remove-Item -LiteralPath $installRoot -Recurse -Force
}

Write-Host "studio-brightness has been removed."

