[CmdletBinding()]
param(
    [switch]$EnableLogging,
    [ValidateRange(1,100)]
    [int]$ExternalOnlyStartupFallbackPercent = 70,
    [switch]$AllowStartupZeroSync
)

$ErrorActionPreference = "Stop"

$mirrorRoot = $PSScriptRoot
$pidFile = Join-Path $mirrorRoot "SystemBrightnessMirror.pid"
$logPath = Join-Path $mirrorRoot "SystemBrightnessMirror.log"
$mutexName = "StudioDisplaySystemBrightnessMirror"
$coordinationRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\Shared"
$suppressionFile = Join-Path $coordinationRoot "BrightnessKeySuppression.txt"
$pollIntervalMilliseconds = 300
$recoveryIntervalMilliseconds = 2000

Add-Type -AssemblyName System.Management
$hidHelperPath = Join-Path $mirrorRoot "StudioDisplayHid.ps1"
. $hidHelperPath

function Write-Log {
    param([string]$Message)
    if (-not $EnableLogging) {
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $logPath -Value "$timestamp $Message"
}

function Sync-ManagedPidFile {
    try {
        $existingPid = $null
        if (Test-Path $pidFile) {
            $existingPid = Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        }

        if ([string]$existingPid -ne [string]$PID) {
            Set-Content -LiteralPath $pidFile -Value $PID -Encoding ascii -ErrorAction Stop
            Write-Log "System brightness mirror refreshed managed pid file with PID=$PID."
        }
    }
    catch {
        Write-Log "System brightness mirror could not refresh managed pid file: $($_.Exception.Message)"
    }
}

function Get-InternalBrightnessPercent {
    $monitor = Get-WmiObject -Namespace root\wmi -Class WmiMonitorBrightness |
        Where-Object { $_.Active -eq $true } |
        Select-Object -First 1

    if (-not $monitor) {
        throw "No active internal brightness source was returned by WMI."
    }

    return [int]$monitor.CurrentBrightness
}

function Set-StudioBrightnessToPercent {
    param([int]$Percent)

    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    Set-StudioDisplayBrightnessPercent -Percent $Percent
}

function Sync-StudioBrightness {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Percent,
        [string]$Reason = "brightness sync"
    )

    try {
        Set-StudioBrightnessToPercent -Percent $Percent
        Write-Log "Studio Display brightness synced to $Percent% during $Reason."
        return $true
    }
    catch {
        Write-Log "Studio Display sync failed during $Reason at $Percent%: $($_.Exception.Message)"
        return $false
    }
}

function Get-SuppressedDirection {
    if (-not (Test-Path $suppressionFile)) {
        return $null
    }

    try {
        $content = Get-Content -LiteralPath $suppressionFile | Select-Object -First 1
        if (-not $content) {
            return $null
        }

        $parts = $content -split '\|', 2
        if ($parts.Count -ne 2) {
            return $null
        }

        $timestamp = [DateTime]::Parse($parts[0], $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if (([DateTime]::UtcNow - $timestamp).TotalMilliseconds -gt 1200) {
            return $null
        }

        return $parts[1]
    }
    catch {
        return $null
    }
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-Log "Another system brightness mirror instance is already running; exiting this duplicate instance."
    exit 2
}

Set-Content -LiteralPath $pidFile -Value $PID -Encoding ascii

try {
    $initialPercent = Get-InternalBrightnessPercent
    $lastInternalPercent = $initialPercent
    $startupSyncPercent = $initialPercent
    $lastRecoveryAttempt = [DateTime]::UtcNow
    $lastPidRefresh = [DateTime]::UtcNow
    $studioDisplayAvailable = $false
    Write-Log "Initial internal brightness is $initialPercent%."

    if ($initialPercent -eq 0 -and -not $AllowStartupZeroSync) {
        $currentStudioPercent = $null
        try {
            $currentStudioPercent = Get-StudioDisplayBrightnessPercent
        }
        catch {
            Write-Log "Could not read Studio Display brightness before startup zero guard: $($_.Exception.Message)"
        }

        if ($null -ne $currentStudioPercent -and $currentStudioPercent -gt 0) {
            $startupSyncPercent = [int]$currentStudioPercent
            Write-Log "Startup internal brightness is 0%, likely because the internal panel is off. Preserving current Studio Display brightness at $startupSyncPercent%."
        }
        else {
            $startupSyncPercent = $ExternalOnlyStartupFallbackPercent
            Write-Log "Startup internal brightness is 0% and Studio Display brightness is not readable/nonzero. Using safe external startup fallback $startupSyncPercent% instead of syncing 0%."
        }
    }

    if (Sync-StudioBrightness -Percent $startupSyncPercent -Reason "initial startup sync") {
        $studioDisplayAvailable = $true
    } else {
        Write-Log "Studio Display is not ready yet. The mirror will keep retrying until the display reconnects."
    }

    Write-Log "System brightness mirror started."

    while ($true) {
        $currentPercent = $null

        try {
            $currentPercent = Get-InternalBrightnessPercent
        }
        catch {
            Write-Log "Unable to read internal brightness from WMI: $($_.Exception.Message)"
            Start-Sleep -Milliseconds $pollIntervalMilliseconds
            continue
        }

        $delta = $currentPercent - $lastInternalPercent
        $suppressedDirection = Get-SuppressedDirection
        $shouldAttemptSync = $false
        $syncReason = $null

        if ($delta -ne 0) {
            if (($delta -gt 0 -and $suppressedDirection -eq "up") -or ($delta -lt 0 -and $suppressedDirection -eq "down")) {
                Write-Log "Internal brightness event $currentPercent% ignored because a direct key step already handled this direction."
                $lastInternalPercent = $currentPercent
                Start-Sleep -Milliseconds $pollIntervalMilliseconds
                continue
            }

            Write-Log "Internal brightness event: $currentPercent%."
            $lastInternalPercent = $currentPercent
            $shouldAttemptSync = $true
            $syncReason = "internal brightness change"
        }
        elseif (-not $studioDisplayAvailable -and ([DateTime]::UtcNow - $lastRecoveryAttempt).TotalMilliseconds -ge $recoveryIntervalMilliseconds) {
            $shouldAttemptSync = $true
            $syncReason = "recovery retry"
        }

        if ($shouldAttemptSync) {
            $lastRecoveryAttempt = [DateTime]::UtcNow
            $syncSucceeded = Sync-StudioBrightness -Percent $lastInternalPercent -Reason $syncReason

            if ($syncSucceeded) {
                if (-not $studioDisplayAvailable) {
                    Write-Log "Studio Display brightness sync recovered after reconnect."
                }

                $studioDisplayAvailable = $true
            } else {
                $studioDisplayAvailable = $false
            }
        }

        if (([DateTime]::UtcNow - $lastPidRefresh).TotalSeconds -ge 5) {
            $lastPidRefresh = [DateTime]::UtcNow
            Sync-ManagedPidFile
        }

        Start-Sleep -Milliseconds $pollIntervalMilliseconds
    }
}
finally {
    if (Test-Path $pidFile) {
        Remove-Item -LiteralPath $pidFile -Force
    }

    if ($mutex) {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}
