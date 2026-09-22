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

Describe 'Invoke-AXEBrokerCommand - motor de decision (sin pipe, con tweak sintetico HKCU)' -Tag 'unit' {
    BeforeAll {
        $script:CAT = New-Object System.Collections.ArrayList
        . "$PSScriptRoot/../src/10-reg-helpers.ps1"
        . "$PSScriptRoot/../src/20-tweaks.ps1"
        . "$PSScriptRoot/../src/28-revert-export.ps1"
        . "$PSScriptRoot/../src/34-safety.ps1"

        $script:OldAXEData = $script:AXEData
        $script:OldStateBak = $script:StateBak
        $script:AXEData = Join-Path ([IO.Path]::GetTempPath()) ('axe-test-broker-cmd-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
        $script:StateBak = Join-Path $script:AXEData 'tweak_state.json'

        $script:DummyKey = 'HKCU:\Software\AXE\_TestBrokerCmdDummy'
        Remove-Item $script:DummyKey -Recurse -Force -EA SilentlyContinue
        $script:DummyTweak = [pscustomobject]@{
            Id='_test_broker_cmd_dummy'; Cat='TEST'; Tier=0; Reboot=$false
            Name='(test) dummy'; Desc='(test) dummy'; Requires=@{}; Source='n/a'; SourceType='official'; PlaceboLikely=$false
            Test   = { (Get-RV 'HKCU:\Software\AXE\_TestBrokerCmdDummy' 'V') -eq 1 }
            Apply  = { Set-RD 'HKCU:\Software\AXE\_TestBrokerCmdDummy' 'V' 1 }
            Revert = { Set-RD 'HKCU:\Software\AXE\_TestBrokerCmdDummy' 'V' 0 }
        }
        [void]$script:CAT.Add($script:DummyTweak)
    }
    AfterAll {
        $script:CAT.Remove($script:DummyTweak)
        Remove-Item $script:DummyKey -Recurse -Force -EA SilentlyContinue
        Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue
        $script:AXEData = $script:OldAXEData; $script:StateBak = $script:OldStateBak
    }

    It 'tweaks.apply aplica y persiste el snapshot (mismo protocolo ya arreglado en el bridge)' {
        $r = Invoke-AXEBrokerCommand 'tweaks.apply' @{ id = $script:DummyTweak.Id }
        $r.ok | Should -BeTrue
        (Get-RV $script:DummyKey 'V') | Should -Be 1
        (Read-StateBak).ContainsKey($script:DummyTweak.Id) | Should -BeTrue
    }
    It 'tweaks.revert restaura el valor real (snapshot), no el fallback' {
        $r = Invoke-AXEBrokerCommand 'tweaks.revert' @{ id = $script:DummyTweak.Id }
        $r.ok | Should -BeTrue
        (Get-RV $script:DummyKey 'V') | Should -BeNullOrEmpty
    }
    It 'tweaks.apply con id inexistente devuelve ok=false, no lanza' {
        $r = Invoke-AXEBrokerCommand 'tweaks.apply' @{ id = '__no_existe__' }
        $r.ok | Should -BeFalse
        $r.err | Should -Not -BeNullOrEmpty
    }
    It 'un comando fuera de la whitelist devuelve ok=false' {
        (Invoke-AXEBrokerCommand 'os.format' @{}).ok | Should -BeFalse
    }
}

Describe 'Start-AXEBroker - servidor real sobre un pipe (mismo proceso: cliente y servidor)' -Tag 'integration' {
    # -Tag integration: aunque el pipe en si no exige admin (ACL al propio SID), lanza runspaces
    # de fondo reales y toca el sistema de ficheros de %LOCALAPPDATA%; se corre con
    # AXE_INTEGRATION=1 (mismo criterio que el resto del repo), nunca en el gate rapido local.
    BeforeAll {
        . "$PSScriptRoot/../src/05-core.ps1"
        $script:CAT = New-Object System.Collections.ArrayList
        . "$PSScriptRoot/../src/10-reg-helpers.ps1"
        . "$PSScriptRoot/../src/20-tweaks.ps1"
        . "$PSScriptRoot/../src/28-revert-export.ps1"
        . "$PSScriptRoot/../src/34-safety.ps1"

        function New-TestPipeName { "AXE-Test-Broker-$([guid]::NewGuid().ToString('N'))" }

        function Invoke-TestBroker([string]$PipeName, [string]$TokenPath){
            # Corre Start-AXEBroker en un runspace de fondo para no bloquear el hilo del test
            # mientras espera la conexion del cliente.
            # NOTA (desvio deliberado respecto al brief, ver task-5-report.md): AddScript((Get-Content
            # -Raw)) ejecuta el contenido SIN archivo de respaldo, asi que $MyInvocation.MyCommand.Path
            # queda $null dentro del runspace -- 05-core.ps1 depende de esa ruta para fijar $script:AXELog,
            # y con ella rota Write-AXELog lanza (Add-Content -Path $null) la PRIMERA vez que el broker
            # intenta loguear, lo que aborta Start-AXEBroker antes de escribir ninguna respuesta al pipe
            # (el cliente ve EOF limpio, no un frame). Dot-sourcing el fichero REAL (en vez de su texto
            # crudo) resuelve $MyInvocation.MyCommand.Path igual que en produccion (AXE.bat siempre lanza
            # el broker desde un .ps1 real, nunca desde un string en memoria), sin tocar ninguna asercion.
            #
            # Ademas (mismo motivo -- runspace nuevo, SIN las funciones que ya cargo el BeforeAll en el
            # runspace del PROCESO de test): Start-AXEBroker llama a Test-Admin (src/28-revert-export.ps1,
            # listado como dependencia en el brief). Sin cargarla aqui tambien, Test-Admin no existe DENTRO
            # del runspace de fondo y el guard de elevacion revienta con CommandNotFoundException, cayendo
            # al catch generico ('fallo interno') en vez de al mensaje especifico de "no elevado" que este
            # Describe pretende comprobar.
            $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
            $ps = [powershell]::Create(); $ps.Runspace = $rs
            foreach($f in '46-broker.ps1','05-core.ps1','28-revert-export.ps1'){ [void]$ps.AddScript(". '$PSScriptRoot/../src/$f'") }
            [void]$ps.AddScript('param($p,$t) Start-AXEBroker $p $t')
            [void]$ps.AddArgument($PipeName); [void]$ps.AddArgument($TokenPath)
            @{ RS=$rs; PS=$ps; Handle=$ps.BeginInvoke() }
        }

        function Send-TestRequest([string]$PipeName, [hashtable]$Body){
            $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
            try {
                $client.Connect(5000)
                Write-AXEBrokerFrame $client ($Body | ConvertTo-Json -Compress -Depth 6)
                Read-AXEBrokerFrame $client
            } finally { $client.Dispose() }
        }
    }

    It 'una peticion valida (comando desconocido, sin necesitar admin real) recibe una respuesta framed' {
        $pipe = New-TestPipeName
        $tokenPath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.token')
        Set-Content -LiteralPath $tokenPath -Value 'tok123' -NoNewline
        $bg = Invoke-TestBroker $pipe $tokenPath
        Start-Sleep -Milliseconds 300   # dar tiempo a que el runspace cree el pipe
        $resp = Send-TestRequest $pipe @{ cmd='os.format'; args=@{}; token='tok123'; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        while(-not $bg.Handle.IsCompleted){ Start-Sleep -Milliseconds 50 }
        try { $bg.PS.EndInvoke($bg.Handle) } catch {}
        $bg.RS.Close()
        ($resp | ConvertFrom-Json).ok | Should -BeFalse   # 'os.format' no esta en la whitelist
    }

    It 'sin token correcto, el broker cierra sin ejecutar nada' {
        $pipe = New-TestPipeName
        $tokenPath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.token')
        Set-Content -LiteralPath $tokenPath -Value 'tok-real' -NoNewline
        $bg = Invoke-TestBroker $pipe $tokenPath
        Start-Sleep -Milliseconds 300
        $resp = Send-TestRequest $pipe @{ cmd='safety.restorePoint'; args=@{}; token='tok-FALSO'; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        while(-not $bg.Handle.IsCompleted){ Start-Sleep -Milliseconds 50 }
        try { $bg.PS.EndInvoke($bg.Handle) } catch {}
        $bg.RS.Close()
        ($resp | ConvertFrom-Json).ok | Should -BeFalse
    }

    It 'el fichero de token se borra en cuanto el broker lo lee (un solo uso)' {
        $pipe = New-TestPipeName
        $tokenPath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.token')
        Set-Content -LiteralPath $tokenPath -Value 'tok456' -NoNewline
        $bg = Invoke-TestBroker $pipe $tokenPath
        Start-Sleep -Milliseconds 300
        Test-Path $tokenPath | Should -BeFalse
        [void](Send-TestRequest $pipe @{ cmd='os.format'; args=@{}; token='tok456'; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() })
        while(-not $bg.Handle.IsCompleted){ Start-Sleep -Milliseconds 50 }
        try { $bg.PS.EndInvoke($bg.Handle) } catch {}
        $bg.RS.Close()
    }

    It 'sin elevacion (Test-Admin=false en este proceso de test), rechaza cualquier comando valido con un error claro' {
        # Este test NO necesita UAC: corre en el proceso normal (no admin) del runner de tests,
        # que es EXACTAMENTE el escenario que este guard cubre -- si el broker se lanzara alguna
        # vez sin elevar (bug de arranque), debe fallar limpio, no a medias dentro de sc.exe/reg.
        $pipe = New-TestPipeName
        $tokenPath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.token')
        Set-Content -LiteralPath $tokenPath -Value 'tok789' -NoNewline
        $bg = Invoke-TestBroker $pipe $tokenPath
        Start-Sleep -Milliseconds 300
        $resp = Send-TestRequest $pipe @{ cmd='safety.restorePoint'; args=@{}; token='tok789'; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
        while(-not $bg.Handle.IsCompleted){ Start-Sleep -Milliseconds 50 }
        try { $bg.PS.EndInvoke($bg.Handle) } catch {}
        $bg.RS.Close()
        $r = $resp | ConvertFrom-Json
        $r.ok | Should -BeFalse
        $r.err | Should -Match 'elevad'
    }
}
