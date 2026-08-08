[CmdletBinding()]
param(
    [string]$Version = "0.1.0",
    [string]$ProjectName = "StudioDisplayXdrWinController"
)

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$distRoot = Join-Path $projectRoot "dist"
$stagingRoot = Join-Path $distRoot "$ProjectName-v$Version"
$zipPath = Join-Path $distRoot "$ProjectName-v$Version.zip"

$rootFiles = @(
    ".gitattributes",
    ".gitignore",
    "CHANGELOG.md",
    "LICENSE",
    "README.md"
)

$directories = @(
    "docs"
)

$scriptFiles = @(
    "Apply-StudioDisplayEdidOverride.ps1",
    "BrightnessKeyBridge.ps1",
    "Build-Release.ps1",
    "Check-StudioDisplayGaming.ps1",
    "Get-StudioDisplayAdvancedColorState.ps1",
    "Install-StudioDisplayBootCampStyleMonitorDriver.ps1",
    "Install-StudioDisplayManager.ps1",
    "Install-StudioDisplayTools.ps1",
    "Invoke-StudioDisplayAutoRepair.ps1",
    "Open-StudioDisplayColorTools.ps1",
    "Publish-GitHubRelease.ps1",
    "Register-StudioDisplayAutoRepairTask.ps1",
    "Refresh-StudioDisplayXdrLink.ps1",
    "Remove-StudioDisplayLegacyTools.ps1",
    "Remove-StudioDisplayLocalSigningCertificate.ps1",
    "Repair-DiscordStudioDisplayMic.ps1",
    "Repair-StudioDisplayAppleUsbInterfaces.ps1",
    "Repair-StudioDisplayExternalMode.ps1",
    "Repair-StudioDisplayIntegrated.ps1",
    "Set-StudioDisplayHdrState.ps1",
    "Show-StudioDisplayRepairProgress.ps1",
    "Start-StudioDisplayManager.bat",
    "Start-StudioDisplayManager.ps1",
    "Stop-StudioDisplayManager.bat",
    "Stop-StudioDisplayManager.ps1",
    "StudioDisplayHid.ps1",
    "StudioDisplayManager.ps1",
    "SystemBrightnessMirror.ps1",
    "Test-StudioDisplayResolutionLadder.ps1",
    "Trace-StudioDisplayBrightnessInput.ps1"
)

$excludedReleaseDocs = @(
    "Discord-StudioDisplay-Overwatch-Troubleshooting.md",
    "The-Alters-Studio-Display-XDR.md",
    "Zenless-Zone-Zero-Studio-Display-XDR.md"
)

function Copy-IfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if (Test-Path -LiteralPath $SourcePath) {
        $destinationDirectory = Split-Path -Parent $DestinationPath
        if ($destinationDirectory) {
            New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
        }

        Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force
    }
}

if (Test-Path -LiteralPath $stagingRoot) {
    Remove-Item -LiteralPath $stagingRoot -Recurse -Force
}

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null

foreach ($fileName in $rootFiles) {
    Copy-IfPresent -SourcePath (Join-Path $projectRoot $fileName) -DestinationPath (Join-Path $stagingRoot $fileName)
}

foreach ($directoryName in $directories) {
    $sourceDirectory = Join-Path $projectRoot $directoryName
    if (Test-Path -LiteralPath $sourceDirectory) {
        Get-ChildItem -LiteralPath $sourceDirectory -Recurse -File |
            Where-Object {
                if ($directoryName -eq "docs") {
                    $_.Name -notin $excludedReleaseDocs
                }
                else {
                    $true
                }
            } |
            ForEach-Object {
                $relativePath = $_.FullName.Substring($sourceDirectory.Length).TrimStart("\")
                Copy-IfPresent -SourcePath $_.FullName -DestinationPath (Join-Path (Join-Path $stagingRoot $directoryName) $relativePath)
            }
    }
}

foreach ($fileName in $scriptFiles) {
    Copy-IfPresent -SourcePath (Join-Path $projectRoot $fileName) -DestinationPath (Join-Path $stagingRoot $fileName)
}

Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -Force

Write-Host "Release folder: $stagingRoot"
Write-Host "Release archive: $zipPath"
