@echo off
:: =====================================================
:: Launcher AXE - Elite Windows Optimizer
:: Se auto-eleva a admin y abre la GUI del motor unico (single source of truth).
:: Modos headless (sin GUI, sin admin necesariamente):
::   AXE.bat -SelfTest   -> validacion de integridad del catalogo
::   AXE.bat -List       -> estado real de cada tweak
::   AXE.bat -Export fichero.json
::   AXE.bat -Import fichero.json   (requiere admin)
::
:: ExecutionPolicy RemoteSigned: permite este script local; el
:: Unblock-File de abajo quita el Mark-of-the-Web si vino de un ZIP.
:: =====================================================

:: Preservar el modo headless sin pedir UAC: solo se eleva cuando una operacion realmente
:: necesita privilegios (la GUI y los comandos mutativos). Los modos de lectura salen antes.
set "AXEARGS=%*"
set "HEADLESS=0"
for %%A in (%AXEARGS%) do (
    if /I "%%~A"=="-SelfTest" set "HEADLESS=1"
    if /I "%%~A"=="-List" set "HEADLESS=1"
    if /I "%%~A"=="-Diag" set "HEADLESS=1"
    if /I "%%~A"=="-Measure" set "HEADLESS=1"
    if /I "%%~A"=="-Score" set "HEADLESS=1"
    if /I "%%~A"=="-Report" set "HEADLESS=1"
    if /I "%%~A"=="-TimerSweep" set "HEADLESS=1"
    if /I "%%~A"=="-Advice" set "HEADLESS=1"
    if /I "%%~A"=="-NetMon" set "HEADLESS=1"
    if /I "%%~A"=="-NetLoad" set "HEADLESS=1"
)

if "%HEADLESS%"=="0" (
    net session >nul 2>&1
    if %errorlevel% neq 0 (
        powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
        exit /b
    )
)

:: Quitar Mark-of-the-Web de TODO el arbol por si vino de un ZIP descargado. No basta con
:: desbloquear dist\AXE.ps1: los DLL de webview2\ (Microsoft.Web.WebView2.Core.dll y compania)
:: tambien llegan marcados y .NET se niega a cargarlos (0x80131515), aunque el .ps1 si arranque.
powershell -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"

:: El repo usa dist\AXE.ps1; el paquete de release lleva AXE.ps1 en la raiz. Resolver ambos
:: formatos aqui evita que el launcher dependa de una sola forma de distribucion.
set "AXEENGINE=%~dp0dist\AXE.ps1"
if not exist "%AXEENGINE%" set "AXEENGINE=%~dp0AXE.ps1"
if not exist "%AXEENGINE%" (
    echo AXE: no encuentro AXE.ps1 en dist\ ni en la raiz. 1>&2
    exit /b 1
)

:: Si hay argumentos, reenviarlos al .ps1 (modo CLI). Si no, abre GUI (admin ya concedido).
if "%AXEARGS%"=="" (
    powershell -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%AXEENGINE%"
) else (
    powershell -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%AXEENGINE%" %AXEARGS%
)
