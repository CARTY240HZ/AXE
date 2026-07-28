# =====================================================
# REGION 10e - DIAGNOSTICO DE HARDWARE MAL CONFIGURADO
# =====================================================
#
# POR QUE EXISTE: los 78 tweaks del catalogo pelean por porcentajes de un digito, y varios
# ni eso (el propio catalogo marca PlaceboLikely y NO-OP EN LA MAYORIA en unos cuantos). Lo
# que de verdad cuesta FPS en una maquina mal montada no es una clave del registro:
#
#   XMP/EXPO sin activar      10-30%   la RAM corre a la velocidad JEDEC de arranque
#   RAM en single channel     20-40%   un solo modulo, o dos en el mismo canal
#   Monitor por debajo de Hz  hasta 2x un panel de 144Hz puesto a 60
#   Juego/SO en HDD           enorme en stutter y cargas
#
# Ninguno de esos se arregla desde AXE, y a proposito: XMP y los canales de RAM viven en la
# BIOS y en los slots fisicos. Este modulo DETECTA y EXPLICA, no toca nada. Es la unica
# categoria del proyecto con efecto grande garantizado, precisamente porque no promete: el
# usuario puede verificar cada hallazgo por su cuenta.
#
# DIVISION PURO/HARDWARE (mismo motivo que Get-AXEFpsStats vs Measure-AXEFps en 33-fps.ps1):
#   Get-AXEDiagFacts     -> toca CIM, no decide nada. No testeable sin hardware.
#   Get-AXEDiagFindings  -> PURA. Recibe los hechos, devuelve hallazgos. Testeable en CI.
#   Format-AXEDiag       -> PURA. Render de texto, compartido por CLI y GUI.
# Si el juicio viviera dentro de la lectura de CIM solo se podria probar en la maquina del
# que lo escribio, o sea nunca.
#
# ESTADOS, y por que hay tres y no dos:
#   BAD      medido y mal configurado.
#   OK       medido y correcto.
#   UNKNOWN  NO SE PUDO MEDIR. Es un estado de primera clase, no un OK disfrazado. Un
#            diagnostico que calla lo que no sabe es exactamente el problema que tienen los
#            optimizadores de pago: todo sale verde porque nada se comprueba de verdad.

# --- velocidades JEDEC de arranque, base de la heuristica de XMP -----------------------
# Sin XMP/EXPO el modulo arranca al perfil JEDEC del SPD. En DDR4 eso cae en 2133/2400/2666
# (3200 es JEDEC valido pero rarisimo como perfil de arranque); en DDR5, 4800.
# LIMITE CONOCIDO: el SPD no expone el perfil XMP por WMI, asi que esto es una HEURISTICA por
# umbral, no una lectura del perfil. Un kit DDR4-2666 sin ningun perfil XMP dara falso
# positivo. Se acepta porque el consejo ("miralo en la BIOS") es inofensivo en ese caso, y
# porque el fallo contrario (callar un XMP apagado) cuesta 10-30% real.
$script:DiagJedecBase   = @{ 26 = 2666; 34 = 4800 }   # SMBIOSMemoryType: 26=DDR4, 34=DDR5
$script:DiagMemTypeName = @{ 24 = 'DDR3'; 26 = 'DDR4'; 34 = 'DDR5' }

function Get-AXEDiagFacts {
    # Lee el hardware. No juzga: eso es Get-AXEDiagFindings. Cada bloque va en su try porque
    # WMI falla distinto en cada maquina y un fallo parcial debe degradar a UNKNOWN, nunca
    # tumbar el diagnostico entero ni -peor- pasar por OK.
    $f = [ordered]@{
        MemModules = $null; MemSpeedMhz = $null; MemType = $null; MemLocators = $null
        RefreshCur = $null; RefreshMax = $null
        IsSSD      = $null
        # --- Campos nuevos. Ninguno de los de arriba cambia de nombre ni de tipo. ---
        # Refresco REAL del panel (EDID), no el del modo actual del adaptador: ver el bloque
        # de WmiMonitorListedSupportedSourceModes mas abajo y el hallazgo 3.
        PanelMaxHz = $null; PanelMaxHzAtRes = $null
        # Nucleos fisicos vs hilos: de ahi sale el reparto P/E por aritmetica (hallazgo 5).
        CpuCores   = $null; CpuThreads = $null; IsWin11 = $null
    }
    try {
        $mem = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
        if($mem.Count -gt 0){
            $f.MemModules = $mem.Count
            # La velocidad configurada real. ConfiguredClockSpeed es la fiable cuando existe;
            # Speed puede reportar el rating del modulo en algunas BIOS. Nos quedamos con la
            # menor de las dos: si difieren, la baja es la que esta corriendo de verdad.
            $spd = @($mem | ForEach-Object {
                $c = $_.ConfiguredClockSpeed; $s = $_.Speed
                if($c -and $s){ [math]::Min([int]$c,[int]$s) } elseif($c){ [int]$c } elseif($s){ [int]$s }
            }) | Where-Object { $_ -gt 0 }
            if($spd.Count -gt 0){ $f.MemSpeedMhz = ($spd | Measure-Object -Minimum).Minimum }
            $f.MemType     = [int]($mem[0].SMBIOSMemoryType)
            $f.MemLocators = @($mem | ForEach-Object { $_.DeviceLocator })
        }
    } catch {}
    try {
        # Solo GPUs reales, mismo filtro que Get-AXEHardware: los adaptadores virtuales
        # reportan refrescos inventados y ensuciarian el hallazgo.
        $vc = Get-CimInstance Win32_VideoController -ErrorAction Stop |
              Where-Object { $_.Name -notmatch 'Virtual|Basic|Meta|Parsec|Remote' -and $_.CurrentRefreshRate } |
              Select-Object -First 1
        if($vc){ $f.RefreshCur = [int]$vc.CurrentRefreshRate; $f.RefreshMax = [int]$vc.MaxRefreshRate }
    } catch {}
    # --- Refresco REAL del panel, no el del adaptador ------------------------------------
    # CIERRA EL TODO que este modulo llevaba declarado: Win32_VideoController.MaxRefreshRate es
    # el maximo del MODO ACTUAL del adaptador, asi que un panel de 144 Hz puesto a 60 puede
    # reportar 60/60 y salir OK. WmiMonitorListedSupportedSourceModes viene del EDID del
    # monitor: son los modos que el PANEL declara, independientemente de como este ahora.
    #
    # Se guardan DOS maximos a proposito, y la diferencia importa: un panel puede dar 240 Hz a
    # 1080p y solo 144 a 1440p. Comparar el refresco actual contra el maximo ABSOLUTO mandaria
    # al usuario a buscar unos Hz que a su resolucion no existen, que es un falso positivo y
    # de los que peor sientan. Manda el maximo A SU RESOLUCION; el absoluto solo se usa si la
    # resolucion actual no se pudo leer.
    try {
        $curW = $null; $curH = $null
        if($script:HW){ $curW = $script:HW.ScreenW; $curH = $script:HW.ScreenH }
        $best = 0; $bestAtRes = 0
        foreach($mm in @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop)){
            foreach($sm in @($mm.MonitorSourceModes)){
                $den = [double]$sm.VerticalRefreshRateDenominator
                if($den -le 0){ continue }
                $hz = [int][math]::Round([double]$sm.VerticalRefreshRateNumerator / $den)
                if($hz -le 0 -or $hz -gt 1000){ continue }   # modos basura del EDID
                if($hz -gt $best){ $best = $hz }
                if($curW -and $curH -and [int]$sm.HorizontalActivePixels -eq [int]$curW -and [int]$sm.VerticalActivePixels -eq [int]$curH){
                    if($hz -gt $bestAtRes){ $bestAtRes = $hz }
                }
            }
        }
        if($best -gt 0){ $f.PanelMaxHz = $best }
        if($bestAtRes -gt 0){ $f.PanelMaxHzAtRes = $bestAtRes }
    } catch {}
    # CPU: nucleos fisicos vs hilos logicos. De la diferencia sale el reparto P/E sin adivinar
    # por el nombre comercial (ver hallazgo 5). Se reusa $script:HW si ya esta cargado.
    try {
        if($script:HW){ $f.CpuCores = $script:HW.Cores; $f.CpuThreads = $script:HW.Threads; $f.IsWin11 = $script:HW.IsWin11 }
    } catch {}
    # IsSSD ya lo calcula Get-AXEHardware; se reusa si el caller lo paso, no se recalcula.
    if($script:HW -and $null -ne $script:HW.IsSSD){ $f.IsSSD = [bool]$script:HW.IsSSD }
    [pscustomobject]$f
}

function New-AXEDiagFinding {
    param($Id,$Status,$Title,$Detail,$Fix,$EstPct,$Confidence)
    [pscustomobject]@{
        Id=$Id; Status=$Status; Title=$Title; Detail=$Detail
        Fix=$Fix; EstPct=$EstPct; Confidence=$Confidence
    }
}

function Get-AXEDiagFindings {
    # PURA: mismos hechos dentro, mismos hallazgos fuera. Sin CIM, sin registro, sin disco.
    # EstPct es un RANGO ESTIMADO tipico documentado por la industria, no una medida de esta
    # maquina. Se muestra como estimacion y jamas como promesa: la unica cifra real que da
    # este proyecto sale de 32-measure.ps1 midiendo antes y despues.
    param([Parameter(Mandatory)]$Facts)
    $out = New-Object System.Collections.Generic.List[object]

    # --- 1. XMP / EXPO -----------------------------------------------------------------
    $base  = if($null -ne $Facts.MemType){ $script:DiagJedecBase[[int]$Facts.MemType] } else { $null }
    $tname = if($null -ne $Facts.MemType -and $script:DiagMemTypeName.ContainsKey([int]$Facts.MemType)) { $script:DiagMemTypeName[[int]$Facts.MemType] } else { 'RAM' }
    if($null -eq $Facts.MemSpeedMhz -or $null -eq $base){
        [void]$out.Add((New-AXEDiagFinding 'xmp' 'UNKNOWN' 'XMP / EXPO' `
            'No se pudo leer la velocidad o el tipo de memoria por WMI.' `
            'Comprueba a mano la velocidad de la RAM en la BIOS.' '10-30%' 'desconocida'))
    } elseif($Facts.MemSpeedMhz -le $base){
        [void]$out.Add((New-AXEDiagFinding 'xmp' 'BAD' 'XMP / EXPO' `
            "$tname corriendo a $($Facts.MemSpeedMhz) MHz: es la velocidad JEDEC de arranque. El perfil de tu kit casi seguro esta sin activar." `
            'BIOS > perfil de memoria > activa XMP (Intel) o EXPO (AMD). Reinicia y vuelve a mirar.' `
            '10-30%' 'heuristica (WMI no expone el perfil XMP del SPD)'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'xmp' 'OK' 'XMP / EXPO' `
            "$tname a $($Facts.MemSpeedMhz) MHz, por encima de la base JEDEC ($base MHz)." `
            $null '10-30%' 'heuristica'))
    }

    # --- 2. Canales de RAM --------------------------------------------------------------
    # Un solo modulo es single channel SIEMPRE: no hay heuristica que valga, es aritmetica.
    # Con dos o mas no se afirma dual channel, porque WMI no dice de forma fiable si estan en
    # canales distintos; dos modulos en A1+A2 son single y aqui saldrian como probables. Por
    # eso el texto dice "probable" y manda al manual, en vez de dar un OK que no se ha medido.
    if($null -eq $Facts.MemModules){
        [void]$out.Add((New-AXEDiagFinding 'ramchan' 'UNKNOWN' 'Canales de RAM' `
            'No se pudieron enumerar los modulos de memoria.' `
            'Revisa a mano cuantos modulos hay y en que slots.' '20-40%' 'desconocida'))
    } elseif($Facts.MemModules -eq 1){
        [void]$out.Add((New-AXEDiagFinding 'ramchan' 'BAD' 'Canales de RAM' `
            'Un solo modulo instalado: single channel seguro. Es de lo mas caro que hay en un PC de juego.' `
            'Anade un segundo modulo igual, en el slot que diga el manual de la placa (normalmente A2+B2).' `
            '20-40%' 'cierta'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'ramchan' 'OK' 'Canales de RAM' `
            "$($Facts.MemModules) modulos instalados: dual channel probable." `
            'Confirma en el manual que estan en canales distintos (tipico A2+B2, no A1+A2).' `
            '20-40%' 'parcial (WMI no confirma el canal)'))
    }

    # --- 3. Refresco del monitor --------------------------------------------------------
    # ANTES: solo Win32_VideoController.MaxRefreshRate, que es el maximo del MODO ACTUAL del
    # adaptador. Un panel de 144 Hz puesto a 60 reportaba 60/60 y salia OK: falso negativo
    # conocido, declarado en un TODO y sin resolver. AHORA se prefiere el EDID del panel.
    #
    # PRIORIDAD, y el orden no es cosmetico:
    #   1. PanelMaxHzAtRes  el maximo del panel A LA RESOLUCION ACTUAL. Es el unico que puede
    #                       compararse contra RefreshCur sin mentir.
    #   2. PanelMaxHz       maximo absoluto del panel. Solo si no se supo la resolucion actual;
    #                       si no, un panel de 240@1080p / 144@1440p mandaria a buscar 240 Hz
    #                       que a 1440p no existen.
    #   3. RefreshMax       el del adaptador, como antes. Ultimo recurso: en RDP, en algunos
    #                       hibridos y con drivers basicos el namespace root\wmi no responde.
    # NINGUNA de las tres fuentes es de fiar como techo. Todas valen como SUELO:
    #   RefreshCur       lo que hay puesto ahora. Suelo garantizado del maximo real.
    #   PanelMaxHz*      modos del EDID. MEDIDO EN UN PORTATIL REAL DURANTE ESTA SESION: la
    #                    lista devolvio 60 Hz en un panel que estaba corriendo a 180. La clase
    #                    WmiMonitorListedSupportedSourceModes solo trae los timings ESTANDAR
    #                    del EDID, no los detallados, asi que en muchos paneles se queda corta.
    #                    Tomarla por techo daba un OK con confianza 'cierta' que era falso, y
    #                    ademas imprimia "A 180Hz, el maximo disponible (60 Hz)".
    #   RefreshMax       maximo del modo actual del adaptador. Otro suelo, el de siempre.
    # Por eso el maximo efectivo es el MAYOR de los que haya. La unica afirmacion honesta que
    # se puede hacer desde aqui es "estas por debajo de un refresco que SE PUEDE VER"; probar
    # que estas al techo real del panel no se puede, y por eso el OK nunca dice 'cierta'.
    # OJO CON EL PAPEL DE RefreshCur: es un TOPE INFERIOR, no una fuente. Si entrase como
    # candidato a maximo, con las otras dos fuentes caidas el maximo saldria igual al actual y
    # el hallazgo diria OK. Eso convierte "no se cual es el maximo" en "estas al maximo", que
    # es exactamente el OK sin comprobar que este modulo existe para no dar. Sin ninguna fuente
    # de modos -> UNKNOWN, como siempre.
    $refMax = $null; $refSrc = $null; $panel = $null
    if($Facts.PanelMaxHzAtRes -and $Facts.PanelMaxHzAtRes -gt 0){
        $panel = [int]$Facts.PanelMaxHzAtRes
    } elseif($Facts.PanelMaxHz -and $Facts.PanelMaxHz -gt 0){
        # Absoluto solo si no se supo la resolucion actual: un panel de 240@1080p / 144@1440p
        # mandaria a buscar unos Hz que a la resolucion puesta no existen.
        $panel = [int]$Facts.PanelMaxHz
    }
    foreach($c in @($panel, $Facts.RefreshMax)){
        if($c -and [int]$c -gt 0 -and ($null -eq $refMax -or [int]$c -gt $refMax)){ $refMax = [int]$c }
    }
    if($null -ne $refMax){
        # Una fuente que reporta MENOS que el refresco que hay PUESTO esta incompleta, y hay que
        # decirlo aunque OTRA fuente gane el maximo. El caso MEDIDO en portatil: el EDID devolvio
        # 60 con el panel corriendo a 180; el maximo lo salvo RefreshMax, pero la confianza no
        # puede presumir de haber leido el panel cuando lo que leyo estaba mal.
        #   Mirar solo el maximo final (lo que hacia antes este bloque) perdia ese aviso en cuanto
        # una sola fuente acertaba: el unico caso que quedaba delatado era el de TODAS cortas.
        $cur   = if($Facts.RefreshCur){ [int]$Facts.RefreshCur } else { $null }
        $under = @(@($panel, $Facts.RefreshMax) | Where-Object { $_ -and $cur -and [int]$_ -lt $cur })
        # Clamp al actual para el caso de TODAS cortas: sin el, el hallazgo imprimia
        # "A 180Hz, el maximo disponible (60 Hz)", que ademas de falso es absurdo.
        if($cur -and $cur -gt $refMax){ $refMax = $cur }
        $refSrc = if($under.Count -gt 0){ 'parcial (las listas de modos reportan menos que tu refresco actual: estan incompletas)' }
                  elseif($panel -and $panel -eq $refMax){ 'parcial (modos que declara el EDID del panel; la lista puede estar incompleta)' }
                  else { 'parcial (maximo del modo actual del adaptador, no del panel)' }
    }
    if($null -eq $Facts.RefreshCur -or $null -eq $refMax){
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'UNKNOWN' 'Refresco del monitor' `
            'No se pudo leer el refresco actual o el maximo.' `
            'Configuracion > Pantalla > Configuracion avanzada de pantalla.' 'hasta 2x' 'desconocida'))
    } elseif($Facts.RefreshCur -lt $refMax){
        $mult = [math]::Round($refMax / [double]$Facts.RefreshCur,1)
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'BAD' 'Refresco del monitor' `
            "A $($Facts.RefreshCur)Hz cuando admite $refMax Hz. Estas viendo ${mult}x menos frames de los que ya renderiza tu GPU." `
            'Configuracion > Pantalla > Configuracion avanzada > Elegir frecuencia de actualizacion.' `
            "${mult}x" $refSrc))
    } else {
        # "el mas alto que AXE puede ver", no "el maximo del panel": ver el bloque de arriba.
        # Decir lo segundo seria afirmar algo que ninguna de las tres fuentes prueba.
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'OK' 'Refresco del monitor' `
            "A $($Facts.RefreshCur)Hz, el mas alto de los modos que AXE puede ver." `
            $null 'hasta 2x' $refSrc))
    }

    # --- 4. Disco de sistema ------------------------------------------------------------
    if($null -eq $Facts.IsSSD){
        [void]$out.Add((New-AXEDiagFinding 'ssd' 'UNKNOWN' 'Disco de sistema' `
            'No se pudo determinar el tipo de disco.' `
            'Comprueba si el disco del sistema es SSD o HDD.' 'grande en stutter' 'desconocida'))
    } elseif(-not $Facts.IsSSD){
        [void]$out.Add((New-AXEDiagFinding 'ssd' 'BAD' 'Disco de sistema' `
            'Windows esta en un disco mecanico. Afecta a cargas y a los tirones por streaming de texturas, no tanto al FPS medio.' `
            'Migra Windows y los juegos a un SSD. Es la mejora mas grande por euro que existe.' `
            'grande en stutter' 'cierta'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'ssd' 'OK' 'Disco de sistema' 'SSD/NVMe.' $null 'grande en stutter' 'cierta'))
    }

    # --- 5. Nucleos P/E (CPU hibrida) ---------------------------------------------------
    # POR ARITMETICA, NO POR EL NOMBRE COMERCIAL. En una CPU hibrida de Intel los nucleos P
    # llevan Hyper-Threading (2 hilos) y los E no (1 hilo). Entonces:
    #     P = hilos - nucleos       E = nucleos - P
    # Un i9-13900H (14 nucleos / 20 hilos) da P=6, E=8. Correcto.
    # El gate es que 'hilos' caiga ESTRICTAMENTE entre 'nucleos' y '2*nucleos': con HT en todos
    # los nucleos hilos=2*nucleos (no hibrida, P=nucleos y E=0), y sin HT hilos=nucleos (no
    # hibrida tampoco). Solo el caso intermedio prueba que hay nucleos sin HT.
    #   Esto es mejor que $HW.IsHybrid, que adivina por regex sobre el nombre ('1[2-9]th Gen'
    # o 'Ultra'): eso falla con cualquier CPU futura y con las que no rotulan la generacion.
    #
    # Y ES UN DIAGNOSTICO, NO UN TWEAK, a proposito. Forzar la afinidad a los nucleos P suena
    # bien y suele EMPEORARLO: Thread Director mueve los hilos con telemetria del propio
    # silicio, y una mascara fija le quita esa informacion. El catalogo ya bloquea core parking
    # en hibridas por este motivo (20-tweaks: 'pelea con Thread Director'). Aqui se explica
    # que hay que mirar; no se toca nada.
    $hc = $Facts.CpuCores; $ht = $Facts.CpuThreads
    if($null -eq $hc -or $null -eq $ht -or $hc -le 0 -or $ht -le 0){
        [void]$out.Add((New-AXEDiagFinding 'hybrid' 'UNKNOWN' 'Nucleos P/E' `
            'No se pudo leer el numero de nucleos fisicos o de hilos.' `
            'Administrador de tareas > Rendimiento > CPU: compara "Nucleos" con "Procesadores logicos".' `
            'tirones si el juego cae en nucleos E' 'desconocida'))
    } elseif($ht -gt $hc -and $ht -lt (2 * $hc)) {
        $pc = $ht - $hc; $ec = $hc - $pc
        if($Facts.IsWin11 -eq $false){
            # Win10 no tiene Thread Director por hardware: el planificador reparte a ciegas y
            # los hilos del juego acaban en nucleos E con mucha mas frecuencia. Es el unico
            # caso de este hallazgo que merece BAD, y el arreglo es real (actualizar el SO).
            [void]$out.Add((New-AXEDiagFinding 'hybrid' 'BAD' 'Nucleos P/E' `
                "CPU hibrida ($pc nucleos P + $ec nucleos E) con Windows 10. Win10 no recibe la telemetria de Thread Director, asi que reparte los hilos sin saber que nucleos son rapidos: los del juego caen en nucleos E mas de la cuenta y eso son tirones." `
                'Actualiza a Windows 11. Es de las pocas veces que el cambio de version tiene efecto medible en juego, y solo pasa en CPUs hibridas como la tuya.' `
                'tirones si el juego cae en nucleos E' 'cierta (aritmetica de nucleos e hilos)'))
        } else {
            [void]$out.Add((New-AXEDiagFinding 'hybrid' 'OK' 'Nucleos P/E' `
                "CPU hibrida ($pc nucleos P + $ec nucleos E) con Windows 11: Thread Director reparte con telemetria del propio silicio." `
                $null 'tirones si el juego cae en nucleos E' `
                'cierta (aritmetica de nucleos e hilos). NO fuerces la afinidad a los nucleos P: una mascara fija le quita a Thread Director la informacion con la que decide, y suele salir peor.'))
        }
    } else {
        [void]$out.Add((New-AXEDiagFinding 'hybrid' 'OK' 'Nucleos P/E' `
            "CPU no hibrida ($hc nucleos / $ht hilos): todos los nucleos son iguales, no hay reparto que pueda salir mal." `
            $null 'tirones si el juego cae en nucleos E' 'cierta (aritmetica de nucleos e hilos)'))
    }

    $out.ToArray()
}

function Format-AXEDiag {
    # PURA. Devuelve lineas; el caller decide donde van (Write-Host en CLI, LogBox en GUI).
    # Texto compartido a proposito: si CLI y GUI redactaran cada una lo suyo acabarian
    # diciendo cosas distintas del mismo hallazgo, que es como se pierde la confianza.
    # $Title existe para que 44-latency reuse ESTE render en vez de escribir el suyo: un
    # hallazgo debe leerse igual venga de donde venga. El default es el literal de siempre, asi
    # que todos los llamantes anteriores producen exactamente la misma salida que antes.
    # $BadNote es la linea que explica DONDE se arregla lo que salio mal, y tiene que ser
    # parametrizable porque no es cierta fuera de este modulo: los hallazgos de 35-diag viven
    # en la BIOS y en los slots, pero los de 44-latency viven en un driver o en el software del
    # raton. Reusar el render con el pie equivocado seria decirle al usuario que busque en la
    # BIOS un problema de DPC. El default es el literal de siempre.
    param(
        [Parameter(Mandatory)]$Findings,
        [string]$Title = 'AXE DIAGNOSTICO DE CONFIGURACION',
        [string]$BadNote = 'Ninguno se arregla desde AXE: viven en la BIOS, en los slots o en Configuracion de Windows.'
    )
    $L = New-Object System.Collections.Generic.List[string]
    [void]$L.Add("== $Title ==")
    [void]$L.Add('')
    $bad = @($Findings | Where-Object Status -eq 'BAD')
    $unk = @($Findings | Where-Object Status -eq 'UNKNOWN')
    foreach($f in $Findings){
        $mark = switch($f.Status){ 'BAD'{'[MAL]'} 'OK'{'[OK ]'} default{'[ ? ]'} }
        [void]$L.Add(("{0} {1}" -f $mark,$f.Title))
        [void]$L.Add(("      {0}" -f $f.Detail))
        if($f.Status -eq 'BAD'){
            [void]$L.Add(("      EN JUEGO : {0} (estimacion tipica, NO medida en esta maquina)" -f $f.EstPct))
            [void]$L.Add(("      ARREGLO  : {0}" -f $f.Fix))
        }
        if($f.Confidence -and $f.Status -ne 'OK'){ [void]$L.Add(("      CONFIANZA: {0}" -f $f.Confidence)) }
        [void]$L.Add('')
    }
    [void]$L.Add('---')
    if($bad.Count -eq 0 -and $unk.Count -eq 0){
        [void]$L.Add('Nada mal configurado de lo que se comprueba aqui.')
        [void]$L.Add('Los tweaks del catalogo pelean por porcentajes de un digito sobre esta base.')
    } else {
        if($bad.Count -gt 0){
            # Sin cifra de catalogo a proposito: el numero de tweaks crece y una constante aqui
            # envejece sola. Es el mismo motivo por el que el badge de tests no lleva numero.
            [void]$L.Add(("{0} punto(s) mal configurados. Valen mas que todo el catalogo junto." -f $bad.Count))
            if($BadNote){ [void]$L.Add($BadNote) }
        }
        if($unk.Count -gt 0){ [void]$L.Add(("{0} sin comprobar: se dicen en vez de darlos por buenos." -f $unk.Count)) }
    }
    $L.ToArray()
}
