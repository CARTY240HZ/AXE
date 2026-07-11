@echo off
color 0A
title GPU Optimization Tool - Restore Mode

:: =====================================================
:: GPU RESTORE - MODO NORMAL
:: Vuelve Windows a su configuracion original
:: Si algo no te gusta, ejecuta esto
:: =====================================================

echo =========================================
echo      RESTAURAR CONFIGURACION GPU
echo =========================================
echo.

:: -----------------------------------------------------
:: 1. VOLVER GPU A MODO NORMAL
:: Windows vuelve a gestionar la grafica automaticamente
:: -----------------------------------------------------
echo [1/3] Restaurando GPU...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v HwSchMode /t REG_DWORD /d 1 /f >nul 2>&1

:: -----------------------------------------------------
:: 2. QUITAR PRIORIDAD EXTRA A JUEGOS
:: Todo vuelve al sistema equilibrado de Windows
:: -----------------------------------------------------
echo [2/3] Restaurando prioridades...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v GPU Priority /t REG_DWORD /d 2 /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" /v Priority /t REG_DWORD /d 2 /f >nul 2>&1

:: -----------------------------------------------------
:: 3. VOLVER CONFIGURACION DE RED NORMAL
:: Windows vuelve a sus limites por defecto
:: -----------------------------------------------------
echo [3/3] Restaurando red...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 10 /f >nul 2>&1

echo.
echo =========================================
echo   SISTEMA RESTAURADO A NORMAL
echo =========================================
echo.

:: -----------------------------------------------------
:: EXPLICACION SIMPLE
:: -----------------------------------------------------
:: Este modo no mejora rendimiento, solo vuelve todo a como estaba
:: Usalo si notas problemas o quieres estabilidad total

pause