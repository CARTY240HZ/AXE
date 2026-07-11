@echo off
chcp 65001 >nul
color 0A
title Windows Cleanup Tool v2 - Nivel 1

:: =====================================================
:: CHECK ADMIN (necesario para C:\Windows\Temp y wuauserv)
:: =====================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo SE REQUIEREN PERMISOS DE ADMINISTRADOR
    echo Click derecho -^> "Ejecutar como administrador"
    pause
    exit
)

echo =========================================
echo        LIMPIEZA BASICA DEL SISTEMA v2
echo =========================================
echo.

:: Espacio libre antes
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "[math]::Round((Get-PSDrive C).Free/1GB,2)"`) do set FREE_BEFORE=%%a

:: -----------------------------------------------------
:: 1. TEMPORALES DEL USUARIO
:: -----------------------------------------------------
echo [1/5] Limpiando temporales del usuario...
del /s /f /q "%temp%\*" >nul 2>&1
for /d %%d in ("%temp%\*") do rd /s /q "%%d" >nul 2>&1

:: -----------------------------------------------------
:: 2. TEMPORALES DE WINDOWS
:: -----------------------------------------------------
echo [2/5] Limpiando temporales de Windows...
del /s /f /q "C:\Windows\Temp\*" >nul 2>&1
for /d %%d in ("C:\Windows\Temp\*") do rd /s /q "%%d" >nul 2>&1

:: -----------------------------------------------------
:: 3. CACHE DE SHADERS DIRECTX
:: Windows y los juegos la regeneran solos.
:: Util si un juego tiene glitches graficos tras update de driver.
:: (Nota v2: se ELIMINO el borrado de Prefetch de la version
::  anterior porque ralentiza la apertura de programas.)
:: -----------------------------------------------------
echo [3/5] Limpiando cache de shaders DirectX...
del /s /f /q "%LOCALAPPDATA%\D3DSCache\*" >nul 2>&1

:: -----------------------------------------------------
:: 4. CACHE DE ACTUALIZACIONES DE WINDOWS
:: -----------------------------------------------------
echo [4/5] Limpiando cache de actualizaciones...
net stop wuauserv >nul 2>&1
net stop bits >nul 2>&1
del /s /f /q "C:\Windows\SoftwareDistribution\Download\*" >nul 2>&1
net start bits >nul 2>&1
net start wuauserv >nul 2>&1

:: -----------------------------------------------------
:: 5. CACHE DNS
:: -----------------------------------------------------
echo [5/5] Limpiando cache DNS...
ipconfig /flushdns >nul 2>&1

:: Espacio libre despues
for /f "usebackq delims=" %%a in (`powershell -NoProfile -Command "[math]::Round((Get-PSDrive C).Free/1GB,2)"`) do set FREE_AFTER=%%a

echo.
echo =========================================
echo        LISTO, PC LIMPIO
echo =========================================
echo.
echo Espacio libre antes:   %FREE_BEFORE% GB
echo Espacio libre ahora:   %FREE_AFTER% GB
echo.
pause
