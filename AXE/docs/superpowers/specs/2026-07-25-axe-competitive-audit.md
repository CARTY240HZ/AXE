# Auditoría competitiva y de catálogo — 2026-07-25

**Estado:** cerrado; pendientes resueltos el 2026-07-26 (§8). **Rama:** `axe`.
**Versión al auditar:** v7.0.0, 78 tweaks → 81 → **82**.

Documento de traspaso. Lo caro de esta sesión no fue el código: fue **verificar qué hace la
competencia** y **descubrir qué ítems del plan eran malos**. Eso es lo que se guarda aquí para no
volver a pagarlo.

---

## 1. Competencia — datos verificados en web (2026-07-25)

Todo lo de abajo sale de la web oficial de cada producto. Lo no verificado está marcado.

### PULSE — `pulse-optimization.com` (competidor directo real)

- **84 tweaks**: Windows 19 · Red 12 · GPU 9 · Power 6 · Input delay 6 · Gaming 6 · Storage 5 ·
  Memoria 5 · CPU 4 · Security 4 · Boot config 4 · Audio 4
- Revert: snapshot JSON antes de cambiar, *"one click undoes everything"*
- Mide: DPC latency, ping, jitter, packet loss, FPS/frametime **vía RTSS**
- **Live Tune**: lee telemetría cada 4 s, ajusta *driver quality* de GPU para sostener frametime
- GPU OC NVIDIA/AMD/RDNA4 (Eco/Balanced/Max), CPU tuner (power, turbo, EPP)
- 14 MB de Rust, **sin driver kernel**, user space. Declara compatible EAC/BattlEye/Vanguard/VAC
- Free $0 (solo monitorización) · Pro **$19.99/año** (estándar $29.99)
- Claim: *"15–45% more FPS on many CPU-bound games"*, admite que GPU-bound gana menos

### Hone — `hone.gg`

- Free = **10 optimizaciones** · Premium **$2.99/mes** anual
- Claims: free "15% FPS Boost", premium "30% FPS Boost". **Sin auditoría de terceros**
- 2.5M usuarios, Epic Games Store + Overwolf, 100.000+ títulos
- **No publica**: nº de tweaks, driver kernel, mecanismo de revert, postura anti-cheat

### Pulse Hardware — `pulsehard.com` — **no es software**

Servicio humano remoto. Sesión 15–25 min. Toca BIOS, overclock, **timings de RAM**, Windows, red.
Claim +72% FPS medio. Mide antes/después. Precio no recuperable (el sitio devuelve HTTP 403).

### DELTA Pro — `dprojects.org`

App Windows, **$22.99** pago único (subs desde $1.99/mes). 12 módulos: compresión de Windows,
migración de edición, GPU, disco, detección de hardware, instalar DirectX/VC++, Office,
personalización, gestión de componentes, privacidad+IA, modos Safe/Medium/Extreme, planes de
energía. **Reversibilidad: no la declara. Benchmarking: ninguno.**

### Gratuitos

- **hellzerg/optimizer** (GPL-3.0): **archivado 2026-01-20**, sucesor OptimizerNXT. Sin revert
  documentado, sin benchmark. Ya no es competencia.
- **ChrisTitusTech/winutil** (MIT): Installs/Tweaks/Config/Updates, presets Standard/Minimal/
  Advanced. Su página no documenta revert ni benchmark — *dato incompleto, la página cargó parcial*.
- **AtlasOS** (GPL-3.0): no es app, es modificación de Windows vía AME Wizard playbook.
  ~1,5 GB RAM liberada al arranque. **Sin rollback: "You will need to reinstall Windows."** Win11.

### Dónde está AXE realmente

Primero o segundo en el nicho *"tweaker gratuito, reversible, con medición honesta"*. PULSE es el
único que lo disputa: más features, menos transparencia. Fuera de ese nicho (overclock, BIOS,
bucle cerrado sobre driver de GPU) AXE **no compite, y por diseño no debería**.

**Ventaja metodológica real y defendible:** PULSE mide con RTSS (contador de overlay); AXE con
PresentMon sobre tiempos de frame presentados (`33-fps.ps1:9-22`), que es la convención de
CapFrameX y las reviews. Y AXE declara el límite que PULSE calla (`33-fps.ps1:24-28`): dos
capturas de escenas distintas miden el mapa, no el tweak.

---

## 2. Auditoría del plan de mejora — 7 defectos

Criterio fijado **antes** de auditar: **C1** hueco verificado en código · **C2** no rompe el
invariante de reversibilidad · **C3** sin ring0 ni hardware · **C4** coherente con los valores del
proyecto (nada de afirmar sin medir, nada de métricas de vanidad).

| # | Sev | Defecto |
|---|---|---|
| D-01 | **BLOQUEANTE** | La resolución de timer **no es palanca válida en vivo**. `32-measure.ps1:182-190` documenta que desde build 19041 el request es **por proceso**; lo global es `GlobalTimerResolutionRequests` = tweak `lat_timerres`, y ese es `Reboot=$true`. Quedan **2 palancas** (plan de energía, prioridades), no 4. |
| D-02 | MAYOR | El bucle cerrado **no puede igualar Live Tune**: el mando de PULSE es driver quality de GPU, que AXE no controla ni debe. Además el periodo real es 30–60 s (un 1% low válido necesita ventana larga), no 4 s. |
| D-03 | MAYOR | Ignoraba la maldición del ganador, que el repo **ya resolvió** en `Get-AXESweepVerdict` (`32-measure.ps1:229-236`). Un lazo que elige "la mejor config medida" cae en la misma trampa, amplificada al iterar. Reusar esa función, no reinventar. |
| D-04 | MAYOR | "98 > 84 tweaks" es **métrica de vanidad** — la lógica de marketing que el proyecto rechaza. Los huecos son reales; el contador no es la razón. |
| D-05 | MAYOR | "Unificar perfiles" choca con una decisión ya tomada y documentada en `40-session.ps1:99-103` (esquemas separados a posta). Unificar en **orquestación**, nunca en disco. |
| D-06 | MENOR | El A/B vs PULSE no es "1 sesión": exige misma escena, N repeticiones, **desinstalar PULSE entre tandas**, y $19.99. |
| D-07 | MENOR | Todas las estimaciones de esfuerzo carecían de base. Retiradas. |

---

## 3. Decisiones — qué se rechazó y por qué

**Releer esto antes de "arreglar" cualquiera de estos puntos. Todos parecen huecos y no lo son.**

| Rechazado | Motivo |
|---|---|
| Añadir tweak `useplatformclock` | **Sería regresión.** `28-revert-export.ps1:16-17` lo limpia como residuo de **AXE v1**; v2 lo quitó de apply a propósito. Forzar HPET empeora latencia. |
| Benchmark de DNS | Se iba a construir sobre **código muerto**: `$script:DNSPROFILES` no tenía ni un consumidor (la pestaña DNS murió en el cutover a WebUI, fase 8 de v7). La lista se borró. Si vuelve una sección DNS, que llegue **midiendo**. |
| Tweak EPP (`PERFEPP`) y PCIe ASPM | **Ocultos por atributo** en el plan de energía de la máquina de pruebas; `powercfg /query` no los devuelve. No se escriben GUIDs que no se ha visto responder. |
| Desactivar defrag programado en SSD | **Mito.** Win10/11 ya detecta SSD y manda retrim en vez de desfragmentar. Apagarlo quita el retrim. |
| `net_rsc`, `AutoTuningLevel`, LSO | RSC: no verificado (ver §4). AutoTuning/LSO: folclore; desactivar autotuning perjudica con BDP alto. |
| Duplicar last-access / 8.3 en DISCO | Ya existen como `mem_lastaccess` / `mem_8dot3` en MEMORIA. Duplicar solo engorda el contador (D-04). |
| Overclock de GPU | Viola **C2**: el revert no puede deshacer un cuelgue. Si algún día entra: módulo aislado, Tier 2, fuera de MASTER. |

---

## 4. ~~Abierto~~ — RESUELTO 2026-07-26

**Resuelto sin tocar el contrato de `Test`.** La pregunta era si `Test` podía devolver un tercer
estado. Respuesta: **no debe**. Lo consumen el score, el SelfTest, el puente y la GUI como
booleano; volverlo tri-estado los rompe a los cuatro en silencio.

El tercer estado ya existía en otro sitio: **el gate**. Nueva clave `Requires=@{NicProp='...'}`
en `Get-BlockReason` (`20-tweaks.ps1`). Si el adaptador no expone ese `RegistryKeyword` de NDIS,
el tweak sale de la lista con motivo — *"el adaptador 'Wi-Fi' no expone \*InterruptModeration: no
hay nada que aplicar aquí"* — en vez de pintarse igual que uno aplicado.

Por qué esta salida y no las dos que ya se habían descartado:

- No es `Requires=@{Wired=$true}`: eso seguiría siendo **falso** para un Wi-Fi que sí expone la
  propiedad. `NicProp` pregunta por **la propiedad**, no por el medio.
- No es devolver `$false`: seguiría siendo la mentira simétrica de "no aplicado".

Arregla de paso el mismo fallo en otro sitio: las reglas `net_intmod` de `RECRULES` y `LATRULES`
usaban la heurística `-not $h.IsWifi`, con idéntico falso. Ahora llaman a `Test-AXENicProp`, y
`Get-AXELatencyNotes` dejó de deducirlo del medio.

La enumeración NDIS es cara → cache permanente con la clave del NIC. **No se cachea sin HW
detectado**: en la GUI el hardware llega desde un runspace de fondo y una lista vacía guardada
como permanente dejaría el gate mintiendo el resto de la sesión.

El `return $true` vacuo sigue en el `Test` como defensa para `-List` (evalúa el catálogo sin
gating) y para el hueco entre arranque de GUI y llegada del HW, donde `Get-BlockReason` retorna
`$null` por no tener hardware que consultar.

### Contexto original del problema

### `net_intmod` se pinta verde sin hacer nada en adaptadores que no exponen la propiedad

`20-tweaks.ps1:140-149`. El `Test` devuelve `$true` cuando el adaptador no expone
`*InterruptModeration`:

```powershell
$p = Get-NetAdapterAdvancedProperty -Name $script:HW.NicName -RegistryKeyword '*InterruptModeration' -EA SilentlyContinue
if($null -eq $p){ return $true }
```

Verificado en la máquina de referencia: adaptador activo **Wi-Fi**, no expone *ninguna* de
`*RscIPv4` / `*LsoV2` / `*FlowControl` / `*InterruptModeration`. El tweak sale como **aplicado**
sin haber tocado nada.

El comentario del código lo defiende como "true vacuo, correcto" y es defendible. Pero para el
usuario **"aplicado" y "no aplica aquí" no son el mismo estado**, y la UI los pinta igual.

**No se parcheó**, porque las dos salidas fáciles son incorrectas:

- Gatear con `Requires=@{Wired=$true}` (la clave existe en la whitelist, `45-cli.ps1:95`) sería
  **falso** para un Wi-Fi que sí exponga la propiedad.
- Devolver `$false` reportaría "no aplicado" en algo que no se puede aplicar — mentira simétrica.

**La pregunta real:** ¿puede `Test` devolver un tercer estado ("no procede") o eso vive en
`Get-BlockReason`? Afecta también a `net_nagle`, `net_rss`, `net_ctcp`. Decisión del dueño.

---

## 5. Pendiente — estado a 2026-07-26

| # | Ítem | Estado |
|---|---|---|
| 1 | `SvcHostSplitThresholdInKB` | **HECHO** — tweak `svc_hostsplit`, ver §8 |
| 2 | Verificar `net_rsc` en adaptador cableado | **BLOQUEADO** — no hay hardware. Ver abajo |
| 3 | Tercer estado de `Test` | **HECHO** — ver §4 |
| 4 | Monitor de red en vivo | **HECHO** — `src/37-netmon.ps1`, ver §8 |
| 5 | Regulador de carga de fondo | **RECHAZADO** — ver abajo, con evidencia |

### 2 — por qué sigue bloqueado

`net_rsc` no está en el catálogo y no se añade a ciegas. La máquina de referencia tiene el Wi-Fi
como adaptador activo y **no expone** `*RscIPv4` / `*LsoV2` / `*FlowControl` /
`*InterruptModeration`. Con el gate `NicProp` de §4 ya construido, el día que haya una máquina
cableada el trabajo es: comprobar que la propiedad existe, medir, y si aporta, añadir el tweak con
`Requires=@{NicProp='*RscIPv4'}`. **La infraestructura ya está; falta el hardware, no el código.**

### 5 — rechazado, y por qué (mismo criterio que §3)

El plan pedía un lazo cerrado sobre 2 palancas con periodo 30–60 s. Al mirar el código, las dos
palancas y el instrumento fallan:

| Pieza | Qué dice el código |
|---|---|
| Palanca "prioridades" | `40-session.ps1:317-350`: durante una sesión el fondo ya está **congelado** con Job objects del kernel y el resto degradado a `BelowNormal`. No es un dial: es binario y ya está al máximo. Modularlo cada 30–60 s significaría **descongelar el fondo periódicamente mientras juegas** — estrictamente peor. |
| Palanca "plan de energía" | `rend_ultperf` (`20-tweaks.ps1`) usa `powercfg /setactive`. Cambiar de plan a mitad de partida **es en sí una perturbación**, y estando ya en Ultimate Performance no hay a dónde subir. |
| Instrumento | `Measure-AXEJitter` (`32-measure.ps1:521-535`) es un **busy-loop** de 1 s. Correrlo mientras el usuario juega roba un núcleo y **añade el stutter que pretende medir**. Un instrumento que perturba lo que mide no cierra ningún lazo. |

Y el veredicto que D-03 mandaba reusar no es reusable tal cual: `Get-AXESweepVerdict`
(`32-measure.ps1:299-315`) lleva un chequeo **físico** específico de la cuantización del timer
(`ceil(1/R)*R - 1`). Con 2 puntos de palanca ese modelo no significa nada y la correlación sale
±1 por construcción. Reusarla sin más daría veredictos con aspecto de rigor y cero contenido.

**Conclusión:** el regulador no es un hueco de AXE, es una función de un producto con otra
arquitectura (PULSE modula *driver quality* de GPU, que AXE ni controla ni debe — D-02). Si algún
día entra, entra por otra puerta: un instrumento que **no perturbe** durante el juego. Mientras
tanto, el A/B honesto ya existe y no requiere lazo: `-Benchmark` / `-Benchmark -After`
(`41-bench.ps1`).

### A/B a coste cero

La restricción de $0 deja fuera PULSE Pro. Alternativas gratis:

- **`winutil.exe` ya está en la raíz del repo** — MIT, A/B completo por $0.
- **Hone free** (10 optimizaciones) — A/B parcial.
- **OptimizerNXT** — sucesor de hellzerg.
- PULSE: comparativa de *features* gratis (publican el desglose); el A/B de FPS queda fuera.

Sin una tabla A/B, "somos superiores" es marketing — y este proyecto está construido para no
hacer marketing.

---

## 6. Cambios de esta sesión

| Fichero | Cambio |
|---|---|
| `README.md` | Sección **Anti-cheat**: la regla exacta de `Get-AXESessionLevel` y dónde vive, en vez de un "compatible con EAC/BattlEye/Vanguard/VAC" en bloque. Declara la única incertidumbre real (`lat_timerres`). |
| `src/20-tweaks.ps1` | +3 tweaks, 3 categorías nuevas: `dsk_trim` (DISCO, T0), `aud_protectedaudio` (AUDIO, T2, `PlaceboLikely=$true`), `pwr_usbsuspend` (ENERGIA, T1, GUIDs verificados con `powercfg /query`, captura el previo en `HKCU:\Software\AXE` como `cpu_park`). |
| `src/22-catalogs.ps1` | −7 líneas: `$script:DNSPROFILES` borrado (código muerto que además rankeaba sin medir). |
| `src/25-assistant.ps1` | String obsoleto "pestana DNS" → apunta al tweak `net_dns` y repite su advertencia (no da FPS). |

**Verificado:** `SelfTest` 81 tweaks / 111 checks / **0 fallos** · Pester **456 passed, 0 failed**
(Catalog + Gating + RevertFidelity) · suite completa antes de los tweaks: **664 passed, 0 failed**.

### Nota suelta

El badge del README dice `671 tests passing`; la ejecución local da 664 + 49 skipped. Los skips
varían por hardware, así que CI puede dar otro número legítimamente. **No se tocó** — pero en un
proyecto que vende honestidad, ese badge merece una revisión del dueño.

---

## 7. Cómo se auditó (para repetirlo)


Fijar el criterio **antes** de mirar. Sin criterio, una auditoría siempre encuentra algo, porque
encontrar cosas parece útil — y eso es ruido, no rigor. Cada hallazgo va contra `fichero:línea`.
Si no hay evidencia, no es un hallazgo: es una opinión.

Resultado de aplicarlo aquí: **2 ítems del plan murieron al leer el código** (`useplatformclock`
era una regresión, el benchmark DNS colgaba de código muerto) y la auditoría de conexiones
`webbridge` ↔ `app.js` salió **limpia** — las 21 acciones tienen consumidor, cero huérfanas. Un
resultado negativo es un resultado. No se fabrica una desconexión para tener algo que arreglar.

---

## 8. Sesión 2026-07-26 — cierre de los pendientes

Se cerró §4 y los ítems 1, 3, 4 de §5; el 5 murió al leer el código (§5), el 2 sigue sin hardware.

### Catálogo: 81 → 82 tweaks

`svc_hostsplit` (SERVICIOS, **Tier 2**, `Reboot=$true`, `PlaceboLikely=$true`). Deshace el reparto
1-servicio-por-proceso de Win10 1703+ subiendo `SvcHostSplitThresholdInKB` por encima de la RAM.

**Verificado antes de escribir**, no asumido — la misma regla que dejó fuera EPP y PCIe ASPM en §3.
Con el umbral por encima de la RAM, en la máquina de referencia: 92 servicios en 41 procesos, solo
**2 de 92** lanzados en forma split (`-k <grupo> -p -s <servicio>`), y los del mismo grupo
comparten PID (`netsvcs` 20 servicios / 3 PIDs, `DcomLaunch` 7 / 1). El mecanismo responde.

Honestidad del encuadre: lo que ahorra son **procesos**, no frames. `PlaceboLikely=$true` para que
nunca entre en el set recomendado ni en el de latencia. El coste es exactamente la razón por la
que Microsoft los separó: se pierde el aislamiento por servicio ante cuelgues y el hardening de
token por servicio.

**Clave nueva `MaxRam`** (simétrica a `MinRam`). `svc_hostsplit` lleva `MaxRam=8` porque por
encima de esa RAM el ahorro es irrelevante y **solo queda el inconveniente**. Sin ese techo, el
tweak sería una trampa en un equipo de 32 GB. Por debajo de ~3,5 GB Windows ya agrupa de fábrica y
el tweak es un no-op, así que la ventana útil es estrecha y está declarada.

El `Test` pregunta por la **regla** (`umbral > RAM física`), no por una constante: un `-eq` contra
un número mágico daría falso en cualquier máquina con otra RAM. Dato encontrado de paso: la
máquina de referencia venía con `137922056`, que **no es el default de Microsoft** (`0x380000`).
Algo la tocó antes. El `Revert` normal restaura el valor real capturado por el snapshot; el
fallback avisa de que 0x380000 es el default documentado y no necesariamente *tu* valor previo.

### Monitor de red — `src/37-netmon.ps1` (cobertura pasa de cero)

CLI `-NetMon [-NetMonTarget <ip>] [-NetMonCount N]`, puente `net.probe`, tarjeta en Telemetría.

Decisiones que lo separan de un `ping` con esteroides:

- **Dos destinos, reportados aparte.** Puerta de enlace = tu enlace; ancla pública = el camino a
  internet. Es lo único que distingue *tu Wi-Fi* de *tu operador*.
- **Sin puntuación 0–100.** No hay umbral honesto para "buen ping" (200 ms desde otro continente
  puede ser normal). Se emiten hallazgos solo donde el dato es inequívoco.
- **Jitter = media del |salto| entre paquetes consecutivos**, no desviación típica: una rampa
  monótona da desviación alta y no se nota; saltar arriba y abajo cada paquete sí. Los saltos se
  toman solo entre sondas **consecutivas recibidas** — encadenar los extremos de un hueco de
  pérdida inflaría el jitter con un intervalo que cubre varios periodos, y la pérdida ya se
  reporta aparte.
- **El aviso de ICMP va en la primera línea de la salida**, no en una nota al pie.

**Trampa que casi se cuela, y que la propia medida destapó.** La primera versión decía *"el tramo
hasta tu router llega inestable"* al superar el corte de 5 ms. La medición real dio 7,91 ms contra
la puerta de enlace y **0,55 ms contra 1.1.1.1 — que atraviesa ese mismo router**. Un router
responde a los pings *dirigidos a él* con su CPU de gestión, la de menor prioridad del aparato,
mientras que el tráfico que solo *reenvía* va por la ruta rápida. Culpar al Wi-Fi del usuario con
ese dato habría sido exactamente el tipo de afirmación sin base que este proyecto rechaza. Ahora
compara los dos tramos y, si el de internet sale igual o mejor, dice que es la CPU del router y
que **no es accionable desde el PC**.

`tests/NetMon.Tests.ps1`: 19 tests sobre las dos funciones **puras**
(`Get-AXENetStats`, `Get-AXENetFindings`). `Measure-AXENetProbe` y `Get-AXENetGateway` no se
testean: dependerían del router de quien ejecute la suite, y eso no es un test, es una lotería.

### Badge de tests — se quita el número, no se actualiza

El badge decía `671 tests passing`; la ejecución real da 707. Actualizarlo solo mueve la mentira
unos commits más allá. Los tres números se mueven por motivos distintos y legítimos: los **pasados**
dependen del commit, los **omitidos** de *tu hardware* (sin NVIDIA o sin PresentMon se omiten otros),
y los **no ejecutados** son los `-Tag integration`, excluidos a posta
(`scripts/Invoke-AXETests.ps1:55`) porque mutan Windows real y corren en un job de CI propio. El
README explica los tres y da los comandos para reproducirlos.

### Verificado

`SelfTest` **82 tweaks / 112 checks / 0 fallos** · Pester **707 passed, 0 failed, 49 skipped**
(177 `NotRun` = los `integration`, exclusión por diseño) · web host harness verde ·
`-NetMon` ejecutado contra la red real.

### Deuda declarada

La whitelist de claves `Requires` está **duplicada**: `45-cli.ps1:95` (check S19) y
`tests/Catalog.Tests.ps1:19`. Añadir una clave obliga a tocar las dos. Se deja así a propósito —
`45-cli.ps1` no se puede dot-sourcear (trae dispatch y `exit`), y duplicar 18 cadenas cuesta menos
que extraer el bloque `-SelfTest` a una función solo para compartirlas. El olvido no es silencioso:
el test se pone rojo. Ambos sitios llevan el comentario que apunta al otro.

---

## 9. Bloqueadores de lanzamiento — 2026-07-26 (segunda sesión)

Tres defectos reportados por el autor al preguntarse si el proyecto era lanzable. Los tres eran
reales y los tres estaban **fuera** del alcance de esta auditoría, que miró catálogo y motor y no
miró la ventana.

### 9.1 La ventana no cabía en la pantalla

`47-webhost.ps1` fijaba `1200x840` con `MinHeight=720`. `Window.Width/Height` de WPF van en **DIP**,
y el escritorio útil también: a más escalado de Windows hay *menos* DIP, no los mismos.

| Pantalla | Escritorio útil | Ventana pedida | Resultado |
|---|---|---|---|
| 1920×1080 @125 % (la de referencia) | 1536×816 DIP | 840 de alto | nacía 24 DIP por debajo del escritorio |
| 1920×1080 @150 % | 1280×680 DIP | mínimo 720 | **no se podía encoger hasta que cupiera, nunca** |

Arreglado con `Get-AXEWindowFit` (39-webdetect, pura): recorta contra `SystemParameters.WorkArea`
**en la misma unidad**, con lo que el escalado deja de importar. El mínimo se recorta al tamaño
real, así que un `MinHeight` mayor que la pantalla no puede volver por construcción.

Complemento: CSS con cortes por ancho **y por alto** (el alto es el que escasea al escalar), y zoom
persistente (`Ctrl`+rueda) en `AXE/ui.json`.

### 9.2 «Sesión de juego no hace smart detect»

Cierto: había que **escribir** el nombre del proceso. Quien no sabe que Valorant corre como
`VALORANT-Win64-Shipping` no podía usar la función — justo el usuario al que sirve.

Resuelto con `Get-AXEGameCandidates` (40-session, pura). **Rechazada** la lista de títulos
conocidos: es lo que hacen las suites de pago y envejece sola. Se puntúan señales que valen para un
juego que salió ayer (carpeta de tienda, firma del motor Unreal, ventana, memoria) y se devuelven
las **razones**, para que el usuario pueda desmentir a la máquina. No arranca solo.

Dos falsos positivos cazados ejecutándolo contra la máquina real, no razonando:
- `\windowsapps\` marcaba **toda** app MSIX (Claude Desktop y NitroSense puntuaban 70). Marcador
  retirado: un indicio que señala a todo el mundo no es un indicio.
- `epiconlineservicesuserhelper` salía **primero** por vivir en `Epic Games\`. Resuelto con una
  regla anclada al final del nombre (`*service`, `*helper`, `*launcher`…), no ampliando una lista.

### 9.3 «¿Lee todo el equipo, sea torre o portátil, W10 o W11?»

`Get-AXEHardware` consultaba `Win32_Processor` y `Win32_OperatingSystem` **sin `-ErrorAction`**: un
fallo de WMI tumbaba la función entera, y `hw.get` (48-webbridge) no la envolvía, así que la ventana
perdía el panel de hardware completo. Como es la base del gating, eso no dejaba a AXE sin *un* dato
sino sin *ninguno*. Importa por el público: son equipos a los que ya les pasó otro optimizador, y
romper WMI es de lo más común que dejan detrás.

Ahora cada hecho va en su `try`, lo esencial tiene camino alternativo por **registro**, y lo
ilegible viaja en `DetectWarnings`, que la interfaz enseña. Añadidos: `GpuNames`/`GpuPrimary`/
`GpuVendor` (antes sólo existía `HasNvidia`: quien tuviera Radeon o Arc no veía GPU ninguna),
`RefreshHz`, `ScreenW/H`, `IsVM`, `Model`, `Vendor`, `DisplayVersion`, `Ubr`. Ningún campo previo
cambia de nombre ni de tipo — hay un test-trinquete por cada uno.

### Lo que encontró el verificar de verdad

- **`es-ES` rompía el zoom.** `[double]::TryParse('1.5')` con la cultura del sistema devuelve **15**
  (el punto es separador de miles), así que se rechazaba en silencio. En un Windows en inglés habría
  pasado inadvertido hasta el primer usuario fuera de EEUU. Lo cazó un test, no una revisión.
- **Tres hipótesis mías sobre el marcador, dos falsas.** La tarjeta del score colapsaba a 38 px y
  el gauge se salía encima de las demás. `min-height:min-content` **no** arregla la fila;
  `overflow:visible` **tampoco**. Sólo una longitud definida participa en el cálculo de la pista.
  Medido en el navegador, con las barras rellenas para probar el caso alto.

### Verificado

`SelfTest` **82 tweaks / 112 checks / 0 fallos** · Pester **798 passed, 0 failed, 49 skipped**
(+91 tests nuevos en `tests/Detect.Tests.ps1`) · web host harness verde · interfaz comprobada en
navegador a 1280 / 940 / 840 / 700 px: sin solapes, sin recortes y sin desborde horizontal en
ninguna de las siete vistas.

### Sin cubrir (declarado)

- El detector se ha probado contra procesos **sintéticos** y contra la máquina de referencia **sin
  ningún juego abierto**. Falta ejecutarlo con un juego real delante.
- Arrastrar la ventana a un segundo monitor con distinto DPI: WPF sin PerMonitorV2 la reescala como
  mapa de bits. Aceptado, no resuelto.
- `Start-AXESession` resuelve el juego por nombre (`Get-Process -Name X | Select -First 1`). Con
  varios procesos del mismo nombre elige arbitrariamente. Preexistente, no tocado en esta sesión.
