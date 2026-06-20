[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$managerStopper = Join-Path $PSScriptRoot "Stop-StudioDisplayManager.ps1"
& $managerStopper
