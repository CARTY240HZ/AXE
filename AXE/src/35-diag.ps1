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
    # LIMITE CONOCIDO: MaxRefreshRate es el maximo del MODO ACTUAL del adaptador, no del panel.
    # Un 144Hz a una resolucion que el cable no aguanta puede reportar 60/60 y salir OK. Es un
    # falso negativo aceptado: el falso positivo (mandar a tocar ajustes que ya estan bien) es
    # peor para la confianza. Subir a WmiMonitorListedSupportedSourceModes lo arreglaria.
    if($null -eq $Facts.RefreshCur -or $null -eq $Facts.RefreshMax -or $Facts.RefreshMax -le 0){
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'UNKNOWN' 'Refresco del monitor' `
            'No se pudo leer el refresco actual o el maximo.' `
            'Configuracion > Pantalla > Configuracion avanzada de pantalla.' 'hasta 2x' 'desconocida'))
    } elseif($Facts.RefreshCur -lt $Facts.RefreshMax){
        $mult = [math]::Round($Facts.RefreshMax / [double]$Facts.RefreshCur,1)
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'BAD' 'Refresco del monitor' `
            "A $($Facts.RefreshCur)Hz cuando admite $($Facts.RefreshMax)Hz. Estas viendo ${mult}x menos frames de los que ya renderiza tu GPU." `
            'Configuracion > Pantalla > Configuracion avanzada > Elegir frecuencia de actualizacion.' `
            "${mult}x" 'cierta'))
    } else {
        [void]$out.Add((New-AXEDiagFinding 'refresh' 'OK' 'Refresco del monitor' `
            "A $($Facts.RefreshCur)Hz, el maximo que reporta el adaptador." `
            $null 'hasta 2x' 'parcial (maximo del modo actual, no del panel)'))
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

    $out.ToArray()
}

function Format-AXEDiag {
    # PURA. Devuelve lineas; el caller decide donde van (Write-Host en CLI, LogBox en GUI).
    # Texto compartido a proposito: si CLI y GUI redactaran cada una lo suyo acabarian
    # diciendo cosas distintas del mismo hallazgo, que es como se pierde la confianza.
    param([Parameter(Mandatory)]$Findings)
    $L = New-Object System.Collections.Generic.List[string]
    [void]$L.Add('== AXE DIAGNOSTICO DE CONFIGURACION ==')
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
            [void]$L.Add(("{0} punto(s) mal configurados. Valen mas que los 78 tweaks juntos." -f $bad.Count))
            [void]$L.Add('Ninguno se arregla desde AXE: viven en la BIOS, en los slots o en Configuracion de Windows.')
        }
        if($unk.Count -gt 0){ [void]$L.Add(("{0} sin comprobar: se dicen en vez de darlos por buenos." -f $unk.Count)) }
    }
    $L.ToArray()
}
