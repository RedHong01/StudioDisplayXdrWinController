[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$managerStarter = Join-Path $PSScriptRoot "Start-StudioDisplayManager.ps1"
& $managerStarter
