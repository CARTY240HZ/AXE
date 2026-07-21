# =====================================================
# REGION 14 - PUENTE RPC (JS <-> PS). SUPERFICIE DE ATAQUE.
# =====================================================
# Regla dura: lista blanca cerrada. cmd fuera de la lista => rechazo. Nunca eval del payload.
# Cargar este modulo SOLO define funciones y el mapa; nada se ejecuta hasta Register-AXEBridge
# (lo llama 47-webhost en el init del control). Cada cmd mapea a una funcion YA EXISTENTE del
# motor (1-45); aqui no se anade logica de negocio.

# Mapa cerrado: cmd -> scriptblock($args) que devuelve el 'data' (o lanza).
# Cada entrada llama SOLO a funciones ya existentes del motor (1-45). Sin logica de negocio nueva:
# aqui solo se re-empaqueta a un DTO plano y JSON-seguro (nulls en vez de 'n/a' donde el front
# decide como pintar). La honestidad del motor se preserva: si algo no se midio, viaja null.
$script:AXEBridgeMap = @{
    'hw.get' = { param($a)
        if(-not $script:HW){ $script:HW = Get-AXEHardware }
        $script:HW
    }

    # Identidad de la app: version (00-header, la fija build.ps1) + tamano del catalogo.
    # El front la usa para el rotulo del rail; los assets estaticos NO pasan por el tokenizador
    # de build, asi que la version tiene que llegar por el puente, no incrustada en el HTML.
    'app.info' = { param($a)
        [pscustomobject]@{
            version = [string]$script:AXEVersion
            tweaks  = [int]($script:CAT | Measure-Object).Count
        }
    }

    # Medicion real (timer + jitter + cobertura). Get-AXESnapshot corre el busy-loop de jitter
    # (~1s) en ESTE hilo (UI); no congela el render (WebView2 es out-of-process) pero si retrasa
    # otras respuestas ~1s. Fase 5 lo mueve a un runspace de fondo. DTO plano para el gauge.
    'measure.score' = { param($a)
        $snap = Get-AXESnapshot
        $sc   = Get-AXEScore $snap
        $timerMs = $null; if($snap.Timer  -isnot [string]){ $timerMs = $snap.Timer.CurrentMs }
        $p999 = $null; $jMean = $null
        if($snap.Jitter -isnot [string]){ $p999 = $snap.Jitter.P999Ms; $jMean = $snap.Jitter.MeanMs }
        $onN = $null; $appN = $null
        if($snap.TweaksApplicable -isnot [string]){ $onN = [int]$snap.TweaksOn; $appN = [int]$snap.TweaksApplicable }
        [pscustomobject]@{
            total      = [int]$sc.Total
            timer      = $sc.Timer      # int 0-30 o 'n/a'
            jitter     = $sc.Jitter     # int 0-35 o 'n/a'
            coverage   = $sc.Coverage   # int 0-25 o 'n/a'
            idle       = $sc.Idle
            timerMs    = $timerMs       # resolucion instantanea (ms) o null
            jitterP999 = $p999          # P99.9 (ms) o null
            jitterMean = $jMean
            on         = $onN           # tweaks Tier0/1 activos o null
            app        = $appN          # tweaks Tier0/1 aplicables o null
            ts         = $snap.Timestamp
            breakdown  = $sc.Breakdown  # texto multilinea, la 'receta'
        }
    }

    # Metadatos del catalogo: total por tier. Barato y real (no lee registro, no aplica nada).
    # El conteo de ACTIVOS por tier (Test-TweakSafe por tweak) llega en Fase 6 (Optimizar).
    'catalog.tiers' = { param($a)
        if(-not $script:CAT){ return @() }
        @($script:CAT | Group-Object Tier | Sort-Object { [int]$_.Name } | ForEach-Object {
            [pscustomobject]@{ tier = [int]$_.Name; total = [int]$_.Count }
        })
    }
}

function Invoke-AXEBridgeCmd {
    param([string]$cmd,[hashtable]$cmdArgs)
    $fn = $script:AXEBridgeMap[$cmd]
    if(-not $fn){ return [pscustomobject]@{ ok=$false; data=$null; err="cmd desconocido: $cmd" } }
    try {
        $data = & $fn $cmdArgs
        return [pscustomobject]@{ ok=$true; data=$data; err='' }
    } catch {
        Write-AXELog "Puente: $cmd lanzo: $($_.Exception.Message)" 'ERR'
        return [pscustomobject]@{ ok=$false; data=$null; err=$_.Exception.Message }
    }
}

function Register-AXEBridge($core){
    # JS -> PS: cada mensaje es {id, cmd, args}. Se responde por ExecuteScriptAsync(__axeReply).
    $core.add_WebMessageReceived({
        param($s,$e)
        $reqId = -1
        try {
            $msg = $e.WebMessageAsJson | ConvertFrom-Json
            $reqId = [int]$msg.id
            # Diagnostico (AXE_WEBUI_DEBUG=1): corre en el hilo UI (con runspace) => Write-AXELog
            # funciona. Prueba que el postMessage del navegador llega al puente (JS->PS).
            if($env:AXE_WEBUI_DEBUG -eq '1'){ Write-AXELog "Puente RX id=$reqId cmd=$($msg.cmd)" 'INFO' }
            $argsHt = @{}
            if($msg.args){ $msg.args.PSObject.Properties | ForEach-Object { $argsHt[$_.Name] = $_.Value } }
            $res = Invoke-AXEBridgeCmd $msg.cmd $argsHt
        } catch {
            $res = [pscustomobject]@{ ok=$false; data=$null; err="payload invalido: $($_.Exception.Message)" }
        }
        $json = ($res | ConvertTo-Json -Depth 8 -Compress)
        # __axeReply(id, jsonString): el JSON viaja como argumento string. ConvertTo-Json del string
        # lo envuelve en comillas escapadas => JSON.parse en JS lo desdobla, sin inyeccion de comillas.
        $js = 'window.__axeReply(' + $reqId + ', ' + ($json | ConvertTo-Json) + ')'
        [void]$s.ExecuteScriptAsync($js)
    })

    # PS -> JS: telemetria REAL (Fase 5). Un runspace PRODUCTOR muestrea CPU/RAM (CIM barato) y
    # jitter (busy-loop nativo corto) y escribe en un buffer SINCRONIZADO; el DispatcherTimer (hilo
    # UI) SOLO lee ese buffer y lo empuja por PostWebMessageAsJson. Asi el busy-loop de jitter nunca
    # corre en el hilo UI (no congela la ventana). [AXE.Native] se compila con Add-Type en el hilo
    # principal al cargar el motor => visible en este runspace (mismo AppDomain).
    # Coste honesto: el muestreo de jitter es ~100ms/1s (~10% de un nucleo en el hilo productor)
    # mientras la ventana este abierta; es el precio de un osciloscopio de latencia REAL, no simulado.
    $script:TelemBuf = [hashtable]::Synchronized(@{ cpu=$null; ram=$null; jitterUs=$null; jitterMeanUs=$null; ts=$null; seq=0 })
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $producer = [powershell]::Create(); $producer.Runspace = $rs
        [void]$producer.AddScript({
            param($BUF)
            while($true){
                $ramPct = $null
                try {
                    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                    if($os.TotalVisibleMemorySize -gt 0){
                        $ramPct = [math]::Round(100.0 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize, 1)
                    }
                } catch {}
                $cpuPct = $null
                try {
                    $c = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
                    if($null -ne $c){ $cpuPct = [double]$c }
                } catch {}
                $jUs = $null; $jMeanUs = $null
                try {
                    $r = [AXE.Native]::SampleJitter(100)   # 100ms -> P99.9 y media, en ms
                    if($r){ $jUs = [math]::Round($r[3] * 1000, 1); $jMeanUs = [math]::Round($r[1] * 1000, 1) }  # ms -> us
                } catch {}
                $BUF.cpu = $cpuPct; $BUF.ram = $ramPct; $BUF.jitterUs = $jUs; $BUF.jitterMeanUs = $jMeanUs
                $BUF.ts = (Get-Date).ToString('HH:mm:ss'); $BUF.seq = [int]$BUF.seq + 1
                Start-Sleep -Milliseconds 850
            }
        })
        [void]$producer.AddArgument($script:TelemBuf)
        $script:TelemRS = $rs; $script:TelemPS = $producer
        $script:TelemHandle = $producer.BeginInvoke()
    } catch { Write-AXELog "Telemetria: runspace productor no arranco: $($_.Exception.Message)" 'ERR' }

    $script:TelemTick = 0
    $script:TelemetryTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:TelemetryTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
    $script:TelemetryTimer.Add_Tick({
        try {
            $script:TelemTick++
            $b = $script:TelemBuf
            $payload = [pscustomobject]@{
                evt  = 'telemetry'
                data = [pscustomobject]@{
                    ts           = $(if($b.ts){ $b.ts } else { (Get-Date).ToString('HH:mm:ss') })
                    uptimeS      = [int]([Environment]::TickCount64 / 1000)
                    cpu          = $b.cpu
                    ram          = $b.ram
                    jitterUs     = $b.jitterUs
                    jitterMeanUs = $b.jitterMeanUs
                }
            }
            $script:Web.CoreWebView2.PostWebMessageAsJson(($payload | ConvertTo-Json -Depth 6 -Compress))
            if($env:AXE_WEBUI_DEBUG -eq '1' -and $script:TelemTick -le 3){ Write-AXELog "Telemetria TX tick=$($script:TelemTick) cpu=$($b.cpu) jUs=$($b.jitterUs)" 'INFO' }
        } catch { if($env:AXE_WEBUI_DEBUG -eq '1'){ Write-AXELog "Telemetria TX fallo: $($_.Exception.Message)" 'ERR' } }
    })
    $script:TelemetryTimer.Start()
}
