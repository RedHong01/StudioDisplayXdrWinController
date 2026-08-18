[CmdletBinding(DefaultParameterSetName = "Plan")]
param(
    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$TargetHardwareId = "MONITOR\MS_0001",

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$SourceMonitorId = "APPAE3A",

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$TargetMonitorId = "MS_0001",

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [switch]$EnableHdrMetadata,

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [switch]$SignWithLocalCertificate,

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [switch]$TrustLocalSigningCertificate,

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [switch]$PreferTargetEffectiveEdid,

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$SigningCertificateSubject = "CN=StudioDIsplayWithWindows Local Driver Signing",

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$OutputDirectory = "",

    [Parameter(ParameterSetName = "Apply")]
    [switch]$Apply,

    [Parameter(ParameterSetName = "Apply")]
    [switch]$Elevate,

    [Parameter(ParameterSetName = "Plan")]
    [Parameter(ParameterSetName = "Apply")]
    [string]$LogPath = ""
)

$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $scriptRoot "drivers\StudioDisplayXdrBootCampStyleMonitor"
}

$script:bootCampMonitorLogPath = $LogPath

$displayRoot = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY"
$resolutionLadderScript = Join-Path $scriptRoot "Test-StudioDisplayResolutionLadder.ps1"
$repairScript = Join-Path $scriptRoot "Repair-StudioDisplayExternalMode.ps1"

function Write-InstallLog {
    param([string]$Message)

    Write-Host $Message
    if (-not [string]::IsNullOrWhiteSpace($script:bootCampMonitorLogPath)) {
        $parent = Split-Path -Parent $script:bootCampMonitorLogPath
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        Add-Content -LiteralPath $script:bootCampMonitorLogPath -Value "$timestamp $Message" -Encoding UTF8
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-ElevatedSelf {
    param([string[]]$Arguments)

    $powershellExe = if (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")) { Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe" } else { Join-Path $PSHOME "powershell.exe" }
    Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $Arguments -ErrorAction Stop
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
                    Edid = [byte[]]$edid
                    EdidBytes = $edid.Length
                    Name = Convert-EdidDescriptorToString -Block $block0 -DescriptorTag 0xFC
                }
            }
    )
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
                    $result[$payloadOffset + 1] = ($result[$payloadOffset + 1] -bor 0x0C)
                    $result[$payloadOffset + 2] = ($result[$payloadOffset + 2] -bor 0x01)
                    $patchedHdr = $true
                }
                elseif ($extendedTag -eq 0x05 -and $length -ge 2) {
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

function Get-EdidChecksumSummary {
    param([byte[]]$Edid)

    $states = @()
    for ($offset = 0; $offset -lt $Edid.Length; $offset += 128) {
        $block = $Edid[$offset..($offset + 127)]
        $sum = (($block | Measure-Object -Sum).Sum % 256)
        $states += [pscustomobject]@{
            Block = [int]($offset / 128)
            ChecksumOk = ($sum -eq 0)
            ChecksumByte = ("0x{0:x2}" -f $block[127])
        }
    }

    return $states
}

function Get-PreferredEdid {
    $target = @(Get-DisplayEdidEntries -MonitorId $TargetMonitorId | Sort-Object EdidBytes -Descending | Select-Object -First 1)
    $source = @(Get-DisplayEdidEntries -MonitorId $SourceMonitorId | Where-Object { $_.EdidBytes -ge 256 } | Sort-Object EdidBytes -Descending | Select-Object -First 1)

    if ($PreferTargetEffectiveEdid -and $target -and $target.EdidBytes -ge 256) {
        return [pscustomobject]@{
            Source = "target-effective"
            Entry = $target
            Edid = [byte[]]$target.Edid
        }
    }

    if ($source) {
        return [pscustomobject]@{
            Source = "source-apple"
            Entry = $source
            Edid = [byte[]]$source.Edid
        }
    }

    if ($target -and $target.EdidBytes -ge 256) {
        return [pscustomobject]@{
            Source = "target-effective-fallback"
            Entry = $target
            Edid = [byte[]]$target.Edid
        }
    }

    throw "No usable EDID was found under DISPLAY\$TargetMonitorId or DISPLAY\$SourceMonitorId."
}

function Format-InfBinaryBytes {
    param([byte[]]$Bytes)

    $hex = $Bytes | ForEach-Object { "0x{0:X2}" -f $_ }
    $lines = @()
    for ($index = 0; $index -lt $hex.Count; $index += 16) {
        $end = [Math]::Min($index + 15, $hex.Count - 1)
        $slice = $hex[$index..$end] -join ","
        if ($end -lt ($hex.Count - 1)) {
            $lines += "    $slice,\"
        }
        else {
            $lines += "    $slice"
        }
    }

    return $lines
}

function New-MonitorInfContent {
    param(
        [byte[]]$Edid,
        [string]$HardwareId,
        [string]$CatalogFileName = ""
    )

    $blocks = @(Split-EdidBlocks -Edid $Edid)
    $today = Get-Date -Format "MM/dd/yyyy"
    $lines = New-Object System.Collections.Generic.List[string]

    $lines.Add("; StudioDisplayXdrBootCampStyleMonitor.inf") | Out-Null
    $lines.Add("; Generated by StudioDIsplayWithWindows. This unsigned package mirrors Boot Camp's monitor-INF EDID override approach.") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[Version]") | Out-Null
    $lines.Add('Signature="$WINDOWS NT$"') | Out-Null
    $lines.Add("Class=Monitor") | Out-Null
    $lines.Add("ClassGuid={4D36E96E-E325-11CE-BFC1-08002BE10318}") | Out-Null
    $lines.Add("Provider=%ProviderName%") | Out-Null
    $lines.Add("DriverVer=$today,0.1.3.0") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($CatalogFileName)) {
        $lines.Add("CatalogFile=$CatalogFileName") | Out-Null
    }
    $lines.Add("PnpLockdown=1") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[Manufacturer]") | Out-Null
    $lines.Add("%ProviderName%=StudioDisplay,NTamd64") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[StudioDisplay.NTamd64]") | Out-Null
    $lines.Add("%DeviceDesc%=StudioDisplayXdr.Install, $HardwareId") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[StudioDisplayXdr.Install]") | Out-Null
    $lines.Add("DelReg=DEL_CURRENT_REG") | Out-Null
    $lines.Add("AddReg=StudioDisplayXdr.AddReg, StudioDisplayXdr.Modes, DPMS") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[StudioDisplayXdr.Install.HW]") | Out-Null
    $lines.Add("AddReg=StudioDisplayXdr.HWAddReg") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[StudioDisplayXdr.Install.Services]") | Out-Null
    $lines.Add("AddService=monitor,%SPSVCINST_ASSOCSERVICE%,Monitor_Service.Install") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[Monitor_Service.Install]") | Out-Null
    $lines.Add("DisplayName=%MonitorServiceDesc%") | Out-Null
    $lines.Add("ServiceType=%SERVICE_KERNEL_DRIVER%") | Out-Null
    $lines.Add("StartType=%SERVICE_DEMAND_START%") | Out-Null
    $lines.Add("ErrorControl=%SERVICE_ERROR_NORMAL%") | Out-Null
    $lines.Add("ServiceBinary=%12%\monitor.sys") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[DEL_CURRENT_REG]") | Out-Null
    $lines.Add("HKR,MODES") | Out-Null
    $lines.Add("HKR,,MaxResolution") | Out-Null
    $lines.Add("HKR,,DPMS") | Out-Null
    $lines.Add("HKR,,ICMProfile") | Out-Null
    $lines.Add("HKR,,PreferredMode") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[StudioDisplayXdr.AddReg]") | Out-Null
    $lines.Add('HKR,,MaxResolution,,"5120,2880"') | Out-Null
    $lines.Add('HKR,,PreferredMode,,"5120,2880,60"') | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[StudioDisplayXdr.Modes]") | Out-Null
    $lines.Add('HKR,"MODES\5120,2880",Mode1,,"178.0-180.0,59.0-61.0,+,+"') | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[DPMS]") | Out-Null
    $lines.Add("HKR,,DPMS,,1") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("[StudioDisplayXdr.HWAddReg]") | Out-Null

    for ($blockIndex = 0; $blockIndex -lt $blocks.Count; $blockIndex++) {
        $lines.Add("HKR,EDID_OVERRIDE,""$blockIndex"",0x00000001,\") | Out-Null
        foreach ($line in Format-InfBinaryBytes -Bytes $blocks[$blockIndex]) {
            $lines.Add($line) | Out-Null
        }
    }

    $lines.Add("") | Out-Null
    $lines.Add("[Strings]") | Out-Null
    $lines.Add('ProviderName="StudioDIsplayWithWindows"') | Out-Null
    $lines.Add('DeviceDesc="Studio Display XDR Boot Camp Style Monitor"') | Out-Null
    $lines.Add('MonitorServiceDesc="Monitor Class Function Driver"') | Out-Null
    $lines.Add("SPSVCINST_ASSOCSERVICE=0x00000002") | Out-Null
    $lines.Add("SERVICE_KERNEL_DRIVER=1") | Out-Null
    $lines.Add("SERVICE_DEMAND_START=3") | Out-Null
    $lines.Add("SERVICE_ERROR_NORMAL=1") | Out-Null

    return ($lines -join [Environment]::NewLine)
}

function Get-LocalCodeSigningCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject
    )

    $stores = @("Cert:\LocalMachine\My", "Cert:\CurrentUser\My")
    foreach ($store in $stores) {
        $certificate = Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Subject -eq $Subject -and
                $_.HasPrivateKey -and
                $_.NotAfter -gt (Get-Date).AddDays(30)
            } |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1

        if ($certificate) {
            Write-InstallLog "Using existing local signing certificate: $($certificate.Thumbprint) from $store"
            return $certificate
        }
    }

    $targetStore = if (Test-IsAdministrator) { "Cert:\LocalMachine\My" } else { "Cert:\CurrentUser\My" }
    Write-InstallLog "Creating local code-signing certificate in ${targetStore}: $Subject"
    return New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $Subject `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -HashAlgorithm SHA256 `
        -CertStoreLocation $targetStore `
        -NotAfter (Get-Date).AddYears(5)
}

function Install-LocalSigningCertificateTrust {
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory = $true)]
        [string]$OutputDirectory
    )

    if (-not (Test-IsAdministrator)) {
        throw "TrustLocalSigningCertificate requires administrator rights because it writes to LocalMachine certificate stores."
    }

    $certificatePath = Join-Path $OutputDirectory "StudioDisplayLocalDriverSigning.cer"
    Export-Certificate -Cert $Certificate -FilePath $certificatePath -Force | Out-Null

    foreach ($store in @("Cert:\LocalMachine\Root", "Cert:\LocalMachine\TrustedPublisher")) {
        $existing = Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint } |
            Select-Object -First 1

        if ($existing) {
            Write-InstallLog "Local signing certificate already trusted in ${store}: $($Certificate.Thumbprint)"
            continue
        }

        Import-Certificate -FilePath $certificatePath -CertStoreLocation $store | Out-Null
        Write-InstallLog "Trusted local signing certificate in ${store}: $($Certificate.Thumbprint)"
    }

    return $certificatePath
}

function New-SignedMonitorCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InfPath,
        [Parameter(Mandatory = $true)]
        [string]$CatalogPath,
        [Parameter(Mandatory = $true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate
    )

    if (Test-Path -LiteralPath $CatalogPath) {
        Remove-Item -LiteralPath $CatalogPath -Force
    }

    Write-InstallLog "Generating local driver catalog: $CatalogPath"
    New-FileCatalog -Path $InfPath -CatalogFilePath $CatalogPath -CatalogVersion 2.0 | Out-Null

    Write-InstallLog "Signing local driver catalog with certificate: $($Certificate.Thumbprint)"
    $signature = Set-AuthenticodeSignature -FilePath $CatalogPath -Certificate $Certificate -HashAlgorithm SHA256
    Write-InstallLog "Catalog signature status: $($signature.Status) $($signature.StatusMessage)"

    $verifiedSignature = Get-AuthenticodeSignature -FilePath $CatalogPath
    Write-InstallLog "Catalog verification status: $($verifiedSignature.Status) $($verifiedSignature.StatusMessage)"
    if ($verifiedSignature.Status -ne "Valid") {
        throw "Signed catalog verification failed: $($verifiedSignature.Status) $($verifiedSignature.StatusMessage)"
    }

    return $verifiedSignature
}

function Invoke-MonitorDriverInstall {
    param([string]$InfPath)

    Write-InstallLog "Installing monitor INF with pnputil: $InfPath"
    $output = & pnputil.exe /add-driver $InfPath /install 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-InstallLog ([string]$_) }
    if ($exitCode -ne 0) {
        $joinedOutput = ($output | Out-String)
        if ($joinedOutput -match 'Already exists in the system' -or $joinedOutput -match 'up-to-date on device') {
            Write-InstallLog "pnputil returned exit code $exitCode, but the driver package already exists and is up-to-date; treating this as success."
        }
        else {
            throw "pnputil failed with exit code $exitCode. Windows rejected the monitor driver package; check install.log for signature, trust, or rank details."
        }
    }

    & pnputil.exe /scan-devices | ForEach-Object { Write-InstallLog ([string]$_) }

    if (Test-Path -LiteralPath $resolutionLadderScript) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $resolutionLadderScript 2>&1 |
            ForEach-Object { Write-InstallLog ([string]$_) }
    }

    if (Test-Path -LiteralPath $repairScript) {
        $repairOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $repairScript `
            -Topology External `
            -ExpectedWidth 5120 `
            -ExpectedHeight 2880 `
            -ExpectedRefreshRate 60 `
            -RefreshRate 60 `
            -SkipSafetyMode `
            -PreserveActiveHdr 2>&1
        $repairExitCode = $LASTEXITCODE
        $repairOutput | ForEach-Object { Write-InstallLog ([string]$_) }
        if ($repairExitCode -ne 0) {
            Write-InstallLog "Post-install 5K60 mode guard returned exit code $repairExitCode. The monitor INF install succeeded; the integrated repair will continue with USB4/monitor retraining before final 5K/HDR validation."
        }
    }
}

$preferred = Get-PreferredEdid
$edidToWrite = [byte[]]$preferred.Edid
$hdrPatchSummary = $null
if ($EnableHdrMetadata) {
    $hdrPatchSummary = Enable-EdidHdrMetadata -Edid $edidToWrite
    $edidToWrite = [byte[]]$hdrPatchSummary.Edid
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
if ([string]::IsNullOrWhiteSpace($script:bootCampMonitorLogPath)) {
    $script:bootCampMonitorLogPath = Join-Path $OutputDirectory "install.log"
}

$infPath = Join-Path $OutputDirectory "StudioDisplayXdrBootCampStyleMonitor.inf"
$catalogPath = Join-Path $OutputDirectory "StudioDisplayXdrBootCampStyleMonitor.cat"
$edidPath = Join-Path $OutputDirectory "StudioDisplayXdrBootCampStyleMonitor.edid.bin"
$metadataPath = Join-Path $OutputDirectory "metadata.json"

if ($Apply -and -not (Test-IsAdministrator)) {
    if ($Elevate) {
        $args = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", "`"$PSCommandPath`"",
            "-Apply",
            "-TargetHardwareId", "`"$TargetHardwareId`"",
            "-SourceMonitorId", "`"$SourceMonitorId`"",
            "-TargetMonitorId", "`"$TargetMonitorId`"",
            "-OutputDirectory", "`"$OutputDirectory`"",
            "-LogPath", "`"$script:bootCampMonitorLogPath`""
        )
        if ($EnableHdrMetadata) {
            $args += "-EnableHdrMetadata"
        }
        if ($SignWithLocalCertificate) {
            $args += "-SignWithLocalCertificate"
        }
        if ($TrustLocalSigningCertificate) {
            $args += "-TrustLocalSigningCertificate"
        }
        if ($PreferTargetEffectiveEdid) {
            $args += "-PreferTargetEffectiveEdid"
        }
        if (-not [string]::IsNullOrWhiteSpace($SigningCertificateSubject)) {
            $args += "-SigningCertificateSubject"
            $args += "`"$SigningCertificateSubject`""
        }

        Start-ElevatedSelf -Arguments $args
        exit 0
    }

    throw "Apply requires administrator rights. Re-run with -Apply -Elevate or from an elevated PowerShell."
}

$catalogFileName = if ($SignWithLocalCertificate) { Split-Path -Leaf $catalogPath } else { "" }
$infContent = New-MonitorInfContent -Edid $edidToWrite -HardwareId $TargetHardwareId -CatalogFileName $catalogFileName
Set-Content -LiteralPath $infPath -Value $infContent -Encoding ASCII
[System.IO.File]::WriteAllBytes($edidPath, $edidToWrite)

$signingCertificate = $null
$signature = $null
$trustedCertificatePath = $null
if ($SignWithLocalCertificate) {
    $signingCertificate = Get-LocalCodeSigningCertificate -Subject $SigningCertificateSubject
    if ($TrustLocalSigningCertificate) {
        $trustedCertificatePath = Install-LocalSigningCertificateTrust -Certificate $signingCertificate -OutputDirectory $OutputDirectory
    }

    $signature = New-SignedMonitorCatalog -InfPath $infPath -CatalogPath $catalogPath -Certificate $signingCertificate
}

$metadata = [pscustomobject]@{
    Created = (Get-Date).ToString("o")
    Strategy = "BootCamp-style Monitor INF with EDID_OVERRIDE in DDInstall.HW"
    TargetHardwareId = $TargetHardwareId
    Source = $preferred.Source
    SourceMonitorId = $preferred.Entry.MonitorId
    SourceInstanceId = $preferred.Entry.InstanceId
    SourceName = $preferred.Entry.Name
    EdidBytes = $edidToWrite.Length
    EnableHdrMetadata = [bool]$EnableHdrMetadata
    SignWithLocalCertificate = [bool]$SignWithLocalCertificate
    TrustLocalSigningCertificate = [bool]$TrustLocalSigningCertificate
    PreferTargetEffectiveEdid = [bool]$PreferTargetEffectiveEdid
    SigningCertificateSubject = if ($signingCertificate) { $signingCertificate.Subject } else { $SigningCertificateSubject }
    SigningCertificateThumbprint = if ($signingCertificate) { $signingCertificate.Thumbprint } else { $null }
    SigningCertificateExport = $trustedCertificatePath
    CatalogPath = if ($SignWithLocalCertificate) { $catalogPath } else { $null }
    CatalogSignatureStatus = if ($signature) { [string]$signature.Status } else { $null }
    HdrPatch = if ($hdrPatchSummary) {
        [pscustomobject]@{
            PatchedHdr = $hdrPatchSummary.PatchedHdr
            PatchedColorimetry = $hdrPatchSummary.PatchedColorimetry
        }
    }
    else {
        $null
    }
    Checksum = @(Get-EdidChecksumSummary -Edid $edidToWrite)
    InfPath = $infPath
    EdidPath = $edidPath
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metadataPath -Encoding UTF8

Write-Host "Boot Camp-style monitor INF generated."
Write-Host "Source: $($preferred.Source) DISPLAY\$($preferred.Entry.MonitorId)\$($preferred.Entry.InstanceId) '$($preferred.Entry.Name)'"
Write-Host "Target hardware ID: $TargetHardwareId"
Write-Host "INF: $infPath"
if ($SignWithLocalCertificate) {
    Write-Host "Catalog: $catalogPath"
    Write-Host "Local signing certificate: $($signingCertificate.Thumbprint)"
}
Write-Host "EDID binary: $edidPath"
Write-Host "Metadata: $metadataPath"
Write-Host "Checksums:"
Get-EdidChecksumSummary -Edid $edidToWrite | Format-Table -AutoSize

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry run only. Re-run with -Apply -Elevate to attempt pnputil installation."
    Write-Host "Add -SignWithLocalCertificate -TrustLocalSigningCertificate to build and trust a local signed package when pnputil rejects unsigned monitor INFs."
    exit 0
}

Invoke-MonitorDriverInstall -InfPath $infPath
