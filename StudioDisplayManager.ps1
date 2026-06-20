[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$installRoot = $PSScriptRoot
$mirrorScript = Join-Path $installRoot "SystemBrightnessMirror.ps1"
$micRepairScript = Join-Path $installRoot "Repair-DiscordStudioDisplayMic.ps1"
$externalModeRepairScript = Join-Path $installRoot "Repair-StudioDisplayExternalMode.ps1"
$overwatchProfileScript = Join-Path $installRoot "Set-OverwatchExclusiveFullscreenProfile.ps1"
$mirrorPidFile = Join-Path $installRoot "SystemBrightnessMirror.pid"
$trayPidFile = Join-Path $installRoot "StudioDisplayManager.pid"
$logPath = Join-Path $installRoot "SystemBrightnessMirror.log"
$powershellExe = Join-Path $PSHOME "powershell.exe"
$mutexName = "StudioDisplayManager"
$statusTooltipRunning = "Studio Display Manager: Running"
$statusTooltipStopped = "Studio Display Manager: Brightness stopped"
$studioDisplayHardwareId = "DISPLAY\APPAE3A"
$displayRepairCooldownSeconds = 45
$displayRepairBlockedProcessNames = @("Overwatch")

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class StudioDisplayUser32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);
}
"@

function Write-AppLog {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -LiteralPath $logPath -Value "$timestamp $Message" -ErrorAction SilentlyContinue
}

function Test-ManagedProcessRunning {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PidPath
    )

    if (-not (Test-Path $PidPath)) {
        return $false
    }

    $existingPid = Get-Content -LiteralPath $PidPath | Select-Object -First 1
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

function Stop-ManagedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PidPath
    )

    if (-not (Test-Path $PidPath)) {
        return
    }

    $existingPid = Get-Content -LiteralPath $PidPath | Select-Object -First 1
    if ($existingPid) {
        $process = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
        if ($process) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
        }
    }

    Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
}

function Start-MirrorService {
    if (Test-ManagedProcessRunning -PidPath $mirrorPidFile) {
        return $true
    }

    Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
        "-NoProfile",
        "-WindowStyle", "Hidden",
        "-ExecutionPolicy", "Bypass",
        "-File", $mirrorScript,
        "-EnableLogging"
    )

    Start-Sleep -Seconds 2
    return (Test-ManagedProcessRunning -PidPath $mirrorPidFile)
}

function Restart-MirrorService {
    Stop-ManagedProcess -PidPath $mirrorPidFile
    return (Start-MirrorService)
}

function Test-StudioDisplayConnected {
    try {
        $studioDisplay = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop |
            Where-Object { $_.InstanceName -like "$studioDisplayHardwareId*" } |
            Select-Object -First 1

        return [bool]$studioDisplay
    }
    catch {
        try {
            $studioDisplay = Get-CimInstance Win32_DesktopMonitor -ErrorAction Stop |
                Where-Object { $_.PNPDeviceID -like "$studioDisplayHardwareId*" -and $_.Availability -eq 3 } |
                Select-Object -First 1

            return [bool]$studioDisplay
        }
        catch {
            Write-AppLog "Studio Display connection check failed: $($_.Exception.Message)"
            return $false
        }
    }
}

function Test-ForegroundFullscreenWindow {
    try {
        $handle = [StudioDisplayUser32]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero -or -not [StudioDisplayUser32]::IsWindowVisible($handle)) {
            return $false
        }

        $rect = New-Object StudioDisplayUser32+RECT
        if (-not [StudioDisplayUser32]::GetWindowRect($handle, [ref]$rect)) {
            return $false
        }

        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $windowWidth = $rect.Right - $rect.Left
        $windowHeight = $rect.Bottom - $rect.Top
        $tolerance = 3

        return (
            [Math]::Abs($rect.Left - $screen.Left) -le $tolerance -and
            [Math]::Abs($rect.Top - $screen.Top) -le $tolerance -and
            [Math]::Abs($windowWidth - $screen.Width) -le $tolerance -and
            [Math]::Abs($windowHeight - $screen.Height) -le $tolerance
        )
    }
    catch {
        Write-AppLog "Fullscreen foreground check failed: $($_.Exception.Message)"
        return $false
    }
}

function Get-DisplayRepairBlockReason {
    $blockingProcess = Get-Process -Name $displayRepairBlockedProcessNames -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($blockingProcess) {
        return "game process '$($blockingProcess.ProcessName)' is running"
    }

    if (Test-ForegroundFullscreenWindow) {
        return "a fullscreen foreground window is active"
    }

    return $null
}

function Invoke-StudioDisplayExternalTopology {
    param(
        [string]$Reason = "manual",
        [switch]$AllowDuringFullscreen,
        [switch]$SkipSafetyMode
    )

    if (-not (Test-StudioDisplayConnected)) {
        Write-AppLog "Skipped external display topology repair for $Reason because Studio Display is not connected."
        return $false
    }

    $blockReason = if ($AllowDuringFullscreen) { $null } else { Get-DisplayRepairBlockReason }
    if ($blockReason) {
        $script:pendingDisplayRepair = $true
        Write-AppLog "Deferred external display topology repair for $Reason because $blockReason."
        return $false
    }

    if (-not (Test-Path $externalModeRepairScript)) {
        Write-AppLog "Skipped silent external display topology repair for $Reason because repair script is missing."
        return $false
    }

    try {
        $repairArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $externalModeRepairScript,
            "-Topology", "External"
        )
        if ($SkipSafetyMode) {
            $repairArgs += "-SkipSafetyMode"
        }

        $repairOutput = & $powershellExe @repairArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            $script:pendingDisplayRepair = $false
            Write-AppLog "Applied silent external display topology repair for $Reason. $($repairOutput -join ' ')"
            return $true
        }

        Write-AppLog "Silent external display topology repair for $Reason failed with exit code $LASTEXITCODE. $($repairOutput -join ' ')"
        return $false
    }
    catch {
        Write-AppLog "Silent external display topology repair for $Reason failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-OverwatchExclusiveFullscreenProfile {
    param(
        [string]$Reason = "manual"
    )

    if (-not (Test-Path $overwatchProfileScript)) {
        Write-AppLog "Skipped Overwatch exclusive fullscreen profile for $Reason because profile script is missing."
        return $false
    }

    try {
        Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass",
            "-File", $overwatchProfileScript,
            "-Action", "Apply",
            "-WaitForGameExit"
        )
        Write-AppLog "Started Overwatch exclusive fullscreen profile for $Reason."
        return $true
    }
    catch {
        Write-AppLog "Overwatch exclusive fullscreen profile for $Reason failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-StudioDisplayMicRepair {
    param(
        [string]$Reason = "manual"
    )

    if (-not (Test-Path $micRepairScript)) {
        Write-AppLog "Skipped Studio Display microphone repair for $Reason because repair script is missing."
        return $false
    }

    if (-not (Test-StudioDisplayConnected)) {
        Write-AppLog "Skipped Studio Display microphone repair for $Reason because Studio Display is not connected."
        return $false
    }

    try {
        Start-Process -FilePath $powershellExe -WorkingDirectory $installRoot -WindowStyle Hidden -ArgumentList @(
            "-NoProfile",
            "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass",
            "-File", $micRepairScript,
            "-EnableDesktopMicrophoneAccess"
        )
        Write-AppLog "Started Studio Display microphone repair for $Reason."
        return $true
    }
    catch {
        Write-AppLog "Studio Display microphone repair for $Reason failed: $($_.Exception.Message)"
        return $false
    }
}

function New-StatusIcon {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$Color
    )

    $bitmap = New-Object System.Drawing.Bitmap 16, 16
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $shadowBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 0, 0, 0))
    $fillBrush = New-Object System.Drawing.SolidBrush $Color
    $outlinePen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(210, 255, 255, 255), 1)

    $graphics.FillEllipse($shadowBrush, 3, 3, 10, 10)
    $graphics.FillEllipse($fillBrush, 2, 2, 10, 10)
    $graphics.DrawEllipse($outlinePen, 2, 2, 10, 10)

    $iconHandle = $bitmap.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($iconHandle)

    $shadowBrush.Dispose()
    $fillBrush.Dispose()
    $outlinePen.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()

    return $icon
}

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

Set-Content -LiteralPath $trayPidFile -Value $PID -Encoding ascii
Write-AppLog "Studio Display Manager tray started with PID $PID."

$context = $null
$notifyIcon = $null
$timer = $null
$runningIcon = $null
$stoppedIcon = $null
$degradedIcon = $null
$lastStudioDisplayConnected = $false
$lastDisplayRepairAt = [DateTime]::MinValue
$pendingDisplayRepair = $false

try {
    $runningIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(60, 179, 113))
    $stoppedIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(130, 130, 130))
    $degradedIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(255, 140, 0))

    $context = New-Object System.Windows.Forms.ApplicationContext
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Visible = $true
    $notifyIcon.Icon = $stoppedIcon
    $notifyIcon.Text = $statusTooltipStopped
    $notifyIcon.BalloonTipTitle = "Studio Display Manager"
    $notifyIcon.BalloonTipText = "亮度同步和外屏模式修复正在后台运行。"
    $notifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    $statusItem.Text = "状态：正在检查"

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem "亮度同步：启动"
    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem "亮度同步：重启"
    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem "亮度同步：停止"
    $repairDisplayItem = New-Object System.Windows.Forms.ToolStripMenuItem "外屏模式：立即修复"
    $repairMicItem = New-Object System.Windows.Forms.ToolStripMenuItem "Discord 麦克风：立即修复"
    $applyOverwatchProfileItem = New-Object System.Windows.Forms.ToolStripMenuItem "守望先锋：应用独占全屏配置"
    $openLogItem = New-Object System.Windows.Forms.ToolStripMenuItem "打开日志"
    $openFolderItem = New-Object System.Windows.Forms.ToolStripMenuItem "打开安装目录"
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem "退出"

    [void]$menu.Items.Add($statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($startItem)
    [void]$menu.Items.Add($restartItem)
    [void]$menu.Items.Add($stopItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($repairDisplayItem)
    [void]$menu.Items.Add($repairMicItem)
    [void]$menu.Items.Add($applyOverwatchProfileItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($openLogItem)
    [void]$menu.Items.Add($openFolderItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($exitItem)

    $notifyIcon.ContextMenuStrip = $menu

    $updateUi = {
        $mirrorRunning = Test-ManagedProcessRunning -PidPath $mirrorPidFile

        if ($mirrorRunning) {
            $statusItem.Text = "状态：亮度同步运行中；外屏修复监控中"
            $startItem.Enabled = $false
            $restartItem.Enabled = $true
            $stopItem.Enabled = $true
            $notifyIcon.Icon = $runningIcon
            $notifyIcon.Text = $statusTooltipRunning
        } else {
            $statusItem.Text = "状态：亮度同步未运行；外屏修复监控中"
            $startItem.Enabled = $true
            $restartItem.Enabled = $false
            $stopItem.Enabled = $false
            $notifyIcon.Icon = $stoppedIcon
            $notifyIcon.Text = $statusTooltipStopped
        }
    }

    $startItem.add_Click({
        if (Start-MirrorService) {
            & $updateUi
        } else {
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "Studio Display Manager: Error"
            [System.Windows.Forms.MessageBox]::Show(
                "亮度同步服务启动失败。你可以先检查 Studio Display 是否已经重新连上，然后再试一次。",
                "Studio Display Manager",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            & $updateUi
        }
    })

    $restartItem.add_Click({
        if (Restart-MirrorService) {
            & $updateUi
        } else {
            $notifyIcon.Icon = $degradedIcon
            $notifyIcon.Text = "Studio Display Manager: Error"
            [System.Windows.Forms.MessageBox]::Show(
                "亮度同步服务重启失败。请确认 Studio Display 已连接，然后再重试。",
                "Studio Display Manager",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            & $updateUi
        }
    })

    $stopItem.add_Click({
        Stop-ManagedProcess -PidPath $mirrorPidFile
        & $updateUi
    })

    $repairDisplayItem.add_Click({
        Invoke-StudioDisplayExternalTopology -Reason "tray menu" -AllowDuringFullscreen | Out-Null
    })

    $repairMicItem.add_Click({
        Invoke-StudioDisplayMicRepair -Reason "tray menu" | Out-Null
    })

    $applyOverwatchProfileItem.add_Click({
        Invoke-OverwatchExclusiveFullscreenProfile -Reason "tray menu" | Out-Null
    })

    $openLogItem.add_Click({
        if (Test-Path $logPath) {
            Start-Process -FilePath "notepad.exe" -ArgumentList @($logPath)
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "日志文件还没有生成。",
                "Studio Display Manager",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    })

    $openFolderItem.add_Click({
        Start-Process -FilePath "explorer.exe" -ArgumentList @($installRoot)
    })

    $exitItem.add_Click({
        Stop-ManagedProcess -PidPath $mirrorPidFile
        if ($timer) {
            $timer.Stop()
        }
        if ($notifyIcon) {
            $notifyIcon.Visible = $false
        }
        if ($context) {
            $context.ExitThread()
        }
    })

    $notifyIcon.add_DoubleClick({
        if (-not (Test-ManagedProcessRunning -PidPath $mirrorPidFile)) {
            Start-MirrorService | Out-Null
            & $updateUi
        } else {
            Start-Process -FilePath "explorer.exe" -ArgumentList @($installRoot)
        }
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.add_Tick({
        $studioDisplayConnected = Test-StudioDisplayConnected
        $repairDueToReconnect = $studioDisplayConnected -and -not $script:lastStudioDisplayConnected
        $repairDueToStartup = $studioDisplayConnected -and $script:lastDisplayRepairAt -eq [DateTime]::MinValue
        $repairDueToDeferredFullscreen = $studioDisplayConnected -and $script:pendingDisplayRepair
        $repairCooldownElapsed = ((Get-Date) - $script:lastDisplayRepairAt).TotalSeconds -ge $displayRepairCooldownSeconds

        if (($repairDueToReconnect -or $repairDueToStartup -or $repairDueToDeferredFullscreen) -and $repairCooldownElapsed) {
            $script:lastDisplayRepairAt = Get-Date
            $repairReason = if ($repairDueToDeferredFullscreen) {
                "deferred repair after fullscreen ended"
            } else {
                "Studio Display connect/startup detection"
            }
            Invoke-StudioDisplayExternalTopology -Reason $repairReason -SkipSafetyMode:$repairDueToDeferredFullscreen | Out-Null
        }

        if ($repairDueToReconnect -or $repairDueToStartup) {
            Invoke-StudioDisplayMicRepair -Reason "Studio Display connect/startup detection" | Out-Null
        }

        $script:lastStudioDisplayConnected = $studioDisplayConnected
        & $updateUi
    })

    Start-MirrorService | Out-Null
    if (Test-StudioDisplayConnected) {
        $script:lastDisplayRepairAt = Get-Date
        Invoke-StudioDisplayExternalTopology -Reason "tray startup" | Out-Null
        Invoke-StudioDisplayMicRepair -Reason "tray startup" | Out-Null
        $script:lastStudioDisplayConnected = $true
    }

    & $updateUi
    $notifyIcon.ShowBalloonTip(3000)
    $timer.Start()
    [System.Windows.Forms.Application]::Run($context)
}
finally {
    Write-AppLog "Studio Display Manager tray stopped."

    if ($timer) {
        $timer.Stop()
        $timer.Dispose()
    }

    if ($notifyIcon) {
        $notifyIcon.Visible = $false
        $notifyIcon.Dispose()
    }

    foreach ($icon in @($runningIcon, $stoppedIcon, $degradedIcon)) {
        if ($icon) {
            $icon.Dispose()
        }
    }

    if (Test-Path $trayPidFile) {
        Remove-Item -LiteralPath $trayPidFile -Force -ErrorAction SilentlyContinue
    }

    if ($mutex) {
        $mutex.ReleaseMutex() | Out-Null
        $mutex.Dispose()
    }
}
