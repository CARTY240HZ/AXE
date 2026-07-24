# =====================================================
# REGION 8e - BENCHMARK "Pruebalo en tu PC" (subproyecto C) - spec 2026-07-24
# =====================================================
# Prueba MEDIBLE y compartible del efecto real de AXE en la maquina del usuario. El
# diferenciador frente a hone.gg / atlaspro / deltapro: ellos ensenan un "score" fabricado;
# aqui sale el delta real CON su intervalo de ruido, y cuando el cambio no supera ese ruido
# el veredicto es 'ruido', no "mejora".
#
# Dos fases con humano en medio (spec §3), a posta:
#   AXE -Benchmark              -> mide, guarda AXE/bench/<id>.json, dice como seguir
#   [ el usuario aplica lo que quiera y REINICIA - fuera del alcance del script ]
#   AXE -Benchmark -After <id>  -> mide, compara, veredicto por metrica, reporte
# NO hay auto-resume por RunOnce: esconderia lo que se aplico y es fragil (elevacion, timing,
# anti-cheat). Misma politica que -FpsCompare, que tampoco automatiza la pausa humana.
#
# Reparto igual que el resto del motor: lo PURO (agregacion y veredicto) se testea sin
# hardware; lo que mide reusa 32-measure.ps1 sin duplicar logica. Carga despues de 40-session
# y antes de 45-cli, que es quien despacha -Benchmark.

# Store de baselines. Deriva de $script:AXEData (05-core) para que dist/ y src/ tengan cada
# uno el suyo. Fallback a TEMP para cuando el modulo se dot-sourcea suelto (Pester unitario);
# los tests lo sobreescriben con un directorio temporal, igual que S12 con $script:ProfilesBak.
$script:AXEBenchDir = Join-Path $(if($script:AXEData){ $script:AXEData } else { Join-Path ([IO.Path]::GetTempPath()) 'AXE' }) 'bench'

# Catalogo de metricas del benchmark. UNA sola fuente para la direccion "buena": si el
# veredicto y el reporte tuvieran cada uno la suya, un dia dirian cosas distintas del mismo
# numero (que es exactamente lo que Format-AXETimerSweep evita viviendo en el motor).
#   DPC no esta: no hay API userland honesta para medirlo, y el P99.9 de jitter es el proxy.
#   Asi se etiqueta en el reporte, misma postura que el resto del motor.
$script:AXEBenchMetrics = @(
    [pscustomobject]@{ Key='jitterP999Ms'; Label='Jitter P99.9'; Unit='ms'; Digits=3; Better='down'
                       Note='proxy de latencia; no atribuible a un driver concreto' }
    [pscustomobject]@{ Key='jitterMeanMs'; Label='Jitter medio'; Unit='ms'; Digits=4; Better='down'
                       Note='' }
    [pscustomobject]@{ Key='timerMs';      Label='Timer';        Unit='ms'; Digits=3; Better='down'
                       Note='en build 19041+ es ambiental: lo fija la app en primer plano, no la config' }
    [pscustomobject]@{ Key='score';        Label='AXE Score';    Unit='';   Digits=1; Better='up'
                       Note='0-100, compuesto por el motor' }
)

function Format-AXEBenchNum {
    # Invariante A POSTA. Con la cultura del sistema el mismo dato sale '0,420' en es-ES y
    # '0.420' en en-US: el Markdown "compartible" dejaria de ser comparable entre usuarios y
    # de parsearse igual. Mismo motivo por el que Measure-AXETimerSweep no castea [double] el
    # nombre de un Group-Object. n/a nunca es 0: si no se pudo medir, se dice.
    param($v,[int]$Digits=3)
    if($null -eq $v){ return 'n/a' }
    [string]::Format([cultureinfo]::InvariantCulture, ('{0:F' + $Digits + '}'), [double]$v)
}

function Format-AXEBenchTs {
    # Normaliza una marca de tiempo a ISO-8601 UTC, venga como sea.
    #   POR QUE EXISTE: ConvertFrom-Json convierte una cadena ISO en [datetime], asi que el
    # 'antes' recuperado del disco y el 'despues' recien medido llegan con TIPOS distintos.
    # Medido en la primera ejecucion real: el mismo reporte imprimia
    #   Antes   : 24/07/2026 13:36:23        <- [datetime] renderizado con la cultura local
    #   Despues : 2026-07-24T13:37:07.0054975Z
    # o sea dos formatos para el mismo campo, y un .md "compartible" con el formato de fecha
    # de cada pais. Un reporte que se comparte no puede depender de la configuracion regional.
    param($ts)
    if($null -eq $ts){ return 'n/a' }
    if($ts -is [datetime]){ return $ts.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture) }
    $d = [datetime]::MinValue
    if([datetime]::TryParse([string]$ts,[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$d)){
        return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture)
    }
    [string]$ts
}

function Get-AXEBenchPercentile {
    # Percentil con interpolacion lineal sobre la serie YA ORDENADA. Pura.
    param([object[]]$Sorted,[double]$P)
    $n = @($Sorted).Count
    if($n -eq 0){ return $null }
    if($n -eq 1){ return [double]$Sorted[0] }
    $idx = $P * ($n - 1)
    $lo  = [int][math]::Floor($idx)
    $hi  = [int][math]::Ceiling($idx)
    if($lo -eq $hi){ return [double]$Sorted[$lo] }
    $f = $idx - $lo
    [double]$Sorted[$lo] + $f * ([double]$Sorted[$hi] - [double]$Sorted[$lo])
}

function Get-AXEBenchStat {
    # Mediana + IQR de una serie de pasadas. PURA.
    #   Mediana y no media: una sola pasada con un stall del scheduler desplaza la media y no
    #   la mediana, y en un benchmark de latencia esos stalls existen siempre.
    #   IQR (cuartil3 - cuartil1) = ancho del 50% central = el RUIDO MEDIDO de esta maquina.
    #   Es lo que despues tiene que superar un delta para llamarse mejora. El ruido se MIDE,
    #   no se asume: la leccion del timer-flakiness (2026-07-19) es justo esa.
    param([object[]]$Values)
    $v = @(foreach($x in $Values){ if($null -ne $x){ [double]$x } })
    if($v.Count -eq 0){ return $null }
    $s = @($v | Sort-Object)
    [pscustomobject]@{
        median = [math]::Round((Get-AXEBenchPercentile -Sorted $s -P 0.50),4)
        iqr    = [math]::Round(((Get-AXEBenchPercentile -Sorted $s -P 0.75) - (Get-AXEBenchPercentile -Sorted $s -P 0.25)),4)
        passes = $v.Count
    }
}

function Get-AXEBenchHwHash {
    # PURA. Hash de identidad = para NEGARSE a comparar dos maquinas (o dos builds) distintas,
    # no para identificar a nadie: entra solo modelo generico de CPU, RAM, vendor de GPU,
    # build de Windows y version de AXE. Ni serial, ni usuario, ni MAC, ni IP.
    #   El formateo va en cultura invariante: si no, la misma maquina daria un hash en es-ES
    # ('31,9') y otro en en-US ('31.9') y toda comparacion abortaria por "otra maquina".
    param([string]$Cpu,[double]$RamGB,[string]$GpuVendor,[int]$Build,[string]$Version)
    $s = [string]::Format([cultureinfo]::InvariantCulture,'{0}|{1:F1}|{2}|{3}|{4}',$Cpu,$RamGB,$GpuVendor,$Build,$Version)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
        'sha256:' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-AXEBenchIdentity {
    # Impura (lee hardware). Devuelve {axeVersion;hw;hwHash}. Todo campo que no se pueda leer
    # viaja con un valor generico explicito, nunca inventado: el hash solo tiene que ser
    # ESTABLE en la misma maquina, no unico en el mundo.
    $hw = $script:HW
    if(-not $hw){ try { $hw = Get-AXEHardware } catch { $hw = $null } }

    $vendor = 'desconocido'
    try {
        $vs = New-Object System.Collections.ArrayList
        foreach($n in @(Get-AXEGpuList | ForEach-Object Name)){
            $v = switch -Regex ($n) {
                'NVIDIA|GeForce|Quadro' { 'NVIDIA'; break }
                'AMD|Radeon|ATI'        { 'AMD';    break }
                'Intel'                 { 'Intel';  break }
                default                 { $null }
            }
            if($v -and $vs -notcontains $v){ [void]$vs.Add($v) }
        }
        if($vs.Count -gt 0){ $vendor = (($vs | Sort-Object) -join '+') }
    } catch {
        # Sin Get-AXEGpuList (modulo suelto) o sin CIM: se cae al unico dato de GPU que trae el
        # snapshot de hardware. No se inventa un vendor.
        if($hw -and $hw.HasNvidia){ $vendor = 'NVIDIA' }
    }

    $cpu = if($hw -and $hw.CpuName){ [string]$hw.CpuName } else { 'desconocida' }
    $ram = if($hw -and $hw.RamGB){ [double]$hw.RamGB } else { 0.0 }
    $build = 0; if($hw -and $hw.BuildNumber){ $build = [int]$hw.BuildNumber }
    if($build -eq 0){ try { $build = [int][Environment]::OSVersion.Version.Build } catch {} }
    $ver = if($script:AXEVersion){ [string]$script:AXEVersion } else { 'desconocida' }

    [pscustomobject]@{
        axeVersion = $ver
        hw         = [pscustomobject]@{ cpu=$cpu; ramGB=$ram; gpuVendor=$vendor; build=$build }
        hwHash     = (Get-AXEBenchHwHash -Cpu $cpu -RamGB $ram -GpuVendor $vendor -Build $build -Version $ver)
    }
}

function Measure-AXEBenchSample {
    # Corre $Passes muestras de las metricas de SISTEMA (headless, sin juego) y devuelve por
    # metrica {median;iqr;passes}, NO una sola muestra: sin dispersion no hay forma honesta de
    # decir si un delta posterior es real. Reusa Get-AXESnapshot/Get-AXEScore (32-measure): la
    # medicion vive en un sitio, aqui solo se repite y se agrega.
    #   Metrica que no se pudo medir (p.ej. [AXE.Native] ausente) viaja $null, no 0. Un 0 en
    # jitter seria la mejor cifra posible: exactamente la mentira que este subproyecto ataca.
    # No muta nada del sistema => seguro en SelfTest/CI, sin admin y sin punto de restauracion.
    param([int]$Passes=7,[int]$JitterMs=250)
    if($Passes -lt 1){ $Passes = 1 }
    if($JitterMs -lt 20){ $JitterMs = 20 }

    $p999=@(); $jmean=@(); $timer=@(); $score=@()
    for($i=0; $i -lt $Passes; $i++){
        $snap = Get-AXESnapshot -JitterMs $JitterMs
        if($snap.Jitter -isnot [string]){
            $p999  += [double]$snap.Jitter.P999Ms
            $jmean += [double]$snap.Jitter.MeanMs
        }
        if($snap.Timer -isnot [string]){ $timer += [double]$snap.Timer.CurrentMs }
        try { $sc = Get-AXEScore $snap; if($sc){ $score += [double]$sc.Total } } catch {}
    }

    $id = Get-AXEBenchIdentity
    [pscustomobject]@{
        id         = $null                       # lo asigna Save-AXEBenchBaseline
        axeVersion = $id.axeVersion
        hwHash     = $id.hwHash
        hw         = $id.hw
        ts         = (Get-Date).ToUniversalTime().ToString('o')
        passes     = [int]$Passes
        jitterMs   = [int]$JitterMs
        metrics    = [pscustomobject]@{
            jitterP999Ms = (Get-AXEBenchStat $p999)
            jitterMeanMs = (Get-AXEBenchStat $jmean)
            timerMs      = (Get-AXEBenchStat $timer)
            score        = (Get-AXEBenchStat $score)
        }
    }
}

function Get-AXEBenchVerdict {
    # PURA y testeable: no mide, solo compara dos agregados. El corazon honesto del subproyecto.
    #
    # delta = medianaDespues - medianaAntes. Concluyente SOLO si
    #     abs(delta) > K * (IQRantes + IQRdespues)
    # o sea: el cambio tiene que salirse del ruido que ESTA maquina acaba de demostrar tener,
    # sumando el de las dos fases. Un delta por debajo de esa banda se etiqueta 'ruido' y NUNCA
    # se llama mejora. Es la leccion del timer-flakiness (2026-07-19) aplicada aqui: la
    # estadistica sola, sin comparar contra el ruido medido, declara ganadores por azar.
    #   K arranca conservador en 1.0. Subirlo exige mas evidencia; bajarlo de 1.0 seria empezar
    # a llamar mejora a cosas dentro del ruido, asi que no.
    #   Metrica ausente o sin mediana en cualquiera de las dos fases => se OMITE de la lista.
    # No se compara contra un 0 fabricado.
    param($Before,$After,[double]$K=1.0)
    $out = New-Object System.Collections.ArrayList
    if(-not $Before -or -not $After){ return @($out) }
    foreach($m in $script:AXEBenchMetrics){
        $b = $null; $a = $null
        try { $b = $Before.metrics.$($m.Key) } catch {}
        try { $a = $After.metrics.$($m.Key)  } catch {}
        if($null -eq $b -or $null -eq $a){ continue }
        if($null -eq $b.median -or $null -eq $a.median){ continue }

        $bm = [double]$b.median; $am = [double]$a.median
        $bq = if($null -eq $b.iqr){ 0.0 } else { [double]$b.iqr }
        $aq = if($null -eq $a.iqr){ 0.0 } else { [double]$a.iqr }
        $delta = $am - $bm
        # SUELO DE RESOLUCION. Con pocas pasadas y una metrica muy estable el IQR se redondea a
        # 0, y entonces CUALQUIER delta distinto de cero pasa el umbral: el ruido no ha
        # desaparecido, es que no lo estamos resolviendo. Medido en la primera ejecucion real:
        # 'Jitter medio' salio MEJOR con delta -0.0001ms e IQR 0.0000 en las dos fases. Eso es
        # justo el titular fabricado que este subproyecto existe para no publicar.
        #   El suelo es la resolucion con la que el propio reporte imprime la metrica (10^-Digits):
        # un cambio mas pequeno que el ultimo decimal que ensenamos no se puede llamar mejora.
        $floor = [math]::Pow(10, -$m.Digits)
        $noise = [math]::Max(($K * ($bq + $aq)), $floor)
        $conclusive = [math]::Abs($delta) -gt $noise

        $tag = 'ruido'
        if($conclusive){
            if($m.Better -eq 'down'){ $tag = $(if($delta -lt 0){'mejor'}else{'peor'}) }
            else                    { $tag = $(if($delta -gt 0){'mejor'}else{'peor'}) }
        }
        $pct = $null
        if([math]::Abs($bm) -gt 1e-9){ $pct = [math]::Round(100.0 * $delta / [math]::Abs($bm), 1) }

        $d = $m.Digits
        $reason = if($conclusive){
            "delta {0}{1} supera el ruido combinado {2}{1} (IQR {3} + {4}, K={5})." -f `
                (Format-AXEBenchNum $delta $d),$m.Unit,(Format-AXEBenchNum $noise $d), `
                (Format-AXEBenchNum $bq $d),(Format-AXEBenchNum $aq $d),(Format-AXEBenchNum $K 1)
        } else {
            "delta {0}{1} NO supera el ruido combinado {2}{1}: dentro del margen, no concluyente." -f `
                (Format-AXEBenchNum $delta $d),$m.Unit,(Format-AXEBenchNum $noise $d)
        }

        [void]$out.Add([pscustomobject]@{
            Key        = $m.Key
            Label      = $m.Label
            Unit       = $m.Unit
            Digits     = $d
            Better     = $m.Better
            Note       = $m.Note
            Before     = [math]::Round($bm,4)
            After      = [math]::Round($am,4)
            Delta      = [math]::Round($delta,4)
            PctChange  = $pct
            Noise      = [math]::Round($noise,4)
            Conclusive = [bool]$conclusive
            Tag        = $tag
            Reason     = $reason
        })
    }
    @($out)
}

function Save-AXEBenchBaseline {
    # Persiste el agregado en <AXEData>/bench/<id>.json y devuelve el id (o $null si no pudo).
    # id = marca de tiempo corta, legible y tecleable: el usuario lo copia a mano tras reiniciar.
    param($Sample)
    if(-not $Sample){ return $null }
    try {
        if(-not (Test-Path $script:AXEBenchDir)){ New-Item -ItemType Directory -Path $script:AXEBenchDir -Force | Out-Null }
        $base = (Get-Date).ToString('yyyyMMdd-HHmm')
        $id = $base; $n = 1
        # Dos baselines en el mismo minuto no se pisan: la segunda no puede borrar en silencio
        # el 'antes' de la primera, que es justo el dato que ya no se puede volver a tomar.
        while(Test-Path (Join-Path $script:AXEBenchDir ($id + '.json'))){ $id = ('{0}-{1}' -f $base,$n); $n++ }
        $Sample.id = $id
        $Sample | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:AXEBenchDir ($id + '.json')) -Encoding UTF8
        $id
    } catch {
        try { Write-AXELog "Benchmark: no pude guardar la linea base: $($_.Exception.Message)" 'ERR' } catch {}
        $null
    }
}

function Read-AXEBenchBaseline {
    # Carga <AXEData>/bench/<id>.json. $null si no existe o esta corrupto (no se inventa un
    # 'antes'). La validacion de comparabilidad NO va aqui: vive en Test-AXEBenchComparable,
    # que puede decir POR QUE no se puede comparar; devolver $null tambien para "otra maquina"
    # mezclaria dos fallos que merecen mensajes distintos.
    param([string]$Id)
    if([string]::IsNullOrWhiteSpace($Id)){ return $null }
    # El id es un NOMBRE de fichero, no una ruta: sin esto, '-After ..\..\algo' leeria fuera
    # del store. Barato, y cierra la unica entrada de usuario de todo el bloque.
    if($Id -notmatch '^[A-Za-z0-9._-]+$'){
        try { Write-AXELog "Benchmark: id de linea base invalido '$Id'." 'ERR' } catch {}
        return $null
    }
    $file = Join-Path $script:AXEBenchDir ($Id + '.json')
    if(-not (Test-Path $file)){ return $null }
    try {
        $raw = Get-Content $file -Raw -Encoding UTF8
        if([string]::IsNullOrWhiteSpace($raw)){ return $null }
        $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        try { Write-AXELog "Benchmark: linea base '$Id' ilegible: $($_.Exception.Message)" 'ERR' } catch {}
        $null
    }
}

function Test-AXEBenchComparable {
    # Devuelve $null si el 'antes' es comparable con ESTA maquina/build, o el motivo en texto.
    # Sin esto, un delta entre dos equipos (o entre dos versiones de AXE) tendria pinta de
    # medicion y seria basura: justo el tipo de cifra que el mercado publica.
    param($Before,$Identity=$null)
    if(-not $Before){ return 'no hay linea base que comparar.' }
    if(-not $Identity){ $Identity = Get-AXEBenchIdentity }
    if(-not $Before.hwHash){ return 'la linea base no trae hash de identidad (fichero de una version antigua).' }
    if($Before.hwHash -ne $Identity.hwHash){
        $bhw = $Before.hw
        return ("no comparable: la linea base se tomo en otra maquina/build o con otra version de AXE " +
                "(antes: {0} | {1} GB | GPU {2} | build {3} | AXE {4}  --  ahora: {5} | {6} GB | GPU {7} | build {8} | AXE {9})." -f `
                $bhw.cpu,(Format-AXEBenchNum $bhw.ramGB 1),$bhw.gpuVendor,$bhw.build,$Before.axeVersion, `
                $Identity.hw.cpu,(Format-AXEBenchNum $Identity.hw.ramGB 1),$Identity.hw.gpuVendor,$Identity.hw.build,$Identity.axeVersion)
    }
    $null
}

function Format-AXEBenchSample {
    # Render de UNA fase (la linea base). string[]: el consumidor decide como pintarlo, igual
    # que Format-AXETimerSweep. Ensena la mediana Y el IQR: el ruido se muestra desde el
    # principio, para que se vea contra que va a tener que competir el 'despues'.
    param($Sample,[string]$Title='LINEA BASE')
    if(-not $Sample){ return @('Sin datos (ver log).') }
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add("-- $Title --")
    [void]$L.Add(("Equipo   : {0} | {1} GB | GPU {2} | build {3}" -f $Sample.hw.cpu,(Format-AXEBenchNum $Sample.hw.ramGB 1),$Sample.hw.gpuVendor,$Sample.hw.build))
    [void]$L.Add(("Pasadas  : {0} (jitter {1}ms por pasada)" -f $Sample.passes,$Sample.jitterMs))
    [void]$L.Add('')
    [void]$L.Add('Metrica          mediana          ruido (IQR)')
    foreach($m in $script:AXEBenchMetrics){
        $st = $null; try { $st = $Sample.metrics.$($m.Key) } catch {}
        if($null -eq $st -or $null -eq $st.median){
            [void]$L.Add(("{0,-14}   {1,-16} {2}" -f $m.Label,'n/a','no medible en este equipo'))
            continue
        }
        [void]$L.Add(("{0,-14}   {1,-16} {2}" -f $m.Label, `
            ((Format-AXEBenchNum $st.median $m.Digits) + $m.Unit), `
            ((Format-AXEBenchNum $st.iqr $m.Digits) + $m.Unit)))
    }
    @($L)
}

function New-AXEBenchReport {
    # Tres representaciones del MISMO dato: Text (string[] para CLI), Json (string) y Markdown
    # (string, el compartible). Se generan aqui juntas a posta: si cada consumidor armara la
    # suya, un dia el .md diria "mejora" donde la CLI dice "ruido".
    #   SIN PII: solo modelo de CPU, RAM, vendor de GPU y build. Ni serial, ni usuario, ni IP.
    param($Before,$After,$Verdict)
    if(-not $Verdict){ $Verdict = Get-AXEBenchVerdict $Before $After }
    $rows = @($Verdict)
    $hw = $After.hw

    $notes = @(
        'Jitter = proxy de latencia (no atribuible a un driver concreto). DPC no se mide: no hay API userland honesta.'
        'Timer: en build 19041+ la resolucion instantanea la fija la app en primer plano; es ambiental, no configuracion.'
        "'ruido' = el cambio NO supera el ancho del ruido medido (IQR antes + IQR despues). No es una mejora."
        'FPS y 1% low NO se miden aqui (esto es headless, sin juego). Usa: AXE -Fps <proceso> -FpsCompare, con el juego abierto y la MISMA escena.'
        'Protocolo reproducible: cualquiera puede repetirlo en su equipo y verificar el resultado.'
    )

    # ---- Text (CLI) ----
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('=== AXE BENCHMARK - antes / despues (medido en esta maquina) ===')
    [void]$L.Add(("Equipo   : {0} | {1} GB | GPU {2} | build {3}" -f $hw.cpu,(Format-AXEBenchNum $hw.ramGB 1),$hw.gpuVendor,$hw.build))
    [void]$L.Add(("Version  : AXE {0}" -f $After.axeVersion))
    [void]$L.Add(("Antes    : {0}  (id {1}, {2} pasadas)" -f (Format-AXEBenchTs $Before.ts),$Before.id,$Before.passes))
    [void]$L.Add(("Despues  : {0}  ({1} pasadas)" -f (Format-AXEBenchTs $After.ts),$After.passes))
    [void]$L.Add('')
    if($rows.Count -eq 0){
        [void]$L.Add('Ninguna metrica se pudo medir en las DOS fases: no hay nada que comparar.')
    } else {
        [void]$L.Add('Metrica          antes            despues          delta            ruido            veredicto')
        foreach($v in $rows){
            [void]$L.Add(("{0,-14}   {1,-16} {2,-16} {3,-16} {4,-16} {5}" -f $v.Label, `
                ((Format-AXEBenchNum $v.Before $v.Digits) + $v.Unit), `
                ((Format-AXEBenchNum $v.After  $v.Digits) + $v.Unit), `
                ((Format-AXEBenchNum $v.Delta  $v.Digits) + $v.Unit), `
                ((Format-AXEBenchNum $v.Noise  $v.Digits) + $v.Unit), `
                $v.Tag.ToUpperInvariant()))
        }
        [void]$L.Add('')
        foreach($v in $rows){ [void]$L.Add(("{0,-14} : {1}" -f $v.Label,$v.Reason)) }
        $mej = @($rows | Where-Object { $_.Tag -eq 'mejor' }).Count
        $peo = @($rows | Where-Object { $_.Tag -eq 'peor'  }).Count
        $rui = @($rows | Where-Object { $_.Tag -eq 'ruido' }).Count
        [void]$L.Add('')
        [void]$L.Add(("RESUMEN  : {0} mejor(es), {1} peor(es), {2} dentro del ruido." -f $mej,$peo,$rui))
        if($mej -eq 0 -and $peo -eq 0){
            [void]$L.Add('           Nada salio del ruido: en este equipo el cambio NO es demostrable con estas metricas.')
            [void]$L.Add('           Eso es un resultado valido, no un fallo de la herramienta.')
        }
    }
    [void]$L.Add('')
    [void]$L.Add('Notas:')
    foreach($n in $notes){ [void]$L.Add(" - $n") }

    # ---- Markdown (compartible) ----
    $M = New-Object System.Collections.ArrayList
    [void]$M.Add('# AXE - benchmark antes / despues')
    [void]$M.Add('')
    [void]$M.Add(("**Equipo:** {0} | {1} GB | GPU {2} | Windows build {3}  " -f $hw.cpu,(Format-AXEBenchNum $hw.ramGB 1),$hw.gpuVendor,$hw.build))
    [void]$M.Add(("**AXE:** {0}  " -f $After.axeVersion))
    [void]$M.Add(("**Antes:** {0} ({1} pasadas) - **Despues:** {2} ({3} pasadas)" -f (Format-AXEBenchTs $Before.ts),$Before.passes,(Format-AXEBenchTs $After.ts),$After.passes))
    [void]$M.Add('')
    if($rows.Count -eq 0){
        [void]$M.Add('_Ninguna metrica se pudo medir en las dos fases: no hay nada que comparar._')
    } else {
        [void]$M.Add('| Metrica | Antes | Despues | Delta | Ruido (IQR sumado) | Veredicto |')
        [void]$M.Add('|---|---|---|---|---|---|')
        foreach($v in $rows){
            [void]$M.Add(("| {0} | {1}{6} | {2}{6} | {3}{6} | {4}{6} | **{5}** |" -f $v.Label, `
                (Format-AXEBenchNum $v.Before $v.Digits),(Format-AXEBenchNum $v.After $v.Digits), `
                (Format-AXEBenchNum $v.Delta $v.Digits),(Format-AXEBenchNum $v.Noise $v.Digits), `
                $v.Tag,$v.Unit))
        }
    }
    [void]$M.Add('')
    [void]$M.Add('## Como leerlo')
    foreach($n in $notes){ [void]$M.Add("- $n") }
    [void]$M.Add('')
    [void]$M.Add('> Reproducelo: `AXE -Benchmark`, aplica los cambios, reinicia, `AXE -Benchmark -After <id>`.')

    # ---- Json (mismo dato, plano) ----
    $json = ([pscustomobject]@{
        generated  = (Get-Date).ToUniversalTime().ToString('o')
        axeVersion = $After.axeVersion
        hw         = $hw
        before     = $Before
        after      = $After
        verdict    = @($rows | ForEach-Object {
            [pscustomobject]@{ key=$_.Key; label=$_.Label; unit=$_.Unit; better=$_.Better
                before=$_.Before; after=$_.After; delta=$_.Delta; pctChange=$_.PctChange
                noise=$_.Noise; conclusive=$_.Conclusive; tag=$_.Tag; reason=$_.Reason }
        })
        notes      = $notes
    } | ConvertTo-Json -Depth 8)

    [pscustomobject]@{ Text=@($L); Json=$json; Markdown=(($M) -join "`r`n") }
}

function Export-AXEBenchReport {
    # Escribe <stem>.json y <stem>.md a partir del reporte ya construido. Devuelve las rutas
    # escritas (string[]). Un solo -Report en la CLI produce las dos caras compartibles.
    param($Report,[string]$Path)
    if(-not $Report -or [string]::IsNullOrWhiteSpace($Path)){ return @() }
    $dir = Split-Path -Parent $Path
    # '-Report informe.json' (sin carpeta) deja $dir vacio y Join-Path revienta con cadena
    # vacia: se cae al directorio actual, que es lo que el usuario quiso decir.
    if([string]::IsNullOrWhiteSpace($dir)){ $dir = '.' }
    if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stem = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($Path))
    $jf = "$stem.json"; $mf = "$stem.md"
    Set-Content -Path $jf -Value $Report.Json -Encoding UTF8
    Set-Content -Path $mf -Value $Report.Markdown -Encoding UTF8
    @($jf,$mf)
}
