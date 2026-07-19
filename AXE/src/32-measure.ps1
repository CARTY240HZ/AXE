# =====================================================
# REGION 8b - MEDICION (Trust & Proof): timer resolution + jitter proxy + score
# =====================================================
# Capa nativa: P/Invoke NtQueryTimerResolution + busy-loop de jitter en C# compilado
# (el loop debe ser nativo; un loop PowerShell mediria el interprete, no el scheduler).
# Cargada UNA vez al init del modulo en el hilo principal; los runspaces de fondo ven
# el tipo (mismo AppDomain). C# compat-safe (csc 5.1 + Roslyn 7): C# 5, sin record.
if(-not ('AXE.Native' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
namespace AXE {
  public static class Native {
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int NtQueryTimerResolution(out uint Min, out uint Max, out uint Current);

    // Unidades de 100ns, igual que Query. SetResolution=false LIBERA el request de este proceso.
    // OJO Win11 2004+: sin GlobalTimerResolutionRequests=1 el efecto es SOLO de este proceso.
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);

    // Nucleo del barrido: mide cuanto se PASA de largo un Sleep(1) a la resolucion actual.
    // El DELTA (no el absoluto) es la senal: a mejor resolucion el scheduler despierta mas
    // cerca del 1ms pedido. Debe ser nativo - un Sleep en bucle de PowerShell mediria el
    // interprete. Devuelve {samples, avgDeltaMs, maxDeltaMs, stdevMs}.
    public static double[] MeasureSleepDelta(int samples) {
      if (samples < 1) samples = 1;
      double toMs = 1000.0 / (double)Stopwatch.Frequency;
      double[] vals = new double[samples];
      double sum = 0.0, max = 0.0;
      for (int i = 0; i < samples; i++) {
        long t0 = Stopwatch.GetTimestamp();
        System.Threading.Thread.Sleep(1);
        double delta = ((Stopwatch.GetTimestamp() - t0) * toMs) - 1.0;
        if (delta < 0.0) delta = 0.0;          // Sleep nunca vuelve antes; clamp del ruido de QPC
        vals[i] = delta; sum += delta;
        if (delta > max) max = delta;
      }
      double avg = sum / samples;
      double sq = 0.0;
      for (int i = 0; i < samples; i++) { double d = vals[i] - avg; sq += d * d; }
      return new double[] { (double)samples, avg, max, Math.Sqrt(sq / samples) };
    }

    // Devuelve {samples, meanMs, maxMs, p999Ms, stalls1ms}. Histograma acotado (memoria O(1)).
    public static double[] SampleJitter(int durationMs) {
      double freq = (double)Stopwatch.Frequency;
      double toMs = 1000.0 / freq;
      long endTicks = Stopwatch.GetTimestamp() + (long)(freq * durationMs / 1000.0);
      int B = 2000; double bw = 0.05;            // 2000 buckets x 0.05ms = 0..100ms
      long[] hist = new long[B];
      long n = 0; double sum = 0.0, max = 0.0; long stalls = 0;
      long prev = Stopwatch.GetTimestamp();
      while (true) {
        long now = Stopwatch.GetTimestamp();
        double gapMs = (now - prev) * toMs;
        prev = now;
        n++; sum += gapMs; if (gapMs > max) max = gapMs; if (gapMs > 1.0) stalls++;
        int bi = (int)(gapMs / bw); if (bi < 0) bi = 0; if (bi >= B) bi = B - 1;
        hist[bi]++;
        if (now >= endTicks) break;
      }
      double p999 = 0.0; long target = (long)Math.Ceiling(0.999 * n); long cum = 0;
      for (int i = 0; i < B; i++) { cum += hist[i]; if (cum >= target) { p999 = (i + 1) * bw; break; } }
      double mean = n > 0 ? sum / n : 0.0;
      return new double[] { (double)n, mean, max, p999, (double)stalls };
    }

    // ---- Standby list purge (ISLC-style). Requiere admin (SeProfileSingleProcessPrivilege). ----
    [DllImport("ntdll.dll")]
    static extern int NtSetSystemInformation(int InfoClass, IntPtr Info, int Length);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool LookupPrivilegeValue(string host, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKEN_PRIVILEGES newst, int len, IntPtr prev, IntPtr rl);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential, Pack=4)]
    struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public long Luid; public uint Attributes; }

    const int SystemMemoryListInformation = 0x50;
    const int MemoryPurgeStandbyList = 4;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x20, TOKEN_QUERY = 0x08;
    const uint SE_PRIVILEGE_ENABLED = 0x2;

    // Vacia la standby list (paginas en cache reclamables). NTSTATUS 0 = OK; negativo propio = fallo de privilegio.
    public static int PurgeStandby() {
      IntPtr tok = IntPtr.Zero;
      if(!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out tok)) return -1;
      try {
        long luid;
        if(!LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out luid)) return -2;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1; tp.Luid = luid; tp.Attributes = SE_PRIVILEGE_ENABLED;
        if(!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return -3;
        if(Marshal.GetLastWin32Error() != 0) return -4;   // ERROR_NOT_ALL_ASSIGNED: sin admin
        IntPtr p = Marshal.AllocHGlobal(sizeof(int));
        try { Marshal.WriteInt32(p, MemoryPurgeStandbyList); return NtSetSystemInformation(SystemMemoryListInformation, p, sizeof(int)); }
        finally { Marshal.FreeHGlobal(p); }
      } finally { CloseHandle(tok); }
    }
  }
}
'@
}

function Get-AXETimerResolution {
    # NtQueryTimerResolution devuelve unidades de 100ns. Current/10000 = ms. Menor = mejor.
    try {
        $min=0; $max=0; $cur=0
        $rc = [AXE.Native]::NtQueryTimerResolution([ref]$min,[ref]$max,[ref]$cur)
        if($rc -ne 0){ return $null }
        # Windows 10 2004 (build 19041) aisla los requests de resolucion POR PROCESO. Desde ahi,
        # CurrentMs NO refleja configuracion: refleja lo que pida la app que este corriendo en
        # ese instante. Lo unico accionable es GlobalTimerResolutionRequests, que devuelve el
        # comportamiento global. Por eso se leen juntos: puntuar CurrentMs a secas castiga
        # maquinas bien configuradas solo porque en ese segundo nadie pedia 0.5ms.
        # Ref: https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod
        #   Measure-AXETimerSweep usa este MISMO corte para su aviso. Uso 22000 (Win11) hasta
        #   2026-07-19, con lo que los builds 19041-19045 aislaban y no recibian el aviso.
        $isolated = ([Environment]::OSVersion.Version.Build -ge 19041)
        $gtrr = $null
        try {
            # Cmdlet nativo a posta, sin Get-RV: esta funcion corre tambien en runspaces de
            # fondo (GUI) donde solo estan las funciones de la lista blanca.
            $gtrr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' `
                        -Name 'GlobalTimerResolutionRequests' -EA Stop).GlobalTimerResolutionRequests
        } catch {}
        [pscustomobject]@{
            CurrentMs        = [math]::Round($cur/10000.0,4)
            MinMs            = [math]::Round($min/10000.0,4)   # peor (mayor numero)
            MaxMs            = [math]::Round($max/10000.0,4)   # mejor posible (menor numero)
            PerProcess       = $isolated                        # CurrentMs es ambiental, no config
            GlobalRequests   = $gtrr                            # $null = clave ausente
        }
    } catch { $null }
}

function Set-AXETimerResolution {
    # $Ms en milisegundos -> unidades de 100ns. -Release suelta el request de ESTE proceso.
    # Devuelve la resolucion resultante en ms, o $null si el kernel la rechazo.
    param([double]$Ms,[switch]$Release)
    try {
        $cur=0
        if($Release){
            # STATUS_TIMER_RESOLUTION_NOT_SET (0xC0000245) si no habia request nuestro: no es error.
            [void][AXE.Native]::NtSetTimerResolution(0,$false,[ref]$cur)
        } else {
            $units=[uint32][math]::Round($Ms*10000.0)
            if([AXE.Native]::NtSetTimerResolution($units,$true,[ref]$cur) -ne 0){ return $null }
        }
        [math]::Round($cur/10000.0,4)
    } catch { $null }
}

function Get-AXESweepVerdict {
    # Decide si el barrido encontro algo REAL o esta persiguiendo ruido. Pura (no mide) para
    # poder testearla sin hardware: ver tests/TimerSweep.Tests.ps1.
    #
    # Reemplaza al test anterior ($spread -gt $best.StdevMs), que fallaba por dos motivos:
    #
    #  1. ARGMIN DE N PUNTOS RUIDOSOS. Coger el minimo de ~50 medias con ruido y luego
    #     preguntar "el spread supera al ruido?" es la maldicion del ganador: el minimo de N
    #     sorteos cae sistematicamente por debajo del minimo real, asi que sale un spread de
    #     3-4 sigmas SOLO POR AZAR, sin que haya efecto. Medido en Win11 26200: declaro
    #     concluyente ganando por 0.001ms (spread 0.250 vs stdev 0.249).
    #     Arreglo: umbral Bonferroni sobre el numero de comparaciones, y el error estimado con
    #     la varianza AGRUPADA entre pasadas (dof grande) en vez de la stdev intra-punto de un
    #     solo punto, que con 2-3 pasadas no estima nada.
    #
    #  2. NO COMPROBABA LA FISICA. Sleep(1) con granularidad R despierta en el primer tick
    #     >= 1ms, o sea ceil(1/R)*R, luego el delta teorico es ceil(1/R)*R-1: CRECIENTE entre
    #     0.5 y 1.0ms. En la maquina medida el delta DECRECIA - curva invertida. Eso significa
    #     que lo medido es overhead de despertar del scheduler (~0.4ms), no cuantizacion del
    #     timer (rango total 0.2ms): la senal esta enterrada bajo el ruido.
    #     Sin este chequeo la estadistica sola SI daba "concluyente" en ese barrido, o sea que
    #     arreglar solo el punto 1 no habria bastado.
    #
    # Ambas condiciones son necesarias. Devuelve Reason para que la UI diga POR QUE.
    param([object[]]$Points)

    $P = @($Points | Where-Object { $_ -and @($_.PassMeans).Count -ge 1 })
    if($P.Count -le 1){
        return [pscustomobject]@{
            Conclusive  = $false
            Reason      = 'un solo punto concedido: el kernel cuantizo todo, no hay nada que elegir.'
            Best        = $(if($P.Count -eq 1){ $P[0] } else { $null })
            Worst       = $null
            SpreadMs    = 0.0
            ThresholdMs = 0.0
            ModelR      = $null
        }
    }

    $stats = @(foreach($p in $P){
        $pm = @($p.PassMeans)
        [pscustomobject]@{
            Point     = $p
            AppliedMs = [double]$p.AppliedMs
            Mean      = ($pm | Measure-Object -Average).Average
            N         = $pm.Count
        }
    })

    # Varianza agrupada entre pasadas. Cada punto aporta pocos grados de libertad (2-3
    # pasadas), pero el ruido del scheduler es el mismo en todas las resoluciones, asi que
    # agrupar da dof ~= 2*N y una estimacion usable. Es el MSE de un ANOVA de un factor.
    $ss = 0.0; $dof = 0
    foreach($s in $stats){
        if($s.N -lt 2){ continue }
        foreach($x in @($s.Point.PassMeans)){ $d = [double]$x - $s.Mean; $ss += $d*$d }
        $dof += ($s.N - 1)
    }
    $pooledVar = $(if($dof -gt 0){ $ss / $dof } else { 0.0 })

    $best   = $stats | Sort-Object Mean | Select-Object -First 1
    $worst  = $stats | Sort-Object Mean -Descending | Select-Object -First 1
    $spread = $worst.Mean - $best.Mean
    $seDiff = [math]::Sqrt($pooledVar * (1.0/$best.N + 1.0/$worst.N))

    # Bonferroni: el mejor se compara contra los otros N-1 puntos, asi que el umbral sube con
    # N. Valores = z bilateral a alpha=0.05/comparaciones. Interpolado con Get-AXEBand para no
    # meter una inversa de la normal por 7 numeros. Aproximado a posta: entre z=3.3 y z=4.0
    # casi nunca cambia el veredicto; lo que importa es que CREZCA con N.
    $nComp = $stats.Count - 1
    $k = Get-AXEBand -x $nComp -pairs @(@(1,1.96),@(2,2.24),@(5,2.58),@(10,2.81),@(20,3.02),@(50,3.29),@(100,3.48))
    $threshold = $k * $seDiff
    $statOk = $(if($seDiff -gt 0){ $spread -gt $threshold } else { $spread -gt 0 })

    # Modelo fisico: delta teorico = ceil(1/R)*R - 1. Si las resoluciones concedidas predicen
    # todas el mismo delta (p.ej. solo 0.500 y 1.000, ambas 0), el modelo no discrimina: el
    # chequeo se salta porque no puede opinar. Si discrimina, exigimos correlacion positiva.
    $modelR = $null; $modelOk = $true
    $pred = @(foreach($s in $stats){ [math]::Ceiling(1.0/$s.AppliedMs)*$s.AppliedMs - 1.0 })
    $meas = @(foreach($s in $stats){ $s.Mean })
    $mx = ($pred | Measure-Object -Average).Average
    $my = ($meas | Measure-Object -Average).Average
    $sxy = 0.0; $sxx = 0.0; $syy = 0.0
    for($i=0; $i -lt $pred.Count; $i++){
        $dx = $pred[$i] - $mx; $dy = $meas[$i] - $my
        $sxy += $dx*$dy; $sxx += $dx*$dx; $syy += $dy*$dy
    }
    if($sxx -gt 0 -and $syy -gt 0){
        $modelR  = $sxy / [math]::Sqrt($sxx * $syy)
        $modelOk = ($modelR -ge 0.3)
    }

    # Orden a posta: el fallo del modelo es mas fundamental que el estadistico. Si la curva no
    # tiene la forma que dicta la fisica, que el spread sea "significativo" da igual.
    $reason =
        if(-not $modelOk){
            "la curva medida no sigue el modelo de cuantizacion (r={0:F2}): domina el overhead del scheduler, no la resolucion." -f $modelR
        } elseif(-not $statOk){
            "spread {0:F3}ms no supera el umbral {1:F3}ms (ruido entre pasadas x{2:F2} por {3} comparaciones)." -f $spread,$threshold,$k,$nComp
        } else {
            "spread {0:F3}ms supera el umbral {1:F3}ms y la curva sigue el modelo (r={2:F2})." -f $spread,$threshold,$modelR
        }

    [pscustomobject]@{
        Conclusive  = [bool]($modelOk -and $statOk)
        Reason      = $reason
        Best        = $best.Point
        Worst       = $worst.Point
        SpreadMs    = [math]::Round($spread,4)
        ThresholdMs = [math]::Round($threshold,4)
        ModelR      = $(if($null -eq $modelR){ $null } else { [math]::Round($modelR,3) })
    }
}

function Measure-AXETimerSweep {
    # §3.5 - Barrido de resolucion de timer. Motivo: la investigacion de valleyofdoom midio
    # que 0.500ms NO es optima en todas las maquinas (a varios candidatos 0.507ms les daba
    # MENOS delta, y un portatil necesitaba 0.600ms), sin poder explicar por que tras comparar
    # BCD, hardware, timers y version de Windows. O sea: el optimo es POR MAQUINA y hay que
    # medirlo. Esto lo mide en vez de asumirlo.
    #   Senal = delta medio de un Sleep(1). Menor delta = el scheduler despierta mas cerca
    #   de lo pedido. Se reporta tambien stdev: un delta bajo con stdev alta es ruido, no ganancia.
    # Ref: https://github.com/valleyofdoom/TimerResolution
    param(
        [double]$StartMs = 0.5,
        [double]$EndMs   = 0.6,
        [double]$StepMs  = 0.002,
        [int]$Samples    = 200,
        [int]$Passes     = 3
    )
    if(-not ('AXE.Native' -as [type])){ return $null }
    if(-not [AXE.Native].GetMethod('MeasureSleepDelta')){
        Write-AXELog 'AXE.Native cargado sin MeasureSleepDelta (tipo obsoleto en esta sesion). Reinicia AXE.' 'ERR'
        return $null
    }
    if($StepMs -le 0 -or $EndMs -lt $StartMs){ Write-AXELog 'Barrido: rango invalido.' 'ERR'; return $null }

    # Aviso honesto: desde Windows 10 2004 el request es por-proceso salvo que este el flag
    # global. Sin el, el optimo que encontremos vale para AXE, NO para el juego.
    #   El corte es 19041 (Win10 2004), no 22000 (Win11). Con 22000, los builds 19041-19045
    # aislaban igual y NO recibian el aviso: justo las maquinas que mas lo necesitan, porque en
    # Win10 nadie espera este comportamiento. Mismo umbral que Get-AXETimerResolution, que ya lo
    # tenia bien; que los dos sitios usaran cortes distintos era la incoherencia de fondo.
    try {
        if([Environment]::OSVersion.Version.Build -ge 19041 -and
           (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests') -ne 1){
            Write-AXELog 'Sin GlobalTimerResolutionRequests=1 (Win10 2004+): el optimo medido aplica solo a este proceso. Activa lat_timerres y reinicia para que valga a nivel sistema.' 'WARN'
        }
    } catch {}

    $orig = Get-AXETimerResolution
    $proc = [System.Diagnostics.Process]::GetCurrentProcess()
    $prio = $proc.PriorityClass
    $out  = New-Object System.Collections.ArrayList
    try {
        # Prioridad alta: baja el ruido de otros procesos en el delta. No RealTime (puede colgar la UI).
        try { $proc.PriorityClass='High' } catch {}
        # ORDEN ALEATORIO, N PASADAS. Un barrido ascendente de una pasada CONFUNDE resolucion
        # con tiempo: cualquier deriva del sistema durante el barrido (turbo, termica, otro
        # proceso despertando) se leeria como si fuera efecto de la resolucion, porque ambas
        # avanzan juntas. Medido: una pasada ascendente dibujo una curva en U preciosa que
        # NO se puede distinguir de deriva. Aleatorizar rompe esa correlacion; repetir permite
        # medir repetibilidad (ReproMs) en vez de suponerla.
        $plan = New-Object System.Collections.ArrayList
        for($p=0; $p -lt [math]::Max(1,$Passes); $p++){
            for($ms=$StartMs; $ms -le ($EndMs + 1e-9); $ms += $StepMs){ [void]$plan.Add($ms) }
        }
        foreach($ms in ($plan | Sort-Object { Get-Random })){
            $applied = Set-AXETimerResolution -Ms $ms
            if($null -eq $applied){ continue }
            [void][AXE.Native]::MeasureSleepDelta(5)          # warm-up, descartado
            $r = [AXE.Native]::MeasureSleepDelta([int]$Samples)
            [void]$out.Add([pscustomobject]@{
                RequestedMs = [math]::Round($ms,4)
                AppliedMs   = $applied
                AvgDeltaMs  = [math]::Round($r[1],4)
                MaxDeltaMs  = [math]::Round($r[2],4)
                StdevMs     = [math]::Round($r[3],4)
                Samples     = [int]$r[0]
            })
        }
    } finally {
        # Siempre soltar el request y restaurar prioridad, aunque el barrido reviente.
        [void](Set-AXETimerResolution -Release)
        try { $proc.PriorityClass=$prio } catch {}
    }
    if($out.Count -eq 0){ Write-AXELog 'Barrido: el kernel rechazo todas las resoluciones.' 'ERR'; return $null }

    # El kernel CUANTIZA: varios Requested distintos aterrizan en el mismo Applied real.
    # Comparar por Requested fabricaria un "optimo" entre puntos fisicamente identicos
    # (medido: dos filas con Applied=0.50 dieron avgDelta 0.59 y 0.36 - eso es ruido puro).
    # Se agrega por Applied, que es la unica magnitud que el hardware distingue de verdad.
    $agg = New-Object System.Collections.ArrayList
    foreach($grp in ($out | Group-Object AppliedMs)){
        $m = $grp.Group | Measure-Object AvgDeltaMs -Average -Maximum
        [void]$agg.Add([pscustomobject]@{
            # NO usar [double]$grp.Name: Group-Object serializa con la cultura del sistema
            # ("0,5" en es-ES) y el cast [double] parsea con InvariantCulture, donde la coma
            # es separador de MILES -> 0,5 se convierte en 5 y 0,51 en 51. Silencioso y falso.
            # El valor original del grupo no pasa por string, asi que es inmune al locale.
            AppliedMs   = $grp.Group[0].AppliedMs
            # Medias POR PASADA, sin agregar. Son la unidad de observacion del veredicto:
            # pasadas separadas en el tiempo y en orden aleatorio, luego su dispersion SI
            # estima el ruido real. La stdev intra-pasada no, porque las muestras dentro de
            # una pasada estan autocorreladas (el sistema deriva durante los 200 sleeps).
            PassMeans   = @($grp.Group | ForEach-Object AvgDeltaMs)
            AvgDeltaMs  = [math]::Round($m.Average,4)
            MaxDeltaMs  = [math]::Round(($grp.Group | Measure-Object MaxDeltaMs -Maximum).Maximum,4)
            # Stdev intra-punto mas alta del grupo: cota superior honesta del ruido.
            StdevMs     = [math]::Round(($grp.Group | Measure-Object StdevMs -Maximum).Maximum,4)
            # Dispersion ENTRE repeticiones del mismo Applied: si es alta, la medida no es repetible.
            ReproMs     = [math]::Round($m.Maximum - $m.Average,4)
            Passes      = $grp.Count
            Samples     = ($grp.Group | Measure-Object Samples -Sum).Sum
        })
    }
    # Win11 2004+ aisla el request POR PROCESO. Cuando el nuestro no se concede, el sleep cae
    # al default de 15.6ms AUNQUE NtSetTimerResolution reporte exito y devuelva la resolucion
    # del SISTEMA (que otro proceso mantiene). Medido aqui: 10 de 13 puntos reportaron
    # AppliedMs=1.0 mientras dormian 15.6ms reales. El valor reportado MIENTE; el delta no.
    # Por eso el corte es por delta medido, no por lo que dice el kernel.
    $granted    = @($agg | Where-Object { $_.AvgDeltaMs -lt 5.0 })
    $notGranted = @($agg | Where-Object { $_.AvgDeltaMs -ge 5.0 })
    if($notGranted.Count -gt 0){
        Write-AXELog "Barrido: $($notGranted.Count) de $($agg.Count) resoluciones no se concedieron a este proceso (sleeps de ~15.6ms). Sintoma tipico del aislamiento por-proceso de Win11: activa lat_timerres y reinicia." 'WARN'
    }
    if($granted.Count -eq 0){
        Write-AXELog 'Barrido: ningun request concedido. Sin datos utiles.' 'ERR'
        return $null
    }
    # Comparar SOLO entre resoluciones concedidas. Mezclar concedidas con fallbacks a 15.6ms
    # daria un spread enorme y un "Conclusive" falso: mediria "obtener el request vs no
    # obtenerlo", que no es la pregunta. La pregunta es cual resolucion concedida es mejor.
    # El veredicto vive en Get-AXESweepVerdict: logica pura, con tests, sin hardware. Aqui solo
    # se mide. Antes se decidia inline y por eso el bug (comparar contra la stdev intra-punto)
    # sobrevivio: no habia forma de testearlo sin un barrido real de 60s.
    $v = Get-AXESweepVerdict -Points $granted
    [pscustomobject]@{
        Results      = @($granted)
        NotGranted   = @($notGranted)
        Raw          = @($out)
        Best         = $v.Best
        Worst        = $v.Worst
        SpreadMs     = $v.SpreadMs
        ThresholdMs  = $v.ThresholdMs
        ModelR       = $v.ModelR
        Reason       = $v.Reason
        OriginalMs   = $(if($orig){ $orig.CurrentMs } else { $null })
        DistinctRes  = $granted.Count
        Passes       = $Passes
        Conclusive   = $v.Conclusive
    }
}

function Format-AXETimerSweep {
    # Render compartido CLI (-TimerSweep) / GUI (boton "Barrido de timer"). Vive aqui y no en
    # cada consumidor porque el texto dice si el resultado es concluyente o ruido: si cada UI
    # se escribe el suyo, una acaba recomendando un valor que la otra declara no concluyente.
    # Devuelve string[] (una linea por elemento); el consumidor decide como pintarlo.
    param($Sweep)
    # OJO: devolver '@(...)' pelado, NO ',@(...)'. La coma unaria envuelve el array en OTRO
    # array, asi que el llamante recibe UN elemento (el array entero) en vez de N lineas: el
    # foreach del CLI itera una vez y el -join de la GUI concatena con espacios. Resultado
    # medido: las 6 lineas del informe salian pegadas en un renglon.
    if(-not $Sweep){ return @('Sin datos utiles (ver log).') }
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('Resolucion  avgDelta   stdev    pasadas')
    foreach($r in ($Sweep.Results | Sort-Object AppliedMs)){
        [void]$L.Add(("  {0,6:F3}ms  {1,7:F3}ms {2,7:F3}ms  {3,4}" -f $r.AppliedMs,$r.AvgDeltaMs,$r.StdevMs,$r.Passes))
    }
    if($Sweep.NotGranted.Count -gt 0){
        $np = ($Sweep.NotGranted | Measure-Object Passes -Sum).Sum
        [void]$L.Add('')
        [void]$L.Add("AVISO: $np request(s) no concedidos a este proceso (sleeps de ~15.6ms).")
        [void]$L.Add('       Sintoma del aislamiento por-proceso de Win11. Activa lat_timerres y reinicia.')
    }
    [void]$L.Add('')
    if($Sweep.Conclusive){
        [void]$L.Add(("MEJOR : {0:F3}ms  (delta medio {1:F3}ms)" -f $Sweep.Best.AppliedMs,$Sweep.Best.AvgDeltaMs))
        [void]$L.Add(("        {0}" -f $Sweep.Reason))
    } else {
        # Honestidad: el caso comun. valleyofdoom midio que el optimo es por-maquina y a
        # menudo cae dentro del margen de error. Recomendar un valor aqui seria inventar.
        # El motivo concreto lo da Get-AXESweepVerdict y puede ser de dos tipos: ruido
        # estadistico, o que la curva no siga el modelo fisico (entonces lo que se esta
        # midiendo es el overhead del scheduler, no la resolucion del timer).
        # Se imprime Reason y NO $Sweep.Best.StdevMs: con un solo punto concedido Best es
        # $null y el formato anterior reventaba justo en el caso que queria explicar.
        [void]$L.Add(("NO CONCLUYENTE: {0}" -f $Sweep.Reason))
        [void]$L.Add('       En esta maquina no hay diferencia real entre las resoluciones probadas.')
        [void]$L.Add('       Dejalo como esta: afinar aqui seria perseguir ruido.')
    }
    [void]$L.Add(("Resolucion restaurada a: {0}ms" -f $Sweep.OriginalMs))
    @($L)
}

function Measure-AXEJitter {
    # PROXY de latencia (no atribuible a driver concreto). El busy-loop corre en C#
    # nativo; en la GUI se invoca [AXE.Native]::SampleJitter en un runspace de fondo.
    param([int]$DurationMs=1000)
    try {
        $r = [AXE.Native]::SampleJitter([int]$DurationMs)
        [pscustomobject]@{
            Samples   = [int]$r[0]
            MeanMs    = [math]::Round($r[1],4)
            MaxMs     = [math]::Round($r[2],4)
            P999Ms    = [math]::Round($r[3],4)
            Stalls1ms = [int]$r[4]
        }
    } catch { $null }
}

function Get-AXESnapshot {
    # Snapshot honesto. Cada campo en su try/catch -> 'n/a', nunca aborta.
    # Timer + cobertura son instantaneos (UI-thread OK); el jitter (1s) es el unico
    # que la GUI empuja a un runspace (ver 57-gui-handlers). En CLI corre inline.
    param([int]$JitterMs=1000)
    $timer='n/a'; try { $t=Get-AXETimerResolution; if($t){ $timer=$t } } catch {}
    $jit='n/a';   try { $j=Measure-AXEJitter -DurationMs $JitterMs; if($j){ $jit=$j } } catch {}
    $on='n/a'; $app='n/a'
    try {
        $onN=0; $appN=0
        foreach($tw in $script:CAT){
            if($tw.Tier -notin 0,1){ continue }        # cobertura = Tier 0/1 (seguros/elite)
            if(Get-BlockReason $tw){ continue }          # no aplicable en este HW
            $appN++
            if(Test-TweakSafe $tw){ $onN++ }
        }
        $on=$onN; $app=$appN
    } catch {}
    [pscustomobject]@{
        Timestamp        = (Get-Date).ToUniversalTime().ToString('u')
        Timer            = $timer
        Jitter           = $jit
        TweaksOn         = $on
        TweaksApplicable = $app
    }
}

function Get-AXEBand {
    # Interpolacion lineal por tramos: $pairs = @(@(x0,y0),@(x1,y1),...) x ASCENDENTE.
    # Devuelve y clamped al rango de los extremos.
    param([double]$x,[object[]]$pairs)
    if($x -le $pairs[0][0]){ return [double]$pairs[0][1] }
    $last=$pairs.Count-1
    if($x -ge $pairs[$last][0]){ return [double]$pairs[$last][1] }
    for($i=0;$i -lt $last;$i++){
        $x0=[double]$pairs[$i][0]; $y0=[double]$pairs[$i][1]
        $x1=[double]$pairs[$i+1][0]; $y1=[double]$pairs[$i+1][1]
        if($x -ge $x0 -and $x -le $x1){
            $f=($x-$x0)/($x1-$x0); return $y0 + $f*($y1-$y0)
        }
    }
    return [double]$pairs[$last][1]
}
function Get-AXEScore {
    param($snap,[pscustomobject]$prev=$null)
    $lines=New-Object System.Collections.ArrayList
    $naCount=0

    # Timer 30. Se puntua la CONFIGURACION, no la resolucion instantanea.
    #
    # Antes se puntuaba Get-AXEBand(CurrentMs) a secas. En build 19041+ eso esta mal: el kernel
    # aisla los requests por proceso, asi que CurrentMs dice lo que pedia OTRA app en ese
    # segundo, no como esta configurado el equipo. Medido en Win11 26200 con lat_timerres YA
    # aplicado (GlobalTimerResolutionRequests=1): marcaba 1ms -> 20/30, presentando como fallo
    # de config algo que el usuario no puede arreglar y que ademas ya tenia bien.
    #
    # Ahi el unico ajuste accionable es GlobalTimerResolutionRequests, que es binario. En
    # builds anteriores los requests SI son globales, luego CurrentMs refleja config de verdad
    # y se mantiene la banda de siempre.
    if($snap.Timer -is [string]){ $timer='n/a'; $naCount++; [void]$lines.Add('Timer     : n/a') }
    elseif($snap.Timer.PerProcess){
        if($snap.Timer.GlobalRequests -eq 1){
            $timer=30
            [void]$lines.Add(("Timer     : {0,3}/30  (config OK; ahora {1}ms, lo fija la app en primer plano)" -f $timer,$snap.Timer.CurrentMs))
        } else {
            # No es 0: sin el flag el equipo funciona y las apps que piden resolucion la
            # obtienen para si mismas. Lo que se pierde es que el ajuste valga a nivel sistema.
            # Parcial, y el numero es un flag de config, no una medida.
            $timer=15
            [void]$lines.Add(("Timer     : {0,3}/30  (GlobalTimerResolutionRequests ausente: aplica lat_timerres y reinicia)" -f $timer))
        }
    }
    else {
        $timer=[int][math]::Round((Get-AXEBand ([double]$snap.Timer.CurrentMs) @(@(0.5,30),@(1.0,20),@(5.0,8),@(15.6,0))))
        [void]$lines.Add(("Timer     : {0,3}/30  ({1}ms)" -f $timer,$snap.Timer.CurrentMs))
    }
    # Jitter 35: menor P99.9 = mas puntos
    if($snap.Jitter -is [string]){ $jit='n/a'; $naCount++; [void]$lines.Add('Jitter    : n/a') }
    else {
        $jit=[int][math]::Round((Get-AXEBand ([double]$snap.Jitter.P999Ms) @(@(0.3,35),@(1.0,20),@(2.0,8),@(5.0,0))))
        [void]$lines.Add(("Jitter    : {0,3}/35  (P99.9 {1}ms, proxy)" -f $jit,$snap.Jitter.P999Ms))
    }
    # Cobertura 25: fraccion Tier0/1 aplicables activas. Guarda div/0.
    if($snap.TweaksApplicable -is [string] -or [int]$snap.TweaksApplicable -eq 0){
        $cov='n/a'; $naCount++; [void]$lines.Add('Cobertura : n/a')
    } else {
        $cov=[int][math]::Round(25.0 * ([int]$snap.TweaksOn / [int]$snap.TweaksApplicable))
        [void]$lines.Add(("Cobertura : {0,3}/25  ({1}/{2} Tier0/1)" -f $cov,$snap.TweaksOn,$snap.TweaksApplicable))
    }
    # Idle 10: sin regresion de jitter vs prev (10 si no hay prev). Deadband via 36-report.
    $idle=10
    if($prev -and $prev.Jitter -isnot [string] -and $snap.Jitter -isnot [string]){
        $pv=[double]$prev.Jitter.P999Ms; $cv=[double]$snap.Jitter.P999Ms
        $band=[math]::Max(0.1,$pv*0.10)
        if($cv -gt ($pv + $band)){
            $worse=[math]::Min(1.0, ($cv-$pv)/[math]::Max($pv,0.1))
            $idle=[int][math]::Round(10*(1-$worse))
        }
    }
    [void]$lines.Add(("Idle      : {0,3}/10" -f $idle))

    $total=0
    foreach($c in @($timer,$jit,$cov,$idle)){ if($c -isnot [string]){ $total+=[int]$c } }
    if($total -lt 0){ $total=0 }; if($total -gt 100){ $total=100 }
    if($naCount -gt 0){ [void]$lines.Add("(score parcial: $($naCount) componente(s) n/a)") }

    [pscustomobject]@{
        Total=$total; Timer=$timer; Jitter=$jit; Coverage=$cov; Idle=$idle
        Breakdown=($lines -join "`r`n")
    }
}
