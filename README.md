<div align="center">
  <img src="AXE/logo/axe.svg" alt="AXE" width="120" />

# AXE

**Afinador de rendimiento de Windows para gaming.**
Primero te dice qué tienes mal configurado. Después, y solo después, toca algo.

[![Release](https://img.shields.io/github/v/release/CARTY240HZ/AXE)](https://github.com/CARTY240HZ/AXE/releases/latest)
[![CI](https://github.com/CARTY240HZ/AXE/actions/workflows/ci.yml/badge.svg?branch=axe)](https://github.com/CARTY240HZ/AXE/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

## Por qué existe

Un optimizador que te aplica 80 tweaks pelea por porcentajes de un dígito mientras tu RAM
corre a la velocidad base porque XMP está apagado, o tu monitor de 144 Hz está puesto a 60.
Eso son multiplicadores, no porcentajes, y ningún tweak los compensa.

Por eso `-Diag` va antes que el catálogo, y por eso AXE dice **UNKNOWN** cuando no puede
comprobar algo en vez de rellenar el hueco con un OK. Un OK sin comprobar no es un OK: es la
misma frase con menos información y más confianza.

## Instalación

Descarga desde [**Releases**](https://github.com/CARTY240HZ/AXE/releases/latest) —
`AXE.ps1` suelto o el `.zip` con el lanzador.

### Verifica antes de ejecutar

AXE corre elevado y escribe en el Registro. No lo ejecutes sin comprobar de dónde salió.

```powershell
# 1. Integridad: que el fichero llegó entero
(Get-FileHash .\AXE.ps1 -Algorithm SHA256).Hash.ToLower()
#    compáralo con la línea de AXE.ps1 en SHA256SUMS

# 2. Procedencia: de qué repositorio, commit y workflow salió  (necesita gh CLI)
gh attestation verify .\AXE.ps1 --repo CARTY240HZ/AXE
```

Las dos responden preguntas distintas. El hash prueba que el fichero está entero, pero viaja
**dentro** del mismo release que el fichero: quien controle el release controla los dos. La
attestation la firma [Sigstore](https://www.sigstore.dev/) **fuera** del release y ata esos
bytes a este repositorio, a un commit concreto y al workflow que los construyó.

> **Los releases todavía no van firmados con Authenticode.** Windows seguirá avisando por
> SmartScreen y `-Update` **no** instalará solo. Es deliberado mientras no haya certificado:
> preferimos que el aviso salga a fingir una firma que no existe.

## Uso

**Interfaz:** doble clic en `AXE.bat` — se eleva solo.

**Diagnóstico (no toca nada):**

```powershell
pwsh -File AXE.ps1 -Diag       # XMP/EXPO, canales de RAM, Hz reales del panel por EDID, SSD, núcleos P/E
pwsh -File AXE.ps1 -Advice     # qué hacer ahora, ordenado por efecto real
pwsh -File AXE.ps1 -Mouse      # sondeo real del ratón (125 vs 1000 Hz = 7 ms de input lag)
pwsh -File AXE.ps1 -Dpc        # tirones de drivers: los que no bajan el FPS medio
pwsh -File AXE.ps1 -NetMon     # ping, jitter y pérdida: separa tu enlace de tu operador
pwsh -File AXE.ps1 -NetLoad    # bufferbloat: el ping que tendrás cuando alguien descargue en casa
```

**Medir de verdad:**

```powershell
pwsh -File AXE.ps1 -Benchmark              # línea base, mediana + IQR. Imprime un id
pwsh -File AXE.ps1 -Benchmark -After <id>  # tras aplicar y reiniciar: mejor / peor / RUIDO
pwsh -File AXE.ps1 -Fps <proceso> -FpsCompare   # FPS reales y 1% low con PresentMon
```

`-Benchmark` dice **RUIDO** cuando la diferencia cae dentro del margen de ruido, en vez de
apuntarse la mejora. Es la razón de que exista: un número que siempre sube no mide nada.

**Aplicar:**

```powershell
pwsh -File AXE.ps1 -List       # estado real de cada tweak contra tu sistema
pwsh -File AXE.ps1 -SelfTest   # integridad del catálogo, sin tocar el equipo
```

## Qué lo separa de los demás

| | |
|---|---|
| **Diagnóstico antes que tweaks** | Los puntos mal configurados valen más que todo el catálogo junto, y te lo dice aunque signifique no venderte nada. |
| **UNKNOWN existe** | Cuando una lectura no es concluyente, sale UNKNOWN. No hay OK por defecto. |
| **Todo reversible** | Cada cambio guarda el valor anterior **real** por snapshot, no un valor "por defecto" supuesto. |
| **Punto de restauración verificado** | Creado *y comprobado* antes de tocar nada; si VSS está bloqueado, cae a export `.reg`. |
| **Solo lo que aplica a ti** | Detecta el ecosistema y **oculta** los tweaks que tu equipo no puede usar, con el motivo. |
| **Nada de placebo callado** | Los tweaks marginales o sin fuente verificable van a Tier 2, etiquetados. |
| **Verificable** | Gate bloqueante en CI, `SHA256SUMS`, SBOM CycloneDX y procedencia Sigstore en cada release. |

> ⚠️ AXE modifica configuración del sistema. Está diseñado para ser reversible, pero úsalo bajo
> tu responsabilidad. Cierra anti-cheats y juegos antes de crear el punto de restauración.

## Requisitos

- Windows 10 u 11 (los tweaks que piden build o edición concreta se ocultan solos).
- PowerShell 5.1 o 7.x.
- Administrador — AXE se auto-eleva.

## Tiers

| Tier | Significado |
|------|-------------|
| **0** | Seguro — bajo riesgo, alta confianza |
| **1** | Elite — efecto real medido o documentado |
| **2** | EXTREMO, opt-in — baja protecciones o efecto marginal; exige consentimiento explícito |

## Seguridad

- Escrituras de registro con *snapshot-revert*: capturan el valor previo real.
- Tier 2 que baja defensas (VBS/HVCI, CFG, ASLR, mitigaciones Spectre/Meltdown) pide
  confirmación y dice **qué protección cae**.
- Defender vía `*-MpPreference`, respetando Tamper Protection. Exclusiones solo de procesos de
  juego y `steamapps\common`, nunca la raíz de Steam.
- `-Update` verifica SHA256 **y** firma Authenticode antes de reemplazar nada. Sin firma
  válida avisa y no toca el fichero: AXE corre elevado, y un updater laxo sería la vía de
  escalada.

## Desarrollo

El código vive en módulos `AXE/src/NN-*.ps1` y se concatena a `AXE/dist/AXE.ps1`.

```powershell
./AXE/build.ps1                                  # concatena src -> dist y corre el gate completo
Invoke-Pester -Path AXE/tests -ExcludeTag integration
```

El gate no es decorativo: un solo test rojo aborta el build. CI (`windows-latest`) corre en
cada push ScriptAnalyzer → build → anti-deriva de `dist` → SelfTest → Pester, más un job de
integración contra Windows real.

## Qué NO incluye este repo

Binarios de terceros (por ejemplo `winutil.exe`) no se distribuyen aquí: no son de este
proyecto y tienen sus propias licencias. El núcleo de AXE es autocontenido y usa solo
utilidades integradas de Windows. PresentMon lo aporta el usuario.

## Licencia

[MIT](LICENSE) © 2026 CARTY240HZ
