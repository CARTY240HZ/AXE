# =====================================================
# REGION 11 - MODOS CLI (headless)
# =====================================================
# --- HW: en modo headless (CLI) se carga SINCRONO (lo necesita gating/Tests). En modo
#     GUI se DEFIERE a un runspace de fondo (Start-AXEHardwareLoad, region 12) para que
#     la ventana no espere ~3.7s de CIM (Win32_Processor + Get-NetAdapter pagan cold-init WMI).
$script:HW = $null
#     -Diag entra aqui porque Get-AXEDiagFacts reusa $script:HW.IsSSD en vez de recalcularlo.
#     -Benchmark tambien: Get-AXESnapshot mide cobertura via Get-BlockReason, que necesita $HW.
#     Sin el, la metrica 'score' cambiaria entre fases por el orden de carga y no por el sistema.
if($SelfTest -or $List -or $Export -or $Import -or $Measure -or $Score -or $Report -or $TimerSweep -or $Diag -or $Benchmark){
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
    # S22 ELIMINADO (auditoria 2026-07-19). Comprobaba que Assert-AXEVss y Get-AXETamperState
    # estuvieran DEFINIDAS. Ninguna tenia llamadores de produccion, asi que el check solo probaba
    # que existia codigo muerto: imposible de fallar mientras nadie borrara las funciones, y cero
    # senal sobre si el preflight de §4.1 servia (no servia: no se invocaba nunca). Las funciones
    # se han borrado en 34-safety.ps1 y el check se va con ellas.
    #   Leccion por si se reescribe: un check de "la funcion existe" no vale. Si se cablea un
    # preflight de verdad, el check debe EJECUTARLO y mirar lo que devuelve -- como S21 con
    # Get-AXEEnvBanner, o el harness GUI pulsando de verdad el boton de REGISTRO.

    # S23: GPU por juego (region 10c). Siguiendo la leccion de S22: no se comprueba que las
    # funciones EXISTAN, se EJECUTAN sobre una ruta sintetica y se mira lo que devuelven.
    # Nada de esto toca una entrada de juego real.
    $checks++
    try {
        # Parser: roundtrip sobre el formato real, incluida la cadena que empieza por ';'.
        $rt = ConvertTo-AXEGpuPref (ConvertFrom-AXEGpuPref 'AppStatus=4096;GpuPreference=2;')
        if($rt -ne 'AppStatus=4096;GpuPreference=2;'){ [void]$fails.Add("S23: parser no hace roundtrip: '$rt'") }
        if((ConvertFrom-AXEGpuPref ';SwapEffectUpgradeEnable=1;').Count -ne 1){ [void]$fails.Add('S23: parser no tolera cadena que empieza por ;') }
        # Escritura + revert sobre un exe que no existe en disco.
        $probe = 'C:\__AXE_SELFTEST_GPU__\probe.exe'
        Set-AXEGameGpuPref -Exe $probe -HighPerf $true -FlipModel $true
        $ps = Get-AXEGameGpuState $probe
        if(-not $ps.HighPerf -or -not $ps.FlipModel){ [void]$fails.Add("S23: Set-AXEGameGpuPref no aplico (raw='$($ps.Raw)')") }
        if((Revert-AXEGameGpu $probe) -eq 0){ [void]$fails.Add('S23: revert no encontro la captura que acababa de hacer') }
        if($null -ne (Get-RV $script:GpuPrefKey $probe)){ [void]$fails.Add('S23: revert dejo residuo en el registro') }
        # Exe jamas tocado: 0 y sin escribir.
        if((Revert-AXEGameGpu 'C:\__AXE_SELFTEST_GPU__\jamas.exe') -ne 0){ [void]$fails.Add('S23: revert de exe intacto no devolvio 0') }
        # Ruta inexistente: Optimize avisa y no escribe.
        $om = (Optimize-AXEGame -Exe 'C:\__AXE_SELFTEST_GPU__\no-existe.exe') -join "`n"
        if($om -notmatch 'no existe'){ [void]$fails.Add("S23: Optimize-AXEGame no aviso de ruta inexistente: $om") }
    } catch { [void]$fails.Add("S23: GPU por juego lanzo: $($_.Exception.Message)") }

    # S24: las variables de ruta del catalogo siguen siendo cadenas con contenido.
    # POR QUE EXISTE: al anadir la CLI de GPU por juego se declaro un '[switch]$Games' en el
    # param block, y 20-tweaks.ps1 ya usaba $Games para la ruta de la tarea MMCSS. Declararla
    # como switch la tipa a nivel de script, la asignacion de la cadena revienta y $Games queda
    # vacia => gpu_mmcss apuntando a la nada. El SelfTest daba 0 fallos: S1-S23 miran el ESQUEMA
    # del catalogo (claves, tipos, ids) y ninguno mira si las RUTAS que usan tienen valor.
    # Cualquier futura colision param-vs-variable cae aqui en vez de silenciosamente en runtime.
    $checks++
    foreach($pv in @(@{N='PC';V=$PC},@{N='SP';V=$SP},@{N='GD';V=$GD},@{N='MM';V=$MM},@{N='Games';V=$Games})){
        if([string]::IsNullOrWhiteSpace([string]$pv.V)){
            [void]$fails.Add("S24: `$$($pv.N) vacia - colision con un parametro del param block? Los tweaks que la usan escribirian en una ruta invalida")
        } elseif([string]$pv.V -notmatch '^HK(LM|CU):\\'){
            [void]$fails.Add("S24: `$$($pv.N) no parece ruta de registro: '$($pv.V)'")
        }
    }

    # S25: medicion de FPS (region 10d). Se EJERCE el calculo y el veredicto con series
    # sinteticas: no hace falta PresentMon ni un juego abierto, y por eso el check corre
    # siempre en vez de saltarse en la mitad de las maquinas.
    $checks++
    try {
        $const = Get-AXEFpsStats -FrameTimesMs (@(16.667) * 100)
        if(-not $const.Ok -or [math]::Abs($const.AvgFps - 60) -gt 0.5){ [void]$fails.Add("S25: 60 FPS constantes dieron $($const.AvgFps)") }
        # El 1% low debe mirar los frames MAS LENTOS. Si el orden se invirtiera, este caso lo
        # caza: 99 frames de 10ms + 1 de 100ms tiene que dar 1% low ~= 10 FPS, no ~100.
        $spike = Get-AXEFpsStats -FrameTimesMs (@(@(10.0) * 99) + @(100.0))
        if([math]::Abs($spike.P1LowFps - 10) -gt 1){ [void]$fails.Add("S25: 1% low midio los frames rapidos (dio $($spike.P1LowFps), esperado ~10)") }
        if((Get-AXEFpsStats -FrameTimesMs @(16.6,16.6)).Ok){ [void]$fails.Add('S25: captura de 2 frames se dio por valida') }
        # Veredicto: dos capturas iguales NO pueden ser concluyentes.
        $mk = { param($base,$j,$n) Get-AXEFpsStats -FrameTimesMs @(foreach($i in 0..($n-1)){ $base + $j*[math]::Sin($i*0.7) }) }
        $s1 = & $mk 16.667 1.0 800; $s2 = & $mk 16.667 1.0 800
        $vSame = Get-AXEFpsVerdict -Before $s1 -After $s2
        if($vSame.Conclusive){ [void]$fails.Add('S25: dos capturas identicas salieron CONCLUYENTES (umbral de ruido roto)') }
        $vBig = Get-AXEFpsVerdict -Before (& $mk 20.0 0.5 800) -After (& $mk 16.667 0.5 800)
        if(-not $vBig.Conclusive){ [void]$fails.Add('S25: 50->60 FPS limpios NO salieron concluyentes') }
        # El aviso de misma-escena tiene que ir tambien cuando el resultado es bueno.
        if($vBig.Warning -notmatch 'MISMA escena'){ [void]$fails.Add('S25: falta el aviso de misma-escena en un veredicto positivo') }
        # Columna de PresentMon: las dos versiones, y null si no la reconoce.
        if((Get-AXEFrameTimeColumn ([pscustomobject]@{msBetweenPresents='1'})) -ne 'msBetweenPresents'){ [void]$fails.Add('S25: no reconoce la columna de PresentMon 1.x') }
        if((Get-AXEFrameTimeColumn ([pscustomobject]@{FrameTime='1'})) -ne 'FrameTime'){ [void]$fails.Add('S25: no reconoce la columna de PresentMon 2.x') }
        if($null -ne (Get-AXEFrameTimeColumn ([pscustomobject]@{Nada='1'}))){ [void]$fails.Add('S25: adivina columna desconocida en vez de devolver null') }
        if(-not (Get-Command Measure-AXEFps -EA SilentlyContinue)){ [void]$fails.Add('S25: Measure-AXEFps no definida') }
    } catch { [void]$fails.Add("S25: medicion de FPS lanzo: $($_.Exception.Message)") }

    # S26: la capa WebUI (webui/) existe y trae los assets minimos (rediseno WebView2, fase 0).
    # Usa $script:WebUIDir (39-webdetect resuelve AXE\webui aun corriendo desde dist\).
    $checks++
    foreach($a in 'index.html','styles.css','app.js','bridge.js'){
        if(-not (Test-Path (Join-Path $script:WebUIDir $a))){ [void]$fails.Add("S26: falta webui/$a") }
    }
    # S27: deteccion de runtime WebView2 definida y con la forma esperada {Available,Version,Reason}
    $checks++
    if(-not (Get-Command Get-AXEWebView2Runtime -EA SilentlyContinue)){
        [void]$fails.Add('S27: Get-AXEWebView2Runtime no definida')
    } else {
        $rt = Get-AXEWebView2Runtime
        foreach($k in 'Available','Version','Reason'){
            if(($rt.PSObject.Properties.Name) -notcontains $k){ [void]$fails.Add("S27: runtime sin campo '$k'") }
        }
    }
    # S-webui-3: coherencia lista blanca (48-webbridge) <-> literales del frontend (webui/*.js).
    #  Directo: cada AXE.call('x') literal existe en la lista blanca (caza typos / cmds inventados).
    #  Inverso: cada cmd de la lista blanca aparece como literal en el JS. El inverso usa presencia
    #  de literal (no el prefijo AXE.call() del regex directo) a proposito: asi ve el despacho
    #  ternario AXE.call(cond ? 'tweaks.apply' : 'tweaks.revert') que el directo no captura.
    #  El bloque -SelfTest de 45-cli hace 'exit' ANTES de que 48-webbridge cargue el mapa, asi que
    #  el $script:AXEBridgeMap vivo no existe aqui: las claves se extraen del propio script en curso
    #  ($PSCommandPath), donde "'x' = { param($a)" es un patron EXCLUSIVO del puente (14/14 en dist).
    #  Si el mapa esta cargado (contexto Pester/futuro) se usa tal cual. Match case-sensitive (-c*),
    #  coherente con el despacho exacto del puente.
    $checks++
    $wlKeys = @()
    if($script:AXEBridgeMap){
        $wlKeys = @($script:AXEBridgeMap.Keys)
    } else {
        $selfSrc = ''
        try { $selfSrc = Get-Content $PSCommandPath -Raw -EA Stop } catch {}
        $rx = '(?m)^\s*''([A-Za-z][A-Za-z.]*)''\s*=\s*\{\s*param\(\$a\)'
        $wlKeys = @([regex]::Matches($selfSrc, $rx) | ForEach-Object { $_.Groups[1].Value })
    }
    if(@($wlKeys).Count -eq 0){
        [void]$fails.Add('S-webui-3: no se pudo determinar la lista blanca del puente (mapa vivo ausente y parseo vacio)')
    } else {
        $wjs = Get-ChildItem $script:WebUIDir -Recurse -Filter '*.js' -EA SilentlyContinue
        $jsRaw = ($wjs | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        $called = @{}
        foreach($m in [regex]::Matches($jsRaw, "AXE\.call\(\s*'([^']+)'")){ $called[$m.Groups[1].Value] = $true }
        foreach($c in $called.Keys){
            if($wlKeys -cnotcontains $c){ [void]$fails.Add("S-webui-3: app.js llama '$c' fuera de la lista blanca") }
        }
        foreach($c in $wlKeys){
            if($jsRaw -notmatch [regex]::Escape("'$c'")){ [void]$fails.Add("S-webui-3: '$c' en lista blanca pero ningun JS lo referencia (cmd muerto)") }
        }
    }

    # S28: daemon de sesion de juego (region 12b, spec 2026-07-20). Leccion S22: no se comprueba
    # que las funciones EXISTAN, se EJECUTA el planificador PURO sobre hechos sinteticos y se mira
    # el reparto. No toca el kernel ni procesos reales.
    $checks++
    try {
        $sf = @(
            [pscustomobject]@{Pid=1000;Name='thegame';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1001;Name='explorer';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1002;Name='discord';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1003;Name='chrome';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1004;Name='EasyAntiCheat';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1005;Name='randomthing';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1006;Name='svchost';SessionId=0;Path=$null}
            [pscustomobject]@{Pid=99;Name='powershell';SessionId=1;Path=$null}
        )
        $pl = Get-AXESessionPlan -Processes $sf -GamePid 1000 -GameName 'thegame' -SelfPid 99 -SessionId 1
        $cong = @($pl.Congelado | ForEach-Object Name)
        $deg  = @($pl.Degradado | ForEach-Object Name)
        $int  = @($pl.Intacto   | ForEach-Object Name)
        if($cong -notcontains 'randomthing'){ [void]$fails.Add('S28: proceso desconocido no quedo CONGELADO') }
        foreach($never in 'thegame','explorer','discord','EasyAntiCheat','powershell','svchost'){
            if($cong -contains $never){ [void]$fails.Add("S28: '$never' NO debe ser congelable") }
        }
        if($deg -notcontains 'chrome'){ [void]$fails.Add('S28: chrome no quedo DEGRADADO') }
        if($int -notcontains 'discord'){ [void]$fails.Add('S28: discord no quedo INTACTO') }
        foreach($grp in $int,$deg,$cong){ if($grp -contains 'svchost'){ [void]$fails.Add('S28: proceso de Session 0 entro en el plan') } }
        $empty = Get-AXESessionPlan -Processes @() -GamePid 0 -GameName 'x' -SelfPid 1 -SessionId 1
        if(@($empty.Congelado).Count -ne 0){ [void]$fails.Add('S28: plan de lista vacia no salio vacio') }
        foreach($fn in 'Start-AXESession','Stop-AXESession','Watch-AXESession','Format-AXESession','Get-AXESessionProcesses'){
            if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S28: funcion de sesion '$fn' no definida") }
        }
    } catch { [void]$fails.Add("S28: planificador de sesion lanzo: $($_.Exception.Message)") }

    # S29: benchmark "pruebalo en tu PC" (region 8e, spec 2026-07-24). Misma leccion que S22/S25:
    # el veredicto se EJERCE con series sinteticas en vez de comprobar que la funcion existe. Aqui
    # lo que hay que proteger es una sola propiedad: que NUNCA se declare mejora dentro del ruido.
    # Si algun dia alguien "afina" el umbral, este check se pone rojo antes de que salga del repo.
    $checks++
    try {
        # Fabrica de agregados sinteticos: {median,iqr,passes} por metrica, la misma forma que
        # produce Measure-AXEBenchSample y que sobrevive al round-trip JSON.
        $mkS = {
            param($p999,$q999,$scoreV,$scoreQ)
            [pscustomobject]@{
                id='synth'; axeVersion='test'; hwHash='sha256:synth'; ts='2026-07-24T00:00:00Z'
                passes=7; jitterMs=250
                hw=[pscustomobject]@{ cpu='synth'; ramGB=16.0; gpuVendor='synth'; build=26200 }
                metrics=[pscustomobject]@{
                    jitterP999Ms=[pscustomobject]@{ median=$p999; iqr=$q999; passes=7 }
                    jitterMeanMs=$null
                    timerMs=$null
                    score=[pscustomobject]@{ median=$scoreV; iqr=$scoreQ; passes=7 }
                }
            }
        }
        # (a) delta grande y limpio (jitter baja mucho, ruido pequeno) => concluyente 'mejor'.
        $vA = Get-AXEBenchVerdict (& $mkS 1.00 0.02 50 1) (& $mkS 0.40 0.02 70 1)
        $jA = $vA | Where-Object Key -eq 'jitterP999Ms'
        if(-not $jA -or $jA.Tag -ne 'mejor'){ [void]$fails.Add("S29: delta limpio de jitter no salio 'mejor' (dio '$($jA.Tag)')") }
        $sA = $vA | Where-Object Key -eq 'score'
        if(-not $sA -or $sA.Tag -ne 'mejor'){ [void]$fails.Add("S29: score 50->70 no salio 'mejor' (dio '$($sA.Tag)')") }
        # (b) delta REAL pero por debajo del ruido combinado => 'ruido'. El check que importa.
        $vB = Get-AXEBenchVerdict (& $mkS 1.00 0.30 50 5) (& $mkS 0.95 0.30 52 5)
        foreach($m in $vB){
            if($m.Tag -ne 'ruido'){ [void]$fails.Add("S29: '$($m.Key)' dentro del ruido salio '$($m.Tag)' - el motor declara mejoras que no existen") }
            if($m.Conclusive){ [void]$fails.Add("S29: '$($m.Key)' dentro del ruido salio Conclusive") }
        }
        # (c) delta grande en la direccion mala => 'peor' (el veredicto no solo sabe felicitar).
        $vC = Get-AXEBenchVerdict (& $mkS 0.40 0.02 70 1) (& $mkS 1.00 0.02 50 1)
        foreach($k in 'jitterP999Ms','score'){
            $m = $vC | Where-Object Key -eq $k
            if(-not $m -or $m.Tag -ne 'peor'){ [void]$fails.Add("S29: regresion grande en '$k' no salio 'peor' (dio '$($m.Tag)')") }
        }
        # (d) metrica no medible (native ausente) => se OMITE, sin lanzar y sin comparar contra 0.
        if(@($vA | Where-Object Key -eq 'timerMs').Count -ne 0){ [void]$fails.Add('S29: metrica null no se omitio del veredicto') }
        if(@($vA | Where-Object Key -eq 'jitterMeanMs').Count -ne 0){ [void]$fails.Add('S29: metrica ausente no se omitio del veredicto') }
        # Round-trip Save/Read en store TEMPORAL: no toca el AXE/bench/ real del usuario.
        $realBench = $script:AXEBenchDir
        try {
            $script:AXEBenchDir = Join-Path $script:AXEData ('benchtest_{0}' -f [guid]::NewGuid())
            $sample = & $mkS 0.42 0.05 61 2
            $bid = Save-AXEBenchBaseline $sample
            if(-not $bid){ [void]$fails.Add('S29: Save-AXEBenchBaseline no devolvio id') }
            $back = Read-AXEBenchBaseline $bid
            if(-not $back){ [void]$fails.Add('S29: Read-AXEBenchBaseline no recupero la linea base') }
            elseif([double]$back.metrics.jitterP999Ms.median -ne 0.42){ [void]$fails.Add("S29: round-trip perdio la mediana (dio $($back.metrics.jitterP999Ms.median))") }
            if($null -ne (Read-AXEBenchBaseline 'no-existe-jamas')){ [void]$fails.Add('S29: un id inexistente devolvio algo en vez de null') }
            if($null -ne (Read-AXEBenchBaseline '..\..\etc')){ [void]$fails.Add('S29: un id con separadores de ruta no se rechazo') }
            # Comparabilidad: hash distinto => se niega con motivo, no produce un delta falso.
            $why = Test-AXEBenchComparable $back ([pscustomobject]@{ axeVersion='otra'; hwHash='sha256:OTRA'; hw=[pscustomobject]@{cpu='x';ramGB=8.0;gpuVendor='y';build=1} })
            if([string]::IsNullOrWhiteSpace($why)){ [void]$fails.Add('S29: hash de HW distinto se dio por comparable') }
            # Reporte: no vacio, JSON parseable, y sin PII (ni usuario ni equipo).
            $rep = New-AXEBenchReport $back (& $mkS 0.30 0.04 70 2) $null
            if(@($rep.Text).Count -lt 5){ [void]$fails.Add('S29: reporte de texto vacio o demasiado corto') }
            if([string]::IsNullOrWhiteSpace($rep.Markdown)){ [void]$fails.Add('S29: reporte Markdown vacio') }
            $pj = $null
            try { $pj = $rep.Json | ConvertFrom-Json -EA Stop } catch { [void]$fails.Add("S29: JSON del reporte no parsea: $($_.Exception.Message)") }
            if($pj -and @($pj.verdict).Count -lt 1){ [void]$fails.Add('S29: JSON del reporte sin veredicto') }
            $all = (@($rep.Text) -join "`n") + $rep.Markdown + $rep.Json
            foreach($pii in @($env:USERNAME,$env:COMPUTERNAME,$env:USERDOMAIN)){
                if($pii -and $all -match [regex]::Escape($pii)){ [void]$fails.Add("S29: el reporte compartible contiene PII ('$pii')") }
            }
            Remove-Item $script:AXEBenchDir -Recurse -Force -EA SilentlyContinue
        } finally { $script:AXEBenchDir = $realBench }
    } catch { [void]$fails.Add("S29: benchmark lanzo: $($_.Exception.Message)") }

    # S30: cadena de confianza + updater (region 8f, spec 2026-07-24). Misma leccion que
    # S25/S29: no se comprueba que las funciones EXISTAN, se EJERCEN las decisiones. Aqui lo
    # que hay que proteger es una sola propiedad, y es de seguridad: EL UPDATER NUNCA REEMPLAZA
    # NADA QUE NO HAYA VERIFICADO. Si alguien "simplifica" una de estas negativas, esto se pone
    # rojo antes de que salga del repo. Todo headless y SIN RED: los caminos de rechazo que se
    # ejercen ocurren antes de cualquier descarga, y el resto va con fixtures locales.
    $checks++
    try {
        # (a) Comparacion de versiones, incluido el orden de prerelease de SemVer §11.
        $vc = @(
            @{ A='7.0.0'; B='7.0.1'; W=-1 }, @{ A='7.0.1'; B='7.0.0'; W=1 }, @{ A='7.0.0'; B='7.0.0'; W=0 }
            @{ A='7';     B='7.0.0'; W=0 }              # '7' se normaliza a '7.0.0'
            @{ A='v7.1.0';B='7.1.0'; W=0 }              # la 'v' del tag no cuenta
            @{ A='7.1.0-beta'; B='7.1.0'; W=-1 }        # prerelease < estable
            @{ A='7.10.0'; B='7.9.0'; W=1 }             # 10 > 9, no comparacion de cadenas
            @{ A='7.0.0+abc'; B='7.0.0'; W=0 }          # los metadatos de build no cuentan
        )
        foreach($t in $vc){
            $got = Compare-AXEVersion $t.A $t.B
            if($got -ne $t.W){ [void]$fails.Add("S30: Compare-AXEVersion '$($t.A)' vs '$($t.B)' dio $got, esperado $($t.W)") }
        }
        if($null -ne (Compare-AXEVersion '7.x.0' '7.0.0')){ [void]$fails.Add('S30: una version ilegible no devolvio null (se confundiria con "al dia")') }

        # (b) Checksums: round-trip generar -> verificar, y que una alteracion de UN byte lo cace.
        $ctmp = Join-Path $script:AXEData ('updtest_{0}' -f [guid]::NewGuid())
        try {
            New-Item -ItemType Directory -Path $ctmp -Force | Out-Null
            Set-Content (Join-Path $ctmp 'a.txt') -Value 'contenido a' -Encoding UTF8 -NoNewline
            Set-Content (Join-Path $ctmp 'b.txt') -Value 'contenido b' -Encoding UTF8 -NoNewline
            $sumFile = New-AXEChecksums -Dir $ctmp
            $bad = @(Test-AXEChecksums -Dir $ctmp)
            if($bad.Count -ne 0){ [void]$fails.Add("S30: SHA256SUMS recien generado no se verifica a si mismo ($($bad -join '; '))") }
            # Determinismo: regenerar sobre lo mismo da BYTES identicos (lo que permite el guard anti-deriva).
            $first = Get-Content $sumFile -Raw -Encoding UTF8
            [void](New-AXEChecksums -Dir $ctmp)
            if((Get-Content $sumFile -Raw -Encoding UTF8) -ne $first){ [void]$fails.Add('S30: New-AXEChecksums no es determinista (dos pasadas, dos ficheros)') }
            # Un byte distinto => el verificador tiene que cazarlo. Este es el check que importa.
            Set-Content (Join-Path $ctmp 'a.txt') -Value 'contenido A' -Encoding UTF8 -NoNewline
            if(@(Test-AXEChecksums -Dir $ctmp).Count -eq 0){ [void]$fails.Add('S30: un fichero MODIFICADO paso la verificacion de checksum') }
            # Parseo puntual + rechazo de lo que no esta listado.
            $h = Get-AXEChecksumFor $first 'b.txt'
            if($h -notmatch '^[0-9a-f]{64}$'){ [void]$fails.Add("S30: Get-AXEChecksumFor no devolvio un sha256 valido (dio '$h')") }
            if($null -ne (Get-AXEChecksumFor $first 'no-listado.txt')){ [void]$fails.Add('S30: un nombre NO listado en SHA256SUMS devolvio hash') }
        } finally { Remove-Item $ctmp -Recurse -Force -EA SilentlyContinue }

        # (c) Firma: la NEGATIVA es el lado del que depende la seguridad del updater, y es el
        # unico que se puede comprobar sin exigir un cert en el entorno (CI no lo tiene). Se usa
        # un .ps1 recien escrito en temp: sin firma POR CONSTRUCCION, aqui y en la maquina de
        # quien sea. Comprobarlo contra $PSCommandPath daria un resultado distinto segun si el
        # dist local esta firmado o no, o sea un check que no comprueba nada estable.
        $sigTmp = Join-Path ([IO.Path]::GetTempPath()) ('axe_sig_{0}.ps1' -f [guid]::NewGuid())
        try {
            Set-Content -LiteralPath $sigTmp -Value '# sin firma' -Encoding UTF8
            if(Test-AXESignature $sigTmp){ [void]$fails.Add('S30: Test-AXESignature dio true sobre un fichero SIN firmar') }
            $si = Get-AXESignatureInfo $sigTmp
            if($si.Valid){ [void]$fails.Add('S30: Get-AXESignatureInfo marco Valid un fichero sin firmar') }
        } finally { Remove-Item -LiteralPath $sigTmp -Force -EA SilentlyContinue }
        if(Test-AXESignature 'C:\no\existe\jamas.ps1'){ [void]$fails.Add('S30: Test-AXESignature dio true sobre un fichero inexistente') }
        if(Test-AXESignature ''){ [void]$fails.Add('S30: Test-AXESignature dio true sobre una ruta vacia') }
        if((Get-AXESignatureInfo 'C:\no\existe\jamas.ps1').Status -ne 'NotFound'){ [void]$fails.Add('S30: Get-AXESignatureInfo no reporto NotFound sobre una ruta inexistente') }

        # (d) Origen de la descarga: solo https, solo hosts de GitHub, solo este owner/repo.
        $okUrl  = "https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v9.9.9/AXE.ps1"
        if(-not (Test-AXEAssetUrl $okUrl)){ [void]$fails.Add('S30: la URL legitima del repo oficial se rechazo') }
        foreach($mal in @(
            "http://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v1/AXE.ps1"  # sin TLS
            'https://evil.example.com/AXE.ps1'                                                                   # otro dominio
            "https://github.com/otro/repo/releases/download/v1/AXE.ps1"                                          # otro repo
            'https://github.com.evil.example/AXE.ps1'                                                            # host que solo lo parece
            'no-soy-una-url'; ''
        )){
            if(Test-AXEAssetUrl $mal){ [void]$fails.Add("S30: se acepto una URL de descarga que NO es del repo oficial: '$mal'") }
        }

        # (e) Decisiones del updater con un release INYECTADO (sin red). Se ejercen los caminos
        # de rechazo, que ocurren todos antes de la primera descarga.
        $mkRel = {
            param($tag,$assets)
            ConvertFrom-AXEReleaseJson ([pscustomobject]@{
                tag_name=$tag; published_at='2026-01-01T00:00:00Z'; prerelease=$false; assets=$assets })
        }
        $goodAssets = @(
            [pscustomobject]@{ name='AXE.ps1';    size=1; browser_download_url=$okUrl }
            [pscustomobject]@{ name='SHA256SUMS'; size=1; browser_download_url="https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v9.9.9/SHA256SUMS" }
        )
        $vieja = & $mkRel ('v' + $script:AXEVersion) $goodAssets
        if((Invoke-AXEUpdate -Release $vieja).Status -ne 'current'){ [void]$fails.Add('S30: con la MISMA version el updater no dijo "current"') }
        $nueva = & $mkRel 'v999.0.0' $goodAssets
        if((Invoke-AXEUpdate -Release $nueva -Check).Status -ne 'available'){ [void]$fails.Add('S30: -Check con version nueva no dijo "available"') }
        # Sin SHA256SUMS no se instala NADA, aunque el AXE.ps1 venga del repo bueno.
        $sinSums = & $mkRel 'v999.0.0' @($goodAssets[0])
        if((Invoke-AXEUpdate -Release $sinSums).Status -ne 'refused'){ [void]$fails.Add('S30: un release SIN SHA256SUMS no se rechazo') }
        # Asset servido desde fuera del repo oficial: rechazo antes de descargar.
        $urlMala = & $mkRel 'v999.0.0' @(
            [pscustomobject]@{ name='AXE.ps1';    size=1; browser_download_url='https://evil.example.com/AXE.ps1' }
            $goodAssets[1])
        if((Invoke-AXEUpdate -Release $urlMala).Status -ne 'refused'){ [void]$fails.Add('S30: un asset alojado FUERA del repo oficial no se rechazo') }
        # Un release sin tag no es un release: no puede acabar en "estas al dia".
        if($null -ne (ConvertFrom-AXEReleaseJson ([pscustomobject]@{ assets=@() }))){ [void]$fails.Add('S30: un release sin tag_name no devolvio null') }
        if((Invoke-AXEUpdate -Release $null -Check).Status -ne 'error'){ [void]$fails.Add('S30: sin poder consultar la API el updater no dijo "error"') }

        foreach($fn in 'Invoke-AXEUpdate','Get-AXELatestRelease','Test-AXESignature','New-AXEChecksums','New-AXESbom','Test-AXEAssetUrl'){
            if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S30: funcion de la cadena de confianza '$fn' no definida") }
        }
    } catch { [void]$fails.Add("S30: updater/cadena de confianza lanzo: $($_.Exception.Message)") }

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

# --- UPDATER (region 8f, spec 2026-07-24) --------------------------------------------------
# Va ANTES de -List y de cualquier bloque que necesite $script:HW: comprobar actualizaciones no
# depende del hardware ni de admin, y no tiene por que pagar los ~3.7s de CIM. Por eso -Update
# tampoco entra en el gate de carga de HW de arriba.
if($Update){
    Write-Host "== AXE $($script:AXEVersion) - actualizacion =="
    $r = Invoke-AXEUpdate -Check:$Check
    Write-Host ''
    Write-Host $r.Message
    Write-Host ''
    # Exit codes pensados para encadenar desde un script: 0 = nada que hacer o ya hecho,
    # 1 = hay algo que el usuario tiene que resolver a mano, 2 = no se pudo comprobar.
    switch($r.Status){
        'current'   { exit 0 }
        'updated'   { exit 0 }
        'available' { exit 0 }
        'refused'   { exit 1 }
        default     { exit 2 }
    }
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
# --- BENCHMARK "pruebalo en tu PC" (region 8e, spec 2026-07-24) -----------------------
# ORDEN A POSTA: este bloque va ANTES de 'if($Report)'. -Report es un flag compartido y el
# bloque de reporte hace 'exit' incondicional, asi que puesto despues,
# 'AXE -Benchmark -After <id> -Report x.json' habria salido por el camino del reporte A/B
# clasico sin llegar nunca aqui: el usuario pediria un benchmark y recibiria otra cosa.
# Todo el bloque es headless, no muta el sistema y no necesita admin.
if($Benchmark){
    Write-Host '== AXE BENCHMARK - pruebalo en tu PC =='
    $passes = $BenchPasses
    if($passes -lt 3){ $passes = 3 }        # menos de 3 pasadas no da IQR con sentido
    if($passes -gt 25){ $passes = 25 }

    if(-not $After){
        # --- FASE 1: linea base ---
        Write-Host "Midiendo la linea base: $passes pasadas. Tarda ~$([int]($passes*1.5))-$([int]($passes*4)) s."
        Write-Host 'Cierra lo que no estes usando y no toques el equipo mientras mide.'
        $b = Measure-AXEBenchSample -Passes $passes
        $id = Save-AXEBenchBaseline $b
        if(-not $id){ Write-Host '  No pude guardar la linea base (ver log).'; exit 1 }
        Write-Host ''
        foreach($line in (Format-AXEBenchSample $b 'LINEA BASE')){ Write-Host $line }
        Write-Host ''
        Write-Host "Linea base guardada con id: $id"
        Write-Host 'Ahora aplica los tweaks que quieras y REINICIA el equipo. Despues, vuelve y ejecuta:'
        Write-Host "    AXE -Benchmark -After $id"
        Write-Host '(El reinicio no se automatiza a posta: hacerlo esconderia lo que se aplico,'
        Write-Host ' y el valor de esto es que puedas ver y repetir cada paso.)'
        exit 0
    }

    # --- FASE 2: despues + veredicto ---
    $before = Read-AXEBenchBaseline $After
    if(-not $before){
        # No se inventa un 'antes': sin linea base no hay comparacion posible, igual que
        # 'prueba.report' del puente se niega sin baseline.
        Write-Host "  No hay linea base con id '$After' (o el fichero esta corrupto)."
        Write-Host "  Busca en: $script:AXEBenchDir"
        Write-Host '  Empieza una nueva con:  AXE -Benchmark'
        exit 1
    }
    $why = Test-AXEBenchComparable $before
    if($why){
        Write-Host "  $why"
        Write-Host '  Un delta entre maquinas o versiones distintas no mide un cambio: mide otra cosa.'
        exit 1
    }
    # Mismas pasadas y misma duracion de jitter que la fase 1: comparar 7 pasadas contra 3
    # cambiaria el ruido medido y con el el umbral del veredicto.
    Write-Host ("Midiendo el DESPUES con los mismos parametros que la linea base ({0} pasadas)..." -f $before.passes)
    # OJO con el nombre: NO llamar a esta variable '$after'. Los nombres de variable de
    # PowerShell son case-insensitive, asi que '$after' ES el parametro '[string]$After' del
    # param block, que ademas esta TIPADO: asignarle el agregado lo convertiria a su
    # representacion en texto y el veredicto se quedaria sin datos, en silencio. Es la misma
    # familia de bug que la colision $Games/S24 documentada en 00-header.
    $afterSample = Measure-AXEBenchSample -Passes ([int]$before.passes) -JitterMs ([int]$before.jitterMs)
    $verdict = Get-AXEBenchVerdict $before $afterSample
    $rep = New-AXEBenchReport $before $afterSample $verdict
    Write-Host ''
    foreach($line in $rep.Text){ Write-Host $line }
    if($Report){
        $written = Export-AXEBenchReport $rep $Report
        Write-Host ''
        foreach($f in $written){ Write-Host "Escrito: $f" }
        Write-Host 'El .md es el compartible (sin datos personales: modelo de CPU, RAM, vendor de GPU y build).'
    }
    # Salida 1 si alguna metrica EMPEORO de forma concluyente, para poder encadenarlo en scripts.
    # 'ruido' no es fallo: es el resultado honesto mas comun.
    exit ([int](@($verdict | Where-Object Tag -eq 'peor').Count -gt 0))
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
if($Diag){
    # Diagnostico de configuracion (region 10e). NO aplica nada: lo que detecta vive en la BIOS,
    # en los slots de RAM o en Configuracion de Windows, fuera del alcance de un script.
    # Salida 1 si hay algo mal configurado, para poder encadenarlo en scripts.
    $findings = Get-AXEDiagFindings -Facts (Get-AXEDiagFacts)
    foreach($line in (Format-AXEDiag -Findings $findings)){ Write-Host $line }
    exit ([int](@($findings | Where-Object Status -eq 'BAD').Count -gt 0))
}

# --- GPU POR JUEGO (region 10c) -------------------------------------------------------
# Escriben en HKCU, asi que NO piden admin: se pueden correr sin el launcher .bat.
if($GameList){
    Write-Host '== AXE - GPU POR JUEGO =='
    $gpus = Get-AXEGpuList
    Write-Host ("GPUs: {0}" -f (($gpus | Select-Object -Expand Name) -join ' | '))
    if(Test-AXEHybridGpu){
        Write-Host 'Equipo HIBRIDO: forzar la dedicada es el mayor lever de FPS de toda la suite.'
    } else {
        Write-Host 'Una sola GPU: GpuPreference no aplica en este equipo (ganancia por esa via = 0).'
    }
    Write-Host ''
    $k = Get-Item $script:GpuPrefKey -EA SilentlyContinue
    if(-not $k -or $k.GetValueNames().Count -eq 0){
        Write-Host 'Sin entradas: Windows decide la GPU de todo por heuristica.'
        exit 0
    }
    foreach($n in $k.GetValueNames()){
        $st  = Get-AXEGameGpuState $n
        # 'Windows decide' NO es lo mismo que 'GpuPreference=0'. Se distinguen a posta: la
        # clave ausente es el estado de fabrica; el 0 explicito lo escribio alguien (AXE al
        # apagar el ajuste, o el propio usuario en Configuracion).
        $pref = (ConvertFrom-AXEGpuPref $st.Raw)['GpuPreference']
        $gpu  = switch($pref){ '2'{'dGPU'} '1'{'iGPU'} '0'{'delegado (0)'} default{'Windows decide'} }
        "{0,-15} flip={1,-3} fso={2,-3} {3}" -f $gpu,$(if($st.FlipModel){'si'}else{'no'}),$(if($st.NoFSO){'off'}else{'on'}),(Split-Path $n -Leaf) | Write-Host
    }
    exit 0
}
if($OptimizeGame){
    Write-Host '== AXE - OPTIMIZAR JUEGO =='
    # Se resuelve a ruta absoluta: el registro indexa por ruta COMPLETA, asi que una relativa
    # crearia una entrada que Windows no va a mirar nunca (fallo silencioso).
    $full = try { (Resolve-Path -LiteralPath $OptimizeGame -EA Stop).Path } catch { $OptimizeGame }
    Write-Host "Objetivo: $full"
    foreach($line in (Optimize-AXEGame -Exe $full -NoFSO:$NoFSO)){ Write-Host "  $line" }
    Write-Host ''
    Write-Host "Deshacer: -RevertGame `"$full`""
    exit 0
}
if($Fps){
    Write-Host '== AXE - FPS REALES (PresentMon) =='
    if(-not (Get-AXEPresentMon)){
        # Se sale sin medir en vez de ensenar ceros: un informe de FPS vacio presentado como
        # medicion es peor que no medir.
        Write-Host '  PresentMon no encontrado.'
        Write-Host '  Bajalo de https://github.com/GameTechDev/PresentMon/releases'
        Write-Host '  y deja PresentMon.exe junto a AXE (o define AXE_PRESENTMON).'
        Write-Host '  AXE no lo descarga solo: bajar y ejecutar binarios de internet no es cosa de una herramienta que corre como admin.'
        exit 1
    }
    if(-not $FpsCompare){
        Write-Host "Capturando $FpsSeconds s de '$Fps'..."
        foreach($l in (Format-AXEFpsStats (Measure-AXEFps -ProcessName $Fps -Seconds $FpsSeconds) 'Captura')){ Write-Host $l }
        exit 0
    }
    # Modo comparacion: dos capturas con una pausa manual en medio. La pausa es a posta y NO se
    # automatiza: entre una y otra hay que aplicar el cambio Y volver a la MISMA escena, y eso
    # solo lo puede hacer una persona. Automatizarlo produciria comparaciones de escenas
    # distintas con pinta de rigor, que es peor que no medir.
    #   OJO: este modo BLOQUEA en Read-Host. Solo se llega con -Fps explicito, asi que ni el
    # gate de build.ps1 ni la GUI lo tocan; no meterlo nunca en un runspace de fondo.
    Write-Host "1/2 - captura ANTES ($FpsSeconds s). Ponte en la escena que vas a repetir."
    Read-Host '     Enter cuando estes listo' | Out-Null
    $b = Measure-AXEFps -ProcessName $Fps -Seconds $FpsSeconds
    foreach($l in (Format-AXEFpsStats $b 'ANTES')){ Write-Host $l }
    if(-not $b.Ok){ exit 1 }
    Write-Host ''
    Write-Host '2/2 - aplica el cambio, vuelve a la MISMA escena y repite el mismo recorrido.'
    Read-Host '     Enter cuando estes listo' | Out-Null
    $a = Measure-AXEFps -ProcessName $Fps -Seconds $FpsSeconds
    foreach($l in (Format-AXEFpsStats $a 'DESPUES')){ Write-Host $l }
    if(-not $a.Ok){ exit 1 }
    $v = Get-AXEFpsVerdict -Before $b -After $a
    Write-Host ''
    Write-Host '-- VEREDICTO --'
    Write-Host $(if($v.Conclusive){ "  CONCLUYENTE: $($v.Reason)" } else { "  NO CONCLUYENTE: $($v.Reason)" })
    if($v.Warning){ Write-Host "  AVISO: $($v.Warning)" }
    exit 0
}
if($RevertGame){
    Write-Host '== AXE - DESHACER JUEGO =='
    $full = try { (Resolve-Path -LiteralPath $RevertGame -EA Stop).Path } catch { $RevertGame }
    $n = Revert-AXEGameGpu $full
    if($n -eq 0){
        # No se inventa un estado: si AXE nunca toco ese exe, no hay original que restaurar.
        Write-Host "  Sin captura previa para '$full': AXE no lo ha tocado, no revierto nada."
        Write-Host '  (Escribir un default aqui seria dejarte un estado que quiza nunca tuviste.)'
    } else {
        Write-Host "  Restauradas $n clave(s) al estado exacto que habia antes."
    }
    exit 0
}

# --- DAEMON DE SESION DE JUEGO (region 12b, spec 2026-07-20) --------------------------
# Congela el fondo mientras el juego corre y descongela al cerrar el juego (o AXE). El handle
# del job vive en ESTE proceso: si AXE muere, el kernel descongela solo. Recomendado como admin
# (via AXE.bat) para poder tocar procesos del sistema; sin admin degrada a lo que el usuario posee.
if($Session){
    Write-Host '== AXE - SESION DE JUEGO (congela el fondo) =='
    $sess = Start-AXESession -GameName $Session
    foreach($line in (Format-AXESession $sess)){ Write-Host $line }
    if(-not $sess.Ok){ exit 1 }
    Write-Host ''
    Write-Host 'Sesion activa. Cierra el juego o pulsa Ctrl+C para descongelar el fondo.'
    try {
        Watch-AXESession -Session $sess -PollMs $SessionPoll
    } finally {
        # Salida normal (juego cerrado) o Ctrl+C: descongela y restaura prioridades. Si esto no
        # llega a correr (kill duro de AXE), el kernel descongela igual al cerrarse el handle.
        Stop-AXESession $sess
        Write-Host 'Sesion cerrada: fondo descongelado y prioridades restauradas.'
    }
    exit 0
}

