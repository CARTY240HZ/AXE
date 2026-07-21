# AXE WEBUI — rediseño de la capa de presentación (WebView2)

**Fecha:** 2026-07-21
**Estado:** aprobado en brainstorming, sin implementar
**Objetivo del producto:** superar a hone.gg / PulseHardware / Delta / Atlas en **UI y experiencia**,
sin perder la honestidad (medible, reversible, con fuentes) que es la ventaja de AXE.

---

## Problema

El motor (regiones 1–45) es maduro: 77 tweaks con gating por ecosistema, medición real
(timer/jitter, PresentMon), revert con snapshot del valor previo, punto de restauración verificado.
Lo que falta es la **capa de presentación**. La GUI actual (WPF, `50-xaml`…`60-selftest`) es
correcta pero es una **lista de ajustes**: abre en el catálogo. Los competidores abren en un
**panel vivo** — score animado, telemetría, gráficas — y ganan en primera impresión y percepción.

La GUI WPF tiene techo para lo que exige ese panel: gráficas en vivo, movimiento fluido, densidad
de datos animada. WebView2 (HTML/CSS/JS) no tiene ese techo y reutiliza herramienta web madura.

**Regla dura de identidad (decidida con el usuario):** minimalista, **no genérico, no muy colorido**,
movimiento y transiciones fluidas. Estética de **instrumento de medida**, no de UI gamer. El color
saturado sigue reservado al riesgo (tier) y a la salud. El ámbar es la única "luz" de marca.

---

## Decisiones tomadas

### 1. Reemplazo completo, host WPF fino

WPF se reduce a una **carcasa**: ventana, chrome oscuro (Mica), STA, auto-elevación admin, y aloja
**un control WebView2 a pantalla completa**. Toda la UI vive en web.

- **Se conserva:** regiones 1–45 (motor). Intacto. El catálogo sigue siendo la única fuente de verdad.
- **Se reemplaza:** `50-xaml`…`60-selftest` → **frontend web** (`AXE/webui/`) + **un módulo puente**.
- **Por qué reemplazo y no coexistencia:** dos UIs = dos lenguajes visuales, doble mantenimiento y
  aspecto "cosido". El objetivo es superar en todos los ámbitos, no parchear.

### 2. Un solo proceso, sin servidor localhost

El frontend se sirve **local** vía `CoreWebView2.SetVirtualHostNameToFolderMapping`
(`https://axe.local/` → carpeta `AXE/webui/`, acceso solo-lectura). No hay `HttpListener`, no hay
segundo proceso, no hay puerto abierto. Menos superficie de ataque.

### 3. Puente = RPC por WebMessage con lista blanca

- **JS → PS:** `window.chrome.webview.postMessage(JSON {id, cmd, args})`.
  El handler `WebMessageReceived` (PowerShell) **despacha solo `cmd` que estén en una lista blanca**
  de funciones del motor. Nunca `Invoke-Expression`/eval de payload. Args validados por comando.
  Respuesta: `ExecuteScriptAsync("window.__axeReply(<id>, <json>)")`.
- **PS → JS (telemetría):** un `DispatcherTimer` empuja `PostWebMessageAsJson(JSON {evt, data})`;
  el frontend escucha `chrome.webview.addEventListener('message', …)`.
- **El puente es la superficie de ataque** → tiene sus propios tests Pester (lista blanca cerrada,
  comando desconocido rechazado, args fuera de rango rechazados).

Contrato mínimo (se ampliará en el plan):

| Sentido | Forma | Ejemplo |
|---|---|---|
| JS→PS petición | `{id:int, cmd:string, args:obj}` | `{id:7, cmd:"tweaks.list", args:{}}` |
| PS→JS respuesta | `{id:int, ok:bool, data:any, err:string?}` | `{id:7, ok:true, data:[…]}` |
| PS→JS evento | `{evt:string, data:any}` | `{evt:"telemetry", data:{dpc:68, cpu:18…}}` |

Lista blanca inicial de `cmd` (mapea a funciones ya existentes del motor):
`hw.get` (`Get-AXEHardware`), `tweaks.list`/`tweaks.apply`/`tweaks.revert`,
`measure.run` (`Measure-*`), `fps.*`, `session.start`/`session.stop`/`session.plan`,
`diag.get`, `safety.restorepoint`/`safety.masterrevert`, `report.get`.

### 4. Estética: instrumento que se mueve (tokens)

- Grafito frío: `--bg:#0E1013`, `--surface:#16191F`, `--surface-2:#1E232B`, `--line:#2A303B`.
- Tinta `#E6EAF0`, apagado `#7E8798`. Ámbar de marca/armado `#E0A32E` (única luz).
- Riesgo/salud: verde `#5FAF8D` (tier0/ok), ámbar (tier1), rojo `#D9605A` (tier2/spike). Nada más.
- Tipo: **Segoe UI Variable** (cara real de Windows) para UI; **monospace tabular** para toda lectura
  numérica (score, µs, %). Es un analizador, no un folleto.
- Movimiento: entrada en cascada, barrido del score al medir, trazas vivas continuas, toggles con
  muelle, transición cross-fade entre pantallas, tickers numéricos. **`prefers-reduced-motion` honrado.**
  Sin glow de sobra, sin RGB.
- Logo: el wordmark AXE real (`AXE/logo/axe.svg`), recoloreado a ámbar (placa negra fuera, contador
  de la A a fondo). Ya validado en el mockup.

### 5. Dependencia WebView2 (coste honesto aceptado)

- Runtime Evergreen: presente en Win11; en Win10 puede faltar → **detectar y ofrecer instalar**
  (bootstrapper de Microsoft), nunca crashear.
- Los DLL del SDK (`Microsoft.Web.WebView2.*`, `WebView2Loader.dll`) se distribuyen en `AXE/webview2/`.
- **Rompe** el "single-file zero-dep" que presume el README → el README se reescribe con honestidad.
- Runtime ausente + sin red → mensaje claro con enlace, no pantalla en blanco.

---

## Inventario de pantallas (nav lateral, riel de instrumento)

| # | Pantalla | Qué es | Fuente en el motor |
|---|---|---|---|
| 1 | **Panel** | Landing: AXE Score medido + receta, vitals en vivo, osciloscopio DPC, estado por tier, acciones | measure, diag, hw |
| 2 | **Telemetría** | En vivo a fondo: barrido de jitter, frame-time, DPC/ISR, CPU/GPU | measure, fps |
| 3 | **Optimizar** | Catálogo por categoría, badges de tier, toggles, aplicar/master-revert (los 77 tweaks, reskin) | tweaks, catalogs |
| 4 | **Sesión de juego** | El daemon (subsistemas A–D): elegir juego, ON/OFF, grupos Intacto/Degradado/Congelado en vivo | session |
| 5 | **Prueba y receta** | Recetas A/B antes→después, informe compartible | measure, report |
| 6 | **Seguridad** | Puntos de restauración, backups, master-revert, verify-tamper, hash de integridad | safety, revert-export |
| 7 | **Ajustes** | Canal de actualización, idioma, preferencias | config |

El landing (Panel) es el mockup ya aprobado. Pantalla 4 es el diferenciador que ninguno de los
competidores tiene de verdad (congela el fondo por Job Object; ver spec `2026-07-20-game-session`).

---

## Arquitectura de ficheros

```
AXE/
  src/
    47-webbridge.ps1   (NUEVO)  host WebView2 + RPC lista-blanca + bomba de telemetría
                                 (hueco entre 45-cli y el antiguo bloque GUI; carga tras 32-measure)
    50..60             (BORRAR/RETIRAR)  WPF sustituido; el .bat lanza el host web
  webui/               (NUEVO)  frontend
    index.html
    app.js             router + bridge client (postMessage / __axeReply / addEventListener)
    styles.css         tokens + componentes
    logo.svg           wordmark recoloreado
    views/             una vista por pantalla (panel, telemetria, optimizar, sesion, prueba, seguridad, ajustes)
```

Reparto puro/impuro (mismo patrón que el motor): la **decisión de render** vive en JS (puro sobre
datos), el **acceso al sistema** vive en PS (impuro). El puente solo transporta.

---

## Manejo de errores

| Fallo | Respuesta |
|---|---|
| Runtime WebView2 ausente | Detectar antes de crear el control. Mensaje + enlace al bootstrapper. No crashear. |
| DLL del SDK no cargan | Abortar con mensaje; la carcasa WPF sigue viva para mostrarlo. |
| `cmd` fuera de la lista blanca | Rechazar, responder `{ok:false, err:"cmd desconocido"}`, log. **No ejecutar nada.** |
| Args inválidos para un `cmd` | Rechazar antes de tocar el motor. |
| El motor lanza en un `cmd` | Capturar, responder `{ok:false, err}`, no tumbar el host. |
| Catálogo roto (`CAT.Count<10`) | Mismo guard que hoy: abortar la UI para proteger. |

**Principio:** el puente nunca confía en el payload. La lista blanca es cerrada por defecto.

---

## Testing

- **Pester (sin hardware):** lista blanca del puente (cmd desconocido rechazado, args fuera de rango
  rechazados, forma de respuesta), y que el frontend exista/valide en `-SelfTest`.
- **SelfTest gate (`build.ps1`):** asserta que `AXE/webui/` tiene los assets esperados y que la lista
  blanca del puente cubre exactamente los `cmd` que `app.js` invoca (coherencia JS↔PS).
- **No testeable (documentado):** que WebView2 aloje y pinte de verdad; pide runtime y una versión de
  Windows. Se documenta igual que `Fps.Tests.ps1` documenta lo que no cubre.
- **CI:** ScriptAnalyzer Error gate → build → SelfTest → Pester, sigue en verde.

---

## Riesgos abiertos

1. **Alojar WebView2 desde PowerShell/WPF es delicado** (STA, orden de carga de DLL, `EnsureCoreWebView2Async`
   asíncrono en un hilo STA). → **Spike de rebanada vertical PRIMERO**: carcasa + puente + Panel con una
   métrica en vivo, antes de construir las 7 pantallas. De-riesgo lo más caro.
2. **Endurecer el IPC.** La lista blanca debe ser la única puerta; revisado con tests.
3. **Reescritura grande de presentación.** Se mitiga congelando el motor (1–45) y tocando solo 47/50–60.
4. **Dependencia de runtime** rompe la promesa zero-dep; se asume y se documenta.

---

## Qué NO entra en este spec

- Cambios en el motor (tweaks, medición, sesión) — intactos.
- Auto-update (canal de actualización): se **muestra** en Ajustes pero su implementación es otro spec.
- Informe compartible / export (pantalla 5) más allá de mostrar recetas ya medidas.
- Firma de código (ya cubierto por `docs/SIGNING.md` / plan trust-proof).
- Detección automática de juegos (es del spec de sesión).
