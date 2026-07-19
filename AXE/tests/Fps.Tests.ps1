# Unit - medicion de FPS (33-fps.ps1).
#
# Todo lo que se testea aqui es PURO a posta: el calculo de estadisticas y el veredicto no
# tocan disco ni necesitan PresentMon instalado ni un juego abierto. Esa separacion es el
# motivo de que Get-AXEFpsStats reciba un array de tiempos de frame en vez de una ruta de CSV:
# si el calculo viviera dentro de Measure-AXEFps solo se podria probar con un juego corriendo,
# o sea nunca en CI.
#
# Lo que NO se cubre y hay que saberlo: que PresentMon enganche de verdad un juego. Eso pide
# hardware, un titulo abierto y admin para la sesion ETW. Los tests de abajo cubren el borde
# donde de verdad se rompen estas cosas: version de PresentMon que cambia el nombre de la
# columna, capturas cortas y deltas que son ruido.

BeforeAll {
    $script:AXEData = Join-Path ([System.IO.Path]::GetTempPath()) ('axe-test-fps-' + [guid]::NewGuid().ToString('N'))
    $script:AXERoot = $script:AXEData
    New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
    function Write-AXELog($m,$l='INFO'){ }
    . "$PSScriptRoot/../src/33-fps.ps1"
}
AfterAll { Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue }

Describe 'Deteccion de la columna de tiempo de frame' -Tag 'unit' {

    It 'reconoce el nombre de PresentMon 1.x' {
        (Get-AXEFrameTimeColumn ([pscustomobject]@{ Application='x'; msBetweenPresents='16.6' })) | Should -Be 'msBetweenPresents'
    }
    It 'reconoce el nombre de PresentMon 2.x' {
        (Get-AXEFrameTimeColumn ([pscustomobject]@{ Application='x'; FrameTime='16.6' })) | Should -Be 'FrameTime'
    }
    It 'columna desconocida da null en vez de adivinar' {
        # Devolver una columna al azar seria peor que fallar: saldrian estadisticas de basura
        # presentadas como FPS.
        (Get-AXEFrameTimeColumn ([pscustomobject]@{ Foo='1'; Bar='2' })) | Should -BeNullOrEmpty
        (Get-AXEFrameTimeColumn $null) | Should -BeNullOrEmpty
    }
}

Describe 'Get-AXEFpsStats' -Tag 'unit' {

    It '60 FPS constantes dan 60 FPS' {
        $s = Get-AXEFpsStats -FrameTimesMs (@(16.667) * 100)
        $s.Ok      | Should -BeTrue
        $s.AvgFps  | Should -Be 60
        $s.Frames  | Should -Be 100
        $s.StdevMs | Should -Be 0
    }

    It 'el 1% low usa los frames MAS LENTOS, no los mas rapidos' {
        # 99 frames a 10ms (100 FPS) + 1 frame de 100ms (10 FPS). El 1% low tiene que ser ~10,
        # no ~100. Si el signo del ordenamiento se invirtiera, este test lo caza.
        $ft = @(@(10.0) * 99) + @(100.0)
        $s = Get-AXEFpsStats -FrameTimesMs $ft
        $s.P1LowFps | Should -Be 10
        $s.AvgFps   | Should -BeGreaterThan 80
    }

    It 'el medio no se lo come un solo tiron, el 1% low si' {
        # Justo el motivo de que el informe ensene los minimos primero.
        $ft = @(@(16.667) * 999) + @(200.0)
        $s = Get-AXEFpsStats -FrameTimesMs $ft
        $s.AvgFps   | Should -BeGreaterThan 55
        $s.P1LowFps | Should -BeLessThan 30
    }

    It 'captura demasiado corta no devuelve estadisticas, devuelve el motivo' {
        $s = Get-AXEFpsStats -FrameTimesMs @(16.6,16.6,16.6)
        $s.Ok     | Should -BeFalse
        $s.Reason | Should -Match 'demasiado corta'
    }

    It 'descarta tiempos de frame no positivos' {
        $s = Get-AXEFpsStats -FrameTimesMs (@(@(16.667) * 50) + @(0.0, -5.0))
        $s.Frames | Should -Be 50
    }
}

Describe 'Get-AXEFpsVerdict' -Tag 'unit' {

    BeforeAll {
        # Ruido realista: 60 FPS con variacion, generado determinista (sin Get-Random) para que
        # el test no sea flaky.
        $script:mk = {
            param($baseMs,$jitterMs,$n)
            $ft = foreach($i in 0..($n-1)){ $baseMs + $jitterMs * [math]::Sin($i * 0.7) }
            Get-AXEFpsStats -FrameTimesMs @($ft)
        }
    }

    It 'dos capturas identicas NO son concluyentes' {
        $a = & $script:mk 16.667 1.0 2000
        $b = & $script:mk 16.667 1.0 2000
        $v = Get-AXEFpsVerdict -Before $a -After $b
        $v.Conclusive | Should -BeFalse
        $v.Reason     | Should -Match 'ruido'
    }

    It 'una mejora grande y limpia SI es concluyente' {
        $a = & $script:mk 20.0 0.5 2000     # 50 FPS
        $b = & $script:mk 16.667 0.5 2000   # 60 FPS
        $v = Get-AXEFpsVerdict -Before $a -After $b
        $v.Conclusive | Should -BeTrue
        $v.DeltaFps   | Should -BeGreaterThan 5
    }

    It 'una mejora minima enterrada en ruido NO es concluyente' {
        # 0.05ms de diferencia con 3ms de jitter: el numero sube, la senal no existe. Este es
        # el caso que separa esta herramienta de un tweaker que ensena cualquier delta positivo.
        $a = & $script:mk 16.70 3.0 500
        $b = & $script:mk 16.65 3.0 500
        $v = Get-AXEFpsVerdict -Before $a -After $b
        $v.Conclusive | Should -BeFalse
    }

    It 'el aviso de misma-escena sale TAMBIEN cuando el resultado es bueno' {
        $a = & $script:mk 20.0 0.5 2000
        $b = & $script:mk 16.667 0.5 2000
        $v = Get-AXEFpsVerdict -Before $a -After $b
        $v.Conclusive | Should -BeTrue
        $v.Warning    | Should -Match 'MISMA escena'
    }

    It 'captura invalida o ausente no lanza y no concluye' {
        (Get-AXEFpsVerdict -Before $null -After $null).Conclusive | Should -BeFalse
        $bad = Get-AXEFpsStats -FrameTimesMs @(16.6)
        (Get-AXEFpsVerdict -Before $bad -After $bad).Conclusive   | Should -BeFalse
    }
}

Describe 'Localizacion de PresentMon' -Tag 'unit' {

    It 'no lanza y devuelve ruta o null' {
        # Sin assert sobre si esta instalado: depende de la maquina y de CI.
        { Get-AXEPresentMon } | Should -Not -Throw
        $p = Get-AXEPresentMon
        if($p){ $p | Should -BeOfType [string] }
    }

    It 'sin PresentMon, Measure-AXEFps explica donde conseguirlo en vez de fallar a secas' {
        # Si la maquina lo tiene instalado, el test se salta en vez de mentir sobre lo que probo.
        if(Get-AXEPresentMon){ Set-ItResult -Skipped -Because 'esta maquina tiene PresentMon instalado'; return }
        $r = Measure-AXEFps -ProcessName 'proceso_que_no_existe'
        $r.Ok     | Should -BeFalse
        $r.Reason | Should -Match 'PresentMon no encontrado'
        $r.Reason | Should -Match 'github\.com/GameTechDev/PresentMon'
    }
}

Describe 'Format-AXEFpsStats' -Tag 'unit' {

    It 'ensena los minimos ANTES que la media' {
        $s = Get-AXEFpsStats -FrameTimesMs (@(16.667) * 200)
        $s | Add-Member -NotePropertyName Process -NotePropertyValue 'juego.exe' -Force
        $txt = (Format-AXEFpsStats $s 'Antes') -join "`n"
        $txt | Should -Match '1% low'
        ($txt.IndexOf('1% low')) | Should -BeLessThan ($txt.IndexOf('Medio'))
    }

    It 'captura fallida imprime el motivo, no estadisticas vacias' {
        $bad = Get-AXEFpsStats -FrameTimesMs @(16.6)
        (Format-AXEFpsStats $bad 'Antes') -join "`n" | Should -Match 'demasiado corta'
    }
}
