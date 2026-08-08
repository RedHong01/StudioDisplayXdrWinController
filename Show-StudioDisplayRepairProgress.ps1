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
$powershellExe = Join-Path $PSHOME "powershell.exe"

if (-not $LogPath) {
    New-Item -ItemType Directory -Force -Path $reportsRoot -ErrorAction SilentlyContinue | Out-Null
    $LogPath = Join-Path $reportsRoot ("StudioDisplayIntegratedRepair-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
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

    Start-Process -FilePath $powershellExe -WorkingDirectory $scriptRoot -WindowStyle Hidden -ArgumentList $arguments
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Studio Display XDR Win Controller"
$form.Size = New-Object System.Drawing.Size(720, 360)
$form.StartPosition = "CenterScreen"
$form.TopMost = $true
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

$hint = New-Object System.Windows.Forms.Label
$hint.Text = "屏幕短暂黑屏/闪烁是 Windows 重新训练显示链路时的正常现象；这个窗口会持续显示日志阶段。"
$hint.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$hint.AutoSize = $true
$hint.Location = New-Object System.Drawing.Point(28, 292)

[void]$form.Controls.Add($title)
[void]$form.Controls.Add($reasonLabel)
[void]$form.Controls.Add($stageLabel)
[void]$form.Controls.Add($progress)
[void]$form.Controls.Add($logBox)
[void]$form.Controls.Add($hint)
[void]$form.Controls.Add($closeButton)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$script:started = $false
$script:finished = $false

$timer.Add_Tick({
    try {
        if (-not $script:started) {
            $script:started = $true
            Start-IntegratedRepair
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

        if ($stage.Percent -ge 100) {
            $script:finished = $true
            $closeButton.Enabled = $true
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
