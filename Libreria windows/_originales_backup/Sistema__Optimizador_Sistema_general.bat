@echo off
color 0A
title Optimizador de Sistema Windows - MAXI

:: =====================================================
:: MENU PRINCIPAL
:: =====================================================
:menu
cls
echo =========================================
echo   OPTIMIZADOR DE SISTEMA WINDOWS - MAXI
echo =========================================
echo.
echo 1 - Aplicar perfil RECOMENDADO
echo 2 - Aplicar perfil GAMING COMPETITIVO
echo 3 - Revertir perfil RECOMENDADO
echo 4 - Revertir perfil GAMING COMPETITIVO
echo 5 - Ver que hace cada tweak
echo 0 - Salir
echo.
echo IMPORTANTE:
echo Ejecuta este archivo como administrador.
echo.
set /p opcion=Selecciona una opcion: 

if "%opcion%"=="1" goto recomendado
if "%opcion%"=="2" goto competitivo
if "%opcion%"=="3" goto revert_recomendado
if "%opcion%"=="4" goto revert_competitivo
if "%opcion%"=="5" goto info
if "%opcion%"=="0" exit

goto menu

:: =====================================================
:: PERFIL RECOMENDADO
:: =====================================================
:recomendado
cls
echo =========================================
echo   APLICANDO PERFIL RECOMENDADO
echo =========================================
echo.

echo [1/10] Desactivando Game DVR...
timeout /t 1 >nul
reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /t REG_DWORD /d 0 /f >nul 2>&1

echo [2/10] Desactivando hibernacion...
timeout /t 1 >nul
powercfg /h off >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" /v ShowHibernateOption /t REG_DWORD /d 0 /f >nul 2>&1

echo [3/10] Desactivando optimizacion de entrega P2P...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /t REG_DWORD /d 0 /f >nul 2>&1

echo [4/10] Activando rutas largas...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f >nul 2>&1

echo [5/10] Eliminando resultados web de Bing en busqueda...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" /v "IsAADCloudSearchEnabled" /t REG_DWORD /d 0 /f >nul 2>&1

echo [6/10] Desactivando Phone Link...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "NoConnectedUser" /t REG_DWORD /d "1" /f >nul 2>&1
powershell -NoProfile -NonInteractive -Command "Get-AppxPackage -AllUsers Microsoft.YourPhone* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue" >nul 2>&1

echo [7/10] Mejorando apagado de apps colgadas...
timeout /t 1 >nul
reg add "HKCU\Control Panel\Desktop" /v AutoEndTasks /t REG_SZ /d 1 /f >nul 2>&1

echo [8/10] Ajustando explorador y accesos directos...
timeout /t 1 >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates" /v ShortcutNameTemplate /d "\"%%s.lnk\"" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags" /f >nul 2>&1
reg add "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell" /v "FolderType" /t REG_SZ /d "NotSpecified" /f >nul 2>&1

echo [9/10] Mostrando mensajes detallados de inicio/apagado...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /t REG_DWORD /v verbosestatus /d "1" /f >nul 2>&1

echo [10/10] Ocultando Workplace en configuracion...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "SettingsPageVisibility" /t REG_SZ /d "hide:workplace" /f >nul 2>&1

echo.
echo =========================================
echo   PERFIL RECOMENDADO APLICADO
echo =========================================
echo.
echo Recomendado: reinicia el PC.
echo.
pause
goto menu

:: =====================================================
:: PERFIL GAMING COMPETITIVO
:: =====================================================
:competitivo
cls
echo =========================================
echo   APLICANDO PERFIL GAMING COMPETITIVO
echo =========================================
echo.

echo Primero se aplicara el perfil recomendado...
timeout /t 1 >nul
call :recomendado_core

echo [EXTRA 1/5] Optimizando comportamiento Fullscreen...
timeout /t 1 >nul
reg add "HKCU\System\GameConfigStore" /v GameDVR_FSEBehavior /t REG_DWORD /d 2 /f >nul 2>&1

echo [EXTRA 2/5] Reduciendo presencia de GameBar...
timeout /t 1 >nul
reg add "HKCU\Software\Microsoft\GameBar" /v ShowStartupPanel /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\GameBar" /v UseNexusForGameBarEnabled /t REG_DWORD /d 0 /f >nul 2>&1

echo [EXTRA 3/5] Aplicando prioridad de juegos MMCSS...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d "High" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /t REG_SZ /d "High" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Background Only" /t REG_SZ /d "False" /f >nul 2>&1

echo [EXTRA 4/5] Priorizando ventana activa...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 38 /f >nul 2>&1

echo [EXTRA 5/5] Desactivando Hyper-V para reducir sobrecarga...
timeout /t 1 >nul
bcdedit /set hypervisorlaunchtype off >nul 2>&1

echo.
echo =========================================
echo   PERFIL GAMING COMPETITIVO APLICADO
echo =========================================
echo.
echo Recomendado: reinicia el PC.
echo.
echo Nota: este perfil puede afectar WSL2, Docker, emuladores
echo y funciones que dependan de Hyper-V.
echo.
pause
goto menu

:: =====================================================
:: REVERTIR PERFIL RECOMENDADO
:: =====================================================
:revert_recomendado
cls
echo =========================================
echo   REVERTIENDO PERFIL RECOMENDADO
echo =========================================
echo.

echo [1/10] Restaurando Game DVR...
timeout /t 1 >nul
reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 1 /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /f >nul 2>&1

echo [2/10] Restaurando hibernacion...
timeout /t 1 >nul
powercfg /h on >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" /v ShowHibernateOption /t REG_DWORD /d 1 /f >nul 2>&1

echo [3/10] Restaurando optimizacion de entrega...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /t REG_DWORD /d 1 /f >nul 2>&1

echo [4/10] Restaurando rutas largas...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 0 /f >nul 2>&1

echo [5/10] Restaurando busqueda web...
timeout /t 1 >nul
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /f >nul 2>&1
reg delete "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /f >nul 2>&1
reg delete "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" /v "IsAADCloudSearchEnabled" /f >nul 2>&1

echo [6/10] Restaurando Phone Link...
timeout /t 1 >nul
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "NoConnectedUser" /f >nul 2>&1

echo [7/10] Restaurando cierre de apps...
timeout /t 1 >nul
reg add "HKCU\Control Panel\Desktop" /v AutoEndTasks /t REG_SZ /d 0 /f >nul 2>&1

echo [8/10] Restaurando explorador y accesos directos...
timeout /t 1 >nul
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates" /v ShortcutNameTemplate /f >nul 2>&1
reg delete "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders" /f >nul 2>&1

echo [9/10] Restaurando mensajes de estado...
timeout /t 1 >nul
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v verbosestatus /f >nul 2>&1

echo [10/10] Restaurando Workplace en configuracion...
timeout /t 1 >nul
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "SettingsPageVisibility" /f >nul 2>&1

echo.
echo =========================================
echo   PERFIL RECOMENDADO REVERTIDO
echo =========================================
echo.
echo Recomendado: reinicia el PC.
echo.
pause
goto menu

:: =====================================================
:: REVERTIR PERFIL GAMING COMPETITIVO
:: =====================================================
:revert_competitivo
cls
echo =========================================
echo   REVERTIENDO PERFIL GAMING COMPETITIVO
echo =========================================
echo.

echo [1/5] Restaurando Fullscreen...
timeout /t 1 >nul
reg add "HKCU\System\GameConfigStore" /v GameDVR_FSEBehavior /t REG_DWORD /d 0 /f >nul 2>&1

echo [2/5] Restaurando GameBar...
timeout /t 1 >nul
reg add "HKCU\Software\Microsoft\GameBar" /v UseNexusForGameBarEnabled /t REG_DWORD /d 1 /f >nul 2>&1

echo [3/5] Restaurando perfil MMCSS Games...
timeout /t 1 >nul
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Background Only" /f >nul 2>&1

echo [4/5] Restaurando prioridad de ventana activa...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 2 /f >nul 2>&1

echo [5/5] Restaurando Hyper-V...
timeout /t 1 >nul
bcdedit /set hypervisorlaunchtype auto >nul 2>&1

echo.
echo El perfil recomendado NO se revierte automaticamente aqui.
echo Si quieres volver todo al estado anterior, usa tambien:
echo opcion 3 - Revertir perfil RECOMENDADO.
echo.
echo =========================================
echo   PERFIL GAMING COMPETITIVO REVERTIDO
echo =========================================
echo.
echo Recomendado: reinicia el PC.
echo.
pause
goto menu

:: =====================================================
:: INFORMACION DE TWEAKS
:: =====================================================
:info
cls
echo =========================================
echo   QUE HACE CADA TWEAK
echo =========================================
echo.

echo PERFIL RECOMENDADO
echo -----------------------------------------
echo Game DVR OFF:
echo Desactiva la grabacion en segundo plano de Windows.
echo.

echo Game DVR por politica:
echo Refuerza el bloqueo de Game DVR desde directiva del sistema.
echo.

echo Hibernacion OFF:
echo Libera espacio eliminando hiberfil.sys. En portatiles puede quitar la opcion hibernar.
echo.

echo Optimizacion de entrega P2P OFF:
echo Evita que Windows comparta actualizaciones con otros PCs.
echo.

echo Rutas largas:
echo Permite manejar rutas de archivos superiores a 260 caracteres.
echo.

echo Busqueda web Bing OFF:
echo Evita resultados web en la busqueda de inicio, dejando una busqueda mas limpia.
echo.

echo Phone Link OFF:
echo Desactiva la integracion de Enlace Movil. La app puede volver desde Microsoft Store.
echo.

echo AutoEndTasks:
echo Reduce esperas al apagar si hay aplicaciones bloqueadas.
echo.

echo Quitar texto Acceso directo:
echo Evita que Windows anada ese texto al crear accesos directos.
echo.

echo Fijar vista de carpetas:
echo Evita que el Explorador cambie automaticamente entre vistas de fotos, musica o documentos.
echo.

echo Mensajes verbose:
echo Muestra mensajes mas detallados durante inicio y apagado.
echo.

echo Ocultar Workplace:
echo Oculta la pagina Area de trabajo en Configuracion.
echo.

echo.
echo PERFIL GAMING COMPETITIVO
echo -----------------------------------------
echo Fullscreen FSE:
echo Ajusta el comportamiento de pantalla completa para juegos.
echo.

echo GameBar Presence OFF:
echo Reduce avisos y deteccion de GameBar sin eliminar el modo juego.
echo.

echo MMCSS Games:
echo Da prioridad alta al perfil multimedia de juegos.
echo.

echo Foreground Boost:
echo Prioriza la ventana activa para mejorar respuesta en primer plano.
echo.

echo Hyper-V OFF:
echo Desactiva el hipervisor de Windows. Puede ayudar en gaming, pero rompe WSL2, Docker,
echo emuladores o funciones que dependan de virtualizacion.
echo.

pause
goto menu

:: =====================================================
:: CORE RECOMENDADO PARA USAR DENTRO DEL PERFIL COMPETITIVO
:: =====================================================
:recomendado_core
reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /t REG_DWORD /d 0 /f >nul 2>&1
powercfg /h off >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" /v ShowHibernateOption /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" /v "IsAADCloudSearchEnabled" /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v "NoConnectedUser" /t REG_DWORD /d "1" /f >nul 2>&1
powershell -NoProfile -NonInteractive -Command "Get-AppxPackage -AllUsers Microsoft.YourPhone* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue" >nul 2>&1
reg add "HKCU\Control Panel\Desktop" /v AutoEndTasks /t REG_SZ /d 1 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates" /v ShortcutNameTemplate /d "\"%%s.lnk\"" /f >nul 2>&1
reg delete "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags" /f >nul 2>&1
reg add "HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell" /v "FolderType" /t REG_SZ /d "NotSpecified" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /t REG_DWORD /v verbosestatus /d "1" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "SettingsPageVisibility" /t REG_SZ /d "hide:workplace" /f >nul 2>&1
exit /b
