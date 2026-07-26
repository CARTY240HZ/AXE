# Unit - el consejero (42-advisor.ps1). Todo lo de aqui es PURO o toca un unico json en un
# temporal; nada mide, nada aplica, nada toca el registro.
#
# Lo que se protege, por orden de importancia:
#   1. EL ORDEN. Un hallazgo del diagnostico (10-40% real) va SIEMPRE antes que el catalogo
#      (porcentajes de un digito). Invertirlo es lo que hace un optimizador que vende tweaks, y
#      es el unico test de este fichero cuyo fallo seria un problema de honestidad, no un bug.
#   2. QUE NO AFIRME SIN DATOS. Con menos de 3 medidas a cada lado, 'sin evidencia'. Siempre.
#   3. QUE NO DIGA "CAUSA". La comparacion es observacional y el texto tiene que decirlo.
#
# Lo que NO se testea, a proposito: Get-AXEAdviceNow (mide de verdad, tarda ~1s y depende de la
# maquina) y Get-AXEAppliedIds (ejecuta el Test de 82 tweaks contra el registro real).

BeforeAll {
    . "$PSScriptRoot/_load-engine.ps1"

    function New-Sample { param([int]$score,[string[]]$applied=@())
        [pscustomobject]@{ at='2026-07-26T09:00:00Z'; score=$score; jitter=$null; applied=$applied } }
    function New-Find { param($id,$status,$title='t',$detail='d')
        [pscustomobject]@{ Id=$id; Status=$status; Title=$title; Detail=$detail; Fix='f'; EstPct='10-30%'; Confidence='cierta' } }
    function KindsOf($plan){ @($plan | ForEach-Object { $_.Kind }) }
}

Describe 'Get-AXETweakEvidence - no afirma sin datos' -Tag 'unit' {

    It 'sin muestras dice "sin evidencia"' {
        (Get-AXETweakEvidence -Id 'x' -Samples @()).Verdict | Should -Be 'sin evidencia'
    }

    It 'con n insuficiente a un lado sigue siendo "sin evidencia"' {
        # 5 con el ajuste puesto pero solo 2 sin el: no basta. El corte es a CADA lado.
        $s = @(1..5 | ForEach-Object { New-Sample 80 @('x') }) + @(1..2 | ForEach-Object { New-Sample 60 @() })
        $ev = Get-AXETweakEvidence -Id 'x' -Samples $s
        $ev.Verdict | Should -Be 'sin evidencia'
        $ev.Detail  | Should -Match 'hacen falta 3'
    }

    It 'una diferencia dentro del ruido NO se presenta como mejora' {
        # 71 vs 70: un punto. Ensenar eso como "mejora" es exactamente como se fabrica un placebo.
        $s = @(1..3 | ForEach-Object { New-Sample 71 @('x') }) + @(1..3 | ForEach-Object { New-Sample 70 @() })
        (Get-AXETweakEvidence -Id 'x' -Samples $s).Verdict | Should -Be 'sin diferencia apreciable'
    }

    It 'con evidencia suficiente y diferencia real dice "asociado a", nunca "causa"' {
        $s = @(1..3 | ForEach-Object { New-Sample 80 @('x') }) + @(1..3 | ForEach-Object { New-Sample 60 @() })
        $ev = Get-AXETweakEvidence -Id 'x' -Samples $s
        $ev.Verdict | Should -Be 'asociado a mejor score'
        $ev.Delta   | Should -Be 20
        $ev.Detail  | Should -Match 'no es un experimento controlado'
        $ev.Verdict | Should -Not -Match 'causa'
    }

    It 'detecta tambien lo que va PEOR con el ajuste puesto' {
        $s = @(1..3 | ForEach-Object { New-Sample 55 @('x') }) + @(1..3 | ForEach-Object { New-Sample 75 @() })
        (Get-AXETweakEvidence -Id 'x' -Samples $s).Verdict | Should -Be 'asociado a peor score'
    }

    It 'no confunde un ajuste con otro' {
        $s = @(1..3 | ForEach-Object { New-Sample 90 @('otro') }) + @(1..3 | ForEach-Object { New-Sample 50 @() })
        (Get-AXETweakEvidence -Id 'x' -Samples $s).NOn | Should -Be 0
    }

    It 'una muestra sin score no cuenta ni rompe' {
        $s = @([pscustomobject]@{ at='x'; score=$null; applied=@('x') }) + @(1..3 | ForEach-Object { New-Sample 70 @() })
        { Get-AXETweakEvidence -Id 'x' -Samples $s } | Should -Not -Throw
        (Get-AXETweakEvidence -Id 'x' -Samples $s).NOn | Should -Be 0
    }
}

Describe 'Get-AXEBottleneck - razona sobre combinaciones' -Tag 'unit' {

    It 'cruza RAM en single channel con un panel rapido en UN solo diagnostico' {
        # Esta es la frase que hace que parezca que el programa entiende el equipo: no es la suma
        # de dos avisos, es una conclusion que necesita los dos hechos a la vez.
        $b = Get-AXEBottleneck -Hw ([pscustomobject]@{ RefreshHz=180 }) -DiagFindings @((New-Find 'ramchan' 'BAD')) -Snapshot $null
        @($b).Count | Should -Be 1
        $b[0].Detail | Should -Match '180 Hz'
        $b[0].Detail | Should -Match 'single channel'
    }

    It 'sin panel rapido NO inventa la frase del panel' {
        $b = Get-AXEBottleneck -Hw ([pscustomobject]@{ RefreshHz=60 }) -DiagFindings @((New-Find 'ramchan' 'BAD')) -Snapshot $null
        $b[0].Detail | Should -Not -Match 'Hz'
    }

    It 'la memoria manda sobre el resto de cuellos' {
        $b = Get-AXEBottleneck -Hw $null -DiagFindings @((New-Find 'ssd' 'BAD'),(New-Find 'ramchan' 'BAD'),(New-Find 'xmp' 'BAD')) -Snapshot $null
        $b[0].Id | Should -Be 'ramchan'
    }

    It 'avisa de la bateria: cualquier medida con el portatil desenchufado sale peor' {
        $b = Get-AXEBottleneck -Hw ([pscustomobject]@{ IsLaptop=$true; OnBattery=$true }) -DiagFindings @() -Snapshot $null
        @($b | Where-Object Id -eq 'battery').Count | Should -Be 1
    }

    It 'avisa de maquina virtual: el timer medido no es el del hierro' {
        $b = Get-AXEBottleneck -Hw ([pscustomobject]@{ IsVM=$true }) -DiagFindings @() -Snapshot $null
        @($b | Where-Object Id -eq 'vm').Count | Should -Be 1
    }

    It 'sin nada malo y con el timer fino, lo DICE en vez de inventar una tarea' {
        $snap = [pscustomobject]@{ Timer = [pscustomobject]@{ CurrentMs = 0.5 } }
        $b = Get-AXEBottleneck -Hw $null -DiagFindings @((New-Find 'xmp' 'OK')) -Snapshot $snap
        $b[0].Id | Should -Be 'clean'
    }

    It 'sin nada malo y sin medicion no se inventa un veredicto de limpieza' {
        # Sin snapshot no se sabe si el timer esta fino: callar es la respuesta correcta.
        @(Get-AXEBottleneck -Hw $null -DiagFindings @() -Snapshot $null).Count | Should -Be 0
    }

    It 'los hallazgos OK y UNKNOWN no generan cuellos' {
        @(Get-AXEBottleneck -Hw $null -DiagFindings @((New-Find 'ramchan' 'OK'),(New-Find 'xmp' 'UNKNOWN')) -Snapshot $null).Count | Should -Be 0
    }
}

Describe 'Get-AXEAdvice - el orden es la honestidad' -Tag 'unit' {

    It 'REGRESION: no lanza (el subarray @() sobre List[T] revienta en PS 7.6.4)' {
        # Cazado ejecutandolo: '@($plan)' sobre System.Collections.Generic.List[object] lanza
        # "Argument types do not match" en PowerShell 7.6.4, en un proceso limpio y sin el motor
        # cargado. Todo el proyecto usa .ToArray() por eso; este test lo deja atado.
        { Get-AXEAdvice -Hw $null -DiagFindings @() -Snapshot $null -Tweaks @() -RecommendedIds @('a') -AppliedIds @() -Samples @() } |
            Should -Not -Throw
    }

    It 'el diagnostico va SIEMPRE antes que el catalogo' {
        $plan = Get-AXEAdvice -Hw $null -DiagFindings @((New-Find 'ramchan' 'BAD')) -Snapshot $null `
                    -Tweaks @() -RecommendedIds @('cpu_mmcss') -AppliedIds @() -Samples @()
        $k = KindsOf $plan
        $k.IndexOf('cuello') | Should -BeLessThan $k.IndexOf('catalogo')
    }

    It 'el catalogo va el ULTIMO de los accionables y declara su tamano real' {
        $plan = Get-AXEAdvice -Hw $null -DiagFindings @() -Snapshot $null `
                    -Tweaks @() -RecommendedIds @('cpu_mmcss') -AppliedIds @() -Samples @()
        $cat = @($plan | Where-Object Kind -eq 'catalogo')[0]
        $cat.Impact | Should -Be 'bajo'
        $cat.Detail | Should -Match 'un digito'
        $cat.Detail | Should -Match 'placebo'
    }

    It 'no propone lo que ya esta puesto' {
        $plan = Get-AXEAdvice -Hw $null -DiagFindings @() -Snapshot $null `
                    -Tweaks @() -RecommendedIds @('a','b') -AppliedIds @('a','b') -Samples @()
        @($plan | Where-Object Kind -eq 'catalogo').Count | Should -Be 0
    }

    It 'usa el NOMBRE del ajuste cuando lo tiene, no el id' {
        $tw = @([pscustomobject]@{ Id='cpu_mmcss'; Name='Liberar CPU multimedia'; Tier=0 })
        $plan = Get-AXEAdvice -Hw $null -DiagFindings @() -Snapshot $null `
                    -Tweaks $tw -RecommendedIds @('cpu_mmcss') -AppliedIds @() -Samples @()
        (@($plan | Where-Object Kind -eq 'catalogo')[0]).Detail | Should -Match 'Liberar CPU multimedia'
    }

    It 'sugiere revisar un ajuste puesto que TU maquina asocia a peor score' {
        $s = @(1..3 | ForEach-Object { New-Sample 55 @('x') }) + @(1..3 | ForEach-Object { New-Sample 75 @() })
        $plan = Get-AXEAdvice -Hw $null -DiagFindings @() -Snapshot $null `
                    -Tweaks @() -RecommendedIds @() -AppliedIds @('x') -Samples $s
        @($plan | Where-Object Kind -eq 'revisar').Count | Should -Be 1
    }

    It 'NO sugiere revisar nada sin evidencia suficiente' {
        # Una corazonada con n=1 seria peor que callarse: el usuario revertiria a ciegas.
        $s = @((New-Sample 55 @('x')), (New-Sample 75 @()))
        $plan = Get-AXEAdvice -Hw $null -DiagFindings @() -Snapshot $null `
                    -Tweaks @() -RecommendedIds @() -AppliedIds @('x') -Samples $s
        @($plan | Where-Object Kind -eq 'revisar').Count | Should -Be 0
    }

    It 'lo que no se pudo comprobar se declara en vez de darlo por bueno' {
        $plan = Get-AXEAdvice -Hw $null -DiagFindings @((New-Find 'xmp' 'UNKNOWN' 'XMP / EXPO')) -Snapshot $null `
                    -Tweaks @() -RecommendedIds @() -AppliedIds @() -Samples @()
        $u = @($plan | Where-Object Kind -eq 'sin comprobar')
        $u.Count | Should -Be 1
        $u[0].Detail | Should -Match 'aprobado regalado'
    }

    It 'el campo Order es correlativo y empieza en 1' {
        $plan = Get-AXEAdvice -Hw $null -DiagFindings @((New-Find 'ramchan' 'BAD'),(New-Find 'xmp' 'UNKNOWN')) -Snapshot $null `
                    -Tweaks @() -RecommendedIds @('a') -AppliedIds @() -Samples @()
        @($plan | ForEach-Object { $_.Order }) | Should -Be @(1,2,3)
    }

    It 'sin nada que decir devuelve un plan vacio, no relleno' {
        @(Get-AXEAdvice -Hw $null -DiagFindings @() -Snapshot $null -Tweaks @() -RecommendedIds @() -AppliedIds @() -Samples @()).Count |
            Should -Be 0
    }
}

Describe 'Historico de resultados - persistencia' -Tag 'unit' {

    BeforeAll {
        $script:advOld  = $script:AXEData
        $script:AXEData = Join-Path ([System.IO.Path]::GetTempPath()) ('axe-test-adv-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
    }
    AfterAll {
        if($script:AXEData -and (Test-Path $script:AXEData)){ Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue }
        $script:AXEData = $script:advOld
    }
    BeforeEach {
        $p = Get-AXEOutcomePath
        if($p -and (Test-Path $p)){ Remove-Item $p -Force -EA SilentlyContinue }
    }

    It 'sin fichero devuelve historico vacio y no lanza' {
        { Read-AXEOutcomes } | Should -Not -Throw
        @((Read-AXEOutcomes).samples).Count | Should -Be 0
    }

    It 'ida y vuelta: lo guardado se lee igual' {
        Add-AXEOutcome -Score 72 -AppliedIds @('b','a') -HwHash 'h1' | Should -BeTrue
        $d = Read-AXEOutcomes
        @($d.samples).Count | Should -Be 1
        $d.samples[0].score | Should -Be 72
        # Los ids se guardan ordenados y sin duplicados, para que la huella de dos medidas con los
        # mismos ajustes sea comparable aunque el catalogo cambie de orden.
        @($d.samples[0].applied) | Should -Be @('a','b')
    }

    It 'la fecha va en ISO-8601 UTC invariante, no en formato local' {
        # En es-ES una fecha local seria '26/07/2026 9:14:03' y el fichero dejaria de ser portable.
        Add-AXEOutcome -Score 50 -HwHash 'h1' | Out-Null
        (Read-AXEOutcomes).samples[0].at | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }

    It 'un fichero corrupto no lanza: se sigue sin evidencia local' {
        Set-Content -Path (Get-AXEOutcomePath) -Value '{roto' -Encoding UTF8
        { Read-AXEOutcomes } | Should -Not -Throw
        @((Read-AXEOutcomes).samples).Count | Should -Be 0
    }

    It 'si la maquina cambia se DESCARTA el historico en vez de mezclarlo' {
        # Mezclar el score de dos equipos distintos da una media que no describe a ninguno.
        Add-AXEOutcome -Score 70 -HwHash 'h1'   | Out-Null
        Add-AXEOutcome -Score 40 -HwHash 'OTRA' | Out-Null
        $d = Read-AXEOutcomes
        @($d.samples).Count | Should -Be 1
        $d.samples[0].score | Should -Be 40
    }

    It 'sin carpeta de datos no lanza ni finge que guardo' {
        $old = $script:AXEData
        $script:AXEData = $null
        try {
            Add-AXEOutcome -Score 10 | Should -BeFalse
            @((Read-AXEOutcomes).samples).Count | Should -Be 0
        } finally { $script:AXEData = $old }
    }

    It 'el historico tiene tope y tira las medidas mas viejas' {
        # Un fichero de ayuda no puede convertirse en un problema de disco.
        1..($script:AXEOutcomeMaxRow + 5) | ForEach-Object { Add-AXEOutcome -Score $_ -HwHash 'h1' | Out-Null }
        $d = Read-AXEOutcomes
        @($d.samples).Count  | Should -Be $script:AXEOutcomeMaxRow
        $d.samples[-1].score | Should -Be ($script:AXEOutcomeMaxRow + 5)   # la ultima sigue estando
    }
}

Describe 'Format-AXEAdvice - texto compartido CLI/GUI' -Tag 'unit' {

    It 'un plan vacio manda al diagnostico en vez de quedarse en blanco' {
        (Format-AXEAdvice -Plan @() -Samples @()) -join ' ' | Should -Match 'diagnostico'
    }

    It 'declara que la comparacion es observacional cuando hay historico' {
        $plan = @([pscustomobject]@{ Order=1;Kind='cuello';Id='x';Title='t';Detail='d';Why='w';Impact='alto';Action='a' })
        (Format-AXEAdvice -Plan $plan -Samples @((New-Sample 70 @()))) -join ' ' | Should -Match 'OBSERVACIONAL'
    }

    It 'sin historico lo dice y explica como se construye' {
        $plan = @([pscustomobject]@{ Order=1;Kind='cuello';Id='x';Title='t';Detail='d';Why='w';Impact='alto';Action='a' })
        (Format-AXEAdvice -Plan $plan -Samples @()) -join ' ' | Should -Match 'Sin historico local'
    }

    It 'la salida es ASCII puro: a dist/AXE.ps1 lo lanza powershell.exe 5.1 y destroza el resto' {
        # Cazado en la maquina real: un caracter de punto medio salia como 'A-con-circunflejo'.
        # Era la unica cadena de todo src/ que llegaba a consola con caracteres no-ASCII; este
        # test impide que vuelva a colarse.
        $plan = @([pscustomobject]@{ Order=1;Kind='cuello';Id='x';Title='titulo';Detail='detalle';Why='base';Impact='alto';Action='accion' })
        foreach($line in (Format-AXEAdvice -Plan $plan -Samples @())){
            $line | Should -Not -Match '[^\x00-\x7F]'
        }
    }
}
