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
#   (sin args)    GUI (requiere admin via el launcher .bat)
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
    # Verificado sin colision contra el resto de src/ antes de anadirlo (ver nota de $GameList).
    [switch]$Diag,
    # Consejero (42-advisor). Comprobado como manda la leccion S24 antes de anadirlo:
    # 'grep $Advice src/' = 0 apariciones fuera de aqui y de 45-cli, ninguna como variable de
    # ruta. Declarar un switch cuyo nombre ya usa un modulo como variable local lo tipa a nivel de
    # script y revienta esa asignacion en silencio: fue exactamente lo que paso con $Games.
    [switch]$Advice,
    # OJO: NO llamar a este switch '$Games'. 20-tweaks.ps1 usa $Games como variable local para
    # la ruta de la tarea MMCSS ('...\SystemProfile\Tasks\Games'); declararlo aqui como [switch]
    # la tipa a nivel de script y la asignacion de esa cadena revienta => gpu_mmcss se queda
    # apuntando a una ruta vacia. Pasaba el SelfTest con 0 fallos (su Test solo devuelve false).
    [switch]$GameList,
    [string]$OptimizeGame,
    [string]$RevertGame,
    [switch]$NoFSO,
    # Nombres verificados contra el resto de src/ antes de anadirlos: ver la nota de $GameList
    # sobre la colision con el $Games de 20-tweaks.ps1, y el check S24 que la caza.
    [string]$Fps,
    [int]$FpsSeconds = 20,
    [switch]$FpsCompare,
    # Daemon de sesion de juego (subsistema A, spec 2026-07-20): congela el fondo mientras
    # juegas y lo descongela al cerrar el juego o AXE. Nombre verificado sin colision en src/.
    [string]$Session,
    [int]$SessionPoll = 1000,
    # Benchmark "pruebalo en tu PC" (subproyecto C, spec 2026-07-24). Dos fases con reinicio
    # humano en medio: -Benchmark guarda la linea base, -Benchmark -After <id> la compara.
    #   Nombres verificados contra el resto de src/ antes de anadirlos (leccion $Games/S24):
    # 'Benchmark' no aparece en ningun modulo; 'After' solo existe como PARAMETRO LOCAL de
    # Get-AXEFpsVerdict (param([object]$After)), que tiene su propio ambito y no colisiona con
    # una variable de script. Ninguno de los dos se usa como variable de ruta => S24 no aplica.
    [switch]$Benchmark,
    [string]$After,
    [int]$BenchPasses = 7,
    # Updater con cadena de confianza (subproyectos A+B, spec 2026-07-24). '-Update' comprueba
    # y, si hay version nueva, la instala SOLO tras verificar checksum + firma Authenticode.
    # '-Update -Check' se queda en informar y no descarga nada.
    #   Nombres verificados contra el resto de src/ antes de anadirlos (leccion $Games/S24):
    # 'Update' y 'Check' no aparecen como variable en ningun modulo (grep sobre src/ = 0 hits),
    # asi que no pueden tipar a [switch] una variable de ruta ajena. S24 los vigila igual.
    [switch]$Update,
    [switch]$Check,
    # Monitor de red (37-netmon.ps1). Cubre el hueco que el audit de 2026-07-25 dejo abierto:
    # el jitter de 32-measure es de TIMER, no de red, y de red no se medi­a nada.
    #   Nombres verificados contra el resto de src/ antes de anadirlos (leccion $Games/S24):
    # grep '$NetMon' sobre src/ = 0 hits fuera de 45-cli. Ninguno se usa como variable de ruta.
    [switch]$NetMon,
    [string]$NetMonTarget = '1.1.1.1',
    [int]$NetMonCount = 20,
    # v7.1: diagnosticos de latencia que el catalogo no puede tocar.
    #   -Mouse    sondeo del raton + aceleracion + escalado 1:1   (44-latency.ps1)
    #   -Dpc      tiempo en rutinas diferidas de drivers          (44-latency.ps1)
    #   -NetLoad  latencia bajo carga / bufferbloat               (37-netmon.ps1)
    #   Nombres verificados contra el resto de src/ antes de anadirlos (leccion $Games/S24):
    # grep de '$Mouse', '$Dpc' y '$NetLoad' sobre src/ = 0 hits. Ninguno se usa como variable
    # de ruta en ningun modulo, asi que declararlos aqui no puede tipar nada ajeno a [switch].
    [switch]$Mouse,
    [int]$MouseSeconds = 3,
    [switch]$Dpc,
    [int]$DpcSeconds = 5,
    [switch]$NetLoad,
    # Vacio a proposito: el default real vive en $script:AXENetLoadUrl (37-netmon), y un param
    # block no puede leer una variable de un modulo que aun no se ha concatenado.
    [string]$NetLoadUrl = ''
)

# Version canonica. build.ps1 reemplaza el token desde el fichero VERSION (fuente unica).
# Va DESPUES del param block (regla PS: param() debe ser la primera sentencia).
# Fallback si el token no se reemplazo (se corre src suelto sin build).
$script:AXEVersion = '__AXE_VERSION__'
if($script:AXEVersion -like '*__AXE_VERSION__*'){ $script:AXEVersion = '6.1.0-dev' }

