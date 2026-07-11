# =====================================================
# LW Suite v6 - Registry + Service helpers
# Direct port from v4 (LWSuite_v4.ps1:84-100). Canonical registry/service primitives.
# =====================================================
function Get-RV($p,$n){ try { (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n } catch { $null } }
function Set-RD($p,$n,$v){ if(-not(Test-Path $p)){ New-Item -Path $p -Force | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType DWord -Force | Out-Null }
function Set-RS($p,$n,$v){ if(-not(Test-Path $p)){ New-Item -Path $p -Force | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType String -Force | Out-Null }
function Del-RV($p,$n){ Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue }

function Test-LWService($n){ [bool](Get-Service $n -ErrorAction SilentlyContinue) }
function Get-LWServiceStart($n){ try { (Get-Service $n -ErrorAction Stop).StartType } catch { $null } }
# Alias kept for v4 source-compat during migration
Set-Alias -Name Test-Svc -Value Test-LWService
Set-Alias -Name Get-SvcStart -Value Get-LWServiceStart

function Set-LWService($n,$m){
    if(-not(Test-LWService $n)){ Write-LWLog "Servicio '$n' no existe en este SKU, omitido" 'WARN'; return }
    & sc.exe config $n start= $m | Out-Null
    if($LASTEXITCODE -ne 0){ throw "sc config $n start=$m fallo (code $LASTEXITCODE)" }
}
# Alias for v4 source-compat
Set-Alias -Name Set-SvcStart -Value Set-LWService

function Backup-RegKey($hive,$file){
    $dest = Join-Path $script:LWBackup $file
    if(Test-Path $dest){ return }   # non-destructive: first-time only
    & reg.exe export $hive $dest /y *>$null
    if($LASTEXITCODE -eq 0){ Write-LWLog "Backup: $file" }
}
