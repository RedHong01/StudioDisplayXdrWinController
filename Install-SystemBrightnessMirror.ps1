[CmdletBinding()]
param(
    [switch]$SkipAutoStart,
    [switch]$SkipStartNow
)

$ErrorActionPreference = "Stop"

$managerInstaller = Join-Path $PSScriptRoot "Install-StudioDisplayManager.ps1"
& $managerInstaller -SkipAutoStart:$SkipAutoStart -SkipStartNow:$SkipStartNow
