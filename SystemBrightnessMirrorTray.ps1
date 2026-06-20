[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$installRoot = $PSScriptRoot
$mirrorScript = Join-Path $installRoot "SystemBrightnessMirror.ps1"
$mirrorPidFile = Join-Path $installRoot "SystemBrightnessMirror.pid"
$trayPidFile = Join-Path $installRoot "SystemBrightnessMirrorTray.pid"
$logPath = Join-Path $installRoot "SystemBrightnessMirror.log"
$powershellExe = Join-Path $PSHOME "powershell.exe"
$mutexName = "StudioDisplaySystemBrightnessMirrorTray"
$statusTooltipRunning = "Studio Display Brightness: Running"
$statusTooltipStopped = "Studio Display Brightness: Stopped"
$studioDisplayHardwareId = "DISPLAY\APPAE3A"
$displayRepairCooldownSeconds = 45

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

function Invoke-StudioDisplayExternalTopology {
    param(
        [string]$Reason = "manual"
    )

    if (-not (Test-StudioDisplayConnected)) {
        Write-AppLog "Skipped external display topology repair for $Reason because Studio Display is not connected."
        return $false
    }

    try {
        Start-Process -FilePath (Join-Path $env:WINDIR "System32\DisplaySwitch.exe") -ArgumentList "/external" -WindowStyle Hidden
        Write-AppLog "Started DisplaySwitch.exe /external for $Reason."
        return $true
    }
    catch {
        Write-AppLog "DisplaySwitch.exe /external for $Reason failed: $($_.Exception.Message)"
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

$context = $null
$notifyIcon = $null
$timer = $null
$runningIcon = $null
$stoppedIcon = $null
$degradedIcon = $null
$lastStudioDisplayConnected = $false
$lastDisplayRepairAt = [DateTime]::MinValue

try {
    $runningIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(60, 179, 113))
    $stoppedIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(130, 130, 130))
    $degradedIcon = New-StatusIcon -Color ([System.Drawing.Color]::FromArgb(255, 140, 0))

    $context = New-Object System.Windows.Forms.ApplicationContext
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Visible = $true
    $notifyIcon.Icon = $stoppedIcon
    $notifyIcon.Text = $statusTooltipStopped

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $statusItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $statusItem.Enabled = $false
    $statusItem.Text = "状态：正在检查"

    $startItem = New-Object System.Windows.Forms.ToolStripMenuItem "启动亮度同步"
    $restartItem = New-Object System.Windows.Forms.ToolStripMenuItem "重启亮度同步"
    $stopItem = New-Object System.Windows.Forms.ToolStripMenuItem "停止亮度同步"
    $repairDisplayItem = New-Object System.Windows.Forms.ToolStripMenuItem "重套外屏显示模式"
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
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($openLogItem)
    [void]$menu.Items.Add($openFolderItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add($exitItem)

    $notifyIcon.ContextMenuStrip = $menu

    $updateUi = {
        $mirrorRunning = Test-ManagedProcessRunning -PidPath $mirrorPidFile

        if ($mirrorRunning) {
            $statusItem.Text = "状态：亮度同步运行中"
            $startItem.Enabled = $false
            $restartItem.Enabled = $true
            $stopItem.Enabled = $true
            $notifyIcon.Icon = $runningIcon
            $notifyIcon.Text = $statusTooltipRunning
        } else {
            $statusItem.Text = "状态：亮度同步未运行"
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
            $notifyIcon.Text = "Studio Display Brightness: Error"
            [System.Windows.Forms.MessageBox]::Show(
                "亮度同步服务启动失败。你可以先检查 Studio Display 是否已经重新连上，然后再试一次。",
                "Studio Display Brightness",
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
            $notifyIcon.Text = "Studio Display Brightness: Error"
            [System.Windows.Forms.MessageBox]::Show(
                "亮度同步服务重启失败。请确认 Studio Display 已连接，然后再重试。",
                "Studio Display Brightness",
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
        Invoke-StudioDisplayExternalTopology -Reason "tray menu" | Out-Null
    })

    $openLogItem.add_Click({
        if (Test-Path $logPath) {
            Start-Process -FilePath "notepad.exe" -ArgumentList @($logPath)
        } else {
            [System.Windows.Forms.MessageBox]::Show(
                "日志文件还没有生成。",
                "Studio Display Brightness",
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
        $repairCooldownElapsed = ((Get-Date) - $script:lastDisplayRepairAt).TotalSeconds -ge $displayRepairCooldownSeconds

        if (($repairDueToReconnect -or $repairDueToStartup) -and $repairCooldownElapsed) {
            $script:lastDisplayRepairAt = Get-Date
            Invoke-StudioDisplayExternalTopology -Reason "Studio Display connect/startup detection" | Out-Null
        }

        $script:lastStudioDisplayConnected = $studioDisplayConnected
        & $updateUi
    })

    Start-MirrorService | Out-Null
    if (Test-StudioDisplayConnected) {
        $script:lastDisplayRepairAt = Get-Date
        Invoke-StudioDisplayExternalTopology -Reason "tray startup" | Out-Null
        $script:lastStudioDisplayConnected = $true
    }

    & $updateUi
    $timer.Start()
    [System.Windows.Forms.Application]::Run($context)
}
finally {
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
