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
