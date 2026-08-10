[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager"
$managerTarget = Join-Path $installRoot "StudioDisplayManager.ps1"
$managerPidFile = Join-Path $installRoot "StudioDisplayManager.pid"
$powershellExe = Join-Path $PSHOME "powershell.exe"
$appName = "Studio Display XDR Win Controller"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Remove-StaleManagerPidFile {
    if (-not (Test-Path -LiteralPath $managerPidFile)) {
        return $true
    }

    try {
        Remove-Item -LiteralPath $managerPidFile -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-Warning "$appName could not remove stale pid file $managerPidFile`: $($_.Exception.Message)"
    }

    if (-not (Test-IsAdministrator)) {
        try {
            $escapedPidFile = $managerPidFile.Replace("'", "''")
            $cleanupCommand = "Remove-Item -LiteralPath '$escapedPidFile' -Force -ErrorAction Stop"
            Write-Host "$appName needs one UAC approval to remove a stale protected pid file."
            Start-Process -FilePath $powershellExe -Verb RunAs -WindowStyle Hidden -Wait -ArgumentList @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-Command", $cleanupCommand
            ) | Out-Null

            if (-not (Test-Path -LiteralPath $managerPidFile)) {
                return $true
            }
        }
        catch {
            Write-Warning "$appName elevated stale pid cleanup failed: $($_.Exception.Message)"
        }
    }

    return $false
}

function Test-ManagerRunning {
    if (-not (Test-Path $managerPidFile)) {
        return $false
    }

    $existingPid = Get-Content -LiteralPath $managerPidFile -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $existingPid) {
        [void](Remove-StaleManagerPidFile)
        return $false
    }

    if ($existingPid -notmatch '^\d+$') {
        [void](Remove-StaleManagerPidFile)
        return $false
    }

    $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
    if ($process) {
        return $true
    }

    [void](Remove-StaleManagerPidFile)
    return $false
}

function Wait-ManagerRunning {
    param([int]$TimeoutSeconds = 15)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-ManagerRunning) {
            return $true
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
}

if (-not (Test-Path $managerTarget)) {
    throw "$appName is not installed. Run Install-StudioDisplayManager.ps1 first."
}

if (Test-ManagerRunning) {
    Write-Host "$appName is already running."
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

if (Wait-ManagerRunning -TimeoutSeconds 15) {
    Write-Host "$appName started."
} else {
    throw "$appName did not start successfully."
}
