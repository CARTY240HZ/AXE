#Requires -Version 5.1
<#
.SYNOPSIS
  Genera los 3 manifiestos winget de un release ya construido (subproyecto B, spec 2026-07-24).

.DESCRIPTION
  POR QUE SE GENERAN Y NO SE MANTIENEN A MANO: de los ~40 campos de un manifiesto winget, tres
  cambian en CADA release (version, URL del asset y SHA256 del zip) y uno de ellos es un hash
  de 64 caracteres. Mantenerlos a mano garantiza que tarde o temprano se publique un manifiesto
  con el hash de la version anterior: winget rechaza la instalacion y el usuario ve "el paquete
  esta corrupto" cuando lo que hay es un error de copiar y pegar. Aqui el hash se lee del zip
  real que se va a publicar.

  Escribe en dist/release/winget/<version>/ los 3 ficheros que pide microsoft/winget-pkgs:
    CARTY240HZ.AXE.yaml                 manifiesto de version
    CARTY240HZ.AXE.installer.yaml       instalador (zip con portable anidado)
    CARTY240HZ.AXE.locale.en-US.yaml    metadatos en ingles (locale por defecto)

  NO abre la PR a microsoft/winget-pkgs: eso lo hace una persona, a mano, tras revisar. Un
  script que publica solo en el repo de paquetes de Microsoft es exactamente el tipo de
  automatismo que no debe existir sin revision humana. El procedimiento esta en
  packaging/winget/README.md.

.PARAMETER Tag
  Tag del release (con o sin 'v'). Default: la version del fichero VERSION.

.PARAMETER ReleaseDir
  Directorio con los artefactos. Default: dist/release.

.EXAMPLE
  ./scripts/New-AXEWingetManifest.ps1 -Tag v7.0.0
#>
[CmdletBinding()]
param(
    [string]$Tag,
    [string]$ReleaseDir
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $repo 'src\43-update.ps1')

if(-not $ReleaseDir){ $ReleaseDir = Join-Path $repo 'dist\release' }
if(-not $Tag){ $Tag = (Get-Content (Join-Path $repo 'VERSION') -Raw).Trim() }
$ver = $Tag -replace '^[vV]',''
if(-not (ConvertTo-AXEVersionParts $ver)){ throw "Tag no parseable como version: '$Tag'" }

$zip = Join-Path $ReleaseDir ("AXE-{0}.zip" -f $ver)
if(-not (Test-Path $zip)){ throw "No existe el paquete '$zip'. Corre scripts/New-AXERelease.ps1 antes." }
# El hash sale del zip REAL que se va a publicar, no de una variable que alguien actualiza.
$sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
$url = "https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v$ver/AXE-$ver.zip"

$out = Join-Path $ReleaseDir "winget\$ver"
if(Test-Path $out){ Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null
$id  = 'CARTY240HZ.AXE'
$enc = New-Object System.Text.UTF8Encoding $false
function Write-Manifest {
    param([string]$Name,[string]$Body)
    [IO.File]::WriteAllText((Join-Path $out $Name), ($Body -replace "`r`n","`n"), $enc)
}

Write-Manifest "$id.yaml" @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.6.0.schema.json
PackageIdentifier: $id
PackageVersion: $ver
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.6.0
"@

# InstallerType zip + NestedInstallerType portable: AXE no tiene instalador, es una carpeta con
# un launcher. 'portable' hace que winget cree un alias en el PATH sin escribir en el registro
# ni dejar un desinstalador que borre cosas del usuario.
#   ArchiveBinariesDependOnPath: el .bat resuelve powershell.exe por PATH, y ademas el motor
# resuelve webui/ y webview2/ RELATIVOS a su propia carpeta (39-webdetect), asi que winget no
# debe reubicar el ejecutable fuera del arbol extraido.
Write-Manifest "$id.installer.yaml" @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.6.0.schema.json
PackageIdentifier: $id
PackageVersion: $ver
MinimumOSVersion: 10.0.19041.0
InstallerType: zip
NestedInstallerType: portable
NestedInstallerFiles:
  - RelativeFilePath: AXE.bat
    PortableCommandAlias: axe
ArchiveBinariesDependOnPath: true
UpgradeBehavior: install
ReleaseDate: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd'))
Installers:
  - Architecture: x64
    InstallerUrl: $url
    InstallerSha256: $sha
ManifestType: installer
ManifestVersion: 1.6.0
"@

# La descripcion dice lo que AXE hace Y lo que NO hace. Quien instala desde winget no ha leido
# el README: si la unica linea que ve promete "mas FPS", el producto empieza mintiendo.
Write-Manifest "$id.locale.en-US.yaml" @"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.6.0.schema.json
PackageIdentifier: $id
PackageVersion: $ver
PackageLocale: en-US
Publisher: CARTY240HZ
PublisherUrl: https://github.com/$($script:AXEUpdateOwner)
PublisherSupportUrl: https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/issues
PackageName: AXE
PackageUrl: https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)
License: MIT
LicenseUrl: https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/blob/axe/LICENSE
ShortDescription: Auditable Windows tuning tool with per-tweak snapshot revert and measured before/after verdicts.
Description: |-
  AXE applies Windows tweaks and measures whether they actually did anything on your machine.

  Every tweak records the previous registry value before changing it, so revert restores your
  original state rather than a guessed default. Tweaks are gated on your hardware, cite an
  official or community-measured source, and are flagged when the community consensus behind
  them is likely placebo - those are opt-in and excluded from the one-click path.

  The built-in benchmark reports the delta with its noise interval. When a change does not
  clear that interval the verdict is "noise", not "improvement".

  What it does not do: it does not modify the Windows image, disable Defender or SmartScreen,
  install a kernel driver, phone home, or promise FPS numbers it has not measured on your PC.
Tags:
  - windows
  - optimization
  - latency
  - benchmark
  - gaming
ReleaseNotesUrl: https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/tag/v$ver
ManifestType: defaultLocale
ManifestVersion: 1.6.0
"@

Write-Host "Manifiestos winget $ver generados en: $out"
Write-Host "  zip    : $(Split-Path $zip -Leaf)"
Write-Host "  sha256 : $sha"
Write-Host ''
Write-Host 'Siguiente paso (a mano, ver packaging/winget/README.md):'
Write-Host "  winget validate --manifest `"$out`""
Get-ChildItem $out -File | ForEach-Object { Write-Host "  - $($_.Name)" }
