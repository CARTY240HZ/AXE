@echo off
chcp 65001 >nul
color 0A
title MEJORA WINDOWS: NETWORK EDITION v2 by ELMAXI

:: =====================================================
:: CHECK ADMIN
:: =====================================================
net session >nul 2>&1
if %errorlevel% neq 0 (
    cls
    echo ==========================================
    echo   SE REQUIEREN PERMISOS DE ADMINISTRADOR
    echo ==========================================
    pause
    exit
)

:: =====================================================
:: DETECTAR ADAPTADOR ACTIVO (v2)
:: La version anterior asumia que se llamaba "Ethernet".
:: Fallaba con Wi-Fi o nombres en espanol. Ahora se detecta
:: el adaptador con la ruta por defecto (el que usa internet).
:: =====================================================
set "IFNAME="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1).InterfaceAlias"`) do set "IFNAME=%%i"

:menu
cls
echo ==========================================
echo   MEJORA WINDOWS: NETWORK EDITION v2
echo              by ELMAXI
echo ==========================================
echo.
if defined IFNAME (echo  Adaptador detectado: %IFNAME%) else (echo  AVISO: no se detecto adaptador activo)
echo.
echo  1 - Modo Basico
echo  2 - Modo Competitivo
echo  3 - Revertir Modo Basico
echo  4 - Revertir Modo Competitivo
echo  5 - Informacion de Tweaks
echo  0 - Salir
echo.
set /p opcion=Selecciona una opcion:

if "%opcion%"=="1" goto basic
if "%opcion%"=="2" goto competitive
if "%opcion%"=="3" goto revert_basic
if "%opcion%"=="4" goto revert_competitive
if "%opcion%"=="5" goto info
if "%opcion%"=="0" exit

goto menu

:: =====================================================
:: MODO BASICO
:: =====================================================
:basic
cls
echo ==========================================
echo      APLICANDO MODO BASICO
echo ==========================================

if not exist "%~dp0Backups" mkdir "%~dp0Backups"
reg export "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "%~dp0Backups\SystemProfile.reg" /y >nul 2>&1
reg export "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" "%~dp0Backups\TcpipParameters.reg" /y >nul 2>&1

echo [1/4] Activando RSS...
netsh interface tcp set global rss=enabled >nul 2>&1
echo -^> Usa varios nucleos CPU para procesar red

echo [2/4] Configurando DNS rapidos (Cloudflare + Google)...
if defined IFNAME (
    netsh interface ip set dns name="%IFNAME%" static 1.1.1.1 >nul 2>&1
    netsh interface ip add dns name="%IFNAME%" 8.8.8.8 index=2 >nul 2>&1
    echo -^> DNS aplicado en "%IFNAME%"
) else (
    echo -^> OMITIDO: no hay adaptador detectado
)

echo [3/4] Quitando limite de red multimedia...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f >nul 2>&1
echo -^> Elimina limitaciones de ancho de banda multimedia

echo [4/4] Ampliando puertos TCP disponibles...
reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /t REG_DWORD /d 65534 /f >nul 2>&1
echo -^> Aumenta conexiones simultaneas disponibles

echo.
echo MODO BASICO COMPLETADO
pause
goto menu

:: =====================================================
:: MODO COMPETITIVO
:: (Nota v2: se quito SystemResponsiveness de aqui para
::  no pisar el valor que aplica el script de CPU.)
:: =====================================================
:competitive
cls
echo ==========================================
echo    MODO COMPETITIVO
echo ==========================================

echo [1/2] Activando perfil TCP CTCP...
netsh int tcp set supplemental template=internet congestionprovider=ctcp >nul 2>&1
echo -^> Algoritmo de congestion mas estable para online

echo [2/2] Limpieza DNS...
ipconfig /flushdns >nul 2>&1
echo -^> Refresca resolucion de red

echo.
echo MODO COMPETITIVO COMPLETADO
pause
goto menu

:: =====================================================
:: REVERTIR MODO BASICO
:: =====================================================
:revert_basic
cls
echo ==========================================
echo    REVERTIENDO MODO BASICO
echo ==========================================

echo [1/3] Restaurando DNS automatico...
if defined IFNAME (
    netsh interface ip set dns name="%IFNAME%" source=dhcp >nul 2>&1
    echo -^> DNS de "%IFNAME%" en automatico
) else (
    echo -^> OMITIDO: no hay adaptador detectado
)

echo [2/3] Restaurando RSS a valor por defecto...
netsh int tcp set global rss=default >nul 2>&1

echo [3/3] Eliminando tweaks de registro...
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /f >nul 2>&1
reg delete "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /f >nul 2>&1
echo -^> Registro limpio (Windows usa sus defaults)

echo.
echo MODO BASICO REVERTIDO
pause
goto menu

:: =====================================================
:: REVERTIR MODO COMPETITIVO
:: =====================================================
:revert_competitive
cls
echo ==========================================
echo  REVERTIENDO MODO COMPETITIVO
echo ==========================================

echo [1/2] Restaurando algoritmo TCP por defecto (cubic)...
netsh int tcp set supplemental template=internet congestionprovider=cubic >nul 2>&1

echo [2/2] Limpieza DNS...
ipconfig /flushdns >nul 2>&1

echo.
echo MODO COMPETITIVO REVERTIDO
pause
goto menu

:: =====================================================
:: INFO
:: =====================================================
:info
cls
echo ==========================================
echo        EXPLICACION PARA SUBS
echo ==========================================
echo.
echo [RSS (Escalado de Red)]
echo Reparte el trafico de red entre varios nucleos de CPU.
echo Evita tirones si descargas y juegas a la vez.
echo.
echo [DNS 1.1.1.1 / 8.8.8.8]
echo Servidores DNS rapidos. Las webs resuelven antes.
echo (v2: se aplica al adaptador REAL detectado, ya no
echo  falla si usas Wi-Fi o tu adaptador tiene otro nombre)
echo.
echo [NetworkThrottling OFF]
echo Windows limita paquetes de red cuando hay multimedia.
echo Esto lo desactiva para latencia estable en juego.
echo.
echo [MaxUserPort]
echo Mas puertos TCP disponibles para conexiones simultaneas.
echo.
echo [CTCP]
echo Algoritmo de congestion que recupera mas rapido tras
echo perdida de paquetes. Ping mas estable en partida.
echo.
echo [ELIMINADO EN v2]
echo SystemResponsiveness ya no se toca aqui: lo gestiona
echo el script de CPU para evitar valores contradictorios.
echo.
pause
goto menu
