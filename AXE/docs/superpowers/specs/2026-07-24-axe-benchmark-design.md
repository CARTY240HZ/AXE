# AXE Benchmark — "Pruébalo en tu PC" (subproyecto C)

**Fecha:** 2026-07-24
**Estado:** Diseño aprobado (jefe de orquestación). Pendiente: writing-plans → implementación.
**Rama:** axe
**Decisión de diseño:** Opción 1 — dos fases, humano en el loop.

---

## 1. Propósito

Producir **prueba MEDIBLE y compartible** del efecto real de AXE en la máquina del usuario, con
la misma honestidad que el resto del motor: veredicto de ruido explícito, `null` cuando algo no se
puede medir, **cero cifras inventadas**. Es el diferenciador que hone.gg / atlaspro / deltapro no
pueden copiar sin rehacer su producto: ellos muestran "scores" fabricados; AXE muestra el delta real
con su intervalo de ruido y admite cuando el cambio no es concluyente.

## 2. No-goals (YAGNI)

- **NO** auto-resume por RunOnce tras reinicio (frágil: elevación/timing/anti-cheat; esconde el
  apply; contradice la política "no automatizar lo que necesita un humano" de `-FpsCompare`).
- **NO** auto-mezclar FPS in-game en el flujo de sistema (necesita humano + misma escena; ya existe
  `-Fps -FpsCompare`, se referencia, no se absorbe).
- **NO** telemetría ni subida a servidor (el reporte es un archivo local que el usuario comparte si
  quiere).
- **NO** un "score de marketing" agregado con pesos opacos. El reporte enseña las métricas crudas +
  su veredicto.

## 3. Arquitectura

Módulo nuevo `src/41-bench.ps1` (numeración: después de `40-session`, antes de `45-cli`; el build
concatena por orden de nombre, así que las funciones existen cuando `45-cli` las despacha). Reusa el
motor de medición de `32-measure.ps1` sin duplicar lógica.

Flujo de dos fases (humano decide apply + reboot en medio):

```
Fase BASELINE:   AXE -Benchmark
  Measure-AXEBenchSample (N pasadas) -> agregado {mediana, IQR} por métrica
  Save-AXEBenchBaseline -> AXE/bench/<id>.json  (id = timestamp corto)
  imprime: "aplica tweaks + reinicia, luego:  AXE -Benchmark -After <id>"

  [ el usuario aplica lo que quiera y reinicia — fuera del alcance del script ]

Fase AFTER:      AXE -Benchmark -After <id>
  Read-AXEBenchBaseline <id>  (valida hash HW+build; aborta si no coincide)
  Measure-AXEBenchSample (N pasadas) -> agregado {mediana, IQR}
  Get-AXEBenchVerdict (before, after) -> por métrica: mejor/peor/ruido + magnitud
  New-AXEBenchReport -> txt (CLI) + JSON + Markdown compartible (sin PII)
```

## 4. Métricas (sistema, headless — sin juego)

Todas ya existentes en `32-measure.ps1`, se muestrean N veces y se agregan:

| Métrica | Fuente existente | Dirección buena |
|---|---|---|
| Jitter P99.9 (µs/ms) | `Measure-AXEJitter` (native `SampleJitter`) | menor |
| Jitter media | `Measure-AXEJitter` | menor |
| Timer resolution (ms) | `Get-AXETimerResolution` | menor |
| AXE Score (0–100) | `Get-AXEScore (Get-AXESnapshot)` | mayor |
| Tweaks on / aplicables | `Get-AXESnapshot` | contexto |

DPC: **no** se mide directo (no hay API userland honesta); el jitter P99.9 es el proxy y así se
etiqueta en el reporte (misma postura que el motor actual). FPS 1% low: sección **opcional** del
reporte que referencia `-FpsCompare` — el benchmark de sistema NO la ejecuta.

## 5. Componentes (contratos)

- `Measure-AXEBenchSample([int]$Passes=7, [int]$JitterMs=250) -> [pscustomobject]`
  Corre `$Passes` muestras de cada métrica de sistema. Devuelve por métrica **mediana + IQR**
  (cuartil3−cuartil1), NO una sola muestra: el ruido se MIDE, no se asume. Native ausente → esa
  métrica viaja `null` (honesto), no 0. Puro salvo lectura de hardware.

- `Get-AXEBenchVerdict($before, $after) -> [pscustomobject[]]`  **(función pura, testeable)**
  Por métrica: `delta = medianaAfter − medianaBefore`. Concluyente **solo si**
  `abs(delta) > $k * (IQRbefore + IQRafter)` con `$k` conservador (arranque 1.0, ajustar con datos).
  Aplica la lección del timer-flakiness (2026-07-19): un delta por debajo del ruido combinado NO es
  concluyente, se etiqueta `ruido`. Nunca declara mejora dentro del margen de ruido.

- `Save-AXEBenchBaseline($sample) -> [string]$id` / `Read-AXEBenchBaseline($id) -> $sample|$null`
  Persisten en `AXE/bench/<id>.json`. Incluyen **hash de identidad** = hash(CpuName + RamGB +
  GpuVendor + BuildNumber + AXEVersion). `Read` en fase After valida el hash: mismatch → aborta
  "no comparable (otra máquina/estado o build distinta)". Corrupto/ausente → `$null` + mensaje.

- `New-AXEBenchReport($before, $after, $verdict) -> [pscustomobject]{ Text; Json; Markdown }`
  Tres representaciones del MISMO dato. **Sin PII**: HW = modelo CPU + RAM + vendor GPU + build; NO
  serial, NO nombre de usuario, NO IP. El Markdown es el compartible ("mi ganancia real en AXE").

## 6. Superficie CLI / puente

- CLI (`45-cli.ps1`, patrón de los demás bloques `if($Switch){...; exit}`):
  - `-Benchmark`              → fase baseline (imprime id + instrucciones).
  - `-Benchmark -After <id>`  → fase after (imprime reporte txt; `-Report <file>` escribe json+md).
  - Nuevos params en `00-header.ps1`: `[switch]$Benchmark`, `[string]$After`. **Verificar colisión**
    de nombres contra el resto de `src/` antes de añadir (lección `$Games`/S24) y añadir S24-check si
    usan variables de ruta.
- Puente (`48-webbridge.ps1`, whitelist cerrada): `bench.baseline` / `bench.after`. Añadir al mapa +
  el frontend debe referenciarlos (S-webui-3 exige mapeo 1:1). Pantalla webui = fase posterior del
  subproyecto, no bloquea la CLI.

## 7. Datos — `AXE/bench/<id>.json`

```json
{
  "id": "20260724-1224",
  "axeVersion": "7.0.0",
  "hwHash": "sha256:...",
  "hw": { "cpu": "Ryzen 7 5800X", "ramGB": 31.9, "gpuVendor": "NVIDIA", "build": 26200 },
  "ts": "2026-07-24T12:24:00Z",
  "metrics": {
    "jitterP999Ms": { "median": 0.42, "iqr": 0.05, "passes": 7 },
    "jitterMeanMs": { "median": 0.011, "iqr": 0.002, "passes": 7 },
    "timerMs":      { "median": 0.98, "iqr": 0.01, "passes": 7 },
    "score":        { "median": 61, "iqr": 2, "passes": 7 }
  }
}
```

`AXE/bench/` va al `.gitignore` (estado de runtime, como `tweak_state.json`).

## 8. Manejo de errores

- Native `[AXE.Native]` ausente → métricas de jitter `null`, reporte lo dice; el resto (timer/score)
  sigue. No aborta.
- Hash HW mismatch en fase After → aborta con mensaje claro; no produce un delta falso entre máquinas.
- `-After <id>` sin baseline → se niega (igual que `prueba.report` sin baseline). No inventa un antes.
- Todo el bloque es headless y no muta el sistema → seguro en SelfTest/CI (no necesita admin, no crea
  restore points).

## 9. Testing

- **SelfTest S29** (`45-cli.ps1`, patrón S25): ejercita `Get-AXEBenchVerdict` con series sintéticas:
  (a) delta grande y limpio → concluyente `mejor`; (b) delta dentro del ruido → `ruido`
  (no concluyente); (c) delta negativo grande → `peor`; (d) native null → métrica omitida sin lanzar.
  Round-trip `Save/Read-AXEBenchBaseline` en store temporal (no toca `AXE/bench/` real). Report no
  vacío + JSON parseable.
- **Pester** (`tests/Bench.Tests.ps1`): unit del verdict puro (tabla de casos), round-trip baseline,
  ausencia de PII en el reporte (`-notmatch` serial/usuario). Sin tag integration (headless).

## 10. Privacidad / seguridad

Reporte compartible = HW genérico + métricas. Cero identificadores. Firmable con Authenticode cuando
exista el subproyecto A. `connect-src 'none'` de la CSP ya impide que la pantalla webui filtre nada.

## 11. Orden de build (para writing-plans)

1. `src/41-bench.ps1`: `Measure-AXEBenchSample` + `Get-AXEBenchVerdict` (puro primero, TDD con S29).
2. `Save/Read-AXEBenchBaseline` + `.gitignore AXE/bench/`.
3. `New-AXEBenchReport` (txt/json/md).
4. CLI en `45-cli` + params en `00-header` (+ S24 si aplica) + SelfTest S29.
5. Puente `bench.*` en `48-webbridge` + coherencia S-webui-3.
6. `tests/Bench.Tests.ps1`.
7. Rebuild + SelfTest 0 fallos + Pester verde. Pantalla webui = iteración posterior.

## 12. Criterio de "hecho" (elite)

- `-Benchmark` / `-Benchmark -After` funcionan headless, 0 fallos SelfTest, Pester verde.
- El verdict NUNCA declara mejora dentro del ruido (regresión-test lo prueba).
- Reporte reproducible, sin PII, con la misma honestidad textual que la CLI actual.
- Un tercero puede correr el mismo protocolo y verificar el claim → ataca directo la credibilidad de
  los "scores" fabricados del mercado.
