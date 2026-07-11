# =====================================================
# LIBRERIA WINDOWS TWEAKER v2 - GUI estilo W11Tweaker
# Toggles con estado real del sistema, preset gaming,
# log en vivo y punto de restauracion integrado.
# Requiere: ejecutar como administrador (usa el .bat launcher)
# =====================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$admin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    [System.Windows.Forms.MessageBox]::Show("Ejecuta 'Libreria Windows Tweaker.bat' (se eleva solo).","Se requiere administrador",'OK','Warning') | Out-Null
    exit 1
}

# ---------- Helpers ----------
function Get-RV($p,$n){ try{(Get-ItemProperty -Path $p -Name $n -ErrorAction Stop).$n}catch{$null} }
function Set-RD($p,$n,$v){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType DWord -Force|Out-Null }
function Set-RS($p,$n,$v){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType String -Force|Out-Null }
function Del-RV($p,$n){ Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue }
function Svc-Is($n,$m){ try{ (Get-Service $n -ErrorAction Stop).StartType -eq $m }catch{ $false } }
function Svc-Set($n,$m){ sc.exe config $n start= $m | Out-Null }
function Bcd-Has($k,$v){ ((bcdedit /enum '{current}' | Out-String) -match "$k\s+$v") }

# Rutas frecuentes
$PC    = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
$SP    = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$Games = "$SP\Tasks\Games"
$GD    = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$Tcp   = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
$Pol   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
$GCS   = 'HKCU:\System\GameConfigStore'
$PwrSchemes = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'

$script:IfAlias = try { (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).InterfaceAlias } catch { $null }

function Get-ActiveScheme { ((Get-RV $PwrSchemes 'ActivePowerScheme') -replace '[{}]','') }

# ---------- Catalogo de tweaks (Test = estado actual real) ----------
$T = New-Object System.Collections.ArrayList
function AddT($h){ [void]$T.Add($h) }

# --- CPU ---
AddT @{Cat='CPU';Name='Prioridad a ventana activa';Desc='Win32PrioritySeparation=38: el juego en foco manda';Preset=$true;Reboot=$false;
 Test={(Get-RV $PC 'Win32PrioritySeparation') -eq 38};On={Set-RD $PC 'Win32PrioritySeparation' 38};Off={Set-RD $PC 'Win32PrioritySeparation' 2}}
AddT @{Cat='CPU';Name='Liberar CPU multimedia';Desc='SystemResponsiveness=0: sin CPU reservada de fondo';Preset=$true;Reboot=$false;
 Test={(Get-RV $SP 'SystemResponsiveness') -eq 0};On={Set-RD $SP 'SystemResponsiveness' 0};Off={Set-RD $SP 'SystemResponsiveness' 20}}
AddT @{Cat='CPU';Name='Power Throttling OFF';Desc='Windows no limita frecuencia de procesos';Preset=$true;Reboot=$false;
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff') -eq 1};
 On={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1};Off={Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff'}}
AddT @{Cat='CPU';Name='FTH OFF (micro-tirones)';Desc='Desactiva Fault Tolerant Heap';Preset=$true;Reboot=$false;
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled') -eq 0};On={Set-RD 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 0};Off={Set-RD 'HKLM:\SOFTWARE\Microsoft\FTH' 'Enabled' 1}}
AddT @{Cat='CPU';Name='Dynamic Tick OFF';Desc='Timer constante, menos jitter (REINICIO)';Preset=$true;Reboot=$true;
 Test={Bcd-Has 'disabledynamictick' 'Yes'};On={bcdedit /set disabledynamictick yes | Out-Null};Off={bcdedit /deletevalue disabledynamictick | Out-Null}}
AddT @{Cat='CPU';Name='TSC Sync Enhanced';Desc='Sincroniza contador de tiempo entre nucleos (REINICIO)';Preset=$true;Reboot=$true;
 Test={Bcd-Has 'tscsyncpolicy' 'Enhanced'};On={bcdedit /set tscsyncpolicy Enhanced | Out-Null};Off={bcdedit /deletevalue tscsyncpolicy | Out-Null}}
AddT @{Cat='CPU';Name='Core Parking OFF';Desc='Nucleos siempre activos, menor latencia';Preset=$true;Reboot=$false;
 Test={ $g=Get-ActiveScheme; (Get-RV "$PwrSchemes\{$g}\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583" 'ACSettingIndex') -eq 100 };
 On={powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE 2>$null; powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100; powercfg -setdcvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100; powercfg -setactive scheme_current};
 Off={powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 0; powercfg -setdcvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 0; powercfg -setactive scheme_current}}
AddT @{Cat='CPU';Name='Plan Alto Rendimiento';Desc='CPU no baja de frecuencia en idle (mas consumo)';Preset=$true;Reboot=$false;
 Test={(Get-ActiveScheme) -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'};On={powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c};Off={powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e}}

# --- GPU ---
AddT @{Cat='GPU';Name='HAGS (programacion por hardware)';Desc='GPU gestiona su propia cola, menos latencia (REINICIO)';Preset=$true;Reboot=$true;
 Test={(Get-RV $GD 'HwSchMode') -eq 2};On={Set-RD $GD 'HwSchMode' 2};Off={Del-RV $GD 'HwSchMode'}}
AddT @{Cat='GPU';Name='Prioridad MMCSS juegos';Desc='GPU Priority=8, Priority=6 en perfil Games';Preset=$true;Reboot=$false;
 Test={((Get-RV $Games 'GPU Priority') -eq 8) -and ((Get-RV $Games 'Priority') -eq 6)};
 On={Set-RD $Games 'GPU Priority' 8; Set-RD $Games 'Priority' 6};Off={Set-RD $Games 'GPU Priority' 8; Set-RD $Games 'Priority' 2}}
AddT @{Cat='GPU';Name='MMCSS categoria High';Desc='Scheduling/SFIO High + primer plano para juegos';Preset=$true;Reboot=$false;
 Test={(Get-RV $Games 'Scheduling Category') -eq 'High'};
 On={Set-RS $Games 'Scheduling Category' 'High'; Set-RS $Games 'SFIO Priority' 'High'; Set-RS $Games 'Background Only' 'False'};
 Off={Del-RV $Games 'Scheduling Category'; Del-RV $Games 'SFIO Priority'; Del-RV $Games 'Background Only'}}

# --- RED ---
AddT @{Cat='RED';Name='Network Throttling OFF';Desc='Sin limite de paquetes con multimedia activo';Preset=$true;Reboot=$false;
 Test={(Get-RV $SP 'NetworkThrottlingIndex') -eq 4294967295};On={Set-RD $SP 'NetworkThrottlingIndex' 4294967295};Off={Del-RV $SP 'NetworkThrottlingIndex'}}
AddT @{Cat='RED';Name='RSS activado';Desc='Reparte trafico de red entre nucleos de CPU';Preset=$true;Reboot=$false;
 Test={try{(Get-NetOffloadGlobalSetting).ReceiveSideScaling -eq 'Enabled'}catch{$false}};
 On={netsh interface tcp set global rss=enabled | Out-Null};Off={netsh interface tcp set global rss=default | Out-Null}}
AddT @{Cat='RED';Name='DNS rapidos (1.1.1.1 / 8.8.8.8)';Desc="Adaptador detectado: $($script:IfAlias)";Preset=$true;Reboot=$false;
 Test={ if(-not $script:IfAlias){return $false}; try{(Get-DnsClientServerAddress -InterfaceAlias $script:IfAlias -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses -contains '1.1.1.1'}catch{$false} };
 On={ if($script:IfAlias){ Set-DnsClientServerAddress -InterfaceAlias $script:IfAlias -ServerAddresses @('1.1.1.1','8.8.8.8') } };
 Off={ if($script:IfAlias){ Set-DnsClientServerAddress -InterfaceAlias $script:IfAlias -ResetServerAddresses } }}
AddT @{Cat='RED';Name='Mas puertos TCP';Desc='MaxUserPort=65534 para conexiones simultaneas';Preset=$true;Reboot=$true;
 Test={(Get-RV $Tcp 'MaxUserPort') -eq 65534};On={Set-RD $Tcp 'MaxUserPort' 65534};Off={Del-RV $Tcp 'MaxUserPort'}}
AddT @{Cat='RED';Name='CTCP (congestion gaming)';Desc='Recupera antes tras perdida de paquetes';Preset=$true;Reboot=$false;
 Test={try{(Get-NetTCPSetting -SettingName Internet -ErrorAction Stop).CongestionProvider -eq 'CTCP'}catch{$false}};
 On={netsh int tcp set supplemental template=internet congestionprovider=ctcp | Out-Null};Off={netsh int tcp set supplemental template=internet congestionprovider=cubic | Out-Null}}

# --- SERVICIOS ---
AddT @{Cat='SERVICIOS';Name='Telemetria OFF';Desc='DiagTrack, dmwappushservice, WerSvc';Preset=$true;Reboot=$false;
 Test={Svc-Is 'DiagTrack' 'Disabled'};On={Svc-Set DiagTrack disabled; Svc-Set dmwappushservice disabled; Svc-Set WerSvc disabled};
 Off={Svc-Set DiagTrack auto; Svc-Set dmwappushservice demand; Svc-Set WerSvc demand}}
AddT @{Cat='SERVICIOS';Name='Servicios obsoletos OFF';Desc='Fax, RetailDemo, MapsBroker, TrkWks, RemoteRegistry';Preset=$true;Reboot=$false;
 Test={Svc-Is 'Fax' 'Disabled'};On={'Fax','RetailDemo','MapsBroker','TrkWks','RemoteRegistry'|ForEach-Object{Svc-Set $_ disabled}};
 Off={Svc-Set Fax demand; Svc-Set RetailDemo demand; Svc-Set MapsBroker demand; Svc-Set TrkWks auto; Svc-Set RemoteRegistry disabled}}
AddT @{Cat='SERVICIOS';Name='Analisis de fondo OFF';Desc='SysMain, PcaSvc, DPS (precarga y diagnostico)';Preset=$true;Reboot=$false;
 Test={Svc-Is 'SysMain' 'Disabled'};On={'SysMain','PcaSvc','DPS'|ForEach-Object{Svc-Set $_ disabled}};Off={'SysMain','PcaSvc','DPS'|ForEach-Object{Svc-Set $_ auto}}}
AddT @{Cat='SERVICIOS';Name='[AVZ] Notificaciones OFF';Desc='PIERDES notificaciones, Phone Link y cercanos';Preset=$false;Reboot=$false;
 Test={Svc-Is 'WpnService' 'Disabled'};On={'WpnService','CDPSvc','PhoneSvc'|ForEach-Object{Svc-Set $_ disabled}};
 Off={Svc-Set WpnService auto; Svc-Set CDPSvc auto; Svc-Set PhoneSvc demand}}
AddT @{Cat='SERVICIOS';Name='[AVZ] Tactil y sensores OFF';Desc='PIERDES teclado tactil, brillo auto, rotacion';Preset=$false;Reboot=$false;
 Test={Svc-Is 'TabletInputService' 'Disabled'};On={'TabletInputService','SensorService','SensorDataService','SensrSvc'|ForEach-Object{Svc-Set $_ disabled}};
 Off={'TabletInputService','SensorService','SensorDataService','SensrSvc'|ForEach-Object{Svc-Set $_ demand}}}
AddT @{Cat='SERVICIOS';Name='[AVZ] Escritorio remoto OFF';Desc='PIERDES acceso RDP a este PC';Preset=$false;Reboot=$false;
 Test={Svc-Is 'TermService' 'Disabled'};On={'TermService','UmRdpService'|ForEach-Object{Svc-Set $_ disabled}};Off={'TermService','UmRdpService'|ForEach-Object{Svc-Set $_ demand}}}
AddT @{Cat='SERVICIOS';Name='[AVZ] Varios poco usados OFF';Desc='Hotspot, tarjetas intelig., VR, Wallet, AppReadiness';Preset=$false;Reboot=$false;
 Test={Svc-Is 'icssvc' 'Disabled'};On={'icssvc','SCardSvr','ScDeviceEnum','SharedRealitySvc','WalletService','AppReadiness'|ForEach-Object{Svc-Set $_ disabled}};
 Off={'icssvc','SCardSvr','ScDeviceEnum','SharedRealitySvc','WalletService','AppReadiness'|ForEach-Object{Svc-Set $_ demand}}}

# --- PRIVACIDAD ---
AddT @{Cat='PRIVACIDAD';Name='Telemetria minima';Desc='AllowTelemetry=0 por politica';Preset=$true;Reboot=$false;
 Test={(Get-RV "$Pol\DataCollection" 'AllowTelemetry') -eq 0};On={Set-RD "$Pol\DataCollection" 'AllowTelemetry' 0};Off={Del-RV "$Pol\DataCollection" 'AllowTelemetry'}}
AddT @{Cat='PRIVACIDAD';Name='Anuncios personalizados OFF';Desc='Sin ID de publicidad';Preset=$true;Reboot=$false;
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled') -eq 0};
 On={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0};Off={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 1}}
AddT @{Cat='PRIVACIDAD';Name='Sugerencias del menu OFF';Desc='Sin recomendaciones en inicio/configuracion';Preset=$true;Reboot=$false;
 Test={(Get-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled') -eq 0};
 On={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 0};
 Off={Set-RD 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 1}}
AddT @{Cat='PRIVACIDAD';Name='Cortana OFF';Desc='Sin busquedas automaticas con internet';Preset=$true;Reboot=$false;
 Test={(Get-RV "$Pol\Windows Search" 'AllowCortana') -eq 0};On={Set-RD "$Pol\Windows Search" 'AllowCortana' 0};Off={Del-RV "$Pol\Windows Search" 'AllowCortana'}}
AddT @{Cat='PRIVACIDAD';Name='Copilot OFF';Desc='Desactiva la IA de la barra de tareas';Preset=$true;Reboot=$false;
 Test={(Get-RV "$Pol\WindowsCopilot" 'TurnOffWindowsCopilot') -eq 1};On={Set-RD "$Pol\WindowsCopilot" 'TurnOffWindowsCopilot' 1};Off={Del-RV "$Pol\WindowsCopilot" 'TurnOffWindowsCopilot'}}
AddT @{Cat='PRIVACIDAD';Name='Historial de actividad OFF';Desc='Windows no guarda que programas usas';Preset=$true;Reboot=$false;
 Test={(Get-RV "$Pol\System" 'PublishUserActivities') -eq 0};On={Set-RD "$Pol\System" 'PublishUserActivities' 0};Off={Del-RV "$Pol\System" 'PublishUserActivities'}}
AddT @{Cat='PRIVACIDAD';Name='Recall OFF';Desc='Bloquea la IA que captura tu pantalla';Preset=$true;Reboot=$false;
 Test={(Get-RV "$Pol\WindowsAI" 'AllowRecallEnablement') -eq 0};On={Set-RD "$Pol\WindowsAI" 'AllowRecallEnablement' 0};Off={Del-RV "$Pol\WindowsAI" 'AllowRecallEnablement'}}
AddT @{Cat='PRIVACIDAD';Name='Compatibility Appraiser OFF';Desc='Sin analisis de compatibilidad en 2o plano';Preset=$true;Reboot=$false;
 Test={try{(Get-ScheduledTask -TaskName 'Microsoft Compatibility Appraiser' -TaskPath '\Microsoft\Windows\Application Experience\' -ErrorAction Stop).State -eq 'Disabled'}catch{$false}};
 On={schtasks /change /tn '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser' /disable | Out-Null};
 Off={schtasks /change /tn '\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser' /enable | Out-Null}}
AddT @{Cat='PRIVACIDAD';Name='Edge sidebar IA OFF';Desc='Quita barra lateral inteligente de Edge';Preset=$false;Reboot=$false;
 Test={(Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled') -eq 0};
 On={Set-RD 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 0};Off={Del-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled'}}
AddT @{Cat='PRIVACIDAD';Name='Project Rome OFF';Desc='Sin seguimiento entre dispositivos';Preset=$false;Reboot=$false;
 Test={(Get-RV "$Pol\System" 'EnableProjectRome') -eq 0};On={Set-RD "$Pol\System" 'EnableProjectRome' 0};Off={Del-RV "$Pol\System" 'EnableProjectRome'}}

# --- SISTEMA ---
AddT @{Cat='SISTEMA';Name='Game DVR OFF';Desc='Sin grabacion de fondo = mas FPS';Preset=$true;Reboot=$false;
 Test={(Get-RV $GCS 'GameDVR_Enabled') -eq 0};On={Set-RD $GCS 'GameDVR_Enabled' 0; Set-RD "$Pol\GameDVR" 'AllowGameDVR' 0};
 Off={Set-RD $GCS 'GameDVR_Enabled' 1; Del-RV "$Pol\GameDVR" 'AllowGameDVR'}}
AddT @{Cat='SISTEMA';Name='Fullscreen exclusivo (FSE)';Desc='GameDVR_FSEBehavior=2 para pantalla completa';Preset=$true;Reboot=$false;
 Test={(Get-RV $GCS 'GameDVR_FSEBehavior') -eq 2};On={Set-RD $GCS 'GameDVR_FSEBehavior' 2};Off={Del-RV $GCS 'GameDVR_FSEBehavior'}}
AddT @{Cat='SISTEMA';Name='GameBar minimizada';Desc='Sin panel de inicio ni overlay Nexus';Preset=$true;Reboot=$false;
 Test={(Get-RV 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel') -eq 0};
 On={Set-RD 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0; Set-RD 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0};
 Off={Set-RD 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 1; Set-RD 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 1}}
AddT @{Cat='SISTEMA';Name='Hibernacion OFF';Desc='Libera hiberfil.sys (portatil pierde hibernar)';Preset=$true;Reboot=$false;
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled') -eq 0};On={powercfg /h off};Off={powercfg /h on}}
AddT @{Cat='SISTEMA';Name='Delivery Optimization P2P OFF';Desc='No compartes updates con otros PCs';Preset=$true;Reboot=$false;
 Test={(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode') -eq 0};
 On={Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode' 0};
 Off={Del-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' 'DODownloadMode'}}
AddT @{Cat='SISTEMA';Name='Busqueda sin Bing';Desc='Menu inicio sin resultados web';Preset=$true;Reboot=$false;
 Test={(Get-RV "$Pol\Windows Search" 'DisableWebSearch') -eq 1};
 On={Set-RD "$Pol\Windows Search" 'DisableWebSearch' 1; Set-RD "$Pol\Windows Search" 'ConnectedSearchUseWeb' 0; Set-RD 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0};
 Off={Del-RV "$Pol\Windows Search" 'DisableWebSearch'; Del-RV "$Pol\Windows Search" 'ConnectedSearchUseWeb'; Del-RV 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled'}}
AddT @{Cat='SISTEMA';Name='Rutas largas ON';Desc='Soporta rutas de mas de 260 caracteres';Preset=$true;Reboot=$true;
 Test={(Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled') -eq 1};
 On={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1};Off={Set-RD 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 0}}
AddT @{Cat='SISTEMA';Name='AutoEndTasks ON';Desc='Apagado mas rapido con apps colgadas';Preset=$true;Reboot=$false;
 Test={(Get-RV 'HKCU:\Control Panel\Desktop' 'AutoEndTasks') -eq '1'};On={Set-RS 'HKCU:\Control Panel\Desktop' 'AutoEndTasks' '1'};Off={Del-RV 'HKCU:\Control Panel\Desktop' 'AutoEndTasks'}}

# ---------- GUI ----------
$bg=[System.Drawing.Color]::FromArgb(30,30,32); $fg=[System.Drawing.Color]::FromArgb(230,230,230)
$accent=[System.Drawing.Color]::FromArgb(0,120,212); $panelBg=[System.Drawing.Color]::FromArgb(40,40,44)

$form = New-Object System.Windows.Forms.Form
$form.Text='LIBRERIA WINDOWS TWEAKER v2 - Gaming Edition'; $form.Size='980,760'; $form.StartPosition='CenterScreen'
$form.BackColor=$bg; $form.ForeColor=$fg; $form.Font=New-Object System.Drawing.Font('Segoe UI',9)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location='10,10'; $tabs.Size='945,430'; $tabs.Anchor='Top,Left,Right'
$form.Controls.Add($tabs)

$allChecks = New-Object System.Collections.ArrayList
foreach($cat in ($T | ForEach-Object {$_.Cat} | Select-Object -Unique)){
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text=$cat; $page.BackColor=$panelBg
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Dock='Fill'; $flow.FlowDirection='TopDown'; $flow.WrapContents=$false; $flow.AutoScroll=$true; $flow.BackColor=$panelBg
    foreach($tw in ($T | Where-Object {$_.Cat -eq $cat})){
        $row = New-Object System.Windows.Forms.Panel; $row.Size='900,34'; $row.BackColor=$panelBg
        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text=$tw.Name; $chk.Location='8,6'; $chk.Size='330,24'; $chk.ForeColor=$fg
        $chk.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
        $chk.Tag=$tw
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text=$tw.Desc; $lbl.Location='345,9'; $lbl.Size='540,20'; $lbl.ForeColor=[System.Drawing.Color]::FromArgb(150,150,155)
        $row.Controls.AddRange(@($chk,$lbl)); $flow.Controls.Add($row); [void]$allChecks.Add($chk)
    }
    $page.Controls.Add($flow); $tabs.TabPages.Add($page)
}

# Pestana LIMPIEZA (acciones directas)
$pageL = New-Object System.Windows.Forms.TabPage; $pageL.Text='LIMPIEZA'; $pageL.BackColor=$panelBg
$cleanFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$cleanFlow.Dock='Fill'; $cleanFlow.FlowDirection='TopDown'; $cleanFlow.BackColor=$panelBg; $cleanFlow.Padding='10,10,10,10'
function New-CleanBtn($text,$desc,$action){
    $p=New-Object System.Windows.Forms.Panel; $p.Size='900,42'
    $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Size='260,32'; $b.Location='5,5'
    $b.BackColor=$accent; $b.ForeColor='White'; $b.FlatStyle='Flat'; $b.Add_Click($action)
    $l=New-Object System.Windows.Forms.Label; $l.Text=$desc; $l.Location='280,13'; $l.Size='600,20'; $l.ForeColor=[System.Drawing.Color]::FromArgb(150,150,155)
    $p.Controls.AddRange(@($b,$l)); $cleanFlow.Controls.Add($p)
}
$pageL.Controls.Add($cleanFlow); $tabs.TabPages.Add($pageL)

# Log
$log = New-Object System.Windows.Forms.RichTextBox
$log.Location='10,500'; $log.Size='945,205'; $log.Anchor='Bottom,Left,Right'
$log.BackColor=[System.Drawing.Color]::FromArgb(20,20,22); $log.ForeColor=[System.Drawing.Color]::FromArgb(120,220,120)
$log.ReadOnly=$true; $log.Font=New-Object System.Drawing.Font('Consolas',9)
$form.Controls.Add($log)
function W-Log($m){ $log.AppendText("[$(Get-Date -Format HH:mm:ss)] $m`r`n"); $log.ScrollToCaret() }

# Botonera
function New-Btn($text,$x,$w,$color){
    $b=New-Object System.Windows.Forms.Button; $b.Text=$text; $b.Location="$x,450"; $b.Size="$w,38"
    $b.BackColor=$color; $b.ForeColor='White'; $b.FlatStyle='Flat'; $b.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($b); $b
}
$btnRestore = New-Btn 'CREAR PUNTO RESTAURACION' 10 220 ([System.Drawing.Color]::FromArgb(180,120,0))
$btnPreset  = New-Btn 'PRESET GAMING' 240 150 ([System.Drawing.Color]::FromArgb(90,40,160))
$btnRefresh = New-Btn 'LEER ESTADO ACTUAL' 400 180 ([System.Drawing.Color]::FromArgb(60,60,66))
$btnApply   = New-Btn 'APLICAR CAMBIOS' 590 200 $accent
$lblCount = New-Object System.Windows.Forms.Label
$lblCount.Location='800,460'; $lblCount.Size='160,22'; $lblCount.ForeColor=$fg
$form.Controls.Add($lblCount)

function Refresh-States {
    $n=0
    foreach($chk in $allChecks){ $s=[bool](& $chk.Tag.Test); $chk.Checked=$s; if($s){$n++} }
    $lblCount.Text="$n / $($allChecks.Count) activos"
}

$btnRefresh.Add_Click({ W-Log 'Leyendo estado real del sistema...'; Refresh-States; W-Log 'Estado actualizado.' })

$btnPreset.Add_Click({
    foreach($chk in $allChecks){ if($chk.Tag.Preset){ $chk.Checked=$true } }
    W-Log 'Preset GAMING marcado (los [AVZ] no se tocan). Pulsa APLICAR CAMBIOS.'
})

$btnApply.Add_Click({
    $btnApply.Enabled=$false; $needReboot=$false; $changed=0
    foreach($chk in $allChecks){
        $tw=$chk.Tag; $cur=[bool](& $tw.Test)
        if($chk.Checked -ne $cur){
            try{
                if($chk.Checked){ & $tw.On; W-Log "APLICADO : $($tw.Name)" } else { & $tw.Off; W-Log "REVERTIDO: $($tw.Name)" }
                $changed++; if($tw.Reboot){$needReboot=$true}
            } catch { W-Log "ERROR    : $($tw.Name) -> $($_.Exception.Message)" }
        }
    }
    if($changed -eq 0){ W-Log 'Sin cambios: los toggles ya coinciden con el sistema.' }
    else { W-Log "$changed cambio(s) aplicado(s)." }
    if($needReboot){ W-Log '>>> ALGUNOS CAMBIOS REQUIEREN REINICIAR EL PC <<<' }
    Refresh-States; $btnApply.Enabled=$true
})

$btnRestore.Add_Click({
    $btnRestore.Enabled=$false; W-Log 'Creando punto de restauracion (1-2 min)...'
    try{
        Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue
        Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore' 'SystemRestorePointCreationFrequency' 0
        Checkpoint-Computer -Description 'Libreria Windows Tweaker' -RestorePointType MODIFY_SETTINGS
        W-Log 'Punto de restauracion CREADO. Ya puedes aplicar tweaks.'
    } catch { W-Log "ERROR creando punto: $($_.Exception.Message)" }
    $btnRestore.Enabled=$true
})

# Acciones de limpieza
New-CleanBtn 'Temporales usuario + Windows' 'Borra %TEMP% y C:\Windows\Temp' {
    W-Log 'Limpiando temporales...'
    $before=[math]::Round((Get-PSDrive C).Free/1GB,2)
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue
    $after=[math]::Round((Get-PSDrive C).Free/1GB,2)
    W-Log "Temporales limpios. Libre: $before GB -> $after GB"
}
New-CleanBtn 'Cache shaders DirectX' 'Se regenera sola; util tras update de driver' {
    Remove-Item "$env:LOCALAPPDATA\D3DSCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    W-Log 'Cache de shaders DirectX limpiada.'
}
New-CleanBtn 'Cache Windows Update' 'Para wuauserv/bits, borra Download, reinicia servicios' {
    W-Log 'Limpiando cache de Windows Update...'
    Stop-Service wuauserv,bits -Force -ErrorAction SilentlyContinue
    Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service bits,wuauserv -ErrorAction SilentlyContinue
    W-Log 'Cache de Windows Update limpiada.'
}
New-CleanBtn 'Flush DNS' 'Vacia la cache de resolucion de nombres' {
    ipconfig /flushdns | Out-Null; W-Log 'Cache DNS vaciada.'
}

# Modo test sin GUI (validacion automatica)
if($env:LW_TEST -eq '1'){
    Write-Host "Adaptador: $($script:IfAlias)"
    foreach($tw in $T){
        try{ $s=[bool](& $tw.Test); Write-Host ("{0,-12} {1,-35} = {2}" -f $tw.Cat,$tw.Name,$s) }
        catch{ Write-Host ("{0,-12} {1,-35} = TEST ERROR: {2}" -f $tw.Cat,$tw.Name,$_.Exception.Message) }
    }
    exit 0
}

W-Log "LIBRERIA WINDOWS TWEAKER v2 lista. Adaptador de red: $($script:IfAlias)"
W-Log 'Consejo: crea PRIMERO el punto de restauracion, luego PRESET GAMING y APLICAR.'
Refresh-States
[void]$form.ShowDialog()
