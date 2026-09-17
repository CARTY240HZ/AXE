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
:: ExecutionPolicy RemoteSigned: permite este script local.
:: Solo se quita Mark-of-the-Web a los artefactos que AXE realmente carga/ejecuta.
:: =====================================================

set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS_EXE%" (
    echo ERROR: Windows PowerShell no esta disponible en %SystemRoot%\System32.
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    "%PS_EXE%" -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Quitar Mark-of-the-Web solo de los ficheros que el motor realmente carga como codigo:
:: el script compilado y las DLL de WebView2. No se recorre/desbloquea todo el repositorio,
:: evitando convertir un archivo auxiliar inesperado en un binario aparentemente confiable.
if exist "%~dp0dist\AXE.ps1" (
    "%PS_EXE%" -NoProfile -Command "Unblock-File -LiteralPath '%~dp0dist\AXE.ps1' -ErrorAction SilentlyContinue"
)
if exist "%~dp0webview2" (
    "%PS_EXE%" -NoProfile -Command "Get-ChildItem -LiteralPath '%~dp0webview2' -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
)

:: Si hay argumentos, reenviarlos al .ps1 (modo CLI). Si no, abre GUI (admin ya concedido).
set "AXEARGS=%*"
if "%AXEARGS%"=="" (
    "%PS_EXE%" -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0dist\AXE.ps1"
) else (
    "%PS_EXE%" -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0dist\AXE.ps1" %AXEARGS%
)
