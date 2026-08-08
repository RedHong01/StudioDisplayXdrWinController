[CmdletBinding()]
param(
    [string]$Version = "0.1.12",
    [string]$ProjectName = "StudioDisplayXdrWinController",
    [string]$Repo = "RedHong01/StudioDisplayXdrWinController",
    [switch]$SkipBuild,
    [switch]$Draft
)

$ErrorActionPreference = "Stop"

$gh = @(
    "$env:ProgramFiles\GitHub CLI\gh.exe",
    "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $gh) {
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($command) {
        $gh = $command.Source
    }
}

if (-not $gh) {
    throw "GitHub CLI (gh) was not found. Install with: winget install --id GitHub.cli -e"
}

Write-Host "==> Checking GitHub authentication"
& $gh auth status
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Not logged in. Run this once, then rerun this script:"
    Write-Host "  & `"$gh`" auth login --hostname github.com --git-protocol https --web"
    throw "GitHub CLI authentication is required before publishing a release."
}

$projectRoot = $PSScriptRoot
$tag = "v$Version"
$zipPath = Join-Path $projectRoot "dist\$ProjectName-v$Version.zip"
$title = "Studio Display XDR Win Controller $tag"

if (-not $SkipBuild) {
    Write-Host "==> Building release package $tag"
    & (Join-Path $projectRoot "Build-Release.ps1") -Version $Version -ProjectName $ProjectName
}

if (-not (Test-Path -LiteralPath $zipPath)) {
    throw "Release zip was not found: $zipPath"
}

$notesFile = Join-Path $env:TEMP "StudioDisplayXdrWinController-$tag-notes.md"
@"
## Studio Display XDR Win Controller $tag

Open-source PowerShell utilities for Apple Studio Display / Studio Display XDR on Windows.

### Install

1. Download ``$ProjectName-v$Version.zip``
2. Extract it
3. Run:

``````powershell
powershell -ExecutionPolicy Bypass -File .\Install-StudioDisplayTools.ps1
``````

See ``README.md`` and ``CHANGELOG.md`` in the archive for details.
"@ | Set-Content -LiteralPath $notesFile -Encoding UTF8

$existingTag = & $gh api "repos/$Repo/git/refs/tags/$tag" 2>$null
if ($LASTEXITCODE -eq 0 -and $existingTag) {
    Write-Warning "Remote tag $tag already exists."
}

$releaseArgs = @(
    "release", "create", $tag,
    $zipPath,
    "--repo", $Repo,
    "--title", $title,
    "--notes-file", $notesFile
)

if ($Draft) {
    $releaseArgs += "--draft"
}

Write-Host "==> Creating GitHub release $tag"
Write-Host "Asset: $zipPath"
& $gh @releaseArgs

if ($LASTEXITCODE -ne 0) {
    throw "gh release create failed with exit code $LASTEXITCODE"
}

Write-Host ""
Write-Host "Release published:"
& $gh release view $tag --repo $Repo --web
