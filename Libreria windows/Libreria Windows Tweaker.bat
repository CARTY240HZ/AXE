@echo off
:: =====================================================
:: LIBRERIA WINDOWS TWEAKER - Launcher principal
:: -----------------------------------------------------
:: Redirige al motor UNICO consolidado: LWSuite v4.
:: Las versiones anteriores (Libreria_Windows_Tweaker.ps1 v2
:: y los .bat individuales por categoria) quedan como LEGACY:
:: siguen funcionando pero NO reciben mas correcciones.
:: Para todo uso nuevo, este launcher abre la GUI v4 con
:: gating por hardware, tiers, master-revert y backup robusto.
:: =====================================================

if exist "%~dp0LWSuite\LWSuite.bat" (
    "%~dp0LWSuite\LWSuite.bat" %*
) else (
    echo [ERROR] No se encontro LWSuite\LWSuite.bat
    echo Se esperaba en: %~dp0LWSuite\
    pause
    exit /b 1
)
