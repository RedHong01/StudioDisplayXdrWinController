[CmdletBinding()]
param(
    [switch]$SkipAutoStart,
    [switch]$SkipStartNow
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repoApi = "https://api.github.com/repos/sfjohnson/studio-brightness/releases/latest"
$installRoot = Join-Path $env:LOCALAPPDATA "StudioDisplayTools\studio-brightness"
$exePath = Join-Path $installRoot "studio-brightness.exe"
$startupShortcut = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup\Studio Display Brightness.lnk"
$tempDir = Join-Path $env:TEMP ("studio-brightness-" + [guid]::NewGuid().ToString("N"))

function Test-StudioDisplayPresence {
    $monitorText = (& pnputil /enum-devices /class Monitor 2>$null | Out-String)
    $usbText = (& pnputil /enum-devices /class USB 2>$null | Out-String)
    $cameraText = (& pnputil /enum-devices /class Camera 2>$null | Out-String)
    $mediaText = (& pnputil /enum-devices /class Media 2>$null | Out-String)

    [pscustomobject]@{
        MonitorDetected = ($monitorText -match "DISPLAY\\APPAE3A") -or ($monitorText -match "StudioDisplay")
        UsbDetected     = $usbText -match "VID_05AC&PID_1114"
        CameraDetected  = $cameraText -match "Studio Display Camera"
        AudioDetected   = $mediaText -match "Studio Display Audio"
    }
}

function New-Shortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [string]$WorkingDirectory,
        [string]$IconLocation
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $TargetPath
    if ($WorkingDirectory) {
        $shortcut.WorkingDirectory = $WorkingDirectory
    }
    if ($IconLocation) {
        $shortcut.IconLocation = $IconLocation
    }
    $shortcut.Save()
}

$presence = Test-StudioDisplayPresence
Write-Host "Studio Display monitor detected: $($presence.MonitorDetected)"
Write-Host "Studio Display USB device detected: $($presence.UsbDetected)"
Write-Host "Studio Display camera detected: $($presence.CameraDetected)"
Write-Host "Studio Display audio detected: $($presence.AudioDetected)"

New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    $headers = @{ "User-Agent" = "StudioDisplayInstaller/1.0" }
    $release = Invoke-RestMethod -Uri $repoApi -Headers $headers
    $asset = $release.assets |
        Where-Object { $_.name -match "^studio-brightness.*\.exe$" } |
        Select-Object -First 1

    if (-not $asset) {
        $asset = $release.assets |
            Where-Object { $_.name -match "\.exe$" } |
            Select-Object -First 1
    }

    if (-not $asset) {
        throw "No downloadable Windows executable was found in the latest GitHub release."
    }

    $downloadPath = Join-Path $tempDir $asset.name
    Write-Host "Downloading $($asset.name) from $($release.tag_name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -Headers $headers -OutFile $downloadPath

    Copy-Item -LiteralPath $downloadPath -Destination $exePath -Force
    Write-Host "Installed to $exePath"

    if (-not $SkipAutoStart) {
        if (Test-Path $startupShortcut) {
            Remove-Item -LiteralPath $startupShortcut -Force
        }

        New-Shortcut -Path $startupShortcut -TargetPath $exePath -WorkingDirectory $installRoot -IconLocation "$exePath,0"
        Write-Host "Auto-start shortcut created at $startupShortcut"
    } else {
        Write-Host "Skipped auto-start creation."
    }

    if (-not $SkipStartNow) {
        $running = Get-Process -Name "studio-brightness" -ErrorAction SilentlyContinue
        if (-not $running) {
            Start-Process -FilePath $exePath -WorkingDirectory $installRoot
            Start-Sleep -Seconds 2
        }
    }

    $running = Get-Process -Name "studio-brightness" -ErrorAction SilentlyContinue
    if ($running) {
        Write-Host "studio-brightness is running."
    } else {
        Write-Warning "studio-brightness was installed, but it is not running yet."
    }
}
finally {
    if (Test-Path $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

