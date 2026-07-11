@echo off
color 0A
title OPTIMIZAR PRIVACIDAD by ELMAXI

:: =====================================================
:: VERIFICAR ADMINISTRADOR
:: =====================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    cls
    echo =========================================
    echo  PERMISOS DE ADMINISTRADOR NECESARIOS
    echo =========================================
    echo.
    echo Este programa necesita acceso completo al sistema
    echo para modificar configuraciones de privacidad.
    echo.
    echo CLICK DERECHO -> "Ejecutar como administrador"
    echo =========================================
    pause
    exit
)

:: =====================================================
:: MENU PRINCIPAL
:: =====================================================
:menu
cls
echo =========================================
echo        OPTIMIZAR PRIVACIDAD
echo              by ELMAXI
echo =========================================
echo.
echo 1 - PRIVACIDAD BASICA (RECOMENDADO)
echo 2 - PRIVACIDAD AVANZADA (MAXIMO BLOQUEO)
echo 3 - RESTAURAR BASICA
echo 4 - RESTAURAR AVANZADA
echo 5 - QUE HACE CADA AJUSTE (EXPLICADO FACIL)
echo.
set /p opcion=Selecciona una opcion: 

if "%opcion%"=="1" goto basic
if "%opcion%"=="2" goto advanced
if "%opcion%"=="3" goto revert_basic
if "%opcion%"=="4" goto revert_advanced
if "%opcion%"=="5" goto info

goto menu

:: =====================================================
:: PRIVACIDAD BASICA
:: =====================================================
:basic
cls
echo =========================================
echo        PRIVACIDAD BASICA
echo =========================================
echo.

echo [1/7] Reduciendo telemetria (datos a Microsoft)...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f >nul

echo [2/7] Quitando anuncios personalizados...
timeout /t 1 >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f >nul

echo [3/7] Eliminando sugerencias molestas de Windows...
timeout /t 1 >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f >nul

echo [4/7] Quitando Cortana y busquedas con internet...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 0 /f >nul

echo [5/7] Desactivando Copilot (IA de Windows)...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f >nul

echo [6/7] Evitando que Windows guarde tu actividad...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v PublishUserActivities /t REG_DWORD /d 0 /f >nul

echo [7/7] Evitando seguimiento de apps usadas...
timeout /t 1 >nul
reg add "HKCU\Software\Policies\Microsoft\Windows\EdgeUI" /v DisableMFUTracking /t REG_DWORD /d 1 /f >nul

echo.
echo =========================================
echo   PRIVACIDAD BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: PRIVACIDAD AVANZADA
:: =====================================================
:advanced
cls
echo =========================================
echo       PRIVACIDAD AVANZADA
echo =========================================
echo.

echo [1/6] Desactivando tareas ocultas de Microsoft...
timeout /t 1 >nul
schtasks /change /tn "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" /disable >nul 2>&1

echo [2/6] Bloqueando sistema de reputacion de archivos...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 0 /f >nul

echo [3/6] Bloqueando IA que hace capturas del sistema (Recall)...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v AllowRecallEnablement /t REG_DWORD /d 0 /f >nul

echo [4/6] Desactivando IA de Microsoft Edge...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v HubsSidebarEnabled /t REG_DWORD /d 0 /f >nul

echo [5/6] Evitando que Windows analice tu PC (hardware)...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Census" /v CheckSession /t REG_DWORD /d 0 /f >nul

echo [6/6] Desactivando conexion entre dispositivos...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableProjectRome /t REG_DWORD /d 0 /f >nul

echo.
echo =========================================
echo   PRIVACIDAD AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: RESTAURAR BASICA
:: =====================================================
:revert_basic
cls
echo =========================================
echo        RESTAURAR BASICA
echo =========================================
echo.

echo Volviendo configuracion normal de Windows...
timeout /t 1 >nul

reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 3 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 0 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 1 /f >nul

echo.
echo =========================================
echo   RESTAURACION BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: RESTAURAR AVANZADA
:: =====================================================
:revert_advanced
cls
echo =========================================
echo      RESTAURAR AVANZADA
echo =========================================
echo.

echo Restaurando funciones avanzadas del sistema...
timeout /t 1 >nul

schtasks /change /tn "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" /enable >nul 2>&1
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableSmartScreen /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v AllowRecallEnablement /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v HubsSidebarEnabled /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Census" /v CheckSession /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableProjectRome /t REG_DWORD /d 1 /f >nul

echo.
echo =========================================
echo  RESTAURACION AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: EXPLICACION SIMPLE
:: =====================================================
:info
cls
echo =========================================
echo        QUE HACE CADA OPCION
echo =========================================
echo.

echo ========= PRIVACIDAD BASICA =========
echo.
echo TELEMETRIA:
echo Windows deja de enviar informacion sobre como usas el PC.
echo.
echo PUBLICIDAD:
echo Quita anuncios dentro del sistema.
echo.
echo SUGERENCIAS:
echo Elimina recomendaciones molestas del menu inicio.
echo.
echo BING Y CORTANA:
echo Evita que Windows use internet para buscar cosas automaticamente.
echo.
echo COPILOT:
echo Desactiva la IA de Windows que aparece en la barra.
echo.
echo ACTIVIDAD:
echo Windows deja de recordar que programas usas.
echo.
echo APPS FRECUENTES:
echo Evita que Windows analice lo que mas usas.
echo.

echo ========= PRIVACIDAD AVANZADA =========
echo.
echo TAREAS OCULTAS:
echo Windows deja de hacer analisis internos en segundo plano.
echo.
echo SMARTSCREEN:
echo Evita que Windows analice archivos que abres.
echo.
echo RECALL IA:
echo Bloquea la IA que hace capturas de lo que haces en pantalla.
echo.
echo EDGE IA:
echo Quita funciones inteligentes del navegador Edge.
echo.
echo HARDWARE ANALYSIS:
echo Windows deja de analizar tu ordenador para Microsoft.
echo.
echo DISPOSITIVOS:
echo Evita conexion y seguimiento entre otros dispositivos.
echo.

pause
goto menu