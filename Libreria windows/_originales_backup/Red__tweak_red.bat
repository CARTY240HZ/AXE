@echo off
chcp 65001 >nul
color 0A
title MEJORA WINDOWS: NETWORK EDITION by ELMAXI

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
:: MENU PRINCIPAL
:: =====================================================
:menu
cls
echo ==========================================
echo   MEJORA WINDOWS: NETWORK EDITION
echo              by ELMAXI
echo ==========================================
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

echo [1/4] Activando RSS...
netsh interface tcp set global rss=enabled >nul 2>&1
echo -^> Usa varios nucleos CPU para procesar red

echo [2/4] Optimizando DNS...
netsh interface ip set dns name="Ethernet" static 1.1.1.1 >nul 2>&1
netsh interface ip add dns name="Ethernet" 8.8.8.8 index=2 >nul 2>&1
echo -^> Mejora resolucion de dominios

echo [3/4] Ajustando prioridad de red...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /t REG_DWORD /d 4294967295 /f >nul 2>&1
echo -^> Elimina limitaciones de ancho de banda multimedia

echo [4/4] Optimizacion TCP basica...
reg add "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /t REG_DWORD /d 65534 /f >nul 2>&1
echo -^> Aumenta conexiones simultaneas disponibles

echo.
echo MODO BASICO COMPLETADO
pause
goto menu

:: =====================================================
:: MODO COMPETITIVO
:: =====================================================
:competitive
cls
echo ==========================================
echo    MODO COMPETITIVO ACTIVADO
echo ==========================================

echo [1/3] Activando perfil TCP gaming...
netsh int tcp set supplemental template=internet congestionprovider=ctcp >nul 2>&1
echo -^> Mejora estabilidad en juegos online

echo [2/3] Ajustando prioridad multimedia...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 10 /f >nul 2>&1
echo -^> Reduce latencia en procesos activos

echo [3/3] Limpieza DNS...
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

echo [1/4] Restaurando DNS automatico...
netsh interface ip set dns name="Ethernet" source=dhcp >nul 2>&1
echo -^> DNS restaurado a configuracion automatica

echo [2/4] Restaurando AutoTuning...
netsh int tcp set global autotuninglevel=normal >nul 2>&1
echo -^> Configuracion TCP restaurada

echo [3/4] Restaurando RSS...
netsh int tcp set global rss=default >nul 2>&1
echo -^> RSS vuelto a valores por defecto

echo [4/4] Eliminando tweaks basicos...
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v NetworkThrottlingIndex /f >nul 2>&1
reg delete "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" /v MaxUserPort /f >nul 2>&1
echo -^> Tweaks eliminados correctamente

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

echo [1/3] Restaurando TCP default...
netsh int tcp set supplemental template=internet congestionprovider=cubic >nul 2>&1
echo -^> Vuelve al algoritmo estandar de Windows

echo [2/3] Restaurando prioridad multimedia...
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" /v SystemResponsiveness /t REG_DWORD /d 20 /f >nul 2>&1
echo -^> Equilibra carga del sistema

echo [3/3] Limpieza DNS...
ipconfig /flushdns >nul 2>&1
echo -^> Limpia cache de red

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
echo Permite que tu procesador ayude a gestionar el internet.
echo Evita tirones si estas descargando y jugando a la vez.
echo.
echo [DNS 1.1.1.1 / 8.8.8.8]
echo Cambia la ruta por la que te conectas a las webs.
echo Hace que las paginas carguen mas rapido y baja el ping.
echo.
echo [NetworkThrottling (Limite de Red)]
echo Windows limita tu internet por defecto para ahorrar recursos.
echo Esto lo desactiva para darte el 100%% de tu velocidad real.
echo.
echo [MaxUserPort (Puertos TCP)]
echo Abre mas caminos invisibles para que fluyan los datos.
echo Perfecto para que no se sature la red con muchas apps abiertas.
echo.
echo [CTCP (Congestion Gaming)]
echo Es un algoritmo especial que estabiliza tu conexion.
echo Evita que el ping te pegue subidas raras en medio de la partida.
echo.
echo [SystemResponsiveness (Prioridad)]
echo Le dice a Windows que le de maxima prioridad a tu juego
echo frente a otras tareas secundarias que esten de fondo.
echo.
pause
goto menu