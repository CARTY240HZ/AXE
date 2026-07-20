# ================================================================
# AXE 6.1.0-dev - BUILT from /src by build.ps1 - DO NOT EDIT DIRECTLY
# Build UTC: 2026-07-20 00:08:20Z
# Modules: 00-header.ps1, 05-core.ps1, 10-reg-helpers.ps1, 15-startup.ps1, 20-tweaks.ps1, 22-catalogs.ps1, 23-defender.ps1, 25-assistant.ps1, 28-revert-export.ps1, 30-profiles.ps1, 31-gamegpu.ps1, 32-measure.ps1, 33-fps.ps1, 34-safety.ps1, 36-report.ps1, 38-regedit.ps1, 45-cli.ps1, 50-xaml.ps1, 52-gui-build.ps1, 55-gui-actions.ps1, 57-gui-handlers.ps1, 60-gui-selftest.ps1, 99-main.ps1
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
    [switch]$FpsCompare
)

# Version canonica. build.ps1 reemplaza el token desde el fichero VERSION (fuente unica).
# Va DESPUES del param block (regla PS: param() debe ser la primera sentencia).
# Fallback si el token no se reemplazo (se corre src suelto sin build).
$script:AXEVersion = '6.1.0-dev'
if($script:AXEVersion -like '*6.1.0-dev*'){ $script:AXEVersion = '6.1.0-dev' }



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
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os  = Get-CimInstance Win32_OperatingSystem
    $enc = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)
    $isLaptop = ($enc | Where-Object { $_ -in 8,9,10,11,12,14,18,21,30,31,32 }).Count -gt 0
    $isHybrid = $false
    try { if($cpu.Name -match '1[2-9]th Gen' -or $cpu.Name -match 'Ultra'){ $isHybrid = $true } } catch {}
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Virtual|Basic|Meta|Parsec|Remote' }
    $hasNvidia = @($gpu | Where-Object Name -match 'NVIDIA').Count -gt 0
    $activeNic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1
    $isWifi = $activeNic -and ($activeNic.PhysicalMediaType -match 'Native 802.11|Wireless' -or $activeNic.Name -match 'Wi-?Fi|Wireless')
    $edition = $os.Caption
    $onBattery = $false
    try { $b = Get-CimInstance Win32_Battery -ErrorAction Stop; if($b -and $b.BatteryStatus -ne 2){ $onBattery = $true } } catch {}
    # WinVer: Win11 = build >= 22000 (corte oficial Microsoft), Win10 = resto de 10.0.x
    $build = $os.BuildNumber
    $isWin11 = [int]$build -ge 22000
    # --- ecosistema (§3.1): arquitectura, vendor, seguridad. Todo self-contained (corre en runspace) ---
    $cpuArch   = $env:PROCESSOR_ARCHITECTURE                 # AMD64 / ARM64 / x86
    $cpuVendor = $cpu.Manufacturer                            # GenuineIntel / AuthenticAMD / Qualcomm...
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
    [pscustomobject]@{
        CpuName=$cpu.Name; Cores=$cpu.NumberOfCores; Threads=$cpu.NumberOfLogicalProcessors
        IsLaptop=$isLaptop; IsHybrid=$isHybrid; HasNvidia=$hasNvidia
        IsWifi=[bool]$isWifi; NicName=$activeNic.Name; Edition=$edition
        IsHome=($edition -match 'Home'); OnBattery=$onBattery
        IsWin11=$isWin11; BuildNumber=$build
        RamGB=[math]::Round($os.TotalVisibleMemorySize/1MB,1)
        CpuArch=$cpuArch; CpuVendor=$cpuVendor
        HasDefender=$hasDefender; IsTamperProtected=$isTamper
        IsSMode=$isSMode; SupportsHAGS=$supportsHAGS; IsSSD=$isSSD
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
Add-Tweak @{Id='net_intmod';Cat='RED';Tier=1;Reboot=$false;Name='Interrupt Moderation NIC OFF';Desc='Menos buffering en el adaptador activo. COMPROMISO REAL: baja latencia a cambio de MAS uso de CPU por interrupciones. En CPU justa puede salir peor';Requires=@{};Source='https://learn.microsoft.com/en-us/windows-server/networking/technologies/network-subsystem/net-sub-performance-tuning-nics';
 # El catch de antes devolvia $true: CUALQUIER error al leer la propiedad se reportaba como
 # "aplicado", y ademas sumaba en TweaksOn del score. Un fallo silencioso presentado como exito.
 # Ahora se distingue: si el adaptador no expone la propiedad no hay nada que aplicar (true
 # vacuo, correcto); si la expone se lee su valor real. Sin rama que convierta error en exito.
 Test={ if(-not $script:HW.NicName){return $true};
        $p=Get-NetAdapterAdvancedProperty -Name $script:HW.NicName -RegistryKeyword '*InterruptModeration' -EA SilentlyContinue
        if($null -eq $p){ return $true }
        ([int]$p.RegistryValue -eq 0) };
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
    'net_intmod'      = { param($h) -not $h.IsWifi }                               # moderacion de interrupciones es cosa del NIC cableado
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
    'net_intmod'      = { param($h) -not $h.IsWifi }                               # moderacion de interrupciones: cosa del NIC cableado
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
    if($h.IsWifi){    [void]$n.Add('Wi-Fi: dentro CTCP (recupera antes tras perdida), fuera moderacion de interrupciones (es del NIC cableado). El jitter lo domina la radio: por cable bajaria mas.') }
    else {            [void]$n.Add('Ethernet: dentro moderacion de interrupciones del adaptador.') }
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

$script:DNSPROFILES = @(
    @{Name='Cloudflare (1.1.1.1)';V4=@('1.1.1.1','1.0.0.1')}
    @{Name='Google (8.8.8.8)';V4=@('8.8.8.8','8.8.4.4')}
    @{Name='AdGuard (bloquea ads)';V4=@('94.140.14.14','94.140.15.15')}
    @{Name='Quad9 (seguridad)';V4=@('9.9.9.9','149.112.112.112')}
    @{Name='Automatico (DHCP)';V4=$null}
)


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
    if($s -match 'red|ping|dns|internet|wifi|online|conexion'){ $r=Report-Cats @('RED') 'RED'; if($script:HW.IsWifi){ $r+="`n>> Wi-Fi: el jitter lo domina la radio. Cable = mas estabilidad." }; $r+="`n>> DNS: pestana DNS."; return $r }
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


# >>>>> MODULE: 45-cli.ps1 >>>>>
# =====================================================
# REGION 11 - MODOS CLI (headless)
# =====================================================
# --- HW: en modo headless (CLI) se carga SINCRONO (lo necesita gating/Tests). En modo
#     GUI se DEFIERE a un runspace de fondo (Start-AXEHardwareLoad, region 12) para que
#     la ventana no espere ~3.7s de CIM (Win32_Processor + Get-NetAdapter pagan cold-init WMI).
$script:HW = $null
if($SelfTest -or $List -or $Export -or $Import -or $Measure -or $Score -or $Report -or $TimerSweep){
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
    $knownReq = @('MinRam','Desktop','NotLaptop','NotHybrid','AC','Wired','NotHome','Nvidia','WinVer','WinBuild','CpuArch','CpuVendor','HAGS','TamperOff','Defender','NotSMode')
    foreach($tw in $script:CAT){
        $rq = $tw.Requires
        if($rq -isnot [hashtable]){ continue }
        foreach($k in $rq.Keys){ if($k -notin $knownReq){ [void]$fails.Add("S19: $($tw.Id) clave Requires desconocida '$k' (typo? no gatea)") } }
        if($rq.ContainsKey('HAGS') -and $tw.Cat -ne 'GPU'){ [void]$fails.Add("S19: $($tw.Id) HAGS solo aplica a Cat=GPU") }
        if($rq.ContainsKey('MinRam')){ $mr=$rq['MinRam']; if(-not ($mr -is [int]) -or $mr -le 0){ [void]$fails.Add("S19: $($tw.Id) MinRam invalido: $mr") } }
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



# >>>>> MODULE: 50-xaml.ps1 >>>>>
# =====================================================
# REGION 12 - GUI WPF FLUENT (rediseno elite, tema dark Win11)
# Reemplaza la GUI WinForms. Motor (regiones 1-11) intacto.
#   - WPF nativo (PresentationFramework, 0 deps externas)
#   - DPI PerMonitorV2 (P/Invoke) + titlebar oscuro + Mica best-effort
#   - ToggleSwitch Fluent, tarjetas redondeadas, nav con grupos
#   - Apply sin freeze (DispatcherTimer 1 tweak/tick)
#   - Gate de seguridad para Tier 2 (EXTREMO)
#   - LW_GUITEST=1 : construye + assert + render PNG, sin ShowDialog
# =====================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---- 12.0 Guard STA (WPF lo exige; el .bat ya pasa -STA, esto cubre run directo) ----
if($env:AXE_GUITEST -ne '1' -and $env:AXE_GUISHOW -ne '1' -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){
    Write-Host 'WPF requiere apartment STA. Relanzando con -STA...'
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',"`"$PSCommandPath`"") -Verb RunAs
    return
}

# ---- 12.1 P/Invoke: DPI awareness + DWM (titlebar oscuro + Mica) ----
if(-not ('LWNative.Win' -as [type])){
Add-Type -Namespace LWNative -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
'@
}
# PerMonitorV2 = -4. Debe llamarse ANTES de crear ventana. Falla silencioso en Win viejo.
try { [void][LWNative.Win]::SetProcessDpiAwarenessContext([System.IntPtr](-4)) } catch {}

function Set-AXEWindowChrome($hwnd){
    # DWMWA_USE_IMMERSIVE_DARK_MODE = 20 : titlebar negra (fiable en Win10 2004+/Win11)
    try { $d=1; [void][LWNative.Win]::DwmSetWindowAttribute($hwnd,20,[ref]$d,4) } catch {}
    # DWMWA_SYSTEMBACKDROP_TYPE = 38, valor 2 = Mica (best-effort, Win11 22621+)
    try { $m=2; [void][LWNative.Win]::DwmSetWindowAttribute($hwnd,38,[ref]$m,4) } catch {}
}

# ---- 12.2 Guards admin + catalogo (WPF MessageBox, sin cargar WinForms) ----
if($env:AXE_GUITEST -ne '1' -and $env:AXE_GUISHOW -ne '1' -and -not (Test-Admin)){
    [System.Windows.MessageBox]::Show("Ejecuta 'AXE.bat' (se eleva solo).","Admin requerido",'OK','Warning') | Out-Null
    return
}
if($script:CAT.Count -lt 10){
    [System.Windows.MessageBox]::Show("Catalogo roto ($($script:CAT.Count) tweaks). Abortando para protegerte.","AXE",'OK','Error') | Out-Null
    return
}

# ---- 12.3 XAML: shell + estilos Fluent ----
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AXE" Height="840" Width="1200" MinHeight="720" MinWidth="1040"
        WindowStartupLocation="CenterScreen" Background="#101216"
        TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True"
        FontFamily="Segoe UI Variable, Segoe UI" FontSize="13" Foreground="#ECECF0">
  <Window.Resources>
    <!-- ============================================================
         PALETA: banco de instrumentos, no UI gamer.
         Grafito frio desplazado a azul = carcasa del instrumento.
         REGLA DURA: toda la saturacion esta reservada al RIESGO.
         Fuera de la escala de tier + severidad de log, la UI es
         grafito y blanco. Asi el tier es imposible de no ver.
         ============================================================ -->
    <SolidColorBrush x:Key="Bg"       Color="#101216"/>
    <SolidColorBrush x:Key="Surface"  Color="#181B21"/>
    <SolidColorBrush x:Key="Surface2" Color="#212630"/>
    <SolidColorBrush x:Key="Line"     Color="#2C323D"/>
    <SolidColorBrush x:Key="Fg"       Color="#E4E8EF"/>
    <SolidColorBrush x:Key="Muted"    Color="#828B9C"/>
    <!-- Ambar de instrumento (lampara "armado"). No es el teal/acid-green por defecto. -->
    <SolidColorBrush x:Key="Accent"   Color="#E0A32E"/>
    <SolidColorBrush x:Key="AccentDim" Color="#24E0A32E"/>
    <SolidColorBrush x:Key="OnAccent" Color="#101216"/>
    <!-- Escala de riesgo. Green=Tier 0 seguro, Accent=Tier 1 elite, Red=Tier 2 extremo.
         Tier 1 comparte color con la marca a proposito: es el tier que el producto recomienda. -->
    <SolidColorBrush x:Key="Green"    Color="#5FAF8D"/>
    <SolidColorBrush x:Key="Amber"    Color="#E0A32E"/>
    <SolidColorBrush x:Key="Red"      Color="#E2593C"/>
    <SolidColorBrush x:Key="Purple"   Color="#8C86C9"/>

    <!-- Cara de utilidad. Regla semantica: todo lo que es VERDAD DE MAQUINA
         (valores de registro, contadores, codigos de tier, banner de HW, log)
         va en mono. Las etiquetas humanas van en sans. -->
    <FontFamily x:Key="Mono">Cascadia Mono, Consolas, Courier New</FontFamily>

    <!-- Anillo de foco de teclado (a11y: foco visible por teclado, guia Fluent) -->
    <Style x:Key="FocusRing">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Stroke="#F2C368" StrokeThickness="2" RadiusX="8" RadiusY="8" Margin="-2" SnapsToDevicePixels="True"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ScrollBar fino -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border CornerRadius="5" Background="#39414F" Margin="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Opacity="0" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton><RepeatButton Opacity="0" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Input redondeado -->
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Surface2}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Boton pastilla (color via Background) -->
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="8" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.90"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.78"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.40"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Boton secundario ghost (transparente + borde, hover rellena) -->
    <Style x:Key="PillGhost" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Surface2}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Line}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.40"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Boton destructivo (outline rojo, hover rellena rojo) -->
    <Style x:Key="PillDanger" TargetType="Button" BasedOn="{StaticResource PillGhost}">
      <Setter Property="Foreground" Value="{StaticResource Red}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{StaticResource Red}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Red}"/>
                <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.40"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Item de navegacion (RadioButton) -->
    <Style x:Key="NavItem" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <!-- Sel = capa de seleccion (glow teal) que se FUNDE via Opacity; separada de B
                 para no pelear con el brush de hover (swap de brush congelado no es animable) -->
            <Grid Margin="8,1">
              <Border x:Name="Sel" CornerRadius="7" Background="{StaticResource AccentDim}" Opacity="0"/>
              <Border x:Name="B" Background="Transparent" BorderBrush="{StaticResource Accent}"
                      BorderThickness="0" CornerRadius="7" Padding="10,8">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="Ico" Grid.Column="0" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                             FontSize="15" Text="{TemplateBinding Tag}" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
                  <TextBlock Grid.Column="1" Margin="10,0,0,0" Text="{TemplateBinding Content}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Surface2}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Sel" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.16"/></Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Sel" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.16"/></Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
                <Setter TargetName="B" Property="BorderThickness" Value="3,0,0,0"/>
                <Setter TargetName="Ico" Property="Foreground" Value="{StaticResource Accent}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ToggleSwitch Fluent (CheckBox retemplado) -->
    <Style x:Key="ToggleSwitch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="24" Background="Transparent">
              <Border x:Name="Track" CornerRadius="12" Background="{StaticResource Surface2}"
                      BorderBrush="{StaticResource Line}" BorderThickness="1"/>
              <Ellipse x:Name="Thumb" Width="16" Height="16" HorizontalAlignment="Left" Margin="4,0,0,0" Fill="#AEB6C4">
                <Ellipse.RenderTransform><TranslateTransform x:Name="TT" X="0"/></Ellipse.RenderTransform>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Thumb" Property="Fill" Value="White"/>
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="TT" Storyboard.TargetProperty="X" To="22" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="TT" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ProgressBar slim -->
    <Style x:Key="Slim" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="{StaticResource Surface2}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="3" Background="{TemplateBinding Background}" ClipToBounds="True">
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="3" Background="{TemplateBinding Foreground}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- HEADER -->
    <Border Grid.Row="0" Background="{StaticResource Surface}" Padding="18,12" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Viewbox x:Name="LogoBox" Height="34" VerticalAlignment="Center">
            <Canvas x:Name="LogoCanvas" Width="2624" Height="1624">
              <Path Data="M1856.000000,1626.000000 C1237.405884,1626.000000 619.811768,1626.000000 2.108846,1626.000000 C2.108846,1084.802856 2.108846,543.605652 2.108846,2.204240 C876.427673,2.204240 1750.855469,2.204240 2625.641602,2.204240 C2625.641602,543.333130 2625.641602,1084.666504 2625.641602,1626.000000 C2369.605225,1626.000000 2113.302490,1626.000000 1856.000000,1626.000000 M741.003723,951.907471 C720.601868,900.810181 708.002563,847.833557 704.400574,792.951172 C698.314270,700.215698 715.926758,612.031311 757.112488,528.650330 C790.572327,460.910431 836.139404,402.351746 891.699402,351.369720 C893.863403,349.384094 897.597351,348.223022 897.326965,343.842010 C890.258789,343.842010 883.595947,343.841797 876.933105,343.842072 C748.944885,343.846893 620.956604,343.851654 492.968384,343.856659 C455.638489,343.858124 418.307892,343.727142 380.978912,343.912415 C358.721924,344.022888 343.173431,354.896149 333.785980,374.837799 C332.232880,378.137024 331.015594,381.608856 329.832794,385.065796 C307.539948,450.219971 285.285889,515.387390 263.003632,580.545166 C197.339005,772.561401 131.656342,964.571533 66.058945,1156.610718 C64.680763,1160.645386 63.630501,1164.983765 63.499184,1169.213745 C63.202446,1178.772339 68.966484,1185.783936 78.278770,1187.771851 C81.180626,1188.391479 84.242310,1188.442383 87.231262,1188.446533 C125.227692,1188.498291 163.224213,1188.506104 201.220703,1188.498169 C217.504593,1188.494873 229.064255,1180.660767 236.600128,1166.613525 C238.789276,1162.532837 240.419632,1158.118896 241.986984,1153.743408 C256.011475,1114.592651 269.953369,1075.412109 283.957001,1036.253906 C285.261963,1032.604858 286.825653,1029.048340 288.075714,1025.931274 C394.718384,1025.931274 500.275909,1025.931274 606.261597,1025.931274 C608.316528,1031.495850 610.324585,1036.754883 612.206665,1042.058594 C626.115540,1081.251587 640.087097,1120.422607 653.853027,1159.665771 C660.484558,1178.570801 676.049255,1188.799683 695.744385,1188.661987 C760.401917,1188.209473 825.064636,1188.497070 889.725342,1188.479492 C892.204163,1188.478760 894.682922,1188.262695 898.003601,1188.107666 C884.125305,1172.441650 870.884888,1158.038330 858.242249,1143.128174 C809.667419,1085.841309 769.424805,1023.395020 741.003723,951.907471 M2298.998535,1188.551147 C2311.994873,1188.544922 2324.991211,1188.540527 2337.987549,1188.532349 C2373.984619,1188.509399 2409.984375,1188.217651 2445.977539,1188.587646 C2461.147217,1188.743530 2475.829590,1177.036011 2475.954346,1158.973755 C2476.196289,1123.977905 2476.309326,1088.975952 2475.905518,1053.983032 C2475.725586,1038.375244 2463.325439,1026.539917 2447.783447,1025.636353 C2445.125488,1025.481812 2442.452637,1025.561646 2439.786621,1025.561523 C2317.795166,1025.552856 2195.803711,1025.547485 2073.812256,1025.541748 C2070.576172,1025.541626 2067.339844,1025.541748 2063.896973,1025.541748 C2063.896973,957.266785 2063.896973,890.110535 2063.896973,822.152039 C2067.737549,822.152039 2071.002197,822.152588 2074.266602,822.151978 C2093.931885,822.148071 2113.597412,822.143311 2133.262695,822.139832 C2199.924805,822.127930 2266.587158,822.159973 2333.249268,822.080811 C2356.197998,822.053528 2367.428467,810.603333 2367.515869,787.510498 C2367.552246,777.844604 2367.522461,768.178406 2367.523438,758.512390 C2367.525391,735.847229 2367.761475,713.178955 2367.459229,690.517822 C2367.195312,670.725037 2355.044434,658.926025 2335.476807,658.687744 C2333.810547,658.667419 2332.143555,658.688782 2330.477051,658.688538 C2245.149414,658.675659 2159.821777,658.662415 2074.494141,658.649414 C2070.962402,658.648865 2067.430420,658.649353 2063.643066,658.649353 C2063.643066,607.827271 2063.643066,558.297424 2063.643066,507.765686 C2067.900391,507.765686 2071.814453,507.765320 2075.728760,507.765717 C2198.053955,507.777496 2320.379150,507.797760 2442.704346,507.793396 C2464.362061,507.792603 2476.173340,496.155548 2476.229980,474.605011 C2476.316650,441.607697 2475.783691,408.600342 2476.458252,375.616577 C2476.775391,360.098694 2463.436768,343.605408 2444.192627,343.636292 C2239.206787,343.965332 2034.220093,343.835907 1829.233643,343.865936 C1827.153809,343.866241 1825.074097,344.316284 1822.123657,344.656921 C1825.074341,348.075958 1827.256592,350.549347 1829.379395,353.072723 C1857.298584,386.260101 1883.350220,420.751587 1905.127075,458.398499 C1954.704834,544.106323 1982.693115,636.224670 1987.672241,735.146484 C1990.929810,799.865417 1982.993164,863.489929 1967.007690,926.150269 C1944.681030,1013.666748 1910.217407,1096.472046 1869.110840,1176.666504 C1867.328125,1180.144653 1865.623779,1183.662842 1863.228394,1188.478149 C2008.674561,1188.478149 2152.836914,1188.478149 2298.998535,1188.551147 M1621.000000,343.843628 C1579.338257,343.846527 1537.675293,343.998779 1496.015747,343.699249 C1489.393066,343.651642 1485.064697,345.757996 1480.725098,350.633270 C1447.488281,387.972565 1413.985718,425.075317 1380.547607,462.235229 C1377.549316,465.567413 1374.422974,468.784393 1371.208740,472.211853 C1368.636963,469.458984 1366.778687,467.558502 1365.017700,465.571808 C1331.195923,427.415771 1297.290894,389.332550 1263.683960,350.988129 C1259.122070,345.783234 1254.562256,343.661560 1247.561890,343.679779 C1154.240112,343.922913 1060.917603,343.842285 967.595215,343.842255 C964.343140,343.842255 961.091003,343.842255 957.258484,343.842255 C957.003601,347.947449 956.698303,351.217316 956.613586,354.492828 C956.043213,376.563385 958.280090,398.412811 962.078430,420.113953 C973.317261,484.325195 1000.697815,540.159912 1048.175415,585.516174 C1081.889404,617.723938 1120.993164,641.403137 1164.369019,658.037598 C1247.624756,689.965881 1333.524414,698.987854 1421.688843,686.440613 C1487.893555,677.018616 1549.435181,654.522217 1605.521729,618.065613 C1668.029907,577.434875 1713.862793,522.841492 1739.086182,452.219055 C1749.146973,424.049652 1757.163818,395.146820 1765.957520,366.530640 C1768.166870,359.340454 1769.782837,351.967896 1771.888428,343.842072 C1721.589722,343.842072 1672.294922,343.842072 1621.000000,343.843628 M1528.367798,804.523376 C1491.405640,793.821167 1453.634888,787.851135 1415.249878,786.166382 C1370.157349,784.187134 1325.323975,786.811340 1281.029053,796.026917 C1214.693970,809.827820 1152.974854,834.333923 1098.535278,875.444946 C1038.928589,920.458130 999.535950,979.075806 981.692932,1051.668091 C972.444824,1089.292969 969.162720,1127.847290 966.578064,1166.420776 C966.379761,1169.381226 966.578430,1172.440796 967.100891,1175.363525 C968.722046,1184.433716 972.632751,1187.779663 981.938293,1188.401245 C983.930481,1188.534424 985.935852,1188.491455 987.935181,1188.491577 C1079.921509,1188.499756 1171.907837,1188.503540 1263.894165,1188.507812 C1266.440063,1188.507935 1268.985962,1188.507812 1272.235962,1188.507812 C1272.235962,1183.543335 1272.235474,1179.605103 1272.235962,1175.666748 C1272.244141,1093.678955 1272.098999,1011.690735 1272.320679,929.703552 C1272.446289,883.286438 1296.331787,850.767517 1340.236694,835.575439 C1364.406006,827.212341 1389.233765,826.346069 1414.267334,828.815918 C1430.628174,830.430115 1446.167114,835.377258 1460.574707,843.559448 C1479.794067,854.474304 1492.906494,870.367798 1497.903442,891.922058 C1500.435181,902.842529 1501.866333,914.269775 1501.909668,925.475220 C1502.234619,1009.461487 1502.088745,1093.449463 1502.090332,1177.437012 C1502.090454,1180.974609 1502.090454,1184.512085 1502.090454,1187.790649 C1602.876831,1187.790649 1702.373535,1187.790649 1802.727661,1187.790649 C1803.923706,1180.727905 1805.455688,1174.260498 1806.053101,1167.708130 C1808.670166,1139.002319 1806.910278,1110.422729 1802.246216,1082.057983 C1788.231079,996.826599 1746.351440,928.432007 1677.224487,876.747253 C1632.707397,843.462891 1583.211548,820.315796 1528.367798,804.523376 z" Fill="{StaticResource Accent}"/>
              <Path Data="M741.326904,952.609741 C769.424805,1023.395020 809.667419,1085.841309 858.242249,1143.128174 C870.884888,1158.038330 884.125305,1172.441650 898.003601,1188.107666 C894.682922,1188.262695 892.204163,1188.478760 889.725342,1188.479492 C825.064636,1188.497070 760.401917,1188.209473 695.744385,1188.661987 C676.049255,1188.799683 660.484558,1178.570801 653.853027,1159.665771 C640.087097,1120.422607 626.115540,1081.251587 612.206665,1042.058594 C610.324585,1036.754883 608.316528,1031.495850 606.261597,1025.931274 C500.275909,1025.931274 394.718384,1025.931274 288.075714,1025.931274 C286.825653,1029.048340 285.261963,1032.604858 283.957001,1036.253906 C269.953369,1075.412109 256.011475,1114.592651 241.986984,1153.743408 C240.419632,1158.118896 238.789276,1162.532837 236.600128,1166.613525 C229.064255,1180.660767 217.504593,1188.494873 201.220703,1188.498169 C163.224213,1188.506104 125.227692,1188.498291 87.231262,1188.446533 C84.242310,1188.442383 81.180626,1188.391479 78.278770,1187.771851 C68.966484,1185.783936 63.202446,1178.772339 63.499184,1169.213745 C63.630501,1164.983765 64.680763,1160.645386 66.058945,1156.610718 C131.656342,964.571533 197.339005,772.561401 263.003632,580.545166 C285.285889,515.387390 307.539948,450.219971 329.832794,385.065796 C331.015594,381.608856 332.232880,378.137024 333.785980,374.837799 C343.173431,354.896149 358.721924,344.022888 380.978912,343.912415 C418.307892,343.727142 455.638489,343.858124 492.968384,343.856659 C620.956604,343.851654 748.944885,343.846893 876.933105,343.842072 C883.595947,343.841797 890.258789,343.842010 897.326965,343.842010 C897.597351,348.223022 893.863403,349.384094 891.699402,351.369720 C836.139404,402.351746 790.572327,460.910431 757.112488,528.650330 C715.926758,612.031311 698.314270,700.215698 704.400574,792.951172 C708.002563,847.833557 720.601868,900.810181 741.326904,952.609741 M437.795624,552.698364 C406.735779,654.143494 375.672363,755.587524 344.652863,857.044983 C344.224060,858.447571 344.347687,860.019104 344.194763,861.719727 C413.117462,861.719727 481.374115,861.719727 550.661011,861.719727 C516.194763,749.239075 481.903137,637.328430 446.968933,523.320679 C443.559052,534.068054 440.851166,542.602783 437.795624,552.698364 z" Fill="{StaticResource Surface}"/>
              <Path Data="M2297.999023,1188.514648 C2152.836914,1188.478149 2008.674561,1188.478149 1863.228394,1188.478149 C1865.623779,1183.662842 1867.328125,1180.144653 1869.110840,1176.666504 C1910.217407,1096.472046 1944.681030,1013.666748 1967.007690,926.150269 C1982.993164,863.489929 1990.929810,799.865417 1987.672241,735.146484 C1982.693115,636.224670 1954.704834,544.106323 1905.127075,458.398499 C1883.350220,420.751587 1857.298584,386.260101 1829.379395,353.072723 C1827.256592,350.549347 1825.074341,348.075958 1822.123657,344.656921 C1825.074097,344.316284 1827.153809,343.866241 1829.233643,343.865936 C2034.220093,343.835907 2239.206787,343.965332 2444.192627,343.636292 C2463.436768,343.605408 2476.775391,360.098694 2476.458252,375.616577 C2475.783691,408.600342 2476.316650,441.607697 2476.229980,474.605011 C2476.173340,496.155548 2464.362061,507.792603 2442.704346,507.793396 C2320.379150,507.797760 2198.053955,507.777496 2075.728760,507.765717 C2071.814453,507.765320 2067.900391,507.765686 2063.643066,507.765686 C2063.643066,558.297424 2063.643066,607.827271 2063.643066,658.649353 C2067.430420,658.649353 2070.962402,658.648865 2074.494141,658.649414 C2159.821777,658.662415 2245.149414,658.675659 2330.477051,658.688538 C2332.143555,658.688782 2333.810547,658.667419 2335.476807,658.687744 C2355.044434,658.926025 2367.195312,670.725037 2367.459229,690.517822 C2367.761475,713.178955 2367.525391,735.847229 2367.523438,758.512390 C2367.522461,768.178406 2367.552246,777.844604 2367.515869,787.510498 C2367.428467,810.603333 2356.197998,822.053528 2333.249268,822.080811 C2266.587158,822.159973 2199.924805,822.127930 2133.262695,822.139832 C2113.597412,822.143311 2093.931885,822.148071 2074.266602,822.151978 C2071.002197,822.152588 2067.737549,822.152039 2063.896973,822.152039 C2063.896973,890.110535 2063.896973,957.266785 2063.896973,1025.541748 C2067.339844,1025.541748 2070.576172,1025.541626 2073.812256,1025.541748 C2195.803711,1025.547485 2317.795166,1025.552856 2439.786621,1025.561523 C2442.452637,1025.561646 2445.125488,1025.481812 2447.783447,1025.636353 C2463.325439,1026.539917 2475.725586,1038.375244 2475.905518,1053.983032 C2476.309326,1088.975952 2476.196289,1123.977905 2475.954346,1158.973755 C2475.829590,1177.036011 2461.147217,1188.743530 2445.977539,1188.587646 C2409.984375,1188.217651 2373.984619,1188.509399 2337.987549,1188.532349 C2324.991211,1188.540527 2311.994873,1188.544922 2297.999023,1188.514648 z" Fill="{StaticResource Surface}"/>
              <Path Data="M1622.000000,343.842834 C1672.294922,343.842072 1721.589722,343.842072 1771.888428,343.842072 C1769.782837,351.967896 1768.166870,359.340454 1765.957520,366.530640 C1757.163818,395.146820 1749.146973,424.049652 1739.086182,452.219055 C1713.862793,522.841492 1668.029907,577.434875 1605.521729,618.065613 C1549.435181,654.522217 1487.893555,677.018616 1421.688843,686.440613 C1333.524414,698.987854 1247.624756,689.965881 1164.369019,658.037598 C1120.993164,641.403137 1081.889404,617.723938 1048.175415,585.516174 C1000.697815,540.159912 973.317261,484.325195 962.078430,420.113953 C958.280090,398.412811 956.043213,376.563385 956.613586,354.492828 C956.698303,351.217316 957.003601,347.947449 957.258484,343.842255 C961.091003,343.842255 964.343140,343.842255 967.595215,343.842255 C1060.917603,343.842285 1154.240112,343.922913 1247.561890,343.679779 C1254.562256,343.661560 1259.122070,345.783234 1263.683960,350.988129 C1297.290894,389.332550 1331.195923,427.415771 1365.017700,465.571808 C1366.778687,467.558502 1368.636963,469.458984 1371.208740,472.211853 C1374.422974,468.784393 1377.549316,465.567413 1380.547607,462.235229 C1413.985718,425.075317 1447.488281,387.972565 1480.725098,350.633270 C1485.064697,345.757996 1489.393066,343.651642 1496.015747,343.699249 C1537.675293,343.998779 1579.338257,343.846527 1622.000000,343.842834 z" Fill="{StaticResource Surface}"/>
              <Path Data="M1529.124512,804.814697 C1583.211548,820.315796 1632.707397,843.462891 1677.224487,876.747253 C1746.351440,928.432007 1788.231079,996.826599 1802.246216,1082.057983 C1806.910278,1110.422729 1808.670166,1139.002319 1806.053101,1167.708130 C1805.455688,1174.260498 1803.923706,1180.727905 1802.727661,1187.790649 C1702.373535,1187.790649 1602.876831,1187.790649 1502.090454,1187.790649 C1502.090454,1184.512085 1502.090454,1180.974609 1502.090332,1177.437012 C1502.088745,1093.449463 1502.234619,1009.461487 1501.909668,925.475220 C1501.866333,914.269775 1500.435181,902.842529 1497.903442,891.922058 C1492.906494,870.367798 1479.794067,854.474304 1460.574707,843.559448 C1446.167114,835.377258 1430.628174,830.430115 1414.267334,828.815918 C1389.233765,826.346069 1364.406006,827.212341 1340.236694,835.575439 C1296.331787,850.767517 1272.446289,883.286438 1272.320679,929.703552 C1272.098999,1011.690735 1272.244141,1093.678955 1272.235962,1175.666748 C1272.235474,1179.605103 1272.235962,1183.543335 1272.235962,1188.507812 C1268.985962,1188.507812 1266.440063,1188.507935 1263.894165,1188.507812 C1171.907837,1188.503540 1079.921509,1188.499756 987.935181,1188.491577 C985.935852,1188.491455 983.930481,1188.534424 981.938293,1188.401245 C972.632751,1187.779663 968.722046,1184.433716 967.100891,1175.363525 C966.578430,1172.440796 966.379761,1169.381226 966.578064,1166.420776 C969.162720,1127.847290 972.444824,1089.292969 981.692932,1051.668091 C999.535950,979.075806 1038.928589,920.458130 1098.535278,875.444946 C1152.974854,834.333923 1214.693970,809.827820 1281.029053,796.026917 C1325.323975,786.811340 1370.157349,784.187134 1415.249878,786.166382 C1453.634888,787.851135 1491.405640,793.821167 1529.124512,804.814697 z" Fill="{StaticResource Surface}"/>
              <Path Data="M437.969482,551.917969 C440.851166,542.602783 443.559052,534.068054 446.968933,523.320679 C481.903137,637.328430 516.194763,749.239075 550.661011,861.719727 C481.374115,861.719727 413.117462,861.719727 344.194763,861.719727 C344.347687,860.019104 344.224060,858.447571 344.652863,857.044983 C375.672363,755.587524 406.735779,654.143494 437.969482,551.917969 z" Fill="{StaticResource Accent}"/>


            </Canvas>
          </Viewbox>
          <TextBlock x:Name="VerLbl" Text="v6" FontSize="12" Foreground="{StaticResource Muted}" Margin="7,4,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Grid.Column="1" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,18,0">
          <StackPanel x:Name="HwChips" Orientation="Horizontal" HorizontalAlignment="Right"/>
          <!-- 3.3: banner de ecosistema. Hace explicito POR QUE se ve lo que se ve (cuantos
               tweaks aplican a esta maquina y cuantos estan ocultos por gating). -->
          <!-- Verdad de maquina -> mono. Es un volcado del ecosistema detectado, no una etiqueta. -->
          <TextBlock x:Name="EnvBannerLbl" Text="HW no detectado (arranque)" FontSize="10.5"
                     FontFamily="{StaticResource Mono}"
                     Foreground="{StaticResource Muted}" HorizontalAlignment="Right"
                     Margin="0,6,2,0" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
        <Border Grid.Column="2" Background="{StaticResource Surface2}" CornerRadius="8" Padding="14,8" VerticalAlignment="Center" MinWidth="172">
          <StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <TextBlock x:Name="CountLbl" Text="-/-" FontWeight="Bold" FontSize="15"/>
              <TextBlock Text="activas" Foreground="{StaticResource Muted}" FontSize="11" Margin="6,4,0,0"/>
            </StackPanel>
            <ProgressBar x:Name="StatusBar" Style="{StaticResource Slim}" Background="#131318" Minimum="0" Maximum="100" Value="0" Margin="0,7,0,0"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- MAIN -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="212"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- NAV -->
      <Border Grid.Column="0" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
        <DockPanel Margin="0,10,0,0">
          <Grid DockPanel.Dock="Top" Margin="10,0,10,8">
            <TextBox x:Name="SearchBox" Style="{StaticResource Input}" TabIndex="1" AutomationProperties.Name="Buscar tweaks por nombre o descripcion"/>
            <!-- H12: watermark real (overlay), no texto-literal-como-valor -->
            <TextBlock Text="Buscar..." Foreground="{StaticResource Muted}" IsHitTestVisible="False"
                       VerticalAlignment="Center" Margin="11,0,0,0" FontSize="13">
              <TextBlock.Style>
                <Style TargetType="TextBlock">
                  <Setter Property="Visibility" Value="Collapsed"/>
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding Text.Length, ElementName=SearchBox}" Value="0">
                      <Setter Property="Visibility" Value="Visible"/>
                    </DataTrigger>
                  </Style.Triggers>
                </Style>
              </TextBlock.Style>
            </TextBlock>
          </Grid>
          <Border DockPanel.Dock="Bottom" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="16,9,10,12">
            <StackPanel>
              <TextBlock Text="TIER" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Muted}" Margin="0,0,0,5"/>
              <StackPanel Orientation="Horizontal" Margin="0,1">
                <Ellipse Width="8" Height="8" Fill="{StaticResource Green}" VerticalAlignment="Center"/>
                <TextBlock Text="0  Seguro" FontSize="11" Foreground="{StaticResource Muted}" Margin="7,0,0,0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,1">
                <Ellipse Width="8" Height="8" Fill="{StaticResource Accent}" VerticalAlignment="Center"/>
                <TextBlock Text="1  Elite" FontSize="11" Foreground="{StaticResource Muted}" Margin="7,0,0,0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,1">
                <Ellipse Width="8" Height="8" Fill="{StaticResource Red}" VerticalAlignment="Center"/>
                <TextBlock Text="2  EXTREMO" FontSize="11" Foreground="{StaticResource Muted}" Margin="7,0,0,0"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="NavPanel"/></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- CONTENT -->
      <Border Grid.Column="1" Background="{StaticResource Bg}">
        <DockPanel Margin="16,12,8,8">
          <StackPanel DockPanel.Dock="Top" Margin="4,0,0,10">
            <TextBlock x:Name="ContentTitle" FontSize="17" FontWeight="Bold"/>
            <TextBlock x:Name="ContentSub" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,2,0,0"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><Grid x:Name="ContentHost"/></ScrollViewer>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ACTION BAR -->
    <Border Grid.Row="2" Background="{StaticResource Surface}" Padding="16,10" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <WrapPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnRestore" Style="{StaticResource PillGhost}" Content="Punto restauracion" TabIndex="10" AutomationProperties.Name="Crear punto de restauracion del sistema"/>
          <Button x:Name="BtnPreset"  Style="{StaticResource PillGhost}" Content="Preset gaming" TabIndex="11" AutomationProperties.Name="Marcar preset gaming (Tier 0 y 1)"/>
          <Button x:Name="BtnRead"    Style="{StaticResource PillGhost}" Content="Leer estado" TabIndex="12" AutomationProperties.Name="Leer estado real de los tweaks"/>
          <ProgressBar x:Name="ApplyBar" Style="{StaticResource Slim}" Width="150" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center" Margin="4,0,0,0" Visibility="Collapsed" AutomationProperties.Name="Progreso de aplicacion"/>
        </WrapPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="BtnMaster" Style="{StaticResource PillDanger}" Content="Master revert" TabIndex="13" AutomationProperties.Name="Revertir todos los tweaks a fabrica"/>
          <Button x:Name="BtnApply"  Style="{StaticResource Pill}" Background="{StaticResource Accent}" Content="APLICAR cambios" MinWidth="152" Margin="8,0,0,0" TabIndex="14" AutomationProperties.Name="Aplicar los cambios marcados"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- LOG -->
    <Border Grid.Row="3" Background="#131318" Height="152" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
      <DockPanel>
        <Grid DockPanel.Dock="Top" Background="#101015">
          <TextBlock Text="REGISTRO" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="12,0,0,0"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,4,8,4">
            <Button x:Name="BtnLogCopy" Style="{StaticResource PillGhost}" Height="24" Padding="12,0" FontSize="11" Margin="0,0,6,0" Content="Copiar"/>
            <Button x:Name="BtnLogClear" Style="{StaticResource PillGhost}" Height="24" Padding="12,0" FontSize="11" Margin="0" Content="Limpiar"/>
          </StackPanel>
        </Grid>
        <RichTextBox x:Name="LogBox" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                 Foreground="#828B9C" FontFamily="{StaticResource Mono}" FontSize="11.5"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="12,6">
          <RichTextBox.Document><FlowDocument PagePadding="0"/></RichTextBox.Document>
        </RichTextBox>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [System.Windows.Markup.XamlReader]::Load($reader)

# ---- 12.4 refs nombradas ----
$NavPanel     = $win.FindName('NavPanel')
$ContentHost  = $win.FindName('ContentHost')
$ContentTitle = $win.FindName('ContentTitle')
$SearchBox    = $win.FindName('SearchBox')
$HwChips      = $win.FindName('HwChips')
$EnvBannerLbl = $win.FindName('EnvBannerLbl')
$LogoBox      = $win.FindName('LogoBox')
$LogoCanvas   = $win.FindName('LogoCanvas')
$CountLbl     = $win.FindName('CountLbl')
$StatusBar    = $win.FindName('StatusBar')
$VerLbl       = $win.FindName('VerLbl'); if($VerLbl){ $VerLbl.Text = "v$($script:AXEVersion)" }
$ApplyBar     = $win.FindName('ApplyBar')
$script:LogBox = $win.FindName('LogBox')
# Sink de log con color por severidad + cap 500 lineas.
# INFO va NEUTRO a proposito: el verde-sobre-negro de terminal competia con la escala de
# riesgo y era lo unico que delataba la edad de la UI. La saturacion se gasta solo donde
# significa algo (WARN ambar / ERR rojo), igual que la regla de la paleta.
$script:AXELogSink = {
    param($line,$level)
    $col = switch($level){ 'ERR' {'#E2593C'} 'WARN' {'#E0A32E'} default {'#828B9C'} }
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness(0)
    $run = New-Object System.Windows.Documents.Run([string]$line)
    $run.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($col))
    [void]$p.Inlines.Add($run)
    [void]$script:LogBox.Document.Blocks.Add($p)
    while($script:LogBox.Document.Blocks.Count -gt 500){ $script:LogBox.Document.Blocks.Remove($script:LogBox.Document.Blocks.FirstBlock) }
    $script:LogBox.ScrollToEnd()
}
$BtnRestore = $win.FindName('BtnRestore'); $BtnPreset = $win.FindName('BtnPreset')
$BtnRead = $win.FindName('BtnRead'); $BtnApply = $win.FindName('BtnApply'); $BtnMaster = $win.FindName('BtnMaster')
$ContentSub = $win.FindName('ContentSub')
$BtnLogCopy = $win.FindName('BtnLogCopy'); $BtnLogClear = $win.FindName('BtnLogClear')
$BtnLogCopy.Add_Click({ try { $tr=New-Object System.Windows.Documents.TextRange($script:LogBox.Document.ContentStart,$script:LogBox.Document.ContentEnd); [System.Windows.Clipboard]::SetText($tr.Text) } catch {} })
$BtnLogClear.Add_Click({ $script:LogBox.Document.Blocks.Clear() })

# ---- 12.5 chrome DWM (dark titlebar + Mica) tras tener HWND ----
$win.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    Set-AXEWindowChrome $h
})



# >>>>> MODULE: 52-gui-build.ps1 >>>>>
# ---- 12.6 helpers UI ----
function New-AXEBrush($key){ $win.FindResource($key) }
function New-Chip($glyph,$text){
    $b = New-Object System.Windows.Controls.Border
    $b.Background = New-AXEBrush 'Surface2'; $b.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $b.Padding = New-Object System.Windows.Thickness(9,4,9,4); $b.Margin = New-Object System.Windows.Thickness(5,0,0,0)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation='Horizontal'
    $ic = New-Object System.Windows.Controls.TextBlock
    $ic.Text=$glyph; $ic.FontFamily=New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $ic.Foreground=New-AXEBrush 'Accent'; $ic.FontSize=12; $ic.VerticalAlignment='Center'
    $tx = New-Object System.Windows.Controls.TextBlock
    $tx.Text=$text; $tx.Foreground=New-AXEBrush 'Muted'; $tx.FontSize=12; $tx.Margin=New-Object System.Windows.Thickness(6,0,0,0); $tx.VerticalAlignment='Center'
    [void]$sp.Children.Add($ic); [void]$sp.Children.Add($tx); $b.Child=$sp; $b
}

# Chips de hardware: se pueblan cuando HW llega (async en GUI). Idempotente.
function Build-HwChips {
    if(-not $script:HW){ return }
    $HwChips.Children.Clear()
    [void]$HwChips.Children.Add((New-Chip ([char]0xE950) ("{0}  {1}C/{2}T" -f ($script:HW.CpuName -replace '\(R\)|\(TM\)|CPU| Processor',''),$script:HW.Cores,$script:HW.Threads)))
    [void]$HwChips.Children.Add((New-Chip ([char]0xE964) ("RAM {0}GB" -f $script:HW.RamGB)))
    [void]$HwChips.Children.Add((New-Chip ([char]0xE7F4) ($(if($script:HW.IsLaptop){'Portatil'}else{'Desktop'}))))
    [void]$HwChips.Children.Add((New-Chip ([char]0xE701) ($(if($script:HW.IsWifi){'Wi-Fi'}else{'Ethernet'}))))
    [void]$HwChips.Children.Add((New-Chip ([char]0xE83E) ($(if($script:HW.OnBattery){'Bateria'}else{'AC'}))))
    # 3.3: mismo banner que imprime la CLI (-List "ECO:"). Fuente unica: Get-AXEEnvBanner.
    if($EnvBannerLbl){
        $EnvBannerLbl.Text = Get-AXEEnvBanner
        $EnvBannerLbl.ToolTip = 'Ecosistema detectado: define que tweaks aplican a esta maquina y cuantos quedan ocultos por gating (3.2).'
    }
}
if($script:HW){ Build-HwChips }   # headless/GUISHOW con HW ya cargado

# ---- 12.7 catalogo -> categorias + iconos ----
$script:glyphs = @{
    'CPU'=[char]0xE950; 'LATENCIA'=[char]0xE945; 'GPU'=[char]0xE7F4; 'RED'=[char]0xE774;
    'MEMORIA'=[char]0xE964; 'SISTEMA'=[char]0xE713; 'RENDIMIENTO'=[char]0xE9D9; 'SERVICIOS'=[char]0xE90F;
    'PRIVACIDAD'=[char]0xE72E; 'APPS'=[char]0xE71D; 'EXTREMO'=[char]0xE7BA;
    'LIMPIEZA'=[char]0xE74D; 'DEBLOAT'=[char]0xECC9; 'DNS'=[char]0xE968; 'STARTUP'=[char]0xE768; 'ASISTENTE IA'=[char]0xE99A; 'PERFILES'=[char]0xE7FC; 'MEDICION'=[char]0xE9D2; 'REGISTRO'=[char]0xE8FD
    'FPS'=[char]0xEC4A
}
# NOTA sobre los cuatro glyphs de arriba (FPS, SISTEMA, REGISTRO, DEBLOAT): se eligieron
# RENDERIZANDO la fuente a PNG y mirando el dibujo, no por lo que sugiere el nombre del
# codepoint. Los cuatro anteriores estaban mal y ninguno lo delataba leyendo el codigo:
#   FPS      E7F8 -> EC4A : E7F8 dibuja un PORTATIL, no velocidad. EC4A es el velocimetro.
#   SISTEMA  E770 -> E713 : E770 tambien es un portatil, o sea que SISTEMA y FPS salian con el
#                           mismo dibujo pese a tener codepoints distintos. E713 es el engranaje
#                           de Settings, que ademas describe mejor lo que hay dentro.
#   REGISTRO E71D -> E8FD : E71D era literalmente el MISMO codepoint que APPS. E8FD es la lista
#                           con vinetas, que es lo que la vista ensena (claves del catalogo).
#   DEBLOAT  E738 -> ECC9 : E738 dibuja UN GUION, sin significado. ECC9 es el circulo con menos,
#                           el simbolo de quitar.
# Si se toca alguno, renderizarlo antes: el nombre oficial del glyph miente a menudo.
# Sombra suave compartida (solo se aplica en hover -> 1 card a la vez, sin coste en reposo)
$script:cardShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:cardShadow.Color=[System.Windows.Media.Colors]::Black; $script:cardShadow.BlurRadius=20; $script:cardShadow.ShadowDepth=0; $script:cardShadow.Opacity=0.40
# Brush translucido de un color base (tiles de icono tenidos por tier / badges). alpha 0-255.
function New-TintBrush($key,$alpha){
    $c=(New-AXEBrush $key).Color
    New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($alpha,$c.R,$c.G,$c.B))
}
# ---- helpers de animacion (easing CubicOut, micro-transiciones estilo Fluent) ----
$script:easeOut = New-Object System.Windows.Media.Animation.CubicEase; $script:easeOut.EasingMode='EaseOut'
function New-DblAnim($to,$ms){
    $a=New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To=[double]$to; $a.Duration=[System.Windows.Duration][TimeSpan]::FromMilliseconds($ms); $a.EasingFunction=$script:easeOut; $a
}
function New-ColorAnim($to,$ms){
    $a=New-Object System.Windows.Media.Animation.ColorAnimation
    $a.To=[System.Windows.Media.Color]$to; $a.Duration=[System.Windows.Duration][TimeSpan]::FromMilliseconds($ms); $a.EasingFunction=$script:easeOut; $a
}
# Fade-in de un elemento (cambio de vista). Opacity 0 -> 1.
function Start-AXEFade($el,$ms=170){
    $el.Opacity=0
    $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty,(New-DblAnim 1 $ms))
}
# Pulso del tile al activar un tweak (scale 1 -> 1.18 -> 1, centrado). Solo en accion del usuario.
function Pulse-Tile($tile){
    if($tile.RenderTransform -isnot [System.Windows.Media.ScaleTransform]){
        $tile.RenderTransformOrigin=New-Object System.Windows.Point(0.5,0.5)
        $tile.RenderTransform=New-Object System.Windows.Media.ScaleTransform
    }
    $a=New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To=1.18; $a.Duration=[System.Windows.Duration][TimeSpan]::FromMilliseconds(110); $a.AutoReverse=$true; $a.EasingFunction=$script:easeOut
    $tile.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty,$a)
    $tile.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty,$a)
}
$script:tweakCats = New-Object System.Collections.ArrayList
foreach($tw in $script:CAT){ if(-not $script:tweakCats.Contains($tw.Cat)){ [void]$script:tweakCats.Add($tw.Cat) } }
$script:actionCats = @('FPS','MEDICION','REGISTRO','LIMPIEZA','DEBLOAT','DNS','STARTUP','PERFILES','ASISTENTE IA')
# Badge "Recomendado" = §3.4, calculado contra ESTA maquina (Get-AXERecommended en 20-tweaks).
# Al arrancar el HW aun no esta (runspace); sale el nucleo universal y Apply-AXEGating
# lo recalcula en cuanto la deteccion termina. $script:recBadges guarda el Border de cada
# tarjeta para poder encender/apagar la insignia sin reconstruir la vista.
$script:RECOMMENDED = @(Get-AXERecommended)
$script:recBadges   = @{}

$script:views    = @{}   # cat -> panel (en ContentHost)
$script:rows     = @{}   # cat -> lista de @{Tw;Toggle;Desc}
$script:navBtns  = @{}
$script:activeCat = $null
$script:busy = $false

# ---- 12.8 construir una tarjeta de tweak ----
function New-TweakCard($tw){
    $tierKey = switch($tw.Tier){ 0 {'Green'} 1 {'Accent'} 2 {'Red'} }
    $tierTip = switch($tw.Tier){ 0 {'Tier 0 - Seguro'} 1 {'Tier 1 - Elite'} 2 {'Tier 2 - EXTREMO (baja seguridad)'} }
    $glyph = $script:glyphs[$tw.Cat]; if(-not $glyph){ $glyph=[char]0xE9D9 }

    $card = New-Object System.Windows.Controls.Border
    $card.Background = New-AXEBrush 'Surface'; $card.BorderBrush = New-AXEBrush 'Line'
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    # Radio corto: chasis de instrumento, no burbuja. Padding izq 0 -> la espina toca el borde.
    $card.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $card.Padding = New-Object System.Windows.Thickness(0,11,14,11)
    $card.Margin = New-Object System.Windows.Thickness(0,0,0,6)

    $g = New-Object System.Windows.Controls.Grid
    foreach($w in @('Auto','Auto','*','Auto')){ $cd=New-Object System.Windows.Controls.ColumnDefinition; $cd.Width=$w; [void]$g.ColumnDefinitions.Add($cd) }

    # FIRMA: espina de riesgo. Barra vertical tenida por tier en el borde izquierdo.
    # Es el UNICO sitio de la tarjeta donde vive el color de tier: al scrollear, el catalogo
    # se lee como un espectro de riesgo y el racimo de Tier 2 salta a la vista sin leer nada.
    $spine = New-Object System.Windows.Controls.Border
    $spine.Width=3; $spine.CornerRadius=New-Object System.Windows.CornerRadius(2)
    $spine.Background = New-AXEBrush $tierKey
    # Margen negativo = padding vertical de la tarjeta (11) menos 3px de respiro arriba/abajo.
    # Sin esto la espina queda recortada y flotando: se lee como un tick suelto, no como espina.
    $spine.VerticalAlignment='Stretch'; $spine.Margin=New-Object System.Windows.Thickness(0,-8,13,-8)
    $spine.ToolTip=$tierTip
    # Tier 1 es la NORMA (55 de 77 tweaks): a plena saturacion pinta la columna entera de
    # ambar y el "espectro de riesgo" deja de discriminar - T0 y T2 se pierden en el muro.
    # Atenuando solo T1, lo excepcional (verde seguro / rojo extremo) vuelve a saltar.
    if($tw.Tier -eq 1){ $spine.Opacity = 0.45 }
    [System.Windows.Controls.Grid]::SetColumn($spine,0); [void]$g.Children.Add($spine)

    # Tile de icono: NEUTRO. Marca categoria, no riesgo. Tintarlo tambien por tier duplicaria
    # la senal y le quitaria fuerza a la espina (una senal, un sitio).
    $tile = New-Object System.Windows.Controls.Border
    $tile.Width=34; $tile.Height=34; $tile.CornerRadius=New-Object System.Windows.CornerRadius(7)
    $tile.Background = New-AXEBrush 'Surface2'
    $tile.VerticalAlignment='Center'; $tile.Margin=New-Object System.Windows.Thickness(0,0,12,0); $tile.ToolTip=$tierTip
    $ico = New-Object System.Windows.Controls.TextBlock
    $ico.Text=$glyph; $ico.FontFamily=New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $ico.FontSize=16; $ico.Foreground=New-AXEBrush 'Muted'; $ico.HorizontalAlignment='Center'; $ico.VerticalAlignment='Center'
    $tile.Child=$ico
    [System.Windows.Controls.Grid]::SetColumn($tile,1); [void]$g.Children.Add($tile)

    $left = New-Object System.Windows.Controls.StackPanel; $left.VerticalAlignment='Center'
    $nameRow = New-Object System.Windows.Controls.StackPanel; $nameRow.Orientation='Horizontal'
    # Codigo de tier en mono: dato de maquina, escaneable, sin ir a buscar la leyenda.
    $tierC = New-Object System.Windows.Controls.TextBlock
    $tierC.Text=("T{0}" -f $tw.Tier); $tierC.FontFamily=$win.FindResource('Mono')
    $tierC.FontSize=10.5; $tierC.Foreground=New-AXEBrush $tierKey; $tierC.VerticalAlignment='Center'
    $tierC.Margin=New-Object System.Windows.Thickness(0,1,8,0); $tierC.ToolTip=$tierTip
    if($tw.Tier -eq 1){ $tierC.Opacity = 0.6 }   # mismo motivo que la espina: T1 es el fondo, no la senal
    [void]$nameRow.Children.Add($tierC)
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text=$tw.Name; $name.FontWeight='SemiBold'; $name.FontSize=13.5; $name.VerticalAlignment='Center'
    [void]$nameRow.Children.Add($name)
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text=$tw.Desc; $desc.Foreground=New-AXEBrush 'Muted'; $desc.TextWrapping='Wrap'; $desc.Margin=New-Object System.Windows.Thickness(0,3,10,0); $desc.FontSize=11.5
    [void]$left.Children.Add($nameRow); [void]$left.Children.Add($desc)
    [System.Windows.Controls.Grid]::SetColumn($left,2); [void]$g.Children.Add($left)

    $tog = New-Object System.Windows.Controls.CheckBox
    $tog.Style = $win.FindResource('ToggleSwitch'); $tog.VerticalAlignment='Center'; $tog.Tag=$tw
    [System.Windows.Automation.AutomationProperties]::SetName($tog,$tw.Name)
    [System.Windows.Controls.Grid]::SetColumn($tog,3); [void]$g.Children.Add($tog)

    $blk = Get-BlockReason $tw
    if($blk){
        # Bloqueado es un ESTADO, no un tier: apaga la espina (el riesgo ya no aplica a esta
        # maquina) y mueve la senal al tile + candado, para no ensuciar el espectro de riesgo.
        $tog.IsEnabled=$false; $desc.Foreground=New-AXEBrush 'Muted'; $desc.Text="No aplica: $blk"
        $spine.Background = New-AXEBrush 'Line'
        $card.Opacity = 0.62
        $tile.Background = New-AXEBrush 'Surface2'; $ico.Foreground=New-AXEBrush 'Muted'; $ico.Text=[char]0xE72E  # candado
    }
    # Insignia "Para tu equipo". VERDE, no ambar: el ambar es el color de la accion primaria
    # (APLICAR) y de Tier 1. Si la insignia tambien fuese ambar, tres cosas distintas
    # competirian por el mismo color y ninguna destacaria. Verde = "esto te conviene".
    # Se construye SIEMPRE y se oculta si no toca: asi Apply-AXEGating puede encenderla
    # cuando llega el hardware, sin reconstruir la tarjeta.
    $recB = New-Object System.Windows.Controls.Border
    $recB.Background=New-TintBrush 'Green' 30
    $recB.CornerRadius=New-Object System.Windows.CornerRadius(5); $recB.Padding=New-Object System.Windows.Thickness(6,1,6,2)
    $recB.Margin=New-Object System.Windows.Thickness(9,0,0,0); $recB.VerticalAlignment='Center'
    $recB.ToolTip='Recomendado para ESTE equipo segun el hardware detectado (RAM, disco, GPU, red, portatil/sobremesa).'
    $recT = New-Object System.Windows.Controls.TextBlock
    $recT.Text='Para tu equipo'; $recT.Foreground=New-AXEBrush 'Green'; $recT.FontSize=10; $recT.FontWeight='SemiBold'
    $recB.Child=$recT; [void]$nameRow.Children.Add($recB)
    $recB.Visibility = if(-not $blk -and ($script:RECOMMENDED -contains $tw.Id)){'Visible'}else{'Collapsed'}
    $script:recBadges[$tw.Id] = $recB
    # Atajo a regedit.exe. Solo si el tweak TIENE clave: 23 de 78 son servicios o bcdedit y un
    # boton que abre la raiz del registro seria peor que no tenerlo. La ruta se extrae del
    # Test/Apply (ver 38-regedit.ps1), no de un campo declarado que podria quedar desfasado.
    $regPaths = @(Get-AXERegPathsForTweak $tw)
    if($regPaths.Count -gt 0){
        $regB = New-Object System.Windows.Controls.Border
        $regB.Background=New-TintBrush 'Accent' 26
        $regB.CornerRadius=New-Object System.Windows.CornerRadius(5); $regB.Padding=New-Object System.Windows.Thickness(6,1,6,2)
        $regB.Margin=New-Object System.Windows.Thickness(6,0,0,0); $regB.VerticalAlignment='Center'
        $regB.Cursor='Hand'
        $regB.ToolTip="Abrir regedit.exe en:`n$($regPaths -join "`n")"
        $regT = New-Object System.Windows.Controls.TextBlock
        $regT.Text='regedit'; $regT.Foreground=New-AXEBrush 'Accent'; $regT.FontSize=10; $regT.FontWeight='SemiBold'
        $regB.Child=$regT
        # Handled=$true OBLIGATORIO: la tarjeta entera es clicable (MouseLeftButtonUp conmuta
        # el tweak). Sin esto, abrir regedit marcaria ademas el ajuste para aplicar, que es
        # justo lo contrario de "solo quiero mirar la clave".
        $regB.Add_MouseLeftButtonUp({ param($s,$e)
            $e.Handled=$true
            [void](Open-AXERegedit $regPaths[0])
        }.GetNewClosure())
        [void]$nameRow.Children.Add($regB)
    }
    # Card clickable (patron Fluent SettingsCard) + hover ANIMADO: eleva (lift) + fade de fondo + sombra.
    # NO toca BorderBrush -> no pisa el borde accent de "cambio pendiente" (Update-AXEPending).
    if(-not $blk){
        $tog.Add_Click({ if($tog.IsChecked){ Pulse-Tile $tile }; Update-AXEPending }.GetNewClosure())
        $card.Cursor='Hand'; $card.Tag=$tog
        # brush propio (animable; el de recursos esta congelado) + transform de elevacion
        $card.Background = New-Object System.Windows.Media.SolidColorBrush ((New-AXEBrush 'Surface').Color)
        $card.RenderTransform = New-Object System.Windows.Media.TranslateTransform
        $card.Add_MouseEnter({ param($s,$e)
            $s.Effect=$script:cardShadow   # sombra: assign en enter (sin coste en reposo)
            $s.Background.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty,(New-ColorAnim (New-AXEBrush 'Surface2').Color 130))
            $s.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty,(New-DblAnim -3 130))
        })
        $card.Add_MouseLeave({ param($s,$e)
            $s.Effect=$null
            $s.Background.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty,(New-ColorAnim (New-AXEBrush 'Surface').Color 150))
            $s.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty,(New-DblAnim 0 150))
        })
        $card.Add_MouseLeftButtonUp({ param($s,$e)
            if($tog.IsEnabled -and -not $tog.IsMouseOver){ $tog.IsChecked = -not $tog.IsChecked; if($tog.IsChecked){ Pulse-Tile $tile }; Update-AXEPending }
        }.GetNewClosure())
    }
    $card.Child=$g
    @{Card=$card; Toggle=$tog; Desc=$desc; Tw=$tw; Blocked=[bool]$blk; Base=$null}
}

# ---- 12.9 construir vistas de tweaks ----
function Build-TweakViews {
    $allTweaks=@($script:CAT)
    foreach($catName in $script:tweakCats){
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Visibility='Collapsed'
        [void]$ContentHost.Children.Add($panel)
        $script:views[$catName]=$panel
        $script:rows[$catName]=New-Object System.Collections.ArrayList
        foreach($tw in ($allTweaks | Where-Object { $_.Cat -eq $catName })){
            try {
                $e = New-TweakCard $tw
                [void]$panel.Children.Add($e.Card)
                [void]$script:rows[$catName].Add($e)
            } catch { Write-AXELog "No pude construir card $($tw.Id): $($_.Exception.Message)" 'ERR' }
        }
    }
}
Build-TweakViews

# ---- 12.9b tarea en segundo plano (runspace + poll DispatcherTimer) ----
# A2: LIMPIEZA/DEBLOAT/DNS corrian inline en el UI thread (Remove-AppxPackage ~20-30s,
# Stop/Start-Service, purga de todos los procesos) => freeze. Ahora van a un runspace
# de fondo con el MISMO patron que el "Punto de restauracion". El $Work DEVUELVE lineas
# de log (string[]); al completar se escriben con Write-AXELog en el UI thread. Args solo
# ESCALARES (une arrays con coma; el $Work los separa) para evitar aplanado de PowerShell.
$script:jobPS=$null
# Bombea la cola del dispatcher hasta idle (permite que DispatcherTimer ticke sin ShowDialog).
# Vive AQUI y no dentro del selftest a proposito. Estaba definida como funcion anidada en
# 60-gui-selftest.ps1, o sea que existia SOLO mientras corria el harness: cualquier handler que
# la llamase pasaba el gate en verde y reventaba con CommandNotFoundException en el primer clic
# del usuario. Paso de verdad. Un helper que solo existe en tests convierte el test en un
# entorno distinto del de produccion, que es justo lo que un test no debe ser.
#   OJO al usarla: PushFrame es REENTRANTE y procesa entrada, asi que durante el bombeo se
#   pueden pulsar otros botones. Para "solo repintar antes de una tarea larga" NO uses esto:
#   usa Dispatcher.Invoke([action]{},'Render'), que repinta sin dejar pasar clics.
function Invoke-AXEDoEvents {
    $frame=New-Object System.Windows.Threading.DispatcherFrame
    [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::SystemIdle,[action]{ $frame.Continue=$false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Start-AXEJob {
    param([scriptblock]$Work,[string[]]$JobArgs=@(),$Button)
    # H10: mutex unico con APLICAR/MASTER. $script:busy cubre tambien Limpieza/DNS/Debloat/
    # Startup para que ninguna tarea de fondo mute el sistema mientras corre otra operacion.
    if($script:busy -or $script:jobPS){ Write-AXELog 'Otra operacion en curso, espera a que termine.' 'WARN'; return }
    $script:busy=$true
    if($Button){ $script:jobBtn=$Button; $Button.IsEnabled=$false } else { $script:jobBtn=$null }
    $ps=[PowerShell]::Create(); [void]$ps.AddScript($Work)
    foreach($a in $JobArgs){ [void]$ps.AddArgument($a) }
    $script:jobPS=$ps; $script:jobHandle=$ps.BeginInvoke()
    $script:jobTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:jobTimer.Interval=[TimeSpan]::FromMilliseconds(120)
    $script:jobTimer.Add_Tick({
        if(-not $script:jobHandle.IsCompleted){ return }
        $script:jobTimer.Stop()
        try { $res=$script:jobPS.EndInvoke($script:jobHandle) } catch { $res=@("ERROR tarea de fondo: $($_.Exception.Message)") }
        $script:jobPS.Dispose(); $script:jobPS=$null
        foreach($line in $res){
            if($null -eq $line -or "$line" -eq ''){ continue }
            $lvl = if("$line" -match '^(ERROR|ERR)\b'){'ERR'} elseif("$line" -match '^WARN\b'){'WARN'} else {'INFO'}
            Write-AXELog ("$line" -replace '^(ERROR|ERR|WARN)\s*','') $lvl
        }
        if($script:jobBtn){ $script:jobBtn.IsEnabled=$true; $script:jobBtn=$null }
        $script:busy=$false   # H10: libera el mutex al completar la tarea
    })
    $script:jobTimer.Start()
}



# >>>>> MODULE: 55-gui-actions.ps1 >>>>>
# ---- 12.10 vistas de accion ----
function New-ActionButton($text,$brushKey){
    $b=New-Object System.Windows.Controls.Button; $b.Style=$win.FindResource('Pill')
    $b.Background=New-AXEBrush $brushKey; $b.Content=$text; $b.HorizontalAlignment='Left'; $b.Margin=New-Object System.Windows.Thickness(0,0,0,8)
    $b
}
function Build-ActionView($catName){
    $panel=New-Object System.Windows.Controls.StackPanel; $panel.Visibility='Collapsed'
    [void]$ContentHost.Children.Add($panel); $script:views[$catName]=$panel
    switch($catName){
        'LIMPIEZA' {
            # --- monitor auto standby (ISLC-style): purga cuando la RAM libre baja del umbral ---
            $mon=New-Object System.Windows.Controls.StackPanel; $mon.Orientation='Horizontal'; $mon.Margin=New-Object System.Windows.Thickness(0,0,0,4)
            $sbTog=New-Object System.Windows.Controls.CheckBox; $sbTog.Style=$win.FindResource('ToggleSwitch'); $sbTog.VerticalAlignment='Center'
            [System.Windows.Automation.AutomationProperties]::SetName($sbTog,'Auto-limpiar standby cuando la RAM libre baja')
            $sbLbl=New-Object System.Windows.Controls.TextBlock; $sbLbl.Text='Auto-limpiar standby'; $sbLbl.Foreground=New-AXEBrush 'Fg'; $sbLbl.FontWeight='SemiBold'; $sbLbl.VerticalAlignment='Center'; $sbLbl.Margin=New-Object System.Windows.Thickness(10,0,0,0)
            [void]$mon.Children.Add($sbTog); [void]$mon.Children.Add($sbLbl); [void]$panel.Children.Add($mon)
            $sbInfo=New-Object System.Windows.Controls.TextBlock; $sbInfo.Text='Monitor ON: cada 5s, si la RAM libre baja del 15%, AXE purga la standby list. Solo mientras AXE este abierto.'; $sbInfo.Foreground=New-AXEBrush 'Muted'; $sbInfo.FontSize=12; $sbInfo.TextWrapping='Wrap'; $sbInfo.Margin=New-Object System.Windows.Thickness(0,0,0,12)
            [void]$panel.Children.Add($sbInfo)
            $sbTog.Add_Checked({
                if(-not $script:sbTimer){
                    $script:sbTimer=New-Object System.Windows.Threading.DispatcherTimer
                    $script:sbTimer.Interval=[TimeSpan]::FromSeconds(5)
                    # ponytail: umbral fijo 15%, chequeo en UI thread (CIM ya caliente por deteccion HW). Config si alguien lo pide.
                    $script:sbTimer.Add_Tick({
                        if($script:busy){ return }
                        try {
                            $os=Get-CimInstance Win32_OperatingSystem
                            $freePct=$os.FreePhysicalMemory/$os.TotalVisibleMemorySize
                            if($freePct -lt 0.15){
                                $rc=[AXE.Native]::PurgeStandby()
                                if($rc -eq 0){ Write-AXELog ("Auto-standby: RAM libre {0:P0} < 15%, standby purgada." -f $freePct) }
                                elseif($rc -eq -4){ Write-AXELog 'Auto-standby: sin privilegio (ejecuta como admin). Monitor detenido.' 'WARN'; $script:sbTimer.Stop() }
                            }
                        } catch { Write-AXELog "Auto-standby: $($_.Exception.Message)" 'WARN' }
                    })
                }
                $script:sbTimer.Start(); Write-AXELog 'Monitor standby ON (cada 5s, umbral 15%).'
            })
            $sbTog.Add_Unchecked({ if($script:sbTimer){ $script:sbTimer.Stop() }; Write-AXELog 'Monitor standby OFF.' })
            foreach($cl in $script:CLEAN){
                $card=New-Object System.Windows.Controls.Border; $card.Background=New-AXEBrush 'Surface'; $card.BorderBrush=New-AXEBrush 'Line'
                $card.BorderThickness=New-Object System.Windows.Thickness(1); $card.CornerRadius=New-Object System.Windows.CornerRadius(8)
                $card.Padding=New-Object System.Windows.Thickness(14,10,14,10); $card.Margin=New-Object System.Windows.Thickness(0,0,0,8)
                $g=New-Object System.Windows.Controls.Grid
                $ca=New-Object System.Windows.Controls.ColumnDefinition; $ca.Width='*'; $cb=New-Object System.Windows.Controls.ColumnDefinition; $cb.Width='Auto'
                [void]$g.ColumnDefinitions.Add($ca); [void]$g.ColumnDefinitions.Add($cb)
                $sp=New-Object System.Windows.Controls.StackPanel
                $t=New-Object System.Windows.Controls.TextBlock; $t.Text=$cl.Name; $t.FontWeight='SemiBold'
                $d=New-Object System.Windows.Controls.TextBlock; $d.Text=$cl.Desc; $d.Foreground=New-AXEBrush 'Muted'; $d.FontSize=12; $d.TextWrapping='Wrap'; $d.Margin=New-Object System.Windows.Thickness(0,3,10,0)
                [void]$sp.Children.Add($t); [void]$sp.Children.Add($d); [System.Windows.Controls.Grid]::SetColumn($sp,0); [void]$g.Children.Add($sp)
                $btn=New-Object System.Windows.Controls.Button; $btn.Style=$win.FindResource('Pill'); $btn.Background=New-AXEBrush 'Accent'; $btn.Content='Ejecutar'; $btn.VerticalAlignment='Center'; $btn.Margin=New-Object System.Windows.Thickness(0)
                $btn.Tag=$cl
                $btn.Add_Click({ param($s,$e)
                    $act=$s.Tag; Write-AXELog "Limpieza: $($act.Name)..."
                    Start-AXEJob -Work { param($src) & ([scriptblock]::Create($src)) } -JobArgs @([string]$act.Run.ToString()) -Button $s
                })
                [System.Windows.Controls.Grid]::SetColumn($btn,1); [void]$g.Children.Add($btn)
                $card.Child=$g; [void]$panel.Children.Add($card)
            }
        }
        'DEBLOAT' {
            $script:debloatChecks=New-Object System.Collections.ArrayList
            foreach($app in $script:DEBLOAT){
                $cb=New-Object System.Windows.Controls.CheckBox; $cb.Content=$app.Name; $cb.Foreground=New-AXEBrush 'Fg'; $cb.Margin=New-Object System.Windows.Thickness(2,4,0,4); $cb.Tag=$app.Pkg
                if(-not (Get-DebloatInstalled $app.Pkg)){ $cb.IsEnabled=$false; $cb.Content="$($app.Name)  (no instalada)"; $cb.Foreground=New-AXEBrush 'Muted' }
                [void]$panel.Children.Add($cb); [void]$script:debloatChecks.Add($cb)
            }
            $btn=New-ActionButton 'Quitar seleccionadas' 'Red'; $btn.Margin=New-Object System.Windows.Thickness(0,10,0,0)
            $btn.Add_Click({ param($s,$e)
                $sel=@(); foreach($cb in $script:debloatChecks){ if($cb.IsEnabled -and $cb.IsChecked){ $sel+=[string]$cb.Tag } }
                if($sel.Count -eq 0){ Write-AXELog 'Sin apps seleccionadas.' 'WARN'; return }
                Write-AXELog "Quitando $($sel.Count) app(s) en segundo plano..."
                Start-AXEJob -Button $s -JobArgs @([string]($sel -join ',')) -Work {
                    param($csv)
                    $out=@()
                    foreach($pkg in ($csv -split ',')){
                        $p=Get-AppxPackage -Name $pkg -EA SilentlyContinue
                        if($p){ try{ $p | Remove-AppxPackage -EA Stop; $out+="Quitada app: $pkg" } catch { $out+="ERROR quitando $pkg : $($_.Exception.Message)" } }
                        else { $out+="No instalada: $pkg" }
                    }
                    $out+="$(@($csv -split ',').Count) app(s) procesadas."
                    $out
                }
            })
            [void]$panel.Children.Add($btn)
        }
        'DNS' {
            foreach($dns in $script:DNSPROFILES){
                $b=New-ActionButton $dns.Name 'Accent'; $b.Tag=$dns.V4
                $b.Add_Click({ param($s,$e)
                    $nic=[string]$script:HW.NicName
                    $csv=$(if($s.Tag){ ($s.Tag -join ',') } else { '' })
                    Write-AXELog 'Aplicando DNS en segundo plano...'
                    Start-AXEJob -Button $s -JobArgs @($nic,[string]$csv) -Work {
                        param($nic,$serverCsv)
                        if(-not $nic){ return @('WARN Sin adaptador activo detectado') }
                        if([string]::IsNullOrEmpty($serverCsv)){ Set-DnsClientServerAddress -InterfaceAlias $nic -ResetServerAddresses; $msg='DNS -> automatico (DHCP)' }
                        else { Set-DnsClientServerAddress -InterfaceAlias $nic -ServerAddresses ($serverCsv -split ','); $msg="DNS -> $($serverCsv -replace ',',', ')" }
                        Clear-DnsClientCache
                        @($msg)
                    }
                })
                $lbl=New-Object System.Windows.Controls.TextBlock; $lbl.Text=$(if($dns.V4){$dns.V4 -join '   /   '}else{'quita DNS manual (DHCP)'}); $lbl.Foreground=New-AXEBrush 'Muted'; $lbl.FontSize=12; $lbl.Margin=New-Object System.Windows.Thickness(2,0,0,10)
                [void]$panel.Children.Add($b); [void]$panel.Children.Add($lbl)
            }
        }
        'STARTUP' {
            $script:startupChecks=New-Object System.Collections.ArrayList
            foreach($ar in (Get-Autoruns)){
                $cb=New-Object System.Windows.Controls.CheckBox; $cb.Content="[$($ar.Hive)] $($ar.Name)"; $cb.Foreground=New-AXEBrush 'Fg'; $cb.Margin=New-Object System.Windows.Thickness(2,4,0,2); $cb.Tag=$ar
                $cb.ToolTip=$ar.Value
                [void]$panel.Children.Add($cb); [void]$script:startupChecks.Add($cb)
            }
            $row=New-Object System.Windows.Controls.StackPanel; $row.Orientation='Horizontal'; $row.Margin=New-Object System.Windows.Thickness(0,10,0,0)
            $bDis=New-ActionButton 'Desactivar' 'Amber'
            $bDis.Add_Click({
                if($script:busy){ Write-AXELog 'Otra operacion en curso, espera a que termine.' 'WARN'; return }   # H10/H11 mutex
                $n=0; foreach($cb in $script:startupChecks){ if($cb.IsChecked){ Disable-Autorun $cb.Tag; $n++ } }
                Write-AXELog "$n autorun(s) desactivado(s)."
            })
            $bRes=New-ActionButton 'Restaurar backup' 'Green'
            $bRes.Add_Click({
                if($script:busy){ Write-AXELog 'Otra operacion en curso, espera a que termine.' 'WARN'; return }   # H10/H11 mutex
                Restore-Autorun | Out-Null
            })
            [void]$row.Children.Add($bDis); [void]$row.Children.Add($bRes); [void]$panel.Children.Add($row)
        }
        'PERFILES' {
            # --- fila monitor automatico ---
            $mon=New-Object System.Windows.Controls.StackPanel; $mon.Orientation='Horizontal'; $mon.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            $script:profMonTog=New-Object System.Windows.Controls.CheckBox; $script:profMonTog.Style=$win.FindResource('ToggleSwitch'); $script:profMonTog.VerticalAlignment='Center'
            [System.Windows.Automation.AutomationProperties]::SetName($script:profMonTog,'Monitor automatico de perfiles por juego')
            $monLbl=New-Object System.Windows.Controls.TextBlock; $monLbl.Text='Monitor automatico'; $monLbl.Foreground=New-AXEBrush 'Fg'; $monLbl.FontWeight='SemiBold'; $monLbl.VerticalAlignment='Center'; $monLbl.Margin=New-Object System.Windows.Thickness(10,0,0,0)
            [void]$mon.Children.Add($script:profMonTog); [void]$mon.Children.Add($monLbl); [void]$panel.Children.Add($mon)
            $info=New-Object System.Windows.Controls.TextBlock; $info.Text='Monitor ON: al abrir un juego con perfil, AXE cambia su plan de energia; al cerrarlo lo restaura. No toca el proceso del juego (0 riesgo anticheat).'; $info.Foreground=New-AXEBrush 'Muted'; $info.FontSize=12; $info.TextWrapping='Wrap'; $info.Margin=New-Object System.Windows.Thickness(0,0,0,12)
            [void]$panel.Children.Add($info)
            $script:profMonTog.Add_Checked({
                if(-not $script:profTimer){
                    $script:profTimer=New-Object System.Windows.Threading.DispatcherTimer
                    $script:profTimer.Interval=[TimeSpan]::FromSeconds(4)
                    $script:profTimer.Add_Tick({ try { Tick-GameProfiles | Out-Null } catch { Write-AXELog "Monitor perfiles: $($_.Exception.Message)" 'ERR' } })
                }
                $script:profTimer.Start(); Write-AXELog 'Monitor de perfiles ON (revisa cada 4s).'
            })
            $script:profMonTog.Add_Unchecked({ if($script:profTimer){ $script:profTimer.Stop() }; Revert-GameProfile; Write-AXELog 'Monitor de perfiles OFF.' })

            # --- lista de perfiles existentes ---
            $listPanel=New-Object System.Windows.Controls.StackPanel; $listPanel.Margin=New-Object System.Windows.Thickness(0,0,0,10); [void]$panel.Children.Add($listPanel)
            $script:profRefreshList={
                $listPanel.Children.Clear()
                $profs=@(Read-Profiles)
                if($profs.Count -eq 0){
                    $e=New-Object System.Windows.Controls.TextBlock; $e.Text='Sin perfiles todavia. Crea uno abajo.'; $e.Foreground=New-AXEBrush 'Muted'; $e.FontSize=12; [void]$listPanel.Children.Add($e); return
                }
                foreach($p in $profs){
                    $card=New-Object System.Windows.Controls.Border; $card.Background=New-AXEBrush 'Surface'; $card.BorderBrush=New-AXEBrush 'Line'; $card.BorderThickness=New-Object System.Windows.Thickness(1); $card.CornerRadius=New-Object System.Windows.CornerRadius(8); $card.Padding=New-Object System.Windows.Thickness(14,10,14,10); $card.Margin=New-Object System.Windows.Thickness(0,0,0,6)
                    $g=New-Object System.Windows.Controls.Grid
                    $c0=New-Object System.Windows.Controls.ColumnDefinition; $c0.Width='*'; $c1=New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='Auto'
                    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
                    $t=New-Object System.Windows.Controls.TextBlock; $t.Text="$($p.Name)    [$($p.Exe)]    ->  $($p.PlanName)"; $t.Foreground=New-AXEBrush 'Fg'; $t.VerticalAlignment='Center'; $t.TextWrapping='Wrap'
                    [System.Windows.Controls.Grid]::SetColumn($t,0); [void]$g.Children.Add($t)
                    $bb=New-Object System.Windows.Controls.StackPanel; $bb.Orientation='Horizontal'; [System.Windows.Controls.Grid]::SetColumn($bb,1)
                    $ba=New-Object System.Windows.Controls.Button; $ba.Style=$win.FindResource('Pill'); $ba.Background=New-AXEBrush 'Accent'; $ba.Content='Aplicar'; $ba.Height=28; $ba.Padding=New-Object System.Windows.Thickness(12,0,12,0); $ba.Margin=New-Object System.Windows.Thickness(0,0,6,0); $ba.Tag=$p
                    [System.Windows.Automation.AutomationProperties]::SetName($ba,"Aplicar perfil $($p.Name) ahora")
                    $ba.Add_Click({ param($s,$e) if($script:busy){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }; Apply-GameProfile $s.Tag })
                    $bd=New-Object System.Windows.Controls.Button; $bd.Style=$win.FindResource('PillDanger'); $bd.Content='Borrar'; $bd.Height=28; $bd.Padding=New-Object System.Windows.Thickness(12,0,12,0); $bd.Tag=$p.Name
                    [System.Windows.Automation.AutomationProperties]::SetName($bd,"Borrar perfil $($p.Name)")
                    $bd.Add_Click({ param($s,$e) if($script:profActive -eq $s.Tag){ Revert-GameProfile }; Remove-GameProfile $s.Tag; & $script:profRefreshList; Write-AXELog "Perfil '$($s.Tag)' borrado." })
                    [void]$bb.Children.Add($ba); [void]$bb.Children.Add($bd); [void]$g.Children.Add($bb)
                    $card.Child=$g; [void]$listPanel.Children.Add($card)
                }
            }

            # --- formulario de alta ---
            $form=New-Object System.Windows.Controls.Border; $form.Background=New-AXEBrush 'Surface'; $form.BorderBrush=New-AXEBrush 'Line'; $form.BorderThickness=New-Object System.Windows.Thickness(1); $form.CornerRadius=New-Object System.Windows.CornerRadius(8); $form.Padding=New-Object System.Windows.Thickness(14)
            $fp=New-Object System.Windows.Controls.StackPanel
            $ft=New-Object System.Windows.Controls.TextBlock; $ft.Text='Nuevo perfil'; $ft.FontWeight='SemiBold'; $ft.Foreground=New-AXEBrush 'Fg'; $ft.Margin=New-Object System.Windows.Thickness(0,0,0,8); [void]$fp.Children.Add($ft)
            $nameBox=New-Object System.Windows.Controls.TextBox; $nameBox.Style=$win.FindResource('Input'); $nameBox.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            [System.Windows.Automation.AutomationProperties]::SetName($nameBox,'Nombre del perfil'); [void]$fp.Children.Add($nameBox)
            $nameHint=New-Object System.Windows.Controls.TextBlock; $nameHint.Text='Nombre del perfil (ej: CS2 gaming)'; $nameHint.Foreground=New-AXEBrush 'Muted'; $nameHint.FontSize=11; $nameHint.Margin=New-Object System.Windows.Thickness(2,0,0,8); [void]$fp.Children.Add($nameHint)
            $procRow=New-Object System.Windows.Controls.Grid; $pr0=New-Object System.Windows.Controls.ColumnDefinition; $pr0.Width='*'; $pr1=New-Object System.Windows.Controls.ColumnDefinition; $pr1.Width='Auto'; [void]$procRow.ColumnDefinitions.Add($pr0); [void]$procRow.ColumnDefinitions.Add($pr1); $procRow.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            $procCombo=New-Object System.Windows.Controls.ComboBox; $procCombo.IsEditable=$true; $procCombo.Margin=New-Object System.Windows.Thickness(0,0,6,0)
            [System.Windows.Automation.AutomationProperties]::SetName($procCombo,'Proceso del juego'); [System.Windows.Controls.Grid]::SetColumn($procCombo,0); [void]$procRow.Children.Add($procCombo)
            $procBtn=New-Object System.Windows.Controls.Button; $procBtn.Style=$win.FindResource('PillGhost'); $procBtn.Content='Refrescar'; $procBtn.Height=32; [System.Windows.Controls.Grid]::SetColumn($procBtn,1); [void]$procRow.Children.Add($procBtn); [void]$fp.Children.Add($procRow)
            $procHint=New-Object System.Windows.Controls.TextBlock; $procHint.Text='Proceso del juego (elige de la lista o escribe, sin .exe). Abre el juego y pulsa Refrescar.'; $procHint.Foreground=New-AXEBrush 'Muted'; $procHint.FontSize=11; $procHint.TextWrapping='Wrap'; $procHint.Margin=New-Object System.Windows.Thickness(2,0,0,8); [void]$fp.Children.Add($procHint)
            $planCombo=New-Object System.Windows.Controls.ComboBox; $planCombo.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            [System.Windows.Automation.AutomationProperties]::SetName($planCombo,'Plan de energia'); [void]$fp.Children.Add($planCombo)
            $planHint=New-Object System.Windows.Controls.TextBlock; $planHint.Text='Plan de energia a activar mientras el juego corre.'; $planHint.Foreground=New-AXEBrush 'Muted'; $planHint.FontSize=11; $planHint.Margin=New-Object System.Windows.Thickness(2,0,0,10); [void]$fp.Children.Add($planHint)
            $saveBtn=New-Object System.Windows.Controls.Button; $saveBtn.Style=$win.FindResource('Pill'); $saveBtn.Background=New-AXEBrush 'Accent'; $saveBtn.Content='Guardar perfil'; $saveBtn.HorizontalAlignment='Left'
            [System.Windows.Automation.AutomationProperties]::SetName($saveBtn,'Guardar perfil'); [void]$fp.Children.Add($saveBtn)
            $form.Child=$fp; [void]$panel.Children.Add($form)

            # rellenar combos + lista
            $fillProcs={ $procCombo.Items.Clear(); foreach($pn in @(Get-Process -EA SilentlyContinue | Where-Object { $_.MainWindowTitle } | Select-Object -ExpandProperty ProcessName -Unique | Sort-Object)){ [void]$procCombo.Items.Add($pn) } }
            $fillPlans={ $planCombo.Items.Clear(); foreach($pl in (Get-PowerPlans)){ $it=New-Object System.Windows.Controls.ComboBoxItem; $it.Content=$pl.Name; $it.Tag=$pl.Guid; [void]$planCombo.Items.Add($it) }; if($planCombo.Items.Count -gt 0){ $planCombo.SelectedIndex=0 } }
            $procBtn.Add_Click($fillProcs)
            $saveBtn.Add_Click({ param($s,$e)
                $nm=$nameBox.Text.Trim(); $ex=[string]$procCombo.Text; if([string]::IsNullOrWhiteSpace($ex) -and $procCombo.SelectedItem){ $ex=[string]$procCombo.SelectedItem }
                $pi=$planCombo.SelectedItem
                if([string]::IsNullOrWhiteSpace($nm) -or [string]::IsNullOrWhiteSpace($ex) -or -not $pi){ Write-AXELog 'Rellena nombre, proceso y plan.' 'WARN'; return }
                [void](Add-GameProfile $nm $ex $pi.Tag ([string]$pi.Content))
                $nameBox.Clear(); Write-AXELog "Perfil '$nm' guardado ($ex -> $($pi.Content))."
                & $script:profRefreshList
            })
            & $fillProcs; & $fillPlans; & $script:profRefreshList

        }
        'FPS' {
            # ================= FPS: subirlos (10c) y MEDIRLOS (10d) =================
            # Pestana propia y no un apartado de PERFILES: es lo unico de toda la suite que
            # sube FPS de verdad, y estaba enterrado bajo los planes de energia. Aparte, aqui
            # conviven la palanca y su medicion a proposito -- aplicar sin medir es como se
            # llega a un catalogo lleno de placebos, que es justo lo que este proyecto corrigio.
            # ================= GPU POR JUEGO (region 10c) =================
            # Va en esta pestana y no en una nueva porque es la misma idea (ajuste por juego,
            # no global), pero OJO: los perfiles de arriba guardan NOMBRE DE PROCESO y esto
            # necesita RUTA COMPLETA. Windows indexa UserGpuPreferences por ruta, asi que un
            # nombre suelto crearia una entrada que el sistema no mira nunca. De ahi el
            # selector de fichero y que el combo muestre la ruta resuelta, no solo el nombre.
            $gpuHdr=New-Object System.Windows.Controls.TextBlock; $gpuHdr.Text='GPU por juego'; $gpuHdr.FontWeight='SemiBold'; $gpuHdr.FontSize=15; $gpuHdr.Foreground=New-AXEBrush 'Fg'; $gpuHdr.Margin=New-Object System.Windows.Thickness(0,18,0,4); [void]$panel.Children.Add($gpuHdr)

            $gpuInfo=New-Object System.Windows.Controls.TextBlock; $gpuInfo.Foreground=New-AXEBrush 'Muted'; $gpuInfo.FontSize=12; $gpuInfo.TextWrapping='Wrap'; $gpuInfo.Margin=New-Object System.Windows.Thickness(0,0,0,10)
            # El texto NO promete ganancia: la dice segun la maquina. En equipo de una sola
            # GPU, forzar la "dedicada" no existe y fingirlo seria justo el fallo que este
            # proyecto persigue en el resto del catalogo.
            $gpuInfo.Text = if(Test-AXEHybridGpu){
                "Equipo HIBRIDO ($(((Get-AXEGpuList | Select-Object -Expand Name) -join ' + '))). Forzar la GPU dedicada en un juego es el mayor lever de FPS de toda la suite: si Windows lo estaba corriendo en la integrada, no es un 3%, son 2-5x. Los cambios entran al ARRANCAR el juego."
            } else {
                "Una sola GPU ($((Get-AXEGpuList | Select-Object -First 1 -Expand Name))). 'GPU alto rendimiento' no aplica aqui: no hay otra entre la que elegir, ganancia por esa via = 0. El flip model (juegos en ventana) si sirve."
            }
            [void]$panel.Children.Add($gpuInfo)

            # El panel va en scope SCRIPT, no local. $script:gpuRefreshList se invoca despues de
            # que Build-ActionView haya retornado (desde el boton 'Deshacer' y desde el harness),
            # y PowerShell resuelve las variables de un scriptblock EN EL MOMENTO DE LLAMARLO: una
            # local ya no existe entonces y '.Children.Clear()' revienta con "No se puede llamar a
            # un metodo en una expresion con valor NULL".
            #   .GetNewClosure() tampoco vale aqui: crea un scope de modulo propio donde los
            # '$script:*' de este fichero (GpuPrefKey, LayersKey) dejan de resolver, y el fallo se
            # muda a "No se puede enlazar el argumento al parametro 'Path' porque es nulo".
            # Scope script es ademas el idiom que ya usa el resto de la GUI ($script:profMonTog,
            # $script:aiOut, $script:scoreLbl).
            $script:gpuListPanel=New-Object System.Windows.Controls.StackPanel; $script:gpuListPanel.Margin=New-Object System.Windows.Thickness(0,0,0,10); [void]$panel.Children.Add($script:gpuListPanel)
            $script:gpuRefreshList={
                $script:gpuListPanel.Children.Clear()
                $k=Get-Item $script:GpuPrefKey -EA SilentlyContinue
                $names=if($k){ @($k.GetValueNames()) } else { @() }
                if($names.Count -eq 0){
                    $e=New-Object System.Windows.Controls.TextBlock; $e.Text='Sin ajustes por juego. Windows decide la GPU de todo por heuristica.'; $e.Foreground=New-AXEBrush 'Muted'; $e.FontSize=12; [void]$script:gpuListPanel.Children.Add($e); return
                }
                foreach($n in $names){
                    $st=Get-AXEGameGpuState $n
                    # 'Windows decide' (clave ausente) != 'delegado' (0 explicito). Se distinguen
                    # a posta: uno es estado de fabrica, el otro lo escribio alguien.
                    $pv=(ConvertFrom-AXEGpuPref $st.Raw)['GpuPreference']
                    $gtxt=switch($pv){ '2'{'dGPU'} '1'{'iGPU'} '0'{'delegado'} default{'Windows decide'} }
                    $card=New-Object System.Windows.Controls.Border; $card.Background=New-AXEBrush 'Surface'; $card.BorderBrush=New-AXEBrush 'Line'; $card.BorderThickness=New-Object System.Windows.Thickness(1); $card.CornerRadius=New-Object System.Windows.CornerRadius(8); $card.Padding=New-Object System.Windows.Thickness(14,10,14,10); $card.Margin=New-Object System.Windows.Thickness(0,0,0,6)
                    $g=New-Object System.Windows.Controls.Grid
                    $c0=New-Object System.Windows.Controls.ColumnDefinition; $c0.Width='*'; $c1=New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='Auto'
                    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
                    $t=New-Object System.Windows.Controls.TextBlock; $t.Text="$(Split-Path $n -Leaf)    [$gtxt]    flip: $(if($st.FlipModel){'si'}else{'no'})    FSO: $(if($st.NoFSO){'off'}else{'on'})"; $t.Foreground=New-AXEBrush 'Fg'; $t.VerticalAlignment='Center'; $t.TextWrapping='Wrap'; $t.ToolTip=$n
                    [System.Windows.Controls.Grid]::SetColumn($t,0); [void]$g.Children.Add($t)
                    $bu=New-Object System.Windows.Controls.Button; $bu.Style=$win.FindResource('PillDanger'); $bu.Content='Deshacer'; $bu.Height=28; $bu.Padding=New-Object System.Windows.Thickness(12,0,12,0); $bu.Tag=$n
                    [System.Windows.Automation.AutomationProperties]::SetName($bu,"Deshacer ajustes de GPU de $(Split-Path $n -Leaf)")
                    $bu.Add_Click({ param($s,$e)
                        $r=Revert-AXEGameGpu $s.Tag
                        # 0 = AXE nunca capturo ese exe (lo escribio Windows o el usuario). No se
                        # inventa un original: se dice y se deja como esta.
                        if($r -eq 0){ Write-AXELog "GPU '$(Split-Path $s.Tag -Leaf)': sin captura previa de AXE, no revierto (escribir un default seria dejarte un estado que quiza nunca tuviste)." 'WARN' }
                        else { Write-AXELog "GPU '$(Split-Path $s.Tag -Leaf)': restauradas $r clave(s) al estado exacto anterior." }
                        & $script:gpuRefreshList
                    })
                    [System.Windows.Controls.Grid]::SetColumn($bu,1); [void]$g.Children.Add($bu)
                    $card.Child=$g; [void]$script:gpuListPanel.Children.Add($card)
                }
            }

            # --- alta: selector de ejecutable ---
            $gform=New-Object System.Windows.Controls.Border; $gform.Background=New-AXEBrush 'Surface'; $gform.BorderBrush=New-AXEBrush 'Line'; $gform.BorderThickness=New-Object System.Windows.Thickness(1); $gform.CornerRadius=New-Object System.Windows.CornerRadius(8); $gform.Padding=New-Object System.Windows.Thickness(14)
            $gfp=New-Object System.Windows.Controls.StackPanel
            $gft=New-Object System.Windows.Controls.TextBlock; $gft.Text='Optimizar un juego'; $gft.FontWeight='SemiBold'; $gft.Foreground=New-AXEBrush 'Fg'; $gft.Margin=New-Object System.Windows.Thickness(0,0,0,8); [void]$gfp.Children.Add($gft)
            $exeRow=New-Object System.Windows.Controls.Grid; $er0=New-Object System.Windows.Controls.ColumnDefinition; $er0.Width='*'; $er1=New-Object System.Windows.Controls.ColumnDefinition; $er1.Width='Auto'; [void]$exeRow.ColumnDefinitions.Add($er0); [void]$exeRow.ColumnDefinitions.Add($er1); $exeRow.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            $exeCombo=New-Object System.Windows.Controls.ComboBox; $exeCombo.IsEditable=$true; $exeCombo.Margin=New-Object System.Windows.Thickness(0,0,6,0)
            [System.Windows.Automation.AutomationProperties]::SetName($exeCombo,'Ruta del ejecutable del juego'); [System.Windows.Controls.Grid]::SetColumn($exeCombo,0); [void]$exeRow.Children.Add($exeCombo)
            $exeBtn=New-Object System.Windows.Controls.Button; $exeBtn.Style=$win.FindResource('PillGhost'); $exeBtn.Content='Examinar...'; $exeBtn.Height=32; [System.Windows.Controls.Grid]::SetColumn($exeBtn,1); [void]$exeRow.Children.Add($exeBtn); [void]$gfp.Children.Add($exeRow)
            $exeHint=New-Object System.Windows.Controls.TextBlock; $exeHint.Text='Ruta COMPLETA del .exe. El combo lista los juegos abiertos ahora con su ruta ya resuelta; si no esta, usa Examinar.'; $exeHint.Foreground=New-AXEBrush 'Muted'; $exeHint.FontSize=11; $exeHint.TextWrapping='Wrap'; $exeHint.Margin=New-Object System.Windows.Thickness(2,0,0,8); [void]$gfp.Children.Add($exeHint)
            $fsoChk=New-Object System.Windows.Controls.CheckBox; $fsoChk.Content='Apagar tambien Fullscreen Optimizations (opt-in)'; $fsoChk.Foreground=New-AXEBrush 'Fg'; $fsoChk.Margin=New-Object System.Windows.Thickness(0,0,0,4); [void]$gfp.Children.Add($fsoChk)
            $fsoHint=New-Object System.Windows.Controls.TextBlock; $fsoHint.Text='Sin marcar por defecto: en muchos juegos FSO ya usa flip model y quitarlo NO da FPS, solo empeora el alt-tab. Marcalo si mides que te mejora.'; $fsoHint.Foreground=New-AXEBrush 'Muted'; $fsoHint.FontSize=11; $fsoHint.TextWrapping='Wrap'; $fsoHint.Margin=New-Object System.Windows.Thickness(2,0,0,10); [void]$gfp.Children.Add($fsoHint)
            $gpuBtn=New-Object System.Windows.Controls.Button; $gpuBtn.Style=$win.FindResource('Pill'); $gpuBtn.Background=New-AXEBrush 'Accent'; $gpuBtn.Content='Optimizar GPU'; $gpuBtn.HorizontalAlignment='Left'
            [System.Windows.Automation.AutomationProperties]::SetName($gpuBtn,'Optimizar la GPU de este juego'); [void]$gfp.Children.Add($gpuBtn)
            $gform.Child=$gfp; [void]$panel.Children.Add($gform)

            # Procesos con ventana Y ruta legible. El .Path de un proceso elevado o protegido
            # lanza, por eso el try: se omite en vez de tumbar el rellenado entero.
            $fillExes={
                $exeCombo.Items.Clear()
                foreach($pr in @(Get-Process -EA SilentlyContinue | Where-Object { $_.MainWindowTitle })){
                    try { if($pr.Path){ [void]$exeCombo.Items.Add($pr.Path) } } catch {}
                }
            }
            $exeBtn.Add_Click({ param($s,$e)
                $dlg=New-Object Microsoft.Win32.OpenFileDialog
                $dlg.Filter='Ejecutables (*.exe)|*.exe'; $dlg.Title='Elige el ejecutable del juego'
                if($dlg.ShowDialog()){ $exeCombo.Text=$dlg.FileName }
            })
            $gpuBtn.Add_Click({ param($s,$e)
                $ex=[string]$exeCombo.Text; if([string]::IsNullOrWhiteSpace($ex) -and $exeCombo.SelectedItem){ $ex=[string]$exeCombo.SelectedItem }
                if([string]::IsNullOrWhiteSpace($ex)){ Write-AXELog 'Elige el ejecutable del juego.' 'WARN'; return }
                # Optimize-AXEGame ya valida que la ruta exista y devuelve el motivo si no.
                foreach($l in (Optimize-AXEGame -Exe $ex -NoFSO:([bool]$fsoChk.IsChecked))){ Write-AXELog $l }
                & $script:gpuRefreshList
            })
            & $fillExes; & $script:gpuRefreshList

            # --- MEDICION REAL (region 10d) ---
            $mHdr=New-Object System.Windows.Controls.TextBlock; $mHdr.Text='Medir FPS reales'; $mHdr.FontWeight='SemiBold'; $mHdr.FontSize=15; $mHdr.Foreground=New-AXEBrush 'Fg'; $mHdr.Margin=New-Object System.Windows.Thickness(0,18,0,4); [void]$panel.Children.Add($mHdr)
            $mInfo=New-Object System.Windows.Controls.TextBlock; $mInfo.Foreground=New-AXEBrush 'Muted'; $mInfo.FontSize=12; $mInfo.TextWrapping='Wrap'; $mInfo.Margin=New-Object System.Windows.Thickness(0,0,0,10); [void]$panel.Children.Add($mInfo)
            $pmPath=Get-AXEPresentMon
            $mInfo.Text = if($pmPath){
                "PresentMon: $pmPath`nMide el tiempo entre frames PRESENTADOS (la fuente que usan las reviews). El 1% low es lo que mueven los ajustes de esta suite; la media casi no se entera."
            } else {
                'PresentMon no encontrado. Bajalo de github.com/GameTechDev/PresentMon/releases y deja PresentMon.exe junto a AXE. AXE no lo descarga solo: bajar y ejecutar binarios de internet no es cosa de una herramienta que corre como admin.'
            }
            $mOut=New-Object System.Windows.Controls.TextBox; $mOut.IsReadOnly=$true; $mOut.Background=New-AXEBrush 'Surface'; $mOut.Foreground=New-AXEBrush 'Fg'; $mOut.BorderBrush=New-AXEBrush 'Line'; $mOut.BorderThickness=New-Object System.Windows.Thickness(1); $mOut.FontFamily='Consolas'; $mOut.FontSize=12; $mOut.MinHeight=110; $mOut.TextWrapping='NoWrap'; $mOut.VerticalScrollBarVisibility='Auto'; $mOut.Padding=New-Object System.Windows.Thickness(10,10,10,10); $mOut.Margin=New-Object System.Windows.Thickness(0,0,0,8)
            $mOut.Text='Sin medir todavia.'
            $script:fpsOut=$mOut; [void]$panel.Children.Add($mOut)
            $mRow=New-Object System.Windows.Controls.StackPanel; $mRow.Orientation='Horizontal'
            $mBtn=New-Object System.Windows.Controls.Button; $mBtn.Style=$win.FindResource('Pill'); $mBtn.Background=New-AXEBrush 'Accent'; $mBtn.Content='Medir 20s'; $mBtn.Margin=New-Object System.Windows.Thickness(0,0,6,0)
            [System.Windows.Automation.AutomationProperties]::SetName($mBtn,'Medir FPS del juego seleccionado durante 20 segundos')
            $mBase=New-Object System.Windows.Controls.Button; $mBase.Style=$win.FindResource('PillGhost'); $mBase.Content='Guardar como ANTES'; $mBase.Margin=New-Object System.Windows.Thickness(0,0,6,0)
            [System.Windows.Automation.AutomationProperties]::SetName($mBase,'Guardar la ultima medicion como referencia ANTES')
            $mCmp=New-Object System.Windows.Controls.Button; $mCmp.Style=$win.FindResource('PillGhost'); $mCmp.Content='Comparar con ANTES'
            [System.Windows.Automation.AutomationProperties]::SetName($mCmp,'Comparar la ultima medicion con la referencia ANTES')
            [void]$mRow.Children.Add($mBtn); [void]$mRow.Children.Add($mBase); [void]$mRow.Children.Add($mCmp); [void]$panel.Children.Add($mRow)

            # El flujo es en TRES pasos manuales (medir / guardar ANTES / comparar) y no un
            # boton unico de "antes y despues", porque entre las dos capturas hay que aplicar el
            # cambio Y volver a la MISMA escena. Un boton que lo hiciera solo produciria
            # comparaciones de escenas distintas con pinta de rigor.
            $mBtn.Add_Click({ param($s,$e)
                if($script:busy){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }   # H10/H11 mutex
                $ex=[string]$exeCombo.Text; if([string]::IsNullOrWhiteSpace($ex) -and $exeCombo.SelectedItem){ $ex=[string]$exeCombo.SelectedItem }
                if([string]::IsNullOrWhiteSpace($ex)){ Write-AXELog 'Elige arriba el ejecutable del juego que quieres medir.' 'WARN'; return }
                $name=[System.IO.Path]::GetFileNameWithoutExtension($ex)
                $script:fpsOut.Text="Midiendo 20s de $name... (la ventana se queda quieta mientras tanto)"
                $script:fpsOut.Dispatcher.Invoke([action]{},'Render')   # pinta el aviso antes de bloquear
                $r=Measure-AXEFps -ProcessName $name -Seconds 20
                $script:fpsLast=$r
                $script:fpsOut.Text=((Format-AXEFpsStats $r 'Ultima') -join "`r`n")
                foreach($l in (Format-AXEFpsStats $r 'FPS')){ Write-AXELog $l }
            })
            $mBase.Add_Click({ param($s,$e)
                if(-not $script:fpsLast -or -not $script:fpsLast.Ok){ Write-AXELog 'No hay una medicion valida que guardar. Mide primero.' 'WARN'; return }
                $script:fpsBefore=$script:fpsLast
                $script:fpsOut.Text=(((Format-AXEFpsStats $script:fpsBefore 'ANTES (guardado)') -join "`r`n") + "`r`n`r`nAhora aplica el cambio, vuelve a la MISMA escena y pulsa Medir otra vez.")
                Write-AXELog 'Referencia ANTES guardada.'
            })
            $mCmp.Add_Click({ param($s,$e)
                if(-not $script:fpsBefore){ Write-AXELog 'Falta la referencia ANTES. Mide, pulsa Guardar como ANTES, aplica el cambio y vuelve a medir.' 'WARN'; return }
                if(-not $script:fpsLast -or -not $script:fpsLast.Ok){ Write-AXELog 'Falta una medicion valida DESPUES.' 'WARN'; return }
                $v=Get-AXEFpsVerdict -Before $script:fpsBefore -After $script:fpsLast
                $txt=@()
                $txt+=(Format-AXEFpsStats $script:fpsBefore 'ANTES')
                $txt+=(Format-AXEFpsStats $script:fpsLast  'DESPUES')
                $txt+=''
                $txt+=$(if($v.Conclusive){ "VEREDICTO: CONCLUYENTE - $($v.Reason)" } else { "VEREDICTO: NO CONCLUYENTE - $($v.Reason)" })
                if($v.Warning){ $txt+="AVISO: $($v.Warning)" }
                $script:fpsOut.Text=($txt -join "`r`n")
                foreach($l in $txt){ if($l){ Write-AXELog $l } }
            })
        }
        'ASISTENTE IA' {
            $script:aiOut=New-Object System.Windows.Controls.TextBox; $script:aiOut.IsReadOnly=$true; $script:aiOut.Background=New-AXEBrush 'Surface'; $script:aiOut.Foreground=New-AXEBrush 'Fg'
            $script:aiOut.BorderBrush=New-AXEBrush 'Line'; $script:aiOut.BorderThickness=New-Object System.Windows.Thickness(1); $script:aiOut.Padding=New-Object System.Windows.Thickness(12,8,12,8)
            $script:aiOut.Height=340; $script:aiOut.TextWrapping='Wrap'; $script:aiOut.VerticalScrollBarVisibility='Auto'; $script:aiOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:aiOut.FontSize=12
            $script:aiOut.Text="Asistente AXE $($script:AXEVersion) (local, sin API). Pregunta o pulsa ANALIZAR.`r`nTemas: que aplico, input lag, fps, red, seguridad, extremo.`r`n`r`n"
            $inRow=New-Object System.Windows.Controls.Grid; $inRow.Margin=New-Object System.Windows.Thickness(0,8,0,0)
            $q0=New-Object System.Windows.Controls.ColumnDefinition; $q0.Width='*'; $q1=New-Object System.Windows.Controls.ColumnDefinition; $q1.Width='Auto'; $q2=New-Object System.Windows.Controls.ColumnDefinition; $q2.Width='Auto'
            [void]$inRow.ColumnDefinitions.Add($q0); [void]$inRow.ColumnDefinitions.Add($q1); [void]$inRow.ColumnDefinitions.Add($q2)
            $script:aiIn=New-Object System.Windows.Controls.TextBox; $script:aiIn.Style=$win.FindResource('Input'); $script:aiIn.Margin=New-Object System.Windows.Thickness(0,0,8,0)
            [System.Windows.Controls.Grid]::SetColumn($script:aiIn,0); [void]$inRow.Children.Add($script:aiIn)
            $ask=New-Object System.Windows.Controls.Button; $ask.Style=$win.FindResource('Pill'); $ask.Background=New-AXEBrush 'Accent'; $ask.Content='Preguntar'
            [System.Windows.Controls.Grid]::SetColumn($ask,1); [void]$inRow.Children.Add($ask)
            $ana=New-Object System.Windows.Controls.Button; $ana.Style=$win.FindResource('Pill'); $ana.Background=New-AXEBrush 'Purple'; $ana.Content='Analizar'; $ana.Margin=New-Object System.Windows.Thickness(0)
            [System.Windows.Controls.Grid]::SetColumn($ana,2); [void]$inRow.Children.Add($ana)
            $script:aiDoAsk={ if($script:busy){ $script:aiOut.AppendText(">> (operacion en curso; espera a que termine)`r`n"); $script:aiOut.ScrollToEnd(); return }; $qtext=$script:aiIn.Text; if([string]::IsNullOrWhiteSpace($qtext)){return}; $script:aiOut.AppendText(">> $qtext`r`n"); $script:aiOut.AppendText((Invoke-AXEAssistant $qtext)+"`r`n`r`n"); $script:aiOut.ScrollToEnd(); $script:aiIn.Clear() }
            $ask.Add_Click($script:aiDoAsk)
            $script:aiIn.Add_KeyDown({ param($s,$e) if($e.Key -eq 'Return'){ & $script:aiDoAsk; $e.Handled=$true } })
            $ana.Add_Click({ if($script:busy){ $script:aiOut.AppendText(">> (operacion en curso; espera a que termine)`r`n"); $script:aiOut.ScrollToEnd(); return }; $script:aiOut.AppendText(">> Analisis del sistema`r`n"); $script:aiOut.AppendText(((Get-AXERecommendations) -join "`r`n")+"`r`n`r`n"); $script:aiOut.ScrollToEnd() })
            [void]$panel.Children.Add($script:aiOut); [void]$panel.Children.Add($inRow)
        }
        'REGISTRO' {
            # Foto global: que clave toca cada tweak y si el Test la da por aplicada. Solo
            # lectura; escribir sigue siendo cosa de APLICAR (punto de restauracion + snapshot).
            $hint=New-Object System.Windows.Controls.TextBlock
            $hint.Text='Claves del registro que toca el catalogo, agrupadas por ruta. Solo lectura: aqui no se cambia nada. Cada tarjeta de ajuste tiene ademas su propio atajo "regedit".'
            $hint.Foreground=New-AXEBrush 'Muted'; $hint.TextWrapping='Wrap'; $hint.FontSize=12; $hint.Margin=New-Object System.Windows.Thickness(0,0,0,10)
            [void]$panel.Children.Add($hint)

            $script:regOut=New-Object System.Windows.Controls.TextBox
            $script:regOut.IsReadOnly=$true; $script:regOut.Background=New-AXEBrush 'Surface'; $script:regOut.Foreground=New-AXEBrush 'Fg'
            $script:regOut.BorderBrush=New-AXEBrush 'Line'; $script:regOut.BorderThickness=New-Object System.Windows.Thickness(1)
            $script:regOut.Padding=New-Object System.Windows.Thickness(12,8,12,8); $script:regOut.Height=420
            $script:regOut.VerticalScrollBarVisibility='Auto'; $script:regOut.HorizontalScrollBarVisibility='Auto'
            $script:regOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:regOut.FontSize=12
            $script:regOut.Text='Pulsa "Leer estado del registro".'

            $script:regBtn=New-ActionButton 'Leer estado del registro' 'Accent'
            $script:regBtn.Add_Click({
                if($script:busy){ return }
                # ~1.8s medido (ejecuta el Test de 55 tweaks). Corto para montar un runspace,
                # largo para no avisar: se pinta el aviso y se fuerza UNA pasada de render.
                #   Prioridad Render y NO un bombeo tipo PushFrame/DoEvents: el bombeo es
                #   reentrante y procesa entrada, o sea que durante la lectura se podria pulsar
                #   APLICAR y mutar el sistema en mitad del diagnostico. Render repinta sin
                #   dejar pasar clics. (Invoke-AXEDoEvents, ademas, solo existe dentro del
                #   selftest: usarlo aqui reventaba con CommandNotFoundException.)
                $script:busy=$true
                $script:regBtn.IsEnabled=$false
                try {
                    $script:regOut.Text='Leyendo el registro...'
                    $script:regOut.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::Render)
                    $script:regOut.Text=((Format-AXERegDiagnostic (Get-AXERegDiagnostic)) -join "`r`n")
                } catch {
                    $script:regOut.Text="No se pudo leer: $($_.Exception.Message)"
                } finally {
                    $script:regBtn.IsEnabled=$true
                    $script:busy=$false
                }
            })
            [void]$panel.Children.Add($script:regBtn)
            [void]$panel.Children.Add($script:regOut)
        }
        'MEDICION' {
            # Numero grande del score
            $scoreRow=New-Object System.Windows.Controls.StackPanel; $scoreRow.Orientation='Horizontal'; $scoreRow.Margin=New-Object System.Windows.Thickness(0,0,0,4)
            $script:scoreLbl=New-Object System.Windows.Controls.TextBlock; $script:scoreLbl.Text='--'; $script:scoreLbl.FontSize=48; $script:scoreLbl.FontWeight='Bold'; $script:scoreLbl.Foreground=New-AXEBrush 'Accent'; $script:scoreLbl.VerticalAlignment='Center'
            $of=New-Object System.Windows.Controls.TextBlock; $of.Text='/100  AXE Score'; $of.Foreground=New-AXEBrush 'Muted'; $of.FontSize=15; $of.VerticalAlignment='Bottom'; $of.Margin=New-Object System.Windows.Thickness(8,0,0,10)
            [void]$scoreRow.Children.Add($script:scoreLbl); [void]$scoreRow.Children.Add($of); [void]$panel.Children.Add($scoreRow)
            # Desglose
            $script:scoreBreak=New-Object System.Windows.Controls.TextBlock; $script:scoreBreak.Text='Pulsa "Medir ahora" para calcular.'; $script:scoreBreak.Foreground=New-AXEBrush 'Fg'; $script:scoreBreak.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:scoreBreak.FontSize=12; $script:scoreBreak.TextWrapping='Wrap'; $script:scoreBreak.Margin=New-Object System.Windows.Thickness(0,0,0,10)
            [void]$panel.Children.Add($script:scoreBreak)
            # Boton Medir ahora
            $script:measureBtn=New-ActionButton 'Medir ahora' 'Accent'
            $script:measureBtn.Add_Click({ Invoke-AXEMeasure -JitterMs 1000 })
            [void]$panel.Children.Add($script:measureBtn)
            # §3.5: el boton vive en MEDICION a posta. Marca los ajustes de latencia pero NO
            # aplica nada: obliga a pasar por APLICAR (punto de restauracion + snapshot) y deja
            # el medir-antes / medir-despues a un clic, que es lo unico que convierte "va mejor"
            # en un numero. Un boton que tocase el registro directamente se saltaria las dos cosas.
            $script:latBtn=New-ActionButton 'Optimizar latencia e input lag' 'Green'
            $script:latBtn.Add_Click({
                if($script:busy){ return }
                if(-not $script:HW){ Write-AXELog 'Hardware aun sin detectar: espera a que termine para no marcar ajustes que no aplican.' 'WARN'; return }
                $set=@(Get-AXELatencySet); $n=0
                foreach($catName in $script:tweakCats){
                    foreach($e in $script:rows[$catName]){
                        if(-not $e.Blocked -and ($set -contains $e.Tw.Id) -and -not $e.Toggle.IsChecked){ $e.Toggle.IsChecked=$true; $n++ }
                    }
                }
                Update-AXEPending
                Write-AXELog ("Latencia/input lag: {0} ajustes marcados de {1} aplicables a este equipo. NO se ha cambiado nada todavia: pulsa APLICAR." -f $n,$set.Count)
                $notes = @(Get-AXELatencyNotes) | ForEach-Object { "  - $_" }
                $bat = if($script:HW.OnBattery){ "`r`nAVISO: estas en BATERIA. Mide enchufado o los numeros no seran comparables.`r`n" } else { '' }
                $script:measureOut.Text = @"
PLAN DE LATENCIA PARA ESTE EQUIPO
$($script:HW.CpuName) - $($script:HW.RamGB)GB - $(if($script:HW.IsSSD){'SSD'}else{'HDD'}) - $(if($script:HW.IsLaptop){'Portatil'}else{'Sobremesa'}) - $(if($script:HW.IsWifi){'Wi-Fi'}else{'Ethernet'})

$n ajustes marcados ($($set.Count) aplicables; el resto fuera por tu hardware, o por ser Tier 2 / placebo probable).

Por que este plan y no otro:
$($notes -join "`r`n")
$bat
Nada se ha cambiado aun. Para que el numero signifique algo:
  1. "Medir ahora"        -> guarda el score ANTES
  2. "APLICAR cambios"    -> crea punto de restauracion y aplica
  3. Reinicia si se pide  -> varios ajustes solo entran al arrancar
  4. "Medir ahora"        -> compara el score DESPUES

El jitter es un PROXY de latencia: sirve para comparar la misma maquina antes/despues,
no para comparar entre maquinas distintas.
"@
            })
            [void]$panel.Children.Add($script:latBtn)
            # §3.5: barrido de resolucion de timer. Separado de "Medir ahora" a posta -- aquel
            # tarda 1s y se puede pulsar a menudo; este tarda ~30s (3 pasadas) y sube el proceso
            # a prioridad High, asi que no debe colarse dentro del flujo de medir-antes/despues.
            # Corre en runspace de fondo: bloquearlo en el UI thread congelaria la ventana 30s.
            $script:sweepBtn=New-ActionButton 'Barrido de timer (~30s)' 'Accent'
            $script:sweepBtn.Add_Click({ Invoke-AXETimerSweepJob })
            [void]$panel.Children.Add($script:sweepBtn)
            # Reporte / delta
            $script:measureOut=New-Object System.Windows.Controls.TextBox; $script:measureOut.IsReadOnly=$true; $script:measureOut.Background=New-AXEBrush 'Surface'; $script:measureOut.Foreground=New-AXEBrush 'Fg'; $script:measureOut.BorderBrush=New-AXEBrush 'Line'; $script:measureOut.BorderThickness=New-Object System.Windows.Thickness(1); $script:measureOut.Padding=New-Object System.Windows.Thickness(12,8,12,8); $script:measureOut.Height=260; $script:measureOut.TextWrapping='Wrap'; $script:measureOut.VerticalScrollBarVisibility='Auto'; $script:measureOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:measureOut.FontSize=12
            $script:measureOut.Text="Medicion local, 0 dependencias. El jitter es un PROXY de latencia (no atribuible a driver concreto)."
            [void]$panel.Children.Add($script:measureOut)
        }
    }
    $panel
}



# >>>>> MODULE: 57-gui-handlers.ps1 >>>>>
# ---- 12.11 navegacion ----
function Add-NavHeader($text){
    $t=New-Object System.Windows.Controls.TextBlock; $t.Text=$text; $t.FontSize=11; $t.FontWeight='Bold'; $t.Foreground=New-AXEBrush 'Muted'
    $t.Margin=New-Object System.Windows.Thickness(16,10,10,4); [void]$NavPanel.Children.Add($t)
}
function Add-NavItem($catName){
    $rb=New-Object System.Windows.Controls.RadioButton; $rb.Style=$win.FindResource('NavItem')
    $rb.Content=$catName; $rb.Tag=[string]$script:glyphs[$catName]; $rb.GroupName='nav'
    [System.Windows.Automation.AutomationProperties]::SetName($rb,$catName)
    $rb.Add_Checked({ param($s,$e) Switch-View $s.Content })
    [void]$NavPanel.Children.Add($rb); $script:navBtns[$catName]=$rb
}
Add-NavHeader 'OPTIMIZAR'
foreach($catName in $script:tweakCats){ Add-NavItem $catName }
Add-NavHeader 'ACCIONES'
foreach($catName in $script:actionCats){ Add-NavItem $catName }

function Switch-View($catName){
    foreach($v in $script:views.Values){ $v.Visibility='Collapsed' }
    $ContentTitle.Text=$catName; $script:activeCat=$catName
    if($catName -in $script:actionCats){
        $ContentSub.Text = switch($catName){ 'FPS'{'Sube FPS por juego (GPU dedicada + flip model) y mide si es real'} 'MEDICION'{'Mide latencia/timer y calcula el AXE Score'} 'REGISTRO'{'Que claves toca el catalogo (solo lectura)'} 'LIMPIEZA'{'Libera espacio en disco'} 'DEBLOAT'{'Quita apps preinstaladas'} 'DNS'{'Servidores DNS rapidos'} 'STARTUP'{'Programas de arranque'} 'PERFILES'{'Plan de energia por-juego (auto)'} 'ASISTENTE IA'{'Recomendaciones locales, sin internet'} default{''} }
        if(-not $script:views.ContainsKey($catName)){ Build-ActionView $catName | Out-Null }
        $script:views[$catName].Visibility='Visible'; Start-AXEFade $script:views[$catName]; return
    }
    if($script:views.ContainsKey($catName)){ $script:views[$catName].Visibility='Visible'; Start-AXEFade $script:views[$catName] }
    Update-AXESubtitle $catName
}
# Subtitulo de contexto: N tweaks / activas / bloqueadas
function Update-AXESubtitle($catName){
    $rc=$script:rows[$catName]; if(-not $rc){ $ContentSub.Text=''; return }
    $bk=@($rc | Where-Object { $_.Blocked }).Count
    $ac=@($rc | Where-Object { -not $_.Blocked -and $_.Toggle.IsChecked }).Count
    $ContentSub.Text = "$($rc.Count) tweaks - $ac activas" + $(if($bk -gt 0){" - $bk bloqueadas"}else{''})
}

# ---- 12.12 refresh estado ----
# Diff de cambios pendientes: resalta filas sucias + contador vivo en APLICAR
function Update-AXEPending {
    $n=0
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){
            if($e.Blocked){ continue }
            $dirty = ($null -ne $e.Base) -and (([bool]$e.Toggle.IsChecked) -ne ([bool]$e.Base))
            $e.Card.BorderBrush = $(if($dirty){ New-AXEBrush 'Accent' } else { New-AXEBrush 'Line' })
            $e.Card.BorderThickness = New-Object System.Windows.Thickness($(if($dirty){2}else{1}))
            if($dirty){ $n++ }
        }
    }
    $BtnApply.Content = $(if($n -gt 0){ "APLICAR ($n)" } else { 'APLICAR cambios' })
}

# A1: async. Antes corria ~60 Test SINCRONOS en el UI thread (bcdedit, CIM lentos,
# Get-ScheduledTask...) => la ventana se congelaba al arrancar y en "Leer estado".
# Ahora procesa por lotes con DispatcherTimer (mismo patron que APLICAR): la UI
# responde y rellena progresivamente. $Then se invoca al completar (p.ej. re-habilitar
# botones tras APLICAR). Reentrante-seguro via $script:refreshing.
function Refresh-States {
    param([scriptblock]$Then)
    if($script:refreshing){ if($Then){ & $Then }; return }
    $script:refreshing=$true; $script:refThen=$Then
    $script:tCache=@{}   # cacheo de tests: nueva pasada => estado fresco
    $script:refQueue=New-Object System.Collections.Queue
    foreach($catName in $script:tweakCats){ foreach($e in $script:rows[$catName]){ if(-not $e.Blocked){ [void]$script:refQueue.Enqueue($e) } } }
    $script:refOn=0; $script:refApplicable=$script:refQueue.Count
    $script:refTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:refTimer.Interval=[TimeSpan]::FromMilliseconds(1)
    $script:refTimer.Add_Tick({
        $budget=6
        while($budget -gt 0 -and $script:refQueue.Count -gt 0){
            $e=$script:refQueue.Dequeue(); $budget--
            try { $s=[bool](& $e.Tw.Test); $e.Toggle.IsChecked=$s; $e.Base=$s; if($s){$script:refOn++} }
            catch { Write-AXELog "Test fallo: $($e.Tw.Name)" 'WARN' }
        }
        if($script:refQueue.Count -gt 0){ return }
        $script:refTimer.Stop()
        $CountLbl.Text="$($script:refOn)/$($script:refApplicable)"
        if($script:refApplicable -gt 0){ $StatusBar.Value=[int](($script:refOn/$script:refApplicable)*100) }
        Update-AXEPending
        if($script:activeCat -and ($script:activeCat -notin $script:actionCats)){ Update-AXESubtitle $script:activeCat }
        $script:refreshing=$false
        if($script:refThen){ $cb=$script:refThen; $script:refThen=$null; & $cb }
    })
    $script:refTimer.Start()
}

# ---- 12.12b carga HW async (GUI): la ventana no espera los ~3.7s de CIM ----
# Re-aplica el gating a las cards ya construidas (se construyeron con HW=null => sin bloqueo).
function Apply-AXEGating {
    # §3.4: las tarjetas se construyen antes de que el runspace devuelva el hardware, asi
    # que la lista inicial es solo el nucleo universal. Aqui ya hay HW real: se recalcula
    # contra ESTA maquina y se encienden/apagan las insignias en sitio.
    $script:RECOMMENDED = @(Get-AXERecommended)
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){
            $blk = Get-BlockReason $e.Tw
            if($blk -and -not $e.Blocked){
                $e.Blocked=$true; $e.Toggle.IsEnabled=$false; $e.Toggle.IsChecked=$false
                $e.Desc.Foreground=New-AXEBrush 'Red'; $e.Desc.Text="[BLOQUEADO] $blk"
            }
            $b = $script:recBadges[$e.Tw.Id]
            if($b){ $b.Visibility = if(-not $blk -and ($script:RECOMMENDED -contains $e.Tw.Id)){'Visible'}else{'Collapsed'} }
        }
    }
    Write-AXELog ("Recomendaciones ajustadas a tu equipo: {0} de {1} tweaks." -f $script:RECOMMENDED.Count,$script:CAT.Count)
}
# Get-AXEHardware es self-contained (solo CIM + pscustomobject) => corre limpio en runspace.
$script:hwPS=$null
function Start-AXEHardwareLoad {
    if($script:HW){ Build-HwChips; Apply-AXEGating; Refresh-States; return }  # ya cargado
    Write-AXELog 'Detectando hardware en segundo plano...'
    $ps=[PowerShell]::Create(); [void]$ps.AddScript([string](Get-Command Get-AXEHardware).ScriptBlock)
    $script:hwPS=$ps; $script:hwHandle=$ps.BeginInvoke()
    $script:hwTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:hwTimer.Interval=[TimeSpan]::FromMilliseconds(120)
    $script:hwTimer.Add_Tick({
        if(-not $script:hwHandle.IsCompleted){ return }
        $script:hwTimer.Stop()
        try { $res=$script:hwPS.EndInvoke($script:hwHandle); $script:HW=@($res)[0] }
        catch { Write-AXELog "Deteccion HW fallo: $($_.Exception.Message)" 'ERR' }
        $script:hwPS.Dispose(); $script:hwPS=$null
        # H7: sin HW fiable el gating por hardware no se puede evaluar. Fail-safe:
        # deshabilita APLICAR/PRESET/MASTER para no aplicar tweaks a ciegas. "Leer
        # estado" reintenta la deteccion.
        if(-not $script:HW){
            Write-AXELog 'No pude detectar el hardware. APLICAR deshabilitado por seguridad (el gating por HW no es fiable). Pulsa "Leer estado" para reintentar.' 'ERR'
            foreach($b in @($BtnApply,$BtnPreset,$BtnMaster)){ $b.IsEnabled=$false }
            return
        }
        foreach($b in @($BtnApply,$BtnPreset,$BtnMaster)){ $b.IsEnabled=$true }
        Build-HwChips
        Apply-AXEGating
        $nBlk=0; foreach($tw in $script:CAT){ if(Get-BlockReason $tw){ $nBlk++ } }
        Write-AXELog "Hardware detectado. Bloqueados por HW: $nBlk."
        Refresh-States
    })
    $script:hwTimer.Start()
}

# ---- 12.13 buscador ----
# H12: el placeholder es un overlay XAML (watermark real). SearchBox.Text es SIEMPRE
# la query real (vacio = sin filtro); ya no hay hacks de GotFocus/LostFocus.
$SearchBox.Add_TextChanged({
    $q=$SearchBox.Text.ToLower()
    $cat=$script:activeCat
    if(-not $cat -or ($cat -in $script:actionCats)){ return }   # busca solo en categorias de tweaks
    foreach($e in $script:rows[$cat]){
        if($q -eq ''){ $e.Card.Visibility='Visible' }
        else {
            $m = ($e.Tw.Name.ToLower().Contains($q)) -or ($e.Tw.Desc.ToLower().Contains($q))
            $e.Card.Visibility = $(if($m){'Visible'}else{'Collapsed'})
        }
    }
    $ContentTitle.Text = $(if($q -ne ''){"$cat  -  buscar: $q"}else{$cat})
})

# ---- 12.14 acciones principales ----
$BtnRead.Add_Click({
    if(-not $script:HW){ Write-AXELog 'Reintentando deteccion de hardware...'; Start-AXEHardwareLoad; return }   # H7: retry
    Write-AXELog 'Leyendo estado real...'; Refresh-States -Then { Write-AXELog 'Estado actualizado.' }
})

$BtnPreset.Add_Click({
    foreach($catName in $script:tweakCats){
        # net_dns queda FUERA del preset a posta: sobrescribe DNS local/VPN (ver su Desc). Opt-in manual en pestana DNS.
        foreach($e in $script:rows[$catName]){ if(-not $e.Blocked -and $e.Tw.Tier -lt 2 -and $e.Tw.Id -ne 'net_dns'){ $e.Toggle.IsChecked=$true } }
    }
    Update-AXEPending
    Write-AXELog 'Preset GAMING marcado (Tier 0+1, excepto DNS manual). EXTREMO no se toca. Pulsa APLICAR.'
})

# A3: Master revert sin freeze. Antes Invoke-AXEMasterRevert corria ~60 reverts SINCRONOS
# en el UI thread (bcdedit, powercfg, sc.exe, Set-ProcessMitigation) => congelaba la
# ventana varios segundos. Ahora drena el catalogo por lotes con DispatcherTimer (mismo
# patron que APLICAR) y corre el tail (residuos v1 + restore startup) al terminar.
$BtnMaster.Add_Click({
    if($script:busy){ return }
    $r=[System.Windows.MessageBox]::Show("Esto revierte TODOS los tweaks a fabrica + limpia residuos de versiones antiguas. Continuar?",'MASTER REVERT','YesNo','Warning')
    if($r -ne 'Yes'){ return }
    Write-AXELog '=== MASTER REVERT: revirtiendo TODO a fabrica ==='
    $script:mrQueue=New-Object System.Collections.Queue
    foreach($tw in $script:CAT){ if(-not (Get-BlockReason $tw)){ [void]$script:mrQueue.Enqueue($tw) } }
    $script:busy=$true
    foreach($b in @($BtnApply,$BtnPreset,$BtnMaster,$BtnRead)){ $b.IsEnabled=$false }
    $ApplyBar.Visibility='Visible'; $ApplyBar.Value=0
    $script:mrTotal=$script:mrQueue.Count; $script:mrDone=0; $script:mrRev=0
    $script:mrTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:mrTimer.Interval=[TimeSpan]::FromMilliseconds(1)
    $script:mrTimer.Add_Tick({
        $budget=3
        while($budget -gt 0 -and $script:mrQueue.Count -gt 0){
            $tw=$script:mrQueue.Dequeue(); $budget--
            try { if((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id)){ } else { & $tw.Revert }; $script:mrRev++ } catch { Write-AXELog "No pude revertir $($tw.Name): $($_.Exception.Message)" 'ERR' }
            $script:mrDone++
        }
        if($script:mrTotal -gt 0){ $ApplyBar.Value=[int](($script:mrDone/$script:mrTotal)*100) }
        if($script:mrQueue.Count -gt 0){ return }
        $script:mrTimer.Stop()
        Write-AXELog "Revertidos $($script:mrRev) tweaks del catalogo."
        Invoke-AXEMasterRevertTail
        Refresh-States -Then {
            foreach($b in @($BtnApply,$BtnPreset,$BtnMaster,$BtnRead)){ $b.IsEnabled=$true }
            $ApplyBar.Visibility='Collapsed'; $script:busy=$false
        }
    })
    $script:mrTimer.Start()
})

# H2: hay un punto de restauracion reciente (ultimas 24h)? Query no-mutante, seguro.
# CIM root/default SystemRestore funciona en PS 5.1 y pwsh 7. Cualquier fallo => $false
# (asi el Apply ofrece crear uno; nunca asume que existe).
function Test-RecentRestorePoint {
    try {
        $pts = Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -EA Stop
        if(-not $pts){ return $false }
        $cut = (Get-Date).AddHours(-24)
        foreach($p in $pts){
            $ct = $p.CreationTime
            if($ct -is [string]){ try { $ct = [Management.ManagementDateTimeConverter]::ToDateTime($ct) } catch { $ct = $null } }
            if($ct -and $ct -ge $cut){ return $true }
        }
        return $false
    } catch { return $false }
}

# Medicion sin freeze: el busy-loop de jitter (1s) va a un runspace; timer + cobertura
# se calculan al volver en el UI thread (instantaneos). Reusa el patron de rsPS/timers.
$script:snapPrev=$null; $script:snapCur=$null; $script:measurePS=$null; $script:measureBtn=$null
function Invoke-AXEMeasure {
    param([int]$JitterMs=1000,[scriptblock]$OnDone=$null)
    if($script:busy -or $script:measurePS){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }
    # H10: medir TAMBIEN coge el mutex. Antes solo lo LEIA: comprobaba $script:busy pero nunca
    # lo ponia, asi que era la unica operacion de fondo que no lo tomaba. Durante el segundo de
    # muestreo, busy seguia en $false y APLICAR/MASTER/Start-AXEJob podian arrancar y mutar el
    # registro EN MITAD del snapshot, contaminando justo el "antes" del delta antes/despues.
    #   Se llama desde el tail de APLICAR (tras liberar el mutex en el Then de Refresh-States),
    #   no desde dentro, asi que tomarlo aqui no se auto-bloquea.
    $script:busy=$true
    if($script:measureBtn){ $script:measureBtn.IsEnabled=$false }
    if($script:scoreLbl){ $script:scoreLbl.Text='...' }
    $ps=[PowerShell]::Create()
    [void]$ps.AddScript({ param($ms) [AXE.Native]::SampleJitter([int]$ms) })   # tipo visible en el AppDomain
    [void]$ps.AddArgument([int]$JitterMs)
    $script:measurePS=$ps; $script:measureHandle=$ps.BeginInvoke()
    $script:measureTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:measureTimer.Interval=[TimeSpan]::FromMilliseconds(150)
    $script:measureTimer.Add_Tick({
        if(-not $script:measureHandle.IsCompleted){ return }
        $script:measureTimer.Stop()
        # try/finally sobre TODO el cuerpo: ahora que el tick tiene el mutex, una excepcion aqui
        # (Get-AXEScore, New-AXEReport, un Test de tweak) lo dejaria cogido para siempre y la
        # ventana quedaria inerte -- ningun boton volveria a responder y sin error visible.
        # $snap/$sc se declaran fuera para que $OnDone, que corre despues del finally, los vea.
        $snap=$null; $sc=$null
        try {
        try { $r=@($script:measurePS.EndInvoke($script:measureHandle)) } catch { $r=$null }
        $script:measurePS.Dispose(); $script:measurePS=$null
        # ensamblar snapshot en el UI thread
        $jit='n/a'
        if($r -and $r.Count -ge 5){ $jit=[pscustomobject]@{ Samples=[int]$r[0]; MeanMs=[math]::Round($r[1],4); MaxMs=[math]::Round($r[2],4); P999Ms=[math]::Round($r[3],4); Stalls1ms=[int]$r[4] } }
        $timer='n/a'; try { $t=Get-AXETimerResolution; if($t){ $timer=$t } } catch {}
        $on='n/a'; $app='n/a'
        try { $onN=0;$appN=0; foreach($tw in $script:CAT){ if($tw.Tier -notin 0,1){continue}; if(Get-BlockReason $tw){continue}; $appN++; if(Test-TweakSafe $tw){$onN++} }; $on=$onN; $app=$appN } catch {}
        $snap=[pscustomobject]@{ Timestamp=(Get-Date).ToUniversalTime().ToString('u'); Timer=$timer; Jitter=$jit; TweaksOn=$on; TweaksApplicable=$app }
        $script:snapPrev=$script:snapCur; $script:snapCur=$snap
        $sc=Get-AXEScore $snap $script:snapPrev
        if($script:scoreLbl){ $script:scoreLbl.Text="$($sc.Total)" }
        if($script:scoreBreak){ $script:scoreBreak.Text=$sc.Breakdown }
        if($script:measureOut){
            if($script:snapPrev){ $script:measureOut.Text=(New-AXEReport $script:snapPrev $snap (Get-AXEScore $script:snapPrev) $sc) }
            else { $script:measureOut.Text=$sc.Breakdown + "`r`n(mide otra vez para ver delta antes/despues)" }
        }
        if($script:measureBtn){ $script:measureBtn.IsEnabled=$true }
        Write-AXELog "Medicion: AXE Score $($sc.Total)/100."
        } catch {
            Write-AXELog "Medicion fallo: $($_.Exception.Message)" 'ERR'
            if($script:measureBtn){ $script:measureBtn.IsEnabled=$true }
            if($script:measurePS){ $script:measurePS.Dispose(); $script:measurePS=$null }
        } finally {
            # El mutex protege la MEDICION, no el callback: liberar aqui deja a $OnDone lanzar
            # otra tarea de fondo sin bloquearse contra la medicion que acaba de terminar.
            $script:busy=$false
        }
        # Fuera del try: si el cuerpo fallo, $sc es $null y no hay nada que reportar.
        if($OnDone -and $sc){ try { & $OnDone $snap $sc } catch {} }
    })
    $script:measureTimer.Start()
}

# Barrido de timer sin freeze. Mismo patron que Invoke-AXEMeasure, pero con un problema extra:
# el jitter llama a [AXE.Native]::SampleJitter, que es un TIPO .NET y por tanto visible desde
# cualquier runspace del AppDomain. Measure-AXETimerSweep es una FUNCION de PowerShell, y el
# scope de funciones es por-runspace: un [PowerShell]::Create() nuevo no la ve. Por eso se envia
# el codigo fuente de la funcion y sus dependencias, en vez de reimplementar el barrido aqui
# (una copia derivaria del original justo en la logica que decide si el resultado es ruido).
$script:sweepPS=$null; $script:sweepHandle=$null; $script:sweepTimer=$null; $script:sweepBtn=$null
function Invoke-AXETimerSweepJob {
    if($script:busy -or $script:measurePS -or $script:sweepPS){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }
    # Mutex H10 compartido con APLICAR/MASTER: durante el barrido el proceso sube a prioridad
    # High y mantiene un request de resolucion de timer. Dejar que APLICAR corra a la vez
    # mezclaria mutacion del sistema con la medicion que intenta caracterizarlo.
    $script:busy=$true
    if($script:sweepBtn){ $script:sweepBtn.IsEnabled=$false }
    if($script:measureBtn){ $script:measureBtn.IsEnabled=$false }
    if($script:measureOut){ $script:measureOut.Text="Barrido en curso: ~30s (3 pasadas en orden aleatorio).`r`nNo toques nada mientras mide o el delta recogera tu actividad." }
    Write-AXELog 'Barrido de timer: midiendo delta de Sleep(1) por resolucion (~30s).'

    $fnSrc = ''
    # Get-AXESweepVerdict y Get-AXEBand van SI O SI: Measure-AXETimerSweep las llama y el scope
    # de funciones es por-runspace, asi que sin enviarlas el barrido de la GUI muere con
    # "termino no reconocido" DENTRO del runspace, donde el error no se ve. La CLI seguiria
    # funcionando, que es justo lo que hace este fallo dificil de pillar.
    foreach($n in 'Get-RV','Get-AXETimerResolution','Set-AXETimerResolution','Get-AXEBand','Get-AXESweepVerdict','Measure-AXETimerSweep'){
        $fnSrc += "function $n {`r`n" + (Get-Command $n).Definition + "`r`n}`r`n"
    }
    $ps=[PowerShell]::Create()
    [void]$ps.AddScript({
        param($src)
        # Shim de log: en un runspace nuevo no existen $script:AXELog ni $script:LogBox, asi que
        # el Write-AXELog real escribiria Add-Content contra ruta vacia y perderia los avisos
        # (el de GlobalTimerResolutionRequests y el de requests no concedidos, que son justo los
        # que explican un resultado raro). Se recogen aqui y el UI thread los reemite.
        $script:swLog = New-Object System.Collections.ArrayList
        function Write-AXELog { param([string]$Msg,[string]$Level='INFO') [void]$script:swLog.Add("$Level|$Msg") }
        . ([scriptblock]::Create($src))
        [pscustomobject]@{ Sweep=(Measure-AXETimerSweep); Log=@($script:swLog) }
    })
    [void]$ps.AddArgument($fnSrc)
    try { $script:sweepPS=$ps; $script:sweepHandle=$ps.BeginInvoke() }
    catch {
        # Si el arranque falla hay que soltar el mutex aqui: el tick de abajo nunca correra.
        $ps.Dispose(); $script:sweepPS=$null; $script:busy=$false
        if($script:sweepBtn){ $script:sweepBtn.IsEnabled=$true }
        if($script:measureBtn){ $script:measureBtn.IsEnabled=$true }
        Write-AXELog "Barrido: no arranco -> $($_.Exception.Message)" 'ERR'
        return
    }
    $script:sweepTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:sweepTimer.Interval=[TimeSpan]::FromMilliseconds(200)
    $script:sweepTimer.Add_Tick({
        if(-not $script:sweepHandle.IsCompleted){ return }
        $script:sweepTimer.Stop()
        $res=$null
        try { $res=@($script:sweepPS.EndInvoke($script:sweepHandle)) | Select-Object -First 1 }
        catch { Write-AXELog "Barrido: fallo en el runspace -> $($_.Exception.Message)" 'ERR' }
        $script:sweepPS.Dispose(); $script:sweepPS=$null
        # Reemitir los avisos del runspace con el logger real, ya en el UI thread.
        if($res -and $res.Log){
            foreach($e in $res.Log){
                $p="$e" -split '\|',2
                if($p.Count -eq 2){ Write-AXELog $p[1] $p[0] } else { Write-AXELog "$e" }
            }
        }
        $sw = if($res){ $res.Sweep } else { $null }
        if($script:measureOut){ $script:measureOut.Text = ((Format-AXETimerSweep $sw) -join "`r`n") }
        if($sw){
            Write-AXELog $(if($sw.Conclusive){
                "Barrido: mejor resolucion {0:F3}ms (spread {1:F3}ms sobre el ruido)." -f $sw.Best.AppliedMs,$sw.SpreadMs
            } else {
                "Barrido: no concluyente (spread {0:F3}ms dentro del ruido). No se recomienda cambiar nada." -f $sw.SpreadMs
            })
        }
        if($script:sweepBtn){ $script:sweepBtn.IsEnabled=$true }
        if($script:measureBtn){ $script:measureBtn.IsEnabled=$true }
        $script:busy=$false
    })
    $script:sweepTimer.Start()
}

# Apply sin freeze: DispatcherTimer procesa 1 tweak/tick
$BtnApply.Add_Click({
    if($script:busy){ return }
    # construir cola de cambios
    $script:applyQueue=New-Object System.Collections.Queue
    $tier2on=$false
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){
            if($e.Blocked){ continue }
            try{ $cur=[bool](& $e.Tw.Test) }catch{ continue }
            $want=[bool]$e.Toggle.IsChecked
            if($want -ne $cur){
                $script:applyQueue.Enqueue(@{Tw=$e.Tw; Want=$want})
                if($want -and $e.Tw.Tier -eq 2){ $tier2on=$true }
            }
        }
    }
    if($script:applyQueue.Count -eq 0){ Write-AXELog 'Sin cambios.'; return }
    # Gate de seguridad Tier 2
    if($tier2on){
        $r=[System.Windows.MessageBox]::Show("Vas a ACTIVAR tweaks EXTREMO (Tier 2) que DESACTIVAN protecciones de seguridad reales (Tamper Protection, VBS/HVCI, CFG/ASLR, Spectre). Solo en PC dedicada a gaming. Continuar?",'RIESGO DE SEGURIDAD','YesNo','Warning')
        if($r -ne 'Yes'){ Write-AXELog 'Aplicacion cancelada por el usuario (gate Tier 2).' 'WARN'; return }
    }
    # H2: exigir punto de restauracion (opt-out). Si no hay uno reciente, ofrecer crearlo.
    if(-not (Test-RecentRestorePoint)){
        $rp=[System.Windows.MessageBox]::Show("No detecto un punto de restauracion reciente (ultimas 24h). Se recomienda crear uno ANTES de aplicar cambios.`n`nSi = crear ahora (vuelve a pulsar APLICAR cuando termine)`nNo = aplicar SIN punto de restauracion`nCancelar = no hacer nada",'Sin punto de restauracion','YesNoCancel','Warning')
        if($rp -eq 'Cancel'){ Write-AXELog 'Aplicacion cancelada (sin punto de restauracion).' 'WARN'; return }
        if($rp -eq 'Yes'){ Write-AXELog 'Creando punto de restauracion primero. Vuelve a pulsar APLICAR al terminar.'; & $script:doRestorePoint; return }
        Write-AXELog 'Aplicando SIN punto de restauracion (opt-out del usuario).' 'WARN'
    }
    $script:applyPreSnap=$script:snapCur   # baseline: ultima medicion (o $null si no midio aun)
    $script:busy=$true
    foreach($b in @($BtnApply,$BtnPreset,$BtnMaster,$BtnRead)){ $b.IsEnabled=$false }
    $ApplyBar.Visibility='Visible'; $ApplyBar.Value=0
    $script:applyTotal=$script:applyQueue.Count; $script:applyDone=0; $script:reboot=$false; $script:changed=0
    $script:applyTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:applyTimer.Interval=[TimeSpan]::FromMilliseconds(1)
    $script:applyTimer.Add_Tick({
        if($script:applyQueue.Count -eq 0){
            $script:applyTimer.Stop()
            if($script:changed -eq 0){ Write-AXELog 'Sin cambios efectivos.' } else { Write-AXELog "$($script:changed) cambio(s) aplicado(s)." }
            if($script:reboot){ Write-AXELog '>>> ALGUNOS CAMBIOS REQUIEREN REINICIAR <<<' 'WARN' }
            # A1: re-habilitar tras completar el refresh async (evita leer estado a medias)
            Refresh-States -Then {
                foreach($b in @($BtnApply,$BtnPreset,$BtnMaster,$BtnRead)){ $b.IsEnabled=$true }
                $ApplyBar.Visibility='Collapsed'; $script:busy=$false
                # Trust & Proof: medir despues (no bloquea; jitter en runspace). Si habia
                # baseline previa, el reporte muestra el delta antes/despues del apply.
                Invoke-AXEMeasure -JitterMs 1000 -OnDone {
                    param($snap,$sc)
                    $pre=$script:applyPreSnap
                    if($pre -and $script:measureOut){ $script:measureOut.Text=(New-AXEReport $pre $snap (Get-AXEScore $pre) $sc) }
                }
            }
            return
        }
        $item=$script:applyQueue.Dequeue(); $tw=$item.Tw
        try {
            if($item.Want){
                if(Test-SnapEligible $tw){ $script:capTweak=$tw.Id }
                try { & $tw.Apply } finally { $script:capTweak=$null }
                Commit-TweakState $tw.Id
                Write-AXELog "APLICADO : $($tw.Name)"
            } else {
                if((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id)){ Write-AXELog "REVERTIDO (estado previo): $($tw.Name)" } else { & $tw.Revert; Write-AXELog "REVERTIDO: $($tw.Name)" }
            }
            $ok=[bool](& $tw.Test)
            if($ok -ne $item.Want){ Write-AXELog "  ! verificacion no coincide en $($tw.Name)" 'WARN' }
            $script:changed++; if($tw.Reboot){ $script:reboot=$true }
        } catch { Write-AXELog "ERROR    : $($tw.Name) -> $($_.Exception.Message)" 'ERR' }
        $script:applyDone++; $ApplyBar.Value=[int](($script:applyDone/$script:applyTotal)*100)
    })
    $script:applyTimer.Start()
})

# Punto de restauracion en runspace (no congela) - portado a WPF.
# Extraido a scriptblock para reutilizarlo desde el gate de APLICAR (H2).
$script:doRestorePoint = {
    if($script:rsPS){ return }
    $BtnRestore.IsEnabled=$false; Write-AXELog 'Creando punto de restauracion en segundo plano...'
    $ps=[PowerShell]::Create()
    [void]$ps.AddScript($script:RestorePointScript.ToString())   # fuente unica en 34-safety.ps1
    [void]$ps.AddArgument("AXE $($script:AXEVersion)")
    $script:rsPS=$ps; $script:rsHandle=$ps.BeginInvoke()
    $t=New-Object System.Windows.Threading.DispatcherTimer; $t.Interval=[TimeSpan]::FromSeconds(1); $script:rsTimer=$t
    $t.Add_Tick({
        if($script:rsHandle.IsCompleted){
            $script:rsTimer.Stop()
            $res=$script:rsPS.EndInvoke($script:rsHandle)
            $script:rsPS.Dispose(); $script:rsPS=$null; $script:rsHandle=$null
            foreach($line in $res){ Write-AXELog "$line" $(if($line -match '^ERROR'){'ERR'}else{'INFO'}) }
            $BtnRestore.IsEnabled=$true
        }
    })
    $t.Start()
}
$BtnRestore.Add_Click($script:doRestorePoint)

# ---- 12.15 init ----
$n = Repair-StartupBackup
if($n -gt 0){ Write-AXELog "Startup backup migrado a formato v5: $n entrada(s)." }
Write-AXELog "AXE $($script:AXEVersion) lista. Tweaks: $($script:CAT.Count)."
Write-AXELog 'Recomendado: crea PRIMERO el punto de restauracion.'
# A4: HW async -> chips + gating + Refresh-States al completar (la ventana ya esta visible)
Start-AXEHardwareLoad

$firstCat = $script:tweakCats | Select-Object -First 1
if($firstCat){ $script:navBtns[$firstCat].IsChecked=$true }



# >>>>> MODULE: 60-gui-selftest.ps1 >>>>>
# ---- 12.16 GUITEST: assert + render PNG, sin ShowDialog ----
if($env:AXE_GUITEST -eq '1'){
    Write-Host "== AXE $($script:AXEVersion) WPF - LAYOUT TEST =="
    Write-Host "NAV items         : $($script:navBtns.Count)"
    Write-Host "Vistas tweaks     : $(($script:tweakCats).Count)"
    $allOk=$true

    # Invoke-AXEDoEvents ya NO se define aqui: vive en 52-gui-build.ps1 con el resto de helpers
    # de GUI. Definirla aqui la hacia existir solo durante el harness, asi que un handler que la
    # usara pasaba el gate y fallaba en el primer clic real.

    # regresion A4+A1: init lanza Get-AXEHardware en runspace (la ventana NO espera ~3.7s de
    # CIM). Al llegar HW: chips + gating + Refresh-States async. Todo drena al bombear el
    # dispatcher. Prueba el fix de "tarda mucho en iniciar" end-to-end.
    try {
        $hwAsync=[bool]$script:hwPS
        $dl=(Get-Date).AddSeconds(40); while(($script:hwPS -or $script:refreshing) -and (Get-Date) -lt $dl){ Invoke-AXEDoEvents }
        $hwDone=($null -ne $script:HW)
        $chipsOk=($HwChips.Children.Count -gt 0)
        $refDone=-not $script:refreshing
        $countOk=($CountLbl.Text -match '^\d+/\d+$')
        Write-Host "HW async          : lanzada=$hwAsync HW=$hwDone chips=$chipsOk (esperado True x3)"
        Write-Host "Refresh async     : completo=$refDone count='$($CountLbl.Text)' (esperado True)"
        if(-not ($hwAsync -and $hwDone -and $chipsOk -and $refDone -and $countOk)){ $allOk=$false }
    } catch { Write-Host "HW/Refresh async  : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # regresion A2: Start-AXEJob corre en runspace de fondo y devuelve log (UI no congela)
    try {
        Start-AXEJob -Work { param($x) "JOBTEST $x" } -JobArgs @('OK') -Button $null
        $jobStarted=[bool]$script:jobPS
        $dl=(Get-Date).AddSeconds(10); while($script:jobPS -and (Get-Date) -lt $dl){ Invoke-AXEDoEvents }
        $jobDone = -not $script:jobPS
        Write-Host "Background job    : arranco=$jobStarted termino=$jobDone (esperado True/True)"
        if(-not ($jobStarted -and $jobDone)){ $allOk=$false }
    } catch { Write-Host "Background job    : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # regresion H10: mutex unico. Con $script:busy=$true, Start-AXEJob DEBE rechazar
    # (no arranca runspace) para no mutar el sistema mientras corre APLICAR/MASTER.
    try {
        $script:busy=$true
        Start-AXEJob -Work { 'NO_DEBE_CORRER' } -Button $null
        $refused=(-not $script:jobPS)
        $script:busy=$false
        Write-Host "Job mutex (H10)   : rechazado con busy=$refused (esperado True)"
        if(-not $refused){ $allOk=$false }
    } catch { $script:busy=$false; Write-Host "Job mutex (H10)   : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # regresion A3: Master revert (cola tail extraida). Solo verifica ESTRUCTURA:
    # la funcion tail definida. NO se ejecuta (revertiria los tweaks reales del sistema).
    $mrOk = [bool](Get-Command Invoke-AXEMasterRevertTail -EA SilentlyContinue)
    Write-Host "Master revert     : tail definido=$mrOk (esperado True)"
    if(-not $mrOk){ $allOk=$false }

    # regresion H2: gate de punto de restauracion. Verifica que el query es no-mutante
    # y devuelve bool sin lanzar, y que el scriptblock reutilizable existe.
    $rpFnOk=[bool](Get-Command Test-RecentRestorePoint -EA SilentlyContinue)
    $rpBool=$false; try { $rpBool=((Test-RecentRestorePoint) -is [bool]) } catch {}
    $rpSbOk=($script:doRestorePoint -is [scriptblock])
    Write-Host "RestorePoint gate : fn=$rpFnOk retornaBool=$rpBool scriptblock=$rpSbOk (esperado True x3)"
    if(-not ($rpFnOk -and $rpBool -and $rpSbOk)){ $allOk=$false }

    foreach($catName in $script:tweakCats){
        $rowCount=$script:rows[$catName].Count
        if($rowCount -eq 0){ Write-Host "  FAIL: $catName vacio"; $allOk=$false } else { Write-Host ("  OK: {0,-12} {1} cards" -f $catName,$rowCount) }
    }
    Switch-View 'CPU'
    $vis=@($script:views.Values | Where-Object { $_.Visibility -eq 'Visible' }).Count
    Write-Host "Switch CPU        : vistas visibles=$vis (esperado 1)"
    if($vis -ne 1){ $allOk=$false }
    # forzar construccion de vistas de accion
    foreach($catName in $script:actionCats){ Build-ActionView $catName | Out-Null }
    Write-Host "Vistas accion     : construidas"
    # regresion PERFILES: la vista cablea el toggle de monitor + refresh de lista, y
    # Tick-GameProfiles no lanza sin juego corriendo (debe devolver el perfil activo o null).
    try {
        $pvOk = ($null -ne $script:profMonTog) -and ($script:profRefreshList -is [scriptblock])
        $tickNull = $null; try { $tickNull = Tick-GameProfiles } catch { $pvOk=$false }
        Write-Host "Perfiles view     : toggle+refresh=$pvOk tickActivo='$tickNull' (esperado True/vacio)"
        if(-not $pvOk){ $allOk=$false }
        if($null -ne $tickNull){ $allOk=$false }   # sin juego corriendo no debe activar nada
    } catch { Write-Host "Perfiles view     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion GPU POR JUEGO (region 10c): la misma vista PERFILES cablea el refresh de la
    # lista de ejecutables. Se EJERCE el scriptblock, no solo se comprueba que exista: construir
    # las tarjetas es donde se lee el registro y se parsea la cadena "K=V;", que es lo que se
    # puede romper. Ojo con confiar en el PNG para esto: el render sale en blanco (el bitmap se
    # toma sin pasar por ShowDialog), asi que la unica prueba real de que la seccion se construye
    # es el Build-ActionView de arriba mas este ejercicio. Solo LEE el registro.
    try {
        $gvOk = ($script:gpuRefreshList -is [scriptblock])
        if($gvOk){ & $script:gpuRefreshList }   # si el parser o la lectura del registro revientan, cae al catch
        $hyb = Test-AXEHybridGpu
        Write-Host "GPU-juego view    : refresh=$gvOk hibrida=$hyb gpus=$((Get-AXEGpuList).Count)"
        if(-not $gvOk){ $allOk=$false }
        if($hyb -isnot [bool]){ $allOk=$false }
    } catch { Write-Host "GPU-juego view    : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion PESTANA FPS: existe como vista propia (no enterrada en PERFILES) y trae el
    # cuadro de medicion cableado. Se comprueba la vista Y el control, porque registrar la
    # categoria sin construir nada daria una pestana vacia que igual pasaba el resto de checks.
    try {
        $fpsTabOk = ($script:actionCats -contains 'FPS') -and ($null -ne $script:views['FPS'])
        $fpsUiOk  = ($null -ne $script:fpsOut)
        # Las funciones de la region 10d tienen que estar cargadas antes que la GUI (33 < 55).
        $fpsFnOk  = [bool](Get-Command Measure-AXEFps -EA SilentlyContinue) -and [bool](Get-Command Get-AXEFpsVerdict -EA SilentlyContinue)
        Write-Host "Pestana FPS       : vista=$fpsTabOk salida=$fpsUiOk funciones=$fpsFnOk (esperado True/True/True)"
        if(-not ($fpsTabOk -and $fpsUiOk -and $fpsFnOk)){ $allOk=$false }
    } catch { Write-Host "Pestana FPS       : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion ICONO+SUBTITULO por categoria. Anadir una pestana son TRES sitios: actionCats
    # (52-gui-build), el glyph de $script:glyphs y la rama del subtitulo en Switch-View
    # (57-gui-handlers). FPS se anadio con el primero y sin los otros dos: la pestana salia
    # funcionando pero sin icono en la barra lateral y sin subtitulo en la cabecera, y el gate
    # daba LAYOUT OK igual. Este check cubre la clase entera, no el caso de FPS.
    try {
        $sinIcono = @($script:actionCats | Where-Object { -not $script:glyphs.ContainsKey($_) })
        $sinSub   = @(foreach($c in $script:actionCats){ Switch-View $c; if([string]::IsNullOrWhiteSpace($ContentSub.Text)){ $c } })
        Write-Host "Iconos/subtitulos : sin icono=$($sinIcono.Count) sin subtitulo=$($sinSub.Count) (esperado 0/0)"
        if($sinIcono.Count -gt 0){ Write-Host "  FAIL: categorias sin glyph -> $($sinIcono -join ', ')"; $allOk=$false }
        if($sinSub.Count   -gt 0){ Write-Host "  FAIL: categorias sin subtitulo -> $($sinSub -join ', ')"; $allOk=$false }
        # Glyph REPETIDO entre categorias. REGISTRO llevaba el mismo codepoint que APPS (E71D):
        # dos secciones con el dibujo identico en la barra lateral, que es donde se elige sin
        # leer. Ningun check lo veia porque cada una tenia SU entrada; el fallo era que las dos
        # apuntaban al mismo sitio. Esto NO cubre parecidos visuales entre codepoints distintos
        # (SISTEMA y FPS dibujaban los dos un portatil con codepoints distintos): eso solo se
        # caza mirando la fuente renderizada, y por eso los glyphs se eligen viendolos.
        $dup = @($script:glyphs.GetEnumerator() | Group-Object Value | Where-Object Count -gt 1)
        if($dup.Count -gt 0){
            foreach($d in $dup){ Write-Host ("  FAIL: glyph 0x{0:X4} repetido en -> {1}" -f [int][char]$d.Name,(($d.Group.Name) -join ', ')) }
            $allOk=$false
        }
    } catch { Write-Host "Iconos/subtitulos : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion: ejercer handler ASISTENTE (bug de scope $out/$doAsk null)
    try {
        $before=$script:aiOut.Text.Length
        $script:aiIn.Text='fps'
        & $script:aiDoAsk
        $grew=$script:aiOut.Text.Length -gt $before
        Write-Host "Asistente handler : output crecio=$grew (esperado True)"
        if(-not $grew){ $allOk=$false }
    } catch { Write-Host "Asistente handler : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion MEDICION: la vista construye score label + boton + reporte, y el helper existe
    try {
        Build-ActionView 'MEDICION' | Out-Null
        $measOk = ($null -ne $script:scoreLbl) -and ($null -ne $script:measureBtn) -and ($null -ne $script:measureOut) -and ([bool](Get-Command Invoke-AXEMeasure -EA SilentlyContinue))
        Write-Host "Medicion view     : score+boton+reporte+helper=$measOk (esperado True)"
        if(-not $measOk){ $allOk=$false }
        # regresion H10-medicion: Invoke-AXEMeasure debe COGER el mutex, no solo leerlo. Era la
        # unica operacion de fondo que comprobaba $script:busy sin ponerlo nunca, asi que durante
        # el muestreo APLICAR/MASTER/Start-AXEJob podian arrancar y mutar el registro en mitad del
        # snapshot, contaminando el "antes" del delta antes/despues.
        #   El test de mutex de mas arriba NO cubria esto: prueba Start-AXEJob, que si lo cogia.
        # Se mide con 1ms de jitter (el minimo util) para no alargar el gate.
        try {
            Invoke-AXEMeasure -JitterMs 1
            $tookMutex = $script:busy
            # Drena hasta que el tick complete y suelte el mutex. Tope por si nunca completa:
            # sin el, un fallo de liberacion colgaria el gate en vez de reportarlo.
            $spins=0
            while($script:busy -and $spins -lt 200){ Invoke-AXEDoEvents; Start-Sleep -Milliseconds 20; $spins++ }
            $released = -not $script:busy
            Write-Host "Medicion mutex    : coge=$tookMutex libera=$released (esperado True/True)"
            if(-not $tookMutex -or -not $released){ $allOk=$false; $script:busy=$false }
        } catch {
            Write-Host "Medicion mutex    : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false; $script:busy=$false
        }
        # regresion §3.5: el barrido de timer vive en la GUI, no solo en el CLI. Se comprueba
        # boton + handler + formateador compartido. El barrido NO se ejecuta aqui: tarda ~30s
        # y sube la prioridad del proceso, que no es aceptable dentro de un selftest.
        $swOk = ($null -ne $script:sweepBtn) -and
                ([bool](Get-Command Invoke-AXETimerSweepJob -EA SilentlyContinue)) -and
                ([bool](Get-Command Format-AXETimerSweep -EA SilentlyContinue))
        Write-Host "Barrido timer view: boton+handler+formateador=$swOk (esperado True)"
        if(-not $swOk){ $allOk=$false }
        # Format-AXETimerSweep con $null (barrido sin datos utiles) debe degradar a un mensaje,
        # no reventar: es el camino real cuando el kernel rechaza todos los requests.
        try {
            $fmtNull = @(Format-AXETimerSweep $null)
            $fmtOk = ($fmtNull.Count -ge 1) -and -not [string]::IsNullOrWhiteSpace($fmtNull[0])
        } catch { $fmtOk=$false }
        Write-Host "Barrido fmt null  : degrada sin excepcion=$fmtOk (esperado True)"
        if(-not $fmtOk){ $allOk=$false }
    } catch { Write-Host "Medicion view     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion REGISTRO: la vista se construye y el extractor de rutas cubre el catalogo.
    # NO se llama a Open-AXERegedit: lanzaria regedit.exe de verdad en medio del selftest.
    try {
        Build-ActionView 'REGISTRO' | Out-Null
        $regViewOk = ($null -ne $script:regOut) -and ($null -ne $script:regBtn) -and
                     ([bool](Get-Command Get-AXERegDiagnostic -EA SilentlyContinue)) -and
                     ([bool](Get-Command Open-AXERegedit -EA SilentlyContinue))
        Write-Host "Registro view     : salida+boton+helpers=$regViewOk (esperado True)"
        if(-not $regViewOk){ $allOk=$false }
        # El extractor debe encontrar clave en la MAYORIA del catalogo. Si un refactor rompe el
        # regex, esto cae a ~0 y los atajos "regedit" desaparecen de las tarjetas en silencio.
        $nPaths=0; foreach($tw in @($script:CAT)){ if((@(Get-AXERegPathsForTweak $tw)).Count){ $nPaths++ } }
        $pathOk = ($nPaths -ge 40)
        Write-Host "Registro rutas    : $nPaths/$(@($script:CAT).Count) tweaks con clave (esperado >=40)"
        if(-not $pathOk){ $allOk=$false }
        # Conversion al formato de LastKey, incluido el rechazo de basura.
        $convOk = ((ConvertTo-AXERegeditPath 'HKLM:\SYSTEM\Foo') -match '\\HKEY_LOCAL_MACHINE\\SYSTEM\\Foo$') -and
                  ($null -eq (ConvertTo-AXERegeditPath 'no-es-una-ruta'))
        Write-Host "Registro convpath : hive+rechazo basura=$convOk (esperado True)"
        if(-not $convOk){ $allOk=$false }
        # PULSAR el boton de verdad, no solo comprobar que existe. Construir la vista NO ejecuta
        # el cuerpo del handler, asi que un comando inexistente ahi dentro pasaba el gate y
        # reventaba en el primer clic del usuario (caso real: Invoke-AXEDoEvents, que solo
        # existe dentro de este selftest). Cuesta ~2s y cubre el camino entero.
        try {
            $script:regBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            $clickOk = ($script:regOut.Text -match 'claves distintas') -and (-not $script:busy) -and $script:regBtn.IsEnabled
            Write-Host "Registro clic     : handler completo + mutex liberado=$clickOk (esperado True)"
            if(-not $clickOk){ $allOk=$false; Write-Host "  salida: $($script:regOut.Text -split "`r?`n" | Select-Object -First 1)" }
        } catch {
            Write-Host "Registro clic     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false
        }
    } catch { Write-Host "Registro view     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion: badge recomendado curado (no todo Tier<2)
    $recCount=0
    foreach($catName in $script:tweakCats){ foreach($e in $script:rows[$catName]){ if($script:RECOMMENDED -contains $e.Tw.Id){ $recCount++ } } }
    Write-Host "Badges recomendado: $recCount catalogo / $($script:RECOMMENDED.Count) curados"
    # regresion: diff de cambios pendientes (APLICAR muestra contador)
    $row0=$null; foreach($catName in $script:tweakCats){ foreach($e in $script:rows[$catName]){ if(-not $e.Blocked){ $row0=$e; break } }; if($row0){break} }
    if($row0){
        $row0.Base=[bool]$row0.Toggle.IsChecked
        $row0.Toggle.IsChecked = -not [bool]$row0.Base
        Update-AXEPending
        $pendOk = ($BtnApply.Content -match '^APLICAR \(\d')
        Write-Host "Pending diff      : BtnApply='$($BtnApply.Content)' dirty=$pendOk (esperado True)"
        if(-not $pendOk){ $allOk=$false }
        $row0.Toggle.IsChecked=$row0.Base; Update-AXEPending
    }
    # regresion: log sink colorea por severidad (RichTextBox blocks)
    try {
        Write-AXELog 'regresion ERR' 'ERR'
        $sinkOk=($script:LogBox.Document.Blocks.Count -gt 0)
        Write-Host "Log sink          : blocks=$($script:LogBox.Document.Blocks.Count) ok=$sinkOk (esperado True)"
        if(-not $sinkOk){ $allOk=$false }
    } catch { Write-Host "Log sink          : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion logo AXE: 6 paths en el Canvas del header (2 Accent + 4 Surface),
    # sin path en negro-sobre-oscuro (invisible). El ActualWidth se mide despues del
    # layout forzado del bloque de render (mas abajo).
    try {
        $paths=@($LogoCanvas.Children)
        # Derivado de los recursos, no hardcodeado: la regresion que importa es "el logo usa
        # los colores de la paleta", no "el logo es teal". Retocar la paleta ya no rompe esto,
        # pero olvidarse de repintar el logo si.
        $accentHex =(New-AXEBrush 'Accent').Color.ToString()
        $surfaceHex=(New-AXEBrush 'Surface').Color.ToString()
        $accent=$paths | Where-Object { $_.Fill -is [System.Windows.Media.SolidColorBrush] -and $_.Fill.Color.ToString() -eq $accentHex }
        $surface=$paths | Where-Object { $_.Fill -is [System.Windows.Media.SolidColorBrush] -and $_.Fill.Color.ToString() -eq $surfaceHex }
        $logoOk=($paths.Count -eq 6) -and ($accent.Count -eq 2) -and ($surface.Count -eq 4)
        Write-Host ("Logo AXE          : paths={0} accent={1} surface={2} (esperado 6/2/4)" -f $paths.Count,$accent.Count,$surface.Count)
        if(-not $logoOk){ $allOk=$false }
    } catch { Write-Host "Logo AXE          : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # regresion 3.3: el header muestra el banner de ecosistema, y es EL MISMO texto que
    # imprime la CLI (-List "ECO:"). Si alguien duplica la logica en la GUI, esto lo caza.
    try {
        $bannerTxt = $EnvBannerLbl.Text
        $bannerOk  = $bannerTxt -and ($bannerTxt -eq (Get-AXEEnvBanner)) -and ($bannerTxt -match 'aplicables')
        Write-Host ("Banner ecosistema : '{0}' coincide con CLI={1} (esperado True)" -f $bannerTxt,$bannerOk)
        if(-not $bannerOk){ $allOk=$false }
    } catch { Write-Host "Banner ecosistema : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # render PNG
    try {
        $W=1200;$H=840
        $win.Width=$W; $win.Height=$H
        $win.Measure([System.Windows.Size]::new($W,$H))
        $win.Arrange([System.Windows.Rect]::new(0,0,$W,$H))
        $win.UpdateLayout()
        # logo: el Viewbox escala el Canvas proporcionalmente al Height=34. En modo headless
        # ActualWidth puede quedar en 0 (sin HWND el layout no drena); en runtime con ShowDialog
        # si. Solo informativo aqui - la verificacion estructural (6/2/4) ya cubre la regresion.
        $logoW=[int]$LogoBox.ActualWidth
        Write-Host ("Logo AXE box      : w={0} (info; >0 en runtime con ShowDialog)" -f $logoW)
        $rtb=New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W,$H,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($win.Content)
        $enc=New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $pngPath=Join-Path $env:AXE_GUITEST_PNG_DIR 'axe_render.png'
        $fs=[System.IO.File]::Create($pngPath); $enc.Save($fs); $fs.Close()
        Write-Host "Render PNG        : $pngPath"
    } catch {
        # El volcado del PNG es un ARTEFACTO, no una asercion: que no se pueda escribir no dice
        # nada sobre si la GUI esta bien, asi que no tumba el gate (y esta bien que no lo haga).
        # Pero antes imprimia "FALLO" igualmente y el harness remataba con "LAYOUT OK": un fallo
        # que no era fallo, ruido que entrena a ignorar la palabra FALLO en la salida.
        #   Sin AXE_GUITEST_PNG_DIR (ejecucion manual del harness) ni siquiera es un problema: es
        # que no se pidio el volcado. build.ps1 si define la variable.
        if([string]::IsNullOrWhiteSpace($env:AXE_GUITEST_PNG_DIR)){
            Write-Host "Render PNG        : omitido (AXE_GUITEST_PNG_DIR no definida; no es un fallo)"
        } else {
            Write-Host "Render PNG        : no se pudo escribir -> $($_.Exception.Message)  (artefacto, no tumba el gate)"
        }
    }
    if($allOk){ Write-Host "RESULTADO: LAYOUT OK"; exit 0 } else { Write-Host "RESULTADO: LAYOUT FALLO"; exit 1 }
}

if($env:AXE_GUISHOW -eq '1'){
    $win.Add_ContentRendered({
        try {
            $rtb=New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$win.ActualWidth,[int]$win.ActualHeight,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($win)
            $enc=New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $p=Join-Path $env:AXE_GUITEST_PNG_DIR 'axe_shown.png'
            $fs=[System.IO.File]::Create($p); $enc.Save($fs); $fs.Close(); Write-Host "SHOWN PNG: $p"
        } catch { Write-Host "SHOW render fallo: $($_.Exception.Message)" }
        $win.Dispatcher.InvokeAsync([action]{ $win.Close() },[System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    })
}
# H4: al cerrar, drena runspaces + timers vivos (evita fuga de handles/hilos si el
# usuario cierra con una tarea de fondo en curso). Stop antes de Dispose por si el
# PowerShell sigue ejecutando (Checkpoint-Computer, HW load, tarea de limpieza).


# >>>>> MODULE: 99-main.ps1 >>>>>
$win.Add_Closed({
    foreach($t in @($script:hwTimer,$script:jobTimer,$script:rsTimer,$script:applyTimer,$script:mrTimer,$script:profTimer,$script:sbTimer,$script:measureTimer,$script:refTimer)){
        if($t){ try { $t.Stop() } catch {} }
    }
    foreach($psRef in @($script:hwPS,$script:jobPS,$script:rsPS,$script:measurePS)){
        if($psRef){ try { $psRef.Stop() } catch {}; try { $psRef.Dispose() } catch {} }
    }
    $script:hwPS=$null; $script:jobPS=$null; $script:rsPS=$null; $script:measurePS=$null
})
[void]$win.ShowDialog()


