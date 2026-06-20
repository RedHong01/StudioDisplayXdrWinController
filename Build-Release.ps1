[CmdletBinding()]
param(
    [string]$Version = "0.1.0",
    [string]$ProjectName = "studio-display-tools-windows"
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

Get-ChildItem -LiteralPath $projectRoot -File |
    Where-Object {
        $_.Extension -in ".ps1", ".bat" -and
        $_.Name -notin @("BrightnessKeyBridge.log")
    } |
    ForEach-Object {
        Copy-IfPresent -SourcePath $_.FullName -DestinationPath (Join-Path $stagingRoot $_.Name)
    }

Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -Force

Write-Host "Release folder: $stagingRoot"
Write-Host "Release archive: $zipPath"
