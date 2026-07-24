# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/)
y [Versionado Semántico](https://semver.org/lang/es/).

## [Sin publicar]

### Añadido
- **Benchmark «pruébalo en tu PC»** (subproyecto C, `src/41-bench.ps1`, CLI `-Benchmark` /
  `-Benchmark -After <id>`, puente `bench.baseline` / `bench.after`): prueba **medible y
  compartible** del efecto real en tu equipo. Dos fases con reinicio humano en medio — el
  «antes» se guarda en `AXE/bench/<id>.json` y sobrevive al reinicio. Cada métrica se muestrea
  N veces y se agrega a **mediana + IQR**: el ruido se **mide**, no se asume. Un delta que no
  supera `IQR(antes) + IQR(después)` se etiqueta **`ruido`**, nunca «mejora» — más un **suelo de
  resolución** para que un IQR redondeado a cero no convierta cualquier cambio en un titular.
  Se niega a comparar entre máquinas, builds o versiones distintas (hash de identidad). Reporte
  en tres caras del mismo dato (texto, JSON y Markdown compartible) **sin PII**: modelo de CPU,
  RAM, vendor de GPU y build; ni serie, ni usuario, ni IP. Métrica que no se puede medir viaja
  `null`, jamás `0`. Veredicto **puro y testeado** (`Get-AXEBenchVerdict`, 46 tests + SelfTest S29).
  *Ellos publican un «score» fabricado; esto publica el delta real con su margen de error y admite
  cuando no hay nada que enseñar.*
- **Daemon de sesión de juego** (subsistema A, `src/40-session.ps1`, CLI `-Session <proceso>`):
  congela el fondo con un **Job Object** mientras juegas y lo descongela al cerrar el juego o
  AXE. La recuperación la garantiza el **kernel** (al cerrarse el handle, Windows descongela solo:
  cubre crash, kill y BSOD). Reparto en tres niveles por familias — INTACTO (juego, voz,
  anti-cheat, shell) / DEGRADADO (navegadores, música, mensajería) / CONGELADO (el resto de la
  sesión del usuario; Session 0 queda fuera por definición). Planificador **puro y testeado**
  (`Get-AXESessionPlan`, 15 tests + SelfTest S28). `JobObjectFreezeInformation` validada en
  Win11 26200. *El hueco que ninguna suite de pago (hone.gg/Pulse/Atlas/Delta) rellena de verdad.*
- **CI en GitHub Actions** (`.github/workflows/ci.yml`): en cada push/PR corre el gate completo
  en Windows (lint + Pester + SelfTest + web host harness + build). Rojo bloquea el merge.
- **Runner único de tests** (`scripts/Invoke-AXETests.ps1`): ejecuta la suite Pester, con lint
  opcional (PSScriptAnalyzer) y salida NUnit para artefactos.
- **Config de lint** (`PSScriptAnalyzerSettings.psd1`) afinada a los patrones deliberados del proyecto.
- **LICENSE** (MIT), **README** y este **CHANGELOG**. `.gitignore`.

### Corregido
- Los 9 ficheros `tests/*.Tests.ps1` (671 tests) **ahora se ejecutan en el gate de build**.
  Antes `build.ps1` solo corría `-SelfTest`: la suite existía pero no la ejecutaba nadie
  (cobertura ficticia). Ahora un solo test rojo aborta el build.

## [7.0.0] — 2026-07-22

### Cambiado
- **Cutover a interfaz web** como frontend único: carcasa WPF fina que aloja un control WebView2;
  toda la UI vive en `webui/`. Se retiró la GUI WPF anterior.

### Añadido
- Puente RPC JS↔PS con **lista blanca cerrada y exacta** (sin `eval`, sin lógica de negocio nueva).
- Pantallas: Panel, Optimizar (aplicar/revertir catálogo), Telemetría, Prueba (A/B), Seguridad, Ajustes.
- **Telemetría real** por runspace de fondo (CPU/RAM/jitter) sin congelar la ventana.

## [6.x] — Trust & Proof + Gating

### Añadido
- **Capa de medición nativa** (P/Invoke): timer resolution, jitter (media/máx/P99.9/stalls),
  purga de standby list estilo ISLC. Score y prueba A/B honestas (exigen baseline antes/después).
- **Gating por hardware** (`Requires` + `Get-BlockReason`): no aplica tweaks en equipos incompatibles.
- Flag **`PlaceboLikely`** + `NotesEng` por tweak (qué documenta Microsoft vs. folclore).
- Diagnóstico que detecta configuración que cuesta más FPS que todo el catálogo (XMP, refresh, SSD…).

### Cambiado
- **Build modular**: el motor se parte en módulos numerados en `src/`; `build.ps1` los concatena
  a `dist/AXE.ps1` (fuente única). Reversión con **fidelidad de snapshot** (no inventa defaults).

[Sin publicar]: https://example.invalid/compare/v7.0.0...HEAD
[7.0.0]: https://example.invalid/releases/tag/v7.0.0
