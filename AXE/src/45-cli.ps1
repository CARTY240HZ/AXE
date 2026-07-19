# =====================================================
# REGION 11 - MODOS CLI (headless)
# =====================================================
# --- HW: en modo headless (CLI) se carga SINCRONO (lo necesita gating/Tests). En modo
#     GUI se DEFIERE a un runspace de fondo (Start-AXEHardwareLoad, region 12) para que
#     la ventana no espere ~3.7s de CIM (Win32_Processor + Get-NetAdapter pagan cold-init WMI).
$script:HW = $null
if($SelfTest -or $List -or $Export -or $Import -or $Measure -or $Score -or $Report -or $TimerSweep){
    try { $script:HW = Get-AXEHardware } catch { $script:HW = $null }
}

if($SelfTest){
    # =====================================================
    # MODO SELFTEST (TDD): validacion de integridad. 0 fallos = OK.
    # =====================================================
    $fails = New-Object System.Collections.ArrayList
    $checks = 0

    # S1: cada tweak tiene las 10 claves obligatorias
    $required = 'Id','Cat','Tier','Reboot','Name','Desc','Requires','Test','Apply','Revert'
    foreach($tw in $script:CAT){
        $checks++
        foreach($k in $required){
            $col = @($tw.PSObject.Properties.Name)
            if($col -notcontains $k){ [void]$fails.Add("S1: $($tw.Id) falta clave '$k'") }
        }
    }
    # S2: Ids unicos
    $checks++
    $ids = @($script:CAT | ForEach-Object Id)
    $dup = $ids | Group-Object | Where-Object Count -gt 1
    if($dup){ foreach($d in $dup){ [void]$fails.Add("S2: Id duplicado '$($d.Name)'") } }
    # S3: Tier en {0,1,2}
    $checks++
    foreach($tw in $script:CAT){ if($tw.Tier -notin 0,1,2){ [void]$fails.Add("S3: $($tw.Id) Tier invalido $($tw.Tier)") } }
    # S4: Test/Apply/Revert son scriptblocks
    $checks++
    foreach($tw in $script:CAT){
        if($tw.Test  -isnot [scriptblock]){ [void]$fails.Add("S4: $($tw.Id) Test no es scriptblock") }
        if($tw.Apply -isnot [scriptblock]){ [void]$fails.Add("S4: $($tw.Id) Apply no es scriptblock") }
        if($tw.Revert-isnot [scriptblock]){ [void]$fails.Add("S4: $($tw.Id) Revert no es scriptblock") }
    }
    # S5: Apply != Revert (salvo hardening documentado svc_remotereg)
    $checks++
    foreach($tw in $script:CAT){
        if($tw.Id -eq 'svc_remotereg'){ continue }   # unidireccional intencional
        if($tw.Apply.ToString() -eq $tw.Revert.ToString()){ [void]$fails.Add("S5: $($tw.Id) Apply==Revert (revert inutil / no-op)") }
    }
    # S6: catalogo tiene masa critica
    $checks++
    if($script:CAT.Count -lt 10){ [void]$fails.Add("S6: catalogo con $($script:CAT.Count) tweaks (<10) - roto") }
    # S7: round-trip JSON de startup
    $checks++
    try {
        $tmp = Join-Path $script:AXEData ('selftest_{0}.json' -f [guid]::NewGuid())
        $probe = @(
            [pscustomobject]@{Hive='HKCU';Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';Name='__LW_TEST__';Value='x'}
            [pscustomobject]@{Hive='HKLM';Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';Name='__LW_TEST2__';Value='y'}
        )
        $probe | ConvertTo-Json -Depth 5 | Set-Content $tmp -Encoding UTF8
        $back = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        if(@($back).Count -ne 2){ [void]$fails.Add("S7: round-trip JSON perdio elementos (esperado 2, got $(@($back).Count))") }
        Remove-Item $tmp -Force -EA SilentlyContinue
    } catch { [void]$fails.Add("S7: round-trip JSON lanzo excepcion: $($_.Exception.Message)") }
    # S8: gating devuelve null o string
    $checks++
    if($script:HW){
        foreach($tw in $script:CAT){
            $r = Get-BlockReason $tw
            if($r -ne $null -and $r -isnot [string]){ [void]$fails.Add("S8: $($tw.Id) gating devolvio tipo invalido"); break }
        }
    }
    # S9: helpers basicos existen (no codigo muerto / funciones rotas)
    $checks++
    foreach($fn in 'Get-RV','Set-RD','Set-RS','Del-RV','Test-Svc','Get-SvcStart','Set-SvcStart','Backup-RegKey','Get-BlockReason','Read-StartupBackup','Restore-Autorun','Repair-StartupBackup','Invoke-AXEMasterRevertTail'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S9: funcion requerida '$fn' no definida") }
    }
    # S10: WinVer (si un tweak lo usa, debe ser array de enteros 10/11)
    $checks++
    foreach($tw in $script:CAT){
        if($tw.Requires.PSObject.Properties['WinVer']){
            $wv = $tw.Requires.WinVer
            if(-not ($wv -is [array]) -or ($wv | Where-Object { $_ -notin 10,11 }).Count -gt 0){
                [void]$fails.Add("S10: $($tw.Id) WinVer invalido: $($wv -join ',')")
            }
        }
    }
    # S19: coherencia de Requires del ecosistema (§3.2) - claves fabricadas / mal tipadas.
    # Whitelist: cualquier clave desconocida (typo tipo 'MimRam') => FAIL, porque Get-BlockReason
    # la ignoraria en silencio y el tweak quedaria siempre visible (el linter no lo detecta).
    $checks++
    $knownReq = @('MinRam','Desktop','NotLaptop','NotHybrid','AC','Wired','NotHome','Nvidia','WinVer','WinBuild','CpuArch','CpuVendor','HAGS','TamperOff','Defender','NotSMode')
    foreach($tw in $script:CAT){
        $rq = $tw.Requires
        if($rq -isnot [hashtable]){ continue }
        foreach($k in $rq.Keys){ if($k -notin $knownReq){ [void]$fails.Add("S19: $($tw.Id) clave Requires desconocida '$k' (typo? no gatea)") } }
        if($rq.ContainsKey('HAGS') -and $tw.Cat -ne 'GPU'){ [void]$fails.Add("S19: $($tw.Id) HAGS solo aplica a Cat=GPU") }
        if($rq.ContainsKey('MinRam')){ $mr=$rq['MinRam']; if(-not ($mr -is [int]) -or $mr -le 0){ [void]$fails.Add("S19: $($tw.Id) MinRam invalido: $mr") } }
        foreach($ak in 'CpuArch','CpuVendor','WinBuild'){ if($rq.ContainsKey($ak) -and ($rq[$ak] -isnot [array])){ [void]$fails.Add("S19: $($tw.Id) $ak debe ser array") } }
    }
    # S11: masa critica actualizada (el catalogo crece con cada fusion)
    $checks++
    if($script:CAT.Count -lt 60){ [void]$fails.Add("S11: catalogo con $($script:CAT.Count) tweaks (<60) - posible carga incompleta") }

    # S12: perfiles por-juego (region 10b). Round-trip Add/Remove en store temporal
    # (no toca el store real) + power plans se enumeran + plan activo es un GUID.
    $checks++
    $realBak = $script:ProfilesBak
    try {
        $script:ProfilesBak = Join-Path $script:AXEData ('proftest_{0}.json' -f [guid]::NewGuid())
        if((Read-Profiles).Count -ne 0){ [void]$fails.Add('S12: store temporal no arranca vacio') }
        [void](Add-GameProfile 'test' 'cs2.exe' '381b4222-f694-41f0-9685-ff5bb260df2e' 'Equilibrado')
        $r = Read-Profiles
        if($r.Count -ne 1 -or $r[0].Exe -ne 'cs2' -or $r[0].Name -ne 'test'){ [void]$fails.Add('S12: Add/Read perfil no round-trip') }
        Remove-GameProfile 'test'
        if((Read-Profiles).Count -ne 0){ [void]$fails.Add('S12: Remove perfil no vacia el store') }
        Remove-Item $script:ProfilesBak -Force -EA SilentlyContinue
    } catch { [void]$fails.Add("S12: perfiles lanzaron excepcion: $($_.Exception.Message)") }
    finally { $script:ProfilesBak = $realBak }
    # S12b: funciones de plan de energia presentes y coherentes
    $checks++
    foreach($fn in 'Get-PowerPlans','Get-ActivePlan','Set-ActivePlan','Test-GameRunning','Tick-GameProfiles'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S12b: funcion '$fn' no definida") }
    }
    $ap = Get-ActivePlan
    if($ap -and $ap -notmatch '^[0-9a-fA-F-]{36}$'){ [void]$fails.Add("S12b: plan activo no es GUID: $ap") }

    # S13: timer resolution medible (o null sin lanzar)
    $checks++
    try {
        $tr = Get-AXETimerResolution
        if($tr -ne $null -and ($tr.CurrentMs -isnot [double] -and $tr.CurrentMs -isnot [int] -and $tr.CurrentMs -isnot [decimal])){ [void]$fails.Add("S13: Get-AXETimerResolution.CurrentMs no numerico") }
    } catch { [void]$fails.Add("S13: Get-AXETimerResolution lanzo: $($_.Exception.Message)") }

    # S14: jitter sampler (duracion corta) devuelve stats numericas rapido
    $checks++
    try {
        $jt = Measure-AXEJitter -DurationMs 50
        if($jt.Samples -le 0 -or $jt.P999Ms -lt 0 -or $jt.MaxMs -lt 0){ [void]$fails.Add("S14: Measure-AXEJitter stats invalidas (n=$($jt.Samples))") }
    } catch { [void]$fails.Add("S14: Measure-AXEJitter lanzo: $($_.Exception.Message)") }

    # S15: snapshot devuelve los 5 campos y no lanza (jitter corto)
    $checks++
    try {
        $sn = Get-AXESnapshot -JitterMs 50
        foreach($f in 'Timestamp','Timer','Jitter','TweaksOn','TweaksApplicable'){
            if(-not $sn.PSObject.Properties[$f]){ [void]$fails.Add("S15: snapshot falta campo '$f'") }
        }
    } catch { [void]$fails.Add("S15: Get-AXESnapshot lanzo: $($_.Exception.Message)") }

    # S16: score en [0,100] con snapshot real y con snapshot n/a (parcial), sin lanzar
    $checks++
    try {
        $scReal = Get-AXEScore (Get-AXESnapshot -JitterMs 50)
        if($scReal.Total -lt 0 -or $scReal.Total -gt 100){ [void]$fails.Add("S16: Total fuera de rango: $($scReal.Total)") }
        $naSnap=[pscustomobject]@{Timestamp='x';Timer='n/a';Jitter='n/a';TweaksOn='n/a';TweaksApplicable='n/a'}
        $scNa = Get-AXEScore $naSnap
        if($scNa.Total -lt 0 -or $scNa.Total -gt 100){ [void]$fails.Add("S16: Total(n/a) fuera de rango: $($scNa.Total)") }
    } catch { [void]$fails.Add("S16: Get-AXEScore lanzo: $($_.Exception.Message)") }

    # S17: restore point con AXE_NOSR=1 devuelve fallback sin lanzar ni crear punto
    $checks++
    try {
        $env:AXE_NOSR='1'
        $rp = New-AXERestorePoint 'selftest'
        if($rp.Status -ne 'fallback'){ [void]$fails.Add("S17: con AXE_NOSR esperaba 'fallback', got '$($rp.Status)'") }
    } catch { [void]$fails.Add("S17: New-AXERestorePoint lanzo: $($_.Exception.Message)") }

    # S18: reporte string no vacio + export JSON parseable (roundtrip en temp)
    $checks++
    try {
        $s0=Get-AXESnapshot -JitterMs 50; $s1=Get-AXESnapshot -JitterMs 50
        $rep=New-AXEReport $s0 $s1 (Get-AXEScore $s0) (Get-AXEScore $s1 $s0)
        if([string]::IsNullOrWhiteSpace($rep)){ [void]$fails.Add('S18: New-AXEReport vacio') }
        $tmp=Join-Path $script:AXEData ('reptest_{0}.json' -f [guid]::NewGuid())
        Export-AXEReport $s0 $s1 $tmp
        $back=Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        if(-not $back.scoreAfter){ [void]$fails.Add('S18: export JSON sin scoreAfter') }
        Remove-Item $tmp -Force -EA SilentlyContinue
    } catch { [void]$fails.Add("S18: report/export lanzo: $($_.Exception.Message)") }

    # S20: modulo Defender (§7) presente - funciones de exclusion/afinado definidas
    $checks++
    foreach($fn in 'Add-AXEDefenderExclusion','Remove-AXEDefenderExclusion','Get-AXESteamCommon'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S20: funcion Defender '$fn' no definida") }
    }
    foreach($id in 'def_cpulimit','def_scanidle'){
        if(-not ($script:CAT | Where-Object Id -eq $id)){ [void]$fails.Add("S20: tweak Defender '$id' no en catalogo") }
    }
    # S21: banner de ecosistema (§3.3) + azucar de gating (§3.2) presentes y no lanzan
    $checks++
    foreach($fn in 'Get-AXEEnvBanner','Test-AXEEnvApplies'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S21: funcion '$fn' no definida") }
    }
    try { if([string]::IsNullOrWhiteSpace((Get-AXEEnvBanner))){ [void]$fails.Add('S21: Get-AXEEnvBanner vacio') } }
    catch { [void]$fails.Add("S21: Get-AXEEnvBanner lanzo: $($_.Exception.Message)") }
    # S22: preflight de seguridad (§4.1) presente
    $checks++
    foreach($fn in 'Assert-AXEVss','Get-AXETamperState'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S22: funcion '$fn' no definida") }
    }

    Write-Host "========================================="
    Write-Host " AXE $($script:AXEVersion) - SELF TEST"
    Write-Host "========================================="
    Write-Host " Catalogo   : $($script:CAT.Count) tweaks"
    Write-Host " Checks     : $checks"
    Write-Host " Fallos     : $($fails.Count)"
    Write-Host "-----------------------------------------"
    if($fails.Count -gt 0){ $fails | ForEach-Object { Write-Host "  FAIL: $_" } }
    Write-Host "========================================="
    if($fails.Count -eq 0){ Write-Host " RESULTADO: OK (0 fallos)"; exit 0 } else { Write-Host " RESULTADO: FALLO"; exit 1 }
}

if($List){
    Write-Host "== AXE $($script:AXEVersion) =="
    if($script:HW){ Write-Host "HW: $($script:HW.CpuName) | Laptop=$($script:HW.IsLaptop) Hybrid=$($script:HW.IsHybrid) Nvidia=$($script:HW.HasNvidia) Wifi=$($script:HW.IsWifi) AC=$(-not $script:HW.OnBattery)" }
    if($script:HW){ Write-Host ("ECO: " + (Get-AXEEnvBanner)) }
    # §3.4: la CLI dice lo mismo que la GUI. Una sola fuente (Get-AXERecommended), dos caras.
    if($script:HW){ $rec=@(Get-AXERecommended); Write-Host ("REC: {0} recomendados para este equipo -> {1}" -f $rec.Count,($rec -join ', ')) }
    Write-Host ""
    foreach($tw in $script:CAT){
        $blk = Get-BlockReason $tw
        $st  = try{ if($blk){'BLOCKED'}else{ if([bool](& $tw.Test)){'ON'}else{'off'} } }catch{ "ERR" }
        "{0,-11} T{1} {2,-34} {3}{4}" -f $tw.Cat,$tw.Tier,$tw.Name,$st,$(if($blk){" ($blk)"}) | Write-Host
    }
    exit 0
}

if($Export){
    Export-AXEProfile $Export
    exit 0
}
if($Import){
    Import-AXEProfile $Import
    exit 0
}
if($Measure){
    $snap=Get-AXESnapshot
    $sc=Get-AXEScore $snap
    Write-Host "== AXE MEDICION =="
    Write-Host $sc.Breakdown
    Write-Host ("AXE Score : {0}/100" -f $sc.Total)
    Write-Host 'Jitter = proxy de latencia (no atribuible a driver concreto).'
    exit 0
}
if($Score){
    $sc=Get-AXEScore (Get-AXESnapshot)
    Write-Host ("AXE Score : {0}/100" -f $sc.Total)
    Write-Host $sc.Breakdown
    exit 0
}
if($Report){
    $s0=Get-AXESnapshot; $s1=Get-AXESnapshot
    Write-Host (Export-AXEReport $s0 $s1 $Report)
    exit 0
}
if($TimerSweep){
    # Barrido de resolucion de timer. NO recomienda un valor a ciegas: si el resultado cae
    # dentro del ruido de medicion lo dice y no recomienda nada. Ver Measure-AXETimerSweep.
    Write-Host '== AXE BARRIDO DE TIMER =='
    Write-Host 'Midiendo delta de Sleep(1) por resolucion. Tarda unos segundos...'
    $sw = Measure-AXETimerSweep
    if(-not $sw){ Write-Host 'Sin datos utiles (ver log).'; exit 1 }

    # Render via Format-AXETimerSweep (32-measure.ps1): mismo texto que el boton de la GUI.
    Write-Host ''
    foreach($line in (Format-AXETimerSweep $sw)){ Write-Host $line }
    exit 0
}

