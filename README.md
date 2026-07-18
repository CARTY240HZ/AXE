<div align="center">
  <img src="AXE/logo/axe.svg" alt="AXE" width="120" />

# AXE

**Afinador de rendimiento de Windows para gaming — opt-in, reversible, medido y con fuentes.**

[![CI](https://github.com/CARTY240HZ/AXE/actions/workflows/ci.yml/badge.svg?branch=axe)](https://github.com/CARTY240HZ/AXE/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

AXE aplica *tweaks* de Windows (Registro, servicios, energía, GPU, red, Defender) pensados
para **latencia y FPS**, pero sin los pecados habituales de los "optimizadores":

- **Todo es opt-in y reversible.** Cada cambio guarda su valor anterior real y se puede deshacer.
- **Punto de restauración creado *y verificado*** antes de tocar nada (no confía a ciegas en `Checkpoint-Computer`).
- **Solo muestra lo que aplica a tu equipo.** Detecta el ecosistema (RAM, CPU Intel/AMD/ARM, portátil/sobremesa, NVIDIA, SSD, Defender/Tamper, S mode…) y **oculta** los tweaks que no aplican.
- **Nada de placebo silencioso.** Los tweaks marginales o sin fuente verificable van a Tier 2 (opt-in) y se etiquetan.
- **Medible.** AXE Score (0-100) + jitter antes/después, para ver si de verdad mejoró.

> ⚠️ AXE modifica configuración del sistema. Está diseñado para ser reversible, pero úsalo bajo tu responsabilidad. Cierra anti-cheats/juegos antes de crear el punto de restauración.

## Requisitos

- Windows 10 o 11 (algunos tweaks requieren build/edición concretos; se ocultan si no aplican).
- PowerShell 5.1 o 7.x.
- Permisos de **administrador** (AXE se auto-eleva).

## Uso

**GUI (recomendado):** doble clic en `AXE/AXE.bat` — se eleva solo y abre la interfaz.

**CLI / avanzado:**

```powershell
# validación de integridad del catálogo (sin tocar el equipo)
pwsh -File AXE/dist/AXE.ps1 -SelfTest

# listar tweaks + banner de ecosistema (qué aplica / qué se oculta y por qué)
pwsh -File AXE/dist/AXE.ps1 -List

# medir el estado actual (timer/jitter/score)
pwsh -File AXE/dist/AXE.ps1 -Measure
```

## Tiers

| Tier | Significado |
|------|-------------|
| **0** | Seguro — bajo riesgo, alta confianza |
| **1** | Elite — efecto real medido/documentado |
| **2** | EXTREMO / opt-in — baja protecciones o efecto marginal; requiere consentimiento explícito |

## Seguridad

- Punto de restauración **creado y verificado** (fallback a export `.reg` si VSS está bloqueado).
- Escrituras de registro vía primitivos con *snapshot-revert* (capturan el valor previo real).
- Tweaks EXTREMO (Tier 2) que bajan defensas (VBS/HVCI, CFG, ASLR, mitigaciones Spectre/Meltdown) exigen confirmación y avisan qué protección cae.
- Ajustes de Defender vía `*-MpPreference` (respetan Tamper Protection); exclusiones solo de procesos de juego + `steamapps\common` (nunca la raíz de Steam).

## Desarrollo

El código vive en módulos `AXE/src/NN-*.ps1` y se concatena a `AXE/dist/AXE.ps1`:

```powershell
./AXE/build.ps1                    # concatena src -> dist + corre el SelfTest gate

# tests unitarios (Pester 5/7)
Invoke-Pester -Path AXE/tests -ExcludeTag integration
```

CI (GitHub Actions, `windows-latest`) corre en cada push: ScriptAnalyzer (Error gate) → build → SelfTest → Pester.

## Qué NO incluye este repo

Binarios de terceros (p. ej. `winutil.exe`) **no** se distribuyen aquí: no son de este proyecto y tienen sus propias licencias. AXE funciona sin ellos — su núcleo es autocontenido (usa solo utilidades integradas de Windows).

## Licencia

[MIT](LICENSE) © 2026 CARTY240HZ
