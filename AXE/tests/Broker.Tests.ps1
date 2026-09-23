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
        #
        # Si el propio shell que corre los tests YA esta elevado (maquina de desarrollo, CI o
        # sandbox elevados), Test-Admin() devuelve $true de verdad dentro del runspace de fondo y
        # el guard de "no elevado" nunca se dispara -- no hay forma de observar ese branch sin
        # mockear Test-Admin, lo que iria en contra del proposito del test (probar la funcion
        # REAL, no una copia). Se salta en vez de fallar en falso o mentir sobre lo que probo
        # (mismo idioma que tests/Fps.Tests.ps1:141 y tests/Catalog.Tests.ps1:87).
        if(Test-Admin){ Set-ItResult -Skipped -Because 'este proceso ya esta elevado, no se puede probar el guard de "no elevado" aqui'; return }
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

Describe 'New-AXEBrokerToken - secreto de un solo uso con ACL restringida' -Tag 'unit' {
    BeforeAll { $script:TmpTokDir = Join-Path ([IO.Path]::GetTempPath()) ('axe-test-tok-' + [guid]::NewGuid().ToString('N')) }
    AfterAll { Remove-Item $script:TmpTokDir -Recurse -Force -EA SilentlyContinue }

    It 'crea el fichero con un token no vacio' {
        $t = New-AXEBrokerToken $script:TmpTokDir
        Test-Path $t.Path | Should -BeTrue
        $t.Token | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $t.Path -Raw).Trim() | Should -Be $t.Token
    }
    It 'la ACL rompe la herencia (reglas explicitas, no heredadas del directorio)' {
        $t = New-AXEBrokerToken $script:TmpTokDir
        (Get-Acl $t.Path).AreAccessRulesProtected | Should -BeTrue
    }
    It 'dos llamadas dan tokens y ficheros distintos' {
        $a = New-AXEBrokerToken $script:TmpTokDir
        $b = New-AXEBrokerToken $script:TmpTokDir
        $a.Path | Should -Not -Be $b.Path
        $a.Token | Should -Not -Be $b.Token
    }
}

Describe 'Send-AXEBrokerRequest - cliente contra un servidor de pruebas minimo' -Tag 'unit' {
    # Servidor de pruebas: NO es Start-AXEBroker (eso ya se cubrio en Task 5 con -Tag
    # integration). Aqui solo se comprueba que el CLIENTE manda el frame correcto y sabe leer
    # la respuesta -- un servidor que simplemente eco-responde basta.
    BeforeAll {
        function Start-TestEchoServer([string]$PipeName, [hashtable]$Reply){
            $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
            $ps = [powershell]::Create(); $ps.Runspace = $rs
            [void]$ps.AddScript((Get-Content "$PSScriptRoot/../src/46-broker.ps1" -Raw))
            [void]$ps.AddScript({
                param($PipeName, $ReplyJson)
                $server = New-Object System.IO.Pipes.NamedPipeServerStream($PipeName, [System.IO.Pipes.PipeDirection]::InOut)
                $server.WaitForConnection()
                [void](Read-AXEBrokerFrame $server)
                Write-AXEBrokerFrame $server $ReplyJson
                $server.Disconnect(); $server.Dispose()
            })
            [void]$ps.AddArgument($PipeName)
            [void]$ps.AddArgument(($Reply | ConvertTo-Json -Compress))
            @{ RS=$rs; PS=$ps; Handle=$ps.BeginInvoke() }
        }
    }

    It 'round-trip: manda la peticion y devuelve la respuesta del servidor' {
        $pipe = "AXE-Test-Echo-$([guid]::NewGuid().ToString('N'))"
        $bg = Start-TestEchoServer $pipe @{ ok=$true; data=@{ x=1 }; err=$null }
        Start-Sleep -Milliseconds 200
        $r = Send-AXEBrokerRequest $pipe 'tweaks.apply' @{id='x'} 'tok' 5000
        while(-not $bg.Handle.IsCompleted){ Start-Sleep -Milliseconds 50 }
        try { $bg.PS.EndInvoke($bg.Handle) } catch {}
        $bg.RS.Close()
        $r.ok | Should -BeTrue
        $r.data.x | Should -Be 1
    }

    It 'si nadie escucha en el pipe, devuelve ok=false en vez de lanzar' {
        $r = Send-AXEBrokerRequest 'AXE-Test-NoOneHome' 'tweaks.apply' @{} 'tok' 1000
        $r.ok | Should -BeFalse
    }
}

Describe 'CLI -Broker/-Token de extremo a extremo (dist/AXE.ps1 real, sin admin)' -Tag 'integration' {
    # Requiere dist/AXE.ps1 reconstruido con los cambios de este plan (Task 10). Lanza el propio
    # .ps1 construido como subproceso NORMAL (sin admin): ejercita 00-header (parseo de -Broker/
    # -Token) + 49-webmain (despacho) + Start-AXEBroker juntos, de principio a fin, sin UAC.
    It 'dist\AXE.ps1 -Broker/-Token responde "no elevado" a traves del CLI real' {
        # dist/AXE.ps1 YA EXISTE en el repo (build anterior, de otro trabajo): Test-Path por si
        # solo no basta para detectar "todavia sin el broker". Se comprueba que el CONTENIDO
        # incluye ya Start-AXEBroker -- si no, es la build vieja (pre-Task 10) y se salta en vez
        # de fallar contra un dist desactualizado.
        $dist = "$PSScriptRoot/../dist/AXE.ps1"
        if(-not (Test-Path $dist) -or -not (Select-String -Path $dist -Pattern 'function Start-AXEBroker' -Quiet)){
            Set-ItResult -Skipped -Because 'dist/AXE.ps1 sin el broker todavia (se reconstruye en Task 10)'; return
        }
        $pipe = "AXE-Test-E2E-$([guid]::NewGuid().ToString('N'))"
        $tokenPath = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.token')
        Set-Content -LiteralPath $tokenPath -Value 'tokE2E' -NoNewline
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-File',"`"$dist`"",'-Broker',$pipe,'-Token',"`"$tokenPath`"") -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 500
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipe, [System.IO.Pipes.PipeDirection]::InOut)
        $client.Connect(5000)
        Write-AXEBrokerFrame $client (@{ cmd='safety.restorePoint'; args=@{}; token='tokE2E'; ts=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() } | ConvertTo-Json -Compress)
        $resp = Read-AXEBrokerFrame $client
        $client.Dispose()
        $p.WaitForExit(5000) | Out-Null
        ($resp | ConvertFrom-Json).ok | Should -BeFalse
        ($resp | ConvertFrom-Json).err | Should -Match 'elevad'
    }
}

Describe 'Invoke-AXEPrivilegedBackground / Receive-AXEPrivilegedBackground - runspace sin bloquear' -Tag 'unit' {
    BeforeAll {
        $script:OldInvokePriv = (Get-Item function:Invoke-AXEPrivileged -EA SilentlyContinue).ScriptBlock
        # Doble de pruebas: nunca toca Start-Process/UAC. Devuelve lo que recibio, para probar
        # que los argumentos SI cruzan al runspace de fondo intactos.
        Set-Item function:Invoke-AXEPrivileged -Value {
            param($Cmd, $A)
            [pscustomobject]@{ ok=$true; data=@{ echoCmd=$Cmd; echoId=$A.id }; err=$null }
        }
    }
    AfterAll {
        if($script:OldInvokePriv){ Set-Item function:Invoke-AXEPrivileged -Value $script:OldInvokePriv }
    }

    It 'el resultado del doble de pruebas cruza intacto el runspace de fondo' {
        $bg = Invoke-AXEPrivilegedBackground 'tweaks.apply' @{ id = 'cpu_mmcss' }
        $timeout = (Get-Date).AddSeconds(5)
        while(-not $bg.Handle.IsCompleted -and (Get-Date) -lt $timeout){ Start-Sleep -Milliseconds 50 }
        $bg.Handle.IsCompleted | Should -BeTrue -Because 'el runspace de fondo debe terminar en <5s con el doble de pruebas'
        $r = Receive-AXEPrivilegedBackground $bg
        $r.ok | Should -BeTrue
        $r.data.echoCmd | Should -Be 'tweaks.apply'
        $r.data.echoId | Should -Be 'cpu_mmcss'
    }

    It 'una excepcion dentro del runspace se repackea como ok=false, no se relanza' {
        Set-Item function:Invoke-AXEPrivileged -Value { param($Cmd,$A) throw 'boom de prueba' }
        $bg = Invoke-AXEPrivilegedBackground 'tweaks.apply' @{ id = 'x' }
        $timeout = (Get-Date).AddSeconds(5)
        while(-not $bg.Handle.IsCompleted -and (Get-Date) -lt $timeout){ Start-Sleep -Milliseconds 50 }
        $r = Receive-AXEPrivilegedBackground $bg
        $r.ok | Should -BeFalse
        $r.err | Should -Match 'boom de prueba'
    }
}
