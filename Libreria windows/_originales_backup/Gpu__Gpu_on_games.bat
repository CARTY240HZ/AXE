@echo off
color 0C
title GPU Optimization Tool - Apply Mode

:: =====================================================
:: GPU OPTIMIZATION - MODO APLICAR
:: Esto ajusta Windows para dar mas rendimiento en juegos
:: =====================================================

echo =========================================
echo      OPTIMIZACION GPU (MODO RENDIMIENTO)
echo =========================================
echo.

:: -----------------------------------------------------
:: 1. MEJOR GESTION DE LA GPU
:: Esto hace que Windows gestione mejor la tarjeta grafica
:: -----------------------------------------------------
echo [1/3] Activando mejora de GPU...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /t REG_DWORD /d 2 /f >nul 2>&1

:: -----------------------------------------------------
:: 2. MAS PRIORIDAD PARA JUEGOS
:: Los juegos tienen preferencia frente a otras tareas
:: -----------------------------------------------------
echo [2/3] Dando prioridad a juegos...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v GPU Priority /t REG_DWORD /d 8 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v Priority /t REG_DWORD /d 6 /f >nul 2>&1

:: -----------------------------------------------------
:: 3. MEJORA PEQUEÑA EN JUEGOS ONLINE
:: Reduce limitaciones internas de red de Windows
:: -----------------------------------------------------
echo [3/3] Ajustando red para juegos...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f >nul 2>&1

echo.
echo =========================================
echo   LISTO: MODO RENDIMIENTO ACTIVADO
echo =========================================
echo.

:: -----------------------------------------------------
:: EXPLICACION SIMPLE
:: -----------------------------------------------------
:: HwSchMode = mejora como Windows usa la GPU
:: GPU Priority = da mas importancia a juegos
:: NetworkThrottlingIndex = reduce limites en juegos online

pause