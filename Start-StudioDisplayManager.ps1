[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager"
$managerTarget = Join-Path $installRoot "StudioDisplayManager.ps1"
$managerPidFile = Join-Path $installRoot "StudioDisplayManager.pid"
$powershellExe = Join-Path $PSHOME "powershell.exe"

function Test-ManagerRunning {
    if (-not (Test-Path $managerPidFile)) {
        return $false
    }

    $existingPid = Get-Content -LiteralPath $managerPidFile | Select-Object -First 1
    if (-not $existingPid) {
        Remove-Item -LiteralPath $managerPidFile -Force -ErrorAction SilentlyContinue
        return $false
    }

    $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
    if ($process) {
        return $true
    }

    Remove-Item -LiteralPath $managerPidFile -Force -ErrorAction SilentlyContinue
    return $false
}

if (-not (Test-Path $managerTarget)) {
    throw "Studio Display Manager is not installed. Run Install-StudioDisplayManager.ps1 first."
}

if (Test-ManagerRunning) {
    Write-Host "Studio Display Manager is already running."
    exit 0
}

Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
    "-Sta",
    "-NoProfile",
    "-WindowStyle", "Hidden",
    "-ExecutionPolicy", "Bypass",
    "-File", $managerTarget
)

Start-Sleep -Seconds 5

if (Test-ManagerRunning) {
    Write-Host "Studio Display Manager started."
} else {
    throw "Studio Display Manager did not start successfully."
}
