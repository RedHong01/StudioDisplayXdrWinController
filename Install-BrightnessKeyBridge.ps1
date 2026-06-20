[CmdletBinding()]
param(
    [switch]$SkipAutoStart,
    [switch]$SkipStartNow
)

$ErrorActionPreference = "Stop"

$sourceRoot = $PSScriptRoot
$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\BrightnessKeyBridge"
$scriptSource = Join-Path $sourceRoot "BrightnessKeyBridge.ps1"
$scriptTarget = Join-Path $installRoot "BrightnessKeyBridge.ps1"
$hidHelperSource = Join-Path $sourceRoot "StudioDisplayHid.ps1"
$hidHelperTarget = Join-Path $installRoot "StudioDisplayHid.ps1"
$startupShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\Studio Display Brightness Keys.lnk"
$powershellExe = Join-Path $PSHOME "powershell.exe"

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [string]$Arguments,
        [string]$WorkingDirectory
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    $shortcut.Arguments = $Arguments
    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    $shortcut.Save()
}

New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
Copy-Item -LiteralPath $scriptSource -Destination $scriptTarget -Force
Copy-Item -LiteralPath $hidHelperSource -Destination $hidHelperTarget -Force

if (-not $SkipAutoStart) {
    if (Test-Path $startupShortcut) {
        Remove-Item -LiteralPath $startupShortcut -Force
    }

    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptTarget`" -EnableLogging -StepPercent 10"
    New-Shortcut -Path $startupShortcut -TargetPath $powershellExe -Arguments $arguments -WorkingDirectory $installRoot
    Write-Host "Brightness key bridge auto-start shortcut created."
} else {
    Write-Host "Skipped brightness key bridge auto-start creation."
}

if (-not $SkipStartNow) {
    Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $scriptTarget,
        "-EnableLogging",
        "-StepPercent", "10"
    )
    Start-Sleep -Seconds 2
}

$pidFile = Join-Path $installRoot "BrightnessKeyBridge.pid"
if (Test-Path $pidFile) {
    Write-Host "Brightness key bridge is running."
} else {
    Write-Warning "Brightness key bridge was installed, but it is not confirmed running yet."
}
