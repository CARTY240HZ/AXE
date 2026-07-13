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
