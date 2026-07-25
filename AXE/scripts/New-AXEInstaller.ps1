#Requires -Version 5.1
<#
.SYNOPSIS
  Instalador ligero de AXE (subproyecto B, spec 2026-07-24).

.DESCRIPTION
  Copia el arbol a %LOCALAPPDATA%\AXE y crea un acceso directo en el Menu Inicio. Nada mas.

  LO QUE NO HACE, Y POR QUE (spec §2, no-goals):
    - NO es un MSIX/Inno/WiX. AXE es una carpeta con un launcher: un instalador pesado anadiria
      un desinstalador que puede borrar cosas del usuario y una entrada de registro que
      mantener, a cambio de cero funcionalidad.
    - NO escribe en HKLM ni en Program Files, asi que NO pide admin. AXE se eleva cuando lo
      necesita, desde AXE.bat, y solo entonces.
    - NO crea una tarea programada de auto-update. El updater es explicito (`AXE -Update`)
      porque un proceso de fondo que descarga y reemplaza codigo que luego corre elevado es
      justo lo que este subproyecto existe para no ser.
    - NO descarga nada. Instala lo que ya tienes al lado.

  VERIFICA ANTES DE INSTALAR (con -Verify lo hace el script; si no, hazlo tu):
    (Get-FileHash .\AXE.ps1 -Algorithm SHA256).Hash.ToLower()   # comparalo con SHA256SUMS
    Get-AuthenticodeSignature .\AXE.ps1 | Format-List Status

.PARAMETER Source
  Carpeta con los ficheros de AXE. Default: la carpeta padre de este script.

.PARAMETER Destination
  Destino. Default: %LOCALAPPDATA%\AXE.

.PARAMETER Verify
  Comprueba el SHA256SUMS del origen antes de copiar nada, y aborta si no cuadra.

.PARAMETER NoShortcut
  No crear el acceso directo del Menu Inicio.

.EXAMPLE
  ./scripts/New-AXEInstaller.ps1 -Verify
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Source,
    [string]$Destination,
    [switch]$Verify,
    [switch]$NoShortcut
)
$ErrorActionPreference = 'Stop'

if(-not $Source){ $Source = Split-Path -Parent $PSScriptRoot }
$Source = (Resolve-Path -LiteralPath $Source).Path
if(-not $Destination){ $Destination = Join-Path $env:LOCALAPPDATA 'AXE' }

$engine = Join-Path $Source 'AXE.ps1'
if(-not (Test-Path $engine)){ $engine = Join-Path $Source 'dist\AXE.ps1' }
if(-not (Test-Path $engine)){ throw "No encuentro AXE.ps1 en '$Source'. Pasa -Source apuntando al zip extraido." }

Write-Host '== Instalador AXE ==' -ForegroundColor Cyan
Write-Host "  Origen  : $Source"
Write-Host "  Destino : $Destination"

# --- verificacion opcional del origen ------------------------------------------------------
if($Verify){
    . (Join-Path $PSScriptRoot '..\src\43-update.ps1')
    if(-not (Test-Path (Join-Path $Source 'SHA256SUMS'))){ throw "-Verify pedido pero no hay SHA256SUMS en '$Source'." }
    $bad = @(Test-AXEChecksums -Dir $Source)
    if($bad.Count){ throw ("Verificacion FALLIDA, no se instala nada: {0}" -f ($bad -join '; ')) }
    Write-Host '  Checksums: OK' -ForegroundColor Green
    $sig = Get-AXESignatureInfo $engine
    if($sig.Valid){ Write-Host "  Firma    : OK ($($sig.Signer))" -ForegroundColor Green }
    else          { Write-Warning "  Firma    : $($sig.Status). El paquete NO esta firmado o la firma no es valida." }
}

# --- copia ---------------------------------------------------------------------------------
# Se copia el CONTENIDO, no la carpeta, y se conserva lo que el usuario ya tuviera dentro de
# %LOCALAPPDATA%\AXE\AXE\ (logs, tweak_state.json, baselines del benchmark): ese subarbol es
# estado de runtime, y borrarlo al actualizar destruiria los snapshots de revert del usuario,
# o sea justo lo que hace que AXE sea reversible.
if($PSCmdlet.ShouldProcess($Destination,'Instalar AXE')){
    if(-not (Test-Path $Destination)){ New-Item -ItemType Directory -Path $Destination -Force | Out-Null }
    $copied = 0
    foreach($item in (Get-ChildItem -LiteralPath $Source -Force)){
        if($item.PSIsContainer -and $item.Name -in 'AXE','Backups','dist','.git'){ continue }   # runtime / build
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
        $copied++
    }
    # Si el origen era el repo (no el zip), el motor vive en dist/: se sube a la raiz del destino.
    if(-not (Test-Path (Join-Path $Destination 'AXE.ps1'))){
        Copy-Item -LiteralPath $engine -Destination (Join-Path $Destination 'AXE.ps1') -Force
    }
    Write-Host "  Copiados : $copied elementos"
}

# --- acceso directo ------------------------------------------------------------------------
# Apunta al .bat, que es quien se auto-eleva. Un .lnk marcado 'RunAs' contra powershell.exe
# pediria UAC incluso para `-List`, que no necesita admin.
$bat = Join-Path $Destination 'AXE.bat'
if(-not $NoShortcut -and (Test-Path $bat)){
    $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\AXE.lnk'
    if($PSCmdlet.ShouldProcess($sm,'Crear acceso directo')){
        try {
            $ws  = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($sm)
            $lnk.TargetPath       = $bat
            $lnk.WorkingDirectory = $Destination
            $lnk.Description      = 'AXE - Windows tuning auditable'
            $ico = Join-Path $Destination 'logo\axe.ico'
            if(Test-Path $ico){ $lnk.IconLocation = $ico }
            $lnk.Save()
            Write-Host "  Acceso   : $sm"
        } catch { Write-Warning "No pude crear el acceso directo: $($_.Exception.Message)" }
    }
}

Write-Host ''
Write-Host 'Instalado.' -ForegroundColor Green
Write-Host "  Abrir        :  `"$bat`""
Write-Host "  Estado real  :  `"$bat`" -List"
Write-Host "  Actualizar   :  `"$bat`" -Update -Check"
Write-Host ''
Write-Host 'Desinstalar = borrar la carpeta y el acceso directo. No se ha tocado el registro.'
