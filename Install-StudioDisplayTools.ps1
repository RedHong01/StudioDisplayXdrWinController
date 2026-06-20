[CmdletBinding()]
param(
    [switch]$SkipBrightnessUtility,
    [switch]$SkipManager,
    [switch]$SkipBrightnessKeyBridge,
    [switch]$SkipAutoStart,
    [switch]$SkipStartNow
)

$ErrorActionPreference = "Stop"

$sourceRoot = $PSScriptRoot

function Get-SharedInstallArguments {
    $arguments = @()

    if ($SkipAutoStart) {
        $arguments += "-SkipAutoStart"
    }

    if ($SkipStartNow) {
        $arguments += "-SkipStartNow"
    }

    return $arguments
}

function Invoke-LocalInstallScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,
        [string[]]$ArgumentList = @()
    )

    $scriptPath = Join-Path $sourceRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Required installer script was not found: $scriptPath"
    }

    Write-Host ""
    Write-Host "==> Running $ScriptName"
    & $scriptPath @ArgumentList
}

$sharedArguments = Get-SharedInstallArguments

if (-not $SkipBrightnessUtility) {
    Invoke-LocalInstallScript -ScriptName "Install-StudioDisplayBrightness.ps1" -ArgumentList $sharedArguments
}

if (-not $SkipManager) {
    Invoke-LocalInstallScript -ScriptName "Install-StudioDisplayManager.ps1" -ArgumentList $sharedArguments
}

if (-not $SkipBrightnessKeyBridge) {
    Invoke-LocalInstallScript -ScriptName "Install-BrightnessKeyBridge.ps1" -ArgumentList $sharedArguments
}

Write-Host ""
Write-Host "Studio Display Tools installation finished."
