# Unit - diagnostico de configuracion (35-diag.ps1).
#
# Todo lo de aqui es PURO a posta: Get-AXEDiagFindings recibe un objeto de hechos en vez de
# leer CIM, asi que estos tests corren sin RAM concreta, sin monitor y sin disco. Es el mismo
# reparto que Get-AXEFpsStats vs Measure-AXEFps: si el juicio viviera dentro de la lectura de
# WMI solo se podria probar en la maquina del que lo escribio.
#
# Lo que NO se cubre y hay que saberlo: que Get-AXEDiagFacts lea bien WMI en una maquina real.
# Eso pide hardware. Los tests de abajo cubren el borde donde de verdad se rompen estas cosas:
# el umbral JEDEC de la heuristica de XMP, y que un dato ausente degrade a UNKNOWN y no a OK.

BeforeAll {
    . "$PSScriptRoot/../src/35-diag.ps1"
    # Atajo: hallazgo por Id, que es como se consultan en los asserts.
    function Find($findings,$id){ $findings | Where-Object Id -eq $id }
    # Hechos por defecto, todos correctos. Cada test rompe SOLO el campo que mide.
    # CpuCores/CpuThreads van aqui porque "todo correcto" tiene que dar CERO UNKNOWN: sin ellos
    # el hallazgo 'hybrid' (anadido despues que este helper) salia UNKNOWN y el render dejaba de
    # decir 'Nada mal configurado'. 8/16 = HT en todos los nucleos = NO hibrida = nada que avisar.
    function OkFacts { [pscustomobject]@{
        MemModules=2; MemSpeedMhz=6000; MemType=34; MemLocators=@('DIMM_A2','DIMM_B2')
        RefreshCur=144; RefreshMax=144; IsSSD=$true; CpuCores=8; CpuThreads=16 } }
}

Describe 'Heuristica de XMP/EXPO' -Tag 'unit' {

    It 'marca DDR5 a la base JEDEC (4800) como XMP apagado' {
        $f = OkFacts; $f.MemSpeedMhz = 4800
        (Find (Get-AXEDiagFindings -Facts $f) 'xmp').Status | Should -Be 'BAD'
    }
    It 'marca DDR4 a la base JEDEC (2666) como XMP apagado' {
        $f = OkFacts; $f.MemType = 26; $f.MemSpeedMhz = 2666
        (Find (Get-AXEDiagFindings -Facts $f) 'xmp').Status | Should -Be 'BAD'
    }
    It 'da OK justo por encima del umbral' {
        # 4801 y no 6000: el borde es donde se rompen los <= mal escritos.
        $f = OkFacts; $f.MemSpeedMhz = 4801
        (Find (Get-AXEDiagFindings -Facts $f) 'xmp').Status | Should -Be 'OK'
    }
    It 'no inventa veredicto con un tipo de memoria desconocido' {
        # DDR3 (24) no esta en la tabla JEDEC: sin base no hay heuristica posible.
        $f = OkFacts; $f.MemType = 24
        (Find (Get-AXEDiagFindings -Facts $f) 'xmp').Status | Should -Be 'UNKNOWN'
    }
    It 'declara la heuristica como tal en la confianza' {
        # El texto de confianza es parte del contrato: sin el, una heuristica se lee como medida.
        (Find (Get-AXEDiagFindings -Facts (OkFacts)) 'xmp').Confidence | Should -Match 'heuristica'
    }
}

Describe 'Canales de RAM' -Tag 'unit' {

    It 'un solo modulo es single channel seguro' {
        $f = OkFacts; $f.MemModules = 1
        $r = Find (Get-AXEDiagFindings -Facts $f) 'ramchan'
        $r.Status     | Should -Be 'BAD'
        $r.Confidence | Should -Be 'cierta'
    }
    It 'con dos modulos no afirma dual channel, solo lo llama probable' {
        # WMI no confirma el canal: dos modulos en A1+A2 son single y aqui saldrian igual.
        $r = Find (Get-AXEDiagFindings -Facts (OkFacts)) 'ramchan'
        $r.Status     | Should -Be 'OK'
        $r.Confidence | Should -Match 'parcial'
    }
}

Describe 'Refresco del monitor' -Tag 'unit' {

    It 'detecta un panel de 144Hz puesto a 60' {
        $f = OkFacts; $f.RefreshCur = 60
        $r = Find (Get-AXEDiagFindings -Facts $f) 'refresh'
        $r.Status | Should -Be 'BAD'
        $r.EstPct | Should -Be '2.4x'
    }
    It 'da OK cuando ya va al maximo' {
        (Find (Get-AXEDiagFindings -Facts (OkFacts)) 'refresh').Status | Should -Be 'OK'
    }
}

Describe 'Dato ausente degrada a UNKNOWN, nunca a OK' -Tag 'unit' {

    # El fallo peligroso de un diagnostico no es equivocarse: es dar por bueno lo que no miro.
    # Un OK falso es justo lo que hace que estas herramientas no sirvan para nada.
    It 'sin velocidad de memoria no da OK a XMP' {
        $f = OkFacts; $f.MemSpeedMhz = $null
        (Find (Get-AXEDiagFindings -Facts $f) 'xmp').Status | Should -Be 'UNKNOWN'
    }
    It 'sin numero de modulos no da OK a los canales' {
        $f = OkFacts; $f.MemModules = $null
        (Find (Get-AXEDiagFindings -Facts $f) 'ramchan').Status | Should -Be 'UNKNOWN'
    }
    It 'sin refresco no da OK al monitor' {
        $f = OkFacts; $f.RefreshMax = $null
        (Find (Get-AXEDiagFindings -Facts $f) 'refresh').Status | Should -Be 'UNKNOWN'
    }
    It 'sin tipo de disco no da OK al SSD' {
        $f = OkFacts; $f.IsSSD = $null
        (Find (Get-AXEDiagFindings -Facts $f) 'ssd').Status | Should -Be 'UNKNOWN'
    }
    It 'con todo a null ningun hallazgo sale OK' {
        $empty = [pscustomobject]@{ MemModules=$null; MemSpeedMhz=$null; MemType=$null
                                    MemLocators=$null; RefreshCur=$null; RefreshMax=$null; IsSSD=$null }
        @(Get-AXEDiagFindings -Facts $empty | Where-Object Status -eq 'OK') | Should -HaveCount 0
    }
}

Describe 'Render' -Tag 'unit' {

    It 'avisa de que el porcentaje es estimacion y no medida de esta maquina' {
        # Sin esta linea el numero se lee como promesa, que es lo que hace el marketing que
        # este modulo existe para no imitar.
        $f = OkFacts; $f.MemModules = 1
        $txt = (Format-AXEDiag -Findings (Get-AXEDiagFindings -Facts $f)) -join "`n"
        $txt | Should -Match 'NO medida en esta maquina'
    }
    It 'con todo correcto no inventa problemas' {
        $txt = (Format-AXEDiag -Findings (Get-AXEDiagFindings -Facts (OkFacts))) -join "`n"
        $txt | Should -Match 'Nada mal configurado'
    }
}

Describe 'Refresco: EDID del panel vs modo del adaptador' -Tag 'unit' {

    # El TODO que este modulo llevaba declarado: MaxRefreshRate es el maximo del MODO ACTUAL,
    # asi que un panel de 144 puesto a 60 podia reportar 60/60 y salir OK.
    It 'caza el falso negativo que el adaptador escondia' {
        $f = OkFacts; $f.RefreshCur = 60; $f.RefreshMax = 60
        (Find (Get-AXEDiagFindings -Facts $f) 'refresh').Status | Should -Be 'OK'   # sin EDID no se sabe
        $f2 = OkFacts; $f2.RefreshCur = 60; $f2.RefreshMax = 60
        $f2 | Add-Member PanelMaxHzAtRes 144 -Force
        $r = Find (Get-AXEDiagFindings -Facts $f2) 'refresh'
        $r.Status | Should -Be 'BAD'
        $r.Detail | Should -Match '144'
    }

    # MEDIDO EN UN PORTATIL REAL: WmiMonitorListedSupportedSourceModes devolvio 60 Hz en un
    # panel que estaba corriendo a 180. Sin el clamp al actual, el hallazgo imprimia
    # "A 180Hz, el maximo disponible (60 Hz)": falso y ademas absurdo.
    It 'no se cree una lista de EDID que reporta MENOS que el refresco actual' {
        $f = OkFacts; $f.RefreshCur = 180; $f.RefreshMax = 180
        $f | Add-Member PanelMaxHzAtRes 60 -Force
        $r = Find (Get-AXEDiagFindings -Facts $f) 'refresh'
        $r.Status | Should -Be 'OK'
        $r.Detail | Should -Not -Match '60 Hz'
        $r.Confidence | Should -Match 'incompletas'
    }

    It 'prefiere el maximo A TU RESOLUCION antes que el absoluto del panel' {
        # Panel de 240@1080p pero 144@1440p, corriendo a 144: mandar a buscar 240 seria un
        # falso positivo, porque a esa resolucion no existen.
        $f = OkFacts; $f.RefreshCur = 144; $f.RefreshMax = 144
        $f | Add-Member PanelMaxHz 240 -Force
        $f | Add-Member PanelMaxHzAtRes 144 -Force
        (Find (Get-AXEDiagFindings -Facts $f) 'refresh').Status | Should -Be 'OK'
    }

    It 'usa el absoluto solo si no se supo la resolucion actual' {
        $f = OkFacts; $f.RefreshCur = 60; $f.RefreshMax = 60
        $f | Add-Member PanelMaxHz 144 -Force
        (Find (Get-AXEDiagFindings -Facts $f) 'refresh').Status | Should -Be 'BAD'
    }

    It 'sin ninguna fuente de modos sigue siendo UNKNOWN, no un OK disfrazado' {
        # RefreshCur NO puede establecer el maximo: si lo hiciera, "no se cual es el maximo"
        # se convertiria en "estas al maximo", que es justo el OK sin comprobar que este
        # modulo existe para no dar.
        $f = OkFacts; $f.RefreshMax = $null
        (Find (Get-AXEDiagFindings -Facts $f) 'refresh').Status | Should -Be 'UNKNOWN'
    }
}

Describe 'Nucleos P/E: aritmetica, no el nombre comercial' -Tag 'unit' {

    BeforeAll {
        function HybFacts($cores,$threads,$win11){
            $f = OkFacts
            $f | Add-Member CpuCores $cores -Force
            $f | Add-Member CpuThreads $threads -Force
            $f | Add-Member IsWin11 $win11 -Force
            $f
        }
    }

    It 'reparte bien un i9-13900H (14 nucleos / 20 hilos = 6P + 8E)' {
        $r = Find (Get-AXEDiagFindings -Facts (HybFacts 14 20 $true)) 'hybrid'
        $r.Detail | Should -Match '6 nucleos P'
        $r.Detail | Should -Match '8 nucleos E'
    }

    It 'marca MAL una CPU hibrida en Windows 10 (sin Thread Director)' {
        $r = Find (Get-AXEDiagFindings -Facts (HybFacts 14 20 $false)) 'hybrid'
        $r.Status | Should -Be 'BAD'
        $r.Fix | Should -Match 'Windows 11'
    }

    It 'da OK a una hibrida en Windows 11 y avisa de NO forzar afinidad' {
        $r = Find (Get-AXEDiagFindings -Facts (HybFacts 14 20 $true)) 'hybrid'
        $r.Status | Should -Be 'OK'
        $r.Confidence | Should -Match 'NO fuerces la afinidad'
    }

    It 'no confunde HT en todos los nucleos con una hibrida' {
        # 8 nucleos / 16 hilos: todos con HT, no hay ninguno sin el.
        $r = Find (Get-AXEDiagFindings -Facts (HybFacts 8 16 $false)) 'hybrid'
        $r.Status | Should -Be 'OK'
        $r.Detail | Should -Match 'no hibrida'
    }

    It 'no confunde una CPU sin HT con una toda de nucleos E' {
        # 8 nucleos / 8 hilos. Sin el gate, P = 8-8 = 0 y E = 8: diria que todo son nucleos E.
        $r = Find (Get-AXEDiagFindings -Facts (HybFacts 8 8 $true)) 'hybrid'
        $r.Status | Should -Be 'OK'
        $r.Detail | Should -Match 'no hibrida'
    }

    It 'degrada a UNKNOWN sin datos de CPU, nunca a OK' {
        (Find (Get-AXEDiagFindings -Facts (HybFacts $null $null $true)) 'hybrid').Status | Should -Be 'UNKNOWN'
    }
}
