# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/)
y [Versionado Semántico](https://semver.org/lang/es/).

## [Sin publicar]

### Añadido
- **Sesión de juego en la ventana** (spec `2026-07-25`, `webui/` + 5 cmds `session.*` del puente):
  el daemon del subsistema A existía y estaba testeado, pero **sólo se alcanzaba por CLI**; en la
  WebUI la entrada del rail decía «pronto». Ahora es una vista real (tecla `4`) que **previsualiza
  el reparto antes de tocar nada**: cuántos procesos y cuáles caen en CONGELAR / DEGRADAR / INTACTO,
  con la sonda de `JobObjectFreezeInformation` ya ejecutada, y ON deshabilitado si el kernel no lo
  soporta o el juego no está abierto. `session.preview` no crea job, no asigna y no congela.
  *Un ON a ciegas sobre ~15 procesos pide una confianza que no se ha ganado; las suites rivales no
  enseñan qué tocan.* La salida automática al cerrar el juego la mueve el sondeo de `session.status`
  (2 s) contra `Sync-AXESessionTracked` — el ciclo vive en el motor, no en el puente, y no hay
  `Watch` bloqueante en el hilo de la ventana. Coste escrito en la propia pantalla: la ventana tiene
  que quedarse abierta, porque ahí vive el handle del job.
- **El reparto es configurable y persiste** (`AXE/session_levels.json`): `Read-AXESessionOverrides`
  era un stub que devolvía `@{}` («hasta que exista la UI que los escriba»), así que «configurable
  por app» era una promesa a medias. Ahora hay par leer/escribir tolerante a corrupción y selector
  por app en la UI. Un override sobre shell o anticheat **se rechaza con motivo** en vez de
  guardarse y ser ignorado en silencio por el planificador: un ajuste que parece guardarse y no hace
  nada es peor que un rechazo.

### Corregido
- **La prioridad degradada ya no se queda baja si AXE muere** (`src/40-session.ps1`,
  `src/47-webhost.ps1`, `src/49-webmain.ps1`). El diseño apoyaba TODA la recuperación en el kernel:
  al cerrarse el handle del job, Windows descongela. Cierto para lo congelado y **falso para lo
  degradado** — bajar la prioridad no es estado del job, es una propiedad del proceso. Cerrar la
  ventana con sesión activa dejaba el navegador en `BelowNormal` hasta reiniciarlo, que es el «dejar
  la máquina a medias» que el spec prohíbe; y la sección nueva pone esa ruta al alcance de todos, no
  sólo de quien usa CLI. Ahora el cierre limpio llama a `Stop-AXESessionTracked` desde `Add_Closed`, y
  la salida sucia (kill, BSOD, corte de luz) la cubre un diario en `AXE/session_degraded.json` que el
  arranque siguiente consume. El diario verifica **pid + nombre + instante de arranque** antes de
  tocar nada, porque los pid se reusan y restaurar por pid a secas sube la prioridad de un tercero; y
  lleva **dueño**, para que con dos AXE abiertos el segundo no restaure a media partida ni borre la
  red del primero. Se ejerce con un proceso real degradado y restaurado, sin admin.
- **Los servicios POR-USUARIO ya no son congelables** (`src/40-session.ps1`). El spec del daemon
  asumía que «Session 0 queda fuera por definición» cubría a los servicios. No los cubre: Windows
  aloja `CDPUserSvc`, `WpnUserService`, `OneSyncSvc`, `UnistoreSvc` y compañía en instancias de
  `svchost` que corren **en la sesión interactiva**, y el planificador las clasificaba como
  desconocidas, es decir, CONGELABLES. Congelar un host de servicios por-usuario cuelga a quien le
  haga un RPC síncrono (shell, notificaciones, portapapeles) hasta el timeout. `svchost`, `conhost`
  y `audiodg` pasan a la familia `shell`. Lo cazó el nuevo check del puente, que corre
  `session.preview` sobre los procesos **reales** de la máquina: los 15 tests sintéticos no podían
  verlo porque su fixture ponía `svchost` en Session 0 — precisamente lo que la suposición daba por
  cierto.
- **El router de la ventana robaba teclas al selector de nivel** (`webui/app.js`): con el `<select>`
  enfocado, teclear para elegir una opción cambiaba de vista. `SELECT` entra en la misma exclusión
  que `INPUT`/`TEXTAREA`.
- **`Update.Tests.ps1` probaba lo contrario de lo que decía.** El caso «sin poder consultar la API
  dice error» pasaba `-Release $null`, que es indistinguible de omitir el parámetro, así que caía en
  `Get-AXELatestRelease` y **llamaba a la API de GitHub de verdad**. Verde sólo mientras no hubiera
  red ni releases publicados; con release empezó a devolver `current`. Ahora usa `Mock` y es
  determinista offline.
- **Cadena de confianza + updater** (subproyectos A+B, `src/43-update.ps1`, CLI `-Update` /
  `-Update -Check`): AXE pasa de «script que corres» a **producto instalable y actualizable con
  procedencia verificable**. Tres piezas, cada una garantiza algo distinto — `SHA256SUMS`
  (formato coreutils, verificable con `sha256sum -c` sin fiarse de nuestro código) da
  **integridad**; `sbom.json` (CycloneDX 1.5, generado a mano sin dependencias externas) da
  **transparencia** de lo que va dentro, con hash y licencia real por componente; la firma
  **Authenticode** con timestamp RFC3161 da **autenticidad**.
  **El updater se niega a reemplazar nada que no haya verificado.** El checksum por sí solo no
  basta, y no se finge que baste: viaja en el mismo release que el asset, así que prueba que el
  fichero llegó entero, no **quién** lo publicó. Como AXE se instala en una ruta escribible por
  el usuario y `AXE.bat` lo eleva después, un updater laxo sería una vía de escalada de
  privilegios — sin firma válida informa y se para. Owner/repo **hardcoded**, host de descarga
  validado contra lista, reemplazo atómico, cero telemetría (solo un GET público a la API de
  GitHub). 56 tests + SelfTest S30, con todos los rechazos ejercidos por fixtures y sin red.
  *La mayoría de optimizadores de GitHub se distribuyen como un `.bat` que hace `Invoke-WebRequest`
  a una URL y lo ejecuta; hone/Atlas piden confianza ciega en un binario cerrado.*
- **Pipeline de release** (`.github/workflows/release.yml`, `scripts/New-AXERelease.ps1`): un tag
  `v*` dispara el gate completo, empaqueta, firma **si hay certificado** y publica. Sin cert
  **degrada honesto**: el release sale marcado `SIN FIRMAR` en las notas y el updater no lo
  auto-instalará. No se finge una firma que no existe. Guard de coherencia tag ↔ `VERSION` (la
  misma clase de deriva que degradó la versión a `6.1.0-dev`), y dry-run en PR para que el
  pipeline falle allí y no la primera vez que se etiqueta una versión.
- **Distribución winget** (`scripts/New-AXEWingetManifest.ps1`, `packaging/winget/README.md`):
  manifiestos **generados** del release real, nunca a mano — de sus ~40 campos, tres cambian por
  versión y uno es un hash de 64 caracteres. La descripción del paquete dice también lo que AXE
  **no** hace (no toca la imagen de Windows, no desactiva Defender, no instala driver de kernel,
  no promete FPS sin medirlos). La PR a `microsoft/winget-pkgs` se abre a mano, a propósito.
- **Instalador ligero** (`scripts/New-AXEInstaller.ps1`): copia a `%LOCALAPPDATA%\AXE` + acceso
  directo. Sin admin, sin registro, sin MSIX y **sin tarea programada de auto-update**. Preserva
  el subárbol de runtime al actualizar: borrarlo destruiría los snapshots de revert del usuario.
  `-Verify` comprueba `SHA256SUMS` y firma **antes** de copiar nada.
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
