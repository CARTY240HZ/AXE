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
