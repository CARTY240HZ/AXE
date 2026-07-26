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

