# Auditoría competitiva y de catálogo — 2026-07-25

**Estado:** cerrado. **Rama:** `axe`. **Versión al auditar:** v7.0.0, 78 tweaks → 81 tras esta sesión.

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

## 4. Abierto — decisión de diseño pendiente

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

## 5. Pendiente

1. `SvcHostSplitThresholdInKB` — hueco real, sin implementar.
2. Verificar `net_rsc` en una máquina con adaptador **cableado**.
3. Resolver §4 (tercer estado de `Test`).
4. Monitor de red en vivo: ping, jitter de red, packet loss. Cobertura actual: **cero** (el jitter
   que mide `32-measure` es de *timer*, no de red).
5. **Regulador de carga de fondo** — no "Live Tune". 2 palancas, periodo 30–60 s, veredicto vía
   `Get-AXESweepVerdict`. Ver D-01/D-02/D-03 antes de tocar nada.

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
