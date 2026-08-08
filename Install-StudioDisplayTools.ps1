[CmdletBinding()]
param(
    [switch]$SkipManager,
    [switch]$SkipBrightnessUtility,
    [switch]$SkipBrightnessKeyBridge,
    [switch]$SkipAutoStart,
    [switch]$SkipStartNow
)

$ErrorActionPreference = "Stop"

$sourceRoot = $PSScriptRoot
$appName = "Studio Display XDR Win Controller"

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
    if ($ArgumentList -and $ArgumentList.Count -gt 0) {
        & $scriptPath @ArgumentList
    }
    else {
        & $scriptPath
    }
}

$sharedArguments = @(Get-SharedInstallArguments)

if ($SkipBrightnessUtility) {
    Write-Host ""
    Write-Host "==> -SkipBrightnessUtility is kept for compatibility; the upstream studio-brightness auto-start utility is no longer installed by default."
}
else {
    Write-Host ""
    Write-Host "==> Skipping standalone studio-brightness. Direct HID brightness is managed inside Studio Display XDR Win Controller."
}

if ($SkipBrightnessKeyBridge) {
    Write-Host ""
    Write-Host "==> -SkipBrightnessKeyBridge is kept for compatibility; the brightness-key bridge now runs only as a controller worker."
}

if (-not $SkipManager) {
    Invoke-LocalInstallScript -ScriptName "Install-StudioDisplayManager.ps1" -ArgumentList $sharedArguments
}
else {
    Write-Warning "Skipped the integrated controller. No standalone brightness, HDR, or hot-plug automation will be installed."
}

Write-Host ""
Write-Host "$appName installation finished."
