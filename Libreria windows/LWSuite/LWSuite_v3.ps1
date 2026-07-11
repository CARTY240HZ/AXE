# =====================================================
# LW SUITE v3 - Elite Windows Optimizer (hardware-aware)
# Motor de catalogo + GUI + perfiles + tier EXTREMO opt-in.
# Cada tweak: Id/Cat/Tier/Requires/Test/Apply/Revert/Verify.
# Gating por hardware: un tweak que dana en TU PC sale bloqueado.
# Requiere admin (usa LWSuite.bat, se eleva solo).
# =====================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    [System.Windows.Forms.MessageBox]::Show("Ejecuta 'LWSuite.bat' (se eleva solo).","Admin requerido",'OK','Warning') | Out-Null
    exit 1
}

$LWRoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$LWData   = Join-Path $LWRoot 'LWSuite'
$LWBackup = Join-Path $LWData 'Backups'
$LWLog    = Join-Path $LWData ("lw_log_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
foreach($d in @($LWData,$LWBackup)){ if(-not(Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# ---------- Log a fichero + a GUI ----------
$script:LogBox = $null
function Write-LWLog {
    param([string]$Msg,[string]$Level='INFO')
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Msg
    Add-Content -Path $LWLog -Value $line -Encoding UTF8
    if($script:LogBox){ $script:LogBox.AppendText("$line`r`n"); $script:LogBox.ScrollToCaret() }
}

# =====================================================
# DETECCION DE HARDWARE  (define que tweaks son validos)
# =====================================================
function Get-LWHardware {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os  = Get-CimInstance Win32_OperatingSystem
    $enc = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes
    $isLaptop = @($enc | Where-Object { $_ -in 8,9,10,11,12,14,18,21,30,31,32 }).Count -gt 0
    $isHybrid = $false
    try {
        if($cpu.Name -match '1[2-9]th Gen' -or $cpu.Name -match 'Ultra'){ $isHybrid = $true }
    } catch {}
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Virtual|Basic|Meta|Parsec|Remote' }
    $hasNvidia = @($gpu | Where-Object Name -match 'NVIDIA').Count -gt 0
    $hasOptimus = @($gpu).Count -ge 2 -and $hasNvidia
    $activeNic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1
    $isWifi = $activeNic.PhysicalMediaType -match 'Native 802.11|Wireless' -or $activeNic.Name -match 'Wi-?Fi|Wireless'
    $edition = $os.Caption
    $onBattery = $false
    try { $b = Get-CimInstance Win32_Battery; if($b -and $b.BatteryStatus -ne 2){ $onBattery = $true } } catch {}
    [pscustomobject]@{
        CpuName=$cpu.Name; Cores=$cpu.NumberOfCores; Threads=$cpu.NumberOfLogicalProcessors
        IsLaptop=$isLaptop; IsHybrid=$isHybrid; HasNvidia=$hasNvidia; HasOptimus=$hasOptimus
        IsWifi=[bool]$isWifi; NicName=$activeNic.Name; Edition=$edition
        IsHome=($edition -match 'Home'); OnBattery=$onBattery; RamGB=[math]::Round($os.TotalVisibleMemorySize/1MB,1)
    }
}
$HW = Get-LWHardware

# ---------- Helpers registro / servicio ----------
function Get-RV($p,$n){ try{(Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n}catch{$null} }
function Set-RD($p,$n,$v){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType DWord -Force|Out-Null }
function Set-RS($p,$n,$v){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType String -Force|Out-Null }
function Del-RV($p,$n){ Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue }
function Test-Svc($n){ [bool](Get-Service $n -ErrorAction SilentlyContinue) }
function Get-SvcStart($n){ try{(Get-Service $n -ErrorAction Stop).StartType}catch{$null} }
function Set-SvcStart($n,$m){                      # verifica exito real (arregla hallazgo #5 del audit)
    if(-not(Test-Svc $n)){ Write-LWLog "Servicio '$n' no existe en este SKU, omitido" 'WARN'; return }
    & sc.exe config $n start= $m | Out-Null
    if($LASTEXITCODE -ne 0){ throw "sc config $n start=$m fallo (code $LASTEXITCODE)" }
}
# Backup .reg NO destructivo: solo primera vez (arregla hallazgo #1 del audit)
function Backup-RegKey($hive,$file){
    $dest = Join-Path $LWBackup $file
    if(Test-Path $dest){ return }
    & reg.exe export $hive $dest /y *>$null
    if($LASTEXITCODE -eq 0){ Write-LWLog "Backup: $file" }
}

# =====================================================
# CATALOGO DE TWEAKS
# Tier: 0=Seguro 1=Elite 2=EXTREMO(opt-in, degrada seguridad)
# Requires: condiciones HW. Si falla -> BLOQUEADO con motivo.
# =====================================================
$PC  = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
$SP  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$GD  = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$MM  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$Games = "$SP\Tasks\Games"

$CAT = New-Object System.Collections.ArrayList
function Add-Tweak($h){ [void]$CAT.Add([pscustomobject]$h) }

# --- CPU / SCHEDULER (Tier 1) ---
Add-Tweak @{Id='cpu_prio';Cat='CPU';Tier=1;Reboot=$false;Name='Prioridad ventana activa (0x28)';Desc='Foreground boost, menos input lag';Requires=@{};
 Test={(Get-RV $PC 'Win32PrioritySeparation') -eq 40};Apply={Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl' 'PriorityControl.reg';Set-RD $PC 'Win32PrioritySeparation' 40};Revert={Set-RD $PC 'Win32PrioritySeparation' 2}}
Add-Tweak @{Id='cpu_mmcss';Cat='CPU';Tier=1;Reboot=$false;Name='Liberar CPU multimedia';Desc='SystemResponsiveness=0';Requires=@{};
 Test={(Get-RV $SP 'SystemResponsiveness') -eq 0};Apply={Set-RD $SP 'SystemResponsiveness' 0};Revert={Set-RD $SP 'SystemResponsiveness' 20}}
Add-Tweak @{Id='cpu_pthr';Cat='CPU';Tier=1;Reboot=$false;Name='Power Throttling OFF';Desc='Sin limite de frecuencia (solo con AC)';Requires=@{AC=$true};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff') -eq 1};Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1};Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'}}
Add-Tweak @{Id='cpu_park';Cat='CPU';Tier=1;Reboot=$false;Name='Core Parking OFF';Desc='Nucleos siempre activos';Requires=@{Desktop=$true;NotHybrid=$true};
 Test={ $g=((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActivePowerScheme') -replace '[{}]',''); (Get-RV "HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$g\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583" 'ACSettingIndex') -eq 100 };
 Apply={powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100; powercfg -setactive scheme_current};Revert={powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 0; powercfg -setactive scheme_current}}

# --- LATENCIA / INPUT LAG (Tier 1) ---
Add-Tweak @{Id='lat_hdaudio_msi';Cat='LATENCIA';Tier=1;Reboot=$true;Name='MSI mode en HD Audio';Desc='Baja DPC latency del audio (medible LatencyMon)';Requires=@{};
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

# --- GPU (Tier 1) ---
Add-Tweak @{Id='gpu_hags';Cat='GPU';Tier=1;Reboot=$true;Name='HAGS (scheduling por hardware)';Desc='GPU gestiona su cola, menos latencia';Requires=@{};
 Test={(Get-RV $GD 'HwSchMode') -eq 2};Apply={Backup-RegKey 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'GraphicsDrivers.reg';Set-RD $GD 'HwSchMode' 2};Revert={Del-RV $GD 'HwSchMode'}}
Add-Tweak @{Id='gpu_mmcss';Cat='GPU';Tier=1;Reboot=$false;Name='Prioridad MMCSS juegos';Desc='GPU Priority 8 / Priority 6 / High';Requires=@{};
 Test={((Get-RV $Games 'GPU Priority') -eq 8) -and ((Get-RV $Games 'Priority') -eq 6) -and ((Get-RV $Games 'Scheduling Category') -eq 'High')};
 Apply={Set-RD $Games 'GPU Priority' 8;Set-RD $Games 'Priority' 6;Set-RS $Games 'Scheduling Category' 'High';Set-RS $Games 'SFIO Priority' 'High';Set-RS $Games 'Background Only' 'False'};
 Revert={Set-RD $Games 'GPU Priority' 8;Set-RD $Games 'Priority' 2;Del-RV $Games 'Scheduling Category';Del-RV $Games 'SFIO Priority';Del-RV $Games 'Background Only'}}

# --- RED (Tier 1) ---
Add-Tweak @{Id='net_throttle';Cat='RED';Tier=1;Reboot=$false;Name='Network Throttling OFF';Desc='Sin limite de paquetes con multimedia';Requires=@{};
 Test={(Get-RV $SP 'NetworkThrottlingIndex') -eq 4294967295};Apply={Set-RD $SP 'NetworkThrottlingIndex' 4294967295};Revert={Del-RV $SP 'NetworkThrottlingIndex'}}
Add-Tweak @{Id='net_nagle';Cat='RED';Tier=1;Reboot=$false;Name='Nagle OFF (adaptador activo)';Desc='Menos delay en paquetes pequenos. Wi-Fi: ganancia baja';Requires=@{};
 Test={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -EA SilentlyContinue; $any=$false; foreach($i in $ifs){ $p=Get-ItemProperty $i.PSPath -EA SilentlyContinue; if($p.DhcpIPAddress -or $p.IPAddress){ if((Get-RV $i.PSPath 'TcpAckFrequency') -eq 1 -and (Get-RV $i.PSPath 'TCPNoDelay') -eq 1){$any=$true} } }; $any };
 Apply={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'; foreach($i in $ifs){ $p=Get-ItemProperty $i.PSPath -EA SilentlyContinue; if($p.DhcpIPAddress -or $p.IPAddress){ Set-RD $i.PSPath 'TcpAckFrequency' 1; Set-RD $i.PSPath 'TCPNoDelay' 1 } } };
 Revert={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'; foreach($i in $ifs){ Del-RV $i.PSPath 'TcpAckFrequency'; Del-RV $i.PSPath 'TCPNoDelay' } }}
Add-Tweak @{Id='net_rss';Cat='RED';Tier=1;Reboot=$false;Name='RSS activado';Desc='Reparte trafico de red entre nucleos';Requires=@{};
 Test={try{(Get-NetOffloadGlobalSetting).ReceiveSideScaling -eq 'Enabled'}catch{$false}};Apply={netsh interface tcp set global rss=enabled | Out-Null};Revert={netsh interface tcp set global rss=default | Out-Null}}

# --- SISTEMA (Tier 0/1) ---
Add-Tweak @{Id='sys_gamedvr';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Game DVR OFF';Desc='Sin grabacion de fondo = mas FPS';Requires=@{};
 Test={(Get-RV 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled') -eq 0};
 Apply={Set-RD 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0; Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0};
 Revert={Set-RD 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 1; Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR'}}
Add-Tweak @{Id='sys_hibernate';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Hibernacion OFF';Desc='Libera hiberfil.sys (portatil pierde hibernar)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled') -eq 0};Apply={powercfg /h off};Revert={powercfg /h on}}
Add-Tweak @{Id='sys_do';Cat='SISTEMA';Tier=0;Reboot=$false;Name='Delivery Optimization P2P OFF';Desc='No compartes updates con otros PCs (clave de politica correcta)';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode') -eq 0};
 Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode'}}

# --- SERVICIOS (Tier 0) ---
Add-Tweak @{Id='svc_telemetry';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='Telemetria OFF';Desc='DiagTrack, dmwappushservice';Requires=@{};
 Test={(Get-SvcStart 'DiagTrack') -eq 'Disabled'};Apply={Set-SvcStart 'DiagTrack' 'disabled'; Set-SvcStart 'dmwappushservice' 'disabled'};Revert={Set-SvcStart 'DiagTrack' 'auto'; Set-SvcStart 'dmwappushservice' 'demand'}}
Add-Tweak @{Id='svc_hotspot';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='Hotspot (icssvc) a demanda';Desc='Corriendo sin uso -> demand';Requires=@{};
 Test={(Get-SvcStart 'icssvc') -eq 'Manual'};Apply={Set-SvcStart 'icssvc' 'demand'};Revert={Set-SvcStart 'icssvc' 'demand'}}

# --- PRIVACIDAD (Tier 0) ---
Add-Tweak @{Id='priv_ads';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Anuncios personalizados OFF';Desc='Sin ID de publicidad';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled') -eq 0};
 Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0};Revert={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 1}}
Add-Tweak @{Id='priv_recall';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Recall OFF';Desc='Bloquea la IA que captura tu pantalla';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement') -eq 0};
 Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement'}}
Add-Tweak @{Id='priv_appraiser';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Compatibility Appraiser OFF';Desc='Sin analisis de compatibilidad de fondo (nombre de tarea real)';Requires=@{};
 Test={ $t=Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -EA SilentlyContinue | Where-Object TaskName -match 'Compatibility Appraiser'; if(-not $t){return $true}; @($t | Where-Object State -ne 'Disabled').Count -eq 0 };
 Apply={ Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -EA SilentlyContinue | Where-Object TaskName -match 'Compatibility Appraiser' | Disable-ScheduledTask -EA SilentlyContinue | Out-Null };
 Revert={ Get-ScheduledTask -TaskPath '\Microsoft\Windows\Application Experience\' -EA SilentlyContinue | Where-Object TaskName -match 'Compatibility Appraiser' | Enable-ScheduledTask -EA SilentlyContinue | Out-Null }}

# --- EXTREMO (Tier 2, opt-in, degrada seguridad) ---
Add-Tweak @{Id='ext_vbs';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Aislamiento de Nucleo / Memory Integrity OFF';Desc='Core Isolation OFF: +15-25% en 1% low, quita stutter. Coste ~5% avg FPS y seguridad kernel';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled') -eq 0 -and (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity') -eq 0};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0};
 Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled'; Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity'}}
Add-Tweak @{Id='ext_mitig';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Mitigaciones Spectre/Meltdown OFF';Desc='PIERDES proteccion CVE-2017-5715/5754. Ganancia CPU en gen antiguas';Requires=@{};
 Test={(Get-RV $MM 'FeatureSettingsOverride') -eq 3};
 Apply={Set-RD $MM 'FeatureSettingsOverride' 3; Set-RD $MM 'FeatureSettingsOverrideMask' 3};Revert={Del-RV $MM 'FeatureSettingsOverride'; Del-RV $MM 'FeatureSettingsOverrideMask'}}
Add-Tweak @{Id='ext_hyperv';Cat='EXTREMO';Tier=2;Reboot=$true;Name='Hypervisor OFF';Desc='ROMPE WSL2/Docker/sandbox. Apaga VBS entero';Requires=@{};
 Test={ ((bcdedit /enum '{current}' | Out-String) -match 'hypervisorlaunchtype\s+Off') };
 Apply={ bcdedit /set hypervisorlaunchtype off | Out-Null };Revert={ bcdedit /set hypervisorlaunchtype auto | Out-Null }}

# --- CPU EXTRA (Tier 1, reboot via BCD) ---
Add-Tweak @{Id='cpu_dyntick';Cat='CPU';Tier=1;Reboot=$true;Name='Dynamic Tick OFF';Desc='Timer constante, menos jitter (REINICIO)';Requires=@{};
 Test={ ((bcdedit /enum '{current}' | Out-String) -match 'disabledynamictick\s+Yes') };Apply={ bcdedit /set disabledynamictick yes | Out-Null };Revert={ bcdedit /deletevalue disabledynamictick | Out-Null }}
Add-Tweak @{Id='cpu_tsc';Cat='CPU';Tier=1;Reboot=$true;Name='TSC Sync Enhanced';Desc='Sincroniza contador de tiempo entre nucleos (REINICIO)';Requires=@{};
 Test={ ((bcdedit /enum '{current}' | Out-String) -match 'tscsyncpolicy\s+Enhanced') };Apply={ bcdedit /set tscsyncpolicy Enhanced | Out-Null };Revert={ bcdedit /deletevalue tscsyncpolicy | Out-Null }}

# --- LATENCIA EXTRA (Tier 1) ---
Add-Tweak @{Id='lat_irq_gpu';Cat='LATENCIA';Tier=1;Reboot=$true;Name='IRQ priority alta en GPU';Desc='DevicePriority=3 en la GPU (REINICIO)';Requires=@{};
 Test={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; if(-not $g){return $true}; $ok=$true; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; if((Get-RV $p 'DevicePriority') -ne 3){$ok=$false} }; $ok };
 Apply={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; Set-RD $p 'DevicePriority' 3 } };
 Revert={ $g=Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual' }; foreach($d in $g){ $p="HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\Affinity Policy"; Del-RV $p 'DevicePriority' } }}
Add-Tweak @{Id='lat_hpet_off';Cat='LATENCIA';Tier=1;Reboot=$true;Name='HPET no forzado (correcto)';Desc='Quita useplatformclock: HPET forzado empeora latencia (REINICIO)';Requires=@{};
 Test={ -not ((bcdedit /enum '{current}' | Out-String) -match 'useplatformclock\s+Yes') };Apply={ bcdedit /deletevalue useplatformclock 2>$null | Out-Null; bcdedit /set useplatformtick yes | Out-Null };Revert={ bcdedit /deletevalue useplatformtick 2>$null | Out-Null }}

# --- GPU EXTRA (Tier 1) ---
Add-Tweak @{Id='gpu_ulps';Cat='GPU';Tier=1;Reboot=$true;Name='NVIDIA ULPS OFF';Desc='GPU no entra en bajo consumo profundo (REINICIO)';Requires=@{Nvidia=$true};
 Test={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; $sub=Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' }; if(-not $sub){return $true}; $ok=$true; foreach($s in $sub){ if((Get-RV $s.PSPath 'EnableUlps') -ne 0){$ok=$false} }; $ok };
 Apply={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' } | ForEach-Object { Set-RD $_.PSPath 'EnableUlps' 0 } };
 Revert={ $k='HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'; Get-ChildItem $k -EA SilentlyContinue | Where-Object { (Get-RV $_.PSPath 'DriverDesc') -match 'NVIDIA' } | ForEach-Object { Del-RV $_.PSPath 'EnableUlps' } }}
Add-Tweak @{Id='gpu_tdr';Cat='GPU';Tier=1;Reboot=$true;Name='TDR delay ampliado';Desc='Menos cuelgues de driver bajo carga (REINICIO)';Requires=@{};
 Test={(Get-RV $GD 'TdrDelay') -eq 10};Apply={Set-RD $GD 'TdrDelay' 10};Revert={Del-RV $GD 'TdrDelay'}}

# --- RED EXTRA (Tier 1) ---
Add-Tweak @{Id='net_ecn';Cat='RED';Tier=1;Reboot=$false;Name='ECN OFF';Desc='Evita conflictos con routers viejos';Requires=@{};
 Test={try{(Get-NetTCPSetting -SettingName Internet -EA Stop).EcnCapability -eq 'Disabled'}catch{$false}};Apply={netsh int tcp set global ecncapability=disabled | Out-Null};Revert={netsh int tcp set global ecncapability=default | Out-Null}}
Add-Tweak @{Id='net_autotune';Cat='RED';Tier=1;Reboot=$false;Name='Auto-tuning ventana RX normal';Desc='Rendimiento TCP correcto (no disabled)';Requires=@{};
 Test={try{(Get-NetTCPSetting -SettingName Internet -EA Stop).AutoTuningLevelLocal -eq 'Normal'}catch{$false}};Apply={netsh int tcp set global autotuninglevel=normal | Out-Null};Revert={netsh int tcp set global autotuninglevel=normal | Out-Null}}
Add-Tweak @{Id='net_dns';Cat='RED';Tier=1;Reboot=$false;Name='[OPT] DNS rapidos 1.1.1.1 / 8.8.8.8';Desc='OJO: rompe DNS local/VPN corporativa. No va en preset';Requires=@{};
 Test={ if(-not $HW.NicName){return $false}; try{(Get-DnsClientServerAddress -InterfaceAlias $HW.NicName -AddressFamily IPv4 -EA Stop).ServerAddresses -contains '1.1.1.1'}catch{$false} };
 Apply={ if($HW.NicName){ Set-DnsClientServerAddress -InterfaceAlias $HW.NicName -ServerAddresses @('1.1.1.1','8.8.8.8') } };Revert={ if($HW.NicName){ Set-DnsClientServerAddress -InterfaceAlias $HW.NicName -ResetServerAddresses } }}

# --- MEMORIA (nueva categoria, Tier 1) ---
Add-Tweak @{Id='mem_pagingexec';Cat='MEMORIA';Tier=1;Reboot=$true;Name='Kernel siempre en RAM';Desc='DisablePagingExecutive=1 (necesita RAM holgada) (REINICIO)';Requires=@{};
 Test={(Get-RV $MM 'DisablePagingExecutive') -eq 1};Apply={Set-RD $MM 'DisablePagingExecutive' 1};Revert={Set-RD $MM 'DisablePagingExecutive' 0}}
Add-Tweak @{Id='mem_ntfsmem';Cat='MEMORIA';Tier=1;Reboot=$true;Name='Cache de metadatos NTFS alta';Desc='NtfsMemoryUsage=2, util con mucha RAM (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage') -eq 2};Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage' 2};Revert={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsMemoryUsage'}}
Add-Tweak @{Id='mem_lastaccess';Cat='MEMORIA';Tier=0;Reboot=$false;Name='NTFS last-access OFF';Desc='Menos escrituras de metadatos al leer';Requires=@{};
 Test={ (& fsutil behavior query disablelastaccess) -match 'Disabled|= 1' };Apply={ fsutil behavior set disablelastaccess 1 | Out-Null };Revert={ fsutil behavior set disablelastaccess 0 | Out-Null }}

# --- SISTEMA EXTRA (Tier 0/1) ---
Add-Tweak @{Id='sys_longpaths';Cat='SISTEMA';Tier=0;Reboot=$true;Name='Rutas largas ON';Desc='Soporta rutas >260 caracteres (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled') -eq 1};Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1};Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 0}}
Add-Tweak @{Id='sys_autoend';Cat='SISTEMA';Tier=1;Reboot=$false;Name='AutoEndTasks ON';Desc='Apagado mas rapido con apps colgadas';Requires=@{};
 Test={(Get-RV 'HKCU:\Control Panel\Desktop' 'AutoEndTasks') -eq '1'};Apply={Set-RS 'HKCU:\Control Panel\Desktop' 'AutoEndTasks' '1'};Revert={Del-RV 'HKCU:\Control Panel\Desktop' 'AutoEndTasks'}}
Add-Tweak @{Id='sys_menudelay';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Menus instantaneos';Desc='MenuShowDelay 0 (sin retardo de animacion)';Requires=@{};
 Test={(Get-RV 'HKCU:\Control Panel\Desktop' 'MenuShowDelay') -eq '0'};Apply={Set-RS 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '0'};Revert={Set-RS 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '400'}}
Add-Tweak @{Id='sys_startdelay';Cat='SISTEMA';Tier=1;Reboot=$false;Name='Sin retardo de apps al inicio';Desc='StartupDelayInMSec=0';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec') -eq 0};Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0};Revert={Del-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec'}}
Add-Tweak @{Id='sys_bing';Cat='SISTEMA';Tier=0;Reboot=$false;Name='Busqueda sin Bing';Desc='Menu inicio sin resultados web';Requires=@{};
 Test={(Get-RV 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled') -eq 0};
 Apply={Set-RD 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0};Revert={Del-RV 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled'}}

# --- SERVICIOS EXTRA (Tier 0/1) ---
Add-Tweak @{Id='svc_obsolete';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='Servicios obsoletos OFF';Desc='RetailDemo, MapsBroker, WerSvc (SKU-safe)';Requires=@{};
 Test={(Get-SvcStart 'RetailDemo') -eq 'Disabled'};Apply={'RetailDemo','MapsBroker','WerSvc'|ForEach-Object{Set-SvcStart $_ 'disabled'}};Revert={Set-SvcStart 'RetailDemo' 'demand'; Set-SvcStart 'MapsBroker' 'demand'; Set-SvcStart 'WerSvc' 'demand'}}
Add-Tweak @{Id='svc_sysmain';Cat='SERVICIOS';Tier=1;Reboot=$false;Name='Precarga/diagnostico OFF';Desc='SysMain, PcaSvc, DPS (con SSD, precarga aporta poco)';Requires=@{};
 Test={(Get-SvcStart 'SysMain') -eq 'Disabled'};Apply={'SysMain','PcaSvc','DPS'|ForEach-Object{Set-SvcStart $_ 'disabled'}};Revert={'SysMain','PcaSvc','DPS'|ForEach-Object{Set-SvcStart $_ 'auto'}}}
Add-Tweak @{Id='svc_remotereg';Cat='SERVICIOS';Tier=0;Reboot=$false;Name='RemoteRegistry OFF (seguridad)';Desc='Registro remoto, riesgo si esta activo';Requires=@{};
 Test={(Get-SvcStart 'RemoteRegistry') -eq 'Disabled'};Apply={Set-SvcStart 'RemoteRegistry' 'disabled'};Revert={Set-SvcStart 'RemoteRegistry' 'disabled'}}

# --- PRIVACIDAD EXTRA (Tier 0) ---
Add-Tweak @{Id='priv_activity';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Historial de actividad OFF';Desc='Windows no guarda que programas usas';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities') -eq 0};Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities'}}
Add-Tweak @{Id='priv_tips';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Sugerencias del menu OFF';Desc='Sin recomendaciones en inicio/config';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled') -eq 0};Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0};Revert={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 1}}
Add-Tweak @{Id='priv_diagtask';Cat='PRIVACIDAD';Tier=0;Reboot=$false;Name='Tareas de telemetria OFF';Desc='Desactiva tareas programadas de DiagTrack/CEIP';Requires=@{};
 Test={ $t=Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -EA SilentlyContinue; if(-not $t){return $true}; @($t | Where-Object State -ne 'Disabled').Count -eq 0 };
 Apply={ Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -EA SilentlyContinue | Disable-ScheduledTask -EA SilentlyContinue | Out-Null };
 Revert={ Get-ScheduledTask -TaskPath '\Microsoft\Windows\Customer Experience Improvement Program\' -EA SilentlyContinue | Enable-ScheduledTask -EA SilentlyContinue | Out-Null }}

# --- RENDIMIENTO (nueva categoria, Tier 1) ---
Add-Tweak @{Id='rend_ultimate';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Plan Ultimate Performance';Desc='Plan de energia maximo (solo con cargador)';Requires=@{AC=$true};
 Test={ (powercfg /getactivescheme) -match 'e9a42b02-d5df-448d-aa00-03f14749eb61' };
 Apply={ powercfg -duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 2>$null | Out-Null; powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 };Revert={ powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e }}
Add-Tweak @{Id='rend_gamemode';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Game Mode ON';Desc='Prioriza recursos al juego en primer plano';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled') -eq 1};
 Apply={Set-RD 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1; Set-RD 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1};Revert={Set-RD 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 0}}
Add-Tweak @{Id='rend_visualfx';Cat='RENDIMIENTO';Tier=1;Reboot=$false;Name='Efectos visuales: rendimiento';Desc='Quita animaciones/sombras (UI mas sosa, mas fluida)';Requires=@{};
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting') -eq 2};
 Apply={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2};Revert={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 0}}
Add-Tweak @{Id='rend_mpo';Cat='RENDIMIENTO';Tier=1;Reboot=$true;Name='MPO OFF (arregla stutter/flicker)';Desc='Desactiva Multi-Plane Overlay del DWM (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode') -eq 5};
 Apply={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 5};Revert={Del-RV 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode'}}
Add-Tweak @{Id='rend_prefetch';Cat='RENDIMIENTO';Tier=1;Reboot=$true;Name='Prefetch/Superfetch OFF';Desc='Con SSD la precarga aporta poco (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher') -eq 0};
 Apply={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 0; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 0};
 Revert={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnablePrefetcher' 3; Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters' 'EnableSuperfetch' 3}}

# --- RED EXTRA 2 (Tier 1) ---
Add-Tweak @{Id='net_qos';Cat='RED';Tier=1;Reboot=$true;Name='QoS sin reserva de banda';Desc='NonBestEffortLimit=0: Windows no reserva 20% de red (REINICIO)';Requires=@{};
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit') -eq 0};
 Apply={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit' 0};Revert={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched' 'NonBestEffortLimit'}}
Add-Tweak @{Id='net_delack';Cat='RED';Tier=1;Reboot=$false;Name='Delayed ACK OFF';Desc='TcpDelAckTicks=0: sin espera artificial de ACK';Requires=@{};
 Test={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -EA SilentlyContinue; $any=$false; foreach($i in $ifs){ $p=Get-ItemProperty $i.PSPath -EA SilentlyContinue; if(($p.DhcpIPAddress -or $p.IPAddress) -and (Get-RV $i.PSPath 'TcpDelAckTicks') -eq 0){$any=$true} }; $any };
 Apply={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'; foreach($i in $ifs){ $p=Get-ItemProperty $i.PSPath -EA SilentlyContinue; if($p.DhcpIPAddress -or $p.IPAddress){ Set-RD $i.PSPath 'TcpDelAckTicks' 0 } } };
 Revert={ $ifs=Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'; foreach($i in $ifs){ Del-RV $i.PSPath 'TcpDelAckTicks' } }}
Add-Tweak @{Id='net_lso';Cat='RED';Tier=1;Reboot=$false;Name='Interrupt Moderation NIC OFF';Desc='Menos buffering en el adaptador activo (baja latencia)';Requires=@{};
 Test={ if(-not $HW.NicName){return $true}; try{ $v=(Get-NetAdapterAdvancedProperty -Name $HW.NicName -RegistryKeyword '*InterruptModeration' -EA Stop).RegistryValue; $v -eq 0 }catch{ $true } };
 Apply={ if($HW.NicName){ Set-NetAdapterAdvancedProperty -Name $HW.NicName -RegistryKeyword '*InterruptModeration' -RegistryValue 0 -EA SilentlyContinue } };
 Revert={ if($HW.NicName){ Set-NetAdapterAdvancedProperty -Name $HW.NicName -RegistryKeyword '*InterruptModeration' -RegistryValue 1 -EA SilentlyContinue } }}

# --- GPU EXTRA 2 (Tier 1) ---
Add-Tweak @{Id='gpu_vrr';Cat='GPU';Tier=1;Reboot=$true;Name='Optimizaciones para juegos con ventana';Desc='VRR + optimizaciones de ventana (REINICIO)';Requires=@{};
 Test={(Get-RV $GD 'VRROptimizeEnable') -eq 1};Apply={Set-RD $GD 'VRROptimizeEnable' 1};Revert={Del-RV $GD 'VRROptimizeEnable'}}

# --- ACCIONES DE LIMPIEZA (no son toggles; se ejecutan con boton) ---
$CLEAN = New-Object System.Collections.ArrayList
function Add-Clean($h){ [void]$CLEAN.Add([pscustomobject]$h) }
Add-Clean @{Name='Temporales (usuario + Windows)';Desc='Borra %TEMP% y C:\Windows\Temp';Run={
 $b=[math]::Round((Get-PSDrive C).Free/1GB,2); Remove-Item "$env:TEMP\*" -Recurse -Force -EA SilentlyContinue; Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -EA SilentlyContinue; $a=[math]::Round((Get-PSDrive C).Free/1GB,2); Write-LWLog "Temporales limpios. Libre: $b -> $a GB" }}
Add-Clean @{Name='Cache shaders DirectX';Desc='Se regenera sola; util tras update de driver';Run={ Remove-Item "$env:LOCALAPPDATA\D3DSCache\*" -Recurse -Force -EA SilentlyContinue; Write-LWLog 'Cache shaders DirectX limpiada.' }}
Add-Clean @{Name='Cache Windows Update';Desc='Para wuauserv/bits, borra Download, reinicia';Run={
 Stop-Service wuauserv,bits -Force -EA SilentlyContinue; Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -EA SilentlyContinue; Start-Service bits,wuauserv -EA SilentlyContinue; Write-LWLog 'Cache Windows Update limpiada.' }}
Add-Clean @{Name='Flush DNS';Desc='Vacia cache de resolucion de nombres';Run={ ipconfig /flushdns | Out-Null; Write-LWLog 'Cache DNS vaciada.' }}
Add-Clean @{Name='Purga standby memory (working set)';Desc='Libera RAM en cache de procesos idle';Run={
 $sig='[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);'; $t=Add-Type -MemberDefinition $sig -Name WS -Namespace LW -PassThru; $n=0; Get-Process | ForEach-Object { try{ if($t::EmptyWorkingSet($_.Handle)){$n++} }catch{} }; Write-LWLog "Working set purgado en $n procesos." }}

# =====================================================
# GATING: evaluar Requires contra el hardware real
# Devuelve $null si OK, o el motivo del bloqueo (string)
# =====================================================
function Get-BlockReason($tw){
    $r = $tw.Requires
    if($r.Desktop -and $HW.IsLaptop){ return "portatil: sube termicas, throttlea" }
    if($r.NotHybrid -and $HW.IsHybrid){ return "CPU hibrida P/E: pelea con Thread Director" }
    if($r.AC -and $HW.OnBattery){ return "en bateria: mata autonomia sin ganancia sostenida" }
    if($r.Wired -and $HW.IsWifi){ return "Wi-Fi: ganancia casi nula" }
    if($r.NotHome -and $HW.IsHome){ return "Windows Home: politica ignorada por el SKU" }
    if($r.Nvidia -and -not $HW.HasNvidia){ return "sin GPU NVIDIA: no aplica" }
    return $null
}

# =====================================================
# DEBLOAT: apps UWP seguras de quitar (reinstalables desde Store)
# =====================================================
$DEBLOAT = @(
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

# =====================================================
# DNS: perfiles multi-proveedor sobre el adaptador activo
# =====================================================
$DNSPROFILES = @(
 @{Name='Cloudflare (1.1.1.1)';V4=@('1.1.1.1','1.0.0.1')}
 @{Name='Google (8.8.8.8)';V4=@('8.8.8.8','8.8.4.4')}
 @{Name='AdGuard (bloquea ads)';V4=@('94.140.14.14','94.140.15.15')}
 @{Name='Quad9 (seguridad)';V4=@('9.9.9.9','149.112.112.112')}
 @{Name='Automatico (DHCP)';V4=$null}
)
function Set-LWDns($v4){
    if(-not $HW.NicName){ Write-LWLog 'Sin adaptador activo detectado' 'WARN'; return }
    if($null -eq $v4){ Set-DnsClientServerAddress -InterfaceAlias $HW.NicName -ResetServerAddresses; Write-LWLog "DNS -> automatico (DHCP) en $($HW.NicName)" }
    else { Set-DnsClientServerAddress -InterfaceAlias $HW.NicName -ServerAddresses $v4; Write-LWLog "DNS -> $($v4 -join ', ') en $($HW.NicName)" }
    Clear-DnsClientCache
}

# =====================================================
# STARTUP: autoruns de las claves Run (backup reversible)
# =====================================================
$RunKeys = @{
 'HKCU'  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
 'HKLM'  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
 'WOW64' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
}
$RunBak = Join-Path $LWData 'startup_disabled.json'
function Get-Autoruns {
    $list=New-Object System.Collections.ArrayList
    foreach($k in $RunKeys.Keys){
        $p=$RunKeys[$k]; if(-not(Test-Path $p)){ continue }
        $item=Get-Item $p
        foreach($n in $item.GetValueNames()){ [void]$list.Add([pscustomobject]@{Hive=$k;Path=$p;Name=$n;Value=$item.GetValue($n)}) }
    }
    $list
}
function Disable-Autorun($entry){
    $bak=@(); if(Test-Path $RunBak){ $bak=@(Get-Content $RunBak -Raw | ConvertFrom-Json) }
    $bak += [pscustomobject]@{Hive=$entry.Hive;Path=$entry.Path;Name=$entry.Name;Value=$entry.Value}
    $bak | ConvertTo-Json | Set-Content $RunBak -Encoding UTF8
    Remove-ItemProperty $entry.Path -Name $entry.Name -EA SilentlyContinue
    Write-LWLog "Startup desactivado: $($entry.Name) (backup guardado)"
}

# =====================================================
# ASISTENTE IA LOCAL (sin API): sistema experto state-aware.
# Lee el estado REAL de cada tweak en vivo, no texto enlatado.
# =====================================================
function Get-LWState($tw){
    $blk=Get-BlockReason $tw
    if($blk){ return @{S='BLOCK';T="  [BLOQUEADO] $($tw.Name)  ->  $blk"} }
    try { if([bool](& $tw.Test)){ return @{S='ON';T="  [ON]  $($tw.Name)"} } else { return @{S='OFF';T="  [off] $($tw.Name)  ->  $($tw.Desc)"} } }
    catch { return @{S='ERR';T="  [?]   $($tw.Name)"} }
}
function Report-Cats($cats,$titulo){
    $out=@("== $titulo =="); $off=0; $blk=0
    foreach($tw in $CAT){ if($cats -contains $tw.Cat){ $st=Get-LWState $tw; $out+=$st.T; if($st.S -eq 'OFF'){$off++}; if($st.S -eq 'BLOCK'){$blk++} } }
    if($off -gt 0){ $out+="`n>> $off sin aplicar. Marca esas casillas en la pestana y pulsa APLICAR (o usa PRESET GAMING)." }
    else { $out+="`n>> Todo lo aplicable ya esta ON. Nada que hacer aqui." }
    if($blk -gt 0){ $out+=">> $blk bloqueado(s) por tu hardware: NO los fuerces, danarian este equipo." }
    $out -join "`r`n"
}
function Get-LWRecommendations {
    $r=New-Object System.Collections.ArrayList
    # Seguridad
    $ss=(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled')
    if($ss -eq 'Off' -or (Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen') -eq 0){
        [void]$r.Add('[CRITICO] SmartScreen esta DESACTIVADO. Windows no evalua reputacion de lo que descargas. Reactivalo (Seguridad de Windows > Control de apps).')
    }
    $excl=@((Get-MpPreference -EA SilentlyContinue).ExclusionPath)
    if($excl.Count -gt 0){ [void]$r.Add("[SEGURIDAD] Defender tiene $($excl.Count) exclusion(es) de carpeta. Revisa que ninguna sea un inyector/cheat: $($excl -join '; ')") }
    # Hog de CPU
    try {
        $up=((Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds
        $hog=Get-Process | Where-Object { $_.CPU -gt ($up*0.8) } | Sort-Object CPU -Descending | Select-Object -First 1
        if($hog){ [void]$r.Add("[RENDIMIENTO] '$($hog.Name)' consume mas de 0.8 nucleos continuos. Cerralo antes de jugar; ningun tweak compensa eso.") }
    } catch {}
    # Tweaks del preset sin aplicar
    $pend=0; foreach($tw in $CAT){ if($tw.Tier -lt 2 -and -not (Get-BlockReason $tw)){ try{ if(-not [bool](& $tw.Test)){$pend++} }catch{} } }
    if($pend -gt 0){ [void]$r.Add("[TWEAKS] $pend optimizaciones del preset GAMING aun sin aplicar. Pulsa PRESET GAMING > APLICAR.") }
    # Portatil / bateria
    if($HW.IsLaptop -and $HW.OnBattery){ [void]$r.Add('[ENERGIA] Estas en BATERIA. Los tweaks de energia (Power Throttling) rinden con cargador. Conectalo para maximo rendimiento.') }
    # Punto de restauracion
    [void]$r.Add('[SEGURIDAD] Antes de aplicar, crea un PUNTO DE RESTAURACION (boton naranja).')
    $r
}
function Invoke-LWAssistant($q){
    if([string]::IsNullOrWhiteSpace($q)){ return 'Escribe una pregunta. Ej: "que aplico", "input lag", "seguridad", "fps", "red", "portatil". Respondo leyendo el estado REAL de tu equipo.' }
    $s=$q.ToLower()
    if($s -match 'recom|que aplic|que hago|deber|empez|inicio|todo|optimiz'){ return (Get-LWRecommendations) -join "`r`n" }
    if($s -match 'input|lag(?! online)|raton|mouse|latenc|delay|responsiv'){ return (Report-Cats @('LATENCIA','CPU') 'INPUT LAG / LATENCIA (tu estado real)') }
    if($s -match 'fps|juego|gaming|rendi|frame'){ return (Report-Cats @('GPU','SISTEMA','CPU') 'FPS / GAMING (tu estado real)') + "`n>> Cierra emuladores/overlays de fondo antes de jugar; pesan mas que cualquier tweak." }
    if($s -match 'red|ping|dns|internet|wifi|online|conexion'){ $r=Report-Cats @('RED') 'RED (tu estado real)'; if($HW.IsWifi){ $r+="`n>> Estas en Wi-Fi: la ganancia de estos tweaks es baja, el jitter lo domina la radio. Cable Ethernet daria mas." }; $r+="`n>> DNS rapido: pestana DNS (Cloudflare/Quad9)."; return $r }
    if($s -match 'segur|virus|defender|smartscreen|malware|proteg'){
        $out=@('== SEGURIDAD (analisis en vivo) ==')
        $ss=(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled')
        if($ss -eq 'Off' -or (Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen') -eq 0){ $out+='  [CRITICO] SmartScreen DESACTIVADO. Reactivar ya.' } else { $out+='  [OK] SmartScreen activo.' }
        $ex=@((Get-MpPreference -EA SilentlyContinue).ExclusionPath)
        if($ex.Count -gt 0){ $out+="  [AVISO] $($ex.Count) exclusion(es) de Defender. Revisa que ninguna sea un cheat/inyector:"; $ex | ForEach-Object { $out+="     - $_" } } else { $out+='  [OK] Sin exclusiones de Defender.' }
        $out+='  Tier EXTREMO (VBS/Spectre/Hyper) reduce seguridad real: solo opt-in consciente.'
        return $out -join "`r`n"
    }
    if($s -match 'portatil|bateria|termic|temperatura|calor|energia|power'){ $r=Report-Cats @('CPU') 'ENERGIA / CPU (tu estado real)'; if($HW.IsLaptop){ $r+="`n>> Portatil hibrido: Core Parking OFF y Alto Rendimiento bruto SUBEN termicas y throttlean. Por eso salen bloqueados." }; if($HW.OnBattery){ $r+="`n>> Estas en BATERIA: conecta el cargador para que los tweaks de energia rindan." }; return $r }
    if($s -match 'ram|memoria|cache'){ return (Report-Cats @('MEMORIA') 'MEMORIA (tu estado real)') + "`n>> Los 'limpiadores de RAM' son placebo. La purga de working set (LIMPIEZA) sirve puntual, no en bucle." }
    if($s -match 'extremo|vbs|spectre|hyperv|mitigac'){ return (Report-Cats @('EXTREMO') 'EXTREMO (tu estado real)') + "`n>> Cada uno baja seguridad: VBS->pierdes Memory Integrity, Spectre->expones CVEs, Hyper->rompe WSL2/Docker. Ganancia tipica 1-5% FPS. Decide tu." }
    if($s -match 'servicio|telemetr|privac'){ return (Report-Cats @('SERVICIOS','PRIVACIDAD') 'SERVICIOS / PRIVACIDAD (tu estado real)') }
    if($s -match 'limpi|basura|temp|disco|espacio'){ return "Pestana LIMPIEZA: temporales, cache shaders DX, cache Windows Update, flush DNS, purga working set. Todo reversible (se regenera solo)." }
    if($s -match 'debloat|apps|uwp|quitar|desinstal|bloatware'){ return "Pestana DEBLOAT: quita apps UWP (Xbox, Clipchamp, Copilot...). Reinstalables desde Store. No toco nada critico del sistema." }
    if($s -match 'startup|inicio|arranque|autorun'){ return "Pestana STARTUP: lista tus autoruns reales. Desactiva los que no uses (Overwolf, Razer Cortex, SteelSeries pesan al arrancar). Reversible: backup en startup_disabled.json." }
    if($s -match 'restaur|backup|punto|deshacer|revert'){ return "Boton naranja PUNTO RESTAURACION (ahora corre en segundo plano, no congela). Cada tweak tiene su reversa: desmarca la casilla y APLICAR para revertir uno." }
    if($s -match 'ayuda|help|comando|que puedes|opciones'){ return "Pregunta por: recomendaciones / que aplico, input lag, fps, red, seguridad, portatil, ram, extremo, servicios, limpieza, debloat, startup, restaurar. Leo tu estado real y te digo que falta." }
    return "No reconozco eso. Temas que entiendo: que aplico, input lag, fps, red, seguridad, portatil, ram, extremo, servicios, limpieza, debloat, startup, restaurar, ayuda."
}

# =====================================================
# MODO CONSOLA (sin GUI):  -List  (validacion / CI)
# =====================================================
if($args -contains '-List' -or $env:LW_TEST -eq '1'){
    Write-Host "== LW SUITE v3 == HW: $($HW.CpuName)"
    Write-Host "Laptop=$($HW.IsLaptop) Hybrid=$($HW.IsHybrid) Nvidia=$($HW.HasNvidia) Wifi=$($HW.IsWifi) Home=$($HW.IsHome) AC=$(-not $HW.OnBattery)`n"
    foreach($tw in $CAT){
        $blk = Get-BlockReason $tw
        $st  = try{ if($blk){'BLOCKED'}else{ if([bool](& $tw.Test)){'ON'}else{'off'} } }catch{ "ERR:$($_.Exception.Message)" }
        "{0,-9} T{1} {2,-34} {3}{4}" -f $tw.Cat,$tw.Tier,$tw.Name,$st,$(if($blk){" ($blk)"}) | Write-Host
    }
    exit 0
}

# =====================================================
# GUI
# =====================================================
$bg=[System.Drawing.Color]::FromArgb(24,24,28); $fg=[System.Drawing.Color]::FromArgb(232,232,236)
$accent=[System.Drawing.Color]::FromArgb(90,120,255); $panel=[System.Drawing.Color]::FromArgb(34,34,40)
$danger=[System.Drawing.Color]::FromArgb(200,60,60); $muted=[System.Drawing.Color]::FromArgb(140,140,150)

$form=New-Object System.Windows.Forms.Form
$form.Text='LW SUITE v3 - Elite Optimizer (hardware-aware)'; $form.Size='1000,780'; $form.StartPosition='CenterScreen'
$form.BackColor=$bg; $form.ForeColor=$fg; $form.Font=New-Object System.Drawing.Font('Segoe UI',9)

$hdr=New-Object System.Windows.Forms.Label
$hdr.Text=("HW: {0} | {1}C/{2}T | {3} | {4} | {5} | RAM {6}GB" -f $HW.CpuName,$HW.Cores,$HW.Threads,$(if($HW.IsLaptop){'Portatil'}else{'Desktop'}),$(if($HW.IsHybrid){'Hibrida P/E'}else{'Homogenea'}),$(if($HW.IsWifi){'Wi-Fi'}else{'Ethernet'}),$HW.RamGB)
$hdr.Location='12,8'; $hdr.Size='960,20'; $hdr.ForeColor=$accent; $hdr.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
$form.Controls.Add($hdr)

$tabs=New-Object System.Windows.Forms.TabControl
$tabs.Location='10,34'; $tabs.Size='965,440'; $tabs.Anchor='Top,Left,Right'
$form.Controls.Add($tabs)

# Enumerar categorias con foreach directo (pipeline $_ falla con ArrayList aqui)
$cats=New-Object System.Collections.ArrayList
foreach($tw in $CAT){ if(-not $cats.Contains($tw.Cat)){ [void]$cats.Add($tw.Cat) } }

$allChecks=New-Object System.Collections.ArrayList
foreach($catName in $cats){   # NO usar $cat: colisiona con $CAT (PS es case-insensitive)
    $page=New-Object System.Windows.Forms.TabPage; $page.Text=$catName; $page.BackColor=$panel
    $flow=New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock='Fill'; $flow.FlowDirection='TopDown'; $flow.WrapContents=$false; $flow.AutoScroll=$true; $flow.BackColor=$panel
    foreach($tw in $CAT){
        if($tw.Cat -ne $catName){ continue }
        $rowp=New-Object System.Windows.Forms.Panel; $rowp.Size='920,36'; $rowp.BackColor=$panel
        $chk=New-Object System.Windows.Forms.CheckBox
        $chk.Location='8,7'; $chk.Size='340,22'; $chk.ForeColor=$fg; $chk.Tag=$tw
        $chk.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
        $blk=Get-BlockReason $tw
        if($tw.Tier -eq 2){ $chk.Text="[EXTREMO] $($tw.Name)"; $chk.ForeColor=$danger }
        else { $chk.Text=$tw.Name }
        $lbl=New-Object System.Windows.Forms.Label; $lbl.Location='355,10'; $lbl.Size='555,20'; $lbl.ForeColor=$muted
        if($blk){ $chk.Enabled=$false; $chk.Text="[BLOQUEADO] $($chk.Text)"; $chk.ForeColor=$muted; $lbl.Text="X $blk"; $lbl.ForeColor=$danger }
        else { $lbl.Text=$tw.Desc }
        $rowp.Controls.AddRange(@($chk,$lbl)); $flow.Controls.Add($rowp); [void]$allChecks.Add($chk)
    }
    $page.Controls.Add($flow); $tabs.TabPages.Add($page)
}

# Pestana LIMPIEZA (acciones directas, no toggles)
$pageC=New-Object System.Windows.Forms.TabPage; $pageC.Text='LIMPIEZA'; $pageC.BackColor=$panel
$flowC=New-Object System.Windows.Forms.FlowLayoutPanel
$flowC.Dock='Fill'; $flowC.FlowDirection='TopDown'; $flowC.WrapContents=$false; $flowC.AutoScroll=$true; $flowC.BackColor=$panel; $flowC.Padding='8,8,8,8'
foreach($cl in $CLEAN){
    $rowc=New-Object System.Windows.Forms.Panel; $rowc.Size='910,44'; $rowc.BackColor=$panel
    $b=New-Object System.Windows.Forms.Button; $b.Text=$cl.Name; $b.Size='300,32'; $b.Location='4,6'
    $b.BackColor=$accent; $b.ForeColor='White'; $b.FlatStyle='Flat'; $b.Tag=$cl
    $b.Add_Click({ param($s,$e) $act=$s.Tag; Write-LWLog "Limpieza: $($act.Name)..."; try{ & $act.Run }catch{ Write-LWLog "ERROR limpieza: $($_.Exception.Message)" 'ERR' } })
    $l=New-Object System.Windows.Forms.Label; $l.Text=$cl.Desc; $l.Location='315,13'; $l.Size='585,20'; $l.ForeColor=$muted
    $rowc.Controls.AddRange(@($b,$l)); $flowC.Controls.Add($rowc)
}
$pageC.Controls.Add($flowC); $tabs.TabPages.Add($pageC)

# Pestana DEBLOAT (apps UWP)
$pageD=New-Object System.Windows.Forms.TabPage; $pageD.Text='DEBLOAT'; $pageD.BackColor=$panel
$flowD=New-Object System.Windows.Forms.FlowLayoutPanel; $flowD.Dock='Fill'; $flowD.FlowDirection='TopDown'; $flowD.WrapContents=$false; $flowD.AutoScroll=$true; $flowD.BackColor=$panel
$dbChecks=New-Object System.Collections.ArrayList
foreach($app in $DEBLOAT){
    $rd=New-Object System.Windows.Forms.Panel; $rd.Size='900,26'; $rd.BackColor=$panel
    $ck=New-Object System.Windows.Forms.CheckBox; $ck.Text=$app.Name; $ck.Location='8,3'; $ck.Size='400,20'; $ck.ForeColor=$fg; $ck.Tag=$app.Pkg
    if(-not (Get-DebloatInstalled $app.Pkg)){ $ck.Enabled=$false; $ck.Text="$($app.Name) (no instalada)"; $ck.ForeColor=$muted }
    $rd.Controls.Add($ck); $flowD.Controls.Add($rd); [void]$dbChecks.Add($ck)
}
$btnDb=New-Object System.Windows.Forms.Button; $btnDb.Text='QUITAR SELECCIONADAS'; $btnDb.Size='220,30'; $btnDb.BackColor=$accent; $btnDb.ForeColor='White'; $btnDb.FlatStyle='Flat'
$btnDb.Add_Click({ $n=0; foreach($ck in $dbChecks){ if($ck.Enabled -and $ck.Checked){ Remove-Debloat $ck.Tag; $n++ } }; Write-LWLog "$n app(s) procesadas. Reinstalables desde Store." })
$pd=New-Object System.Windows.Forms.Panel; $pd.Size='900,40'; $pd.Controls.Add($btnDb); $flowD.Controls.Add($pd)
$pageD.Controls.Add($flowD); $tabs.TabPages.Add($pageD)

# Pestana DNS (perfiles)
$pageN=New-Object System.Windows.Forms.TabPage; $pageN.Text='DNS'; $pageN.BackColor=$panel
$flowN=New-Object System.Windows.Forms.FlowLayoutPanel; $flowN.Dock='Fill'; $flowN.FlowDirection='TopDown'; $flowN.BackColor=$panel; $flowN.Padding='8,8,8,8'
foreach($dns in $DNSPROFILES){
    $rn=New-Object System.Windows.Forms.Panel; $rn.Size='900,42'
    $bn=New-Object System.Windows.Forms.Button; $bn.Text=$dns.Name; $bn.Size='280,32'; $bn.Location='4,5'; $bn.BackColor=$accent; $bn.ForeColor='White'; $bn.FlatStyle='Flat'; $bn.Tag=$dns.V4
    $bn.Add_Click({ param($s,$e) Set-LWDns $s.Tag })
    $ln=New-Object System.Windows.Forms.Label; $ln.Text=$(if($dns.V4){$dns.V4 -join ' / '}else{'quita DNS manual'}); $ln.Location='295,12'; $ln.Size='560,20'; $ln.ForeColor=$muted
    $rn.Controls.AddRange(@($bn,$ln)); $flowN.Controls.Add($rn)
}
$pageN.Controls.Add($flowN); $tabs.TabPages.Add($pageN)

# Pestana STARTUP (autoruns)
$pageS=New-Object System.Windows.Forms.TabPage; $pageS.Text='STARTUP'; $pageS.BackColor=$panel
$flowS=New-Object System.Windows.Forms.FlowLayoutPanel; $flowS.Dock='Fill'; $flowS.FlowDirection='TopDown'; $flowS.WrapContents=$false; $flowS.AutoScroll=$true; $flowS.BackColor=$panel
$suChecks=New-Object System.Collections.ArrayList
foreach($ar in (Get-Autoruns)){
    $rs=New-Object System.Windows.Forms.Panel; $rs.Size='900,24'; $rs.BackColor=$panel
    $cs=New-Object System.Windows.Forms.CheckBox; $cs.Text="[$($ar.Hive)] $($ar.Name)"; $cs.Location='8,2'; $cs.Size='330,20'; $cs.ForeColor=$fg; $cs.Tag=$ar
    $vl=New-Object System.Windows.Forms.Label; $vl.Text=$ar.Value; $vl.Location='345,4'; $vl.Size='545,18'; $vl.ForeColor=$muted; $vl.AutoEllipsis=$true
    $rs.Controls.AddRange(@($cs,$vl)); $flowS.Controls.Add($rs); [void]$suChecks.Add($cs)
}
$btnSu=New-Object System.Windows.Forms.Button; $btnSu.Text='DESACTIVAR SELECCIONADOS'; $btnSu.Size='240,30'; $btnSu.BackColor=([System.Drawing.Color]::FromArgb(180,120,0)); $btnSu.ForeColor='White'; $btnSu.FlatStyle='Flat'
$btnSu.Add_Click({ $n=0; foreach($cs in $suChecks){ if($cs.Checked){ Disable-Autorun $cs.Tag; $n++ } }; Write-LWLog "$n autorun(s) desactivado(s). Backup en startup_disabled.json." })
$ps=New-Object System.Windows.Forms.Panel; $ps.Size='900,40'; $ps.Controls.Add($btnSu); $flowS.Controls.Add($ps)
$pageS.Controls.Add($flowS); $tabs.TabPages.Add($pageS)

# Pestana ASISTENTE IA (local, sin API)
$pageA=New-Object System.Windows.Forms.TabPage; $pageA.Text='ASISTENTE IA'; $pageA.BackColor=$panel
$aiOut=New-Object System.Windows.Forms.RichTextBox; $aiOut.Location='10,10'; $aiOut.Size='930,320'; $aiOut.BackColor=[System.Drawing.Color]::FromArgb(16,16,20); $aiOut.ForeColor=$fg; $aiOut.ReadOnly=$true; $aiOut.Font=New-Object System.Drawing.Font('Segoe UI',9); $aiOut.Anchor='Top,Left,Right,Bottom'
$aiIn=New-Object System.Windows.Forms.TextBox; $aiIn.Location='10,340'; $aiIn.Size='700,26'; $aiIn.BackColor=[System.Drawing.Color]::FromArgb(30,30,36); $aiIn.ForeColor=$fg; $aiIn.Anchor='Left,Right,Bottom'
$aiBtn=New-Object System.Windows.Forms.Button; $aiBtn.Text='PREGUNTAR'; $aiBtn.Location='720,338'; $aiBtn.Size='120,30'; $aiBtn.BackColor=$accent; $aiBtn.ForeColor='White'; $aiBtn.FlatStyle='Flat'; $aiBtn.Anchor='Right,Bottom'
$aiRec=New-Object System.Windows.Forms.Button; $aiRec.Text='ANALIZAR PC'; $aiRec.Location='845,338'; $aiRec.Size='95,30'; $aiRec.BackColor=([System.Drawing.Color]::FromArgb(90,40,160)); $aiRec.ForeColor='White'; $aiRec.FlatStyle='Flat'; $aiRec.Anchor='Right,Bottom'
$aiAsk={ $q=$aiIn.Text; $aiOut.AppendText(">> $q`r`n"); $aiOut.AppendText((Invoke-LWAssistant $q)+"`r`n`r`n"); $aiOut.ScrollToCaret(); $aiIn.Clear() }
$aiBtn.Add_Click($aiAsk)
$aiIn.Add_KeyDown({ param($s,$e) if($e.KeyCode -eq 'Enter'){ & $aiAsk; $e.SuppressKeyPress=$true } })
$aiRec.Add_Click({ $aiOut.AppendText(">> Analisis del sistema`r`n"); $aiOut.AppendText(((Get-LWRecommendations) -join "`r`n")+"`r`n`r`n"); $aiOut.ScrollToCaret() })
$pageA.Controls.AddRange(@($aiOut,$aiIn,$aiBtn,$aiRec)); $tabs.TabPages.Add($pageA)
$aiOut.AppendText("Asistente LW Suite (local, sin API). Pregunta lo que quieras o pulsa ANALIZAR PC.`r`nTemas: que aplico, input lag, fps, red, seguridad, portatil, ram, extremo, limpieza, debloat.`r`n`r`n")

$log=New-Object System.Windows.Forms.RichTextBox
$log.Location='10,540'; $log.Size='965,190'; $log.Anchor='Bottom,Left,Right'
$log.BackColor=[System.Drawing.Color]::FromArgb(16,16,20); $log.ForeColor=[System.Drawing.Color]::FromArgb(120,220,140)
$log.ReadOnly=$true; $log.Font=New-Object System.Drawing.Font('Consolas',9)
$form.Controls.Add($log); $script:LogBox=$log

function New-Btn($text,$x,$w,$color){
    $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Location="$x,484"; $b.Size="$w,40"
    $b.BackColor=$color; $b.ForeColor='White'; $b.FlatStyle='Flat'; $b.Anchor='Bottom,Left'
    $b.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($b); $b
}
$btnRestore=New-Btn 'PUNTO RESTAURACION' 10 200 ([System.Drawing.Color]::FromArgb(180,120,0))
$btnPreset =New-Btn 'PRESET GAMING (T0+T1)' 220 190 ([System.Drawing.Color]::FromArgb(90,40,160))
$btnRefresh=New-Btn 'LEER ESTADO' 420 150 ([System.Drawing.Color]::FromArgb(60,60,68))
$btnApply  =New-Btn 'APLICAR CAMBIOS' 580 200 $accent
$lblCount=New-Object System.Windows.Forms.Label; $lblCount.Location='800,494'; $lblCount.Size='170,22'; $lblCount.Anchor='Bottom,Left'; $lblCount.ForeColor=$fg
$form.Controls.Add($lblCount)

function Refresh-States {
    $n=0
    foreach($chk in $allChecks){
        $tw=$chk.Tag
        if(-not $chk.Enabled){ continue }
        try{ $s=[bool](& $tw.Test); $chk.Checked=$s; if($s){$n++} }catch{ Write-LWLog "Test fallo: $($tw.Name) -> $($_.Exception.Message)" 'WARN' }
    }
    $lblCount.Text="$n activos"
}
$btnRefresh.Add_Click({ Write-LWLog 'Leyendo estado real...'; Refresh-States; Write-LWLog 'Estado actualizado.' })
$btnPreset.Add_Click({
    foreach($chk in $allChecks){ if($chk.Enabled -and $chk.Tag.Tier -lt 2){ $chk.Checked=$true } }
    Write-LWLog 'Preset GAMING marcado (Tier 0+1, EXTREMO no se toca). Pulsa APLICAR.'
})
$btnApply.Add_Click({
    $btnApply.Enabled=$false; $reboot=$false; $changed=0
    foreach($chk in $allChecks){
        if(-not $chk.Enabled){ continue }
        $tw=$chk.Tag
        try{ $cur=[bool](& $tw.Test) }catch{ Write-LWLog "Test fallo (omito): $($tw.Name)" 'WARN'; continue }
        if($chk.Checked -ne $cur){
            try{
                if($chk.Checked){ & $tw.Apply; Write-LWLog "APLICADO : $($tw.Name)" } else { & $tw.Revert; Write-LWLog "REVERTIDO: $($tw.Name)" }
                $ok=[bool](& $tw.Test)
                if($ok -ne $chk.Checked){ Write-LWLog "  ! verificacion no coincide en $($tw.Name)" 'WARN' }
                $changed++; if($tw.Reboot){$reboot=$true}
            } catch { Write-LWLog "ERROR    : $($tw.Name) -> $($_.Exception.Message)" 'ERR' }
        }
    }
    if($changed -eq 0){ Write-LWLog 'Sin cambios.' } else { Write-LWLog "$changed cambio(s)." }
    if($reboot){ Write-LWLog '>>> ALGUNOS CAMBIOS REQUIEREN REINICIAR <<<' 'WARN' }
    Refresh-States; $btnApply.Enabled=$true
})
$btnRestore.Add_Click({
    if($script:rsPS){ return }   # ya hay uno en marcha
    $btnRestore.Enabled=$false; Write-LWLog 'Creando punto de restauracion en segundo plano (1-2 min, la ventana sigue usable)...'
    # Runspace aparte: no bloquea el hilo de la GUI (antes se congelaba "No responde")
    $ps=[PowerShell]::Create()
    [void]$ps.AddScript({
        param($desc)
        # Los anti-cheat kernel (EasyAntiCheat, BattlEye, Vanguard) bloquean el
        # DeviceIoControl de VSS -> 0x80070005 Acceso Denegado. Ni Windows puede
        # crear el punto mientras esten cargados. Detectar y avisar claro.
        $ac = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | Where-Object { $_.State -eq 'Running' -and $_.Name -match 'EasyAntiCheat|BEDaisy|BattlEye|vgk' }
        if($ac){ return "ANTICHEAT: '$($ac.Name -join ', ')' esta cargado y bloquea las instantaneas VSS (Acceso Denegado). Cierra el juego/launcher (Epic, etc.), o detén el servicio anti-cheat, y reintenta. Los tweaks igual son reversibles uno a uno (desmarcar + APLICAR) y hay backup .reg en LWSuite\Backups." }
        foreach($sv in 'VSS','swprv'){ $s=Get-Service $sv -EA SilentlyContinue; if($s -and $s.StartType -eq 'Disabled'){ & sc.exe config $sv start= demand | Out-Null } }
        Start-Service VSS -EA SilentlyContinue
        Enable-ComputerRestore -Drive 'C:\' -EA SilentlyContinue
        $rp='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
        New-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
        try { Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS; Remove-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -EA SilentlyContinue; 'OK: punto de restauracion CREADO.' }
        catch {
            $m=$_.Exception.Message
            if($m -match 'deshabilitado|disabled|0x80070005|denegado|denied'){ "ERROR: VSS no pudo crear la instantanea (Acceso Denegado). Causa habitual: un anti-cheat o driver de filtro bloquea el volumen C:. Cierra juegos/launchers con anti-cheat y reintenta. Los tweaks son reversibles individualmente." }
            else { "ERROR: $m" }
        }
    })
    [void]$ps.AddArgument('LW Suite v3')
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

$nBlk=0; foreach($tw in $CAT){ if(Get-BlockReason $tw){ $nBlk++ } }
Write-LWLog "LW SUITE v3 lista. Tweaks: $($CAT.Count). Bloqueados por HW: $nBlk."
Write-LWLog 'Recomendado: crea PRIMERO el punto de restauracion.'
Refresh-States

if($env:LW_GUITEST -eq '1'){
    Write-Host "FORM controls: $($form.Controls.Count)"
    Write-Host "TABS: $($tabs.TabPages.Count)"
    foreach($tp in $tabs.TabPages){ $fp=$tp.Controls[0]; Write-Host ("  {0,-11} rows={1}" -f $tp.Text,$fp.Controls.Count) }
    Write-Host "CHECKS total: $($allChecks.Count)"
    exit 0
}
[void]$form.ShowDialog()
