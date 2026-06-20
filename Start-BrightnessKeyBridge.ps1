[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\BrightnessKeyBridge"
$scriptTarget = Join-Path $installRoot "BrightnessKeyBridge.ps1"
$pidFile = Join-Path $installRoot "BrightnessKeyBridge.pid"
$powershellExe = Join-Path $PSHOME "powershell.exe"

function Test-BridgeProcessRunning {
    param(
        [string]$PidPath
    )

    if (-not (Test-Path $PidPath)) {
        return $false
    }

    $existingPid = Get-Content $PidPath | Select-Object -First 1
    if (-not $existingPid) {
        Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
    if ($process) {
        return $true
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    return $false
}

if (-not (Test-Path $scriptTarget)) {
    throw "BrightnessKeyBridge is not installed. Run Install-BrightnessKeyBridge.ps1 first."
}

if (Test-BridgeProcessRunning -PidPath $pidFile) {
    Write-Host "Brightness key bridge is already running."
    exit 0
}

Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
    "-NoProfile",
    "-WindowStyle", "Hidden",
    "-ExecutionPolicy", "Bypass",
    "-File", $scriptTarget,
    "-EnableLogging",
    "-StepPercent", "10"
)

Start-Sleep -Seconds 2

if (Test-BridgeProcessRunning -PidPath $pidFile) {
    Write-Host "Brightness key bridge started."
} else {
    throw "Brightness key bridge did not start successfully."
}
