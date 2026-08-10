[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$EnsureBootCampMonitorDriver,
    [switch]$RestartAppleUsb4Router,
    [string]$Reason = "manual",
    [string]$LogPath
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptRoot = $PSScriptRoot
$reportsRoot = Join-Path $scriptRoot "reports"
$integratedRepairScript = Join-Path $scriptRoot "Repair-StudioDisplayIntegrated.ps1"
$externalModeRepairScript = Join-Path $scriptRoot "Repair-StudioDisplayExternalMode.ps1"
$fastFallbackStateFile = Join-Path $scriptRoot "StudioDisplayFastVisibleFallbackState.json"
$powershellExe = Join-Path $PSHOME "powershell.exe"

if (-not $LogPath) {
    New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null
    $LogPath = Join-Path $reportsRoot ("StudioDisplayIntegratedRepair-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedProgressHost {
    $arguments = @(
        "-Sta",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Reason", "`"$Reason`"",
        "-LogPath", "`"$LogPath`""
    )

    foreach ($switchName in @(
            "Apply",
            "EnsureBootCampMonitorDriver",
            "RestartAppleUsb4Router"
        )) {
        if ((Get-Variable -Name $switchName -ValueOnly)) {
            $arguments += "-$switchName"
        }
    }

    Start-Process -FilePath $powershellExe -WorkingDirectory $scriptRoot -Verb RunAs -ArgumentList $arguments -ErrorAction Stop
}

if ($Apply -and -not (Test-IsAdministrator)) {
    try {
        Start-ElevatedProgressHost
        exit 0
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "没有获得管理员权限，无法执行需要 USB4/HDR/Apple HID 修复的一键管线。请重新点击一键修复并在 UAC 中确认允许。`r`n`r`n$($_.Exception.Message)",
            "Studio Display XDR Win Controller",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        exit 1
    }
}

function Get-RepairStage {
    param([string]$Text)

    if ($Text -match 'Integrated repair finished successfully') { return @{ Percent = 100; Label = "完成：5K/HDR/亮度管线已验证" } }
    if ($Text -match 'Integrated repair finished, but') { return @{ Percent = 100; Label = "完成：需要查看日志里的剩余阻塞" } }
    if ($Text -match 'brightness HID get|Brightness validation') { return @{ Percent = 94; Label = "验证亮度 HID 和按键桥" } }
    if ($Text -match 'advanced color validation') { return @{ Percent = 88; Label = "验证 Windows HDR / Advanced Color 状态" } }
    if ($Text -match 'HDR state repair') { return @{ Percent = 78; Label = "请求 Windows HDR 状态" } }
    if ($Text -match 'Apple USB/HID interface repair') { return @{ Percent = 68; Label = "修复 Apple USB/HID 控制接口" } }
    if ($Text -match 'link refresh|USB4|PnP|router') { return @{ Percent = 56; Label = "刷新 Thunderbolt/USB4 链路和模式表" } }
    if ($Text -match 'external-only topology repair') { return @{ Percent = 42; Label = "切换 Studio Display XDR 为唯一显示器" } }
    if ($Text -match 'Boot Camp-style monitor driver') { return @{ Percent = 30; Label = "检查 Boot Camp-style 5K60 兜底驱动" } }
    if ($Text -match 'Brightness preflight|Stopping .*Brightness|brightness services would be paused') { return @{ Percent = 18; Label = "暂停亮度组件，避免和显示修复互相抢状态" } }
    if ($Text -match 'resolution ladder') { return @{ Percent = 10; Label = "检查 5K/刷新率阶梯" } }
    if ($Text -match 'Studio Display integrated repair started') { return @{ Percent = 5; Label = "启动统一修复管线" } }
    return @{ Percent = 3; Label = "等待修复进程启动" }
}

function Start-IntegratedRepair {
    if (-not (Test-Path -LiteralPath $integratedRepairScript)) {
        throw "Integrated repair script is missing: $integratedRepairScript"
    }

    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$integratedRepairScript`"",
        "-LogPath", "`"$LogPath`""
    )

    if ($Apply) {
        $arguments += "-Apply"
        $arguments += "-Elevate"
    }

    if ($EnsureBootCampMonitorDriver) {
        $arguments += "-EnsureBootCampMonitorDriver"
    }

    if ($RestartAppleUsb4Router) {
        $arguments += "-RestartAppleUsb4Router"
    }

    return Start-Process -FilePath $powershellExe -WorkingDirectory $scriptRoot -WindowStyle Hidden -ArgumentList $arguments -PassThru
}

function Play-RepairAudioFeedback {
    param([ValidateSet("Progress", "Fallback", "Done", "Warning")][string]$Kind = "Progress")

    try {
        switch ($Kind) {
            "Fallback" { [System.Media.SystemSounds]::Exclamation.Play() }
            "Done" { [System.Media.SystemSounds]::Asterisk.Play() }
            "Warning" { [System.Media.SystemSounds]::Hand.Play() }
            default { [System.Media.SystemSounds]::Beep.Play() }
        }
    }
    catch {
        try { [Console]::Beep(880, 180) } catch { }
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Studio Display XDR Win Controller"
$form.Size = New-Object System.Drawing.Size(720, 360)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true
$form.KeyPreview = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 247)

$title = New-Object System.Windows.Forms.Label
$title.Text = "正在恢复 Studio Display XDR 显示管线"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$title.AutoSize = $true
$title.Location = New-Object System.Drawing.Point(24, 22)

$reasonLabel = New-Object System.Windows.Forms.Label
$reasonLabel.Text = "触发原因：$Reason"
$reasonLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$reasonLabel.AutoSize = $true
$reasonLabel.Location = New-Object System.Drawing.Point(26, 58)

$stageLabel = New-Object System.Windows.Forms.Label
$stageLabel.Text = "等待修复进程启动"
$stageLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$stageLabel.AutoSize = $true
$stageLabel.Location = New-Object System.Drawing.Point(26, 92)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Minimum = 0
$progress.Maximum = 100
$progress.Value = 3
$progress.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
$progress.Location = New-Object System.Drawing.Point(28, 122)
$progress.Size = New-Object System.Drawing.Size(650, 24)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = "Vertical"
$logBox.Font = New-Object System.Drawing.Font("Consolas", 8)
$logBox.Location = New-Object System.Drawing.Point(28, 162)
$logBox.Size = New-Object System.Drawing.Size(650, 112)

$closeButton = New-Object System.Windows.Forms.Button
$closeButton.Text = "关闭"
$closeButton.Enabled = $false
$closeButton.Location = New-Object System.Drawing.Point(598, 286)
$closeButton.Size = New-Object System.Drawing.Size(80, 28)
$closeButton.Add_Click({ $form.Close() })

$fallbackButton = New-Object System.Windows.Forms.Button
$fallbackButton.Text = "先显示 fallback (Space)"
$fallbackButton.Location = New-Object System.Drawing.Point(402, 286)
$fallbackButton.Size = New-Object System.Drawing.Size(176, 28)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "建立 Boot Camp-style 身份时会有声音提示；如果暂时只想先恢复可见画面，按 Space 进入快速 fallback。"
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(28, 292)

[void]$form.Controls.Add($title)
[void]$form.Controls.Add($reasonLabel)
[void]$form.Controls.Add($stageLabel)
[void]$form.Controls.Add($progress)
[void]$form.Controls.Add($logBox)
[void]$form.Controls.Add($hint)
[void]$form.Controls.Add($fallbackButton)
[void]$form.Controls.Add($closeButton)

function Write-FastFallbackState {
    param(
        [string]$Status,
        [string]$Message
    )

    try {
        [pscustomobject]@{
            Version = 1
            UpdatedAt = (Get-Date).ToString("o")
            Status = $Status
            Message = $Message
            Reason = $Reason
        } |
            ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath $fastFallbackStateFile -Encoding ascii
    }
    catch {
    }
}

function Start-FastVisibleFallback {
    if ($script:fastFallbackRequested) {
        return
    }

    $script:fastFallbackRequested = $true
    $fallbackButton.Enabled = $false
    $stageLabel.Text = "用户按下 Space：停止等待 Boot Camp-style HDR，先恢复可见 fallback"
    $hint.Text = '正在切换快速可见 fallback。之后可从托盘点击「重建 Boot Camp-style 5K60 HDR 管线」重新走完整 HDR 管线。'
    $progress.Value = 18
    Play-RepairAudioFeedback -Kind Fallback
    Write-FastFallbackState -Status "Requested" -Message "User requested fast visible fallback with Space."

    try {
        if ($script:repairProcess -and -not $script:repairProcess.HasExited) {
            Stop-Process -Id $script:repairProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
    }

    if (-not (Test-Path -LiteralPath $externalModeRepairScript)) {
        $stageLabel.Text = "快速 fallback 失败：缺少 Repair-StudioDisplayExternalMode.ps1"
        Write-FastFallbackState -Status "Failed" -Message "External mode repair script missing."
        Play-RepairAudioFeedback -Kind Warning
        $closeButton.Enabled = $true
        return
    }

    try {
        $fallbackArguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$externalModeRepairScript`"",
            "-Topology", "External",
            "-Width", "2560",
            "-Height", "1440",
            "-RefreshRate", "60",
            "-ExpectedWidth", "1920",
            "-ExpectedHeight", "1080",
            "-ExpectedRefreshRate", "60",
            "-AllowLowResolutionFallback",
            "-AllowDisplaySwitchFallback",
            "-SkipSafetyMode"
        )

        $script:fastFallbackProcess = Start-Process -FilePath $powershellExe -WorkingDirectory $scriptRoot -WindowStyle Hidden -ArgumentList $fallbackArguments -PassThru
        Write-FastFallbackState -Status "Running" -Message "Fast visible fallback process started."
    }
    catch {
        $stageLabel.Text = "快速 fallback 启动失败：$($_.Exception.Message)"
        Write-FastFallbackState -Status "Failed" -Message $_.Exception.Message
        Play-RepairAudioFeedback -Kind Warning
        $closeButton.Enabled = $true
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$script:started = $false
$script:finished = $false
$script:repairProcess = $null
$script:fastFallbackRequested = $false
$script:fastFallbackProcess = $null
$script:lastAudioFeedbackAt = [DateTime]::MinValue

$fallbackButton.Add_Click({ Start-FastVisibleFallback })
$form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Space) {
        $eventArgs.Handled = $true
        Start-FastVisibleFallback
    }
})

$timer.Add_Tick({
    try {
        if ($script:fastFallbackRequested) {
            if ($script:fastFallbackProcess -and $script:fastFallbackProcess.HasExited) {
                $script:finished = $true
                $closeButton.Enabled = $true
                $progress.Value = 100
                if ($script:fastFallbackProcess.ExitCode -eq 0) {
                    $stageLabel.Text = "快速可见 fallback 已执行。需要 HDR 时请从托盘重建 Boot Camp-style 5K60 HDR 管线。"
                    Write-FastFallbackState -Status "Completed" -Message "Fast visible fallback completed."
                    Play-RepairAudioFeedback -Kind Done
                }
                else {
                    $stageLabel.Text = "快速 fallback 退出：ExitCode=$($script:fastFallbackProcess.ExitCode)，请查看日志"
                    Write-FastFallbackState -Status "Failed" -Message "Fast visible fallback exited with code $($script:fastFallbackProcess.ExitCode)."
                    Play-RepairAudioFeedback -Kind Warning
                }
                $timer.Stop()
            }
            return
        }

        if (-not $script:started) {
            $script:started = $true
            $script:repairProcess = Start-IntegratedRepair
            Play-RepairAudioFeedback -Kind Progress
        }

        $text = ""
        if (Test-Path -LiteralPath $LogPath) {
            $lines = @(Get-Content -LiteralPath $LogPath -Tail 24 -ErrorAction SilentlyContinue)
            $text = $lines -join "`r`n"
            $logBox.Text = $text
            $logBox.SelectionStart = $logBox.TextLength
            $logBox.ScrollToCaret()
        }

        $stage = Get-RepairStage -Text $text
        $progress.Value = [Math]::Min([Math]::Max([int]$stage.Percent, $progress.Minimum), $progress.Maximum)
        $stageLabel.Text = $stage.Label

        $now = Get-Date
        if (($now - $script:lastAudioFeedbackAt).TotalSeconds -ge 12 -and -not $script:finished) {
            $script:lastAudioFeedbackAt = $now
            Play-RepairAudioFeedback -Kind Progress
        }

        if ($stage.Percent -ge 100) {
            $script:finished = $true
            $closeButton.Enabled = $true
            Play-RepairAudioFeedback -Kind Done
            $timer.Stop()
        }
        elseif ($script:repairProcess -and $script:repairProcess.HasExited) {
            $script:finished = $true
            $closeButton.Enabled = $true
            $progress.Value = 100
            if ($script:repairProcess.ExitCode -eq 0) {
                $stageLabel.Text = "修复进程已退出，但日志没有写入完成标记；请查看日志确认最后阶段"
            }
            else {
                $stageLabel.Text = "修复进程异常退出：ExitCode=$($script:repairProcess.ExitCode)，请查看日志"
            }
            $timer.Stop()
        }
    }
    catch {
        $stageLabel.Text = "进度窗口出错：$($_.Exception.Message)"
        $closeButton.Enabled = $true
        $timer.Stop()
    }
})

$form.Add_Shown({ $timer.Start() })
$form.Add_FormClosed({
    if ($timer) {
        $timer.Stop()
        $timer.Dispose()
    }
})

[void][System.Windows.Forms.Application]::Run($form)
