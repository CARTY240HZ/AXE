# AXE GAME SESSION — sección de UI + persistencia del reparto

**Fecha:** 2026-07-25
**Estado:** diseño aprobado, cierra el subsistema **A**
**Depende de:** `2026-07-20-axe-game-session-design.md` (daemon, implementado en `src/40-session.ps1`)
**Rama:** axe

---

## Problema

El daemon de sesión funciona y está testeado (planificador puro, 15 tests + SelfTest S28), pero
**sólo se alcanza por CLI** (`-Session <proceso>`). En la WebUI la entrada del rail dice `pronto` y
el botón del panel está `disabled`. Para el usuario que abre AXE, la función que más diferencia a
AXE de hone.gg / Pulse / Atlas / Delta **no existe**.

Y hay una promesa a medias: el spec de A dice que el nivel es "configurable por app, no lo decide
AXE", pero `Read-AXESessionOverrides` devuelve `@{}` fijo con el comentario *"hasta que exista la UI
que los escriba"*. El planificador acepta `-Config` y está testeado con overrides; lo que falta es
el par leer/escribir y quien lo edite.

Este spec cubre las dos cosas: **la sección de UI y la persistencia del reparto**. No añade
capacidades nuevas al kernel.

---

## Decisiones tomadas

### 1. Previsualización antes de congelar, no botón ON a ciegas

La sección enseña el reparto **antes** de tocar nada: cuántos procesos y cuáles caen en CONGELAR,
DEGRADAR e INTACTO, con la sonda de `JobObjectFreezeInformation` ya ejecutada.

**Por qué:** congelar ~15 procesos es la acción más agresiva de AXE. Un ON ciego pide una confianza
que no se ha ganado. La previsualización es el mismo principio que ya rige el catálogo (cada tweak
con su fuente y su estado real) y que el benchmark (mide, no promete). Las suites rivales esconden
qué tocan; aquí se lista con pid y nombre. La previsualización **no crea job, no asigna, no congela**.

### 2. Salida automática por sondeo desde el frontend, no por timer en el puente

Mientras hay sesión activa, el frontend llama `session.status` cada 2 s. El motor, en esa llamada,
comprueba si el proceso del juego murió y, si murió, **cierra la sesión él mismo** y devuelve el
motivo.

**Por qué esta y no un `DispatcherTimer`:** `48-webbridge.ps1` tiene una regla de cabecera —lista
blanca cerrada, cero lógica de negocio— y el ciclo de vida de una sesión es lógica de negocio; va en
`40-session.ps1`. `Watch-AXESession` (bloqueante) no sirve en la UI: colgaría el hilo que atiende el
puente. El sondeo mantiene el ciclo donde pertenece y deja el puente como re-empaquetador.

**Coste honesto, y va escrito en la propia sección:** la salida automática necesita la ventana de
AXE abierta, porque es donde vive el handle del job. Eso no es una limitación nueva del sondeo: es
el invariante del spec de A (*AXE abierto = sesión viva*). Si AXE muere, el kernel descongela; lo
que se pierde con la ventana cerrada no es la recuperación, es el aviso.

### 3. El reparto persiste en su propio fichero, no dentro de `game_profiles.json`

`AXE/session_levels.json`: un objeto plano `{ "chrome": "congelado", ... }`, mismo patrón de
lectura tolerante que `Read-Profiles` (ausente o corrupto → vacío, nunca lanza).

**Desviación consciente del spec de A**, que decía reutilizar el JSON de perfiles "sin formato
nuevo": `game_profiles.json` es un **array** de perfiles de plan de energía
`{Name,Exe,Plan,PlanName}` que `Read-Profiles` / `Tick-GameProfiles` recorren. Meter un mapa
app→nivel en ese array mezcla dos esquemas sin relación y obliga a todos sus consumidores a
filtrar. Un fichero de 1 KB con el mismo patrón de tolerancia cuesta menos y no arriesga el
monitor de perfiles, que sí toca el plan de energía en vivo.

### 4. Los procesos duros no son configurables: doble red

El escritor **rechaza** un override sobre juego / AXE / shell / anticheat con motivo explícito, y la
UI no ofrece el selector para ellos.

**Por qué las dos:** el planificador ya los protege (los duros ganan a la config, y está testeado),
así que un override sobre `explorer` sería *silenciosamente ignorado*. Un ajuste que parece
guardarse y no hace nada es peor que un rechazo. La UI evita el paso en falso; el escritor lo
garantiza aunque la UI se equivoque.

### 4-bis. Los servicios **por-usuario** también son duros (corrección al spec A)

El spec de A decidió que la frontera fuera el `SessionId`, con este argumento: *"Session 0 queda
fuera por definición: servicios, drivers, `audiodg`, `lsass` los aisló ya el SO"*. **Es incompleto.**
Windows aloja los servicios *por-usuario* — `CDPUserSvc`, `WpnUserService`, `OneSyncSvc`,
`UnistoreSvc`, `PimIndexMaintenanceSvc` — en instancias de `svchost` que corren **en la sesión
interactiva**, no en la 0. El planificador los clasificaba como desconocidos, es decir, CONGELABLES.

Congelar un host de servicios por-usuario cuelga a quien le haga un **RPC síncrono** (shell,
notificaciones, portapapeles) hasta que expire el timeout. `svchost`, `conhost` y `audiodg` pasan a
la familia `shell`, con lo que quedan INTACTOS y no configurables por las dos redes de la decisión 4.

**Cómo salió a la luz:** el test del puente corre `session.preview` sobre los procesos **reales** de
la máquina, no sobre un fixture. Los 15 tests sintéticos del spec A no podían verlo, porque el
fixture ponía `svchost` en Session 0 — que es exactamente lo que la suposición daba por cierto. La
lección va al testing: **un check sobre la máquina real, aunque sólo pueda afirmar propiedades
(«ningún duro sale tocable»), caza lo que el fixture no sabe que existe.**

### 5. Una sesión por proceso AXE, y `start` sobre sesión viva no crea otra

Invariante del spec A (*un proceso, un dueño, un estado*). `Start-AXESessionTracked` con sesión ya
activa devuelve **la actual** y lo registra en el log, sin crear un segundo job. La UI no ofrece ON
mientras hay sesión, así que este camino es una red defensiva, no un flujo.

**Por qué:** dos jobs con dos handles rompen la única cosa que hace segura la recuperación por
kernel: que cerrar *el* handle descongele *todo*.

### 5-bis. La prioridad degradada necesita su propia red: el kernel no la cubre

El spec de A apoya **toda** la recuperación en el kernel: al cerrarse el handle del job, Windows
descongela solo. Es cierto para lo CONGELADO y **falso para lo DEGRADADO**: bajar la prioridad no es
un estado del job, es una propiedad del proceso. Nadie la devuelve si AXE muere — ni siquiera si el
usuario simplemente **cierra la ventana**, porque `Add_Closed` liberaba timers y no la sesión. El
navegador se quedaba en `BelowNormal` hasta reiniciarlo: el «dejar la máquina a medias» que el propio
spec prohíbe. La UI lo agrava, porque pone esa ruta al alcance de todos y no sólo de quien usa CLI.

Dos redes, una por tipo de salida:

- **Salida limpia** (cerrar la ventana): `47-webhost.ps1` llama a `Stop-AXESessionTracked` en
  `Add_Closed`.
- **Salida sucia** (kill, BSOD, corte de luz): diario en `AXE/session_degraded.json`, escrito al
  degradar y consumido en el arranque siguiente por `Restore-AXESessionDegraded`
  (`49-webmain.ps1` para la ventana, bloque `-Session` para la CLI).

Dos cosas que el diario **tiene** que verificar, y verifica:

1. **Los pid se reusan.** Restaurar por pid a secas sube la prioridad de un tercero que heredó el
   número. Se guarda pid + nombre + instante de arranque (`Test-AXESessionSameProcess`) y, ante
   cualquier duda, no se toca. Lo mismo aplica dentro de la sesión: `Stop-AXESession` ahora verifica
   identidad antes de escribir.
2. **Puede haber dos AXE abiertos.** El diario lleva **dueño** (pid + nombre + arranque del proceso
   AXE). Si el dueño sigue vivo y no soy yo, no se restaura *ni se borra*: sigue siendo su red. Sin
   esto la segunda instancia devolvía prioridades a media partida y, peor, borraba el diario —
   dejando a la primera sin red justo para el caso que el diario existe para cubrir.

Formato (`AXE/session_degraded.json`):

```json
{ "owner": { "pid": 111, "name": "powershell", "startTicks": 638000000000000000 },
  "degraded": [ { "pid": 12345, "name": "chrome", "prev": "Normal", "startTicks": 638000000000000000 } ] }
```

### 6. El estado que pinta la UI es una función pura de su argumento

`Get-AXESessionStatus -Session $s` no lee estado global: recibe el objeto de sesión (o `$null`) y
devuelve el DTO. La variable de sesión viva la resuelve el llamante.

**Por qué:** es lo que hace el DTO testeable headless, igual que `Get-AXESessionPlan`. Mismo reparto
puro/impuro que ya está validado tres veces en el repo (`35-diag`, `33-fps`, `40-session`).

---

## Arquitectura

### Motor — `src/40-session.ps1` (extiende la región 12b)

| Función | Pura | Qué hace |
|---|---|---|
| `Get-AXESessionLevelsPath` | no | Resuelve el fichero de overrides. `$script:AXESessionLevelsFile` lo sobrescribe (tests). Sin `$script:AXEData` → `$null`. |
| `Read-AXESessionOverrides` | no | Fichero → `@{nombre=nivel}`. Ausente/corrupto/entradas inválidas → se ignoran. **Nunca lanza.** (Sustituye al stub que devolvía `@{}`.) |
| `Set-AXESessionOverride` | no | Escribe/borra un override. Valida nivel; rechaza duros. Devuelve `{Ok,Reason,Overrides}`. |
| `Get-AXESessionFamily` | **sí** | Nombre → familia (`navegador`/`voz`/…) o `$null`. Para etiquetar en la UI. |
| `Test-AXESessionHardApp` | **sí** | Nombre → `$true` si es shell/anticheat (no configurable). |
| `Start-AXESessionTracked` | no | `Start-AXESession` + guarda la sesión viva. Idempotente. |
| `Stop-AXESessionTracked` | no | `Stop-AXESession` + limpia y guarda el motivo de cierre. |
| `Sync-AXESessionTracked` | no | Si el juego murió → cierra con motivo. Devuelve la sesión viva o `$null`. |
| `Get-AXESessionStatus` | **sí** | Sesión (o `$null`) + motivo → DTO plano para el frontend. |
| `Test-AXESessionSameProcess` | no | pid + nombre + arranque → ¿sigue siendo ESE proceso? Ante duda, `$false`. |
| `Write-AXESessionJournal` | no | Deja el diario de prioridades con su dueño. Best-effort. |
| `Restore-AXESessionDegraded` | no | Repara prioridades de una sesión que murió sucia. Devuelve cuántas. |
| `Clear-AXESessionJournal` | no | Borra el diario (cierre en orden). |

`Watch-AXESession` y la ruta CLI **no cambian**: el bloqueante sigue siendo el camino de `-Session`.

### Puente — `src/48-webbridge.ps1` (5 cmds, lista blanca cerrada)

| cmd | Modifica | Devuelve |
|---|---|---|
| `session.preview` | **no** | `{freezeOk, freezeReason, gameFound, gamePid, counts{…}, apps[]}` |
| `session.start` | sí | DTO de estado + `lines` de `Format-AXESession` |
| `session.status` | sí (auto-cierre) | DTO de estado |
| `session.stop` | sí | DTO de estado |
| `session.setLevel` | sí (fichero) | `{ok, reason, overrides}` |

`apps[]` = `{pid, name, level, family, hard, override}`. `level` es el nivel **resultante** (con
override aplicado), `override` dice si vino del usuario: la UI no recalcula reglas, sólo pinta.

`session.setLevel` con `level='default'` borra el override. Sin admin, `session.start` no se niega:
degrada a lo que el usuario posee y **reporta los fallos** (`Failed`), que es lo que ya hace el
motor.

### Frontend — `webui/index.html`, `webui/app.js`, `webui/styles.css`

- Rail: la entrada `soon` pasa a `data-view="sesion"` con tecla **4** (hueco libre en `keyMap`).
- Panel: el botón `disabled` pasa a `data-view="sesion"`.
- Vista `#viewSesion`: barra de estado · tarjeta de arranque (campo de juego, *Previsualizar*, ON /
  OFF, sonda de freeze, tiempo activo) · tarjeta de reparto (contadores + apps con selector de
  nivel, duros marcados y sin selector) · salida cruda de `Format-AXESession` · tarjeta de
  honestidad (recuperación por kernel, coste de degradar el navegador, anticheat no verificado por
  título, la ventana abierta).
- `lazyInit.sesion` (init perezoso, como el resto). El sondeo de 2 s corre **mientras haya sesión
  activa**, aunque el usuario navegue a otra vista.
- CSS: reutiliza `card` / `obar` / `btn` / `in` / `mono-out` / `badge`; se añade sólo la rejilla de
  apps y el selector de nivel.

---

## Manejo de errores

| Fallo | Respuesta |
|---|---|
| Campo de juego vacío | La UI no llama al puente; pide el nombre. |
| Juego no corriendo (preview) | `gameFound=false` y el plan **se enseña igual** (es informativo). ON queda deshabilitado. |
| Juego no corriendo (start) | El motor ya se niega con motivo; la UI lo pinta. |
| `JobObjectFreezeInformation` ausente | `freezeOk=false` + motivo con el status; ON deshabilitado. Sin fallback (regla del spec A). |
| Fichero de overrides corrupto | Se ignora, se sigue con los defaults. No se borra: se deja para inspección. |
| `$script:AXEData` ausente (motor cargado suelto) | `Read` devuelve `@{}`; `Set` devuelve `Ok=$false` con motivo. |
| Override sobre proceso duro | Rechazo con motivo. No se escribe nada. |
| `start` con sesión ya activa | Devuelve la activa con motivo. No crea un segundo job. |
| El juego muere | `session.status` lo detecta, cierra y devuelve el motivo. |
| La ventana se cierra / AXE muere | El kernel descongela al cerrarse el handle. Invariante del spec A. |

---

## Testing

### `tests/Session.Tests.ps1` (headless, sin kernel)

- Overrides: fichero ausente → `@{}`; JSON corrupto → `@{}` sin lanzar; round-trip escribir→leer;
  nivel inválido rechazado; `'default'` borra la entrada; override sobre duro rechazado y **no
  escrito**; sin ruta resoluble `Set` devuelve `Ok=$false`.
- `Get-AXESessionFamily`: `brave`→`navegador`, `discord`→`voz`, `chrome.exe` (con extensión)→
  `navegador`, desconocido→`$null`.
- `Test-AXESessionHardApp`: `explorer`/`EasyAntiCheat` → `$true`; `chrome` → `$false`.
- `svchost` **de la sesión interactiva** sale INTACTO, y sigue saliendo INTACTO aunque el usuario
  fuerce `congelado` por override (decisión 4-bis).
- El puente sobre procesos reales: ninguna fila con nivel distinto de `intacto` es dura, y `svchost`
  nunca aparece como congelable ni degradable. Es el check que encontró la decisión 4-bis.
- `Get-AXESessionStatus`: `$null` → `active=false` sin lanzar; sesión fallida → `active=false` con
  su motivo; sesión sintética → contadores y `elapsedS` presentes.
- El planificador con overrides ya está cubierto; se añade que un override **leído del fichero**
  llega al plan (integración de las dos piezas, sin tocar procesos reales).

### SelfTest (`-SelfTest`, S28 ampliado)

S28 ya **ejerce** el planificador. Se le añade, con `$script:AXESessionLevelsFile` apuntado a un
temporal y restaurado al salir: round-trip de override, rechazo del duro, y forma del DTO de
estado. Headless, sin tocar el `AXE/` real.

`S-webui-3` cubre gratis los 5 cmds nuevos: exige biyección lista blanca ↔ literales
`AXE.call('…')` del JS. Un cmd sin llamada, o una llamada sin cmd, pone el gate en rojo.

### Diario de prioridades — se ejerce con un proceso real, sin admin

Lo demás del módulo se prueba con hechos sintéticos, pero una red que sólo existe para el día que
algo va mal hay que **verla funcionar**. Estos tests lanzan otro proceso del mismo host que corre la
suite, lo degradan a `BelowNormal`, simulan que AXE murió sin cerrar, y comprueban el resultado:

- la prioridad **vuelve de verdad** y el diario se consume (no se repite en el arranque siguiente);
- un pid con **otro nombre** o con **otro instante de arranque** no se toca (pid reusado);
- un diario cuyo **dueño sigue vivo** no se restaura ni se borra;
- si el dueño ya murió, sí se repara — el caso que el diario existe para cubrir;
- un diario ilegible se descarta sin lanzar.

En el SelfTest (S28) la misma propiedad se ejerce sin lanzar procesos: se escribe el diario contra el
propio pid con el arranque cambiado y se exige que **se niegue** a restaurar.

### No testeable, y hay que saberlo

Que el freeze funcione de verdad (pide hardware y versión de Windows) y que el anticheat de un
título concreto no se moleste. Igual que en el spec de A: se documenta, no se finge.

### Verificación manual antes de dar por bueno

1. Previsualizar sin juego abierto → plan visible, ON deshabilitado, nada congelado.
2. ON con juego abierto → contadores coherentes; comprobar en el Administrador de tareas que el
   navegador sigue vivo y que lo congelado está suspendido.
3. Cerrar el juego → la sección pasa a OFF sola con el motivo, en ≤ 2 s.
4. Matar AXE desde el Administrador de tareas con sesión activa → todo descongela solo, y al abrir
   AXE otra vez las prioridades degradadas vuelven a su valor previo (diario).
5. Cambiar el nivel de una app, reabrir AXE → el nivel persiste.
6. Cerrar la ventana con sesión activa → comprobar en el Administrador de tareas que el navegador
   recupera prioridad `Normal` sin reiniciarlo.

---

## Qué NO entra

- Subsistemas **B** (pinning CPU a CCD/P-cores), **C** (cadena de input lag) y **D** (corte de
  tráfico de fondo) del spec de A. Siguen pendientes, cada uno con su riesgo y su spec.
- Detección automática de juegos (entrada manual, por decisión del spec A).
- Fallback a suspensión manual si no hay freeze.
- Medición del beneficio dentro de la sección: eso ya lo hacen `Prueba y receta` (FPS/benchmark) y
  se mide **fuera**, ON vs OFF, con el veredicto de ruido. La sección no promete un número.
- i18n de la sección: entra con el subproyecto **G** del roadmap maestro, no aquí.
