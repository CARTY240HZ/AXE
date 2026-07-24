# Pester del benchmark "pruebalo en tu PC" (41-bench.ps1, spec 2026-07-24).
#
# Lo que se cubre aqui es la parte PURA: agregacion (mediana/IQR), veredicto contra el ruido
# medido, round-trip del store y ausencia de PII en el reporte compartible. Todo con series
# sinteticas: ni [AXE.Native], ni admin, ni una maquina concreta -> corre igual en CI.
#
# Lo que NO se cubre, a proposito: que Measure-AXEBenchSample mida BIEN el jitter. Eso es
# 32-measure (busy-loop nativo) y ya tiene su propio terreno; repetirlo aqui seria testear el
# scheduler de Windows. Mismo criterio que Fps.Tests con PresentMon y Session.Tests con el
# freeze de Job Objects.
#
# La propiedad que este fichero existe para proteger: EL VEREDICTO NUNCA DECLARA MEJORA
# DENTRO DEL RUIDO. Si alguien afloja el umbral, aqui se pone rojo.

BeforeAll {
    . "$PSScriptRoot/_load-engine.ps1"

    # Store aislado: los tests no tocan el AXE/bench/ real de nadie.
    $script:BenchTmp = Join-Path ([IO.Path]::GetTempPath()) ('axe_bench_{0}' -f [guid]::NewGuid())
    $script:AXEBenchDir = $script:BenchTmp

    # Fabrica de agregados sinteticos con la MISMA forma que produce Measure-AXEBenchSample
    # (y que sobrevive al round-trip por ConvertTo/FromJson).
    function New-Sample {
        param($P999,$P999Iqr,$Score,$ScoreIqr,$TimerV=$null,$TimerIqr=0.0,$Hash='sha256:synth')
        $mk = { param($m,$q) if($null -eq $m){ $null } else { [pscustomobject]@{ median=$m; iqr=$q; passes=7 } } }
        [pscustomobject]@{
            id='synth'; axeVersion='test'; hwHash=$Hash; ts='2026-07-24T00:00:00.0000000Z'
            passes=7; jitterMs=250
            hw=[pscustomobject]@{ cpu='CPU generica'; ramGB=16.0; gpuVendor='NVIDIA'; build=26200 }
            metrics=[pscustomobject]@{
                jitterP999Ms = (& $mk $P999 $P999Iqr)
                jitterMeanMs = $null                      # simula native ausente para esta metrica
                timerMs      = (& $mk $TimerV $TimerIqr)
                score        = (& $mk $Score $ScoreIqr)
            }
        }
    }
    function VerdictFor($v,$key){ @($v | Where-Object Key -eq $key) | Select-Object -First 1 }
}

AfterAll {
    if($script:BenchTmp -and (Test-Path $script:BenchTmp)){ Remove-Item $script:BenchTmp -Recurse -Force -EA SilentlyContinue }
}

Describe 'Get-AXEBenchStat - mediana e IQR' -Tag 'unit' {
    It 'una serie vacia devuelve null, no un cero' {
        Get-AXEBenchStat @() | Should -BeNullOrEmpty
    }
    It 'una sola muestra da mediana y ruido cero' {
        $s = Get-AXEBenchStat @(0.5)
        $s.median | Should -Be 0.5
        $s.iqr    | Should -Be 0.0
        $s.passes | Should -Be 1
    }
    It 'la mediana ignora un outlier que si arrastraria a la media' {
        # 6 valores en 1.0 + un stall de 100: la media seria ~15, la mediana sigue en 1.
        $s = Get-AXEBenchStat @(1,1,1,1,1,1,100)
        $s.median | Should -Be 1
    }
    It 'el IQR mide la dispersion del 50% central' {
        # 1..9 -> Q1=3, Q3=7 con interpolacion lineal.
        $s = Get-AXEBenchStat @(1,2,3,4,5,6,7,8,9)
        $s.median | Should -Be 5
        $s.iqr    | Should -Be 4
    }
    It 'los nulls no cuentan como muestra' {
        (Get-AXEBenchStat @(1,$null,3)).passes | Should -Be 2
    }
}

Describe 'Get-AXEBenchVerdict - nunca declara mejora dentro del ruido' -Tag 'unit' {

    It 'un delta grande con ruido pequeno es concluyente y sale MEJOR' {
        $v = Get-AXEBenchVerdict (New-Sample 1.00 0.02 50 1) (New-Sample 0.40 0.02 70 1)
        (VerdictFor $v 'jitterP999Ms').Tag        | Should -Be 'mejor'
        (VerdictFor $v 'jitterP999Ms').Conclusive | Should -BeTrue
        (VerdictFor $v 'score').Tag               | Should -Be 'mejor'   # aqui MAS es mejor
    }

    It 'un delta real pero por debajo del ruido combinado sale RUIDO' {
        # jitter baja 0.05 con IQR 0.30 en cada fase: el umbral es 0.60. No es una mejora.
        $v = Get-AXEBenchVerdict (New-Sample 1.00 0.30 50 5) (New-Sample 0.95 0.30 52 5)
        foreach($m in $v){
            $m.Tag        | Should -Be 'ruido'
            $m.Conclusive | Should -BeFalse
        }
    }

    It 'justo por debajo del umbral NO es concluyente y justo por encima si' {
        # Umbral = 1.0 * (0.10 + 0.10) = 0.20 exacto. La frontera es estricta (>), no >=.
        (VerdictFor (Get-AXEBenchVerdict (New-Sample 1.00 0.10 50 0) (New-Sample 0.80 0.10 50 0)) 'jitterP999Ms').Conclusive | Should -BeFalse
        (VerdictFor (Get-AXEBenchVerdict (New-Sample 1.00 0.10 50 0) (New-Sample 0.79 0.10 50 0)) 'jitterP999Ms').Conclusive | Should -BeTrue
    }

    It 'una regresion grande sale PEOR, no se disimula' {
        $v = Get-AXEBenchVerdict (New-Sample 0.40 0.02 70 1) (New-Sample 1.00 0.02 50 1)
        (VerdictFor $v 'jitterP999Ms').Tag | Should -Be 'peor'
        (VerdictFor $v 'score').Tag        | Should -Be 'peor'
    }

    It 'dos medidas identicas jamas salen concluyentes' {
        $s = New-Sample 0.42 0.05 61 2
        foreach($m in (Get-AXEBenchVerdict $s $s)){ $m.Conclusive | Should -BeFalse }
    }

    It 'una metrica no medible se OMITE en vez de compararse contra un cero fabricado' {
        $v = Get-AXEBenchVerdict (New-Sample 1.00 0.02 50 1) (New-Sample 0.40 0.02 70 1)
        @($v | Where-Object Key -eq 'jitterMeanMs') | Should -BeNullOrEmpty   # null en ambas fases
        @($v | Where-Object Key -eq 'timerMs')      | Should -BeNullOrEmpty
    }

    It 'una metrica medida solo en una de las dos fases tambien se omite' {
        $v = Get-AXEBenchVerdict (New-Sample 1.0 0.02 50 1 -TimerV 0.5 -TimerIqr 0.01) (New-Sample 0.4 0.02 70 1)
        @($v | Where-Object Key -eq 'timerMs') | Should -BeNullOrEmpty
    }

    It 'subir K endurece el criterio (la misma medida deja de ser concluyente)' {
        $b = New-Sample 1.00 0.10 50 0; $a = New-Sample 0.70 0.10 50 0
        (VerdictFor (Get-AXEBenchVerdict $b $a -K 1.0) 'jitterP999Ms').Conclusive | Should -BeTrue
        (VerdictFor (Get-AXEBenchVerdict $b $a -K 2.0) 'jitterP999Ms').Conclusive | Should -BeFalse
    }

    It 'un IQR de cero NO convierte cualquier delta en mejora (suelo de resolucion)' {
        # Regresion de la primera ejecucion real (2026-07-24): con 3 pasadas el 'Jitter medio'
        # dio IQR 0.0000 en las dos fases y un delta de -0.0001ms salio como MEJOR. El ruido no
        # habia desaparecido: no lo estabamos resolviendo. Un cambio mas pequeno que el ultimo
        # decimal que el reporte imprime no puede llamarse mejora.
        $v = Get-AXEBenchVerdict (New-Sample 0.0001 0.0 50 0) (New-Sample 0.0000 0.0 50 0)
        (VerdictFor $v 'jitterP999Ms').Tag | Should -Be 'ruido'
        # Y con ruido cero, un cambio MUY por encima de esa resolucion si es concluyente.
        $v2 = Get-AXEBenchVerdict (New-Sample 1.000 0.0 50 0) (New-Sample 0.500 0.0 50 0)
        (VerdictFor $v2 'jitterP999Ms').Tag | Should -Be 'mejor'
    }

    It 'sin datos no revienta: devuelve una lista vacia' {
        @(Get-AXEBenchVerdict $null $null).Count | Should -Be 0
    }
}

Describe 'Format-AXEBenchTs - la fecha del reporte no depende del pais' -Tag 'unit' {
    It 'normaliza a ISO-8601 UTC venga [datetime] o cadena' {
        # Regresion: ConvertFrom-Json devuelve la marca del disco como [datetime], asi que el
        # 'antes' y el 'despues' salian con formatos distintos en el MISMO reporte.
        Format-AXEBenchTs ([datetime]::new(2026,7,24,13,36,23,[DateTimeKind]::Utc)) | Should -Be '2026-07-24T13:36:23Z'
        Format-AXEBenchTs '2026-07-24T13:36:23.0054975Z'                            | Should -Be '2026-07-24T13:36:23Z'
    }
    It 'no depende de la cultura del sistema' {
        $old = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('es-ES')
            Format-AXEBenchTs ([datetime]::new(2026,7,24,13,36,23,[DateTimeKind]::Utc)) | Should -Be '2026-07-24T13:36:23Z'
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
    It 'lo que no es fecha se devuelve tal cual en vez de reventar' {
        Format-AXEBenchTs 'no-soy-una-fecha' | Should -Be 'no-soy-una-fecha'
        Format-AXEBenchTs $null              | Should -Be 'n/a'
    }
}

Describe 'Save/Read-AXEBenchBaseline - store en disco' -Tag 'unit' {

    It 'guarda y recupera el mismo agregado' {
        $id = Save-AXEBenchBaseline (New-Sample 0.42 0.05 61 2)
        $id | Should -Not -BeNullOrEmpty
        $back = Read-AXEBenchBaseline $id
        [double]$back.metrics.jitterP999Ms.median | Should -Be 0.42
        [double]$back.metrics.jitterP999Ms.iqr    | Should -Be 0.05
        [double]$back.metrics.score.median        | Should -Be 61
        $back.id | Should -Be $id
    }

    It 'el reporte da UN solo formato de fecha aunque el antes venga del disco' {
        # El 'antes' pasa por ConvertFrom-Json (ts -> [datetime]) y el 'despues' no. Las dos
        # lineas del reporte tienen que salir iguales, no una en formato local y otra en ISO.
        $id = Save-AXEBenchBaseline (New-Sample 1.00 0.02 50 1)
        $rep = New-AXEBenchReport (Read-AXEBenchBaseline $id) (New-Sample 0.40 0.02 70 1) $null
        $txt = $rep.Text -join "`n"
        [regex]::Matches($txt,'(?m)^(Antes|Despues)\s+:\s+(\S+)') | ForEach-Object {
            $_.Groups[2].Value | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
        }
    }

    It 'el agregado recuperado del JSON sirve tal cual para el veredicto' {
        # El round-trip JSON convierte los pscustomobject en otros pscustomobject: si el
        # veredicto dependiera del tipo exacto, esto lo cazaria.
        $id = Save-AXEBenchBaseline (New-Sample 1.00 0.02 50 1)
        $v = Get-AXEBenchVerdict (Read-AXEBenchBaseline $id) (New-Sample 0.40 0.02 70 1)
        (VerdictFor $v 'jitterP999Ms').Tag | Should -Be 'mejor'
    }

    It 'dos baselines seguidas no se pisan (ids distintos)' {
        $a = Save-AXEBenchBaseline (New-Sample 1.0 0.1 50 1)
        $b = Save-AXEBenchBaseline (New-Sample 2.0 0.1 50 1)
        $a | Should -Not -Be $b
        [double](Read-AXEBenchBaseline $a).metrics.jitterP999Ms.median | Should -Be 1.0
    }

    It 'un id inexistente devuelve null (no se inventa un antes)' {
        Read-AXEBenchBaseline 'jamas-existio' | Should -BeNullOrEmpty
    }

    It 'un id con separadores de ruta se rechaza (no lee fuera del store)' {
        Read-AXEBenchBaseline '..\..\Windows\win' | Should -BeNullOrEmpty
        Read-AXEBenchBaseline 'C:\Windows\win'    | Should -BeNullOrEmpty
        Read-AXEBenchBaseline ''                  | Should -BeNullOrEmpty
    }

    It 'un fichero corrupto devuelve null en vez de lanzar' {
        $f = Join-Path $script:AXEBenchDir 'corrupto.json'
        Set-Content $f -Value '{esto no es json' -Encoding UTF8
        Read-AXEBenchBaseline 'corrupto' | Should -BeNullOrEmpty
    }
}

Describe 'Test-AXEBenchComparable - se niega a comparar peras con manzanas' -Tag 'unit' {

    BeforeAll {
        $script:ident = [pscustomobject]@{ axeVersion='test'; hwHash='sha256:synth'
            hw=[pscustomobject]@{ cpu='CPU generica'; ramGB=16.0; gpuVendor='NVIDIA'; build=26200 } }
    }

    It 'el mismo hash es comparable' {
        Test-AXEBenchComparable (New-Sample 1 0.1 50 1) $script:ident | Should -BeNullOrEmpty
    }
    It 'un hash distinto NO es comparable y explica por que' {
        $why = Test-AXEBenchComparable (New-Sample 1 0.1 50 1 -Hash 'sha256:OTRA') $script:ident
        $why | Should -Match 'no comparable'
    }
    It 'una linea base sin hash (formato antiguo) se rechaza' {
        $old = New-Sample 1 0.1 50 1; $old.hwHash = $null
        Test-AXEBenchComparable $old $script:ident | Should -Match 'hash'
    }
}

Describe 'Get-AXEBenchHwHash - identidad estable y sin PII' -Tag 'unit' {
    It 'el mismo hardware da el mismo hash' {
        $a = Get-AXEBenchHwHash -Cpu 'Ryzen 7 5800X' -RamGB 31.9 -GpuVendor 'NVIDIA' -Build 26200 -Version '7.0.0'
        $b = Get-AXEBenchHwHash -Cpu 'Ryzen 7 5800X' -RamGB 31.9 -GpuVendor 'NVIDIA' -Build 26200 -Version '7.0.0'
        $a | Should -Be $b
        $a | Should -Match '^sha256:[0-9a-f]{64}$'
    }
    It 'cambiar la version de AXE cambia el hash (dos builds no son comparables)' {
        (Get-AXEBenchHwHash -Cpu 'x' -RamGB 16 -GpuVendor 'y' -Build 1 -Version '7.0.0') |
            Should -Not -Be (Get-AXEBenchHwHash -Cpu 'x' -RamGB 16 -GpuVendor 'y' -Build 1 -Version '7.1.0')
    }
    It 'cambiar el build de Windows cambia el hash' {
        (Get-AXEBenchHwHash -Cpu 'x' -RamGB 16 -GpuVendor 'y' -Build 22631 -Version '7.0.0') |
            Should -Not -Be (Get-AXEBenchHwHash -Cpu 'x' -RamGB 16 -GpuVendor 'y' -Build 26200 -Version '7.0.0')
    }
}

Describe 'Format-AXEBenchNum - cultura invariante' -Tag 'unit' {
    It 'usa punto decimal aunque la maquina sea es-ES' {
        # Sin esto el .md compartido diria '0,420' aqui y '0.420' en otro equipo: el mismo dato
        # dejaria de ser comparable y de parsearse igual.
        $old = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [cultureinfo]::GetCultureInfo('es-ES')
            Format-AXEBenchNum 0.42 3 | Should -Be '0.420'
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $old }
    }
    It 'lo no medido sale n/a, nunca 0' {
        Format-AXEBenchNum $null 3 | Should -Be 'n/a'
    }
}

Describe 'New-AXEBenchReport - tres caras del mismo dato, sin PII' -Tag 'unit' {

    BeforeAll {
        $b = New-Sample 1.00 0.02 50 1
        $b.id = '20260724-1200'
        $script:repBefore = $b
        $script:rep     = New-AXEBenchReport $b (New-Sample 0.40 0.02 70 1) $null
        $script:allText = (@($script:rep.Text) -join "`n") + "`n" + $script:rep.Markdown + "`n" + $script:rep.Json
    }

    It 'el texto de CLI no viene vacio y trae la tabla' {
        @($script:rep.Text).Count | Should -BeGreaterThan 5
        ($script:rep.Text -join "`n") | Should -Match 'Jitter P99\.9'
    }
    It 'el JSON parsea y trae el veredicto' {
        $o = $script:rep.Json | ConvertFrom-Json
        @($o.verdict).Count | Should -BeGreaterThan 0
        ($o.verdict | Where-Object key -eq 'jitterP999Ms').tag | Should -Be 'mejor'
    }
    It 'el Markdown trae una tabla con el veredicto' {
        $script:rep.Markdown | Should -Match '\| Metrica \|'
        $script:rep.Markdown | Should -Match 'mejor'
    }
    It 'las tres caras cuentan lo mismo (mismo veredicto en texto, md y json)' {
        $tag = (($script:rep.Json | ConvertFrom-Json).verdict | Where-Object key -eq 'jitterP999Ms').tag
        # -cmatch: la tabla de texto pinta el tag en MAYUSCULAS y el md en minusculas. Con el
        # -Match case-insensitive de Pester las dos asserts pasarian sin comprobar nada.
        (($script:rep.Text -join "`n") -cmatch $tag.ToUpperInvariant()) | Should -BeTrue
        ($script:rep.Markdown -cmatch $tag)                             | Should -BeTrue
    }
    It 'dice explicitamente que el jitter es un proxy y que DPC no se mide' {
        $script:allText | Should -Match 'proxy'
        $script:allText | Should -Match 'DPC'
    }
    It 'remite a -FpsCompare para los FPS en vez de fabricarlos' {
        $script:allText | Should -Match 'FpsCompare'
    }
    It 'NO contiene datos personales del equipo' {
        foreach($pii in @($env:USERNAME,$env:COMPUTERNAME,$env:USERDOMAIN,$env:USERPROFILE)){
            if($pii){ $script:allText | Should -Not -Match ([regex]::Escape($pii)) }
        }
        $script:allText | Should -Not -Match '(?i)serial'
        $script:allText | Should -Not -Match '(?i)\bmac\b'
    }
    It 'cuando nada supera el ruido, el resumen lo dice y no vende una mejora' {
        $s = New-Sample 1.00 0.50 50 5; $s.id = '20260724-1300'
        $r = New-AXEBenchReport $s (New-Sample 0.95 0.50 52 5) $null
        ($r.Text -join "`n") | Should -Match 'NO es demostrable'
        # -cmatch a mano: 'Should -Not -Match' es case-insensitive y daria falso positivo con
        # el "0 mejor(es)" del resumen. Lo que se quiere comprobar es que NINGUNA fila de la
        # tabla lleve la etiqueta MEJOR (en mayusculas, como la pinta el reporte).
        (($r.Text -join "`n") -cmatch 'MEJOR') | Should -BeFalse
    }
    It 'sin ninguna metrica comparable lo dice en vez de fabricar una tabla vacia' {
        $vacio = New-Sample $null 0 $null 0
        $r = New-AXEBenchReport $vacio $vacio @()
        ($r.Text -join "`n") | Should -Match 'no hay nada que comparar'
    }
}

Describe 'Export-AXEBenchReport - escribe json y md' -Tag 'unit' {
    It 'un solo -Report produce las dos caras compartibles' {
        $b = New-Sample 1.00 0.02 50 1; $b.id = '20260724-1400'
        $rep = New-AXEBenchReport $b (New-Sample 0.40 0.02 70 1) $null
        $target = Join-Path $script:AXEBenchDir 'informe.json'
        $files = Export-AXEBenchReport $rep $target
        @($files).Count | Should -Be 2
        foreach($f in $files){ Test-Path $f | Should -BeTrue }
        (Get-Content ($files[0]) -Raw | ConvertFrom-Json).verdict | Should -Not -BeNullOrEmpty
        (Get-Content ($files[1]) -Raw) | Should -Match '\| Metrica \|'
    }
}

Describe 'Puente: bench.* en la lista blanca' -Tag 'unit' {
    It 'bench.baseline y bench.after estan en el mapa del puente' {
        $script:AXEBridgeMap.Keys | Should -Contain 'bench.baseline'
        $script:AXEBridgeMap.Keys | Should -Contain 'bench.after'
    }
    It 'bench.after sin id se niega en vez de inventar un antes' {
        $r = Invoke-AXEBridgeCmd 'bench.after' @{}
        $r.ok  | Should -BeFalse
        $r.err | Should -Match 'id'
    }
    It 'bench.after con un id inexistente se niega con motivo' {
        $r = Invoke-AXEBridgeCmd 'bench.after' @{ id = 'jamas-existio' }
        $r.ok  | Should -BeFalse
        $r.err | Should -Match 'linea base'
    }
}
