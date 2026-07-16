#Requires -Version 5.1
# =====================================================
# AXE - Elite Windows Optimizer (single source of truth)
#
# Motor UNICO consolidado. Corrige todos los hallazgos del audit:
#   C1  Backup/restore de startup robusto + Restore-Autorun
#   A1  Master revert limpia residuos v1 (SmartScreen/NoConnectedUser/hypervisor)
#   A2  Un valor canonico por tweak; fuentes unificadas
#   M1  Reverts que no revertian -> eliminados o documentados como unidireccionales
#   M4  Punto de restauracion en runspace (GUI no se congela)
#   M5  Guard anti-catalogo-roto + modo -SelfTest (validacion headless)
#
# Modos de ejecucion (headless, sin GUI ni admin):
#   -SelfTest     Validacion de integridad del catalogo y helpers (0 fallos)
#   -List         Estado real de cada tweak contra el sistema
#   -Export/-Import <file>  Perfil JSON
#   (sin args)    GUI (requiere admin via el launcher .bat)
# =====================================================

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$List,
    [string]$Export,
    [string]$Import,
    [switch]$Measure,
    [switch]$Score,
    [string]$Report
)

# Version canonica. build.ps1 reemplaza el token desde el fichero VERSION (fuente unica).
# Va DESPUES del param block (regla PS: param() debe ser la primera sentencia).
# Fallback si el token no se reemplazo (se corre src suelto sin build).
$script:AXEVersion = '__AXE_VERSION__'
if($script:AXEVersion -like '*__AXE_VERSION__*'){ $script:AXEVersion = '6.1.0-dev' }

