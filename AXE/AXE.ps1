#Requires -Version 5.1
# =====================================================
# AXE v5 - Elite Windows Optimizer (single source of truth)
#
# Motor UNICO consolidado. Corrige todos los hallazgos del audit:
#   C1  Backup/restore de startup robusto + Restore-Autorun
#   A1  Invoke-AXEMasterRevert limpia residuos v1 (SmartScreen/NoConnectedUser/hypervisor)
#   A2  Un valor canonico por tweak; fuentes unificadas
#   M1  Reverts que no revertian -> eliminados o documentados como unidireccionales
#   M4  Punto de restauracion en runspace (GUI no se congela)
#   M5  Guard anti-catalogo-roto + modo -SelfTest (validacion headless)
#
# Modos de ejecucion (headless, sin GUI ni admin):
#   -SelfTest     Validacion de integridad del catalogo y helpers (0 fallos)
#   -List         Estado real de cada tweak contra el sistema
#   -Export/-Import <file>  Perfil JSON
#   (sin args)    GUI (requiere admin via el launcher .bat)
# =====================================================

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$List,
    [string]$Export,
    [string]$Import
)

# =====================================================
# REGION 1 - PATHS & LOGGING  (headless, sin UI)
# =====================================================
$script:AXERoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AXEData   = Join-Path $script:AXERoot 'AXE'
$script:AXEBackup = Join-Path $script:AXEData 'Backups'
$script:AXELog    = Join-Path $script:AXEData ("axe_log_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$script:RunBak   = Join-Path $script:AXEData 'startup_disabled.json'
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
    [pscustomobject]@{
        CpuName=$cpu.Name; Cores=$cpu.NumberOfCores; Threads=$cpu.NumberOfLogicalProcessors
        IsLaptop=$isLaptop; IsHybrid=$isHybrid; HasNvidia=$hasNvidia
        IsWifi=[bool]$isWifi; NicName=$activeNic.Name; Edition=$edition
        IsHome=($edition -match 'Home'); OnBattery=$onBattery
        IsWin11=$isWin11; BuildNumber=$build
        RamGB=[math]::Round($os.TotalVisibleMemorySize/1MB,1)
    }
}

# =====================================================
# REGION 3 - HELPERS (registro / servicio / backup)
# =====================================================
function Get-RV($p,$n){ try { (Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n } catch { $null } }
function Set-RD($p,$n,$v){ if(-not(Test-Path $p)){ New-Item -Path $p -Force | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType DWord -Force | Out-Null }
function Set-RS($p,$n,$v){ if(-not(Test-Path $p)){ New-Item -Path $p -Force | Out-Null }; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType String -Force | Out-Null }
function Del-RV($p,$n){ Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue }
function Test-Svc($n){ [bool](Get-Service $n -ErrorAction SilentlyContinue) }
function Get-SvcStart($n){ try { (Get-Service $n -ErrorAction Stop).StartType } catch { $null } }
function Set-SvcStart($n,$m){
    if(-not(Test-Svc $n)){ Write-AXELog "Servicio '$n' no existe en este SKU, omitido" 'WARN'; return }
    & sc.exe config $n start= $m | Out-Null
    if($LASTEXITCODE -ne 0){ throw "sc config $n start=$m fallo (code $LASTEXITCODE)" }
}
function Backup-RegKey($hive,$file){
    $dest = Join-Path $script:AXEBackup $file
    if(Test-Path $dest){ return }   # NO destructivo: solo la primera vez
    & reg.exe export $hive $dest /y *>$null
    if($LASTEXITCODE -eq 0){ Write-AXELog "Backup: $file" }
}

# ---- CACHEO DE TESTS ----
# Varios Test lentos repiten la MISMA consulta externa dentro de una sola pasada de
# Refresh (bcdedit, Get-NetTCPSetting, Get-ProcessMitigation). Get-AXECache memoiza por
# pasada: $script:tCache se vacia al arrancar cada Refresh-States (y tras Apply/Revert,
# que disparan Refresh), asi el valor NUNCA queda obsoleto respecto al estado real.
$script:tCache = @{}
function Get-AXECache {
    param([string]$Key,[scriptblock]$Producer)
    if($null -eq $script:tCache){ $script:tCache=@{} }
    if($script:tCache.ContainsKey($Key)){ return $script:tCache[$Key] }
    $v = & $Producer
    $script:tCache[$Key] = $v
    return $v
}
# Topologia HW (lista de dispositivos PnP) es inmutable en la sesion => cache permanente.
# El bit mutable (registro MSISupported/DevicePriority) se sigue leyendo fresco por Get-RV
# en cada Test; aqui solo cacheamos la ENUMERACION cara de CIM.
$script:hwTopoCache = @{}
function Get-AXEHwCache {
    param([string]$Key,[scriptblock]$Producer)
    if($null -eq $script:hwTopoCache){ $script:hwTopoCache=@{} }
    if($script:hwTopoCache.ContainsKey($Key)){ return $script:hwTopoCache[$Key] }
    $v = & $Producer
    $script:hwTopoCache[$Key] = $v
    return $v
}

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
    } catch {}
    if($clean.Count -eq 0){ return 0 }
    $clean.ToArray() | ConvertTo-Json -Depth 5 | Set-Content $script:RunBak -Encoding UTF8
    return $clean.Count
}

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
Add-Tweak @{Id='cpu_prio';Cat='CPU';Tier=1;Reboot=$false;Name='Prioridad ventana activa';Desc="Win32PrioritySeparation=$W32PS : el juego en foco manda";Requires=@{};
 Test={(Get-RV $PC 'Win32PrioritySeparation') -eq $W32PS};
 Apply={Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl' 'PriorityControl.reg'; Set-RD $PC 'Win32PrioritySeparation' $W32PS};
 Revert={Set-RD $PC 'Win32PrioritySeparation' 2}}
Add-Tweak @{Id='cpu_mmcss';Cat='CPU';Tier=1;Reboot=$false;Name='Liberar CPU multimedia';Desc='SystemResponsiveness=0';Requires=@{};
 Test={(Get-RV $SP 'SystemResponsiveness') -eq 0};Apply={Set-RD $SP 'SystemResponsiveness' 0};Revert={Set-RD $SP 'SystemResponsiveness' 20}}
Add-Tweak @{Id='cpu_pthr';Cat='CPU';Tier=1;Reboot=$false;Name='Power Throttling OFF';Desc='Sin limite de frecuencia';Requires=@{AC=$true};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff') -eq 1};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1};Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'}}
Add-Tweak @{Id='cpu_park';Cat='CPU';Tier=1;Reboot=$false;Name='Core Parking OFF';Desc='Nucleos siempre activos';Requires=@{Desktop=$true;NotHybrid=$true};
 Test={ $g=((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActivePowerScheme') -replace '[{}]',''); (Get-RV "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$g\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583" 'ACSettingIndex') -eq 100 };
 Apply={powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100; powercfg -setactive scheme_current};
 Revert={powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 0; powercfg -setactive scheme_current}}
Add-Tweak @{Id='cpu_fth';Cat='CPU';Tier=1;Reboot=$false;Name='FTH OFF (micro-tirones)';Desc='Desactiva Fault Tolerant Heap';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 0};Revert={Set-RD 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 1}}
Add-Tweak @{Id='cpu_dyntick';Cat='CPU';Tier=1;Reboot=$true;Name='Dynamic Tick OFF';Desc='Timer constante, menos jitter (REINICIO)';Requires=@{};
 Test={ ((Get-AXECache 'bcd' { bcdedit /enum '{current}' | Out-String }) -match 'disabledynamictick\s+Yes') };Apply={bcdedit /set disabledynamictick yes | Out-Null};Revert={bcdedit /deletevalue disabledynamictick | Out-Null}}
Add-Tweak @{Id='cpu_tsc';Cat='CPU';Tier=1;Reboot=$true;Name='TSC Sync Enhanced';Desc='Sincroniza contador de tiempo entre nucleos (REINICIO)';Requires=@{};
 Test={ ((Get-AXECache 'bcd' { bcdedit /enum '{current}' | Out-String }) -match 'tscsyncpolicy\s+Enhanced') };Apply={bcdedit /set tscsyncpolicy Enhanced | Out-Null};Revert={bcdedit /deletevalue tscsyncpolicy | Out-Null}}

# --- LATENCIA / INPUT LAG (Tier 1) ---
Add-Tweak @{Id='lat_msi_audio';Cat='LATENCIA';Tier=1;Reboot=$true;Name='MSI mode en HD Audio';Desc='Baja DPC latency del audio';Requires=@{};
 Test={ $hd=Get-AXEHwCache 'pnp:hda' { Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%High Definition Audio%'" -EA SilentlyContinue | Where-Object PNPDeviceID -like 'PCI*' }; if(-not $hd){return $true}; $ok=$true; foreach($d in $hd){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"; if((Get-RV $p 'MSISupported') -ne 1){$ok=$false} }; $ok };
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
 Test={ $g=Get-AXEHwCache 'pnp:disp' { Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' } }; if(-not $g){return $true}; $ok=$true; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; if((Get-RV $p 'DevicePriority') -ne 3){$ok=$false} }; $ok };
 Apply={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; Set-RD $p 'DevicePriority' 3 } };
 Revert={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; Del-RV $p 'DevicePriority' } }}

# --- GPU (Tier 1) ---
Add-Tweak @{Id='gpu_hags';Cat='GPU';Tier=1;Reboot=$true;Name='HAGS (scheduling por hardware)';Desc='GPU gestiona su cola, menos latencia (REINICIO)';Requires=@{};
 Test={(Get-RV $GD 'HwSchMode') -eq 2};Apply={Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'GraphicsDrivers.reg'; Set-RD $GD 'HwSchMode' 2};Revert={Del-RV $GD 'HwSchMode'}}
Add-Tweak @{Id='gpu_mmcss';Cat='GPU';Tier=1;Reboot=$false;Name='Prioridad MMCSS juegos';Desc='GPU Priority 8 / Priority 6 / High';Requires=@{};
 Test={((Get-RV $Games 'GPU Priority') -eq 8) -and ((Get-RV $Games 'Priority') -eq 6) -and ((Get-RV $Games 'Scheduling Category') -eq 'High')};
 Apply={Set-RD $Games 'GPU Priority' 8;Set-RD $Games 'Priority' 6;Set-RS $Games 'Scheduling Category' 'High';Set-RS $Games 'SFIO Priority' 'High';Set-RS $Games 'Background Only' 'False'};
 Revert={Set-RD $Games 'GPU Priority' 8;Set-RD $Games 'Priority' 2;Del-RV $Games 'Scheduling Category';Del-RV $Games 'SFIO Priority';Del-RV $Games 'Background Only'}}
Add-Tweak @{Id='gpu_ulps';Cat='GPU';Tier=1;Reboot=$true;Name='NVIDIA ULPS OFF';Desc='GPU no entra en bajo consumo profundo (REINICIO)';Requires=@{Nvidia=$true};
 Test={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; $sub=Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' }; if(-not $sub){return $true}; $ok=$true; foreach($s in $sub){ if((Get-RV $s.PSPath 'EnableUlps') -ne 0){$ok=$false} }; $ok };
 Apply={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' } | ForEach-Object { Set-RD $_.PSPath 'EnableUlps' 0 } };
 Revert={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' } | ForEach-Object { Del-RV $_.PSPath 'EnableUlps' } }}
Add-Tweak @{Id='gpu_tdr';Cat='GPU';Tier=1;Reboot=$true;Name='TDR delay ampliado';Desc='Menos cuelgues de driver bajo carga (REINICIO)';Requires=@{};
 Test={(Get-RV $GD 'TdrDelay') -eq 10};Apply={Set-RD $GD 'TdrDelay' 10};Revert={Del-RV $GD 'TdrDelay'}}
Add-Tweak @{Id='gpu_vrr';Cat='GPU';Tier=1;Reboot=$true;Name='Optimizaciones para juegos con ventana';Desc='VRR + optimizaciones de ventana (REINICIO)';Requires=@{};
 Test={(Get-RV $GD 'VRROptimizeEnable') -eq 1};Apply={Set-RD $GD 'VRROptimizeEnable' 1};Revert={Del-RV $GD 'VRROptimizeEnable'}}

# --- RED (Tier 1) ---
Add-Tweak @{Id='net_throttle';Cat='RED';Tier=1;Reboot=$false;Name='Network Throttling OFF';Desc='Sin limite de paquetes con multimedia';Requires=@{};
 Test={(Get-RV $SP 'NetworkThrottlingIndex') -eq 4294967295};Apply={Set-RD $SP 'NetworkThrottlingIndex' 4294967295};Revert={Del-RV $SP 'NetworkThrottlingIndex'}}
Add-Tweak @{Id='net_nagle';Cat='RED';Tier=1;Reboot=$false;Name='Nagle OFF (adaptador activo)';Desc='Menos delay en paquetes pequenos';Requires=@{};
 Test={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -EA SilentlyContinue; $any=$false; foreach($i in $ifs){ $p=Get-ItemProperty $i.PSPath -EA SilentlyContinue; if($p.DhcpIPAddress -or $p.IPAddress){ if((Get-RV $i.PSPath 'TcpAckFrequency') -eq 1 -and (Get-RV $i.PSPath 'TCPNoDelay') -eq 1){$any=$true} } }; $any };
 Apply={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'; foreach($i in $ifs){ $p=Get-ItemProperty $i.PSPath -EA SilentlyContinue; if($p.DhcpIPAddress -or $p.IPAddress){ Set-RD $i.PSPath 'TcpAckFrequency' 1; Set-RD $i.PSPath 'TCPNoDelay' 1 } } };
 Revert={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'; foreach($i in $ifs){ Del-RV $i.PSPath 'TcpAckFrequency'; Del-RV $i.PSPath 'TCPNoDelay' } }}
Add-Tweak @{Id='net_rss';Cat='RED';Tier=1;Reboot=$false;Name='RSS activado';Desc='Reparte trafico de red entre nucleos';Requires=@{};
 Test={try{(Get-NetOffloadGlobalSetting -EA Stop).ReceiveSideScaling -eq 'Enabled'}catch{$false}};Apply={netsh interface tcp set global rss=enabled | Out-Null};Revert={netsh interface tcp set global rss=default | Out-Null}}
Add-Tweak @{Id='net_ctcp';Cat='RED';Tier=1;Reboot=$false;Name='CTCP (congestion gaming)';Desc='Recupera antes tras perdida de paquetes';Requires=@{};
 Test={ $t=Get-AXECache 'nettcp' { try{Get-NetTCPSetting -SettingName Internet -EA Stop}catch{$null} }; if(-not $t){$false}else{$t.CongestionProvider -eq 'CTCP'} };Apply={netsh int tcp set supplemental template=internet congestionprovider=ctcp | Out-Null};Revert={netsh int tcp set supplemental template=internet congestionprovider=cubic | Out-Null}}
Add-Tweak @{Id='net_ecn';Cat='RED';Tier=1;Reboot=$false;Name='ECN OFF';Desc='Evita conflictos con routers viejos';Requires=@{};
 Test={ $t=Get-AXECache 'nettcp' { try{Get-NetTCPSetting -SettingName Internet -EA Stop}catch{$null} }; if(-not $t){$false}else{$t.EcnCapability -eq 'Disabled'} };Apply={netsh int tcp set global ecncapability=disabled | Out-Null};Revert={netsh int tcp set global ecncapability=default | Out-Null}}
Add-Tweak @{Id='net_qos';Cat='RED';Tier=1;Reboot=$true;Name='QoS sin reserva de banda';Desc='NonBestEffortLimit=0 (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit'}}
Add-Tweak @{Id='net_intmod';Cat='RED';Tier=1;Reboot=$false;Name='Interrupt Moderation NIC OFF';Desc='Menos buffering en el adaptador activo';Requires=@{};
 Test={ if(-not $script:HW.NicName){return $true}; try{ $v=(Get-NetAdapterAdvancedProperty -Name $script:HW.NicName -RegistryKeyword '*InterruptModeration' -EA Stop).RegistryValue; $v -eq 0 }catch{ $true } };
 Apply={ if($script:HW.NicName){ Set-NetAdapterAdvancedProperty -Name $script:HW.NicName -RegistryKeyword '*InterruptModeration' -RegistryValue 0 -EA SilentlyContinue } };
 Revert={ if($script:HW.NicName){ Set-NetAdapterAdvancedProperty -Name $script:HW.NicName -RegistryKeyword '*InterruptModeration' -RegistryValue 1 -EA SilentlyContinue } }}
Add-Tweak @{Id='net_dns';Cat='RED';Tier=1;Reboot=$false;Name='[OPT] DNS rapidos 1.1.1.1 / 8.8.8.8';Desc='OJO: rompe DNS local/VPN. No va en preset';Requires=@{};
 Test={ if(-not $script:HW.NicName){return $false}; try{(Get-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -AddressFamily IPv4 -EA Stop).ServerAddresses -contains '1.1.1.1'}catch{$false} };
 Apply={ if($script:HW.NicName){ Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ServerAddresses @('1.1.1.1','8.8.8.8') } };Revert={ if($script:HW.NicName){ Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ResetServerAddresses } }}

# --- MEMORIA (Tier 0/1) ---
Add-Tweak @{Id='mem_pagingexec';Cat='MEMORIA';Tier=1;Reboot=$true;Name='Kernel siempre en RAM';Desc='DisablePagingExecutive=1 (necesita RAM holgada) (REINICIO)';Requires=@{};
 Test={(Get-RV $MM 'DisablePagingExecutive') -eq 1};Apply={Set-RD $MM 'DisablePagingExecutive' 1};Revert={Set-RD $MM 'DisablePagingExecutive' 0}}
Add-Tweak @{Id='mem_ntfsmem';Cat='MEMORIA';Tier=1;Reboot=$true;Name='Cache de metadatos NTFS alta';Desc='NtfsMemoryUsage=2 (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage') -eq 2};Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage' 2};Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage'}}
Add-Tweak @{Id='mem_lastaccess';Cat='MEMORIA';Tier=0;Reboot=$false;Name='NTFS last-access OFF';Desc='Menos escrituras de metadatos al leer';Requires=@{};
 Test={ (& fsutil behavior query disablelastaccess) -match 'Disabled|= 1' };Apply={fsutil behavior set disablelastaccess 1 | Out-Null};Revert={fsutil behavior set disablelastaccess 0 | Out-Null}}

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
Add-Tweak @{Id='sys_do';Cat='SISTEMA';Tier=0;Reboot=$false;Name='Delivery Optimization P2P OFF';Desc='No compartes updates con otros PCs';Requires=@{};
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
Add-Tweak @{Id='rend_prefetch';Cat='RENDIMIENTO';Tier=1;Reboot=$true;Name='Prefetch/Superfetch OFF';Desc='Con SSD la precarga aporta poco (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher') -eq 0};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 0};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 3; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 3}}
Add-Tweak @{Id='rend_ultperf';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Plan energia Ultimate Performance';Desc='Evita downclock de CPU en idle. OJO: mas consumo/calor (mejor en sobremesa/enchufado)';Requires=@{};
 Test={$g=(Get-RV 'HKCU:\Software\AXE' 'UltPerfGuid'); if(-not $g){$false}else{[bool]((powercfg /getactivescheme) -match [regex]::Escape($g))}};
 Apply={$g=(Get-RV 'HKCU:\Software\AXE' 'UltPerfGuid'); if(-not $g){ $o=(powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>&1 | Out-String); $g=[regex]::Match($o,'[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value; if(-not $g){$g='e9a42b02-d5df-448d-aa00-03f14749eb61'}; Set-RS 'HKCU:\Software\AXE' 'UltPerfGuid' $g }; powercfg /setactive $g | Out-Null};
 Revert={$g=(Get-RV 'HKCU:\Software\AXE' 'UltPerfGuid'); powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e | Out-Null; if($g){ powercfg -delete $g 2>$null | Out-Null; Del-RV 'HKCU:\Software\AXE' 'UltPerfGuid' }}}
Add-Tweak @{Id='rend_bgapps';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Apps en segundo plano OFF';Desc='Apps UWP no corren en background. Libera CPU/RAM en idle';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled') -eq 1};
 Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1; Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 0};
 Revert={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 0; Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BackgroundAppGlobalToggle' 1}}

# --- SERVICIOS (Tier 0/1) ---
Add-Tweak @{Id='svc_telemetry';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='Telemetria OFF';Desc='DiagTrack, dmwappushservice, WerSvc';Requires=@{};
 Test={(Get-SvcStart 'DiagTrack') -eq 'Disabled'};Apply={Set-SvcStart 'DiagTrack' 'disabled'; Set-SvcStart 'dmwappushservice' 'disabled'; Set-SvcStart 'WerSvc' 'disabled'};Revert={Set-SvcStart 'DiagTrack' 'auto'; Set-SvcStart 'dmwappushservice' 'demand'; Set-SvcStart 'WerSvc' 'demand'}}
Add-Tweak @{Id='svc_obsolete';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='Servicios obsoletos OFF';Desc='RetailDemo, MapsBroker, Fax (SKU-safe)';Requires=@{};
 Test={(Get-SvcStart 'RetailDemo') -eq 'Disabled'};Apply={'RetailDemo','MapsBroker','Fax'|ForEach-Object{Set-SvcStart $_ 'disabled'}};Revert={Set-SvcStart 'RetailDemo' 'demand'; Set-SvcStart 'MapsBroker' 'demand'; Set-SvcStart 'Fax' 'demand'}}
Add-Tweak @{Id='svc_sysmain';Cat='SERVICIOS';Tier=1;Reboot=$false;Name='Precarga/diagnostico OFF';Desc='SysMain, PcaSvc, DPS (con SSD, precarga aporta poco)';Requires=@{};
 Test={(Get-SvcStart 'SysMain') -eq 'Disabled'};Apply={'SysMain','PcaSvc','DPS'|ForEach-Object{Set-SvcStart $_ 'disabled'}};Revert={'SysMain','PcaSvc','DPS'|ForEach-Object{Set-SvcStart $_ 'auto'}}}
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
Add-Tweak @{Id='app_firefox';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria Firefox OFF';Desc='Telemetria + agente navegador por defecto';Requires=@{};
 Test={(Get-RV $FfPol 'DisableTelemetry') -eq 1};
 Apply={Set-RD $FfPol 'DisableTelemetry' 1; Set-RD $FfPol 'DisableDefaultBrowserAgent' 1};
 Revert={Del-RV $FfPol 'DisableTelemetry'; Del-RV $FfPol 'DisableDefaultBrowserAgent'}}

Add-Tweak @{Id='app_nvidia';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria NVIDIA OFF';Desc='Servicio NvTelemetryContainer + tareas programadas';Requires=@{Nvidia=$true};
 Test={ (Get-SvcStart 'NvTelemetryContainer') -eq 'Disabled' };
 Apply={ Set-SvcStart 'NvTelemetryContainer' 'disabled'; & schtasks.exe /change /tn 'NvTmRepOnLogon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /disable 2>$null | Out-Null; & schtasks.exe /change /tn 'NvTmRep_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /disable 2>$null | Out-Null; & schtasks.exe /change /tn 'NvTmMon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /disable 2>$null | Out-Null };
 Revert={ Set-SvcStart 'NvTelemetryContainer' 'demand'; & schtasks.exe /change /tn 'NvTmRepOnLogon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /enable 2>$null | Out-Null; & schtasks.exe /change /tn 'NvTmRep_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /enable 2>$null | Out-Null; & schtasks.exe /change /tn 'NvTmMon_{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}' /enable 2>$null | Out-Null }}

# Office: essentials (ClientTelemetry + OSM upload + QM). No las 50 claves anidadas por version.
Add-Tweak @{Id='app_office';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria Office OFF';Desc='ClientTelemetry, OSM upload y QM (15.0 y 16.0)';Requires=@{};
 Test={(Get-RV 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry' 'DisableTelemetry') -eq 1};
 Apply={Set-RD 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry' 'DisableTelemetry' 1; Set-RD 'HKCU:\SOFTWARE\Microsoft\Office\Common\ClientTelemetry' 'DisableTelemetry' 1; Set-RD 'HKCU:\SOFTWARE\Policies\Microsoft\Office\16.0\OSM' 'EnableUpload' 0; Set-RD 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common' 'QMEnable' 0};
 Revert={Del-RV 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common\ClientTelemetry' 'DisableTelemetry'; Del-RV 'HKCU:\SOFTWARE\Microsoft\Office\Common\ClientTelemetry' 'DisableTelemetry'; Del-RV 'HKCU:\SOFTWARE\Policies\Microsoft\Office\16.0\OSM' 'EnableUpload'; Del-RV 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Common' 'QMEnable'}}

Add-Tweak @{Id='app_vs';Cat='APPS';Tier=0;Reboot=$false;Name='Telemetria Visual Studio OFF';Desc='Telemetry TurnOffSwitch + SQM opt-out (14/15/16)';Requires=@{};
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
Add-Tweak @{Id='ext_tamper';Cat='EXTREMO';Tier=2;Reboot=$false;Name='Tamper Protection OFF';Desc='Prerequisito: deja persistir los cambios de VBS/CFG/ASLR. Apaga la proteccion anti-modificacion de Defender';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection') -eq 0};
 Apply={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection' 0};
 Revert={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection' 1}}

# Core Isolation / VBS / HVCI OFF: ~5-10% FPS (Tom's Hardware 2024-2026). Requiere ext_tamper antes.
Add-Tweak @{Id='ext_vbs';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Core Isolation / Memory Integrity (VBS+HVCI) OFF';Desc='+5-10% FPS. Apaga VBS, HVCI y Credential Guard. Requiere Tamper Protection OFF primero';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled') -eq 0 -and (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity') -eq 0 -and (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags') -ne 1};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags' 0};
 Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'; Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity'; Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LsaCfgFlags'}}

# Control Flow Guard OFF: mitigacion de exploits. Ganancia pequena pero medible en CPU-bound.
Add-Tweak @{Id='ext_cfg';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Control Flow Guard (CFG) OFF';Desc='Apaga proteccion de salto indirecto. Ganancia pequena en CPU-bound. Requiere reinicio';Requires=@{};
 Test={ $m=Get-AXECache 'procmit' { try{Get-ProcessMitigation -System -EA Stop}catch{$null} }; if(-not $m){$false}else{$m.Cfg.Enable -eq 'OFF'} };
 Apply={ Set-ProcessMitigation -System -Disable CFG };
 Revert={ Set-ProcessMitigation -System -Enable CFG }}

# Mandatory ASLR OFF: desactiva el randomizado de memoria forzado del sistema.
Add-Tweak @{Id='ext_aslr';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Mandatory ASLR OFF';Desc='Apaga randomizado de memoria del sistema. Expone a exploits de buffer overflow';Requires=@{};
 Test={ $m=Get-AXECache 'procmit' { try{Get-ProcessMitigation -System -EA Stop}catch{$null} }; if(-not $m){$false}else{$m.Aslr.ForceRelocateImages -eq 'OFF'} };
 Apply={ Set-ProcessMitigation -System -Disable ForceRelocateImages };
 Revert={ Set-ProcessMitigation -System -Enable ForceRelocateImages }}

# Vulnerable Driver Blocklist OFF: permite cargar drivers sin firma estricta (DMA, overlays custom).
Add-Tweak @{Id='ext_driverblock';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Vulnerable Driver Blocklist OFF';Desc='Permite drivers bloqueados por Microsoft (overlays, inyectores). Riesgo: drivers vulnerables cargan';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable') -eq 0};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable' 0};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Config' 'VulnerableDriverBlocklistEnable' 1}}

Add-Tweak @{Id='ext_mitig';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Mitigaciones Spectre/Meltdown OFF';Desc='PIERDES proteccion CVE-2017-5715/5754';Requires=@{};
 Test={(Get-RV $MM 'FeatureSettingsOverride') -eq 3};
 Apply={Set-RD $MM 'FeatureSettingsOverride' 3; Set-RD $MM 'FeatureSettingsOverrideMask' 3};Revert={Del-RV $MM 'FeatureSettingsOverride'; Del-RV $MM 'FeatureSettingsOverrideMask'}}

# ---- AGREGADOS (peticion usuario): seguridad -> FPS. Todos opt-in, reversibles, REINICIO. ----
# ext_hypervisor: apaga el hipervisor en el arranque. DISTINTO de ext_vbs (que solo pone la
# POLITICA de registro de VBS): con Hyper-V/WSL2/Sandbox el hipervisor sigue arrancando y
# mantiene overhead; esto lo mata de raiz. Test reusa el cache 'bcd' (mismo bcdedit /enum).
Add-Tweak @{Id='ext_hypervisor';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Hypervisor OFF (mata VBS/CredGuard de raiz)';Desc='+3-8% FPS si usas Hyper-V/WSL2/Sandbox. ROMPE WSL2, Docker, Windows Sandbox, Hyper-V y Credential Guard. Reversible. REINICIO';Requires=@{};
 Test={ ((Get-AXECache 'bcd' { bcdedit /enum '{current}' | Out-String }) -match 'hypervisorlaunchtype\s+Off') };
 Apply={bcdedit /set hypervisorlaunchtype off | Out-Null};Revert={bcdedit /set hypervisorlaunchtype auto | Out-Null}}

# ext_dep: NX/DEP AlwaysOff. HONESTO: ganancia FPS ~0 en hardware moderno (DEP es gratis en la
# MMU). Incluido por peticion explicita. Reduce proteccion anti-exploit.
Add-Tweak @{Id='ext_dep';Cat='EXTREMO';Tier=2;Reboot=$true;Name='DEP/NX OFF (placebo, ~0 FPS)';Desc='Desactiva Data Execution Prevention. Ganancia FPS ~0 en hardware moderno. Reduce proteccion anti-exploit. REINICIO';Requires=@{};
 Test={ ((Get-AXECache 'bcd' { bcdedit /enum '{current}' | Out-String }) -match 'nx\s+AlwaysOff') };
 Apply={bcdedit /set nx AlwaysOff | Out-Null};Revert={bcdedit /set nx OptIn | Out-Null}}

# ext_sehop: SEHOP OFF. HONESTO: ganancia FPS ~0 (solo pesa en dispatch de excepciones).
# Incluido por peticion. Reduce proteccion anti-exploit. 1=SEHOP off, 0=SEHOP on (default).
Add-Tweak @{Id='ext_sehop';Cat='EXTREMO';Tier=2;Reboot=$true;Name='SEHOP OFF (placebo, ~0 FPS)';Desc='Desactiva Structured Exception Handling Overwrite Protection. Ganancia FPS ~0. Reduce proteccion anti-exploit. REINICIO';Requires=@{};
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
    if($r.WinVer){
        $cur = if($script:HW.IsWin11){ 11 } else { 10 }
        if($cur -notin $r.WinVer){ return "requiere Windows $($r.WinVer -join '/'), tienes Windows $cur (build $($script:HW.BuildNumber))" }
    }
    return $null
}

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
function Remove-Debloat($pkg){
    $p=Get-AppxPackage -Name $pkg -EA SilentlyContinue
    if($p){ $p | Remove-AppxPackage -EA SilentlyContinue; Write-AXELog "Quitada app: $pkg" } else { Write-AXELog "No instalada: $pkg" }
}

$script:DNSPROFILES = @(
    @{Name='Cloudflare (1.1.1.1)';V4=@('1.1.1.1','1.0.0.1')}
    @{Name='Google (8.8.8.8)';V4=@('8.8.8.8','8.8.4.4')}
    @{Name='AdGuard (bloquea ads)';V4=@('94.140.14.14','94.140.15.15')}
    @{Name='Quad9 (seguridad)';V4=@('9.9.9.9','149.112.112.112')}
    @{Name='Automatico (DHCP)';V4=$null}
)
function Set-AXEDns($v4){
    if(-not $script:HW.NicName){ Write-AXELog 'Sin adaptador activo detectado' 'WARN'; return }
    if($null -eq $v4){ Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ResetServerAddresses; Write-AXELog "DNS -> automatico (DHCP)" }
    else { Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ServerAddresses $v4; Write-AXELog "DNS -> $($v4 -join ', ')" }
    Clear-DnsClientCache
}

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

# =====================================================
# REGION 9 - MASTER REVERT  (FIX A1: limpia residuos v1)
# =====================================================
# A3: cola (limpieza residuos v1 + restore startup). Extraido para que la GUI pueda
# drenar el loop de reverts ASYNC (sin congelar) y correr esta cola al final. CLI y
# el Invoke-AXEMasterRevert completo la siguen usando igual.
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
function Invoke-AXEMasterRevert {
    Write-AXELog '=== MASTER REVERT: revirtiendo TODO a fabrica ==='
    # 1. Revertir cada tweak del catalogo
    $rev=0
    foreach($tw in $script:CAT){
        if(Get-BlockReason $tw){ continue }
        try { & $tw.Revert; $rev++ } catch { Write-AXELog "No pude revertir $($tw.Name): $($_.Exception.Message)" 'ERR' }
    }
    Write-AXELog "Revertidos $rev tweaks del catalogo."
    # 2+3. limpieza residuos v1 + restore startup
    Invoke-AXEMasterRevertTail
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
            if($e.On){ & $tw.Apply } else { & $tw.Revert }
            $applied++
        } catch { $errors++; Write-AXELog "Error importando $($tw.Id): $($_.Exception.Message)" 'ERR' }
    }
    Write-AXELog "Perfil importado: $applied aplicados, $errors errores. Reinicia si hubo cambios."
}

# =====================================================
# REGION 11 - MODOS CLI (headless)
# =====================================================
# --- HW: en modo headless (CLI) se carga SINCRONO (lo necesita gating/Tests). En modo
#     GUI se DEFIERE a un runspace de fondo (Start-AXEHardwareLoad, region 12) para que
#     la ventana no espere ~3.7s de CIM (Win32_Processor + Get-NetAdapter pagan cold-init WMI).
$script:HW = $null
if($SelfTest -or $List -or $Export -or $Import){
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
    foreach($fn in 'Get-RV','Set-RD','Set-RS','Del-RV','Test-Svc','Get-SvcStart','Set-SvcStart','Backup-RegKey','Get-BlockReason','Read-StartupBackup','Restore-Autorun','Repair-StartupBackup','Invoke-AXEMasterRevert','Invoke-AXEMasterRevertTail'){
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
    # S11: masa critica actualizada (el catalogo crece con cada fusion)
    $checks++
    if($script:CAT.Count -lt 60){ [void]$fails.Add("S11: catalogo con $($script:CAT.Count) tweaks (<60) - posible carga incompleta") }

    Write-Host "========================================="
    Write-Host " AXE v5 - SELF TEST"
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
    Write-Host "== AXE v5 =="
    if($script:HW){ Write-Host "HW: $($script:HW.CpuName) | Laptop=$($script:HW.IsLaptop) Hybrid=$($script:HW.IsHybrid) Nvidia=$($script:HW.HasNvidia) Wifi=$($script:HW.IsWifi) AC=$(-not $script:HW.OnBattery)" }
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
        WindowStartupLocation="CenterScreen" Background="#1B1B1F"
        TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True"
        FontFamily="Segoe UI Variable, Segoe UI" FontSize="13" Foreground="#ECECF0">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"       Color="#1B1B1F"/>
    <SolidColorBrush x:Key="Surface"  Color="#26262B"/>
    <SolidColorBrush x:Key="Surface2" Color="#303036"/>
    <SolidColorBrush x:Key="Line"     Color="#3A3A42"/>
    <SolidColorBrush x:Key="Fg"       Color="#ECECF0"/>
    <SolidColorBrush x:Key="Muted"    Color="#9A9AA6"/>
    <SolidColorBrush x:Key="Accent"   Color="#2DD4BF"/>
    <SolidColorBrush x:Key="AccentHi" Color="#3AE7D0"/>
    <SolidColorBrush x:Key="Green"    Color="#4ADE80"/>
    <SolidColorBrush x:Key="Amber"    Color="#FBBF24"/>
    <SolidColorBrush x:Key="Red"      Color="#F87171"/>
    <SolidColorBrush x:Key="Purple"   Color="#A78BFA"/>

    <!-- Anillo de foco de teclado (a11y: foco visible por teclado, guia Fluent) -->
    <Style x:Key="FocusRing">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Stroke="#3AE7D0" StrokeThickness="2" RadiusX="8" RadiusY="8" Margin="-2" SnapsToDevicePixels="True"/>
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
                        <Border CornerRadius="5" Background="#4A4A55" Margin="2"/>
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
      <Setter Property="Foreground" Value="White"/>
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
                <Setter Property="Foreground" Value="White"/>
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
            <Border x:Name="B" Background="Transparent" BorderBrush="{StaticResource Accent}"
                    BorderThickness="0" CornerRadius="7" Padding="10,8" Margin="8,1">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                <TextBlock x:Name="Ico" Grid.Column="0" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                           FontSize="15" Text="{TemplateBinding Tag}" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
                <TextBlock Grid.Column="1" Margin="10,0,0,0" Text="{TemplateBinding Content}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Surface2}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Surface2}"/>
                <Setter TargetName="B" Property="BorderThickness" Value="3,0,0,0"/>
                <Setter TargetName="Ico" Property="Foreground" Value="{StaticResource Accent}"/>
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
              <Ellipse x:Name="Thumb" Width="16" Height="16" HorizontalAlignment="Left" Margin="4,0,0,0" Fill="{StaticResource Muted}">
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
          <TextBlock Text="v5" FontSize="12" Foreground="{StaticResource Muted}" Margin="7,4,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel x:Name="HwChips" Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,18,0"/>
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
          <TextBox x:Name="SearchBox" DockPanel.Dock="Top" Style="{StaticResource Input}" Margin="10,0,10,8" Text="Buscar..."/>
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
          <Button x:Name="BtnRestore" Style="{StaticResource PillGhost}" Content="Punto restauracion"/>
          <Button x:Name="BtnPreset"  Style="{StaticResource PillGhost}" Content="Preset gaming"/>
          <Button x:Name="BtnRead"    Style="{StaticResource PillGhost}" Content="Leer estado"/>
          <ProgressBar x:Name="ApplyBar" Style="{StaticResource Slim}" Width="150" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center" Margin="4,0,0,0" Visibility="Collapsed"/>
        </WrapPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="BtnMaster" Style="{StaticResource PillDanger}" Content="Master revert"/>
          <Button x:Name="BtnApply"  Style="{StaticResource Pill}" Background="{StaticResource Accent}" Content="APLICAR cambios" MinWidth="152" Margin="8,0,0,0"/>
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
                 Foreground="#7CDCA0" FontFamily="Cascadia Code, Consolas" FontSize="12"
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
$LogoBox      = $win.FindName('LogoBox')
$LogoCanvas   = $win.FindName('LogoCanvas')
$CountLbl     = $win.FindName('CountLbl')
$StatusBar    = $win.FindName('StatusBar')
$ApplyBar     = $win.FindName('ApplyBar')
$script:LogBox = $win.FindName('LogBox')
# Sink de log con color por severidad (ERR rojo / WARN ambar / INFO verde) + cap 500 lineas
$script:AXELogSink = {
    param($line,$level)
    $col = switch($level){ 'ERR' {'#F87171'} 'WARN' {'#FBBF24'} default {'#7CDCA0'} }
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
}
if($script:HW){ Build-HwChips }   # headless/GUISHOW con HW ya cargado

# ---- 12.7 catalogo -> categorias + iconos ----
$script:glyphs = @{
    'CPU'=[char]0xE950; 'LATENCIA'=[char]0xE945; 'GPU'=[char]0xE7F4; 'RED'=[char]0xE774;
    'MEMORIA'=[char]0xE964; 'SISTEMA'=[char]0xE770; 'RENDIMIENTO'=[char]0xE9D9; 'SERVICIOS'=[char]0xE90F;
    'PRIVACIDAD'=[char]0xE72E; 'APPS'=[char]0xE71D; 'EXTREMO'=[char]0xE7BA;
    'LIMPIEZA'=[char]0xE74D; 'DEBLOAT'=[char]0xE738; 'DNS'=[char]0xE968; 'STARTUP'=[char]0xE768; 'ASISTENTE IA'=[char]0xE99A
}
$script:tweakCats = New-Object System.Collections.ArrayList
foreach($tw in $script:CAT){ if(-not $script:tweakCats.Contains($tw.Cat)){ [void]$script:tweakCats.Add($tw.Cat) } }
$script:actionCats = @('LIMPIEZA','DEBLOAT','DNS','STARTUP','ASISTENTE IA')
# Badge "Recomendado" = senal curada (no todo Tier<2): mejores ganancias seguras y universales
$script:RECOMMENDED = @('cpu_mmcss','cpu_prio','lat_mouse','sys_gamedvr','sys_fse','rend_gamemode','rend_visualfx','rend_mpo','gpu_hags','net_throttle','net_nagle','priv_recall','mem_lastaccess')

$script:views    = @{}   # cat -> panel (en ContentHost)
$script:rows     = @{}   # cat -> lista de @{Tw;Toggle;Desc}
$script:navBtns  = @{}
$script:activeCat = $null
$script:busy = $false

# ---- 12.8 construir una tarjeta de tweak ----
function New-TweakCard($tw){
    $card = New-Object System.Windows.Controls.Border
    $card.Background = New-AXEBrush 'Surface'; $card.BorderBrush = New-AXEBrush 'Line'
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $card.Padding = New-Object System.Windows.Thickness(14,10,14,10)
    $card.Margin = New-Object System.Windows.Thickness(0,0,0,8)

    $g = New-Object System.Windows.Controls.Grid
    $c0=New-Object System.Windows.Controls.ColumnDefinition; $c0.Width='*'
    $c1=New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='Auto'
    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)

    $left = New-Object System.Windows.Controls.StackPanel
    # fila nombre + punto de tier
    $nameRow = New-Object System.Windows.Controls.StackPanel; $nameRow.Orientation='Horizontal'
    $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width=9; $dot.Height=9; $dot.VerticalAlignment='Center'
    $dot.Fill = switch($tw.Tier){ 0 {New-AXEBrush 'Green'} 1 {New-AXEBrush 'Accent'} 2 {New-AXEBrush 'Red'} }
    $tierTip = switch($tw.Tier){ 0 {'Tier 0 - Seguro'} 1 {'Tier 1 - Elite'} 2 {'Tier 2 - EXTREMO (baja seguridad)'} }
    $dot.ToolTip = $tierTip
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text=$tw.Name; $name.FontWeight='SemiBold'; $name.Margin=New-Object System.Windows.Thickness(9,0,0,0); $name.VerticalAlignment='Center'
    [void]$nameRow.Children.Add($dot); [void]$nameRow.Children.Add($name)
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text=$tw.Desc; $desc.Foreground=New-AXEBrush 'Muted'; $desc.TextWrapping='Wrap'; $desc.Margin=New-Object System.Windows.Thickness(18,3,10,0); $desc.FontSize=12
    [void]$left.Children.Add($nameRow); [void]$left.Children.Add($desc)
    [System.Windows.Controls.Grid]::SetColumn($left,0); [void]$g.Children.Add($left)

    $tog = New-Object System.Windows.Controls.CheckBox
    $tog.Style = $win.FindResource('ToggleSwitch'); $tog.VerticalAlignment='Center'; $tog.Tag=$tw
    [System.Windows.Automation.AutomationProperties]::SetName($tog,$tw.Name)
    [System.Windows.Controls.Grid]::SetColumn($tog,1); [void]$g.Children.Add($tog)

    $blk = Get-BlockReason $tw
    if($blk){
        $tog.IsEnabled=$false; $desc.Foreground=New-AXEBrush 'Red'; $desc.Text="[BLOQUEADO] $blk"
    }
    if(-not $blk -and ($script:RECOMMENDED -contains $tw.Id)){
        $recB = New-Object System.Windows.Controls.Border
        $recB.BorderBrush=New-AXEBrush 'Accent'; $recB.BorderThickness=New-Object System.Windows.Thickness(1)
        $recB.CornerRadius=New-Object System.Windows.CornerRadius(4); $recB.Padding=New-Object System.Windows.Thickness(5,0,5,1)
        $recB.Margin=New-Object System.Windows.Thickness(8,0,0,0); $recB.VerticalAlignment='Center'
        $recT = New-Object System.Windows.Controls.TextBlock
        $recT.Text='Recomendado'; $recT.Foreground=New-AXEBrush 'Accent'; $recT.FontSize=10; $recT.FontWeight='SemiBold'
        $recB.Child=$recT; [void]$nameRow.Children.Add($recB)
    }
    # Card entera clickable (patron Fluent SettingsCard) + hook de cambios pendientes
    if(-not $blk){
        $tog.Add_Click({ Update-AXEPending })
        $card.Cursor='Hand'; $card.Tag=$tog
        $card.Add_MouseEnter({ param($s,$e) $s.Background = New-AXEBrush 'Surface2' })
        $card.Add_MouseLeave({ param($s,$e) $s.Background = New-AXEBrush 'Surface' })
        $card.Add_MouseLeftButtonUp({ param($s,$e)
            $tg=$s.Tag
            if($tg -and $tg.IsEnabled -and -not $tg.IsMouseOver){ $tg.IsChecked = -not $tg.IsChecked; Update-AXEPending }
        })
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
function Start-AXEJob {
    param([scriptblock]$Work,[string[]]$JobArgs=@(),$Button)
    if($script:jobPS){ Write-AXELog 'Otra tarea de fondo en curso, espera a que termine.' 'WARN'; return }
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
    })
    $script:jobTimer.Start()
}

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
            $bDis.Add_Click({ $n=0; foreach($cb in $script:startupChecks){ if($cb.IsChecked){ Disable-Autorun $cb.Tag; $n++ } }; Write-AXELog "$n autorun(s) desactivado(s)." })
            $bRes=New-ActionButton 'Restaurar backup' 'Green'
            $bRes.Add_Click({ Restore-Autorun | Out-Null })
            [void]$row.Children.Add($bDis); [void]$row.Children.Add($bRes); [void]$panel.Children.Add($row)
        }
        'ASISTENTE IA' {
            $script:aiOut=New-Object System.Windows.Controls.TextBox; $script:aiOut.IsReadOnly=$true; $script:aiOut.Background=New-AXEBrush 'Surface'; $script:aiOut.Foreground=New-AXEBrush 'Fg'
            $script:aiOut.BorderBrush=New-AXEBrush 'Line'; $script:aiOut.BorderThickness=New-Object System.Windows.Thickness(1); $script:aiOut.Padding=New-Object System.Windows.Thickness(12,8,12,8)
            $script:aiOut.Height=340; $script:aiOut.TextWrapping='Wrap'; $script:aiOut.VerticalScrollBarVisibility='Auto'; $script:aiOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:aiOut.FontSize=12
            $script:aiOut.Text="Asistente AXE v5 (local, sin API). Pregunta o pulsa ANALIZAR.`r`nTemas: que aplico, input lag, fps, red, seguridad, extremo.`r`n`r`n"
            $inRow=New-Object System.Windows.Controls.Grid; $inRow.Margin=New-Object System.Windows.Thickness(0,8,0,0)
            $q0=New-Object System.Windows.Controls.ColumnDefinition; $q0.Width='*'; $q1=New-Object System.Windows.Controls.ColumnDefinition; $q1.Width='Auto'; $q2=New-Object System.Windows.Controls.ColumnDefinition; $q2.Width='Auto'
            [void]$inRow.ColumnDefinitions.Add($q0); [void]$inRow.ColumnDefinitions.Add($q1); [void]$inRow.ColumnDefinitions.Add($q2)
            $script:aiIn=New-Object System.Windows.Controls.TextBox; $script:aiIn.Style=$win.FindResource('Input'); $script:aiIn.Margin=New-Object System.Windows.Thickness(0,0,8,0)
            [System.Windows.Controls.Grid]::SetColumn($script:aiIn,0); [void]$inRow.Children.Add($script:aiIn)
            $ask=New-Object System.Windows.Controls.Button; $ask.Style=$win.FindResource('Pill'); $ask.Background=New-AXEBrush 'Accent'; $ask.Content='Preguntar'
            [System.Windows.Controls.Grid]::SetColumn($ask,1); [void]$inRow.Children.Add($ask)
            $ana=New-Object System.Windows.Controls.Button; $ana.Style=$win.FindResource('Pill'); $ana.Background=New-AXEBrush 'Purple'; $ana.Content='Analizar'; $ana.Margin=New-Object System.Windows.Thickness(0)
            [System.Windows.Controls.Grid]::SetColumn($ana,2); [void]$inRow.Children.Add($ana)
            $script:aiDoAsk={ $qtext=$script:aiIn.Text; if([string]::IsNullOrWhiteSpace($qtext)){return}; $script:aiOut.AppendText(">> $qtext`r`n"); $script:aiOut.AppendText((Invoke-AXEAssistant $qtext)+"`r`n`r`n"); $script:aiOut.ScrollToEnd(); $script:aiIn.Clear() }
            $ask.Add_Click($script:aiDoAsk)
            $script:aiIn.Add_KeyDown({ param($s,$e) if($e.Key -eq 'Return'){ & $script:aiDoAsk; $e.Handled=$true } })
            $ana.Add_Click({ $script:aiOut.AppendText(">> Analisis del sistema`r`n"); $script:aiOut.AppendText(((Get-AXERecommendations) -join "`r`n")+"`r`n`r`n"); $script:aiOut.ScrollToEnd() })
            [void]$panel.Children.Add($script:aiOut); [void]$panel.Children.Add($inRow)
        }
    }
    $panel
}

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
        $ContentSub.Text = switch($catName){ 'LIMPIEZA'{'Libera espacio en disco'} 'DEBLOAT'{'Quita apps preinstaladas'} 'DNS'{'Servidores DNS rapidos'} 'STARTUP'{'Programas de arranque'} 'ASISTENTE IA'{'Recomendaciones locales, sin internet'} default{''} }
        if(-not $script:views.ContainsKey($catName)){ Build-ActionView $catName | Out-Null }
        $script:views[$catName].Visibility='Visible'; return
    }
    if($script:views.ContainsKey($catName)){ $script:views[$catName].Visibility='Visible' }
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
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){
            $blk = Get-BlockReason $e.Tw
            if($blk -and -not $e.Blocked){
                $e.Blocked=$true; $e.Toggle.IsEnabled=$false; $e.Toggle.IsChecked=$false
                $e.Desc.Foreground=New-AXEBrush 'Red'; $e.Desc.Text="[BLOQUEADO] $blk"
            }
        }
    }
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
        Build-HwChips
        Apply-AXEGating
        $nBlk=0; foreach($tw in $script:CAT){ if(Get-BlockReason $tw){ $nBlk++ } }
        Write-AXELog "Hardware detectado. Bloqueados por HW: $nBlk."
        Refresh-States
    })
    $script:hwTimer.Start()
}

# ---- 12.13 buscador ----
$SearchBox.Add_GotFocus({ if($SearchBox.Text -eq 'Buscar...'){ $SearchBox.Text='' } })
$SearchBox.Add_LostFocus({ if([string]::IsNullOrWhiteSpace($SearchBox.Text)){ $SearchBox.Text='Buscar...' } })
$SearchBox.Add_TextChanged({
    $q=$SearchBox.Text.ToLower(); if($q -eq 'buscar...'){ $q='' }
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
$BtnRead.Add_Click({ Write-AXELog 'Leyendo estado real...'; Refresh-States -Then { Write-AXELog 'Estado actualizado.' } })

$BtnPreset.Add_Click({
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){ if(-not $e.Blocked -and $e.Tw.Tier -lt 2){ $e.Toggle.IsChecked=$true } }
    }
    Update-AXEPending
    Write-AXELog 'Preset GAMING marcado (Tier 0+1). EXTREMO no se toca. Pulsa APLICAR.'
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
            try { & $tw.Revert; $script:mrRev++ } catch { Write-AXELog "No pude revertir $($tw.Name): $($_.Exception.Message)" 'ERR' }
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
            }
            return
        }
        $item=$script:applyQueue.Dequeue(); $tw=$item.Tw
        try {
            if($item.Want){ & $tw.Apply; Write-AXELog "APLICADO : $($tw.Name)" } else { & $tw.Revert; Write-AXELog "REVERTIDO: $($tw.Name)" }
            $ok=[bool](& $tw.Test)
            if($ok -ne $item.Want){ Write-AXELog "  ! verificacion no coincide en $($tw.Name)" 'WARN' }
            $script:changed++; if($tw.Reboot){ $script:reboot=$true }
        } catch { Write-AXELog "ERROR    : $($tw.Name) -> $($_.Exception.Message)" 'ERR' }
        $script:applyDone++; $ApplyBar.Value=[int](($script:applyDone/$script:applyTotal)*100)
    })
    $script:applyTimer.Start()
})

# Punto de restauracion en runspace (no congela) - portado a WPF
$BtnRestore.Add_Click({
    if($script:rsPS){ return }
    $BtnRestore.IsEnabled=$false; Write-AXELog 'Creando punto de restauracion en segundo plano...'
    $ps=[PowerShell]::Create()
    [void]$ps.AddScript({
        param($desc)
        $ac = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | Where-Object { $_.State -eq 'Running' -and $_.Name -match 'EasyAntiCheat|BEDaisy|BattlEye|vgk' }
        if($ac){ return "ANTICHEAT: '$($ac.Name -join ', ')' bloquea VSS. Cierra el juego/launcher y reintenta." }
        foreach($sv in 'VSS','swprv'){ $s=Get-Service $sv -EA SilentlyContinue; if($s -and $s.StartType -eq 'Disabled'){ & sc.exe config $sv start= demand | Out-Null } }
        Start-Service VSS -EA SilentlyContinue
        Enable-ComputerRestore -Drive 'C:\' -EA SilentlyContinue
        $rp='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        New-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
        try { Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS; 'OK: punto CREADO.' }
        catch { "ERROR: $($_.Exception.Message)" }
        finally { Remove-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -EA SilentlyContinue }
    })
    [void]$ps.AddArgument('AXE v5')
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
})

# ---- 12.15 init ----
$n = Repair-StartupBackup
if($n -gt 0){ Write-AXELog "Startup backup migrado a formato v5: $n entrada(s)." }
Write-AXELog "AXE v5 lista. Tweaks: $($script:CAT.Count)."
Write-AXELog 'Recomendado: crea PRIMERO el punto de restauracion.'
# A4: HW async -> chips + gating + Refresh-States al completar (la ventana ya esta visible)
Start-AXEHardwareLoad

$firstCat = $script:tweakCats | Select-Object -First 1
if($firstCat){ $script:navBtns[$firstCat].IsChecked=$true }

# ---- 12.16 GUITEST: assert + render PNG, sin ShowDialog ----
if($env:AXE_GUITEST -eq '1'){
    Write-Host "== AXE v5 WPF - LAYOUT TEST =="
    Write-Host "NAV items         : $($script:navBtns.Count)"
    Write-Host "Vistas tweaks     : $(($script:tweakCats).Count)"
    $allOk=$true

    # Bombea la cola del dispatcher hasta idle (permite que DispatcherTimer ticke sin ShowDialog)
    function Invoke-AXEDoEvents {
        $frame=New-Object System.Windows.Threading.DispatcherFrame
        [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::SystemIdle,[action]{ $frame.Continue=$false })
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }

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

    # regresion A3: split de Master revert (tail extraido). Solo verifica ESTRUCTURA:
    # ambas funciones definidas. NO se ejecuta (revertiria los tweaks reales del sistema).
    $mrOk = [bool](Get-Command Invoke-AXEMasterRevert -EA SilentlyContinue) -and [bool](Get-Command Invoke-AXEMasterRevertTail -EA SilentlyContinue)
    Write-Host "Master revert     : tail+full definidos=$mrOk (esperado True)"
    if(-not $mrOk){ $allOk=$false }

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
    # regresion: ejercer handler ASISTENTE (bug de scope $out/$doAsk null)
    try {
        $before=$script:aiOut.Text.Length
        $script:aiIn.Text='fps'
        & $script:aiDoAsk
        $grew=$script:aiOut.Text.Length -gt $before
        Write-Host "Asistente handler : output crecio=$grew (esperado True)"
        if(-not $grew){ $allOk=$false }
    } catch { Write-Host "Asistente handler : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
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
        $accent=$paths | Where-Object { $_.Fill -is [System.Windows.Media.SolidColorBrush] -and $_.Fill.Color.ToString() -eq '#FF2DD4BF' }
        $surface=$paths | Where-Object { $_.Fill -is [System.Windows.Media.SolidColorBrush] -and $_.Fill.Color.ToString() -eq '#FF26262B' }
        $script:logoPathCount=$paths.Count; $script:logoAccent=$accent.Count; $script:logoSurface=$surface.Count
        $logoOk=($paths.Count -eq 6) -and ($accent.Count -eq 2) -and ($surface.Count -eq 4)
        Write-Host ("Logo AXE          : paths={0} accent={1} surface={2} (esperado 6/2/4)" -f $paths.Count,$accent.Count,$surface.Count)
        if(-not $logoOk){ $allOk=$false }
    } catch { Write-Host "Logo AXE          : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

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
    } catch { Write-Host "Render PNG        : FALLO -> $($_.Exception.Message)" }
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
[void]$win.ShowDialog()
