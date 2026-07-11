@echo off
chcp 65001 >nul
color 0A
title OPTIMIZAR PRIVACIDAD v2 by ELMAXI

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
    echo CLICK DERECHO -^> "Ejecutar como administrador"
    echo =========================================
    pause
    exit
)

:menu
cls
echo =========================================
echo        OPTIMIZAR PRIVACIDAD v2
echo              by ELMAXI
echo =========================================
echo.
echo 1 - PRIVACIDAD BASICA (RECOMENDADO)
echo 2 - PRIVACIDAD AVANZADA
echo 3 - RESTAURAR BASICA
echo 4 - RESTAURAR AVANZADA
echo 5 - QUE HACE CADA AJUSTE
echo 0 - SALIR
echo.
set /p opcion=Selecciona una opcion:

if "%opcion%"=="1" goto basic
if "%opcion%"=="2" goto advanced
if "%opcion%"=="3" goto revert_basic
if "%opcion%"=="4" goto revert_advanced
if "%opcion%"=="5" goto info
if "%opcion%"=="0" exit

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
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f >nul

echo [2/7] Quitando anuncios personalizados...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f >nul

echo [3/7] Eliminando sugerencias de Windows...
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f >nul

echo [4/7] Quitando Cortana y busquedas con internet...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 0 /f >nul

echo [5/7] Desactivando Copilot (IA de Windows)...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f >nul

echo [6/7] Evitando que Windows guarde tu actividad...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v PublishUserActivities /t REG_DWORD /d 0 /f >nul

echo [7/7] Evitando seguimiento de apps usadas...
reg add "HKCU\Software\Policies\Microsoft\Windows\EdgeUI" /v DisableMFUTracking /t REG_DWORD /d 1 /f >nul

echo.
echo =========================================
echo   PRIVACIDAD BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: PRIVACIDAD AVANZADA
:: (Nota v2: se ELIMINO la desactivacion de SmartScreen.
::  SmartScreen protege contra malware; apagarlo es un
::  riesgo real de seguridad, no un tweak de privacidad.)
:: =====================================================
:advanced
cls
echo =========================================
echo       PRIVACIDAD AVANZADA
echo =========================================
echo.

echo [1/5] Desactivando Compatibility Appraiser...
schtasks /change /tn "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" /disable >nul 2>&1

echo [2/5] Bloqueando Recall (IA que captura pantalla)...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v AllowRecallEnablement /t REG_DWORD /d 0 /f >nul

echo [3/5] Desactivando barra lateral IA de Edge...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v HubsSidebarEnabled /t REG_DWORD /d 0 /f >nul

echo [4/5] Desactivando Device Census (analisis de hardware)...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Census" /v CheckSession /t REG_DWORD /d 0 /f >nul

echo [5/5] Desactivando Project Rome (conexion entre equipos)...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableProjectRome /t REG_DWORD /d 0 /f >nul

echo.
echo =========================================
echo   PRIVACIDAD AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: RESTAURAR BASICA
:: (Nota v2: ahora restaura TODOS los valores que se
::  tocaron, y elimina las politicas en vez de forzar
::  valores, que es el estado real de fabrica.)
:: =====================================================
:revert_basic
cls
echo =========================================
echo        RESTAURAR BASICA
echo =========================================
echo.

echo Volviendo a la configuracion de fabrica de Windows...

reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /f >nul 2>&1
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 1 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 1 /f >nul
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot" /v TurnOffWindowsCopilot /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v PublishUserActivities /f >nul 2>&1
reg delete "HKCU\Software\Policies\Microsoft\Windows\EdgeUI" /v DisableMFUTracking /f >nul 2>&1

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

schtasks /change /tn "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" /enable >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsAI" /v AllowRecallEnablement /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Edge" /v HubsSidebarEnabled /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Census" /v CheckSession /t REG_DWORD /d 1 /f >nul
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableProjectRome /f >nul 2>&1

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
echo TELEMETRIA: Windows deja de enviar datos de uso a Microsoft.
echo PUBLICIDAD: quita anuncios personalizados del sistema.
echo SUGERENCIAS: elimina recomendaciones del menu inicio.
echo CORTANA: evita busquedas automaticas con internet.
echo COPILOT: desactiva la IA de la barra de tareas.
echo ACTIVIDAD: Windows no guarda historial de lo que haces.
echo APPS FRECUENTES: no analiza que programas usas mas.
echo.
echo ========= PRIVACIDAD AVANZADA =========
echo.
echo APPRAISER: desactiva analisis de compatibilidad en 2o plano.
echo RECALL: bloquea la IA que captura tu pantalla.
echo EDGE IA: quita la barra lateral inteligente de Edge.
echo DEVICE CENSUS: Windows no analiza tu hardware para Microsoft.
echo PROJECT ROME: sin seguimiento entre dispositivos.
echo.
echo ========= ELIMINADO EN v2 =========
echo.
echo SMARTSCREEN OFF: se quito de esta libreria porque
echo desactivarlo deja el PC sin proteccion contra malware.
echo No aporta FPS y si aporta riesgo.
echo.
pause
goto menu
