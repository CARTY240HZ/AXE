# Unit - latencia del sistema: sondeo del raton y tiempo en DPC (44-latency.ps1).
#
# Todo lo de aqui es PURO a posta. Get-AXEMouseRate recibe un array de intervalos en vez de
# cronometrar un raton, y Get-AXEDpcStats recibe dos instantaneas de contadores en vez de
# leerlos del kernel. Asi los casos que de verdad rompen esto -reportes perdidos, rafagas del
# planificador, un solo nucleo cargado- se prueban en CI, sin raton y sin drivers.
#
# Lo que NO se cubre y hay que saberlo: que [AXE.Lat]::SampleCursorIntervals cronometre bien un
# raton fisico, y que ProcessorPerf lea de verdad los contadores. Eso pide hardware. Se valido
# a mano con un generador sintetico que mueve el cursor a frecuencia conocida (125/500/1000 Hz,
# con y sin rafagas): 6 de 6 correctos. Los tests de abajo cubren la aritmetica.

BeforeAll {
    # 35-diag primero: Get-AXEMouseFindings construye con New-AXEDiagFinding y Format-AXELatency
    # delega el render en Format-AXEDiag. En el motor real ese orden lo garantiza el numero de
    # modulo (35 < 44); aqui hay que declararlo.
    . "$PSScriptRoot/../src/35-diag.ps1"
    . "$PSScriptRoot/../src/44-latency.ps1"

    function Find($findings,$id){ $findings | Where-Object Id -eq $id }

    # Genera intervalos de un raton a $Hz. $Drop = fraccion de reportes PERDIDOS (el cursor no
    # se movio en pixeles enteros), que se ven como un intervalo del doble. $Burst = fraccion
    # de reportes que llegan pegados al anterior, como los entrega el stack de entrada tras una
    # pausa de planificacion. El primer elemento simula la espera hasta el primer movimiento,
    # que Get-AXEMouseRate debe descartar siempre.
    function Intervals([double]$Hz, [int]$N = 400, [double]$Drop = 0.0, [double]$Burst = 0.0, [double]$Jitter = 0.05) {
        $T = 1000.0 / $Hz
        $rng = New-Object System.Random 42
        $out = New-Object System.Collections.Generic.List[double]
        [void]$out.Add(850.0)                     # reaccion humana: se descarta
        for($i=0; $i -lt $N; $i++){
            $r = $rng.NextDouble()
            $v = if($r -lt $Burst){ $T * 0.02 }             # rafaga: casi cero
                  elseif($r -lt ($Burst + $Drop)){ $T * 2 }  # reporte perdido: el doble
                  else { $T }
            # Jitter multiplicativo del planificador, +/- $Jitter.
            $v = $v * (1.0 + (($rng.NextDouble() - 0.5) * 2.0 * $Jitter))
            [void]$out.Add($v)
        }
        $out.ToArray()
    }

    # Instantanea plana de ProcessorPerf: 5 valores por CPU {Idle,Kernel,User,Dpc,Int}.
    function Perf([object[]]$Cpus) {
        $o = New-Object System.Collections.Generic.List[long]
        foreach($c in $Cpus){ foreach($v in $c){ [void]$o.Add([long]$v) } }
        $o.ToArray()
    }
}

Describe 'Get-AXEMouseRate - estimacion del sondeo' -Tag 'unit' {

    It 'acierta 1000 Hz con reportes limpios' {
        (Get-AXEMouseRate -Intervals (Intervals 1000)).Hz | Should -Be 1000
    }

    It 'acierta 125 Hz con reportes limpios' {
        (Get-AXEMouseRate -Intervals (Intervals 125)).Hz | Should -Be 125
    }

    It 'acierta 500 Hz con reportes limpios' {
        (Get-AXEMouseRate -Intervals (Intervals 500)).Hz | Should -Be 500
    }

    # ESTE es el caso que mata a la mediana: si un tercio de los reportes no mueve el cursor,
    # la mediana se va al doble del periodo y reporta la mitad de la frecuencia.
    It 'sigue acertando con un 35% de reportes perdidos (donde la mediana fallaria)' {
        (Get-AXEMouseRate -Intervals (Intervals 1000 400 0.35)).Hz | Should -Be 1000
    }

    # Y ESTE es el que mato al percentil 10 en la validacion con generador sintetico: las
    # rafagas del stack de entrada son intervalos casi cero, y el P10 los tomaba por el periodo
    # real. Medido entonces: 500 Hz -> reportaba 1000. Sobreestimar justo al doble es el peor
    # error posible porque cae en otro escalon estandar y encaja igual de limpio.
    It 'no sobreestima con un 25% de rafagas (donde el percentil 10 fallaba al doble)' {
        (Get-AXEMouseRate -Intervals (Intervals 500 600 0.0 0.25)).Hz | Should -Be 500
    }

    It 'aguanta perdidas y rafagas a la vez' {
        (Get-AXEMouseRate -Intervals (Intervals 1000 800 0.20 0.20)).Hz | Should -Be 1000
    }

    It 'descarta el primer intervalo (la espera hasta el primer movimiento)' {
        # 850 ms al frente serian 1.2 Hz. Si no se descartara, contaminaria el histograma.
        $r = Get-AXEMouseRate -Intervals (Intervals 1000)
        $r.Hz | Should -Be 1000
        $r.Samples | Should -Be 400          # 401 generados menos el primero
    }

    It 'devuelve UNKNOWN con motivo si no hubo movimiento suficiente' {
        $r = Get-AXEMouseRate -Intervals @(850.0, 1.0, 1.0)
        $r.Hz | Should -BeNullOrEmpty
        $r.Reason | Should -Match 'mover el raton'
    }

    It 'devuelve UNKNOWN con un array vacio, sin reventar' {
        (Get-AXEMouseRate -Intervals @()).Hz | Should -BeNullOrEmpty
    }

    It 'no encaja un sondeo que no es estandar y lo dice' {
        # 180 Hz: a 0.44 de 125 y a 0.28 de 250, o sea fuera de la tolerancia de ambos.
        # (300 Hz NO vale como caso: |300-250|/250 = 0.20 exacto, justo dentro del umbral.)
        $r = Get-AXEMouseRate -Intervals (Intervals 180 400 0 0 0.01)
        $r.Snapped | Should -BeFalse
        $r.Confidence | Should -Match 'no encaja'
    }

    It 'baja la confianza cuando los intervalos salen muy repartidos' {
        # Jitter enorme: ninguna cubeta se lleva un tercio de las muestras.
        $r = Get-AXEMouseRate -Intervals (Intervals 1000 600 0.3 0.3 0.9)
        $r.Confidence | Should -Match 'parcial'
    }

    It 'ignora intervalos nulos o negativos' {
        $iv = @(850.0) + @(1.0) * 200 + @($null, -5.0, 0.0)
        (Get-AXEMouseRate -Intervals $iv).Hz | Should -Be 1000
    }
}

Describe 'Get-AXEMouseFindings - hallazgos del raton' -Tag 'unit' {

    It 'marca MAL un sondeo por debajo de 500 Hz' {
        $r = Find (Get-AXEMouseFindings -Rate ([pscustomobject]@{Hz=125;Confidence='cierta'}) -Settings $null) 'mouse_rate'
        $r.Status | Should -Be 'BAD'
        $r.Detail | Should -Match '125 Hz'
    }

    It 'da OK a 1000 Hz' {
        (Find (Get-AXEMouseFindings -Rate ([pscustomobject]@{Hz=1000;Confidence='cierta'}) -Settings $null) 'mouse_rate').Status | Should -Be 'OK'
    }

    It 'propaga el motivo del UNKNOWN al hallazgo en vez de inventar un numero' {
        $rate = [pscustomobject]@{Hz=$null; Reason='no movio el raton.'; Confidence='desconocida'}
        $r = Find (Get-AXEMouseFindings -Rate $rate -Settings $null) 'mouse_rate'
        $r.Status | Should -Be 'UNKNOWN'
        $r.Detail | Should -Be 'no movio el raton.'
    }

    It 'marca MAL la aceleracion del puntero activada' {
        $s = [pscustomobject]@{Accel=1; Sensitivity=10; QueueSize=100}
        (Find (Get-AXEMouseFindings -Rate $null -Settings $s) 'mouse_accel').Status | Should -Be 'BAD'
    }

    It 'da OK a la aceleracion desactivada' {
        $s = [pscustomobject]@{Accel=0; Sensitivity=10; QueueSize=100}
        (Find (Get-AXEMouseFindings -Rate $null -Settings $s) 'mouse_accel').Status | Should -Be 'OK'
    }

    It 'marca MAL un escalado que no es 1:1' {
        $s = [pscustomobject]@{Accel=0; Sensitivity=14; QueueSize=100}
        $r = Find (Get-AXEMouseFindings -Rate $null -Settings $s) 'mouse_scale'
        $r.Status | Should -Be 'BAD'
        $r.Detail | Should -Match '14'
    }

    It 'degrada a UNKNOWN si el registro no se pudo leer, nunca a OK' {
        $s = [pscustomobject]@{Accel=$null; Sensitivity=$null; QueueSize=$null}
        $f = Get-AXEMouseFindings -Rate $null -Settings $s
        (Find $f 'mouse_accel').Status | Should -Be 'UNKNOWN'
        (Find $f 'mouse_scale').Status | Should -Be 'UNKNOWN'
    }
}

Describe 'Get-AXEDpcStats - aritmetica de los contadores' -Tag 'unit' {

    It 'calcula el porcentaje por nucleo sobre Kernel+User' {
        # Kernel sube 100, User 0 => total 100. Dpc 10 => 10%. Int 5 => 5%.
        $b = Perf @(,@(0,1000,0,0,0))
        $a = Perf @(,@(0,1100,0,10,5))
        $s = Get-AXEDpcStats -Before $b -After $a
        $s.Cpus[0].DpcPct | Should -Be 10
        $s.Cpus[0].IsrPct | Should -Be 5
    }

    It 'NO suma Idle al denominador (KernelTime ya lo incluye)' {
        # Si Idle entrase en el denominador, 10/(100+900)=1% en vez de 10%.
        $b = Perf @(,@(0,1000,0,0,0))
        $a = Perf @(,@(900,1100,0,10,0))
        (Get-AXEDpcStats -Before $b -After $a).Cpus[0].DpcPct | Should -Be 10
    }

    It 'reporta el maximo por nucleo, no la media' {
        $b = Perf @(@(0,1000,0,0,0), @(0,1000,0,0,0))
        $a = Perf @(@(0,1100,0,1,0), @(0,1100,0,20,0))
        $s = Get-AXEDpcStats -Before $b -After $a
        $s.MaxDpcPct   | Should -Be 20
        $s.TotalDpcPct | Should -Be 10.5     # (1+20)/200
    }

    It 'identifica cual es el nucleo peor' {
        $b = Perf @(@(0,1000,0,0,0), @(0,1000,0,0,0), @(0,1000,0,0,0))
        $a = Perf @(@(0,1100,0,1,0), @(0,1100,0,2,0), @(0,1100,0,30,0))
        $s = Get-AXEDpcStats -Before $b -After $a
        ($s.Cpus | Sort-Object DpcPct -Descending)[0].Cpu | Should -Be 2
    }

    It 'devuelve vacio si las instantaneas no cuadran, sin reventar' {
        (Get-AXEDpcStats -Before (Perf @(,@(0,1,0,0,0))) -After @()).MaxDpcPct | Should -BeNullOrEmpty
        (Get-AXEDpcStats -Before @() -After @()).MaxDpcPct | Should -BeNullOrEmpty
    }

    It 'salta los nucleos sin tiempo transcurrido en vez de dividir por cero' {
        $b = Perf @(@(0,1000,0,0,0), @(0,1000,0,0,0))
        $a = Perf @(@(0,1000,0,0,0), @(0,1100,0,10,0))   # cpu0 sin cambio
        $s = Get-AXEDpcStats -Before $b -After $a
        $s.Cpus.Count | Should -Be 1
        $s.Cpus[0].Cpu | Should -Be 1
    }
}

Describe 'Get-AXEDpcFindings - veredicto del DPC' -Tag 'unit' {

    It 'marca MAL por encima del umbral' {
        $d = [pscustomobject]@{ Cpus=@([pscustomobject]@{Cpu=3;DpcPct=7.0;IsrPct=0.1}); MaxDpcPct=7.0; MaxIsrPct=0.1; TotalDpcPct=1.0; TotalIsrPct=0.1 }
        $r = Find (Get-AXEDpcFindings -Dpc $d) 'dpc'
        $r.Status | Should -Be 'BAD'
        $r.Detail | Should -Match 'nucleo 3'
    }

    It 'da OK por debajo del umbral' {
        $d = [pscustomobject]@{ Cpus=@([pscustomobject]@{Cpu=0;DpcPct=0.4;IsrPct=0.1}); MaxDpcPct=0.4; MaxIsrPct=0.1; TotalDpcPct=0.2; TotalIsrPct=0.1 }
        (Find (Get-AXEDpcFindings -Dpc $d) 'dpc').Status | Should -Be 'OK'
    }

    It 'aniade el hallazgo de interrupciones solo cuando pasa su umbral' {
        $lo = [pscustomobject]@{ Cpus=@([pscustomobject]@{Cpu=0;DpcPct=0.1;IsrPct=0.1}); MaxDpcPct=0.1; MaxIsrPct=0.1; TotalDpcPct=0.1; TotalIsrPct=0.1 }
        $hi = [pscustomobject]@{ Cpus=@([pscustomobject]@{Cpu=5;DpcPct=0.1;IsrPct=4.0}); MaxDpcPct=0.1; MaxIsrPct=4.0; TotalDpcPct=0.1; TotalIsrPct=1.0 }
        Find (Get-AXEDpcFindings -Dpc $lo) 'isr' | Should -BeNullOrEmpty
        (Find (Get-AXEDpcFindings -Dpc $hi) 'isr').Status | Should -Be 'BAD'
    }

    It 'degrada a UNKNOWN si no se pudo medir, nunca a OK' {
        (Find (Get-AXEDpcFindings -Dpc $null) 'dpc').Status | Should -Be 'UNKNOWN'
    }

    It 'nunca afirma QUE driver es: eso necesita ETW y no se hace' {
        $d = [pscustomobject]@{ Cpus=@([pscustomobject]@{Cpu=0;DpcPct=9.0;IsrPct=0.1}); MaxDpcPct=9.0; MaxIsrPct=0.1; TotalDpcPct=2.0; TotalIsrPct=0.1 }
        $r = Find (Get-AXEDpcFindings -Dpc $d) 'dpc'
        $r.Fix | Should -Match 'AXE no lo atribuye'
        $r.Detail | Should -Not -Match '\.sys'
    }
}

Describe 'Format-AXELatency - render' -Tag 'unit' {

    BeforeAll {
        $script:F = Get-AXEMouseFindings -Rate ([pscustomobject]@{Hz=125;Confidence='cierta'}) `
                                         -Settings ([pscustomobject]@{Accel=1;Sensitivity=14;QueueSize=100})
    }

    It 'saca solo ASCII (la leccion del punto medio que salia como A-circunflejo)' {
        foreach($line in (Format-AXELatency -Findings $script:F -WithDpcNote)){
            foreach($ch in $line.ToCharArray()){
                [int]$ch | Should -BeLessOrEqual 127 -Because "'$line' lleva un caracter no ASCII"
            }
        }
    }

    It 'no manda a la BIOS por un problema de raton o de driver' {
        # El pie de Format-AXEDiag dice "viven en la BIOS, en los slots"; aqui seria falso.
        $txt = (Format-AXELatency -Findings $script:F) -join "`n"
        $txt | Should -Not -Match 'en los slots'
        $txt | Should -Match 'software del raton'
    }

    It 'incluye la nota del limite del DPC solo si se pide' {
        ((Format-AXELatency -Findings $script:F -WithDpcNote) -join "`n") | Should -Match 'LatencyMon'
        ((Format-AXELatency -Findings $script:F) -join "`n")             | Should -Not -Match 'LatencyMon'
    }
}
