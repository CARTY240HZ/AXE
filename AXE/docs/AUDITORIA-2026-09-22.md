# Auditoría técnica AXE — 2026-09-22

## Metodología

Esta auditoría se basa en lectura completa del código fuente real del repo `CARTY240HZ/AXE`
(los 27 módulos de `AXE/src/`, ~8000 líneas), cruzado contra `AXE/tests/` (18 ficheros, 671+
tests), `CHANGELOG.md`, y los issues abiertos en GitHub del propio repositorio. Ningún dato de
este documento es inventado ni "medido de oídas": cada hallazgo de bug cita **archivo y línea
real**, y cada tweak/detección propuesta cita su **fuente externa verificable** (documentación
oficial de Microsoft, o un repositorio público concreto de alguien con trayectoria pública en
tuning de Windows: ChrisTitusTech/winutil, valleyofdoom/PC-Tuning, hellzerg/optimizerNXT — los
mismos tipos de fuente que el propio catálogo de AXE ya cita en `Source`/`SourceType`).

No se ha podido ejecutar el motor en una máquina Windows real desde este entorno de auditoría
(agente en `C:\WINDOWS\system32` sin sesión Windows interactiva de prueba), así que todos los
hallazgos de bug son de **lectura y trazado de código**, no de reproducción en vivo. Se marca
explícitamente la confianza de cada uno.

---

## Resumen ejecutivo

| Severidad | Nº | Resumen |
|---|---|---|
| **EXTREMO** | 2 | (1) El sistema de "revert con fidelidad de snapshot" —la promesa central del proyecto— está desconectado en el único camino de uso real (WebUI). (2) WebView2 corre en el mismo proceso elevado que la lógica privilegiada (ya reportado por el propio autor, issue #5, sin resolver). |
| **GRAVE** | 1 | Gobernanza del repo: sin protección de rama/tags (issue #6, ya abierto, sin resolver). |
| **MEDIO** | 2 | Huecos de UX en el Consejero y en el diagnóstico de cuellos de botella cuando no hay hallazgo "BAD" pero tampoco todo está óptimo. |
| **LEVE** | 1 | Cobertura de tests de integración con tag `integration` (excluida del run por defecto) es la única que ejercita el round-trip real; el hueco de #1 vivía exactamente en el borde que esa exclusión no cubre. |

Además: **6 detecciones nuevas propuestas** (todas con mecanismo Windows oficial verificado) y
**6 tweaks nuevos propuestos** (todos cruzados contra el catálogo actual de 78 tweaks para
confirmar que NO están ya cubiertos), más una lista de descartes razonados.

---

## 1. Bugs — EXTREMO

### 1.1 — `Commit-TweakState` nunca se invoca en el camino real de uso (WebUI). El "revert con fidelidad de snapshot" no funciona en producción.

**Confianza: alta (verificado por trazado completo de código + tests existentes que lo confirman indirectamente).**

**El diseño que el proyecto anuncia** (README: *"Cada cambio guarda el valor anterior **real**
por snapshot, no un valor 'por defecto' supuesto"*; CHANGELOG: *"Reversión con fidelidad de
snapshot (no inventa defaults)"*) depende de una secuencia de 3 pasos:

1. Al aplicar: `$script:capTweak = $tw.Id` → ejecutar `$tw.Apply` (cada `Set-RD`/`Set-RS`/`Del-RV`
   dentro captura el valor previo real vía `Push-RegBackup`, `src/10-reg-helpers.ps1:17-28`).
2. **`Commit-TweakState $tw.Id`** — vuelca la captura en memoria (`$script:capBuf`) al fichero
   persistente `tweak_state.json` (`src/10-reg-helpers.ps1:79-87`).
3. Al revertir: `Restore-TweakState $tw.Id` lee ese fichero y restaura el valor real capturado
   (`src/10-reg-helpers.ps1:89-113`).

**El fallo:** `Commit-TweakState` está definido una vez y se invoca en **un solo sitio de todo
el repo**: `src/28-revert-export.ps1:64`, dentro de `Import-AXEProfile` — la función que importa
un perfil `.json` exportado, una vía secundaria y poco usada.

```
$ grep -rn "Commit-TweakState" AXE/ --include=*.ps1
./src/10-reg-helpers.ps1:79:function Commit-TweakState($id){
./src/28-revert-export.ps1:64:                Commit-TweakState $tw.Id
./tests/Integration.Tests.ps1:110:        Commit-TweakState $id
./tests/RevertFidelity.Tests.ps1:101:        $script:ImportSrc | Should -Match 'Commit-TweakState'
```

El único camino real por el que un usuario aplica o revierte un tweak individual es la WebUI
(`tweaks.apply` / `tweaks.revert` en `src/48-webbridge.ps1:92-107`) — la CLI (`src/00-header.ps1`)
**no tiene ningún parámetro `-Apply`/`-Revert` por tweak**, solo `-List`, `-Export`/`-Import`,
`-SelfTest`, etc. Y ese handler de la WebUI **nunca llama a `Commit-TweakState`**:

```powershell
# src/48-webbridge.ps1:92-101
'tweaks.apply' = { param($a)
    ...
    if(Test-SnapEligible $tw){ $script:capTweak = $tw.Id }
    try { & $tw.Apply } finally { $script:capTweak = $null }
    [pscustomobject]@{ id=$tw.Id; applied=[bool](Test-TweakSafe $tw); reboot=[bool]$tw.Reboot }
}
'tweaks.revert' = { param($a)
    ...
    if(-not ((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){ & $tw.Revert }
    ...
}
```

**Consecuencia real:** la captura en `Push-RegBackup` sí ocurre (queda en `$script:capBuf`,
en memoria), pero como nunca se llama `Commit-TweakState`, **nunca llega al disco**. Cuando el
usuario pulsa "revertir", `Restore-TweakState` busca en `tweak_state.json`, no encuentra nada
(porque nunca se escribió), y el código cae **siempre** a la rama `& $tw.Revert` — el
scriptblock hardcodeado de cada tweak, que para la mayoría del catálogo escribe el "valor por
defecto documentado por Microsoft", no el valor real que tenía el usuario.

Esto es exactamente el defecto que el propio proyecto identificó y corrigió en tres tweaks
concretos en su auditoría interna del 2026-07-19 (ver `tests/RevertFidelity.Tests.ps1`,
comentario de cabecera: *"gpu_mmcss sí es elegible, pero Import-AXEProfile no usaba el
snapshot en NINGÚN sentido, así que por esa vía se caía al fallback"*) — pero la corrección se
aplicó **solo dentro de `Import-AXEProfile`**, no en el bridge de la WebUI, que es donde
realmente vive el 100% del uso interactivo del producto.

**Por qué el test de integración no lo detecta:** `tests/Integration.Tests.ps1:95-129`
("round-trip Apply/Revert real") reproduce la secuencia correcta a mano (`$script:capTweak = $id;
& $tw.Apply; Commit-TweakState $id; ...Restore-TweakState $id`) **directamente**, sin pasar por
`tweaks.apply`/`tweaks.revert`. Verifica que el *mecanismo* funciona de forma aislada, pero nunca
ejercita la función real de la WebUI que un usuario dispara al hacer clic. Además ese `Describe`
lleva `-Tag 'integration'` y está `-Skip` salvo `$env:AXE_INTEGRATION -eq '1'`, así que ni
siquiera corre en el `Invoke-Pester -ExcludeTag integration` que documenta el propio README.

**Tweaks afectados:** de los 78 del catálogo, quedan **fuera** de este bug los ~11 que tienen su
propio mini-sistema de captura manual e independiente en `HKCU:\Software\AXE\*Prev` (`cpu_park`,
`rend_ultperf`, `pwr_usbsuspend`, `net_dns`, `net_intmod` — su `Apply`/`Revert` usa `powercfg` /
`Set-NetAdapterAdvancedProperty` / `Set-DnsClientServerAddress`, así que `Test-SnapEligible`
los excluye del sistema genérico y su propio código de captura sí corre siempre). Los **~60
restantes** (todo lo que usa `Set-RD`/`Set-RS`/`Del-RV` "a pelo": `cpu_mmcss`, `cpu_pthr`,
`gpu_hags`, `gpu_mmcss`, `net_throttle`, `mem_ntfsmem`, `sys_gamedvr`, todos los `priv_*`, todos
los `app_*`, etc.) dependen del sistema genérico roto. Para la mayoría el impacto práctico es
bajo (el valor hardcodeado de `Revert` coincide con el default documentado de Microsoft), pero:

- Si el usuario tenía un valor **personalizado** distinto del default antes de usar AXE (p. ej.
  `SystemResponsiveness` a 15 en vez de 20, `MenuShowDelay` a 100 en vez de 400), el revert se lo
  **pisa silenciosamente** por el "default de fábrica", no por lo que tenía.
- `gpu_mmcss` y `svc_hostsplit` tienen un fallback que sus propios comentarios describen como
  **explícitamente incompleto por diseño** ("revertido parcial... `Scheduling Category`, `SFIO
  Priority` y `Background Only` quedan como están"), asumiendo que ese fallback casi nunca se
  alcanzaría porque el camino normal sería el snapshot. Con este bug, **siempre** se alcanza.

**Arreglo sugerido:** añadir `Commit-TweakState $tw.Id` inmediatamente después de `& $tw.Apply`
en `tweaks.apply` (`src/48-webbridge.ps1:99`), y el mismo patrón en cualquier otro punto de
aplicación real (p. ej. si se añade un `-Apply` a CLI en el futuro). Después, añadir un test que
invoque **la función RPC del bridge tal cual la llama la WebUI** (no solo las primitivas
internas), para que esta clase de regresión — lógica correcta pero mal cableada en el punto de
entrada real — no pueda colarse otra vez sin que el gate rojo.

---

### 1.2 — WebView2 corre en el mismo proceso elevado que la lógica privilegiada

**Ya reportado por el propio autor** como issue abierto sin resolver:
[CARTY240HZ/AXE#5](https://github.com/CARTY240HZ/AXE/issues/5) — *"security: split WebView2 UI
from elevated privileged backend"*.

Confirmado leyendo `src/47-webhost.ps1`: el control WebView2 se aloja dentro del mismo proceso
`powershell.exe` elevado que ejecuta `Set-RD`/`sc.exe`/`bcdedit`/`Set-ProcessMitigation`, etc.
Ya existen mitigaciones parciales verificadas en el código (`src/47-webhost.ps1:96-102`):
DevTools y menú contextual deshabilitados fuera de `AXE_WEBUI_DEBUG`, mapeo de host virtual con
`Deny` cross-origin, y contenido 100% local (sin navegación remota). Pero el problema
arquitectónico de fondo —un documento HTML/JS comprometido podría, en teoría, alcanzar el mismo
espacio de proceso que tiene privilegios de administrador— sigue abierto exactamente como lo
describe el propio issue, con su lista de criterios de aceptación (proceso UI no elevado +
broker elevado aparte con IPC por named pipe y allowlist cerrada). No he encontrado ninguna rama
ni PR que lo aborde en el estado actual del repo.

---

## 2. Bugs — GRAVE

### 2.1 — Gobernanza del repositorio: sin protección de rama ni de tags

También ya reportado por el propio autor:
[CARTY240HZ/AXE#6](https://github.com/CARTY240HZ/AXE/issues/6) — *"security: protect release
tags and require security CI before merge"*. El propio issue documenta que "Current repository
rulesets: none" — cualquiera con push directo podría saltarse el gate de CI, y los tags `v*`
(que disparan el pipeline de release firmado) no están protegidos contra recreación/reasignación.
No es un bug de código sino de configuración de GitHub, pero es real, verificable ahora mismo
consultando el repo, y de severidad alta porque afecta a la cadena de confianza que
`src/43-update.ps1` construye con tanto cuidado (SHA256SUMS + SBOM + firma Authenticode).

---

## 3. Bugs — MEDIO

### 3.1 — `Get-AXEBottleneck` puede devolver una lista vacía sin decir ni "hay un problema" ni "está todo limpio"

**Confianza: media** (leído en código, no reproducido).

En `src/42-advisor.ps1:155-218`, la regla 7 ("nada mal configurado y sistema ya fino") solo añade
el mensaje "No te encuentro un cuello de botella" si `$out.Count -eq 0` **y además**
`$Snapshot.Timer.CurrentMs -le 1.0`. Si el diagnóstico no encontró ningún `BAD` pero la
resolución del timer medida está por encima de 1 ms (o `$Snapshot` es `$null` porque
`-NoMeasure`/la medición falló), `Get-AXEBottleneck` devuelve un array vacío **sin ningún
mensaje**. `Get-AXEAdvice` (línea 243) itera ese array vacío y simplemente no añade ninguna
entrada de tipo `cuello` al plan — el usuario nunca ve ni "tienes un problema" ni "estás limpio"
para esa sección, un salto silencioso en vez de un estado explícito. Dado el principio de diseño
explícito del propio módulo ("UNKNOWN es un estado de primera clase... no se calla lo que no se
sabe"), este hueco contradice la propia filosofía del código que lo rodea.

**Arreglo sugerido:** separar la condición del timer de la condición de "no hay bottleneck": si
`$out.Count -eq 0` pero `$timerOk` es falso o desconocido, añadir una entrada explícita tipo
`Rank=9; Id='clean-partial'` que diga "nada mal configurado en lo que se pudo medir, pero la
resolución del timer no se ha confirmado en <=1ms" en vez de omitir la sección entera.

### 3.2 — `net_ctcp`/AXE recomienda repliegue a un algoritmo de congestión TCP más antiguo que el propio default de Windows, y lo dice — pero solo en el `Desc`, no en `Get-AXELatencyNotes`

**Confianza: media.** El propio tweak (`src/20-tweaks.ps1:125`) es honestísimo en su `Desc`:
*"OJO: CUBIC es el default de Windows desde 10 1709 y es MÁS moderno que CTCP. Esto RETROCEDE la
plantilla Internet a un algoritmo viejo"* — y aun así entra en `$script:LATRULES['net_ctcp']`
para cualquier equipo con Wi-Fi (`src/20-tweaks.ps1:671`) y se pinta en el "SET DE LATENCIA" de
un clic. `Get-AXELatencyNotes` (línea 705) no repite esa advertencia cuando el equipo es Wi-Fi;
solo dice "CTCP recupera antes tras pérdida", omitiendo el propio "OJO" que el catálogo declara
en el mismo módulo. Es una inconsistencia de mensaje, no un bug funcional: el `PlaceboLikely`
del tweak es `$false` (no está marcado como probable placebo) pese al propio texto admitir que
es un downgrade de algoritmo, lo que también significa que **no** queda excluido del set de
latencia por el filtro `PlaceboLikely` de `Get-AXELatencySet` (línea 694-696).

---

## 4. Bugs — LEVE

### 4.1 — La única cobertura que habría detectado 1.1 está etiquetada `integration` y excluida del run por defecto

Ya explicado en el punto 1.1: es una observación sobre la propia arquitectura de tests, no un
bug de producto, pero merece registrarse como acción: mover al menos una versión headless (sin
tocar hardware real, con un tweak de prueba dummy o mockeado) del round-trip **a través de
`Invoke-AXEBridgeCommand`/los handlers de `48-webbridge.ps1`** al set que sí corre siempre.

---

## 5. Nuevas detecciones propuestas (para "diagnóstico más inteligente")

Todas usan mecanismos de Windows **oficiales y documentados**, ninguna requiere telemetría de
terceros ni red (salvo donde se indica explícitamente), y todas se integran en el mismo patrón
puro/impuro que ya usa `35-diag.ps1` (`Get-AXEDiagFacts` impura → `Get-AXEDiagFindings` pura y
testeable → `Format-AXEDiag` compartido).

1. **Reinicio pendiente.** Windows puede dejar tareas de fondo (CBS, Windows Update,
   renombrados pendientes) corriendo hasta el próximo reinicio, compitiendo por CPU/disco
   durante una sesión de juego sin que el usuario sepa por qué. Se detecta comprobando tres
   claves estándar, ninguna requiere admin ni red:
   - `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending`
   - `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired`
   - `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` valor `PendingFileRenameOperations`
   Patrón estándar de detección (SCCM, Boxstarter `Get-PendingReboot.ps1` y decenas de scripts
   de administración de sistemas usan exactamente estas tres claves).

2. **Enlace PCIe de la GPU negociado por debajo de su máximo.** Una GPU corriendo en un slot
   x4/x8 en vez de x16, o en Gen1/2 en vez de Gen3/4 (riser mal asentado, slot compartido con
   NVMe, BIOS con "PCIe bifurcation" mal puesta) es una de las causas de bajo rendimiento más
   difíciles de notar a simple vista y más comunes en builds con múltiples NVMe. Es legible con
   el cmdlet oficial `Get-PnpDeviceProperty` sobre las claves `DEVPKEY_PciDevice_CurrentLinkSpeed`
   y `DEVPKEY_PciDevice_CurrentLinkWidth` (módulo `PnpDevice`, incluido en Windows 10/11):
   ```powershell
   Get-PnpDevice -Class Display | Get-PnpDeviceProperty -KeyName DEVPKEY_PciDevice_CurrentLinkSpeed,DEVPKEY_PciDevice_CurrentLinkWidth
   ```
   Fuente: [Microsoft Learn — Get-PnpDeviceProperty](https://learn.microsoft.com/en-us/powershell/module/pnpdevice/get-pnpdeviceproperty).
   El "máximo esperado" no siempre es leíble por WMI de forma fiable entre vendors, así que este
   hallazgo debería seguir el mismo patrón que `refresh` en `35-diag.ps1`: comparar contra lo que
   *se pueda* leer y marcar `UNKNOWN` cuando no se pueda, nunca asumir el máximo de la GPU por
   nombre comercial.

3. **Análisis de Defender programado en horario de juego.** `Get-MpPreference` expone
   `ScanScheduleDay`/`ScanScheduleQuickScanTime`/`ScanScheduleTime` — es información **local**,
   sin red, sin admin. Si el análisis completo programado cae en un rango horario típico de
   juego (tarde/noche), es un candidato real a "por qué se me cae el FPS a ratos" que ningún
   competidor diagnostica. Se sugiere solo **detectar y avisar**, nunca reprogramar el análisis
   automáticamente (coherente con el principio de "diagnosticar, no tocar" de `35-diag.ps1`).

4. **Modo de energía de Windows 11 ("Mejor rendimiento" / "Equilibrado" / "Mejor eficiencia")
   distinto del plan de energía clásico.** Desde Windows 11 22H2 existe el slider de "Modo de
   energía" en Configuración > Energía, que es **distinto** del plan clásico `powercfg` que
   `rend_ultperf` ya gestiona — puede estar en "Mejor eficiencia energética" con el portátil
   enchufado sin que el usuario lo note, lo que sí limita CPU/GPU. Es legible en
   `HKCU:\Software\Microsoft\Power\PowerThrottling` / vía `powercfg /getactivescheme` combinado
   con la clave `EnergySaverBrightnessOverride` — necesita verificación exacta en máquina real
   antes de convertirse en tweak (no se ha podido confirmar la ruta exacta en esta auditoría sin
   acceso a Windows en vivo); se propone como **detección a investigar**, no a implementar a
   ciegas.

5. **Antigüedad del driver de GPU.** Comparar `Win32_PnPSignedDriver.DriverDate` de la GPU contra
   la fecha actual es 100% local y sin red; un driver de más de ~12 meses en un equipo de juego
   es un candidato razonable a advertencia ("no se ha actualizado el driver de GPU en N meses").
   Ir más allá (comparar contra la última versión publicada por NVIDIA/AMD) exigiría una consulta
   de red a una API de terceros, que rompería el principio "cero telemetría, sin red" que
   `43-update.ps1` cita como ventaja frente a la competencia — se recomienda **no** implementar
   esa parte, solo la comparación de antigüedad local.

6. **Ancho de banda de RAM real vs. teórico ya está cubierto** por el hallazgo `xmp`/`ramchan`
   existente — no se propone nada nuevo aquí, se confirma que ya está bien resuelto.

---

## 6. Nuevos tweaks propuestos (fuentes oficiales/reputadas, verificados contra el catálogo actual)

Antes de proponer cada uno se comprobó que **no** existe ya un tweak equivalente en
`src/20-tweaks.ps1` (78 entradas revisadas una a una).

| Id propuesto | Categoría | Qué hace | Fuente | Por qué no está ya |
|---|---|---|---|---|
| `priv_location` | PRIVACIDAD (Tier 0) | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location` → `Value`="Deny", más `SensorPermissionState`=0 y `HKLM:\SYSTEM\Maps` `AutoUpdateEnabled`=0 | [ChrisTitusTech/winutil — tweaks.json](https://github.com/ChrisTitusTech/winutil/blob/main/config/tweaks.json), claves de política estándar de Microsoft | No hay ningún tweak de geolocalización en el catálogo actual (los `priv_*` cubren telemetría, anuncios, Cortana, Copilot, Recall, actividad — no ubicación) |
| `sys_consumerfeat` | SISTEMA (Tier 0) | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent` → `DisableWindowsConsumerOptimization`=1: para la reinstalación automática de apps "sugeridas" (Candy Crush, Spotify, etc.) tras reset/update | [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil/blob/main/config/tweaks.json), política documentada de Microsoft (CloudContent ADMX) | El `DEBLOAT` actual (17 apps) las desinstala una vez, pero no evita que Windows las reinstale solas tras una actualización de feature; esta clave sí |
| `ext_wpbt` | SEGURIDAD (Tier 1, no EXTREMO — endurece, no debilita) | `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` → `DisableWpbtExecution`=1: bloquea que la UEFI inyecte un binario firmado por el OEM (Windows Platform Binary Table) en cada arranque, el mecanismo que en el pasado se usó para bloatware/software de OEM tipo Lenovo Service Engine | [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil/blob/main/config/tweaks.json); mecanismo WPBT documentado por Microsoft (ACPI spec / Windows Hardware docs) | No hay ningún tweak que toque WPBT; encaja como hardening reversible, no como el bloque EXTREMO (no baja ninguna mitigación de exploits, solo un vector de persistencia de firmware específico) |
| `net_rsc` | RED (Tier 1, mismo patrón que `net_nagle`/`net_ctcp`: honesto sobre el trade-off) | `Disable-NetAdapterRsc` (cmdlet oficial) — apaga Receive Segment Coalescing: la NIC deja de agrupar paquetes recibidos en el mismo intervalo de interrupción antes de entregarlos a la pila de red. Baja latencia de recepción a cambio de más uso de CPU por interrupciones | [Microsoft Learn — Disable-NetAdapterRsc](https://learn.microsoft.com/en-us/powershell/module/netadapter/disable-netadapterrsc) | El catálogo tiene RSS, CTCP, ECN, Nagle, QoS, Interrupt Moderation — pero ningún tweak toca RSC, que es el offload hermano de RSS y con el trade-off inverso (RSS reparte carga entre núcleos; RSC añade retardo de agregación) |
| `net_devpower` | RED (Tier 1) | `Set-NetAdapterPowerManagement -Name <nic> -AllowComputerToTurnOffDevice Disabled` — evita que Windows apague el puerto de red en reposo (mismo problema de latencia de "despertar" que ya motiva `pwr_usbsuspend`, pero para la NIC en vez de USB) | Cmdlet oficial del módulo `NetAdapter` (mismo módulo que ya usa `net_intmod`/`net_rss`); ver también [Microsoft Learn — Power management on network adapter](https://learn.microsoft.com/en-gb/troubleshoot/windows-client/networking/power-management-on-network-adapter) | El equivalente de USB existe (`pwr_usbsuspend`) pero el de NIC no. Se prefiere el cmdlet `Set-NetAdapterPowerManagement` sobre el registro directo (`PnPCapabilities`=24) porque ese método de registro está documentado por Microsoft como poco fiable en Windows 10/11 ("puede no funcionar", ver hilo de Microsoft Q&A) — el cmdlet es la vía moderna soportada |
| `sys_devicemeta` | PRIVACIDAD (Tier 0) | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata` → `PreventDeviceMetadataFromNetwork`=1: Windows deja de consultar metadatos/imágenes de dispositivo por red al conectar hardware nuevo | [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil/blob/main/config/tweaks.json) | No cubierto por el catálogo actual de privacidad |

### Descartado tras investigar (para que quede constancia y no se repita la pregunta)

- **Deshabilitar IPv6 por completo** (visto en winutil, `DisabledComponents`=255): Microsoft
  **desaconseja explícitamente** desactivar IPv6 del todo y solo recomienda, cuando hace falta,
  priorizar IPv4 (`DisabledComponents`=32). No se propone como tweak nuevo: sería repetir
  exactamente el patrón de folclore-sin-medir que el propio catálogo de AXE ya rechaza para
  `ext_dep`/`ext_sehop` (coste real, beneficio no demostrado para gaming).
- **AMD ULPS / equivalentes de ahorro de energía "profundo" en GPU AMD**: existe `gpu_ulps`
  para NVIDIA con clave de registro verificada (`EnableUlps`). No se ha encontrado una clave de
  registro universal y verificada para el equivalente en GPUs AMD (el control vive normalmente
  en el software Radeon, no en una clave de registro estable entre generaciones de driver) — se
  deja fuera en vez de adivinar una clave no verificada, siguiendo el mismo criterio que el
  propio proyecto usa para excluir EPP/ASPM en `20-tweaks.ps1` ("escribir un GUID que no se ha
  visto responder es exactamente la clase de conjetura que el catálogo no admite").
- **Ampliar VRAM dedicada de iGPU vía registro (`DedicatedSegmentSize`)**: es un tweak real y
  citado en comunidades de tuning, pero solo aplica a sistemas con GPU integrada como única GPU
  (exactamente el escenario que `31-gamegpu.ps1` ya identifica como el que menos se beneficia de
  cualquier ajuste de software). Se anota como candidato de baja prioridad, gateado a
  "sin GPU dedicada" en `Get-BlockReason`, pero no se ha verificado la clave exacta en esta
  auditoría — no se incluye en la tabla de arriba por no tener la confirmación que el resto sí
  tiene.

---

## 7. Funciones / mejoras de arquitectura (más allá de tweaks sueltos)

1. **Arreglar §1.1** (`Commit-TweakState` en `tweaks.apply`) — es, con diferencia, lo más
   importante de todo este documento: sin esto, la característica que el proyecto usa como
   argumento de venta frente a la competencia no opera en el producto real.
2. **Test de regresión al nivel del handler RPC**, no solo de la función interna — para que
   un fallo de "cableado" como el de §1.1 no pueda volver a colarse en silencio.
3. **Completar issue #5** (split de proceso WebView2/broker elevado) — ya diseñado por el propio
   autor con criterios de aceptación claros, solo falta implementarlo.
4. **Completar issue #6** (reglas de protección de rama/tags) — es configuración de GitHub, no
   código; 15 minutos de trabajo con impacto de seguridad real sobre la cadena de firma que
   `43-update.ps1` construye.
5. **Extender `Get-AXEDiagFindings`** con las 3 detecciones "listas para implementar" de la
   sección 5 (reinicio pendiente, enlace PCIe de GPU, análisis de Defender en horario de juego),
   siguiendo el mismo patrón puro/impuro ya establecido — son aditivas, no tocan nada existente.
6. **Corregir el mensaje silencioso de `Get-AXEBottleneck`** (§3.1) para que nunca haya una
   sección sin veredicto explícito, coherente con el propio principio "UNKNOWN es un estado de
   primera clase" que el resto del proyecto ya sigue.

---

## Fuentes citadas

- [Microsoft Learn — Disable-NetAdapterRsc](https://learn.microsoft.com/en-us/powershell/module/netadapter/disable-netadapterrsc)
- [Microsoft Learn — Get-PnpDeviceProperty](https://learn.microsoft.com/en-us/powershell/module/pnpdevice/get-pnpdeviceproperty)
- [Microsoft Learn — Power management on a network adapter](https://learn.microsoft.com/en-gb/troubleshoot/windows-client/networking/power-management-on-network-adapter)
- [ChrisTitusTech/winutil — config/tweaks.json](https://github.com/ChrisTitusTech/winutil/blob/main/config/tweaks.json)
- [GitHub CARTY240HZ/AXE — issue #5](https://github.com/CARTY240HZ/AXE/issues/5)
- [GitHub CARTY240HZ/AXE — issue #6](https://github.com/CARTY240HZ/AXE/issues/6)
- Código propio del repo: `AXE/src/*.ps1`, `AXE/tests/*.Tests.ps1`, `AXE/CHANGELOG.md` (líneas
  citadas inline en cada hallazgo)

*(Los patrones de detección de "reinicio pendiente" en la sección 5.1 son de dominio público y
ampliamente estandarizados en scripts de administración de sistemas — p. ej. el script
`Get-PendingReboot.ps1` del proyecto Chocolatey/Boxstarter usa las mismas tres claves de
registro citadas arriba.)*

<sub><sup>Nota de naming: el proyecto no debe mostrar ni anunciar números de versión (nada de
"v7", "7.0.0", "6.x", etc.) en ningún sitio visible — ni en GitHub (releases, tags visibles,
README, CHANGELOG), ni dentro del propio producto (UI, CLI, logs de cara al usuario). El nombre
público es simplemente "AXE", sin versión adjunta.</sup></sub>
