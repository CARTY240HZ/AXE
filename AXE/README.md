<p align="center">
  <img src="logo/axe.svg" alt="AXE" width="96" height="96">
</p>

<h1 align="center">AXE</h1>

<p align="center"><b>Optimizador de Windows para juegos — con honestidad como característica, no como eslogan.</b></p>

<p align="center">
  <img alt="version" src="https://img.shields.io/badge/version-7.0.0-E0A32E">
  <img alt="tests" src="https://img.shields.io/badge/tests-passing-2ea043">
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
| **Detección** | Lee tu equipo campo a campo y **enseña lo que no pudo leer**; el juego se detecta por señales (carpeta de la tienda, firma del motor), no por una lista de títulos que envejece | Lista de juegos que hay que actualizar con cada lanzamiento |
| **Tests** | Suite Pester en CI, reproducible en tu máquina (ver abajo) | Ninguno público |
| **Precio / cuenta / telemetría** | Gratis, sin cuenta, sin telemetría | Suscripción |

> AXE no promete FPS mágicos. La mayoría de tweaks —en AXE **y** en las herramientas de pago—
> mueven el FPS **dentro del margen de ruido de medición**. AXE te lo dice a la cara. Esa
> honestidad *es* la ventaja.

## Uso

1. Descarga o clona el repo.
2. Ejecuta **`AXE.bat`** — se auto-eleva a administrador y abre la interfaz (WebView2).

### «¿Y ahora qué hago?»

Es la única pregunta que importa, y AXE la responde en una lista ordenada (botón **¿Qué hago
ahora?**, o `-Advice`). Lo que la hace distinta no es que sea larga, sino **el orden**:

1. **Lo que vale 10-40 %** — RAM en single channel, XMP apagado, el monitor por debajo de sus Hz,
   Windows en disco mecánico. Va primero **aunque AXE no pueda arreglarlo**: vive en la BIOS, en
   los slots o en Configuración de Windows.
2. **Lo que tu propia máquina asocia a ir peor** con un ajuste puesto.
3. **Los ajustes del catálogo, los últimos**, diciendo que mueven porcentajes de un dígito y que
   varios están marcados como probable placebo.

Un optimizador que vende tweaks pone ese orden justo al revés. Aquí hay un test que lo impide.

Y razona sobre **combinaciones**, no sobre campos sueltos: «tienes la RAM en single channel **y**
un panel de 180 Hz, o sea que pagaste por unos frames que la memoria no deja llegar» necesita
cruzar dos hechos, y es lo que hace que parezca que el programa entiende tu equipo.

**Aprende de lo tuyo, y sin salir de tu disco.** Cada vez que pides consejo, AXE mide y guarda el
resultado junto a los ajustes que tenías puestos. Con el tiempo compara tu score con cada ajuste
puesto y sin él, **en esta máquina**. Con menos de 3 medidas a cada lado **no afirma nada**, y
cuando afirma dice *«asociado a»*, nunca *«causa»*: entre dos medidas cambian más cosas que el
ajuste, así que es una observación, no un experimento. No hay modelo, ni nube, ni cuenta: es
aritmética sobre un `outcomes.json` tuyo, y el código está a la vista.

### Se adapta al equipo que tengas

AXE lee tu máquina campo a campo: torre o portátil (por chasis, y por batería si el fabricante
no rellenó el chasis), Windows 10 u 11 —siempre por número de build, nunca por el nombre del
producto, que en Win11 **sigue diciendo "Windows 10"**—, GPU por nombre y fabricante (NVIDIA, AMD
o Intel, no sólo una de las tres), Hz y resolución del panel, RAM, SSD/NVMe, red, y si estás en
una máquina virtual. Lo esencial tiene camino alternativo por registro, porque en un equipo al que
ya le pasó otro optimizador por encima WMI puede estar roto — y ahí es donde AXE hace falta.

**Lo que no consigue leer lo dice**, con un aviso en el panel. "No lo sé" es un estado distinto de
"no lo tienes", y de esa diferencia depende qué ajustes se te ofrecen.

En **Sesión de juego**, el botón *Detectar* encuentra el juego solo y enseña **por qué** cree que
lo es: carpeta de la tienda (Steam, Epic, Riot, GOG, Xbox…), firma del motor (`-Win64-Shipping` de
Unreal), ventana propia, memoria. No hay una base de datos de títulos —esas envejecen solas y un
indie nunca entra en ellas—, así que también acierta con un juego que salió ayer. Propone con el
motivo a la vista; **eliges tú**. Y la detección no abre ningún handle al proceso del juego: lee
sólo el listado que ya da el sistema.

La ventana se ajusta al escritorio que tengas, con el escalado de Windows incluido (125 %, 150 %…),
y la interfaz se reorganiza al encogerla. `Ctrl` + rueda cambia el zoom y se recuerda.

### Modos por línea de comandos (headless)

```bat
AXE.bat -SelfTest            :: valida la integridad del catálogo de tweaks
AXE.bat -List               :: estado real de cada tweak en este equipo
AXE.bat -Export perfil.json  :: exporta el estado actual
AXE.bat -Import perfil.json  :: aplica un perfil (requiere admin)
AXE.bat -Diag                :: config mal puesta que cuesta más FPS que el catálogo entero
AXE.bat -NetMon              :: ping, jitter de red y pérdida (router + internet). Solo mide
AXE.bat -Advice              :: qué hacer ahora, ordenado por efecto real. Mide y recuerda
```

`-NetMon` mide el **camino ICMP**, y los juegos van por UDP: muchos routers y operadores
despriorizan ICMP, así que es un indicador, no el dato del juego. Sondea dos destinos por
separado a propósito — tu router y una ancla pública — porque eso es lo que distingue *tu enlace*
de *tu operador*. No puntúa el ping a internet: no existe un umbral honesto para eso.

## Seguridad

- **Niveles (Tier):** `0` Seguro · `1` Elite · `2` EXTREMO (opt-in, confirma antes de aplicar).
- **Punto de restauración** best-effort antes de aplicar (detecta anti-cheat que bloquea VSS y avisa).
- **Backups `.reg`** de las claves tocadas + `Export`/`Import` como red de seguridad.
- **Revertir todo** desde la interfaz revierte solo lo que está aplicado, usando el snapshot real.

> AXE modifica el registro y la energía del sistema. Está diseñado para ser reversible, pero
> úsalo bajo tu responsabilidad. Consulta el `NotesEng` de cada tweak para el detalle técnico.

### Anti-cheat

La sesión de juego reparte prioridades entre procesos de fondo. Lo que **nunca** toca, por
código y no por promesa (`src/40-session.ps1`, función `Get-AXESessionLevel`):

| Qué | Cómo se garantiza |
|---|---|
| El proceso del juego | `Pid -eq GamePid` → `intacto`, primera regla del planificador |
| Procesos anti-cheat | Familia `anticheat` + regex `anticheat\|battleye\|easyanti` → `intacto` |
| El shell (explorer, dwm…) | Familia `shell` → `intacto` |
| Servicios y drivers | Session 0 se descarta por definición: solo se considera la sesión interactiva |
| Tu configuración | Los duros ganan a los overrides del usuario: un override sobre ellos se **rechaza al escribir**, no se ignora en silencio |

AXE **no inyecta en procesos, no lee ni escribe memoria de juego, y no abre handle al proceso
del juego ni al del anti-cheat.** Cambia ajustes de Windows; nada más.

**La única incertidumbre declarada:** el tweak `lat_timerres` restaura el honrado global de
timer resolution en Win11. Su propio `NotesEng` dice *"Possible anti-cheat interaction: possible,
not confirmed"*. No afirmamos que sea seguro con todos los anti-cheat porque no lo hemos
verificado. Está en el catálogo con esa nota y tú decides.

> Los optimizadores de pago declaran "compatible con EAC / BattlEye / Vanguard / VAC" en bloque.
> Aquí se enseña la regla exacta que lo garantiza, la línea donde vive, y el único caso donde
> no lo sabemos.

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

Cada push/PR corre el gate completo en Windows (`.github/workflows/ci.yml`): lint + suite Pester
+ SelfTest + web host harness + build. Rojo = no mergea.

**Sobre el número de tests.** El badge no lleva cifra a propósito. Cualquier número fijo ahí
miente al poco tiempo, y este proyecto no puede permitirse un dato decorativo justo en la sección
que dice que mide en vez de afirmar. Los tres números se mueven por motivos distintos y legítimos:

| Número | De qué depende |
|---|---|
| **Pasados** | Del commit. Crece con cada test nuevo. |
| **Omitidos** | De **tu hardware**. Un equipo sin NVIDIA o sin PresentMon omite tests que en otro corren; nadie tiene el mismo total. |
| **No ejecutados** | Los marcados `-Tag integration`, que mutan Windows real y corren en un job aparte de CI (`scripts/Invoke-AXETests.ps1:55`). |

Reproducible en tu máquina, que es lo que importa:

```powershell
pwsh -File scripts\Invoke-AXETests.ps1                       # suite normal
pwsh -File scripts\Invoke-AXETests.ps1 -IncludeIntegration   # + los que tocan Windows real
pwsh -File dist\AXE.ps1 -SelfTest                            # integridad del catalogo
```

## Licencia

[MIT](LICENSE).
