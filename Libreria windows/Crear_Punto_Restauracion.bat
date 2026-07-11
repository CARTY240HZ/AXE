@echo off
chcp 65001 >nul
color 0E
title Crear Punto de Restauracion - EJECUTAR ANTES DE OPTIMIZAR

:: =====================================================
:: RED DE SEGURIDAD DE LA LIBRERIA
:: Ejecuta esto UNA VEZ antes de aplicar cualquier tweak.
:: Si algo sale mal, podras volver a este punto desde:
:: Panel de control -> Recuperacion -> Restaurar sistema
:: =====================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    cls
    echo =========================================
    echo   SE REQUIEREN PERMISOS DE ADMINISTRADOR
    echo =========================================
    echo.
    echo CLICK DERECHO -^> "Ejecutar como administrador"
    pause
    exit
)

cls
echo =========================================
echo   CREANDO PUNTO DE RESTAURACION
echo =========================================
echo.
echo Esto puede tardar 1-2 minutos, no cierres la ventana...
echo.

:: Activar proteccion del sistema en C: (por si esta apagada)
powershell -NoProfile -NonInteractive -Command "Enable-ComputerRestore -Drive 'C:\' -ErrorAction SilentlyContinue"

:: Windows limita a 1 punto cada 24h; esta clave lo permite ahora
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" /v SystemRestorePointCreationFrequency /t REG_DWORD /d 0 /f >nul 2>&1

:: Crear el punto
powershell -NoProfile -NonInteractive -Command "Checkpoint-Computer -Description 'Antes de Libreria Windows Gaming' -RestorePointType MODIFY_SETTINGS; if ($?) { exit 0 } else { exit 1 }"

if %errorlevel% equ 0 (
    echo.
    echo =========================================
    echo   PUNTO DE RESTAURACION CREADO OK
    echo =========================================
    echo.
    echo Ya puedes aplicar los tweaks de la libreria.
    echo Para volver atras: buscar "Restaurar sistema"
    echo en el menu inicio y elegir el punto
    echo "Antes de Libreria Windows Gaming".
) else (
    echo.
    echo =========================================
    echo   NO SE PUDO CREAR EL PUNTO
    echo =========================================
    echo.
    echo Revisa que "Proteccion del sistema" este activada:
    echo Menu inicio -^> "Crear un punto de restauracion"
    echo -^> selecciona C: -^> Configurar -^> Activar.
)

echo.
pause
