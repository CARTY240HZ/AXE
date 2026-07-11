@echo off
chcp 65001 >nul
color 0B
title CPU Optimization Tool PRO v2 - Gaming Edition

:: =====================================================
:: CHECK ADMIN (bcdedit y reg HKLM lo requieren)
:: =====================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    cls
    echo =========================================
    echo   SE REQUIEREN PERMISOS DE ADMINISTRADOR
    echo =========================================
    echo.
    echo CLICK DERECHO en el archivo y elige
    echo "Ejecutar como administrador"
    echo.
    pause
    exit
)

:menu
cls
echo =========================================
echo         CPU OPTIMIZATION TOOL v2
echo =========================================
echo.
echo 1 - Optimizar BASICO (Seguro - solo registro)
echo 2 - Optimizar AVANZADO (Timers + Core Parking)
echo 3 - Revertir BASICO
echo 4 - Revertir AVANZADO
echo 5 - Ver que hace cada tweak
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
echo    APLICANDO OPTIMIZACION BASICA CPU
echo =========================================
echo.

call :backup_regs
call :basic_core

echo.
echo =========================================
echo    OPTIMIZACION BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: OPTIMIZACION AVANZADA
:: =====================================================
:advanced
cls
echo =========================================
echo    APLICANDO OPTIMIZACION AVANZADA CPU
echo =========================================
echo.

call :backup_regs
call :basic_core

echo [EXTRA 1] Desactivando dynamic tick (timer mas estable)...
bcdedit /set disabledynamictick yes >nul

echo [EXTRA 2] Sincronizando TSC entre nucleos...
bcdedit /set tscsyncpolicy Enhanced >nul

echo [EXTRA 3] Desactivando Core Parking (nucleos siempre activos)...
powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE >nul 2>&1
powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100 >nul 2>&1
powercfg -setdcvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100 >nul 2>&1
powercfg -setactive scheme_current >nul 2>&1

echo [EXTRA 4] Activando plan de energia Alto Rendimiento...
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c >nul 2>&1

echo.
echo NOTA: reinicia el PC para que los cambios de bcdedit apliquen.
echo.
echo =========================================
echo    OPTIMIZACION AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: REVERTIR BASICO
:: =====================================================
:revert_basic
cls
echo =========================================
echo      RESTAURANDO CPU (BASICO)
echo =========================================
echo.

call :revert_basic_core

echo.
echo =========================================
echo    RESTAURACION BASICA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: REVERTIR AVANZADO
:: =====================================================
:revert_advanced
cls
echo =========================================
echo    RESTAURANDO CPU (AVANZADO)
echo =========================================
echo.

call :revert_basic_core

echo [EXTRA] Restaurando dynamic tick...
bcdedit /deletevalue disabledynamictick >nul 2>&1

echo [EXTRA] Restaurando sincronizacion TSC...
bcdedit /deletevalue tscsyncpolicy >nul 2>&1

echo [EXTRA] Restaurando Core Parking (valores por defecto)...
powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 0 >nul 2>&1
powercfg -setdcvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 0 >nul 2>&1
powercfg -setactive scheme_current >nul 2>&1

echo [EXTRA] Restaurando plan de energia Equilibrado...
powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e >nul 2>&1

echo.
echo NOTA: reinicia el PC para completar la restauracion.
echo.
echo =========================================
echo    RESTAURACION AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: BACKUP DE CLAVES ANTES DE TOCAR NADA
:: =====================================================
:backup_regs
if not exist "%~dp0Backups" mkdir "%~dp0Backups"
reg export "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" "%~dp0Backups\PriorityControl.reg" /y >nul 2>&1
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "%~dp0Backups\SystemProfile.reg" /y >nul 2>&1
echo [OK] Backup de registro guardado en carpeta Backups
exit /b

:: =====================================================
:: CORE BASICO
:: =====================================================
:basic_core
echo [1/4] Priorizando ventana activa (juego en primer plano)...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 38 /f >nul

echo [2/4] Liberando CPU reservada para multimedia...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 0 /f >nul

echo [3/4] Desactivando Power Throttling...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" /v PowerThrottlingOff /t REG_DWORD /d 1 /f >nul

echo [4/4] Desactivando FTH (micro-tirones)...
reg add "HKLM\SOFTWARE\Microsoft\FTH" /v Enabled /t REG_DWORD /d 0 /f >nul
exit /b

:: =====================================================
:: CORE REVERTIR BASICO (valores por defecto de Windows)
:: =====================================================
:revert_basic_core
echo [1/4] Restaurando prioridad de ventana...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 2 /f >nul

echo [2/4] Restaurando CPU multimedia...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 20 /f >nul

echo [3/4] Restaurando Power Throttling...
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" /v PowerThrottlingOff /f >nul 2>&1

echo [4/4] Restaurando FTH...
reg add "HKLM\SOFTWARE\Microsoft\FTH" /v Enabled /t REG_DWORD /d 1 /f >nul
exit /b

:: =====================================================
:: INFO
:: =====================================================
:info
cls
echo =========================================
echo         INFORMACION DE TWEAKS CPU
echo =========================================
echo.
echo [BASICO - solo registro, 100%% reversible]
echo Win32PrioritySeparation 38 -^> Prioriza el juego en primer plano
echo SystemResponsiveness 0     -^> No reserva CPU para tareas de fondo
echo PowerThrottlingOff         -^> Evita que Windows limite frecuencia
echo FTH OFF                    -^> Elimina heap de tolerancia a fallos
echo.
echo [AVANZADO - requiere reinicio]
echo Dynamic Tick OFF   -^> Timer del sistema constante, menos jitter
echo TSC Sync Enhanced  -^> Sincroniza contador de tiempo entre nucleos
echo Core Parking OFF   -^> Nucleos siempre despiertos, menos latencia
echo Plan Alto Rendim.  -^> CPU no baja de frecuencia en idle
echo.
echo [ELIMINADOS EN v2 - eran riesgo o placebo]
echo useplatformtick    -^> EMPEORA latencia en hardware moderno
echo hypervisor OFF     -^> Rompe WSL2/Docker/aislamiento del nucleo
echo CoalescingTimer    -^> Clave no documentada, sin efecto medible
echo EnergyDrv OFF      -^> Ese servicio no existe en Windows 11
echo.
echo Pulsa cualquier tecla para volver al menu...
pause >nul
goto menu
