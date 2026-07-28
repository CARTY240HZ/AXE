# ================================================================
# AXE 7.1.0 - BUILT from /src by build.ps1 - DO NOT EDIT DIRECTLY
# Build UTC: 2026-07-28 20:27:41Z
# Modules: 00-header.ps1, 05-core.ps1, 10-reg-helpers.ps1, 15-startup.ps1, 20-tweaks.ps1, 22-catalogs.ps1, 23-defender.ps1, 25-assistant.ps1, 28-revert-export.ps1, 30-profiles.ps1, 31-gamegpu.ps1, 32-measure.ps1, 33-fps.ps1, 34-safety.ps1, 35-diag.ps1, 36-report.ps1, 37-netmon.ps1, 38-regedit.ps1, 39-webdetect.ps1, 40-session.ps1, 41-bench.ps1, 42-advisor.ps1, 43-update.ps1, 44-latency.ps1, 45-cli.ps1, 47-webhost.ps1, 48-webbridge.ps1, 49-webmain.ps1
# ================================================================

# >>>>> MODULE: 00-header.ps1 >>>>>
#Requires -Version 5.1
# =====================================================
# AXE - Elite Windows Optimizer (single source of truth)
#
# Motor UNICO consolidado. Corrige todos los hallazgos del audit:
#   C1  Backup/restore de startup robusto + Restore-Autorun
#   A1  Master revert limpia residuos v1 (SmartScreen/NoConnectedUser/hypervisor)
#   A2  Un valor canonico por tweak; fuentes unificadas
#   M1  Reverts que no revertian -> eliminados o documentados como unidireccionales
#   M4  Punto de restauracion en runspace (GUI no se congela)
#   M5  Guard anti-catalogo-roto + modo -SelfTest (validacion headless)
#
# Modos de ejecucion (headless, sin GUI ni admin):
#   -SelfTest     Validacion de integridad del catalogo y helpers (0 fallos)
#   -List         Estado real de cada tweak contra el sistema
#   -Export/-Import <file>  Perfil JSON
#   -GameList     Preferencia de GPU por juego, tal como esta ahora
#   -OptimizeGame <ruta.exe> [-NoFSO]  dGPU + flip model en ESE ejecutable
#   -RevertGame   <ruta.exe>           Deshace lo anterior al estado capturado
#   -Fps <proceso> [-FpsSeconds N]     Mide FPS reales con PresentMon (1% low incluido)
#   -Fps <proceso> -FpsCompare         Antes/despues con veredicto honesto (ruido o no)
#   -Benchmark                     Linea base medible (N pasadas, mediana + IQR). Imprime un id.
#   -Benchmark -After <id> [-Report <file>]
#                 Vuelve a medir tras aplicar+reiniciar y da el veredicto por metrica:
#                 mejor / peor / RUIDO. Nunca declara mejora dentro del margen de ruido.
#   -NetMon [-NetMonTarget <ip>] [-NetMonCount N]
#                 Ping, jitter de RED y perdida contra la puerta de enlace y una ancla publica.
#                 Solo mide. Distingue "tu enlace" de "tu operador"; no puntua el ping a
#                 internet porque no hay umbral honesto para eso.
#   -Diag         Configuracion mal puesta que cuesta mas FPS que todo el catalogo junto
#                 (XMP/EXPO, canales de RAM, Hz del monitor por EDID, SSD, nucleos P/E).
#                 Solo detecta, no toca nada.
#   -Mouse [-MouseSeconds N]
#                 Sondeo real del raton (125 vs 1000 Hz = 7 ms de input lag), aceleracion del
#                 puntero y escalado 1:1. Hay que MOVER el raton mientras mide.
#   -Dpc [-DpcSeconds N]
#                 Tiempo en rutinas diferidas de drivers por nucleo: la otra familia de
#                 tirones, la que no baja el FPS medio. Mide carga total, no atribuye driver.
#   -NetLoad [-NetLoadUrl <url>]
#                 Latencia BAJO CARGA (bufferbloat): el ping que tendras cuando alguien de casa
#                 descargue algo. Satura el enlace a proposito descargando de Cloudflare (no
#                 envia nada del equipo); sin saturar no hay nada que medir.
#   -Update [-Check]  Comprueba si hay version nueva en el repo oficial. Sin -Check la instala,
#                 pero SOLO tras verificar SHA256 + firma Authenticode; sin firma valida avisa
#                 y NO reemplaza nada (el destino es escribible por el usuario y AXE corre
#                 elevado: un updater laxo seria la via de escalada). No envia nada del equipo.
#   (sin args)    GUI (requiere admin via el launcher .bat)
# =====================================================

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$List,
    [string]$Export,
    [string]$Import,
    [switch]$Measure,
    [switch]$Score,
    [string]$Report,
    [switch]$TimerSweep,
    # Verificado sin colision contra el resto de src/ antes de anadirlo (ver nota de $GameList).
    [switch]$Diag,
    # Consejero (42-advisor). Comprobado como manda la leccion S24 antes de anadirlo:
    # 'grep $Advice src/' = 0 apariciones fuera de aqui y de 45-cli, ninguna como variable de
    # ruta. Declarar un switch cuyo nombre ya usa un modulo como variable local lo tipa a nivel de
    # script y revienta esa asignacion en silencio: fue exactamente lo que paso con $Games.
    [switch]$Advice,
    # OJO: NO llamar a este switch '$Games'. 20-tweaks.ps1 usa $Games como variable local para
    # la ruta de la tarea MMCSS ('...\SystemProfile\Tasks\Games'); declararlo aqui como [switch]
    # la tipa a nivel de script y la asignacion de esa cadena revienta => gpu_mmcss se queda
    # apuntando a una ruta vacia. Pasaba el SelfTest con 0 fallos (su Test solo devuelve false).
    [switch]$GameList,
    [string]$OptimizeGame,
    [string]$RevertGame,
    [switch]$NoFSO,
    # Nombres verificados contra el resto de src/ antes de anadirlos: ver la nota de $GameList
    # sobre la colision con el $Games de 20-tweaks.ps1, y el check S24 que la caza.
    [string]$Fps,
    [int]$FpsSeconds = 20,
    [switch]$FpsCompare,
    # Daemon de sesion de juego (subsistema A, spec 2026-07-20): congela el fondo mientras
    # juegas y lo descongela al cerrar el juego o AXE. Nombre verificado sin colision en src/.
    [string]$Session,
    [int]$SessionPoll = 1000,
    # Benchmark "pruebalo en tu PC" (subproyecto C, spec 2026-07-24). Dos fases con reinicio
    # humano en medio: -Benchmark guarda la linea base, -Benchmark -After <id> la compara.
    #   Nombres verificados contra el resto de src/ antes de anadirlos (leccion $Games/S24):
    # 'Benchmark' no aparece en ningun modulo; 'After' solo existe como PARAMETRO LOCAL de
    # Get-AXEFpsVerdict (param([object]$After)), que tiene su propio ambito y no colisiona con
    # una variable de script. Ninguno de los dos se usa como variable de ruta => S24 no aplica.
    [switch]$Benchmark,
    [string]$After,
    [int]$BenchPasses = 7,
    # Updater con cadena de confianza (subproyectos A+B, spec 2026-07-24). '-Update' comprueba
    # y, si hay version nueva, la instala SOLO tras verificar checksum + firma Authenticode.
    # '-Update -Check' se queda en informar y no descarga nada.
    #   Nombres verificados contra el resto de src/ antes de anadirlos (leccion $Games/S24):
    # 'Update' y 'Check' no aparecen como variable en ningun modulo (grep sobre src/ = 0 hits),
    # asi que no pueden tipar a [switch] una variable de ruta ajena. S24 los vigila igual.
    [switch]$Update,
    [switch]$Check,
    # Monitor de red (37-netmon.ps1). Cubre el hueco que el audit de 2026-07-25 dejo abierto:
    # el jitter de 32-measure es de TIMER, no de red, y de red no se medi­a nada.
    #   Nombres verificados contra el resto de src/ antes de anadirlos (leccion $Games/S24):
    # grep '$NetMon' sobre src/ = 0 hits fuera de 45-cli. Ninguno se usa como variable de ruta.
    [switch]$NetMon,
    [string]$NetMonTarget = '1.1.1.1',
    [int]$NetMonCount = 20,
    # v7.1: diagnosticos de latencia que el catalogo no puede tocar.
    #   -Mouse    sondeo del raton + aceleracion + escalado 1:1   (44-latency.ps1)
    #   -Dpc      tiempo en rutinas diferidas de drivers          (44-latency.ps1)
    #   -NetLoad  latencia bajo carga / bufferbloat               (37-netmon.ps1)
    #   Nombres verificados contra el resto de src/ antes de anadirlos (leccion $Games/S24):
    # grep de '$Mouse', '$Dpc' y '$NetLoad' sobre src/ = 0 hits. Ninguno se usa como variable
    # de ruta en ningun modulo, asi que declararlos aqui no puede tipar nada ajeno a [switch].
    [switch]$Mouse,
    [int]$MouseSeconds = 3,
    [switch]$Dpc,
    [int]$DpcSeconds = 5,
    [switch]$NetLoad,
    # Vacio a proposito: el default real vive en $script:AXENetLoadUrl (37-netmon), y un param
    # block no puede leer una variable de un modulo que aun no se ha concatenado.
    [string]$NetLoadUrl = ''
)

# Version canonica. build.ps1 reemplaza el token desde el fichero VERSION (fuente unica).
# Va DESPUES del param block (regla PS: param() debe ser la primera sentencia).
# Fallback si el token no se reemplazo (se corre src suelto sin build).
$script:AXEVersion = '7.1.0'
if($script:AXEVersion -like '*__AXE_VERSION__*'){ $script:AXEVersion = '6.1.0-dev' }



# >>>>> MODULE: 05-core.ps1 >>>>>
# =====================================================
# REGION 1 - PATHS & LOGGING  (headless, sin UI)
# =====================================================
$script:AXERoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AXEData   = Join-Path $script:AXERoot 'AXE'
$script:AXEBackup = Join-Path $script:AXEData 'Backups'
$script:AXELog    = Join-Path $script:AXEData ("axe_log_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$script:RunBak   = Join-Path $script:AXEData 'startup_disabled.json'
$script:StateBak = Join-Path $script:AXEData 'tweak_state.json'   # snapshot revert: estado previo real por tweak
# Migracion de datos legacy: si existe <root>/LWSuite/ (motor v4 pre-rebrand) y aun no hay
# <root>/AXE/, moverlo entero (Backups, logs, startup_disabled.json). Idempotente.
$legacy = Join-Path $script:AXERoot 'LWSuite'
if((Test-Path $legacy) -and -not (Test-Path $script:AXEData)){
    Move-Item -Path $legacy -Destination $script:AXEData -Force -EA Stop
}
foreach($d in @($script:AXEData,$script:AXEBackup)){ if(-not(Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$script:LogBox = $null
function Write-AXELog {
    param([string]$Msg,[string]$Level='INFO')
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Msg
    Add-Content -Path $script:AXELog -Value $line -Encoding UTF8
    if($script:LogBox -and $script:AXELogSink){
        try {
            if($script:LogBox.Dispatcher.CheckAccess()){ & $script:AXELogSink $line $Level }
            else { $script:LogBox.Dispatcher.Invoke([action]{ & $script:AXELogSink $line $Level }) }
        } catch {}
    }
}

# =====================================================
# REGION 2 - HARDWARE DETECTION  (define que tweaks son validos)
# =====================================================
function Get-AXEHardware {
    # Detecta el equipo entero degradando CAMPO A CAMPO, no todo o nada.
    #
    # El defecto que arregla: Win32_Processor y Win32_OperatingSystem se consultaban SIN
    # -ErrorAction, asi que un unico fallo de WMI tiraba la funcion entera. Y como el puente
    # (48-webbridge, 'hw.get') no la envuelve en try/catch, la ventana se quedaba sin panel de
    # hardware por un fallo que a lo mejor solo afectaba a un campo. Peor: Get-AXEHardware es la
    # base del gating -que tweaks aplican en esta maquina-, o sea que quedarse sin ella no deja a
    # AXE sin UN dato, lo deja sin NINGUNO.
    #   Importa mas de lo que parece por quien usa esto: el publico de AXE son equipos a los que ya
    # les paso otro optimizador por encima, y romper WMI es de lo mas comun que dejan detras. Por eso
    # lo esencial -version, build, edicion- tiene camino alternativo por REGISTRO, que sigue vivo
    # cuando WMI no. Lo que aun asi no se pueda leer viaja como $null y su motivo se apunta en
    # DetectWarnings, que la interfaz ENSENA: "no lo se" es un estado legitimo y distinto de "no lo
    # tienes", y esta suite no va a mentir justo en el panel de hardware.
    $warn = New-Object System.Collections.ArrayList
    $cpu = $null; try { $cpu = Get-CimInstance Win32_Processor -EA Stop | Select-Object -First 1 }
                  catch { [void]$warn.Add('CPU: WMI no respondio a Win32_Processor.') }
    $os  = $null; try { $os  = Get-CimInstance Win32_OperatingSystem -EA Stop }
                  catch { [void]$warn.Add('sistema: WMI no respondio a Win32_OperatingSystem; se tira de registro.') }

    # Chasis -> portatil. Si el fabricante no rellena el chasis (pasa, y mucho, en portatiles de
    # marca blanca) queda 1/2 = Other/Unknown y la bateria desempata. No al reves: hay sobremesas
    # con SAI que exponen Win32_Battery, asi que la bateria SOLO decide cuando el chasis no sabe.
    $enc = @(); try { $enc = @((Get-CimInstance Win32_SystemEnclosure -EA Stop).ChassisTypes) }
                catch { [void]$warn.Add('chasis: no pude leer Win32_SystemEnclosure (torre/portatil se deduce por bateria).') }
    $isLaptop = @($enc | Where-Object { $_ -in 8,9,10,11,12,14,18,21,30,31,32 }).Count -gt 0
    $bat = $null; try { $bat = Get-CimInstance Win32_Battery -EA Stop | Select-Object -First 1 } catch {}
    $chassisKnown = @($enc | Where-Object { $_ -notin 1,2 }).Count -gt 0
    if(-not $isLaptop -and -not $chassisKnown -and $bat){ $isLaptop = $true }

    $isHybrid = $false
    try { if($cpu.Name -match '1[2-9]th Gen' -or $cpu.Name -match 'Ultra'){ $isHybrid = $true } } catch {}

    # GPU. Se filtran los adaptadores que no pintan un juego (RDP, escritorios virtuales, capturadoras).
    $gpu = @(); try { $gpu = @(Get-CimInstance Win32_VideoController -EA Stop | Where-Object { $_.Name -notmatch 'Virtual|Basic|Meta|Parsec|Remote|DisplayLink|IDD' }) }
                catch { [void]$warn.Add('GPU: no pude leer Win32_VideoController.') }
    $hasNvidia = @($gpu | Where-Object Name -match 'NVIDIA').Count -gt 0
    $gpuNames  = @($gpu | ForEach-Object { [string]$_.Name } | Where-Object { $_ })
    # Vendor de la GPU que MANDA. En un portatil hibrido hay dos y la dedicada es la que juega, asi
    # que NVIDIA/AMD ganan a la integrada de Intel en el rotulo. Antes solo existia HasNvidia: quien
    # tuviera Radeon o Arc no veia GPU ninguna en el panel, como si AXE no supiera que existe.
    $gpuVendor = $null
    if($gpuNames -match 'NVIDIA'){ $gpuVendor = 'NVIDIA' }
    elseif($gpuNames -match 'AMD|Radeon'){ $gpuVendor = 'AMD' }
    elseif($gpuNames -match 'Intel'){ $gpuVendor = 'Intel' }
    $gpuPrimary = $null
    if($gpuVendor){ $gpuPrimary = [string](@($gpuNames | Where-Object { $_ -match $gpuVendor }) | Select-Object -First 1) }
    if(-not $gpuPrimary -and $gpuNames.Count){ $gpuPrimary = [string]$gpuNames[0] }

    # Hz y resolucion del modo ACTIVO. En hibridos la dedicada suele no tener modo (la pantalla la
    # pinta la integrada) y devuelve $null, asi que se coge el maximo de los que si reportan.
    # Es el dato mas relevante que faltaba en un afinador de juegos: sin saber que el panel va a
    # 180 Hz no se puede opinar sobre un limitador de FPS ni sobre VSync.
    $refresh = $null; $scrW = $null; $scrH = $null
    try {
        $mode = @($gpu | Where-Object { $_.CurrentRefreshRate -and [int]$_.CurrentRefreshRate -gt 0 } |
                  Sort-Object { [int]$_.CurrentRefreshRate } -Descending | Select-Object -First 1)
        if($mode.Count){
            $refresh = [int]$mode[0].CurrentRefreshRate
            if($mode[0].CurrentHorizontalResolution){ $scrW = [int]$mode[0].CurrentHorizontalResolution }
            if($mode[0].CurrentVerticalResolution){   $scrH = [int]$mode[0].CurrentVerticalResolution }
        }
    } catch {}
    if($null -eq $refresh){ [void]$warn.Add('frecuencia del monitor: ningun adaptador reporto modo activo.') }

    # Maquina virtual: cambia como hay que leer TODO lo demas (timer, jitter, energia), asi que se
    # declara en vez de medir como si fuera hierro real.
    $isVM = $false; $csModel = $null; $csVendor = $null
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -EA Stop
        $csModel = [string]$cs.Model; $csVendor = [string]$cs.Manufacturer
        $isVM = [bool](("$csModel $csVendor") -match 'VMware|VirtualBox|VBOX|QEMU|KVM|Xen|Hyper-V|Virtual Machine|Parallels|innotek|Bochs')
    } catch { [void]$warn.Add('modelo del equipo: no pude leer Win32_ComputerSystem.') }

    $activeNic = $null
    try { $activeNic = Get-NetAdapter -Physical -EA Stop | Where-Object Status -eq 'Up' | Select-Object -First 1 }
    catch { [void]$warn.Add('red: no pude enumerar adaptadores fisicos.') }
    if(-not $activeNic){ [void]$warn.Add('red: ningun adaptador fisico conectado.') }
    $isWifi = [bool]($activeNic -and ($activeNic.PhysicalMediaType -match 'Native 802.11|Wireless' -or $activeNic.Name -match 'Wi-?Fi|Wireless'))

    $onBattery = $false
    try { if($bat -and $bat.BatteryStatus -ne 2){ $onBattery = $true } } catch {}

    # --- Version de Windows. Camino WMI con RESPALDO por registro y por Environment. -------------
    # OJO con ProductName del registro: en Win11 sigue diciendo "Windows 10 Pro". Es un fallo
    # conocido de Microsoft, y por eso Win11 se decide SIEMPRE por numero de build (>= 22000, el
    # corte oficial), nunca por el nombre.
    $reg = $null
    try { $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA Stop } catch {}
    $build = $null
    if($os -and $os.BuildNumber){ $build = [string]$os.BuildNumber }
    elseif($reg -and $reg.CurrentBuildNumber){ $build = [string]$reg.CurrentBuildNumber }
    else { try { $build = [string][System.Environment]::OSVersion.Version.Build } catch {} }
    $isWin11 = $false
    try { $isWin11 = ([int]$build -ge 22000) } catch {}
    $edition = $null
    if($os -and $os.Caption){ $edition = [string]$os.Caption }
    elseif($reg -and $reg.ProductName){ $edition = [string]$reg.ProductName }
    if($edition -and $isWin11){ $edition = $edition -replace 'Windows 10','Windows 11' }   # ver nota de arriba
    if(-not $edition){ [void]$warn.Add('edicion de Windows: ilegible por WMI y por registro.') }
    # 24H2, 23H2... Decide mas que 10 vs 11 sobre que hay disponible en la maquina.
    $displayVer = $null
    if($reg){ $displayVer = [string]$(if($reg.DisplayVersion){ $reg.DisplayVersion } else { $reg.ReleaseId }) }
    $ubr = $null; if($reg -and $null -ne $reg.UBR){ try { $ubr = [int]$reg.UBR } catch {} }
    # --- ecosistema (§3.1): arquitectura, vendor, seguridad. Todo self-contained (corre en runspace) ---
    $cpuArch   = $env:PROCESSOR_ARCHITECTURE                 # AMD64 / ARM64 / x86
    # Con WMI caido $cpu es $null. El registro guarda el mismo dato y no depende del servicio.
    $cpuVendor = $null; $cpuName = $null; $cpuCores = $null; $cpuThreads = $null
    if($cpu){
        $cpuVendor = [string]$cpu.Manufacturer                # GenuineIntel / AuthenticAMD / Qualcomm...
        $cpuName   = [string]$cpu.Name
        $cpuCores  = $cpu.NumberOfCores; $cpuThreads = $cpu.NumberOfLogicalProcessors
    } else {
        try {
            $c0 = Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -EA Stop
            $cpuName   = [string]$c0.ProcessorNameString
            $cpuVendor = [string]$c0.VendorIdentifier
        } catch {}
        # Hilos siempre disponibles sin WMI; nucleos fisicos no, y no se inventan.
        try { $cpuThreads = [int][System.Environment]::ProcessorCount } catch {}
        [void]$warn.Add('CPU: nucleos fisicos desconocidos (solo hilos logicos) porque WMI no respondio.')
    }
    # Defender + Tamper: una sola llamada (lenta), ambos derivados. AV de terceros -> el cmdlet falla o AMServiceEnabled=false.
    $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {}
    $hasDefender = [bool]($mp -and $mp.AMServiceEnabled)
    $isTamper    = [bool]($mp -and $mp.IsTamperProtected)
    # S mode: SkuPolicyRequired=1 en CI\Policy (try/catch, default no-S)
    $isSMode = $false
    try { $isSMode = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name SkuPolicyRequired -ErrorAction Stop).SkuPolicyRequired -eq 1) } catch {}
    # HAGS: heuristica conservadora. El OS solo crea el valor HwSchMode en GPUs WDDM>=2.7 capaces;
    # ausente => tratamos como no-soportado (ocultar), nunca falso-positivo que aplique HAGS en HW incompatible.
    $supportsHAGS = $false
    try { $supportsHAGS = ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction Stop).HwSchMode) } catch {}
    # SSD del disco de sistema (§3.3 banner). NVMe suele reportar MediaType 'Unspecified' => fallback BusType.
    $isSSD = $false
    try {
        $osDiskNum = (Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop).DiskNumber
        $osPhys = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$osDiskNum" }
        if($osPhys){ $isSSD = ($osPhys.MediaType -eq 'SSD') -or ($osPhys.BusType -eq 'NVMe') }
    } catch {}
    # RAM. Sin WMI el respaldo es el contador de rendimiento, que no depende del servicio de WMI.
    # A diferencia del resto NO se deja en $null: RamGB alimenta el gating (MinRam/MaxRam) y un
    # nulo ahi se compara como 0, o sea que bloquearia tweaks callando el motivo. 0 con aviso
    # declarado bloquea igual, pero diciendo por que.
    $ramGB = 0
    if($os -and $os.TotalVisibleMemorySize){ $ramGB = [math]::Round($os.TotalVisibleMemorySize/1MB,1) }
    else {
        try { $ramGB = [math]::Round((Get-CimInstance Win32_PhysicalMemory -EA Stop | Measure-Object Capacity -Sum).Sum/1GB,1) } catch {}
        if($ramGB -le 0){ [void]$warn.Add('RAM: ilegible; los ajustes que dependen de la memoria quedaran bloqueados.') }
    }

    [pscustomobject]@{
        CpuName=$cpuName; Cores=$cpuCores; Threads=$cpuThreads
        IsLaptop=$isLaptop; IsHybrid=$isHybrid; HasNvidia=$hasNvidia
        IsWifi=[bool]$isWifi; NicName=$activeNic.Name; Edition=$edition
        IsHome=($edition -match 'Home'); OnBattery=$onBattery
        IsWin11=$isWin11; BuildNumber=$build
        RamGB=$ramGB
        CpuArch=$cpuArch; CpuVendor=$cpuVendor
        HasDefender=$hasDefender; IsTamperProtected=$isTamper
        IsSMode=$isSMode; SupportsHAGS=$supportsHAGS; IsSSD=$isSSD
        # --- Campos nuevos. Ninguno de los de arriba cambia de nombre ni de tipo: el gating
        # (20-tweaks), el banner y los tests siguen leyendo exactamente lo mismo que antes. ---
        GpuNames=$gpuNames; GpuPrimary=$gpuPrimary; GpuVendor=$gpuVendor
        RefreshHz=$refresh; ScreenW=$scrW; ScreenH=$scrH
        IsVM=$isVM; Model=$csModel; Vendor=$csVendor
        DisplayVersion=$displayVer; Ubr=$ubr
        # Lo que NO se pudo leer, con su motivo. La interfaz lo ensena en vez de fingir certeza.
        DetectWarnings=@($warn)
    }
}



# >>>>> MODULE: 10-reg-helpers.ps1 >>>>>
# =====================================================
# REGION 3 - HELPERS (registro / servicio / backup)
# =====================================================
# --- SNAPSHOT REVERT: captura del estado previo REAL por tweak (H3) ---
# Los 4 primitivos de escritura (Set-RD/Set-RS/Del-RV/Set-SvcStart) graban el valor
# ANTERIOR de cada clave/servicio que tocan, la PRIMERA vez que se aplica el tweak.
# Revert/Master restauran ese valor exacto (o lo borran si no existia) en vez de un
# default de fabrica hardcodeado. Solo aplica a tweaks 100% registro/servicio; los que
# usan bcdedit/powercfg/ProcessMitigation/DNS caen a su Revert scriptblock (Test-SnapEligible).
$script:capTweak = $null    # id del tweak en captura (o $null)
$script:capBuf   = @{}      # id -> [ordered]@{ "P|N" = record }
function Test-SnapEligible($tw){
    $s = "$($tw.Apply)`n$($tw.Revert)"
    foreach($t in 'bcdedit','powercfg','Set-ProcessMitigation','Set-DnsClient'){ if($s -match [regex]::Escape($t)){ return $false } }
    return $true
}
function Push-RegBackup($p,$n){
    if(-not $script:capTweak){ return }
    if(-not $script:capBuf.ContainsKey($script:capTweak)){ $script:capBuf[$script:capTweak]=[ordered]@{} }
    $key="$p|$n"
    if($script:capBuf[$script:capTweak].Contains($key)){ return }   # solo primera vez
    $rec=@{T='reg'; P=$p; N=$n; Had=$false}
    try {
        $it=Get-Item -LiteralPath $p -ErrorAction Stop
        if($it.GetValueNames() -contains $n){ $rec.Had=$true; $rec.V=$it.GetValue($n); $rec.K=$it.GetValueKind($n).ToString() }
    } catch {}
    $script:capBuf[$script:capTweak][$key]=$rec
}
function Push-SvcBackup($n){
    if(-not $script:capTweak){ return }
    if(-not $script:capBuf.ContainsKey($script:capTweak)){ $script:capBuf[$script:capTweak]=[ordered]@{} }
    $key="svc|$n"
    if($script:capBuf[$script:capTweak].Contains($key)){ return }
    $st=Get-SvcStart $n
    $map=@{Automatic='auto'; Manual='demand'; Disabled='disabled'; Boot='boot'; System='system'}
    $tok=if($st -and $map.ContainsKey("$st")){ $map["$st"] } else { $null }
    # 'Automatic' de .StartType cubre auto normal Y auto-RETRASADO: el cmdlet no los distingue.
    # El bit real vive en DelayedAutostart bajo la clave del servicio. Sin esto, restaurar un
    # servicio que venia retrasado (DiagTrack, MapsBroker...) lo devolvia como auto normal, o sea
    # arrancando ANTES que antes: el snapshot decia "estado previo" y no lo era del todo.
    # 'delayed-auto' es el token que entiende sc.exe, que es lo que usa Restore-TweakState.
    if($tok -eq 'auto' -and (Get-RV "HKLM:\SYSTEM\CurrentControlSet\Services\$n" 'DelayedAutostart') -eq 1){ $tok='delayed-auto' }
    $script:capBuf[$script:capTweak][$key]=@{T='svc'; N=$n; Start=$tok}
}
function Get-RV($p,$n){ try { (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n } catch { $null } }
function Set-RD($p,$n,$v){ Push-RegBackup $p $n; if(-not(Test-Path $p)){ New-Item -Path $p -Force -EA Stop | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType DWord -Force -EA Stop | Out-Null }
function Set-RS($p,$n,$v){ Push-RegBackup $p $n; if(-not(Test-Path $p)){ New-Item -Path $p -Force -EA Stop | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType String -Force -EA Stop | Out-Null }
function Del-RV($p,$n){ Push-RegBackup $p $n; Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue }
function Test-Svc($n){ [bool](Get-Service $n -ErrorAction SilentlyContinue) }
function Get-SvcStart($n){ try { (Get-Service $n -ErrorAction Stop).StartType } catch { $null } }
function Set-SvcStart($n,$m){
    if(-not(Test-Svc $n)){ Write-AXELog "Servicio '$n' no existe en este SKU, omitido" 'WARN'; return }
    Push-SvcBackup $n
    & sc.exe config $n start= $m | Out-Null
    if($LASTEXITCODE -ne 0){ throw "sc config $n start=$m fallo (code $LASTEXITCODE)" }
}
function Backup-RegKey($hive,$file){
    $dest = Join-Path $script:AXEBackup $file
    if(Test-Path $dest){ return }   # NO destructivo: solo la primera vez
    & reg.exe export $hive $dest /y *>$null
    if($LASTEXITCODE -eq 0){ Write-AXELog "Backup: $file" }
}
# --- Persistencia del snapshot (sobrevive reinicios) ---
function Read-StateBak {
    if(-not(Test-Path $script:StateBak)){ return @{} }
    try {
        $raw=Get-Content $script:StateBak -Raw -Encoding UTF8
        if([string]::IsNullOrWhiteSpace($raw)){ return @{} }
        $o=$raw | ConvertFrom-Json -ErrorAction Stop
        $h=@{}; foreach($pr in $o.PSObject.Properties){ $h[$pr.Name]=$pr.Value }
        return $h
    } catch {
        Write-AXELog "tweak_state.json ilegible: $($_.Exception.Message). Renombrado a .corrupt" 'ERR'
        try { Move-Item $script:StateBak "$($script:StateBak).corrupt" -Force -EA Stop } catch {}
        return @{}
    }
}
function Save-StateBak($h){ ($h | ConvertTo-Json -Depth 6) | Set-Content $script:StateBak -Encoding UTF8 }
function Commit-TweakState($id){
    # Vuelca capBuf[id] al store. Solo si el id NO existe ya (preserva la captura ORIGINAL).
    if(-not $script:capBuf.ContainsKey($id)){ return }
    $recs=@($script:capBuf[$id].Values); $script:capBuf.Remove($id)
    if($recs.Count -eq 0){ return }
    $store=Read-StateBak
    if($store.ContainsKey($id)){ return }   # ya teniamos el estado original; no pisar
    $store[$id]=$recs; Save-StateBak $store
}
function Remove-TweakState($id){ $store=Read-StateBak; if($store.ContainsKey($id)){ $store.Remove($id); Save-StateBak $store } }
function Restore-TweakState($id){
    # Restaura el estado previo REAL capturado. Devuelve $true si habia snapshot.
    $store=Read-StateBak
    if(-not $store.ContainsKey($id)){ return $false }
    $recs=@($store[$id])
    for($i=$recs.Count-1; $i -ge 0; $i--){
        $r=$recs[$i]
        try {
            if($r.T -eq 'reg'){
                if($r.Had){
                    if(-not(Test-Path $r.P)){ New-Item -Path $r.P -Force -EA Stop | Out-Null }
                    New-ItemProperty -Path $r.P -Name $r.N -Value $r.V -PropertyType $r.K -Force -EA Stop | Out-Null
                } else { Remove-ItemProperty -Path $r.P -Name $r.N -ErrorAction SilentlyContinue }
            } elseif($r.T -eq 'svc'){ if($r.Start){ & sc.exe config $r.N start= $r.Start | Out-Null } }
        } catch { Write-AXELog "Restore ${id}: fallo en $($r.P)\$($r.N): $($_.Exception.Message)" 'ERR' }
    }
    Remove-TweakState $id
    return $true
}

# ---- CACHEO DE TESTS ----
# Varios Test lentos repiten la MISMA consulta externa dentro de una sola pasada de
# Refresh (bcdedit, Get-NetTCPSetting, Get-ProcessMitigation). Get-AXECache memoiza por
# pasada: $script:tCache se vacia al arrancar cada Refresh-States (y tras Apply/Revert,
# que disparan Refresh), asi el valor NUNCA queda obsoleto respecto al estado real.
$script:tCache = @{}
# Topologia HW (lista de dispositivos PnP): inmutable durante la sesion => cache PERMANENTE, en
# un store aparte. El bit mutable (registro MSISupported/DevicePriority) se sigue leyendo fresco
# con Get-RV en cada Test; aqui solo se cachea la ENUMERACION cara de CIM.
$script:hwTopoCache = @{}
# Antes esto eran DOS funciones byte a byte identicas (Get-AXECache / Get-AXEHwCache) que solo se
# diferenciaban en el hashtable de respaldo. Ahora es una con -Permanent.
#   Los dos stores siguen SEPARADOS a posta: $tCache se vacia al arrancar cada Refresh-States
# (57-gui-handlers:62) para que ningun Test devuelva estado obsoleto despues de un Apply/Revert,
# y $hwTopoCache no se vacia nunca. Fundirlos en un solo diccionario haria que cada Refresh
# tirase la enumeracion PnP cara, o peor, que la topologia sobreviviese donde no debe.
function Get-AXECache {
    param([string]$Key,[scriptblock]$Producer,[switch]$Permanent)
    if($Permanent){
        if($null -eq $script:hwTopoCache){ $script:hwTopoCache=@{} }
        if($script:hwTopoCache.ContainsKey($Key)){ return $script:hwTopoCache[$Key] }
        $v = & $Producer
        $script:hwTopoCache[$Key] = $v
        return $v
    }
    if($null -eq $script:tCache){ $script:tCache=@{} }
    if($script:tCache.ContainsKey($Key)){ return $script:tCache[$Key] }
    $v = & $Producer
    $script:tCache[$Key] = $v
    return $v
}



# >>>>> MODULE: 15-startup.ps1 >>>>>
# =====================================================
# REGION 4 - STARTUP BACKUP/RESTORE  (FIX C1)
# Array tipado + serializacion robusta + Restore-Autorun (antes inexistente)
# =====================================================
$script:RunKeys = [ordered]@{
    'HKCU'  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'HKLM'  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'WOW64' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
}
function Read-StartupBackup {
    # Lee el JSON como array SIEMPRE (corregible y robusto ante formato corrupto/heredado)
    if(-not(Test-Path $script:RunBak)){ return @() }
    $raw = Get-Content $script:RunBak -Raw -Encoding UTF8
    if([string]::IsNullOrWhiteSpace($raw)){ return @() }
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        # Normalizar a array SIEMPRE (@(...) envuelve objeto suelto o deja array tal cual)
        return @($obj)
    } catch { return @() }
}
function Get-Autoruns {
    $list = New-Object System.Collections.ArrayList
    foreach($k in $script:RunKeys.Keys){
        $p = $script:RunKeys[$k]; if(-not(Test-Path $p)){ continue }
        $item = Get-Item $p
        foreach($n in $item.GetValueNames()){
            [void]$list.Add([pscustomobject]@{Hive=$k; Path=$p; Name=$n; Value=$item.GetValue($n)})
        }
    }
    $list
}
function Disable-Autorun($entry){
    $bak = [System.Collections.ArrayList]@(Read-StartupBackup)
    [void]$bak.Add([pscustomobject]@{Hive=$entry.Hive; Path=$entry.Path; Name=$entry.Name; Value=$entry.Value})
    $bak.ToArray() | ConvertTo-Json -Depth 5 | Set-Content $script:RunBak -Encoding UTF8
    Remove-ItemProperty $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
    Write-AXELog "Startup desactivado: $($entry.Name) (backup guardado)"
}
function Restore-Autorun {
    # FIX C1: funcion que antes NO existia. Restaura todos los autoruns del backup.
    $bak = Read-StartupBackup
    if($bak.Count -eq 0){ Write-AXELog 'No hay startup en backup.' 'WARN'; return 0 }
    $restored = 0
    foreach($e in $bak){
        try {
            if(-not(Test-Path $e.Path)){ New-Item -Path $e.Path -Force | Out-Null }
            New-ItemProperty -Path $e.Path -Name $e.Name -Value $e.Value -PropertyType String -Force | Out-Null
            $restored++
            Write-AXELog "Startup restaurado: $($e.Name)"
        } catch { Write-AXELog "No pude restaurar $($e.Name): $($_.Exception.Message)" 'ERR' }
    }
    if($restored -gt 0){ Remove-Item $script:RunBak -ErrorAction SilentlyContinue }
    Write-AXELog "$restored autorun(s) restaurado(s)."
    return $restored
}
function Repair-StartupBackup {
    # Migra el JSON corrupto heredado (objeto anidado con value/Count) a array plano.
    if(-not(Test-Path $script:RunBak)){ return 0 }
    $raw = Get-Content $script:RunBak -Raw -Encoding UTF8
    $clean = New-Object System.Collections.ArrayList
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $candidates = @()
        if($obj -is [array]){ $candidates = $obj } else { $candidates = @($obj) }
        foreach($c in $candidates){
            # Objeto valido: tiene Hive, Path, Name
            if($c.PSObject.Properties['Hive'] -and $c.PSObject.Properties['Path'] -and $c.PSObject.Properties['Name']){
                [void]$clean.Add([pscustomobject]@{Hive=$c.Hive; Path=$c.Path; Name=$c.Name; Value=$c.Value})
                continue
            }
            # Formato heredado corrupto: el dato real puede estar bajo 'value' (array)
            if($c.PSObject.Properties['value'] -and $c.value){
                foreach($inner in @($c.value)){
                    if($inner.PSObject.Properties['Hive'] -and $inner.PSObject.Properties['Path']){
                        [void]$clean.Add([pscustomobject]@{Hive=$inner.Hive; Path=$inner.Path; Name=$inner.Name; Value=$inner.Value})
                    }
                }
            }
        }
    } catch {
        Write-AXELog "startup_disabled.json corrupto: $($_.Exception.Message). Renombrado a .corrupt" 'ERR'
        try { Move-Item $script:RunBak "$($script:RunBak).corrupt" -Force -EA Stop } catch {}
        return 0
    }
    if($clean.Count -eq 0){ return 0 }
    $clean.ToArray() | ConvertTo-Json -Depth 5 | Set-Content $script:RunBak -Encoding UTF8
    return $clean.Count
}



# >>>>> MODULE: 20-tweaks.ps1 >>>>>
# =====================================================
# REGION 5 - CATALOGO DE TWEAKS  (fuente unica de verdad)
# Tier: 0=Seguro 1=Elite 2=EXTREMO(opt-in)
# Schema estricta validada por -SelfTest: Id/Cat/Tier/Reboot/Name/Desc/Requires/Test/Apply/Revert
# =====================================================
$script:CAT = New-Object System.Collections.ArrayList
function Add-Tweak($h){ [void]$script:CAT.Add([pscustomobject]$h) }

$PC    = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
$SP    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$GD    = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$MM    = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$Games = "$SP\Tasks\Games"
# FIX A2: valor CANONICO unico para toda la suite
$W32PS = 38

# --- CPU / SCHEDULER (Tier 1) ---
Add-Tweak @{Id='cpu_prio';Cat='CPU';Tier=2;Reboot=$false;Name='Prioridad ventana activa';Desc="Win32PrioritySeparation=$W32PS (0x26, valor de comunidad; MS solo documenta 0/1/2): el juego en foco manda";Requires=@{};Source='https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-2000-server/cc958314(v=technet.10)';SourceType='official';PlaceboLikely=$true;NotesEng='0x26 quantum/boost combo is community lore; MS documents the foreground-boost mechanism but not this exotic value. Demoted to Tier 2 opt-in. Measure foreground responsiveness before/after; gaming FPS delta typically within noise.';
 Test={(Get-RV $PC 'Win32PrioritySeparation') -eq $W32PS};
 Apply={Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl' 'PriorityControl.reg'; Set-RD $PC 'Win32PrioritySeparation' $W32PS};
 Revert={Set-RD $PC 'Win32PrioritySeparation' 2}}
Add-Tweak @{Id='cpu_mmcss';Cat='CPU';Tier=1;Reboot=$false;Name='Liberar CPU multimedia';Desc='SystemResponsiveness=0: MS reserva un % de CPU a tareas de baja prioridad; a 0 baja al minimo real (10)';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service';SourceType='official';PlaceboLikely=$false;NotesEng='MS documents SystemResponsiveness under the SystemProfile key as the percentage of CPU guaranteed to low-priority tasks. Values not evenly divisible by 10 are rounded down, so 0 lands at the floor and frees the reservation for the foreground multimedia task. Documented mechanism.';
 Test={(Get-RV $SP 'SystemResponsiveness') -eq 0};Apply={Set-RD $SP 'SystemResponsiveness' 0};Revert={Set-RD $SP 'SystemResponsiveness' 20}}
Add-Tweak @{Id='cpu_pthr';Cat='CPU';Tier=1;Reboot=$false;Name='Power Throttling OFF';Desc='Sin limite de frecuencia';Requires=@{AC=$true};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff') -eq 1};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1};Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'}}
Add-Tweak @{Id='cpu_park';Cat='CPU';Tier=1;Reboot=$false;Name='Core Parking OFF';Desc='Nucleos siempre activos';Requires=@{Desktop=$true;NotHybrid=$true};
 Test={ $g=((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActivePowerScheme') -replace '[{}]',''); (Get-RV "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$g\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583" 'ACSettingIndex') -eq 100 };
 Apply={
   # Captura el minimo de nucleos previo. Igual que rend_ultperf, usa powercfg => sin snapshot,
   # asi que el Revert es el UNICO camino de vuelta. Antes escribia 0 hardcodeado, que no es un
   # restore sino una conjetura del default: Windows OCULTA este ajuste en 'powercfg -q' salvo
   # que se desbloquee su atributo, asi que ni comprobando a mano se sabe cual era.
   $sg=((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActivePowerScheme') -replace '[{}]','')
   $cur=(Get-RV "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$sg\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583" 'ACSettingIndex')
   if($null -ne $cur -and $null -eq (Get-RV 'HKCU:\Software\AXE' 'ParkMinCoresPrev')){ Set-RD 'HKCU:\Software\AXE' 'ParkMinCoresPrev' $cur }
   powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100; powercfg -setactive scheme_current};
 Revert={
   $p=(Get-RV 'HKCU:\Software\AXE' 'ParkMinCoresPrev')
   if($null -eq $p){
       # No se capturo (aplicado por una version anterior). NO se inventa un default: escribir 0
       # como antes dejaba el equipo en un estado que quiza nunca tuvo, y encima presentado como
       # "revertido". Mejor no tocar y decirlo.
       Write-AXELog 'cpu_park: no hay valor previo guardado, no revierto (escribir un default supuesto seria peor). Ajusta Core Parking a mano si lo necesitas.' 'WARN'
   } else {
       powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 $p; powercfg -setactive scheme_current
       Del-RV 'HKCU:\Software\AXE' 'ParkMinCoresPrev'
   }}}
Add-Tweak @{Id='cpu_fth';Cat='CPU';Tier=1;Reboot=$false;Name='FTH OFF (micro-tirones)';Desc='Desactiva Fault Tolerant Heap';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 0};Revert={Set-RD 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 1}}
Add-Tweak @{Id='cpu_dyntick';Cat='CPU';Tier=1;Reboot=$true;Name='Dynamic Tick OFF';Desc='Timer constante, menos jitter (REINICIO)';Requires=@{};
 Test={ ((Get-AXECache 'bcd' { bcdedit /enum '{current}' | Out-String }) -match 'disabledynamictick\s+Yes') };Apply={bcdedit /set disabledynamictick yes | Out-Null};Revert={bcdedit /deletevalue disabledynamictick | Out-Null}}
Add-Tweak @{Id='cpu_tsc';Cat='CPU';Tier=1;Reboot=$true;Name='TSC Sync Enhanced';Desc='Sincroniza contador de tiempo entre nucleos (REINICIO)';Requires=@{};
 Test={ ((Get-AXECache 'bcd' { bcdedit /enum '{current}' | Out-String }) -match 'tscsyncpolicy\s+Enhanced') };Apply={bcdedit /set tscsyncpolicy Enhanced | Out-Null};Revert={bcdedit /deletevalue tscsyncpolicy | Out-Null}}

# --- LATENCIA / INPUT LAG (Tier 1) ---
Add-Tweak @{Id='lat_msi_audio';Cat='LATENCIA';Tier=1;Reboot=$true;Name='MSI mode en HD Audio';Desc='Baja DPC latency del audio';Requires=@{};
 Test={ $hd=Get-AXECache 'pnp:hda' { Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%High Definition Audio%'" -EA SilentlyContinue | Where-Object PNPDeviceID -like 'PCI*' } -Permanent; if(-not $hd){return $true}; $ok=$true; foreach($d in $hd){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"; if((Get-RV $p 'MSISupported') -ne 1){$ok=$false} }; $ok };
 Apply={ $hd=Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%High Definition Audio%'" -EA SilentlyContinue | Where-Object PNPDeviceID -like 'PCI*'; foreach($d in $hd){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"; Set-RD $p 'MSISupported' 1 } };
 Revert={ $hd=Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%High Definition Audio%'" -EA SilentlyContinue | Where-Object PNPDeviceID -like 'PCI*'; foreach($d in $hd){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"; Del-RV $p 'MSISupported' } }}
Add-Tweak @{Id='lat_mouse';Cat='LATENCIA';Tier=1;Reboot=$false;Name='Aceleracion de raton OFF';Desc='Movimiento 1:1, sin curva de Windows';Requires=@{};
 Test={(Get-RV 'HKCU:\Control Panel\Mouse' 'MouseSpeed') -eq '0'};
 Apply={Set-RS 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0'; Set-RS 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0'; Set-RS 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0'};
 Revert={Set-RS 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '1'; Set-RS 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '6'; Set-RS 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '10'}}
Add-Tweak @{Id='lat_faststart';Cat='LATENCIA';Tier=1;Reboot=$false;Name='Fast Startup OFF';Desc='Arranque limpio, menos estados corruptos';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled') -eq 0};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0};Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 1}}
Add-Tweak @{Id='lat_irq_gpu';Cat='LATENCIA';Tier=1;Reboot=$true;Name='IRQ priority alta en GPU';Desc='DevicePriority=3 en la GPU (REINICIO)';Requires=@{};
 Test={ $g=Get-AXECache 'pnp:disp' { Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' } } -Permanent; if(-not $g){return $true}; $ok=$true; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; if((Get-RV $p 'DevicePriority') -ne 3){$ok=$false} }; $ok };
 Apply={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; Set-RD $p 'DevicePriority' 3 } };
 Revert={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; Del-RV $p 'DevicePriority' } }}
Add-Tweak @{Id='lat_msi_gpu';Cat='LATENCIA';Tier=1;Reboot=$true;Name='MSI mode en GPU';Desc='Message Signaled Interrupts en la GPU: baja DPC latency (REINICIO)';Requires=@{};
 Test={ $g=Get-AXECache 'pnp:disp' { Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' } } -Permanent; if(-not $g){return $true}; $ok=$true; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"; if((Get-RV $p 'MSISupported') -ne 1){$ok=$false} }; $ok };
 Apply={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"; Set-RD $p 'MSISupported' 1 } };
 Revert={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"; Del-RV $p 'MSISupported' } }}
Add-Tweak @{Id='lat_timerres';Cat='LATENCIA';Tier=1;Reboot=$true;Name='Timer resolution global (Win11)';Desc='El request de alta resolucion del juego aplica a TODO el sistema (baja DPC). Win11 lo aisla por-proceso por defecto (REINICIO). Posible interaccion con anti-cheat: no confirmado';Requires=@{WinVer=@(11)};Source='https://github.com/valleyofdoom/TimerResolution';SourceType='community-measured';PlaceboLikely=$false;NotesEng='Restores Win10-style global timer honoring on Win11 2004+ (read by ntoskrnl at kernel init, reboot required). Community-measured DPC/latency effect (valleyofdoom). Possible anti-cheat interaction: possible, not confirmed. Measure jitter before/after AFTER reboot.';
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests') -eq 1};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 1};
 Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests'}}

# --- GPU (Tier 1) ---
Add-Tweak @{Id='gpu_hags';Cat='GPU';Tier=1;Reboot=$true;Name='HAGS (scheduling por hardware)';Desc='GPU gestiona su cola, menos latencia (REINICIO)';Requires=@{HAGS=$true};
 Test={(Get-RV $GD 'HwSchMode') -eq 2};Apply={Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'GraphicsDrivers.reg'; Set-RD $GD 'HwSchMode' 2};Revert={Del-RV $GD 'HwSchMode'}}
Add-Tweak @{Id='gpu_mmcss';Cat='GPU';Tier=1;Reboot=$false;Name='Prioridad MMCSS juegos';Desc='Scheduling Category=High sube el hilo del juego a la banda 23-26. OJO: de los 3 valores clasicos, solo este hace algo (ver NotesEng)';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service';SourceType='official';PlaceboLikely=$false;NotesEng='Partially inert by MS design, documented on the MMCSS page: (1) "GPU Priority ... This priority is not yet used"; (2) "For tasks with a Scheduling Category of High, this value [Priority] is always treated as 2" - so Priority=6 is overridden. Only Scheduling Category=High does real work: it moves the task into the 23-26 thread-priority band. Kept at Tier 1 because that one value is a documented, real mechanism; the other two are preserved for parity with the community preset and are harmless no-ops.';
 Test={((Get-RV $Games 'GPU Priority') -eq 8) -and ((Get-RV $Games 'Priority') -eq 6) -and ((Get-RV $Games 'Scheduling Category') -eq 'High')};
 Apply={Set-RD $Games 'GPU Priority' 8;Set-RD $Games 'Priority' 6;Set-RS $Games 'Scheduling Category' 'High';Set-RS $Games 'SFIO Priority' 'High';Set-RS $Games 'Background Only' 'False'};
 # OJO: este Revert es solo el FALLBACK. La via normal es Restore-TweakState, que devuelve los
 # valores REALES capturados por Set-RD/Set-RS al aplicar (10-reg-helpers). Aqui se llega unicamente
 # si no hay snapshot: tweak aplicado por una version anterior de AXE, o a mano fuera de AXE.
 #   Antes este fallback BORRABA 'Scheduling Category', 'SFIO Priority' y 'Background Only'. La
 # tarea Games de Windows trae esos valores de fabrica (verificado en el registro: Affinity,
 # Background Only, Clock Rate, GPU Priority, Priority, Scheduling Category, SFIO Priority), asi
 # que borrarlos no restaura nada: deja la tarea sin claves que el sistema espera encontrar.
 #   Se restaura solo 'Priority'=2, que es el valor que MS documenta para esta tarea. Los otros
 # tres NO se tocan: sus valores de fabrica no estan registrados en ningun sitio y escribir una
 # suposicion es justo el fallo que se esta corrigiendo. Se avisa para que no parezca completo.
 #   'GPU Priority' ya no se reescribe: Apply lo deja en 8, que es lo que ya valia.
 Revert={
   Set-RD $Games 'Priority' 2
   Write-AXELog "gpu_mmcss: revertido parcial (sin snapshot). 'Priority' restaurado a 2; 'Scheduling Category', 'SFIO Priority' y 'Background Only' quedan como estan porque no se capturo su valor original." 'WARN'}}
Add-Tweak @{Id='gpu_ulps';Cat='GPU';Tier=1;Reboot=$true;Name='NVIDIA ULPS OFF';Desc='GPU no entra en bajo consumo profundo (REINICIO)';Requires=@{Nvidia=$true};
 Test={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; $sub=Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' }; if(-not $sub){return $true}; $ok=$true; foreach($s in $sub){ if((Get-RV $s.PSPath 'EnableUlps') -ne 0){$ok=$false} }; $ok };
 Apply={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' } | ForEach-Object { Set-RD $_.PSPath 'EnableUlps' 0 } };
 Revert={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' } | ForEach-Object { Del-RV $_.PSPath 'EnableUlps' } }}
Add-Tweak @{Id='gpu_tdr';Cat='GPU';Tier=1;Reboot=$true;Name='TDR delay ampliado';Desc='Menos cuelgues de driver bajo carga (REINICIO)';Requires=@{};
 Test={(Get-RV $GD 'TdrDelay') -eq 10};Apply={Set-RD $GD 'TdrDelay' 10};Revert={Del-RV $GD 'TdrDelay'}}
Add-Tweak @{Id='gpu_vrr';Cat='GPU';Tier=1;Reboot=$true;Name='Optimizaciones para juegos con ventana';Desc='VRR + optimizaciones de ventana (REINICIO)';Requires=@{};
 Test={(Get-RV $GD 'VRROptimizeEnable') -eq 1};Apply={Set-RD $GD 'VRROptimizeEnable' 1};Revert={Del-RV $GD 'VRROptimizeEnable'}}

# --- RED (Tier 1) ---
Add-Tweak @{Id='net_throttle';Cat='RED';Tier=1;Reboot=$false;Name='Network Throttling OFF';Desc='Sin limite de paquetes con multimedia. MMCSS limita a 10 paq/ms cuando hay reproduccion; 0xFFFFFFFF lo desactiva. Default MS = 10';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service';
 Test={(Get-RV $SP 'NetworkThrottlingIndex') -eq 4294967295};Apply={Set-RD $SP 'NetworkThrottlingIndex' 4294967295};Revert={Del-RV $SP 'NetworkThrottlingIndex'}}
Add-Tweak @{Id='net_nagle';Cat='RED';Tier=2;Reboot=$false;Name='Nagle OFF (adaptador activo)';Desc='TcpAckFrequency=1 + TCPNoDelay=1. Placebo probable en NIC modernas con offload NDIS; MS no recomienda cambiarlo sin estudio';Requires=@{};Source='https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/registry-entry-control-tcp-acknowledgment-behavior';SourceType='official';PlaceboLikely=$true;NotesEng='Disabling delayed ACK / Nagle rarely helps on modern hardware with NDIS offload and can hurt bulk throughput. MS: do not change the default without careful study. Demoted to Tier 2 opt-in. Measure ping/jitter before/after.';
 # Test = TODAS las interfaces con IP, no "alguna". Apply escribe en todas, asi que con $any
 # bastaba una para dar el tweak por aplicado: si anadias un segundo NIC despues, seguia
 # diciendo aplicado mientras el nuevo se quedaba sin tocar.
 Test={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -EA SilentlyContinue
        $n=0; $ok=0
        foreach($i in $ifs){ $p=Get-ItemProperty $i.PSPath -EA SilentlyContinue; if($p.DhcpIPAddress -or $p.IPAddress){ $n++; if((Get-RV $i.PSPath 'TcpAckFrequency') -eq 1 -and (Get-RV $i.PSPath 'TCPNoDelay') -eq 1){$ok++} } }
        ($n -gt 0 -and $ok -eq $n) };
 Apply={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'; foreach($i in $ifs){ $p=Get-ItemProperty $i.PSPath -EA SilentlyContinue; if($p.DhcpIPAddress -or $p.IPAddress){ Set-RD $i.PSPath 'TcpAckFrequency' 1; Set-RD $i.PSPath 'TCPNoDelay' 1 } } };
 Revert={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'; foreach($i in $ifs){ Del-RV $i.PSPath 'TcpAckFrequency'; Del-RV $i.PSPath 'TCPNoDelay' } }}
Add-Tweak @{Id='net_rss';Cat='RED';Tier=1;Reboot=$false;Name='RSS activado';Desc='Reparte trafico de red entre nucleos. NO-OP EN LA MAYORIA: RSS viene activado de fabrica en Windows 10/11 (medido aqui: ya Enabled). Solo sirve si algo lo apago antes';Requires=@{};Source='https://learn.microsoft.com/en-us/windows-hardware/drivers/network/introduction-to-receive-side-scaling';
 Test={try{(Get-NetOffloadGlobalSetting -EA Stop).ReceiveSideScaling -eq 'Enabled'}catch{$false}};Apply={netsh interface tcp set global rss=enabled | Out-Null};Revert={netsh interface tcp set global rss=default | Out-Null}}
Add-Tweak @{Id='net_ctcp';Cat='RED';Tier=1;Reboot=$false;Name='CTCP (congestion gaming)';Desc='OJO: CUBIC es el default de Windows desde 10 1709 y es MAS moderno que CTCP. Esto RETROCEDE la plantilla Internet a un algoritmo viejo. No lo actives sin medir que te mejora';Requires=@{};Source='https://learn.microsoft.com/en-us/powershell/module/nettcpip/set-nettcpsetting';
 Test={ $t=Get-AXECache 'nettcp' { try{Get-NetTCPSetting -SettingName Internet -EA Stop}catch{$null} }; if(-not $t){$false}else{$t.CongestionProvider -eq 'CTCP'} };Apply={netsh int tcp set supplemental template=internet congestionprovider=ctcp | Out-Null};
 # Revert a 'default' y no a 'cubic' hardcodeado: deja que Windows ponga el algoritmo que
 # corresponda a la version, en vez de fijar el que HOY es el default. Mismo fallo de clase que
 # los reverts con valor supuesto, en pequeno.
 Revert={netsh int tcp set supplemental template=internet congestionprovider=default | Out-Null}}
Add-Tweak @{Id='net_ecn';Cat='RED';Tier=1;Reboot=$false;Name='ECN OFF';Desc='Evita conflictos con routers viejos. NO-OP EN LA MAYORIA: ECN ya viene Disabled de fabrica en Win10/11 (medido aqui: Disabled en las 3 plantillas)';Requires=@{};Source='https://learn.microsoft.com/en-us/powershell/module/nettcpip/set-nettcpsetting';
 Test={ $t=Get-AXECache 'nettcp' { try{Get-NetTCPSetting -SettingName Internet -EA Stop}catch{$null} }; if(-not $t){$false}else{$t.EcnCapability -eq 'Disabled'} };Apply={netsh int tcp set global ecncapability=disabled | Out-Null};Revert={netsh int tcp set global ecncapability=default | Out-Null}}
Add-Tweak @{Id='net_qos';Cat='RED';Tier=1;Reboot=$true;Name='QoS sin reserva de banda';Desc='NonBestEffortLimit=0 (REINICIO). EFECTO DISCUTIDO: la reserva del 20% solo la consumen apps que usan la API de QoS; si ninguna reserva, el ancho ya esta disponible. Ganancia probable ~0 en un PC domestico';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-admx-qos';
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit'}}
Add-Tweak @{Id='net_intmod';Cat='RED';Tier=1;Reboot=$false;Name='Interrupt Moderation NIC OFF';Desc='Menos buffering en el adaptador activo. COMPROMISO REAL: baja latencia a cambio de MAS uso de CPU por interrupciones. En CPU justa puede salir peor';Requires=@{NicProp='*InterruptModeration'};Source='https://learn.microsoft.com/en-us/windows-server/networking/technologies/network-subsystem/net-sub-performance-tuning-nics';
 # El catch de antes devolvia $true: CUALQUIER error al leer la propiedad se reportaba como
 # "aplicado", y ademas sumaba en TweaksOn del score. Un fallo silencioso presentado como exito.
 # Ahora se distingue: si el adaptador no expone la propiedad no hay nada que aplicar (true
 # vacuo, correcto); si la expone se lee su valor real. Sin rama que convierta error en exito.
 # El "true vacuo" de abajo YA NO es lo que ve el usuario: Requires.NicProp saca el tweak de la
 # lista con motivo ("el adaptador X no expone *InterruptModeration") antes de llegar aqui. Se
 # conserva como defensa para las rutas que evaluan el catalogo entero sin gating (-List) y para
 # el hueco entre el arranque de la GUI y la llegada del HW desde el runspace, donde
 # Get-BlockReason retorna $null por no tener hardware que consultar.
 Test={ if(-not $script:HW.NicName){return $true};
        $p=Get-NetAdapterAdvancedProperty -Name $script:HW.NicName -RegistryKeyword '*InterruptModeration' -EA SilentlyContinue
        if($null -eq $p){ return $true }
        # RegistryValue puede venir como String[] (REG_MULTI_SZ) o Get-* devolver varios adaptadores;
        # [int] sobre un array LANZA "Cannot convert System.String[] to System.Int32" (visto en CI).
        # Se toma el primer adaptador y el primer valor, y se acota el cast: no numerico -> false
        # (no aplicado), coherente con la regla de no reportar exito ante un error de lectura.
        $rv=@($p)[0].RegistryValue
        if($rv -is [array]){ $rv=@($rv)[0] }
        try { ([int]$rv -eq 0) } catch { $false } };
 Apply={ if($script:HW.NicName){ Set-NetAdapterAdvancedProperty -Name $script:HW.NicName -RegistryKeyword '*InterruptModeration' -RegistryValue 0 -EA SilentlyContinue } };
 Revert={ if($script:HW.NicName){ Set-NetAdapterAdvancedProperty -Name $script:HW.NicName -RegistryKeyword '*InterruptModeration' -RegistryValue 1 -EA SilentlyContinue } }}
Add-Tweak @{Id='net_dns';Cat='RED';Tier=1;Reboot=$false;Name='[OPT] DNS rapidos 1.1.1.1 / 8.8.8.8';Desc='OJO: rompe DNS local/VPN. No va en preset. Afecta a la RESOLUCION de nombres, no al ping ni al throughput: no da FPS';Requires=@{};Source='https://developers.cloudflare.com/1.1.1.1/';
 Test={ if(-not $script:HW.NicName){return $false}; try{(Get-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -AddressFamily IPv4 -EA Stop).ServerAddresses -contains '1.1.1.1'}catch{$false} };
 Apply={ if($script:HW.NicName){ Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ServerAddresses @('1.1.1.1','8.8.8.8') } };Revert={ if($script:HW.NicName){ Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ResetServerAddresses } }}

# --- MEMORIA (Tier 0/1) ---
Add-Tweak @{Id='mem_pagingexec';Cat='MEMORIA';Tier=1;Reboot=$true;Name='Kernel siempre en RAM';Desc='DisablePagingExecutive=1 (necesita RAM holgada) (REINICIO)';Requires=@{MinRam=16};
 Test={(Get-RV $MM 'DisablePagingExecutive') -eq 1};Apply={Set-RD $MM 'DisablePagingExecutive' 1};Revert={Set-RD $MM 'DisablePagingExecutive' 0}}
Add-Tweak @{Id='mem_ntfsmem';Cat='MEMORIA';Tier=1;Reboot=$true;Name='Cache de metadatos NTFS alta';Desc='NtfsMemoryUsage=2 (REINICIO)';Requires=@{MinRam=12};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage') -eq 2};Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage' 2};Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage'}}
Add-Tweak @{Id='mem_lastaccess';Cat='MEMORIA';Tier=0;Reboot=$false;Name='NTFS last-access OFF';Desc='Menos escrituras de metadatos al leer';Requires=@{};
 Test={ (& fsutil behavior query disablelastaccess) -match 'Disabled|= 1' };Apply={fsutil behavior set disablelastaccess 1 | Out-Null};Revert={fsutil behavior set disablelastaccess 0 | Out-Null}}
Add-Tweak @{Id='mem_8dot3';Cat='MEMORIA';Tier=0;Reboot=$false;Name='Nombres 8.3 NTFS OFF';Desc='NtfsDisable8dot3NameCreation=1: Windows deja de generar el alias corto (PROGRA~1) por cada archivo nuevo. Menos trabajo de metadatos en carpetas grandes. Solo afecta archivos NUEVOS';Requires=@{};Source='https://github.com/valleyofdoom/PC-Tuning';SourceType='community-measured';PlaceboLikely=$false;NotesEng='Listed as measured by valleyofdoom PC-Tuning alongside disablelastaccess. NTFS stops generating the legacy short-name alias per new file, cutting metadata work in large directories. Only affects NEW files: existing 8.3 aliases persist, so Revert does not restore aliases lost in between. Risk: 16-bit/legacy installers and old apps that hardcode short paths.';
 Test={ (& fsutil 8dot3name query) -match 'disabled|= 1' };
 Apply={Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' 'FileSystem.reg'; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisable8dot3NameCreation' 1};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisable8dot3NameCreation' 2}}
Add-Tweak @{Id='mem_compression';Cat='MEMORIA';Tier=2;Reboot=$false;Name='Compresion de memoria OFF';Desc='Disable-MMAgent -mc. CONTROVERTIDO: sin compresion, la RAM que no cabe va a DISCO, mucho mas lento que descomprimir. Solo con RAM muy holgada y midiendo antes/despues';Requires=@{MinRam=16};Source='https://learn.microsoft.com/en-us/windows/win32/memory/memory-compression';SourceType='community-measured';PlaceboLikely=$true;NotesEng='Memory compression trades a little CPU for avoiding disk paging, and disk paging is orders of magnitude slower than decompressing a page. Disabling only helps if the working set genuinely never approaches physical RAM; otherwise it converts cheap decompression into expensive hard faults. The MinRam=16 gate is necessary but NOT sufficient: a 16GB machine running a modern AAA title plus a browser can still exceed it. Demoted from Tier 1 to Tier 2 opt-in. Measure hard faults/sec and 1% lows before/after.';
 Test={ try{ (Get-MMAgent -EA Stop).MemoryCompression -eq $false }catch{ $false } };
 Apply={ Disable-MMAgent -mc -EA SilentlyContinue };Revert={ Enable-MMAgent -mc -EA SilentlyContinue }}

# --- DISCO (Tier 0) ---
# Categoria deliberadamente CORTA. El folclore de "optimizar el SSD" es casi todo falso en Win10/11:
# el defrag programado YA detecta SSD y manda retrim en vez de desfragmentar, asi que desactivarlo
# no acelera nada y ademas quita el retrim. Lo unico accionable que queda es comprobar que nadie
# haya apagado TRIM. NTFS last-access y 8.3 ya viven en MEMORIA (mem_lastaccess / mem_8dot3): no se
# duplican aqui solo para engordar el contador de una categoria.
Add-Tweak @{Id='dsk_trim';Cat='DISCO';Tier=0;Reboot=$false;Name='TRIM activado (SSD)';Desc='DisableDeleteNotify=0. NO es una optimizacion: es comprobar que ningun tweaker lo apago. Sin TRIM el SSD se degrada segun se llena. En HDD es inocuo';Requires=@{};Source='https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/fsutil-behavior';SourceType='official';PlaceboLikely=$false;NotesEng='DisableDeleteNotify=0 keeps the TRIM/UNMAP hint enabled so the SSD controller can reclaim freed blocks. Some "optimizer" presets disable it under the myth that it costs latency; the real cost is write amplification and degraded steady-state performance. This entry exists to DETECT and undo that, not to speed anything up. Zero FPS effect by design.';
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotify') -eq 0};
 Apply={Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' 'FileSystem.reg'; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotify' 0};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotify' 1}}

# --- AUDIO (Tier 2) ---
Add-Tweak @{Id='aud_protectedaudio';Cat='AUDIO';Tier=2;Reboot=$true;Name='Protected Audio DG OFF';Desc='Quita el grafo de audio protegido (DRM) (REINICIO). EFECTO DISCUTIDO: la ganancia de latencia no esta medida y ROMPE reproduccion DRM (Netflix, Spotify app). Opt-in consciente';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/win32/medfound/protected-media-path';SourceType='community-lore';PlaceboLikely=$true;NotesEng='DisableProtectedAudioDG=1 stops audiodg.exe from loading the Protected Media Path graph. Community tweak lists claim lower audio DPC latency; no measured evidence found. Known cost is concrete: DRM-protected playback (Netflix, Spotify desktop, some Blu-ray software) can drop to silence or refuse to play. Tier 2 and PlaceboLikely=true on purpose: a real, documented downside against an unmeasured upside. Measure audio DPC before/after or leave it off.';
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio' 'DisableProtectedAudioDG') -eq 1};
 Apply={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio' 'DisableProtectedAudioDG' 1};
 Revert={Del-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Audio' 'DisableProtectedAudioDG'}}

# --- ENERGIA (Tier 1) ---
# Solo entra lo que se pudo VERIFICAR con 'powercfg /query' en maquina real. EPP (PERFEPP) y
# PCIe ASPM quedan fuera a posta: en este equipo estan ocultos por atributo y escribir un GUID
# que no se ha visto responder es exactamente la clase de conjetura que el catalogo no admite.
Add-Tweak @{Id='pwr_usbsuspend';Cat='ENERGIA';Tier=1;Reboot=$false;Name='USB selective suspend OFF';Desc='Windows deja de dormir los puertos USB: raton y teclado no pagan el coste de despertar. Sube algo el consumo en reposo';Requires=@{AC=$true};Source='https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/usb-selective-suspend';SourceType='official';PlaceboLikely=$false;NotesEng='Selective suspend lets the USB hub driver idle a port whose device is inactive. Waking it costs latency on the first event after idle, which is what input devices hit between menus and gameplay. Documented mechanism, GUIDs verified with powercfg /query on the target machine (subgroup 2a737441-1930-4402-8d77-b2bebba308a3, setting 48e6b7a6-50f5-4782-a5d4-53bb8f07e226, 0=Disabled). Uses powercfg, so Test-SnapEligible excludes it from the snapshot store and the previous index is captured to HKCU:\Software\AXE, same contract as cpu_park.';
 Test={ $g=((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActivePowerScheme') -replace '[{}]',''); (Get-RV "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$g\2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226" 'ACSettingIndex') -eq 0 };
 Apply={
   $sg=((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActivePowerScheme') -replace '[{}]','')
   $cur=(Get-RV "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$sg\2a737441-1930-4402-8d77-b2bebba308a3\48e6b7a6-50f5-4782-a5d4-53bb8f07e226" 'ACSettingIndex')
   if($null -ne $cur -and $null -eq (Get-RV 'HKCU:\Software\AXE' 'UsbSuspendPrev')){ Set-RD 'HKCU:\Software\AXE' 'UsbSuspendPrev' $cur }
   powercfg -setacvalueindex scheme_current 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0; powercfg -setactive scheme_current};
 Revert={
   $p=(Get-RV 'HKCU:\Software\AXE' 'UsbSuspendPrev')
   if($null -eq $p){
       Write-AXELog 'pwr_usbsuspend: no hay valor previo guardado, no revierto (escribir un default supuesto seria peor). Ajusta la suspension selectiva USB a mano si lo necesitas.' 'WARN'
   } else {
       powercfg -setacvalueindex scheme_current 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 $p; powercfg -setactive scheme_current
       Del-RV 'HKCU:\Software\AXE' 'UsbSuspendPrev'
   }}}

# --- SISTEMA (Tier 0/1) ---
Add-Tweak @{Id='sys_gamedvr';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Game DVR OFF';Desc='Sin grabacion de fondo = mas FPS';Requires=@{};
 Test={(Get-RV 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0};
 Apply={Set-RD 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0; Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0};
 Revert={Set-RD 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1; Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'}}
Add-Tweak @{Id='sys_fse';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Fullscreen exclusivo (FSE)';Desc='GameDVR_FSEBehavior=2';Requires=@{};
 Test={(Get-RV 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior') -eq 2};Apply={Set-RD 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2};Revert={Del-RV 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior'}}
Add-Tweak @{Id='sys_gamebar';Cat='SISTEMA';Tier=1;Reboot=$false;Name='GameBar minimizada';Desc='Sin panel de inicio ni overlay Nexus';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel') -eq 0};
 Apply={Set-RD 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0; Set-RD 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0};
 Revert={Set-RD 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 1; Set-RD 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 1}}
Add-Tweak @{Id='sys_hibernate';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Hibernacion OFF';Desc='Libera hiberfil.sys (portatil pierde hibernar)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled') -eq 0};Apply={powercfg /h off};Revert={powercfg /h on}}
Add-Tweak @{Id='sys_do';Cat='SISTEMA';Tier=0;Reboot=$false;Name='Delivery Optimization P2P OFF';Desc='DODownloadMode=0 (HTTP Only): no compartes updates con otros PCs, las descargas siguen funcionando';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/deployment/do/waas-delivery-optimization-reference';SourceType='official';PlaceboLikely=$false;NotesEng='MS documents mode 0 as "HTTP Only": disables peer-to-peer caching but still allows Delivery Optimization to download over HTTP from the original source or a Connected Cache server. Default is LAN (1). Note MS deprecates Bypass (100) in Win11 and explicitly says to use 0 to disable P2P - which is what this tweak does.';
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode') -eq 0};   # FIX A2: policy key correcta
 Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode'}}
Add-Tweak @{Id='sys_bing';Cat='SISTEMA';Tier=0;Reboot=$false;Name='Busqueda sin Bing';Desc='Menu inicio sin resultados web';Requires=@{};
 Test={(Get-RV 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled') -eq 0};
 Apply={Set-RD 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0};Revert={Del-RV 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled'}}
Add-Tweak @{Id='sys_longpaths';Cat='SISTEMA';Tier=0;Reboot=$true;Name='Rutas largas ON';Desc='Soporta rutas >260 caracteres (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled') -eq 1};Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1};Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 0}}
Add-Tweak @{Id='sys_autoend';Cat='SISTEMA';Tier=1;Reboot=$false;Name='AutoEndTasks ON';Desc='Apagado mas rapido con apps colgadas';Requires=@{};
 Test={(Get-RV 'HKCU:\Control Panel\Desktop' 'AutoEndTasks') -eq '1'};Apply={Set-RS 'HKCU:\Control Panel\Desktop' 'AutoEndTasks' '1'};Revert={Del-RV 'HKCU:\Control Panel\Desktop' 'AutoEndTasks'}}
Add-Tweak @{Id='sys_menudelay';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Menus instantaneos';Desc='MenuShowDelay 0';Requires=@{};
 Test={(Get-RV 'HKCU:\Control Panel\Desktop' 'MenuShowDelay') -eq '0'};Apply={Set-RS 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0'};Revert={Set-RS 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '400'}}
Add-Tweak @{Id='sys_startdelay';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Sin retardo de apps al inicio';Desc='StartupDelayInMSec=0';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec') -eq 0};Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0};Revert={Del-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec'}}

# --- RENDIMIENTO (Tier 1) ---
Add-Tweak @{Id='rend_gamemode';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Game Mode ON';Desc='Prioriza recursos al juego en primer plano';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled') -eq 1};
 Apply={Set-RD 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1; Set-RD 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1};Revert={Set-RD 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0}}
Add-Tweak @{Id='rend_visualfx';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Efectos visuales: rendimiento';Desc='Quita animaciones/sombras';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting') -eq 2};Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2};Revert={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 0}}
Add-Tweak @{Id='rend_mpo';Cat='RENDIMIENTO';Tier=1;Reboot=$true;Name='MPO OFF (arregla stutter/flicker)';Desc='Desactiva Multi-Plane Overlay del DWM (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode') -eq 5};Apply={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5};Revert={Del-RV 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode'}}
Add-Tweak @{Id='rend_prefetch';Cat='RENDIMIENTO';Tier=2;Reboot=$true;Name='Prefetch/Superfetch OFF';Desc='EnablePrefetcher/EnableSuperfetch=0. Con SSD Windows ya lo autogestiona; MS avisa "may negatively impact". Sin gate de SSD -> opt-in (REINICIO)';Requires=@{};Source='https://www.tomshardware.com/reviews/ssd-performance-tweak,2911-5.html';SourceType='community-measured';PlaceboLikely=$true;NotesEng='Modern Windows auto-manages prefetch/SysMain for SSDs; disabling gives ~0 benefit and MS warns it may hurt. No SSD-gating infra in Get-BlockReason, so demoted to Tier 2 opt-in instead of a false Tier 1 SSD claim. Measure app cold-launch before/after.';
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher') -eq 0};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 0};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 3; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 3}}
Add-Tweak @{Id='rend_ultperf';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Plan energia Ultimate Performance';Desc='Evita downclock de CPU en idle. OJO: mas consumo/calor (mejor en sobremesa/enchufado)';Requires=@{};
 Test={$g=(Get-RV 'HKCU:\Software\AXE' 'UltPerfGuid'); if(-not $g){$false}else{[bool]((powercfg /getactivescheme) -match [regex]::Escape($g))}};
 Apply={
   # Captura el plan ACTIVO antes de cambiarlo. Este tweak usa powercfg, luego Test-SnapEligible
   # lo excluye del snapshot: sin esta captura no hay NADA de donde restaurar, y el Revert
   # forzaba Equilibrado a ciegas -- quien viniera de Alto Rendimiento o de un plan del
   # fabricante acababa en otro plan sin que nadie se lo dijera.
   $g=(Get-RV 'HKCU:\Software\AXE' 'UltPerfGuid')
   if(-not (Get-RV 'HKCU:\Software\AXE' 'PrevPlanGuid')){
       $cur=[regex]::Match(((powercfg /getactivescheme) | Out-String),'[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
       # Si ya estabas en el plan que crea este tweak (re-aplicar), guardarlo seria guardar el
       # destino como origen y el Revert no te llevaria a ninguna parte.
       if($cur -and $cur -ne $g){ Set-RS 'HKCU:\Software\AXE' 'PrevPlanGuid' $cur }
   }
   if(-not $g){ $o=(powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String); $g=[regex]::Match($o,'[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value; if(-not $g){$g='e9a42b02-d5df-448d-aa00-03f14749eb61'}; Set-RS 'HKCU:\Software\AXE' 'UltPerfGuid' $g }
   powercfg /setactive $g | Out-Null};
 Revert={
   $g=(Get-RV 'HKCU:\Software\AXE' 'UltPerfGuid')
   $prev=(Get-RV 'HKCU:\Software\AXE' 'PrevPlanGuid')
   # Sin plan capturado (aplicado por una version anterior de AXE) se cae a Equilibrado. Es una
   # CONJETURA, no un restore, y se dice en el log en vez de fingir que se devolvio el original.
   if(-not $prev){ $prev='381b4222-f694-41f0-9685-ff5bb260df2e'; Write-AXELog 'rend_ultperf: no habia plan previo guardado; activo Equilibrado (default de Windows), que puede no ser el que tenias.' 'WARN' }
   powercfg /setactive $prev | Out-Null
   # Borrar DESPUES de activar otro: powercfg no puede borrar el esquema activo.
   if($g){ powercfg -delete $g 2>$null | Out-Null; Del-RV 'HKCU:\Software\AXE' 'UltPerfGuid' }
   Del-RV 'HKCU:\Software\AXE' 'PrevPlanGuid'}}
Add-Tweak @{Id='rend_bgapps';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Apps en segundo plano OFF';Desc='Apps UWP no corren en background. Libera CPU/RAM en idle';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled') -eq 1};
 Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1; Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0};
 Revert={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 0; Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 1}}

# --- SERVICIOS (Tier 0/1) ---
Add-Tweak @{Id='svc_telemetry';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='Telemetria OFF';Desc='DiagTrack, dmwappushservice, WerSvc';Requires=@{};
 Test={(Get-SvcStart 'DiagTrack') -eq 'Disabled'};Apply={Set-SvcStart 'DiagTrack' 'disabled'; Set-SvcStart 'dmwappushservice' 'disabled'; Set-SvcStart 'WerSvc' 'disabled'};Revert={Set-SvcStart 'DiagTrack' 'auto'; Set-SvcStart 'dmwappushservice' 'demand'; Set-SvcStart 'WerSvc' 'demand'}}
Add-Tweak @{Id='svc_obsolete';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='Servicios obsoletos OFF';Desc='RetailDemo, MapsBroker, Fax (SKU-safe)';Requires=@{};
 Test={(Get-SvcStart 'RetailDemo') -eq 'Disabled'};Apply={'RetailDemo','MapsBroker','Fax'|ForEach-Object{Set-SvcStart $_ 'disabled'}};Revert={Set-SvcStart 'RetailDemo' 'demand'; Set-SvcStart 'MapsBroker' 'demand'; Set-SvcStart 'Fax' 'demand'}}
Add-Tweak @{Id='svc_sysmain';Cat='SERVICIOS';Tier=2;Reboot=$false;Name='Precarga/diagnostico OFF';Desc='SysMain, PcaSvc, DPS. CONTRA RECOMENDACION DE MS: SysMain sigue aportando en SSD (precarga a RAM, que es 100x mas rapida que el SSD). Apagarlo suele SUBIR el tiempo de arranque de apps. Mide antes/despues';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/client-management/manage-windows-11-services';SourceType='official';PlaceboLikely=$true;NotesEng='Microsoft explicitly advises against disabling SysMain. The "SSD makes prefetch pointless" claim confuses the source and destination of the cache: SysMain preloads into RAM, which stays orders of magnitude faster than any NVMe drive, so the benefit survives the move to SSD. Disabling typically increases cold app-launch time, and the freed standby memory is not a gain (free RAM is wasted RAM). DPS additionally powers the network/audio troubleshooters and PcaSvc the Program Compatibility Assistant; both break silently when disabled. Demoted from Tier 1 to Tier 2 opt-in. Measure cold app-launch time before/after, not "free RAM".';
 Test={(Get-SvcStart 'SysMain') -eq 'Disabled'};Apply={'SysMain','PcaSvc','DPS'|ForEach-Object{Set-SvcStart $_ 'disabled'}};Revert={'SysMain','PcaSvc','DPS'|ForEach-Object{Set-SvcStart $_ 'auto'}}}
Add-Tweak @{Id='svc_wsearch';Cat='SERVICIOS';Tier=1;Reboot=$false;Name='Indexacion de busqueda OFF';Desc='WSearch OFF: corta el I/O de disco de fondo del indexador. La busqueda sigue funcionando, solo mas lenta';Requires=@{};
 Test={(Get-SvcStart 'WSearch') -eq 'Disabled'};
 Apply={Set-SvcStart 'WSearch' 'disabled'; Stop-Service 'WSearch' -Force -EA SilentlyContinue};
 Revert={Set-SvcStart 'WSearch' 'auto'; Start-Service 'WSearch' -EA SilentlyContinue}}
Add-Tweak @{Id='svc_hostsplit';Cat='SERVICIOS';Tier=2;Reboot=$true;Name='Agrupar servicios en menos svchost';Desc='Deshace el reparto 1-servicio-por-proceso de Win10 1703+. Ahorra procesos y RAM de sobrecarga, NO da FPS. Precio real: se pierde el aislamiento por servicio que Microsoft puso a posta (un cuelgue se lleva al grupo). Solo se ofrece con RAM justa (REINICIO)';Requires=@{MaxRam=8};Source='https://learn.microsoft.com/en-us/windows/application-management/svchost-service-refactoring';SourceType='official';PlaceboLikely=$true;NotesEng='Windows 10 1703+ hosts each service in its own svchost.exe when physical RAM exceeds the threshold in SvcHostSplitThresholdInKB (MS default 0x380000 = 3.5GB in KB). Raising the threshold above installed RAM restores the pre-1703 grouped hosting. Mechanism VERIFIED on the reference machine rather than assumed: with the threshold above RAM, 92 running services occupy 41 processes with only 2 launched in split form (-k <group> -p -s <service>), and same-group services share a PID (netsvcs 20 services / 3 PIDs, DcomLaunch 7 / 1). The saving is process count and per-process overhead, not frames: PlaceboLikely stays true so this never enters the recommended or latency sets. The cost is the reason MS split them: grouped services lose per-service crash isolation and per-service token hardening. Gated by MaxRam=8 because above that the memory saved is irrelevant and only the downside remains; below ~3.5GB Windows already groups and the tweak is a no-op.';
 # Test pregunta por la REGLA, no por un numero magico: "el umbral configurado fuerza agrupacion
 # en ESTA maquina?". Un -eq contra una constante daria falso en cualquier equipo con otra RAM.
 Test={ $ram=Get-AXECache 'osmem' { try{(Get-CimInstance Win32_OperatingSystem -EA Stop).TotalVisibleMemorySize}catch{$null} }
        if(-not $ram){ return $false }
        $t=Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB'
        ($null -ne $t) -and ([int64]$t -gt [int64]$ram) };
 Apply={ $ram=(Get-CimInstance Win32_OperatingSystem).TotalVisibleMemorySize
         Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' ([int]($ram + 1024)) };
 # Via normal = Restore-TweakState (devuelve el valor REAL previo capturado por Set-RD). Aqui se
 # llega solo sin snapshot; 0x380000 no es una conjetura del default sino el valor que Microsoft
 # documenta en la pagina citada, y se avisa igual porque la maquina podia venir ya modificada
 # por otro optimizador (en la de referencia venia con 137922056, no con el default).
 Revert={
   Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control' 'SvcHostSplitThresholdInKB' 3670016
   Write-AXELog 'svc_hostsplit: revertido al umbral documentado por Microsoft (0x380000 = 3.5GB). Si tu equipo tenia otro valor puesto por otra herramienta, ese no se recupera desde aqui.' 'WARN'}}
# FIX M1: svc_remotereg = hardening UNIDIRECCIONAL documentado (Apply==Revert a posta; no es un toggle falso)
Add-Tweak @{Id='svc_remotereg';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='RemoteRegistry OFF (seguridad)';Desc='Hardening: siempre lo deja disabled (no es reversible por seguridad)';Requires=@{};
 Test={(Get-SvcStart 'RemoteRegistry') -eq 'Disabled'};Apply={Set-SvcStart 'RemoteRegistry' 'disabled'};Revert={Set-SvcStart 'RemoteRegistry' 'disabled'}}

# --- PRIVACIDAD (Tier 0) ---
Add-Tweak @{Id='priv_telemetry';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Telemetria minima';Desc='AllowTelemetry=0 por politica';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry'}}
Add-Tweak @{Id='priv_ads';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Anuncios personalizados OFF';Desc='Sin ID de publicidad';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled') -eq 0};Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0};Revert={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 1}}
Add-Tweak @{Id='priv_tips';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Sugerencias del menu OFF';Desc='Sin recomendaciones en inicio/config';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled') -eq 0};Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0};Revert={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 1}}
Add-Tweak @{Id='priv_cortana';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Cortana OFF';Desc='Sin busquedas automaticas con internet';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana'}}
Add-Tweak @{Id='priv_copilot';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Copilot OFF';Desc='Desactiva la IA de la barra de tareas';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot') -eq 1};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot'}}
Add-Tweak @{Id='priv_activity';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Historial de actividad OFF';Desc='Windows no guarda que programas usas';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities'}}
Add-Tweak @{Id='priv_recall';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Recall OFF';Desc='Bloquea la IA que captura tu pantalla';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement'}}
Add-Tweak @{Id='priv_appraiser';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Compatibility Appraiser OFF';Desc='Sin analisis de compatibilidad de fondo';Requires=@{};
 Test={ $t=Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -EA SilentlyContinue | Where-Object TaskName -match 'Compatibility Appraiser'; if(-not $t){return $true}; @($t | Where-Object State -ne 'Disabled').Count -eq 0 };
 Apply={ Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -EA SilentlyContinue | Where-Object TaskName -match 'Compatibility Appraiser' | Disable-ScheduledTask -EA SilentlyContinue | Out-Null };
 Revert={ Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -EA SilentlyContinue | Where-Object TaskName -match 'Compatibility Appraiser' | Enable-ScheduledTask -EA SilentlyContinue | Out-Null }}
Add-Tweak @{Id='priv_diagtask';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Tareas de telemetria OFF';Desc='Desactiva tareas CEIP';Requires=@{};
 Test={ $t=Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -EA SilentlyContinue; if(-not $t){return $true}; @($t | Where-Object State -ne 'Disabled').Count -eq 0 };
 Apply={ Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -EA SilentlyContinue | Disable-ScheduledTask -EA SilentlyContinue | Out-Null };
 Revert={ Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -EA SilentlyContinue | Enable-ScheduledTask -EA SilentlyContinue | Out-Null }}

# --- APPS: telemetria de terceros (Tier 0, policy keys reversibles) ---
# Fuente de las claves: hellzerg/optimizerNXT (yaml/disable-*-telemetry.yaml), verificadas.
$ChromePol = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
Add-Tweak @{Id='app_chrome';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria Chrome OFF';Desc='Metrics, cleanup reporting y feedback a Google';Requires=@{};
 Test={(Get-RV $ChromePol 'MetricsReportingEnabled') -eq 0};
 Apply={Set-RD $ChromePol 'MetricsReportingEnabled' 0; Set-RD $ChromePol 'ChromeCleanupReportingEnabled' 0; Set-RD $ChromePol 'ChromeCleanupEnabled' 0; Set-RD $ChromePol 'UserFeedbackAllowed' 0; Set-RD $ChromePol 'DeviceMetricsReportingEnabled' 0};
 Revert={Del-RV $ChromePol 'MetricsReportingEnabled'; Del-RV $ChromePol 'ChromeCleanupReportingEnabled'; Del-RV $ChromePol 'ChromeCleanupEnabled'; Del-RV $ChromePol 'UserFeedbackAllowed'; Del-RV $ChromePol 'DeviceMetricsReportingEnabled'}}

$EdgePol = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
Add-Tweak @{Id='app_edge';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria Edge OFF';Desc='Sidebar, personalizacion, metrics y feedback de Edge';Requires=@{};
 Test={(Get-RV $EdgePol 'MetricsReportingEnabled') -eq 0};
 Apply={Set-RD $EdgePol 'HubsSidebarEnabled' 0; Set-RD $EdgePol 'PersonalizationReportingEnabled' 0; Set-RD $EdgePol 'UserFeedbackAllowed' 0; Set-RD $EdgePol 'MetricsReportingEnabled' 0; Set-RD $EdgePol 'Edge3PSerpTelemetryEnabled' 0; Set-RD $EdgePol 'SpotlightExperiencesAndRecommendationsEnabled' 0; Set-RD $EdgePol 'DefaultBrowserSettingsCampaignEnabled' 0; Set-RD $EdgePol 'ComposeInlineEnabled' 0};
 Revert={Del-RV $EdgePol 'HubsSidebarEnabled'; Del-RV $EdgePol 'PersonalizationReportingEnabled'; Del-RV $EdgePol 'UserFeedbackAllowed'; Del-RV $EdgePol 'MetricsReportingEnabled'; Del-RV $EdgePol 'Edge3PSerpTelemetryEnabled'; Del-RV $EdgePol 'SpotlightExperiencesAndRecommendationsEnabled'; Del-RV $EdgePol 'DefaultBrowserSettingsCampaignEnabled'; Del-RV $EdgePol 'ComposeInlineEnabled'}}

$FfPol = 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox'
Add-Tweak @{Id='app_firefox';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria Firefox OFF';Desc='DisableTelemetry + DisableDefaultBrowserAgent por politica de empresa';Requires=@{};Source='https://mozilla.github.io/policy-templates/';SourceType='official';PlaceboLikely=$false;NotesEng='Mozilla policy templates (official) document both keys under Software\Policies\Mozilla\Firefox as REG_DWORD 0x1/0x0. Path and value type verified to match this tweak exactly.';
 Test={(Get-RV $FfPol 'DisableTelemetry') -eq 1};
 Apply={Set-RD $FfPol 'DisableTelemetry' 1; Set-RD $FfPol 'DisableDefaultBrowserAgent' 1};
 Revert={Del-RV $FfPol 'DisableTelemetry'; Del-RV $FfPol 'DisableDefaultBrowserAgent'}}

Add-Tweak @{Id='app_nvidia';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria NVIDIA OFF';Desc='Servicio NvTelemetryContainer + tareas programadas';Requires=@{Nvidia=$true};
 Test={ (Get-SvcStart 'NvTelemetryContainer') -eq 'Disabled' };
 Apply={ Set-SvcStart 'NvTelemetryContainer' 'disabled'; & schtasks.exe /change /tn 'NvTmRepOnLogon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /disable 2>$null | Out-Null; & schtasks.exe /change /tn 'NvTmRep_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /disable 2>$null | Out-Null; & schtasks.exe /change /tn 'NvTmMon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /disable 2>$null | Out-Null };
 Revert={ Set-SvcStart 'NvTelemetryContainer' 'demand'; & schtasks.exe /change /tn 'NvTmRepOnLogon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /enable 2>$null | Out-Null; & schtasks.exe /change /tn 'NvTmRep_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /enable 2>$null | Out-Null; & schtasks.exe /change /tn 'NvTmMon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /enable 2>$null | Out-Null }}

# Office: essentials (ClientTelemetry + OSM upload + QM). No las 50 claves anidadas por version.
Add-Tweak @{Id='app_office';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria Office OFF';Desc='ClientTelemetry (16.0 + rama sin version), OSM upload y QM';Requires=@{};
 Test={(Get-RV 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry' 'DisableTelemetry') -eq 1};
 Apply={Set-RD 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry' 'DisableTelemetry' 1; Set-RD 'HKCU:\SOFTWARE\Microsoft\Office\Common\ClientTelemetry' 'DisableTelemetry' 1; Set-RD 'HKCU:\SOFTWARE\Policies\Microsoft\Office\16.0\OSM' 'EnableUpload' 0; Set-RD 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common' 'QMEnable' 0};
 Revert={Del-RV 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry' 'DisableTelemetry'; Del-RV 'HKCU:\SOFTWARE\Microsoft\Office\Common\ClientTelemetry' 'DisableTelemetry'; Del-RV 'HKCU:\SOFTWARE\Policies\Microsoft\Office\16.0\OSM' 'EnableUpload'; Del-RV 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common' 'QMEnable'}}

Add-Tweak @{Id='app_vs';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria Visual Studio OFF';Desc='Telemetry TurnOffSwitch + Feedback + SQM opt-out (claves sin version, valen para todas)';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\VisualStudio\Telemetry' 'TurnOffSwitch') -eq 1};
 Apply={Set-RD 'HKCU:\Software\Microsoft\VisualStudio\Telemetry' 'TurnOffSwitch' 1; Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback' 'DisableFeedbackDialog' 1; Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\SQM' 'OptIn' 0};
 Revert={Del-RV 'HKCU:\Software\Microsoft\VisualStudio\Telemetry' 'TurnOffSwitch'; Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\Feedback' 'DisableFeedbackDialog'; Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\VisualStudio\SQM' 'OptIn'}}

# --- EXTREMO (Tier 2, opt-in, degrada seguridad real) ---
# NOTA DE INGENIERIA - lo que NO entra y por qué (investigacion 2026):
#  - DisableAntiSpyware (Defender OFF completo): Microsoft lo ignora en 24H2/25H2
#    (build 26200+). La clave existe pero no desactiva Defender; se reactiva solo.
#    Meterlo seria un tweak ROTO por diseno: el usuario cree que funciona y no hace nada.
#  - Smart App Control OFF: IRREVERSIBLE. Una vez apagado no se puede reactivar sin
#    resetear Windows. Viola el principio de reversibilidad 100% de esta suite.
#  - Exclusiones de Defender para carpetas: no es un tweak de rendimiento, es un
#    blind spot de seguridad para todo lo que caiga en la carpeta.
# Tamper Protection OFF: prerequisito para que el resto de tweaks EXTREMO persistan
# (en 24H2/25H2, si Tamper esta ON, Windows revierte los cambios de DeviceGuard al reiniciar).
Add-Tweak @{Id='ext_tamper';Cat='EXTREMO';Tier=2;Reboot=$false;Name='Tamper Protection OFF';Desc='Prerequisito: deja persistir los cambios de VBS/CFG/ASLR. Apaga la proteccion anti-modificacion de Defender';Requires=@{};Source='https://learn.microsoft.com/en-us/defender-endpoint/prevent-changes-to-security-settings-with-tamper-protection';
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection') -eq 0};
 Apply={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection' 0};
 Revert={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection' 1}}

# Core Isolation / VBS / HVCI OFF: ~5-10% FPS (Tom's Hardware 2024-2026). Requiere ext_tamper antes.
Add-Tweak @{Id='ext_vbs';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Core Isolation / Memory Integrity (VBS+HVCI) OFF';Desc='+5-10% FPS. Apaga VBS, HVCI y Credential Guard. Requiere Tamper Protection OFF primero';Requires=@{TamperOff=$true};Source='https://learn.microsoft.com/en-us/windows/security/hardware-security/enable-virtualization-based-protection-of-code-integrity';
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled') -eq 0 -and (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity') -eq 0 -and (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags') -in @($null,0)};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags' 0};
 Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'; Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity'; Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags'}}

# Control Flow Guard OFF: mitigacion de exploits. Ganancia pequena pero medible en CPU-bound.
Add-Tweak @{Id='ext_cfg';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Control Flow Guard (CFG) OFF';Desc='Apaga proteccion de salto indirecto. Ganancia pequena en CPU-bound. Requiere reinicio';Requires=@{TamperOff=$true};Source='https://learn.microsoft.com/en-us/windows/win32/secbp/control-flow-guard';
 Test={ $m=Get-AXECache 'procmit' { try{Get-ProcessMitigation -System -EA Stop}catch{$null} }; if(-not $m){$false}else{$m.Cfg.Enable -eq 'OFF'} };
 Apply={ Set-ProcessMitigation -System -Disable CFG };
 Revert={ Set-ProcessMitigation -System -Enable CFG }}

# Mandatory ASLR OFF: desactiva el randomizado de memoria forzado del sistema.
Add-Tweak @{Id='ext_aslr';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Mandatory ASLR OFF';Desc='Apaga randomizado de memoria del sistema. Expone a exploits de buffer overflow';Requires=@{TamperOff=$true};Source='https://learn.microsoft.com/en-us/defender-endpoint/customize-exploit-protection';
 Test={ $m=Get-AXECache 'procmit' { try{Get-ProcessMitigation -System -EA Stop}catch{$null} }; if(-not $m){$false}else{$m.Aslr.ForceRelocateImages -eq 'OFF'} };
 Apply={ Set-ProcessMitigation -System -Disable ForceRelocateImages };
 Revert={ Set-ProcessMitigation -System -Enable ForceRelocateImages }}

# Vulnerable Driver Blocklist OFF: permite cargar drivers sin firma estricta (DMA, overlays custom).
Add-Tweak @{Id='ext_driverblock';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Vulnerable Driver Blocklist OFF';Desc='Permite drivers bloqueados por Microsoft (overlays, inyectores). Riesgo: drivers vulnerables cargan';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/security/application-security/application-control/app-control-for-business/design/microsoft-recommended-driver-block-rules';
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable') -eq 0};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable' 0};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable' 1}}

Add-Tweak @{Id='ext_mitig';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Mitigaciones Spectre/Meltdown OFF';Desc='PIERDES proteccion CVE-2017-5715/5754';Requires=@{};Source='https://support.microsoft.com/en-us/topic/kb4072698-windows-server-and-azure-stack-hci-guidance-to-protect-against-silicon-based-microarchitectural-and-speculative-execution-side-channel-vulnerabilities-2f965763-00e2-8f98-b632-0d96f30c8c8e';
 Test={(Get-RV $MM 'FeatureSettingsOverride') -eq 3};
 Apply={Set-RD $MM 'FeatureSettingsOverride' 3; Set-RD $MM 'FeatureSettingsOverrideMask' 3};Revert={Del-RV $MM 'FeatureSettingsOverride'; Del-RV $MM 'FeatureSettingsOverrideMask'}}

# ---- AGREGADOS (peticion usuario): seguridad -> FPS. Todos opt-in, reversibles, REINICIO. ----
# ext_hypervisor: apaga el hipervisor en el arranque. DISTINTO de ext_vbs (que solo pone la
# POLITICA de registro de VBS): con Hyper-V/WSL2/Sandbox el hipervisor sigue arrancando y
# mantiene overhead; esto lo mata de raiz. Test reusa el cache 'bcd' (mismo bcdedit /enum).
Add-Tweak @{Id='ext_hypervisor';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Hypervisor OFF (mata VBS/CredGuard de raiz)';Desc='+3-8% FPS si usas Hyper-V/WSL2/Sandbox. ROMPE WSL2, Docker, Windows Sandbox, Hyper-V y Credential Guard. Reversible. REINICIO';Requires=@{};Source='https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/bcdedit--set';
 Test={ ((Get-AXECache 'bcd' { bcdedit /enum '{current}' | Out-String }) -match 'hypervisorlaunchtype\s+Off') };
 Apply={bcdedit /set hypervisorlaunchtype off | Out-Null};Revert={bcdedit /set hypervisorlaunchtype auto | Out-Null}}

# ext_dep: NX/DEP AlwaysOff. HONESTO: ganancia FPS ~0 en hardware moderno (DEP es gratis en la
# MMU). Incluido por peticion explicita. Reduce proteccion anti-exploit.
Add-Tweak @{Id='ext_dep';Cat='EXTREMO';Tier=2;Reboot=$true;Name='DEP/NX OFF (placebo, ~0 FPS)';Desc='Desactiva Data Execution Prevention. Ganancia FPS ~0 en hardware moderno. Reduce proteccion anti-exploit. REINICIO';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/win32/memory/data-execution-prevention';
 Test={ ((Get-AXECache 'bcd' { bcdedit /enum '{current}' | Out-String }) -match 'nx\s+AlwaysOff') };
 Apply={bcdedit /set nx AlwaysOff | Out-Null};Revert={bcdedit /set nx OptIn | Out-Null}}

# ext_sehop: SEHOP OFF. HONESTO: ganancia FPS ~0 (solo pesa en dispatch de excepciones).
# Incluido por peticion. Reduce proteccion anti-exploit. 1=SEHOP off, 0=SEHOP on (default).
Add-Tweak @{Id='ext_sehop';Cat='EXTREMO';Tier=2;Reboot=$true;Name='SEHOP OFF (placebo, ~0 FPS)';Desc='Desactiva Structured Exception Handling Overwrite Protection. Ganancia FPS ~0. Reduce proteccion anti-exploit. REINICIO';Requires=@{};Source='https://learn.microsoft.com/en-us/windows/security/threat-protection/overview-of-threat-mitigations-in-windows-10';
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DisableExceptionChainValidation') -eq 1};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DisableExceptionChainValidation' 1};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'DisableExceptionChainValidation' 0}}

# FIX M2: guard anti-catalogo-roto. Si el catalogo no tiene masa critica, abortar antes de tocar nada.
if($script:CAT.Count -lt 10){
    Write-AXELog "ALERTA: catalogo con $($script:CAT.Count) tweaks (<10). Abortando para no operar en estado inconsistente." 'ERR'
    if($SelfTest -or $List -or $Export -or $Import){ exit 1 }
}

# --- Propiedades avanzadas del adaptador activo (soporte del gate NicProp) ---
# POR QUE EXISTE: varios Test de RED devuelven "true vacuo" cuando el adaptador no expone la
# propiedad que el tweak toca (net_intmod, mas abajo). Es correcto -- no hay nada que aplicar --
# pero la UI lo pinta IGUAL que "aplicado", y para el usuario "no aplica aqui" y "hecho" no son
# el mismo estado. Verificado en la maquina de referencia: el Wi-Fi activo no expone
# *InterruptModeration y el tweak salia verde sin haber tocado nada.
#   La salida NO es un tercer valor de retorno de Test: lo consumen el score, el SelfTest, el
# puente y la GUI como booleano, y volverlo tri-estado los rompe a todos en silencio. Es el gate
# que YA existe: si la propiedad no esta, el tweak no aplica a esta maquina y Get-BlockReason lo
# dice nombrando el adaptador. Gatear con Requires=@{Wired=$true} habria sido falso para un Wi-Fi
# que si expone la propiedad; esto pregunta por LA PROPIEDAD, no por el medio.
#   La enumeracion NDIS es cara y no cambia mientras no cambie el adaptador => cache permanente,
# igual que la topologia PnP. La clave lleva el nombre del NIC: otro adaptador, otra entrada.
function Get-AXENicProps {
    # Sin HW detectado NO se cachea: en la GUI el hardware llega desde un runspace de fondo y
    # una lista vacia guardada en el cache PERMANENTE dejaria el gate mintiendo toda la sesion.
    if(-not $script:HW -or -not $script:HW.NicName){ return @() }
    Get-AXECache "nic:adv:$($script:HW.NicName)" {
        try { @(Get-NetAdapterAdvancedProperty -Name $script:HW.NicName -EA Stop | ForEach-Object { $_.RegistryKeyword }) }
        catch { @() }
    } -Permanent
}
function Test-AXENicProp([string]$Keyword){ (Get-AXENicProps) -contains $Keyword }

# =====================================================
# REGION 6 - GATING  (devuelve $null=OK | string=motivo)
# =====================================================
function Get-BlockReason($tw){
    if(-not $script:HW){ return $null }
    $r = $tw.Requires
    if($r.Desktop  -and $script:HW.IsLaptop){ return "portatil: sube termicas, throttlea" }
    if($r.NotHybrid -and $script:HW.IsHybrid){ return "CPU hibrida P/E: pelea con Thread Director" }
    if($r.AC       -and $script:HW.OnBattery){ return "en bateria: mata autonomia sin ganancia sostenida" }
    if($r.Wired    -and $script:HW.IsWifi){ return "Wi-Fi: ganancia casi nula" }
    if($r.NotHome  -and $script:HW.IsHome){ return "Windows Home: politica ignorada por el SKU" }
    if($r.Nvidia   -and -not $script:HW.HasNvidia){ return "sin GPU NVIDIA: no aplica" }
    if($r.NotLaptop -and $script:HW.IsLaptop){ return "portatil: no aplica" }
    if($r.WinVer){
        $cur = if($script:HW.IsWin11){ 11 } else { 10 }
        if($cur -notin $r.WinVer){ return "requiere Windows $($r.WinVer -join '/'), tienes Windows $cur (build $($script:HW.BuildNumber))" }
    }
    # --- ecosistema extendido (§3.2) ---
    if($r.MinRam -and $script:HW.RamGB -lt $r.MinRam){ return "requiere >= $($r.MinRam)GB RAM, tienes $($script:HW.RamGB)GB (con menos RAM = peor rendimiento)" }
    # Techo de RAM. Simetrico a MinRam y no redundante: hay ajustes cuyo unico beneficio es
    # ahorrar memoria/procesos y que por encima de cierta RAM son coste puro (svc_hostsplit).
    if($r.MaxRam -and $script:HW.RamGB -gt $r.MaxRam){ return "requiere <= $($r.MaxRam)GB RAM, tienes $($script:HW.RamGB)GB (con esta RAM el ahorro no compensa lo que se pierde)" }
    # Tercer estado real: la palanca no existe en ESTE adaptador. Distinto de "no aplicado".
    if($r.NicProp -and -not (Test-AXENicProp $r.NicProp)){ return "el adaptador '$($script:HW.NicName)' no expone $($r.NicProp): no hay nada que aplicar aqui" }
    if($r.WinBuild){ if([int]$script:HW.BuildNumber -notin $r.WinBuild){ return "requiere build $($r.WinBuild -join '/'), tienes $($script:HW.BuildNumber)" } }
    if($r.CpuArch){ if($script:HW.CpuArch -notin $r.CpuArch){ return "requiere CPU $($r.CpuArch -join '/'), tienes $($script:HW.CpuArch)" } }
    if($r.CpuVendor){ if($script:HW.CpuVendor -notin $r.CpuVendor){ return "requiere $($r.CpuVendor -join '/'), tienes $($script:HW.CpuVendor)" } }
    if($r.HAGS -and -not $script:HW.SupportsHAGS){ return "GPU/driver sin soporte HAGS (WDDM 2.7+): no aplica" }
    if($r.TamperOff -and $script:HW.IsTamperProtected){ return "Tamper Protection ON: el cambio no persiste (apaga Tamper primero)" }
    if($r.Defender -and -not $script:HW.HasDefender){ return "AV de terceros / Defender inactivo: ajuste omitido" }
    if($r.NotSMode -and $script:HW.IsSMode){ return "Windows S mode: no permite el cambio" }
    return $null
}

# §3.2: azucar booleano - un tweak se MUESTRA solo si aplica al ecosistema.
function Test-AXEEnvApplies($tw){ -not (Get-BlockReason $tw) }

# §3.3: banner de ecosistema (GUI header + CLI). Hace explicito POR QUE se ve lo que se ve.
function Get-AXEEnvBanner {
    if(-not $script:HW){ return 'HW no detectado (arranque)' }
    $h = $script:HW
    $applic = 0; $hidden = 0
    foreach($tw in $script:CAT){ if(Get-BlockReason $tw){ $hidden++ } else { $applic++ } }
    $ver  = if($h.IsWin11){ 'Win11' } else { 'Win10' }
    $sku  = if($h.IsHome){ 'Home' } else { 'Pro/Ent' }
    $hyb  = if($h.IsHybrid){ 'hibrida' } else { 'clasica' }
    $gpu  = if($h.HasNvidia){ 'NVIDIA' } else { 'no-NVIDIA' }
    $ssd  = if($h.IsSSD){ 'SSD' } else { 'HDD/otro' }
    $net  = if($h.IsWifi){ 'Wi-Fi' } else { 'Ethernet' }
    $def  = if($h.HasDefender){ if($h.IsTamperProtected){ 'Defender+Tamper' } else { 'Defender' } } else { 'AV 3ros' }
    "{0} {1} - {2} - {3} - {4} - {5}GB - {6} - {7} - {8} - {9} - {10} aplicables / {11} ocultos" -f `
        $ver,$h.BuildNumber,$sku,$h.CpuArch,$hyb,$h.RamGB,$gpu,$ssd,$net,$def,$applic,$hidden
}

# =====================================================
# REGION 6.5 - RECOMENDACION POR MAQUINA (§3.4)
# El gating (§3.2) responde "¿esto SE PUEDE aplicar aqui?". Esto responde la otra
# mitad: "de lo que se puede, ¿que VALE LA PENA en ESTA maquina?". Un portatil de
# 8GB en bateria y una torre de 32GB con NVIDIA no merecen la misma lista.
# =====================================================

# Nucleo: ganancia real, segura y universal. No depende del hardware.
$script:RECCORE = @(
    'cpu_mmcss','lat_mouse','sys_gamedvr','sys_fse','rend_gamemode',
    'rend_visualfx','rend_mpo','gpu_hags','net_throttle','priv_recall','mem_lastaccess'
)

# Condicionales: id -> predicado sobre el hardware. Cada regla lleva el porque al lado:
# una recomendacion sin motivo es indistinguible de una lista copiada de un foro.
$script:RECRULES = @{
    # OJO con los umbrales: RamGB sale de TotalVisibleMemorySize, que SIEMPRE es algo
    # menor que la RAM fisica (32GB reales -> 31,7). Un umbral en 32 no dispararia nunca.
    # Por eso los cortes van 1-2GB por debajo de la cifra comercial: 15=16GB, 23=24GB, 30=32GB.
    'mem_pagingexec'  = { param($h) $h.RamGB -ge 23 }                              # kernel deja de paginar: solo con RAM de sobra (24GB+)
    'mem_ntfsmem'     = { param($h) $h.RamGB -ge 15 }                              # cache de metadatos NTFS: paga si hay RAM libre (16GB+)
    'mem_compression' = { param($h) $h.RamGB -ge 30 }                              # quitar compresion cambia CPU por RAM: solo con RAM abundante (32GB+)
    'svc_sysmain'     = { param($h) $h.IsSSD }                                     # SysMain precarga para HDD; con SSD casi no aporta
    'svc_wsearch'     = { param($h) -not $h.IsSSD }                                # el indexador duele sobre todo en disco mecanico
    'rend_ultperf'    = { param($h) (-not $h.IsLaptop) -and (-not $h.OnBattery) }  # mas consumo/calor: sobremesa enchufado
    'rend_bgapps'     = { param($h) ($h.RamGB -lt 15) -or $h.IsLaptop }            # liberar CPU/RAM en idle importa en equipos justos (<16GB) o portatiles
    'cpu_park'        = { param($h) -not $h.IsLaptop }                             # desparkear en portatil = termicas y bateria
    'sys_hibernate'   = { param($h) -not $h.IsLaptop }                             # en portatil la hibernacion si se usa
    'lat_msi_audio'   = { param($h) -not $h.IsLaptop }                             # MSI en audio: IRQ compartida es mas fragil en portatil
    'net_intmod'      = { param($h) Test-AXENicProp '*InterruptModeration' }       # se pregunta por la propiedad, no por el medio: hay Wi-Fi que si la expone
    'net_rss'         = { param($h) $h.Threads -ge 8 }                             # repartir RX entre nucleos necesita nucleos
    'net_ctcp'        = { param($h) $h.IsWifi }                                    # CTCP recupera antes tras perdida: la radio pierde mas
    'gpu_ulps'        = { param($h) $h.HasNvidia }                                 # ULPS es especifico de NVIDIA
    'priv_copilot'    = { param($h) $h.IsWin11 }                                   # Copilot solo existe en Win11
}

function Get-AXERecommended {
    # Sin HW no hay recomendacion honesta: solo el nucleo universal. La GUI recalcula
    # cuando el runspace de deteccion entrega el hardware (Apply-AXEGating).
    $ids = New-Object System.Collections.Generic.List[string]
    foreach($i in $script:RECCORE){ [void]$ids.Add($i) }
    $h = $script:HW
    if($h){
        foreach($id in $script:RECRULES.Keys){
            $ok = $false
            try { $ok = [bool](& $script:RECRULES[$id] $h) } catch { $ok = $false }
            if($ok -and -not $ids.Contains($id)){ [void]$ids.Add($id) }
        }
    }
    # Filtro duro. Recomendar algo que el propio catalogo marca Tier 2 o placebo probable
    # es contradecirse, y la insignia pierde todo su valor. Se aplica SIEMPRE, tambien al
    # nucleo: si un tweak se degrada a Tier 2 manana, sale solo de las recomendaciones.
    $out = New-Object System.Collections.Generic.List[string]
    foreach($id in $ids){
        $tw = $script:CAT | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if(-not $tw){ continue }                                                    # id muerto tras un rename: se cae solo, no rompe
        if($tw.Tier -ge 2){ continue }
        if($tw.PSObject.Properties['PlaceboLikely'] -and $tw.PlaceboLikely){ continue }
        if(Get-BlockReason $tw){ continue }                                         # no aplica a esta maquina
        [void]$out.Add($id)
    }
    # .ToArray() y NO ",$out": el operador coma envolveria la lista en otro array y los
    # llamantes (que ya hacen @(Get-AXERecommended)) verian 1 elemento en vez de N.
    $out.ToArray()
}

# §3.5 - SET DE LATENCIA / INPUT LAG
# No es "todo Tier<2": son los ajustes cuyo efecto cae en la cadena
# entrada -> proceso -> render -> pantalla, o en el jitter del timer que la sostiene.
# Deliberadamente FUERA: net_dns (pisa DNS local/VPN), todo EXTREMO, y cualquier cosa
# marcada PlaceboLikely - un boton de un clic no es sitio para apuestas.

# Nucleo: la cadena de entrada y render. Vale igual en cualquier maquina.
$script:LATCORE = @(
    'lat_mouse','lat_timerres','lat_msi_gpu','lat_irq_gpu','lat_faststart',
    'cpu_dyntick','cpu_tsc','cpu_fth','cpu_mmcss',
    'sys_gamedvr','sys_fse','sys_gamebar',
    'rend_gamemode','rend_mpo','gpu_hags','gpu_vrr','net_throttle'
)

# Condicionales. Dos familias:
#  (a) ajustes de latencia que en cierto hardware SALEN CAROS (bateria, termicas, IRQ);
#  (b) ajustes que no son "latencia" de manual pero que en ESTA maquina son la mayor
#      fuente de stutter real - un indexador sobre disco mecanico arruina mas frametimes
#      que cualquier valor de registro de los que circulan por los foros.
$script:LATRULES = @{
    'cpu_pthr'        = { param($h) -not $h.OnBattery }                            # Power Throttling OFF en bateria = autonomia a cero sin ganancia sostenida
    'cpu_park'        = { param($h) (-not $h.IsLaptop) -and (-not $h.IsHybrid) }   # en portatil throttlea; en hibrida pelea con Thread Director
    'lat_msi_audio'   = { param($h) -not $h.IsLaptop }                             # MSI en audio: la IRQ compartida de portatil es mas fragil
    'rend_ultperf'    = { param($h) (-not $h.IsLaptop) -and (-not $h.OnBattery) }  # evita el downclock en idle que se nota como lag al reaccionar
    'net_intmod'      = { param($h) Test-AXENicProp '*InterruptModeration' }       # idem RECRULES: decide la propiedad expuesta, no Wi-Fi vs cable
    'net_rss'         = { param($h) $h.Threads -ge 8 }                             # repartir RX entre nucleos necesita nucleos
    'net_ctcp'        = { param($h) $h.IsWifi }                                    # la radio pierde paquetes; CTCP recupera antes
    'mem_pagingexec'  = { param($h) $h.RamGB -ge 23 }                              # kernel fuera del pagefile = menos micro-tirones (24GB+)
    'mem_compression' = { param($h) $h.RamGB -ge 30 }                              # sin compresion, menos CPU en paginado (32GB+)
    'svc_sysmain'     = { param($h) $h.IsSSD }                                     # con SSD la precarga solo genera I/O de fondo
    'svc_wsearch'     = { param($h) -not $h.IsSSD }                                # indexador sobre HDD: la mayor fuente de stutter del sistema
    'rend_bgapps'     = { param($h) ($h.RamGB -lt 15) -or $h.IsLaptop }            # apps UWP en background compiten por CPU en equipos justos
}

function Get-AXELatencySet {
    $ids = New-Object System.Collections.Generic.List[string]
    foreach($i in $script:LATCORE){ [void]$ids.Add($i) }
    $h = $script:HW
    if($h){
        foreach($id in $script:LATRULES.Keys){
            $ok = $false
            try { $ok = [bool](& $script:LATRULES[$id] $h) } catch { $ok = $false }
            if($ok -and -not $ids.Contains($id)){ [void]$ids.Add($id) }
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach($id in $ids){
        $tw = $script:CAT | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if(-not $tw){ continue }
        if($tw.Tier -ge 2){ continue }
        if($tw.PSObject.Properties['PlaceboLikely'] -and $tw.PlaceboLikely){ continue }
        if(Get-BlockReason $tw){ continue }   # cruce con el gating: cada maquina, su lista
        [void]$out.Add($id)
    }
    $out.ToArray()
}

# Notas de por que ESTA maquina recibe este plan y no otro. Sin esto el boton es una
# caja negra: el usuario ve "23 marcados" y no sabe si le ha tocado lo suyo o una receta
# generica. Es la diferencia entre una herramienta y un .bat de foro.
function Get-AXELatencyNotes {
    $n = New-Object System.Collections.Generic.List[string]
    $h = $script:HW
    if(-not $h){ [void]$n.Add('Hardware sin detectar: solo se aplica el nucleo universal.'); return $n.ToArray() }
    if($h.OnBattery){ [void]$n.Add('EN BATERIA: Power Throttling y plan de energia quedan fuera. Ademas la medicion en bateria no es comparable con la de enchufado: conecta el cargador antes de medir.') }
    if($h.IsLaptop){  [void]$n.Add('Portatil: fuera MSI de audio y core parking. En chasis compacto la IRQ compartida y las termicas cuestan mas de lo que dan.') }
    if($h.IsHybrid){  [void]$n.Add('CPU hibrida P/E: core parking fuera, se pelea con Thread Director.') }
    # La nota de moderacion de interrupciones ya no se deduce del medio: se consulta el adaptador.
    # Un Wi-Fi que expone *InterruptModeration la recibe; un Ethernet que no la expone, no.
    $im = Test-AXENicProp '*InterruptModeration'
    if($h.IsWifi){    [void]$n.Add('Wi-Fi: dentro CTCP (recupera antes tras perdida). El jitter lo domina la radio: por cable bajaria mas.') }
    if($im){          [void]$n.Add("Adaptador '$($h.NicName)': expone moderacion de interrupciones, asi que entra en el plan.") }
    else {            [void]$n.Add("Adaptador '$($h.NicName)': no expone moderacion de interrupciones, el ajuste no aplica aqui (no es que falle: no existe la palanca).") }
    if(-not $h.IsSSD){ [void]$n.Add('Disco mecanico: apagar el indexador de busqueda es aqui la mayor ganancia de frametimes, por encima de cualquier valor de registro.') }
    else {             [void]$n.Add('SSD: dentro apagar la precarga (SysMain), que sobre SSD solo genera I/O de fondo.') }
    if($h.RamGB -lt 15){ [void]$n.Add('RAM justa: se prioriza liberar memoria sobre cachear. Kernel-en-RAM y quitar compresion quedan fuera: costarian mas de lo que dan.') }
    elseif($h.RamGB -ge 30){ [void]$n.Add('RAM abundante: dentro kernel-en-RAM y sin compresion de memoria, ambos reducen micro-tirones.') }
    if(-not $h.SupportsHAGS){ [void]$n.Add('Sin soporte HAGS (WDDM 2.7+): el scheduling por hardware no aplica a esta GPU/driver.') }
    $n.ToArray()
}



# >>>>> MODULE: 22-catalogs.ps1 >>>>>
# =====================================================
# REGION 7 - ACCIONES (limpieza, debloat, DNS)
# =====================================================
$script:CLEAN = New-Object System.Collections.ArrayList
function Add-Clean($h){ [void]$script:CLEAN.Add([pscustomobject]$h) }
# NOTA: los Run DEVUELVEN lineas de log (string) en vez de llamar Write-AXELog, para
# poder ejecutarse en runspace de fondo (la GUI no congela). El handler GUI las loguea.
Add-Clean @{Name='Temporales (usuario + Windows)';Desc='Borra %TEMP% y C:\Windows\Temp';Run={
    $b=[math]::Round((Get-PSDrive C).Free/1GB,2); Remove-Item "$env:TEMP\*" -Recurse -Force -EA SilentlyContinue; Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -EA SilentlyContinue; $a=[math]::Round((Get-PSDrive C).Free/1GB,2); "Temporales limpios. Libre: $b -> $a GB" }}
Add-Clean @{Name='Cache shaders DirectX';Desc='Se regenera sola; util tras update de driver';Run={ Remove-Item "$env:LOCALAPPDATA\D3DSCache\*" -Recurse -Force -EA SilentlyContinue; 'Cache shaders DirectX limpiada.' }}
Add-Clean @{Name='Cache Windows Update';Desc='Para wuauserv/bits, borra Download, reinicia';Run={
    Stop-Service wuauserv,bits -Force -EA SilentlyContinue; Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -EA SilentlyContinue; Start-Service bits,wuauserv -EA SilentlyContinue; 'Cache Windows Update limpiada.' }}
Add-Clean @{Name='Flush DNS';Desc='Vacia cache de resolucion de nombres';Run={ ipconfig /flushdns | Out-Null; 'Cache DNS vaciada.' }}
Add-Clean @{Name='Purga working set (RAM)';Desc='Libera RAM en cache de procesos idle';Run={
    $sig='[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);'; $t=('LW.WS' -as [type]); if(-not $t){ $t=Add-Type -MemberDefinition $sig -Name WS -Namespace LW -PassThru }; $n=0; Get-Process | ForEach-Object { try{ if($t::EmptyWorkingSet($_.Handle)){$n++} }catch{} }; "Working set purgado en $n procesos." }}
Add-Clean @{Name='Purga standby list (RAM cacheada)';Desc='Vacia la lista standby (estilo ISLC): quita el hitch de reclamar cache. Util antes/durante el juego';Run={
    $os=Get-CimInstance Win32_OperatingSystem; $b=[math]::Round($os.FreePhysicalMemory/1MB,2)
    $rc=[AXE.Native]::PurgeStandby()
    if($rc -ne 0){ if($rc -eq -4){ "ERROR standby: sin privilegio. Ejecuta AXE como administrador." } else { "ERROR purga standby (codigo $rc)." } }
    else { $a=[math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,2); "Standby list purgada. RAM libre: $b -> $a GB" } }}

$script:DEBLOAT = @(
    @{Pkg='Microsoft.BingNews';Name='Noticias (Bing)'}
    @{Pkg='Microsoft.BingWeather';Name='El Tiempo'}
    @{Pkg='Microsoft.GamingApp';Name='Xbox App'}
    @{Pkg='Microsoft.XboxGamingOverlay';Name='Xbox Game Bar overlay'}
    @{Pkg='Microsoft.XboxSpeechToTextOverlay';Name='Xbox voz'}
    @{Pkg='Microsoft.549981C3F5F10';Name='Cortana'}
    @{Pkg='Clipchamp.Clipchamp';Name='Clipchamp (editor video)'}
    @{Pkg='Microsoft.Todos';Name='Microsoft To Do'}
    @{Pkg='Microsoft.PowerAutomateDesktop';Name='Power Automate'}
    @{Pkg='Microsoft.MicrosoftOfficeHub';Name='Office Hub'}
    @{Pkg='Microsoft.MicrosoftSolitaireCollection';Name='Solitaire'}
    @{Pkg='Microsoft.People';Name='Contactos'}
    @{Pkg='Microsoft.WindowsFeedbackHub';Name='Comentarios'}
    @{Pkg='Microsoft.GetHelp';Name='Obtener ayuda'}
    @{Pkg='Microsoft.Getstarted';Name='Sugerencias'}
    @{Pkg='MicrosoftTeams';Name='Teams (personal)'}
    @{Pkg='Microsoft.Copilot';Name='Copilot (app)'}
)
function Get-DebloatInstalled($pkg){ [bool](Get-AppxPackage -Name $pkg -EA SilentlyContinue) }

# $script:DNSPROFILES vivia aqui: 5 proveedores con sus IPs, sin un solo consumidor en todo el
# repo (la pestana DNS que los mostraba murio en el cutover a WebUI, fase 8 de v7). Codigo muerto
# que ademas afirmaba un ranking -"rapidos", "seguridad"- sin medir nada: justo lo que documenta
# 33-fps que no se debe hacer. Quien quiera cambiar DNS tiene el tweak 'net_dns' en RED, que
# declara en su propio Desc que NO da FPS. Si algun dia vuelve una seccion DNS, que llegue
# midiendo la latencia de resolucion real en la maquina del usuario, no con una lista a ojo.


# >>>>> MODULE: 23-defender.ps1 >>>>>
# =====================================================
# REGION 5b - DEFENDER (gaps §7: exclusiones granulares opt-in, CPU limit, scan idle)
# Todo *-MpPreference / ScheduledTask en try/catch (AV de terceros o Tamper pueden
# rechazarlo). NO baja la proteccion global de Defender: solo afina rendimiento del
# escaneo y excluye rutas/procesos concretos de juegos (opt-in, reversible).
# Los cmdlets *-MpPreference funcionan con Tamper ON (no son registro crudo) => no se rutea.
# =====================================================

# --- Tweaks de rendimiento de Defender (catalogo, gated Defender=$true) ---
Add-Tweak @{Id='def_cpulimit';Cat='SERVICIOS';Tier=1;Reboot=$false;Name='Defender: limitar CPU de escaneo';Desc='ScanAvgCPULoadFactor 30 (default 50): el escaneo programado no acapara CPU';Requires=@{Defender=$true};
 Source='https://learn.microsoft.com/en-us/powershell/module/defender/set-mppreference';SourceType='official';PlaceboLikely=$false;NotesEng='Caps average CPU during SCHEDULED scans (not real-time) at 30% vs default 50. Helps only while a scheduled scan overlaps play; measure CPU during a manual scan before/after. Fully reversible to the 50 default.';
 Test={ try{ (Get-MpPreference -ErrorAction Stop).ScanAvgCPULoadFactor -le 30 }catch{ $false } };
 Apply={ try{ Set-MpPreference -ScanAvgCPULoadFactor 30 -ErrorAction Stop }catch{} };
 Revert={ try{ Set-MpPreference -ScanAvgCPULoadFactor 50 -ErrorAction Stop }catch{} }}
Add-Tweak @{Id='def_scanidle';Cat='SERVICIOS';Tier=1;Reboot=$false;Name='Defender: escaneo solo en reposo';Desc='La tarea "Windows Defender Scheduled Scan" corre solo con el equipo inactivo';Requires=@{Defender=$true};
 Source='https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-runonlyifidle';SourceType='official';PlaceboLikely=$false;NotesEng='Sets RunOnlyIfIdle on the Defender scheduled-scan task so it never fires mid-game. Tamper Protection may reject the change (wrapped, no-op on failure). Reversible to RunOnlyIfIdle=false.';
 Test={ try{ [bool](Get-ScheduledTask -TaskName 'Windows Defender Scheduled Scan' -ErrorAction Stop).Settings.RunOnlyIfIdle }catch{ $false } };
 Apply={ try{ $t=Get-ScheduledTask -TaskName 'Windows Defender Scheduled Scan' -ErrorAction Stop; $t.Settings.RunOnlyIfIdle=$true; Set-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null }catch{} };
 Revert={ try{ $t=Get-ScheduledTask -TaskName 'Windows Defender Scheduled Scan' -ErrorAction Stop; $t.Settings.RunOnlyIfIdle=$false; Set-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null }catch{} }}

# --- Exclusiones granulares opt-in (§7). Devuelven strings (corren en runspace/CLI).
# El modal de consentimiento (trade-off: excluir un proceso reduce cobertura AV) es
# responsabilidad de la capa UI antes de invocar estas funciones.
$script:AXEDefGames = @('cs2.exe','csgo.exe','valorant.exe','LeagueClient.exe','League of Legends.exe','FortniteClient-Win64-Shipping.exe','r5apex.exe','RainbowSix.exe')

function Get-AXESteamCommon {
    <#.SYNOPSIS Resuelve steamapps\common a ruta literal. NUNCA devuelve la raiz de Steam (vector de malware).#>
    $sp = $null
    foreach($k in 'HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam'){
        try{ $v = Get-ItemProperty $k -ErrorAction Stop; $sp = $v.SteamPath; if(-not $sp){ $sp = $v.InstallPath }; if($sp){ break } }catch{}
    }
    if(-not $sp){ return $null }
    try{ return (Resolve-Path -LiteralPath (Join-Path $sp 'steamapps\common') -ErrorAction Stop).Path }catch{ return $null }
}

function Add-AXEDefenderExclusion {
    <#.SYNOPSIS Exclusion opt-in de procesos de juego + steamapps\common. Reversible.#>
    param([string[]]$Process = $script:AXEDefGames)
    $out = New-Object System.Collections.ArrayList
    $mp = $null; try{ $mp = Get-MpComputerStatus -ErrorAction Stop }catch{}
    if(-not ($mp -and $mp.AMServiceEnabled)){ [void]$out.Add('Defender inactivo / AV de terceros: exclusiones omitidas'); return ($out -join "`n") }
    foreach($p in $Process){
        try{ Add-MpPreference -ExclusionProcess $p -ErrorAction Stop; [void]$out.Add("excl proceso: $p") }catch{ [void]$out.Add("fallo proceso $p : $($_.Exception.Message)") }
    }
    $common = Get-AXESteamCommon
    if($common){ try{ Add-MpPreference -ExclusionPath $common -ErrorAction Stop; [void]$out.Add("excl ruta: $common") }catch{ [void]$out.Add("fallo ruta: $($_.Exception.Message)") } }
    else { [void]$out.Add('steamapps\common no encontrado: ruta omitida (nunca se excluye la raiz de Steam)') }
    $out -join "`n"
}

function Remove-AXEDefenderExclusion {
    <#.SYNOPSIS Revierte las exclusiones creadas por Add-AXEDefenderExclusion.#>
    param([string[]]$Process = $script:AXEDefGames)
    $out = New-Object System.Collections.ArrayList
    foreach($p in $Process){ try{ Remove-MpPreference -ExclusionProcess $p -ErrorAction Stop; [void]$out.Add("quitada excl proceso: $p") }catch{} }
    $common = Get-AXESteamCommon
    if($common){ try{ Remove-MpPreference -ExclusionPath $common -ErrorAction Stop; [void]$out.Add("quitada excl ruta: $common") }catch{} }
    $out -join "`n"
}


# >>>>> MODULE: 25-assistant.ps1 >>>>>
# =====================================================
# REGION 8 - ASISTENTE IA LOCAL (sin API, state-aware)
# =====================================================
function Get-AXEState($tw){
    $blk=Get-BlockReason $tw
    if($blk){ return @{S='BLOCK';T="  [BLOQUEADO] $($tw.Name)  ->  $blk"} }
    try { if([bool](& $tw.Test)){ return @{S='ON';T="  [ON]  $($tw.Name)"} } else { return @{S='OFF';T="  [off] $($tw.Name)  ->  $($tw.Desc)"} } }
    catch { return @{S='ERR';T="  [?]   $($tw.Name)"} }
}
function Report-Cats($cats,$titulo){
    $out=@("== $titulo =="); $off=0; $blk=0
    foreach($tw in $script:CAT){ if($cats -contains $tw.Cat){ $st=Get-AXEState $tw; $out+=$st.T; if($st.S -eq 'OFF'){$off++}; if($st.S -eq 'BLOCK'){$blk++} } }
    if($off -gt 0){ $out+="`n>> $off sin aplicar." } else { $out+="`n>> Todo lo aplicable ya esta ON." }
    if($blk -gt 0){ $out+=">> $blk bloqueado(s) por tu hardware." }
    $out -join "`r`n"
}
function Get-AXERecommendations {
    $r=New-Object System.Collections.ArrayList
    $ss=(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled')
    if($ss -eq 'Off' -or (Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen') -eq 0){
        [void]$r.Add('[CRITICO] SmartScreen DESACTIVADO. Reactivalo (Seguridad de Windows > Control de apps).')
    }
    $excl=@((Get-MpPreference -EA SilentlyContinue).ExclusionPath)
    if($excl.Count -gt 0){ [void]$r.Add("[SEGURIDAD] Defender tiene $($excl.Count) exclusion(es) de carpeta. Revisa: $($excl -join '; ')") }
    try {
        $up=((Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds
        $hog=Get-Process | Where-Object { $_.CPU -gt ($up*0.8) } | Sort-Object CPU -Descending | Select-Object -First 1
        if($hog){ [void]$r.Add("[RENDIMIENTO] '$($hog.Name)' lleva $('{0:N0}' -f $hog.CPU)s de CPU acumulada (proceso pesado). Cierralo antes de jugar.") }
    } catch {}
    $pend=0; foreach($tw in $script:CAT){ if($tw.Tier -lt 2 -and -not (Get-BlockReason $tw)){ try{ if(-not [bool](& $tw.Test)){$pend++} }catch{} } }
    if($pend -gt 0){ [void]$r.Add("[TWEAKS] $pend optimizaciones del preset aun sin aplicar.") }
    # Aviso EXTREMO sin Tamper: si VBS/CFG/ASLR estan aplicados pero Tamper sigue ON, Windows los reverts
    $tamperOff = (Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection') -eq 0
    $extApplied = $false
    foreach($id in 'ext_vbs','ext_cfg','ext_aslr'){ $tw=$script:CAT | Where-Object Id -eq $id; if($tw -and (Test-TweakSafe $tw)){ $extApplied=$true; break } }
    if($extApplied -and -not $tamperOff){ [void]$r.Add('[AVISO] Tienes EXTREMO aplicado pero Tamper Protection sigue ON. En 24H2/25H2 Windows REVERTIRA esos cambios al reiniciar. Activa "Tamper Protection OFF" primero.') }
    if($script:HW.IsLaptop -and $script:HW.OnBattery){ [void]$r.Add('[ENERGIA] Estas en BATERIA. Conecta el cargador para maximo rendimiento.') }
    [void]$r.Add('[SEGURIDAD] Crea PRIMERO el PUNTO DE RESTAURACION (boton naranja).')
    $r
}
function Invoke-AXEAssistant($q){
    if([string]::IsNullOrWhiteSpace($q)){ return 'Escribe: "que aplico", "input lag", "fps", "red", "seguridad", "portatil".' }
    $s=$q.ToLower()
    if($s -match 'recom|que aplic|que hago|deber|empez|inicio|todo|optimiz'){ return (Get-AXERecommendations) -join "`r`n" }
    if($s -match 'input|lag|raton|mouse|latenc|delay|responsiv'){ return (Report-Cats @('LATENCIA','CPU') 'INPUT LAG / LATENCIA') }
    if($s -match 'fps|juego|gaming|rendi|frame'){ return (Report-Cats @('GPU','SISTEMA','CPU','RENDIMIENTO') 'FPS / GAMING') + "`n>> Cierra overlays de fondo antes de jugar." }
    if($s -match 'red|ping|dns|internet|wifi|online|conexion'){ $r=Report-Cats @('RED') 'RED'; if($script:HW.IsWifi){ $r+="`n>> Wi-Fi: el jitter lo domina la radio. Cable = mas estabilidad." }; $r+="`n>> DNS: tweak 'net_dns' (categoria RED). Cambia la RESOLUCION de nombres, no el ping: no da FPS."; return $r }
    if($s -match 'segur|virus|defender|smartscreen|malware|proteg'){
        $out=@('== SEGURIDAD ==')
        $ss=(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled')
        if($ss -eq 'Off' -or (Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen') -eq 0){ $out+='  [CRITICO] SmartScreen DESACTIVADO.' } else { $out+='  [OK] SmartScreen activo.' }
        $ex=@((Get-MpPreference -EA SilentlyContinue).ExclusionPath)
        if($ex.Count -gt 0){ $out+="  [AVISO] $($ex.Count) exclusion(es) de Defender." } else { $out+='  [OK] Sin exclusiones.' }
        $out+='  Tier EXTREMO reduce seguridad: solo opt-in consciente.'
        return $out -join "`r`n"
    }
    if($s -match 'portatil|bateria|termic|calor|energia|power'){ $r=Report-Cats @('CPU') 'ENERGIA / CPU'; if($script:HW.IsLaptop){ $r+="`n>> Portatil hibrido: Core Parking/Alto Rendimiento bruto throttlea." }; return $r }
    if($s -match 'ram|memoria|cache'){ return (Report-Cats @('MEMORIA') 'MEMORIA') }
    if($s -match 'extremo|vbs|spectre|mitigac|cfg|aslr|tamper|defender'){ $r=Report-Cats @('EXTREMO') 'EXTREMO (tu estado real)'; $r+="`n>> ORDEN: activa PRIMERO Tamper Protection OFF, despues VBS/CFG/ASLR (sin Tamper off, Windows los revierte al reiniciar en 24H2/25H2)."; $r+="`n>> VBS/HVCI: +5-10% FPS (Tom's Hardware). CFG/ASLR: ganancia pequena en CPU-bound."; $r+="`n>> Cada uno baja seguridad. No recomiendo TODO apagado salvo PC solo-gaming."; return $r }
    if($s -match 'servicio|telemetr|privac'){ return (Report-Cats @('SERVICIOS','PRIVACIDAD') 'SERVICIOS / PRIVACIDAD') }
    if($s -match 'limpi|basura|temp|disco|espacio'){ return "Pestana LIMPIEZA: temporales, shaders, cache WU, flush DNS, working set." }
    if($s -match 'debloat|apps|uwp|bloatware'){ return "Pestana DEBLOAT: apps UWP. Reinstalables desde Store." }
    if($s -match 'startup|inicio|arranque|autorun'){ return "Pestana STARTUP: autoruns reales + RESTAURAR (boton verde) recupera el backup." }
    return "Temas: que aplico, input lag, fps, red, seguridad, portatil, ram, extremo, servicios, limpieza, debloat, startup."
}



# >>>>> MODULE: 28-revert-export.ps1 >>>>>
# =====================================================
# REGION 9 - MASTER REVERT  (FIX A1: limpia residuos v1)
# =====================================================
# A3: cola (limpieza residuos v1 + restore startup). Extraido para que la GUI pueda
# drenar el loop de reverts ASYNC (sin congelar) y correr esta cola al final.
function Invoke-AXEMasterRevertTail {
    # SmartScreen (v1 lo apagaba; v2 lo quito de apply pero no limpiaba en revert)
    $ssKey='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    if((Get-RV $ssKey 'EnableSmartScreen') -ne $null){ Del-RV $ssKey 'EnableSmartScreen'; Write-AXELog 'Limpieza v1: EnableSmartScreen eliminado (restaura SmartScreen)' }
    # NoConnectedUser (v1 bloqueaba login Microsoft)
    $ncuKey='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if((Get-RV $ncuKey 'NoConnectedUser') -ne $null){ Del-RV $ncuKey 'NoConnectedUser'; Write-AXELog 'Limpieza v1: NoConnectedUser eliminado (desbloquea login MS)' }
    # hypervisorlaunchtype (v1 lo ponia off; rompia WSL2/Docker)
    $hv=((bcdedit /enum '{current}' | Out-String))
    if($hv -match 'hypervisorlaunchtype\s+Off'){ bcdedit /set hypervisorlaunchtype auto | Out-Null; Write-AXELog 'Limpieza v1: hypervisorlaunchtype -> auto (restaura WSL2/Docker)' }
    # useplatformtick / CoalescingTimerDisabled (v1 CPU avanzado)
    if($hv -match 'useplatformclock\s+Yes'){ bcdedit /deletevalue useplatformclock | Out-Null; Write-AXELog 'Limpieza v1: useplatformclock eliminado' }
    if((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'CoalescingTimerDisabled') -ne $null){ Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'CoalescingTimerDisabled'; Write-AXELog 'Limpieza v1: CoalescingTimerDisabled eliminado' }
    # Restaurar startup si hay backup
    Restore-Autorun | Out-Null
    Write-AXELog '=== MASTER REVERT completado. Reinicia el PC. ==='
}

# =====================================================
# REGION 10 - PERFIL EXPORT/IMPORT
# =====================================================
function Test-TweakSafe($tw){
    try { return [bool](& $tw.Test) } catch { return $false }
}
function Export-AXEProfile($file){
    $prof = foreach($tw in $script:CAT){ [pscustomobject]@{Id=$tw.Id; On=(Test-TweakSafe $tw)} }
    $prof | ConvertTo-Json -Depth 3 | Set-Content $file -Encoding UTF8
    Write-AXELog "Perfil exportado: $file ($($prof.Count) tweaks)"
}
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Import-AXEProfile($file){
    if(-not(Test-Path $file)){ Write-AXELog "No existe: $file" 'ERR'; return }
    if(-not (Test-Admin)){ Write-AXELog 'Import requiere admin. Ejecuta via AXE.bat (se eleva solo) o como administrador.' 'ERR'; return }
    $data = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $applied=0; $errors=0
    foreach($e in $data){
        $tw = $script:CAT | Where-Object Id -eq $e.Id
        if(-not $tw){ continue }
        if(Get-BlockReason $tw){ continue }
        try {
            if($e.On){
                # Mismo protocolo de snapshot que la GUI (57-gui-handlers:429). Import lo saltaba
                # en los DOS sentidos: aplicaba sin poner $capTweak (no capturaba nada) y revertia
                # llamando al scriptblock directo (ignorando lo capturado). Resultado: aplicar por
                # perfil dejaba el tweak sin estado previo guardado, asi que el revert posterior
                # caia al fallback -- que para varios tweaks escribe un default SUPUESTO, y para
                # gpu_mmcss borra valores que Windows trae de fabrica en la tarea Games.
                if(Test-SnapEligible $tw){ $script:capTweak=$tw.Id }
                try { & $tw.Apply } finally { $script:capTweak=$null }
                Commit-TweakState $tw.Id
            } else {
                # El scriptblock es el FALLBACK, no la via normal: solo si no hay estado previo
                # capturado (tweak aplicado fuera de AXE, o no elegible por usar powercfg/bcdedit).
                if(-not ((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){ & $tw.Revert }
            }
            $applied++
        } catch { $errors++; Write-AXELog "Error importando $($tw.Id): $($_.Exception.Message)" 'ERR' }
    }
    Write-AXELog "Perfil importado: $applied aplicados, $errors errores. Reinicia si hubo cambios."
}



# >>>>> MODULE: 30-profiles.ps1 >>>>>
# =====================================================
# REGION 10b - PERFILES POR-JUEGO (power-plan-per-game, live-safe)
# Detecta el juego corriendo -> cambia el plan de energia -> restaura al cerrar.
# Lever REAL en vivo (la freq policy cambia al instante). NO toca el proceso del juego
# (0 riesgo anticheat) ni aplica tweaks de registro (esos son reboot / solo-al-arrancar).
# =====================================================
$script:ProfilesBak = Join-Path $script:AXEData 'game_profiles.json'
$script:profActive   = $null    # nombre del perfil actualmente aplicado
$script:profPrevPlan = $null    # GUID del plan que estaba activo antes de aplicar (para restaurar)

function Read-Profiles {
    if(-not(Test-Path $script:ProfilesBak)){ return @() }
    $raw = Get-Content $script:ProfilesBak -Raw -Encoding UTF8
    if([string]::IsNullOrWhiteSpace($raw)){ return @() }
    try { return @($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return @() }
}
function Save-Profiles($list) {
    $arr = @($list)
    # forzar '[]' cuando esta vacio: si no, ConvertTo-Json no emite nada y Set-Content
    # no llega a escribir (dejaria el fichero anterior intacto = borrado que no borra).
    $json = if($arr.Count -eq 0){ '[]' } else { ConvertTo-Json -InputObject $arr -Depth 5 }
    Set-Content -Path $script:ProfilesBak -Value $json -Encoding UTF8
}
function Add-GameProfile($name,$exe,$plan,$planName) {
    $exe = ($exe -replace '\.exe$','')   # normaliza: guardamos el nombre de proceso sin extension
    $list = [System.Collections.ArrayList]@(Read-Profiles | Where-Object { $_.Name -ne $name })
    [void]$list.Add([pscustomobject]@{Name=$name; Exe=$exe; Plan=$plan; PlanName=$planName})
    Save-Profiles $list.ToArray()
    return $list.Count
}
function Remove-GameProfile($name) {
    Save-Profiles (@(Read-Profiles | Where-Object { $_.Name -ne $name }))
}
# ---- power plans (locale-agnostico: el GUID se extrae por regex) ----
function Get-PowerPlans {
    $out = New-Object System.Collections.ArrayList
    foreach($line in (powercfg /list 2>$null)){
        if($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}).*\(([^)]+)\)'){
            [void]$out.Add([pscustomobject]@{Guid=$matches[1]; Name=$matches[2].Trim()})
        }
    }
    $out
}
function Get-ActivePlan {
    $s = (powercfg /getactivescheme 2>$null | Out-String)
    if($s -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'){ return $matches[1] }
    return $null
}
function Set-ActivePlan($guid) {
    if([string]::IsNullOrWhiteSpace($guid)){ return $false }
    powercfg /setactive $guid 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Test-GameRunning($exe) {
    if([string]::IsNullOrWhiteSpace($exe)){ return $false }
    [bool](Get-Process -Name ($exe -replace '\.exe$','') -EA SilentlyContinue)
}
function Apply-GameProfile($p) {
    if($script:profActive -eq $p.Name){ return }   # idempotente
    $script:profPrevPlan = Get-ActivePlan
    if(Set-ActivePlan $p.Plan){
        $script:profActive = $p.Name
        Write-AXELog "Perfil '$($p.Name)' ON -> plan '$($p.PlanName)' (juego: $($p.Exe))."
    } else { Write-AXELog "Perfil '$($p.Name)': no pude cambiar el plan de energia." 'WARN' }
}
function Revert-GameProfile {
    if(-not $script:profActive){ return }
    $name = $script:profActive
    if($script:profPrevPlan){ Set-ActivePlan $script:profPrevPlan | Out-Null }
    Write-AXELog "Perfil '$name' OFF -> plan restaurado (juego cerrado)."
    $script:profActive = $null; $script:profPrevPlan = $null
}
# Un tick del monitor: aplica el perfil del juego que corre, o revierte si su juego cerro.
# Puro (sin timer) => testeable headless. Devuelve el nombre del perfil activo o $null.
function Tick-GameProfiles {
    if($script:busy){ return $script:profActive }   # no colisiona con APLICAR/MASTER/jobs
    $profs = Read-Profiles
    if($script:profActive){
        $ap = $profs | Where-Object { $_.Name -eq $script:profActive } | Select-Object -First 1
        if(-not $ap -or -not (Test-GameRunning $ap.Exe)){ Revert-GameProfile }
        return $script:profActive
    }
    foreach($p in $profs){ if(Test-GameRunning $p.Exe){ Apply-GameProfile $p; break } }
    return $script:profActive
}



# >>>>> MODULE: 31-gamegpu.ps1 >>>>>
# =====================================================
# REGION 10c - GPU POR JUEGO (el unico lever de FPS que mueve la aguja de verdad)
# =====================================================
# POR QUE ESTE MODULO EXISTE
#   El resto del catalogo son ajustes GLOBALES de Windows: quitan trabajo de fondo y bajan
#   jitter, pero ninguno le da mas GPU al juego, porque no hay mas GPU que dar. Aqui si:
#
#   1. GpuPreference=2  -> en un equipo con GPU hibrida (iGPU Intel/AMD + dGPU dedicada),
#      Windows decide por heuristica cual usa cada .exe. Cuando falla, el juego corre en la
#      integrada. Forzarlo a la dedicada no es un 3%: es 2-5x FPS. Es, con diferencia, el
#      mayor lever de rendimiento que existe en todo AXE. En equipos de UNA sola GPU no
#      hace absolutamente nada, y este modulo lo dice en vez de fingir.
#   2. SwapEffectUpgradeEnable=1 -> sube los juegos en ventana/borderless del modelo blt
#      (copia extra por frame, via DWM) al modelo flip (la GPU presenta directa). Menos
#      latencia y mas FPS reales en borderless, que es como juega la mayoria. Es la mitad
#      POR-JUEGO de la funcion que gpu_vrr (VRROptimizeEnable, HKLM) activa a nivel global:
#      el interruptor "Optimizaciones para juegos con ventana" de Win11 escribe LAS DOS.
#   3. DISABLEDXMAXIMIZEDWINDOWEDMODE -> apaga Fullscreen Optimizations en ese .exe. NO es
#      universalmente bueno: en muchos juegos FSO ya usa flip y quitarlo EMPEORA el alt-tab
#      sin dar FPS. Va aparte y opt-in por eso, no metido en el boton de "optimizar".
#
# FORMATO DEL REGISTRO (verificado en build 26200, no deducido):
#   HKCU\SOFTWARE\Microsoft\DirectX\UserGpuPreferences
#     nombre = ruta completa del exe, valor = cadena "Clave=Valor;" concatenada.
#     Windows gestiona ahi tambien 'AppStatus' por su cuenta => se PRESERVAN las claves que
#     no tocamos. Reescribir la cadena entera seria borrarle estado al sistema.
#   HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers
#     nombre = ruta completa del exe, valor = tokens separados por espacio (HIGHDPIAWARE...).
#     Mismo criterio: se anade/quita UN token, el resto se respeta.
#
# REVERT: se captura la cadena ORIGINAL entera la primera vez que se toca un exe, igual que
# hace Push-RegBackup con los tweaks. Si el exe no tenia entrada, el revert la BORRA. No se
# escribe nunca un default supuesto (mismo principio que cpu_park / rend_ultperf).
# =====================================================

$script:GpuPrefKey  = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
$script:LayersKey   = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$script:GameGpuBak  = Join-Path $script:AXEData 'game_gpu.json'
$script:FSOToken    = 'DISABLEDXMAXIMIZEDWINDOWEDMODE'

# ---- parser del formato "K=V;K=V;" -------------------------------------------------
# Tolera la basura real que hay en el registro: cadenas que empiezan por ';', pares sin
# '=', espacios sueltos. Devuelve [ordered] para que reescribir no baraje el orden.
function ConvertFrom-AXEGpuPref($raw){
    $h = [ordered]@{}
    if([string]::IsNullOrWhiteSpace($raw)){ return $h }
    foreach($part in ($raw -split ';')){
        $p = $part.Trim()
        if([string]::IsNullOrWhiteSpace($p)){ continue }
        $i = $p.IndexOf('=')
        if($i -lt 1){ continue }
        $h[$p.Substring(0,$i).Trim()] = $p.Substring($i+1).Trim()
    }
    return $h
}
function ConvertTo-AXEGpuPref($h){
    $sb = New-Object System.Text.StringBuilder
    foreach($k in $h.Keys){ [void]$sb.Append("$k=$($h[$k]);") }
    return $sb.ToString()
}

# ---- topologia de GPU: solo asi sabemos si GpuPreference sirve de algo ---------------
# Cache permanente: la lista de adaptadores no cambia durante la sesion.
function Get-AXEGpuList {
    Get-AXECache 'pnp:gpulist' {
        @(Get-CimInstance Win32_VideoController -EA SilentlyContinue |
            Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual|Basic Display|Remote|Meta|Parsec' })
    } -Permanent
}
function Test-AXEHybridGpu { (Get-AXEGpuList).Count -gt 1 }

# ---- snapshot (mismo contrato que tweak_state.json, fichero aparte) -------------------
function Read-GameGpuBak {
    if(-not(Test-Path $script:GameGpuBak)){ return @{} }
    try {
        $raw = Get-Content $script:GameGpuBak -Raw -Encoding UTF8
        if([string]::IsNullOrWhiteSpace($raw)){ return @{} }
        $o = $raw | ConvertFrom-Json -ErrorAction Stop
        $h = @{}; foreach($pr in $o.PSObject.Properties){ $h[$pr.Name] = $pr.Value }
        return $h
    } catch {
        Write-AXELog "game_gpu.json ilegible: $($_.Exception.Message). Renombrado a .corrupt" 'ERR'
        try { Move-Item $script:GameGpuBak "$($script:GameGpuBak).corrupt" -Force -EA Stop } catch {}
        return @{}
    }
}
function Save-GameGpuBak($h){ ($h | ConvertTo-Json -Depth 5) | Set-Content $script:GameGpuBak -Encoding UTF8 }

# Captura el estado previo de UN exe en UNA clave. Solo la primera vez (igual que
# Push-RegBackup): si vuelves a optimizar el mismo juego, el original sigue siendo el de la
# primera vez, no el que dejo AXE en la pasada anterior.
function Push-GameGpuBackup($exe,$key){
    $store = Read-GameGpuBak
    $id = "$key|$exe"
    if($store.ContainsKey($id)){ return }
    $rec = @{ Exe=$exe; Key=$key; Had=$false; V=$null }
    $v = Get-RV $key $exe
    if($null -ne $v){ $rec.Had = $true; $rec.V = [string]$v }
    $store[$id] = $rec
    Save-GameGpuBak $store
}

# ---- lectura de estado (para la GUI / Test) -----------------------------------------
function Get-AXEGameGpuState($exe){
    $pref = ConvertFrom-AXEGpuPref (Get-RV $script:GpuPrefKey $exe)
    $lay  = [string](Get-RV $script:LayersKey $exe)
    [pscustomobject]@{
        Exe       = $exe
        HighPerf  = ($pref['GpuPreference'] -eq '2')
        FlipModel = ($pref['SwapEffectUpgradeEnable'] -eq '1')
        NoFSO     = ($lay -split '\s+' -contains $script:FSOToken)
        Raw       = (Get-RV $script:GpuPrefKey $exe)
        RawLayers = $lay
    }
}

# ---- escritura ----------------------------------------------------------------------
# $HighPerf/$FlipModel son [bool] con $null = "no tocar", para poder cambiar una sola cosa
# sin arrastrar la otra.
function Set-AXEGameGpuPref {
    param([Parameter(Mandatory)][string]$Exe, $HighPerf = $null, $FlipModel = $null)
    if($null -eq $HighPerf -and $null -eq $FlipModel){ return }
    Push-GameGpuBackup $Exe $script:GpuPrefKey
    $h = ConvertFrom-AXEGpuPref (Get-RV $script:GpuPrefKey $Exe)
    # GpuPreference: 0=lo decide Windows, 1=ahorro (iGPU), 2=alto rendimiento (dGPU).
    # Apagarlo = volver a 0 (delegar), NO borrar la clave: borrarla y dejar la entrada del
    # exe a medias deja a Windows con una cadena que el no escribio.
    if($null -ne $HighPerf) { $h['GpuPreference']           = $(if($HighPerf) {'2'}else{'0'}) }
    if($null -ne $FlipModel){ $h['SwapEffectUpgradeEnable'] = $(if($FlipModel){'1'}else{'0'}) }
    Set-RS $script:GpuPrefKey $Exe (ConvertTo-AXEGpuPref $h)
}

function Set-AXEGameFSO {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][bool]$Disable)
    Push-GameGpuBackup $Exe $script:LayersKey
    $cur = [string](Get-RV $script:LayersKey $Exe)
    $toks = @($cur -split '\s+' | Where-Object { $_ -and $_ -ne $script:FSOToken })
    if($Disable){ $toks += $script:FSOToken }
    if($toks.Count -eq 0){
        # Sin tokens no se deja una cadena vacia: eso es una entrada muerta en Layers.
        Remove-ItemProperty -Path $script:LayersKey -Name $Exe -EA SilentlyContinue
    } else {
        Set-RS $script:LayersKey $Exe (($toks | Select-Object -Unique) -join ' ')
    }
}

# ---- revert ------------------------------------------------------------------------
# Devuelve el numero de claves restauradas. 0 = no habia snapshot (nunca se optimizo ese
# exe con AXE) y NO se toca nada: no se inventa un estado.
function Revert-AXEGameGpu($exe){
    $store = Read-GameGpuBak
    $n = 0
    foreach($id in @($store.Keys)){
        $r = $store[$id]
        if($r.Exe -ne $exe){ continue }
        try {
            if($r.Had){ Set-RS $r.Key $r.Exe $r.V }
            else      { Remove-ItemProperty -Path $r.Key -Name $r.Exe -EA SilentlyContinue }
            $store.Remove($id); $n++
        } catch { Write-AXELog "Revert GPU '$exe': fallo en $($r.Key): $($_.Exception.Message)" 'ERR' }
    }
    if($n -gt 0){ Save-GameGpuBak $store }
    return $n
}

# ---- accion de alto nivel ----------------------------------------------------------
# Aplica lo que SI es seguro-bueno para un juego: dGPU (si hay de donde elegir) + flip model.
# FSO queda fuera a proposito (ver cabecera). Devuelve lineas de log como los Run de
# Add-Clean, para poder llamarse desde runspace de fondo sin tocar Write-AXELog.
function Optimize-AXEGame {
    param([Parameter(Mandatory)][string]$Exe, [switch]$NoFSO)
    $out = New-Object System.Collections.ArrayList
    if(-not (Test-Path -LiteralPath $Exe)){
        [void]$out.Add("ERROR: no existe '$Exe'. Hace falta la RUTA COMPLETA del .exe (Windows indexa por ruta, no por nombre de proceso).")
        return $out.ToArray()
    }
    $hybrid = Test-AXEHybridGpu
    Set-AXEGameGpuPref -Exe $Exe -HighPerf $hybrid -FlipModel $true
    if($hybrid){
        $gpus = (Get-AXEGpuList | Select-Object -Expand Name) -join ' + '
        [void]$out.Add("GPU alto rendimiento forzada ($gpus). Este es el ajuste que mas FPS mueve de toda la suite.")
    } else {
        [void]$out.Add("Una sola GPU ($((Get-AXEGpuList | Select-Object -First 1 -Expand Name))): GpuPreference no aplica, no se fuerza. Ganancia por esta via = 0.")
    }
    [void]$out.Add('Flip model activado (SwapEffectUpgradeEnable=1): menos latencia en ventana/borderless.')
    if($NoFSO){
        Set-AXEGameFSO -Exe $Exe -Disable $true
        [void]$out.Add('Fullscreen Optimizations OFF. OJO: en muchos juegos esto NO da FPS y empeora el alt-tab. Mide antes/despues.')
    }
    [void]$out.Add('Los cambios entran al ARRANCAR el juego, no en caliente. Cierralo y abrelo.')
    return $out.ToArray()
}


# >>>>> MODULE: 32-measure.ps1 >>>>>
# =====================================================
# REGION 8b - MEDICION (Trust & Proof): timer resolution + jitter proxy + score
# =====================================================
# Capa nativa: P/Invoke NtQueryTimerResolution + busy-loop de jitter en C# compilado
# (el loop debe ser nativo; un loop PowerShell mediria el interprete, no el scheduler).
# Cargada UNA vez al init del modulo en el hilo principal; los runspaces de fondo ven
# el tipo (mismo AppDomain). C# compat-safe (csc 5.1 + Roslyn 7): C# 5, sin record.
if(-not ('AXE.Native' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;
namespace AXE {
  public static class Native {
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int NtQueryTimerResolution(out uint Min, out uint Max, out uint Current);

    // Unidades de 100ns, igual que Query. SetResolution=false LIBERA el request de este proceso.
    // OJO Win11 2004+: sin GlobalTimerResolutionRequests=1 el efecto es SOLO de este proceso.
    [DllImport("ntdll.dll", SetLastError=true)]
    public static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);

    // Nucleo del barrido: mide cuanto se PASA de largo un Sleep(1) a la resolucion actual.
    // El DELTA (no el absoluto) es la senal: a mejor resolucion el scheduler despierta mas
    // cerca del 1ms pedido. Debe ser nativo - un Sleep en bucle de PowerShell mediria el
    // interprete. Devuelve {samples, avgDeltaMs, maxDeltaMs, stdevMs}.
    public static double[] MeasureSleepDelta(int samples) {
      if (samples < 1) samples = 1;
      double toMs = 1000.0 / (double)Stopwatch.Frequency;
      double[] vals = new double[samples];
      double sum = 0.0, max = 0.0;
      for (int i = 0; i < samples; i++) {
        long t0 = Stopwatch.GetTimestamp();
        System.Threading.Thread.Sleep(1);
        double delta = ((Stopwatch.GetTimestamp() - t0) * toMs) - 1.0;
        if (delta < 0.0) delta = 0.0;          // Sleep nunca vuelve antes; clamp del ruido de QPC
        vals[i] = delta; sum += delta;
        if (delta > max) max = delta;
      }
      double avg = sum / samples;
      double sq = 0.0;
      for (int i = 0; i < samples; i++) { double d = vals[i] - avg; sq += d * d; }
      return new double[] { (double)samples, avg, max, Math.Sqrt(sq / samples) };
    }

    // Devuelve {samples, meanMs, maxMs, p999Ms, stalls1ms}. Histograma acotado (memoria O(1)).
    public static double[] SampleJitter(int durationMs) {
      double freq = (double)Stopwatch.Frequency;
      double toMs = 1000.0 / freq;
      long endTicks = Stopwatch.GetTimestamp() + (long)(freq * durationMs / 1000.0);
      int B = 2000; double bw = 0.05;            // 2000 buckets x 0.05ms = 0..100ms
      long[] hist = new long[B];
      long n = 0; double sum = 0.0, max = 0.0; long stalls = 0;
      long prev = Stopwatch.GetTimestamp();
      while (true) {
        long now = Stopwatch.GetTimestamp();
        double gapMs = (now - prev) * toMs;
        prev = now;
        n++; sum += gapMs; if (gapMs > max) max = gapMs; if (gapMs > 1.0) stalls++;
        int bi = (int)(gapMs / bw); if (bi < 0) bi = 0; if (bi >= B) bi = B - 1;
        hist[bi]++;
        if (now >= endTicks) break;
      }
      double p999 = 0.0; long target = (long)Math.Ceiling(0.999 * n); long cum = 0;
      for (int i = 0; i < B; i++) { cum += hist[i]; if (cum >= target) { p999 = (i + 1) * bw; break; } }
      double mean = n > 0 ? sum / n : 0.0;
      return new double[] { (double)n, mean, max, p999, (double)stalls };
    }

    // ---- Standby list purge (ISLC-style). Requiere admin (SeProfileSingleProcessPrivilege). ----
    [DllImport("ntdll.dll")]
    static extern int NtSetSystemInformation(int InfoClass, IntPtr Info, int Length);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool LookupPrivilegeValue(string host, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKEN_PRIVILEGES newst, int len, IntPtr prev, IntPtr rl);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool CloseHandle(IntPtr h);

    [StructLayout(LayoutKind.Sequential, Pack=4)]
    struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public long Luid; public uint Attributes; }

    const int SystemMemoryListInformation = 0x50;
    const int MemoryPurgeStandbyList = 4;
    const uint TOKEN_ADJUST_PRIVILEGES = 0x20, TOKEN_QUERY = 0x08;
    const uint SE_PRIVILEGE_ENABLED = 0x2;

    // Vacia la standby list (paginas en cache reclamables). NTSTATUS 0 = OK; negativo propio = fallo de privilegio.
    public static int PurgeStandby() {
      IntPtr tok = IntPtr.Zero;
      if(!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out tok)) return -1;
      try {
        long luid;
        if(!LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out luid)) return -2;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1; tp.Luid = luid; tp.Attributes = SE_PRIVILEGE_ENABLED;
        if(!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return -3;
        if(Marshal.GetLastWin32Error() != 0) return -4;   // ERROR_NOT_ALL_ASSIGNED: sin admin
        IntPtr p = Marshal.AllocHGlobal(sizeof(int));
        try { Marshal.WriteInt32(p, MemoryPurgeStandbyList); return NtSetSystemInformation(SystemMemoryListInformation, p, sizeof(int)); }
        finally { Marshal.FreeHGlobal(p); }
      } finally { CloseHandle(tok); }
    }

    // ---- Game Session: Job Object + freeze (subsistema A, spec 2026-07-20) ----
    // La red de seguridad es del KERNEL: al cerrarse el handle del job (JobClose, o la muerte del
    // proceso AXE por crash/kill/BSOD) Windows DESCONGELA solo todo lo asignado. No hay codigo de
    // recuperacion que pueda a su vez fallar. JobObjectFreezeInformation esta semi-documentada:
    // JobProbeFreeze() sondea si existe en ESTE Windows antes de congelar nada; si no, el llamante
    // aborta limpio (sin fallback a suspension manual: eso seria otro spec).
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("ntdll.dll")]
    static extern int NtSetInformationJobObject(IntPtr hJob, int JobObjectInformationClass, IntPtr JobObjectInformation, int Length);

    const int JobObjectFreezeInformation = 18;              // clase no documentada (ntpsapi reversado)
    const uint JOB_OBJECT_OPERATION_FREEZE = 0x1;           // el bit Freeze de Flags es valido
    const uint PROCESS_SET_QUOTA = 0x0100, PROCESS_TERMINATE = 0x0001;  // lo que exige AssignProcessToJobObject

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_FREEZE_INFORMATION {
      public uint Flags; public byte Freeze; public byte Swap; public byte R0; public byte R1;
      public uint HighEdgeFilter; public uint LowEdgeFilter;   // JOBOBJECT_WAKE_FILTER (no usado)
    }

    // Crea un job anonimo. IntPtr.Zero si falla.
    public static IntPtr JobCreate() { return CreateJobObject(IntPtr.Zero, null); }

    // Asigna un PID al job. 0 = OK; -1 = no pude abrir el proceso; -2 = assign fallo. Un pid
    // protegido (assign falla) NO tumba la sesion: el llamante cuenta y sigue.
    public static int JobAssignPid(IntPtr hJob, int pid) {
      IntPtr hp = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE, false, (uint)pid);
      if (hp == IntPtr.Zero) return -1;
      bool ok = AssignProcessToJobObject(hJob, hp);
      CloseHandle(hp);
      return ok ? 0 : -2;
    }

    // Congela (freeze=true) o descongela (freeze=false) el job entero. Devuelve NTSTATUS (0 = OK).
    static int SetFreeze(IntPtr hJob, bool freeze) {
      JOBOBJECT_FREEZE_INFORMATION fi = new JOBOBJECT_FREEZE_INFORMATION();
      fi.Flags = JOB_OBJECT_OPERATION_FREEZE;
      fi.Freeze = (byte)(freeze ? 1 : 0);
      int len = Marshal.SizeOf(typeof(JOBOBJECT_FREEZE_INFORMATION));
      IntPtr p = Marshal.AllocHGlobal(len);
      try { Marshal.StructureToPtr(fi, p, false); return NtSetInformationJobObject(hJob, JobObjectFreezeInformation, p, len); }
      finally { Marshal.FreeHGlobal(p); }
    }
    public static int JobFreeze(IntPtr hJob) { return SetFreeze(hJob, true); }
    public static int JobThaw(IntPtr hJob) { return SetFreeze(hJob, false); }

    // Cierra el handle del job -> el kernel descongela TODO lo asignado. La red de seguridad.
    public static bool JobClose(IntPtr hJob) { return CloseHandle(hJob); }

    // Sonda: crea un job vacio e intenta congelar/descongelar. Devuelve el NTSTATUS del freeze.
    // 0 => JobObjectFreezeInformation soportado aqui. !=0 => NO; el llamante no debe congelar nada.
    public static int JobProbeFreeze() {
      IntPtr j = CreateJobObject(IntPtr.Zero, null);
      if (j == IntPtr.Zero) return unchecked((int)0x80000000);   // no pude ni crear el job
      try { int s = SetFreeze(j, true); if (s == 0) SetFreeze(j, false); return s; }
      finally { CloseHandle(j); }
    }
  }
}
'@
}

function Get-AXETimerResolution {
    # NtQueryTimerResolution devuelve unidades de 100ns. Current/10000 = ms. Menor = mejor.
    try {
        $min=0; $max=0; $cur=0
        $rc = [AXE.Native]::NtQueryTimerResolution([ref]$min,[ref]$max,[ref]$cur)
        if($rc -ne 0){ return $null }
        # Windows 10 2004 (build 19041) aisla los requests de resolucion POR PROCESO. Desde ahi,
        # CurrentMs NO refleja configuracion: refleja lo que pida la app que este corriendo en
        # ese instante. Lo unico accionable es GlobalTimerResolutionRequests, que devuelve el
        # comportamiento global. Por eso se leen juntos: puntuar CurrentMs a secas castiga
        # maquinas bien configuradas solo porque en ese segundo nadie pedia 0.5ms.
        # Ref: https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod
        #   Measure-AXETimerSweep usa este MISMO corte para su aviso. Uso 22000 (Win11) hasta
        #   2026-07-19, con lo que los builds 19041-19045 aislaban y no recibian el aviso.
        $isolated = ([Environment]::OSVersion.Version.Build -ge 19041)
        $gtrr = $null
        try {
            # Cmdlet nativo a posta, sin Get-RV: esta funcion corre tambien en runspaces de
            # fondo (GUI) donde solo estan las funciones de la lista blanca.
            $gtrr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' `
                        -Name 'GlobalTimerResolutionRequests' -EA Stop).GlobalTimerResolutionRequests
        } catch {}
        [pscustomobject]@{
            CurrentMs        = [math]::Round($cur/10000.0,4)
            MinMs            = [math]::Round($min/10000.0,4)   # peor (mayor numero)
            MaxMs            = [math]::Round($max/10000.0,4)   # mejor posible (menor numero)
            PerProcess       = $isolated                        # CurrentMs es ambiental, no config
            GlobalRequests   = $gtrr                            # $null = clave ausente
        }
    } catch { $null }
}

function Set-AXETimerResolution {
    # $Ms en milisegundos -> unidades de 100ns. -Release suelta el request de ESTE proceso.
    # Devuelve la resolucion resultante en ms, o $null si el kernel la rechazo.
    param([double]$Ms,[switch]$Release)
    try {
        $cur=0
        if($Release){
            # STATUS_TIMER_RESOLUTION_NOT_SET (0xC0000245) si no habia request nuestro: no es error.
            [void][AXE.Native]::NtSetTimerResolution(0,$false,[ref]$cur)
        } else {
            $units=[uint32][math]::Round($Ms*10000.0)
            if([AXE.Native]::NtSetTimerResolution($units,$true,[ref]$cur) -ne 0){ return $null }
        }
        [math]::Round($cur/10000.0,4)
    } catch { $null }
}

function Get-AXESweepVerdict {
    # Decide si el barrido encontro algo REAL o esta persiguiendo ruido. Pura (no mide) para
    # poder testearla sin hardware: ver tests/TimerSweep.Tests.ps1.
    #
    # Reemplaza al test anterior ($spread -gt $best.StdevMs), que fallaba por dos motivos:
    #
    #  1. ARGMIN DE N PUNTOS RUIDOSOS. Coger el minimo de ~50 medias con ruido y luego
    #     preguntar "el spread supera al ruido?" es la maldicion del ganador: el minimo de N
    #     sorteos cae sistematicamente por debajo del minimo real, asi que sale un spread de
    #     3-4 sigmas SOLO POR AZAR, sin que haya efecto. Medido en Win11 26200: declaro
    #     concluyente ganando por 0.001ms (spread 0.250 vs stdev 0.249).
    #     Arreglo: umbral Bonferroni sobre el numero de comparaciones, y el error estimado con
    #     la varianza AGRUPADA entre pasadas (dof grande) en vez de la stdev intra-punto de un
    #     solo punto, que con 2-3 pasadas no estima nada.
    #
    #  2. NO COMPROBABA LA FISICA. Sleep(1) con granularidad R despierta en el primer tick
    #     >= 1ms, o sea ceil(1/R)*R, luego el delta teorico es ceil(1/R)*R-1: CRECIENTE entre
    #     0.5 y 1.0ms. En la maquina medida el delta DECRECIA - curva invertida. Eso significa
    #     que lo medido es overhead de despertar del scheduler (~0.4ms), no cuantizacion del
    #     timer (rango total 0.2ms): la senal esta enterrada bajo el ruido.
    #     Sin este chequeo la estadistica sola SI daba "concluyente" en ese barrido, o sea que
    #     arreglar solo el punto 1 no habria bastado.
    #
    # Ambas condiciones son necesarias. Devuelve Reason para que la UI diga POR QUE.
    param([object[]]$Points)

    $P = @($Points | Where-Object { $_ -and @($_.PassMeans).Count -ge 1 })
    if($P.Count -le 1){
        return [pscustomobject]@{
            Conclusive  = $false
            Reason      = 'un solo punto concedido: el kernel cuantizo todo, no hay nada que elegir.'
            Best        = $(if($P.Count -eq 1){ $P[0] } else { $null })
            Worst       = $null
            SpreadMs    = 0.0
            ThresholdMs = 0.0
            ModelR      = $null
        }
    }

    $stats = @(foreach($p in $P){
        $pm = @($p.PassMeans)
        [pscustomobject]@{
            Point     = $p
            AppliedMs = [double]$p.AppliedMs
            Mean      = ($pm | Measure-Object -Average).Average
            N         = $pm.Count
        }
    })

    # Varianza agrupada entre pasadas. Cada punto aporta pocos grados de libertad (2-3
    # pasadas), pero el ruido del scheduler es el mismo en todas las resoluciones, asi que
    # agrupar da dof ~= 2*N y una estimacion usable. Es el MSE de un ANOVA de un factor.
    $ss = 0.0; $dof = 0
    foreach($s in $stats){
        if($s.N -lt 2){ continue }
        foreach($x in @($s.Point.PassMeans)){ $d = [double]$x - $s.Mean; $ss += $d*$d }
        $dof += ($s.N - 1)
    }
    $pooledVar = $(if($dof -gt 0){ $ss / $dof } else { 0.0 })

    $best   = $stats | Sort-Object Mean | Select-Object -First 1
    $worst  = $stats | Sort-Object Mean -Descending | Select-Object -First 1
    $spread = $worst.Mean - $best.Mean
    $seDiff = [math]::Sqrt($pooledVar * (1.0/$best.N + 1.0/$worst.N))

    # Bonferroni: el mejor se compara contra los otros N-1 puntos, asi que el umbral sube con
    # N. Valores = z bilateral a alpha=0.05/comparaciones. Interpolado con Get-AXEBand para no
    # meter una inversa de la normal por 7 numeros. Aproximado a posta: entre z=3.3 y z=4.0
    # casi nunca cambia el veredicto; lo que importa es que CREZCA con N.
    $nComp = $stats.Count - 1
    $k = Get-AXEBand -x $nComp -pairs @(@(1,1.96),@(2,2.24),@(5,2.58),@(10,2.81),@(20,3.02),@(50,3.29),@(100,3.48))
    $threshold = $k * $seDiff
    $statOk = $(if($seDiff -gt 0){ $spread -gt $threshold } else { $spread -gt 0 })

    # Modelo fisico: delta teorico = ceil(1/R)*R - 1. Si las resoluciones concedidas predicen
    # todas el mismo delta (p.ej. solo 0.500 y 1.000, ambas 0), el modelo no discrimina: el
    # chequeo se salta porque no puede opinar. Si discrimina, exigimos correlacion positiva.
    $modelR = $null; $modelOk = $true
    $pred = @(foreach($s in $stats){ [math]::Ceiling(1.0/$s.AppliedMs)*$s.AppliedMs - 1.0 })
    $meas = @(foreach($s in $stats){ $s.Mean })
    $mx = ($pred | Measure-Object -Average).Average
    $my = ($meas | Measure-Object -Average).Average
    $sxy = 0.0; $sxx = 0.0; $syy = 0.0
    for($i=0; $i -lt $pred.Count; $i++){
        $dx = $pred[$i] - $mx; $dy = $meas[$i] - $my
        $sxy += $dx*$dy; $sxx += $dx*$dx; $syy += $dy*$dy
    }
    if($sxx -gt 0 -and $syy -gt 0){
        $modelR  = $sxy / [math]::Sqrt($sxx * $syy)
        $modelOk = ($modelR -ge 0.3)
    }

    # Orden a posta: el fallo del modelo es mas fundamental que el estadistico. Si la curva no
    # tiene la forma que dicta la fisica, que el spread sea "significativo" da igual.
    $reason =
        if(-not $modelOk){
            "la curva medida no sigue el modelo de cuantizacion (r={0:F2}): domina el overhead del scheduler, no la resolucion." -f $modelR
        } elseif(-not $statOk){
            "spread {0:F3}ms no supera el umbral {1:F3}ms (ruido entre pasadas x{2:F2} por {3} comparaciones)." -f $spread,$threshold,$k,$nComp
        } else {
            "spread {0:F3}ms supera el umbral {1:F3}ms y la curva sigue el modelo (r={2:F2})." -f $spread,$threshold,$modelR
        }

    [pscustomobject]@{
        Conclusive  = [bool]($modelOk -and $statOk)
        Reason      = $reason
        Best        = $best.Point
        Worst       = $worst.Point
        SpreadMs    = [math]::Round($spread,4)
        ThresholdMs = [math]::Round($threshold,4)
        ModelR      = $(if($null -eq $modelR){ $null } else { [math]::Round($modelR,3) })
    }
}

function Measure-AXETimerSweep {
    # §3.5 - Barrido de resolucion de timer. Motivo: la investigacion de valleyofdoom midio
    # que 0.500ms NO es optima en todas las maquinas (a varios candidatos 0.507ms les daba
    # MENOS delta, y un portatil necesitaba 0.600ms), sin poder explicar por que tras comparar
    # BCD, hardware, timers y version de Windows. O sea: el optimo es POR MAQUINA y hay que
    # medirlo. Esto lo mide en vez de asumirlo.
    #   Senal = delta medio de un Sleep(1). Menor delta = el scheduler despierta mas cerca
    #   de lo pedido. Se reporta tambien stdev: un delta bajo con stdev alta es ruido, no ganancia.
    # Ref: https://github.com/valleyofdoom/TimerResolution
    param(
        [double]$StartMs = 0.5,
        [double]$EndMs   = 0.6,
        [double]$StepMs  = 0.002,
        [int]$Samples    = 200,
        [int]$Passes     = 3
    )
    if(-not ('AXE.Native' -as [type])){ return $null }
    if(-not [AXE.Native].GetMethod('MeasureSleepDelta')){
        Write-AXELog 'AXE.Native cargado sin MeasureSleepDelta (tipo obsoleto en esta sesion). Reinicia AXE.' 'ERR'
        return $null
    }
    if($StepMs -le 0 -or $EndMs -lt $StartMs){ Write-AXELog 'Barrido: rango invalido.' 'ERR'; return $null }

    # Aviso honesto: desde Windows 10 2004 el request es por-proceso salvo que este el flag
    # global. Sin el, el optimo que encontremos vale para AXE, NO para el juego.
    #   El corte es 19041 (Win10 2004), no 22000 (Win11). Con 22000, los builds 19041-19045
    # aislaban igual y NO recibian el aviso: justo las maquinas que mas lo necesitan, porque en
    # Win10 nadie espera este comportamiento. Mismo umbral que Get-AXETimerResolution, que ya lo
    # tenia bien; que los dos sitios usaran cortes distintos era la incoherencia de fondo.
    try {
        if([Environment]::OSVersion.Version.Build -ge 19041 -and
           (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests') -ne 1){
            Write-AXELog 'Sin GlobalTimerResolutionRequests=1 (Win10 2004+): el optimo medido aplica solo a este proceso. Activa lat_timerres y reinicia para que valga a nivel sistema.' 'WARN'
        }
    } catch {}

    $orig = Get-AXETimerResolution
    $proc = [System.Diagnostics.Process]::GetCurrentProcess()
    $prio = $proc.PriorityClass
    $out  = New-Object System.Collections.ArrayList
    try {
        # Prioridad alta: baja el ruido de otros procesos en el delta. No RealTime (puede colgar la UI).
        try { $proc.PriorityClass='High' } catch {}
        # ORDEN ALEATORIO, N PASADAS. Un barrido ascendente de una pasada CONFUNDE resolucion
        # con tiempo: cualquier deriva del sistema durante el barrido (turbo, termica, otro
        # proceso despertando) se leeria como si fuera efecto de la resolucion, porque ambas
        # avanzan juntas. Medido: una pasada ascendente dibujo una curva en U preciosa que
        # NO se puede distinguir de deriva. Aleatorizar rompe esa correlacion; repetir permite
        # medir repetibilidad (ReproMs) en vez de suponerla.
        $plan = New-Object System.Collections.ArrayList
        for($p=0; $p -lt [math]::Max(1,$Passes); $p++){
            for($ms=$StartMs; $ms -le ($EndMs + 1e-9); $ms += $StepMs){ [void]$plan.Add($ms) }
        }
        foreach($ms in ($plan | Sort-Object { Get-Random })){
            $applied = Set-AXETimerResolution -Ms $ms
            if($null -eq $applied){ continue }
            [void][AXE.Native]::MeasureSleepDelta(5)          # warm-up, descartado
            $r = [AXE.Native]::MeasureSleepDelta([int]$Samples)
            [void]$out.Add([pscustomobject]@{
                RequestedMs = [math]::Round($ms,4)
                AppliedMs   = $applied
                AvgDeltaMs  = [math]::Round($r[1],4)
                MaxDeltaMs  = [math]::Round($r[2],4)
                StdevMs     = [math]::Round($r[3],4)
                Samples     = [int]$r[0]
            })
        }
    } finally {
        # Siempre soltar el request y restaurar prioridad, aunque el barrido reviente.
        [void](Set-AXETimerResolution -Release)
        try { $proc.PriorityClass=$prio } catch {}
    }
    if($out.Count -eq 0){ Write-AXELog 'Barrido: el kernel rechazo todas las resoluciones.' 'ERR'; return $null }

    # El kernel CUANTIZA: varios Requested distintos aterrizan en el mismo Applied real.
    # Comparar por Requested fabricaria un "optimo" entre puntos fisicamente identicos
    # (medido: dos filas con Applied=0.50 dieron avgDelta 0.59 y 0.36 - eso es ruido puro).
    # Se agrega por Applied, que es la unica magnitud que el hardware distingue de verdad.
    $agg = New-Object System.Collections.ArrayList
    foreach($grp in ($out | Group-Object AppliedMs)){
        $m = $grp.Group | Measure-Object AvgDeltaMs -Average -Maximum
        [void]$agg.Add([pscustomobject]@{
            # NO usar [double]$grp.Name: Group-Object serializa con la cultura del sistema
            # ("0,5" en es-ES) y el cast [double] parsea con InvariantCulture, donde la coma
            # es separador de MILES -> 0,5 se convierte en 5 y 0,51 en 51. Silencioso y falso.
            # El valor original del grupo no pasa por string, asi que es inmune al locale.
            AppliedMs   = $grp.Group[0].AppliedMs
            # Medias POR PASADA, sin agregar. Son la unidad de observacion del veredicto:
            # pasadas separadas en el tiempo y en orden aleatorio, luego su dispersion SI
            # estima el ruido real. La stdev intra-pasada no, porque las muestras dentro de
            # una pasada estan autocorreladas (el sistema deriva durante los 200 sleeps).
            PassMeans   = @($grp.Group | ForEach-Object AvgDeltaMs)
            AvgDeltaMs  = [math]::Round($m.Average,4)
            MaxDeltaMs  = [math]::Round(($grp.Group | Measure-Object MaxDeltaMs -Maximum).Maximum,4)
            # Stdev intra-punto mas alta del grupo: cota superior honesta del ruido.
            StdevMs     = [math]::Round(($grp.Group | Measure-Object StdevMs -Maximum).Maximum,4)
            # Dispersion ENTRE repeticiones del mismo Applied: si es alta, la medida no es repetible.
            ReproMs     = [math]::Round($m.Maximum - $m.Average,4)
            Passes      = $grp.Count
            Samples     = ($grp.Group | Measure-Object Samples -Sum).Sum
        })
    }
    # Win11 2004+ aisla el request POR PROCESO. Cuando el nuestro no se concede, el sleep cae
    # al default de 15.6ms AUNQUE NtSetTimerResolution reporte exito y devuelva la resolucion
    # del SISTEMA (que otro proceso mantiene). Medido aqui: 10 de 13 puntos reportaron
    # AppliedMs=1.0 mientras dormian 15.6ms reales. El valor reportado MIENTE; el delta no.
    # Por eso el corte es por delta medido, no por lo que dice el kernel.
    $granted    = @($agg | Where-Object { $_.AvgDeltaMs -lt 5.0 })
    $notGranted = @($agg | Where-Object { $_.AvgDeltaMs -ge 5.0 })
    if($notGranted.Count -gt 0){
        Write-AXELog "Barrido: $($notGranted.Count) de $($agg.Count) resoluciones no se concedieron a este proceso (sleeps de ~15.6ms). Sintoma tipico del aislamiento por-proceso de Win11: activa lat_timerres y reinicia." 'WARN'
    }
    if($granted.Count -eq 0){
        Write-AXELog 'Barrido: ningun request concedido. Sin datos utiles.' 'ERR'
        return $null
    }
    # Comparar SOLO entre resoluciones concedidas. Mezclar concedidas con fallbacks a 15.6ms
    # daria un spread enorme y un "Conclusive" falso: mediria "obtener el request vs no
    # obtenerlo", que no es la pregunta. La pregunta es cual resolucion concedida es mejor.
    # El veredicto vive en Get-AXESweepVerdict: logica pura, con tests, sin hardware. Aqui solo
    # se mide. Antes se decidia inline y por eso el bug (comparar contra la stdev intra-punto)
    # sobrevivio: no habia forma de testearlo sin un barrido real de 60s.
    $v = Get-AXESweepVerdict -Points $granted
    [pscustomobject]@{
        Results      = @($granted)
        NotGranted   = @($notGranted)
        Raw          = @($out)
        Best         = $v.Best
        Worst        = $v.Worst
        SpreadMs     = $v.SpreadMs
        ThresholdMs  = $v.ThresholdMs
        ModelR       = $v.ModelR
        Reason       = $v.Reason
        OriginalMs   = $(if($orig){ $orig.CurrentMs } else { $null })
        DistinctRes  = $granted.Count
        Passes       = $Passes
        Conclusive   = $v.Conclusive
    }
}

function Format-AXETimerSweep {
    # Render compartido CLI (-TimerSweep) / GUI (boton "Barrido de timer"). Vive aqui y no en
    # cada consumidor porque el texto dice si el resultado es concluyente o ruido: si cada UI
    # se escribe el suyo, una acaba recomendando un valor que la otra declara no concluyente.
    # Devuelve string[] (una linea por elemento); el consumidor decide como pintarlo.
    param($Sweep)
    # OJO: devolver '@(...)' pelado, NO ',@(...)'. La coma unaria envuelve el array en OTRO
    # array, asi que el llamante recibe UN elemento (el array entero) en vez de N lineas: el
    # foreach del CLI itera una vez y el -join de la GUI concatena con espacios. Resultado
    # medido: las 6 lineas del informe salian pegadas en un renglon.
    if(-not $Sweep){ return @('Sin datos utiles (ver log).') }
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('Resolucion  avgDelta   stdev    pasadas')
    foreach($r in ($Sweep.Results | Sort-Object AppliedMs)){
        [void]$L.Add(("  {0,6:F3}ms  {1,7:F3}ms {2,7:F3}ms  {3,4}" -f $r.AppliedMs,$r.AvgDeltaMs,$r.StdevMs,$r.Passes))
    }
    if($Sweep.NotGranted.Count -gt 0){
        $np = ($Sweep.NotGranted | Measure-Object Passes -Sum).Sum
        [void]$L.Add('')
        [void]$L.Add("AVISO: $np request(s) no concedidos a este proceso (sleeps de ~15.6ms).")
        [void]$L.Add('       Sintoma del aislamiento por-proceso de Win11. Activa lat_timerres y reinicia.')
    }
    [void]$L.Add('')
    if($Sweep.Conclusive){
        [void]$L.Add(("MEJOR : {0:F3}ms  (delta medio {1:F3}ms)" -f $Sweep.Best.AppliedMs,$Sweep.Best.AvgDeltaMs))
        [void]$L.Add(("        {0}" -f $Sweep.Reason))
    } else {
        # Honestidad: el caso comun. valleyofdoom midio que el optimo es por-maquina y a
        # menudo cae dentro del margen de error. Recomendar un valor aqui seria inventar.
        # El motivo concreto lo da Get-AXESweepVerdict y puede ser de dos tipos: ruido
        # estadistico, o que la curva no siga el modelo fisico (entonces lo que se esta
        # midiendo es el overhead del scheduler, no la resolucion del timer).
        # Se imprime Reason y NO $Sweep.Best.StdevMs: con un solo punto concedido Best es
        # $null y el formato anterior reventaba justo en el caso que queria explicar.
        [void]$L.Add(("NO CONCLUYENTE: {0}" -f $Sweep.Reason))
        [void]$L.Add('       En esta maquina no hay diferencia real entre las resoluciones probadas.')
        [void]$L.Add('       Dejalo como esta: afinar aqui seria perseguir ruido.')
    }
    [void]$L.Add(("Resolucion restaurada a: {0}ms" -f $Sweep.OriginalMs))
    @($L)
}

function Measure-AXEJitter {
    # PROXY de latencia (no atribuible a driver concreto). El busy-loop corre en C#
    # nativo; en la GUI se invoca [AXE.Native]::SampleJitter en un runspace de fondo.
    param([int]$DurationMs=1000)
    try {
        $r = [AXE.Native]::SampleJitter([int]$DurationMs)
        [pscustomobject]@{
            Samples   = [int]$r[0]
            MeanMs    = [math]::Round($r[1],4)
            MaxMs     = [math]::Round($r[2],4)
            P999Ms    = [math]::Round($r[3],4)
            Stalls1ms = [int]$r[4]
        }
    } catch { $null }
}

function Get-AXESnapshot {
    # Snapshot honesto. Cada campo en su try/catch -> 'n/a', nunca aborta.
    # Timer + cobertura son instantaneos (UI-thread OK); el jitter (1s) es el unico
    # que la GUI empuja a un runspace (ver 57-gui-handlers). En CLI corre inline.
    param([int]$JitterMs=1000)
    $timer='n/a'; try { $t=Get-AXETimerResolution; if($t){ $timer=$t } } catch {}
    $jit='n/a';   try { $j=Measure-AXEJitter -DurationMs $JitterMs; if($j){ $jit=$j } } catch {}
    $on='n/a'; $app='n/a'
    try {
        $onN=0; $appN=0
        foreach($tw in $script:CAT){
            if($tw.Tier -notin 0,1){ continue }        # cobertura = Tier 0/1 (seguros/elite)
            if(Get-BlockReason $tw){ continue }          # no aplicable en este HW
            $appN++
            if(Test-TweakSafe $tw){ $onN++ }
        }
        $on=$onN; $app=$appN
    } catch {}
    [pscustomobject]@{
        Timestamp        = (Get-Date).ToUniversalTime().ToString('u')
        Timer            = $timer
        Jitter           = $jit
        TweaksOn         = $on
        TweaksApplicable = $app
    }
}

function Get-AXEBand {
    # Interpolacion lineal por tramos: $pairs = @(@(x0,y0),@(x1,y1),...) x ASCENDENTE.
    # Devuelve y clamped al rango de los extremos.
    param([double]$x,[object[]]$pairs)
    if($x -le $pairs[0][0]){ return [double]$pairs[0][1] }
    $last=$pairs.Count-1
    if($x -ge $pairs[$last][0]){ return [double]$pairs[$last][1] }
    for($i=0;$i -lt $last;$i++){
        $x0=[double]$pairs[$i][0]; $y0=[double]$pairs[$i][1]
        $x1=[double]$pairs[$i+1][0]; $y1=[double]$pairs[$i+1][1]
        if($x -ge $x0 -and $x -le $x1){
            $f=($x-$x0)/($x1-$x0); return $y0 + $f*($y1-$y0)
        }
    }
    return [double]$pairs[$last][1]
}
function Get-AXEScore {
    param($snap,[pscustomobject]$prev=$null)
    $lines=New-Object System.Collections.ArrayList
    $naCount=0

    # Timer 30. Se puntua la CONFIGURACION, no la resolucion instantanea.
    #
    # Antes se puntuaba Get-AXEBand(CurrentMs) a secas. En build 19041+ eso esta mal: el kernel
    # aisla los requests por proceso, asi que CurrentMs dice lo que pedia OTRA app en ese
    # segundo, no como esta configurado el equipo. Medido en Win11 26200 con lat_timerres YA
    # aplicado (GlobalTimerResolutionRequests=1): marcaba 1ms -> 20/30, presentando como fallo
    # de config algo que el usuario no puede arreglar y que ademas ya tenia bien.
    #
    # Ahi el unico ajuste accionable es GlobalTimerResolutionRequests, que es binario. En
    # builds anteriores los requests SI son globales, luego CurrentMs refleja config de verdad
    # y se mantiene la banda de siempre.
    if($snap.Timer -is [string]){ $timer='n/a'; $naCount++; [void]$lines.Add('Timer     : n/a') }
    elseif($snap.Timer.PerProcess){
        if($snap.Timer.GlobalRequests -eq 1){
            $timer=30
            [void]$lines.Add(("Timer     : {0,3}/30  (config OK; ahora {1}ms, lo fija la app en primer plano)" -f $timer,$snap.Timer.CurrentMs))
        } else {
            # No es 0: sin el flag el equipo funciona y las apps que piden resolucion la
            # obtienen para si mismas. Lo que se pierde es que el ajuste valga a nivel sistema.
            # Parcial, y el numero es un flag de config, no una medida.
            $timer=15
            [void]$lines.Add(("Timer     : {0,3}/30  (GlobalTimerResolutionRequests ausente: aplica lat_timerres y reinicia)" -f $timer))
        }
    }
    else {
        $timer=[int][math]::Round((Get-AXEBand ([double]$snap.Timer.CurrentMs) @(@(0.5,30),@(1.0,20),@(5.0,8),@(15.6,0))))
        [void]$lines.Add(("Timer     : {0,3}/30  ({1}ms)" -f $timer,$snap.Timer.CurrentMs))
    }
    # Jitter 35: menor P99.9 = mas puntos
    if($snap.Jitter -is [string]){ $jit='n/a'; $naCount++; [void]$lines.Add('Jitter    : n/a') }
    else {
        $jit=[int][math]::Round((Get-AXEBand ([double]$snap.Jitter.P999Ms) @(@(0.3,35),@(1.0,20),@(2.0,8),@(5.0,0))))
        [void]$lines.Add(("Jitter    : {0,3}/35  (P99.9 {1}ms, proxy)" -f $jit,$snap.Jitter.P999Ms))
    }
    # Cobertura 25: fraccion Tier0/1 aplicables activas. Guarda div/0.
    if($snap.TweaksApplicable -is [string] -or [int]$snap.TweaksApplicable -eq 0){
        $cov='n/a'; $naCount++; [void]$lines.Add('Cobertura : n/a')
    } else {
        $cov=[int][math]::Round(25.0 * ([int]$snap.TweaksOn / [int]$snap.TweaksApplicable))
        [void]$lines.Add(("Cobertura : {0,3}/25  ({1}/{2} Tier0/1)" -f $cov,$snap.TweaksOn,$snap.TweaksApplicable))
    }
    # Idle 10: sin regresion de jitter vs prev (10 si no hay prev). Deadband via 36-report.
    $idle=10
    if($prev -and $prev.Jitter -isnot [string] -and $snap.Jitter -isnot [string]){
        $pv=[double]$prev.Jitter.P999Ms; $cv=[double]$snap.Jitter.P999Ms
        $band=[math]::Max(0.1,$pv*0.10)
        if($cv -gt ($pv + $band)){
            $worse=[math]::Min(1.0, ($cv-$pv)/[math]::Max($pv,0.1))
            $idle=[int][math]::Round(10*(1-$worse))
        }
    }
    [void]$lines.Add(("Idle      : {0,3}/10" -f $idle))

    $total=0
    foreach($c in @($timer,$jit,$cov,$idle)){ if($c -isnot [string]){ $total+=[int]$c } }
    if($total -lt 0){ $total=0 }; if($total -gt 100){ $total=100 }
    if($naCount -gt 0){ [void]$lines.Add("(score parcial: $($naCount) componente(s) n/a)") }

    [pscustomobject]@{
        Total=$total; Timer=$timer; Jitter=$jit; Coverage=$cov; Idle=$idle
        Breakdown=($lines -join "`r`n")
    }
}


# >>>>> MODULE: 33-fps.ps1 >>>>>
# =====================================================
# REGION 10d - FPS REAL (PresentMon)
# =====================================================
# POR QUE ESTE MODULO EXISTE
#   La region 10c afirma FPS. Sin medirlos, esa afirmacion es exactamente el tipo de promesa
#   que este proyecto le reprocha al resto de tweakers. Aqui se miden de verdad.
#
#   PresentMon (Intel, gratis, MIT) engancha el evento Present de DXGI/D3D y saca el tiempo
#   entre frames PRESENTADOS. No es un contador de FPS de overlay: es la fuente que usan las
#   reviews. Se lee su CSV y se calculan medias y percentiles bajos.
#
# NO SE DESCARGA SOLO. Bajarse un ejecutable de internet y correrlo es justo lo que no debe
# hacer una herramienta que pide admin. Si no esta, se dice donde conseguirlo y ya.
#
# LO QUE SE MIDE Y POR QUE
#   El FPS medio es el numero que se ensena y el que menos importa: los tweaks de esta suite
#   (quitar trabajo de fondo, bajar jitter) casi no lo mueven. Lo que mueven son los MINIMOS,
#   porque un servicio que despierta a mitad de un frame no baja la media, crea un tiron. Por
#   eso el 1% low y el 0.1% low salen primero en el informe.
#   Convencion: percentil sobre TIEMPOS de frame, no sobre FPS instantaneo. El 1% low es la
#   media de FPS del 1% de frames MAS LENTOS. Es la definicion que usan CapFrameX y los
#   reviewers; promediar "FPS por frame" da otro numero y no seria comparable con nada.
#
# LIMITE HONESTO QUE NO SE PUEDE ARREGLAR CON CODIGO
#   Dos capturas del mismo juego no son el mismo trabajo salvo que sea la MISMA escena. Un
#   before/after andando por sitios distintos mide el mapa, no el tweak. El veredicto lo dice
#   y no hay forma de detectarlo desde aqui: es responsabilidad de quien mide usar un
#   benchmark integrado o repetir el mismo recorrido.
# =====================================================

$script:FpsCsvDir = Join-Path $script:AXEData 'fps'

# ---- localizar PresentMon (nunca descargarlo) ---------------------------------------
function Get-AXEPresentMon {
    # Orden: variable de entorno explicita -> junto a AXE -> PATH -> instalaciones tipicas.
    $cands = New-Object System.Collections.ArrayList
    if($env:AXE_PRESENTMON){ [void]$cands.Add($env:AXE_PRESENTMON) }
    [void]$cands.Add((Join-Path $script:AXERoot 'PresentMon.exe'))
    [void]$cands.Add((Join-Path $script:AXEData 'PresentMon.exe'))
    foreach($c in $cands){ if($c -and (Test-Path -LiteralPath $c)){ return (Resolve-Path -LiteralPath $c).Path } }
    # PATH y nombres versionados (PresentMon-2.3.0-x64.exe y similares).
    foreach($n in 'PresentMon','PresentMon-x64','presentmon'){
        $cmd = Get-Command $n -EA SilentlyContinue
        if($cmd){ return $cmd.Source }
    }
    foreach($d in @($script:AXERoot,$script:AXEData,"$env:ProgramFiles\PresentMon","${env:ProgramFiles(x86)}\PresentMon")){
        if(-not $d -or -not (Test-Path -LiteralPath $d)){ continue }
        $hit = Get-ChildItem -LiteralPath $d -Filter 'PresentMon*.exe' -EA SilentlyContinue | Select-Object -First 1
        if($hit){ return $hit.FullName }
    }
    return $null
}

# ---- parseo del CSV ------------------------------------------------------------------
# PURA a posta: recibe filas ya parseadas, no toca disco. Asi se testea el calculo sin tener
# PresentMon instalado ni un juego abierto (ver tests/Fps.Tests.ps1).
#
# El nombre de la columna de tiempo de frame cambio entre versiones: PresentMon 1.x emite
# 'msBetweenPresents' y 2.x 'FrameTime'. Se aceptan las dos en vez de fijar una, porque fijar
# la de hoy convierte una actualizacion del binario en un fallo silencioso de "0 frames".
function Get-AXEFrameTimeColumn($row){
    if(-not $row){ return $null }
    $names = @($row.PSObject.Properties.Name)
    foreach($c in 'msBetweenPresents','FrameTime','MsBetweenPresents','msBetweenDisplayChange'){
        if($names -contains $c){ return $c }
    }
    return $null
}

function Get-AXEFpsStats {
    # $FrameTimesMs = tiempos de frame en milisegundos, en orden de captura.
    param([double[]]$FrameTimesMs)
    $ft = @($FrameTimesMs | Where-Object { $_ -gt 0 })
    if($ft.Count -lt 10){
        return [pscustomobject]@{ Frames=$ft.Count; Ok=$false; Reason="solo $($ft.Count) frames validos (<10): captura demasiado corta para decir nada." }
    }
    $sorted = @($ft | Sort-Object -Descending)   # los mas LENTOS primero
    # Percentil bajo = media de FPS sobre el N% de frames mas lentos. Techo a 1 frame minimo
    # para que una captura corta no de una lista vacia y un divide-por-cero.
    $pick = {
        param($pct)
        $n = [math]::Max(1, [int][math]::Ceiling($sorted.Count * $pct))
        $slice = $sorted[0..($n-1)]
        $avgMs = ($slice | Measure-Object -Average).Average
        if($avgMs -le 0){ 0.0 } else { [math]::Round(1000.0/$avgMs, 1) }
    }
    $meanMs = ($ft | Measure-Object -Average).Average
    [pscustomobject]@{
        Frames    = $ft.Count
        Ok        = $true
        Reason    = $null
        AvgFps    = [math]::Round(1000.0/$meanMs, 1)
        P1LowFps  = (& $pick 0.01)
        P01LowFps = (& $pick 0.001)
        AvgMs     = [math]::Round($meanMs,3)
        MaxMs     = [math]::Round(($ft | Measure-Object -Maximum).Maximum,3)
        # Desviacion de los tiempos de frame: es el proxy directo de "tirones", y lo que los
        # tweaks de esta suite pueden mover de verdad.
        StdevMs   = [math]::Round([math]::Sqrt((($ft | ForEach-Object { ($_ - $meanMs) * ($_ - $meanMs) } | Measure-Object -Sum).Sum) / $ft.Count), 3)
        DurationS = [math]::Round(($ft | Measure-Object -Sum).Sum / 1000.0, 1)
    }
}

# ---- veredicto ------------------------------------------------------------------------
# Mismo criterio que Get-AXESweepVerdict: no basta con que el numero suba, tiene que subir
# MAS QUE EL RUIDO. Aqui el ruido se estima con la varianza de los tiempos de frame de las dos
# capturas (Welch sobre la media de tiempo de frame, que es lo que determina el FPS medio).
# PURA: se testea sin hardware.
function Get-AXEFpsVerdict {
    param([object]$Before,[object]$After)

    if(-not $Before -or -not $After -or -not $Before.Ok -or -not $After.Ok){
        return [pscustomobject]@{ Conclusive=$false; Reason='falta una de las dos capturas o no tiene frames suficientes.'; DeltaFps=0.0; DeltaPct=0.0; Warning=$null }
    }

    $dFps = [math]::Round($After.AvgFps - $Before.AvgFps, 1)
    $dPct = if($Before.AvgFps -gt 0){ [math]::Round(100.0*($After.AvgFps-$Before.AvgFps)/$Before.AvgFps, 1) } else { 0.0 }
    # El aviso de escena va SIEMPRE, tambien cuando el resultado sale bonito. Sobre todo cuando
    # sale bonito: es cuando apetece creerselo.
    $warn = 'Solo vale si las dos capturas son la MISMA escena (benchmark integrado o el mismo recorrido). Si no, esto mide el mapa, no el ajuste.'

    # Welch sobre la media de tiempo de frame. Se usa ms y no FPS porque el FPS es 1/x: su
    # media no es el inverso de la media y la varianza no se propaga limpia.
    $seB = $Before.StdevMs / [math]::Sqrt($Before.Frames)
    $seA = $After.StdevMs  / [math]::Sqrt($After.Frames)
    $se  = [math]::Sqrt($seB*$seB + $seA*$seA)
    $dMs = $Before.AvgMs - $After.AvgMs      # positivo = frames mas rapidos despues

    if($se -le 0){
        return [pscustomobject]@{ Conclusive=$false; Reason='varianza nula: captura degenerada (juego pausado o v-sync clavado?).'; DeltaFps=$dFps; DeltaPct=$dPct; Warning=$warn }
    }
    $z = [math]::Abs($dMs) / $se

    # z >= 4: los tiempos de frame estan autocorrelados (un tiron dura varios frames), asi que
    # los N frames NO son N muestras independientes y el error real es mayor que el calculado.
    # Un umbral de 1.96 daria "concluyente" con cualquier cosa. 4 es conservador a posta.
    if($z -lt 4.0){
        return [pscustomobject]@{
            Conclusive=$false
            Reason=("diferencia dentro del ruido (z={0:N1} < 4). {1:N1} FPS de delta no es distinguible de la variacion normal entre dos capturas." -f $z,$dFps)
            DeltaFps=$dFps; DeltaPct=$dPct; Warning=$warn; Z=[math]::Round($z,2)
        }
    }
    [pscustomobject]@{
        Conclusive=$true
        Reason=("delta por encima del ruido (z={0:N1}). Medio {1:N1} -> {2:N1} FPS ({3:+0.0;-0.0;0} / {4:+0.0;-0.0;0}%), 1% low {5:N1} -> {6:N1}." -f $z,$Before.AvgFps,$After.AvgFps,$dFps,$dPct,$Before.P1LowFps,$After.P1LowFps)
        DeltaFps=$dFps; DeltaPct=$dPct; Warning=$warn; Z=[math]::Round($z,2)
    }
}

# ---- captura ---------------------------------------------------------------------------
function Measure-AXEFps {
    param([Parameter(Mandatory)][string]$ProcessName,[int]$Seconds=20)
    $pm = Get-AXEPresentMon
    if(-not $pm){
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason='PresentMon no encontrado. Bajalo de https://github.com/GameTechDev/PresentMon/releases y deja PresentMon.exe junto a AXE (o define AXE_PRESENTMON). AXE no lo descarga solo a proposito.' }
    }
    $proc = ($ProcessName -replace '\.exe$','') + '.exe'
    if(-not (Get-Process -Name ($proc -replace '\.exe$','') -EA SilentlyContinue)){
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason="'$proc' no esta corriendo. Abre el juego, ponlo en la escena que vas a medir y vuelve." }
    }
    if(-not (Test-Path $script:FpsCsvDir)){ New-Item -ItemType Directory -Path $script:FpsCsvDir -Force | Out-Null }
    $csv = Join-Path $script:FpsCsvDir ("fps_{0}_{1}.csv" -f ($proc -replace '\.exe$',''),(Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        # -stop_existing_session: si quedo una sesion ETW colgada de una captura anterior,
        # PresentMon falla al arrancar. -terminate_after_timed cierra el proceso solo.
        $pmArgs = @('-process_name',$proc,'-output_file',$csv,'-timed',$Seconds,'-terminate_after_timed','-stop_existing_session','-no_top')
        $p = Start-Process -FilePath $pm -ArgumentList $pmArgs -PassThru -Wait -WindowStyle Hidden -EA Stop
        if($p.ExitCode -ne 0){ Write-AXELog "PresentMon salio con codigo $($p.ExitCode)." 'WARN' }
    } catch {
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason="no pude ejecutar PresentMon: $($_.Exception.Message). Necesita admin para la sesion ETW." }
    }
    if(-not (Test-Path $csv)){
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason='PresentMon no genero CSV. Suele ser falta de permisos (sesion ETW) o que el juego usa una API que no engancha.' }
    }
    $rows = @(Import-Csv $csv -EA SilentlyContinue)
    if($rows.Count -eq 0){ return [pscustomobject]@{ Ok=$false; Frames=0; Reason='CSV vacio: PresentMon no vio frames de ese proceso.' } }
    $col = Get-AXEFrameTimeColumn $rows[0]
    if(-not $col){
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason="el CSV no trae columna de tiempo de frame conocida (columnas: $((@($rows[0].PSObject.Properties.Name)) -join ', ')). Version de PresentMon no soportada." }
    }
    $ft = @($rows | ForEach-Object { $v=0.0; if([double]::TryParse($_.$col,[ref]$v)){ $v } })
    $st = Get-AXEFpsStats -FrameTimesMs $ft
    $st | Add-Member -NotePropertyName Csv -NotePropertyValue $csv -Force
    $st | Add-Member -NotePropertyName Process -NotePropertyValue $proc -Force
    $st
}

function Format-AXEFpsStats($s,$label='Captura'){
    if(-not $s){ return @("$label : sin datos.") }
    if(-not $s.Ok){ return @("$label : $($s.Reason)") }
    @(
        ("{0} ({1}): {2} frames en {3}s" -f $label,$s.Process,$s.Frames,$s.DurationS)
        # Los minimos van PRIMERO: son lo que mueven los ajustes de esta suite. La media va
        # ultima a posta, para que no sea el numero que se mira.
        ("  1% low   : {0} FPS" -f $s.P1LowFps)
        ("  0.1% low : {0} FPS" -f $s.P01LowFps)
        ("  Medio    : {0} FPS  ({1} ms/frame, stdev {2} ms, peor {3} ms)" -f $s.AvgFps,$s.AvgMs,$s.StdevMs,$s.MaxMs)
    )
}


# >>>>> MODULE: 34-safety.ps1 >>>>>
# =====================================================
# REGION 8c - SEGURIDAD: punto de restauracion best-effort (fuente unica)
# =====================================================
# El cuerpo del checkpoint vive AQUI una sola vez. Lo reusan:
#   - New-AXERestorePoint (headless / CLI, in-process)
#   - $script:doRestorePoint (GUI: lo inyecta en un runspace de fondo; 57-gui-handlers)
# Es AUTOCONTENIDO (no llama funciones de sesion) para poder correr dentro del runspace.
$script:RestorePointScript = {
    param($desc)
    $ac = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | Where-Object { $_.State -eq 'Running' -and $_.Name -match 'EasyAntiCheat|BEDaisy|BattlEye|vgk' }
    if($ac){ return "ANTICHEAT: '$($ac.Name -join ', ')' bloquea VSS. Cierra el juego/launcher y reintenta." }
    foreach($sv in 'VSS','swprv'){ $s=Get-Service $sv -EA SilentlyContinue; if($s -and $s.StartType -eq 'Disabled'){ & sc.exe config $sv start= demand | Out-Null } }
    Start-Service VSS -EA SilentlyContinue
    Enable-ComputerRestore -Drive 'C:\' -EA SilentlyContinue
    $rp='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    New-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
    try {
        Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS
        # §4.2 #5: CREAR *Y VERIFICAR*. Checkpoint-Computer no lanza aunque el throttle 24h
        # o VSS silencien la creacion => confirmar que el punto realmente aterrizo.
        $rpv = Get-ComputerRestorePoint -EA SilentlyContinue | Where-Object { $_.Description -eq $desc } | Select-Object -Last 1
        if($rpv){ 'OK: punto CREADO Y VERIFICADO.' }
        else { 'ERROR: Checkpoint no persistio (throttle 24h o VSS bloqueado): sin punto valido.' }
    }
    catch { "ERROR: $($_.Exception.Message)" }
    finally { Remove-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -EA SilentlyContinue }
}

function New-AXERestorePoint {
    # Best-effort, NUNCA lanza. Devuelve {Status; Message}. Ejecucion in-process (CLI/wrap).
    # La GUI usa el runspace (no congela) via $script:doRestorePoint.
    param([string]$Desc='AXE optimizacion')
    if($env:AXE_NOSR){ return [pscustomobject]@{ Status='fallback'; Message='SR omitido (AXE_NOSR / modo test)' } }
    try {
        $out = & $script:RestorePointScript $Desc
        $line = @($out)[-1]
        if("$line" -match '^OK'){ return [pscustomobject]@{ Status='ok'; Message="$line" } }
        # anticheat / SR deshabilitado / throttle -> fallback: apoyate en las redes existentes
        return [pscustomobject]@{ Status='fallback'; Message="$line  (usa backups .reg + Export como red)" }
    } catch {
        return [pscustomobject]@{ Status='error'; Message=$_.Exception.Message }
    }
}

# ELIMINADAS (auditoria 2026-07-19): Assert-AXEVss y Get-AXETamperState. Escritas contra la
# spec §4.1 ("preflight de seguridad") y nunca cableadas: cero llamadores de produccion. Su
# unica referencia era un check del SelfTest (S22) que comprobaba que estaban DEFINIDAS -- un
# test sobre funciones que nadie llama, verde para siempre y con cobertura ficticia. Se fue con
# ellas.
#
# No eran codigo util pendiente de conectar, eran duplicados de algo que ya corre:
#   - Assert-AXEVss repetia literalmente el bucle VSS/swprv de $script:RestorePointScript (arriba),
#     que si se ejecuta en cada punto de restauracion.
#   - Get-AXETamperState tenia una consulta en vivo como fallback por si no habia $script:HW,
#     pero Get-BlockReason retorna antes en ese caso (20-tweaks:369), asi que esa rama era
#     inalcanzable. Quien necesita el dato usa $script:HW.IsTamperProtected directo.
#
# Si vuelve a hacer falta un preflight de VSS, extraer el bucle de RestorePointScript a una
# funcion y llamarla desde AMBOS sitios; no reescribirlo al lado.


# >>>>> MODULE: 35-diag.ps1 >>>>>
# =====================================================
# REGION 10e - DIAGNOSTICO DE HARDWARE MAL CONFIGURADO
# =====================================================
#
# POR QUE EXISTE: los 78 tweaks del catalogo pelean por porcentajes de un digito, y varios
# ni eso (el propio catalogo marca PlaceboLikely y NO-OP EN LA MAYORIA en unos cuantos). Lo
# que de verdad cuesta FPS en una maquina mal montada no es una clave del registro:
#
#   XMP/EXPO sin activar      10-30%   la RAM corre a la velocidad JEDEC de arranque
#   RAM en single channel     20-40%   un solo modulo, o dos en el mismo canal
#   Monitor por debajo de Hz  hasta 2x un panel de 144Hz puesto a 60
#   Juego/SO en HDD           enorme en stutter y cargas
#
# Ninguno de esos se arregla desde AXE, y a proposito: XMP y los canales de RAM viven en la
# BIOS y en los slots fisicos. Este modulo DETECTA y EXPLICA, no toca nada. Es la unica
# categoria del proyecto con efecto grande garantizado, precisamente porque no promete: el
# usuario puede verificar cada hallazgo por su cuenta.
#
# DIVISION PURO/HARDWARE (mismo motivo que Get-AXEFpsStats vs Measure-AXEFps en 33-fps.ps1):
#   Get-AXEDiagFacts     -> toca CIM, no decide nada. No testeable sin hardware.
#   Get-AXEDiagFindings  -> PURA. Recibe los hechos, devuelve hallazgos. Testeable en CI.
#   Format-AXEDiag       -> PURA. Render de texto, compartido por CLI y GUI.
# Si el juicio viviera dentro de la lectura de CIM solo se podria probar en la maquina del
# que lo escribio, o sea nunca.
#
# ESTADOS, y por que hay tres y no dos:
#   BAD      medido y mal configurado.
#   OK       medido y correcto.
#   UNKNOWN  NO SE PUDO MEDIR. Es un estado de primera clase, no un OK disfrazado. Un
#            diagnostico que calla lo que no sabe es exactamente el problema que tienen los
#            optimizadores de pago: todo sale verde porque nada se comprueba de verdad.

# --- velocidades JEDEC de arranque, base de la heuristica de XMP -----------------------
# Sin XMP/EXPO el modulo arranca al perfil JEDEC del SPD. En DDR4 eso cae en 2133/2400/2666
# (3200 es JEDEC valido pero rarisimo como perfil de arranque); en DDR5, 4800.
# LIMITE CONOCIDO: el SPD no expone el perfil XMP por WMI, asi que esto es una HEURISTICA por
# umbral, no una lectura del perfil. Un kit DDR4-2666 sin ningun perfil XMP dara falso
# positivo. Se acepta porque el consejo ("miralo en la BIOS") es inofensivo en ese caso, y
# porque el fallo contrario (callar un XMP apagado) cuesta 10-30% real.
$script:DiagJedecBase   = @{ 26 = 2666; 34 = 4800 }   # SMBIOSMemoryType: 26=DDR4, 34=DDR5
$script:DiagMemTypeName = @{ 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5' }

function Get-AXEDiagFacts {
    # Lee el hardware. No juzga: eso es Get-AXEDiagFindings. Cada bloque va en su try porque
    # WMI falla distinto en cada maquina y un fallo parcial debe degradar a UNKNOWN, nunca
    # tumbar el diagnostico entero ni -peor- pasar por OK.
    $f = [ordered]@{
        MemModules = $null; MemSpeedMhz = $null; MemType = $null; MemLocators = $null
        RefreshCur = $null; RefreshMax = $null
        IsSSD      = $null
        # --- Campos nuevos. Ninguno de los de arriba cambia de nombre ni de tipo. ---
        # Refresco REAL del panel (EDID), no el del modo actual del adaptador: ver el bloque
        # de WmiMonitorListedSupportedSourceModes mas abajo y el hallazgo 3.
        PanelMaxHz = $null; PanelMaxHzAtRes = $null
        # Nucleos fisicos vs hilos: de ahi sale el reparto P/E por aritmetica (hallazgo 5).
        CpuCores   = $null; CpuThreads = $null; IsWin11 = $null
    }
    try {
        $mem = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        if($mem.Count -gt 0){
            $f.MemModules = $mem.Count
            # La velocidad configurada real. ConfiguredClockSpeed es la fiable cuando existe;
            # Speed puede reportar el rating del modulo en algunas BIOS. Nos quedamos con la
            # menor de las dos: si difieren, la baja es la que esta corriendo de verdad.
            $spd = @($mem | ForEach-Object {
                $c = $_.ConfiguredClockSpeed; $s = $_.Speed
                if($c -and $s){ [math]::Min([int]$c,[int]$s) } elseif($c){ [int]$c } elseif($s){ [int]$s }
            }) | Where-Object { $_ -gt 0 }
            if($spd.Count -gt 0){ $f.MemSpeedMhz = ($spd | Measure-Object -Minimum).Minimum }
            $f.MemType     = [int]($mem[0].SMBIOSMemoryType)
            $f.MemLocators = @($mem | ForEach-Object { $_.DeviceLocator })
        }
    } catch {}
    try {
        # Solo GPUs reales, mismo filtro que Get-AXEHardware: los adaptadores virtuales
        # reportan refrescos inventados y ensuciarian el hallazgo.
        $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop |
              Where-Object { $_.Name -notmatch 'Virtual|Basic|Meta|Parsec|Remote' -and $_.CurrentRefreshRate } |
              Select-Object -First 1
        if($vc){ $f.RefreshCur = [int]$vc.CurrentRefreshRate; $f.RefreshMax = [int]$vc.MaxRefreshRate }
    } catch {}
    # --- Refresco REAL del panel, no el del adaptador ------------------------------------
    # CIERRA EL TODO que este modulo llevaba declarado: Win32_VideoController.MaxRefreshRate es
    # el maximo del MODO ACTUAL del adaptador, asi que un panel de 144 Hz puesto a 60 puede
    # reportar 60/60 y salir OK. WmiMonitorListedSupportedSourceModes viene del EDID del
    # monitor: son los modos que el PANEL declara, independientemente de como este ahora.
    #
    # Se guardan DOS maximos a proposito, y la diferencia importa: un panel puede dar 240 Hz a
    # 1080p y solo 144 a 1440p. Comparar el refresco actual contra el maximo ABSOLUTO mandaria
    # al usuario a buscar unos Hz que a su resolucion no existen, que es un falso positivo y
    # de los que peor sientan. Manda el maximo A SU RESOLUCION; el absoluto solo se usa si la
    # resolucion actual no se pudo leer.
    try {
        $curW = $null; $curH = $null
        if($script:HW){ $curW = $script:HW.ScreenW; $curH = $script:HW.ScreenH }
        $best = 0; $bestAtRes = 0
        foreach($mm in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop)){
            foreach($sm in @($mm.MonitorSourceModes)){
                $den = [double]$sm.VerticalRefreshRateDenominator
                if($den -le 0){ continue }
                $hz = [int][math]::Round([double]$sm.VerticalRefreshRateNumerator / $den)
                if($hz -le 0 -or $hz -gt 1000){ continue }   # modos basura del EDID
                if($hz -gt $best){ $best = $hz }
                if($curW -and $curH -and [int]$sm.HorizontalActivePixels -eq [int]$curW -and [int]$sm.VerticalActivePixels -eq [int]$curH){
                    if($hz -gt $bestAtRes){ $bestAtRes = $hz }
                }
            }
        }
        if($best -gt 0){ $f.PanelMaxHz = $best }
        if($bestAtRes -gt 0){ $f.PanelMaxHzAtRes = $bestAtRes }
    } catch {}
    # CPU: nucleos fisicos vs hilos logicos. De la diferencia sale el reparto P/E sin adivinar
    # por el nombre comercial (ver hallazgo 5). Se reusa $script:HW si ya esta cargado.
    try {
        if($script:HW){ $f.CpuCores = $script:HW.Cores; $f.CpuThreads = $script:HW.Threads; $f.IsWin11 = $script:HW.IsWin11 }
    } catch {}
    # IsSSD ya lo calcula Get-AXEHardware; se reusa si el caller lo paso, no se recalcula.
    if($script:HW -and $null -ne $script:HW.IsSSD){ $f.IsSSD = [bool]$script:HW.IsSSD }
    [pscustomobject]$f
}

function New-AXEDiagFinding {
    param($Id,$Status,$Title,$Detail,$Fix,$EstPct,$Confidence)
    [pscustomobject]@{
        Id=$Id; Status=$Status; Title=$Title; Detail=$Detail
        Fix=$Fix; EstPct=$EstPct; Confidence=$Confidence
    }
}

function Get-AXEDiagFindings {
    # PURA: mismos hechos dentro, mismos hallazgos fuera. Sin CIM, sin registro, sin disco.
    # EstPct es un RANGO ESTIMADO tipico documentado por la industria, no una medida de esta
    # maquina. Se muestra como estimacion y jamas como promesa: la unica cifra real que da
    # este proyecto sale de 32-measure.ps1 midiendo antes y despues.
    param([Parameter(Mandatory)]$Facts)
    $out = New-Object System.Collections.Generic.List[object]

    # --- 1. XMP / EXPO -----------------------------------------------------------------
    $base  = if($null -ne $Facts.MemType){ $script:DiagJedecBase[[int]$Facts.MemType] } else { $null }
    $tname = if($null -ne $Facts.MemType -and $script:DiagMemTypeName.ContainsKey([int]$Facts.MemType)) { $script:DiagMemTypeName[[int]$Facts.MemType] } else { 'RAM' }
    if($null -eq $Facts.MemSpeedMhz -or $null -eq $base){
        [void]$out.Add((New-AXEDiagFinding 'xmp' 'UNKNOWN' 'XMP / EXPO' `
            'No se pudo leer la velocidad o el tipo de memoria por WMI.' `
            'Comprueba a mano la velocidad de la RAM en la BIOS.' '10-30%' 'desconocida'))
    } elseif($Facts.MemSpeedMhz -le $base){
        [void]$out.Add((New-AXEDiagFinding 'xmp' 'BAD' 'XMP / EXPO' `
            "$tname corriendo a $($Facts.MemSpeedMhz) MHz: es la velocidad JEDEC de arranque. El perfil de tu kit casi seguro esta sin activar." `
            'BIOS > perfil de memoria > activa XMP (Intel) o EXPO (AMD). Reinicia y vuelve a mirar.' `
            '10-30%' 'heuristica (WMI no expone el perfil XMP del SPD)'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'xmp' 'OK' 'XMP / EXPO' `
            "$tname a $($Facts.MemSpeedMhz) MHz, por encima de la base JEDEC ($base MHz)." `
            $null '10-30%' 'heuristica'))
    }

    # --- 2. Canales de RAM --------------------------------------------------------------
    # Un solo modulo es single channel SIEMPRE: no hay heuristica que valga, es aritmetica.
    # Con dos o mas no se afirma dual channel, porque WMI no dice de forma fiable si estan en
    # canales distintos; dos modulos en A1+A2 son single y aqui saldrian como probables. Por
    # eso el texto dice "probable" y manda al manual, en vez de dar un OK que no se ha medido.
    if($null -eq $Facts.MemModules){
        [void]$out.Add((New-AXEDiagFinding 'ramchan' 'UNKNOWN' 'Canales de RAM' `
            'No se pudieron enumerar los modulos de memoria.' `
            'Revisa a mano cuantos modulos hay y en que slots.' '20-40%' 'desconocida'))
    } elseif($Facts.MemModules -eq 1){
        [void]$out.Add((New-AXEDiagFinding 'ramchan' 'BAD' 'Canales de RAM' `
            'Un solo modulo instalado: single channel seguro. Es de lo mas caro que hay en un PC de juego.' `
            'Anade un segundo modulo igual, en el slot que diga el manual de la placa (normalmente A2+B2).' `
            '20-40%' 'cierta'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'ramchan' 'OK' 'Canales de RAM' `
            "$($Facts.MemModules) modulos instalados: dual channel probable." `
            'Confirma en el manual que estan en canales distintos (tipico A2+B2, no A1+A2).' `
            '20-40%' 'parcial (WMI no confirma el canal)'))
    }

    # --- 3. Refresco del monitor --------------------------------------------------------
    # ANTES: solo Win32_VideoController.MaxRefreshRate, que es el maximo del MODO ACTUAL del
    # adaptador. Un panel de 144 Hz puesto a 60 reportaba 60/60 y salia OK: falso negativo
    # conocido, declarado en un TODO y sin resolver. AHORA se prefiere el EDID del panel.
    #
    # PRIORIDAD, y el orden no es cosmetico:
    #   1. PanelMaxHzAtRes  el maximo del panel A LA RESOLUCION ACTUAL. Es el unico que puede
    #                       compararse contra RefreshCur sin mentir.
    #   2. PanelMaxHz       maximo absoluto del panel. Solo si no se supo la resolucion actual;
    #                       si no, un panel de 240@1080p / 144@1440p mandaria a buscar 240 Hz
    #                       que a 1440p no existen.
    #   3. RefreshMax       el del adaptador, como antes. Ultimo recurso: en RDP, en algunos
    #                       hibridos y con drivers basicos el namespace root\wmi no responde.
    # NINGUNA de las tres fuentes es de fiar como techo. Todas valen como SUELO:
    #   RefreshCur       lo que hay puesto ahora. Suelo garantizado del maximo real.
    #   PanelMaxHz*      modos del EDID. MEDIDO EN UN PORTATIL REAL DURANTE ESTA SESION: la
    #                    lista devolvio 60 Hz en un panel que estaba corriendo a 180. La clase
    #                    WmiMonitorListedSupportedSourceModes solo trae los timings ESTANDAR
    #                    del EDID, no los detallados, asi que en muchos paneles se queda corta.
    #                    Tomarla por techo daba un OK con confianza 'cierta' que era falso, y
    #                    ademas imprimia "A 180Hz, el maximo disponible (60 Hz)".
    #   RefreshMax       maximo del modo actual del adaptador. Otro suelo, el de siempre.
    # Por eso el maximo efectivo es el MAYOR de los que haya. La unica afirmacion honesta que
    # se puede hacer desde aqui es "estas por debajo de un refresco que SE PUEDE VER"; probar
    # que estas al techo real del panel no se puede, y por eso el OK nunca dice 'cierta'.
    # OJO CON EL PAPEL DE RefreshCur: es un TOPE INFERIOR, no una fuente. Si entrase como
    # candidato a maximo, con las otras dos fuentes caidas el maximo saldria igual al actual y
    # el hallazgo diria OK. Eso convierte "no se cual es el maximo" en "estas al maximo", que
    # es exactamente el OK sin comprobar que este modulo existe para no dar. Sin ninguna fuente
    # de modos -> UNKNOWN, como siempre.
    $refMax = $null; $refSrc = $null; $panel = $null
    if($Facts.PanelMaxHzAtRes -and $Facts.PanelMaxHzAtRes -gt 0){
        $panel = [int]$Facts.PanelMaxHzAtRes
    } elseif($Facts.PanelMaxHz -and $Facts.PanelMaxHz -gt 0){
        # Absoluto solo si no se supo la resolucion actual: un panel de 240@1080p / 144@1440p
        # mandaria a buscar unos Hz que a la resolucion puesta no existen.
        $panel = [int]$Facts.PanelMaxHz
    }
    foreach($c in @($panel, $Facts.RefreshMax)){
        if($c -and [int]$c -gt 0 -and ($null -eq $refMax -or [int]$c -gt $refMax)){ $refMax = [int]$c }
    }
    if($null -ne $refMax){
        # Una fuente que reporta MENOS que el refresco que hay PUESTO esta incompleta, y hay que
        # decirlo aunque OTRA fuente gane el maximo. El caso MEDIDO en portatil: el EDID devolvio
        # 60 con el panel corriendo a 180; el maximo lo salvo RefreshMax, pero la confianza no
        # puede presumir de haber leido el panel cuando lo que leyo estaba mal.
        #   Mirar solo el maximo final (lo que hacia antes este bloque) perdia ese aviso en cuanto
        # una sola fuente acertaba: el unico caso que quedaba delatado era el de TODAS cortas.
        $cur   = if($Facts.RefreshCur){ [int]$Facts.RefreshCur } else { $null }
        $under = @(@($panel, $Facts.RefreshMax) | Where-Object { $_ -and $cur -and [int]$_ -lt $cur })
        # Clamp al actual para el caso de TODAS cortas: sin el, el hallazgo imprimia
        # "A 180Hz, el maximo disponible (60 Hz)", que ademas de falso es absurdo.
        if($cur -and $cur -gt $refMax){ $refMax = $cur }
        $refSrc = if($under.Count -gt 0){ 'parcial (las listas de modos reportan menos que tu refresco actual: estan incompletas)' }
                  elseif($panel -and $panel -eq $refMax){ 'parcial (modos que declara el EDID del panel; la lista puede estar incompleta)' }
                  else { 'parcial (maximo del modo actual del adaptador, no del panel)' }
    }
    if($null -eq $Facts.RefreshCur -or $null -eq $refMax){
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'UNKNOWN' 'Refresco del monitor' `
            'No se pudo leer el refresco actual o el maximo.' `
            'Configuracion > Pantalla > Configuracion avanzada de pantalla.' 'hasta 2x' 'desconocida'))
    } elseif($Facts.RefreshCur -lt $refMax){
        $mult = [math]::Round($refMax / [double]$Facts.RefreshCur,1)
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'BAD' 'Refresco del monitor' `
            "A $($Facts.RefreshCur)Hz cuando admite $refMax Hz. Estas viendo ${mult}x menos frames de los que ya renderiza tu GPU." `
            'Configuracion > Pantalla > Configuracion avanzada > Elegir frecuencia de actualizacion.' `
            "${mult}x" $refSrc))
    } else {
        # "el mas alto que AXE puede ver", no "el maximo del panel": ver el bloque de arriba.
        # Decir lo segundo seria afirmar algo que ninguna de las tres fuentes prueba.
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'OK' 'Refresco del monitor' `
            "A $($Facts.RefreshCur)Hz, el mas alto de los modos que AXE puede ver." `
            $null 'hasta 2x' $refSrc))
    }

    # --- 4. Disco de sistema ------------------------------------------------------------
    if($null -eq $Facts.IsSSD){
        [void]$out.Add((New-AXEDiagFinding 'ssd' 'UNKNOWN' 'Disco de sistema' `
            'No se pudo determinar el tipo de disco.' `
            'Comprueba si el disco del sistema es SSD o HDD.' 'grande en stutter' 'desconocida'))
    } elseif(-not $Facts.IsSSD){
        [void]$out.Add((New-AXEDiagFinding 'ssd' 'BAD' 'Disco de sistema' `
            'Windows esta en un disco mecanico. Afecta a cargas y a los tirones por streaming de texturas, no tanto al FPS medio.' `
            'Migra Windows y los juegos a un SSD. Es la mejora mas grande por euro que existe.' `
            'grande en stutter' 'cierta'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'ssd' 'OK' 'Disco de sistema' 'SSD/NVMe.' $null 'grande en stutter' 'cierta'))
    }

    # --- 5. Nucleos P/E (CPU hibrida) ---------------------------------------------------
    # POR ARITMETICA, NO POR EL NOMBRE COMERCIAL. En una CPU hibrida de Intel los nucleos P
    # llevan Hyper-Threading (2 hilos) y los E no (1 hilo). Entonces:
    #     P = hilos - nucleos       E = nucleos - P
    # Un i9-13900H (14 nucleos / 20 hilos) da P=6, E=8. Correcto.
    # El gate es que 'hilos' caiga ESTRICTAMENTE entre 'nucleos' y '2*nucleos': con HT en todos
    # los nucleos hilos=2*nucleos (no hibrida, P=nucleos y E=0), y sin HT hilos=nucleos (no
    # hibrida tampoco). Solo el caso intermedio prueba que hay nucleos sin HT.
    #   Esto es mejor que $HW.IsHybrid, que adivina por regex sobre el nombre ('1[2-9]th Gen'
    # o 'Ultra'): eso falla con cualquier CPU futura y con las que no rotulan la generacion.
    #
    # Y ES UN DIAGNOSTICO, NO UN TWEAK, a proposito. Forzar la afinidad a los nucleos P suena
    # bien y suele EMPEORARLO: Thread Director mueve los hilos con telemetria del propio
    # silicio, y una mascara fija le quita esa informacion. El catalogo ya bloquea core parking
    # en hibridas por este motivo (20-tweaks: 'pelea con Thread Director'). Aqui se explica
    # que hay que mirar; no se toca nada.
    $hc = $Facts.CpuCores; $ht = $Facts.CpuThreads
    if($null -eq $hc -or $null -eq $ht -or $hc -le 0 -or $ht -le 0){
        [void]$out.Add((New-AXEDiagFinding 'hybrid' 'UNKNOWN' 'Nucleos P/E' `
            'No se pudo leer el numero de nucleos fisicos o de hilos.' `
            'Administrador de tareas > Rendimiento > CPU: compara "Nucleos" con "Procesadores logicos".' `
            'tirones si el juego cae en nucleos E' 'desconocida'))
    } elseif($ht -gt $hc -and $ht -lt (2 * $hc)) {
        $pc = $ht - $hc; $ec = $hc - $pc
        if($Facts.IsWin11 -eq $false){
            # Win10 no tiene Thread Director por hardware: el planificador reparte a ciegas y
            # los hilos del juego acaban en nucleos E con mucha mas frecuencia. Es el unico
            # caso de este hallazgo que merece BAD, y el arreglo es real (actualizar el SO).
            [void]$out.Add((New-AXEDiagFinding 'hybrid' 'BAD' 'Nucleos P/E' `
                "CPU hibrida ($pc nucleos P + $ec nucleos E) con Windows 10. Win10 no recibe la telemetria de Thread Director, asi que reparte los hilos sin saber que nucleos son rapidos: los del juego caen en nucleos E mas de la cuenta y eso son tirones." `
                'Actualiza a Windows 11. Es de las pocas veces que el cambio de version tiene efecto medible en juego, y solo pasa en CPUs hibridas como la tuya.' `
                'tirones si el juego cae en nucleos E' 'cierta (aritmetica de nucleos e hilos)'))
        } else {
            [void]$out.Add((New-AXEDiagFinding 'hybrid' 'OK' 'Nucleos P/E' `
                "CPU hibrida ($pc nucleos P + $ec nucleos E) con Windows 11: Thread Director reparte con telemetria del propio silicio." `
                $null 'tirones si el juego cae en nucleos E' `
                'cierta (aritmetica de nucleos e hilos). NO fuerces la afinidad a los nucleos P: una mascara fija le quita a Thread Director la informacion con la que decide, y suele salir peor.'))
        }
    } else {
        [void]$out.Add((New-AXEDiagFinding 'hybrid' 'OK' 'Nucleos P/E' `
            "CPU no hibrida ($hc nucleos / $ht hilos): todos los nucleos son iguales, no hay reparto que pueda salir mal." `
            $null 'tirones si el juego cae en nucleos E' 'cierta (aritmetica de nucleos e hilos)'))
    }

    $out.ToArray()
}

function Format-AXEDiag {
    # PURA. Devuelve lineas; el caller decide donde van (Write-Host en CLI, LogBox en GUI).
    # Texto compartido a proposito: si CLI y GUI redactaran cada una lo suyo acabarian
    # diciendo cosas distintas del mismo hallazgo, que es como se pierde la confianza.
    # $Title existe para que 44-latency reuse ESTE render en vez de escribir el suyo: un
    # hallazgo debe leerse igual venga de donde venga. El default es el literal de siempre, asi
    # que todos los llamantes anteriores producen exactamente la misma salida que antes.
    # $BadNote es la linea que explica DONDE se arregla lo que salio mal, y tiene que ser
    # parametrizable porque no es cierta fuera de este modulo: los hallazgos de 35-diag viven
    # en la BIOS y en los slots, pero los de 44-latency viven en un driver o en el software del
    # raton. Reusar el render con el pie equivocado seria decirle al usuario que busque en la
    # BIOS un problema de DPC. El default es el literal de siempre.
    param(
        [Parameter(Mandatory)]$Findings,
        [string]$Title = 'AXE DIAGNOSTICO DE CONFIGURACION',
        [string]$BadNote = 'Ninguno se arregla desde AXE: viven en la BIOS, en los slots o en Configuracion de Windows.'
    )
    $L = New-Object System.Collections.Generic.List[string]
    [void]$L.Add("== $Title ==")
    [void]$L.Add('')
    $bad = @($Findings | Where-Object Status -eq 'BAD')
    $unk = @($Findings | Where-Object Status -eq 'UNKNOWN')
    foreach($f in $Findings){
        $mark = switch($f.Status){ 'BAD'{'[MAL]'} 'OK'{'[OK ]'} default{'[ ? ]'} }
        [void]$L.Add(("{0} {1}" -f $mark,$f.Title))
        [void]$L.Add(("      {0}" -f $f.Detail))
        if($f.Status -eq 'BAD'){
            [void]$L.Add(("      EN JUEGO : {0} (estimacion tipica, NO medida en esta maquina)" -f $f.EstPct))
            [void]$L.Add(("      ARREGLO  : {0}" -f $f.Fix))
        }
        if($f.Confidence -and $f.Status -ne 'OK'){ [void]$L.Add(("      CONFIANZA: {0}" -f $f.Confidence)) }
        [void]$L.Add('')
    }
    [void]$L.Add('---')
    if($bad.Count -eq 0 -and $unk.Count -eq 0){
        [void]$L.Add('Nada mal configurado de lo que se comprueba aqui.')
        [void]$L.Add('Los tweaks del catalogo pelean por porcentajes de un digito sobre esta base.')
    } else {
        if($bad.Count -gt 0){
            # Sin cifra de catalogo a proposito: el numero de tweaks crece y una constante aqui
            # envejece sola. Es el mismo motivo por el que el badge de tests no lleva numero.
            [void]$L.Add(("{0} punto(s) mal configurados. Valen mas que todo el catalogo junto." -f $bad.Count))
            if($BadNote){ [void]$L.Add($BadNote) }
        }
        if($unk.Count -gt 0){ [void]$L.Add(("{0} sin comprobar: se dicen en vez de darlos por buenos." -f $unk.Count)) }
    }
    $L.ToArray()
}


# >>>>> MODULE: 36-report.ps1 >>>>>
# =====================================================
# REGION 8d - REPORTE: delta antes/despues + export JSON (Trust & Proof)
# =====================================================
function Format-AXEMetric($v){ if($v -is [string]){ 'n/a' } else { "$v" } }

function Get-AXEDeltaTag {
    # Deadband anti-ruido: |delta| < max(0.1, 10% del previo) => "igual".
    # $better = 'down' si menor es mejor (timer/jitter). Devuelve mejora|igual|regresion.
    param([double]$before,[double]$after,[string]$better='down')
    $band=[math]::Max(0.1,[math]::Abs($before)*0.10)
    $d=$after-$before
    if([math]::Abs($d) -lt $band){ return 'igual' }
    if($better -eq 'down'){ if($d -lt 0){'mejora'}else{'regresion'} }
    else { if($d -gt 0){'mejora'}else{'regresion'} }
}

function New-AXEReport {
    # String multi-linea, runspace-safe. Campos n/a nunca calculan delta falso.
    param($snap0,$snap1,$scoreBefore,$scoreAfter)
    $L=New-Object System.Collections.ArrayList
    [void]$L.Add('=== AXE REPORTE (Trust & Proof) ===')
    # Timer
    if($snap0.Timer -is [string] -or $snap1.Timer -is [string]){
        [void]$L.Add(("Timer          : {0} -> {1}" -f (Format-AXEMetric $snap0.Timer),(Format-AXEMetric $snap1.Timer)))
    } else {
        $tag=Get-AXEDeltaTag ([double]$snap0.Timer.CurrentMs) ([double]$snap1.Timer.CurrentMs) 'down'
        [void]$L.Add(("Timer          : {0}ms -> {1}ms   ({2})" -f $snap0.Timer.CurrentMs,$snap1.Timer.CurrentMs,$tag))
    }
    # Jitter P99.9 (proxy)
    if($snap0.Jitter -is [string] -or $snap1.Jitter -is [string]){
        [void]$L.Add(("Jitter P99.9   : {0} -> {1}  (proxy)" -f (Format-AXEMetric $snap0.Jitter),(Format-AXEMetric $snap1.Jitter)))
    } else {
        $tag=Get-AXEDeltaTag ([double]$snap0.Jitter.P999Ms) ([double]$snap1.Jitter.P999Ms) 'down'
        [void]$L.Add(("Jitter P99.9   : {0}ms -> {1}ms   ({2}, proxy no por-driver)" -f $snap0.Jitter.P999Ms,$snap1.Jitter.P999Ms,$tag))
    }
    # Cobertura
    [void]$L.Add(("Cobertura T0/1 : {0}/{1} -> {2}/{3}" -f (Format-AXEMetric $snap0.TweaksOn),(Format-AXEMetric $snap0.TweaksApplicable),(Format-AXEMetric $snap1.TweaksOn),(Format-AXEMetric $snap1.TweaksApplicable)))
    # Score
    $delta=$scoreAfter.Total-$scoreBefore.Total
    $sign=if($delta -ge 0){"+$delta"}else{"$delta"}
    [void]$L.Add(("AXE Score      : {0} -> {1}   ({2})" -f $scoreBefore.Total,$scoreAfter.Total,$sign))
    [void]$L.Add('--- desglose (despues) ---')
    [void]$L.Add($scoreAfter.Breakdown)
    [void]$L.Add('Deadband: timer exacto; jitter |d|<max(0.1ms,10%) = igual.')
    ($L -join "`r`n")
}

function Export-AXEReport {
    param($snap0,$snap1,$file)
    $obj=[pscustomobject]@{
        timestamp   = (Get-Date).ToUniversalTime().ToString('u')
        snap0       = $snap0
        snap1       = $snap1
        scoreBefore = (Get-AXEScore $snap0)
        scoreAfter  = (Get-AXEScore $snap1 $snap0)
    }
    $obj | ConvertTo-Json -Depth 6 | Set-Content $file -Encoding UTF8
    "Reporte exportado: $file"
}


# >>>>> MODULE: 37-netmon.ps1 >>>>>
# =====================================================
# REGION 9.5 - MONITOR DE RED EN VIVO (ping, jitter de red, perdida)
# =====================================================
# POR QUE EXISTE: hasta ahora la cobertura de red medida era CERO. El jitter que reporta
# 32-measure.ps1 es jitter de TIMER (despertar del scheduler), no de red: son dos cosas
# distintas y confundirlas es el tipo de metrica de vanidad que este proyecto rechaza. El
# catalogo toca ~8 ajustes de RED y no habia forma de ver si alguno hacia algo.
#
# QUE MIDE Y QUE NO (leerlo antes de sacar conclusiones):
#   - Mide el camino ICMP. Los juegos usan UDP. Muchos routers y operadores DESPRIORIZAN o
#     limitan ICMP, asi que un ping alto no implica que el juego vaya mal, ni un ping bajo
#     que vaya bien. Es un indicador, no el dato del juego.
#   - Por eso se miden DOS destinos y se reportan por separado:
#       * puerta de enlace -> calidad del ENLACE local (radio Wi-Fi, cable, driver del NIC).
#         Aqui si hay conclusiones duras: perder paquetes contra tu propio router no es normal.
#       * ancla publica    -> el camino a internet. Sin veredicto absoluto: la latencia depende
#         de la geografia y no existe un umbral honesto de "buen ping".
#   - No hay puntuacion 0-100. Un numero unico aqui seria inventado.
#
# La parte que decide (Get-AXENetStats / Get-AXENetFindings) es PURA: recibe muestras y
# devuelve numeros y hallazgos sin tocar la red. Asi se testea sin hardware ni conexion.

function Get-AXENetStats {
    # PURA. $Samples = RTT en ms por sonda; $null = paquete perdido.
    param([object[]]$Samples)

    $all  = @($Samples)
    $ok   = @($all | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $sent = $all.Count
    $recv = $ok.Count

    if($sent -eq 0){
        return [pscustomobject]@{
            Sent=0; Received=0; LostPct=$null; MinMs=$null; AvgMs=$null
            MaxMs=$null; P95Ms=$null; JitterMs=$null
        }
    }
    $lost = [math]::Round(100.0 * ($sent - $recv) / $sent, 1)
    if($recv -eq 0){
        return [pscustomobject]@{
            Sent=$sent; Received=0; LostPct=$lost; MinMs=$null; AvgMs=$null
            MaxMs=$null; P95Ms=$null; JitterMs=$null
        }
    }

    $sorted = @($ok | Sort-Object)
    # P95 por rango mas cercano, sin interpolar. Con 20 sondas la interpolacion finge una
    # precision que no existe; el indice entero es honesto y reproducible.
    $idx = [int][math]::Ceiling(0.95 * $sorted.Count) - 1
    if($idx -lt 0){ $idx = 0 }
    if($idx -ge $sorted.Count){ $idx = $sorted.Count - 1 }

    # Jitter de red = media del |delta| entre RTT CONSECUTIVOS, que es lo que se percibe como
    # inestabilidad. NO es la desviacion tipica: un RTT que sube despacio y de forma monotona
    # da desviacion alta y no se nota; saltar 5ms arriba y abajo cada paquete si se nota.
    #   Los deltas se toman solo entre sondas CONSECUTIVAS RECIBIDAS. Saltarse las perdidas y
    # encadenar los dos extremos del hueco inflaria el jitter con un intervalo que en realidad
    # cubre varios periodos: la perdida ya se reporta aparte y no se cobra dos veces.
    $deltas = New-Object System.Collections.Generic.List[double]
    for($i=1; $i -lt $all.Count; $i++){
        $a = $all[$i-1]; $b = $all[$i]
        if($null -eq $a -or $null -eq $b){ continue }
        [void]$deltas.Add([math]::Abs([double]$b - [double]$a))
    }
    $jit = $null
    if($deltas.Count -gt 0){ $jit = [math]::Round((($deltas | Measure-Object -Average).Average), 2) }

    [pscustomobject]@{
        Sent     = $sent
        Received = $recv
        LostPct  = $lost
        MinMs    = [math]::Round(($ok | Measure-Object -Minimum).Minimum, 2)
        AvgMs    = [math]::Round(($ok | Measure-Object -Average).Average, 2)
        MaxMs    = [math]::Round(($ok | Measure-Object -Maximum).Maximum, 2)
        P95Ms    = [math]::Round($sorted[$idx], 2)
        JitterMs = $jit
    }
}

function Get-AXENetFindings {
    # PURA. Solo emite hallazgos donde el dato es INEQUIVOCO. Deliberadamente corta: la
    # tentacion es puntuar el ping a internet, y no hay umbral defendible (200ms desde otro
    # continente puede ser perfectamente normal). Contra la propia puerta de enlace si lo hay.
    param($Gw, $Pub)

    $out = New-Object System.Collections.ArrayList

    if($Gw -and $Gw.Sent -gt 0){
        if($Gw.Received -eq 0){
            [void]$out.Add([pscustomobject]@{ Sev='ERR'; Msg='La puerta de enlace no responde a ninguna sonda. O filtra ICMP, o el enlace esta caido.' })
        } else {
            # Perdida contra el router: no atraviesa internet, no hay operador de por medio.
            # Cualquier valor > 0 apunta a radio, cable o driver del adaptador.
            if($Gw.LostPct -gt 0){
                [void]$out.Add([pscustomobject]@{ Sev='ERR'; Msg=("Perdida del {0}% contra tu propia puerta de enlace. Eso no cruza internet: mira la radio Wi-Fi, el cable o el driver del NIC." -f $Gw.LostPct) })
            }
            # Jitter local. El umbral es un corte practico, no una constante fisica: por cable el
            # enlace local aporta decimas de ms, asi que varios ms de variacion consecutiva ya
            # delatan la radio o un adaptador con problemas. Se dice que es un corte, no una ley.
            #   AVISO DE INTERPRETACION, y no es un tecnicismo: un router responde a los pings
            # DIRIGIDOS A EL con su CPU de gestion, que tiene la prioridad mas baja del aparato,
            # mientras que el trafico que solo REENVIA va por la ruta rapida. Por eso se ve a
            # menudo mas jitter contra el propio router que contra un destino de internet que
            # pasa por el. Medido en la maquina de referencia: 7.91ms contra la puerta de enlace
            # frente a 0.55ms contra 1.1.1.1, que atraviesa ese mismo router.
            #   Afirmar "tu radio va mal" con este dato seria pasarse. Se reporta la medida y las
            # DOS lecturas posibles, y se apunta a la comparacion que si distingue: si el tramo a
            # internet sale estable, el enlace no puede ser el cuello.
            if($null -ne $Gw.JitterMs -and $Gw.JitterMs -gt 5){
                $msg = "Jitter de {0}ms hasta el router (corte practico: 5ms)." -f $Gw.JitterMs
                if($Pub -and $Pub.Received -gt 0 -and $null -ne $Pub.JitterMs -and $Pub.JitterMs -le $Gw.JitterMs){
                    $msg += " Pero el tramo a internet, que pasa por ese mismo router, sale en {0}ms: entonces lo que ves es la CPU de gestion del router respondiendo tarde a sus propios pings, no tu enlace. No es accionable desde el PC." -f $Pub.JitterMs
                } else {
                    $msg += ' Dos lecturas posibles: enlace inestable (radio, cable, driver) o la CPU de gestion del router respondiendo tarde a sus propios pings. Mide tambien hacia internet: si ese tramo sale estable, el enlace no es el problema.'
                }
                [void]$out.Add([pscustomobject]@{ Sev='WARN'; Msg=$msg })
            }
        }
    }
    # Perdida hacia fuera con enlace local limpio: separa "tu PC" de "tu operador". Sin el 0%
    # local no se puede afirmar, porque la perdida podria venir del propio enlace.
    if($Pub -and $Pub.Sent -gt 0 -and $Pub.Received -gt 0 -and $Pub.LostPct -gt 0 -and $Gw -and $Gw.Received -gt 0 -and $Gw.LostPct -eq 0){
        [void]$out.Add([pscustomobject]@{ Sev='WARN'; Msg=("Perdida del {0}% hacia internet con 0% hasta tu router: el problema esta fuera de casa (operador o ruta), no en el PC." -f $Pub.LostPct) })
    }
    if($out.Count -eq 0){
        [void]$out.Add([pscustomobject]@{ Sev='OK'; Msg='Sin hallazgos inequivocos. Los numeros de arriba siguen siendo del camino ICMP, no del trafico del juego.' })
    }
    $out.ToArray()
}

function Get-AXENetGateway {
    # Puerta de enlace IPv4 por defecto. $null si no hay (sin red, o red solo IPv6).
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA Stop |
             Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
             Sort-Object RouteMetric | Select-Object -First 1
        if($r){ return [string]$r.NextHop }
    } catch {}
    try {
        $c = Get-NetIPConfiguration -EA Stop | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if($c){ return [string]$c.IPv4DefaultGateway.NextHop }
    } catch {}
    $null
}

function Measure-AXENetProbe {
    # Sondea UN destino. Devuelve el objeto de Get-AXENetStats con Target anadido.
    # Sin dependencias externas: System.Net.NetworkInformation.Ping viene con .NET.
    param(
        [string]$Target,
        [int]$Count = 20,
        [int]$IntervalMs = 200,
        [int]$TimeoutMs = 1000
    )
    if([string]::IsNullOrWhiteSpace($Target)){ return $null }

    $samples = New-Object System.Collections.Generic.List[object]
    $ping = New-Object System.Net.NetworkInformation.Ping
    # 32 bytes = lo que manda ping.exe, para poder contrastar con el ping del sistema.
    $payload = New-Object byte[] 32
    try {
        for($i=0; $i -lt $Count; $i++){
            $rtt = $null
            try {
                $r = $ping.Send($Target, $TimeoutMs, $payload)
                # Solo Success cuenta como recibido. TimedOut, TtlExpired o DestinationUnreachable
                # son perdida desde el punto de vista del que juega: la respuesta no llego.
                if($r.Status -eq 'Success'){ $rtt = [double]$r.RoundtripTime }
            } catch { $rtt = $null }
            [void]$samples.Add($rtt)
            # Sin espera tras la ultima sonda: solo alargaria la medicion sin aportar nada.
            if($i -lt ($Count-1) -and $IntervalMs -gt 0){ Start-Sleep -Milliseconds $IntervalMs }
        }
    } finally { $ping.Dispose() }

    $st = Get-AXENetStats -Samples $samples.ToArray()
    $st | Add-Member -NotePropertyName Target -NotePropertyValue $Target -PassThru
}

function Measure-AXENetwork {
    # Medicion completa: enlace local + ancla publica, con hallazgos.
    #   El ancla por defecto es 1.1.1.1 porque responde a ICMP de forma estable y es anycast
    # global, o sea que mide TU camino y no la distancia a un pais concreto. No se elige "el
    # DNS mas rapido" ni se rankean proveedores: eso fue justo lo que se borro de
    # 22-catalogs.ps1 por rankear sin medir.
    param(
        [string]$Target = '1.1.1.1',
        [int]$Count = 20,
        [int]$IntervalMs = 200,
        [switch]$NoGateway
    )
    $gw = $null
    $gwIp = $(if($NoGateway){ $null } else { Get-AXENetGateway })
    if($gwIp){ $gw = Measure-AXENetProbe -Target $gwIp -Count $Count -IntervalMs $IntervalMs }
    $pub = Measure-AXENetProbe -Target $Target -Count $Count -IntervalMs $IntervalMs

    [pscustomobject]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('u')
        Adapter   = $(if($script:HW){ $script:HW.NicName } else { $null })
        IsWifi    = $(if($script:HW){ [bool]$script:HW.IsWifi } else { $null })
        Gateway   = $gw
        Public    = $pub
        Findings  = (Get-AXENetFindings -Gw $gw -Pub $pub)
    }
}

# =====================================================
# LATENCIA BAJO CARGA (bufferbloat)
# =====================================================
#
# POR QUE EXISTE: todo lo de arriba mide la red EN REPOSO, y en reposo casi cualquier linea da
# un ping decente. La latencia de juego no se muere en reposo: se muere cuando alguien de casa
# se pone a descargar algo. Ahi el router llena su buffer de salida, tus paquetes de juego se
# ponen a la cola detras de megas de descarga, y el ping se va de 20 ms a 300 sin que se caiga
# nada. Eso es bufferbloat, y es LA metrica de red que importa para jugar.
#
# No se puede medir sin saturar el enlace: es la naturaleza de la prueba. Por eso va detras de
# un switch propio y no dentro de -NetMon, y por eso dice a donde se conecta antes de hacerlo.

# Destino de carga por defecto. speed.cloudflare.com es anycast, gratuito, sin cuenta y sin
# limite de peticiones; el parametro 'bytes' pide un flujo de basura del tamanio que se quiera.
# No se manda NADA del equipo: es una descarga. Configurable por si alguien prefiere su propio
# servidor o no quiere tocar Cloudflare.
$script:AXENetLoadUrl = 'https://speed.cloudflare.com/__down?bytes=250000000'

# Cuatro flujos en paralelo. Con uno solo, una linea rapida no se satura: el control de
# congestion de un unico TCP no llega al techo en los pocos segundos que dura la prueba, y
# entonces se mediria "no hay bufferbloat" cuando lo que pasa es que no se cargo el enlace.
$script:AXENetLoadStreams = 4

# Escala de nota. Es la del proyecto Bufferbloat / Waveform, que es el estandar de facto para
# esto, traducida al incremento de P95 sobre el reposo.
$script:AXENetLoadGrades = @(
    @{ Max =   5; Grade = 'A+' }
    @{ Max =  30; Grade = 'A'  }
    @{ Max =  60; Grade = 'B'  }
    @{ Max = 200; Grade = 'C'  }
    @{ Max = 400; Grade = 'D'  }
)

function Start-AXENetLoad {
    # IMPURA: abre N descargas en runspaces y vuelve enseguida. El que llama sondea MIENTRAS
    # esto corre. Cada runspace lleva su propio limite de tiempo: si el que llama muere, las
    # descargas se paran solas y no queda nada colgado tirando de la linea.
    param(
        [string]$Url = $script:AXENetLoadUrl,
        [int]$Streams = $script:AXENetLoadStreams,
        [int]$Seconds = 15
    )
    $pool = [runspacefactory]::CreateRunspacePool(1, [math]::Max(1,$Streams))
    $pool.Open()
    $work = New-Object System.Collections.Generic.List[object]
    $sb = {
        param($url, $seconds)
        $total = 0L
        try {
            # Tls12 explicito: PS 5.1 en Win10 arranca con SSL3/Tls1 y Cloudflare los rechaza.
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Timeout = 10000; $req.ReadWriteTimeout = 10000
            $resp = $req.GetResponse()
            $st   = $resp.GetResponseStream()
            $buf  = New-Object byte[] 65536
            $deadline = (Get-Date).AddSeconds($seconds)
            while((Get-Date) -lt $deadline){
                $n = $st.Read($buf, 0, $buf.Length)
                if($n -le 0){ break }
                $total += $n
            }
            $st.Close(); $resp.Close()
        } catch {}
        $total
    }
    for($i=0; $i -lt $Streams; $i++){
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($sb).AddArgument($Url).AddArgument($Seconds)
        [void]$work.Add([pscustomobject]@{ Ps = $ps; Handle = $ps.BeginInvoke() })
    }
    [pscustomobject]@{ Pool = $pool; Work = $work.ToArray() }
}

function Stop-AXENetLoad {
    # Recoge los bytes descargados y cierra todo. En finally del llamante: dejar un runspace
    # pool abierto deja hilos vivos en el proceso, y en la GUI eso se acumula por cada prueba.
    param($Load)
    $bytes = 0L
    if(-not $Load){ return 0L }
    foreach($w in @($Load.Work)){
        try { foreach($r in @($w.Ps.EndInvoke($w.Handle))){ if($r){ $bytes += [long]$r } } } catch {}
        try { $w.Ps.Dispose() } catch {}
    }
    try { $Load.Pool.Close(); $Load.Pool.Dispose() } catch {}
    $bytes
}

function Get-AXELoadedLatency {
    # PURA: dos objetos de Get-AXENetStats (reposo y bajo carga) -> veredicto.
    #
    # SE PUNTUA EL P95, NO LA MEDIA, y es deliberado. El bufferbloat no sube el ping de forma
    # uniforme: llena el buffer a rachas. Una media que sube 20 ms puede esconder picos de 300
    # que son exactamente los que te matan en la partida. La media se reporta igual, pero la
    # nota sale de la cola, que es lo que se sufre.
    param($Idle, $Loaded, [long]$Bytes = 0)

    if($null -eq $Idle -or $null -eq $Loaded -or $null -eq $Idle.P95Ms -or $null -eq $Loaded.P95Ms){
        return [pscustomobject]@{
            IdleP95=$null; LoadedP95=$null; DeltaP95=$null; DeltaAvg=$null
            Grade=$null; Status='UNKNOWN'; MBytes=[math]::Round($Bytes/1MB,1)
            Detail='no se pudo medir el ping en reposo o bajo carga (sin respuesta del destino).'
        }
    }
    # Sin descarga real no hay prueba: si la carga no llego a bajar nada, un resultado bueno
    # significaria "no se cargo el enlace", no "el enlace aguanta". Se dice, no se puntua.
    if($Bytes -lt 2MB){
        return [pscustomobject]@{
            IdleP95=$Idle.P95Ms; LoadedP95=$Loaded.P95Ms
            DeltaP95=[math]::Round($Loaded.P95Ms - $Idle.P95Ms,2); DeltaAvg=$null
            Grade=$null; Status='UNKNOWN'; MBytes=[math]::Round($Bytes/1MB,1)
            Detail='la descarga de carga no llego a 2 MB: el enlace no se saturo, asi que el resultado no significa nada. Comprueba que hay internet y vuelve a probar.'
        }
    }

    $dP95 = [math]::Round($Loaded.P95Ms - $Idle.P95Ms, 2)
    $dAvg = $null
    if($null -ne $Idle.AvgMs -and $null -ne $Loaded.AvgMs){ $dAvg = [math]::Round($Loaded.AvgMs - $Idle.AvgMs, 2) }

    # Un delta negativo es ruido de medicion, no una mejora: cargar el enlace no puede bajar el
    # ping. Se trata como 0 para la nota en vez de premiar el ruido con un A+ inmerecido.
    $forGrade = [math]::Max(0.0, [double]$dP95)
    $grade = 'F'
    foreach($g in $script:AXENetLoadGrades){ if($forGrade -lt $g.Max){ $grade = $g.Grade; break } }

    # BAD a partir de C: +60 ms de cola sobre el reposo ya se nota en cualquier juego online.
    $status = if($grade -in @('A+','A','B')){ 'OK' } else { 'BAD' }
    $detail = if($status -eq 'OK'){
        "El ping sube $dP95 ms (P95) con el enlace saturado. El router no acumula cola: nota $grade."
    } else {
        "El ping sube $dP95 ms (P95) con el enlace saturado: de $($Idle.P95Ms) a $($Loaded.P95Ms) ms. Nota $grade. Es lo que te pasa cuando alguien de casa descarga algo mientras juegas."
    }

    [pscustomobject]@{
        IdleP95=$Idle.P95Ms; LoadedP95=$Loaded.P95Ms; DeltaP95=$dP95; DeltaAvg=$dAvg
        Grade=$grade; Status=$status; MBytes=[math]::Round($Bytes/1MB,1); Detail=$detail
    }
}

function Measure-AXENetLoaded {
    # IMPURA: reposo -> saturar -> bajo carga. El orden importa: medir primero en reposo evita
    # que la cola que deje la descarga contamine la linea base.
    param(
        [string]$Target = '1.1.1.1',
        [int]$Count = 20,
        [int]$IntervalMs = 200,
        [string]$Url = $script:AXENetLoadUrl,
        [int]$Streams = $script:AXENetLoadStreams
    )
    $idle = Measure-AXENetProbe -Target $Target -Count $Count -IntervalMs $IntervalMs

    # La descarga dura un poco mas que el sondeo para que NO se corte antes de la ultima sonda:
    # si la carga terminase primero, las ultimas sondas medirian reposo y bajarian el P95.
    $probeMs = ($Count * $IntervalMs) + 2000
    $load = $null; $bytes = 0L; $loaded = $null
    try {
        $load   = Start-AXENetLoad -Url $Url -Streams $Streams -Seconds ([int][math]::Ceiling($probeMs/1000.0) + 3)
        # Un segundo de margen: el arranque de TCP no satura el enlace de forma instantanea, y
        # sondear durante ese arranque diluiria la carga con muestras casi de reposo.
        Start-Sleep -Milliseconds 1000
        $loaded = Measure-AXENetProbe -Target $Target -Count $Count -IntervalMs $IntervalMs
    } finally {
        $bytes = Stop-AXENetLoad -Load $load
    }

    [pscustomobject]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('u')
        Adapter   = $(if($script:HW){ $script:HW.NicName } else { $null })
        IsWifi    = $(if($script:HW){ [bool]$script:HW.IsWifi } else { $null })
        Target    = $Target
        LoadUrl   = $Url
        Idle      = $idle
        Loaded    = $loaded
        Verdict   = (Get-AXELoadedLatency -Idle $idle -Loaded $loaded -Bytes $bytes)
    }
}

function Format-AXENetLoaded {
    # PURA. Render de la prueba bajo carga.
    param($r)
    if(-not $r){ return 'Sin medicion de latencia bajo carga.' }
    $L = New-Object System.Collections.ArrayList
    $ad = $(if($r.Adapter){ $r.Adapter } else { 'adaptador desconocido' })
    $md = $(if($r.IsWifi -eq $true){ 'Wi-Fi' } elseif($r.IsWifi -eq $false){ 'cable' } else { 'medio desconocido' })
    [void]$L.Add("LATENCIA BAJO CARGA (bufferbloat) - $ad ($md)")
    [void]$L.Add("Destino de ping: $($r.Target)   Carga: $($r.LoadUrl)")
    [void]$L.Add('')
    $v = $r.Verdict
    if($null -ne $v.IdleP95){   [void]$L.Add(("  reposo      P95 {0} ms" -f $v.IdleP95)) }
    if($null -ne $v.LoadedP95){ [void]$L.Add(("  bajo carga  P95 {0} ms   ({1} MB descargados)" -f $v.LoadedP95,$v.MBytes)) }
    if($null -ne $v.DeltaAvg){  [void]$L.Add(("  media       {0} ms de subida" -f $v.DeltaAvg)) }
    [void]$L.Add('')
    $mark = switch($v.Status){ 'BAD'{'[MAL]'} 'OK'{'[OK ]'} default{'[ ? ]'} }
    [void]$L.Add(("{0} {1}" -f $mark,$v.Detail))
    if($v.Status -eq 'BAD'){
        [void]$L.Add('')
        [void]$L.Add('ARREGLO: activa SQM/QoS inteligente en el router (busca "Smart Queue", "SQM"')
        [void]$L.Add('o "cake"/"fq_codel"). Si el router no lo trae, limitar la subida al 85-90%')
        [void]$L.Add('de lo contratado suele quitar la mayor parte de la cola. Cambiar de operador')
        [void]$L.Add('casi nunca hace falta: el buffer es del router, no de la linea.')
    }
    ($L -join "`r`n")
}

function Format-AXENetwork {
    param($r)
    if(-not $r){ return 'Sin medicion de red.' }
    $L = New-Object System.Collections.ArrayList
    $ad = $(if($r.Adapter){ $r.Adapter } else { 'adaptador desconocido' })
    $md = $(if($r.IsWifi -eq $true){ 'Wi-Fi' } elseif($r.IsWifi -eq $false){ 'cable' } else { 'medio desconocido' })
    [void]$L.Add("RED EN VIVO - $ad ($md)")
    [void]$L.Add('Camino ICMP. Los juegos van por UDP y muchos routers despriorizan ICMP: es un indicador, no el dato del juego.')
    [void]$L.Add('')
    foreach($p in @(@{T='Enlace local (router)';S=$r.Gateway}, @{T='Internet';S=$r.Public})){
        $s = $p.S
        if(-not $s){ [void]$L.Add(("{0,-22} : no medido" -f $p.T)); continue }
        if($s.Received -eq 0){
            [void]$L.Add(("{0,-22} : {1}  sin respuesta ({2} sondas, 100% perdida)" -f $p.T,$s.Target,$s.Sent))
            continue
        }
        [void]$L.Add(("{0,-22} : {1}" -f $p.T,$s.Target))
        [void]$L.Add(("  ping   min/med/max  {0}/{1}/{2} ms    P95 {3} ms" -f $s.MinMs,$s.AvgMs,$s.MaxMs,$s.P95Ms))
        [void]$L.Add(("  jitter {0} ms (media del salto entre paquetes)    perdida {1}% ({2}/{3})" -f $s.JitterMs,$s.LostPct,($s.Sent-$s.Received),$s.Sent))
    }
    [void]$L.Add('')
    foreach($f in @($r.Findings)){ [void]$L.Add(("[{0,-4}] {1}" -f $f.Sev,$f.Msg)) }
    ($L -join "`r`n")
}


# >>>>> MODULE: 38-regedit.ps1 >>>>>
# =====================================================
# REGION 8c - REGEDIT (diagnostico): saltar al regedit.exe de Windows en la clave de un tweak
# =====================================================
# No es un editor propio: abre el Registry Editor de Microsoft posicionado en la clave exacta
# que toca un tweak, para poder comprobar a mano lo que AXE dice. Escribir en el registro sigue
# siendo responsabilidad de APLICAR (punto de restauracion + snapshot + gating); aqui solo se
# mira. La unica escritura de este modulo es LastKey, que es el cursor del propio regedit.

# Las rutas NO estan declaradas como campo del tweak: viven dentro de los scriptblocks
# Test/Apply. Extraerlas del codigo (en vez de anadir un campo RegPath a los 78) evita que el
# campo y el codigo se desincronicen, que es el fallo clasico: alguien cambia la ruta en Apply
# y el RegPath declarado sigue apuntando a la vieja, asi que el boton abre la clave equivocada
# y el usuario concluye que el tweak no se aplico.
#   Cobertura medida sobre el catalogo actual (78): 43 con ruta literal, 12 via variable de
#   modulo ($MM, $SP, $GD...), 23 sin registro (servicios / bcdedit) que no llevan boton.
#   Las variables de BUCLE ($i, $p, $s, $_) son locales al scriptblock y no se pueden resolver
#   estaticamente: esos tweaks iteran dispositivos PnP, donde no hay UNA clave que ensenar.
function Get-AXERegPathsForTweak {
    param($Tweak)
    $paths = New-Object System.Collections.ArrayList
    if(-not $Tweak){ return @() }
    $code = ''
    foreach($sb in @($Tweak.Test,$Tweak.Apply)){ if($sb){ $code += "`n" + $sb.ToString() } }

    # 1. Rutas literales: 'HKLM:\Foo\Bar' entre comillas simples o dobles.
    foreach($m in [regex]::Matches($code,"['`"](HK(?:LM|CU|CR|CC|U):\\[^'`"]+)['`"]")){
        $p = $m.Groups[1].Value.Trim()
        if($p -and -not $paths.Contains($p)){ [void]$paths.Add($p) }
    }
    # 2. Rutas via variable de modulo: Get-RV $MM 'Valor'. Se resuelve el valor ACTUAL de la
    #    variable en el scope del modulo; si no existe o no parece ruta de registro, se ignora.
    foreach($m in [regex]::Matches($code,'(?:Get-RV|Set-RD|Set-RS|Del-RV)\s+\$(\w+)')){
        $name = $m.Groups[1].Value
        if($name -in @('_','i','p','s')){ continue }   # variables de bucle: no resolubles
        $val = $null
        try { $val = Get-Variable $name -ValueOnly -Scope Script -EA SilentlyContinue } catch {}
        if(-not $val){ try { $val = Get-Variable $name -ValueOnly -EA SilentlyContinue } catch {} }
        if($val -is [string] -and $val -match '^HK(LM|CU|CR|CC|U):\\' -and -not $paths.Contains($val)){
            [void]$paths.Add($val)
        }
    }
    @($paths)
}

# Prefijo de LastKey. OJO: esta LOCALIZADO. Medido en Windows 11 es-ES: 'Equipo\HKEY_LOCAL_MACHINE'
# (no 'Computer\'). Hardcodear el ingles hace que regedit ignore el valor y abra donde estaba,
# sin error visible: el boton "funciona" pero no salta. Por eso se reutiliza el prefijo que ya
# tiene el perfil, que por definicion esta en el idioma correcto.
function Get-AXERegeditPrefix {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit'
    $cur = Get-RV $k 'LastKey'
    if($cur -is [string] -and $cur -match '^([^\\]+)\\'){ return $Matches[1] }
    'Computer'   # perfil sin regedit abierto nunca; peor caso, abre en la raiz
}

# 'HKLM:\Foo\Bar' -> '<prefijo>\HKEY_LOCAL_MACHINE\Foo\Bar' (formato que espera LastKey).
function ConvertTo-AXERegeditPath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){ return $null }
    $hives = @{
        'HKLM' = 'HKEY_LOCAL_MACHINE'; 'HKCU' = 'HKEY_CURRENT_USER'
        'HKCR' = 'HKEY_CLASSES_ROOT';  'HKU'  = 'HKEY_USERS'
        'HKCC' = 'HKEY_CURRENT_CONFIG'
    }
    if($Path -notmatch '^(HK(?:LM|CU|CR|CC|U)):\\(.*)$'){ return $null }
    $hive = $hives[$Matches[1]]
    if(-not $hive){ return $null }
    $rest = $Matches[2].TrimEnd('\')
    $prefix = Get-AXERegeditPrefix
    if($rest){ "$prefix\$hive\$rest" } else { "$prefix\$hive" }
}

function Open-AXERegedit {
    # Posiciona regedit.exe en $Path. Devuelve $true si se lanzo.
    param([string]$Path)
    $target = ConvertTo-AXERegeditPath $Path
    if(-not $target){ Write-AXELog "Regedit: ruta no reconocida '$Path'." 'WARN'; return $false }
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit'
    try {
        if(-not (Test-Path $k)){ New-Item -Path $k -Force -EA Stop | Out-Null }
        # Escritura directa a posta, SIN Push-RegBackup: LastKey es la posicion del cursor de
        # regedit, no un ajuste del sistema. Meterlo en el backup de tweaks ensuciaria el
        # revert con una clave cosmetica que nadie quiere restaurar.
        New-ItemProperty -Path $k -Name 'LastKey' -Value $target -PropertyType String -Force -EA Stop | Out-Null
        # -m permite instancia nueva: sin el, un regedit ya abierto se lleva el foco y se
        # queda donde estaba, ignorando LastKey (que solo se lee al arrancar).
        Start-Process regedit.exe -ArgumentList '-m' -EA Stop | Out-Null
        Write-AXELog "Regedit abierto en: $Path"
        $true
    } catch {
        Write-AXELog "Regedit: no se pudo abrir -> $($_.Exception.Message)" 'ERR'
        $false
    }
}

# Foto del registro para la vista de diagnostico: una fila por (tweak, clave), con si la clave
# existe y si el Test del tweak da por aplicado. NO ejecuta Apply ni toca nada.
function Get-AXERegDiagnostic {
    param($Catalog=$null)
    if(-not $Catalog){ $Catalog = $script:CAT }
    $rows = New-Object System.Collections.ArrayList
    foreach($tw in @($Catalog)){
        $paths = @(Get-AXERegPathsForTweak $tw)
        if($paths.Count -eq 0){ continue }
        # Test puede lanzar (clave inexistente, permisos): un diagnostico que revienta no
        # diagnostica nada, asi que se degrada a $null y se sigue.
        #   El centinela es $null y NO la cadena 'n/a'. Con 'n/a', el chequeo posterior
        #   '$Applied -eq "n/a"' coacciona la cadena a booleano ($true por no estar vacia), asi
        #   que TODO tweak aplicado ($true -eq 'n/a' => True) se pintaba como indecidible.
        #   Medido: 47 de 55 filas aplicadas se mostraban como [?]. Con $null no hay coercion.
        $applied = $null
        try { $applied = [bool](& $tw.Test) } catch {}
        foreach($p in $paths){
            [void]$rows.Add([pscustomobject]@{
                Id      = $tw.Id
                Cat     = $tw.Cat
                Tier    = $tw.Tier
                Name    = $tw.Name
                Path    = $p
                Exists  = [bool](Test-Path $p)
                Applied = $applied
            })
        }
    }
    @($rows)
}

function Format-AXERegDiagnostic {
    # Render de la vista. Agrupa por clave y no por tweak: varios tweaks comparten ruta
    # (Memory Management, SystemProfile), y verlos juntos es justo lo que hace falta para
    # entender por que dos ajustes se pisan.
    param($Rows)
    $Rows = @($Rows)
    if($Rows.Count -eq 0){ return @('Sin claves de registro en el catalogo cargado.') }
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add("$($Rows.Count) entradas sobre $(@($Rows | Select-Object -ExpandProperty Path -Unique).Count) claves distintas.")
    [void]$L.Add('  [x] = Test dice aplicado   [ ] = no aplicado   [?] = el Test no pudo decidir')
    [void]$L.Add('  (falta) = la clave no existe todavia en este equipo')
    [void]$L.Add('')
    foreach($grp in ($Rows | Group-Object Path | Sort-Object Name)){
        $miss = if($grp.Group[0].Exists){ '' } else { '   (falta)' }
        [void]$L.Add("$($grp.Name)$miss")
        foreach($r in ($grp.Group | Sort-Object Id)){
            # '$null -eq' delante a proposito: al reves, PowerShell coacciona y falla raro.
            $mark = if($null -eq $r.Applied){ '?' } elseif($r.Applied){ 'x' } else { ' ' }
            [void]$L.Add(("    [{0}] {1,-22} T{2}  {3}" -f $mark,$r.Id,$r.Tier,$r.Name))
        }
        [void]$L.Add('')
    }
    @($L)
}


# >>>>> MODULE: 39-webdetect.ps1 >>>>>
# =====================================================
# REGION 12b - WEBVIEW2: DETECCION (runtime + SDK + rutas de assets)
# =====================================================
# Va ANTES de 45-cli a proposito: el bloque -SelfTest de 45-cli hace 'exit' antes de que
# carguen los modulos 47+ (host) y 50+ (GUI vieja). Para que el SelfTest pueda comprobar la
# deteccion (S27) y los assets (S26), estas funciones puras (solo registro + Test-Path) tienen
# que estar definidas aqui. El HOST (ventana WPF + control WebView2) vive en 47-webhost (Fase 1).
# Cargar este modulo SOLO define funciones/vars; nada se ejecuta.

# $AXERoot en runtime = la carpeta del .ps1 que corre. El build produce dist\AXE.ps1, asi que
# AXERoot = ...\AXE\dist, pero webui/ y webview2/ viven en ...\AXE (el padre). AXEHome resuelve
# ambos casos: assets al lado del script, o un nivel arriba (dist).
$script:AXEHome = $script:AXERoot
if(-not (Test-Path (Join-Path $script:AXEHome 'webui'))){
    $parent = Split-Path $script:AXERoot -Parent
    if($parent -and (Test-Path (Join-Path $parent 'webui'))){ $script:AXEHome = $parent }
}
$script:WebUIDir    = Join-Path $script:AXEHome 'webui'
$script:WebView2Sdk = Join-Path $script:AXEHome 'webview2'

function Get-AXEWebView2SdkPath {
    # Los DLL del SDK se vendorizan en AXE/webview2/ (no se descargan en runtime).
    if(Test-Path (Join-Path $script:WebView2Sdk 'Microsoft.Web.WebView2.Wpf.dll')){ return $script:WebView2Sdk }
    return $null
}

function Get-AXEWindowFit {
    # PURA. (area util del escritorio, tamano deseado) -> tamano que CABE de verdad.
    #
    # El bug que arregla: la ventana venia fijada a 1200x840 con MinHeight=720. Width/Height de WPF
    # van en DIP (1/96") y el area util TAMBIEN (SystemParameters.WorkArea), asi que a mas escalado
    # de Windows hay MENOS DIP disponibles, no los mismos. Con la pantalla de referencia -1920x1080
    # al 125%- el area util son 1536x816 DIP: la ventana nacia 24 DIP mas alta que el escritorio.
    # Al 150% son 1280x680 DIP y ni el MINIMO cabia, o sea que no habia forma de encogerla hasta
    # que entrase: el borde inferior se quedaba debajo de la barra de tareas para siempre.
    #   La correccion no toca DPI ni manifiestos: basta con recortar en la MISMA unidad en la que
    # WPF coloca la ventana. Comparar DIP con DIP hace que el escalado deje de importar.
    param(
        [double]$WorkWidth,  [double]$WorkHeight,
        [double]$WantWidth  = 1200, [double]$WantHeight = 840,
        [double]$FloorWidth = 820,  [double]$FloorHeight = 520,
        [double]$Slack      = 24
    )
    # Area util ilegible (0, negativa o NaN): se devuelve lo deseado tal cual. Inventar un tamano a
    # partir de un dato que no tenemos seria peor que dejar el de siempre.
    $bad = [double]::IsNaN($WorkWidth) -or [double]::IsNaN($WorkHeight) -or $WorkWidth -le 0 -or $WorkHeight -le 0
    if($bad){
        return [pscustomobject]@{
            Width=$WantWidth; Height=$WantHeight; MinWidth=$FloorWidth; MinHeight=$FloorHeight
            Clamped=$false; Reason='no pude leer el area util del escritorio; se usa el tamano por defecto.'
        }
    }
    # El hueco (Slack) evita que la ventana nazca pegada a los bordes. En pantallas diminutas se
    # cede antes que dejar la ventana sin area: el suelo duro es 320x240.
    $availW = [math]::Max(320, $WorkWidth  - $Slack)
    $availH = [math]::Max(240, $WorkHeight - $Slack)
    $w = [math]::Min($WantWidth,  $availW)
    $h = [math]::Min($WantHeight, $availH)
    # El MINIMO se recorta al tamano real, nunca al reves. Un MinHeight mayor que la pantalla es
    # justo el defecto que hacia imposible encoger la ventana; asi no puede volver por construccion.
    $minW = [math]::Min($FloorWidth,  $w)
    $minH = [math]::Min($FloorHeight, $h)
    $clamped = ($w -lt $WantWidth) -or ($h -lt $WantHeight)
    [pscustomobject]@{
        Width=$w; Height=$h; MinWidth=$minW; MinHeight=$minH; Clamped=$clamped
        Reason=$(if($clamped){
            'ventana ajustada a {0}x{1} DIP: el escritorio util son {2}x{3} DIP (escalado de Windows ya incluido).' -f [int]$w,[int]$h,[int]$WorkWidth,[int]$WorkHeight
        } else { $null })
    }
}

# --- Zoom de la interfaz, persistente -------------------------------------------------------
# Ctrl+rueda y Ctrl+/- ya funcionan (WebView2 los trae de serie), pero el nivel se perdia al
# cerrar. Es la otra mitad de "que la escala se ajuste": el recorte de ventana hace que la
# interfaz QUEPA, el zoom decide CUANTA interfaz cabe dentro. Vive aqui y no en 47-webhost
# porque 47 no se puede dot-sourcear en tests (abre ventana) y estas dos si tienen que estarlo.
$script:AXEUIZoomMin = 0.6
$script:AXEUIZoomMax = 2.0

function Get-AXEUIPrefsPath {
    # Sin $script:AXEData (motor cargado suelto) devuelve $null: el llamante degrada a 1.0.
    if([string]::IsNullOrWhiteSpace($script:AXEData)){ return $null }
    Join-Path $script:AXEData 'ui.json'
}

function Test-AXEUIZoom {
    # PURA. Un zoom vale si es un numero real dentro del rango util. Fuera de el la interfaz o no
    # se lee o no cabe, asi que se rechaza en vez de guardarse y estropear el proximo arranque.
    param($Zoom)
    if($null -eq $Zoom){ return $false }
    $d = 0.0
    if($Zoom -is [double] -or $Zoom -is [single] -or $Zoom -is [int] -or $Zoom -is [long] -or $Zoom -is [decimal]){
        $d = [double]$Zoom
    } else {
        # TryParse con la CULTURA DEL SISTEMA es una trampa, y se comio este proyecto en la primera
        # ejecucion: en es-ES (y de-DE, fr-FR...) el punto es separador de MILES, asi que '1.5'
        # parseaba como 15, quedaba fuera de rango y el zoom se rechazaba en silencio. En un Windows
        # en ingles habria pasado inadvertido hasta que lo usara alguien fuera de EEUU.
        #   JSON es invariante por definicion, y el valor viaja por JSON: se parsea invariante.
        if(-not [double]::TryParse([string]$Zoom, [System.Globalization.NumberStyles]::Float,
                                   [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)){ return $false }
    }
    if([double]::IsNaN($d) -or [double]::IsInfinity($d)){ return $false }
    ($d -ge $script:AXEUIZoomMin) -and ($d -le $script:AXEUIZoomMax)
}

function Get-AXEUIZoom {
    # Zoom guardado o 1.0. Ausente, ilegible, corrupto o fuera de rango -> 1.0. NUNCA lanza: un
    # fichero de preferencias roto no puede ser el motivo de que la ventana no abra.
    $p = Get-AXEUIPrefsPath
    if(-not $p -or -not (Test-Path $p)){ return 1.0 }
    try {
        $doc = (Get-Content $p -Raw -Encoding UTF8 -EA Stop) | ConvertFrom-Json -EA Stop
        $z = $doc.zoom
        if(Test-AXEUIZoom $z){ return [double]$z }
    } catch {}
    1.0
}

function Set-AXEUIZoom {
    # Guarda el zoom. Devuelve $true solo si quedo escrito: el llamante no tiene que adivinarlo.
    param($Zoom)
    if(-not (Test-AXEUIZoom $Zoom)){ return $false }
    $p = Get-AXEUIPrefsPath
    if(-not $p){ return $false }
    try {
        $dir = Split-Path $p -Parent
        if($dir -and -not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force -EA Stop | Out-Null }
        Set-Content -Path $p -Value (ConvertTo-Json -InputObject ([pscustomobject]@{ zoom=[double]$Zoom }) -Depth 2) -Encoding UTF8 -EA Stop
        return $true
    } catch { return $false }
}

function Get-AXEWebView2Runtime {
    # El runtime Evergreen registra su version en EdgeUpdate\Clients\{GUID}. Presente por defecto
    # en Win11; en Win10 puede faltar => Available=$false y la carcasa mostrara un mensaje con enlace.
    $paths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach($p in $paths){
        try {
            $v = (Get-ItemProperty -Path $p -Name pv -ErrorAction Stop).pv
            if($v -and $v -ne '0.0.0.0'){ return [pscustomobject]@{ Available=$true; Version=$v; Reason='' } }
        } catch {}
    }
    return [pscustomobject]@{ Available=$false; Version=$null; Reason='Runtime WebView2 Evergreen no encontrado. Instalalo desde https://developer.microsoft.com/microsoft-edge/webview2/' }
}


# >>>>> MODULE: 40-session.ps1 >>>>>
# =====================================================
# REGION 12b - DAEMON DE SESION DE JUEGO (subsistema A) - spec 2026-07-20
# =====================================================
# Congela el fondo mientras juegas y lo descongela al cerrar el juego o AXE. El hueco que
# ninguna suite (hone.gg/Pulse/Atlas/Delta) rellena de verdad: congelan cuatro cosas y timido,
# porque un fallo cuelga el PC y les come el soporte. Aqui la recuperacion la garantiza el
# KERNEL (al cerrar el handle del job, Windows descongela solo), asi que no hay codigo de
# recuperacion que pueda fallar.
#
# Reparto igual que Get-AXEDiagFacts vs Get-AXEDiagFindings: lo PURO (que hacer) es testeable
# sin hardware (Get-AXESessionPlan); lo que toca el kernel (hacerlo) no se testea, se documenta.
# Carga despues de 32-measure, donde vive [AXE.Native] (extendido con los Job* methods).

# --- Familias (deteccion por grupo, no por nombres sueltos). Nivel por defecto: ---
#   voz/anticheat/shell -> INTACTO ; navegador/musica/mensajeria -> DEGRADADO ; resto -> CONGELADO
$script:AXESessionFamilies = @{
    voz        = @('discord','discordptb','discordcanary','teamspeak','teamspeak3','ts3client','mumble','ventrilo')
    anticheat  = @('easyanticheat','easyanticheat_eos','beservice','battleye','bedaisy','vgc','vgtray','vgk','faceitservice','faceit')
    # svchost/conhost/audiodg estan aqui por una razon que el spec de A no vio: Windows aloja los
    # servicios POR-USUARIO (CDPUserSvc, WpnUserService, OneSyncSvc, UnistoreSvc, PimIndexMaintenance
    # ...) en instancias de svchost que corren en la SESION INTERACTIVA, no en la 0. "Session 0 queda
    # fuera por definicion" no los cubre. Congelar uno cuelga a quien le haga un RPC SINCRONO -shell,
    # notificaciones, portapapeles- hasta el timeout. Lo caza el test del puente sobre una maquina real.
    shell      = @('dwm','explorer','csrss','winlogon','wininit','services','lsass','smss','svchost','conhost','audiodg','fontdrvhost','sihost','ctfmon','textinputhost','startmenuexperiencehost','searchhost','searchapp','shellexperiencehost','taskhostw','runtimebroker','dllhost','applicationframehost','systemsettings','lockapp')
    navegador  = @('chrome','brave','msedge','edge','firefox','opera','opera_gx','vivaldi','browser')
    musica     = @('spotify','tidal','deezer','foobar2000','aimp','musicbee')
    mensajeria = @('whatsapp','telegram','signal','slack')
}

function Get-AXESessionProcesses {
    # Impura: lee procesos. NO juzga. Alimenta a Get-AXESessionPlan con hechos planos.
    # Ventana, titulo y memoria viajan para el detector de juego (Get-AXEGameCandidates); el
    # planificador los ignora. Se leen AQUI y no alli para que el detector siga siendo puro.
    #   Nada de esto abre un handle al proceso: Path, MainWindowHandle y WorkingSet64 salen del
    # snapshot que ya trae Get-Process. Es deliberado - abrir handles contra un juego protegido es
    # justo lo que un anti-cheat interpreta mal, y AXE promete por escrito no hacerlo.
    $out = New-Object System.Collections.ArrayList
    foreach($p in (Get-Process -EA SilentlyContinue)){
        $path = $null; try { $path = $p.Path } catch {}
        $hwnd = [IntPtr]::Zero; try { $hwnd = $p.MainWindowHandle } catch {}
        $title = ''; try { $title = [string]$p.MainWindowTitle } catch {}
        $ws = 0.0; try { $ws = [math]::Round($p.WorkingSet64 / 1MB, 0) } catch {}
        [void]$out.Add([pscustomobject]@{
            Pid          = [int]$p.Id
            Name         = [string]$p.ProcessName
            SessionId    = [int]$p.SessionId
            Path         = $path
            HasWindow    = ($hwnd -ne [IntPtr]::Zero)
            Title        = $title
            WorkingSetMB = [double]$ws
        })
    }
    @($out)
}

# --- Smart detect: que proceso es el juego ---------------------------------------------------
# El defecto que arregla: la seccion de sesion pedia ESCRIBIR el nombre del proceso. Quien no sabe
# que Valorant corre como 'VALORANT-Win64-Shipping' no podia usarla, y ese es justo el usuario al
# que sirve congelar el fondo. La funcion existia; la puerta de entrada no.
#
# Como NO se resuelve: con una lista de juegos conocidos. Es lo que hacen las suites de pago y
# envejece sola - cada lanzamiento es una actualizacion, y el juego que no esta en la lista no
# existe para el programa. Un indie de itch.io no entra en esa lista jamas.
#
# Como si: puntuando senales que valen para un juego que salio ayer.
#   - La CARPETA de la tienda es el indicio fuerte y estable. Cambian los juegos, no las rutas:
#     'steamapps\common' lleva ahi desde 2003.
#   - El SUFIJO DEL MOTOR es el segundo. Unreal compila a '<Juego>-Win64-Shipping.exe'; eso
#     identifica al MOTOR, no al titulo, asi que cubre juegos que todavia no existen.
#   - Ventana propia y memoria desempatan.
# Y no se arranca solo: se PROPONE con el motivo a la vista. Congelar el fondo es lo mas agresivo
# que hace AXE; elegir por el usuario sobre que proceso se hace seria pasarse de la raya.

# Fragmentos de ruta (minusculas) -> tienda. Es el indicio de mas peso.
$script:AXEGameStorePaths = [ordered]@{
    'steamapps\common'              = 'Steam'
    'epic games\'                   = 'Epic Games'
    'riot games\'                   = 'Riot Games'
    'gog galaxy\games'              = 'GOG'
    'ubisoft game launcher\games'   = 'Ubisoft'
    'ea games\'                     = 'EA'
    'origin games\'                 = 'EA (Origin)'
    'rockstar games\'               = 'Rockstar'
    'battle.net\games'              = 'Battle.net'
    '\xboxgames\'                   = 'Xbox'
    '\.minecraft'                   = 'Minecraft'
}
# Marcador RECHAZADO a proposito: '\windowsapps\'. Parecia cubrir los juegos de Microsoft Store,
# pero ahi vive TODA app empaquetada MSIX. En la maquina de referencia hacia que Claude Desktop y
# la utilidad NitroSense puntuasen 70 y se colasen por delante de cualquier juego real. Un indicio
# que marca a todo el mundo no es un indicio. Los juegos de Xbox si tienen carpeta propia
# (\XboxGames\) y esa si discrimina, asi que se queda solo esa.

# Lanzaderas y utilidades: NUNCA son "el juego", aunque cumplan el resto de senales (viven en la
# carpeta de la tienda, tienen ventana y comen memoria). Excluirlas evita el falso positivo mas
# probable de todos: proponer Steam como juego porque Steam esta dentro de steamapps.
$script:AXEGameNotGame = @(
    'steam','steamwebhelper','steamservice','epicgameslauncher','epicwebhelper','unrealcefsubprocess'
    'battle.net','battle.net helper','blizzarderror','agent','riotclientservices','riotclientux'
    'riotclientuxrender','riotclientcrashhandler','galaxyclient','galaxyclienthelper','galaxycommunication'
    'upc','uplay','ubisoftconnect','ubisoftgamelauncher','eadesktop','eabackgroundservice','ealauncher'
    'origin','originwebhelperservice','originclientservice','rockstarservice','rockstarerrorhandler'
    'launcher','gamelaunchhelper','xboxapp','xboxpcapp','gamingservices','gameoverlayui','gamebar'
    'gamebarpresencewriter','obs64','obs32','streamlabs obs','streamlabs','xsplit.core'
    'nvcontainer','nvidia share','nvidia web helper','nvidiaoverlay','msiafterburner','rtss'
    'rivatuner','code','devenv','idea64','pycharm64','rider64','pwsh','powershell','cmd'
    'windowsterminal','taskmgr','notepad','notepad++','msiexec','setup','install','unins000'
)

function Test-AXEGameExcluded {
    # PURA. Un proceso que NO puede ser el juego, con el motivo. Devuelve $null si si puede serlo.
    # Se separa del puntuador porque "descartado" y "puntua bajo" son cosas distintas: lo primero
    # no se ensena, lo segundo se ensena al final de la lista.
    param($Proc,[int]$SelfPid)
    if(-not $Proc){ return 'proceso vacio' }
    $name = Get-AXESessionAppName $Proc.Name
    if([int]$Proc.Pid -eq $SelfPid){ return 'es AXE' }
    if([int]$Proc.Pid -le 4){ return 'proceso del sistema' }
    if(Test-AXESessionHardApp $name){ return 'shell o anticheat: AXE nunca lo toca' }
    # Familias conocidas que no son juegos. La voz, el navegador y la musica ya tienen su reparto.
    foreach($fam in 'voz','navegador','musica','mensajeria'){
        if($script:AXESessionFamilies[$fam] -contains $name){ return "es $fam, no un juego" }
    }
    if($script:AXEGameNotGame -contains $name){ return 'es una lanzadera o utilidad, no el juego' }
    # Infraestructura por como SE LLAMA, no por estar en una lista. Cazado en la maquina de
    # referencia: 'epiconlineservicesuserhelper' vive en la carpeta de Epic Games, o sea que se
    # llevaba los 50 puntos de tienda y salia PRIMERO, por delante de cualquier juego real.
    # Ampliar la lista nombre a nombre es perder la carrera: cada tienda trae los suyos y cambian
    # con cada version. La regla no: ningun juego se llama '<algo>service' ni '<algo>helper'.
    #   Se ancla al FINAL del nombre a proposito. Como subcadena suelta, 'agent' descartaria un
    # juego llamado 'Agents of Mayhem' y 'launcher' uno que la lleve en el titulo.
    if($name -match '(service|services|helper|crashhandler|crashreporter|errorreporter|overlay|updater|broker|daemon|launcher|agent|installer)$'){
        return 'es un proceso de servicio o ayudante, no el juego'
    }
    $path = [string]$Proc.Path
    if($path){
        # %WINDIR% queda fuera entero: ahi no se instala ningun juego, y lo que hay dentro es justo
        # lo que no conviene proponerle a nadie como centro de una sesion.
        $win = ([string]$env:SystemRoot).ToLowerInvariant()
        if($win -and $path.ToLowerInvariant().StartsWith($win)){ return 'vive en la carpeta de Windows' }
    }
    $null
}

function Get-AXEGameCandidates {
    # PURA sobre los hechos que recibe (por eso es testeable sin un solo juego instalado). Devuelve
    # los candidatos ORDENADOS por puntuacion, cada uno con sus razones en texto. No decide: propone.
    param(
        [object[]]$Processes,
        [int]$SelfPid,
        [int]$SessionId,
        [int]$Top = 8
    )
    # Cuantos procesos hay con cada nombre en esta sesion. Se cuenta sobre TODOS, no solo sobre los
    # que puntuan: la interfaz dira "x9 procesos" y eso tiene que cuadrar con el Administrador de
    # tareas, no ser un recuento interno de candidatos. De los 9 procesos de una app de Electron
    # solo uno tiene ventana, asi que contar los puntuados habria dicho "x1" teniendo 9 delante.
    $byName = @{}
    foreach($p in @($Processes)){
        if($null -eq $p){ continue }
        if([int]$p.SessionId -ne $SessionId){ continue }
        $k = Get-AXESessionAppName $p.Name
        if($byName.ContainsKey($k)){ $byName[$k]++ } else { $byName[$k] = 1 }
    }

    $out = New-Object System.Collections.ArrayList
    foreach($p in @($Processes)){
        if($null -eq $p){ continue }
        if([int]$p.SessionId -ne $SessionId){ continue }   # solo la sesion interactiva, igual que el plan
        if(Test-AXEGameExcluded -Proc $p -SelfPid $SelfPid){ continue }

        $score   = 0
        $reasons = New-Object System.Collections.ArrayList
        $name    = Get-AXESessionAppName $p.Name
        $path    = [string]$p.Path
        $lp      = $path.ToLowerInvariant()

        # 1. Carpeta de tienda: el indicio de mas peso y el que no envejece.
        $store = $null
        if($lp){
            foreach($frag in $script:AXEGameStorePaths.Keys){
                if($lp.Contains($frag)){ $store = $script:AXEGameStorePaths[$frag]; break }
            }
        }
        if($store){ $score += 50; [void]$reasons.Add("instalado en la carpeta de $store") }

        # 2. Firma del MOTOR, no del titulo: cubre juegos que todavia no existen.
        if($name -match '\-win(64|32|gdk)\-shipping$'){
            $score += 30; [void]$reasons.Add('ejecutable de Unreal Engine (build shipping)')
        } elseif($name -match 'win64|win32'){
            $score += 8;  [void]$reasons.Add('nombre de ejecutable tipico de juego')
        }

        # 3. Ventana propia. Un juego siempre tiene una; un servicio de fondo no.
        if($p.PSObject.Properties['HasWindow'] -and $p.HasWindow){
            $score += 20; [void]$reasons.Add('tiene ventana propia')
        }

        # 4. Memoria. Escalonada y sin llevarse el protagonismo: la RAM sola no prueba nada -un
        #    navegador gasta mas que un indie- pero acompanada de lo de arriba desempata bien.
        $ws = 0.0
        if($p.PSObject.Properties['WorkingSetMB']){ $ws = [double]$p.WorkingSetMB }
        if($ws -ge 1500){ $score += 20; [void]$reasons.Add("usa $([int]$ws) MB de memoria") }
        elseif($ws -ge 600){ $score += 12; [void]$reasons.Add("usa $([int]$ws) MB de memoria") }
        elseif($ws -ge 250){ $score += 6 }

        # Sin una sola senal positiva no se propone: seria ruido, no un candidato.
        if($score -le 0){ continue }

        [void]$out.Add([pscustomobject]@{
            Name    = $name
            Pid     = [int]$p.Pid
            Score   = [int]$score
            Store   = $store
            Title   = $(if($p.PSObject.Properties['Title']){ [string]$p.Title } else { '' })
            Path    = $path
            # "Probable" = tienda, o motor + ventana. Una sola senal debil no basta para que la
            # interfaz lo preseleccione: proponerlo si, elegirlo por el usuario no.
            Likely  = [bool]($score -ge 50)
            Reasons = @($reasons)
        })
    }

    # UNA fila por APP, no por pid. Mismo principio que ya aplica session.preview con Chrome: doce
    # procesos son UNA decision, no doce. Sin esto una app de Electron -que abre un proceso por
    # pestana o por servicio- llenaba la lista entera con su propio nombre repetido y empujaba al
    # juego de verdad fuera del top. Representa al grupo la instancia de MAYOR puntuacion, que es
    # la que tiene la ventana; el numero de procesos viaja para que la interfaz pueda decirlo.
    $best = [ordered]@{}
    foreach($c in $out){
        $k = $c.Name
        if(-not $best.Contains($k) -or $c.Score -gt $best[$k].Score){ $best[$k] = $c }
    }
    foreach($k in @($best.Keys)){
        $best[$k] | Add-Member -NotePropertyName Instances -NotePropertyValue ([int]$byName[$k]) -Force
    }
    # Empate por puntuacion -> orden estable por nombre, para que dos lecturas seguidas no bailen.
    @(@($best.Values) | Sort-Object -Property @{Expression='Score';Descending=$true},@{Expression='Name';Descending=$false} |
        Select-Object -First ([math]::Max(1,$Top)))
}

function Get-AXESessionLevel {
    # PURA. Un proceso -> 'intacto'|'degradado'|'congelado' dado el contexto. Orden a posta:
    # los DUROS (juego, AXE, shell, anticheat) ganan a la config del usuario; nunca se tocan.
    param($Proc,[int]$GamePid,[int]$SelfPid,[hashtable]$Config)
    $name = (([string]$Proc.Name).ToLowerInvariant()) -replace '\.exe$',''
    # 1. Duros: intocables incluso con config.
    if([int]$Proc.Pid -eq $GamePid){ return 'intacto' }
    if([int]$Proc.Pid -eq $SelfPid){ return 'intacto' }
    $fam = $script:AXESessionFamilies
    if(($fam.shell -contains $name) -or ($fam.anticheat -contains $name)){ return 'intacto' }
    if($name -match 'anticheat|battleye|easyanti'){ return 'intacto' }   # variantes con sufijos raros
    # 2. Config del usuario sobreescribe el default por app (solo apps NO duras).
    if($Config -and $Config.ContainsKey($name)){
        $lvl = ([string]$Config[$name]).ToLowerInvariant()
        if($lvl -in 'intacto','degradado','congelado'){ return $lvl }
    }
    # 3. Familias por defecto.
    if($fam.voz -contains $name){ return 'intacto' }   # la voz es sensible a latencia: degradarla se oye
    if(($fam.navegador -contains $name) -or ($fam.musica -contains $name) -or ($fam.mensajeria -contains $name)){ return 'degradado' }
    # 4. Desconocido de la sesion del usuario -> congelado.
    return 'congelado'
}

function Get-AXESessionPlan {
    # PURA. Hechos + config -> los tres grupos. El nucleo testeable (tests/Session.Tests.ps1).
    # Frontera: Session 0 (servicios/drivers/audiodg/lsass) queda fuera POR DEFINICION - lo aisla
    # ya el SO. Solo se considera la sesion interactiva actual.
    param(
        [object[]]$Processes,
        [int]$GamePid,
        [string]$GameName,
        [int]$SelfPid,
        [int]$SessionId,
        [hashtable]$Config = @{}
    )
    # SessionId <= 0 o sin procesos -> plan vacio, sin reventar (caso testeado).
    if($SessionId -le 0){ return [pscustomobject]@{ Intacto=@(); Degradado=@(); Congelado=@() } }
    $intacto   = New-Object System.Collections.ArrayList
    $degradado = New-Object System.Collections.ArrayList
    $congelado = New-Object System.Collections.ArrayList
    foreach($p in @($Processes)){
        if($null -eq $p){ continue }
        if([int]$p.SessionId -eq 0){ continue }             # Session 0 nunca (defensivo)
        if([int]$p.SessionId -ne $SessionId){ continue }    # fuera de la sesion interactiva
        switch(Get-AXESessionLevel -Proc $p -GamePid $GamePid -SelfPid $SelfPid -Config $Config){
            'intacto'   { [void]$intacto.Add($p) }
            'degradado' { [void]$degradado.Add($p) }
            default     { [void]$congelado.Add($p) }
        }
    }
    [pscustomobject]@{ Intacto=@($intacto); Degradado=@($degradado); Congelado=@($congelado) }
}

# --- Reparto configurable por app: persistencia (spec 2026-07-25) ---------------------------
# El planificador ya aceptaba -Config y estaba testeado con overrides; lo que faltaba era el par
# leer/escribir y quien lo edite (la seccion de la WebUI). Fichero PROPIO, no dentro de
# game_profiles.json: ese es un ARRAY de perfiles de plan de energia que recorre Tick-GameProfiles;
# meter un mapa app->nivel en el mismo array mezcla dos esquemas sin relacion, obliga a filtrar a
# todos sus consumidores y arriesga el monitor que si toca el plan de energia en vivo.
$script:AXESessionLevels = @('intacto','degradado','congelado')

function Write-AXESessionLog {
    # 40-session se dot-sourcea SUELTO en tests (sin 05-core, donde vive Write-AXELog): loguear es
    # best-effort, nunca un error que tumbe una sesion.
    param([string]$Message,[string]$Level='INFO')
    if(Get-Command Write-AXELog -EA SilentlyContinue){ Write-AXELog $Message $Level }
}

function Get-AXESessionAppName {
    # PURA. Normaliza a la clave con la que trabajan familias y overrides: minusculas, sin .exe.
    param([string]$Name)
    (([string]$Name).Trim().ToLowerInvariant()) -replace '\.exe$',''
}

function Get-AXESessionLevelsPath {
    # Sin $script:AXEData (motor cargado suelto) devuelve $null: el llamante degrada, no inventa ruta.
    if([string]::IsNullOrWhiteSpace($script:AXEData)){ return $null }
    Join-Path $script:AXEData 'session_levels.json'
}

function Get-AXESessionFamily {
    # PURA. Nombre -> familia ('navegador','voz','musica'...) o $null si no esta en ninguna. No adivina.
    param([string]$Name)
    $n = Get-AXESessionAppName $Name
    foreach($fam in @($script:AXESessionFamilies.Keys)){
        if($script:AXESessionFamilies[$fam] -contains $n){ return [string]$fam }
    }
    $null
}

function Test-AXESessionHardApp {
    # PURA. Duro = shell o anticheat. El planificador los deja INTACTOS ganando a la config, asi que
    # un override sobre ellos no haria NADA: se rechaza al escribir en vez de ignorarlo en silencio.
    param([string]$Name)
    $n = Get-AXESessionAppName $Name
    $fam = $script:AXESessionFamilies
    [bool](($fam.shell -contains $n) -or ($fam.anticheat -contains $n) -or ($n -match 'anticheat|battleye|easyanti'))
}

function Read-AXESessionOverrides {
    # Overrides por-app {nombre->nivel} desde disco. Tolerante como Read-Profiles: ausente, corrupto
    # o con entradas invalidas -> se descarta lo que no vale y NUNCA lanza. Un fichero corrupto no se
    # borra: se deja para inspeccion (el usuario puede haberlo editado a mano).
    $out = @{}
    $path = Get-AXESessionLevelsPath
    if(-not $path -or -not (Test-Path $path)){ return $out }
    $raw = $null
    try { $raw = Get-Content $path -Raw -Encoding UTF8 -EA Stop } catch { return $out }
    if([string]::IsNullOrWhiteSpace($raw)){ return $out }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -EA Stop } catch {
        Write-AXESessionLog 'Sesion: session_levels.json ilegible; se usan los niveles por defecto.' 'WARN'
        return $out
    }
    foreach($p in @($obj.PSObject.Properties)){
        $name = Get-AXESessionAppName $p.Name
        if([string]::IsNullOrWhiteSpace($name)){ continue }
        $lvl = ([string]$p.Value).Trim().ToLowerInvariant()
        if($script:AXESessionLevels -notcontains $lvl){ continue }   # nivel inventado: se descarta
        $out[$name] = $lvl
    }
    $out
}

function Set-AXESessionOverride {
    # Escribe o borra UN override. -Level 'default' borra (vuelve al reparto por familias).
    # Devuelve {Ok,Reason,Overrides}; nunca lanza.
    param([string]$Name,[string]$Level)
    $n = Get-AXESessionAppName $Name
    if([string]::IsNullOrWhiteSpace($n)){
        return [pscustomobject]@{ Ok=$false; Reason='falta el nombre de la app.'; Overrides=(Read-AXESessionOverrides) }
    }
    $lvl = ([string]$Level).Trim().ToLowerInvariant()
    if($lvl -ne 'default' -and $script:AXESessionLevels -notcontains $lvl){
        return [pscustomobject]@{ Ok=$false; Overrides=(Read-AXESessionOverrides)
            Reason=("nivel '{0}' invalido: usa {1} o default." -f $Level,($script:AXESessionLevels -join '/')) }
    }
    if(Test-AXESessionHardApp $n){
        return [pscustomobject]@{ Ok=$false; Overrides=(Read-AXESessionOverrides)
            Reason=("'{0}' es shell o anticheat: AXE nunca lo toca, asi que su nivel no es configurable." -f $n) }
    }
    $path = Get-AXESessionLevelsPath
    if(-not $path){
        return [pscustomobject]@{ Ok=$false; Reason='sin carpeta de datos de AXE: no puedo guardar el nivel.'; Overrides=@{} }
    }
    $map = Read-AXESessionOverrides
    if($lvl -eq 'default'){ [void]$map.Remove($n) } else { $map[$n] = $lvl }
    try {
        $dir = Split-Path $path -Parent
        if($dir -and -not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force -EA Stop | Out-Null }
        # '{}' explicito cuando queda vacio: ConvertTo-Json de un hashtable vacio no emite nada y
        # Set-Content dejaria el fichero anterior intacto (misma trampa que documenta Save-Profiles).
        $json = if($map.Count -eq 0){ '{}' } else { ConvertTo-Json -InputObject $map -Depth 3 }
        Set-Content -Path $path -Value $json -Encoding UTF8 -EA Stop
    } catch {
        return [pscustomobject]@{ Ok=$false; Reason=("no pude guardar el nivel: {0}" -f $_.Exception.Message); Overrides=(Read-AXESessionOverrides) }
    }
    Write-AXESessionLog ("Sesion: nivel de '{0}' -> {1}." -f $n,$lvl)
    [pscustomobject]@{ Ok=$true; Reason=$null; Overrides=$map }
}

# --- Red para la salida SUCIA: prioridades degradadas (auditoria 2026-07-25) -----------------
# El diseño apoya TODA la recuperacion en el kernel: al cerrarse el handle del job, Windows
# descongela. Es cierto para lo CONGELADO y FALSO para lo DEGRADADO: bajar la prioridad no es un
# estado del job, es una propiedad del proceso, y ahi el kernel no ayuda. Si AXE muere -o si
# simplemente cierras la ventana- nadie la devuelve, y el navegador se queda en BelowNormal hasta
# que lo reinicies: exactamente el "dejar la maquina a medias" que el spec prohibe.
#   Dos redes: el cierre limpio llama a Stop (47-webhost), y para el kill/BSOD queda este diario en
# disco, que se restaura en el siguiente arranque.
function Get-AXESessionJournalPath {
    if([string]::IsNullOrWhiteSpace($script:AXEData)){ return $null }
    Join-Path $script:AXEData 'session_degraded.json'
}

function Test-AXESessionSameProcess {
    # Impura (lee el proceso). Los pid SE REUSAN: restaurar una prioridad por pid a secas puede
    # tocar un proceso ajeno que heredo el numero. Nombre + instante de arranque cierra el hueco.
    # Ante cualquier duda devuelve $false: no tocar es siempre mejor que tocar lo que no es.
    param([int]$ProcessId,[string]$Name,[long]$StartTicks)
    if($ProcessId -le 0){ return $false }
    $p = Get-Process -Id $ProcessId -EA SilentlyContinue
    if(-not $p){ return $false }
    if((Get-AXESessionAppName $p.ProcessName) -ne (Get-AXESessionAppName $Name)){ return $false }
    if($StartTicks -gt 0){
        $t = 0
        try { $t = [long]$p.StartTime.Ticks } catch { return $false }
        if($t -ne $StartTicks){ return $false }
    }
    $true
}

function Clear-AXESessionJournal {
    $path = Get-AXESessionJournalPath
    if($path -and (Test-Path $path)){ Remove-Item $path -Force -EA SilentlyContinue }
}

function Write-AXESessionJournal {
    # Deja constancia de lo degradado ANTES de que pueda hacer falta. Best-effort: si no se puede
    # escribir, la sesion sigue (el diario es una red, no un requisito).
    param($Degraded)
    $path = Get-AXESessionJournalPath
    if(-not $path){ return }
    try {
        $rows = @(@($Degraded) | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ pid=[int]$_.Pid; name=[string]$_.Name; prev=[string]$_.Prev; startTicks=[long]$_.StartTicks }
        })
        if($rows.Count -eq 0){ Clear-AXESessionJournal; return }
        # El diario lleva DUEÑO: si hay dos AXE abiertos, el que arranca segundo no puede reparar el
        # de una sesion que sigue viva. Sin esto le devolveria la prioridad a media partida y, peor,
        # borraria el diario: si la primera instancia muriera sucia ya no habria red que la cubriese.
        $me = $null; try { $me = Get-Process -Id $PID -EA Stop } catch {}
        $ownerTicks = 0; if($me){ try { $ownerTicks = [long]$me.StartTime.Ticks } catch {} }
        $doc = [pscustomobject]@{
            owner    = [pscustomobject]@{ pid=[int]$PID; name=$(if($me){ [string]$me.ProcessName } else { '' }); startTicks=$ownerTicks }
            degraded = $rows
        }
        Set-Content -Path $path -Value (ConvertTo-Json -InputObject $doc -Depth 4) -Encoding UTF8 -EA Stop
    } catch { Write-AXESessionLog ("Sesion: no pude escribir el diario de prioridades: {0}" -f $_.Exception.Message) 'WARN' }
}

function Restore-AXESessionDegraded {
    # Se llama al arrancar. Devuelve cuantas prioridades se restauraron (0 si no habia diario).
    # Nunca lanza: un diario ilegible se descarta y se sigue.
    $path = Get-AXESessionJournalPath
    if(-not $path -or -not (Test-Path $path)){ return 0 }
    $doc = $null
    try { $doc = (Get-Content $path -Raw -Encoding UTF8 -EA Stop) | ConvertFrom-Json -EA Stop } catch {
        Write-AXESessionLog 'Sesion: diario de prioridades ilegible; se descarta.' 'WARN'
        Clear-AXESessionJournal
        return 0
    }
    # Dueño vivo y distinto de mi => otra instancia de AXE tiene la sesion abierta. Ni restaurar ni
    # borrar: ese diario sigue siendo SU red.
    $owner = $doc.owner
    if($owner -and ([int]$owner.pid -ne $PID) -and
       (Test-AXESessionSameProcess -ProcessId ([int]$owner.pid) -Name ([string]$owner.name) -StartTicks ([long]$owner.startTicks))){
        Write-AXESessionLog 'Sesion: el diario de prioridades es de otra instancia de AXE que sigue viva; no se toca.' 'WARN'
        return 0
    }
    $rows = @($doc.degraded)
    $n = 0
    foreach($r in $rows){
        if(-not $r){ continue }
        if(-not (Test-AXESessionSameProcess -ProcessId ([int]$r.pid) -Name ([string]$r.name) -StartTicks ([long]$r.startTicks))){ continue }
        try { (Get-Process -Id ([int]$r.pid) -EA Stop).PriorityClass = [string]$r.prev; $n++ } catch {}
    }
    Clear-AXESessionJournal
    if($n -gt 0){ Write-AXESessionLog ("Sesion: restauradas {0} prioridad(es) de una sesion anterior que no cerro limpiamente." -f $n) }
    $n
}

function Start-AXESession {
    # Impura. Sonda freeze -> crea job -> asigna congelados -> congela -> degrada. Devuelve el
    # objeto de sesion. PRINCIPIO: cualquier fallo ANTES de congelar -> abortar sin tocar nada.
    param([string]$GameName)
    if([string]::IsNullOrWhiteSpace($GameName)){ return [pscustomobject]@{ Ok=$false; Reason='falta el nombre del juego.' } }
    $gproc = Get-Process -Name ($GameName -replace '\.exe$','') -EA SilentlyContinue | Select-Object -First 1
    if(-not $gproc){ return [pscustomobject]@{ Ok=$false; Reason="el juego '$GameName' no esta corriendo. Abrelo y reintenta." } }

    if(-not ('AXE.Native' -as [type]) -or -not [AXE.Native].GetMethod('JobProbeFreeze')){
        return [pscustomobject]@{ Ok=$false; Reason='capa nativa de sesion ausente (reinicia AXE tras rebuild).' }
    }
    # Sonda: si JobObjectFreezeInformation no existe en este Windows -> abortar limpio, sin fallback.
    $probe = [AXE.Native]::JobProbeFreeze()
    if($probe -ne 0){
        return [pscustomobject]@{ Ok=$false; Reason=("JobObjectFreezeInformation no disponible aqui (status 0x{0:X8}): sesion abortada sin tocar nada." -f $probe) }
    }

    $sid   = [int]$gproc.SessionId
    $facts = Get-AXESessionProcesses
    $plan  = Get-AXESessionPlan -Processes $facts -GamePid ([int]$gproc.Id) -GameName $GameName -SelfPid $PID -SessionId $sid -Config (Read-AXESessionOverrides)

    $hJob = [AXE.Native]::JobCreate()
    if($hJob -eq [IntPtr]::Zero){ return [pscustomobject]@{ Ok=$false; Reason='CreateJobObject fallo; nada congelado.' } }

    # Asignar congelados. Un pid protegido que falle NO tumba la sesion: se cuenta y se sigue.
    $assigned = 0; $failed = 0
    foreach($p in @($plan.Congelado)){
        $rc = [AXE.Native]::JobAssignPid($hJob, [int]$p.Pid)
        if($rc -eq 0){ $assigned++ } else { $failed++ }
    }
    # Congelar el job entero de una vez.
    $fr = [AXE.Native]::JobFreeze($hJob)
    if($fr -ne 0){
        [void][AXE.Native]::JobClose($hJob)   # cerrar => el kernel descongela lo asignado
        return [pscustomobject]@{ Ok=$false; Reason=("freeze fallo (status 0x{0:X8}) tras asignar; job cerrado, nada quedo congelado." -f $fr) }
    }

    # Degradar (best-effort, no critico): prioridad baja pero VIVO y usable. Pinning a nucleos
    # fuera del juego es el subsistema B, no este. Guardamos la prioridad previa para restaurar.
    $degraded = New-Object System.Collections.ArrayList
    foreach($p in @($plan.Degradado)){
        try {
            $pr = Get-Process -Id ([int]$p.Pid) -EA Stop
            $prev = $pr.PriorityClass
            # Nombre + arranque junto al pid: es lo que permite comprobar mas tarde que el pid sigue
            # siendo ESTE proceso y no otro que heredo el numero.
            $startTicks = 0
            try { $startTicks = [long]$pr.StartTime.Ticks } catch {}
            $pr.PriorityClass = 'BelowNormal'
            [void]$degraded.Add([pscustomobject]@{ Pid=[int]$p.Pid; Name=[string]$pr.ProcessName; Prev=[string]$prev; StartTicks=$startTicks })
        } catch {}
    }
    # Diario en disco ANTES de devolver: si AXE muere a partir de aqui, el kernel descongela pero la
    # prioridad la devuelve el proximo arranque leyendo esto.
    Write-AXESessionJournal $degraded

    [pscustomobject]@{
        Ok=$true; Handle=$hJob; Game=$GameName; GamePid=[int]$gproc.Id; SessionId=$sid
        Plan=$plan; Assigned=$assigned; Failed=$failed; Degraded=@($degraded); Started=(Get-Date)
    }
}

function Stop-AXESession {
    # Impura. Cierra el handle (kernel descongela) y restaura las prioridades degradadas.
    param($Session)
    if(-not $Session -or -not $Session.Ok){ return }
    foreach($d in @($Session.Degraded)){
        # Verificar identidad antes de escribir: si el proceso murio y otro heredo su pid, subirle la
        # prioridad "de vuelta" seria tocar a un tercero por error.
        if(-not (Test-AXESessionSameProcess -ProcessId ([int]$d.Pid) -Name ([string]$d.Name) -StartTicks ([long]$d.StartTicks))){ continue }
        try { (Get-Process -Id ([int]$d.Pid) -EA Stop).PriorityClass = $d.Prev } catch {}
    }
    Clear-AXESessionJournal   # cerrado en orden: el diario ya no hace falta
    try { [void][AXE.Native]::JobClose($Session.Handle) } catch {}
}

function Watch-AXESession {
    # Impura. Bloquea hasta que el proceso del juego muere (salida automatica). El llamante
    # (CLI) envuelve en try/finally -> Stop. Si AXE muere aqui, el kernel descongela igual.
    param($Session,[int]$PollMs=1000)
    if(-not $Session -or -not $Session.Ok){ return }
    if($PollMs -lt 100){ $PollMs = 100 }
    while(Get-Process -Id ([int]$Session.GamePid) -EA SilentlyContinue){
        Start-Sleep -Milliseconds $PollMs
    }
}

# --- Ciclo de vida no bloqueante para la ventana (spec 2026-07-25) ---------------------------
# La CLI usa Watch-AXESession (bloqueante). La ventana NO puede: colgaria el hilo que atiende el
# puente. El ciclo vive aqui porque es logica de negocio y 48-webbridge no lleva logica; el
# frontend lo mueve sondeando session.status cada 2 s. UNA sesion por proceso AXE (invariante del
# spec A): dos handles romperian lo unico que hace segura la recuperacion, que cerrar EL handle
# descongele TODO.
$script:AXESessionCur   = $null   # sesion viva, o $null
$script:AXESessionEnded = $null   # motivo del ultimo cierre, para que la UI diga por que se apago

function Get-AXESessionCurrent { $script:AXESessionCur }

function Start-AXESessionTracked {
    # Idempotente a proposito: con sesion viva devuelve LA MISMA, no crea un segundo job. La UI no
    # ofrece ON mientras hay sesion, asi que este camino es una red defensiva; se loguea.
    param([string]$GameName)
    if($script:AXESessionCur){
        Write-AXESessionLog 'Sesion: ON ignorado, ya habia una sesion activa (un proceso, un dueno, un handle).' 'WARN'
        return $script:AXESessionCur
    }
    $s = Start-AXESession -GameName $GameName
    if($s -and $s.Ok){
        $script:AXESessionCur = $s; $script:AXESessionEnded = $null
        Write-AXESessionLog ("Sesion ON - juego '{0}' (pid {1}): {2} congelados, {3} fallidos, {4} degradados." -f `
            $s.Game,$s.GamePid,$s.Assigned,$s.Failed,@($s.Degraded).Count)
    }
    $s
}

function Stop-AXESessionTracked {
    # Cierra el handle (el kernel descongela) y restaura prioridades. Guarda el motivo para la UI.
    param([string]$Reason='OFF manual.')
    if(-not $script:AXESessionCur){ return $null }
    $s = $script:AXESessionCur
    Stop-AXESession $s
    $script:AXESessionCur   = $null
    $script:AXESessionEnded = [string]$Reason
    Write-AXESessionLog ("Sesion OFF - {0} Fondo descongelado y prioridades restauradas." -f $Reason)
    $s
}

function Sync-AXESessionTracked {
    # Salida automatica: si el proceso del juego murio, la sesion se cierra AQUI. Lo llama
    # session.status en cada sondeo. Si AXE muere antes de sondear, el kernel descongela igual: lo
    # que se pierde con la ventana cerrada no es la recuperacion, es el aviso.
    if(-not $script:AXESessionCur){ return $null }
    if(-not (Get-Process -Id ([int]$script:AXESessionCur.GamePid) -EA SilentlyContinue)){
        [void](Stop-AXESessionTracked -Reason ("el juego '{0}' se cerro." -f $script:AXESessionCur.Game))
        return $null
    }
    $script:AXESessionCur
}

function Get-AXESessionStatus {
    # PURA sobre su argumento: NO lee la sesion viva (la resuelve el llamante), por eso es testeable
    # headless igual que Get-AXESessionPlan. DTO plano y JSON-seguro, con las mismas lineas que ve la
    # CLI: la honestidad del texto vive en Format-AXESession, no duplicada aqui.
    param($Session,[string]$EndedReason)
    $ended = $(if([string]::IsNullOrWhiteSpace($EndedReason)){ $null } else { [string]$EndedReason })
    $lines = @(Format-AXESession $Session)
    if(-not $Session -or -not $Session.Ok){
        return [pscustomobject]@{
            active=$false; game=$null; gamePid=$null; sessionId=$null
            frozen=0; failed=0; degraded=0; intact=0; elapsedS=$null; startedAt=$null
            reason=$(if($Session){ [string]$Session.Reason } else { $null })
            endedReason=$ended; lines=$lines
        }
    }
    $elapsed = $null
    if($Session.Started){ $elapsed = [int][math]::Max(0, ((Get-Date) - [datetime]$Session.Started).TotalSeconds) }
    [pscustomobject]@{
        active    = $true
        game      = [string]$Session.Game
        gamePid   = [int]$Session.GamePid
        sessionId = [int]$Session.SessionId
        frozen    = [int]$Session.Assigned
        failed    = [int]$Session.Failed
        degraded  = @($Session.Degraded).Count
        intact    = @($Session.Plan.Intacto).Count
        elapsedS  = $elapsed
        startedAt = $(if($Session.Started){ ([datetime]$Session.Started).ToString('HH:mm:ss') } else { $null })
        reason    = $null
        endedReason = $ended
        lines     = $lines
    }
}

function Format-AXESession {
    # PURA. Render compartido CLI/GUI.
    param($Session)
    if(-not $Session){ return @('sin sesion.') }
    if(-not $Session.Ok){ return @("Sesion NO iniciada: $($Session.Reason)") }
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add("Sesion AXE activa - juego: $($Session.Game) (pid $($Session.GamePid), sesion $($Session.SessionId))")
    [void]$L.Add("  Congelados : $($Session.Assigned)  (fallidos: $($Session.Failed))")
    [void]$L.Add("  Degradados : $(@($Session.Degraded).Count)")
    [void]$L.Add("  Intactos   : $(@($Session.Plan.Intacto).Count)")
    [void]$L.Add('  El fondo se descongela al cerrar el juego, al pulsar OFF o si AXE muere (lo garantiza el kernel).')
    @($L)
}


# >>>>> MODULE: 41-bench.ps1 >>>>>
# =====================================================
# REGION 8e - BENCHMARK "Pruebalo en tu PC" (subproyecto C) - spec 2026-07-24
# =====================================================
# Prueba MEDIBLE y compartible del efecto real de AXE en la maquina del usuario. El
# diferenciador frente a hone.gg / atlaspro / deltapro: ellos ensenan un "score" fabricado;
# aqui sale el delta real CON su intervalo de ruido, y cuando el cambio no supera ese ruido
# el veredicto es 'ruido', no "mejora".
#
# Dos fases con humano en medio (spec §3), a posta:
#   AXE -Benchmark              -> mide, guarda AXE/bench/<id>.json, dice como seguir
#   [ el usuario aplica lo que quiera y REINICIA - fuera del alcance del script ]
#   AXE -Benchmark -After <id>  -> mide, compara, veredicto por metrica, reporte
# NO hay auto-resume por RunOnce: esconderia lo que se aplico y es fragil (elevacion, timing,
# anti-cheat). Misma politica que -FpsCompare, que tampoco automatiza la pausa humana.
#
# Reparto igual que el resto del motor: lo PURO (agregacion y veredicto) se testea sin
# hardware; lo que mide reusa 32-measure.ps1 sin duplicar logica. Carga despues de 40-session
# y antes de 45-cli, que es quien despacha -Benchmark.

# Store de baselines. Deriva de $script:AXEData (05-core) para que dist/ y src/ tengan cada
# uno el suyo. Fallback a TEMP para cuando el modulo se dot-sourcea suelto (Pester unitario);
# los tests lo sobreescriben con un directorio temporal, igual que S12 con $script:ProfilesBak.
$script:AXEBenchDir = Join-Path $(if($script:AXEData){ $script:AXEData } else { Join-Path ([IO.Path]::GetTempPath()) 'AXE' }) 'bench'

# Catalogo de metricas del benchmark. UNA sola fuente para la direccion "buena": si el
# veredicto y el reporte tuvieran cada uno la suya, un dia dirian cosas distintas del mismo
# numero (que es exactamente lo que Format-AXETimerSweep evita viviendo en el motor).
#   DPC no esta: no hay API userland honesta para medirlo, y el P99.9 de jitter es el proxy.
#   Asi se etiqueta en el reporte, misma postura que el resto del motor.
$script:AXEBenchMetrics = @(
    [pscustomobject]@{ Key='jitterP999Ms'; Label='Jitter P99.9'; Unit='ms'; Digits=3; Better='down'
                       Note='proxy de latencia; no atribuible a un driver concreto' }
    [pscustomobject]@{ Key='jitterMeanMs'; Label='Jitter medio'; Unit='ms'; Digits=4; Better='down'
                       Note='' }
    [pscustomobject]@{ Key='timerMs';      Label='Timer';        Unit='ms'; Digits=3; Better='down'
                       Note='en build 19041+ es ambiental: lo fija la app en primer plano, no la config' }
    [pscustomobject]@{ Key='score';        Label='AXE Score';    Unit='';   Digits=1; Better='up'
                       Note='0-100, compuesto por el motor' }
)

function Format-AXEBenchNum {
    # Invariante A POSTA. Con la cultura del sistema el mismo dato sale '0,420' en es-ES y
    # '0.420' en en-US: el Markdown "compartible" dejaria de ser comparable entre usuarios y
    # de parsearse igual. Mismo motivo por el que Measure-AXETimerSweep no castea [double] el
    # nombre de un Group-Object. n/a nunca es 0: si no se pudo medir, se dice.
    param($v,[int]$Digits=3)
    if($null -eq $v){ return 'n/a' }
    [string]::Format([cultureinfo]::InvariantCulture, ('{0:F' + $Digits + '}'), [double]$v)
}

function Format-AXEBenchTs {
    # Normaliza una marca de tiempo a ISO-8601 UTC, venga como sea.
    #   POR QUE EXISTE: ConvertFrom-Json convierte una cadena ISO en [datetime], asi que el
    # 'antes' recuperado del disco y el 'despues' recien medido llegan con TIPOS distintos.
    # Medido en la primera ejecucion real: el mismo reporte imprimia
    #   Antes   : 24/07/2026 13:36:23        <- [datetime] renderizado con la cultura local
    #   Despues : 2026-07-24T13:37:07.0054975Z
    # o sea dos formatos para el mismo campo, y un .md "compartible" con el formato de fecha
    # de cada pais. Un reporte que se comparte no puede depender de la configuracion regional.
    param($ts)
    if($null -eq $ts){ return 'n/a' }
    if($ts -is [datetime]){ return $ts.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture) }
    $d = [datetime]::MinValue
    if([datetime]::TryParse([string]$ts,[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind,[ref]$d)){
        return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture)
    }
    [string]$ts
}

function Get-AXEBenchPercentile {
    # Percentil con interpolacion lineal sobre la serie YA ORDENADA. Pura.
    param([object[]]$Sorted,[double]$P)
    $n = @($Sorted).Count
    if($n -eq 0){ return $null }
    if($n -eq 1){ return [double]$Sorted[0] }
    $idx = $P * ($n - 1)
    $lo  = [int][math]::Floor($idx)
    $hi  = [int][math]::Ceiling($idx)
    if($lo -eq $hi){ return [double]$Sorted[$lo] }
    $f = $idx - $lo
    [double]$Sorted[$lo] + $f * ([double]$Sorted[$hi] - [double]$Sorted[$lo])
}

function Get-AXEBenchStat {
    # Mediana + IQR de una serie de pasadas. PURA.
    #   Mediana y no media: una sola pasada con un stall del scheduler desplaza la media y no
    #   la mediana, y en un benchmark de latencia esos stalls existen siempre.
    #   IQR (cuartil3 - cuartil1) = ancho del 50% central = el RUIDO MEDIDO de esta maquina.
    #   Es lo que despues tiene que superar un delta para llamarse mejora. El ruido se MIDE,
    #   no se asume: la leccion del timer-flakiness (2026-07-19) es justo esa.
    param([object[]]$Values)
    $v = @(foreach($x in $Values){ if($null -ne $x){ [double]$x } })
    if($v.Count -eq 0){ return $null }
    $s = @($v | Sort-Object)
    [pscustomobject]@{
        median = [math]::Round((Get-AXEBenchPercentile -Sorted $s -P 0.50),4)
        iqr    = [math]::Round(((Get-AXEBenchPercentile -Sorted $s -P 0.75) - (Get-AXEBenchPercentile -Sorted $s -P 0.25)),4)
        passes = $v.Count
    }
}

function Get-AXEBenchHwHash {
    # PURA. Hash de identidad = para NEGARSE a comparar dos maquinas (o dos builds) distintas,
    # no para identificar a nadie: entra solo modelo generico de CPU, RAM, vendor de GPU,
    # build de Windows y version de AXE. Ni serial, ni usuario, ni MAC, ni IP.
    #   El formateo va en cultura invariante: si no, la misma maquina daria un hash en es-ES
    # ('31,9') y otro en en-US ('31.9') y toda comparacion abortaria por "otra maquina".
    param([string]$Cpu,[double]$RamGB,[string]$GpuVendor,[int]$Build,[string]$Version)
    $s = [string]::Format([cultureinfo]::InvariantCulture,'{0}|{1:F1}|{2}|{3}|{4}',$Cpu,$RamGB,$GpuVendor,$Build,$Version)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($s))
        'sha256:' + (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
}

function Get-AXEBenchIdentity {
    # Impura (lee hardware). Devuelve {axeVersion;hw;hwHash}. Todo campo que no se pueda leer
    # viaja con un valor generico explicito, nunca inventado: el hash solo tiene que ser
    # ESTABLE en la misma maquina, no unico en el mundo.
    $hw = $script:HW
    if(-not $hw){ try { $hw = Get-AXEHardware } catch { $hw = $null } }

    $vendor = 'desconocido'
    try {
        $vs = New-Object System.Collections.ArrayList
        foreach($n in @(Get-AXEGpuList | ForEach-Object Name)){
            $v = switch -Regex ($n) {
                'NVIDIA|GeForce|Quadro' { 'NVIDIA'; break }
                'AMD|Radeon|ATI'        { 'AMD';    break }
                'Intel'                 { 'Intel';  break }
                default                 { $null }
            }
            if($v -and $vs -notcontains $v){ [void]$vs.Add($v) }
        }
        if($vs.Count -gt 0){ $vendor = (($vs | Sort-Object) -join '+') }
    } catch {
        # Sin Get-AXEGpuList (modulo suelto) o sin CIM: se cae al unico dato de GPU que trae el
        # snapshot de hardware. No se inventa un vendor.
        if($hw -and $hw.HasNvidia){ $vendor = 'NVIDIA' }
    }

    $cpu = if($hw -and $hw.CpuName){ [string]$hw.CpuName } else { 'desconocida' }
    $ram = if($hw -and $hw.RamGB){ [double]$hw.RamGB } else { 0.0 }
    $build = 0; if($hw -and $hw.BuildNumber){ $build = [int]$hw.BuildNumber }
    if($build -eq 0){ try { $build = [int][Environment]::OSVersion.Version.Build } catch {} }
    $ver = if($script:AXEVersion){ [string]$script:AXEVersion } else { 'desconocida' }

    [pscustomobject]@{
        axeVersion = $ver
        hw         = [pscustomobject]@{ cpu=$cpu; ramGB=$ram; gpuVendor=$vendor; build=$build }
        hwHash     = (Get-AXEBenchHwHash -Cpu $cpu -RamGB $ram -GpuVendor $vendor -Build $build -Version $ver)
    }
}

function Measure-AXEBenchSample {
    # Corre $Passes muestras de las metricas de SISTEMA (headless, sin juego) y devuelve por
    # metrica {median;iqr;passes}, NO una sola muestra: sin dispersion no hay forma honesta de
    # decir si un delta posterior es real. Reusa Get-AXESnapshot/Get-AXEScore (32-measure): la
    # medicion vive en un sitio, aqui solo se repite y se agrega.
    #   Metrica que no se pudo medir (p.ej. [AXE.Native] ausente) viaja $null, no 0. Un 0 en
    # jitter seria la mejor cifra posible: exactamente la mentira que este subproyecto ataca.
    # No muta nada del sistema => seguro en SelfTest/CI, sin admin y sin punto de restauracion.
    param([int]$Passes=7,[int]$JitterMs=250)
    if($Passes -lt 1){ $Passes = 1 }
    if($JitterMs -lt 20){ $JitterMs = 20 }

    $p999=@(); $jmean=@(); $timer=@(); $score=@()
    for($i=0; $i -lt $Passes; $i++){
        $snap = Get-AXESnapshot -JitterMs $JitterMs
        if($snap.Jitter -isnot [string]){
            $p999  += [double]$snap.Jitter.P999Ms
            $jmean += [double]$snap.Jitter.MeanMs
        }
        if($snap.Timer -isnot [string]){ $timer += [double]$snap.Timer.CurrentMs }
        try { $sc = Get-AXEScore $snap; if($sc){ $score += [double]$sc.Total } } catch {}
    }

    $id = Get-AXEBenchIdentity
    [pscustomobject]@{
        id         = $null                       # lo asigna Save-AXEBenchBaseline
        axeVersion = $id.axeVersion
        hwHash     = $id.hwHash
        hw         = $id.hw
        ts         = (Get-Date).ToUniversalTime().ToString('o')
        passes     = [int]$Passes
        jitterMs   = [int]$JitterMs
        metrics    = [pscustomobject]@{
            jitterP999Ms = (Get-AXEBenchStat $p999)
            jitterMeanMs = (Get-AXEBenchStat $jmean)
            timerMs      = (Get-AXEBenchStat $timer)
            score        = (Get-AXEBenchStat $score)
        }
    }
}

function Get-AXEBenchVerdict {
    # PURA y testeable: no mide, solo compara dos agregados. El corazon honesto del subproyecto.
    #
    # delta = medianaDespues - medianaAntes. Concluyente SOLO si
    #     abs(delta) > K * (IQRantes + IQRdespues)
    # o sea: el cambio tiene que salirse del ruido que ESTA maquina acaba de demostrar tener,
    # sumando el de las dos fases. Un delta por debajo de esa banda se etiqueta 'ruido' y NUNCA
    # se llama mejora. Es la leccion del timer-flakiness (2026-07-19) aplicada aqui: la
    # estadistica sola, sin comparar contra el ruido medido, declara ganadores por azar.
    #   K arranca conservador en 1.0. Subirlo exige mas evidencia; bajarlo de 1.0 seria empezar
    # a llamar mejora a cosas dentro del ruido, asi que no.
    #   Metrica ausente o sin mediana en cualquiera de las dos fases => se OMITE de la lista.
    # No se compara contra un 0 fabricado.
    param($Before,$After,[double]$K=1.0)
    $out = New-Object System.Collections.ArrayList
    if(-not $Before -or -not $After){ return @($out) }
    foreach($m in $script:AXEBenchMetrics){
        $b = $null; $a = $null
        try { $b = $Before.metrics.$($m.Key) } catch {}
        try { $a = $After.metrics.$($m.Key)  } catch {}
        if($null -eq $b -or $null -eq $a){ continue }
        if($null -eq $b.median -or $null -eq $a.median){ continue }

        $bm = [double]$b.median; $am = [double]$a.median
        $bq = if($null -eq $b.iqr){ 0.0 } else { [double]$b.iqr }
        $aq = if($null -eq $a.iqr){ 0.0 } else { [double]$a.iqr }
        $delta = $am - $bm
        # SUELO DE RESOLUCION. Con pocas pasadas y una metrica muy estable el IQR se redondea a
        # 0, y entonces CUALQUIER delta distinto de cero pasa el umbral: el ruido no ha
        # desaparecido, es que no lo estamos resolviendo. Medido en la primera ejecucion real:
        # 'Jitter medio' salio MEJOR con delta -0.0001ms e IQR 0.0000 en las dos fases. Eso es
        # justo el titular fabricado que este subproyecto existe para no publicar.
        #   El suelo es la resolucion con la que el propio reporte imprime la metrica (10^-Digits):
        # un cambio mas pequeno que el ultimo decimal que ensenamos no se puede llamar mejora.
        $floor = [math]::Pow(10, -$m.Digits)
        $noise = [math]::Max(($K * ($bq + $aq)), $floor)
        $conclusive = [math]::Abs($delta) -gt $noise

        $tag = 'ruido'
        if($conclusive){
            if($m.Better -eq 'down'){ $tag = $(if($delta -lt 0){'mejor'}else{'peor'}) }
            else                    { $tag = $(if($delta -gt 0){'mejor'}else{'peor'}) }
        }
        $pct = $null
        if([math]::Abs($bm) -gt 1e-9){ $pct = [math]::Round(100.0 * $delta / [math]::Abs($bm), 1) }

        $d = $m.Digits
        $reason = if($conclusive){
            "delta {0}{1} supera el ruido combinado {2}{1} (IQR {3} + {4}, K={5})." -f `
                (Format-AXEBenchNum $delta $d),$m.Unit,(Format-AXEBenchNum $noise $d), `
                (Format-AXEBenchNum $bq $d),(Format-AXEBenchNum $aq $d),(Format-AXEBenchNum $K 1)
        } else {
            "delta {0}{1} NO supera el ruido combinado {2}{1}: dentro del margen, no concluyente." -f `
                (Format-AXEBenchNum $delta $d),$m.Unit,(Format-AXEBenchNum $noise $d)
        }

        [void]$out.Add([pscustomobject]@{
            Key        = $m.Key
            Label      = $m.Label
            Unit       = $m.Unit
            Digits     = $d
            Better     = $m.Better
            Note       = $m.Note
            Before     = [math]::Round($bm,4)
            After      = [math]::Round($am,4)
            Delta      = [math]::Round($delta,4)
            PctChange  = $pct
            Noise      = [math]::Round($noise,4)
            Conclusive = [bool]$conclusive
            Tag        = $tag
            Reason     = $reason
        })
    }
    @($out)
}

function Save-AXEBenchBaseline {
    # Persiste el agregado en <AXEData>/bench/<id>.json y devuelve el id (o $null si no pudo).
    # id = marca de tiempo corta, legible y tecleable: el usuario lo copia a mano tras reiniciar.
    param($Sample)
    if(-not $Sample){ return $null }
    try {
        if(-not (Test-Path $script:AXEBenchDir)){ New-Item -ItemType Directory -Path $script:AXEBenchDir -Force | Out-Null }
        $base = (Get-Date).ToString('yyyyMMdd-HHmm')
        $id = $base; $n = 1
        # Dos baselines en el mismo minuto no se pisan: la segunda no puede borrar en silencio
        # el 'antes' de la primera, que es justo el dato que ya no se puede volver a tomar.
        while(Test-Path (Join-Path $script:AXEBenchDir ($id + '.json'))){ $id = ('{0}-{1}' -f $base,$n); $n++ }
        $Sample.id = $id
        $Sample | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:AXEBenchDir ($id + '.json')) -Encoding UTF8
        $id
    } catch {
        try { Write-AXELog "Benchmark: no pude guardar la linea base: $($_.Exception.Message)" 'ERR' } catch {}
        $null
    }
}

function Read-AXEBenchBaseline {
    # Carga <AXEData>/bench/<id>.json. $null si no existe o esta corrupto (no se inventa un
    # 'antes'). La validacion de comparabilidad NO va aqui: vive en Test-AXEBenchComparable,
    # que puede decir POR QUE no se puede comparar; devolver $null tambien para "otra maquina"
    # mezclaria dos fallos que merecen mensajes distintos.
    param([string]$Id)
    if([string]::IsNullOrWhiteSpace($Id)){ return $null }
    # El id es un NOMBRE de fichero, no una ruta: sin esto, '-After ..\..\algo' leeria fuera
    # del store. Barato, y cierra la unica entrada de usuario de todo el bloque.
    if($Id -notmatch '^[A-Za-z0-9._-]+$'){
        try { Write-AXELog "Benchmark: id de linea base invalido '$Id'." 'ERR' } catch {}
        return $null
    }
    $file = Join-Path $script:AXEBenchDir ($Id + '.json')
    if(-not (Test-Path $file)){ return $null }
    try {
        $raw = Get-Content $file -Raw -Encoding UTF8
        if([string]::IsNullOrWhiteSpace($raw)){ return $null }
        $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        try { Write-AXELog "Benchmark: linea base '$Id' ilegible: $($_.Exception.Message)" 'ERR' } catch {}
        $null
    }
}

function Test-AXEBenchComparable {
    # Devuelve $null si el 'antes' es comparable con ESTA maquina/build, o el motivo en texto.
    # Sin esto, un delta entre dos equipos (o entre dos versiones de AXE) tendria pinta de
    # medicion y seria basura: justo el tipo de cifra que el mercado publica.
    param($Before,$Identity=$null)
    if(-not $Before){ return 'no hay linea base que comparar.' }
    if(-not $Identity){ $Identity = Get-AXEBenchIdentity }
    if(-not $Before.hwHash){ return 'la linea base no trae hash de identidad (fichero de una version antigua).' }
    if($Before.hwHash -ne $Identity.hwHash){
        $bhw = $Before.hw
        return ("no comparable: la linea base se tomo en otra maquina/build o con otra version de AXE " +
                "(antes: {0} | {1} GB | GPU {2} | build {3} | AXE {4}  --  ahora: {5} | {6} GB | GPU {7} | build {8} | AXE {9})." -f `
                $bhw.cpu,(Format-AXEBenchNum $bhw.ramGB 1),$bhw.gpuVendor,$bhw.build,$Before.axeVersion, `
                $Identity.hw.cpu,(Format-AXEBenchNum $Identity.hw.ramGB 1),$Identity.hw.gpuVendor,$Identity.hw.build,$Identity.axeVersion)
    }
    $null
}

function Format-AXEBenchSample {
    # Render de UNA fase (la linea base). string[]: el consumidor decide como pintarlo, igual
    # que Format-AXETimerSweep. Ensena la mediana Y el IQR: el ruido se muestra desde el
    # principio, para que se vea contra que va a tener que competir el 'despues'.
    param($Sample,[string]$Title='LINEA BASE')
    if(-not $Sample){ return @('Sin datos (ver log).') }
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add("-- $Title --")
    [void]$L.Add(("Equipo   : {0} | {1} GB | GPU {2} | build {3}" -f $Sample.hw.cpu,(Format-AXEBenchNum $Sample.hw.ramGB 1),$Sample.hw.gpuVendor,$Sample.hw.build))
    [void]$L.Add(("Pasadas  : {0} (jitter {1}ms por pasada)" -f $Sample.passes,$Sample.jitterMs))
    [void]$L.Add('')
    [void]$L.Add('Metrica          mediana          ruido (IQR)')
    foreach($m in $script:AXEBenchMetrics){
        $st = $null; try { $st = $Sample.metrics.$($m.Key) } catch {}
        if($null -eq $st -or $null -eq $st.median){
            [void]$L.Add(("{0,-14}   {1,-16} {2}" -f $m.Label,'n/a','no medible en este equipo'))
            continue
        }
        [void]$L.Add(("{0,-14}   {1,-16} {2}" -f $m.Label, `
            ((Format-AXEBenchNum $st.median $m.Digits) + $m.Unit), `
            ((Format-AXEBenchNum $st.iqr $m.Digits) + $m.Unit)))
    }
    @($L)
}

function New-AXEBenchReport {
    # Tres representaciones del MISMO dato: Text (string[] para CLI), Json (string) y Markdown
    # (string, el compartible). Se generan aqui juntas a posta: si cada consumidor armara la
    # suya, un dia el .md diria "mejora" donde la CLI dice "ruido".
    #   SIN PII: solo modelo de CPU, RAM, vendor de GPU y build. Ni serial, ni usuario, ni IP.
    param($Before,$After,$Verdict)
    if(-not $Verdict){ $Verdict = Get-AXEBenchVerdict $Before $After }
    $rows = @($Verdict)
    $hw = $After.hw

    $notes = @(
        'Jitter = proxy de latencia (no atribuible a un driver concreto). DPC no se mide: no hay API userland honesta.'
        'Timer: en build 19041+ la resolucion instantanea la fija la app en primer plano; es ambiental, no configuracion.'
        "'ruido' = el cambio NO supera el ancho del ruido medido (IQR antes + IQR despues). No es una mejora."
        'FPS y 1% low NO se miden aqui (esto es headless, sin juego). Usa: AXE -Fps <proceso> -FpsCompare, con el juego abierto y la MISMA escena.'
        'Protocolo reproducible: cualquiera puede repetirlo en su equipo y verificar el resultado.'
    )

    # ---- Text (CLI) ----
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add('=== AXE BENCHMARK - antes / despues (medido en esta maquina) ===')
    [void]$L.Add(("Equipo   : {0} | {1} GB | GPU {2} | build {3}" -f $hw.cpu,(Format-AXEBenchNum $hw.ramGB 1),$hw.gpuVendor,$hw.build))
    [void]$L.Add(("Version  : AXE {0}" -f $After.axeVersion))
    [void]$L.Add(("Antes    : {0}  (id {1}, {2} pasadas)" -f (Format-AXEBenchTs $Before.ts),$Before.id,$Before.passes))
    [void]$L.Add(("Despues  : {0}  ({1} pasadas)" -f (Format-AXEBenchTs $After.ts),$After.passes))
    [void]$L.Add('')
    if($rows.Count -eq 0){
        [void]$L.Add('Ninguna metrica se pudo medir en las DOS fases: no hay nada que comparar.')
    } else {
        [void]$L.Add('Metrica          antes            despues          delta            ruido            veredicto')
        foreach($v in $rows){
            [void]$L.Add(("{0,-14}   {1,-16} {2,-16} {3,-16} {4,-16} {5}" -f $v.Label, `
                ((Format-AXEBenchNum $v.Before $v.Digits) + $v.Unit), `
                ((Format-AXEBenchNum $v.After  $v.Digits) + $v.Unit), `
                ((Format-AXEBenchNum $v.Delta  $v.Digits) + $v.Unit), `
                ((Format-AXEBenchNum $v.Noise  $v.Digits) + $v.Unit), `
                $v.Tag.ToUpperInvariant()))
        }
        [void]$L.Add('')
        foreach($v in $rows){ [void]$L.Add(("{0,-14} : {1}" -f $v.Label,$v.Reason)) }
        $mej = @($rows | Where-Object { $_.Tag -eq 'mejor' }).Count
        $peo = @($rows | Where-Object { $_.Tag -eq 'peor'  }).Count
        $rui = @($rows | Where-Object { $_.Tag -eq 'ruido' }).Count
        [void]$L.Add('')
        [void]$L.Add(("RESUMEN  : {0} mejor(es), {1} peor(es), {2} dentro del ruido." -f $mej,$peo,$rui))
        if($mej -eq 0 -and $peo -eq 0){
            [void]$L.Add('           Nada salio del ruido: en este equipo el cambio NO es demostrable con estas metricas.')
            [void]$L.Add('           Eso es un resultado valido, no un fallo de la herramienta.')
        }
    }
    [void]$L.Add('')
    [void]$L.Add('Notas:')
    foreach($n in $notes){ [void]$L.Add(" - $n") }

    # ---- Markdown (compartible) ----
    $M = New-Object System.Collections.ArrayList
    [void]$M.Add('# AXE - benchmark antes / despues')
    [void]$M.Add('')
    [void]$M.Add(("**Equipo:** {0} | {1} GB | GPU {2} | Windows build {3}  " -f $hw.cpu,(Format-AXEBenchNum $hw.ramGB 1),$hw.gpuVendor,$hw.build))
    [void]$M.Add(("**AXE:** {0}  " -f $After.axeVersion))
    [void]$M.Add(("**Antes:** {0} ({1} pasadas) - **Despues:** {2} ({3} pasadas)" -f (Format-AXEBenchTs $Before.ts),$Before.passes,(Format-AXEBenchTs $After.ts),$After.passes))
    [void]$M.Add('')
    if($rows.Count -eq 0){
        [void]$M.Add('_Ninguna metrica se pudo medir en las dos fases: no hay nada que comparar._')
    } else {
        [void]$M.Add('| Metrica | Antes | Despues | Delta | Ruido (IQR sumado) | Veredicto |')
        [void]$M.Add('|---|---|---|---|---|---|')
        foreach($v in $rows){
            [void]$M.Add(("| {0} | {1}{6} | {2}{6} | {3}{6} | {4}{6} | **{5}** |" -f $v.Label, `
                (Format-AXEBenchNum $v.Before $v.Digits),(Format-AXEBenchNum $v.After $v.Digits), `
                (Format-AXEBenchNum $v.Delta $v.Digits),(Format-AXEBenchNum $v.Noise $v.Digits), `
                $v.Tag,$v.Unit))
        }
    }
    [void]$M.Add('')
    [void]$M.Add('## Como leerlo')
    foreach($n in $notes){ [void]$M.Add("- $n") }
    [void]$M.Add('')
    [void]$M.Add('> Reproducelo: `AXE -Benchmark`, aplica los cambios, reinicia, `AXE -Benchmark -After <id>`.')

    # ---- Json (mismo dato, plano) ----
    $json = ([pscustomobject]@{
        generated  = (Get-Date).ToUniversalTime().ToString('o')
        axeVersion = $After.axeVersion
        hw         = $hw
        before     = $Before
        after      = $After
        verdict    = @($rows | ForEach-Object {
            [pscustomobject]@{ key=$_.Key; label=$_.Label; unit=$_.Unit; better=$_.Better
                before=$_.Before; after=$_.After; delta=$_.Delta; pctChange=$_.PctChange
                noise=$_.Noise; conclusive=$_.Conclusive; tag=$_.Tag; reason=$_.Reason }
        })
        notes      = $notes
    } | ConvertTo-Json -Depth 8)

    [pscustomobject]@{ Text=@($L); Json=$json; Markdown=(($M) -join "`r`n") }
}

function Export-AXEBenchReport {
    # Escribe <stem>.json y <stem>.md a partir del reporte ya construido. Devuelve las rutas
    # escritas (string[]). Un solo -Report en la CLI produce las dos caras compartibles.
    param($Report,[string]$Path)
    if(-not $Report -or [string]::IsNullOrWhiteSpace($Path)){ return @() }
    $dir = Split-Path -Parent $Path
    # '-Report informe.json' (sin carpeta) deja $dir vacio y Join-Path revienta con cadena
    # vacia: se cae al directorio actual, que es lo que el usuario quiso decir.
    if([string]::IsNullOrWhiteSpace($dir)){ $dir = '.' }
    if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stem = Join-Path $dir ([IO.Path]::GetFileNameWithoutExtension($Path))
    $jf = "$stem.json"; $mf = "$stem.md"
    Set-Content -Path $jf -Value $Report.Json -Encoding UTF8
    Set-Content -Path $mf -Value $Report.Markdown -Encoding UTF8
    @($jf,$mf)
}


# >>>>> MODULE: 42-advisor.ps1 >>>>>
# =====================================================
# REGION 12c - CONSEJERO: QUE HACER AHORA, EN ESTA MAQUINA
# =====================================================
#
# POR QUE EXISTE: AXE sabia muchas cosas sueltas -82 tweaks con su gating, un diagnostico de
# configuracion, mediciones de timer y jitter, un monitor de red- y no juntaba ninguna. El
# usuario tenia que leer cuatro pantallas y decidir por su cuenta. Este modulo responde a la
# unica pregunta que de verdad se hace: "vale, y ahora que hago".
#
# COMO PARECE LISTO SIN SERLO: aqui no hay modelo, ni red neuronal, ni nada que "aprenda" en el
# sentido de moda. Hay tres cosas que ningun optimizador del mercado hace a la vez:
#   1. Razonar sobre COMBINACIONES en vez de campos sueltos. "Panel de 180Hz + RAM en single
#      channel" no es la suma de dos avisos: es un diagnostico distinto, porque con la RAM asi
#      esos 180Hz no los vas a ver toques lo que toques.
#   2. Ordenar por EFECTO REAL. Un hallazgo del diagnostico (10-40%) va SIEMPRE por delante de
#      cualquier tweak del catalogo (porcentajes de un digito, y varios ni eso). Ordenar al reves
#      es lo que hacen las suites de pago, porque los tweaks son lo que ellas venden.
#   3. Recordar lo MEDIDO EN ESTA MAQUINA y usarlo. Si con un ajuste puesto tu score medio no se
#      movio en cinco medidas, eso pesa mas que cualquier recomendacion de catalogo.
#
# LA LINEA QUE NO SE CRUZA: la evidencia local es OBSERVACIONAL, no un experimento controlado.
# Entre dos medidas cambian mil cosas (que tenias abierto, la temperatura, el driver). Decir
# "este ajuste te da +3" seria exactamente la mentira que este proyecto existe para no contar.
# Se dice lo que es: "con esto puesto tu score medio fue X (n=5) y sin ello Y (n=4); no es un
# experimento controlado". Y con menos de MinN muestras a cada lado, no se concluye NADA.

$script:AXEOutcomeMinN   = 3     # muestras minimas a CADA lado para abrir la boca
$script:AXEOutcomeMaxRow = 200   # tope del historico: es una ayuda, no un almacen de datos
$script:AXEOutcomeNoise  = 2.0   # puntos de score por debajo de los cuales no se afirma nada

# --- Almacen de resultados ------------------------------------------------------------------
function Get-AXEOutcomePath {
    if([string]::IsNullOrWhiteSpace($script:AXEData)){ return $null }
    Join-Path $script:AXEData 'outcomes.json'
}

function Write-AXEAdvisorLog {
    # 42 se dot-sourcea suelto en tests (sin 05-core). Loguear es best-effort, jamas un error.
    param([string]$Message,[string]$Level='INFO')
    if(Get-Command Write-AXELog -EA SilentlyContinue){ Write-AXELog $Message $Level }
}

function Read-AXEOutcomes {
    # Tolerante como Read-Profiles: ausente, ilegible o corrupto -> historico vacio, NUNCA lanza.
    # Un fichero roto no puede impedir que AXE arranque ni que aconseje sin evidencia local.
    $empty = [pscustomobject]@{ hwHash=$null; samples=@() }
    $p = Get-AXEOutcomePath
    if(-not $p -or -not (Test-Path $p)){ return $empty }
    try {
        $doc = (Get-Content $p -Raw -Encoding UTF8 -EA Stop) | ConvertFrom-Json -EA Stop
        if(-not $doc){ return $empty }
        # ConvertFrom-Json REHIDRATA las cadenas con pinta de ISO-8601 a [datetime]. Si se reescribe
        # tal cual, la fecha sale como '...T09:09:59.0000000Z' y el formato del fichero deriva en
        # cada ciclo de lectura. Peor todavia: un [string] sobre ese datetime usaria la cultura del
        # sistema y en es-ES escribiria '26/07/2026 9:09:59', con lo que el json dejaria de ser
        # portable entre maquinas. Se normaliza a la entrada y el fichero queda estable.
        $rows = foreach($s in @($doc.samples)){
            if(-not $s){ continue }
            $at = $s.at
            if($at -is [datetime]){ $at = $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture) }
            [pscustomobject]@{ at=[string]$at; score=$s.score; jitter=$s.jitter; applied=@($s.applied) }
        }
        return [pscustomobject]@{ hwHash=[string]$doc.hwHash; samples=@($rows) }
    } catch {
        Write-AXEAdvisorLog 'Consejero: outcomes.json ilegible; se sigue sin evidencia local.' 'WARN'
        return $empty
    }
}

function Add-AXEOutcome {
    # Guarda UNA medida con la huella de ajustes aplicados en ese momento. Devuelve $true si quedo
    # escrita. No lanza nunca: perder una muestra es aceptable, romper una medicion no.
    #   El historico se ATA a la maquina (hwHash de 41-bench, que no lleva serial ni usuario ni
    # MAC). Si el hash cambia -otra CPU, otra RAM, otro build- el historico anterior se descarta
    # entero en vez de mezclarse: comparar dos maquinas distintas da un numero sin significado.
    param(
        [Parameter(Mandatory)][int]$Score,
        [double]$JitterP999,
        [string[]]$AppliedIds = @(),
        [string]$HwHash
    )
    $p = Get-AXEOutcomePath
    if(-not $p){ return $false }
    $doc = Read-AXEOutcomes
    if($HwHash -and $doc.hwHash -and $doc.hwHash -ne $HwHash){
        Write-AXEAdvisorLog 'Consejero: la maquina cambio; el historico anterior se descarta en vez de mezclarse.' 'WARN'
        $doc = [pscustomobject]@{ hwHash=$HwHash; samples=@() }
    }
    $rows = [System.Collections.ArrayList]@($doc.samples)
    [void]$rows.Add([pscustomobject]@{
        at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture)
        score   = [int]$Score
        jitter  = $(if($PSBoundParameters.ContainsKey('JitterP999')){ [double]$JitterP999 } else { $null })
        applied = @(@($AppliedIds) | Where-Object { $_ } | Sort-Object -Unique)
    })
    # Tope por antiguedad: se tiran las mas viejas. Un historico infinito no aconseja mejor y
    # convierte un fichero de ayuda en un problema de disco.
    while($rows.Count -gt $script:AXEOutcomeMaxRow){ $rows.RemoveAt(0) }
    try {
        $dir = Split-Path $p -Parent
        if($dir -and -not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force -EA Stop | Out-Null }
        $save = [pscustomobject]@{ hwHash=$(if($HwHash){ $HwHash } else { $doc.hwHash }); samples=@($rows) }
        Set-Content -Path $p -Value (ConvertTo-Json -InputObject $save -Depth 5) -Encoding UTF8 -EA Stop
        return $true
    } catch {
        Write-AXEAdvisorLog ("Consejero: no pude guardar la medida: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Get-AXETweakEvidence {
    # PURA. Para UN ajuste: que dice el historico de ESTA maquina.
    #
    # Es una comparacion OBSERVACIONAL entre las medidas tomadas con el ajuste puesto y las
    # tomadas sin el. No es un ensayo: nadie controlo que cambiaba en medio. Por eso el veredicto
    # mas fuerte que puede emitir es "asociado a", jamas "causa".
    param(
        [Parameter(Mandatory)][string]$Id,
        [object[]]$Samples,
        [int]$MinN = 0
    )
    if($MinN -le 0){ $MinN = $script:AXEOutcomeMinN }
    $on = New-Object System.Collections.Generic.List[double]
    $off = New-Object System.Collections.Generic.List[double]
    foreach($s in @($Samples)){
        if($null -eq $s -or $null -eq $s.score){ continue }
        if(@($s.applied) -contains $Id){ [void]$on.Add([double]$s.score) } else { [void]$off.Add([double]$s.score) }
    }
    $mOn  = $(if($on.Count){  [math]::Round(($on  | Measure-Object -Average).Average,1) } else { $null })
    $mOff = $(if($off.Count){ [math]::Round(($off | Measure-Object -Average).Average,1) } else { $null })
    $delta = $(if($null -ne $mOn -and $null -ne $mOff){ [math]::Round($mOn - $mOff,1) } else { $null })

    # El orden de los cortes importa: primero "no se sabe", luego "no se aprecia", y solo al final
    # se permite decir algo. Al reves se colaria una afirmacion con n=1, que es ruido con formato.
    $verdict = 'sin evidencia'
    $detail  = "hacen falta $MinN medidas con el ajuste puesto y $MinN sin el; llevas $($on.Count) y $($off.Count)."
    if($on.Count -ge $MinN -and $off.Count -ge $MinN){
        if([math]::Abs($delta) -lt $script:AXEOutcomeNoise){
            $verdict = 'sin diferencia apreciable'
            $detail  = "score medio $mOn con el ajuste y $mOff sin el (n=$($on.Count)/$($off.Count)). La diferencia cae dentro del ruido de medicion."
        } elseif($delta -gt 0){
            $verdict = 'asociado a mejor score'
            $detail  = "score medio $mOn con el ajuste y $mOff sin el (n=$($on.Count)/$($off.Count)). Observacional: entre medidas cambiaron mas cosas, no es un experimento controlado."
        } else {
            $verdict = 'asociado a peor score'
            $detail  = "score medio $mOn con el ajuste y $mOff sin el (n=$($on.Count)/$($off.Count)). Observacional, pero merece que lo revises."
        }
    }
    [pscustomobject]@{
        Id=$Id; NOn=$on.Count; NOff=$off.Count; MeanOn=$mOn; MeanOff=$mOff
        Delta=$delta; Verdict=$verdict; Detail=$detail
    }
}

function Get-AXEBottleneck {
    # PURA. Razona sobre COMBINACIONES de hechos, que es de donde sale la sensacion de que el
    # programa entiende tu equipo. Un aviso por campo suelto lo hace cualquiera; decir "con la RAM
    # asi, esos 180Hz no los vas a ver" exige cruzar dos hechos.
    #   Devuelve una lista ordenada por peso. Vacia es una respuesta valida: significa que no hay
    # ningun cuello identificable con lo que se ha podido medir, y eso se dice, no se rellena.
    param($Hw, $DiagFindings, $Snapshot)
    $out = New-Object System.Collections.Generic.List[object]
    $bad = @{}
    foreach($f in @($DiagFindings)){ if($f -and $f.Status -eq 'BAD'){ $bad[[string]$f.Id] = $f } }

    $hz = $null
    if($Hw -and $Hw.RefreshHz){ $hz = [int]$Hw.RefreshHz }

    # 1. RAM en single channel. El techo mas duro que hay, y el peor combinado con panel rapido.
    if($bad.ContainsKey('ramchan')){
        $msg = 'Tu RAM va en single channel. Es el techo mas alto de esta lista: 20-40% en juego.'
        if($hz -and $hz -ge 100){
            $msg += " Y tienes un panel de $hz Hz, o sea que pagaste por unos frames que la memoria no deja llegar. Arreglar esto vale mas que el catalogo entero."
        }
        [void]$out.Add([pscustomobject]@{ Rank=1; Id='ramchan'; Title='La memoria te limita'; Detail=$msg })
    }

    # 2. XMP/EXPO apagado.
    if($bad.ContainsKey('xmp')){
        [void]$out.Add([pscustomobject]@{ Rank=2; Id='xmp'; Title='La RAM corre por debajo de lo que compraste'
            Detail='El perfil XMP/EXPO parece apagado: la memoria va a la velocidad JEDEC de arranque. 10-30% en juego, y se activa en la BIOS en dos minutos.' })
    }

    # 3. Panel por debajo de sus Hz. Barato de arreglar y de efecto inmediato.
    if($bad.ContainsKey('refresh')){
        [void]$out.Add([pscustomobject]@{ Rank=3; Id='refresh'; Title='El monitor no va a sus Hz'
            Detail=([string]$bad['refresh'].Detail + ' Se cambia en Configuracion de Windows y se nota al instante.') })
    }

    # 4. Windows en disco mecanico.
    if($bad.ContainsKey('ssd')){
        [void]$out.Add([pscustomobject]@{ Rank=4; Id='ssd'; Title='Windows vive en un disco mecanico'
            Detail='Afecta sobre todo a tirones y a cargas. Ningun ajuste del catalogo compensa esto.' })
    }

    # 5. Portatil con bateria: Windows recorta frecuencias pase lo que pase en el registro.
    if($Hw -and $Hw.IsLaptop -and $Hw.OnBattery){
        [void]$out.Add([pscustomobject]@{ Rank=5; Id='battery'; Title='Estas con bateria'
            Detail='Con el portatil desenchufado Windows recorta frecuencias de CPU y GPU por politica de energia. Cualquier medida que tomes ahora sale peor de lo que da tu equipo enchufado.' })
    }

    # 6. Maquina virtual: el timer y el jitter medidos no son los del hierro.
    if($Hw -and $Hw.IsVM){
        [void]$out.Add([pscustomobject]@{ Rank=6; Id='vm'; Title='Esto es una maquina virtual'
            Detail='El timer y el jitter que mide AXE aqui son los que da el hipervisor, no los del hardware. Los numeros valen para compararte contigo mismo, no con un equipo real.' })
    }

    # 7. Nada mal configurado Y sistema ya fino: decirlo es mas util que inventar una tarea.
    if($out.Count -eq 0){
        $timerOk = $false
        if($Snapshot -and $Snapshot.Timer -isnot [string] -and $Snapshot.Timer.CurrentMs -le 1.0){ $timerOk = $true }
        if($timerOk){
            [void]$out.Add([pscustomobject]@{ Rank=9; Id='clean'; Title='No te encuentro un cuello de botella'
                Detail='Lo que este programa sabe comprobar esta bien configurado y el timer ya esta fino. A partir de aqui el margen que queda en software es de un digito, y lo grande esta en el hardware o en los ajustes del propio juego. Preferimos decirtelo a inventarte tareas.' })
        }
    }
    @($out | Sort-Object Rank)
}

function Get-AXEAdvice {
    # PURA. Funde diagnostico + cuellos + catalogo + evidencia local en UN plan ordenado.
    # El orden NO es negociable y es lo que separa esto de un optimizador de pago:
    #   1. Lo que vale 10-40% (diagnostico). No lo arregla AXE, y aun asi va primero.
    #   2. Lo que tu propia maquina asocia a ir PEOR con un ajuste puesto.
    #   3. Ajustes recomendados que faltan (porcentajes de un digito, y se dice en el texto).
    # Un catalogo que se pone por delante de "tienes la RAM en single channel" esta vendiendo,
    # no aconsejando.
    param(
        $Hw, $DiagFindings, $Snapshot,
        [object[]]$Tweaks = @(),          # catalogo con {Id,Name,Tier,PlaceboLikely}
        [string[]]$RecommendedIds = @(),  # Get-AXERecommended
        [string[]]$AppliedIds = @(),      # los que estan puestos ahora
        [object[]]$Samples = @()          # historico local
    )
    $plan = New-Object System.Collections.Generic.List[object]
    $n = 0
    $nombreDe = {
        param($id)
        $t = @(@($Tweaks) | Where-Object { $_ -and $_.Id -eq $id }) | Select-Object -First 1
        if($t -and $t.Name){ [string]$t.Name } else { [string]$id }
    }

    foreach($b in @(Get-AXEBottleneck -Hw $Hw -DiagFindings $DiagFindings -Snapshot $Snapshot)){
        $n++
        [void]$plan.Add([pscustomobject]@{
            Order=$n; Kind='cuello'; Id=$b.Id; Title=$b.Title; Detail=$b.Detail
            Why='medido en tu equipo'; Impact='alto'
            Action=$(if($b.Id -eq 'clean'){ 'nada que hacer' } else { 'lo arreglas tu, fuera de AXE' })
        })
    }

    # 2. Ajustes PUESTOS que tu historico asocia a peor score. Solo con evidencia suficiente:
    # sugerir quitar algo por una corazonada seria peor que no decir nada.
    foreach($id in @($AppliedIds)){
        $ev = Get-AXETweakEvidence -Id $id -Samples $Samples
        if($ev.Verdict -ne 'asociado a peor score'){ continue }
        $n++
        [void]$plan.Add([pscustomobject]@{
            Order=$n; Kind='revisar'; Id=$id
            Title=("Revisa '{0}': en TU equipo va peor con el" -f (& $nombreDe $id))
            Detail=$ev.Detail; Why='historico de esta maquina'; Impact='medio'; Action='considera revertirlo'
        })
    }

    # 3. Recomendados que faltan. Van los ULTIMOS a proposito y con el tamano real declarado.
    $faltan = @(@($RecommendedIds) | Where-Object { @($AppliedIds) -notcontains $_ })
    if($faltan.Count -gt 0){
        $nombres = @($faltan | ForEach-Object { & $nombreDe $_ })
        $n++
        [void]$plan.Add([pscustomobject]@{
            Order=$n; Kind='catalogo'; Id='recomendados'
            Title=("Te faltan {0} ajuste(s) recomendados para este equipo" -f $faltan.Count)
            Detail=("Aplican a tu hardware y no estan puestos: {0}. Aviso de tamano: estos mueven porcentajes de un digito, y varios estan marcados como probable placebo en el propio catalogo. Van los ultimos de esta lista justo por eso." -f ($nombres -join ', '))
            Why='gating sobre tu hardware'; Impact='bajo'; Action='pestana Optimizar'
        })
    }

    # 4. Lo que no se pudo comprobar. Un plan que calla sus huecos parece mas listo de lo que es.
    $unk = @(@($DiagFindings) | Where-Object { $_ -and $_.Status -eq 'UNKNOWN' })
    if($unk.Count -gt 0){
        $n++
        [void]$plan.Add([pscustomobject]@{
            Order=$n; Kind='sin comprobar'; Id='unknown'
            Title=("{0} cosa(s) que no he podido comprobar" -f $unk.Count)
            Detail=((@($unk | ForEach-Object { [string]$_.Title }) -join ', ') + '. No salen como correctas por no haberse podido medir: eso seria un aprobado regalado.')
            Why='no medible aqui'; Impact='desconocido'; Action='compruebalo a mano'
        })
    }

    # .ToArray() y NO @($plan): en PowerShell 7.6.4 el subarray @(...) sobre un
    # System.Collections.Generic.List[T] lanza "Argument types do not match". Comprobado en un
    # proceso limpio, sin el motor de AXE cargado, asi que es del intérprete y no de aqui. Por eso
    # todo este proyecto devuelve .ToArray() (Get-AXEDiagFindings, Format-AXEDiag, Format-AXESession):
    # es la convencion que hay que seguir, no una manía. Pasar por una tuberia -como hace
    # Get-AXEBottleneck con Sort-Object- tambien esquiva el fallo, porque enumera de otra forma.
    $plan.ToArray()
}

function Get-AXEAppliedIds {
    # Impura: ejecuta el Test de cada tweak aplicable. Reusa Test-TweakSafe (28-revert-export),
    # que ya envuelve el scriptblock y devuelve $false ante cualquier error, en vez de contar un
    # fallo de lectura como "aplicado" -que fue justo el defecto que arreglo el FIX de 20-tweaks.
    #   Los bloqueados se saltan: un tweak que no aplica a esta maquina no esta "sin poner", es que
    # no existe aqui, y meterlo en la huella ensuciaria el historico con ruido constante.
    @(foreach($tw in @($script:CAT)){
        if(Get-BlockReason $tw){ continue }
        if(Test-TweakSafe $tw){ [string]$tw.Id }
    })
}

function Get-AXEAdviceNow {
    # Impura: junta hardware, diagnostico, medicion e historico, devuelve el plan y -esto es lo
    # importante- GUARDA la medida con la huella de ajustes puestos en ese momento.
    #
    # El bucle se cierra aqui, y a proposito: pedir consejo es lo que construye la evidencia. No
    # hay que acordarse de "registrar" nada ni pulsar un boton extra; usar el programa es lo que
    # lo hace mas util con el tiempo. Es la unica parte del proyecto que mejora sola, y mejora con
    # TUS datos, que no salen de tu disco.
    param([switch]$NoMeasure)
    $hw = $script:HW
    if(-not $hw){ try { $hw = Get-AXEHardware; $script:HW = $hw } catch { $hw = $null } }

    $findings = @()
    try { $findings = @(Get-AXEDiagFindings -Facts (Get-AXEDiagFacts)) } catch {
        Write-AXEAdvisorLog ("Consejero: el diagnostico fallo: {0}" -f $_.Exception.Message) 'WARN'
    }

    $snap = $null; $score = $null
    if(-not $NoMeasure){
        try { $snap = Get-AXESnapshot; $score = Get-AXEScore $snap } catch {
            Write-AXEAdvisorLog ("Consejero: la medicion fallo: {0}" -f $_.Exception.Message) 'WARN'
        }
    }

    $applied = @(); try { $applied = @(Get-AXEAppliedIds) } catch {}
    $rec = @();     try { $rec = @(Get-AXERecommended) } catch {}

    # Guardar la muestra ANTES de aconsejar, para que el consejo de hoy ya cuente con ella.
    # Sin score no se guarda nada: una fila sin la magnitud que se compara no sirve de nada.
    $doc = Read-AXEOutcomes
    if($null -ne $score -and $null -ne $score.Total){
        $hash = $null
        try {
            $hash = Get-AXEBenchHwHash -Cpu ([string]$hw.CpuName) -RamGB ([double]$hw.RamGB) `
                        -GpuVendor ([string]$hw.GpuVendor) -Build ([int]$hw.BuildNumber) -Version ([string]$script:AXEVersion)
        } catch {}
        $jit = $null
        if($snap -and $snap.Jitter -isnot [string]){ $jit = [double]$snap.Jitter.P999Ms }
        try {
            if($null -ne $jit){ [void](Add-AXEOutcome -Score ([int]$score.Total) -JitterP999 $jit -AppliedIds $applied -HwHash $hash) }
            else              { [void](Add-AXEOutcome -Score ([int]$score.Total) -AppliedIds $applied -HwHash $hash) }
        } catch {}
        $doc = Read-AXEOutcomes
    }

    $plan = Get-AXEAdvice -Hw $hw -DiagFindings $findings -Snapshot $snap `
                -Tweaks @($script:CAT) -RecommendedIds $rec -AppliedIds $applied -Samples @($doc.samples)

    [pscustomobject]@{
        Plan=@($plan); Findings=@($findings); Applied=@($applied); Recommended=@($rec)
        Samples=@($doc.samples); Score=$(if($score){ [int]$score.Total } else { $null })
        Hw=$hw; Timestamp=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture)
    }
}

function Format-AXEAdvice {
    # PURA. Render compartido CLI/GUI, como Format-AXEDiag y Format-AXESession.
    param([object[]]$Plan,[object[]]$Samples=@())
    $L = New-Object System.Collections.Generic.List[string]
    [void]$L.Add('== AXE - QUE HACER AHORA ==')
    [void]$L.Add('')
    if(@($Plan).Count -eq 0){
        [void]$L.Add('Sin datos suficientes para aconsejar. Ejecuta antes el diagnostico (-Diag).')
        return $L.ToArray()
    }
    foreach($p in @($Plan)){
        [void]$L.Add(('{0}. [{1}] {2}' -f $p.Order, ([string]$p.Kind).ToUpperInvariant(), $p.Title))
        [void]$L.Add(('     {0}' -f $p.Detail))
        # Separadores ASCII a proposito. El '·' salia como 'Â·' en consola: dist/AXE.ps1 lo lanza
        # 'powershell.exe' (5.1), que lee el .ps1 como ANSI salvo que lleve BOM. Comprobado: esta
        # era la UNICA cadena no-ASCII de todo src/ que llega a la consola; el resto de acentos
        # del proyecto viven en comentarios, que no se imprimen. La convencion ya estaba, se
        # respeta. En la WebUI si se puede usar '·': el HTML declara UTF-8.
        [void]$L.Add(('     efecto: {0} | base: {1} | accion: {2}' -f $p.Impact, $p.Why, $p.Action))
        [void]$L.Add('')
    }
    [void]$L.Add('---')
    $nS = @($Samples).Count
    if($nS -eq 0){
        [void]$L.Add('Sin historico local todavia. Cada medicion que hagas afina esta lista: AXE compara')
        [void]$L.Add('lo medido con cada ajuste puesto y sin el, EN ESTA MAQUINA.')
    } else {
        [void]$L.Add(("Historico local: {0} medicion(es) en este equipo." -f $nS))
        [void]$L.Add('Esa comparacion es OBSERVACIONAL: entre medidas cambian mas cosas que el ajuste,')
        [void]$L.Add('asi que se dice "asociado a", nunca "causa". Con menos de 3 medidas a cada lado')
        [void]$L.Add('no se afirma nada.')
    }
    $L.ToArray()
}


# >>>>> MODULE: 43-update.ps1 >>>>>
# =====================================================
# REGION 8f - CADENA DE CONFIANZA + UPDATER (subproyectos A+B) - spec 2026-07-24
# =====================================================
# Lo que cierra: que AXE se pueda INSTALAR y ACTUALIZAR sin que eso abra un agujero de
# supply-chain. La mayoria de optimizadores de GitHub se distribuyen como un .bat crudo que
# hace Invoke-WebRequest a una URL y lo ejecuta. Eso es exactamente lo que aqui NO se hace.
#
# Las tres piezas, por orden de lo que garantizan:
#   SHA256SUMS   -> integridad EN TRANSITO (llego entero, sin corrupcion ni MITM)
#   sbom.json    -> transparencia (que hay dentro del paquete, con hash y licencia)
#   Authenticode -> AUTENTICIDAD (quien lo firmo). La unica de las tres que prueba PROCEDENCIA.
#
# POR QUE EL CHECKSUM NO BASTA PARA REEMPLAZAR EL SCRIPT (decision de seguridad, no de estilo):
# el SHA256SUMS viaja en el MISMO release que el asset. Quien pueda alterar uno altera el otro
# y ambos seguirian cuadrando. Ademas AXE se instala en %LOCALAPPDATA% (escribible por el
# usuario) y luego AXE.bat lo ELEVA a admin: un proceso sin privilegios que consiga escribir
# ahi se convierte en admin la proxima vez que el usuario abra AXE. Por eso Invoke-AXEUpdate
# solo REEMPLAZA con firma Authenticode valida; sin firma informa y se para. Es menos comodo y
# es lo correcto: el updater no puede ser el eslabon debil de la cadena que el resto del
# proyecto presume de tener.
#
# Reparto igual que el resto del motor: aqui vive lo PURO y testeable (comparar versiones,
# generar/parsear checksums, construir el SBOM); la red queda en funciones finas que degradan
# a $null en vez de lanzar, para que la CI sin red no se ponga roja.
#
# Este modulo se dot-sourcea SUELTO desde scripts/New-AXERelease.ps1 (que no carga el motor
# entero). Por eso no depende de nada de 05-core: el log va por el helper guardado de abajo y
# las rutas se pasan siempre por parametro.

# Repo oficial HARDCODED, a posta. Un updater al que se le puede decir owner/repo por
# parametro o por fichero de config es un updater al que se le puede decir de donde bajar.
$script:AXEUpdateOwner = 'CARTY240HZ'
$script:AXEUpdateRepo  = 'AXE'
# Hosts desde los que GitHub sirve assets de release. Se comprueba el host de la URL que
# devuelve la API ANTES de descargar: aunque la respuesta viniera manipulada, no se baja de un
# dominio arbitrario.
$script:AXEUpdateHosts = @('github.com','objects.githubusercontent.com','release-assets.githubusercontent.com')

function Write-AXEUpdLog {
    # 05-core puede no estar cargado (uso suelto desde el script de release): degrada a verbose.
    param([string]$Msg,[string]$Level='INFO')
    if(Get-Command Write-AXELog -EA SilentlyContinue){ Write-AXELog $Msg $Level } else { Write-Verbose "[$Level] $Msg" }
}

# --- Version ------------------------------------------------------------------------------

function ConvertTo-AXEVersionParts {
    # SemVer parcial A POSTA: numeros + prerelease. Los metadatos de build (+sha) se ignoran
    # porque por spec de SemVer no participan en la precedencia. No se usa [version] de .NET
    # porque trata '7.1.0-beta' como invalido y porque su cuarto campo (revision) no es SemVer.
    param([string]$Version)
    if([string]::IsNullOrWhiteSpace($Version)){ return $null }
    $s = $Version.Trim()
    if($s -match '^[vV]'){ $s = $s.Substring(1) }
    $plus = $s.IndexOf('+'); if($plus -ge 0){ $s = $s.Substring(0,$plus) }
    $pre = ''
    $dash = $s.IndexOf('-'); if($dash -ge 0){ $pre = $s.Substring($dash+1); $s = $s.Substring(0,$dash) }
    $nums = @()
    foreach($p in ($s -split '\.')){
        $n = 0
        if(-not [int]::TryParse($p,[ref]$n)){ return $null }   # '7.x.0' no es una version
        $nums += $n
    }
    if($nums.Count -eq 0){ return $null }
    while($nums.Count -lt 3){ $nums += 0 }                      # '7' y '7.0' == '7.0.0'
    [pscustomobject]@{ Numbers = $nums; PreRelease = $pre }
}

function Compare-AXEVersion {
    # -1 si A < B, 0 si iguales, 1 si A > B. $null si alguna no es parseable: quien llama
    # decide que hacer, en vez de recibir un 0 que se confunde con "estan al dia".
    param([string]$A,[string]$B)
    $pa = ConvertTo-AXEVersionParts $A; $pb = ConvertTo-AXEVersionParts $B
    if(-not $pa -or -not $pb){ return $null }
    $n = [math]::Max($pa.Numbers.Count,$pb.Numbers.Count)
    for($i=0; $i -lt $n; $i++){
        $x = if($i -lt $pa.Numbers.Count){ $pa.Numbers[$i] } else { 0 }
        $y = if($i -lt $pb.Numbers.Count){ $pb.Numbers[$i] } else { 0 }
        if($x -lt $y){ return -1 }
        if($x -gt $y){ return 1 }
    }
    # SemVer §11: una version CON prerelease va SIEMPRE por debajo de la misma sin el. Sin
    # esto '7.1.0-beta' y '7.1.0' saldrian iguales y el updater no ofreceria la estable.
    if($pa.PreRelease -eq $pb.PreRelease){ return 0 }
    if([string]::IsNullOrEmpty($pa.PreRelease)){ return 1 }
    if([string]::IsNullOrEmpty($pb.PreRelease)){ return -1 }
    [math]::Sign([string]::CompareOrdinal($pa.PreRelease,$pb.PreRelease))
}

# --- Firma --------------------------------------------------------------------------------

function Test-AXESignature {
    # $true SOLO con Status 'Valid'. 'NotSigned', 'HashMismatch', 'NotTrusted' y
    # 'UnknownError' son todos $false: a la hora de decidir si se reemplaza un fichero que
    # luego correra ELEVADO no se distingue "aun no firmado" de "firma rota".
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){ return $false }
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ return $false }
    try { return ((Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).Status -eq 'Valid') }
    catch { return $false }
}

function Get-AXESignatureInfo {
    # Detalle para el informe (quien firma, si lleva timestamp). Nunca lanza.
    param([string]$Path)
    $out = [pscustomobject]@{ Path=$Path; Valid=$false; Status='NotChecked'; Signer=$null; TimeStamped=$false }
    if([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){
        $out.Status = 'NotFound'; return $out
    }
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $out.Status      = [string]$s.Status
        $out.Valid       = ($s.Status -eq 'Valid')
        $out.Signer      = if($s.SignerCertificate){ $s.SignerCertificate.Subject } else { $null }
        $out.TimeStamped = [bool]$s.TimeStamperCertificate
    } catch { $out.Status = 'Error' }
    $out
}

# --- Checksums ----------------------------------------------------------------------------

function New-AXEChecksums {
    # Formato coreutils ('<sha256>  <nombre>', dos espacios) para que se pueda verificar con
    # `sha256sum -c SHA256SUMS` desde cualquier Linux/WSL sin fiarse de una herramienta
    # nuestra. Determinista: orden ordinal por nombre, hex en minusculas, LF y UTF-8 SIN BOM.
    # Dos ejecuciones sobre los mismos ficheros dan bytes identicos, que es lo que permite
    # comprobar en CI que el release no derivo.
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$OutFile,
        [string[]]$Exclude = @('SHA256SUMS','SHA256SUMS.sig')
    )
    if(-not (Test-Path -LiteralPath $Dir -PathType Container)){ throw "New-AXEChecksums: no existe el directorio '$Dir'" }
    if(-not $OutFile){ $OutFile = Join-Path $Dir 'SHA256SUMS' }
    $files = @(Get-ChildItem -LiteralPath $Dir -File |
               Where-Object { $Exclude -notcontains $_.Name } |
               Sort-Object { $_.Name })
    $lines = foreach($f in $files){
        '{0}  {1}' -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $f.Name
    }
    $text = if(@($lines).Count){ (@($lines) -join "`n") + "`n" } else { '' }
    [IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding $false))
    Write-AXEUpdLog "SHA256SUMS generado sobre $(@($files).Count) ficheros de '$Dir'"
    $OutFile
}

function Get-AXEChecksumFor {
    # Extrae el hash de UN nombre concreto del texto de un SHA256SUMS. $null si no esta: quien
    # llama debe negarse a instalar, nunca asumir que "no listado" equivale a "correcto".
    param([string]$SumsText,[string]$Name)
    if([string]::IsNullOrWhiteSpace($SumsText) -or [string]::IsNullOrWhiteSpace($Name)){ return $null }
    foreach($line in ($SumsText -split "`r?`n")){
        # El '*' opcional es el marcador de modo binario de coreutils.
        if($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$'){
            if($Matches[2] -eq $Name){ return $Matches[1].ToLowerInvariant() }
        }
    }
    $null
}

function Test-AXEChecksumFile {
    # Comprueba UN fichero contra el hash esperado. Comparacion ordinal sobre hex, no el -eq
    # de PowerShell sobre objetos. $false ante cualquier duda.
    param([string]$Path,[string]$Expected)
    if([string]::IsNullOrWhiteSpace($Expected)){ return $false }
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ return $false }
    try { $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return $false }
    [string]::Equals($actual, $Expected, [StringComparison]::OrdinalIgnoreCase)
}

function Test-AXEChecksums {
    # Verifica un directorio entero contra su SHA256SUMS. Devuelve la LISTA de problemas
    # (vacia = todo OK), no un bool: si algo falla hay que poder decir QUE fallo.
    param([Parameter(Mandatory)][string]$Dir,[string]$SumsPath)
    if(-not $SumsPath){ $SumsPath = Join-Path $Dir 'SHA256SUMS' }
    $bad = New-Object System.Collections.ArrayList
    if(-not (Test-Path -LiteralPath $SumsPath -PathType Leaf)){ [void]$bad.Add("falta $SumsPath"); return $bad.ToArray() }
    $text = Get-Content -LiteralPath $SumsPath -Raw -Encoding UTF8
    $seen = 0
    foreach($line in ($text -split "`r?`n")){
        if([string]::IsNullOrWhiteSpace($line)){ continue }
        if($line -notmatch '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$'){ [void]$bad.Add("linea ilegible: '$line'"); continue }
        $seen++
        $hash = $Matches[1]; $name = $Matches[2]
        $p = Join-Path $Dir $name
        if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ [void]$bad.Add("listado pero ausente: $name"); continue }
        if(-not (Test-AXEChecksumFile $p $hash)){ [void]$bad.Add("hash no cuadra: $name") }
    }
    if($seen -eq 0){ [void]$bad.Add('SHA256SUMS vacio') }
    $bad.ToArray()
}

# --- SBOM ---------------------------------------------------------------------------------

function New-AXESbom {
    # CycloneDX 1.5 a mano (~40 lineas) en vez de traer cyclonedx-cli: seria una dependencia
    # binaria de terceros en el pipeline de release, justo la clase de cosa que este
    # subproyecto existe para no tener. El unico componente de terceros que AXE redistribuye
    # es el SDK de WebView2 (3 DLL); PresentMon NO se vendoriza (lo aporta el usuario) y por
    # eso no aparece aqui: un SBOM que lista lo que no envias es un SBOM que miente.
    param(
        [Parameter(Mandatory)][string]$Root,     # raiz del repo (donde vive webview2/)
        [Parameter(Mandatory)][string]$Version,  # version de AXE
        [string]$OutFile
    )
    if(-not $OutFile){ $OutFile = Join-Path $Root 'sbom.json' }
    $components = New-Object System.Collections.ArrayList

    $wv = Join-Path $Root 'webview2'
    if(Test-Path -LiteralPath $wv){
        foreach($f in @(Get-ChildItem -LiteralPath $wv -Recurse -File -Filter '*.dll' | Sort-Object { $_.Name })){
            $fv = $null
            try { $fv = $f.VersionInfo.FileVersion } catch {}
            if([string]::IsNullOrWhiteSpace($fv)){ $fv = 'unknown' } else { $fv = $fv.Trim() }
            [void]$components.Add([ordered]@{
                type      = 'library'
                name      = $f.BaseName
                version   = $fv
                publisher = 'Microsoft Corporation'
                purl      = ('pkg:nuget/Microsoft.Web.WebView2@{0}' -f $fv)
                hashes    = @(@{ alg='SHA-256'; content=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
                # Licencia PROPIETARIA con permiso de redistribucion, no OSS. Se declara tal
                # cual: poner 'MIT' aqui porque queda mas limpio seria falsear el SBOM.
                licenses  = @(@{ license = @{ name = 'Microsoft Software License Terms - Microsoft Edge WebView2 SDK (redistributable)' } })
            })
        }
    }

    # serialNumber DETERMINISTA: UUID derivado del sha256 de (version + componentes). Un
    # [guid]::NewGuid() haria que dos SBOM del MISMO codigo salieran distintos, y entonces no
    # se podria comprobar en CI que el release no derivo.
    $seed = ($Version + '|' + ((@($components) | ForEach-Object { '{0}@{1}:{2}' -f $_.name,$_.version,$_.hashes[0].content }) -join ';'))
    $sha  = [Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed)) } finally { $sha.Dispose() }
    $uuid = [guid]::new([byte[]]$h[0..15])

    $bom = [ordered]@{
        bomFormat    = 'CycloneDX'
        specVersion  = '1.5'
        serialNumber = "urn:uuid:$uuid"
        version      = 1
        metadata     = [ordered]@{
            # Unico campo NO determinista del documento, y lo exige el formato.
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture)
            component = [ordered]@{
                type     = 'application'
                name     = 'AXE'
                version  = $Version
                purl     = "pkg:github/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)@$Version"
                licenses = @(@{ license = @{ id = 'MIT' } })
            }
        }
        components   = @($components)
    }
    [IO.File]::WriteAllText($OutFile, ($bom | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
    Write-AXEUpdLog "sbom.json generado con $(@($components).Count) componentes de terceros"
    $OutFile
}

# --- Release remoto -----------------------------------------------------------------------

function ConvertFrom-AXEReleaseJson {
    # Separado de la llamada de red A POSTA: asi el parseo se testea con un fixture local y la
    # CI no necesita salir a internet (misma politica que Fps.Tests con PresentMon).
    param($Release)
    if(-not $Release -or [string]::IsNullOrWhiteSpace([string]$Release.tag_name)){ return $null }
    $assets = @()
    foreach($a in @($Release.assets)){
        if([string]::IsNullOrWhiteSpace([string]$a.name)){ continue }
        $size = 0L; try { $size = [int64]$a.size } catch {}
        $assets += [pscustomobject]@{
            Name = [string]$a.name
            Url  = [string]$a.browser_download_url
            Size = $size
        }
    }
    [pscustomobject]@{
        Tag         = [string]$Release.tag_name
        Version     = ([string]$Release.tag_name) -replace '^[vV]',''
        PublishedAt = [string]$Release.published_at
        PreRelease  = [bool]$Release.prerelease
        Assets      = $assets
    }
}

function Get-AXELatestRelease {
    # GET publico a la API de GitHub: sin token, sin telemetria, sin enviar nada del equipo.
    # Devuelve $null ante CUALQUIER problema -sin red, rate limit, JSON raro-: comprobar
    # actualizaciones no puede tumbar la herramienta.
    param([string]$Uri)
    if(-not $Uri){ $Uri = "https://api.github.com/repos/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/latest" }
    try {
        # PS 5.1 negocia SSL3/TLS1.0 por defecto contra api.github.com y falla.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        $r = Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 20 -ErrorAction Stop `
                -Headers @{ 'User-Agent' = 'AXE-Updater'; 'Accept' = 'application/vnd.github+json' }
    } catch {
        Write-AXEUpdLog "No pude consultar releases: $($_.Exception.Message)" 'WARN'
        return $null
    }
    ConvertFrom-AXEReleaseJson $r
}

function Test-AXEAssetUrl {
    # La URL tiene que ser https, de un host de GitHub conocido Y (en github.com) apuntar a
    # owner/repo. Aunque la respuesta de la API llegara manipulada, no se descarga de un
    # dominio arbitrario.
    param([string]$Url)
    if([string]::IsNullOrWhiteSpace($Url)){ return $false }
    $u = $null
    if(-not [uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$u)){ return $false }
    if($u.Scheme -ne 'https'){ return $false }
    if($script:AXEUpdateHosts -notcontains $u.Host){ return $false }
    # En los hosts de CDN el owner/repo no va en la ruta (es un blob opaco firmado por
    # GitHub), asi que ahi basta el host: el enlace lo emitio la propia API de ESTE repo.
    if($u.Host -eq 'github.com' -and $u.AbsolutePath -notlike "/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/*"){ return $false }
    $true
}

# --- Updater ------------------------------------------------------------------------------

function Invoke-AXEUpdate {
    <#
      Estados devueltos (Status):
        current    ya estas en la ultima
        available  hay una nueva (modo -Check)
        updated    descargada, VERIFICADA y reemplazada
        refused    hay una nueva pero NO se puede verificar -> no se toca nada
        error      no se pudo comprobar (sin red, API rara, version ilegible, escritura fallida)
      Nunca lanza: quien llama imprime .Message y sale con el codigo que quiera.
    #>
    param(
        [switch]$Check,
        [string]$Target,          # fichero a reemplazar. Default: el AXE.ps1 en ejecucion.
        [object]$Release          # inyectable para test; si falta se consulta la API.
    )
    $current = if($script:AXEVersion){ [string]$script:AXEVersion } else { '0.0.0' }
    $mk = { param($s,$l,$m) [pscustomobject]@{ Status=$s; Current=$current; Latest=$l; Message=$m } }

    if(-not $Release){ $Release = Get-AXELatestRelease }
    if(-not $Release){ return (& $mk 'error' $null 'No pude comprobar actualizaciones (sin red, o la API de GitHub no respondio). No se ha tocado nada.') }

    $cmp = Compare-AXEVersion $current $Release.Version
    if($null -eq $cmp){ return (& $mk 'error' $Release.Version "No entiendo alguna de las dos versiones (local '$current', remota '$($Release.Version)'). No se ha tocado nada.") }
    if($cmp -ge 0){ return (& $mk 'current' $Release.Version "Estas en la ultima version ($current).") }

    if($Check){ return (& $mk 'available' $Release.Version "Hay una version nueva: $current -> $($Release.Version). Instalala con:  AXE -Update") }

    if(-not $Target){ $Target = $PSCommandPath }
    if([string]::IsNullOrWhiteSpace($Target) -or -not (Test-Path -LiteralPath $Target -PathType Leaf)){
        return (& $mk 'error' $Release.Version 'No pude localizar el AXE.ps1 a reemplazar. Descarga el release a mano.')
    }

    $asset = @($Release.Assets | Where-Object Name -eq 'AXE.ps1')    | Select-Object -First 1
    $sums  = @($Release.Assets | Where-Object Name -eq 'SHA256SUMS') | Select-Object -First 1
    if(-not $asset -or -not $sums){
        return (& $mk 'refused' $Release.Version "El release $($Release.Tag) no trae AXE.ps1 + SHA256SUMS. No se instala nada sin las dos cosas.")
    }
    foreach($a in @($asset,$sums)){
        if(-not (Test-AXEAssetUrl $a.Url)){
            return (& $mk 'refused' $Release.Version "La URL de '$($a.Name)' no apunta al repo oficial. Descarga abortada.")
        }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('axe_upd_{0}' -f [guid]::NewGuid())
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        $newPs   = Join-Path $tmp 'AXE.ps1'
        $newSums = Join-Path $tmp 'SHA256SUMS'
        try {
            Invoke-WebRequest -Uri $asset.Url -OutFile $newPs   -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
            Invoke-WebRequest -Uri $sums.Url  -OutFile $newSums -TimeoutSec 60  -UseBasicParsing -ErrorAction Stop
        } catch {
            return (& $mk 'error' $Release.Version "Fallo la descarga: $($_.Exception.Message). No se ha tocado nada.")
        }

        # (1) INTEGRIDAD: el fichero llego entero.
        $want = Get-AXEChecksumFor (Get-Content -LiteralPath $newSums -Raw -Encoding UTF8) 'AXE.ps1'
        if(-not $want){ return (& $mk 'refused' $Release.Version 'El SHA256SUMS del release no lista AXE.ps1. Abortado sin tocar nada.') }
        if(-not (Test-AXEChecksumFile $newPs $want)){
            return (& $mk 'refused' $Release.Version 'El SHA256 del AXE.ps1 descargado NO coincide con el publicado. Abortado sin tocar nada.')
        }

        # (2) AUTENTICIDAD: quien lo firmo. Es lo unico que el checksum NO puede dar, porque
        #     ambos ficheros vienen del mismo release. Sin firma valida NO se reemplaza: el
        #     destino es escribible por el usuario y AXE.bat lo ejecuta ELEVADO despues.
        if(-not (Test-AXESignature $newPs)){
            return (& $mk 'refused' $Release.Version @"
El AXE.ps1 de $($Release.Tag) no lleva firma Authenticode valida: no se reemplaza nada.
El checksum SI cuadra, pero viaja en el mismo release que el fichero, asi que prueba que
llego entero, no QUIEN lo publico. Como AXE se ejecuta elevado, reemplazarlo sin firma
convertiria al updater en la via de escalada de privilegios que el resto del proyecto evita.
Descarga el release a mano si quieres continuar:
  https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/tag/$($Release.Tag)
"@)
        }

        # (3) REEMPLAZO ATOMICO: se escribe al lado del destino (mismo volumen => Move-Item es
        #     un rename, no una copia a medias) y se sustituye de una. Nunca queda un AXE.ps1
        #     truncado si el proceso muere en medio.
        $stage = "$Target.new"
        try {
            Copy-Item -LiteralPath $newPs -Destination $stage -Force -ErrorAction Stop
            Move-Item -LiteralPath $stage -Destination $Target -Force -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
            return (& $mk 'error' $Release.Version "Verificado pero no pude escribir en '$Target': $($_.Exception.Message). Cierra AXE y reintenta.")
        }
        Write-AXEUpdLog "Actualizado $current -> $($Release.Version) (firma y checksum verificados)"
        return (& $mk 'updated' $Release.Version "Actualizado a $($Release.Version). Firma y checksum verificados. Reinicia AXE.")
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}


# >>>>> MODULE: 44-latency.ps1 >>>>>
# =====================================================
# REGION 10f - LATENCIA DEL SISTEMA: SONDEO DEL RATON Y TIEMPO EN DPC
# =====================================================
#
# POR QUE EXISTE: 35-diag cubre el hardware MAL CONFIGURADO (XMP, canales, Hz, disco). Quedan
# dos fuentes de latencia grandes que no son ni un tweak ni una pieza mal puesta, y que el
# catalogo entero no puede tocar:
#
#   Sondeo del raton   Un raton a 125 Hz manda su posicion cada 8 ms; a 1000 Hz, cada 1 ms.
#                      Son 7 ms de retardo aniadidos a CADA movimiento, antes de que el juego
#                      se entere. Ningun tweak del registro compensa eso.
#   Tiempo en DPC      Un driver que se pasa de tiempo en su rutina diferida bloquea el nucleo
#                      donde corre. Es la otra gran familia de tirones: el FPS medio sale bien
#                      y aun asi la imagen da saltos.
#
# DIVISION PURO/HARDWARE, la misma de 33-fps y 35-diag:
#   Measure-*  -> tocan hardware o cronometran. No testeables en CI.
#   Get-*      -> PURAS. Reciben muestras, deciden. Testeables sin raton y sin drivers.
# Si el juicio viviera dentro de la medicion solo se podria probar en la maquina del que lo
# escribio, o sea nunca.
#
# LIMITE DECLARADO DEL MODULO DE DPC, y es importante: aqui se mide el TIEMPO TOTAL en DPC,
# no la duracion de cada DPC ni quien la causo. Un driver con DPCs raras pero de 2 ms produce
# un tiron audible y sale con un porcentaje ridiculo. Atribuir por driver exige consumir ETW
# (kernel logger) y resolver direcciones contra los modulos cargados; eso no se puede hacer en
# PowerShell sin meter un binario de terceros en el que haya que confiar a ciegas, que es
# justo lo que este proyecto le reprocha a los optimizadores de pago. Asi que se mide lo que se
# puede medir con honestidad y se DICE lo que falta, en vez de fingir un LatencyMon.

# Rangos de sondeo estandar de un raton USB. bInterval del endpoint HID: 8 ms, 4, 2, 1, y los
# 0.5/0.25/0.125 ms de los inalambricos de competicion. Se usan para "encajar" la medida: una
# lectura de 987 Hz es un raton de 1000 Hz con muestras perdidas, no un raton de 987 Hz.
$script:AXEMouseRates = @(125, 250, 500, 1000, 2000, 4000, 8000)

# Tolerancia del encaje. 20% cubre la perdida tipica de muestras sin llegar a confundir dos
# escalones contiguos: entre 500 y 1000 hay un factor 2, muy por encima del 20%.
$script:AXEMouseSnapTol = 0.20

# Minimo de intervalos para afirmar algo. Por debajo, el resultado es UNKNOWN y se dice por que.
# 30 muestras a 125 Hz son 0.24 s de movimiento real: si el usuario no movio el raton, se nota.
$script:AXEMouseMinSamples = 30

# Umbral de tiempo en DPC por nucleo. Por encima de esto un nucleo pasa tanto rato atendiendo
# rutinas diferidas de drivers que el hilo del juego que le toque sufre. Es un umbral de la
# industria (Process Explorer pinta rojo por ahi), no una medida de esta maquina.
$script:AXEDpcBadPct  = 3.0
$script:AXEIsrBadPct  = 2.0

# --- Capa nativa ----------------------------------------------------------------------
# Tipo APARTE de AXE.Native (32-measure): Add-Type no puede aniadir miembros a un tipo ya
# cargado, y 32-measure se carga antes. C# 5 compat-safe (csc de PS 5.1 + Roslyn de PS 7):
# sin var implicito en campos, sin interpolacion de cadenas, sin record.
if(-not ('AXE.Lat' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace AXE {
  [StructLayout(LayoutKind.Sequential)]
  public struct LatPoint { public int X; public int Y; }

  // SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION. DpcTime e InterruptTime son SUBCONJUNTOS de
  // KernelTime, y KernelTime YA INCLUYE IdleTime: por eso el denominador del porcentaje es
  // (Kernel + User) y no (Kernel + User + Idle), que contaria el reposo dos veces.
  [StructLayout(LayoutKind.Sequential)]
  public struct LatCpuPerf {
    public long IdleTime; public long KernelTime; public long UserTime;
    public long DpcTime;  public long InterruptTime; public uint InterruptCount;
  }

  public static class Lat {
    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out LatPoint p);

    [DllImport("ntdll.dll")]
    private static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);

    private const int SystemProcessorPerformanceInformation = 8;

    // Muestrea los intervalos entre CAMBIOS de la posicion del cursor.
    //
    // POR QUE ASI y no con GetMouseMovePointsEx: esa API devuelve el historial con marca de
    // tiempo, pero exige encajar un punto semilla exacto contra su buffer interno y falla con
    // -1 en cuanto el punto no esta (escalado de DPI, cursor movido por otra cosa). Esto es
    // un sondeo directo: si el cursor cambio de sitio, el raton acaba de reportar. El bucle
    // debe ser NATIVO por el mismo motivo que el jitter de 32-measure: un bucle de PowerShell
    // mediria al interprete, no al raton.
    //
    // Quema un nucleo mientras dura. Es a proposito y es corto: sin busy-wait no se puede
    // muestrear por encima de la frecuencia que se quiere medir.
    public static double[] SampleCursorIntervals(int ms) {
      if (ms < 100) ms = 100;
      List<double> outv = new List<double>();
      LatPoint last; GetCursorPos(out last);
      double toMs = 1000.0 / (double)Stopwatch.Frequency;
      long t0 = Stopwatch.GetTimestamp();
      long tLast = t0;
      long deadline = t0 + (long)((ms / 1000.0) * Stopwatch.Frequency);
      LatPoint cur;
      while (Stopwatch.GetTimestamp() < deadline) {
        GetCursorPos(out cur);
        if (cur.X != last.X || cur.Y != last.Y) {
          long tn = Stopwatch.GetTimestamp();
          outv.Add((tn - tLast) * toMs);
          tLast = tn; last = cur;
        }
      }
      return outv.ToArray();
    }

    // Instantanea de contadores por CPU logica. Devuelve un array plano de 5 valores por CPU:
    // {Idle, Kernel, User, Dpc, Interrupt} en unidades de 100 ns. Plano y no un array de
    // structs porque PowerShell marshalea arrays de long sin ceremonia.
    public static long[] ProcessorPerf() {
      int n = Environment.ProcessorCount;
      int sz = Marshal.SizeOf(typeof(LatCpuPerf));
      IntPtr buf = Marshal.AllocHGlobal(sz * n);
      try {
        int ret;
        int st = NtQuerySystemInformation(SystemProcessorPerformanceInformation, buf, sz * n, out ret);
        if (st != 0) return new long[0];
        int have = ret / sz;
        if (have > n) have = n;
        long[] outv = new long[have * 5];
        for (int i = 0; i < have; i++) {
          IntPtr p = new IntPtr(buf.ToInt64() + (long)(i * sz));
          LatCpuPerf c = (LatCpuPerf)Marshal.PtrToStructure(p, typeof(LatCpuPerf));
          outv[i * 5 + 0] = c.IdleTime;
          outv[i * 5 + 1] = c.KernelTime;
          outv[i * 5 + 2] = c.UserTime;
          outv[i * 5 + 3] = c.DpcTime;
          outv[i * 5 + 4] = c.InterruptTime;
        }
        return outv;
      } finally { Marshal.FreeHGlobal(buf); }
    }
  }
}
'@ -ErrorAction SilentlyContinue
}

# =====================================================
# RATON
# =====================================================

function Measure-AXEMouseIntervals {
    # IMPURA: cronometra el raton de verdad. Devuelve intervalos en ms entre reportes.
    # Necesita que el usuario MUEVA el raton: sin movimiento no hay reportes que cronometrar,
    # y devolver un array corto es la respuesta correcta (Get-AXEMouseRate lo convierte en
    # UNKNOWN con motivo, no en un numero inventado).
    param([int]$Seconds = 3)
    if($Seconds -lt 1){ $Seconds = 1 }
    if($Seconds -gt 15){ $Seconds = 15 }
    try { ,([AXE.Lat]::SampleCursorIntervals($Seconds * 1000)) } catch { ,@() }
}

function Get-AXEMouseRate {
    # PURA: mismos intervalos dentro, mismo veredicto fuera.
    #
    # SE USA LA MODA, y las dos alternativas obvias se probaron y FALLAN por lados opuestos:
    #
    #   Mediana        Un movimiento lento produce reportes con delta 0 px que no mueven el
    #                  cursor y se ven como un intervalo del doble o del triple. La mediana se
    #                  los traga y un raton de 1000 Hz movido despacio sale como uno de 300.
    #   Percentil 10   Fue la primera implementacion, con el argumento de que el ruido solo
    #                  puede ALARGAR intervalos, nunca acortarlos. Es falso: el stack de
    #                  entrada de Windows entrega reportes A RAFAGAS tras una pausa de
    #                  planificacion, y esa rafaga son intervalos casi cero. MEDIDO: con un
    #                  generador sintetico a 500 Hz el P10 devolvia 1000, y a 1000 devolvia
    #                  2000. Sobreestima justo el doble, que es el error mas enganioso posible
    #                  porque 2x cae en otro escalon estandar y encaja igual de "limpio".
    #
    # La moda no tiene ninguno de los dos problemas: el periodo REAL es, por definicion, el
    # intervalo que mas veces aparece cuando el movimiento es continuo. Los reportes perdidos
    # se acumulan en 2T y 3T (modas menores) y las rafagas cerca de 0 (otra moda menor), y
    # ninguna de las dos le gana a la fundamental.
    param([object[]]$Intervals)

    $raw = @($Intervals)
    # El primer intervalo va desde el arranque del bucle hasta el primer movimiento: mide
    # cuanto tardo el usuario en reaccionar, no el raton. Fuera siempre.
    if($raw.Count -gt 0){ $raw = @($raw[1..($raw.Count-1)]) }
    $ok = @($raw | Where-Object { $null -ne $_ -and [double]$_ -gt 0 } | ForEach-Object { [double]$_ })

    if($ok.Count -lt $script:AXEMouseMinSamples){
        return [pscustomobject]@{
            Hz=$null; RawHz=$null; Snapped=$false; Samples=$ok.Count; PeriodMs=$null
            Confidence='desconocida'
            Reason=("solo $($ok.Count) reportes utiles (hacen falta $($script:AXEMouseMinSamples)): hay que mover el raton sin parar mientras mide.")
        }
    }

    # Moda por histograma de anchura RELATIVA (bins del 12% en escala logaritmica), no absoluta.
    # Absoluta no sirve: 1 ms y 8 ms son el mismo fenomeno a dos escalas, y un bin fijo que
    # separe bien a 8 ms mete todo el rango de 1 ms en una sola cubeta. El 12% es mas estrecho
    # que la distancia entre escalones estandar (que es 2x) y mas ancho que el jitter tipico
    # del planificador, asi que separa 500 de 1000 sin partir en dos la moda de un mismo raton.
    $bins = @{}
    $lb = [math]::Log(1.12)
    foreach($v in $ok){
        $k = [int][math]::Floor([math]::Log($v) / $lb)
        if($bins.ContainsKey($k)){ [void]$bins[$k].Add($v) } else { $bins[$k] = (New-Object System.Collections.Generic.List[double]); [void]$bins[$k].Add($v) }
    }
    $bestBin = $null; $bestN = 0
    foreach($k in $bins.Keys){
        $n = $bins[$k].Count
        # Empate a favor del bin MAS LARGO: entre dos cubetas igual de pobladas, la corta es
        # una rafaga y la larga es el periodo. Preferir la corta es sobreestimar, que es el
        # error que se acaba de corregir.
        if($n -gt $bestN -or ($n -eq $bestN -and $null -ne $bestBin -and $k -gt $bestBin)){ $bestN = $n; $bestBin = $k }
    }
    $modeVals = @($bins[$bestBin] | Sort-Object)
    $mode = [double]$modeVals[[int][math]::Floor($modeVals.Count / 2)]
    if($mode -le 0){
        return [pscustomobject]@{
            Hz=$null; RawHz=$null; Snapped=$false; Samples=$ok.Count; PeriodMs=$null
            Confidence='desconocida'; Reason='los intervalos medidos son cero: el reloj no dio resolucion suficiente.'
        }
    }

    $rawHz = 1000.0 / $mode
    # Encaje al escalon estandar mas cercano en proporcion (no en distancia absoluta): entre
    # 125 y 250 la distancia absoluta enganiaria a favor del escalon alto.
    $best = $null; $bestRel = [double]::MaxValue
    foreach($r in $script:AXEMouseRates){
        $rel = [math]::Abs($rawHz - $r) / [double]$r
        if($rel -lt $bestRel){ $bestRel = $rel; $best = $r }
    }
    $snapped = ($bestRel -le $script:AXEMouseSnapTol)
    $hz = if($snapped){ [int]$best } else { [int][math]::Round($rawHz) }

    # Confianza: cuantas muestras hay y como de limpio quedo el encaje. No se promete precision
    # que el metodo no da; con pocas muestras se dice "parcial" aunque el numero salga redondo.
    # La moda tambien tiene que ser MAYORITARIA de verdad. Si la cubeta ganadora se lleva menos
    # de un tercio de las muestras, la distribucion esta repartida (movimiento a tirones, o el
    # cursor lo movio algo que no es el raton) y el numero no se sostiene: sale 'parcial'
    # aunque haya miles de muestras.
    $share = [double]$bestN / [double]$ok.Count
    $conf = if(-not $snapped){ 'parcial (no encaja en ningun sondeo estandar; puede ser un raton raro o poco movimiento)' }
            elseif($share -lt 0.33){ 'parcial (los intervalos salen muy repartidos: mueve el raton de forma continua)' }
            elseif($ok.Count -ge 200){ 'cierta' }
            else { 'parcial (pocas muestras)' }

    [pscustomobject]@{
        Hz=$hz; RawHz=[math]::Round($rawHz,1); Snapped=$snapped; Samples=$ok.Count
        PeriodMs=[math]::Round($mode,3); ModeShare=[math]::Round($share,3)
        Confidence=$conf; Reason=$null
    }
}

function Get-AXEMouseSettings {
    # IMPURA: lee el registro. Ajustes del puntero que SI son estaticos y SI se leen siempre,
    # con raton parado y en modo headless. Cada uno en su try: en una maquina por la que ya
    # paso otro optimizador cualquiera de estas claves puede no existir.
    $s = [ordered]@{ Accel=$null; Sensitivity=$null; QueueSize=$null }
    try {
        $m = Get-ItemProperty 'HKCU:\Control Panel\Mouse' -ErrorAction Stop
        # MouseSpeed es el interruptor de "Mejorar la precision del puntero" (aceleracion).
        # 0 = apagado. 1 y 2 son los dos escalones de aceleracion.
        if($null -ne $m.MouseSpeed){ $s.Accel = [int]$m.MouseSpeed }
        # MouseSensitivity 10 = 1:1 (el punto medio del deslizador, 6 de 11). Cualquier otro
        # valor multiplica los contadores del raton, o sea que duplica o SE SALTA pixeles.
        if($null -ne $m.MouseSensitivity){ $s.Sensitivity = [int]$m.MouseSensitivity }
    } catch {}
    try {
        $q = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\mouclass\Parameters' -ErrorAction Stop
        if($null -ne $q.MouseDataQueueSize){ $s.QueueSize = [int]$q.MouseDataQueueSize }
    } catch {}
    [pscustomobject]$s
}

function Get-AXEMouseFindings {
    # PURA. Devuelve hallazgos con la MISMA forma que 35-diag (New-AXEDiagFinding) para que el
    # render y la GUI no tengan que aprender un segundo formato.
    param($Rate, $Settings)
    $out = New-Object System.Collections.Generic.List[object]

    # --- Sondeo -------------------------------------------------------------------------
    if($null -eq $Rate -or $null -eq $Rate.Hz){
        $why = if($Rate -and $Rate.Reason){ $Rate.Reason } else { 'no se midio el sondeo del raton.' }
        [void]$out.Add((New-AXEDiagFinding 'mouse_rate' 'UNKNOWN' 'Sondeo del raton' `
            $why 'Vuelve a medir moviendo el raton en circulos sin parar durante toda la cuenta.' `
            '1-7 ms de input lag' 'desconocida'))
    } elseif($Rate.Hz -lt 500){
        $ms = [math]::Round(1000.0 / $Rate.Hz, 1)
        $gain = [math]::Round($ms - 1.0, 1)
        [void]$out.Add((New-AXEDiagFinding 'mouse_rate' 'BAD' 'Sondeo del raton' `
            "Reporta a $($Rate.Hz) Hz: manda su posicion cada $ms ms. A 1000 Hz seria cada 1 ms." `
            "Software del raton (Logitech G HUB, Razer Synapse, etc.) > tasa de sondeo > 1000 Hz. Si no tiene software, mira si trae un interruptor fisico. Un raton que no pasa de 125 Hz es de los pocos casos en que cambiar de raton se nota de verdad." `
            "${gain} ms de input lag" $Rate.Confidence))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'mouse_rate' 'OK' 'Sondeo del raton' `
            "Reporta a $($Rate.Hz) Hz (cada $([math]::Round(1000.0/$Rate.Hz,2)) ms)." `
            $null '1-7 ms de input lag' $Rate.Confidence))
    }

    # --- Aceleracion --------------------------------------------------------------------
    # Esto no es folclore: con la aceleracion puesta, el MISMO movimiento fisico produce
    # distinta distancia en pantalla segun la velocidad del gesto. La punteria se aprende por
    # memoria muscular, y la memoria muscular necesita que la relacion sea constante.
    if($null -eq $Settings -or $null -eq $Settings.Accel){
        [void]$out.Add((New-AXEDiagFinding 'mouse_accel' 'UNKNOWN' 'Aceleracion del puntero' `
            'No se pudo leer HKCU\Control Panel\Mouse.' `
            'Configuracion > Bluetooth y dispositivos > Raton > Configuracion adicional > Opciones de puntero.' `
            'consistencia de punteria' 'desconocida'))
    } elseif($Settings.Accel -ne 0){
        [void]$out.Add((New-AXEDiagFinding 'mouse_accel' 'BAD' 'Aceleracion del puntero' `
            '"Mejorar la precision del puntero" esta ACTIVADA. El mismo gesto fisico recorre distinta distancia segun lo rapido que lo hagas.' `
            'Configuracion > Raton > Configuracion adicional > Opciones de puntero > desmarca "Mejorar la precision del puntero".' `
            'consistencia de punteria' 'cierta (es el ajuste, leido del registro)'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'mouse_accel' 'OK' 'Aceleracion del puntero' `
            'Desactivada: la relacion entre gesto y pantalla es constante.' `
            $null 'consistencia de punteria' 'cierta'))
    }

    # --- Escalado 1:1 -------------------------------------------------------------------
    if($null -eq $Settings -or $null -eq $Settings.Sensitivity){
        [void]$out.Add((New-AXEDiagFinding 'mouse_scale' 'UNKNOWN' 'Escalado del puntero' `
            'No se pudo leer la sensibilidad del puntero.' `
            'Opciones de puntero > deja el deslizador de velocidad en el punto medio (6 de 11).' `
            'pixeles saltados' 'desconocida'))
    } elseif($Settings.Sensitivity -ne 10){
        [void]$out.Add((New-AXEDiagFinding 'mouse_scale' 'BAD' 'Escalado del puntero' `
            "El deslizador de velocidad no esta en el punto medio (valor $($Settings.Sensitivity), 1:1 es 10). Windows multiplica los contadores del raton: duplica o se salta pixeles." `
            'Opciones de puntero > pon el deslizador en el 6 de 11 (el punto medio) y ajusta la sensibilidad DENTRO del juego.' `
            'pixeles saltados' 'cierta (es el ajuste, leido del registro)'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'mouse_scale' 'OK' 'Escalado del puntero' `
            'En 1:1 (punto medio del deslizador): Windows no multiplica los contadores.' `
            $null 'pixeles saltados' 'cierta'))
    }

    $out.ToArray()
}

# =====================================================
# DPC / ISR
# =====================================================

function Get-AXEDpcStats {
    # PURA: recibe dos instantaneas planas de [AXE.Lat]::ProcessorPerf() y devuelve el
    # porcentaje por nucleo. Separada de la medicion para poder probar la aritmetica sin
    # drivers: los numeros de un test son los mismos que los de una maquina real.
    param([object[]]$Before, [object[]]$After)

    $b = @($Before); $a = @($After)
    if($b.Count -eq 0 -or $a.Count -ne $b.Count -or ($b.Count % 5) -ne 0){
        return [pscustomobject]@{ Cpus=@(); MaxDpcPct=$null; MaxIsrPct=$null; TotalDpcPct=$null; TotalIsrPct=$null }
    }

    $n = [int]($b.Count / 5)
    $cpus = New-Object System.Collections.Generic.List[object]
    $sumDpc = 0.0; $sumIsr = 0.0; $sumTot = 0.0
    for($i=0; $i -lt $n; $i++){
        $o = $i * 5
        # Denominador = Kernel + User. KernelTime YA incluye Idle en esta estructura, asi que
        # sumar Idle aparte contaria el reposo dos veces y hundiria todos los porcentajes.
        $dKern = [double]($a[$o+1] - $b[$o+1])
        $dUser = [double]($a[$o+2] - $b[$o+2])
        $dDpc  = [double]($a[$o+3] - $b[$o+3])
        $dInt  = [double]($a[$o+4] - $b[$o+4])
        $tot   = $dKern + $dUser
        if($tot -le 0){ continue }
        $sumDpc += $dDpc; $sumIsr += $dInt; $sumTot += $tot
        [void]$cpus.Add([pscustomobject]@{
            Cpu    = $i
            DpcPct = [math]::Round(100.0 * $dDpc / $tot, 2)
            IsrPct = [math]::Round(100.0 * $dInt / $tot, 2)
        })
    }
    $arr = $cpus.ToArray()
    if($arr.Count -eq 0){
        return [pscustomobject]@{ Cpus=@(); MaxDpcPct=$null; MaxIsrPct=$null; TotalDpcPct=$null; TotalIsrPct=$null }
    }
    [pscustomobject]@{
        Cpus        = $arr
        MaxDpcPct   = ($arr | Measure-Object DpcPct -Maximum).Maximum
        MaxIsrPct   = ($arr | Measure-Object IsrPct -Maximum).Maximum
        TotalDpcPct = [math]::Round(100.0 * $sumDpc / $sumTot, 2)
        TotalIsrPct = [math]::Round(100.0 * $sumIsr / $sumTot, 2)
    }
}

function Measure-AXEDpc {
    # IMPURA: dos instantaneas separadas por $Seconds. No necesita admin ni ETW: los contadores
    # por CPU salen de NtQuerySystemInformation, que es lo mismo que lee el Administrador de
    # tareas para pintar "tiempo de kernel".
    param([int]$Seconds = 5)
    if($Seconds -lt 1){ $Seconds = 1 }
    if($Seconds -gt 60){ $Seconds = 60 }
    $b = @(); $a = @()
    try { $b = @([AXE.Lat]::ProcessorPerf()) } catch { $b = @() }
    if($b.Count -eq 0){
        return [pscustomobject]@{ Cpus=@(); MaxDpcPct=$null; MaxIsrPct=$null; TotalDpcPct=$null; TotalIsrPct=$null; Seconds=$Seconds }
    }
    Start-Sleep -Seconds $Seconds
    try { $a = @([AXE.Lat]::ProcessorPerf()) } catch { $a = @() }
    $st = Get-AXEDpcStats -Before $b -After $a
    $st | Add-Member -NotePropertyName Seconds -NotePropertyValue $Seconds -Force
    $st
}

function Get-AXEDpcFindings {
    # PURA. Mismo formato de hallazgo que 35-diag.
    param($Dpc)
    $out = New-Object System.Collections.Generic.List[object]

    if($null -eq $Dpc -or $null -eq $Dpc.MaxDpcPct){
        [void]$out.Add((New-AXEDiagFinding 'dpc' 'UNKNOWN' 'Tiempo en DPC' `
            'No se pudieron leer los contadores por nucleo.' `
            'Vuelve a intentarlo; si sigue fallando, el sistema esta limitando NtQuerySystemInformation.' `
            'tirones, no FPS medio' 'desconocida'))
        return $out.ToArray()
    }

    $worst = @($Dpc.Cpus | Sort-Object DpcPct -Descending | Select-Object -First 1)
    $wcpu  = if($worst.Count -gt 0){ $worst[0].Cpu } else { 0 }

    if($Dpc.MaxDpcPct -ge $script:AXEDpcBadPct){
        [void]$out.Add((New-AXEDiagFinding 'dpc' 'BAD' 'Tiempo en DPC' `
            "El nucleo $wcpu paso el $($Dpc.MaxDpcPct)% del tiempo en rutinas diferidas de drivers (media de todos: $($Dpc.TotalDpcPct)%). Por encima del $($script:AXEDpcBadPct)% el hilo que caiga en ese nucleo sufre tirones." `
            'Sospecha primero de red y almacenamiento: actualiza el driver de la tarjeta de red y el del chipset desde la web del FABRICANTE del equipo, no desde Windows Update. Para saber QUE driver es hace falta una traza ETW (LatencyMon o xperf); AXE no lo atribuye, ver la nota de abajo.' `
            'tirones, no FPS medio' 'cierta (medido en esta maquina, ventana corta)'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'dpc' 'OK' 'Tiempo en DPC' `
            "Maximo por nucleo $($Dpc.MaxDpcPct)%, media $($Dpc.TotalDpcPct)%. Por debajo del umbral." `
            $null 'tirones, no FPS medio' 'parcial (mide carga total, no la duracion de cada DPC)'))
    }

    if($Dpc.MaxIsrPct -ge $script:AXEIsrBadPct){
        $iworst = @($Dpc.Cpus | Sort-Object IsrPct -Descending | Select-Object -First 1)
        $icpu = if($iworst.Count -gt 0){ $iworst[0].Cpu } else { 0 }
        [void]$out.Add((New-AXEDiagFinding 'isr' 'BAD' 'Tiempo en interrupciones' `
            "El nucleo $icpu paso el $($Dpc.MaxIsrPct)% atendiendo interrupciones de hardware." `
            'Suele ser un dispositivo USB que reinterrumpe o un driver de red antiguo. Desconecta perifericos USB uno a uno y vuelve a medir.' `
            'tirones, no FPS medio' 'cierta (medido en esta maquina, ventana corta)'))
    }

    $out.ToArray()
}

function Format-AXELatency {
    # PURA. Reusa el render de 35-diag para que un hallazgo se lea IGUAL venga de donde venga,
    # y aniade la nota de limite del DPC, que es especifica de este modulo y no del render.
    param([Parameter(Mandatory)]$Findings, [switch]$WithDpcNote)
    $L = New-Object System.Collections.Generic.List[string]
    $note = 'Ninguno se arregla con un tweak del registro: viven en el driver, en el software del raton o en Opciones de puntero de Windows.'
    foreach($line in (Format-AXEDiag -Findings $Findings -Title 'AXE LATENCIA: RATON Y DPC' -BadNote $note)){ [void]$L.Add($line) }
    if($WithDpcNote){
        [void]$L.Add('')
        [void]$L.Add('NOTA SOBRE EL DPC: esto mide CUANTO tiempo total se va en rutinas de drivers,')
        [void]$L.Add('no CUANTO dura cada una ni de QUE driver es. Un driver con DPCs raras pero de')
        [void]$L.Add('2 ms da un porcentaje bajo y aun asi produce tirones. Atribuir por driver exige')
        [void]$L.Add('consumir ETW y resolver simbolos: AXE no lo hace porque necesitaria un binario')
        [void]$L.Add('de terceros, que es justo lo que este proyecto no quiere pedirte que te creas.')
        [void]$L.Add('Si este apartado sale MAL, LatencyMon (gratis) te dice el nombre del driver.')
    }
    $L.ToArray()
}


# >>>>> MODULE: 45-cli.ps1 >>>>>
# =====================================================
# REGION 11 - MODOS CLI (headless)
# =====================================================
# --- HW: en modo headless (CLI) se carga SINCRONO (lo necesita gating/Tests). En modo
#     GUI se DEFIERE a un runspace de fondo (Start-AXEHardwareLoad, region 12) para que
#     la ventana no espere ~3.7s de CIM (Win32_Processor + Get-NetAdapter pagan cold-init WMI).
$script:HW = $null
#     -Diag entra aqui porque Get-AXEDiagFacts reusa $script:HW.IsSSD en vez de recalcularlo.
#     -Benchmark tambien: Get-AXESnapshot mide cobertura via Get-BlockReason, que necesita $HW.
#     Sin el, la metrica 'score' cambiaria entre fases por el orden de carga y no por el sistema.
#     -NetMon tambien: Measure-AXENetwork rotula la medicion con el adaptador y el medio
#     (Wi-Fi/cable) desde $script:HW. Sin el, el informe no diria SOBRE QUE enlace se midio.
#     -Advice es el que mas lo necesita: cruza hechos del hardware (Hz del panel, bateria, VM)
#     con el diagnostico, y Get-AXEAppliedIds llama a Get-BlockReason una vez por tweak.
#     -NetLoad, por lo mismo que -NetMon: rotula la medida con el adaptador y el medio.
#     -Diag lo necesita ademas para dos campos nuevos: ScreenW/ScreenH (el maximo del panel se
#     compara A TU RESOLUCION, no en absoluto) y Cores/Threads (el reparto P/E es aritmetica
#     sobre esos dos). Sin $HW ambos hallazgos degradan a UNKNOWN en vez de mentir.
if($SelfTest -or $List -or $Export -or $Import -or $Measure -or $Score -or $Report -or $TimerSweep -or $Diag -or $Benchmark -or $NetMon -or $Advice -or $NetLoad){
    try { $script:HW = Get-AXEHardware } catch { $script:HW = $null }
}

if($SelfTest){
    # =====================================================
    # MODO SELFTEST (TDD): validacion de integridad. 0 fallos = OK.
    # =====================================================
    $fails = New-Object System.Collections.ArrayList
    $checks = 0

    # S1: cada tweak tiene las 10 claves obligatorias
    $required = 'Id','Cat','Tier','Reboot','Name','Desc','Requires','Test','Apply','Revert'
    foreach($tw in $script:CAT){
        $checks++
        foreach($k in $required){
            $col = @($tw.PSObject.Properties.Name)
            if($col -notcontains $k){ [void]$fails.Add("S1: $($tw.Id) falta clave '$k'") }
        }
    }
    # S2: Ids unicos
    $checks++
    $ids = @($script:CAT | ForEach-Object Id)
    $dup = $ids | Group-Object | Where-Object Count -gt 1
    if($dup){ foreach($d in $dup){ [void]$fails.Add("S2: Id duplicado '$($d.Name)'") } }
    # S3: Tier en {0,1,2}
    $checks++
    foreach($tw in $script:CAT){ if($tw.Tier -notin 0,1,2){ [void]$fails.Add("S3: $($tw.Id) Tier invalido $($tw.Tier)") } }
    # S4: Test/Apply/Revert son scriptblocks
    $checks++
    foreach($tw in $script:CAT){
        if($tw.Test  -isnot [scriptblock]){ [void]$fails.Add("S4: $($tw.Id) Test no es scriptblock") }
        if($tw.Apply -isnot [scriptblock]){ [void]$fails.Add("S4: $($tw.Id) Apply no es scriptblock") }
        if($tw.Revert-isnot [scriptblock]){ [void]$fails.Add("S4: $($tw.Id) Revert no es scriptblock") }
    }
    # S5: Apply != Revert (salvo hardening documentado svc_remotereg)
    $checks++
    foreach($tw in $script:CAT){
        if($tw.Id -eq 'svc_remotereg'){ continue }   # unidireccional intencional
        if($tw.Apply.ToString() -eq $tw.Revert.ToString()){ [void]$fails.Add("S5: $($tw.Id) Apply==Revert (revert inutil / no-op)") }
    }
    # S6: catalogo tiene masa critica
    $checks++
    if($script:CAT.Count -lt 10){ [void]$fails.Add("S6: catalogo con $($script:CAT.Count) tweaks (<10) - roto") }
    # S7: round-trip JSON de startup
    $checks++
    try {
        $tmp = Join-Path $script:AXEData ('selftest_{0}.json' -f [guid]::NewGuid())
        $probe = @(
            [pscustomobject]@{Hive='HKCU';Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';Name='__LW_TEST__';Value='x'}
            [pscustomobject]@{Hive='HKLM';Path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';Name='__LW_TEST2__';Value='y'}
        )
        $probe | ConvertTo-Json -Depth 5 | Set-Content $tmp -Encoding UTF8
        $back = Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        if(@($back).Count -ne 2){ [void]$fails.Add("S7: round-trip JSON perdio elementos (esperado 2, got $(@($back).Count))") }
        Remove-Item $tmp -Force -EA SilentlyContinue
    } catch { [void]$fails.Add("S7: round-trip JSON lanzo excepcion: $($_.Exception.Message)") }
    # S8: gating devuelve null o string
    $checks++
    if($script:HW){
        foreach($tw in $script:CAT){
            $r = Get-BlockReason $tw
            if($r -ne $null -and $r -isnot [string]){ [void]$fails.Add("S8: $($tw.Id) gating devolvio tipo invalido"); break }
        }
    }
    # S9: helpers basicos existen (no codigo muerto / funciones rotas)
    $checks++
    foreach($fn in 'Get-RV','Set-RD','Set-RS','Del-RV','Test-Svc','Get-SvcStart','Set-SvcStart','Backup-RegKey','Get-BlockReason','Read-StartupBackup','Restore-Autorun','Repair-StartupBackup','Invoke-AXEMasterRevertTail'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S9: funcion requerida '$fn' no definida") }
    }
    # S10: WinVer (si un tweak lo usa, debe ser array de enteros 10/11)
    $checks++
    foreach($tw in $script:CAT){
        if($tw.Requires.PSObject.Properties['WinVer']){
            $wv = $tw.Requires.WinVer
            if(-not ($wv -is [array]) -or ($wv | Where-Object { $_ -notin 10,11 }).Count -gt 0){
                [void]$fails.Add("S10: $($tw.Id) WinVer invalido: $($wv -join ',')")
            }
        }
    }
    # S19: coherencia de Requires del ecosistema (§3.2) - claves fabricadas / mal tipadas.
    # Whitelist: cualquier clave desconocida (typo tipo 'MimRam') => FAIL, porque Get-BlockReason
    # la ignoraria en silencio y el tweak quedaria siempre visible (el linter no lo detecta).
    $checks++
    $knownReq = @('MinRam','MaxRam','Desktop','NotLaptop','NotHybrid','AC','Wired','NotHome','Nvidia','WinVer','WinBuild','CpuArch','CpuVendor','HAGS','TamperOff','Defender','NotSMode','NicProp')
    foreach($tw in $script:CAT){
        $rq = $tw.Requires
        if($rq -isnot [hashtable]){ continue }
        foreach($k in $rq.Keys){ if($k -notin $knownReq){ [void]$fails.Add("S19: $($tw.Id) clave Requires desconocida '$k' (typo? no gatea)") } }
        if($rq.ContainsKey('HAGS') -and $tw.Cat -ne 'GPU'){ [void]$fails.Add("S19: $($tw.Id) HAGS solo aplica a Cat=GPU") }
        if($rq.ContainsKey('MinRam')){ $mr=$rq['MinRam']; if(-not ($mr -is [int]) -or $mr -le 0){ [void]$fails.Add("S19: $($tw.Id) MinRam invalido: $mr") } }
        if($rq.ContainsKey('MaxRam')){ $xr=$rq['MaxRam']; if(-not ($xr -is [int]) -or $xr -le 0){ [void]$fails.Add("S19: $($tw.Id) MaxRam invalido: $xr") } }
        # Ventana imposible: con MinRam >= MaxRam el tweak queda bloqueado en TODA maquina y nadie
        # se entera, porque cada clave por separado es valida. Mismo fallo de clase que un typo en
        # el nombre de la clave: gatea siempre y en silencio.
        if($rq.ContainsKey('MinRam') -and $rq.ContainsKey('MaxRam') -and $rq['MinRam'] -ge $rq['MaxRam']){
            [void]$fails.Add("S19: $($tw.Id) ventana de RAM vacia: MinRam=$($rq['MinRam']) >= MaxRam=$($rq['MaxRam'])")
        }
        # NicProp tiene que ser el RegistryKeyword literal de NDIS ('*InterruptModeration'): si no
        # empieza por '*' no casa con ninguna propiedad y el gate bloquearia el tweak siempre.
        if($rq.ContainsKey('NicProp')){
            $np=$rq['NicProp']
            if($np -isnot [string] -or [string]::IsNullOrWhiteSpace($np) -or -not $np.StartsWith('*')){
                [void]$fails.Add("S19: $($tw.Id) NicProp invalido: '$np' (se espera el RegistryKeyword NDIS, p.ej. '*InterruptModeration')")
            }
        }
        foreach($ak in 'CpuArch','CpuVendor','WinBuild'){ if($rq.ContainsKey($ak) -and ($rq[$ak] -isnot [array])){ [void]$fails.Add("S19: $($tw.Id) $ak debe ser array") } }
    }
    # S11: masa critica actualizada (el catalogo crece con cada fusion)
    $checks++
    if($script:CAT.Count -lt 60){ [void]$fails.Add("S11: catalogo con $($script:CAT.Count) tweaks (<60) - posible carga incompleta") }

    # S12: perfiles por-juego (region 10b). Round-trip Add/Remove en store temporal
    # (no toca el store real) + power plans se enumeran + plan activo es un GUID.
    $checks++
    $realBak = $script:ProfilesBak
    try {
        $script:ProfilesBak = Join-Path $script:AXEData ('proftest_{0}.json' -f [guid]::NewGuid())
        if((Read-Profiles).Count -ne 0){ [void]$fails.Add('S12: store temporal no arranca vacio') }
        [void](Add-GameProfile 'test' 'cs2.exe' '381b4222-f694-41f0-9685-ff5bb260df2e' 'Equilibrado')
        $r = Read-Profiles
        if($r.Count -ne 1 -or $r[0].Exe -ne 'cs2' -or $r[0].Name -ne 'test'){ [void]$fails.Add('S12: Add/Read perfil no round-trip') }
        Remove-GameProfile 'test'
        if((Read-Profiles).Count -ne 0){ [void]$fails.Add('S12: Remove perfil no vacia el store') }
        Remove-Item $script:ProfilesBak -Force -EA SilentlyContinue
    } catch { [void]$fails.Add("S12: perfiles lanzaron excepcion: $($_.Exception.Message)") }
    finally { $script:ProfilesBak = $realBak }
    # S12b: funciones de plan de energia presentes y coherentes
    $checks++
    foreach($fn in 'Get-PowerPlans','Get-ActivePlan','Set-ActivePlan','Test-GameRunning','Tick-GameProfiles'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S12b: funcion '$fn' no definida") }
    }
    $ap = Get-ActivePlan
    if($ap -and $ap -notmatch '^[0-9a-fA-F-]{36}$'){ [void]$fails.Add("S12b: plan activo no es GUID: $ap") }

    # S13: timer resolution medible (o null sin lanzar)
    $checks++
    try {
        $tr = Get-AXETimerResolution
        if($tr -ne $null -and ($tr.CurrentMs -isnot [double] -and $tr.CurrentMs -isnot [int] -and $tr.CurrentMs -isnot [decimal])){ [void]$fails.Add("S13: Get-AXETimerResolution.CurrentMs no numerico") }
    } catch { [void]$fails.Add("S13: Get-AXETimerResolution lanzo: $($_.Exception.Message)") }

    # S14: jitter sampler (duracion corta) devuelve stats numericas rapido
    $checks++
    try {
        $jt = Measure-AXEJitter -DurationMs 50
        if($jt.Samples -le 0 -or $jt.P999Ms -lt 0 -or $jt.MaxMs -lt 0){ [void]$fails.Add("S14: Measure-AXEJitter stats invalidas (n=$($jt.Samples))") }
    } catch { [void]$fails.Add("S14: Measure-AXEJitter lanzo: $($_.Exception.Message)") }

    # S15: snapshot devuelve los 5 campos y no lanza (jitter corto)
    $checks++
    try {
        $sn = Get-AXESnapshot -JitterMs 50
        foreach($f in 'Timestamp','Timer','Jitter','TweaksOn','TweaksApplicable'){
            if(-not $sn.PSObject.Properties[$f]){ [void]$fails.Add("S15: snapshot falta campo '$f'") }
        }
    } catch { [void]$fails.Add("S15: Get-AXESnapshot lanzo: $($_.Exception.Message)") }

    # S16: score en [0,100] con snapshot real y con snapshot n/a (parcial), sin lanzar
    $checks++
    try {
        $scReal = Get-AXEScore (Get-AXESnapshot -JitterMs 50)
        if($scReal.Total -lt 0 -or $scReal.Total -gt 100){ [void]$fails.Add("S16: Total fuera de rango: $($scReal.Total)") }
        $naSnap=[pscustomobject]@{Timestamp='x';Timer='n/a';Jitter='n/a';TweaksOn='n/a';TweaksApplicable='n/a'}
        $scNa = Get-AXEScore $naSnap
        if($scNa.Total -lt 0 -or $scNa.Total -gt 100){ [void]$fails.Add("S16: Total(n/a) fuera de rango: $($scNa.Total)") }
    } catch { [void]$fails.Add("S16: Get-AXEScore lanzo: $($_.Exception.Message)") }

    # S17: restore point con AXE_NOSR=1 devuelve fallback sin lanzar ni crear punto
    $checks++
    try {
        $env:AXE_NOSR='1'
        $rp = New-AXERestorePoint 'selftest'
        if($rp.Status -ne 'fallback'){ [void]$fails.Add("S17: con AXE_NOSR esperaba 'fallback', got '$($rp.Status)'") }
    } catch { [void]$fails.Add("S17: New-AXERestorePoint lanzo: $($_.Exception.Message)") }

    # S18: reporte string no vacio + export JSON parseable (roundtrip en temp)
    $checks++
    try {
        $s0=Get-AXESnapshot -JitterMs 50; $s1=Get-AXESnapshot -JitterMs 50
        $rep=New-AXEReport $s0 $s1 (Get-AXEScore $s0) (Get-AXEScore $s1 $s0)
        if([string]::IsNullOrWhiteSpace($rep)){ [void]$fails.Add('S18: New-AXEReport vacio') }
        $tmp=Join-Path $script:AXEData ('reptest_{0}.json' -f [guid]::NewGuid())
        Export-AXEReport $s0 $s1 $tmp
        $back=Get-Content $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
        if(-not $back.scoreAfter){ [void]$fails.Add('S18: export JSON sin scoreAfter') }
        Remove-Item $tmp -Force -EA SilentlyContinue
    } catch { [void]$fails.Add("S18: report/export lanzo: $($_.Exception.Message)") }

    # S20: modulo Defender (§7) presente - funciones de exclusion/afinado definidas
    $checks++
    foreach($fn in 'Add-AXEDefenderExclusion','Remove-AXEDefenderExclusion','Get-AXESteamCommon'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S20: funcion Defender '$fn' no definida") }
    }
    foreach($id in 'def_cpulimit','def_scanidle'){
        if(-not ($script:CAT | Where-Object Id -eq $id)){ [void]$fails.Add("S20: tweak Defender '$id' no en catalogo") }
    }
    # S21: banner de ecosistema (§3.3) + azucar de gating (§3.2) presentes y no lanzan
    $checks++
    foreach($fn in 'Get-AXEEnvBanner','Test-AXEEnvApplies'){
        if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S21: funcion '$fn' no definida") }
    }
    try { if([string]::IsNullOrWhiteSpace((Get-AXEEnvBanner))){ [void]$fails.Add('S21: Get-AXEEnvBanner vacio') } }
    catch { [void]$fails.Add("S21: Get-AXEEnvBanner lanzo: $($_.Exception.Message)") }
    # S22 ELIMINADO (auditoria 2026-07-19). Comprobaba que Assert-AXEVss y Get-AXETamperState
    # estuvieran DEFINIDAS. Ninguna tenia llamadores de produccion, asi que el check solo probaba
    # que existia codigo muerto: imposible de fallar mientras nadie borrara las funciones, y cero
    # senal sobre si el preflight de §4.1 servia (no servia: no se invocaba nunca). Las funciones
    # se han borrado en 34-safety.ps1 y el check se va con ellas.
    #   Leccion por si se reescribe: un check de "la funcion existe" no vale. Si se cablea un
    # preflight de verdad, el check debe EJECUTARLO y mirar lo que devuelve -- como S21 con
    # Get-AXEEnvBanner, o el harness GUI pulsando de verdad el boton de REGISTRO.

    # S23: GPU por juego (region 10c). Siguiendo la leccion de S22: no se comprueba que las
    # funciones EXISTAN, se EJECUTAN sobre una ruta sintetica y se mira lo que devuelven.
    # Nada de esto toca una entrada de juego real.
    $checks++
    try {
        # Parser: roundtrip sobre el formato real, incluida la cadena que empieza por ';'.
        $rt = ConvertTo-AXEGpuPref (ConvertFrom-AXEGpuPref 'AppStatus=4096;GpuPreference=2;')
        if($rt -ne 'AppStatus=4096;GpuPreference=2;'){ [void]$fails.Add("S23: parser no hace roundtrip: '$rt'") }
        if((ConvertFrom-AXEGpuPref ';SwapEffectUpgradeEnable=1;').Count -ne 1){ [void]$fails.Add('S23: parser no tolera cadena que empieza por ;') }
        # Escritura + revert sobre un exe que no existe en disco.
        $probe = 'C:\__AXE_SELFTEST_GPU__\probe.exe'
        Set-AXEGameGpuPref -Exe $probe -HighPerf $true -FlipModel $true
        $ps = Get-AXEGameGpuState $probe
        if(-not $ps.HighPerf -or -not $ps.FlipModel){ [void]$fails.Add("S23: Set-AXEGameGpuPref no aplico (raw='$($ps.Raw)')") }
        if((Revert-AXEGameGpu $probe) -eq 0){ [void]$fails.Add('S23: revert no encontro la captura que acababa de hacer') }
        if($null -ne (Get-RV $script:GpuPrefKey $probe)){ [void]$fails.Add('S23: revert dejo residuo en el registro') }
        # Exe jamas tocado: 0 y sin escribir.
        if((Revert-AXEGameGpu 'C:\__AXE_SELFTEST_GPU__\jamas.exe') -ne 0){ [void]$fails.Add('S23: revert de exe intacto no devolvio 0') }
        # Ruta inexistente: Optimize avisa y no escribe.
        $om = (Optimize-AXEGame -Exe 'C:\__AXE_SELFTEST_GPU__\no-existe.exe') -join "`n"
        if($om -notmatch 'no existe'){ [void]$fails.Add("S23: Optimize-AXEGame no aviso de ruta inexistente: $om") }
    } catch { [void]$fails.Add("S23: GPU por juego lanzo: $($_.Exception.Message)") }

    # S24: las variables de ruta del catalogo siguen siendo cadenas con contenido.
    # POR QUE EXISTE: al anadir la CLI de GPU por juego se declaro un '[switch]$Games' en el
    # param block, y 20-tweaks.ps1 ya usaba $Games para la ruta de la tarea MMCSS. Declararla
    # como switch la tipa a nivel de script, la asignacion de la cadena revienta y $Games queda
    # vacia => gpu_mmcss apuntando a la nada. El SelfTest daba 0 fallos: S1-S23 miran el ESQUEMA
    # del catalogo (claves, tipos, ids) y ninguno mira si las RUTAS que usan tienen valor.
    # Cualquier futura colision param-vs-variable cae aqui en vez de silenciosamente en runtime.
    $checks++
    foreach($pv in @(@{N='PC';V=$PC},@{N='SP';V=$SP},@{N='GD';V=$GD},@{N='MM';V=$MM},@{N='Games';V=$Games})){
        if([string]::IsNullOrWhiteSpace([string]$pv.V)){
            [void]$fails.Add("S24: `$$($pv.N) vacia - colision con un parametro del param block? Los tweaks que la usan escribirian en una ruta invalida")
        } elseif([string]$pv.V -notmatch '^HK(LM|CU):\\'){
            [void]$fails.Add("S24: `$$($pv.N) no parece ruta de registro: '$($pv.V)'")
        }
    }

    # S25: medicion de FPS (region 10d). Se EJERCE el calculo y el veredicto con series
    # sinteticas: no hace falta PresentMon ni un juego abierto, y por eso el check corre
    # siempre en vez de saltarse en la mitad de las maquinas.
    $checks++
    try {
        $const = Get-AXEFpsStats -FrameTimesMs (@(16.667) * 100)
        if(-not $const.Ok -or [math]::Abs($const.AvgFps - 60) -gt 0.5){ [void]$fails.Add("S25: 60 FPS constantes dieron $($const.AvgFps)") }
        # El 1% low debe mirar los frames MAS LENTOS. Si el orden se invirtiera, este caso lo
        # caza: 99 frames de 10ms + 1 de 100ms tiene que dar 1% low ~= 10 FPS, no ~100.
        $spike = Get-AXEFpsStats -FrameTimesMs (@(@(10.0) * 99) + @(100.0))
        if([math]::Abs($spike.P1LowFps - 10) -gt 1){ [void]$fails.Add("S25: 1% low midio los frames rapidos (dio $($spike.P1LowFps), esperado ~10)") }
        if((Get-AXEFpsStats -FrameTimesMs @(16.6,16.6)).Ok){ [void]$fails.Add('S25: captura de 2 frames se dio por valida') }
        # Veredicto: dos capturas iguales NO pueden ser concluyentes.
        $mk = { param($base,$j,$n) Get-AXEFpsStats -FrameTimesMs @(foreach($i in 0..($n-1)){ $base + $j*[math]::Sin($i*0.7) }) }
        $s1 = & $mk 16.667 1.0 800; $s2 = & $mk 16.667 1.0 800
        $vSame = Get-AXEFpsVerdict -Before $s1 -After $s2
        if($vSame.Conclusive){ [void]$fails.Add('S25: dos capturas identicas salieron CONCLUYENTES (umbral de ruido roto)') }
        $vBig = Get-AXEFpsVerdict -Before (& $mk 20.0 0.5 800) -After (& $mk 16.667 0.5 800)
        if(-not $vBig.Conclusive){ [void]$fails.Add('S25: 50->60 FPS limpios NO salieron concluyentes') }
        # El aviso de misma-escena tiene que ir tambien cuando el resultado es bueno.
        if($vBig.Warning -notmatch 'MISMA escena'){ [void]$fails.Add('S25: falta el aviso de misma-escena en un veredicto positivo') }
        # Columna de PresentMon: las dos versiones, y null si no la reconoce.
        if((Get-AXEFrameTimeColumn ([pscustomobject]@{msBetweenPresents='1'})) -ne 'msBetweenPresents'){ [void]$fails.Add('S25: no reconoce la columna de PresentMon 1.x') }
        if((Get-AXEFrameTimeColumn ([pscustomobject]@{FrameTime='1'})) -ne 'FrameTime'){ [void]$fails.Add('S25: no reconoce la columna de PresentMon 2.x') }
        if($null -ne (Get-AXEFrameTimeColumn ([pscustomobject]@{Nada='1'}))){ [void]$fails.Add('S25: adivina columna desconocida en vez de devolver null') }
        if(-not (Get-Command Measure-AXEFps -EA SilentlyContinue)){ [void]$fails.Add('S25: Measure-AXEFps no definida') }
    } catch { [void]$fails.Add("S25: medicion de FPS lanzo: $($_.Exception.Message)") }

    # S26: la capa WebUI (webui/) existe y trae los assets minimos (rediseno WebView2, fase 0).
    # Usa $script:WebUIDir (39-webdetect resuelve AXE\webui aun corriendo desde dist\).
    $checks++
    foreach($a in 'index.html','styles.css','app.js','bridge.js'){
        if(-not (Test-Path (Join-Path $script:WebUIDir $a))){ [void]$fails.Add("S26: falta webui/$a") }
    }
    # S27: deteccion de runtime WebView2 definida y con la forma esperada {Available,Version,Reason}
    $checks++
    if(-not (Get-Command Get-AXEWebView2Runtime -EA SilentlyContinue)){
        [void]$fails.Add('S27: Get-AXEWebView2Runtime no definida')
    } else {
        $rt = Get-AXEWebView2Runtime
        foreach($k in 'Available','Version','Reason'){
            if(($rt.PSObject.Properties.Name) -notcontains $k){ [void]$fails.Add("S27: runtime sin campo '$k'") }
        }
    }
    # S-webui-3: coherencia lista blanca (48-webbridge) <-> literales del frontend (webui/*.js).
    #  Directo: cada AXE.call('x') literal existe en la lista blanca (caza typos / cmds inventados).
    #  Inverso: cada cmd de la lista blanca aparece como literal en el JS. El inverso usa presencia
    #  de literal (no el prefijo AXE.call() del regex directo) a proposito: asi ve el despacho
    #  ternario AXE.call(cond ? 'tweaks.apply' : 'tweaks.revert') que el directo no captura.
    #  El bloque -SelfTest de 45-cli hace 'exit' ANTES de que 48-webbridge cargue el mapa, asi que
    #  el $script:AXEBridgeMap vivo no existe aqui: las claves se extraen del propio script en curso
    #  ($PSCommandPath), donde "'x' = { param($a)" es un patron EXCLUSIVO del puente (14/14 en dist).
    #  Si el mapa esta cargado (contexto Pester/futuro) se usa tal cual. Match case-sensitive (-c*),
    #  coherente con el despacho exacto del puente.
    $checks++
    $wlKeys = @()
    if($script:AXEBridgeMap){
        $wlKeys = @($script:AXEBridgeMap.Keys)
    } else {
        $selfSrc = ''
        try { $selfSrc = Get-Content $PSCommandPath -Raw -EA Stop } catch {}
        $rx = '(?m)^\s*''([A-Za-z][A-Za-z.]*)''\s*=\s*\{\s*param\(\$a\)'
        $wlKeys = @([regex]::Matches($selfSrc, $rx) | ForEach-Object { $_.Groups[1].Value })
    }
    if(@($wlKeys).Count -eq 0){
        [void]$fails.Add('S-webui-3: no se pudo determinar la lista blanca del puente (mapa vivo ausente y parseo vacio)')
    } else {
        $wjs = Get-ChildItem $script:WebUIDir -Recurse -Filter '*.js' -EA SilentlyContinue
        $jsRaw = ($wjs | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
        $called = @{}
        foreach($m in [regex]::Matches($jsRaw, "AXE\.call\(\s*'([^']+)'")){ $called[$m.Groups[1].Value] = $true }
        foreach($c in $called.Keys){
            if($wlKeys -cnotcontains $c){ [void]$fails.Add("S-webui-3: app.js llama '$c' fuera de la lista blanca") }
        }
        foreach($c in $wlKeys){
            if($jsRaw -notmatch [regex]::Escape("'$c'")){ [void]$fails.Add("S-webui-3: '$c' en lista blanca pero ningun JS lo referencia (cmd muerto)") }
        }
    }

    # S28: daemon de sesion de juego (region 12b, spec 2026-07-20). Leccion S22: no se comprueba
    # que las funciones EXISTAN, se EJECUTA el planificador PURO sobre hechos sinteticos y se mira
    # el reparto. No toca el kernel ni procesos reales.
    $checks++
    try {
        $sf = @(
            [pscustomobject]@{Pid=1000;Name='thegame';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1001;Name='explorer';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1002;Name='discord';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1003;Name='chrome';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1004;Name='EasyAntiCheat';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1005;Name='randomthing';SessionId=1;Path=$null}
            [pscustomobject]@{Pid=1006;Name='svchost';SessionId=0;Path=$null}
            [pscustomobject]@{Pid=99;Name='powershell';SessionId=1;Path=$null}
        )
        $pl = Get-AXESessionPlan -Processes $sf -GamePid 1000 -GameName 'thegame' -SelfPid 99 -SessionId 1
        $cong = @($pl.Congelado | ForEach-Object Name)
        $deg  = @($pl.Degradado | ForEach-Object Name)
        $int  = @($pl.Intacto   | ForEach-Object Name)
        if($cong -notcontains 'randomthing'){ [void]$fails.Add('S28: proceso desconocido no quedo CONGELADO') }
        foreach($never in 'thegame','explorer','discord','EasyAntiCheat','powershell','svchost'){
            if($cong -contains $never){ [void]$fails.Add("S28: '$never' NO debe ser congelable") }
        }
        if($deg -notcontains 'chrome'){ [void]$fails.Add('S28: chrome no quedo DEGRADADO') }
        if($int -notcontains 'discord'){ [void]$fails.Add('S28: discord no quedo INTACTO') }
        foreach($grp in $int,$deg,$cong){ if($grp -contains 'svchost'){ [void]$fails.Add('S28: proceso de Session 0 entro en el plan') } }
        $empty = Get-AXESessionPlan -Processes @() -GamePid 0 -GameName 'x' -SelfPid 1 -SessionId 1
        if(@($empty.Congelado).Count -ne 0){ [void]$fails.Add('S28: plan de lista vacia no salio vacio') }
        # Servicios POR-USUARIO: viven en svchost DENTRO de la sesion interactiva, no en la 0, asi que
        # la frontera de sesion no los protege. Congelar uno cuelga a quien le haga un RPC sincrono.
        $plUser = Get-AXESessionPlan -Processes @([pscustomobject]@{Pid=1100;Name='svchost';SessionId=1;Path=$null}) `
            -GamePid 1000 -GameName 'thegame' -SelfPid 99 -SessionId 1 -Config @{ svchost='congelado' }
        if(@($plUser.Congelado).Count -ne 0 -or @($plUser.Degradado).Count -ne 0){
            [void]$fails.Add('S28: svchost de la sesion interactiva (servicios por-usuario) salio tocable')
        }
        foreach($fn in 'Start-AXESession','Stop-AXESession','Watch-AXESession','Format-AXESession','Get-AXESessionProcesses'){
            if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S28: funcion de sesion '$fn' no definida") }
        }
        # Persistencia del reparto (spec 2026-07-25). Misma leccion: se EJERCE el round-trip, contra
        # un temporal y NUNCA contra el AXE/ del usuario. $script:AXEData se restaura en el finally.
        $oldData = $script:AXEData
        try {
            $script:AXEData = Join-Path ([IO.Path]::GetTempPath()) ('axe-selftest-sess-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $script:AXEData -Force)
            if(-not (Set-AXESessionOverride -Name 'chrome' -Level 'congelado').Ok){ [void]$fails.Add('S28: no pude guardar un override valido') }
            if((Read-AXESessionOverrides)['chrome'] -ne 'congelado'){ [void]$fails.Add('S28: el override guardado no se vuelve a leer') }
            if((Set-AXESessionOverride -Name 'explorer' -Level 'congelado').Ok){ [void]$fails.Add('S28: un proceso DURO acepto override (seria un ajuste que no hace nada)') }
            if((Set-AXESessionOverride -Name 'chrome' -Level 'turbo').Ok){ [void]$fails.Add('S28: acepto un nivel inventado') }
            if(-not (Set-AXESessionOverride -Name 'chrome' -Level 'default').Ok -or (Read-AXESessionOverrides).ContainsKey('chrome')){
                [void]$fails.Add("S28: 'default' no borro el override")
            }
            # Diario de prioridades: la red de la salida sucia. Lo que hay que proteger es que NUNCA
            # toque un pid que ya no es el proceso que se degrado (los pid se reusan). Se ejerce con
            # el propio proceso, cambiando solo el arranque esperado: debe negarse a restaurar.
            $me = Get-Process -Id $PID
            Write-AXESessionJournal @([pscustomobject]@{ Pid=$PID; Name=$me.ProcessName; Prev='High'; StartTicks=1 })
            if(-not (Test-Path (Get-AXESessionJournalPath))){ [void]$fails.Add('S28: el diario de prioridades no se escribio') }
            if((Restore-AXESessionDegraded) -ne 0){ [void]$fails.Add('S28: el diario restauro un proceso con otro instante de arranque (pid reusado)') }
            if(Test-Path (Get-AXESessionJournalPath)){ [void]$fails.Add('S28: el diario no se consumio al restaurar') }
            Set-Content -Path (Get-AXESessionJournalPath) -Value '{ no es json' -Encoding UTF8
            if((Restore-AXESessionDegraded) -ne 0){ [void]$fails.Add('S28: un diario ilegible no se descarto') }
        } finally {
            if($script:AXEData -and ($script:AXEData -ne $oldData) -and (Test-Path $script:AXEData)){ Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue }
            $script:AXEData = $oldData
        }
        # DTO que pinta la ventana: sin sesion nunca sale activa, y el motivo de cierre viaja.
        $stOff = Get-AXESessionStatus -Session $null -EndedReason 'el juego se cerro.'
        if($stOff.active){ [void]$fails.Add('S28: estado sin sesion salio como ACTIVA') }
        if($stOff.endedReason -notmatch 'cerro'){ [void]$fails.Add('S28: el motivo de cierre no llega a la ventana') }
        $stOn = Get-AXESessionStatus -Session ([pscustomobject]@{
            Ok=$true; Game='thegame'; GamePid=1000; SessionId=1; Assigned=2; Failed=1
            Plan=[pscustomobject]@{ Intacto=@(1,2,3); Degradado=@(1); Congelado=@(1,2) }
            Degraded=@([pscustomobject]@{Pid=1;Prev='Normal'}); Started=(Get-Date)
        })
        if(-not $stOn.active -or $stOn.frozen -ne 2 -or $stOn.intact -ne 3){ [void]$fails.Add('S28: el DTO de estado no refleja el reparto') }
    } catch { [void]$fails.Add("S28: planificador de sesion lanzo: $($_.Exception.Message)") }

    # S29: benchmark "pruebalo en tu PC" (region 8e, spec 2026-07-24). Misma leccion que S22/S25:
    # el veredicto se EJERCE con series sinteticas en vez de comprobar que la funcion existe. Aqui
    # lo que hay que proteger es una sola propiedad: que NUNCA se declare mejora dentro del ruido.
    # Si algun dia alguien "afina" el umbral, este check se pone rojo antes de que salga del repo.
    $checks++
    try {
        # Fabrica de agregados sinteticos: {median,iqr,passes} por metrica, la misma forma que
        # produce Measure-AXEBenchSample y que sobrevive al round-trip JSON.
        $mkS = {
            param($p999,$q999,$scoreV,$scoreQ)
            [pscustomobject]@{
                id='synth'; axeVersion='test'; hwHash='sha256:synth'; ts='2026-07-24T00:00:00Z'
                passes=7; jitterMs=250
                hw=[pscustomobject]@{ cpu='synth'; ramGB=16.0; gpuVendor='synth'; build=26200 }
                metrics=[pscustomobject]@{
                    jitterP999Ms=[pscustomobject]@{ median=$p999; iqr=$q999; passes=7 }
                    jitterMeanMs=$null
                    timerMs=$null
                    score=[pscustomobject]@{ median=$scoreV; iqr=$scoreQ; passes=7 }
                }
            }
        }
        # (a) delta grande y limpio (jitter baja mucho, ruido pequeno) => concluyente 'mejor'.
        $vA = Get-AXEBenchVerdict (& $mkS 1.00 0.02 50 1) (& $mkS 0.40 0.02 70 1)
        $jA = $vA | Where-Object Key -eq 'jitterP999Ms'
        if(-not $jA -or $jA.Tag -ne 'mejor'){ [void]$fails.Add("S29: delta limpio de jitter no salio 'mejor' (dio '$($jA.Tag)')") }
        $sA = $vA | Where-Object Key -eq 'score'
        if(-not $sA -or $sA.Tag -ne 'mejor'){ [void]$fails.Add("S29: score 50->70 no salio 'mejor' (dio '$($sA.Tag)')") }
        # (b) delta REAL pero por debajo del ruido combinado => 'ruido'. El check que importa.
        $vB = Get-AXEBenchVerdict (& $mkS 1.00 0.30 50 5) (& $mkS 0.95 0.30 52 5)
        foreach($m in $vB){
            if($m.Tag -ne 'ruido'){ [void]$fails.Add("S29: '$($m.Key)' dentro del ruido salio '$($m.Tag)' - el motor declara mejoras que no existen") }
            if($m.Conclusive){ [void]$fails.Add("S29: '$($m.Key)' dentro del ruido salio Conclusive") }
        }
        # (c) delta grande en la direccion mala => 'peor' (el veredicto no solo sabe felicitar).
        $vC = Get-AXEBenchVerdict (& $mkS 0.40 0.02 70 1) (& $mkS 1.00 0.02 50 1)
        foreach($k in 'jitterP999Ms','score'){
            $m = $vC | Where-Object Key -eq $k
            if(-not $m -or $m.Tag -ne 'peor'){ [void]$fails.Add("S29: regresion grande en '$k' no salio 'peor' (dio '$($m.Tag)')") }
        }
        # (d) metrica no medible (native ausente) => se OMITE, sin lanzar y sin comparar contra 0.
        if(@($vA | Where-Object Key -eq 'timerMs').Count -ne 0){ [void]$fails.Add('S29: metrica null no se omitio del veredicto') }
        if(@($vA | Where-Object Key -eq 'jitterMeanMs').Count -ne 0){ [void]$fails.Add('S29: metrica ausente no se omitio del veredicto') }
        # Round-trip Save/Read en store TEMPORAL: no toca el AXE/bench/ real del usuario.
        $realBench = $script:AXEBenchDir
        try {
            $script:AXEBenchDir = Join-Path $script:AXEData ('benchtest_{0}' -f [guid]::NewGuid())
            $sample = & $mkS 0.42 0.05 61 2
            $bid = Save-AXEBenchBaseline $sample
            if(-not $bid){ [void]$fails.Add('S29: Save-AXEBenchBaseline no devolvio id') }
            $back = Read-AXEBenchBaseline $bid
            if(-not $back){ [void]$fails.Add('S29: Read-AXEBenchBaseline no recupero la linea base') }
            elseif([double]$back.metrics.jitterP999Ms.median -ne 0.42){ [void]$fails.Add("S29: round-trip perdio la mediana (dio $($back.metrics.jitterP999Ms.median))") }
            if($null -ne (Read-AXEBenchBaseline 'no-existe-jamas')){ [void]$fails.Add('S29: un id inexistente devolvio algo en vez de null') }
            if($null -ne (Read-AXEBenchBaseline '..\..\etc')){ [void]$fails.Add('S29: un id con separadores de ruta no se rechazo') }
            # Comparabilidad: hash distinto => se niega con motivo, no produce un delta falso.
            $why = Test-AXEBenchComparable $back ([pscustomobject]@{ axeVersion='otra'; hwHash='sha256:OTRA'; hw=[pscustomobject]@{cpu='x';ramGB=8.0;gpuVendor='y';build=1} })
            if([string]::IsNullOrWhiteSpace($why)){ [void]$fails.Add('S29: hash de HW distinto se dio por comparable') }
            # Reporte: no vacio, JSON parseable, y sin PII (ni usuario ni equipo).
            $rep = New-AXEBenchReport $back (& $mkS 0.30 0.04 70 2) $null
            if(@($rep.Text).Count -lt 5){ [void]$fails.Add('S29: reporte de texto vacio o demasiado corto') }
            if([string]::IsNullOrWhiteSpace($rep.Markdown)){ [void]$fails.Add('S29: reporte Markdown vacio') }
            $pj = $null
            try { $pj = $rep.Json | ConvertFrom-Json -EA Stop } catch { [void]$fails.Add("S29: JSON del reporte no parsea: $($_.Exception.Message)") }
            if($pj -and @($pj.verdict).Count -lt 1){ [void]$fails.Add('S29: JSON del reporte sin veredicto') }
            $all = (@($rep.Text) -join "`n") + $rep.Markdown + $rep.Json
            foreach($pii in @($env:USERNAME,$env:COMPUTERNAME,$env:USERDOMAIN)){
                if($pii -and $all -match [regex]::Escape($pii)){ [void]$fails.Add("S29: el reporte compartible contiene PII ('$pii')") }
            }
            Remove-Item $script:AXEBenchDir -Recurse -Force -EA SilentlyContinue
        } finally { $script:AXEBenchDir = $realBench }
    } catch { [void]$fails.Add("S29: benchmark lanzo: $($_.Exception.Message)") }

    # S30: cadena de confianza + updater (region 8f, spec 2026-07-24). Misma leccion que
    # S25/S29: no se comprueba que las funciones EXISTAN, se EJERCEN las decisiones. Aqui lo
    # que hay que proteger es una sola propiedad, y es de seguridad: EL UPDATER NUNCA REEMPLAZA
    # NADA QUE NO HAYA VERIFICADO. Si alguien "simplifica" una de estas negativas, esto se pone
    # rojo antes de que salga del repo. Todo headless y SIN RED: los caminos de rechazo que se
    # ejercen ocurren antes de cualquier descarga, y el resto va con fixtures locales.
    $checks++
    try {
        # (a) Comparacion de versiones, incluido el orden de prerelease de SemVer §11.
        $vc = @(
            @{ A='7.0.0'; B='7.0.1'; W=-1 }, @{ A='7.0.1'; B='7.0.0'; W=1 }, @{ A='7.0.0'; B='7.0.0'; W=0 }
            @{ A='7';     B='7.0.0'; W=0 }              # '7' se normaliza a '7.0.0'
            @{ A='v7.1.0';B='7.1.0'; W=0 }              # la 'v' del tag no cuenta
            @{ A='7.1.0-beta'; B='7.1.0'; W=-1 }        # prerelease < estable
            @{ A='7.10.0'; B='7.9.0'; W=1 }             # 10 > 9, no comparacion de cadenas
            @{ A='7.0.0+abc'; B='7.0.0'; W=0 }          # los metadatos de build no cuentan
        )
        foreach($t in $vc){
            $got = Compare-AXEVersion $t.A $t.B
            if($got -ne $t.W){ [void]$fails.Add("S30: Compare-AXEVersion '$($t.A)' vs '$($t.B)' dio $got, esperado $($t.W)") }
        }
        if($null -ne (Compare-AXEVersion '7.x.0' '7.0.0')){ [void]$fails.Add('S30: una version ilegible no devolvio null (se confundiria con "al dia")') }

        # (b) Checksums: round-trip generar -> verificar, y que una alteracion de UN byte lo cace.
        $ctmp = Join-Path $script:AXEData ('updtest_{0}' -f [guid]::NewGuid())
        try {
            New-Item -ItemType Directory -Path $ctmp -Force | Out-Null
            Set-Content (Join-Path $ctmp 'a.txt') -Value 'contenido a' -Encoding UTF8 -NoNewline
            Set-Content (Join-Path $ctmp 'b.txt') -Value 'contenido b' -Encoding UTF8 -NoNewline
            $sumFile = New-AXEChecksums -Dir $ctmp
            $bad = @(Test-AXEChecksums -Dir $ctmp)
            if($bad.Count -ne 0){ [void]$fails.Add("S30: SHA256SUMS recien generado no se verifica a si mismo ($($bad -join '; '))") }
            # Determinismo: regenerar sobre lo mismo da BYTES identicos (lo que permite el guard anti-deriva).
            $first = Get-Content $sumFile -Raw -Encoding UTF8
            [void](New-AXEChecksums -Dir $ctmp)
            if((Get-Content $sumFile -Raw -Encoding UTF8) -ne $first){ [void]$fails.Add('S30: New-AXEChecksums no es determinista (dos pasadas, dos ficheros)') }
            # Un byte distinto => el verificador tiene que cazarlo. Este es el check que importa.
            Set-Content (Join-Path $ctmp 'a.txt') -Value 'contenido A' -Encoding UTF8 -NoNewline
            if(@(Test-AXEChecksums -Dir $ctmp).Count -eq 0){ [void]$fails.Add('S30: un fichero MODIFICADO paso la verificacion de checksum') }
            # Parseo puntual + rechazo de lo que no esta listado.
            $h = Get-AXEChecksumFor $first 'b.txt'
            if($h -notmatch '^[0-9a-f]{64}$'){ [void]$fails.Add("S30: Get-AXEChecksumFor no devolvio un sha256 valido (dio '$h')") }
            if($null -ne (Get-AXEChecksumFor $first 'no-listado.txt')){ [void]$fails.Add('S30: un nombre NO listado en SHA256SUMS devolvio hash') }
        } finally { Remove-Item $ctmp -Recurse -Force -EA SilentlyContinue }

        # (c) Firma: la NEGATIVA es el lado del que depende la seguridad del updater, y es el
        # unico que se puede comprobar sin exigir un cert en el entorno (CI no lo tiene). Se usa
        # un .ps1 recien escrito en temp: sin firma POR CONSTRUCCION, aqui y en la maquina de
        # quien sea. Comprobarlo contra $PSCommandPath daria un resultado distinto segun si el
        # dist local esta firmado o no, o sea un check que no comprueba nada estable.
        $sigTmp = Join-Path ([IO.Path]::GetTempPath()) ('axe_sig_{0}.ps1' -f [guid]::NewGuid())
        try {
            Set-Content -LiteralPath $sigTmp -Value '# sin firma' -Encoding UTF8
            if(Test-AXESignature $sigTmp){ [void]$fails.Add('S30: Test-AXESignature dio true sobre un fichero SIN firmar') }
            $si = Get-AXESignatureInfo $sigTmp
            if($si.Valid){ [void]$fails.Add('S30: Get-AXESignatureInfo marco Valid un fichero sin firmar') }
        } finally { Remove-Item -LiteralPath $sigTmp -Force -EA SilentlyContinue }
        if(Test-AXESignature 'C:\no\existe\jamas.ps1'){ [void]$fails.Add('S30: Test-AXESignature dio true sobre un fichero inexistente') }
        if(Test-AXESignature ''){ [void]$fails.Add('S30: Test-AXESignature dio true sobre una ruta vacia') }
        if((Get-AXESignatureInfo 'C:\no\existe\jamas.ps1').Status -ne 'NotFound'){ [void]$fails.Add('S30: Get-AXESignatureInfo no reporto NotFound sobre una ruta inexistente') }

        # (d) Origen de la descarga: solo https, solo hosts de GitHub, solo este owner/repo.
        $okUrl  = "https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v9.9.9/AXE.ps1"
        if(-not (Test-AXEAssetUrl $okUrl)){ [void]$fails.Add('S30: la URL legitima del repo oficial se rechazo') }
        foreach($mal in @(
            "http://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v1/AXE.ps1"  # sin TLS
            'https://evil.example.com/AXE.ps1'                                                                   # otro dominio
            "https://github.com/otro/repo/releases/download/v1/AXE.ps1"                                          # otro repo
            'https://github.com.evil.example/AXE.ps1'                                                            # host que solo lo parece
            'no-soy-una-url'; ''
        )){
            if(Test-AXEAssetUrl $mal){ [void]$fails.Add("S30: se acepto una URL de descarga que NO es del repo oficial: '$mal'") }
        }

        # (e) Decisiones del updater con un release INYECTADO (sin red). Se ejercen los caminos
        # de rechazo, que ocurren todos antes de la primera descarga.
        $mkRel = {
            param($tag,$assets)
            ConvertFrom-AXEReleaseJson ([pscustomobject]@{
                tag_name=$tag; published_at='2026-01-01T00:00:00Z'; prerelease=$false; assets=$assets })
        }
        $goodAssets = @(
            [pscustomobject]@{ name='AXE.ps1';    size=1; browser_download_url=$okUrl }
            [pscustomobject]@{ name='SHA256SUMS'; size=1; browser_download_url="https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v9.9.9/SHA256SUMS" }
        )
        $vieja = & $mkRel ('v' + $script:AXEVersion) $goodAssets
        if((Invoke-AXEUpdate -Release $vieja).Status -ne 'current'){ [void]$fails.Add('S30: con la MISMA version el updater no dijo "current"') }
        $nueva = & $mkRel 'v999.0.0' $goodAssets
        if((Invoke-AXEUpdate -Release $nueva -Check).Status -ne 'available'){ [void]$fails.Add('S30: -Check con version nueva no dijo "available"') }
        # Sin SHA256SUMS no se instala NADA, aunque el AXE.ps1 venga del repo bueno.
        $sinSums = & $mkRel 'v999.0.0' @($goodAssets[0])
        if((Invoke-AXEUpdate -Release $sinSums).Status -ne 'refused'){ [void]$fails.Add('S30: un release SIN SHA256SUMS no se rechazo') }
        # Asset servido desde fuera del repo oficial: rechazo antes de descargar.
        $urlMala = & $mkRel 'v999.0.0' @(
            [pscustomobject]@{ name='AXE.ps1';    size=1; browser_download_url='https://evil.example.com/AXE.ps1' }
            $goodAssets[1])
        if((Invoke-AXEUpdate -Release $urlMala).Status -ne 'refused'){ [void]$fails.Add('S30: un asset alojado FUERA del repo oficial no se rechazo') }
        # Un release sin tag no es un release: no puede acabar en "estas al dia".
        if($null -ne (ConvertFrom-AXEReleaseJson ([pscustomobject]@{ assets=@() }))){ [void]$fails.Add('S30: un release sin tag_name no devolvio null') }
        # "No pude comprobar" NUNCA puede salir como "estas al dia": eso deja al usuario en una
        # version vieja creyendo lo contrario.
        #   -Release $null es indistinguible de omitir el parametro, asi que esta sonda caia en
        # Get-AXELatestRelease y llamaba a la API de GitHub DE VERDAD: verde solo mientras no hubiera
        # red ni releases publicados, y en cuanto hubo release empezo a devolver 'current'. Se
        # sombrea la funcion en un scope hijo (PowerShell resuelve comandos por la cadena de scopes
        # del LLAMANTE, asi que Invoke-AXEUpdate ve esta version): sin red, deterministico.
        $sinApi = & { function Get-AXELatestRelease { $null }; (Invoke-AXEUpdate -Check).Status }
        if($sinApi -ne 'error'){ [void]$fails.Add('S30: sin poder consultar la API el updater no dijo "error"') }

        foreach($fn in 'Invoke-AXEUpdate','Get-AXELatestRelease','Test-AXESignature','New-AXEChecksums','New-AXESbom','Test-AXEAssetUrl'){
            if(-not (Get-Command $fn -EA SilentlyContinue)){ [void]$fails.Add("S30: funcion de la cadena de confianza '$fn' no definida") }
        }
    } catch { [void]$fails.Add("S30: updater/cadena de confianza lanzo: $($_.Exception.Message)") }

    Write-Host "========================================="
    Write-Host " AXE $($script:AXEVersion) - SELF TEST"
    Write-Host "========================================="
    Write-Host " Catalogo   : $($script:CAT.Count) tweaks"
    Write-Host " Checks     : $checks"
    Write-Host " Fallos     : $($fails.Count)"
    Write-Host "-----------------------------------------"
    if($fails.Count -gt 0){ $fails | ForEach-Object { Write-Host "  FAIL: $_" } }
    Write-Host "========================================="
    if($fails.Count -eq 0){ Write-Host " RESULTADO: OK (0 fallos)"; exit 0 } else { Write-Host " RESULTADO: FALLO"; exit 1 }
}

# --- UPDATER (region 8f, spec 2026-07-24) --------------------------------------------------
# Va ANTES de -List y de cualquier bloque que necesite $script:HW: comprobar actualizaciones no
# depende del hardware ni de admin, y no tiene por que pagar los ~3.7s de CIM. Por eso -Update
# tampoco entra en el gate de carga de HW de arriba.
if($Update){
    Write-Host "== AXE $($script:AXEVersion) - actualizacion =="
    $r = Invoke-AXEUpdate -Check:$Check
    Write-Host ''
    Write-Host $r.Message
    Write-Host ''
    # Exit codes pensados para encadenar desde un script: 0 = nada que hacer o ya hecho,
    # 1 = hay algo que el usuario tiene que resolver a mano, 2 = no se pudo comprobar.
    switch($r.Status){
        'current'   { exit 0 }
        'updated'   { exit 0 }
        'available' { exit 0 }
        'refused'   { exit 1 }
        default     { exit 2 }
    }
}

if($List){
    Write-Host "== AXE $($script:AXEVersion) =="
    if($script:HW){ Write-Host "HW: $($script:HW.CpuName) | Laptop=$($script:HW.IsLaptop) Hybrid=$($script:HW.IsHybrid) Nvidia=$($script:HW.HasNvidia) Wifi=$($script:HW.IsWifi) AC=$(-not $script:HW.OnBattery)" }
    if($script:HW){ Write-Host ("ECO: " + (Get-AXEEnvBanner)) }
    # §3.4: la CLI dice lo mismo que la GUI. Una sola fuente (Get-AXERecommended), dos caras.
    if($script:HW){ $rec=@(Get-AXERecommended); Write-Host ("REC: {0} recomendados para este equipo -> {1}" -f $rec.Count,($rec -join ', ')) }
    Write-Host ""
    foreach($tw in $script:CAT){
        $blk = Get-BlockReason $tw
        $st  = try{ if($blk){'BLOCKED'}else{ if([bool](& $tw.Test)){'ON'}else{'off'} } }catch{ "ERR" }
        "{0,-11} T{1} {2,-34} {3}{4}" -f $tw.Cat,$tw.Tier,$tw.Name,$st,$(if($blk){" ($blk)"}) | Write-Host
    }
    exit 0
}

if($Export){
    Export-AXEProfile $Export
    exit 0
}
if($Import){
    Import-AXEProfile $Import
    exit 0
}
if($Measure){
    $snap=Get-AXESnapshot
    $sc=Get-AXEScore $snap
    Write-Host "== AXE MEDICION =="
    Write-Host $sc.Breakdown
    Write-Host ("AXE Score : {0}/100" -f $sc.Total)
    Write-Host 'Jitter = proxy de latencia (no atribuible a driver concreto).'
    exit 0
}
if($Score){
    $sc=Get-AXEScore (Get-AXESnapshot)
    Write-Host ("AXE Score : {0}/100" -f $sc.Total)
    Write-Host $sc.Breakdown
    exit 0
}
# --- BENCHMARK "pruebalo en tu PC" (region 8e, spec 2026-07-24) -----------------------
# ORDEN A POSTA: este bloque va ANTES de 'if($Report)'. -Report es un flag compartido y el
# bloque de reporte hace 'exit' incondicional, asi que puesto despues,
# 'AXE -Benchmark -After <id> -Report x.json' habria salido por el camino del reporte A/B
# clasico sin llegar nunca aqui: el usuario pediria un benchmark y recibiria otra cosa.
# Todo el bloque es headless, no muta el sistema y no necesita admin.
if($Benchmark){
    Write-Host '== AXE BENCHMARK - pruebalo en tu PC =='
    $passes = $BenchPasses
    if($passes -lt 3){ $passes = 3 }        # menos de 3 pasadas no da IQR con sentido
    if($passes -gt 25){ $passes = 25 }

    if(-not $After){
        # --- FASE 1: linea base ---
        Write-Host "Midiendo la linea base: $passes pasadas. Tarda ~$([int]($passes*1.5))-$([int]($passes*4)) s."
        Write-Host 'Cierra lo que no estes usando y no toques el equipo mientras mide.'
        $b = Measure-AXEBenchSample -Passes $passes
        $id = Save-AXEBenchBaseline $b
        if(-not $id){ Write-Host '  No pude guardar la linea base (ver log).'; exit 1 }
        Write-Host ''
        foreach($line in (Format-AXEBenchSample $b 'LINEA BASE')){ Write-Host $line }
        Write-Host ''
        Write-Host "Linea base guardada con id: $id"
        Write-Host 'Ahora aplica los tweaks que quieras y REINICIA el equipo. Despues, vuelve y ejecuta:'
        Write-Host "    AXE -Benchmark -After $id"
        Write-Host '(El reinicio no se automatiza a posta: hacerlo esconderia lo que se aplico,'
        Write-Host ' y el valor de esto es que puedas ver y repetir cada paso.)'
        exit 0
    }

    # --- FASE 2: despues + veredicto ---
    $before = Read-AXEBenchBaseline $After
    if(-not $before){
        # No se inventa un 'antes': sin linea base no hay comparacion posible, igual que
        # 'prueba.report' del puente se niega sin baseline.
        Write-Host "  No hay linea base con id '$After' (o el fichero esta corrupto)."
        Write-Host "  Busca en: $script:AXEBenchDir"
        Write-Host '  Empieza una nueva con:  AXE -Benchmark'
        exit 1
    }
    $why = Test-AXEBenchComparable $before
    if($why){
        Write-Host "  $why"
        Write-Host '  Un delta entre maquinas o versiones distintas no mide un cambio: mide otra cosa.'
        exit 1
    }
    # Mismas pasadas y misma duracion de jitter que la fase 1: comparar 7 pasadas contra 3
    # cambiaria el ruido medido y con el el umbral del veredicto.
    Write-Host ("Midiendo el DESPUES con los mismos parametros que la linea base ({0} pasadas)..." -f $before.passes)
    # OJO con el nombre: NO llamar a esta variable '$after'. Los nombres de variable de
    # PowerShell son case-insensitive, asi que '$after' ES el parametro '[string]$After' del
    # param block, que ademas esta TIPADO: asignarle el agregado lo convertiria a su
    # representacion en texto y el veredicto se quedaria sin datos, en silencio. Es la misma
    # familia de bug que la colision $Games/S24 documentada en 00-header.
    $afterSample = Measure-AXEBenchSample -Passes ([int]$before.passes) -JitterMs ([int]$before.jitterMs)
    $verdict = Get-AXEBenchVerdict $before $afterSample
    $rep = New-AXEBenchReport $before $afterSample $verdict
    Write-Host ''
    foreach($line in $rep.Text){ Write-Host $line }
    if($Report){
        $written = Export-AXEBenchReport $rep $Report
        Write-Host ''
        foreach($f in $written){ Write-Host "Escrito: $f" }
        Write-Host 'El .md es el compartible (sin datos personales: modelo de CPU, RAM, vendor de GPU y build).'
    }
    # Salida 1 si alguna metrica EMPEORO de forma concluyente, para poder encadenarlo en scripts.
    # 'ruido' no es fallo: es el resultado honesto mas comun.
    exit ([int](@($verdict | Where-Object Tag -eq 'peor').Count -gt 0))
}

if($Report){
    $s0=Get-AXESnapshot; $s1=Get-AXESnapshot
    Write-Host (Export-AXEReport $s0 $s1 $Report)
    exit 0
}
if($TimerSweep){
    # Barrido de resolucion de timer. NO recomienda un valor a ciegas: si el resultado cae
    # dentro del ruido de medicion lo dice y no recomienda nada. Ver Measure-AXETimerSweep.
    Write-Host '== AXE BARRIDO DE TIMER =='
    Write-Host 'Midiendo delta de Sleep(1) por resolucion. Tarda unos segundos...'
    $sw = Measure-AXETimerSweep
    if(-not $sw){ Write-Host 'Sin datos utiles (ver log).'; exit 1 }

    # Render via Format-AXETimerSweep (32-measure.ps1): mismo texto que el boton de la GUI.
    Write-Host ''
    foreach($line in (Format-AXETimerSweep $sw)){ Write-Host $line }
    exit 0
}
if($Diag){
    # Diagnostico de configuracion (region 10e). NO aplica nada: lo que detecta vive en la BIOS,
    # en los slots de RAM o en Configuracion de Windows, fuera del alcance de un script.
    # Salida 1 si hay algo mal configurado, para poder encadenarlo en scripts.
    $findings = Get-AXEDiagFindings -Facts (Get-AXEDiagFacts)
    foreach($line in (Format-AXEDiag -Findings $findings)){ Write-Host $line }
    exit ([int](@($findings | Where-Object Status -eq 'BAD').Count -gt 0))
}
if($Advice){
    # Consejero (region 12c). Junta diagnostico + cuellos + catalogo + historico de ESTA maquina
    # en un plan ordenado. Mide y GUARDA la medida: usar el consejero es lo que construye la
    # evidencia local, sin que haya que acordarse de registrar nada aparte.
    #   Salida 1 si hay algun cuello de botella real, para poder encadenarlo en scripts. El id
    # 'clean' no cuenta: es justo el caso en que NO hay cuello, y devolver error por estar todo
    # bien seria absurdo.
    $adv = Get-AXEAdviceNow
    Write-Host ''
    foreach($line in (Format-AXEAdvice -Plan $adv.Plan -Samples $adv.Samples)){ Write-Host $line }
    exit ([int](@($adv.Plan | Where-Object { $_.Kind -eq 'cuello' -and $_.Id -ne 'clean' }).Count -gt 0))
}
if($NetMon){
    # Monitor de red (region 9.5). Solo mide: ninguna rama de este modo escribe nada.
    # Salida 1 si hay hallazgo ERR (perdida contra el propio router o enlace mudo), para
    # poder encadenarlo igual que -Diag.
    $r = Measure-AXENetwork -Target $NetMonTarget -Count $NetMonCount
    Write-Host ''
    Write-Host (Format-AXENetwork $r)
    exit ([int](@($r.Findings | Where-Object Sev -eq 'ERR').Count -gt 0))
}
if($NetLoad){
    # Latencia bajo carga / bufferbloat (region 9.5). Es el UNICO modo de todo AXE que se
    # conecta a un servidor de terceros, y se dice antes de hacerlo: sin saturar el enlace no
    # existe la medida. Solo descarga; no sube nada del equipo.
    $url = if([string]::IsNullOrWhiteSpace($NetLoadUrl)){ $script:AXENetLoadUrl } else { $NetLoadUrl }
    Write-Host ''
    Write-Host "Saturando el enlace a proposito descargando de: $url"
    Write-Host 'Tarda ~15 s y consume datos. Solo descarga: no se envia nada de tu equipo.'
    Write-Host ''
    $r = Measure-AXENetLoaded -Target $NetMonTarget -Count $NetMonCount -Url $url
    Write-Host (Format-AXENetLoaded $r)
    exit ([int]($r.Verdict.Status -eq 'BAD'))
}
if($Mouse){
    # Sondeo del raton (region 10f). Necesita movimiento: sin el, Get-AXEMouseRate devuelve
    # UNKNOWN con el motivo, que es la respuesta honesta y no un numero inventado.
    Write-Host ''
    Write-Host "MUEVE EL RATON EN CIRCULOS SIN PARAR durante $MouseSeconds segundos, ahora."
    Write-Host ''
    $iv   = Measure-AXEMouseIntervals -Seconds $MouseSeconds
    $rate = Get-AXEMouseRate -Intervals $iv
    $f    = Get-AXEMouseFindings -Rate $rate -Settings (Get-AXEMouseSettings)
    foreach($line in (Format-AXELatency -Findings $f)){ Write-Host $line }
    exit ([int](@($f | Where-Object Status -eq 'BAD').Count -gt 0))
}
if($Dpc){
    # Tiempo en DPC/ISR (region 10f). Solo lee contadores del kernel: no necesita admin, no
    # abre traza ETW y no toca nada.
    Write-Host ''
    Write-Host "Midiendo tiempo en rutinas de drivers durante $DpcSeconds segundos..."
    $d = Measure-AXEDpc -Seconds $DpcSeconds
    $f = Get-AXEDpcFindings -Dpc $d
    Write-Host ''
    foreach($line in (Format-AXELatency -Findings $f -WithDpcNote)){ Write-Host $line }
    exit ([int](@($f | Where-Object Status -eq 'BAD').Count -gt 0))
}

# --- GPU POR JUEGO (region 10c) -------------------------------------------------------
# Escriben en HKCU, asi que NO piden admin: se pueden correr sin el launcher .bat.
if($GameList){
    Write-Host '== AXE - GPU POR JUEGO =='
    $gpus = Get-AXEGpuList
    Write-Host ("GPUs: {0}" -f (($gpus | Select-Object -Expand Name) -join ' | '))
    if(Test-AXEHybridGpu){
        Write-Host 'Equipo HIBRIDO: forzar la dedicada es el mayor lever de FPS de toda la suite.'
    } else {
        Write-Host 'Una sola GPU: GpuPreference no aplica en este equipo (ganancia por esa via = 0).'
    }
    Write-Host ''
    $k = Get-Item $script:GpuPrefKey -EA SilentlyContinue
    if(-not $k -or $k.GetValueNames().Count -eq 0){
        Write-Host 'Sin entradas: Windows decide la GPU de todo por heuristica.'
        exit 0
    }
    foreach($n in $k.GetValueNames()){
        $st  = Get-AXEGameGpuState $n
        # 'Windows decide' NO es lo mismo que 'GpuPreference=0'. Se distinguen a posta: la
        # clave ausente es el estado de fabrica; el 0 explicito lo escribio alguien (AXE al
        # apagar el ajuste, o el propio usuario en Configuracion).
        $pref = (ConvertFrom-AXEGpuPref $st.Raw)['GpuPreference']
        $gpu  = switch($pref){ '2'{'dGPU'} '1'{'iGPU'} '0'{'delegado (0)'} default{'Windows decide'} }
        "{0,-15} flip={1,-3} fso={2,-3} {3}" -f $gpu,$(if($st.FlipModel){'si'}else{'no'}),$(if($st.NoFSO){'off'}else{'on'}),(Split-Path $n -Leaf) | Write-Host
    }
    exit 0
}
if($OptimizeGame){
    Write-Host '== AXE - OPTIMIZAR JUEGO =='
    # Se resuelve a ruta absoluta: el registro indexa por ruta COMPLETA, asi que una relativa
    # crearia una entrada que Windows no va a mirar nunca (fallo silencioso).
    $full = try { (Resolve-Path -LiteralPath $OptimizeGame -EA Stop).Path } catch { $OptimizeGame }
    Write-Host "Objetivo: $full"
    foreach($line in (Optimize-AXEGame -Exe $full -NoFSO:$NoFSO)){ Write-Host "  $line" }
    Write-Host ''
    Write-Host "Deshacer: -RevertGame `"$full`""
    exit 0
}
if($Fps){
    Write-Host '== AXE - FPS REALES (PresentMon) =='
    if(-not (Get-AXEPresentMon)){
        # Se sale sin medir en vez de ensenar ceros: un informe de FPS vacio presentado como
        # medicion es peor que no medir.
        Write-Host '  PresentMon no encontrado.'
        Write-Host '  Bajalo de https://github.com/GameTechDev/PresentMon/releases'
        Write-Host '  y deja PresentMon.exe junto a AXE (o define AXE_PRESENTMON).'
        Write-Host '  AXE no lo descarga solo: bajar y ejecutar binarios de internet no es cosa de una herramienta que corre como admin.'
        exit 1
    }
    if(-not $FpsCompare){
        Write-Host "Capturando $FpsSeconds s de '$Fps'..."
        foreach($l in (Format-AXEFpsStats (Measure-AXEFps -ProcessName $Fps -Seconds $FpsSeconds) 'Captura')){ Write-Host $l }
        exit 0
    }
    # Modo comparacion: dos capturas con una pausa manual en medio. La pausa es a posta y NO se
    # automatiza: entre una y otra hay que aplicar el cambio Y volver a la MISMA escena, y eso
    # solo lo puede hacer una persona. Automatizarlo produciria comparaciones de escenas
    # distintas con pinta de rigor, que es peor que no medir.
    #   OJO: este modo BLOQUEA en Read-Host. Solo se llega con -Fps explicito, asi que ni el
    # gate de build.ps1 ni la GUI lo tocan; no meterlo nunca en un runspace de fondo.
    Write-Host "1/2 - captura ANTES ($FpsSeconds s). Ponte en la escena que vas a repetir."
    Read-Host '     Enter cuando estes listo' | Out-Null
    $b = Measure-AXEFps -ProcessName $Fps -Seconds $FpsSeconds
    foreach($l in (Format-AXEFpsStats $b 'ANTES')){ Write-Host $l }
    if(-not $b.Ok){ exit 1 }
    Write-Host ''
    Write-Host '2/2 - aplica el cambio, vuelve a la MISMA escena y repite el mismo recorrido.'
    Read-Host '     Enter cuando estes listo' | Out-Null
    $a = Measure-AXEFps -ProcessName $Fps -Seconds $FpsSeconds
    foreach($l in (Format-AXEFpsStats $a 'DESPUES')){ Write-Host $l }
    if(-not $a.Ok){ exit 1 }
    $v = Get-AXEFpsVerdict -Before $b -After $a
    Write-Host ''
    Write-Host '-- VEREDICTO --'
    Write-Host $(if($v.Conclusive){ "  CONCLUYENTE: $($v.Reason)" } else { "  NO CONCLUYENTE: $($v.Reason)" })
    if($v.Warning){ Write-Host "  AVISO: $($v.Warning)" }
    exit 0
}
if($RevertGame){
    Write-Host '== AXE - DESHACER JUEGO =='
    $full = try { (Resolve-Path -LiteralPath $RevertGame -EA Stop).Path } catch { $RevertGame }
    $n = Revert-AXEGameGpu $full
    if($n -eq 0){
        # No se inventa un estado: si AXE nunca toco ese exe, no hay original que restaurar.
        Write-Host "  Sin captura previa para '$full': AXE no lo ha tocado, no revierto nada."
        Write-Host '  (Escribir un default aqui seria dejarte un estado que quiza nunca tuviste.)'
    } else {
        Write-Host "  Restauradas $n clave(s) al estado exacto que habia antes."
    }
    exit 0
}

# --- DAEMON DE SESION DE JUEGO (region 12b, spec 2026-07-20) --------------------------
# Congela el fondo mientras el juego corre y descongela al cerrar el juego (o AXE). El handle
# del job vive en ESTE proceso: si AXE muere, el kernel descongela solo. Recomendado como admin
# (via AXE.bat) para poder tocar procesos del sistema; sin admin degrada a lo que el usuario posee.
if($Session){
    Write-Host '== AXE - SESION DE JUEGO (congela el fondo) =='
    # Si la sesion anterior murio sucia (kill/BSOD), el kernel descongelo pero las prioridades
    # degradadas siguen bajas: eso no es estado del job. El diario en disco las devuelve.
    $repaired = 0
    try { $repaired = [int](Restore-AXESessionDegraded) } catch {}
    if($repaired -gt 0){ Write-Host "  Restauradas $repaired prioridad(es) de una sesion anterior que no cerro limpiamente." }
    $sess = Start-AXESession -GameName $Session
    foreach($line in (Format-AXESession $sess)){ Write-Host $line }
    if(-not $sess.Ok){ exit 1 }
    Write-Host ''
    Write-Host 'Sesion activa. Cierra el juego o pulsa Ctrl+C para descongelar el fondo.'
    try {
        Watch-AXESession -Session $sess -PollMs $SessionPoll
    } finally {
        # Salida normal (juego cerrado) o Ctrl+C: descongela y restaura prioridades. Si esto no
        # llega a correr (kill duro de AXE), el kernel descongela igual al cerrarse el handle.
        Stop-AXESession $sess
        Write-Host 'Sesion cerrada: fondo descongelado y prioridades restauradas.'
    }
    exit 0
}



# >>>>> MODULE: 47-webhost.ps1 >>>>>
# =====================================================
# REGION 13 - WEBVIEW2 HOST (carcasa WPF fina)
# =====================================================
# Aloja UN control WebView2 a pantalla completa. Toda la UI vive en web (webui/).
# La deteccion (runtime + SDK + rutas) esta en 39-webdetect. Aqui solo el HOST.
# Unico frontend desde el cutover (Fase 8): la GUI WPF vieja (50-60, 99) se retiro. El arranque
# (bootstrap) vive en 49-webmain, que carga tras 48 para que Register-AXEBridge exista al invocarlo.

function Show-AXEWebHost {
    # Guard STA (WPF lo exige; el .bat pasa -STA, esto cubre run directo).
    if($env:AXE_WEBUI_TEST -ne '1' -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){
        Write-Host 'WebView2/WPF requiere STA. Relanza via AXE.bat.'; return
    }
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $sdk = Get-AXEWebView2SdkPath
    if(-not $sdk){ [System.Windows.MessageBox]::Show('Faltan los DLL de WebView2 (AXE/webview2/). Reinstala AXE.','AXE','OK','Error') | Out-Null; return }
    # Orden de carga: Core antes que Wpf. El nativo WebView2Loader.dll lo resuelve el runtime
    # desde runtimes\win-x64\native. Add-Type idempotente (si ya cargo en esta sesion, no repite).
    try {
        Add-Type -Path (Join-Path $sdk 'Microsoft.Web.WebView2.Core.dll') -EA Stop
        Add-Type -Path (Join-Path $sdk 'Microsoft.Web.WebView2.Wpf.dll')  -EA Stop
    } catch {
        Write-AXELog "No pude cargar los DLL de WebView2: $($_.Exception.Message)" 'ERR'
        [System.Windows.MessageBox]::Show("No pude cargar WebView2:`n$($_.Exception.Message)",'AXE','OK','Error') | Out-Null
        return
    }

    # WebView2Loader.dll (nativo): precargarlo por RUTA ABSOLUTA antes de CreateAsync. El Core.dll
    # lo carga con busqueda "segura" (LOAD_LIBRARY_SEARCH_*), que IGNORA PATH y CWD; por eso ni
    # prepender PATH ni el CWD bastan, y da 0x8007007E ERROR_MOD_NOT_FOUND. Si ya esta cargado en el
    # proceso por ruta completa, el LoadLibrary("WebView2Loader.dll") posterior del SDK resuelve al
    # modulo ya presente (match por nombre base). LoadLibrary (kernel32) via P/Invoke funciona en
    # PS 5.1 y 7. MemberDefinition en una sola linea: evita here-strings que el build concatena mal.
    $rid = if($env:PROCESSOR_ARCHITECTURE -match 'ARM64'){ 'win-arm64' } else { 'win-x64' }
    $nativeDir  = Join-Path $sdk (Join-Path 'runtimes' (Join-Path $rid 'native'))
    $loaderPath = Join-Path $nativeDir 'WebView2Loader.dll'
    if(Test-Path $loaderPath){
        if(-not ('AXE.NativeLoad' -as [type])){
            Add-Type -Namespace AXE -Name NativeLoad -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr LoadLibrary(string lpFileName);' -ErrorAction SilentlyContinue
        }
        $h = [IntPtr]::Zero
        try { $h = [AXE.NativeLoad]::LoadLibrary($loaderPath) } catch {}
        if($h -eq [IntPtr]::Zero){ Write-AXELog "No pude precargar WebView2Loader.dll ($loaderPath)" 'WARN' }
    } else {
        Write-AXELog "WebView2Loader.dll ausente en $nativeDir (arch $rid)" 'WARN'
    }

    $rt  = Get-AXEWebView2Runtime
    $bc  = New-Object System.Windows.Media.BrushConverter
    $win = New-Object System.Windows.Window

    # Tamano CALCULADO, no fijado. SystemParameters.WorkArea da el escritorio util en DIP -las
    # mismas unidades que Window.Width/Height-, asi que recortar contra el resuelve el escalado de
    # Windows sin tocar DPI ni manifiestos: a 125% o 150% hay menos DIP y la ventana se encoge sola.
    # WorkArea ya descuenta la barra de tareas. La decision vive en Get-AXEWindowFit (39-webdetect,
    # pura y testeada); aqui solo se lee el escritorio y se aplica.
    $wa  = [System.Windows.SystemParameters]::WorkArea
    $fit = Get-AXEWindowFit -WorkWidth $wa.Width -WorkHeight $wa.Height
    $win.Title='AXE'
    $win.Width=$fit.Width; $win.Height=$fit.Height
    $win.MinWidth=$fit.MinWidth; $win.MinHeight=$fit.MinHeight
    $win.WindowStartupLocation='CenterScreen'
    if($fit.Reason){ Write-AXELog $fit.Reason }
    $win.Background=$bc.ConvertFrom('#0E1013')
    $script:WebWin = $win

    if(-not $rt.Available){
        # Runtime ausente: no pantalla en blanco. Mensaje claro con enlace (riesgo #4 del spec).
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text=$rt.Reason; $tb.TextWrapping='Wrap'; $tb.Margin='40'; $tb.FontSize=15
        $tb.Foreground=$bc.ConvertFrom('#E6EAF0')
        $win.Content=$tb
        if($env:AXE_WEBUI_TEST -eq '1'){ Write-Host 'WEBHOST OK (sin runtime, mensaje mostrado)'; return }
        [void]$win.ShowDialog(); return
    }

    $web = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $script:Web = $web
    $win.Content = $web

    # user data folder fuera de Archivos de programa (powershell.exe corre desde System32, sin
    # permiso de escritura). Se pasa explicito a CreateAsync en Loaded (el env var no se honra).
    $udf = Join-Path $env:LOCALAPPDATA 'AXE\WebView2'
    if(-not (Test-Path $udf)){ New-Item -ItemType Directory -Path $udf -Force | Out-Null }
    $script:Udf = $udf

    # Init asincrono: suscribir el evento ANTES de EnsureCoreWebView2Async. Cuando complete,
    # mapear el host virtual y navegar.
    $web.Add_CoreWebView2InitializationCompleted({
        param($s,$e)
        if(-not $e.IsSuccess){ Write-AXELog "WebView2 init fallo: $($e.InitializationException)" 'ERR'; return }
        $core = $s.CoreWebView2
        # host virtual -> carpeta local, solo lectura (Deny cross-origin).
        $core.SetVirtualHostNameToFolderMapping('axe.local', $script:WebUIDir, 'Deny')
        if($env:AXE_WEBUI_DEBUG -ne '1'){
            $core.Settings.AreDefaultContextMenusEnabled = $false
            $core.Settings.AreDevToolsEnabled = $false
        }
        $core.Settings.IsStatusBarEnabled = $false
        # Zoom: se restaura el elegido la vez anterior y se guarda cada vez que cambia. Sin esto
        # Ctrl+rueda funcionaba pero se olvidaba al cerrar, que para quien necesita la interfaz mas
        # grande equivale a no tenerlo. Guardar es best-effort (Set-AXEUIZoom no lanza).
        try { $s.ZoomFactor = (Get-AXEUIZoom) } catch {}
        $s.Add_ZoomFactorChanged({ param($zs,$ze) try { [void](Set-AXEUIZoom $zs.ZoomFactor) } catch {} })
        Register-AXEBridge $core   # Fase 2: define el despacho JS->PS (48-webbridge).
        $s.Source = [uri]'https://axe.local/index.html'
    })
    # En Loaded (dispatcher YA corriendo tras ShowDialog): crear el entorno con NUESTRO user-data
    # folder y luego el controlador. Pasar $null como entorno hace que WebView2 use la carpeta por
    # defecto (junto a powershell.exe en System32, sin permiso) => COMException E_UNEXPECTED en
    # CreateCoreWebView2ControllerAsync. CreateAsync corre en el threadpool (no necesita el hilo UI),
    # asi que GetResult() no deadlockea; EnsureCoreWebView2Async con el entorno ya hecho crea el
    # controlador en el hilo UI con el loop vivo. En AXE_WEBUI_TEST no hay ShowDialog => Loaded no
    # dispara: el smoke test solo valida que carcasa+control se construyen.
    $win.Add_Loaded({
        try {
            $cwEnv = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $script:Udf, $null).GetAwaiter().GetResult()
            $script:Web.EnsureCoreWebView2Async($cwEnv) | Out-Null
        } catch { Write-AXELog "WebView2 entorno/init fallo: $($_.Exception.Message)" 'ERR' }
    })

    # Liberar timers/runspaces de telemetria al cerrar (definidos en Fase 3/5; defensivo aqui).
    $win.Add_Closed({
        if($script:TelemetryTimer){ try { $script:TelemetryTimer.Stop() } catch {} }
        if($script:TelemPS){ try { $script:TelemPS.Stop() } catch {}; try { $script:TelemPS.Dispose() } catch {} }
        if($script:TelemRS){ try { $script:TelemRS.Close() } catch {} }
        # Sesion de juego activa: cerrarla AQUI. Lo CONGELADO lo descongela el kernel al morir el
        # proceso -esa es la garantia del diseño-, pero la prioridad de lo DEGRADADO no es estado del
        # job y el kernel no la devuelve: sin esto, cerrar la ventana dejaba el navegador en
        # BelowNormal hasta reiniciarlo. La salida sucia (kill/BSOD) la cubre el diario en disco.
        if(Get-Command Get-AXESessionCurrent -EA SilentlyContinue){
            try { if(Get-AXESessionCurrent){ [void](Stop-AXESessionTracked -Reason 'AXE se cerro.') } } catch {}
        }
    })

    if($env:AXE_WEBUI_TEST -eq '1'){ Write-Host 'WEBHOST OK'; return }
    [void]$win.ShowDialog()
}

# El arranque (bootstrap) vive en 49-webmain.ps1, que carga DESPUES de 48-webbridge, para que
# Register-AXEBridge (48) este definido cuando Show-AXEWebHost lo invoque. Si el arranque viviera
# aqui, su 'exit 0' cortaria la carga antes de 48 y el puente quedaria sin enganchar (JS->PS muerto).


# >>>>> MODULE: 48-webbridge.ps1 >>>>>
# =====================================================
# REGION 14 - PUENTE RPC (JS <-> PS). SUPERFICIE DE ATAQUE.
# =====================================================
# Regla dura: lista blanca cerrada. cmd fuera de la lista => rechazo. Nunca eval del payload.
# Cargar este modulo SOLO define funciones y el mapa; nada se ejecuta hasta Register-AXEBridge
# (lo llama 47-webhost en el init del control). Cada cmd mapea a una funcion YA EXISTENTE del
# motor (1-45); aqui no se anade logica de negocio.

# Mapa cerrado: cmd -> scriptblock($args) que devuelve el 'data' (o lanza).
# Cada entrada llama SOLO a funciones ya existentes del motor (1-45). Sin logica de negocio nueva:
# aqui solo se re-empaqueta a un DTO plano y JSON-seguro (nulls en vez de 'n/a' donde el front
# decide como pintar). La honestidad del motor se preserva: si algo no se midio, viaja null.
$script:AXEBridgeMap = @{
    'hw.get' = { param($a)
        # Get-AXEHardware ya degrada campo a campo y no deberia lanzar. El try es defensa en
        # profundidad: si una regresion futura la hace lanzar, el panel de hardware entero
        # desaparecia de la ventana por un solo campo roto. Mejor devolver lo que haya con el
        # fallo declarado en DetectWarnings, que es donde la interfaz ya sabe mirar.
        if(-not $script:HW){
            try { $script:HW = Get-AXEHardware }
            catch {
                Write-AXELog ("hw.get: la deteccion de hardware fallo entera: {0}" -f $_.Exception.Message) 'ERR'
                return [pscustomobject]@{ DetectWarnings=@("la deteccion de hardware fallo entera: $($_.Exception.Message)") }
            }
        }
        $script:HW
    }

    # Identidad de la app: version (00-header, la fija build.ps1) + tamano del catalogo.
    # El front la usa para el rotulo del rail; los assets estaticos NO pasan por el tokenizador
    # de build, asi que la version tiene que llegar por el puente, no incrustada en el HTML.
    'app.info' = { param($a)
        [pscustomobject]@{
            version = [string]$script:AXEVersion
            tweaks  = [int]($script:CAT | Measure-Object).Count
        }
    }

    # Medicion real (timer + jitter + cobertura). Get-AXESnapshot corre el busy-loop de jitter
    # (~1s) en ESTE hilo (UI); no congela el render (WebView2 es out-of-process) pero si retrasa
    # otras respuestas ~1s. Fase 5 lo mueve a un runspace de fondo. DTO plano para el gauge.
    'measure.score' = { param($a)
        $snap = Get-AXESnapshot
        $sc   = Get-AXEScore $snap
        $timerMs = $null; if($snap.Timer  -isnot [string]){ $timerMs = $snap.Timer.CurrentMs }
        $p999 = $null; $jMean = $null
        if($snap.Jitter -isnot [string]){ $p999 = $snap.Jitter.P999Ms; $jMean = $snap.Jitter.MeanMs }
        $onN = $null; $appN = $null
        if($snap.TweaksApplicable -isnot [string]){ $onN = [int]$snap.TweaksOn; $appN = [int]$snap.TweaksApplicable }
        [pscustomobject]@{
            total      = [int]$sc.Total
            timer      = $sc.Timer      # int 0-30 o 'n/a'
            jitter     = $sc.Jitter     # int 0-35 o 'n/a'
            coverage   = $sc.Coverage   # int 0-25 o 'n/a'
            idle       = $sc.Idle
            timerMs    = $timerMs       # resolucion instantanea (ms) o null
            jitterP999 = $p999          # P99.9 (ms) o null
            jitterMean = $jMean
            on         = $onN           # tweaks Tier0/1 activos o null
            app        = $appN          # tweaks Tier0/1 aplicables o null
            ts         = $snap.Timestamp
            breakdown  = $sc.Breakdown  # texto multilinea, la 'receta'
        }
    }

    # Metadatos del catalogo: total por tier. Barato y real (no lee registro, no aplica nada).
    'catalog.tiers' = { param($a)
        if(-not $script:CAT){ return @() }
        @($script:CAT | Group-Object Tier | Sort-Object { [int]$_.Name } | ForEach-Object {
            [pscustomobject]@{ tier = [int]$_.Name; total = [int]$_.Count }
        })
    }

    # --- Fase 6: Optimizar (catalogo + aplicar/revertir) ---
    # tweaks.list es READ-ONLY (corre cada Test via Test-TweakSafe; algunos Tests leen CIM => la
    # primera pasada tarda unos segundos). apply/revert/masterRevert MODIFICAN el sistema: exigen
    # admin (Test-Admin) y usan EXACTAMENTE el camino probado del motor (Test-SnapEligible/capTweak/
    # Apply; Restore-TweakState o Revert), sin logica nueva. Get-BlockReason evita aplicar en HW
    # incompatible. El front confirma Tier 2 y el master revert antes de disparar.
    'tweaks.list' = { param($a)
        @($script:CAT | ForEach-Object {
            $tw = $_
            $blk = $null; try { $blk = Get-BlockReason $tw } catch {}
            $applied = $false; if(-not $blk){ try { $applied = [bool](Test-TweakSafe $tw) } catch {} }
            [pscustomobject]@{
                id=$tw.Id; name=$tw.Name; desc=$tw.Desc; cat=$tw.Cat; tier=[int]$tw.Tier
                reboot=[bool]$tw.Reboot; source=$tw.Source; sourceType=$tw.SourceType
                placebo=[bool]$tw.PlaceboLikely; applied=$applied; blocked=$blk
            }
        })
    }
    'tweaks.apply' = { param($a)
        if(-not (Test-Admin)){ throw 'requiere admin: relanza AXE con AXE.bat (se eleva solo)' }
        $tw = $script:CAT | Where-Object Id -eq ([string]$a.id) | Select-Object -First 1
        if(-not $tw){ throw "tweak desconocido: $($a.id)" }
        $blk = Get-BlockReason $tw
        if($blk){ throw "no aplicable en este equipo: $blk" }
        if(Test-SnapEligible $tw){ $script:capTweak = $tw.Id }
        try { & $tw.Apply } finally { $script:capTweak = $null }
        [pscustomobject]@{ id=$tw.Id; applied=[bool](Test-TweakSafe $tw); reboot=[bool]$tw.Reboot }
    }
    'tweaks.revert' = { param($a)
        if(-not (Test-Admin)){ throw 'requiere admin: relanza AXE con AXE.bat (se eleva solo)' }
        $tw = $script:CAT | Where-Object Id -eq ([string]$a.id) | Select-Object -First 1
        if(-not $tw){ throw "tweak desconocido: $($a.id)" }
        if(-not ((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){ & $tw.Revert }
        [pscustomobject]@{ id=$tw.Id; applied=[bool](Test-TweakSafe $tw); reboot=[bool]$tw.Reboot }
    }
    'tweaks.masterRevert' = { param($a)
        if(-not (Test-Admin)){ throw 'requiere admin: relanza AXE con AXE.bat (se eleva solo)' }
        $done = 0; $err = 0
        foreach($tw in $script:CAT){
            try {
                if(Get-BlockReason $tw){ continue }
                if(-not (Test-TweakSafe $tw)){ continue }   # solo revertir lo que esta aplicado
                if(-not ((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){ & $tw.Revert }
                $done++
            } catch { $err++; Write-AXELog "MasterRevert: $($tw.Name): $($_.Exception.Message)" 'ERR' }
        }
        try { Invoke-AXEMasterRevertTail } catch { Write-AXELog "MasterRevertTail: $($_.Exception.Message)" 'ERR' }
        [pscustomobject]@{ reverted=$done; errors=$err }
    }

    # --- Fase 7: Telemetria / Prueba / Seguridad ---
    # Todo re-empaqueta funciones YA EXISTENTES del motor (32/33/34/35/36). El front pinta las
    # 'lines' del motor TAL CUAL (mismo texto que la CLI): la honestidad vive en el motor, no aqui.

    # Barrido de resolucion de timer (§3.5). Corre el busy-loop nativo N pasadas en ESTE hilo (UI):
    # tarda ~1-2s y retrasa otras respuestas ese rato; no congela el render (WebView2 out-of-process).
    'measure.timerSweep' = { param($a)
        $sw = Measure-AXETimerSweep
        if(-not $sw){ throw 'barrido no disponible (AXE.Native ausente o rango invalido; ver log)' }
        $bestMs = $null; if($sw.Conclusive -and $sw.Best){ $bestMs = [double]$sw.Best.AppliedMs }
        [pscustomobject]@{
            lines      = @(Format-AXETimerSweep $sw)
            conclusive = [bool]$sw.Conclusive
            bestMs     = $bestMs
            originalMs = $sw.OriginalMs
        }
    }

    # Monitor de red (37-netmon.ps1). BLOQUEANTE por diseno: count * intervalo (~4s con los
    # valores por defecto). Se acota el count por el mismo motivo que fps.capture acota los
    # segundos: el payload viene del front y un numero grande dejaria el puente mudo un rato
    # largo. Solo mide; ninguna rama de este cmd escribe nada.
    'net.probe' = { param($a)
        $n = 20; if($a.count){ $n = [int]$a.count }
        if($n -lt 4){ $n = 4 }; if($n -gt 60){ $n = 60 }
        $r = Measure-AXENetwork -Count $n
        # Los stats viajan tal cual (ya son planos y JSON-seguros); null donde no se midio, que
        # es lo que el front necesita para pintar '—' en vez de inventar un cero.
        [pscustomobject]@{
            adapter  = $r.Adapter
            isWifi   = $r.IsWifi
            gateway  = $r.Gateway
            public   = $r.Public
            findings = @($r.Findings | ForEach-Object { [pscustomobject]@{ sev=[string]$_.Sev; msg=[string]$_.Msg } })
            lines    = @((Format-AXENetwork $r) -split "`r?`n")
            ts       = $r.Timestamp
        }
    }

    # Captura de FPS con PresentMon. BLOQUEANTE: Start-Process -Wait durante 'seconds' (default 20s)
    # y requiere admin (sesion ETW). Devuelve Ok/lines del motor; si no puede, el motor da el motivo
    # honesto (PresentMon ausente, juego no abierto, sin permisos) y viaja en 'lines'.
    'fps.capture' = { param($a)
        if(-not $a.process){ throw 'proceso requerido (ej: cs2, valorant)' }
        $secs = 20; if($a.seconds){ $secs = [int]$a.seconds }
        if($secs -lt 3){ $secs = 3 }; if($secs -gt 120){ $secs = 120 }
        $s = Measure-AXEFps -ProcessName ([string]$a.process) -Seconds $secs
        [pscustomobject]@{ ok=[bool]$s.Ok; lines=@(Format-AXEFpsStats $s 'Captura') }
    }

    # Diagnostico de configuracion (XMP, refresh, SSD...). PURO tras leer hechos por CIM. No aplica
    # nada. Devuelve las lineas del motor + un DTO plano de hallazgos para pintar tarjetas.
    'diag.get' = { param($a)
        $facts = Get-AXEDiagFacts
        $find  = Get-AXEDiagFindings -Facts $facts
        $bad = @($find | Where-Object Status -eq 'BAD').Count
        $unk = @($find | Where-Object Status -eq 'UNKNOWN').Count
        [pscustomobject]@{
            lines    = @(Format-AXEDiag -Findings $find)
            bad      = [int]$bad
            unknown  = [int]$unk
            findings = @($find | ForEach-Object {
                [pscustomobject]@{ id=$_.Id; status=$_.Status; title=$_.Title; detail=$_.Detail
                    fix=$_.Fix; estPct=$_.EstPct; confidence=$_.Confidence }
            })
        }
    }

    # Prueba A/B (Trust & Proof). New-AXEReport NO es de un tiro: exige snapshot ANTES y DESPUES.
    # Asi que el flujo honesto es en dos pasos y con estado de sesion:
    #   prueba.baseline  -> mide y GUARDA el 'antes' (snap0 + score0) en variables de sesion.
    #   prueba.report    -> mide el 'despues' (snap1 + score1 vs snap0) y arma el informe real.
    # Sin baseline, prueba.report se niega (no inventa un 'antes'). Reinicia el par cada baseline.
    'prueba.baseline' = { param($a)
        $snap0 = Get-AXESnapshot
        $sc0   = Get-AXEScore $snap0
        $script:PruebaSnap0  = $snap0
        $script:PruebaScore0 = $sc0
        $timerMs = $null; if($snap0.Timer -isnot [string]){ $timerMs = $snap0.Timer.CurrentMs }
        $p999 = $null; if($snap0.Jitter -isnot [string]){ $p999 = $snap0.Jitter.P999Ms }
        [pscustomobject]@{ total=[int]$sc0.Total; timerMs=$timerMs; jitterP999=$p999; ts=$snap0.Timestamp }
    }
    'prueba.report' = { param($a)
        if(-not $script:PruebaSnap0){ throw 'sin linea base: mide el ANTES primero (Capturar baseline)' }
        $snap1 = Get-AXESnapshot
        $sc1   = Get-AXEScore $snap1 $script:PruebaSnap0
        $timerMs = $null; if($snap1.Timer -isnot [string]){ $timerMs = $snap1.Timer.CurrentMs }
        $p999 = $null; if($snap1.Jitter -isnot [string]){ $p999 = $snap1.Jitter.P999Ms }
        $report = New-AXEReport $script:PruebaSnap0 $snap1 $script:PruebaScore0 $sc1
        [pscustomobject]@{
            lines  = @($report -split "`r?`n")
            before = [int]$script:PruebaScore0.Total
            after  = [int]$sc1.Total
            afterTimerMs = $timerMs; afterJitterP999 = $p999
        }
    }

    # Benchmark "pruebalo en tu PC" (region 8e, spec 2026-07-24). Es el hermano SERIO de
    # prueba.baseline/prueba.report: aquel compara DOS snapshots sueltos de la misma sesion (util
    # para ver el efecto inmediato de un tweak); este agrega N pasadas, mide el ruido, sobrevive a
    # un reinicio (el 'antes' vive en disco) y se niega a llamar mejora a lo que cae dentro del
    # ruido. Por eso conviven en vez de sustituirse.
    #   BLOQUEANTE: N pasadas x (jitter + cobertura) en el hilo UI, del orden de 10-30 s con los
    # valores por defecto. Se declara aqui igual que en fps.capture, en vez de disimularlo.
    'bench.baseline' = { param($a)
        $p = 7; if($a.passes){ $p = [int]$a.passes }
        if($p -lt 3){ $p = 3 }; if($p -gt 25){ $p = 25 }
        $s = Measure-AXEBenchSample -Passes $p
        $id = Save-AXEBenchBaseline $s
        if(-not $id){ throw 'no pude guardar la linea base (ver log)' }
        [pscustomobject]@{
            id     = [string]$id
            passes = [int]$s.passes
            lines  = @(Format-AXEBenchSample $s 'LINEA BASE')
        }
    }
    'bench.after' = { param($a)
        if(-not $a.id){ throw 'falta el id de la linea base' }
        $before = Read-AXEBenchBaseline ([string]$a.id)
        if(-not $before){ throw "no hay linea base con id '$($a.id)' (o esta corrupta)" }
        # Maquina/build/version distintas => se niega. Un delta entre equipos no mide un cambio.
        $why = Test-AXEBenchComparable $before
        if($why){ throw $why }
        $after   = Measure-AXEBenchSample -Passes ([int]$before.passes) -JitterMs ([int]$before.jitterMs)
        $verdict = Get-AXEBenchVerdict $before $after
        $rep     = New-AXEBenchReport $before $after $verdict
        [pscustomobject]@{
            lines    = @($rep.Text)
            markdown = [string]$rep.Markdown
            verdict  = @($verdict | ForEach-Object {
                [pscustomobject]@{ key=$_.Key; label=$_.Label; unit=$_.Unit
                    before=$_.Before; after=$_.After; delta=$_.Delta
                    noise=$_.Noise; conclusive=[bool]$_.Conclusive; tag=$_.Tag; reason=$_.Reason }
            })
        }
    }

    # Punto de restauracion del sistema. Best-effort, NUNCA lanza: devuelve {Status;Message}. En
    # anticheat / SR deshabilitado da Status='fallback' con el motivo (no es un error de AXE).
    'safety.restorePoint' = { param($a)
        if(-not (Test-Admin)){ throw 'requiere admin: relanza AXE con AXE.bat (se eleva solo)' }
        $r = New-AXERestorePoint
        [pscustomobject]@{ status=[string]$r.Status; message=[string]$r.Message }
    }

    # --- Sesion de juego (region 12b + spec 2026-07-25) ---
    # El ciclo de vida vive en 40-session (Start/Stop/Sync-AXESessionTracked): aqui solo se
    # re-empaqueta, como manda la cabecera de este fichero. session.preview es READ-ONLY: enseña el
    # reparto ANTES de congelar nada (ni job, ni assign, ni freeze) porque congelar ~15 procesos es
    # la accion mas agresiva de AXE y un ON a ciegas pide una confianza que no se ha ganado.
    'session.preview' = { param($a)
        $game  = [string]$a.game
        $gproc = $null
        if(-not [string]::IsNullOrWhiteSpace($game)){
            $gproc = Get-Process -Name ($game -replace '\.exe$','') -EA SilentlyContinue | Select-Object -First 1
        }
        # Sonda de JobObjectFreezeInformation: si no esta, la sesion se abortaria sin tocar nada
        # (regla del spec A: sin fallback a suspension manual). El front deshabilita ON con esto.
        $freezeOk = $false; $freezeReason = 'capa nativa de sesion ausente (reinicia AXE tras rebuild).'
        if(('AXE.Native' -as [type]) -and [AXE.Native].GetMethod('JobProbeFreeze')){
            $probe = [AXE.Native]::JobProbeFreeze()
            if($probe -eq 0){ $freezeOk = $true; $freezeReason = $null }
            else { $freezeReason = ("JobObjectFreezeInformation no disponible aqui (status 0x{0:X8}): la sesion se abortaria sin tocar nada." -f $probe) }
        }
        # Sin juego abierto el plan se enseña IGUAL (es informativo) contra la sesion interactiva de
        # AXE; gameFound=false y el front no deja arrancar.
        $gpid = 0; $sid = [int](Get-Process -Id $PID).SessionId
        if($gproc){ $gpid = [int]$gproc.Id; $sid = [int]$gproc.SessionId }
        $ovr   = Read-AXESessionOverrides
        $plan  = Get-AXESessionPlan -Processes (Get-AXESessionProcesses) -GamePid $gpid -GameName $game -SelfPid $PID -SessionId $sid -Config $ovr
        # Una fila por (APP, NIVEL), no por pid: 12 procesos de Chrome son UNA decision, no doce.
        #   La clave lleva el nivel a proposito. Agrupar solo por nombre mezclaba procesos con trato
        # distinto: si el juego -o AXE- comparte nombre con otro proceso (dos pwsh, dos instancias
        # del mismo launcher), la fila se creaba en el pase 'congelado' por el ajeno y luego se
        # marcaba dura por el propio => el DTO decia "congelar" y "intocable" a la vez. Con el nivel
        # en la clave cada fila dice la verdad de su grupo y los pids viajan para auditarla.
        $groups = @{ congelado=@($plan.Congelado); degradado=@($plan.Degradado); intacto=@($plan.Intacto) }
        $rows = [ordered]@{}
        foreach($lvl in 'congelado','degradado','intacto'){
            foreach($p in $groups[$lvl]){
                $n   = Get-AXESessionAppName $p.Name
                $key = "$n|$lvl"
                if(-not $rows.Contains($key)){
                    $rows[$key] = [pscustomobject]@{
                        name=$n; level=$lvl; count=0; pids=@()
                        family=(Get-AXESessionFamily $n); hard=[bool](Test-AXESessionHardApp $n)
                        override=[bool]($ovr.ContainsKey($n))
                    }
                }
                $r = $rows[$key]
                $r.count = [int]$r.count + 1
                $r.pids  = @($r.pids) + [int]$p.Pid
                # El juego y AXE tampoco se configuran mientras sean ESTOS pids (siempre en intacto).
                if([int]$p.Pid -eq $gpid -or [int]$p.Pid -eq $PID){ $r.hard = $true }
            }
        }
        $order = @('congelado','degradado','intacto')
        $apps  = @(@($rows.Values) | Sort-Object @{Expression={ $order.IndexOf($_.level) }}, @{Expression='count';Descending=$true}, 'name')
        [pscustomobject]@{
            freezeOk=$freezeOk; freezeReason=$freezeReason
            gameFound=[bool]$gproc; gamePid=$gpid; sessionId=$sid
            counts=[pscustomobject]@{
                congelado=@($plan.Congelado).Count; degradado=@($plan.Degradado).Count
                intacto=@($plan.Intacto).Count; apps=@($apps).Count
            }
            apps=$apps
        }
    }
    # MODIFICA el sistema: crea el job, asigna y congela. Sin admin no se niega (degrada a lo que el
    # usuario posee) pero los assign fallidos viajan en 'failed'. No exige admin a proposito: negarse
    # dejaria sin funcion a quien abre AXE sin elevar, cuando lo suyo si se puede congelar.
    # Consejero (42-advisor). Es la UNICA entrada del puente que escribe algo por si sola:
    # Get-AXEAdviceNow mide y guarda la medida en outcomes.json con la huella de ajustes puestos.
    # Se declara aqui porque escribir sin decirlo seria justo lo que este proyecto le reprocha a
    # los demas. No toca registro, ni servicios, ni procesos: solo anexa una fila a un json propio.
    #   Coste: arrastra Get-AXESnapshot, o sea el busy-loop de jitter (~1s) en este hilo. Es una
    # accion que pulsa el usuario, no un sondeo de fondo, asi que se acepta igual que measure.score.
    'advisor.get' = { param($a)
        $r = Get-AXEAdviceNow
        [pscustomobject]@{
            plan = @(@($r.Plan) | ForEach-Object {
                [pscustomobject]@{
                    order=[int]$_.Order; kind=[string]$_.Kind; id=[string]$_.Id
                    title=[string]$_.Title; detail=[string]$_.Detail
                    why=[string]$_.Why; impact=[string]$_.Impact; action=[string]$_.Action
                }
            })
            samples = [int]@($r.Samples).Count
            score   = $r.Score
            ts      = $r.Timestamp
        }
    }

    # Smart detect. READ-ONLY y sin efectos: solo lee la tabla de procesos y puntua. Es la puerta
    # de entrada que faltaba - la seccion pedia ESCRIBIR el nombre del proceso, cosa que solo sabe
    # hacer quien ya sabe que Valorant corre como 'VALORANT-Win64-Shipping'. Devuelve las RAZONES
    # de cada candidato, no solo el nombre: el usuario tiene que poder desmentir a la maquina.
    'session.detect' = { param($a)
        $n = 8; if($a.top){ $n = [int]$a.top }
        if($n -lt 1){ $n = 1 }; if($n -gt 20){ $n = 20 }
        $sid = [int](Get-Process -Id $PID).SessionId
        $cands = Get-AXEGameCandidates -Processes (Get-AXESessionProcesses) -SelfPid $PID -SessionId $sid -Top $n
        [pscustomobject]@{
            candidates = @($cands | ForEach-Object {
                [pscustomobject]@{
                    name      = [string]$_.Name
                    pid       = [int]$_.Pid
                    score     = [int]$_.Score
                    store     = $(if($_.Store){ [string]$_.Store } else { $null })
                    title     = [string]$_.Title
                    path      = $(if($_.Path){ [string]$_.Path } else { $null })
                    likely    = [bool]$_.Likely
                    instances = [int]$_.Instances
                    reasons   = @($_.Reasons | ForEach-Object { [string]$_ })
                }
            })
        }
    }

    'session.start' = { param($a)
        if([string]::IsNullOrWhiteSpace([string]$a.game)){ throw 'falta el nombre del proceso del juego (ej: cs2)' }
        $s = Start-AXESessionTracked -GameName ([string]$a.game)
        if(-not $s){ throw 'no pude iniciar la sesion (ver log)' }
        if(-not $s.Ok){ throw [string]$s.Reason }
        Get-AXESessionStatus -Session $s
    }
    # Sondeo del front (~2 s). Sync-AXESessionTracked cierra la sesion si el juego murio: es la
    # salida automatica del spec A, sin timer en el puente ni Watch bloqueante en el hilo de la UI.
    'session.status' = { param($a)
        Get-AXESessionStatus -Session (Sync-AXESessionTracked) -EndedReason $script:AXESessionEnded
    }
    'session.stop' = { param($a)
        if(Get-AXESessionCurrent){ [void](Stop-AXESessionTracked -Reason 'OFF manual.') }
        Get-AXESessionStatus -Session $null -EndedReason $script:AXESessionEnded
    }
    # Nivel por app, persistido. El motor rechaza duros y niveles invalidos con motivo; aqui se
    # convierte en error del puente para que el front lo pinte tal cual. needsRestart es honesto: un
    # cambio con sesion viva no re-reparte lo ya congelado, entra en la siguiente.
    'session.setLevel' = { param($a)
        if([string]::IsNullOrWhiteSpace([string]$a.name)){ throw 'falta la app' }
        if([string]::IsNullOrWhiteSpace([string]$a.level)){ throw 'falta el nivel (intacto/degradado/congelado o default)' }
        $r = Set-AXESessionOverride -Name ([string]$a.name) -Level ([string]$a.level)
        if(-not $r.Ok){ throw [string]$r.Reason }
        [pscustomobject]@{
            name=(Get-AXESessionAppName ([string]$a.name)); level=([string]$a.level).Trim().ToLowerInvariant()
            overrides=$r.Overrides; needsRestart=[bool](Get-AXESessionCurrent)
        }
    }
}

function Invoke-AXEBridgeCmd {
    param([string]$cmd,[hashtable]$cmdArgs)
    # Lista blanca EXACTA: el hashtable literal es case-insensitive; exigimos coincidencia de
    # mayus/minus (-ccontains) para que 'HW.GET' no colisione con 'hw.get'. Superficie minima y
    # auditable: el check S-webui-3 asume mapeo 1:1 literal-JS <-> clave, sin deriva de casing.
    $fn = $null
    if($script:AXEBridgeMap.Keys -ccontains $cmd){ $fn = $script:AXEBridgeMap[$cmd] }
    if(-not $fn){ return [pscustomobject]@{ ok=$false; data=$null; err="cmd desconocido: $cmd" } }
    try {
        $data = & $fn $cmdArgs
        return [pscustomobject]@{ ok=$true; data=$data; err='' }
    } catch {
        Write-AXELog "Puente: $cmd lanzo: $($_.Exception.Message)" 'ERR'
        return [pscustomobject]@{ ok=$false; data=$null; err=$_.Exception.Message }
    }
}

function Register-AXEBridge($core){
    # JS -> PS: cada mensaje es {id, cmd, args}. Se responde por ExecuteScriptAsync(__axeReply).
    $core.add_WebMessageReceived({
        param($s,$e)
        $reqId = -1
        try {
            $msg = $e.WebMessageAsJson | ConvertFrom-Json
            $reqId = [int]$msg.id
            # Diagnostico (AXE_WEBUI_DEBUG=1): corre en el hilo UI (con runspace) => Write-AXELog
            # funciona. Prueba que el postMessage del navegador llega al puente (JS->PS).
            if($env:AXE_WEBUI_DEBUG -eq '1'){ Write-AXELog "Puente RX id=$reqId cmd=$($msg.cmd)" 'INFO' }
            $argsHt = @{}
            if($msg.args){ $msg.args.PSObject.Properties | ForEach-Object { $argsHt[$_.Name] = $_.Value } }
            $res = Invoke-AXEBridgeCmd $msg.cmd $argsHt
        } catch {
            $res = [pscustomobject]@{ ok=$false; data=$null; err="payload invalido: $($_.Exception.Message)" }
        }
        $json = ($res | ConvertTo-Json -Depth 8 -Compress)
        # __axeReply(id, jsonString): el JSON viaja como argumento string. ConvertTo-Json del string
        # lo envuelve en comillas escapadas => JSON.parse en JS lo desdobla, sin inyeccion de comillas.
        $js = 'window.__axeReply(' + $reqId + ', ' + ($json | ConvertTo-Json) + ')'
        [void]$s.ExecuteScriptAsync($js)
    })

    # PS -> JS: telemetria REAL (Fase 5). Un runspace PRODUCTOR muestrea CPU/RAM (CIM barato) y
    # jitter (busy-loop nativo corto) y escribe en un buffer SINCRONIZADO; el DispatcherTimer (hilo
    # UI) SOLO lee ese buffer y lo empuja por PostWebMessageAsJson. Asi el busy-loop de jitter nunca
    # corre en el hilo UI (no congela la ventana). [AXE.Native] se compila con Add-Type en el hilo
    # principal al cargar el motor => visible en este runspace (mismo AppDomain).
    # Coste honesto: el muestreo de jitter es ~100ms/1s (~10% de un nucleo en el hilo productor)
    # mientras la ventana este abierta; es el precio de un osciloscopio de latencia REAL, no simulado.
    $script:TelemBuf = [hashtable]::Synchronized(@{ cpu=$null; ram=$null; jitterUs=$null; jitterMeanUs=$null; ts=$null; seq=0 })
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $producer = [powershell]::Create(); $producer.Runspace = $rs
        [void]$producer.AddScript({
            param($BUF)
            while($true){
                $ramPct = $null
                try {
                    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
                    if($os.TotalVisibleMemorySize -gt 0){
                        $ramPct = [math]::Round(100.0 * ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize, 1)
                    }
                } catch {}
                $cpuPct = $null
                try {
                    $c = (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop).PercentProcessorTime
                    if($null -ne $c){ $cpuPct = [double]$c }
                } catch {}
                $jUs = $null; $jMeanUs = $null
                try {
                    $r = [AXE.Native]::SampleJitter(100)   # 100ms -> P99.9 y media, en ms
                    if($r){ $jUs = [math]::Round($r[3] * 1000, 1); $jMeanUs = [math]::Round($r[1] * 1000, 1) }  # ms -> us
                } catch {}
                $BUF.cpu = $cpuPct; $BUF.ram = $ramPct; $BUF.jitterUs = $jUs; $BUF.jitterMeanUs = $jMeanUs
                $BUF.ts = (Get-Date).ToString('HH:mm:ss'); $BUF.seq = [int]$BUF.seq + 1
                Start-Sleep -Milliseconds 850
            }
        })
        [void]$producer.AddArgument($script:TelemBuf)
        $script:TelemRS = $rs; $script:TelemPS = $producer
        $script:TelemHandle = $producer.BeginInvoke()
    } catch { Write-AXELog "Telemetria: runspace productor no arranco: $($_.Exception.Message)" 'ERR' }

    $script:TelemTick = 0
    $script:TelemetryTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:TelemetryTimer.Interval = [TimeSpan]::FromMilliseconds(1000)
    $script:TelemetryTimer.Add_Tick({
        try {
            $script:TelemTick++
            $b = $script:TelemBuf
            $payload = [pscustomobject]@{
                evt  = 'telemetry'
                data = [pscustomobject]@{
                    ts           = $(if($b.ts){ $b.ts } else { (Get-Date).ToString('HH:mm:ss') })
                    uptimeS      = [int]([Environment]::TickCount64 / 1000)
                    cpu          = $b.cpu
                    ram          = $b.ram
                    jitterUs     = $b.jitterUs
                    jitterMeanUs = $b.jitterMeanUs
                }
            }
            $script:Web.CoreWebView2.PostWebMessageAsJson(($payload | ConvertTo-Json -Depth 6 -Compress))
            if($env:AXE_WEBUI_DEBUG -eq '1' -and $script:TelemTick -le 3){ Write-AXELog "Telemetria TX tick=$($script:TelemTick) cpu=$($b.cpu) jUs=$($b.jitterUs)" 'INFO' }
        } catch { if($env:AXE_WEBUI_DEBUG -eq '1'){ Write-AXELog "Telemetria TX fallo: $($_.Exception.Message)" 'ERR' } }
    })
    $script:TelemetryTimer.Start()
}


# >>>>> MODULE: 49-webmain.ps1 >>>>>
# =====================================================
# REGION 14b - ARRANQUE DEL HOST WEB (bootstrap)
# =====================================================
# Va DESPUES de 47-webhost (Show-AXEWebHost) y 48-webbridge (Register-AXEBridge) para que ambos
# esten definidos cuando arranque. Espeja el rol de 99-main.ps1 con la GUI vieja: separa el
# bootstrap de las definiciones.
#
# Cutover (Fase 8): la GUI WPF vieja (50-60, 99-main) se retiro. Este es el arranque UNICO del
# frontend, incondicional. Llegar aqui = modo GUI: los modos CLI (-SelfTest/-List/-Diag/...) ya
# hicieron 'exit' en 45-cli, y las pruebas Pester cargan via _load-engine, que SALTA este modulo
# (no abre ventana). El harness del build entra con AXE_WEBUI_TEST=1: Show-AXEWebHost construye la
# carcasa, imprime 'WEBHOST OK' y vuelve sin ShowDialog bloqueante. El arranque real (sin ese flag)
# bloquea con la ventana hasta que el usuario la cierra. El 'exit 0' cierra el proceso al volver.
# Antes de abrir la ventana: si una sesion anterior no cerro limpiamente (kill, BSOD, corte de luz),
# el kernel ya descongelo lo congelado, pero las prioridades DEGRADADAS siguen bajas porque eso no es
# estado del job. El diario en disco (AXE/session_degraded.json) las devuelve, comprobando
# pid+nombre+arranque para no tocar un proceso que solo heredo el numero.
try { [void](Restore-AXESessionDegraded) } catch {}
Show-AXEWebHost
exit 0


