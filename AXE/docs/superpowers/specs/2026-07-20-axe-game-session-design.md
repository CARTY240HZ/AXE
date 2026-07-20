# AXE GAME SESSION — diseño del daemon de sesión

**Fecha:** 2026-07-20
**Estado:** aprobado en brainstorming, sin implementar
**Sub-proyecto:** A de 4 (ver Descomposición)

---

## Problema

Los 78 tweaks del catálogo son estáticos: se aplican y AXE sale. Lo que hace que una máquina
se sienta rápida mientras juegas no es una clave del registro, es **que no haya nada más
compitiendo por la CPU, el disco y las interrupciones**.

Ninguna suite del mercado (hone.gg, PulseHardware, Atlas, Delta) congela de verdad el fondo.
Tienen "game modes" tímidos: suben prioridad y cierran cuatro cosas. No lo hacen en serio
porque un fallo cuelga el PC del cliente y les come el soporte.

Ese es el hueco.

---

## Descomposición

`AXE GAME SESSION` son cuatro subsistemas independientes. **Este spec cubre sólo el A.**

| # | Subsistema | Riesgo | Estado |
|---|---|---|---|
| **A** | Daemon de sesión + congelación | Alto — un fallo cuelga el PC | **este spec** |
| B | Pinning de CPU (CCD vcache / P-cores) | Medio — depende del hardware | pendiente |
| C | Cadena de input lag (Reflex, frame cap, polling) | Bajo | pendiente |
| D | Corte de tráfico de fondo | Bajo | pendiente |

B, C y D son **políticas que se aplican dentro de una sesión**. A es el contenedor que define
sus interfaces. Diseñar C antes que A haría que C se inventara su propio ciclo de vida y hubiera
que reescribirlo.

---

## Decisiones tomadas

### 1. Job Object con freeze, no suspensión proceso a proceso

Windows congela por Job Object. Cuando el handle del job se cierra —y se cierra **siempre** que
el proceso dueño muere, incluso con kill duro desde el Administrador de tareas— el SO descongela
solo. Es el mismo mecanismo con el que Windows suspende apps UWP.

**Por qué esta y no otra:** la recuperación la garantiza el kernel. No hay código de recuperación
que a su vez pueda fallar. Un watchdog mueve el problema (¿quién vigila al watchdog?) y no cubre
BSOD ni corte de luz. Un fichero de estado deja la máquina rota hasta que el usuario vuelva a
abrir AXE, sin saber que esa es la solución.

**Riesgo aceptado:** `JobObjectFreezeInformation` está poco documentada. Hay que validarla en
Win10 y Win11 antes de construir encima. Si no está disponible, la sesión **aborta limpiamente**
con mensaje — no hay fallback a suspensión manual, eso sería otro spec.

### 2. Frontera de sesión + denylist corta

Sólo se consideran procesos con el `SessionId` de la sesión interactiva actual. **Session 0 queda
fuera por definición**: servicios, drivers, `audiodg`, `lsass` los aisló ya el SO.

**Por qué esta y no una denylist sobre todo el sistema:** la frontera la pone Windows, no una
lista que yo mantengo a mano. No se me puede olvidar ampliarla cuando un OEM, un antivirus o un
driver mete procesos que no conozco. Una denylist global es segura sólo mientras esté completa,
y nunca lo está.

### 3. Entrada manual, salida automática

El usuario pulsa ON y elige el juego. La sesión termina por OFF manual **o** porque el proceso
del juego murió.

**Por qué:** entrada explícita = el usuario siempre sabe que está activa. Salida automática =
si el juego crashea no te deja la máquina a medio gas esperando que te acuerdes de pulsar OFF.
Evita construir detección automática de juegos, que es un subsistema entero (base de datos de
títulos, hooks de lanzamiento) para otro spec.

### 4. El handle vive en el proceso AXE

AXE abierto = sesión viva. Cerrar AXE = sesión cerrada y máquina restaurada.

**Por qué:** un proceso, un dueño, un estado. Sin IPC ni sincronización. Y hace la red del kernel
trivialmente correcta: no existe ningún caso en que la sesión sobreviva a AXE.

**Coste aceptado:** hay que dejar la ventana abierta (minimizada) mientras juegas.

---

## Los tres niveles

El reparto no es binario. Hay apps que el usuario **está usando**, no que estorban.

| Nivel | Qué hace | Por defecto |
|---|---|---|
| **INTACTO** | Sin tocar | Juego, Discord/TeamSpeak/Mumble (voz), anti-cheat, shell, AXE |
| **DEGRADADO** | Vivo y usable, prioridad baja, fuera de los núcleos del juego | Chrome/Brave/Edge/Firefox, Spotify/Tidal, WhatsApp/Telegram/Signal |
| **CONGELADO** | Job object, congelado | Todo lo demás de la sesión del usuario |

**Discord va en INTACTO y no en DEGRADADO a propósito:** la voz es sensible a latencia y
degradarla se oye.

**Coste honesto documentado:** un navegador vivo se come parte del beneficio. Chrome con muchas
pestañas es de lo que más CPU y RAM consume de fondo. Degradarlo ayuda mucho pero no iguala a
congelarlo. Por eso el nivel es **configurable por app**, no lo decide AXE.

### Detección por familias, no por nombres sueltos

```
navegadores : chrome, brave, msedge, firefox, opera, vivaldi
musica      : spotify, tidal, deezer, foobar2000
mensajeria  : whatsapp, telegram, signal, slack
comms voz   : discord, teamspeak, mumble, ventrilo
anticheat   : EasyAntiCheat, BEService, vgc, vgtray, FACEIT
shell       : dwm, explorer, csrss, winlogon, fontdrvhost, sihost, ctfmon, TextInputHost
```

Así "por si se abre Brave u otro" queda cubierto sin que el usuario añada nada a mano.

La configuración se guarda en el JSON de perfiles que ya existe (`30-profiles.ps1`). Sin formato
nuevo.

---

## Arquitectura

**Módulo nuevo:** `src/40-session.ps1`. Hueco libre entre `38-regedit.ps1` y `45-cli.ps1`.
Debe cargar después de `32-measure.ps1`, donde ya vive el tipo `AXE.Native`.

### AXE.Native extendido

Sigue el P/Invoke que ya existe para `MeasureSleepDelta` / `MeasureJitter`:

```
CreateJobObject
AssignProcessToJobObject
NtSetInformationJobObject   <- JobObjectFreezeInformation
CloseHandle                 <- aqui actua la red del kernel
```

### Flujo

```
Get-AXESessionProcesses      toca Get-Process, NO juzga
        v hechos (pid, nombre, sessionId, ruta)
Get-AXESessionPlan           PURA  <- familias, niveles, frontera de sesion
        v {Intacto[], Degradado[], Congelado[]}
Start-AXESession             CreateJob -> Assign x N -> Freeze
        v objeto sesion (handle, plan, juego, hora)
Watch-AXESession             el juego sigue vivo?
        v muerto
Stop-AXESession              CloseHandle -> el kernel descongela
```

La decisión de **qué** hacer es pura y testeable sin hardware. La de **hacerlo** toca el kernel
y no se testea. Mismo reparto que `Get-AXEDiagFindings` vs `Get-AXEDiagFacts` en `35-diag.ps1`,
y que `Get-AXEFpsStats` vs `Measure-AXEFps` en `33-fps.ps1`. Está validado dos veces en el repo.

### Funciones públicas

| Función | Pura | Qué hace |
|---|---|---|
| `Get-AXESessionProcesses` | no | Lee procesos. No juzga. |
| `Get-AXESessionPlan` | **sí** | Hechos + config → los tres grupos. **El núcleo testeable.** |
| `Start-AXESession` | no | Crea el job, asigna, congela, degrada. Devuelve objeto sesión. |
| `Stop-AXESession` | no | Cierra el handle. El kernel descongela. |
| `Watch-AXESession` | no | Vigila el proceso del juego. |
| `Format-AXESession` | **sí** | Render compartido CLI/GUI. |

---

## Manejo de errores

| Fallo | Respuesta |
|---|---|
| `JobObjectFreezeInformation` no disponible | **Abortar limpio.** No congelar nada. Mensaje claro. Sin fallback. |
| `CreateJobObject` falla | Abortar. No se ha congelado nada todavía. |
| `AssignProcessToJobObject` falla en un pid | **Seguir**, contar, reportar al final. Un proceso protegido no debe tumbar la sesión. |
| El juego no existe al pulsar ON | No arrancar. Decirlo. |
| El juego muere | Salida normal por `Watch-AXESession`. |
| AXE muere (crash, kill, BSOD) | **Nada que hacer.** El kernel descongela al cerrarse el handle. Es el punto de todo el diseño. |
| Degradar prioridad falla | Seguir. Es best-effort, no crítico. Reportar. |

**Principio:** cualquier fallo antes de congelar → abortar sin tocar nada. Cualquier fallo
después → seguir y reportar, porque dejar la máquina a medias es peor que un resultado parcial.

---

## Testing

### Testeable sin hardware (`tests/Session.Tests.ps1`)

Todo sobre `Get-AXESessionPlan`, que recibe hechos sintéticos:

- Un proceso de Session 0 **nunca** sale como congelable
- `dwm`, `explorer`, `csrss`, `winlogon` nunca salen como congelables
- El proceso del juego nunca sale como congelable ni degradable
- El propio AXE nunca sale como congelable
- Los anti-cheat conocidos nunca salen como congelables
- Discord sale INTACTO, no DEGRADADO
- Brave, Vivaldi y Opera salen DEGRADADOS por familia sin estar listados uno a uno
- Un proceso desconocido de la sesión del usuario sale CONGELADO
- La config del usuario sobreescribe el default por app
- **Con la lista de procesos vacía, el plan sale vacío y no revienta**

### No testeable, y hay que saberlo

Que el freeze del job funcione de verdad. Pide hardware y una versión concreta de Windows. Se
documenta igual que `Fps.Tests.ps1` documenta que no cubre que PresentMon enganche un juego.

### Verificación manual antes de dar por bueno el módulo

1. Validar `JobObjectFreezeInformation` en Win10 y Win11 **antes de construir encima**.
2. Matar AXE desde el Administrador de tareas con la sesión activa → comprobar que todo
   descongela solo.
3. Medir con `Get-AXEFpsStats` sesión ON vs OFF, mismo juego y misma escena, y pasar el
   resultado por `Get-AXEFpsVerdict`. **Si sale ruido, se dice** — igual que hizo el barrido de
   timer, que en esta máquina salió `NO CONCLUYENTE` con `r=-0,49`.

---

## Riesgos abiertos

1. **Anti-cheat: no probado.** Congelar *otros* procesos es bastante menos arriesgado que tocar
   el proceso del juego —al anti-cheat le importa la manipulación del juego, no que Chrome esté
   parado— pero no está verificado por título. Va como riesgo abierto, no como resuelto.
2. **`JobObjectFreezeInformation` semi-documentada.** Es la decisión de la que cuelga todo el
   diseño de seguridad. Se valida primero.
3. **La ganancia depende del estado de la máquina.** En un PC potente y limpio el FPS medio
   cambia poco; lo que mejora es el stutter y los 1% lows. En una máquina cargada o con poca RAM
   la diferencia es grande en ambos. **No se promete un número: se mide.**

---

## Qué NO entra en este spec

- Pinning de CPU a CCD/P-cores (subsistema B)
- Cadena de input lag: Reflex, frame cap, polling (subsistema C)
- Corte de tráfico de fondo (subsistema D)
- Detección automática de juegos
- Fallback a suspensión manual si no hay freeze
- Interfaz gráfica del modo sesión (primero CLI, `-Session <proceso>`)
