<p align="center">
  <img src="logo/axe.svg" alt="AXE" width="96" height="96">
</p>

<h1 align="center">AXE</h1>

<p align="center"><b>Optimizador de Windows para juegos — con honestidad como característica, no como eslogan.</b></p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-7.0.0-E0A32E">
  <img alt="tests" src="https://img.shields.io/badge/tests-671%20passing-2ea043">
  <img alt="platform" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6">
  <img alt="license" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## Qué es

AXE aplica tweaks de CPU / GPU / latencia / red a Windows 10/11 y **mide el efecto real**
en vez de mostrarte una barra de "boost" inventada. Todo el motor es PowerShell auditable,
cada cambio es reversible con fidelidad y cada tweak declara si su efecto es probable placebo.

## En qué se diferencia de hone.gg / PulseHardware / AtlasPRO / DeltaPRO

| | AXE | Optimizadores de pago típicos |
|---|---|---|
| **Honestidad** | Cada tweak lleva `PlaceboLikely` + nota citando qué documenta Microsoft vs. folclore de comunidad | Venden el placebo como magia |
| **Prueba** | Medición nativa real: timer resolution, jitter (P99.9, stalls), standby purge — antes/después | Barras de "% mejorado" ficticias |
| **Reversión** | Snapshot real por tweak; si no hay snapshot, **se niega a inventar un default** | Muchas veces sin undo limpio |
| **Auditable** | PowerShell abierto, fuentes citadas (learn.microsoft.com, valleyofdoom) | Binario cerrado + driver que confías a ciegas |
| **Tests** | 671 tests Pester en CI | Ninguno público |
| **Precio / cuenta / telemetría** | Gratis, sin cuenta, sin telemetría | Suscripción |

> AXE no promete FPS mágicos. La mayoría de tweaks —en AXE **y** en las herramientas de pago—
> mueven el FPS **dentro del margen de ruido de medición**. AXE te lo dice a la cara. Esa
> honestidad *es* la ventaja.

## Uso

1. Descarga o clona el repo.
2. Ejecuta **`AXE.bat`** — se auto-eleva a administrador y abre la interfaz (WebView2).

### Modos por línea de comandos (headless)

```bat
AXE.bat -SelfTest            :: valida la integridad del catálogo de tweaks
AXE.bat -List               :: estado real de cada tweak en este equipo
AXE.bat -Export perfil.json  :: exporta el estado actual
AXE.bat -Import perfil.json  :: aplica un perfil (requiere admin)
```

## Seguridad

- **Niveles (Tier):** `0` Seguro · `1` Elite · `2` EXTREMO (opt-in, confirma antes de aplicar).
- **Punto de restauración** best-effort antes de aplicar (detecta anti-cheat que bloquea VSS y avisa).
- **Backups `.reg`** de las claves tocadas + `Export`/`Import` como red de seguridad.
- **Revertir todo** desde la interfaz revierte solo lo que está aplicado, usando el snapshot real.

> AXE modifica el registro y la energía del sistema. Está diseñado para ser reversible, pero
> úsalo bajo tu responsabilidad. Consulta el `NotesEng` de cada tweak para el detalle técnico.

## Desarrollo

El motor vive en `src/` (módulos numerados) y `build.ps1` los concatena a `dist/AXE.ps1`
(fuente única que ejecuta el `.bat`). **No edites `dist/AXE.ps1` a mano.**

```powershell
.\build.ps1                    # build + gate (Pester + SelfTest + web host harness)
.\build.ps1 -NoTest            # build rápido sin gate (iteración local)
.\build.ps1 -CI                # gate completo + lint + resultados NUnit (lo usa CI)
.\scripts\Invoke-AXETests.ps1  # solo la suite Pester
```

Requisitos: PowerShell 5.1+ y `pwsh` (7+), Pester ≥ 5, PSScriptAnalyzer (opcional, para lint).

## CI

Cada push/PR corre el gate completo en Windows (`.github/workflows/ci.yml`): lint + 671 tests
Pester + SelfTest + web host harness + build. Rojo = no mergea.

## Licencia

[MIT](LICENSE).
