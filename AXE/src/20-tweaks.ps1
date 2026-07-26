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

