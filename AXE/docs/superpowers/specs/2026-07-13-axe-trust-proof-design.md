# AXE — Sub-proyecto A: "Trust & Proof" (medición + prueba + confianza)

- **Fecha**: 2026-07-13
- **Estado**: Diseño aprobado (secciones 1-4 en brainstorming). Pendiente: plan de implementación.
- **Proyecto**: AXE v6 (`C:\Users\khawa\Downloads\Libreria windows\AXE`), branch `axe`.
- **Spec previo relacionado**: `docs/superpowers/specs/2026-07-12-axe-v6-elite-design.md` (arquitectura base modular).

---

## 1. Problema y objetivo

AXE ya aplica ~55 tweaks de gaming con reversibilidad 100%, gating por hardware y GUI WPF. Lo que le falta para pasar de "tweaker sólido" a "optimizador de mercado" es **prueba**: hoy el usuario aplica cambios y confía a ciegas. Los optimizadores comerciales (y WinUtil) tampoco lo hacen bien — es el mayor diferenciador disponible.

**Objetivo del sub-proyecto A**: que AXE **mida el sistema antes y después**, genere un **reporte de delta honesto**, calcule un **AXE Score (0-100) transparente y desglosado**, y proteja cada sesión con un **punto de restauración best-effort**. Todo con **cero dependencias** (encaja el ADN single-`.ps1`), sin `wpr`/`xperf`/LatencyMon.

### No-objetivos (YAGNI)

- NO benchmark de FPS in-game (requiere overlay/hook por juego — otro producto).
- NO desglose por-driver de latencia (imposible honestamente con método 0-deps; el sampler es **proxy**, no LatencyMon).
- NO forzar activar System Restore ni reservar disco sin permiso.
- NO instalar nada, NO telemetría, NO red saliente.
- La medición/restore **jamás** bloquean el apply (ver §7).

---

## 2. Arquitectura (3 módulos nuevos + wiring)

El build (`build.ps1`) concatena `src/*.ps1` por orden alfabético. Los nuevos módulos encajan solos entre `30-profiles.ps1` y `45-cli.ps1`:

| Módulo | Responsabilidad | Depende de |
|---|---|---|
| `32-measure.ps1` | Snapshot del sistema (timer resolution + jitter/stall) + AXE Score | `05-core` (Write-AXELog), `$script:CAT` |
| `34-safety.ps1` | `New-AXERestorePoint` best-effort, nunca lanza | `05-core` |
| `36-report.ps1` | Reporte delta antes/después + export JSON | `32-measure`, estilo `28-revert-export` |

Wiring (edición de módulos existentes):
- `45-cli.ps1` — verbos `-Measure`, `-Score`, `-Report <file>`.
- `55-gui-actions.ps1` / `57-gui-handlers.ps1` — envuelve apply (snap→restore→apply→snap→report) + botón "Medir ahora".
- `50-xaml.ps1` / `52-gui-build.ps1` — panel Score + textbox reporte + botón.
- `60-gui-selftest.ps1` — extiende SelfTest para las funciones nuevas.

**Regla de aislamiento**: todas las funciones de medición son *runspace-safe* — devuelven objetos/strings, NO llaman a la GUI ni a `Write-AXELog` desde el runspace de fondo (siguen el patrón existente). Cada una envuelve su cuerpo en `try/catch` y degrada a `n/a` en fallo.

**Compatibilidad**: corre en `powershell.exe` (PS 5.1, ruta GUI) y `pwsh` (PS7, ruta SelfTest). Nada de sintaxis PS7-only. P/Invoke vía `Add-Type` con guarda de "tipo ya cargado".

---

## 3. `32-measure.ps1` — medición

### 3.1 Timer resolution (exacto, P/Invoke)

```
NtQueryTimerResolution(out uint Min, out uint Max, out uint Current)  // ntdll, unidades de 100ns
```

- `Add-Type` define la firma una sola vez (guarda: `if(-not ('AXE.Native' -as [type]))`), **cargado al init del módulo en el hilo principal** (no lazy dentro del runspace de fondo → evita race/doble-compilación). El tipo queda en el AppDomain y el runspace lo ve.
- `Get-AXETimerResolution` → `[pscustomobject]{ CurrentMs; MinMs; MaxMs }` (Current/10000). `$null` si falla.
- Interpretación: menor = mejor. Default Windows ≈ 15.6ms; objetivo gaming ≤ 1.0ms; ideal 0.5ms.
- **No requiere admin** → la medición (y el AXE Score) funcionan antes de elevar.

### 3.2 Jitter / stall sampler (proxy honesto, QPC en C# compilado)

- **El loop de muestreo se implementa en C# compilado vía `Add-Type`** (mismo bloque nativo que §3.1), NO en un loop de PowerShell. Motivo: el intérprete PS añade µs y jitter de GC por iteración que dominarían la señal → un loop PS mediría el intérprete, no el scheduler. El método C# hace un busy-loop leyendo `Stopwatch.GetTimestamp()` (QPC), registra el gap entre lecturas sucesivas y devuelve el array de gaps (o stats precalculadas) al llamador PowerShell.
- Duración `[int]$DurationMs` (default 1000; **50 en modo test**). Un gap grande = el hilo fue expropiado (DPC/ISR/scheduler) → **proxy** de latencia.
- `Measure-AXEJitter([int]$DurationMs=1000)` → `[pscustomobject]{ Samples; MeanMs; MaxMs; P999Ms; Stalls1ms }`.
  - `P999Ms` = percentil 99.9 del gap. `Stalls1ms` = cuenta de gaps > 1ms.
- C# mantenido **compat-safe** (compila bajo csc de PS 5.1 y Roslyn de PS7): sin `record`, sin miembros expression-bodied, sintaxis C# 5.
- **Etiqueta obligatoria en toda salida**: "proxy de latencia (no atribuible a driver concreto)".

### 3.3 Snapshot

- `Get-AXESnapshot([int]$JitterMs=1000)` → `[pscustomobject]`:
  ```
  { Timestamp; Timer=<3.1 o 'n/a'>; Jitter=<3.2 o 'n/a'>; TweaksOn=<int>; TweaksApplicable=<int> }
  ```
  - `TweaksOn` / `TweaksApplicable`: recorre `$script:CAT` Tier 0/1 no bloqueados (`Get-BlockReason`), cuenta cuántos dan `Test`=$true. Reusa `Test-TweakSafe` de `28-revert-export`.
  - Cada campo en su propio `try/catch` → `n/a` sin abortar el snapshot.

### 3.4 AXE Score (0-100, transparente)

`Get-AXEScore($snap, [pscustomobject]$prev=$null)` → `[pscustomobject]{ Total; Timer; Jitter; Coverage; Idle; Breakdown }`.

Reparto (documentado en `Breakdown` como texto legible, no caja negra):

| Componente | Peso | Mapeo |
|---|---|---|
| Timer resolution | 30 | ≤0.5ms→30 · 1.0ms→20 · 5ms→8 · ≥15ms→0 (banda lineal) |
| Jitter (P999) | 35 | <0.3ms→35 · 1ms→20 · 2ms→8 · ≥5ms→0 |
| Cobertura Tier0/1 | 25 | 25 × (TweaksOn / TweaksApplicable) |
| Sin regresión idle | 10 | 10 si no hay `prev`; si hay, resta proporcional sólo si `snap.Jitter.P999Ms` empeora más allá del deadband (§5) vs `prev` |

- **Guarda div/0**: si `TweaksApplicable = 0` (todo bloqueado por hardware) → componente cobertura = `n/a` (no 0/0), y se documenta en `Breakdown`.
- La métrica de regresión idle es **jitter P999** (no el timer, que cambiamos a propósito): penaliza sólo si aplicar empeoró el jitter de forma real (fuera del deadband).
- Campos `n/a` → ese componente aporta 0 y se marca `n/a` en `Breakdown` (score parcial honesto, nunca inventado).
- `Total` = suma redondeada, clamp [0,100]. Si hay componentes `n/a`, `Breakdown` indica "score parcial (N/100 medibles)".

---

## 4. `34-safety.ps1` — punto de restauración best-effort

`New-AXERestorePoint([string]$Desc='AXE optimizacion')` → `[pscustomobject]{ Status; Message }`, **nunca lanza**.

Flujo:
1. Si `$env:AXE_NOSR` está seteada (build gate / test) → `Status='fallback'`, message "SR omitido (modo test)". No crea nada.
2. Try `Checkpoint-Computer -Description $Desc -RestorePointType MODIFY_SETTINGS`.
   - OK → `Status='ok'`.
3. Catch (SR deshabilitado, o throttle 24h `SystemRestorePointCreationFrequency`, o SKU sin SR) → `Status='fallback'`, message explica y **apunta a las redes que AXE ya tiene**: backups `.reg` por-clave (`Backup-RegKey`) + `Export-AXEProfile`. NO intenta activar SR.
4. Cualquier otro error → `Status='error'`, message con `$_.Exception.Message`.

**Ejecución**: `Checkpoint-Computer` bloquea 10-60s → corre **dentro del runspace de fondo** (nunca en el hilo UI) con status visible "creando punto de restauración…". Requiere admin (AXE ya está elevado vía `AXE.bat`).

**No bloquea**: el llamador (apply) sigue pase lo que pase; `fallback`/`error` = warning visible, no abort.

---

## 5. `36-report.ps1` — reporte delta + export

- `New-AXEReport($snap0, $snap1, $scoreBefore, $scoreAfter)` → **string** multi-línea (runspace-safe), estilo:
  ```
  === AXE REPORTE ===
  Timer:  15.6ms -> 0.5ms   (mejora)
  Jitter P99.9:  2.1ms -> 0.4ms   (proxy, no por-driver)
  Cobertura Tier0/1:  12/40 -> 38/40
  AXE Score:  31 -> 88   (+57)
  [desglose score...]
  ```
  - Deltas con flecha + etiqueta mejora/igual/regresión. Campos `n/a` se muestran `n/a`, no se calcula delta falso.
  - **Deadband anti-ruido**: timer resolution se compara exacto; para jitter, un delta con |Δ| < `max(0.1ms, 10% del valor previo)` se etiqueta **"igual"** (no "mejora"/"regresión"). Evita que la varianza run-a-run (freq scaling, fondo) se lea como resultado. El deadband se documenta en el reporte.
- `Export-AXEReport($snap0, $snap1, $file)` → JSON (`ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8`), espejo de `Export-AXEProfile`. Incluye ambos snapshots + ambos scores + timestamp.

---

## 6. Wiring en módulos existentes

- **`45-cli.ps1`**:
  - `-Measure` → `Get-AXESnapshot` + `Get-AXEScore`, imprime `Breakdown`.
  - `-Score` → sólo el total + desglose.
  - `-Report <file>` → toma un snapshot ahora y lo exporta a JSON. Combinado con `-Apply` en la misma invocación: snap0 antes, snap1 después, delta completo.
- **`55/57-gui`**: el handler de "Aplicar seleccionados" pasa a envolver (§7). Nuevo botón "Medir ahora" → corre `Get-AXESnapshot` en el runspace de fondo existente, actualiza panel Score sin congelar.
- **`50/52-xaml/gui-build`**: panel nuevo (columna o pestaña) con: número grande AXE Score, barras de los 4 componentes, textbox de reporte (read-only, scroll), botón "Medir ahora". Sigue el estilo XAML actual.
- **`60-gui-selftest.ps1`**: ver §8.

---

## 7. Flujo apply envuelto (garantía de no-bloqueo)

Handler de apply (GUI y CLI `-Apply`):

```
snap0  = Get-AXESnapshot        # try/catch -> n/a, nunca aborta
rp     = New-AXERestorePoint    # best-effort, status ok|fallback|error (nunca lanza)
        # si rp.Status != ok -> warning visible; apply CONTINUA (backups .reg garantizan revert)
<< aplicar tweaks seleccionados >>   # lógica actual intacta
snap1  = Get-AXESnapshot
report = New-AXEReport snap0 snap1 (score snap0) (score snap1)
        # mostrar en panel + log
```

**Invariante duro**: ningún fallo de medición o de restore point impide aplicar u obtener revert. Reversibilidad sigue garantizada por los `.reg` por-clave + `Revert` por-tweak + `Export`/`Import` que ya existen.

---

## 8. Testing (extiende el gate existente)

El build gate corre `-SelfTest` (exige `Fallos: 0`) + GUI harness (exige `LAYOUT OK`). Setear `$env:AXE_NOSR=1` en el gate para no crear puntos de restauración reales durante CI.

Añadir a `60-gui-selftest.ps1`:
- `Get-AXETimerResolution` devuelve objeto con `CurrentMs` numérico **o** `$null` sin lanzar.
- `Measure-AXEJitter -DurationMs 50` devuelve `MaxMs`/`P999Ms` numéricos en <200ms (no congela el gate).
- `Get-AXESnapshot -JitterMs 50` devuelve objeto con los 5 campos.
- `Get-AXEScore` devuelve `Total` en [0,100] con snapshot real y con snapshot `n/a` (parcial).
- `New-AXERestorePoint` con `AXE_NOSR=1` devuelve `Status='fallback'` sin lanzar y sin crear restore point.
- `New-AXEReport` devuelve string no vacío; `Export-AXEReport` escribe JSON parseable.

GUI harness: el panel Score + botón "Medir ahora" presentes en el layout (contribuyen a `LAYOUT OK`).

---

## 9. Riesgos y mitigaciones

| Riesgo | Mitigación |
|---|---|
| Jitter sampler congela UI | Corre sólo en runspace de fondo (patrón GUI actual); en test `DurationMs=50` |
| Loop PS mide el intérprete, no el scheduler | Sampler en **C# compilado** (Add-Type), busy-loop nativo → proxy honesto |
| Ruido run-a-run leído como resultado | Deadband en el reporte (§5); timer exacto, jitter con banda |
| P/Invoke falla en PS7 vs 5.1 | `Add-Type` con guarda de tipo, cargado al init en hilo principal; C# compat-safe (C# 5); test en ambas rutas del gate |
| Checkpoint-Computer congela UI (10-60s) | Corre en runspace de fondo con status "creando punto…" |
| Div/0 en cobertura (todo bloqueado) | `TweaksApplicable=0` → componente `n/a`, no 0/0 |
| Checkpoint-Computer throttle/deshabilitado | best-effort → `fallback`, apunta a redes existentes, no bloquea |
| Score malinterpretado como benchmark absoluto | `Breakdown` transparente + etiqueta "proxy" en jitter; nunca prometer FPS |
| Crear restore points en CI | `AXE_NOSR=1` en el gate |
| Snapshot rompe apply | cada campo en try/catch → `n/a`; apply nunca depende de medición |

---

## 10. Definición de "hecho"

- 3 módulos nuevos + wiring, build gate verde (SelfTest `Fallos: 0` + `LAYOUT OK`).
- `AXE.ps1 -Measure` imprime score desglosado real.
- Apply (GUI/CLI) crea restore point best-effort y muestra reporte antes/después.
- Cada función runspace-safe, degrada a `n/a`, nunca aborta apply.
- Reversibilidad 100% intacta.
- Módulos nuevos < 500 líneas cada uno.
