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
#   -Export/-Import <file>  Perfil JSON. -Import omite por defecto los tweaks Tier 2 EXTREME
#                 del perfil (con aviso); -ImportExtreme los permite. La GUI exige confirmar
#                 Tier 2 antes de aplicar, e -Import (headless) no tenia ningun equivalente.
#   -GameList     Preferencia de GPU por juego, tal como esta ahora
#   -OptimizeGame <ruta.exe> [-NoFSO]  dGPU + flip model en ESE ejecutable
#   -RevertGame   <ruta.exe>           Deshace lo anterior al estado capturado
#   -Fps <proceso> [-FpsSeconds N]     Mide FPS reales con PresentMon (1% low incluido)
#   -Fps <proceso> -FpsCompare         Antes/despues con veredicto honesto (ruido o no)
#   -Benchmark                     Linea base medible (N pasadas, mediana + IQR). Imprime un id.
#   -Benchmark -After <id> [-Report <file>]
#                 Vuelve a medir tras aplicar+reiniciar y da el veredicto por metrica:
#                 mejor / peor / RUIDO. Nunca declara mejora dentro del margen de ruido.
#   -NetMon [-NetMonTarget <ip>] [-NetMonCount N]
#                 Ping, jitter de RED y perdida contra la puerta de enlace y una ancla publica.
#                 Solo mide. Distingue "tu enlace" de "tu operador"; no puntua el ping a
#                 internet porque no hay umbral honesto para eso.
#   -Diag         Configuracion mal puesta que cuesta mas FPS que todo el catalogo junto
#                 (XMP/EXPO, canales de RAM, Hz del monitor por EDID, SSD, nucleos P/E).
#                 Solo detecta, no toca nada.
#   -Mouse [-MouseSeconds N]
#                 Sondeo real del raton (125 vs 1000 Hz = 7 ms de input lag), aceleracion del
#                 puntero y escalado 1:1. Hay que MOVER el raton mientras mide.
#   -Dpc [-DpcSeconds N]
#                 Tiempo en rutinas diferidas de drivers por nucleo: la otra familia de
#                 tirones, la que no baja el FPS medio. Mide carga total, no atribuye driver.
#   -NetLoad [-NetLoadUrl <url>]
#                 Latencia BAJO CARGA (bufferbloat): el ping que tendras cuando alguien de casa
#                 descargue algo. Satura el enlace a proposito descargando de Cloudflare (no
#                 envia nada del equipo); sin saturar no hay nada que medir.
#   -Update [-Check]  Comprueba si hay version nueva en el repo oficial. Sin -Check la instala,
#                 pero SOLO tras verificar SHA256 + firma Authenticode; sin firma valida avisa
#                 y NO reemplaza nada (el destino es escribible por el usuario y AXE corre
#                 elevado: un updater laxo seria la via de escalada). No envia nada del equipo.
#   (sin args)    GUI sin privilegios. Las operaciones privilegiadas usan el broker aislado.
# =====================================================

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$List,
    [string]$Export,
    [string]$Import,
    [switch]$ImportExtreme,
    [switch]$Measure,
    [switch]$Score,
    [string]$Report,
    [switch]$TimerSweep,
    [switch]$Diag,
    [switch]$Advice,
    [switch]$GameList,
    [string]$OptimizeGame,
    [string]$RevertGame,
    [switch]$NoFSO,
    [string]$Fps,
    [int]$FpsSeconds = 20,
    [switch]$FpsCompare,
    [string]$Session,
    [int]$SessionPoll = 1000,
    [switch]$Benchmark,
    [string]$After,
    [int]$BenchPasses = 7,
    [switch]$Update,
    [switch]$Check,
    [switch]$NetMon,
    [string]$NetMonTarget = '1.1.1.1',
    [int]$NetMonCount = 20,
    [switch]$Mouse,
    [int]$MouseSeconds = 3,
    [switch]$Dpc,
    [int]$DpcSeconds = 5,
    [switch]$NetLoad,
    [string]$NetLoadUrl = '',
    # Internal only: one-shot privileged broker entrypoint. Never exposed to WebView2/JS.
    [switch]$BrokerServer,
    [string]$BrokerPipeName = '',
    [string]$BrokerNonce = ''
)

# Version canonica. build.ps1 reemplaza el token desde el fichero VERSION (fuente unica).
# Va DESPUES del param block (regla PS: param() debe ser la primera sentencia).
$script:AXEVersion = '__AXE_VERSION__'
if($script:AXEVersion -like '*__AXE_VERSION__*'){ $script:AXEVersion = '6.1.0-dev' }

