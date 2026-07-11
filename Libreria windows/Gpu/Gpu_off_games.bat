@echo off
chcp 65001 >nul
color 0A
title GPU Optimization Tool v2 - Restore Mode

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
echo      RESTAURAR CONFIGURACION GPU
echo =========================================
echo.

:: -----------------------------------------------------
:: 1. HAGS a decision del driver (valor por defecto real)
:: Nota v2: el default de Windows es NO tener el valor,
:: no HwSchMode=1. Se elimina para volver al estado original.
:: -----------------------------------------------------
echo [1/3] Restaurando HAGS...
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /f >nul 2>&1

:: -----------------------------------------------------
:: 2. PRIORIDADES MMCSS A VALORES DE FABRICA
:: Nota v2: el default real de Windows es GPU Priority=8
:: y Priority=2 (la version anterior ponia 2/2, incorrecto).
:: -----------------------------------------------------
echo [2/3] Restaurando prioridades...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "GPU Priority" /t REG_DWORD /d 8 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v "Priority" /t REG_DWORD /d 2 /f >nul 2>&1

:: -----------------------------------------------------
:: 3. LIMITE DE RED MULTIMEDIA POR DEFECTO
:: -----------------------------------------------------
echo [3/3] Restaurando red...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 10 /f >nul 2>&1

echo.
echo =========================================
echo   SISTEMA RESTAURADO A NORMAL
echo =========================================
echo.
echo Reinicia el PC para que HAGS vuelva a su estado original.
echo.
pause
