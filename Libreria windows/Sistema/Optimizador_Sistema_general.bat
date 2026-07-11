@echo off
chcp 65001 >nul
color 0A
title Optimizador de Sistema Windows v2 - MAXI

:: =====================================================
:: CHECK ADMIN
:: =====================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    cls
    echo =========================================
    echo   SE REQUIEREN PERMISOS DE ADMINISTRADOR
    echo =========================================
    pause
    exit
)

:menu
cls
echo =========================================
echo   OPTIMIZADOR DE SISTEMA WINDOWS v2
echo =========================================
echo.
echo 1 - Aplicar perfil RECOMENDADO
echo 2 - Aplicar perfil GAMING COMPETITIVO
echo 3 - Revertir perfil RECOMENDADO
echo 4 - Revertir perfil GAMING COMPETITIVO
echo 5 - Ver que hace cada tweak
echo 0 - Salir
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

call :recomendado_core

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
:: (Nota v2: se ELIMINO "bcdedit hypervisorlaunchtype off".
::  Rompia WSL2, Docker, emuladores y el aislamiento del
::  nucleo de Windows Defender. Riesgo real, ganancia dudosa.)
:: =====================================================
:competitivo
cls
echo =========================================
echo   APLICANDO PERFIL GAMING COMPETITIVO
echo =========================================
echo.

echo Primero se aplica el perfil recomendado...
call :recomendado_core

echo [EXTRA 1/4] Optimizando comportamiento Fullscreen...
reg add "HKCU\System\GameConfigStore" /v GameDVR_FSEBehavior /t REG_DWORD /d 2 /f >nul 2>&1

echo [EXTRA 2/4] Reduciendo presencia de GameBar...
reg add "HKCU\Software\Microsoft\GameBar" /v ShowStartupPanel /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\GameBar" /v UseNexusForGameBarEnabled /t REG_DWORD /d 0 /f >nul 2>&1

echo [EXTRA 3/4] Aplicando prioridad de juegos MMCSS...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /t REG_SZ /d "High" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /t REG_SZ /d "High" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Background Only" /t REG_SZ /d "False" /f >nul 2>&1

echo [EXTRA 4/4] Priorizando ventana activa...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 38 /f >nul 2>&1

echo.
echo =========================================
echo   PERFIL GAMING COMPETITIVO APLICADO
echo =========================================
echo.
echo Recomendado: reinicia el PC.
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

echo [1/9] Restaurando Game DVR...
reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 1 /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /f >nul 2>&1

echo [2/9] Restaurando hibernacion...
powercfg /h on >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" /v ShowHibernateOption /t REG_DWORD /d 1 /f >nul 2>&1

echo [3/9] Restaurando optimizacion de entrega...
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /f >nul 2>&1

echo [4/9] Restaurando rutas largas...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 0 /f >nul 2>&1

echo [5/9] Restaurando busqueda web...
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /f >nul 2>&1
reg delete "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /f >nul 2>&1
reg delete "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" /v "IsAADCloudSearchEnabled" /f >nul 2>&1

echo [6/9] Restaurando cierre de apps...
reg delete "HKCU\Control Panel\Desktop" /v AutoEndTasks /f >nul 2>&1

echo [7/9] Restaurando plantilla de accesos directos...
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates" /v ShortcutNameTemplate /f >nul 2>&1

echo [8/9] Restaurando mensajes de estado...
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v verbosestatus /f >nul 2>&1

echo [9/9] Restaurando Workplace en configuracion...
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

echo [1/4] Restaurando Fullscreen...
reg delete "HKCU\System\GameConfigStore" /v GameDVR_FSEBehavior /f >nul 2>&1

echo [2/4] Restaurando GameBar...
reg add "HKCU\Software\Microsoft\GameBar" /v ShowStartupPanel /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKCU\Software\Microsoft\GameBar" /v UseNexusForGameBarEnabled /t REG_DWORD /d 1 /f >nul 2>&1

echo [3/4] Restaurando perfil MMCSS Games...
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Scheduling Category" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "SFIO Priority" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Background Only" /f >nul 2>&1

echo [4/4] Restaurando prioridad de ventana activa...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 2 /f >nul 2>&1

echo.
echo El perfil recomendado NO se revierte automaticamente aqui.
echo Si quieres volver todo al estado anterior, usa tambien
echo la opcion 3 - Revertir perfil RECOMENDADO.
echo.
echo =========================================
echo   PERFIL GAMING COMPETITIVO REVERTIDO
echo =========================================
echo.
pause
goto menu

:: =====================================================
:: CORE RECOMENDADO
:: (Nota v2: se ELIMINO NoConnectedUser=1 porque puede
::  bloquear el inicio de sesion con cuenta Microsoft.
::  Tambien se quito el reseteo de vistas de carpetas
::  Bags: borraba preferencias del usuario sin avisar.)
:: =====================================================
:recomendado_core
if not exist "%~dp0Backups" mkdir "%~dp0Backups"
reg export "HKCU\System\GameConfigStore" "%~dp0Backups\GameConfigStore.reg" /y >nul 2>&1
reg export "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "%~dp0Backups\PriorityControl.reg" /y >nul 2>&1

echo [1/9] Desactivando Game DVR (grabacion de fondo)...
reg add "HKCU\System\GameConfigStore" /v GameDVR_Enabled /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR" /v AllowGameDVR /t REG_DWORD /d 0 /f >nul 2>&1

echo [2/9] Desactivando hibernacion (libera hiberfil.sys)...
powercfg /h off >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings" /v ShowHibernateOption /t REG_DWORD /d 0 /f >nul 2>&1

echo [3/9] Desactivando optimizacion de entrega P2P...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /t REG_DWORD /d 0 /f >nul 2>&1

echo [4/9] Activando rutas largas...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f >nul 2>&1

echo [5/9] Eliminando resultados web de Bing en busqueda...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "DisableWebSearch" /t REG_DWORD /d 1 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v "ConnectedSearchUseWeb" /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" /v "BingSearchEnabled" /t REG_DWORD /d 0 /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\SearchSettings" /v "IsAADCloudSearchEnabled" /t REG_DWORD /d 0 /f >nul 2>&1

echo [6/9] Desinstalando app Phone Link...
powershell -NoProfile -NonInteractive -Command "Get-AppxPackage -AllUsers Microsoft.YourPhone* | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue" >nul 2>&1

echo [7/9] Mejorando apagado de apps colgadas...
reg add "HKCU\Control Panel\Desktop" /v AutoEndTasks /t REG_SZ /d 1 /f >nul 2>&1

echo [8/9] Quitando sufijo de accesos directos...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\NamingTemplates" /v ShortcutNameTemplate /d "\"%%s.lnk\"" /f >nul 2>&1

echo [9/9] Mensajes detallados de inicio/apagado + ocultar Workplace...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /t REG_DWORD /v verbosestatus /d "1" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v "SettingsPageVisibility" /t REG_SZ /d "hide:workplace" /f >nul 2>&1
exit /b

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
echo Game DVR OFF: sin grabacion de fondo = mas FPS.
echo Hibernacion OFF: libera espacio (hiberfil.sys).
echo   En portatil pierdes la opcion de hibernar.
echo Delivery P2P OFF: no compartes updates con otros PCs.
echo Rutas largas: soporta rutas de mas de 260 caracteres.
echo Bing OFF: busqueda del menu inicio sin resultados web.
echo Phone Link OFF: desinstala la app (vuelve desde la Store).
echo AutoEndTasks: apagado mas rapido con apps colgadas.
echo Accesos directos: sin texto "- Acceso directo".
echo Verbose: mensajes detallados al iniciar/apagar.
echo Workplace: oculta esa pagina en Configuracion.
echo.
echo PERFIL GAMING COMPETITIVO
echo -----------------------------------------
echo Fullscreen FSE: optimiza pantalla completa exclusiva.
echo GameBar OFF: sin avisos ni overlay de GameBar.
echo MMCSS Games High: maxima prioridad multimedia al juego.
echo Foreground Boost: la ventana activa manda (menos input lag).
echo.
echo ELIMINADO EN v2 (era riesgo)
echo -----------------------------------------
echo Hyper-V OFF: rompia WSL2, Docker, emuladores y el
echo   aislamiento del nucleo (seguridad). Fuera.
echo NoConnectedUser: podia bloquear login con cuenta
echo   Microsoft. Fuera.
echo Reseteo de vistas de carpetas: borraba tus preferencias
echo   del Explorador sin avisar. Fuera.
echo.
pause
goto menu
