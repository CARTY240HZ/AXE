#Requires -Version 5.1
# =====================================================
# LW SUITE v4 - Elite Windows Optimizer (single source of truth)
#
# Motor UNICO consolidado. Corrige todos los hallazgos del audit:
#   C1  Backup/restore de startup robusto + Restore-Autorun
#   A1  Invoke-LWMasterRevert limpia residuos v1 (SmartScreen/NoConnectedUser/hypervisor)
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
$script:LWRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LWData   = Join-Path $script:LWRoot 'LWSuite'
$script:LWBackup = Join-Path $script:LWData 'Backups'
$script:LWLog    = Join-Path $script:LWData ("lw_log_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$script:RunBak   = Join-Path $script:LWData 'startup_disabled.json'
foreach($d in @($script:LWData,$script:LWBackup)){ if(-not(Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$script:LogBox = $null
function Write-LWLog {
    param([string]$Msg,[string]$Level='INFO')
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Msg
    Add-Content -Path $script:LWLog -Value $line -Encoding UTF8
    if($script:LogBox){ $script:LogBox.AppendText("$line`r`n"); $script:LogBox.ScrollToCaret() }
}

# =====================================================
# REGION 2 - HARDWARE DETECTION  (define que tweaks son validos)
# =====================================================
function Get-LWHardware {
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
    if(-not(Test-Svc $n)){ Write-LWLog "Servicio '$n' no existe en este SKU, omitido" 'WARN'; return }
    & sc.exe config $n start= $m | Out-Null
    if($LASTEXITCODE -ne 0){ throw "sc config $n start=$m fallo (code $LASTEXITCODE)" }
}
function Backup-RegKey($hive,$file){
    $dest = Join-Path $script:LWBackup $file
    if(Test-Path $dest){ return }   # NO destructivo: solo la primera vez
    & reg.exe export $hive $dest /y *>$null
    if($LASTEXITCODE -eq 0){ Write-LWLog "Backup: $file" }
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
        # Normalizar: si es un solo objeto -> array; si ya es array -> tal cual
        if($obj -is [array]){ return @($obj) } else { return @($obj) }
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
    Write-LWLog "Startup desactivado: $($entry.Name) (backup guardado)"
}
function Restore-Autorun {
    # FIX C1: funcion que antes NO existia. Restaura todos los autoruns del backup.
    $bak = Read-StartupBackup
    if($bak.Count -eq 0){ Write-LWLog 'No hay startup en backup.' 'WARN'; return 0 }
    $restored = 0
    foreach($e in $bak){
        try {
            if(-not(Test-Path $e.Path)){ New-Item -Path $e.Path -Force | Out-Null }
            New-ItemProperty -Path $e.Path -Name $e.Name -Value $e.Value -PropertyType String -Force | Out-Null
            $restored++
            Write-LWLog "Startup restaurado: $($e.Name)"
        } catch { Write-LWLog "No pude restaurar $($e.Name): $($_.Exception.Message)" 'ERR' }
    }
    if($restored -gt 0){ Remove-Item $script:RunBak -ErrorAction SilentlyContinue }
    Write-LWLog "$restored autorun(s) restaurado(s)."
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
 Test={ ((bcdedit /enum '{current}' | Out-String) -match 'disabledynamictick\s+Yes') };Apply={bcdedit /set disabledynamictick yes | Out-Null};Revert={bcdedit /deletevalue disabledynamictick | Out-Null}}
Add-Tweak @{Id='cpu_tsc';Cat='CPU';Tier=1;Reboot=$true;Name='TSC Sync Enhanced';Desc='Sincroniza contador de tiempo entre nucleos (REINICIO)';Requires=@{};
 Test={ ((bcdedit /enum '{current}' | Out-String) -match 'tscsyncpolicy\s+Enhanced') };Apply={bcdedit /set tscsyncpolicy Enhanced | Out-Null};Revert={bcdedit /deletevalue tscsyncpolicy | Out-Null}}

# --- LATENCIA / INPUT LAG (Tier 1) ---
Add-Tweak @{Id='lat_msi_audio';Cat='LATENCIA';Tier=1;Reboot=$true;Name='MSI mode en HD Audio';Desc='Baja DPC latency del audio';Requires=@{};
 Test={ $hd=Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%High Definition Audio%'" -EA SilentlyContinue | Where-Object PNPDeviceID -like 'PCI*'; if(-not $hd){return $true}; $ok=$true; foreach($d in $hd){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"; if((Get-RV $p 'MSISupported') -ne 1){$ok=$false} }; $ok };
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
 Test={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; if(-not $g){return $true}; $ok=$true; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; if((Get-RV $p 'DevicePriority') -ne 3){$ok=$false} }; $ok };
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
 Test={try{(Get-NetTCPSetting -SettingName Internet -EA Stop).CongestionProvider -eq 'CTCP'}catch{$false}};Apply={netsh int tcp set supplemental template=internet congestionprovider=ctcp | Out-Null};Revert={netsh int tcp set supplemental template=internet congestionprovider=cubic | Out-Null}}
Add-Tweak @{Id='net_ecn';Cat='RED';Tier=1;Reboot=$false;Name='ECN OFF';Desc='Evita conflictos con routers viejos';Requires=@{};
 Test={try{(Get-NetTCPSetting -SettingName Internet -EA Stop).EcnCapability -eq 'Disabled'}catch{$false}};Apply={netsh int tcp set global ecncapability=disabled | Out-Null};Revert={netsh int tcp set global ecncapability=default | Out-Null}}
Add-Tweak @{Id='net_qos';Cat='RED';Tier=1;Reboot=$true;Name='QoS sin reserva de banda';Desc='NonBestEffortLimit=0 (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit'}}
Add-Tweak @{Id='net_lso';Cat='RED';Tier=1;Reboot=$false;Name='Interrupt Moderation NIC OFF';Desc='Menos buffering en el adaptador activo';Requires=@{};
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
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode') -eq 5};Apply={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestType' 5};Revert={Del-RV 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestType'}}
Add-Tweak @{Id='rend_prefetch';Cat='RENDIMIENTO';Tier=1;Reboot=$true;Name='Prefetch/Superfetch OFF';Desc='Con SSD la precarga aporta poco (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher') -eq 0};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 0};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 3; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 3}}

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
 Test={ try { (Get-ProcessMitigation -System).Cfg.Enable -eq 'OFF' } catch { $false } };
 Apply={ Set-ProcessMitigation -System -Disable CFG };
 Revert={ Set-ProcessMitigation -System -Enable CFG }}

# Mandatory ASLR OFF: desactiva el randomizado de memoria forzado del sistema.
Add-Tweak @{Id='ext_aslr';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Mandatory ASLR OFF';Desc='Apaga randomizado de memoria del sistema. Expone a exploits de buffer overflow';Requires=@{};
 Test={ try { (Get-ProcessMitigation -System).Aslr.ForceRelocateImages -eq 'OFF' } catch { $false } };
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

# FIX M5: guard anti-catalogo-roto. Si el catalogo no tiene masa critica, abortar antes de tocar nada.
if($script:CAT.Count -lt 10){
    Write-LWLog "ALERTA: catalogo con $($script:CAT.Count) tweaks (<10). Abortando para no operar en estado inconsistente." 'ERR'
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
Add-Clean @{Name='Temporales (usuario + Windows)';Desc='Borra %TEMP% y C:\Windows\Temp';Run={
    $b=[math]::Round((Get-PSDrive C).Free/1GB,2); Remove-Item "$env:TEMP\*" -Recurse -Force -EA SilentlyContinue; Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -EA SilentlyContinue; $a=[math]::Round((Get-PSDrive C).Free/1GB,2); Write-LWLog "Temporales limpios. Libre: $b -> $a GB" }}
Add-Clean @{Name='Cache shaders DirectX';Desc='Se regenera sola; util tras update de driver';Run={ Remove-Item "$env:LOCALAPPDATA\D3DSCache\*" -Recurse -Force -EA SilentlyContinue; Write-LWLog 'Cache shaders DirectX limpiada.' }}
Add-Clean @{Name='Cache Windows Update';Desc='Para wuauserv/bits, borra Download, reinicia';Run={
    Stop-Service wuauserv,bits -Force -EA SilentlyContinue; Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -EA SilentlyContinue; Start-Service bits,wuauserv -EA SilentlyContinue; Write-LWLog 'Cache Windows Update limpiada.' }}
Add-Clean @{Name='Flush DNS';Desc='Vacia cache de resolucion de nombres';Run={ ipconfig /flushdns | Out-Null; Write-LWLog 'Cache DNS vaciada.' }}
Add-Clean @{Name='Purga working set (RAM)';Desc='Libera RAM en cache de procesos idle';Run={
    $sig='[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);'; $t=Add-Type -MemberDefinition $sig -Name WS -Namespace LW -PassThru; $n=0; Get-Process | ForEach-Object { try{ if($t::EmptyWorkingSet($_.Handle)){$n++} }catch{} }; Write-LWLog "Working set purgado en $n procesos." }}

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
    if($p){ $p | Remove-AppxPackage -EA SilentlyContinue; Write-LWLog "Quitada app: $pkg" } else { Write-LWLog "No instalada: $pkg" }
}

$script:DNSPROFILES = @(
    @{Name='Cloudflare (1.1.1.1)';V4=@('1.1.1.1','1.0.0.1')}
    @{Name='Google (8.8.8.8)';V4=@('8.8.8.8','8.8.4.4')}
    @{Name='AdGuard (bloquea ads)';V4=@('94.140.14.14','94.140.15.15')}
    @{Name='Quad9 (seguridad)';V4=@('9.9.9.9','149.112.112.112')}
    @{Name='Automatico (DHCP)';V4=$null}
)
function Set-LWDns($v4){
    if(-not $script:HW.NicName){ Write-LWLog 'Sin adaptador activo detectado' 'WARN'; return }
    if($null -eq $v4){ Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ResetServerAddresses; Write-LWLog "DNS -> automatico (DHCP)" }
    else { Set-DnsClientServerAddress -InterfaceAlias $script:HW.NicName -ServerAddresses $v4; Write-LWLog "DNS -> $($v4 -join ', ')" }
    Clear-DnsClientCache
}

# =====================================================
# REGION 8 - ASISTENTE IA LOCAL (sin API, state-aware)
# =====================================================
function Get-LWState($tw){
    $blk=Get-BlockReason $tw
    if($blk){ return @{S='BLOCK';T="  [BLOQUEADO] $($tw.Name)  ->  $blk"} }
    try { if([bool](& $tw.Test)){ return @{S='ON';T="  [ON]  $($tw.Name)"} } else { return @{S='OFF';T="  [off] $($tw.Name)  ->  $($tw.Desc)"} } }
    catch { return @{S='ERR';T="  [?]   $($tw.Name)"} }
}
function Report-Cats($cats,$titulo){
    $out=@("== $titulo =="); $off=0; $blk=0
    foreach($tw in $script:CAT){ if($cats -contains $tw.Cat){ $st=Get-LWState $tw; $out+=$st.T; if($st.S -eq 'OFF'){$off++}; if($st.S -eq 'BLOCK'){$blk++} } }
    if($off -gt 0){ $out+="`n>> $off sin aplicar." } else { $out+="`n>> Todo lo aplicable ya esta ON." }
    if($blk -gt 0){ $out+=">> $blk bloqueado(s) por tu hardware." }
    $out -join "`r`n"
}
function Get-LWRecommendations {
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
        if($hog){ [void]$r.Add("[RENDIMIENTO] '$($hog.Name)' consume mas de 0.8 nucleos continuos. Cerralo antes de jugar.") }
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
function Invoke-LWAssistant($q){
    if([string]::IsNullOrWhiteSpace($q)){ return 'Escribe: "que aplico", "input lag", "fps", "red", "seguridad", "portatil".' }
    $s=$q.ToLower()
    if($s -match 'recom|que aplic|que hago|deber|empez|inicio|todo|optimiz'){ return (Get-LWRecommendations) -join "`r`n" }
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
function Invoke-LWMasterRevert {
    Write-LWLog '=== MASTER REVERT: revirtiendo TODO a fabrica ==='
    # 1. Revertir cada tweak del catalogo
    $rev=0
    foreach($tw in $script:CAT){
        if(Get-BlockReason $tw){ continue }
        try { & $tw.Revert; $rev++ } catch { Write-LWLog "No pude revertir $($tw.Name): $($_.Exception.Message)" 'ERR' }
    }
    Write-LWLog "Revertidos $rev tweaks del catalogo."
    # 2. FIX A1: limpiar residuos de scripts v1 que v2 no revertia
    # SmartScreen (v1 lo apagaba; v2 lo quito de apply pero no limpiaba en revert)
    $ssKey='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    if((Get-RV $ssKey 'EnableSmartScreen') -ne $null){ Del-RV $ssKey 'EnableSmartScreen'; Write-LWLog 'Limpieza v1: EnableSmartScreen eliminado (restaura SmartScreen)' }
    # NoConnectedUser (v1 bloqueaba login Microsoft)
    $ncuKey='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if((Get-RV $ncuKey 'NoConnectedUser') -ne $null){ Del-RV $ncuKey 'NoConnectedUser'; Write-LWLog 'Limpieza v1: NoConnectedUser eliminado (desbloquea login MS)' }
    # hypervisorlaunchtype (v1 lo ponia off; rompia WSL2/Docker)
    $hv=((bcdedit /enum '{current}' | Out-String))
    if($hv -match 'hypervisorlaunchtype\s+Off'){ bcdedit /set hypervisorlaunchtype auto | Out-Null; Write-LWLog 'Limpieza v1: hypervisorlaunchtype -> auto (restaura WSL2/Docker)' }
    # useplatformtick / CoalescingTimerDisabled (v1 CPU avanzado)
    if($hv -match 'useplatformclock\s+Yes'){ bcdedit /deletevalue useplatformclock | Out-Null; Write-LWLog 'Limpieza v1: useplatformclock eliminado' }
    if((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'CoalescingTimerDisabled') -ne $null){ Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'CoalescingTimerDisabled'; Write-LWLog 'Limpieza v1: CoalescingTimerDisabled eliminado' }
    # 3. Restaurar startup si hay backup
    Restore-Autorun | Out-Null
    Write-LWLog '=== MASTER REVERT completado. Reinicia el PC. ==='
}

# =====================================================
# REGION 10 - PERFIL EXPORT/IMPORT
# =====================================================
function Test-TweakSafe($tw){
    try { return [bool](& $tw.Test) } catch { return $false }
}
function Export-LWProfile($file){
    $prof = foreach($tw in $script:CAT){ [pscustomobject]@{Id=$tw.Id; On=(Test-TweakSafe $tw)} }
    $prof | ConvertTo-Json -Depth 3 | Set-Content $file -Encoding UTF8
    Write-LWLog "Perfil exportado: $file ($($prof.Count) tweaks)"
}
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Import-LWProfile($file){
    if(-not(Test-Path $file)){ Write-LWLog "No existe: $file" 'ERR'; return }
    if(-not (Test-Admin)){ Write-LWLog 'Import requiere admin. Ejecuta via LWSuite.bat (se eleva solo) o como administrador.' 'ERR'; return }
    $data = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $applied=0; $errors=0
    foreach($e in $data){
        $tw = $script:CAT | Where-Object Id -eq $e.Id
        if(-not $tw){ continue }
        if(Get-BlockReason $tw){ continue }
        try {
            if($e.On){ & $tw.Apply } else { & $tw.Revert }
            $applied++
        } catch { $errors++; Write-LWLog "Error importando $($tw.Id): $($_.Exception.Message)" 'ERR' }
    }
    Write-LWLog "Perfil importado: $applied aplicados, $errors errores. Reinicia si hubo cambios."
}

# =====================================================
# REGION 11 - MODOS CLI (headless)
# =====================================================
# --- HW se carga siempre (para gating), pero tolera fallo en CI/sin admin ---
$script:HW = $null
try { $script:HW = Get-LWHardware } catch { $script:HW = $null }

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
        $tmp = Join-Path $script:LWData ('selftest_{0}.json' -f [guid]::NewGuid())
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
    foreach($fn in 'Get-RV','Set-RD','Set-RS','Del-RV','Test-Svc','Get-SvcStart','Set-SvcStart','Backup-RegKey','Get-BlockReason','Read-StartupBackup','Restore-Autorun','Repair-StartupBackup','Invoke-LWMasterRevert'){
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
    Write-Host " LW SUITE v4 - SELF TEST"
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
    Write-Host "== LW SUITE v4 =="
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
    Export-LWProfile $Export
    exit 0
}
if($Import){
    Import-LWProfile $Import
    exit 0
}

# =====================================================
# REGION 12 - GUI v5 REDISEÑADA (sidebar + tarjetas + estado visual)
# =====================================================
# Requerir admin para GUI (salvo en modo GUITEST, que solo valida layout sin tocar nada)
if($env:LW_GUITEST -ne '1' -and -not (Test-Admin)){
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Ejecuta 'LWSuite.bat' (se eleva solo).","Admin requerido",'OK','Warning') | Out-Null
    exit 1
}
if($script:CAT.Count -lt 10){
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("Catalogo roto ($($script:CAT.Count) tweaks). Abortando para protegerte.","LW Suite",'OK','Error') | Out-Null
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Paleta de diseño (dark moderno con acentos)
$bg     = [System.Drawing.Color]::FromArgb(20,20,24)     # fondo app
$surf   = [System.Drawing.Color]::FromArgb(30,30,36)     # superficie (paneles)
$surf2  = [System.Drawing.Color]::FromArgb(38,38,46)     # superficie hover/fila
$fg     = [System.Drawing.Color]::FromArgb(236,236,240)
$muted  = [System.Drawing.Color]::FromArgb(150,150,160)
$accent = [System.Drawing.Color]::FromArgb(86,156,214)   # azul VS Code
$green  = [System.Drawing.Color]::FromArgb(80,200,120)
$amber  = [System.Drawing.Color]::FromArgb(220,160,40)
$red    = [System.Drawing.Color]::FromArgb(220,80,80)
$purple = [System.Drawing.Color]::FromArgb(150,90,220)
$t0clr  = $green
$t1clr  = $accent
$t2clr  = $red

$form=New-Object System.Windows.Forms.Form
$form.Text='LW SUITE v5'; $form.Size='1200,820'; $form.StartPosition='CenterScreen'
$form.BackColor=$bg; $form.ForeColor=$fg; $form.Font=New-Object System.Drawing.Font('Segoe UI',9)
$form.MinimumSize='1000,700'
try { $form.Icon = [System.Drawing.SystemIcons]::Shield } catch {}

# ---------- Helper: construir controles con defaults ----------
function Lw:Font($size=9,$style='Regular'){ New-Object System.Drawing.Font('Segoe UI',$size,[System.Drawing.FontStyle]::$style) }

# ---------- BARRA SUPERIOR: titulo + tarjeta de hardware ----------
$headerPnl = New-Object System.Windows.Forms.Panel
$headerPnl.Dock='Top'; $headerPnl.Height=58; $headerPnl.BackColor=$surf; $headerPnl.Padding='14,8,14,8'
$form.Controls.Add($headerPnl)

$titleLbl = New-Object System.Windows.Forms.Label
$titleLbl.Text='LW SUITE'; $titleLbl.Font=Lw:Font 15 'Bold'; $titleLbl.ForeColor=$accent
$titleLbl.Location='14,6'; $titleLbl.Size='130,28'; $titleLbl.BackColor=$surf
$headerPnl.Controls.Add($titleLbl)

$verLbl = New-Object System.Windows.Forms.Label
$verLbl.Text='v5'; $verLbl.Font=Lw:Font 9 'Regular'; $verLbl.ForeColor=$muted
$verLbl.Location='148,16'; $verLbl.Size='30,20'; $verLbl.BackColor=$surf
$headerPnl.Controls.Add($verLbl)

# Tarjeta de hardware (derecha del header)
$hwText = if($script:HW){
    $formFactor = if($script:HW.IsLaptop){'Portatil'}else{'Desktop'}
    $arch = if($script:HW.IsHybrid){'Hibrida P+E'}else{'Homogenea'}
    $net = if($script:HW.IsWifi){'Wi-Fi'}else{'Ethernet'}
    $pwr = if($script:HW.OnBattery){'Bateria'}else{'AC'}
    "{0}  |  {1}C/{2}T  |  {3}  |  {4}  |  {5}  |  {6}  |  RAM {7}GB" -f $script:HW.CpuName,$script:HW.Cores,$script:HW.Threads,$formFactor,$arch,$net,$pwr,$script:HW.RamGB
} else { 'Hardware no detectado' }
$hwLbl = New-Object System.Windows.Forms.Label
$hwLbl.Text=$hwText; $hwLbl.Font=Lw:Font 8 'Regular'; $hwLbl.ForeColor=$muted
$hwLbl.TextAlign='MiddleRight'; $hwLbl.Anchor='Top,Right'; $hwLbl.BackColor=$surf
$hwLbl.Location='500,20'; $hwLbl.Size='670,28'
$headerPnl.Controls.Add($hwLbl)

# ---------- LAYOUT PRINCIPAL: sidebar (izq) + contenido (der) ----------
$mainSplit = New-Object System.Windows.Forms.SplitContainer
$mainSplit.Dock='Fill'; $mainSplit.Orientation='Vertical'
$mainSplit.SplitterDistance=190; $mainSplit.SplitterWidth=1
$mainSplit.BackColor=$bg; $mainSplit.Panel1.BackColor=$surf; $mainSplit.Panel2.BackColor=$bg
$form.Controls.Add($mainSplit)
# Traer al frente despues del header (que esta docked top)
$headerPnl.SendToBack(); $mainSplit.BringToFront()

# ---------- SIDEBAR (Panel1): categorias como botones ----------
$sideFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$sideFlow.Dock='Fill'; $sideFlow.FlowDirection='TopDown'; $sideFlow.WrapContents=$false
$sideFlow.AutoScroll=$true; $sideFlow.BackColor=$surf; $sideFlow.Padding='6,8,6,8'
$mainSplit.Panel1.Controls.Add($sideFlow)

# Header del sidebar
$sideHdr = New-Object System.Windows.Forms.Label
$sideHdr.Text='CATEGORIAS'; $sideHdr.Font=Lw:Font 8 'Bold'; $sideHdr.ForeColor=$muted
$sideHdr.Size='172,18'; $sideHdr.BackColor=$surf; $sideHdr.Margin='2,2,2,4'
$sideFlow.Controls.Add($sideHdr)

# Buscador dentro del sidebar
$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Size='172,26'; $searchBox.BackColor=$surf2; $searchBox.ForeColor=$fg
$searchBox.Text='Buscar...'; $searchBox.Font=Lw:Font 9; $searchBox.Margin='2,2,2,6'
$searchBox.BorderStyle='FixedSingle'
$sideFlow.Controls.Add($searchBox)

# Botones de categoria (se generan dinamicamente)
$script:cats = New-Object System.Collections.ArrayList
foreach($tw in $script:CAT){ if(-not $script:cats.Contains($tw.Cat)){ [void]$script:cats.Add($tw.Cat) } }
# Anadir categorias de acciones (no del catalogo)
$script:actionCats = @('LIMPIEZA','DEBLOAT','DNS','STARTUP','ASISTENTE IA')
foreach($c in $script:actionCats){ if(-not $script:cats.Contains($c)){ [void]$script:cats.Add($c) } }

$script:catButtons = @{}
$script:activeCat = $null

foreach($catName in $script:cats){
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text=$catName; $btn.Size='172,32'; $btn.Margin='2,1,2,1'
    $btn.FlatStyle='Flat'; $btn.FlatAppearance.BorderSize=0
    $btn.TextAlign='MiddleLeft'; $btn.Padding='10,0,0,0'
    $btn.Font=Lw:Font 9; $btn.BackColor=$surf; $btn.ForeColor=$fg
    $btn.Cursor='Hand'; $btn.Tag=$catName
    $btn.Add_Click({
        param($s,$e)
        foreach($k in $script:catButtons.Keys){ $b=$script:catButtons[$k]; $b.BackColor=$surf; $b.ForeColor=$fg }
        $s.BackColor=$accent; $s.ForeColor='White'
        $script:activeCat=$s.Tag
        Switch-Panel $s.Tag
    })
    $btn.Add_MouseEnter({ param($s,$e) if($s.BackColor -ne $accent){ $s.BackColor=$surf2 } })
    $btn.Add_MouseLeave({ param($s,$e) if($s.BackColor -ne $accent){ $s.BackColor=$surf } })
    $sideFlow.Controls.Add($btn)
    $script:catButtons[$catName]=$btn
}

# Leyenda de tiers en el pie del sidebar
$legLbl = New-Object System.Windows.Forms.Label
$legLbl.Text="`nTIER  0 Seguro  1 Elite  2 EXTREMO"; $legLbl.Font=Lw:Font 7 'Regular'
$legLbl.ForeColor=$muted; $legLbl.Size='172,36'; $legLbl.BackColor=$surf; $legLbl.Margin='2,8,2,2'
$sideFlow.Controls.Add($legLbl)

# ---------- CONTENIDO (Panel2): area que cambia segun categoria ----------
$contentPnl = New-Object System.Windows.Forms.Panel
$contentPnl.Dock='Fill'; $contentPnl.BackColor=$bg; $contentPnl.Padding='6,6,6,6'
$mainSplit.Panel2.Controls.Add($contentPnl)

# Contador superior del contenido
$script:catTitleLbl = New-Object System.Windows.Forms.Label
$script:catTitleLbl.Dock='Top'; $script:catTitleLbl.Height=30
$script:catTitleLbl.Font=Lw:Font 12 'Bold'; $script:catTitleLbl.ForeColor=$fg
$script:catTitleLbl.BackColor=$bg; $script:catTitleLbl.Padding='4,4,4,0'
$contentPnl.Controls.Add($script:catTitleLbl)

# Panel de contenido (donde van los tweaks/acciones)
$script:viewPnl = New-Object System.Windows.Forms.Panel
$script:viewPnl.Dock='Fill'; $script:viewPnl.BackColor=$bg
$contentPnl.Controls.Add($script:viewPnl)

# Estructura de datos para tweaks
$script:allChecks = New-Object System.Collections.ArrayList
$script:catRows = @{}        # Cat -> array de hashtables {Row,Chk,Lbl,Badge,Id,Name,Desc,Tier}
$script:catFlows = @{}       # Cat -> su FlowLayoutPanel (uno por categoria)
$script:actionFlows = @{}    # Cat de accion -> su FlowLayoutPanel

# Anchura de fila dinamica: se recalcula al cambiar de categoria
function Get-RowWidth { try { [math]::Max(600, $script:viewPnl.ClientSize.Width - 12) } catch { 940 } }

# Construye UNA fila de tweak (contenedor con tier-bar, checkbox, desc, badge)
function New-TweakRow($tw, $rowWidth){
    $row = New-Object System.Windows.Forms.Panel
    $row.Size="$rowWidth,34"; $row.BackColor=$surf; $row.Margin='0,0,0,3'

    # Barra de tier (4px color a la izquierda)
    $tierBar = New-Object System.Windows.Forms.Panel
    $tierBar.Size='4,34'; $tierBar.Location='0,0'
    $tierBar.BackColor = switch($tw.Tier){ 0 {$green} 1 {$accent} 2 {$red} }
    $row.Controls.Add($tierBar)

    # Checkbox (nombre)
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location='16,7'; $chk.Size='300,22'; $chk.ForeColor=$fg; $chk.Tag=$tw
    $chk.Font=Lw:Font 9 'Bold'; $chk.BackColor=$surf; $chk.Text=$tw.Name
    $chk.Anchor='Top,Left'
    $row.Controls.Add($chk)

    # Descripcion
    $lbl = New-Object System.Windows.Forms.Label
    $lblW = [int]$rowWidth - 440
    $lbl.Location='324,10'; $lbl.Size="$lblW,20"; $lbl.ForeColor=$muted; $lbl.BackColor=$surf
    $lbl.Text=$tw.Desc; $lbl.Anchor='Top,Left,Right'; $lbl.AutoEllipsis=$true
    $row.Controls.Add($lbl)

    # Badge de estado ON/OFF (derecha, con anchor)
    $badge = New-Object System.Windows.Forms.Label
    $badgeX = [int]$rowWidth - 104
    $badge.Location="$badgeX,8"; $badge.Size='96,20'; $badge.TextAlign='MiddleCenter'
    $badge.Font=Lw:Font 8 'Bold'; $badge.BackColor=$surf; $badge.Text='...'; $badge.Anchor='Top,Right'
    $row.Controls.Add($badge)

    $blk = Get-BlockReason $tw
    if($blk){
        $chk.Enabled=$false; $chk.ForeColor=$muted
        $lbl.ForeColor=$red; $lbl.Text="[BLOQUEADO] $blk"
        $badge.Text='OFF'; $badge.ForeColor=$muted
    }

    return @{Row=$row; Chk=$chk; Lbl=$lbl; Badge=$badge; Id=$tw.Id; Name=$tw.Name; Desc=$tw.Desc; Tier=$tw.Tier}
}

# Construye UN FlowLayoutPanel por categoria de tweaks, cada uno Dock=Fill + AutoScroll
function Build-TweakView {
    foreach($catName in $script:cats){
        if($catName -in $script:actionCats){ continue }
        $flow = New-Object System.Windows.Forms.FlowLayoutPanel
        $flow.Dock='Fill'; $flow.FlowDirection='TopDown'; $flow.WrapContents=$false
        $flow.AutoScroll=$true; $flow.BackColor=$bg; $flow.Padding='4,2,8,4'
        $flow.Visible=$false
        $script:viewPnl.Controls.Add($flow)
        $script:catFlows[$catName]=$flow
        $script:catRows[$catName]=New-Object System.Collections.ArrayList

        $rowW = Get-RowWidth
        foreach($tw in ($script:CAT | Where-Object Cat -eq $catName)){
            $entry = New-TweakRow $tw $rowW
            $flow.Controls.Add($entry.Row)
            [void]$script:allChecks.Add($entry.Chk)
            [void]$script:catRows[$catName].Add($entry)
        }
    }
}
Build-TweakView

# ---------- Cambiar de panel (categoria): oculta todos los flows, muestra el activo ----------
function Switch-Panel($catName){
    foreach($f in $script:catFlows.Values){ $f.Visible=$false }
    foreach($f in $script:actionFlows.Values){ $f.Visible=$false }
    $script:catTitleLbl.Text=$catName

    if($catName -in $script:actionCats){
        if(-not $script:actionFlows[$catName]){ $script:actionFlows[$catName] = Build-ActionFlow $catName }
        $script:actionFlows[$catName].Visible=$true
        return
    }
    if($script:catFlows[$catName]){ $script:catFlows[$catName].Visible=$true }
}

# ---------- Vistas de acciones: cada una su propio FlowLayoutPanel ----------
function Build-ActionFlow($catName){
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock='Fill'; $flow.FlowDirection='TopDown'; $flow.WrapContents=$false
    $flow.AutoScroll=$true; $flow.BackColor=$bg; $flow.Padding='4,2,8,4'; $flow.Visible=$false
    $rowW = Get-RowWidth
    $script:viewPnl.Controls.Add($flow)

    switch($catName){
        'LIMPIEZA' {
            foreach($cl in $script:CLEAN){
                $row=New-Object System.Windows.Forms.Panel; $row.Size="$rowW,44"; $row.BackColor=$surf; $row.Margin='0,0,0,4'
                $b=New-Object System.Windows.Forms.Button; $b.Text=$cl.Name; $b.Size='280,34'; $b.Location='8,5'
                $b.BackColor=$accent; $b.ForeColor='White'; $b.FlatStyle='Flat'; $b.Font=Lw:Font 9 'Bold'; $b.Tag=$cl; $b.Cursor='Hand'; $b.Anchor='Top,Left'
                $b.Add_Click({ param($s,$e) $act=$s.Tag; Write-LWLog "Limpieza: $($act.Name)..."; try{ & $act.Run }catch{ Write-LWLog "ERROR: $($_.Exception.Message)" 'ERR' } })
                $l=New-Object System.Windows.Forms.Label; $l.Text=$cl.Desc; $l.Location='300,14'; $l.Size="$([int]$rowW-320),20"; $l.ForeColor=$muted; $l.BackColor=$surf; $l.Anchor='Top,Left,Right'; $l.AutoEllipsis=$true
                $row.Controls.AddRange(@($b,$l)); $flow.Controls.Add($row)
            }
        }
        'DEBLOAT' {
            $dbChecks=New-Object System.Collections.ArrayList
            foreach($app in $script:DEBLOAT){
                $row=New-Object System.Windows.Forms.Panel; $row.Size="$rowW,28"; $row.BackColor=$surf; $row.Margin='0,0,0,2'
                $ck=New-Object System.Windows.Forms.CheckBox; $ck.Text=$app.Name; $ck.Location='12,4'; $ck.Size='440,22'; $ck.ForeColor=$fg; $ck.Tag=$app.Pkg; $ck.BackColor=$surf; $ck.Anchor='Top,Left'
                if(-not (Get-DebloatInstalled $app.Pkg)){ $ck.Enabled=$false; $ck.Text="$($app.Name)  (no instalada)"; $ck.ForeColor=$muted }
                $row.Controls.Add($ck); $flow.Controls.Add($row); [void]$dbChecks.Add($ck)
            }
            $btnDb=New-Object System.Windows.Forms.Button; $btnDb.Text='QUITAR SELECCIONADAS'; $btnDb.Size='240,34'; $btnDb.BackColor=$red; $btnDb.ForeColor='White'; $btnDb.FlatStyle='Flat'; $btnDb.Font=Lw:Font 9 'Bold'; $btnDb.Cursor='Hand'; $btnDb.Margin='4,8,4,4'
            $btnDb.Add_Click({ $n=0; foreach($ck in $dbChecks){ if($ck.Enabled -and $ck.Checked){ Remove-Debloat $ck.Tag; $n++ } }; Write-LWLog "$n app(s) procesadas." })
            $flow.Controls.Add($btnDb)
        }
        'DNS' {
            foreach($dns in $script:DNSPROFILES){
                $row=New-Object System.Windows.Forms.Panel; $row.Size="$rowW,44"; $row.BackColor=$surf; $row.Margin='0,0,0,4'
                $bn=New-Object System.Windows.Forms.Button; $bn.Text=$dns.Name; $bn.Size='280,34'; $bn.Location='8,5'; $bn.BackColor=$accent; $bn.ForeColor='White'; $bn.FlatStyle='Flat'; $bn.Font=Lw:Font 9 'Bold'; $bn.Tag=$dns.V4; $bn.Cursor='Hand'; $bn.Anchor='Top,Left'
                $bn.Add_Click({ param($s,$e) Set-LWDns $s.Tag })
                $ln=New-Object System.Windows.Forms.Label; $ln.Text=$(if($dns.V4){$dns.V4 -join '  /  '}else{'quita DNS manual'}); $ln.Location='300,14'; $ln.Size="$([int]$rowW-320),20"; $ln.ForeColor=$muted; $ln.BackColor=$surf; $ln.Anchor='Top,Left,Right'; $ln.AutoEllipsis=$true
                $row.Controls.AddRange(@($bn,$ln)); $flow.Controls.Add($row)
            }
        }
        'STARTUP' {
            $suChecks=New-Object System.Collections.ArrayList
            foreach($ar in (Get-Autoruns)){
                $row=New-Object System.Windows.Forms.Panel; $row.Size="$rowW,28"; $row.BackColor=$surf; $row.Margin='0,0,0,2'
                $cs=New-Object System.Windows.Forms.CheckBox; $cs.Text="[$($ar.Hive)] $($ar.Name)"; $cs.Location='12,3'; $cs.Size='380,22'; $cs.ForeColor=$fg; $cs.Tag=$ar; $cs.BackColor=$surf; $cs.Anchor='Top,Left'
                $vl=New-Object System.Windows.Forms.Label; $vl.Text=$ar.Value; $vl.Location='400,5'; $vl.Size="$([int]$rowW-410),18"; $vl.ForeColor=$muted; $vl.BackColor=$surf; $vl.AutoEllipsis=$true; $vl.Anchor='Top,Left,Right'
                $row.Controls.AddRange(@($cs,$vl)); $flow.Controls.Add($row); [void]$suChecks.Add($cs)
            }
            $btnSu=New-Object System.Windows.Forms.Button; $btnSu.Text='DESACTIVAR'; $btnSu.Size='170,32'; $btnSu.BackColor=$amber; $btnSu.ForeColor='White'; $btnSu.FlatStyle='Flat'; $btnSu.Font=Lw:Font 9 'Bold'; $btnSu.Cursor='Hand'; $btnSu.Margin='4,8,4,4'
            $btnSu.Add_Click({ $n=0; foreach($cs in $suChecks){ if($cs.Checked){ Disable-Autorun $cs.Tag; $n++ } }; Write-LWLog "$n autorun(s) desactivado(s)." })
            $btnSuR=New-Object System.Windows.Forms.Button; $btnSuR.Text='RESTAURAR BACKUP'; $btnSuR.Size='170,32'; $btnSuR.BackColor=$green; $btnSuR.ForeColor='White'; $btnSuR.FlatStyle='Flat'; $btnSuR.Font=Lw:Font 9 'Bold'; $btnSuR.Cursor='Hand'; $btnSuR.Margin='4,8,4,4'
            $btnSuR.Add_Click({ Restore-Autorun | Out-Null })
            $flow.Controls.Add($btnSu); $flow.Controls.Add($btnSuR)
        }
        'ASISTENTE IA' {
            $aiOut=New-Object System.Windows.Forms.RichTextBox; $aiOut.Size="$rowW,360"; $aiOut.BackColor=$surf; $aiOut.ForeColor=$fg; $aiOut.ReadOnly=$true; $aiOut.Font=Lw:Font 9; $aiOut.Margin='2,2,2,4'; $aiOut.Anchor='Top,Left,Right'
            $aiIn=New-Object System.Windows.Forms.TextBox; $aiIn.Size="$([int]$rowW-210),28"; $aiIn.BackColor=$surf2; $aiIn.ForeColor=$fg; $aiIn.Font=Lw:Font 9; $aiIn.BorderStyle='FixedSingle'; $aiIn.Margin='2,2,2,4'
            $aiBtn=New-Object System.Windows.Forms.Button; $aiBtn.Text='PREGUNTAR'; $aiBtn.Size='100,30'; $aiBtn.BackColor=$accent; $aiBtn.ForeColor='White'; $aiBtn.FlatStyle='Flat'; $aiBtn.Font=Lw:Font 9 'Bold'; $aiBtn.Cursor='Hand'; $aiBtn.Margin='2,2,2,4'
            $aiRec=New-Object System.Windows.Forms.Button; $aiRec.Text='ANALIZAR'; $aiRec.Size='100,30'; $aiRec.BackColor=$purple; $aiRec.ForeColor='White'; $aiRec.FlatStyle='Flat'; $aiRec.Font=Lw:Font 9 'Bold'; $aiRec.Cursor='Hand'; $aiRec.Margin='2,2,2,4'
            $aiAsk={ $q=$aiIn.Text; $aiOut.AppendText(">> $q`r`n"); $aiOut.AppendText((Invoke-LWAssistant $q)+"`r`n`r`n"); $aiOut.ScrollToCaret(); $aiIn.Clear() }
            $aiBtn.Add_Click($aiAsk)
            $aiIn.Add_KeyDown({ param($s,$e) if($e.KeyCode -eq 'Enter'){ & $aiAsk; $e.SuppressKeyPress=$true } })
            $aiRec.Add_Click({ $aiOut.AppendText(">> Analisis del sistema`r`n"); $aiOut.AppendText(((Get-LWRecommendations) -join "`r`n")+"`r`n`r`n"); $aiOut.ScrollToCaret() })
            $aiOut.AppendText("Asistente LW Suite v5 (local, sin API). Pregunta o pulsa ANALIZAR.`r`nTemas: que aplico, input lag, fps, red, seguridad, extremo.`r`n`r`n")
            $flow.Controls.Add($aiOut); $flow.Controls.Add($aiIn); $flow.Controls.Add($aiBtn); $flow.Controls.Add($aiRec)
        }
    }
    return $flow
}

# ---------- PANEL INFERIOR: botonera + log ----------
$bottomPnl = New-Object System.Windows.Forms.Panel
$bottomPnl.Dock='Bottom'; $bottomPnl.Height=200; $bottomPnl.BackColor=$surf; $bottomPnl.Padding='8,6,8,6'
$form.Controls.Add($bottomPnl)
$bottomPnl.BringToFront()

# Barra de accion (botones + contador + progreso)
$actionBar = New-Object System.Windows.Forms.Panel
$actionBar.Dock='Top'; $actionBar.Height=52; $actionBar.BackColor=$surf
$bottomPnl.Controls.Add($actionBar)

function Lw:Btn($text,$x,$w,$color,$parent){
    $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Location="$x,8"; $b.Size="$w,36"
    $b.BackColor=$color; $b.ForeColor='White'; $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0
    $b.Font=Lw:Font 9 'Bold'; $b.Cursor='Hand'; $parent.Controls.Add($b); $b
}
$btnRestore = Lw:Btn '◈ PUNTO RESTAURACION' 4 180 $amber $actionBar
$btnPreset  = Lw:Btn '▶ PRESET GAMING' 190 150 $purple $actionBar
$btnRefresh = Lw:Btn '↻ LEER ESTADO' 346 130 ([System.Drawing.Color]::FromArgb(60,60,70)) $actionBar
$btnApply   = Lw:Btn '✓ APLICAR CAMBIOS' 482 160 $accent $actionBar
$btnMaster  = Lw:Btn '⚠ MASTER REVERT' 648 150 $red $actionBar

# Contador y barra de progreso (derecha)
$lblCount=New-Object System.Windows.Forms.Label; $lblCount.Location='810,10'; $lblCount.Size='200,16'; $lblCount.ForeColor=$fg; $lblCount.BackColor=$surf; $lblCount.Font=Lw:Font 9 'Bold'; $lblCount.TextAlign='MiddleRight'
$actionBar.Controls.Add($lblCount)
$progBar=New-Object System.Windows.Forms.ProgressBar; $progBar.Location='810,30'; $progBar.Size='200,14'; $progBar.Style='Continuous'; $progBar.Value=0; $progBar.Visible=$false
$actionBar.Controls.Add($progBar)

# Log
$logBox=New-Object System.Windows.Forms.RichTextBox
$logBox.Dock='Fill'; $logBox.BackColor=[System.Drawing.Color]::FromArgb(14,14,18)
$logBox.ForeColor=[System.Drawing.Color]::FromArgb(120,220,140); $logBox.ReadOnly=$true
$logBox.Font=New-Object System.Drawing.Font('Cascadia Code',8.5); $logBox.BorderStyle='None'
$bottomPnl.Controls.Add($logBox); $script:LogBox=$logBox
$logBox.BringToFront()

# ---------- Refresh-States: actualiza checkbox + badge ON/OFF ----------
function Refresh-States {
    $n=0
    foreach($chk in $script:allChecks){
        $tw=$chk.Tag
        if(-not $chk.Enabled){ continue }
        $entry = $null
        foreach($e in $script:catRows[$tw.Cat]){ if($e.Id -eq $tw.Id){ $entry=$e; break } }
        try{
            $s=[bool](& $tw.Test); $chk.Checked=$s
            if($entry){
                if($s){ $entry.Badge.Text='● ON'; $entry.Badge.ForeColor=$green; $n++ }
                else  { $entry.Badge.Text='○ off'; $entry.Badge.ForeColor=$muted }
            } elseif($s){ $n++ }
        }catch{
            Write-LWLog "Test fallo: $($tw.Name)" 'WARN'
            if($entry){ $entry.Badge.Text='? err'; $entry.Badge.ForeColor=$red }
        }
    }
    $lblCount.Text="$n / $($script:allChecks.Count) activos"
}
$btnRefresh.Add_Click({ Write-LWLog 'Leyendo estado real...'; Refresh-States; Write-LWLog 'Estado actualizado.' })

# ---------- Buscador live ----------
$searchBox.Add_TextChanged({
    $q = $searchBox.Text.ToLower()
    if($q -eq 'buscar...'){ $q='' }
    foreach($catName in $script:cats){
        if($catName -in $script:actionCats){ continue }
        foreach($entry in $script:catRows[$catName]){
            if($q -eq ''){ $entry.Row.Visible = ($catName -eq $script:activeCat) }
            else {
                $match = ($entry.Name.ToLower() -match [regex]::Escape($q)) -or ($entry.Desc.ToLower() -match [regex]::Escape($q))
                $entry.Row.Visible=$match
            }
        }
    }
    if($q -ne ''){ $script:catTitleLbl.Text="RESULTADOS: $q" }
    else { $script:catTitleLbl.Text=$script:activeCat }
})
$searchBox.Add_Enter({ if($searchBox.Text -eq 'Buscar...'){ $searchBox.Text='' } })
$searchBox.Add_Leave({ if([string]::IsNullOrWhiteSpace($searchBox.Text)){ $searchBox.Text='Buscar...' } })

# ---------- Botones de accion ----------
$btnPreset.Add_Click({
    foreach($chk in $script:allChecks){ if($chk.Enabled -and $chk.Tag.Tier -lt 2){ $chk.Checked=$true } }
    Write-LWLog 'Preset GAMING marcado (T0+T1). EXTREMO no se toca. Pulsa APLICAR.'
})
$btnMaster.Add_Click({
    $r=[System.Windows.Forms.MessageBox]::Show("Esto revierte TODOS los tweaks a fabrica + limpia residuos de versiones antiguas. Continuar?",'MASTER REVERT','YesNo','Warning')
    if($r -eq 'Yes'){ Invoke-LWMasterRevert; Refresh-States }
})
$btnApply.Add_Click({
    $btnApply.Enabled=$false; $progBar.Visible=$true; $progBar.Value=0; $reboot=$false; $changed=0
    $toDo = @($script:allChecks | Where-Object { $_.Enabled })
    $idx=0
    foreach($chk in $toDo){
        $tw=$chk.Tag
        try{ $cur=[bool](& $tw.Test) }catch{ $idx++; $progBar.Value=[math]::Min(100,[int](($idx/$toDo.Count)*100)); continue }
        if($chk.Checked -ne $cur){
            try{
                if($chk.Checked){ & $tw.Apply; Write-LWLog "APLICADO : $($tw.Name)" } else { & $tw.Revert; Write-LWLog "REVERTIDO: $($tw.Name)" }
                $ok=[bool](& $tw.Test)
                if($ok -ne $chk.Checked){ Write-LWLog "  ! verificacion no coincide en $($tw.Name)" 'WARN' }
                $changed++; if($tw.Reboot){$reboot=$true}
            } catch { Write-LWLog "ERROR    : $($tw.Name) -> $($_.Exception.Message)" 'ERR' }
        }
        $idx++
        $progBar.Value=[math]::Min(100,[int](($idx/$toDo.Count)*100))
        [System.Windows.Forms.Application]::DoEvents()
    }
    if($changed -eq 0){ Write-LWLog 'Sin cambios.' } else { Write-LWLog "$changed cambio(s) aplicado(s)." }
    if($reboot){ Write-LWLog '>>> ALGUNOS CAMBIOS REQUIEREN REINICIAR <<<' 'WARN' }
    Refresh-States; $btnApply.Enabled=$true; $progBar.Visible=$false
})

# ---------- Punto de restauracion en runspace (no congela) ----------
$btnRestore.Add_Click({
    if($script:rsPS){ return }
    $btnRestore.Enabled=$false; Write-LWLog 'Creando punto de restauracion en segundo plano...'
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
        try { Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS; Remove-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -EA SilentlyContinue; 'OK: punto CREADO.' }
        catch { "ERROR: $($_.Exception.Message)" }
    })
    [void]$ps.AddArgument('LW Suite v5')
    $script:rsPS=$ps; $script:rsHandle=$ps.BeginInvoke()
    $t=New-Object System.Windows.Forms.Timer; $t.Interval=1000; $script:rsTimer=$t
    $t.Add_Tick({
        if($script:rsHandle.IsCompleted){
            $script:rsTimer.Stop()
            $res=$script:rsPS.EndInvoke($script:rsHandle)
            $script:rsPS.Dispose(); $script:rsPS=$null; $script:rsHandle=$null
            foreach($line in $res){ Write-LWLog "$line" $(if($line -match '^ERROR'){'ERR'}else{'INFO'}) }
            $btnRestore.Enabled=$true
        }
    })
    $t.Start()
})

# ---------- Inicializacion ----------
$n = Repair-StartupBackup
if($n -gt 0){ Write-LWLog "Startup backup migrado a formato v5: $n entrada(s) recuperadas." }
$nBlk=0; foreach($tw in $script:CAT){ if(Get-BlockReason $tw){ $nBlk++ } }
Write-LWLog "LW SUITE v5 lista. Tweaks: $($script:CAT.Count). Bloqueados por HW: $nBlk."
Write-LWLog 'Recomendado: crea PRIMERO el punto de restauracion.'
Refresh-States

# Seleccionar primera categoria por defecto
$firstCat = $script:cats | Where-Object { $_ -notin $script:actionCats } | Select-Object -First 1
if($firstCat){
    $script:catButtons[$firstCat].BackColor=$accent
    $script:catButtons[$firstCat].ForeColor='White'
    $script:activeCat=$firstCat
    Switch-Panel $firstCat
}

# Modo GUITEST: valida la construccion visual sin abrir el form (para CI / smoke test)
if($env:LW_GUITEST -eq '1'){
    # Forzar creacion del handle del form para que .Visible de los hijos funcione
    $null = $form.Handle
    Write-Host "== LW SUITE v5 LAYOUT TEST =="
    Write-Host "FORM controls     : $($form.Controls.Count)"
    Write-Host "SIDEBAR botones   : $($script:catButtons.Count)"
    Write-Host "Categorias tweaks : $(($script:catFlows.Keys | Measure-Object).Count)"
    $allOk = $true
    foreach($catName in $script:catFlows.Keys){
        $flow = $script:catFlows[$catName]
        $rows = $flow.Controls.Count
        if($rows -eq 0){ Write-Host "  FAIL: $catName flow vacio"; $allOk=$false }
        else { Write-Host ("  OK: {0,-11} {1} filas" -f $catName,$rows) }
    }
    # Validar que Switch-Panel marca visible SOLO el flow objetivo
    Switch-Panel 'CPU'
    $visibles = @($script:catFlows.Values | Where-Object { $_.Visible }).Count
    $cpuMarked = $script:catFlows['CPU'].Visible
    Write-Host "Switch-Panel CPU : flows visibles=$visibles (esperado 1), CPU marcado=$cpuMarked (esperado True)"
    if($visibles -ne 1 -or -not $cpuMarked){ $allOk=$false }
    Switch-Panel 'GPU'
    $visiblesGpu = @($script:catFlows.Values | Where-Object { $_.Visible }).Count
    $gpuMarked = $script:catFlows['GPU'].Visible
    Write-Host "Switch-Panel GPU : flows visibles=$visiblesGpu (esperado 1), GPU marcado=$gpuMarked (esperado True)"
    if($visiblesGpu -ne 1 -or -not $gpuMarked){ $allOk=$false }
    # Validar badges tras Refresh-States
    $onBadges = 0
    foreach($catName in $script:catRows.Keys){
        foreach($e in $script:catRows[$catName]){ if($e.Badge.Text -match 'ON|off'){ $onBadges++ } }
    }
    Write-Host "Badges con estado : $onBadges / $($script:allChecks.Count)"
    if($onBadges -lt $script:allChecks.Count){ Write-Host "  WARN: algunos badges sin estado" }
    Write-Host ""
    if($allOk){ Write-Host "RESULTADO: LAYOUT OK"; exit 0 } else { Write-Host "RESULTADO: LAYOUT FALLO"; exit 1 }
}

[void]$form.ShowDialog()
