#Requires -Version 5.1
[CmdletBinding()]
param([switch]$NoTest,[string]$Sign)
$ErrorActionPreference='Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $root 'src'
$dist = Join-Path $root 'dist'
if(-not(Test-Path $dist)){ New-Item -ItemType Directory -Path $dist | Out-Null }
$out  = Join-Path $dist 'AXE.ps1'
$modules = Get-ChildItem -Path $src -Filter '*.ps1' | Sort-Object Name
if($modules.Count -eq 0){ throw 'No hay modulos en /src' }
$ver = (Get-Content (Join-Path $root 'VERSION') -Raw -EA SilentlyContinue); if($ver){ $ver=$ver.Trim() } else { $ver='6.0.0-dev' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# ================================================================")
[void]$sb.AppendLine("# AXE $ver - BUILT from /src by build.ps1 - DO NOT EDIT DIRECTLY")
[void]$sb.AppendLine("# Build UTC: $((Get-Date).ToUniversalTime().ToString('u'))")
[void]$sb.AppendLine("# Modules: $($modules.Name -join ', ')")
[void]$sb.AppendLine("# ================================================================")
foreach($m in $modules){
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# >>>>> MODULE: $($m.Name) >>>>>")
    [void]$sb.Append((Get-Content $m.FullName -Raw))
    [void]$sb.AppendLine("")
}
Set-Content -Path $out -Value $sb.ToString() -Encoding UTF8
Write-Host ("BUILT: {0} ({1} lineas, {2} modulos)" -f $out,(Get-Content $out).Count,$modules.Count)
foreach($m in $modules){ Write-Host ("  {0,-28} {1,5} lineas" -f $m.Name,(Get-Content $m.FullName).Count) }
if($Sign){ Set-AuthenticodeSignature -FilePath $out -Certificate (Get-Item "Cert:\CurrentUser\My\$Sign") | Out-Null; Write-Host "Firmado ($Sign)" }
if($NoTest){ return }
Write-Host "`n=== TEST GATE ==="
$env:AXE_NOSR='1'   # no crear puntos de restauracion reales en el gate
$st = & pwsh -NoProfile -File $out -SelfTest 2>&1
$stExit = $LASTEXITCODE
$stStr = ($st | Out-String)
$stStr -split "`r?`n" | Select-String 'Catalogo|Checks|Fallos|RESULTADO' | ForEach-Object { Write-Host "  $_" }
if($stExit -ne 0 -or ($stStr -notmatch 'Fallos\s*:\s*0')){ throw "SelfTest FALLO (exit $stExit)" }
$env:AXE_GUITEST='1'; $env:AXE_GUITEST_PNG_DIR=$dist
$gt = & powershell.exe -NoProfile -STA -File $out 2>&1
$gtExit = $LASTEXITCODE
Remove-Item Env:\AXE_GUITEST -EA SilentlyContinue
$gtStr = ($gt | Out-String)
if($gtExit -ne 0 -or ($gtStr -notmatch 'LAYOUT OK')){ $gtStr -split "`r?`n" | Select-String 'FALLO|EXCEP' | ForEach-Object { Write-Host "  $_" }; throw "GUI harness FALLO (exit $gtExit)" }
Write-Host 'GATE OK: SelfTest + GUI harness verdes.'
