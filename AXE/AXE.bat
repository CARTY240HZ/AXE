@echo off
:: =====================================================
:: Launcher AXE - Elite Windows Optimizer
:: GUI: arranca SIN elevacion. Las operaciones privilegiadas usan el broker aislado.
:: CLI: los comandos con argumentos siguen elevandose porque algunos modos headless escriben
::       directamente en el sistema y no tienen WebView2 como frontera de seguridad.
::
:: Modos headless:
::   AXE.bat -SelfTest
::   AXE.bat -List
::   AXE.bat -Export fichero.json
::   AXE.bat -Import fichero.json   (requiere admin)
::
:: Solo se quita Mark-of-the-Web a los artefactos que AXE realmente carga/ejecuta.
:: =====================================================

set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" (
    echo ERROR: Windows PowerShell no esta disponible en %SystemRoot%\System32.
    exit /b 1
)

:: Si hay argumentos, mantener el comportamiento headless de CLI: elevar antes de ejecutar.
set "AXEARGS=%*"
if not "%AXEARGS%"=="" (
    net session >nul 2>&1
    if %errorlevel% neq 0 (
        "%PS_EXE%" -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
        exit /b
    )
)

:: Quitar Mark-of-the-Web solo de los ficheros que el motor realmente carga como codigo.
if exist "%~dp0dist\AXE.ps1" (
    "%PS_EXE%" -NoProfile -Command "Unblock-File -LiteralPath '%~dp0dist\AXE.ps1' -ErrorAction SilentlyContinue"
)
if exist "%~dp0webview2" (
    "%PS_EXE%" -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0webview2' -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
)

if "%AXEARGS%"=="" (
    :: GUI sin privilegios: el broker se ocupa de tweaks/PresentMon que necesiten admin.
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0dist\AXE.ps1"
) else (
    "%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0dist\AXE.ps1" %AXEARGS%
)
