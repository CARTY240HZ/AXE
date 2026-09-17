# =====================================================
# REGION 3 - HELPERS (registro / servicio / backup)
# =====================================================
# --- SNAPSHOT REVERT: captura del estado previo REAL por tweak (H3) ---
# Los 4 primitivos de escritura (Set-RD/Set-RS/Del-RV/Set-SvcStart) graban el valor
# ANTERIOR de cada clave/servicio que tocan, la PRIMERA vez que se aplica el tweak.
# Revert/Master restauran ese valor exacto (o lo borran si no existia) en vez de un
# default de fabrica hardcodeado. Solo aplica a tweaks 100% registro/servicio; los que
# usan bcdedit/powercfg/ProcessMitigation/DNS caen a su Revert scriptblock (Test-SnapEligible).
$script:capTweak = $null    # id del tweak en captura (o $null)
$script:capBuf   = @{}      # id -> [ordered]@{ "P|N" = record }
function Test-SnapEligible($tw){
    $s = "$($tw.Apply)`n$($tw.Revert)"
    foreach($t in 'bcdedit','powercfg','Set-ProcessMitigation','Set-DnsClient'){ if($s -match [regex]::Escape($t)){ return $false } }
    return $true
}
function Push-RegBackup($p,$n){
    if(-not $script:capTweak){ return }
    if(-not $script:capBuf.ContainsKey($script:capTweak)){ $script:capBuf[$script:capTweak]=[ordered]@{} }
    $key="$p|$n"
    if($script:capBuf[$script:capTweak].Contains($key)){ return }   # solo primera vez
    $rec=@{T='reg'; P=$p; N=$n; Had=$false}
    try {
        $it=Get-Item -LiteralPath $p -ErrorAction Stop
        if($it.GetValueNames() -contains $n){ $rec.Had=$true; $rec.V=$it.GetValue($n); $rec.K=$it.GetValueKind($n).ToString() }
    } catch {}
    $script:capBuf[$script:capTweak][$key]=$rec
}
function Push-SvcBackup($n){
    if(-not $script:capTweak){ return }
    if(-not $script:capBuf.ContainsKey($script:capTweak)){ $script:capBuf[$script:capTweak]=[ordered]@{} }
    $key="svc|$n"
    if($script:capBuf[$script:capTweak].Contains($key)){ return }
    $st=Get-SvcStart $n
    $map=@{Automatic='auto'; Manual='demand'; Disabled='disabled'; Boot='boot'; System='system'}
    $tok=if($st -and $map.ContainsKey("$st")){ $map["$st"] } else { $null }
    # 'Automatic' de .StartType cubre auto normal Y auto-RETRASADO: el cmdlet no los distingue.
    # El bit real vive en DelayedAutostart bajo la clave del servicio. Sin esto, restaurar un
    # servicio que venia retrasado (DiagTrack, MapsBroker...) lo devolvia como auto normal, o sea
    # arrancando ANTES que antes: el snapshot decia "estado previo" y no lo era del todo.
    # 'delayed-auto' es el token que entiende sc.exe, que es lo que usa Restore-TweakState.
    if($tok -eq 'auto' -and (Get-RV "HKLM:\SYSTEM\CurrentControlSet\Services\$n" 'DelayedAutostart') -eq 1){ $tok='delayed-auto' }
    $script:capBuf[$script:capTweak][$key]=@{T='svc'; N=$n; Start=$tok}
}
function Get-RV($p,$n){ try { (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n } catch { $null } }
function Set-RD($p,$n,$v){ Push-RegBackup $p $n; if(-not(Test-Path $p)){ New-Item -Path $p -Force -EA Stop | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType DWord -Force -EA Stop | Out-Null }
function Set-RS($p,$n,$v){ Push-RegBackup $p $n; if(-not(Test-Path $p)){ New-Item -Path $p -Force -EA Stop | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType String -Force -EA Stop | Out-Null }
function Del-RV($p,$n){ Push-RegBackup $p $n; Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue }
function Test-Svc($n){ [bool](Get-Service $n -ErrorAction SilentlyContinue) }
function Get-SvcStart($n){ try { (Get-Service $n -ErrorAction Stop).StartType } catch { $null } }
function Set-SvcStart($n,$m){
    if(-not(Test-Svc $n)){ Write-AXELog "Servicio '$n' no existe en este SKU, omitido" 'WARN'; return }
    Push-SvcBackup $n
    & sc.exe config $n start= $m | Out-Null
    if($LASTEXITCODE -ne 0){ throw "sc config $n start=$m fallo (code $LASTEXITCODE)" }
}
function Backup-RegKey($hive,$file){
    $dest = Join-Path $script:AXEBackup $file
    if(Test-Path $dest){ return }   # NO destructivo: solo la primera vez
    & reg.exe export $hive $dest /y *>$null
    if($LASTEXITCODE -eq 0){ Write-AXELog "Backup: $file" }
}
# --- Persistencia del snapshot (sobrevive reinicios) ---
function Read-StateBak {
    if(-not(Test-Path $script:StateBak)){ return @{} }
    try {
        $raw=Get-Content $script:StateBak -Raw -Encoding UTF8
        if([string]::IsNullOrWhiteSpace($raw)){ return @{} }
        $o=$raw | ConvertFrom-Json -ErrorAction Stop
        $h=@{}; foreach($pr in $o.PSObject.Properties){ $h[$pr.Name]=$pr.Value }
        return $h
    } catch {
        Write-AXELog "tweak_state.json ilegible: $($_.Exception.Message). Renombrado a .corrupt" 'ERR'
        try { Move-Item $script:StateBak "$($script:StateBak).corrupt" -Force -EA Stop } catch {}
        return @{}
    }
}
function Save-StateBak($h){ ($h | ConvertTo-Json -Depth 6) | Set-Content $script:StateBak -Encoding UTF8 }
function Commit-TweakState($id){
    # Vuelca capBuf[id] al store. Solo si el id NO existe ya (preserva la captura ORIGINAL).
    if(-not $script:capBuf.ContainsKey($id)){ return }
    $recs=@($script:capBuf[$id].Values); $script:capBuf.Remove($id)
    if($recs.Count -eq 0){ return }
    $store=Read-StateBak
    if($store.ContainsKey($id)){ return }   # ya teniamos el estado original; no pisar
    $store[$id]=$recs; Save-StateBak $store
}
function Remove-TweakState($id){ $store=Read-StateBak; if($store.ContainsKey($id)){ $store.Remove($id); Save-StateBak $store } }
function Restore-TweakState($id){
    # Restaura el estado previo REAL capturado. Devuelve $true si habia snapshot.
    $store=Read-StateBak
    if(-not $store.ContainsKey($id)){ return $false }
    $recs=@($store[$id])
    for($i=$recs.Count-1; $i -ge 0; $i--){
        $r=$recs[$i]
        try {
            if($r.T -eq 'reg'){
                if($r.Had){
                    if(-not(Test-Path $r.P)){ New-Item -Path $r.P -Force -EA Stop | Out-Null }
                    New-ItemProperty -Path $r.P -Name $r.N -Value $r.V -PropertyType $r.K -Force -EA Stop | Out-Null
                } else { Remove-ItemProperty -Path $r.P -Name $r.N -ErrorAction SilentlyContinue }
            } elseif($r.T -eq 'svc'){
                if($r.Start){ & sc.exe config $r.N start= $r.Start | Out-Null }
                # Sin start-type capturado: mismo criterio que cpu_park (20-tweaks.ps1) -- no se
                # inventa un valor, se avisa y no se toca. Antes era un no-op mudo: el usuario no
                # tenia forma de saber que ese servicio en concreto no se habia restaurado.
                else { Write-AXELog "Restore ${id}: servicio $($r.N) sin start-type previo capturado, no toco (evita fijar un valor supuesto)." 'WARN' }
            }
        } catch { Write-AXELog "Restore ${id}: fallo en $($r.P)\$($r.N): $($_.Exception.Message)" 'ERR' }
    }
    Remove-TweakState $id
    return $true
}

# ---- CACHEO DE TESTS ----
# Varios Test lentos repiten la MISMA consulta externa dentro de una sola pasada de
# Refresh (bcdedit, Get-NetTCPSetting, Get-ProcessMitigation). Get-AXECache memoiza por
# pasada: $script:tCache se vacia al arrancar cada Refresh-States (y tras Apply/Revert,
# que disparan Refresh), asi el valor NUNCA queda obsoleto respecto al estado real.
$script:tCache = @{}
# Topologia HW (lista de dispositivos PnP): inmutable durante la sesion => cache PERMANENTE, en
# un store aparte. El bit mutable (registro MSISupported/DevicePriority) se sigue leyendo fresco
# con Get-RV en cada Test; aqui solo se cachea la ENUMERACION cara de CIM.
$script:hwTopoCache = @{}
# Antes esto eran DOS funciones byte a byte identicas (Get-AXECache / Get-AXEHwCache) que solo se
# diferenciaban en el hashtable de respaldo. Ahora es una con -Permanent.
#   Los dos stores siguen SEPARADOS a posta: $tCache se vacia al arrancar cada Refresh-States
# (57-gui-handlers:62) para que ningun Test devuelva estado obsoleto despues de un Apply/Revert,
# y $hwTopoCache no se vacia nunca. Fundirlos en un solo diccionario haria que cada Refresh
# tirase la enumeracion PnP cara, o peor, que la topologia sobreviviese donde no debe.
function Get-AXECache {
    param([string]$Key,[scriptblock]$Producer,[switch]$Permanent)
    if($Permanent){
        if($null -eq $script:hwTopoCache){ $script:hwTopoCache=@{} }
        if($script:hwTopoCache.ContainsKey($Key)){ return $script:hwTopoCache[$Key] }
        $v = & $Producer
        $script:hwTopoCache[$Key] = $v
        return $v
    }
    if($null -eq $script:tCache){ $script:tCache=@{} }
    if($script:tCache.ContainsKey($Key)){ return $script:tCache[$Key] }
    $v = & $Producer
    $script:tCache[$Key] = $v
    return $v
}

