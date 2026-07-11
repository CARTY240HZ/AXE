@echo off
chcp 65001 >nul
color 0B
title CPU Optimization Tool PRO

------------------------------------------------------

:menu
cls
echo =========================================
echo         CPU OPTIMIZATION TOOL
echo =========================================
echo.
echo 1 - Optimizar BASICO (Seguro)
echo 2 - Optimizar AVANZADO (Pro)
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
echo MODO AVANZADO: puede afectar estabilidad.
pause

call :basic_core

echo [EXTRA 1] Ajustando temporizadores...
timeout /t 1 >nul
bcdedit /set disabledynamictick yes
bcdedit /set useplatformtick yes

echo [EXTRA 2] Eliminando agrupacion de tareas...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel" /v CoalescingTimerDisabled /t REG_DWORD /d 1 /f

echo [EXTRA 3] Desactivando Core Parking...
timeout /t 1 >nul
powercfg -attributes SUB_PROCESSOR 0cc5b647-c1df-4637-891a-dec35c318583 -ATTRIB_HIDE
powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100
powercfg -setdcvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 100
powercfg -setactive scheme_current

echo [EXTRA 4] Desactivando virtualizacion (VBS)...
timeout /t 1 >nul
bcdedit /set hypervisorlaunchtype off

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

echo [EXTRA] Restaurando temporizadores...
timeout /t 1 >nul
bcdedit /deletevalue disabledynamictick
bcdedit /deletevalue useplatformtick

echo [EXTRA] Restaurando coalescing...
timeout /t 1 >nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Kernel" /v CoalescingTimerDisabled /f

echo [EXTRA] Restaurando Core Parking...
timeout /t 1 >nul
powercfg -setacvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 0
powercfg -setdcvalueindex scheme_current sub_processor 0cc5b647-c1df-4637-891a-dec35c318583 0
powercfg -setactive scheme_current

echo [EXTRA] Restaurando virtualizacion...
timeout /t 1 >nul
bcdedit /set hypervisorlaunchtype auto

echo.
echo =========================================
echo    RESTAURACION AVANZADA COMPLETADA
echo =========================================
pause
goto menu

:: =====================================================
:: CORE BASICO
:: =====================================================
:basic_core
echo [1/6] Ajustando prioridad de CPU...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 38 /f

echo [2/6] Liberando CPU reservada...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 0 /f

echo [3/6] Desactivando limitaciones...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" /v PowerThrottlingOff /t REG_DWORD /d 1 /f

echo [4/6] Sincronizando nucleos CPU...
timeout /t 1 >nul
bcdedit /set tscsyncpolicy Enhanced

echo [5/6] Eliminando micro-tirones (FTH)...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\FTH" /v Enabled /t REG_DWORD /d 0 /f

echo [6/6] Reduciendo polling del sistema...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Services\EnergyDrv" /v Start /t REG_DWORD /d 4 /f
exit /b

:: =====================================================
:: CORE REVERTIR BASICO
:: =====================================================
:revert_basic_core
echo [1/6] Restaurando prioridad...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 2 /f

echo [2/6] Restaurando CPU reservada...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 20 /f

echo [3/6] Restaurando limitaciones...
timeout /t 1 >nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" /v PowerThrottlingOff /f

echo [4/6] Restaurando sincronizacion...
timeout /t 1 >nul
bcdedit /deletevalue tscsyncpolicy

echo [5/6] Restaurando FTH...
timeout /t 1 >nul
reg add "HKLM\SOFTWARE\Microsoft\FTH" /v Enabled /t REG_DWORD /d 1 /f

echo [6/6] Restaurando Energy Driver...
timeout /t 1 >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Services\EnergyDrv" /v Start /t REG_DWORD /d 3 /f
exit /b

:info
cls
echo =========================================
echo         INFORMACION DE TWEAKS CPU
echo =========================================
echo.

echo [BASICO]
echo Win32PrioritySeparation -^> Prioriza apps/juegos activos
echo SystemResponsiveness    -^> Libera CPU reservada
echo PowerThrottlingOff      -^> Evita limitaciones
echo TSC Sync Policy         -^> Sincroniza nucleos
echo FTH Disable             -^> Reduce micro-tirones
echo Energy Driver OFF       -^> Reduce carga en segundo plano

echo.
echo [AVANZADO]
echo Timer Resolution        -^> Mejora latencia
echo Coalescing Timer OFF    -^> Evita agrupacion de tareas
echo Core Parking OFF        -^> CPU siempre activa
echo Hypervisor OFF          -^> Reduce input lag

echo.
echo Pulsa cualquier tecla para volver al menu...
pause >nul
goto menu