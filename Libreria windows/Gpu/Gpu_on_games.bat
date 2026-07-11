@echo off
chcp 65001 >nul
color 0C
title GPU Optimization Tool v2 - Apply Mode

:: =====================================================
:: CHECK ADMIN
:: =====================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo SE REQUIEREN PERMISOS DE ADMINISTRADOR
    echo Click derecho -^> "Ejecutar como administrador"
    pause
    exit
)

echo =========================================
echo    OPTIMIZACION GPU (MODO RENDIMIENTO)
echo =========================================
echo.

:: Backup antes de tocar nada
if not exist "%~dp0Backups" mkdir "%~dp0Backups"
reg export "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "%~dp0Backups\GraphicsDrivers.reg" /y >nul 2>&1
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "%~dp0Backups\SystemProfile.reg" /y >nul 2>&1

:: -----------------------------------------------------
:: 1. HAGS - Programacion de GPU acelerada por hardware
:: Reduce latencia dejando que la GPU gestione su propia cola
:: (Solo tiene efecto si tu GPU y driver lo soportan)
:: -----------------------------------------------------
echo [1/3] Activando HAGS (programacion por hardware)...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /t REG_DWORD /d 2 /f >nul 2>&1

:: -----------------------------------------------------
:: 2. PRIORIDAD MMCSS PARA JUEGOS
:: Nota v2: los nombres con espacio DEBEN ir entre comillas.
:: La version anterior fallaba en silencio por esto.
:: -----------------------------------------------------
echo [2/3] Dando prioridad a juegos...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "GPU Priority" /t REG_DWORD /d 8 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Priority" /t REG_DWORD /d 6 /f >nul 2>&1

:: -----------------------------------------------------
:: 3. QUITAR LIMITADOR DE RED MULTIMEDIA
:: -----------------------------------------------------
echo [3/3] Ajustando red para juegos...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f >nul 2>&1

echo.
echo =========================================
echo   LISTO: MODO RENDIMIENTO ACTIVADO
echo =========================================
echo.
echo HAGS requiere REINICIAR el PC para aplicarse.
echo Si notas problemas, ejecuta Gpu_off_games.bat
echo.
pause
