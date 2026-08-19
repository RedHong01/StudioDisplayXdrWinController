[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Subject = "CN=StudioDIsplayWithWindows Local Driver Signing",
    [string]$Thumbprint = "",
    [switch]$Elevate
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator) -and $Elevate) {
    $powershellExe = Join-Path $PSHOME "powershell.exe"
    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-Subject", "`"$Subject`""
    )

    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
        $args += "-Thumbprint"
        $args += "`"$Thumbprint`""
    }

    Start-Process -FilePath $powershellExe -Verb RunAs -ArgumentList $args -ErrorAction Stop
    Write-Host "Elevated certificate removal was launched."
    exit 0
}

$stores = @("Cert:\CurrentUser\My")
if (Test-IsAdministrator) {
    $stores += @(
        "Cert:\LocalMachine\My",
        "Cert:\LocalMachine\Root",
        "Cert:\LocalMachine\TrustedPublisher"
    )
}

$removed = 0
foreach ($store in $stores) {
    $matches = Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
        Where-Object {
            if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
                $_.Thumbprint -eq $Thumbprint
            }
            else {
                $_.Subject -eq $Subject
            }
        }

    foreach ($certificate in $matches) {
        $target = Join-Path $store $certificate.Thumbprint
        if ($PSCmdlet.ShouldProcess($target, "Remove Studio Display local signing certificate")) {
            Remove-Item -LiteralPath $target -Force
            $removed++
            Write-Host "Removed certificate $($certificate.Thumbprint) from $store"
        }
    }
}

if ($removed -eq 0) {
    Write-Host "No matching Studio Display local signing certificate was found."
}
