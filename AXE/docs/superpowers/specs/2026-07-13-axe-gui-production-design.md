# AXE — Sub-proyecto C: "GUI producción" (dashboard + presets + tema + buscador global)

- **Date:** 2026-07-13
- **Status:** Diseño en revisión (secciones 1-4 presentadas en brainstorming)
- **Depende de:** Sub-proyecto A "Trust & Proof" (v6.1.0-dev, ya en `dist/`). Reusa su motor de medición (`Invoke-AXEMeasure`, `Get-AXEScore`) y su patrón fuente-única (scriptblock autocontenido corrido en runspace).
- **Objetivo:** llevar la GUI de AXE a nivel producción con 4 capacidades: (1) **dashboard live 0-dep** (CPU/RAM/disco/red/uptime + botón de Score), (2) **presets curados** Safe/Gaming/Balanced que reemplazan el preset crudo, (3) **tema claro + toggle** persistido, (4) **buscador global** sobre los 73 tweaks de todas las categorías. Todo manteniendo el ADN single-`.ps1`, 0 dependencias, reversibilidad 100%, gate verde.

## Hallazgos de exploración (verificados contra el código, condicionan el diseño)

- **Buscador YA existe pero es local**: `SearchBox` (XAML `50-xaml.ps1:330`) + handler `$SearchBox.Add_TextChanged` (`57-gui-handlers.ps1:136`) filtra por nombre/desc **solo en la categoría activa**. C lo amplía a global, no lo crea de cero.
- **Preset YA existe pero es crudo**: `$BtnPreset.Add_Click` (`57-gui-handlers.ps1:156`) marca todo Tier<2 sin curación. C lo reemplaza por 3 presets curados.
- **Brushes compartidos (clave del tema)**: los 12 brushes son recursos XAML `SolidColorBrush` (`50-xaml.ps1:61-72`) **sin `Freeze`**. `New-AXEBrush($key){ $win.FindResource($key) }` (`52-gui-build.ps1:2`) devuelve la **misma instancia** del recurso — no una copia. Por tanto XAML (`{StaticResource}`, 72 usos) y código comparten los mismos objetos brush. Mutar `.Color` de la instancia del recurso **re-tematiza toda la GUI en vivo, sin rebuild**.
- **Card reutilizable**: `New-TweakCard($tw)` (`52-gui-build.ps1:48`) construye la tarjeta de un tweak a partir del objeto — reusable para la vista plana de resultados de búsqueda.
- **Schema de tweak**: `Id/Cat/Tier/Reboot/Name/Desc/Requires/Test/Apply/Revert` (`20-tweaks.ps1:4`). Tier 0=Seguro, 1=Elite, 2=EXTREMO(opt-in). Los presets referencian tweaks por **`Id`**; el catálogo es `$script:CAT`.
- **Patrón runspace freeze-safe (de A)**: `Invoke-AXEMeasure` (`57-gui-handlers.ps1:221`) usa `PowerShell.BeginInvoke` + `DispatcherTimer` de sondeo. El dashboard reusa este patrón.
- **Tipo nativo existente**: `AXE.Native` via `Add-Type` (`32-measure.ps1:8`), cargado una vez en el hilo principal, visible en todo runspace (mismo AppDomain).

## Alcance (4 items) y no-goals

**Dentro:** dashboard live 0-dep (solo lectura), presets curados, tema claro+toggle, buscador global.

**Fuera (explícito):**
- **Standby-RAM clean → diferido a sub-proyecto B.** Es una acción que **muta el sistema** (P/Invoke `NtSetSystemInformation` + `AdjustTokenPrivileges` + admin) → pertenece a feature-breadth (B), no a GUI-producción (C). El dashboard de C es **solo lectura**.
- **Sin temperatura**: requiere driver/dep vendor (el competidor bundlea OpenHardwareMonitor con `.sys` solo pa eso). Rompe el ADN 0-dep.
- **Sin FPS in-game**: descartado ya en A (otro producto).
- **Sin auto-seguir el tema de Windows**: toggle manual + persistencia. Default sigue siendo Dark.
- **Presets no aplican solos**: solo marcan casillas; el usuario sigue pulsando APLICAR (conserva review + wrap de medición de A).

## Arquitectura — módulos y wiring

| Archivo | Cambio |
|---|---|
| `src/22-catalogs.ps1` | **+** `$script:PRESETS` (data: 3 listas curadas de `Id`) |
| `src/38-monitor.ps1` | **NUEVO** `$script:LiveMetricsScript` (autocontenido) + `Get-AXELiveMetrics` |
| `src/40-theme.ps1` | **NUEVO** `$script:THEMES` (Dark/Light) + `Set-AXETheme` + `Get-AXETheme` |
| `src/45-cli.ps1` | **+** checks SelfTest S19-S22 |
| `src/50-xaml.ps1` | **+** botón toggle tema + `ComboBox` de presets en el header (junto al `SearchBox`) |
| `src/52-gui-build.ps1` | **+** glyph `'DASHBOARD'` + `'DASHBOARD'` al frente de `$script:actionCats` |
| `src/55-gui-actions.ps1` | **+** case `'DASHBOARD'` en `Build-ActionView` |
| `src/57-gui-handlers.ps1` | **+** helpers dashboard (timer 2s) + start/stop en `Switch-View` + wire tema + wire presets + buscador global (mejora `SearchBox` handler) |
| `src/60-gui-selftest.ps1` | **+** asserts: vista DASHBOARD, control tema, combo presets, RESULTADOS global |
| `src/99-main.ps1` | **+** stop `$script:dashTimer` en `Add_Closed` |

Nuevos módulos ordenados: `38-monitor` (tras `36-report`) y `40-theme` (tras `38`), antes de `45-cli`. Cada uno < 500 líneas.

---

## Sección 1 — Módulos de datos/motor

### `38-monitor.ps1` (dashboard engine, 0-dep, runspace-safe)

Patrón fuente-única (idéntico a `$script:RestorePointScript` de A): el cuerpo que consulta CIM vive **una vez** en un scriptblock autocontenido; el wrapper lo invoca in-process (CLI/test) y el runspace del dashboard inyecta su `.ToString()`.

```powershell
$script:LiveMetricsScript = {
    # 0-dep, autocontenido (sin funciones de sesion) -> corre en runspace.
    # Cada metrica en su try/catch -> 'n/a', nunca lanza.
    $cpu='n/a'; try { $cpu=[int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -EA Stop).PercentProcessorTime } catch {}
    $ramU='n/a';$ramT='n/a';$ramP='n/a';$up='n/a'
    try { $os=Get-CimInstance Win32_OperatingSystem -EA Stop
          $ramT=[int]($os.TotalVisibleMemorySize/1024); $ramU=[int](($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/1024)
          if($ramT){ $ramP=[int](100*$ramU/$ramT) }
          $bt=$os.LastBootUpTime; if($bt){ $ts=(Get-Date)-$bt; $up=('{0}d {1}h {2}m' -f $ts.Days,$ts.Hours,$ts.Minutes) } } catch {}
    $disk='n/a'; try { $disk=[int](Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -EA Stop).PercentDiskTime } catch {}
    $rx='n/a';$tx='n/a'
    try { $ni=Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface -EA Stop | Where-Object { $_.Name -notmatch 'Loopback|isatap|Teredo' }
          $rx=[int](($ni|Measure-Object BytesReceivedPersec -Sum).Sum/1024); $tx=[int](($ni|Measure-Object BytesSentPersec -Sum).Sum/1024) } catch {}
    @{ CpuPct=$cpu; RamUsedMB=$ramU; RamTotalMB=$ramT; RamPct=$ramP; DiskActivePct=$disk; NetRxKBs=$rx; NetTxKBs=$tx; UptimeStr=$up }
}
function Get-AXELiveMetrics { [pscustomobject](& $script:LiveMetricsScript) }
```

- **Contrato**: `Get-AXELiveMetrics` → `pscustomobject{ CpuPct; RamUsedMB; RamTotalMB; RamPct; DiskActivePct; NetRxKBs; NetTxKBs; UptimeStr }`. Cada campo numérico o `'n/a'`. Nunca lanza.
- `DiskActivePct` puede pasar de 100 (contador `PercentDiskTime` de Windows lo permite); la UI lo clampa al pintar.

### `40-theme.ps1` (tema claro + toggle, mutación de brushes en vivo)

```powershell
$script:THEMES = @{
    Dark  = @{ Bg='#1B1B1F';Surface='#26262B';Surface2='#303036';Line='#3A3A42';Fg='#ECECF0';Muted='#9A9AA6';Accent='#2DD4BF';OnAccent='#0B0B0D';Green='#4ADE80';Amber='#FBBF24';Red='#F87171';Purple='#A78BFA' }
    Light = @{ Bg='#F4F4F7';Surface='#FFFFFF';Surface2='#ECECF0';Line='#D6D6DE';Fg='#1B1B1F';Muted='#5A5A66';Accent='#0D9488';OnAccent='#FFFFFF';Green='#16A34A';Amber='#B45309';Red='#DC2626';Purple='#7C3AED' }
}
function Set-AXETheme {
    param([string]$Name='Dark')
    $t=$script:THEMES[$Name]; if(-not $t){ return }
    foreach($k in $t.Keys){
        try { $b=$win.FindResource($k); if($b){ $b.Color=[System.Windows.Media.ColorConverter]::ConvertFromString($t[$k]) } } catch {}
    }
    # titlebar DWM (reusa el chrome existente); tema oscuro=1, claro=0
    try { Set-AXEWindowChrome ($Name -eq 'Dark') } catch {}
    $script:currentTheme=$Name
    try { @{theme=$Name} | ConvertTo-Json | Set-Content (Join-Path $script:AXEData 'theme.json') -Encoding UTF8 } catch {}
}
function Get-AXETheme {
    try { $f=Join-Path $script:AXEData 'theme.json'; if(Test-Path $f){ $j=Get-Content $f -Raw|ConvertFrom-Json; if($j.theme){ return "$($j.theme)" } } } catch {}
    'Dark'
}
```

- Mutación de `.Color` sobre la instancia compartida del recurso → re-tematiza XAML + código en vivo (verificado: brushes sin Freeze, `New-AXEBrush` = `FindResource`).
- `Set-AXEWindowChrome` ya existe (aplica DWM dark/light al titlebar). Se pasa el bool según tema.
- Persistencia: `theme.json` en `$script:AXEData`. Al arranque (init GUI) se llama `Set-AXETheme (Get-AXETheme)`.

### `$script:PRESETS` en `22-catalogs.ps1`

```powershell
# Presets curados por Id (subconjuntos del catalogo $script:CAT). Selección, no auto-apply.
# Principio: Safe = Tier0 sin tradeoff; Balanced = Safe + Tier1 bajo impacto; Gaming = Balanced + resto Tier0/1 FPS/latencia. Nunca Tier2.
$script:PRESETS = @{
    Safe     = @( <# Ids Tier0 inocuos: telemetría, timers, ajustes reversibles sin efecto lateral #> )
    Balanced = @( <# Safe + Tier1 de bajo impacto lateral: efectos visuales, algo de background #> )
    Gaming   = @( <# Balanced + resto Tier0/1 orientado FPS/latencia: background apps, GameDVR, power #> )
}
```

> **Nota de implementación (plan):** las listas de `Id` se rellenan en el plan leyendo `20-tweaks.ps1`/`22-catalogs.ps1` y clasificando cada tweak por Tier + efecto lateral. El spec fija el **principio de curación**, no las keys (que dependen del catálogo real). Regla dura: cada preset resuelve a ≥1 `Id` existente en `$script:CAT` (validado por S21).

---

## Sección 2 — Dashboard (vista DASHBOARD, timer 2s en runspace)

- **Vista**: nuevo case `'DASHBOARD'` en `Build-ActionView`. `'DASHBOARD'` va **primero** en `$script:actionCats` (lidera el grupo ACCIONES). **No** cambia la vista de arranque (sigue arrancando donde hoy).
- **Layout**: filas con labels grandes — CPU% · RAM `usado/total MB (P%)` · Disco% · Red `↓rx / ↑tx KB/s` · Uptime. Debajo: botón **"Medir Score"** + label del último Score/hora.
- **Timer**: `$script:dashTimer` = `DispatcherTimer` a **2 s**. **Solo activo con la vista visible**: `Switch-View` lo arranca al entrar en DASHBOARD y lo para al salir a cualquier otra vista; `Add_Closed` lo para también.
- **Freeze-safe**: cada tick, si `$script:dashInFlight` es falso, marca in-flight y hace `PowerShell.BeginInvoke` del `$script:LiveMetricsScript.ToString()` (CIM en runspace). Un `DispatcherTimer` de sondeo corto (~150 ms, patrón de `Invoke-AXEMeasure`) recoge el resultado, pinta labels en el UI thread, limpia in-flight. Tick solapado se salta (guard).
- **Medir Score**: el botón reusa `Invoke-AXEMeasure -JitterMs 1000` (motor de A). El jitter (1 s busy-loop) **no** corre en el timer de 2 s — solo bajo demanda. Muestra `Total/100` + timestamp. (Honesto: el Score no es "live" porque el jitter continuo pegaría un core.)
- **Wiring**: glyph `'DASHBOARD'` en `$script:glyphs`; subtítulo en `Switch-View` ("Métricas del sistema en vivo"); helper `Invoke-AXEDashTick`/start/stop en `57`.

---

## Sección 3 — Tema (toggle header) + Presets (ComboBox header)

- **Tema**: botón toggle en el header (junto al `SearchBox`), icono ☀/🌙. Click → `Set-AXETheme` al tema contrario de `$script:currentTheme`. Al init GUI: `Set-AXETheme (Get-AXETheme)` (aplica el persistido; default Dark).
- **Presets**: `ComboBox` en el header con `Safe / Gaming / Balanced` (reemplaza el `$BtnPreset` crudo — el botón se retira del XAML o se reusa su slot por el ComboBox). Al seleccionar: resuelve `$script:PRESETS[$sel]` → marca las casillas de esos `Id` (y desmarca el resto de marcables), **sin aplicar**. El usuario pulsa APLICAR normal (wrap de medición de A intacto).
- El handler de presets reusa el mecanismo de marcado de casillas del `$BtnPreset` actual, cambiando "todo Tier<2" por "los `Id` del preset".

---

## Sección 4 — Buscador global (mejora del handler existente)

- **Comportamiento**: en `$SearchBox.Add_TextChanged`, si `Text.Length ≥ 1` → modo **global**: filtra `$script:CAT` completo (nombre/desc, case-insensitive) sobre **las 73 de todas las categorías** y renderiza una vista plana **RESULTADOS** reusando `New-TweakCard`. Si `Text` vacío → restaura la categoría previa (`Switch-View` a la última categoría activa).
- **Cabecera**: "N resultados" (cuenta). Sidebar sin categoría resaltada mientras se busca.
- **Accionable**: como reusa `New-TweakCard`, cada resultado trae su casilla y entra en la **misma cola de APLICAR**; marcar desde resultados funciona igual que en una categoría.
- **Alcance**: solo el catálogo de 73 tweaks (no las action-views LIMPIEZA/DEBLOAT/DNS/etc.).
- **Estado**: `$script:lastCat` guarda la categoría previa para restaurar al limpiar la búsqueda.

---

## Testing (regresión, gate verde obligatorio)

Extiende el bloque `-SelfTest` de `45-cli.ps1` (headless, in-process) + asserts del harness GUI (`60-gui-selftest.ps1`).

- **S19** — `Get-AXELiveMetrics` devuelve los 8 campos y no lanza; rápido (CIM inline).
- **S20** — `Set-AXETheme Light` muta ≥1 brush a color claro; `Get-AXETheme` roundtrip por `theme.json` (crear temp, leer, restaurar Dark).
- **S21** — cada preset (`Safe/Gaming/Balanced`) resuelve a ≥1 `Id` **existente** en `$script:CAT`; ninguna key huérfana.
- **S22** — filtro global sobre un término común (ej. la subcadena de un tweak presente en ≥2 categorías) devuelve matches de >1 `Cat`.
- **Harness GUI** — `Build-ActionView 'DASHBOARD'` construye labels + botón "Medir Score" sin lanzar; existe el control toggle de tema; existe el ComboBox de presets; el modo búsqueda global produce la vista RESULTADOS.

## Restricciones (invariantes)

- **Fuente única `/src`**; nunca editar `dist/AXE.ps1` a mano (lo genera `build.ps1`).
- **Cada módulo < 500 líneas.**
- **Runspace-safe**: `$script:LiveMetricsScript` es autocontenido (no llama funciones de sesión ni la GUI). El pintado va siempre en el UI thread.
- **Nunca bloquea / nunca lanza**: métricas y tema degradan a `n/a`/no-op con try/catch. El dashboard es solo lectura → cero riesgo de reversibilidad.
- **Default Dark**: el tema claro es opt-in, persistido, reversible con un click.
- **Gate**: `build.ps1` corre `-SelfTest` (`Fallos : 0`) + harness GUI (`RESULTADO: LAYOUT OK`). Ambos verdes o el build falla.
- **VERSION** → bump a `6.2.0-dev` al cerrar C.

## Backlog derivado (sub-proyecto B, no C)

- **Standby-RAM clean** (0-dep): P/Invoke `NtSetSystemInformation(SystemMemoryListInformation)` + `AdjustTokenPrivileges(SeProfileSingleProcessPrivilege)` en `AXE.Native`; acción etiquetada honesta ("transitorio, el SO rellena"), degrada a `n/a` sin privilegio. Es mutación de sistema → va con feature-breadth (B), no con GUI-producción (C).

---

## Self-Review (checklist de autor)

1. **Placeholders**: las listas de `$script:PRESETS` van con principio de curación fijado + regla dura (S21); las keys exactas son trabajo de plan (dependen del catálogo real), marcado explícito — no es un TODO oculto.
2. **Consistencia de tipos**: `Get-AXELiveMetrics` devuelve los mismos 8 campos que consume la vista DASHBOARD y el assembler del tick. `Set-AXETheme`/`Get-AXETheme` usan la misma clave `theme` en `theme.json`. Presets = listas de `Id` consumidas por el handler del ComboBox y validadas por S21.
3. **Scope**: 4 items acotados a GUI-producción; standby-RAM explícitamente fuera (B). Foco correcto para un solo plan.
4. **Ambigüedad**: "Medir Score" es on-demand (no live) — declarado explícito por honestidad. Búsqueda global limita alcance a los 73 tweaks (no action-views) — declarado. Tema default Dark — declarado.
