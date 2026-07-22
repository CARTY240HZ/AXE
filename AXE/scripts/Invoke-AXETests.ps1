#Requires -Version 5.1
<#
.SYNOPSIS
  Runner unico de la suite Pester de AXE (+ lint opcional PSScriptAnalyzer).
.DESCRIPTION
  Fuente unica de verdad para "correr los tests". Lo usan por igual:
    - el desarrollador en local   (.\scripts\Invoke-AXETests.ps1)
    - el gate de build            (build.ps1 lo invoca antes del SelfTest)
    - CI                          (.github/workflows/ci.yml, con -Lint -CI)
  Devuelve exit code != 0 si hay un solo test rojo o (con -Lint) un diagnostico
  de severidad Error del analizador. Asi el rojo REALMENTE bloquea, en vez de
  quedarse en 9 ficheros .Tests.ps1 que nadie ejecutaba (auditoria 2026-07-22).
.PARAMETER Path
  Carpeta o fichero de tests. Default: <repo>/tests.
.PARAMETER Lint
  Ademas de Pester, corre PSScriptAnalyzer sobre src/, tests/, build.ps1 y scripts/.
  Si el modulo no esta instalado: WARN y se salta (no rompe el local). En CI se instala.
.PARAMETER CI
  Modo CI: emite resultados NUnit a artefactos y guarda el detalle de errores.
.PARAMETER ResultsPath
  Carpeta de artefactos (default: <repo>/dist/test-results).
#>
[CmdletBinding()]
param(
    [string]$Path,
    [switch]$Lint,
    [switch]$CI,
    [switch]$IncludeIntegration,
    [string]$ResultsPath
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if(-not $Path){ $Path = Join-Path $repo 'tests' }
if(-not $ResultsPath){ $ResultsPath = Join-Path $repo 'dist\test-results' }
if(-not (Test-Path $ResultsPath)){ New-Item -ItemType Directory -Path $ResultsPath -Force | Out-Null }

# --- Pester >= 5 obligatorio (New-PesterConfiguration). La suite usa -ForEach/Set-ItResult. ---
$pester = Get-Module Pester -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
if(-not $pester -or $pester.Version.Major -lt 5){
    Write-Host 'ERROR: se requiere Pester >= 5. Instala:  Install-Module Pester -MinimumVersion 5.5.0 -Force -Scope CurrentUser' -ForegroundColor Red
    exit 3
}
Import-Module Pester -MinimumVersion 5.0.0 -Force
Write-Host ("== AXE test runner ==  Pester {0}  |  PS {1}" -f $pester.Version, $PSVersionTable.PSVersion) -ForegroundColor Cyan

# El motor no debe crear puntos de restauracion reales ni arrancar CLI/GUI durante el test.
$env:AXE_NOSR = '1'

$cfg = New-PesterConfiguration
$cfg.Run.Path        = $Path
$cfg.Run.PassThru    = $true
# Los tests -Tag 'integration' mutan/leen Windows real y corren en su JOB dedicado de CI
# (AXE_INTEGRATION=1). El gate local/build ejecuta solo los unit: portable y sin depender del
# estado de esta maquina. -IncludeIntegration los reincluye si hace falta a mano.
if(-not $IncludeIntegration){ $cfg.Filter.ExcludeTag = 'integration' }
$cfg.Output.Verbosity = if($CI){ 'Detailed' } else { 'Normal' }
if($CI){
    $cfg.TestResult.Enabled      = $true
    $cfg.TestResult.OutputFormat = 'NUnitXml'
    $cfg.TestResult.OutputPath   = Join-Path $ResultsPath 'pester.xml'
}

$result = Invoke-Pester -Configuration $cfg

Write-Host ''
Write-Host ('RESULTADO Pester => Passed={0}  Failed={1}  Skipped={2}  Total={3}  ({4:n1}s)' -f `
    $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.TotalCount, $result.Duration.TotalSeconds) `
    -ForegroundColor $(if($result.FailedCount -gt 0){'Red'}else{'Green'})

$exit = if($result.FailedCount -gt 0){ 1 } else { 0 }

# --- Lint opcional (no rompe en local si falta; en CI se instala el modulo) ---
if($Lint){
    $psa = Get-Module PSScriptAnalyzer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if(-not $psa){
        Write-Host 'WARN: PSScriptAnalyzer no instalado -> lint omitido. (Install-Module PSScriptAnalyzer -Scope CurrentUser)' -ForegroundColor Yellow
    } else {
        Import-Module PSScriptAnalyzer -Force
        $targets = @('src','tests','scripts','build.ps1') | ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path $_ }
        $settings = Join-Path $repo 'PSScriptAnalyzerSettings.psd1'
        $paParams = @{ Path = $targets; Recurse = $true }
        if(Test-Path $settings){ $paParams.Settings = $settings }
        $diag = Invoke-ScriptAnalyzer @paParams
        $errs  = @($diag | Where-Object Severity -eq 'Error')
        $warns = @($diag | Where-Object Severity -eq 'Warning')
        Write-Host ('LINT => Errors={0}  Warnings={1}' -f $errs.Count, $warns.Count) -ForegroundColor $(if($errs.Count){'Red'}else{'Green'})
        if($CI -and $diag){ $diag | Export-Clixml (Join-Path $ResultsPath 'psa.xml') }
        $diag | Where-Object Severity -in 'Error','Warning' | Select-Object -First 40 |
            ForEach-Object { Write-Host ("  [{0}] {1}:{2} {3} - {4}" -f $_.Severity, (Split-Path $_.ScriptName -Leaf), $_.Line, $_.RuleName, $_.Message) }
        if($errs.Count -gt 0){ $exit = 2 }   # solo Error bloquea; Warning informa
    }
}

exit $exit
