# Unit - protocolo del broker (issue #5, auditoria 2026-09-22 s1.2). PURO primero: framing,
# tamano/profundidad, whitelist de comando, frescura de timestamp -- sin pipe real, sin admin.
BeforeAll {
    . "$PSScriptRoot/../src/46-broker.ps1"
}

Describe 'Test-AXEBrokerCommand - whitelist cerrada del broker' -Tag 'unit' {
    It '<_> esta permitido' -ForEach 'tweaks.apply','tweaks.revert','tweaks.masterRevert','safety.restorePoint' {
        Test-AXEBrokerCommand $_ | Should -BeTrue
    }
    It 'un comando desconocido se rechaza' {
        Test-AXEBrokerCommand 'os.format' | Should -BeFalse
    }
    It 'es case-sensitive (TWEAKS.APPLY no coincide con tweaks.apply)' {
        Test-AXEBrokerCommand 'TWEAKS.APPLY' | Should -BeFalse
    }
}

Describe 'Test-AXEBrokerJsonDepth - tope de anidamiento' -Tag 'unit' {
    It 'un objeto plano pasa' {
        Test-AXEBrokerJsonDepth '{"a":1,"b":"x"}' 8 | Should -BeTrue
    }
    It 'anidamiento dentro del tope pasa' {
        $j = '{"a":{"b":{"c":{"d":1}}}}'   # profundidad 4
        Test-AXEBrokerJsonDepth $j 8 | Should -BeTrue
    }
    It 'anidamiento que excede el tope se rechaza' {
        $j = '{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":{"i":1}}}}}}}}}'   # profundidad 9
        Test-AXEBrokerJsonDepth $j 8 | Should -BeFalse
    }
    It 'llaves/corchetes DENTRO de una cadena no cuentan como anidamiento' {
        $j = '{"a":"{{{{{{{{{{"}'   # profundidad real 1, el resto es texto
        Test-AXEBrokerJsonDepth $j 8 | Should -BeTrue
    }
    It 'una comilla escapada dentro de la cadena no rompe el escaneo' {
        $j = '{"a":"foo \" bar","b":{"c":1}}'
        Test-AXEBrokerJsonDepth $j 8 | Should -BeTrue
    }
}

Describe 'Test-AXEBrokerTimestamp - ventana de frescura' -Tag 'unit' {
    It 'un timestamp de ahora mismo pasa' {
        $now = Get-Date
        $ts = [DateTimeOffset]::new($now.ToUniversalTime()).ToUnixTimeMilliseconds()
        Test-AXEBrokerTimestamp $ts $now | Should -BeTrue
    }
    It 'un timestamp de hace 10 minutos se rechaza' {
        $now = Get-Date
        $old = $now.AddMinutes(-10)
        $ts = [DateTimeOffset]::new($old.ToUniversalTime()).ToUnixTimeMilliseconds()
        Test-AXEBrokerTimestamp $ts $now | Should -BeFalse
    }
    It 'un timestamp en el futuro (reloj adelantado) tambien se rechaza' {
        $now = Get-Date
        $future = $now.AddMinutes(10)
        $ts = [DateTimeOffset]::new($future.ToUniversalTime()).ToUnixTimeMilliseconds()
        Test-AXEBrokerTimestamp $ts $now | Should -BeFalse
    }
    It 'cero o negativo se rechaza sin reventar' {
        Test-AXEBrokerTimestamp 0 (Get-Date) | Should -BeFalse
        Test-AXEBrokerTimestamp -5 (Get-Date) | Should -BeFalse
    }
}

Describe 'Write/Read-AXEBrokerFrame - framing sobre un stream' -Tag 'unit' {
    It 'round-trip: lo que se escribe se lee igual' {
        $ms = New-Object System.IO.MemoryStream
        Write-AXEBrokerFrame $ms '{"a":1}'
        $ms.Position = 0
        Read-AXEBrokerFrame $ms | Should -Be '{"a":1}'
    }
    It 'un stream vacio (EOF limpio) devuelve $null, no lanza' {
        $ms = New-Object System.IO.MemoryStream
        Read-AXEBrokerFrame $ms | Should -BeNullOrEmpty
    }
    It 'escribir un cuerpo mayor que el tope lanza' {
        $ms = New-Object System.IO.MemoryStream
        $huge = 'x' * ($script:AXEBrokerMaxBytes + 1)
        { Write-AXEBrokerFrame $ms $huge } | Should -Throw
    }
    It 'una longitud declarada mayor que el tope lanza al leer, sin bufferizar el cuerpo' {
        $ms = New-Object System.IO.MemoryStream
        $lenBytes = [BitConverter]::GetBytes([int]($script:AXEBrokerMaxBytes + 1))
        $ms.Write($lenBytes, 0, 4)
        $ms.Position = 0
        { Read-AXEBrokerFrame $ms } | Should -Throw
    }
}

Describe 'Read-AXEBrokerRequest - validacion completa (REGRESION superficie issue #5 criterio 4)' -Tag 'unit' {
    BeforeAll {
        $script:Tok = 'secreto-de-prueba'
        function ReqJson($over = @{}){
            $base = @{ cmd='tweaks.apply'; args=@{id='cpu_mmcss'}; token=$script:Tok; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
            foreach($k in $over.Keys){ $base[$k] = $over[$k] }
            $base | ConvertTo-Json -Compress
        }
    }
    It 'una peticion valida se acepta' {
        $r = Read-AXEBrokerRequest (ReqJson) $script:Tok
        $r.Ok | Should -BeTrue
        $r.Cmd | Should -Be 'tweaks.apply'
        $r.Args['id'] | Should -Be 'cpu_mmcss'
    }
    It 'token incorrecto se rechaza' {
        (Read-AXEBrokerRequest (ReqJson) 'otro-token').Ok | Should -BeFalse
    }
    It 'comando fuera de la whitelist se rechaza' {
        (Read-AXEBrokerRequest (ReqJson @{cmd='os.format'}) $script:Tok).Ok | Should -BeFalse
    }
    It 'timestamp obsoleto se rechaza' {
        $old = [DateTimeOffset]::UtcNow.AddMinutes(-10).ToUnixTimeMilliseconds()
        (Read-AXEBrokerRequest (ReqJson @{ts=$old}) $script:Tok).Ok | Should -BeFalse
    }
    It 'JSON malformado se rechaza sin lanzar' {
        { Read-AXEBrokerRequest '{esto no es json' $script:Tok } | Should -Not -Throw
        (Read-AXEBrokerRequest '{esto no es json' $script:Tok).Ok | Should -BeFalse
    }
    It 'falta un campo obligatorio ("token") se rechaza' {
        $j = (@{ cmd='tweaks.apply'; args=@{}; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress)
        (Read-AXEBrokerRequest $j $script:Tok).Ok | Should -BeFalse
    }
    It 'profundidad excesiva en args se rechaza' {
        $deep = @{ cmd='tweaks.apply'; token=$script:Tok; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                   args=@{a=@{b=@{c=@{d=@{e=@{f=@{g=@{h=@{i=1}}}}}}}}} }
        (Read-AXEBrokerRequest ($deep | ConvertTo-Json -Compress -Depth 20) $script:Tok).Ok | Should -BeFalse
    }
    It 'ts como string no-numerico se rechaza sin lanzar' {
        { Read-AXEBrokerRequest (ReqJson @{ts='not-a-number'}) $script:Tok } | Should -Not -Throw
        (Read-AXEBrokerRequest (ReqJson @{ts='not-a-number'}) $script:Tok).Ok | Should -BeFalse
    }
    It 'ts como array se rechaza sin lanzar' {
        $j = (@{ cmd='tweaks.apply'; args=@{}; token=$script:Tok; ts=@(1,2,3) } | ConvertTo-Json -Compress)
        { Read-AXEBrokerRequest $j $script:Tok } | Should -Not -Throw
        (Read-AXEBrokerRequest $j $script:Tok).Ok | Should -BeFalse
    }
    It 'JSON null (top-level) se rechaza sin lanzar' {
        { Read-AXEBrokerRequest 'null' $script:Tok } | Should -Not -Throw
        (Read-AXEBrokerRequest 'null' $script:Tok).Ok | Should -BeFalse
    }
}
