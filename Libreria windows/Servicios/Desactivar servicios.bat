@echo off
chcp 65001 >nul
color 0A
title Optimizador de Servicios PRO v2

:: =====================================================
:: CHECK ADMIN (sc config lo requiere)
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
echo   OPTIMIZADOR DE SERVICIOS WINDOWS v2
echo =========================================
echo.
echo 1 - Optimizar BASICO (seguro, sin perder funciones)
echo 2 - Optimizar AVANZADO (quita notificaciones, sensores,
echo     teclado tactil, escritorio remoto... lee opcion 5)
echo 3 - Revertir BASICO
echo 4 - Revertir AVANZADO
echo 5 - Ver que hace cada servicio
echo 0 - Salir
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
:: OPTIMIZACION BASICA (sin impacto funcional visible)
:: =====================================================
:basic
cls
echo =========================================
echo   APLICANDO OPTIMIZACION BASICA
echo =========================================
echo.

call :basic_core

echo.
echo =========================================
echo   OPTIMIZACION BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: OPTIMIZACION AVANZADA (impacto funcional, reversible)
:: =====================================================
:advanced
cls
echo =========================================
echo   APLICANDO OPTIMIZACION AVANZADA
echo =========================================
echo.
echo AVISO: perderas notificaciones de Windows, teclado
echo tactil, sensores (brillo/rotacion en portatil),
echo Phone Link y escritorio remoto. Todo es reversible
echo con la opcion 4.
echo.
pause

call :basic_core
call :advanced_core

echo.
echo =========================================
echo   OPTIMIZACION AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: REVERTIR BASICO
:: =====================================================
:revert_basic
cls
echo =========================================
echo   RESTAURANDO SERVICIOS (BASICO)
echo =========================================
echo.

call :revert_basic_core

echo.
echo =========================================
echo   RESTAURACION BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: REVERTIR AVANZADO
:: (Nota v2: la version anterior hacia "call :revert_basic"
::  que saltaba al menu y NUNCA ejecutaba la restauracion
::  avanzada. Ahora usa subrutinas core que si retornan.)
:: =====================================================
:revert_advanced
cls
echo =========================================
echo   RESTAURANDO SERVICIOS (AVANZADO)
echo =========================================
echo.

call :revert_basic_core
call :revert_advanced_core

echo.
echo =========================================
echo   RESTAURACION AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: CORE BASICO - telemetria y servicios obsoletos
:: =====================================================
:basic_core
echo [1/3] Desactivando telemetria...
sc config DiagTrack start= disabled >nul 2>&1
sc config dmwappushservice start= disabled >nul 2>&1
sc config WerSvc start= disabled >nul 2>&1

echo [2/3] Desactivando servicios obsoletos...
sc config Fax start= disabled >nul 2>&1
sc config RetailDemo start= disabled >nul 2>&1
sc config MapsBroker start= disabled >nul 2>&1
sc config TrkWks start= disabled >nul 2>&1
sc config RemoteRegistry start= disabled >nul 2>&1

echo [3/3] Desactivando analisis en segundo plano...
sc config SysMain start= disabled >nul 2>&1
sc config PcaSvc start= disabled >nul 2>&1
sc config DPS start= disabled >nul 2>&1
exit /b

:: =====================================================
:: CORE AVANZADO - servicios con impacto funcional
:: =====================================================
:advanced_core
echo [EXTRA 1] Interfaz tactil y sensores...
sc config TabletInputService start= disabled >nul 2>&1
sc config SensorService start= disabled >nul 2>&1
sc config SensorDataService start= disabled >nul 2>&1
sc config SensrSvc start= disabled >nul 2>&1

echo [EXTRA 2] Notificaciones y sincronizacion...
sc config WpnService start= disabled >nul 2>&1
sc config CDPSvc start= disabled >nul 2>&1
sc config PhoneSvc start= disabled >nul 2>&1

echo [EXTRA 3] Servicios poco usados...
sc config icssvc start= disabled >nul 2>&1
sc config SCardSvr start= disabled >nul 2>&1
sc config ScDeviceEnum start= disabled >nul 2>&1
sc config SharedRealitySvc start= disabled >nul 2>&1
sc config WalletService start= disabled >nul 2>&1
sc config AppReadiness start= disabled >nul 2>&1

echo [EXTRA 4] Escritorio remoto...
sc config TermService start= disabled >nul 2>&1
sc config UmRdpService start= disabled >nul 2>&1
exit /b

:: =====================================================
:: CORE REVERTIR BASICO (defaults reales de Windows 11)
:: =====================================================
:revert_basic_core
echo [1/3] Restaurando telemetria...
sc config DiagTrack start= auto >nul 2>&1
sc config dmwappushservice start= demand >nul 2>&1
sc config WerSvc start= demand >nul 2>&1

echo [2/3] Restaurando servicios...
sc config Fax start= demand >nul 2>&1
sc config RetailDemo start= demand >nul 2>&1
sc config MapsBroker start= demand >nul 2>&1
sc config TrkWks start= auto >nul 2>&1
:: RemoteRegistry se queda deshabilitado: es el default
:: de Windows 11 y tenerlo activo es un riesgo de seguridad.

echo [3/3] Restaurando analisis del sistema...
sc config SysMain start= auto >nul 2>&1
sc config PcaSvc start= auto >nul 2>&1
sc config DPS start= auto >nul 2>&1
exit /b

:: =====================================================
:: CORE REVERTIR AVANZADO (defaults reales de Windows 11)
:: =====================================================
:revert_advanced_core
echo [EXTRA] Restaurando tactil y sensores...
sc config TabletInputService start= demand >nul 2>&1
sc config SensorService start= demand >nul 2>&1
sc config SensorDataService start= demand >nul 2>&1
sc config SensrSvc start= demand >nul 2>&1

echo [EXTRA] Restaurando notificaciones y sincronizacion...
sc config WpnService start= auto >nul 2>&1
sc config CDPSvc start= auto >nul 2>&1
sc config PhoneSvc start= demand >nul 2>&1

echo [EXTRA] Restaurando servicios varios...
sc config icssvc start= demand >nul 2>&1
sc config SCardSvr start= demand >nul 2>&1
sc config ScDeviceEnum start= demand >nul 2>&1
sc config SharedRealitySvc start= demand >nul 2>&1
sc config WalletService start= demand >nul 2>&1
sc config AppReadiness start= demand >nul 2>&1

echo [EXTRA] Restaurando escritorio remoto...
sc config TermService start= demand >nul 2>&1
sc config UmRdpService start= demand >nul 2>&1
exit /b

:: =====================================================
:: INFORMACION
:: =====================================================
:info
cls
echo =========================================
echo   QUE HACE CADA SERVICIO
echo =========================================
echo.
echo [BASICO - no pierdes ninguna funcion visible]
echo DiagTrack / dmwappush - Telemetria de Windows
echo WerSvc                - Reporte de errores a Microsoft
echo Fax / RetailDemo      - Servicios obsoletos
echo MapsBroker            - Mapas offline
echo TrkWks                - Enlaces distribuidos de red
echo RemoteRegistry        - Registro remoto (riesgo seguridad)
echo SysMain               - Precarga de apps (usa disco de fondo)
echo PcaSvc / DPS          - Analisis de compatibilidad/diagnostico
echo.
echo [AVANZADO - pierdes funciones, todo reversible]
echo TabletInputService    - Teclado tactil (PIERDES tactil)
echo Sensor*               - Brillo auto/rotacion (portatiles)
echo WpnService            - TODAS las notificaciones de Windows
echo CDPSvc / PhoneSvc     - Phone Link y dispositivos cercanos
echo icssvc                - Hotspot movil
echo SCardSvr / ScDevice   - Tarjetas inteligentes (DNIe, etc)
echo SharedRealitySvc      - Realidad mixta / VR de Windows
echo WalletService         - Cartera de Windows
echo AppReadiness          - Preparacion de apps Store al inicio
echo TermService / UmRdp   - Escritorio remoto
echo.
echo NOTA v2: los servicios con impacto funcional (notificaciones,
echo sensores, tactil) se movieron de BASICO a AVANZADO para que
echo el modo basico sea 100%% seguro en cualquier PC.
echo.
pause
goto menu
