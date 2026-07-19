# Unit - logica de decision de 32-measure.ps1: veredicto del barrido (Get-AXESweepVerdict) y
# componente Timer del score (Get-AXEScore). NO mide nada: alimenta las funciones con datos
# sinteticos. Medir de verdad tarda ~60s y depende de la maquina, por eso ambas decisiones
# viven en funciones puras.
#
# El caso 'REGRESION' son los numeros de un barrido real en Win11 build 26200 que la version
# anterior declaro concluyente ganando por 0.001ms (spread 0.250 vs stdev 0.249).

# OJO Pester 5/6: las funciones declaradas a nivel top del fichero NO son visibles dentro de
# los It (discovery y run corren en scopes distintos). New-Point va en BeforeAll o los tests
# mueren con "The term 'New-Point' is not recognized".
BeforeAll {
    . "$PSScriptRoot/../src/32-measure.ps1"

    # Punto con N pasadas alrededor de una media, con dispersion controlada y determinista.
    # Alterna +/- para que la media salga exacta y la varianza no dependa del azar.
    function New-Point {
        param([double]$AppliedMs,[double]$Mean,[double]$Jitter=0.02,[int]$Passes=4)
        $pm = @()
        for($i=0; $i -lt $Passes; $i++){
            $sign = if($i % 2 -eq 0){ 1 } else { -1 }
            $pm += $Mean + ($sign * $Jitter)
        }
        [pscustomobject]@{
            AppliedMs  = $AppliedMs
            PassMeans  = $pm
            AvgDeltaMs = ($pm | Measure-Object -Average).Average
        }
    }
}

Describe 'Get-AXESweepVerdict' -Tag 'unit' {

    It 'un solo punto concedido -> no concluyente' {
        $v = Get-AXESweepVerdict -Points @((New-Point 0.5 0.30))
        $v.Conclusive | Should -BeFalse
        $v.Reason     | Should -Match 'un solo punto'
    }

    It 'REGRESION: barrido real de Win11 26200 -> NO concluyente' {
        # Curva medida: el delta BAJA segun sube la resolucion (0.502 -> 0.600).
        # El modelo de cuantizacion predice lo contrario (delta = 2R-1, creciente).
        # La version vieja decia "MEJOR 0.580ms". Debe salir NO concluyente.
        $obs = @(
            @(0.500,0.390), @(0.502,0.552), @(0.510,0.515), @(0.520,0.480),
            @(0.530,0.423), @(0.540,0.397), @(0.550,0.378), @(0.560,0.339),
            @(0.570,0.331), @(0.580,0.304), @(0.590,0.320), @(0.600,0.359)
        )
        $pts = $obs | ForEach-Object { New-Point $_[0] $_[1] 0.01 }
        $v = Get-AXESweepVerdict -Points $pts
        $v.Conclusive | Should -BeFalse
        $v.Reason     | Should -Match 'modelo'
        $v.ModelR     | Should -BeLessThan 0
    }

    It 'senal que sigue el modelo de cuantizacion -> concluyente' {
        # delta = 2R-1 (lo que predice la fisica) mas un offset fijo pequeno.
        $pts = @()
        foreach($r in 0.50,0.52,0.54,0.56,0.58,0.60){
            $pts += New-Point $r ((2*$r - 1) + 0.05) 0.002
        }
        $v = Get-AXESweepVerdict -Points $pts
        $v.Conclusive        | Should -BeTrue
        $v.Best.AppliedMs    | Should -Be 0.50
        $v.ModelR            | Should -BeGreaterThan 0.9
    }

    It 'spread grande pero curva invertida -> no concluyente (lo caza el modelo)' {
        $pts = @()
        foreach($r in 0.50,0.52,0.54,0.56,0.58,0.60){
            $pts += New-Point $r (1.0 - (2*$r - 1)) 0.002
        }
        $v = Get-AXESweepVerdict -Points $pts
        $v.Conclusive | Should -BeFalse
        $v.Reason     | Should -Match 'modelo'
    }

    It 'diferencias dentro del ruido -> no concluyente (lo caza la estadistica)' {
        # Medias siguiendo el modelo, pero dispersion entre pasadas mayor que el spread.
        $pts = @()
        foreach($r in 0.50,0.52,0.54,0.56,0.58,0.60){
            $pts += New-Point $r ((2*$r - 1) + 0.05) 0.40
        }
        $v = Get-AXESweepVerdict -Points $pts
        $v.Conclusive | Should -BeFalse
        $v.Reason     | Should -Match 'umbral'
    }

    It 'modelo sin poder de discriminacion -> decide solo la estadistica' {
        # 0.500 y 1.000 predicen ambos delta=0: el modelo no distingue. Con medias
        # practicamente iguales no hay nada que recomendar.
        $pts = @((New-Point 0.500 0.10 0.05), (New-Point 1.000 0.10 0.05))
        $v = Get-AXESweepVerdict -Points $pts
        $v.Conclusive | Should -BeFalse
    }
}

Describe 'Get-AXEScore - componente Timer' -Tag 'unit' {

    BeforeAll {
        function New-Snap {
            param($Timer)
            [pscustomobject]@{
                Timestamp='x'; Timer=$Timer; Jitter='n/a'
                TweaksOn='n/a'; TweaksApplicable='n/a'
            }
        }
    }

    It 'REGRESION: build con aislamiento + GTRR=1 + 1ms -> 30/30, no penaliza' {
        # El caso medido en Win11 26200: lat_timerres YA aplicado, resolucion instantanea 1ms
        # porque en ese segundo nadie pedia mas. La version vieja daba 20/30.
        $s = New-Snap ([pscustomobject]@{ CurrentMs=1.0; PerProcess=$true; GlobalRequests=1 })
        $sc = Get-AXEScore $s
        $sc.Timer | Should -Be 30
        $sc.Breakdown | Should -Match 'config OK'
    }

    It 'aislamiento sin GTRR -> parcial y dice que aplique lat_timerres' {
        $s = New-Snap ([pscustomobject]@{ CurrentMs=0.5; PerProcess=$true; GlobalRequests=$null })
        $sc = Get-AXEScore $s
        $sc.Timer | Should -Be 15
        $sc.Breakdown | Should -Match 'lat_timerres'
    }

    It 'aislamiento + GTRR=1 puntua igual con 0.5ms que con 15.6ms (es ambiental)' {
        $a = Get-AXEScore (New-Snap ([pscustomobject]@{ CurrentMs=0.5;  PerProcess=$true; GlobalRequests=1 }))
        $b = Get-AXEScore (New-Snap ([pscustomobject]@{ CurrentMs=15.6; PerProcess=$true; GlobalRequests=1 }))
        $a.Timer | Should -Be $b.Timer
    }

    It 'build sin aislamiento -> sigue la banda por resolucion' {
        $good = Get-AXEScore (New-Snap ([pscustomobject]@{ CurrentMs=0.5;  PerProcess=$false; GlobalRequests=$null }))
        $bad  = Get-AXEScore (New-Snap ([pscustomobject]@{ CurrentMs=15.6; PerProcess=$false; GlobalRequests=$null }))
        $good.Timer | Should -Be 30
        $bad.Timer  | Should -Be 0
    }

    It 'Timer n/a no rompe el score' {
        $sc = Get-AXEScore (New-Snap 'n/a')
        $sc.Timer | Should -Be 'n/a'
        $sc.Total | Should -BeGreaterOrEqual 0
        $sc.Total | Should -BeLessOrEqual 100
    }
}
