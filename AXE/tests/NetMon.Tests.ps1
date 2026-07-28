# Tests del monitor de red (src/37-netmon.ps1).
# Solo se testea la parte PURA: Get-AXENetStats y Get-AXENetFindings reciben muestras y
# devuelven numeros/hallazgos sin tocar la red. Measure-AXENetProbe y Get-AXENetGateway
# hablan con hardware y red reales, asi que no se testean aqui: un test que dependa del
# router de quien lo ejecute no es un test, es una loteria.
BeforeAll {
    . "$PSScriptRoot/../src/37-netmon.ps1"
}

Describe 'Get-AXENetStats' {
    It 'sin muestras devuelve ceros y nulls, no revienta' {
        $s = Get-AXENetStats -Samples @()
        $s.Sent | Should -Be 0
        $s.Received | Should -Be 0
        $s.AvgMs | Should -BeNullOrEmpty
        $s.JitterMs | Should -BeNullOrEmpty
    }

    It 'cuenta la perdida como porcentaje del total enviado' {
        # 10 sondas, 3 perdidas => 30%
        $s = Get-AXENetStats -Samples @(10,11,$null,12,$null,13,14,$null,15,16)
        $s.Sent | Should -Be 10
        $s.Received | Should -Be 7
        $s.LostPct | Should -Be 30
    }

    It 'con perdida total reporta 100% y deja las latencias en null' {
        $s = Get-AXENetStats -Samples @($null,$null,$null)
        $s.LostPct | Should -Be 100
        $s.MinMs | Should -BeNullOrEmpty
        $s.P95Ms | Should -BeNullOrEmpty
    }

    It 'min/med/max salen de las muestras recibidas' {
        $s = Get-AXENetStats -Samples @(10,20,30,$null)
        $s.MinMs | Should -Be 10
        $s.MaxMs | Should -Be 30
        $s.AvgMs | Should -Be 20
    }

    It 'jitter cero cuando el RTT es constante' {
        $s = Get-AXENetStats -Samples @(15,15,15,15,15)
        $s.JitterMs | Should -Be 0
    }

    It 'jitter = media del salto entre paquetes consecutivos, no la desviacion tipica' {
        # 10,20,10,20 -> deltas 10,10,10 -> jitter 10.
        # La desviacion tipica de esa serie es ~5.8: si el test pasara con 5.8 seria que
        # alguien cambio la definicion por la de siempre y el numero dejaria de significar
        # "lo inestable que se percibe".
        $s = Get-AXENetStats -Samples @(10,20,10,20)
        $s.JitterMs | Should -Be 10
    }

    It 'una rampa monotona da jitter bajo aunque la desviacion sea grande' {
        # 10..50 en pasos de 10: desviacion grande, saltos constantes de 10.
        $s = Get-AXENetStats -Samples @(10,20,30,40,50)
        $s.JitterMs | Should -Be 10
    }

    It 'no encadena los extremos de un hueco de perdida al calcular el jitter' {
        # Si el hueco se ignorase encadenando 10 con 100, saldria un delta de 90 inventado:
        # ese intervalo cubre dos periodos, no uno. Solo cuenta el par consecutivo real 100->110.
        $s = Get-AXENetStats -Samples @(10,$null,100,110)
        $s.JitterMs | Should -Be 10
    }

    It 'P95 usa rango entero, sin interpolar' {
        # 20 muestras: ceil(0.95*20)-1 = 18 => el penultimo de la serie ordenada.
        $s = Get-AXENetStats -Samples (1..20)
        $s.P95Ms | Should -Be 19
    }

    It 'con una sola muestra el P95 es esa muestra y no hay jitter' {
        $s = Get-AXENetStats -Samples @(42)
        $s.P95Ms | Should -Be 42
        $s.JitterMs | Should -BeNullOrEmpty
    }
}

Describe 'Get-AXENetFindings' {
    It 'enlace y salida limpios: un solo hallazgo OK que repite el limite ICMP' {
        $gw  = Get-AXENetStats -Samples @(1,1,1,1)
        $pub = Get-AXENetStats -Samples @(20,21,20,21)
        $f = @(Get-AXENetFindings -Gw $gw -Pub $pub)
        $f.Count | Should -Be 1
        $f[0].Sev | Should -Be 'OK'
        $f[0].Msg | Should -Match 'ICMP'
    }

    It 'cualquier perdida contra el router es ERR, no aviso' {
        $gw  = Get-AXENetStats -Samples @(1,1,$null,1)   # 25%
        $pub = Get-AXENetStats -Samples @(20,21,20,21)
        $f = @(Get-AXENetFindings -Gw $gw -Pub $pub)
        @($f | Where-Object Sev -eq 'ERR').Count | Should -Be 1
    }

    It 'router mudo se reporta como ERR y no como perdida normal' {
        $gw  = Get-AXENetStats -Samples @($null,$null,$null)
        $f = @(Get-AXENetFindings -Gw $gw -Pub $null)
        $f[0].Sev | Should -Be 'ERR'
        $f[0].Msg | Should -Match 'no responde'
    }

    It 'jitter local por encima del corte practico avisa' {
        # deltas de 10ms => jitter 10 > 5
        $gw = Get-AXENetStats -Samples @(1,11,1,11)
        $f = @(Get-AXENetFindings -Gw $gw -Pub $null)
        @($f | Where-Object Sev -eq 'WARN').Count | Should -Be 1
    }

    It 'sin medida hacia internet deja las dos lecturas abiertas, no acusa al enlace' {
        $gw = Get-AXENetStats -Samples @(1,11,1,11)
        $f = @(Get-AXENetFindings -Gw $gw -Pub $null)
        $w = @($f | Where-Object Sev -eq 'WARN')[0]
        $w.Msg | Should -Match 'Dos lecturas posibles'
    }

    It 'si el tramo a internet sale mas estable, culpa a la CPU del router y no al enlace' {
        # El trafico a internet ATRAVIESA el mismo router: si ese tramo es estable, el enlace
        # no puede ser el cuello, y el jitter contra la puerta de enlace es la ruta lenta de
        # gestion del aparato. Sin esta rama el informe acusaria al Wi-Fi del usuario sin base.
        $gw  = Get-AXENetStats -Samples @(1,11,1,11)     # jitter 10
        $pub = Get-AXENetStats -Samples @(20,20,20,20)   # jitter 0
        $w = @(Get-AXENetFindings -Gw $gw -Pub $pub | Where-Object Sev -eq 'WARN')[0]
        $w.Msg | Should -Match 'CPU de gestion'
        $w.Msg | Should -Not -Match 'Dos lecturas posibles'
    }

    It 'perdida fuera con enlace limpio senala al operador, no al PC' {
        $gw  = Get-AXENetStats -Samples @(1,1,1,1)
        $pub = Get-AXENetStats -Samples @(20,$null,20,21)
        $f = @(Get-AXENetFindings -Gw $gw -Pub $pub)
        $w = @($f | Where-Object Sev -eq 'WARN')
        $w.Count | Should -Be 1
        $w[0].Msg | Should -Match 'fuera de casa'
    }

    It 'no culpa al operador si el enlace local tambien pierde' {
        # Con perdida en los dos tramos no se puede afirmar donde esta el problema: el
        # hallazgo de operador NO debe aparecer, solo el ERR del enlace.
        $gw  = Get-AXENetStats -Samples @(1,$null,1,1)
        $pub = Get-AXENetStats -Samples @(20,$null,20,21)
        $f = @(Get-AXENetFindings -Gw $gw -Pub $pub)
        @($f | Where-Object { $_.Msg -match 'fuera de casa' }).Count | Should -Be 0
        @($f | Where-Object Sev -eq 'ERR').Count | Should -Be 1
    }

    It 'sin ninguna medicion no inventa hallazgos' {
        $f = @(Get-AXENetFindings -Gw $null -Pub $null)
        $f.Count | Should -Be 1
        $f[0].Sev | Should -Be 'OK'
    }
}

Describe 'Get-AXELoadedLatency - bufferbloat' -Tag 'unit' {

    # Puro: recibe dos objetos de Get-AXENetStats ya construidos. No abre red, no descarga
    # nada. La parte que satura el enlace (Start-AXENetLoad) habla con internet y no se
    # testea aqui, por lo mismo que Measure-AXENetProbe: dependeria del router de quien lo
    # ejecute, y eso no es un test.
    BeforeAll {
        # 50 MB: por encima del minimo de 2 MB, o sea que la prueba cuenta como valida.
        $script:OkBytes = 50MB
        function Stats([object]$p95,[object]$avg){ [pscustomobject]@{ P95Ms=$p95; AvgMs=$avg } }
    }

    It 'da A+ cuando el ping no se mueve con el enlace saturado' {
        $v = Get-AXELoadedLatency -Idle (Stats 20 18) -Loaded (Stats 22 19) -Bytes $script:OkBytes
        $v.Grade  | Should -Be 'A+'
        $v.Status | Should -Be 'OK'
    }

    It 'suspende cuando el router acumula cola' {
        $v = Get-AXELoadedLatency -Idle (Stats 20 18) -Loaded (Stats 520 300) -Bytes $script:OkBytes
        $v.Grade    | Should -Be 'F'
        $v.Status   | Should -Be 'BAD'
        $v.DeltaP95 | Should -Be 500
    }

    It 'puntua por el P95 y no por la media' {
        # La media sube 5 ms (parece bien) pero la cola sube 150: eso es lo que se sufre.
        $v = Get-AXELoadedLatency -Idle (Stats 20 20) -Loaded (Stats 170 25) -Bytes $script:OkBytes
        $v.Status   | Should -Be 'BAD'
        $v.DeltaAvg | Should -Be 5
    }

    It 'no premia el ruido: un delta negativo no puede dar mejor nota que cero' {
        # Saturar el enlace no puede BAJAR el ping. Si sale negativo es ruido de medicion.
        $v = Get-AXELoadedLatency -Idle (Stats 30 28) -Loaded (Stats 25 24) -Bytes $script:OkBytes
        $v.Grade | Should -Be 'A+'
    }

    It 'se niega a puntuar si la descarga no llego a saturar el enlace' {
        # Sin carga real un resultado bueno significaria "no se cargo", no "aguanta". Es el
        # mismo principio que el n=3 del consejero: sin datos suficientes no se afirma.
        $v = Get-AXELoadedLatency -Idle (Stats 20 18) -Loaded (Stats 21 19) -Bytes 100KB
        $v.Status | Should -Be 'UNKNOWN'
        $v.Grade  | Should -BeNullOrEmpty
        $v.Detail | Should -Match 'no se saturo'
    }

    It 'degrada a UNKNOWN si un extremo no respondio, nunca a OK' {
        (Get-AXELoadedLatency -Idle $null -Loaded (Stats 20 18) -Bytes $script:OkBytes).Status | Should -Be 'UNKNOWN'
        (Get-AXELoadedLatency -Idle (Stats 20 18) -Loaded (Stats $null $null) -Bytes $script:OkBytes).Status | Should -Be 'UNKNOWN'
    }

    It 'respeta los escalones de la escala' {
        # Frontera B/C en +60 ms: por debajo aprueba, por encima no.
        (Get-AXELoadedLatency -Idle (Stats 20 20) -Loaded (Stats 79 20) -Bytes $script:OkBytes).Status | Should -Be 'OK'
        (Get-AXELoadedLatency -Idle (Stats 20 20) -Loaded (Stats 81 20) -Bytes $script:OkBytes).Status | Should -Be 'BAD'
    }

    It 'no dice nunca que el problema sea la linea contratada' {
        # El buffer es del router. Culpar al operador manda a la gente a cambiar de contrato
        # por algo que se arregla con SQM.
        $v = Get-AXELoadedLatency -Idle (Stats 20 18) -Loaded (Stats 520 300) -Bytes $script:OkBytes
        $v.Detail | Should -Not -Match 'operador'
    }
}
