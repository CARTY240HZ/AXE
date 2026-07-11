@echo off
color 0A
title Optimizador de Servicios PRO

:: =====================================================
:: MENU PRINCIPAL
:: =====================================================
:menu
cls
echo =========================================
echo   OPTIMIZADOR DE SERVICIOS WINDOWS
echo =========================================
echo.
echo 1 - Optimizar BASICO
echo 2 - Optimizar AVANZADO
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
:: OPTIMIZACION BASICA
:: =====================================================
:basic
cls
echo =========================================
echo   APLICANDO OPTIMIZACION BASICA
echo =========================================
echo.

echo [1/5] Optimizando sistema...
timeout /t 1 >nul
sc config SysMain start= disabled >nul 2>&1
sc config PcaSvc start= disabled >nul 2>&1
sc config DPS start= disabled >nul 2>&1
sc config AppReadiness start= disabled >nul 2>&1

echo [2/5] Eliminando telemetria...
timeout /t 1 >nul
sc config DiagTrack start= disabled >nul 2>&1
sc config dmwappushservice start= disabled >nul 2>&1
sc config WerSvc start= disabled >nul 2>&1

echo [3/5] Eliminando servicios innecesarios...
timeout /t 1 >nul
sc config Fax start= disabled >nul 2>&1
sc config RetailDemo start= disabled >nul 2>&1
sc config TabletInputService start= disabled >nul 2>&1

echo [4/5] Ajustando sistema secundario...
timeout /t 1 >nul
sc config SensorService start= disabled >nul 2>&1
sc config SensorDataService start= disabled >nul 2>&1
sc config SensrSvc start= disabled >nul 2>&1

echo [5/5] Optimizando red y gaming...
timeout /t 1 >nul
sc config CDPSvc start= disabled >nul 2>&1
sc config WpnService start= disabled >nul 2>&1
sc config icssvc start= disabled >nul 2>&1

echo.
echo =========================================
echo   OPTIMIZACION BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: OPTIMIZACION AVANZADA
:: =====================================================
:advanced
cls
echo =========================================
echo   APLICANDO OPTIMIZACION AVANZADA
echo =========================================
echo.

call :basic_core

echo [EXTRA 1] Servicios legacy...
timeout /t 1 >nul
sc config TrkWks start= disabled >nul 2>&1
sc config SCardSvr start= disabled >nul 2>&1
sc config ScDeviceEnum start= disabled >nul 2>&1
sc config PhoneSvc start= disabled >nul 2>&1
sc config SharedRealitySvc start= disabled >nul 2>&1
sc config WalletService start= disabled >nul 2>&1

echo [EXTRA 2] Escritorio remoto...
timeout /t 1 >nul
sc config TermService start= disabled >nul 2>&1
sc config UmRdpService start= disabled >nul 2>&1

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
echo   RESTAURANDO SISTEMA BASICO
echo =========================================
echo.

echo [1/5] Restaurando sistema...
timeout /t 1 >nul
sc config SysMain start= auto >nul 2>&1
sc config PcaSvc start= manual >nul 2>&1
sc config DPS start= auto >nul 2>&1
sc config AppReadiness start= demand >nul 2>&1

echo [2/5] Restaurando telemetria...
timeout /t 1 >nul
sc config DiagTrack start= auto >nul 2>&1
sc config dmwappushservice start= manual >nul 2>&1
sc config WerSvc start= manual >nul 2>&1

echo [3/5] Restaurando servicios...
timeout /t 1 >nul
sc config Fax start= manual >nul 2>&1
sc config RetailDemo start= manual >nul 2>&1
sc config TabletInputService start= manual >nul 2>&1

echo [4/5] Restaurando sensores...
timeout /t 1 >nul
sc config SensorService start= manual >nul 2>&1
sc config SensorDataService start= manual >nul 2>&1
sc config SensrSvc start= manual >nul 2>&1

echo [5/5] Restaurando red...
timeout /t 1 >nul
sc config CDPSvc start= auto >nul 2>&1
sc config WpnService start= auto >nul 2>&1
sc config icssvc start= manual >nul 2>&1

echo.
echo =========================================
echo   RESTAURACION BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: REVERTIR AVANZADO
:: =====================================================
:revert_advanced
cls
echo =========================================
echo   RESTAURANDO SISTEMA AVANZADO
echo =========================================
echo.

call :revert_basic

echo [EXTRA] Restaurando servicios avanzados...
timeout /t 1 >nul
sc config TrkWks start= auto >nul 2>&1
sc config SCardSvr start= manual >nul 2>&1
sc config ScDeviceEnum start= manual >nul 2>&1
sc config PhoneSvc start= manual >nul 2>&1
sc config SharedRealitySvc start= manual >nul 2>&1
sc config WalletService start= manual >nul 2>&1

sc config TermService start= manual >nul 2>&1
sc config UmRdpService start= manual >nul 2>&1

echo.
echo =========================================
echo   RESTAURACION AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: INFORMACION DE SERVICIOS
:: =====================================================
:info
cls
echo =========================================
echo   QUE HACE CADA SERVICIO (RESUMEN)
echo =========================================
echo.

echo SysMain - Optimiza carga de apps (puede usar disco en segundo plano)
echo PcaSvc - Analiza compatibilidad de programas
echo DPS - Diagnostico de problemas de Windows
echo AppReadiness - Prepara apps al iniciar sesion

echo.
echo DiagTrack - Telemetria de Windows
echo dmwappushservice - Envio de datos del sistema
echo WerSvc - Reporte de errores a Microsoft

echo.
echo Fax - Servicio obsoleto de fax
echo RetailDemo - Modo demostracion de tiendas
echo TabletInputService - Teclado tactil

echo.
echo SensorService - Sensores del dispositivo
echo SensorDataService - Datos de sensores
echo SensrSvc - Servicio general de sensores

echo.
echo RemoteRegistry - Acceso remoto al registro
echo MapsBroker - Mapas offline

echo.
echo CDPSvc - Sincronizacion de dispositivos
echo WpnService - Notificaciones de Windows
echo icssvc - Compartir internet

echo.
echo TrkWks - Enlaces de red distribuidos
echo SCardSvr - Tarjetas inteligentes
echo ScDeviceEnum - Dispositivos inteligentes
echo PhoneSvc - Conexion con telefono

echo SharedRealitySvc - Realidad mixta / VR
echo WalletService - Cartera de Windows
echo TermService - Escritorio remoto
echo UmRdpService - Soporte RDP

echo.
echo =========================================
echo IMPORTANTE:
echo Algunos servicios pueden afectar red,
echo rendimiento o funciones del sistema.
echo =========================================
pause
goto menu

:: =====================================================
:: CORE BASICO
:: =====================================================
:basic_core
sc config SysMain start= disabled >nul 2>&1
sc config PcaSvc start= disabled >nul 2>&1
sc config DPS start= disabled >nul 2>&1
sc config AppReadiness start= disabled >nul 2>&1
sc config DiagTrack start= disabled >nul 2>&1
sc config dmwappushservice start= disabled >nul 2>&1
sc config WerSvc start= disabled >nul 2>&1
sc config Fax start= disabled >nul 2>&1
sc config RetailDemo start= disabled >nul 2>&1
sc config TabletInputService start= disabled >nul 2>&1
sc config SensorService start= disabled >nul 2>&1
sc config SensorDataService start= disabled >nul 2>&1
sc config SensrSvc start= disabled >nul 2>&1
sc config RemoteRegistry start= disabled >nul 2>&1
sc config MapsBroker start= disabled >nul 2>&1
sc config CDPSvc start= disabled >nul 2>&1
sc config WpnService start= disabled >nul 2>&1
sc config icssvc start= disabled >nul 2>&1
exit /b