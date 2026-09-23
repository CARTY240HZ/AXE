@echo off
:: =====================================================
:: Launcher AXE - Elite Windows Optimizer
:: Modo GUI (sin argumentos): NO se eleva de entrada (issue #5 / auditoria 2026-09-22 s1.2).
:: WebView2 corre sin admin; el broker (src/46-broker.ps1, -Broker/-Token) eleva EL SOLO, bajo
:: demanda, solo cuando hace falta un tweak.apply/revert/masterRevert o un punto de restauracion.
:: Modos headless (CLI, con argumentos) SIGUEN elevando de entrada como siempre -- sin cambios,
:: fuera del alcance de este trabajo (issue #5 es sobre la GUI/WebView2):
::   AXE.bat -SelfTest   -> validacion de integridad del catalogo
::   AXE.bat -List       -> estado real de cada tweak
::   AXE.bat -Export fichero.json
::   AXE.bat -Import fichero.json   (requiere admin)
::
:: ExecutionPolicy RemoteSigned: permite este script local; el
:: Unblock-File de abajo quita el Mark-of-the-Web si vino de un ZIP.
:: =====================================================

if "%~1"=="" goto :gui

:: --- Modos CLI: elevacion incondicional, SIN CAMBIOS respecto al comportamiento previo. ---
:: (Preservado a proposito: este Start-Process NO reenvia %* al relanzar elevado -- ya se
:: comportaba asi antes de este cambio. Fuera de alcance de issue #5, no se toca aqui.)
net session >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
powershell -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0dist\AXE.ps1" %*
exit /b

:gui
:: --- Modo GUI: sin elevar. El broker eleva bajo demanda, por operacion. ---
powershell -NoProfile -Command "Get-ChildItem -Path '%~dp0' -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue"
powershell -NoProfile -ExecutionPolicy RemoteSigned -STA -File "%~dp0dist\AXE.ps1"
exit /b
