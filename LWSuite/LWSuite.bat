@echo off
:: =====================================================
:: Launcher LW SUITE v4 - Elite Windows Optimizer
:: Se auto-eleva a admin y abre la GUI del motor unico (single source of truth).
:: Modos headless (sin GUI, sin admin necesariamente):
::   LWSuite.bat -SelfTest   -> validacion de integridad del catalogo
::   LWSuite.bat -List       -> estado real de cada tweak
::   LWSuite.bat -Export fichero.json
::   LWSuite.bat -Import fichero.json   (requiere admin)
::
:: ExecutionPolicy RemoteSigned: permite este script local; el
:: Unblock-File de abajo quita el Mark-of-the-Web si vino de un ZIP.
:: =====================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:: Quitar Mark-of-the-Web del .ps1 por si se descargo
powershell -NoProfile -Command "Unblock-File -Path '%~dp0LWSuite_v4.ps1' -ErrorAction SilentlyContinue"

:: Si hay argumentos, reenviarlos al .ps1 (modo CLI). Si no, abre GUI (admin ya concedido).
set "LWARGS=%*"
if "%LWARGS%"=="" (
    powershell -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0LWSuite_v4.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0LWSuite_v4.ps1" %LWARGS%
)
