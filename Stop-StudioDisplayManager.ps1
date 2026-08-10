[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\StudioDisplayManager"
$legacyInstallRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\SystemBrightnessMirror"
$appName = "Studio Display XDR Win Controller"
$controllerScriptPaths = @(
    (Join-Path $installRoot "StudioDisplayManager.ps1"),
    (Join-Path $installRoot "SystemBrightnessMirror.ps1"),
    (Join-Path $installRoot "BrightnessKeyBridge.ps1"),
    (Join-Path $installRoot "Watch-StudioDisplayHotplugAutomation.ps1"),
    (Join-Path $legacyInstallRoot "StudioDisplayManager.ps1"),
    (Join-Path $legacyInstallRoot "SystemBrightnessMirror.ps1"),
    (Join-Path $legacyInstallRoot "BrightnessKeyBridge.ps1"),
    (Join-Path $env:LOCALAPPDATA "StudioDisplayTools\BrightnessKeyBridge\BrightnessKeyBridge.ps1")
)
$pidFiles = @(
    (Join-Path $installRoot "StudioDisplayManager.pid"),
    (Join-Path $installRoot "SystemBrightnessMirror.pid"),
    (Join-Path $installRoot "BrightnessKeyBridge.pid"),
    (Join-Path $installRoot "StudioDisplayPassiveHotplugObserver.pid"),
    (Join-Path $legacyInstallRoot "SystemBrightnessMirrorTray.pid"),
    (Join-Path $legacyInstallRoot "StudioDisplayManager.pid"),
    (Join-Path $legacyInstallRoot "SystemBrightnessMirror.pid")
)

function Stop-ManagedProcess {
    param([string]$PidPath)

    if (-not (Test-Path $PidPath)) {
        return $false
    }

    $managedPid = Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($managedPid -match '^\d+$') {
        $process = Get-Process -Id ([int]$managedPid) -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id ([int]$managedPid) -Force -ErrorAction SilentlyContinue
            $deadline = (Get-Date).AddSeconds(4)
            do {
                Start-Sleep -Milliseconds 250
                $process = Get-Process -Id ([int]$managedPid) -ErrorAction SilentlyContinue
            } while ($process -and (Get-Date) -lt $deadline)

            if ($process) {
                Write-Warning "$appName could not stop managed worker PID=$managedPid from $PidPath; leaving the pid file in place so a later restart can still identify it."
                return $false
            }
        }
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    return $true
}

function Stop-OrphanStudioDisplayPowerShellProcesses {
    param([string[]]$ScriptPaths)

    $normalizedScriptPaths = @(
        $ScriptPaths |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.ToLowerInvariant() }
    )

    if (-not $normalizedScriptPaths) {
        return $false
    }

    $processes = @()
    try {
        $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop)
    }
    catch {
        try {
            $processes = @(Get-WmiObject Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction Stop)
        }
        catch {
            Write-Warning "$appName could not inspect PowerShell command lines for orphan cleanup: $($_.Exception.Message)"
            return $false
        }
    }

    $stopped = $false
    foreach ($processInfo in $processes) {
        if ([int]$processInfo.ProcessId -eq $PID) {
            continue
        }

        $commandLine = [string]$processInfo.CommandLine
        if ([string]::IsNullOrWhiteSpace($commandLine)) {
            continue
        }

        $commandLineLower = $commandLine.ToLowerInvariant()
        $isControllerWorker = [bool]($normalizedScriptPaths | Where-Object { $commandLineLower.Contains($_) } | Select-Object -First 1)
        if (-not $isControllerWorker) {
            continue
        }

        $process = Get-Process -Id ([int]$processInfo.ProcessId) -ErrorAction SilentlyContinue
        if ($process) {
            Write-Host "$appName stopping orphaned controller PowerShell worker PID=$($process.Id)."
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            $stopped = $true
        }
    }

    return $stopped
}

$stoppedAny = $false
foreach ($pidFile in $pidFiles) {
    if (Stop-ManagedProcess -PidPath $pidFile) {
        $stoppedAny = $true
    }
}

if (Stop-OrphanStudioDisplayPowerShellProcesses -ScriptPaths $controllerScriptPaths) {
    $stoppedAny = $true
}

if ($stoppedAny) {
    Write-Host "$appName stopped."
} else {
    Write-Host "$appName is not running."
}
