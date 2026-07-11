@echo off
color 0A
title Windows Cleanup Tool - Nivel 1

:: =====================================================
:: LIMPIEZA BASICA DE WINDOWS (EXPLICADO FACIL)
:: Este script borra basura del sistema para liberar espacio
:: =====================================================

echo =========================================
echo        LIMPIEZA BASICA DEL SISTEMA
echo =========================================
echo.

:: -----------------------------------------------------
:: 1. BORRA ARCHIVOS BASURA DEL USUARIO
:: Esto elimina archivos temporales que generan los programas
:: Es como vaciar una papelera invisible del PC
:: -----------------------------------------------------
echo [1/5] Limpiando basura del usuario...
del /s /f /q "%temp%\*" >nul 2>&1

:: -----------------------------------------------------
:: 2. BORRA BASURA DE WINDOWS
:: Son archivos temporales del propio sistema
:: Windows los crea pero no siempre los necesita
:: -----------------------------------------------------
echo [2/5] Limpiando basura de Windows...
del /s /f /q "C:\Windows\Temp\*" >nul 2>&1

:: -----------------------------------------------------
:: 3. LIMPIA CACHE DE ARRANQUE (PREFETCH)
:: Son archivos que ayudan a abrir programas mas rapido
:: Se eliminan y Windows los vuelve a crear solo
:: -----------------------------------------------------
echo [3/5] Limpiando cache de arranque...
del /s /f /q "C:\Windows\Prefetch\*" >nul 2>&1

:: -----------------------------------------------------
:: 4. LIMPIA ACTUALIZACIONES DE WINDOWS
:: Borra restos de actualizaciones descargadas
:: Sirve para liberar espacio
:: -----------------------------------------------------
echo [4/5] Limpiando cache de actualizaciones...
net stop wuauserv >nul 2>&1
del /s /f /q "C:\Windows\SoftwareDistribution\Download\*" >nul 2>&1
net start wuauserv >nul 2>&1

:: -----------------------------------------------------
:: 5. LIMPIA INTERNET (DNS)
:: Es como borrar la memoria de paginas web
:: Puede ayudar si algo de internet falla
:: -----------------------------------------------------
echo [5/5] Limpiando cache de internet...
ipconfig /flushdns >nul 2>&1

echo.
echo =========================================
echo        LISTO, PC LIMPIO
echo =========================================
echo.

:: -----------------------------------------------------
:: EXPLICACION MUY SIMPLE DE LO TECNICO
:: -----------------------------------------------------

:: >nul 2>&1
:: = “no mostrar mensajes en pantalla”
:: (para que se vea limpio y sin errores)

:: del /s /f /q
:: = “borra todo sin preguntar”

:: net stop / start
:: = “apaga y enciende un servicio de Windows”

pause