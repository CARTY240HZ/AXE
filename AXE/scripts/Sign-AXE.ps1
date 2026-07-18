<#
.SYNOPSIS
    Firma Authenticode del artefacto propio de AXE (dist/AXE.ps1) con timestamp + SHA256.

.DESCRIPTION
    Firma UNICAMENTE codigo propio (dist/AXE.ps1). NO firma binarios de terceros
    (winutil.exe, ISLC, Autoruns, OpenHardwareMonitor, DnsJumper): no los escribimos,
    viola su redistribucion y rompe su firma original (§8.3).

    Acepta un cert del store por -Thumbprint, o un .pfx por -PfxPath/-PfxPassword.
    El timestamping es obligatorio (la firma sobrevive a la expiracion del cert).
    Emite el SHA256 del archivo firmado para el changelog/release.

.PARAMETER Path
    Ruta al script a firmar. Default: dist/AXE.ps1 relativo a este script.

.PARAMETER Thumbprint
    Huella del certificado de firma de codigo en Cert:\CurrentUser\My o LocalMachine\My.

.PARAMETER PfxPath
    Alternativa: ruta a un .pfx de firma de codigo.

.PARAMETER PfxPassword
    Password del .pfx (SecureString).

.PARAMETER TimeStampServer
    Servidor RFC3161. Default: DigiCert.

.PARAMETER AllowSelfSigned
    Permite un cert self-signed (SOLO desarrollo; produccion exige OV/EV o Azure Trusted Signing).

.EXAMPLE
    ./Sign-AXE.ps1 -Thumbprint ABC123...

.EXAMPLE
    ./Sign-AXE.ps1 -PfxPath .\axe-cs.pfx -PfxPassword (Read-Host -AsSecureString)
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Store')]
param(
    [string]$Path,

    [Parameter(ParameterSetName = 'Store', Mandatory)]
    [string]$Thumbprint,

    [Parameter(ParameterSetName = 'Pfx', Mandatory)]
    [string]$PfxPath,

    [Parameter(ParameterSetName = 'Pfx')]
    [System.Security.SecureString]$PfxPassword,

    [string]$TimeStampServer = 'http://timestamp.digicert.com',

    [switch]$AllowSelfSigned
)

$ErrorActionPreference = 'Stop'

# --- resolver artefacto propio ---
if (-not $Path) { $Path = Join-Path $PSScriptRoot '..\dist\AXE.ps1' }
$Path = (Resolve-Path -LiteralPath $Path).Path

$leaf = Split-Path $Path -Leaf
if ($leaf -ne 'AXE.ps1') {
    throw "Sign-AXE solo firma codigo propio (dist/AXE.ps1). '$leaf' rechazado: no se firman binarios/artefactos de terceros (§8.3)."
}
if ($Path -match '\.(exe|dll|sys|msi)$') {
    throw "Rechazado: '$Path' es un binario. Sign-AXE no firma binarios de terceros."
}

# --- cargar certificado ---
$cert = if ($PSCmdlet.ParameterSetName -eq 'Pfx') {
    if (-not (Test-Path $PfxPath)) { throw "PFX no encontrado: $PfxPath" }
    [System.Security.Cryptography.X509Certificates.X509Certificate2]::new((Resolve-Path $PfxPath).Path, $PfxPassword)
} else {
    $c = Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -CodeSigningCert -ErrorAction SilentlyContinue |
         Where-Object Thumbprint -eq $Thumbprint | Select-Object -First 1
    if (-not $c) { throw "Cert de firma de codigo con thumbprint '$Thumbprint' no encontrado en el store." }
    $c
}

# --- guardas de seguridad ---
$isSelfSigned = $cert.Subject -eq $cert.Issuer
if ($isSelfSigned -and -not $AllowSelfSigned) {
    throw "Cert self-signed: solo para desarrollo. Produccion exige OV/EV o Azure Trusted Signing. Usa -AllowSelfSigned para dev."
}
$daysLeft = ($cert.NotAfter - (Get-Date)).Days
if ($daysLeft -lt 0) { throw "Cert expirado ($($cert.NotAfter))." }
if ($daysLeft -lt 30) { Write-Warning "Cert expira en $daysLeft dias ($($cert.NotAfter))." }

# --- firmar ---
if ($PSCmdlet.ShouldProcess($Path, "Set-AuthenticodeSignature (timestamp $TimeStampServer)")) {
    $sig = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert `
        -HashAlgorithm SHA256 -TimestampServer $TimeStampServer -Force
    if ($sig.Status -ne 'Valid') {
        throw "Firma fallida: $($sig.Status) - $($sig.StatusMessage)"
    }
    $sha = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    [pscustomobject]@{
        File        = $Path
        Status      = $sig.Status
        SignerCert  = $sig.SignerCertificate.Subject
        TimeStamped = [bool]$sig.TimeStamperCertificate
        SHA256      = $sha
    } | Format-List
    Write-Host "OK: $leaf firmado y timestamped. Incluye el SHA256 en el release/changelog."
}
