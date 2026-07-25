#Requires -Version 5.1
<#
.SYNOPSIS
  Construye los artefactos publicables de un release de AXE (subproyectos A+B, spec 2026-07-24).

.DESCRIPTION
  Fuente unica de "que se publica". Lo usan por igual el owner en local y
  .github/workflows/release.yml, para que un release hecho a mano y uno hecho por CI salgan
  identicos byte a byte (salvo la firma y el timestamp del SBOM).

  Produce en dist/release/:
    AXE.ps1          motor concatenado (lo que descarga el updater)
    AXE-<ver>.zip    paquete portable (motor + launcher + webui + webview2 + docs) -> winget
    SHA256SUMS       formato coreutils, verificable con `sha256sum -c`
    sbom.json        CycloneDX 1.5 de los componentes de terceros vendorizados

  DEGRADA HONESTO SIN CERTIFICADO: si no hay -Thumbprint/-PfxPath, el AXE.ps1 sale SIN firmar
  y el script lo dice claramente en el resumen. No se finge una firma que no existe, y el
  updater del lado del usuario se negara a auto-instalar ese release (por diseno, ver 43-update).
  Comprar un cert es una decision de dinero del owner, no un requisito del pipeline.

.PARAMETER Thumbprint
  Huella de un cert de firma de codigo del store local (uso en local).

.PARAMETER PfxPath / .PARAMETER PfxPassword
  Alternativa para CI: PFX desde un secret. NUNCA commitear el .pfx (ya esta en .gitignore).

.PARAMETER SkipBuild
  Reusa el dist/AXE.ps1 existente en vez de reconstruirlo (para encadenar tras build.ps1).

.EXAMPLE
  ./scripts/New-AXERelease.ps1
.EXAMPLE
  ./scripts/New-AXERelease.ps1 -Thumbprint ABC123...
#>
[CmdletBinding()]
param(
    [string]$Thumbprint,
    [string]$PfxPath,
    [System.Security.SecureString]$PfxPassword,
    [string]$TimeStampServer = 'http://timestamp.digicert.com',
    [switch]$SkipBuild,
    [switch]$AllowSelfSigned
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

# El modulo del motor se dot-sourcea SUELTO: 43-update no depende de 05-core justamente para
# que este script no tenga que cargar (ni ejecutar) el motor entero.
. (Join-Path $repo 'src\43-update.ps1')

$ver = (Get-Content (Join-Path $repo 'VERSION') -Raw).Trim()
if(-not (ConvertTo-AXEVersionParts $ver)){ throw "VERSION no es una version valida: '$ver'" }
Write-Host "== AXE release $ver ==" -ForegroundColor Cyan

# --- 1. build ------------------------------------------------------------------------------
$distPs = Join-Path $repo 'dist\AXE.ps1'
if(-not $SkipBuild){
    & (Join-Path $repo 'build.ps1') -NoTest | Out-Null
}
if(-not (Test-Path $distPs)){ throw "No existe $distPs (corre build.ps1 primero o quita -SkipBuild)" }

# --- 2. staging ----------------------------------------------------------------------------
# Directorio LIMPIO cada vez: un release no puede arrastrar el asset de la version anterior,
# porque entonces el SHA256SUMS listaria un fichero que nadie reviso en este ciclo.
$rel = Join-Path $repo 'dist\release'
if(Test-Path $rel){ Remove-Item $rel -Recurse -Force }
New-Item -ItemType Directory -Path $rel -Force | Out-Null
Copy-Item $distPs (Join-Path $rel 'AXE.ps1') -Force

# --- 3. firma (opcional, degrada honesto) --------------------------------------------------
$signed = $false; $signNote = 'SIN FIRMAR'
if($Thumbprint -or $PfxPath){
    $sign = @{ Path = (Join-Path $rel 'AXE.ps1'); TimeStampServer = $TimeStampServer }
    if($AllowSelfSigned){ $sign.AllowSelfSigned = $true }
    if($PfxPath){ $sign.PfxPath = $PfxPath; if($PfxPassword){ $sign.PfxPassword = $PfxPassword } }
    else        { $sign.Thumbprint = $Thumbprint }
    try {
        & (Join-Path $PSScriptRoot 'Sign-AXE.ps1') @sign | Out-Null
        $info = Get-AXESignatureInfo (Join-Path $rel 'AXE.ps1')
        $signed = $info.Valid
        $signNote = if($info.Valid){ "FIRMADO por $($info.Signer)$(if(-not $info.TimeStamped){' (SIN timestamp!)'})" }
                    else           { "FIRMA INVALIDA ($($info.Status))" }
    } catch {
        # Un timestamp server caido no debe abortar un release entero (spec §6), pero tampoco
        # se publica en silencio como si estuviera firmado.
        Write-Warning "Firma fallida: $($_.Exception.Message)"
        $signNote = "FIRMA FALLIDA: $($_.Exception.Message)"
    }
} else {
    Write-Warning 'Sin -Thumbprint/-PfxPath: el release sale SIN FIRMAR. El updater se negara a auto-instalarlo (por diseno).'
}

# --- 4. paquete portable (lo que consume winget) -------------------------------------------
# El updater baja AXE.ps1 suelto; winget necesita UN artefacto instalable. El zip lleva ademas
# webui/ y webview2/, que el motor necesita en runtime (39-webdetect los resuelve junto al script).
$pkg = Join-Path $repo 'dist\_pkg'
if(Test-Path $pkg){ Remove-Item $pkg -Recurse -Force }
New-Item -ItemType Directory -Path $pkg -Force | Out-Null
Copy-Item (Join-Path $rel 'AXE.ps1') $pkg -Force          # el firmado, no el de dist/
foreach($item in 'AXE.bat','README.md','LICENSE','CHANGELOG.md','VERSION'){
    $p = Join-Path $repo $item
    if(Test-Path $p){ Copy-Item $p $pkg -Force }
}
foreach($dir in 'webui','webview2'){
    $p = Join-Path $repo $dir
    if(Test-Path $p){ Copy-Item $p (Join-Path $pkg $dir) -Recurse -Force }
}
$zip = Join-Path $rel ("AXE-{0}.zip" -f $ver)
Compress-Archive -Path (Join-Path $pkg '*') -DestinationPath $zip -Force
Remove-Item $pkg -Recurse -Force

# --- 5. SBOM + checksums -------------------------------------------------------------------
# El SBOM va DENTRO del directorio de release para que el propio SHA256SUMS lo cubra: un SBOM
# que no esta en el manifiesto de integridad se puede sustituir sin que nadie lo note.
[void](New-AXESbom -Root $repo -Version $ver -OutFile (Join-Path $rel 'sbom.json'))
$sums = New-AXEChecksums -Dir $rel

# --- 6. verificacion del propio release ----------------------------------------------------
# Se verifica lo que se acaba de generar ANTES de publicarlo. Si el manifiesto no cuadra con
# sus propios ficheros, el fallo se ve aqui y no en la maquina del primer usuario.
$bad = @(Test-AXEChecksums -Dir $rel)
if($bad.Count){ throw ("El SHA256SUMS recien generado no verifica: {0}" -f ($bad -join '; ')) }

Write-Host ''
Write-Host '--- artefactos ---' -ForegroundColor Cyan
Get-ChildItem $rel -File | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-24} {1,10:n0} bytes" -f $_.Name, $_.Length)
}
Write-Host ''
Write-Host ("  Version : {0}" -f $ver)
Write-Host ("  Firma   : {0}" -f $signNote) -ForegroundColor $(if($signed){'Green'}else{'Yellow'})
Write-Host ("  Salida  : {0}" -f $rel)
if(-not $signed){
    Write-Host ''
    Write-Host '  NOTA: sin firma valida, "AXE -Update" NO auto-instalara este release.' -ForegroundColor Yellow
    Write-Host '  Los usuarios pueden verificar la integridad con SHA256SUMS e instalar a mano.' -ForegroundColor Yellow
}

[pscustomobject]@{ Version=$ver; Dir=$rel; Signed=$signed; Sums=$sums; Zip=$zip }
