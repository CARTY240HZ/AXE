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
        [pscustomobject]@{
            CurrentMs = [math]::Round($cur/10000.0,4)
            MinMs     = [math]::Round($min/10000.0,4)   # peor (mayor numero)
            MaxMs     = [math]::Round($max/10000.0,4)   # mejor posible (menor numero)
        }
    } catch { $null }
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

    # Timer 30: mejor (menor ms) = mas puntos
    if($snap.Timer -is [string]){ $timer='n/a'; $naCount++; [void]$lines.Add('Timer     : n/a') }
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
