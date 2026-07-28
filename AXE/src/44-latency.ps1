# =====================================================
# REGION 10f - LATENCIA DEL SISTEMA: SONDEO DEL RATON Y TIEMPO EN DPC
# =====================================================
#
# POR QUE EXISTE: 35-diag cubre el hardware MAL CONFIGURADO (XMP, canales, Hz, disco). Quedan
# dos fuentes de latencia grandes que no son ni un tweak ni una pieza mal puesta, y que el
# catalogo entero no puede tocar:
#
#   Sondeo del raton   Un raton a 125 Hz manda su posicion cada 8 ms; a 1000 Hz, cada 1 ms.
#                      Son 7 ms de retardo aniadidos a CADA movimiento, antes de que el juego
#                      se entere. Ningun tweak del registro compensa eso.
#   Tiempo en DPC      Un driver que se pasa de tiempo en su rutina diferida bloquea el nucleo
#                      donde corre. Es la otra gran familia de tirones: el FPS medio sale bien
#                      y aun asi la imagen da saltos.
#
# DIVISION PURO/HARDWARE, la misma de 33-fps y 35-diag:
#   Measure-*  -> tocan hardware o cronometran. No testeables en CI.
#   Get-*      -> PURAS. Reciben muestras, deciden. Testeables sin raton y sin drivers.
# Si el juicio viviera dentro de la medicion solo se podria probar en la maquina del que lo
# escribio, o sea nunca.
#
# LIMITE DECLARADO DEL MODULO DE DPC, y es importante: aqui se mide el TIEMPO TOTAL en DPC,
# no la duracion de cada DPC ni quien la causo. Un driver con DPCs raras pero de 2 ms produce
# un tiron audible y sale con un porcentaje ridiculo. Atribuir por driver exige consumir ETW
# (kernel logger) y resolver direcciones contra los modulos cargados; eso no se puede hacer en
# PowerShell sin meter un binario de terceros en el que haya que confiar a ciegas, que es
# justo lo que este proyecto le reprocha a los optimizadores de pago. Asi que se mide lo que se
# puede medir con honestidad y se DICE lo que falta, en vez de fingir un LatencyMon.

# Rangos de sondeo estandar de un raton USB. bInterval del endpoint HID: 8 ms, 4, 2, 1, y los
# 0.5/0.25/0.125 ms de los inalambricos de competicion. Se usan para "encajar" la medida: una
# lectura de 987 Hz es un raton de 1000 Hz con muestras perdidas, no un raton de 987 Hz.
$script:AXEMouseRates = @(125, 250, 500, 1000, 2000, 4000, 8000)

# Tolerancia del encaje. 20% cubre la perdida tipica de muestras sin llegar a confundir dos
# escalones contiguos: entre 500 y 1000 hay un factor 2, muy por encima del 20%.
$script:AXEMouseSnapTol = 0.20

# Minimo de intervalos para afirmar algo. Por debajo, el resultado es UNKNOWN y se dice por que.
# 30 muestras a 125 Hz son 0.24 s de movimiento real: si el usuario no movio el raton, se nota.
$script:AXEMouseMinSamples = 30

# Umbral de tiempo en DPC por nucleo. Por encima de esto un nucleo pasa tanto rato atendiendo
# rutinas diferidas de drivers que el hilo del juego que le toque sufre. Es un umbral de la
# industria (Process Explorer pinta rojo por ahi), no una medida de esta maquina.
$script:AXEDpcBadPct  = 3.0
$script:AXEIsrBadPct  = 2.0

# --- Capa nativa ----------------------------------------------------------------------
# Tipo APARTE de AXE.Native (32-measure): Add-Type no puede aniadir miembros a un tipo ya
# cargado, y 32-measure se carga antes. C# 5 compat-safe (csc de PS 5.1 + Roslyn de PS 7):
# sin var implicito en campos, sin interpolacion de cadenas, sin record.
if(-not ('AXE.Lat' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace AXE {
  [StructLayout(LayoutKind.Sequential)]
  public struct LatPoint { public int X; public int Y; }

  // SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION. DpcTime e InterruptTime son SUBCONJUNTOS de
  // KernelTime, y KernelTime YA INCLUYE IdleTime: por eso el denominador del porcentaje es
  // (Kernel + User) y no (Kernel + User + Idle), que contaria el reposo dos veces.
  [StructLayout(LayoutKind.Sequential)]
  public struct LatCpuPerf {
    public long IdleTime; public long KernelTime; public long UserTime;
    public long DpcTime;  public long InterruptTime; public uint InterruptCount;
  }

  public static class Lat {
    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out LatPoint p);

    [DllImport("ntdll.dll")]
    private static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);

    private const int SystemProcessorPerformanceInformation = 8;

    // Muestrea los intervalos entre CAMBIOS de la posicion del cursor.
    //
    // POR QUE ASI y no con GetMouseMovePointsEx: esa API devuelve el historial con marca de
    // tiempo, pero exige encajar un punto semilla exacto contra su buffer interno y falla con
    // -1 en cuanto el punto no esta (escalado de DPI, cursor movido por otra cosa). Esto es
    // un sondeo directo: si el cursor cambio de sitio, el raton acaba de reportar. El bucle
    // debe ser NATIVO por el mismo motivo que el jitter de 32-measure: un bucle de PowerShell
    // mediria al interprete, no al raton.
    //
    // Quema un nucleo mientras dura. Es a proposito y es corto: sin busy-wait no se puede
    // muestrear por encima de la frecuencia que se quiere medir.
    public static double[] SampleCursorIntervals(int ms) {
      if (ms < 100) ms = 100;
      List<double> outv = new List<double>();
      LatPoint last; GetCursorPos(out last);
      double toMs = 1000.0 / (double)Stopwatch.Frequency;
      long t0 = Stopwatch.GetTimestamp();
      long tLast = t0;
      long deadline = t0 + (long)((ms / 1000.0) * Stopwatch.Frequency);
      LatPoint cur;
      while (Stopwatch.GetTimestamp() < deadline) {
        GetCursorPos(out cur);
        if (cur.X != last.X || cur.Y != last.Y) {
          long tn = Stopwatch.GetTimestamp();
          outv.Add((tn - tLast) * toMs);
          tLast = tn; last = cur;
        }
      }
      return outv.ToArray();
    }

    // Instantanea de contadores por CPU logica. Devuelve un array plano de 5 valores por CPU:
    // {Idle, Kernel, User, Dpc, Interrupt} en unidades de 100 ns. Plano y no un array de
    // structs porque PowerShell marshalea arrays de long sin ceremonia.
    public static long[] ProcessorPerf() {
      int n = Environment.ProcessorCount;
      int sz = Marshal.SizeOf(typeof(LatCpuPerf));
      IntPtr buf = Marshal.AllocHGlobal(sz * n);
      try {
        int ret;
        int st = NtQuerySystemInformation(SystemProcessorPerformanceInformation, buf, sz * n, out ret);
        if (st != 0) return new long[0];
        int have = ret / sz;
        if (have > n) have = n;
        long[] outv = new long[have * 5];
        for (int i = 0; i < have; i++) {
          IntPtr p = new IntPtr(buf.ToInt64() + (long)(i * sz));
          LatCpuPerf c = (LatCpuPerf)Marshal.PtrToStructure(p, typeof(LatCpuPerf));
          outv[i * 5 + 0] = c.IdleTime;
          outv[i * 5 + 1] = c.KernelTime;
          outv[i * 5 + 2] = c.UserTime;
          outv[i * 5 + 3] = c.DpcTime;
          outv[i * 5 + 4] = c.InterruptTime;
        }
        return outv;
      } finally { Marshal.FreeHGlobal(buf); }
    }
  }
}
'@ -ErrorAction SilentlyContinue
}

# =====================================================
# RATON
# =====================================================

function Measure-AXEMouseIntervals {
    # IMPURA: cronometra el raton de verdad. Devuelve intervalos en ms entre reportes.
    # Necesita que el usuario MUEVA el raton: sin movimiento no hay reportes que cronometrar,
    # y devolver un array corto es la respuesta correcta (Get-AXEMouseRate lo convierte en
    # UNKNOWN con motivo, no en un numero inventado).
    param([int]$Seconds = 3)
    if($Seconds -lt 1){ $Seconds = 1 }
    if($Seconds -gt 15){ $Seconds = 15 }
    try { ,([AXE.Lat]::SampleCursorIntervals($Seconds * 1000)) } catch { ,@() }
}

function Get-AXEMouseRate {
    # PURA: mismos intervalos dentro, mismo veredicto fuera.
    #
    # SE USA LA MODA, y las dos alternativas obvias se probaron y FALLAN por lados opuestos:
    #
    #   Mediana        Un movimiento lento produce reportes con delta 0 px que no mueven el
    #                  cursor y se ven como un intervalo del doble o del triple. La mediana se
    #                  los traga y un raton de 1000 Hz movido despacio sale como uno de 300.
    #   Percentil 10   Fue la primera implementacion, con el argumento de que el ruido solo
    #                  puede ALARGAR intervalos, nunca acortarlos. Es falso: el stack de
    #                  entrada de Windows entrega reportes A RAFAGAS tras una pausa de
    #                  planificacion, y esa rafaga son intervalos casi cero. MEDIDO: con un
    #                  generador sintetico a 500 Hz el P10 devolvia 1000, y a 1000 devolvia
    #                  2000. Sobreestima justo el doble, que es el error mas enganioso posible
    #                  porque 2x cae en otro escalon estandar y encaja igual de "limpio".
    #
    # La moda no tiene ninguno de los dos problemas: el periodo REAL es, por definicion, el
    # intervalo que mas veces aparece cuando el movimiento es continuo. Los reportes perdidos
    # se acumulan en 2T y 3T (modas menores) y las rafagas cerca de 0 (otra moda menor), y
    # ninguna de las dos le gana a la fundamental.
    param([object[]]$Intervals)

    $raw = @($Intervals)
    # El primer intervalo va desde el arranque del bucle hasta el primer movimiento: mide
    # cuanto tardo el usuario en reaccionar, no el raton. Fuera siempre.
    if($raw.Count -gt 0){ $raw = @($raw[1..($raw.Count-1)]) }
    $ok = @($raw | Where-Object { $null -ne $_ -and [double]$_ -gt 0 } | ForEach-Object { [double]$_ })

    if($ok.Count -lt $script:AXEMouseMinSamples){
        return [pscustomobject]@{
            Hz=$null; RawHz=$null; Snapped=$false; Samples=$ok.Count; PeriodMs=$null
            Confidence='desconocida'
            Reason=("solo $($ok.Count) reportes utiles (hacen falta $($script:AXEMouseMinSamples)): hay que mover el raton sin parar mientras mide.")
        }
    }

    # Moda por histograma de anchura RELATIVA (bins del 12% en escala logaritmica), no absoluta.
    # Absoluta no sirve: 1 ms y 8 ms son el mismo fenomeno a dos escalas, y un bin fijo que
    # separe bien a 8 ms mete todo el rango de 1 ms en una sola cubeta. El 12% es mas estrecho
    # que la distancia entre escalones estandar (que es 2x) y mas ancho que el jitter tipico
    # del planificador, asi que separa 500 de 1000 sin partir en dos la moda de un mismo raton.
    $bins = @{}
    $lb = [math]::Log(1.12)
    foreach($v in $ok){
        $k = [int][math]::Floor([math]::Log($v) / $lb)
        if($bins.ContainsKey($k)){ [void]$bins[$k].Add($v) } else { $bins[$k] = (New-Object System.Collections.Generic.List[double]); [void]$bins[$k].Add($v) }
    }
    $bestBin = $null; $bestN = 0
    foreach($k in $bins.Keys){
        $n = $bins[$k].Count
        # Empate a favor del bin MAS LARGO: entre dos cubetas igual de pobladas, la corta es
        # una rafaga y la larga es el periodo. Preferir la corta es sobreestimar, que es el
        # error que se acaba de corregir.
        if($n -gt $bestN -or ($n -eq $bestN -and $null -ne $bestBin -and $k -gt $bestBin)){ $bestN = $n; $bestBin = $k }
    }
    $modeVals = @($bins[$bestBin] | Sort-Object)
    $mode = [double]$modeVals[[int][math]::Floor($modeVals.Count / 2)]
    if($mode -le 0){
        return [pscustomobject]@{
            Hz=$null; RawHz=$null; Snapped=$false; Samples=$ok.Count; PeriodMs=$null
            Confidence='desconocida'; Reason='los intervalos medidos son cero: el reloj no dio resolucion suficiente.'
        }
    }

    $rawHz = 1000.0 / $mode
    # Encaje al escalon estandar mas cercano en proporcion (no en distancia absoluta): entre
    # 125 y 250 la distancia absoluta enganiaria a favor del escalon alto.
    $best = $null; $bestRel = [double]::MaxValue
    foreach($r in $script:AXEMouseRates){
        $rel = [math]::Abs($rawHz - $r) / [double]$r
        if($rel -lt $bestRel){ $bestRel = $rel; $best = $r }
    }
    $snapped = ($bestRel -le $script:AXEMouseSnapTol)
    $hz = if($snapped){ [int]$best } else { [int][math]::Round($rawHz) }

    # Confianza: cuantas muestras hay y como de limpio quedo el encaje. No se promete precision
    # que el metodo no da; con pocas muestras se dice "parcial" aunque el numero salga redondo.
    # La moda tambien tiene que ser MAYORITARIA de verdad. Si la cubeta ganadora se lleva menos
    # de un tercio de las muestras, la distribucion esta repartida (movimiento a tirones, o el
    # cursor lo movio algo que no es el raton) y el numero no se sostiene: sale 'parcial'
    # aunque haya miles de muestras.
    $share = [double]$bestN / [double]$ok.Count
    $conf = if(-not $snapped){ 'parcial (no encaja en ningun sondeo estandar; puede ser un raton raro o poco movimiento)' }
            elseif($share -lt 0.33){ 'parcial (los intervalos salen muy repartidos: mueve el raton de forma continua)' }
            elseif($ok.Count -ge 200){ 'cierta' }
            else { 'parcial (pocas muestras)' }

    [pscustomobject]@{
        Hz=$hz; RawHz=[math]::Round($rawHz,1); Snapped=$snapped; Samples=$ok.Count
        PeriodMs=[math]::Round($mode,3); ModeShare=[math]::Round($share,3)
        Confidence=$conf; Reason=$null
    }
}

function Get-AXEMouseSettings {
    # IMPURA: lee el registro. Ajustes del puntero que SI son estaticos y SI se leen siempre,
    # con raton parado y en modo headless. Cada uno en su try: en una maquina por la que ya
    # paso otro optimizador cualquiera de estas claves puede no existir.
    $s = [ordered]@{ Accel=$null; Sensitivity=$null; QueueSize=$null }
    try {
        $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse' -ErrorAction Stop
        # MouseSpeed es el interruptor de "Mejorar la precision del puntero" (aceleracion).
        # 0 = apagado. 1 y 2 son los dos escalones de aceleracion.
        if($null -ne $m.MouseSpeed){ $s.Accel = [int]$m.MouseSpeed }
        # MouseSensitivity 10 = 1:1 (el punto medio del deslizador, 6 de 11). Cualquier otro
        # valor multiplica los contadores del raton, o sea que duplica o SE SALTA pixeles.
        if($null -ne $m.MouseSensitivity){ $s.Sensitivity = [int]$m.MouseSensitivity }
    } catch {}
    try {
        $q = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' -ErrorAction Stop
        if($null -ne $q.MouseDataQueueSize){ $s.QueueSize = [int]$q.MouseDataQueueSize }
    } catch {}
    [pscustomobject]$s
}

function Get-AXEMouseFindings {
    # PURA. Devuelve hallazgos con la MISMA forma que 35-diag (New-AXEDiagFinding) para que el
    # render y la GUI no tengan que aprender un segundo formato.
    param($Rate, $Settings)
    $out = New-Object System.Collections.Generic.List[object]

    # --- Sondeo -------------------------------------------------------------------------
    if($null -eq $Rate -or $null -eq $Rate.Hz){
        $why = if($Rate -and $Rate.Reason){ $Rate.Reason } else { 'no se midio el sondeo del raton.' }
        [void]$out.Add((New-AXEDiagFinding 'mouse_rate' 'UNKNOWN' 'Sondeo del raton' `
            $why 'Vuelve a medir moviendo el raton en circulos sin parar durante toda la cuenta.' `
            '1-7 ms de input lag' 'desconocida'))
    } elseif($Rate.Hz -lt 500){
        $ms = [math]::Round(1000.0 / $Rate.Hz, 1)
        $gain = [math]::Round($ms - 1.0, 1)
        [void]$out.Add((New-AXEDiagFinding 'mouse_rate' 'BAD' 'Sondeo del raton' `
            "Reporta a $($Rate.Hz) Hz: manda su posicion cada $ms ms. A 1000 Hz seria cada 1 ms." `
            "Software del raton (Logitech G HUB, Razer Synapse, etc.) > tasa de sondeo > 1000 Hz. Si no tiene software, mira si trae un interruptor fisico. Un raton que no pasa de 125 Hz es de los pocos casos en que cambiar de raton se nota de verdad." `
            "${gain} ms de input lag" $Rate.Confidence))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'mouse_rate' 'OK' 'Sondeo del raton' `
            "Reporta a $($Rate.Hz) Hz (cada $([math]::Round(1000.0/$Rate.Hz,2)) ms)." `
            $null '1-7 ms de input lag' $Rate.Confidence))
    }

    # --- Aceleracion --------------------------------------------------------------------
    # Esto no es folclore: con la aceleracion puesta, el MISMO movimiento fisico produce
    # distinta distancia en pantalla segun la velocidad del gesto. La punteria se aprende por
    # memoria muscular, y la memoria muscular necesita que la relacion sea constante.
    if($null -eq $Settings -or $null -eq $Settings.Accel){
        [void]$out.Add((New-AXEDiagFinding 'mouse_accel' 'UNKNOWN' 'Aceleracion del puntero' `
            'No se pudo leer HKCU\Control Panel\Mouse.' `
            'Configuracion > Bluetooth y dispositivos > Raton > Configuracion adicional > Opciones de puntero.' `
            'consistencia de punteria' 'desconocida'))
    } elseif($Settings.Accel -ne 0){
        [void]$out.Add((New-AXEDiagFinding 'mouse_accel' 'BAD' 'Aceleracion del puntero' `
            '"Mejorar la precision del puntero" esta ACTIVADA. El mismo gesto fisico recorre distinta distancia segun lo rapido que lo hagas.' `
            'Configuracion > Raton > Configuracion adicional > Opciones de puntero > desmarca "Mejorar la precision del puntero".' `
            'consistencia de punteria' 'cierta (es el ajuste, leido del registro)'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'mouse_accel' 'OK' 'Aceleracion del puntero' `
            'Desactivada: la relacion entre gesto y pantalla es constante.' `
            $null 'consistencia de punteria' 'cierta'))
    }

    # --- Escalado 1:1 -------------------------------------------------------------------
    if($null -eq $Settings -or $null -eq $Settings.Sensitivity){
        [void]$out.Add((New-AXEDiagFinding 'mouse_scale' 'UNKNOWN' 'Escalado del puntero' `
            'No se pudo leer la sensibilidad del puntero.' `
            'Opciones de puntero > deja el deslizador de velocidad en el punto medio (6 de 11).' `
            'pixeles saltados' 'desconocida'))
    } elseif($Settings.Sensitivity -ne 10){
        [void]$out.Add((New-AXEDiagFinding 'mouse_scale' 'BAD' 'Escalado del puntero' `
            "El deslizador de velocidad no esta en el punto medio (valor $($Settings.Sensitivity), 1:1 es 10). Windows multiplica los contadores del raton: duplica o se salta pixeles." `
            'Opciones de puntero > pon el deslizador en el 6 de 11 (el punto medio) y ajusta la sensibilidad DENTRO del juego.' `
            'pixeles saltados' 'cierta (es el ajuste, leido del registro)'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'mouse_scale' 'OK' 'Escalado del puntero' `
            'En 1:1 (punto medio del deslizador): Windows no multiplica los contadores.' `
            $null 'pixeles saltados' 'cierta'))
    }

    $out.ToArray()
}

# =====================================================
# DPC / ISR
# =====================================================

function Get-AXEDpcStats {
    # PURA: recibe dos instantaneas planas de [AXE.Lat]::ProcessorPerf() y devuelve el
    # porcentaje por nucleo. Separada de la medicion para poder probar la aritmetica sin
    # drivers: los numeros de un test son los mismos que los de una maquina real.
    param([object[]]$Before, [object[]]$After)

    $b = @($Before); $a = @($After)
    if($b.Count -eq 0 -or $a.Count -ne $b.Count -or ($b.Count % 5) -ne 0){
        return [pscustomobject]@{ Cpus=@(); MaxDpcPct=$null; MaxIsrPct=$null; TotalDpcPct=$null; TotalIsrPct=$null }
    }

    $n = [int]($b.Count / 5)
    $cpus = New-Object System.Collections.Generic.List[object]
    $sumDpc = 0.0; $sumIsr = 0.0; $sumTot = 0.0
    for($i=0; $i -lt $n; $i++){
        $o = $i * 5
        # Denominador = Kernel + User. KernelTime YA incluye Idle en esta estructura, asi que
        # sumar Idle aparte contaria el reposo dos veces y hundiria todos los porcentajes.
        $dKern = [double]($a[$o+1] - $b[$o+1])
        $dUser = [double]($a[$o+2] - $b[$o+2])
        $dDpc  = [double]($a[$o+3] - $b[$o+3])
        $dInt  = [double]($a[$o+4] - $b[$o+4])
        $tot   = $dKern + $dUser
        if($tot -le 0){ continue }
        $sumDpc += $dDpc; $sumIsr += $dInt; $sumTot += $tot
        [void]$cpus.Add([pscustomobject]@{
            Cpu    = $i
            DpcPct = [math]::Round(100.0 * $dDpc / $tot, 2)
            IsrPct = [math]::Round(100.0 * $dInt / $tot, 2)
        })
    }
    $arr = $cpus.ToArray()
    if($arr.Count -eq 0){
        return [pscustomobject]@{ Cpus=@(); MaxDpcPct=$null; MaxIsrPct=$null; TotalDpcPct=$null; TotalIsrPct=$null }
    }
    [pscustomobject]@{
        Cpus        = $arr
        MaxDpcPct   = ($arr | Measure-Object DpcPct -Maximum).Maximum
        MaxIsrPct   = ($arr | Measure-Object IsrPct -Maximum).Maximum
        TotalDpcPct = [math]::Round(100.0 * $sumDpc / $sumTot, 2)
        TotalIsrPct = [math]::Round(100.0 * $sumIsr / $sumTot, 2)
    }
}

function Measure-AXEDpc {
    # IMPURA: dos instantaneas separadas por $Seconds. No necesita admin ni ETW: los contadores
    # por CPU salen de NtQuerySystemInformation, que es lo mismo que lee el Administrador de
    # tareas para pintar "tiempo de kernel".
    param([int]$Seconds = 5)
    if($Seconds -lt 1){ $Seconds = 1 }
    if($Seconds -gt 60){ $Seconds = 60 }
    $b = @(); $a = @()
    try { $b = @([AXE.Lat]::ProcessorPerf()) } catch { $b = @() }
    if($b.Count -eq 0){
        return [pscustomobject]@{ Cpus=@(); MaxDpcPct=$null; MaxIsrPct=$null; TotalDpcPct=$null; TotalIsrPct=$null; Seconds=$Seconds }
    }
    Start-Sleep -Seconds $Seconds
    try { $a = @([AXE.Lat]::ProcessorPerf()) } catch { $a = @() }
    $st = Get-AXEDpcStats -Before $b -After $a
    $st | Add-Member -NotePropertyName Seconds -NotePropertyValue $Seconds -Force
    $st
}

function Get-AXEDpcFindings {
    # PURA. Mismo formato de hallazgo que 35-diag.
    param($Dpc)
    $out = New-Object System.Collections.Generic.List[object]

    if($null -eq $Dpc -or $null -eq $Dpc.MaxDpcPct){
        [void]$out.Add((New-AXEDiagFinding 'dpc' 'UNKNOWN' 'Tiempo en DPC' `
            'No se pudieron leer los contadores por nucleo.' `
            'Vuelve a intentarlo; si sigue fallando, el sistema esta limitando NtQuerySystemInformation.' `
            'tirones, no FPS medio' 'desconocida'))
        return $out.ToArray()
    }

    $worst = @($Dpc.Cpus | Sort-Object DpcPct -Descending | Select-Object -First 1)
    $wcpu  = if($worst.Count -gt 0){ $worst[0].Cpu } else { 0 }

    if($Dpc.MaxDpcPct -ge $script:AXEDpcBadPct){
        [void]$out.Add((New-AXEDiagFinding 'dpc' 'BAD' 'Tiempo en DPC' `
            "El nucleo $wcpu paso el $($Dpc.MaxDpcPct)% del tiempo en rutinas diferidas de drivers (media de todos: $($Dpc.TotalDpcPct)%). Por encima del $($script:AXEDpcBadPct)% el hilo que caiga en ese nucleo sufre tirones." `
            'Sospecha primero de red y almacenamiento: actualiza el driver de la tarjeta de red y el del chipset desde la web del FABRICANTE del equipo, no desde Windows Update. Para saber QUE driver es hace falta una traza ETW (LatencyMon o xperf); AXE no lo atribuye, ver la nota de abajo.' `
            'tirones, no FPS medio' 'cierta (medido en esta maquina, ventana corta)'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'dpc' 'OK' 'Tiempo en DPC' `
            "Maximo por nucleo $($Dpc.MaxDpcPct)%, media $($Dpc.TotalDpcPct)%. Por debajo del umbral." `
            $null 'tirones, no FPS medio' 'parcial (mide carga total, no la duracion de cada DPC)'))
    }

    if($Dpc.MaxIsrPct -ge $script:AXEIsrBadPct){
        $iworst = @($Dpc.Cpus | Sort-Object IsrPct -Descending | Select-Object -First 1)
        $icpu = if($iworst.Count -gt 0){ $iworst[0].Cpu } else { 0 }
        [void]$out.Add((New-AXEDiagFinding 'isr' 'BAD' 'Tiempo en interrupciones' `
            "El nucleo $icpu paso el $($Dpc.MaxIsrPct)% atendiendo interrupciones de hardware." `
            'Suele ser un dispositivo USB que reinterrumpe o un driver de red antiguo. Desconecta perifericos USB uno a uno y vuelve a medir.' `
            'tirones, no FPS medio' 'cierta (medido en esta maquina, ventana corta)'))
    }

    $out.ToArray()
}

function Format-AXELatency {
    # PURA. Reusa el render de 35-diag para que un hallazgo se lea IGUAL venga de donde venga,
    # y aniade la nota de limite del DPC, que es especifica de este modulo y no del render.
    param([Parameter(Mandatory)]$Findings, [switch]$WithDpcNote)
    $L = New-Object System.Collections.Generic.List[string]
    $note = 'Ninguno se arregla con un tweak del registro: viven en el driver, en el software del raton o en Opciones de puntero de Windows.'
    foreach($line in (Format-AXEDiag -Findings $Findings -Title 'AXE LATENCIA: RATON Y DPC' -BadNote $note)){ [void]$L.Add($line) }
    if($WithDpcNote){
        [void]$L.Add('')
        [void]$L.Add('NOTA SOBRE EL DPC: esto mide CUANTO tiempo total se va en rutinas de drivers,')
        [void]$L.Add('no CUANTO dura cada una ni de QUE driver es. Un driver con DPCs raras pero de')
        [void]$L.Add('2 ms da un porcentaje bajo y aun asi produce tirones. Atribuir por driver exige')
        [void]$L.Add('consumir ETW y resolver simbolos: AXE no lo hace porque necesitaria un binario')
        [void]$L.Add('de terceros, que es justo lo que este proyecto no quiere pedirte que te creas.')
        [void]$L.Add('Si este apartado sale MAL, LatencyMon (gratis) te dice el nombre del driver.')
    }
    $L.ToArray()
}
