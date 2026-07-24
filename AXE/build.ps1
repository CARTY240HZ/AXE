#Requires -Version 5.1
[CmdletBinding()]
param([switch]$NoTest,[string]$Sign,[switch]$CI)
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
    [void]$sb.Append((Get-Content $m.FullName -Raw -Encoding UTF8))
    [void]$sb.AppendLine("")
}
# Version canonica: SOLO se sustituye la linea de ASIGNACION de 00-header, NO el guard de
# fallback. Ambos van DESPUES del param block (regla PS: param() primero). Fuente unica = VERSION.
#   Un -replace global del token pisaba tambien el '*__AXE_VERSION__*' del guard de 00-header: tras
# el build quedaba como '*7.0.0*', hacia MATCH contra la propia version y la app se AUTO-DEGRADABA
# a '6.1.0-dev' en cada build (banner CLI y app.info del puente mentian). .Replace() literal toca
# solo la asignacion; el guard conserva su token intacto => no dispara cuando SI hubo build.
$built = $sb.ToString().Replace("`$script:AXEVersion = '__AXE_VERSION__'", "`$script:AXEVersion = '$ver'")
Set-Content -Path $out -Value $built -Encoding UTF8
Write-Host ("BUILT: {0} ({1} lineas, {2} modulos)" -f $out,(Get-Content $out).Count,$modules.Count)
foreach($m in $modules){ Write-Host ("  {0,-28} {1,5} lineas" -f $m.Name,(Get-Content $m.FullName).Count) }
if($Sign){ Set-AuthenticodeSignature -FilePath $out -Certificate (Get-Item "Cert:\CurrentUser\My\$Sign") | Out-Null; Write-Host "Firmado ($Sign)" }
if($NoTest){ return }
Write-Host "`n=== TEST GATE ==="
$env:AXE_NOSR='1'   # no crear puntos de restauracion reales en el gate

# --- Suite Pester (fuente unica: scripts/Invoke-AXETests.ps1) ---
# Hasta 2026-07-22 los 9 ficheros tests/*.Tests.ps1 NO los ejecutaba nadie: el gate solo
# corria -SelfTest. Cobertura ficticia. Ahora el gate corre la suite ANTES del SelfTest:
# un solo It rojo aborta el build. Se salta con -NoTest para iterar rapido en local.
$runner = Join-Path $root 'scripts\Invoke-AXETests.ps1'
if(Test-Path $runner){
    Write-Host "`n--- Pester ---"
    # En CI: ademas lint (PSScriptAnalyzer) + resultados NUnit para artefactos.
    if($CI){ & pwsh -NoProfile -File $runner -Lint -CI } else { & pwsh -NoProfile -File $runner }
    if($LASTEXITCODE -ne 0){ throw "Suite Pester FALLO (exit $LASTEXITCODE)" }
} else {
    Write-Warning "Runner de tests ausente ($runner): se salta Pester en el gate."
}

Write-Host "`n--- SelfTest (integridad del catalogo) ---"
$st = & pwsh -NoProfile -File $out -SelfTest 2>&1
$stExit = $LASTEXITCODE
$stStr = ($st | Out-String)
$stStr -split "`r?`n" | Select-String 'Catalogo|Checks|Fallos|RESULTADO' | ForEach-Object { Write-Host "  $_" }
if($stExit -ne 0 -or ($stStr -notmatch 'Fallos\s*:\s*0')){ throw "SelfTest FALLO (exit $stExit)" }
# Cutover (Fase 8): la GUI WPF vieja se retiro. El harness ahora ejercita el HOST WEB:
# AXE_WEBUI_TEST=1 hace que Show-AXEWebHost (47) construya carcasa+control, verifique init, imprima
# 'WEBHOST OK' y vuelva sin ShowDialog bloqueante. Si falta el runtime WebView2 en CI, imprime
# 'WEBHOST OK (sin runtime, ...)' -> el -match 'WEBHOST OK' lo acepta (valida que la carcasa degrada limpio).
$env:AXE_GUITEST='1'; $env:AXE_WEBUI_TEST='1'; $env:AXE_GUITEST_PNG_DIR=$dist
$gt = & powershell.exe -NoProfile -STA -File $out 2>&1
$gtExit = $LASTEXITCODE
Remove-Item Env:\AXE_GUITEST -EA SilentlyContinue; Remove-Item Env:\AXE_WEBUI_TEST -EA SilentlyContinue
$gtStr = ($gt | Out-String)
if($gtExit -ne 0 -or ($gtStr -notmatch 'WEBHOST OK')){ $gtStr -split "`r?`n" | Select-String 'FALLO|EXCEP' | ForEach-Object { Write-Host "  $_" }; throw "Web host harness FALLO (exit $gtExit)" }
Write-Host 'GATE OK: SelfTest + Web host harness verdes.'
