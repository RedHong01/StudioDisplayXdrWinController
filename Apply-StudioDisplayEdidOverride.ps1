[CmdletBinding(DefaultParameterSetName = "Plan")]
param(
    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$SourceMonitorId = "APPAE3A",

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$SourceInstanceId,

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$TargetMonitorId = "MS_0001",

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$TargetInstanceId,

    [Parameter(ParameterSetName = "Apply")]
    [switch]$Apply,

    [Parameter(ParameterSetName = "Apply")]
    [switch]$EnableHdrMetadata,

    [Parameter(ParameterSetName = "Apply")]
    [switch]$PatchEffectiveEdidCache,

    [Parameter(ParameterSetName = "Apply")]
    [switch]$Elevate,

    [Parameter(ParameterSetName = "Rollback")]
    [switch]$Rollback,

    [Parameter(ParameterSetName = "Rollback")]
    [string]$RollbackTargetInstanceId,

    [Parameter(ParameterSetName = "Rollback")]
    [switch]$RollbackElevate
)

$ErrorActionPreference = "Stop"

$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$nativeDisplayRoot = "HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$backupRoot = Join-Path $PSScriptRoot "backups\edid-overrides"
$resolutionLadderScript = Join-Path $PSScriptRoot "Test-StudioDisplayResolutionLadder.ps1"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedSelf {
    param([string[]]$Arguments)

    $powershellExe = Join-Path $PSHOME "powershell.exe"
    Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $Arguments -ErrorAction Stop
}

function Get-EdidChecksumState {
    param([byte[]]$Edid)

    $states = New-Object System.Collections.Generic.List[object]
    for ($offset = 0; $offset -lt $Edid.Length; $offset += 128) {
        $length = [Math]::Min(128, $Edid.Length - $offset)
        if ($length -lt 128) {
            continue
        }

        $sum = 0
        for ($index = 0; $index -lt 128; $index++) {
            $sum = ($sum + $Edid[$offset + $index]) -band 0xFF
        }

        $states.Add([pscustomobject]@{
                Block = [int]($offset / 128)
                ChecksumOk = ($sum -eq 0)
            }) | Out-Null
    }

    return $states.ToArray()
}

function Convert-EdidDescriptorToString {
    param(
        [byte[]]$Block,
        [byte]$DescriptorTag
    )

    $values = @()
    foreach ($offset in 54, 72, 90, 108) {
        if ($Block.Length -lt ($offset + 18)) {
            continue
        }

        if ($Block[$offset] -eq 0 -and $Block[$offset + 1] -eq 0 -and $Block[$offset + 2] -eq 0 -and $Block[$offset + 3] -eq $DescriptorTag) {
            $bytes = $Block[($offset + 5)..($offset + 17)]
            $text = ([System.Text.Encoding]::ASCII.GetString($bytes)).Trim([char]0, [char]10, [char]13, " ")
            if ($text) {
                $values += $text
            }
        }
    }

    return ($values -join "; ")
}

function Get-DisplayEdidEntries {
    param([string]$MonitorId)

    $monitorPath = Join-Path $displayRoot $MonitorId
    if (-not (Test-Path -LiteralPath $monitorPath)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $monitorPath -ErrorAction SilentlyContinue |
            ForEach-Object {
                $deviceParametersPath = Join-Path $_.PSPath "Device Parameters"
                if (-not (Test-Path -LiteralPath $deviceParametersPath)) {
                    return
                }

                $key = Get-Item -LiteralPath $deviceParametersPath -ErrorAction SilentlyContinue
                if (-not $key) {
                    return
                }

                $edid = $key.GetValue("EDID")
                if (-not $edid) {
                    return
                }

                $block0 = [byte[]]($edid[0..127])
                [pscustomobject]@{
                    MonitorId = $MonitorId
                    InstanceId = $_.PSChildName
                    DeviceParametersPath = $deviceParametersPath
                    NativeDeviceParametersPath = "$nativeDisplayRoot\$MonitorId\$($_.PSChildName)\Device Parameters"
                    Edid = [byte[]]$edid
                    EdidBytes = $edid.Length
                    Name = Convert-EdidDescriptorToString -Block $block0 -DescriptorTag 0xFC
                    Checksum = @(Get-EdidChecksumState -Edid ([byte[]]$edid))
                }
            }
    )
}

function Resolve-TargetEntry {
    if ($TargetInstanceId) {
        $entries = @(Get-DisplayEdidEntries -MonitorId $TargetMonitorId)
        return $entries | Where-Object { $_.InstanceId -ieq $TargetInstanceId } | Select-Object -First 1
    }

    try {
        $presentTarget = Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction Stop |
            Where-Object { $_.InstanceId -like "DISPLAY\$TargetMonitorId\*" } |
            Select-Object -First 1

        if ($presentTarget -and $presentTarget.InstanceId -match "^DISPLAY\\[^\\]+\\(.+)$") {
            $TargetInstanceId = $Matches[1]
            $entries = @(Get-DisplayEdidEntries -MonitorId $TargetMonitorId)
            return $entries | Where-Object { $_.InstanceId -ieq $TargetInstanceId } | Select-Object -First 1
        }
    }
    catch {
    }

    return @(Get-DisplayEdidEntries -MonitorId $TargetMonitorId) |
        Sort-Object EdidBytes -Descending |
        Select-Object -First 1
}

function Resolve-SourceEntry {
    param([string]$PreferredInstanceId)

    $entries = @(Get-DisplayEdidEntries -MonitorId $SourceMonitorId) |
        Where-Object { $_.EdidBytes -ge 256 }

    if ($SourceInstanceId) {
        return $entries | Where-Object { $_.InstanceId -ieq $SourceInstanceId } | Select-Object -First 1
    }

    if ($PreferredInstanceId) {
        $sameInstance = $entries | Where-Object { $_.InstanceId -ieq $PreferredInstanceId } | Select-Object -First 1
        if ($sameInstance) {
            return $sameInstance
        }
    }

    return $entries |
        Sort-Object EdidBytes -Descending |
        Select-Object -First 1
}

function Split-EdidBlocks {
    param([byte[]]$Edid)

    $blocks = @()
    for ($offset = 0; $offset -lt $Edid.Length; $offset += 128) {
        $length = [Math]::Min(128, $Edid.Length - $offset)
        if ($length -lt 128) {
            continue
        }

        $block = New-Object byte[] 128
        [Array]::Copy($Edid, $offset, $block, 0, 128)
        $blocks += ,$block
    }

    return $blocks
}

function Update-EdidBlockChecksum {
    param([byte[]]$Block)

    if ($Block.Length -ne 128) {
        throw "EDID block must be exactly 128 bytes."
    }

    $sum = 0
    for ($index = 0; $index -lt 127; $index++) {
        $sum = ($sum + $Block[$index]) -band 0xFF
    }

    $Block[127] = ((256 - $sum) -band 0xFF)
}

function Enable-EdidHdrMetadata {
    param([byte[]]$Edid)

    $result = New-Object byte[] $Edid.Length
    [Array]::Copy($Edid, $result, $Edid.Length)

    $patchedHdr = $false
    $patchedColorimetry = $false
    for ($blockOffset = 128; $blockOffset -lt $result.Length; $blockOffset += 128) {
        if ($result[$blockOffset] -ne 0x02) {
            continue
        }

        $dtdStart = $result[$blockOffset + 2]
        if ($dtdStart -eq 0 -or $dtdStart -gt 127) {
            $dtdStart = 127
        }

        $offset = $blockOffset + 4
        while ($offset -lt ($blockOffset + $dtdStart)) {
            $header = $result[$offset]
            $tag = ($header -shr 5) -band 0x07
            $length = $header -band 0x1F
            if ($length -le 0) {
                $offset += 1
                continue
            }

            $payloadOffset = $offset + 1
            if (($payloadOffset + $length) -gt ($blockOffset + 127)) {
                break
            }

            if ($tag -eq 7) {
                $extendedTag = $result[$payloadOffset]
                if ($extendedTag -eq 0x06 -and $length -ge 3) {
                    # EOTF bits: keep SDR and add SMPTE ST 2084/PQ plus HLG for Windows HDR detection.
                    $result[$payloadOffset + 1] = ($result[$payloadOffset + 1] -bor 0x0C)
                    # Static metadata descriptor type 1 is required for common HDR10 metadata.
                    $result[$payloadOffset + 2] = ($result[$payloadOffset + 2] -bor 0x01)
                    $patchedHdr = $true
                }
                elseif ($extendedTag -eq 0x05 -and $length -ge 2) {
                    # Preserve existing colorimetry and add BT.2020 RGB/YCC container flags.
                    $result[$payloadOffset + 1] = ($result[$payloadOffset + 1] -bor 0xC0)
                    $patchedColorimetry = $true
                }
            }

            $offset += 1 + $length
        }

        $block = New-Object byte[] 128
        [Array]::Copy($result, $blockOffset, $block, 0, 128)
        Update-EdidBlockChecksum -Block $block
        [Array]::Copy($block, 0, $result, $blockOffset, 128)
    }

    if (-not $patchedHdr) {
        throw "No CTA HDR Static Metadata block was found in the source EDID."
    }

    return [pscustomobject]@{
        Edid = $result
        PatchedHdr = $patchedHdr
        PatchedColorimetry = $patchedColorimetry
    }
}

function Export-RegistryBackup {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TargetEntry
    )

    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDirectory = Join-Path $backupRoot $timestamp
    New-Item -ItemType Directory -Force -Path $backupDirectory | Out-Null

    $regPath = Join-Path $backupDirectory "target-device-parameters-before.reg"
    $sourcePath = Join-Path $backupDirectory "source-edid.bin"
    [System.IO.File]::WriteAllBytes($sourcePath, $script:sourceEntry.Edid)

    $regOutput = & reg.exe export $TargetEntry.NativeDeviceParametersPath $regPath /y 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Registry backup failed: $($regOutput -join ' ')"
    }

    $metadata = [pscustomobject]@{
        Created = (Get-Date).ToString("o")
        SourceMonitorId = $script:sourceEntry.MonitorId
        SourceInstanceId = $script:sourceEntry.InstanceId
        SourceEdidBytes = $script:sourceEntry.EdidBytes
        TargetMonitorId = $TargetEntry.MonitorId
        TargetInstanceId = $TargetEntry.InstanceId
        TargetNativeDeviceParametersPath = $TargetEntry.NativeDeviceParametersPath
        RegistryBackup = $regPath
        SourceEdid = $sourcePath
        EnableHdrMetadata = [bool]$EnableHdrMetadata
        PatchEffectiveEdidCache = [bool]$PatchEffectiveEdidCache
    }

    $metadataPath = Join-Path $backupDirectory "metadata.json"
    $metadata | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadataPath -Encoding utf8

    return [pscustomobject]@{
        Directory = $backupDirectory
        RegistryBackup = $regPath
        Metadata = $metadataPath
    }
}

function Write-EdidOverride {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TargetEntry,
        [Parameter(Mandatory = $true)]
        [byte[]]$Edid
    )

    $overridePath = Join-Path $TargetEntry.DeviceParametersPath "EDID_OVERRIDE"
    New-Item -Path $overridePath -Force | Out-Null

    $blocks = @(Split-EdidBlocks -Edid $Edid)
    for ($index = 0; $index -lt $blocks.Count; $index++) {
        New-ItemProperty -LiteralPath $overridePath -Name ([string]$index) -PropertyType Binary -Value $blocks[$index] -Force | Out-Null
    }

    return $blocks.Count
}

function Write-EffectiveEdidCache {
    param(
        [Parameter(Mandatory = $true)]
        [object]$TargetEntry,
        [Parameter(Mandatory = $true)]
        [byte[]]$Edid
    )

    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(($TargetEntry.NativeDeviceParametersPath -replace "^HKLM\\", ""), $true)
    if (-not $key) {
        throw "Unable to open target device parameters registry key for writing."
    }

    $currentEdid = $key.GetValue("EDID")
    if (-not $currentEdid) {
        $key.Close()
        throw "Target device does not have an EDID cache value to patch."
    }

    if (-not $key.GetValue("EDID_STUDIO_TOOLS_BACKUP")) {
        $key.SetValue("EDID_STUDIO_TOOLS_BACKUP", [byte[]]$currentEdid, [Microsoft.Win32.RegistryValueKind]::Binary)
    }

    $key.SetValue("EDID", $Edid, [Microsoft.Win32.RegistryValueKind]::Binary)
    $key.SetValue("EDID_STUDIO_TOOLS_LAST_PATCH_UTC", ([DateTime]::UtcNow.ToString("o")), [Microsoft.Win32.RegistryValueKind]::String)

    $readBack = [byte[]]$key.GetValue("EDID")
    $key.Close()
    if ($readBack.Length -ne $Edid.Length) {
        throw "Effective EDID cache write verification failed: expected $($Edid.Length) bytes, read $($readBack.Length) bytes."
    }

    for ($index = 0; $index -lt $Edid.Length; $index++) {
        if ($readBack[$index] -ne $Edid[$index]) {
            throw "Effective EDID cache write verification failed at byte $index."
        }
    }
}

function Restart-TargetMonitor {
    param([object]$TargetEntry)

    $pnpInstanceId = "DISPLAY\$($TargetEntry.MonitorId)\$($TargetEntry.InstanceId)"
    Write-Host "Restarting monitor device: $pnpInstanceId"
    & pnputil /restart-device $pnpInstanceId
    Start-Sleep -Seconds 3
    & pnputil /scan-devices
    Start-Sleep -Seconds 3
}

function Invoke-LadderIfPresent {
    if (Test-Path -LiteralPath $resolutionLadderScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $resolutionLadderScript
    }
}

function Remove-TargetOverride {
    param([object]$TargetEntry)

    $overridePath = Join-Path $TargetEntry.DeviceParametersPath "EDID_OVERRIDE"
    if (Test-Path -LiteralPath $overridePath) {
        Remove-Item -LiteralPath $overridePath -Recurse -Force
        Write-Host "Removed EDID_OVERRIDE: $overridePath"
    }
    else {
        Write-Host "No EDID_OVERRIDE key exists: $overridePath"
    }

    $key = Get-Item -LiteralPath $TargetEntry.DeviceParametersPath -ErrorAction SilentlyContinue
    if ($key) {
        $effectiveEdidBackup = $key.GetValue("EDID_STUDIO_TOOLS_BACKUP")
        if ($effectiveEdidBackup) {
            $nativeKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(($TargetEntry.NativeDeviceParametersPath -replace "^HKLM\\", ""), $true)
            if (-not $nativeKey) {
                throw "Unable to open target device parameters registry key for rollback."
            }

            $nativeKey.SetValue("EDID", [byte[]]$effectiveEdidBackup, [Microsoft.Win32.RegistryValueKind]::Binary)
            $nativeKey.Close()
            Remove-ItemProperty -LiteralPath $TargetEntry.DeviceParametersPath -Name "EDID_STUDIO_TOOLS_BACKUP" -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $TargetEntry.DeviceParametersPath -Name "EDID_STUDIO_TOOLS_LAST_PATCH_UTC" -ErrorAction SilentlyContinue
            Write-Host "Restored original effective EDID cache from EDID_STUDIO_TOOLS_BACKUP."
        }
        else {
            Write-Host "No EDID_STUDIO_TOOLS_BACKUP value exists; effective EDID cache was left unchanged."
        }
    }

    Restart-TargetMonitor -TargetEntry $TargetEntry
}

if ($Rollback) {
    if (-not (Test-IsAdministrator)) {
        if ($RollbackElevate) {
            $args = @(
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-File", "`"$PSCommandPath`"",
                "-Rollback"
            )
            if ($RollbackTargetInstanceId) {
                $args += "-RollbackTargetInstanceId"
                $args += "`"$RollbackTargetInstanceId`""
            }
            Start-ElevatedSelf -Arguments $args
            exit 0
        }

        throw "Rollback requires administrator rights. Re-run with -RollbackElevate or from an elevated PowerShell."
    }

    if ($RollbackTargetInstanceId) {
        $TargetInstanceId = $RollbackTargetInstanceId
    }

    $targetEntry = Resolve-TargetEntry
    if (-not $targetEntry) {
        throw "Target monitor entry was not found for $TargetMonitorId."
    }

    Remove-TargetOverride -TargetEntry $targetEntry
    Invoke-LadderIfPresent
    exit 0
}

$targetEntry = Resolve-TargetEntry
if (-not $targetEntry) {
    throw "Target monitor entry was not found for $TargetMonitorId."
}

$script:sourceEntry = Resolve-SourceEntry -PreferredInstanceId $targetEntry.InstanceId
if (-not $script:sourceEntry) {
    throw "Source EDID entry was not found for $SourceMonitorId."
}

$targetOverridePath = Join-Path $targetEntry.DeviceParametersPath "EDID_OVERRIDE"
$sourceChecksumOk = -not (@($script:sourceEntry.Checksum | Where-Object { -not $_.ChecksumOk }) | Select-Object -First 1)

Write-Host "Studio Display EDID override plan"
Write-Host "Source: $($script:sourceEntry.MonitorId)\$($script:sourceEntry.InstanceId) name='$($script:sourceEntry.Name)' bytes=$($script:sourceEntry.EdidBytes) checksumOk=$sourceChecksumOk"
Write-Host "Target: $($targetEntry.MonitorId)\$($targetEntry.InstanceId) name='$($targetEntry.Name)' bytes=$($targetEntry.EdidBytes)"
Write-Host "Target override path: $targetOverridePath"
Write-Host "Existing override: $(Test-Path -LiteralPath $targetOverridePath)"
Write-Host "HDR metadata patch requested: $EnableHdrMetadata"
Write-Host "Effective EDID cache patch requested: $PatchEffectiveEdidCache"

if (-not $sourceChecksumOk) {
    throw "Source EDID checksum is not valid; refusing to write override."
}

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry run only. Re-run with -Apply -Elevate to write EDID_OVERRIDE and restart the monitor device."
    Write-Host "Add -EnableHdrMetadata to include PQ/ST2084 HDR metadata in the override."
    Write-Host "Add -PatchEffectiveEdidCache only if Windows keeps using the stale Device Parameters\EDID cache after override."
    Write-Host "Rollback command after apply: powershell -ExecutionPolicy Bypass -File .\Apply-StudioDisplayEdidOverride.ps1 -Rollback -RollbackElevate"
    exit 0
}

if (-not (Test-IsAdministrator)) {
    if ($Elevate) {
        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-Apply"
        )
        if ($SourceMonitorId) {
            $args += "-SourceMonitorId"
            $args += "`"$SourceMonitorId`""
        }
        if ($script:sourceEntry.InstanceId) {
            $args += "-SourceInstanceId"
            $args += "`"$($script:sourceEntry.InstanceId)`""
        }
        if ($EnableHdrMetadata) {
            $args += "-EnableHdrMetadata"
        }
        if ($PatchEffectiveEdidCache) {
            $args += "-PatchEffectiveEdidCache"
        }
        if ($TargetMonitorId) {
            $args += "-TargetMonitorId"
            $args += "`"$TargetMonitorId`""
        }
        if ($targetEntry.InstanceId) {
            $args += "-TargetInstanceId"
            $args += "`"$($targetEntry.InstanceId)`""
        }

        Start-ElevatedSelf -Arguments $args
        exit 0
    }

    throw "Apply requires administrator rights. Re-run with -Apply -Elevate or from an elevated PowerShell."
}

$backup = Export-RegistryBackup -TargetEntry $targetEntry
Write-Host "Backup directory: $($backup.Directory)"

$edidToWrite = $script:sourceEntry.Edid
if ($EnableHdrMetadata) {
    $hdrPatch = Enable-EdidHdrMetadata -Edid $edidToWrite
    $edidToWrite = $hdrPatch.Edid
    Write-Host "Enabled HDR metadata in EDID override. PatchedHdr=$($hdrPatch.PatchedHdr); PatchedColorimetry=$($hdrPatch.PatchedColorimetry)"
}

$writtenBlocks = Write-EdidOverride -TargetEntry $targetEntry -Edid $edidToWrite
Write-Host "Wrote EDID_OVERRIDE blocks: $writtenBlocks"

Restart-TargetMonitor -TargetEntry $targetEntry

if ($PatchEffectiveEdidCache) {
    Write-EffectiveEdidCache -TargetEntry $targetEntry -Edid $edidToWrite
    Write-Host "Patched effective Device Parameters\EDID cache after monitor restart. Original cache is stored in EDID_STUDIO_TOOLS_BACKUP for rollback."
}

Invoke-LadderIfPresent
