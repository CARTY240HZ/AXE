# LW Suite v6 — Diseño formal

- **Estado:** Aprobado por jefatura (auditoría v1→v2 el 2026-07-12)
- **Autor del diseño:** ZCode (orquestación)
- **Auditores:** ponytail-audit, security-review, agent-architecture-audit
- **Predecesor:** `LWSuite/LWSuite_v4.ps1` (1932 líneas, monolito, 69 tweaks, SelfTest 0 fallos)
- **Referencia externa:** ChrisTitusTech/winutil (patrones modulares, data-driven)

---

## 1. Objetivo

Reescribir LWSuite preservando 100% del comportamiento funcional del v4
(hardware gating, Master Revert + cola de residuos v1, backup/restore de
startup, Tier EXTREMO aislado, asistente local, async runspace, 69 tweaks
idénticos) pero con:

1. **Catálogo como dato** (JSON, no embebido en PowerShell)
2. **GUI en C# compilada** (WPF/net48, no XAML inline parseado en caliente)
3. **Motor modular** (1 concern por archivo `.ps1`)
4. **Tests Pester** de esquema + invariantes (no por-feature)
5. **0 código muerto** (legacy a `_archive/`, no borrado)
6. **Fixes M1–M5** del audit del v4

---

## 2. Restricciones de viabilidad (verificadas empíricamente 2026-07-12)

| Restricción | Valor | Evidencia |
|---|---|---|
| Shell de ejecución | Windows PowerShell 5.1 (`powershell.exe`, CLR 4.x) | `$PSVersionTable.PSVersion = 5.1.26100.8655` |
| CLR del host | .NET Framework 4.8 (4.0.30319.42000) | `[System.Environment]::Version` en PS 5.1 |
| TFM del .dll GUI | **net48** (NO net8.0) | net8.0 DLL → "No se encuentra el tipo" en PS 5.1; net48 DLL → carga y resuelve tipos ✅ |
| Compilador | dotnet SDK 8.0.422 (compila net48 sin Visual Studio) | `dotnet build Probe.csproj -c Release` → 0 errores, .dll carga en PS 5.1 |
| WPF en el host | PresentationFramework 4.0.0.0 disponible | `Add-Type -AssemblyName PresentationFramework` OK en PS 5.1 |

**Regla inquebrantable:** todo ensamblado C# del proyecto declara
`<TargetFramework>net48</TargetFramework>`. Cualquier TFM superior rompe
la carga en `powershell.exe`. El `Build.ps1` lo materializa explícitamente.

---

## 3. Arquitectura

```
LWSuite-v6/
├── LWSuite.bat                   launcher (auto-elevate, -STA)
├── LWSuite.ps1                   entrypoint: carga módulos + lanza GUI
├── Build.ps1                     compila src/gui-cs → LWSuite.Gui.dll
├── AGENTS.md                     contrato para agentes (winutil-style + Learnings)
├── README.md
│
├── config/                       CATÁLOGO COMO DATO
│   ├── tweaks.json               69 tweaks + reversibilidad (OriginalValue)
│   ├── debloat.json              16 apps UWP
│   ├── dns.json                  5 perfiles DNS
│   ├── clean.json                6 acciones de limpieza
│   └── manifest.json             SHA-256 de los 4 archivos anteriores
│
├── src/
│   ├── core/                     MOTOR PowerShell (1 concern/archivo)
│   │   ├── Logging.ps1           Write-LWLog (file + GUI sink opcional)
│   │   ├── Hardware.ps1          Get-LWHardware, Get-LWBlockReason (gating)
│   │   ├── Registry.ps1          Get-RV/Set-RD/Set-RS/Del-RV/Set-LWService
│   │   ├── TweakEngine.ps1       Invoke-LWTweak (aplicador genérico sobre JSON)
│   │   ├── Startup.ps1           autoruns Get/Disable/Restore/Repair
│   │   ├── MasterRevert.ps1      Invoke-LWMasterRevert + Invoke-LWMasterRevertTail
│   │   ├── Profile.ps1           Export-LWProfile / Import-LWProfile
│   │   ├── Assistant.ps1         Invoke-LWAssistant + Get-LWRecommendations
│   │   └── Config.ps1            Import-LWConfig (carga + verifica hash de manifest)
│   ├── cli/
│   │   └── Modes.ps1             -SelfTest / -List / -Export / -Import
│   └── gui-cs/                   GUI EN C# (WPF, net48)
│       ├── LWSuite.Gui.csproj    <TargetFramework>net48</TargetFramework>
│       ├── App.cs                [LWSuite.Gui.App]::Start($catalogJson, $hwJson, $host)
│       ├── MainWindow.xaml       shell + nav + content host + action bar + log
│       ├── MainWindow.xaml.cs    code-behind, event wiring, DispatcherTimer
│       ├── ViewModels/           CatalogViewModel, TweakViewModel
│       └── Native.cs             P/Invoke DPI PerMonitorV2, DWM dark+Mica
│
├── tests/                        PESTER (espejo del source tree)
│   ├── tweaks-schema.Tests.ps1   cada tweak: 10 campos + OriginalValue presente
│   ├── catalog.Tests.ps1         IDs únicos, Tiers en {0,1,2}, Apply≠Revert
│   ├── config.Tests.ps1          JSON válido, manifest hash correcto
│   ├── reversibility.Tests.ps1   todo tweak (salvo svc_remotereg) tiene Undo
│   └── build.Tests.ps1           LWSuite.Gui.dll compila y carga en PS 5.1
│
├── LWSuite/                      RUNTIME STATE (heredado del v4)
│   ├── Backups/*.reg
│   ├── startup_disabled.json
│   └── lw_log_*.log
│
└── _archive/                     LEGACY PRESERVADO (referencia, no uso)
    ├── LWSuite_v4.ps1
    ├── LWSuite_v3.ps1
    ├── LWSuite_v4_winforms.bak.ps1
    └── Libreria_Windows_Tweaker.ps1
```

---

## 4. Contrato PS ↔ C# (decisión de diseño clave)

### Principio

El **motor vive en PowerShell** (los tweaks usan `Get-AppxPackage`, `powercfg`,
`sc.exe`, `bcdedit`, `Set-ProcessMitigation` — cmdlets/herramientas gratis en PS).
La **GUI vive en C#** (rendimiento nativo, type-safety, XAML designer-friendly).

### Frontera — delegados + runspace, NO eventos ni callbacks inline

El v4 resuelve la concurrencia correctamente con `DispatcherTimer` + `PowerShell.BeginInvoke()`
(evidencia: `LWSuite_v4.ps1:1390-1412`, `:1631-1651`). El diseño v6 **preserva ese patrón**.

**Patrón de binding: propiedades delegado (`Action`/`Func`), NO `event` + `Register-ObjectEvent`.**

Verificado empíricamente el 2026-07-12: en PS 5.1, `Register-ObjectEvent -Action` corre
en un **runspace separado** y no propaga estado al runspace principal — silenciosamente
pierd el resultado. En cambio, las propiedades delegado (`Action<string,bool>`,
`Func<string,bool>`) se asignan con `$gui.OnApply = { ... }` y **capturan estado
correctamente en el mismo runspace**.

```csharp
// LWSuite.Gui.App (C#) — propiedades delegado, no eventos
public class App {
    public Action<string, bool>  OnApply    { get; set; }  // (tweakId, want)
    public Func<string, bool>    OnTest     { get; set; }  // (tweakId) -> isActive
    public Action                OnMaster   { get; set; }
    public void LoadCatalog(string json);
    public void SetHardware(string json);
    public void Run();  // ShowDialog, STA
}
```

```powershell
# LWSuite.ps1 (PS) — asigna delegados, no Register-ObjectEvent
$gui = New-Object LWSuite.Gui.App
$gui.LoadCatalog($catalogJson)
$gui.SetHardware($hwJson)
$gui.OnApply  = { param($id,$want) Start-LWApplyJob -Id $id -Want $want }
$gui.OnTest   = { param($id) [bool](Invoke-LWTweak $tweaks[$id] 'Test') }
$gui.OnMaster = { Start-LWMasterRevertJob }
$gui.Run()
```

- **C# invoca los delegados desde su propio UI thread**, pero el delegado de PS
  programa el trabajo en un **runspace de fondo** (patrón `Start-LWJob` del v4) →
  el UI thread de C# nunca bloquea.
- **0 duplicación de lógica**: Test/Apply/Revert son únicos, en `TweakEngine.ps1`.
- **0 `Register-ObjectEvent`** en todo el proyecto (verified footgun).

### Serialización

PS pasa datos a C# como **JSON string** (no objetos PS nativos — evita el
modelo C# duplicado, ver recorte R1). C# deserializa a sus propios ViewModels.
El catálogo JSON es la fuente única compartida.

**Tres supuestos críticos verificados empíricamente el 2026-07-12:**

| Supuesto | Verificación | Resultado |
|---|---|---|
| net48 DLL carga en PS 5.1 | `Add-Type -Path LWTest.Probe.dll; [LWTest.Probe]::Hello()` | ✅ `net48-ok CLR=4.0.30319.42000` |
| Delegados `Action`/`Func` capturan estado en PS 5.1 | `$app.OnApply={...}; $app.FireApply('cpu_prio',$true)` | ✅ `Id=cpu_prio Want=True` |
| WPF C# `ShowDialog` corre en PS 5.1 -STA | `[LWTest.Gui]::CreateAndClose()` | ✅ `ok-showdialog` |

---

## 5. Esquema del catálogo (config/tweaks.json)

Adaptación del patrón winutil con la reversibilidad embebida (OriginalValue)
y el campo `Recommended` inline (fix D3 — sin archivo separado).

```json
{
  "cpu_prio": {
    "Category": "CPU",
    "Tier": 1,
    "Reboot": false,
    "Name": "Prioridad ventana activa",
    "Desc": "Win32PrioritySeparation=38: el juego en foco manda",
    "Requires": {},
    "Recommended": true,
    "Registry": [{
      "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\PriorityControl",
      "Name": "Win32PrioritySeparation",
      "Value": 38,
      "Type": "DWord",
      "OriginalValue": 2
    }]
  },
  "net_dns": {
    "Category": "RED", "Tier": 1, "Reboot": false,
    "Name": "[OPT] DNS rapidos 1.1.1.1 / 8.8.8.8",
    "Desc": "OJO: rompe DNS local/VPN. No va en preset",
    "Requires": {},
    "Recommended": false,
    "Script": {
      "Apply": "if($script:HW.NicName){ Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ServerAddresses @('1.1.1.1','8.8.8.8') }",
      "Undo":  "if($script:HW.NicName){ Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ResetServerAddresses }",
      "Test":  "if(-not $script:HW.NicName){return $false}; try{(Get-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -AddressFamily IPv4 -EA Stop).ServerAddresses -contains '1.1.1.1'}catch{$false}"
    }
  },
  "svc_telemetry": {
    "Category": "SERVICIOS", "Tier": 0, "Reboot": false,
    "Name": "Telemetria OFF", "Desc": "DiagTrack, dmwappushservice, WerSvc",
    "Requires": {}, "Recommended": true,
    "Service": [
      { "Name": "DiagTrack",         "StartupType": "disabled", "OriginalType": "auto" },
      { "Name": "dmwappushservice",  "StartupType": "disabled", "OriginalType": "demand" },
      { "Name": "WerSvc",            "StartupType": "disabled", "OriginalType": "demand" }
    ]
  },
  "sys_fse": {
    "Category": "SISTEMA", "Tier": 1, "Reboot": false,
    "Name": "Fullscreen exclusivo (FSE)", "Desc": "GameDVR_FSEBehavior=2",
    "Requires": {}, "Recommended": true,
    "Registry": [{
      "Path": "HKCU:\\System\\GameConfigStore", "Name": "GameDVR_FSEBehavior",
      "Value": 2, "Type": "DWord", "OriginalValue": "__REMOVE__"
    }]
  }
}
```

### Tipos de acción (un tweak compone los que necesita)

| Campo | Tipo | Propósito |
|---|---|---|
| `Registry` | array de `{Path,Name,Value,Type,OriginalValue}` | Cambios de registro declarativos. `OriginalValue`: valor literal a restaurar, u `"__REMOVE__"` (sentinel) para borrar el valor al revertir (equivalente a `Del-RV` del v4). El sentinel es una string improbable para no colisionar con valores reales. |
| `Service` | array de `{Name,StartupType,OriginalType}` | Servicios. `StartupType`/`OriginalType` en el enumerado canónico de `sc.exe`: `disabled`/`demand`/`auto` (minúsculas, matching exacto con `Set-LWService` del v4). |
| `Script` | `{Test,Apply,Undo}` (strings PS, todos opcionales) | Para lo que no es registro/servicio puro (bcdedit, powercfg, Appx, mitigations). **Ejecutado vía `[scriptblock]::Create()` — verificado que hereda scope `$script:` y helpers (2026-07-12).** |

### Semántica del aplicador genérico (ORDEN DE MERGE — crítico)

`Invoke-LWTweak` (en `TweakEngine.ps1`) es el ÚNICO punto que aplica/revierte.
El **orden de evaluación y el cortocircuito** deben estar fijos y documentados
para evitar ambiguity cuando un tweak mezcla Registry + Script:

```powershell
function Invoke-LWTweak {
    param($Tweak,[ValidateSet('Test','Apply','Undo')]$Action)
    switch($Action){
        'Test'  { # AND-lógico, cortocircuito en $false
                  # orden: Registry -> Service -> Script.Test
                  # si Script.Test existe Y devuelve $false, el tweak es OFF
                  # si solo hay Registry, Test = (valor actual == Value)
        }
        'Apply' { # orden: Script.Apply primero -> Registry -> Service
                  # (Script puede necesitar pre-condiciones, p.ej. parar servicio)
        }
        'Undo'  { # orden INVERSO: Service -> Registry -> Script.Undo
                  # (deshacer registro antes de soltar scripts de cleanup)
        }
    }
}
```

**Reglas de coherencia (validadas por Pester `tweaks-schema.Tests.ps1`):**
- Un tweak DEBE tener al menos uno de: `Registry`, `Service`, o `Script`
- `Script.Undo` es **obligatorio** si `Script.Apply` existe (reversibilidad)
- `OriginalValue` es **obligatorio** en cada entrada de `Registry` (sin valor default)
- Excepción documentada: `svc_remotereg` (Apply==Undo, hardening intencional)

**Añadir un tweak = editar JSON. 0 líneas de PowerShell.** (patrón winutil).

---

## 6. Seguridad (auditoría security-review §1, §2)

### Riesgo: ejecución de PowerShell desde JSON

El campo `Script.Apply/Undo/Test` permite código PS arbitrario en `tweaks.json`.
El tool ya corre como **admin** (es un tweaker de sistema), así que cualquier
script del catálogo ejecuta con privilegios elevados. El riesgo incremental
frente al v4 (que tenía el código inline en `.ps1`) es **bajo**: ambos modelos
ejecutan código de confianza del operador. La diferencia es que JSON es más
fácil de editar accidentalmente.

### Mitigación: manifest con hash verificado al cargar

`config/manifest.json`:
```json
{
  "version": "6.0.0",
  "generated": "2026-07-12T14:30:00Z",
  "files": {
    "tweaks.json":  "sha256:ABCDEF...",
    "debloat.json": "sha256:123456...",
    "dns.json":     "sha256:789ABC...",
    "clean.json":   "sha256:DEF123..."
  }
}
```

`Import-LWConfig` (`src/core/Config.ps1`):
1. Lee cada JSON
2. Calcula SHA-256
3. Compara con `manifest.json`
4. **Si mismatch → aborta con error, no carga el catálogo** (fail-closed)

`Build.ps1` regenera `manifest.json` tras cualquier edición de config.

### Limitación honesta del modelo de seguridad

El hash del manifest protege contra **corrupción accidental y ediciones
inadvertidas** (el caso real en un tool local: el usuario edita un valor mal,
un editor reordena el JSON, una sync de nube lo muta). **NO protege contra un
atacante que controle el directorio** — ese atacante puede reescribir
`manifest.json` a la vez que `tweaks.json`. Protección criptográfica real
exigiría firmar el manifest con una clave privada fuera del directorio
(Authenticode), lo cual excede el alcance de un tool local de un solo operador.
El modelo es equivalente al del v4 (confianza en el operador) con una capa
añadida de detección de corrupción accidental.

### Principios de seguridad adicionales (heredados del v4, preservar)

- **Reversibilidad 100%** salvo `svc_remotereg` (hardening unidireccional documentado)
- **Tier 2 (EXTREMO) aislado** con gate de confirmación explícita en UI
- **No se incluye** DisableAntiSpyware (roto en 24H2/25H2), Smart App Control OFF (irreversible), exclusiones de Defender (blind spot)
- `Master Revert` limpia residuos de v1 (SmartScreen, NoConnectedUser, hypervisor)

---

## 7. Fixes de bugs M1–M5 (auditoría del v4)

| ID | Bug v4 | Fix v6 | Dónde |
|---|---|---|---|
| **M1** | `Read-StartupBackup`: rama if/else idéntica (`if($obj -is [array]){return @($obj)} else {return @($obj)}`) | Simplificar a `return @($obj)` | `src/core/Startup.ps1` |
| **M2** | Guard anti-catálogo-roto en headless solo loguea, no aborta | `exit 1` si catálogo < 10 en modos CLI | `src/cli/Modes.ps1` |
| **M3** | `net_lso` — Id dice "LSO" pero el tweak es Interrupt Moderation OFF | Renombrar a `net_intmod` | `config/tweaks.json` |
| **M4** | Heurística HOG: `$_.CPU -gt ($up*0.8)` descrito como "0.8 núcleos continuos" — `Process.CPU` es segundos acumulados | Descripción honesta: `"$('{0:N1}' -f ($hog.CPU))s de CPU acumulada (>80% uptime). Posible HOG."` (sin nueva medición) | `src/core/Assistant.ps1` |
| **M5** | `Remove-ItemProperty ...CreationFrequency` solo en path de éxito; si Checkpoint falla, deja frequency=0 | Mover cleanup a `finally` | `src/gui-cs/MainWindow.xaml.cs` (restore point handler) |

---

## 8. Verificación y calidad

### SelfTest (regresión headless, heredado del v4)

Conservar los 11+ checks (S1–S11) del v4, adaptados a cargar desde JSON:
- S1: cada tweak tiene las claves obligatorias (Category/Tier/Reboot/Name/Desc/Requires + al menos una acción)
- S2: IDs únicos
- S3: Tier en {0,1,2}
- S5: todo tweak (salvo svc_remotereg) tiene Undo ≠ Apply
- S6: catálogo ≥ 60 tweaks (masa crítica)
- S8: gating devuelve null o string
- + nuevo S12: manifest hash verificado

### Pester (nuevo)

`tests/*.Tests.ps1` — validan **esquema del JSON + invariantes**, no comportamiento por-feature (patrón winutil). Como los tweaks son datos, se valida el data shape una vez y se confía en el applier genérico.

### LW_GUITEST=1 (regresión visual, heredado del v4)

Render PNG sin ShowDialog — conservado para CI.

### Build.ps1

Compila `src/gui-cs` → `LWSuite.Gui.dll`. Falla si error. Regenera manifest.

---

## 9. Preservar vs. cambiar (resumen ejecutivo)

| Preservar (no romper) | Cambiar |
|---|---|
| Hardware gating (`Get-LWHardware`, `Get-LWBlockReason`) | Catálogo PS inline → `config/tweaks.json` |
| Master Revert + Tail (limpieza residuos v1) | XAML inline 336 líneas → C# WPF compilado net48 |
| Startup backup/restore/repair | Monolito 1932 líneas → módulos `src/core/*.ps1` |
| Tier EXTREMO aislado + gate de seguridad | Sin tests externos → Pester de esquema |
| Asistente local state-aware | Sin contrato de agentes → AGENTS.md + Learnings |
| Async runspace (HW + apply + master-revert) | — |
| 69 tweaks idénticos en comportamiento | — |
| SelfTest 0 fallos | — |
| LW_GUITEST render PNG | — |

---

## 10. Correcciones del audit del diseño v1 (incorporadas en este v2)

| # | Hallazgo del audit | Corrección en v2 | Sección |
|---|---|---|---|
| **B1** | net8.0 no carga en PS 5.1 | `<TargetFramework>net48</TargetFramework>` obligatorio | §2, §3 |
| **D1** | Callbacks inline recongelarían UI | Contrato por **delegados** (`Action`/`Func`) + runspace (preservar patrón v4; `Register-ObjectEvent` descartado — verified footgun) | §4 |
| **D2** | Script en JSON = vector de ataque vs. v4 inline | manifest.json con SHA-256: protege corrupción accidental (no atacante que controle el dir — ver §6). Riesgo incremental bajo: ambos modelos corren como admin con confianza del operador. | §6 |
| **D3** | recommended.json = YAGNI | Campo `"Recommended"` inline en tweaks.json | §5 |
| **D4** | Fix M4 incompleto | Descripción honesta, no nueva heurística | §7 |
| **R1** | HardwareInfo.cs duplica modelo PS | PS pasa JSON string, no objeto; C# deserializa | §4 |
| **R2** | run-pester.ps1 wrapper YAGNI | Usar `Invoke-Pester` directo | §8 |
| **R3** | ToggleSwitch.xaml custom YAGNI | Reusar CheckBox + style del v4 | §3 (implícito) |

---

## 11. Criterios de aceptación (definition of done)

El v6 se considera completo cuando:

1. ✅ `LWSuite.bat -SelfTest` → 0 fallos (paridad con v4)
2. ✅ `Invoke-Pester tests/` → todos pasan
3. ✅ `LW_GUITEST=1` renderiza PNG sin excepciones
4. ✅ `dotnet build src/gui-cs` → 0 errores, .dll carga en PS 5.1
5. ✅ Los 69 tweaks del v4 están en `tweaks.json` con comportamiento idéntico
6. ✅ Master Revert limpia los mismos residuos v1 que el v4
7. ✅ Hardware gating bloquea los mismos tweaks que el v4 en el mismo PC
8. ✅ `manifest.json` verifica hash al cargar; alterar un config → aborta
9. ✅ `_archive/` contiene los 4 legacy; el repo raíz está limpio
10. ✅ AGENTS.md existe con la sección Learnings arrancada
