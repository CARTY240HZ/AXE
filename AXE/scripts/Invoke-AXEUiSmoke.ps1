# Smoke E2E de la ventana REAL: abre dist\AXE.ps1 con WebView2 en depuracion remota (CDP) y la
# conduce desde fuera. Existe porque el harness de build (AXE_WEBUI_TEST=1) sale ANTES de cargar la
# pagina: nunca ejecuto el JS real, y la GUI podia colgarse con todos los tests en verde.
#   Comprueba: sin errores JS al cargar; cada comando de solo lectura responde por el puente real;
#   la ventana sigue respondiendo MIENTRAS el worker hace un barrido; captura PNG de cada vista.
#   No aplica ni revierte nada (esos van por el broker con UAC: prueba manual).
# Uso: powershell -NoProfile -File .\scripts\Invoke-AXEUiSmoke.ps1 [-OutDir <carpeta PNG>]
# Sale con 0 si todo OK, 1 si algo fallo. Abre una ventana visible unos segundos.
# -WriteFlows: ademas aplica y revierte UN tweak inocuo (sys_bing, HKCU, sin reinicio) por el
# broker REAL y verifica en el registro que queda exactamente como estaba. Opt-in: toca el sistema.
# Sin UAC solo si el shell ya esta elevado; si no, saltara el dialogo (hay que aceptarlo a mano).
param([string]$OutDir = (Join-Path $PSScriptRoot '..\dist\ui-smoke'), [int]$Port = 9333, [switch]$WriteFlows)
$ErrorActionPreference = 'Stop'
$dist = Join-Path $PSScriptRoot '..\dist\AXE.ps1'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$env:AXE_WEBVIEW_DEBUG_PORT = "$Port"
$proc = Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$dist`"") -PassThru
Remove-Item Env:\AXE_WEBVIEW_DEBUG_PORT

$ws = $null; $script:id = 0; $script:events = New-Object System.Collections.ArrayList
function Send-Cdp([string]$Method, [hashtable]$Params = @{}, [int]$TimeoutSec = 180){
    $script:id++; $myId = $script:id
    $msg = @{ id = $myId; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $ws.SendAsync([ArraySegment[byte]]$bytes, 'Text', $true, [Threading.CancellationToken]::None).Wait()
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while((Get-Date) -lt $deadline){
        $sb = New-Object Text.StringBuilder; $buf = New-Object byte[] 65536
        do {
            $t = $ws.ReceiveAsync([ArraySegment[byte]]$buf, [Threading.CancellationToken]::None)
            if(-not $t.Wait(($deadline - (Get-Date)).TotalMilliseconds)){ throw "CDP timeout: $Method" }
            [void]$sb.Append([Text.Encoding]::UTF8.GetString($buf, 0, $t.Result.Count))
        } while(-not $t.Result.EndOfMessage)
        $r = $sb.ToString() | ConvertFrom-Json
        if($r.id -eq $myId){ if($r.error){ throw "CDP $Method : $($r.error.message)" }; return $r.result }
        [void]$script:events.Add($r)
    }
    throw "CDP timeout: $Method"
}
function Invoke-Js([string]$Expr, [int]$TimeoutSec = 180){
    $r = Send-Cdp 'Runtime.evaluate' @{ expression = $Expr; awaitPromise = $true; returnByValue = $true } $TimeoutSec
    if($r.exceptionDetails){ throw "JS: $($r.exceptionDetails.exception.description)" }
    $r.result.value
}
function Save-Shot([string]$Name){
    $r = Send-Cdp 'Page.captureScreenshot' @{ format = 'png' }
    [IO.File]::WriteAllBytes((Join-Path $OutDir "$Name.png"), [Convert]::FromBase64String($r.data))
}

$fails = New-Object System.Collections.ArrayList
try {
    # 1. Conectar al target de la pagina (WebView2 tarda en arrancar).
    $target = $null
    foreach($i in 1..60){
        # Solo cuando YA navego a la app: conectar en about:blank y recargar cancelaba la navegacion.
        try { $target = (Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2) | Where-Object { $_.type -eq 'page' -and $_.url -like 'https://axe.local/*' } | Select-Object -First 1 } catch {}
        if($target){ break }; Start-Sleep -Milliseconds 500
    }
    if(-not $target){ throw "WebView2 no expuso CDP en el puerto $Port (la ventana no llego a cargar)" }
    $ws = New-Object Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait()

    # 2. Recargar con Runtime habilitado para ver TODAS las excepciones JS de la carga.
    [void](Send-Cdp 'Runtime.enable'); [void](Send-Cdp 'Page.enable')
    # navigate y no reload: /json anuncia la URL de destino ANTES de que la navegacion confirme, y un
    # reload en ese instante recargaba about:blank.
    [void](Send-Cdp 'Page.navigate' @{ url = $target.url })
    foreach($i in 1..120){ if((Invoke-Js 'document.readyState') -eq 'complete' -and (Invoke-Js '!!window.AXE')){ break }; Start-Sleep -Milliseconds 250 }
    Start-Sleep -Seconds 2
    if(-not (Invoke-Js '!!window.AXE')){
        "URL: $(Invoke-Js 'location.href')"
        "scripts: $(Invoke-Js 'JSON.stringify([...document.scripts].map(s=>s.src||"inline"))')"
        foreach($e in $script:events){ "evento: $($e.method) $(($e.params | ConvertTo-Json -Depth 6 -Compress).Substring(0, [math]::Min(400, ($e.params | ConvertTo-Json -Depth 6 -Compress).Length)))" }
        throw 'window.AXE no existe tras cargar: bridge.js no se ejecuto'
    }
    foreach($e in $script:events){
        if($e.method -eq 'Runtime.exceptionThrown'){ [void]$fails.Add("excepcion JS al cargar: $($e.params.exceptionDetails.exception.description)") }
        if($e.method -eq 'Runtime.consoleAPICalled' -and $e.params.type -eq 'error'){ [void]$fails.Add("console.error al cargar: $(@($e.params.args | ForEach-Object { $_.value }) -join ' ')") }
    }

    # 3. Cada comando de SOLO LECTURA por el puente real (UI -> PS -> worker -> PS -> UI).
    $cmds = 'app.info','hw.get','catalog.tiers','measure.score','tweaks.list','diag.get','net.probe','advisor.get','session.detect','session.status','session.preview'
    $js = "(async()=>{const o=[];for(const c of $(ConvertTo-Json @($cmds) -Compress)){const t=performance.now();try{await AXE.call(c,{});o.push({c,ok:true,ms:Math.round(performance.now()-t)})}catch(e){o.push({c,ok:false,ms:Math.round(performance.now()-t),err:e.message})}}return JSON.stringify(o)})()"
    foreach($r in (Invoke-Js $js 600 | ConvertFrom-Json)){
        '{0,-18} {1,6} ms  {2}' -f $r.c, $r.ms, $(if($r.ok){'ok'}else{"ERROR: $($r.err)"})
        if(-not $r.ok){ [void]$fails.Add("$($r.c): $($r.err)") }
    }

    # 4. La ventana responde MIENTRAS el worker trabaja: se lanza el barrido (decenas de s) y en
    #    paralelo se mide cuanto tarda app.info (hilo de UI). Antes: bloqueado todo el barrido.
    $js = "(async()=>{const s=AXE.call('measure.timerSweep',{},180000).then(()=>'ok',e=>'err:'+e.message);await new Promise(r=>setTimeout(r,1500));const t=performance.now();await AXE.call('app.info',{});const ui=Math.round(performance.now()-t);return JSON.stringify({ui,sweep:await s})})()"
    $r = Invoke-Js $js 240 | ConvertFrom-Json
    "UI durante barrido: app.info en $($r.ui) ms; barrido: $($r.sweep)"
    if($r.ui -gt 1000){ [void]$fails.Add("la UI tardo $($r.ui) ms en responder durante el barrido (bloqueada)") }
    # 'no obtuvo datos utiles' = Windows 11 no concede la resolucion a una ventana tapada: es el
    # mensaje honesto esperado, no un fallo. Cualquier OTRO error si lo es.
    if($r.sweep -ne 'ok' -and $r.sweep -notmatch 'no obtuvo datos utiles'){ [void]$fails.Add("barrido: $($r.sweep)") }

    # 4b. Escritura por el broker real (opt-in). Solo si el tweak NO estaba aplicado: nunca se
    #     altera un estado que el usuario eligio.
    if($WriteFlows){
        $key = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search'; $name = 'BingSearchEnabled'
        $read = { $p = Get-ItemProperty -Path $key -Name $name -EA SilentlyContinue; if($p){ $p.$name } else { '<ausente>' } }
        $orig = & $read
        if($orig -eq 0){ 'escritura: sys_bing ya aplicado por el usuario, se salta (no se toca su estado)' }
        else {
            $a = Invoke-Js "AXE.call('tweaks.apply',{id:'sys_bing'},90000).then(d=>JSON.stringify({ok:true,d}),e=>JSON.stringify({ok:false,err:e.message}))" 120 | ConvertFrom-Json
            $mid = & $read
            $r = Invoke-Js "AXE.call('tweaks.revert',{id:'sys_bing'},90000).then(d=>JSON.stringify({ok:true,d}),e=>JSON.stringify({ok:false,err:e.message}))" 120 | ConvertFrom-Json
            $end = & $read
            "escritura: apply ok=$($a.ok) applied=$($a.d.applied) reg=$mid | revert ok=$($r.ok) applied=$($r.d.applied) reg=$end (original=$orig)"
            if(-not $a.ok -or -not $a.d.applied -or $mid -ne 0){ [void]$fails.Add("tweaks.apply por el broker: $($a.err) applied=$($a.d.applied) reg=$mid") }
            if(-not $r.ok -or $r.d.applied -or "$end" -ne "$orig"){ [void]$fails.Add("tweaks.revert no dejo el registro como estaba: $($r.err) reg=$end original=$orig") }
        }
    }

    # 4c. CLIC en cada boton de solo medida, como un usuario: navega a la vista, pulsa, espera a
    #     que el boton deje de estar 'busy' y lee lo que pinto la interfaz. Falla si pinta un error
    #     o si se queda colgado. Cubre el cableado JS (handler -> AXE.call -> render), que las
    #     llamadas directas de arriba no ven.
    $clicks = @(
        @('telemetria','btnSweep','sweepOut'), @('telemetria','btnNet','netOut'),
        @('prueba','btnBaseline','pruebaBar'), @('prueba','btnReport','reportOut'),
        @('prueba','btnBenchBase','benchOut'), @('prueba','btnBenchAfter','benchOut'),
        @('prueba','btnDiag','diagList'), @('prueba','btnAdvice','adviceList'),
        @('sesion','btnSessDetect','sessBar'), @('sesion','btnSessPreview','sessBar')
    )
    foreach($k in $clicks){
        $js = "(async()=>{document.querySelector('.nav-item[data-view=`"$($k[0])`"]').click();await new Promise(r=>setTimeout(r,300));const b=document.getElementById('$($k[1])');if(b.disabled)return JSON.stringify({err:'boton desactivado'});const t=performance.now();b.click();await new Promise(r=>setTimeout(r,200));while((b.classList.contains('busy')||b.disabled)&&performance.now()-t<180000)await new Promise(r=>setTimeout(r,250));return JSON.stringify({ms:Math.round(performance.now()-t),busy:b.classList.contains('busy'),txt:(document.getElementById('$($k[2])').textContent||'').trim().slice(0,160)})})()"
        $r = Invoke-Js $js 240 | ConvertFrom-Json
        $txt = ($r.txt -replace '\s+',' ')
        '{0,-15} {1,6} ms  {2}' -f $k[1], $r.ms, $(if($r.err){"ERROR: $($r.err)"}else{$txt.Substring(0,[math]::Min(90,$txt.Length))})
        if($r.err -or $r.busy -or $txt -match '^(No pude|No se pudo)' -or [string]::IsNullOrWhiteSpace($txt)){
            # 'no obtuvo datos utiles' del barrido = ventana tapada (Windows), no un fallo de AXE.
            if($txt -notmatch 'no obtuvo datos utiles'){ [void]$fails.Add("clic $($k[1]): $($r.err)$txt") }
        }
    }

    # 5. Captura de cada vista del router.
    $views = Invoke-Js "JSON.stringify([...document.querySelectorAll('.nav-item[data-view]')].map(n=>n.dataset.view))" | ConvertFrom-Json
    foreach($v in $views){
        [void](Invoke-Js "document.querySelector('.nav-item[data-view=`"$v`"]').click()")
        Start-Sleep -Milliseconds 800
        Save-Shot $v
    }
    # 6. Tamanos/escalados reales de usuario: portatil pequeno, 1366x768, 125% y 150% de Windows.
    #    Captura de cada vista + deteccion de desbordamiento horizontal (lo que "se rompe" primero).
    $sizes = @(@{w=900;h=600;s=1}, @{w=1366;h=768;s=1}, @{w=1280;h=720;s=1.25}, @{w=1280;h=800;s=1.5})
    foreach($z in $sizes){
        [void](Send-Cdp 'Emulation.setDeviceMetricsOverride' @{ width=$z.w; height=$z.h; deviceScaleFactor=$z.s; mobile=$false })
        foreach($v in $views){
            [void](Invoke-Js "document.querySelector('.nav-item[data-view=`"$v`"]').click()")
            Start-Sleep -Milliseconds 500
            $ov = Invoke-Js "JSON.stringify([...document.querySelectorAll('body *')].filter(e=>{const r=e.getBoundingClientRect();return r.width>0&&r.right>innerWidth+1&&getComputedStyle(e).position!=='fixed'}).slice(0,3).map(e=>(e.id||e.className||e.tagName)+'@'+Math.round(e.getBoundingClientRect().right)))"
            if($ov -ne '[]'){ [void]$fails.Add("desborda en horizontal a $($z.w)x$($z.h)@$($z.s) en '$v': $ov") }
            Save-Shot ("{0}_{1}x{2}@{3}" -f $v,$z.w,$z.h,$z.s)
        }
    }
    [void](Send-Cdp 'Emulation.clearDeviceMetricsOverride')
    "Capturas en: $((Resolve-Path $OutDir).Path)"
} catch {
    [void]$fails.Add("smoke abortado: $($_.Exception.Message)")
} finally {
    if($ws){ try { $ws.Dispose() } catch {} }
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
}
if($fails.Count){ ''; 'FALLOS:'; $fails | ForEach-Object { "  - $_" }; exit 1 }
''; 'UI SMOKE OK'; exit 0
