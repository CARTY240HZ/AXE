# Unit - planificador PURO del daemon de sesion (40-session.ps1). Sin hardware, sin kernel:
# Get-AXESessionPlan recibe hechos sinteticos y se comprueba el reparto en los tres niveles.
# El freeze real (Job Object) NO se testea aqui - pide hardware y una version concreta de
# Windows; se valida a mano (ver spec 2026-07-20, "Verificacion manual"). Mismo criterio que
# Fps.Tests documenta que no cubre que PresentMon enganche un juego.

BeforeAll {
    . "$PSScriptRoot/../src/40-session.ps1"

    # Sesion interactiva sintetica = 1. Fabrica de hechos {Pid,Name,SessionId,Path}.
    function New-Proc($procId, $name, $sid = 1) {
        [pscustomobject]@{ Pid = [int]$procId; Name = [string]$name; SessionId = [int]$sid; Path = $null }
    }
    # Nombres de los procesos de un grupo del plan (helper de asercion).
    function NamesOf($group) { @($group | ForEach-Object { $_.Name }) }
}

Describe 'Get-AXESessionPlan - frontera y protegidos' -Tag 'unit' {

    BeforeEach {
        $script:facts = @(
            (New-Proc 1000 'thegame'       1)
            (New-Proc 1001 'explorer'      1)
            (New-Proc 1002 'dwm'           1)
            (New-Proc 1003 'csrss'         1)
            (New-Proc 1004 'winlogon'      1)
            (New-Proc 1005 'discord'       1)
            (New-Proc 1006 'chrome'        1)
            (New-Proc 1007 'brave'         1)
            (New-Proc 1008 'vivaldi'       1)
            (New-Proc 1009 'opera'         1)
            (New-Proc 1010 'spotify'       1)
            (New-Proc 1011 'EasyAntiCheat' 1)
            (New-Proc 1012 'randomthing'   1)
            (New-Proc 1013 'svchost'       0)   # Session 0: fuera por definicion
            (New-Proc 99   'powershell'    1)   # el propio AXE
        )
        $script:plan = Get-AXESessionPlan -Processes $script:facts -GamePid 1000 -GameName 'thegame' -SelfPid 99 -SessionId 1
    }

    It 'un proceso de Session 0 nunca sale como congelable (ni en ningun grupo)' {
        foreach ($g in $script:plan.Intacto, $script:plan.Degradado, $script:plan.Congelado) {
            NamesOf $g | Should -Not -Contain 'svchost'
        }
    }

    It 'dwm/explorer/csrss/winlogon nunca salen como congelables' {
        foreach ($shell in 'dwm', 'explorer', 'csrss', 'winlogon') {
            NamesOf $script:plan.Congelado | Should -Not -Contain $shell
            NamesOf $script:plan.Intacto   | Should -Contain $shell
        }
    }

    It 'el proceso del juego nunca sale como congelable ni degradable' {
        NamesOf $script:plan.Congelado | Should -Not -Contain 'thegame'
        NamesOf $script:plan.Degradado | Should -Not -Contain 'thegame'
        NamesOf $script:plan.Intacto   | Should -Contain 'thegame'
    }

    It 'el propio AXE nunca sale como congelable' {
        NamesOf $script:plan.Congelado | Should -Not -Contain 'powershell'
        NamesOf $script:plan.Intacto   | Should -Contain 'powershell'
    }

    It 'los anti-cheat conocidos nunca salen como congelables' {
        NamesOf $script:plan.Congelado | Should -Not -Contain 'EasyAntiCheat'
        NamesOf $script:plan.Intacto   | Should -Contain 'EasyAntiCheat'
    }

    It 'Discord sale INTACTO, no DEGRADADO (la voz es sensible a latencia)' {
        NamesOf $script:plan.Intacto   | Should -Contain 'discord'
        NamesOf $script:plan.Degradado | Should -Not -Contain 'discord'
    }

    It 'Brave, Vivaldi y Opera salen DEGRADADOS por familia sin estar listados uno a uno' {
        foreach ($b in 'brave', 'vivaldi', 'opera') {
            NamesOf $script:plan.Degradado | Should -Contain $b
        }
    }

    It 'un proceso desconocido de la sesion del usuario sale CONGELADO' {
        NamesOf $script:plan.Congelado | Should -Contain 'randomthing'
    }

    It 'svchost DENTRO de la sesion interactiva (servicios por-usuario) sale INTACTO' {
        # Windows aloja CDPUserSvc/WpnUserService/OneSyncSvc... en svchost de la sesion del usuario,
        # no en la 0: la frontera de sesion NO los protege. Congelar uno cuelga a quien le haga un
        # RPC sincrono (shell, notificaciones, portapapeles) hasta el timeout.
        $facts = @( (New-Proc 6000 'thegame' 1), (New-Proc 6001 'svchost' 1) )
        $plan  = Get-AXESessionPlan -Processes $facts -GamePid 6000 -GameName 'thegame' -SelfPid 99 -SessionId 1
        NamesOf $plan.Congelado | Should -Not -Contain 'svchost'
        NamesOf $plan.Degradado | Should -Not -Contain 'svchost'
        NamesOf $plan.Intacto   | Should -Contain 'svchost'
    }

    It 'ni con override el usuario puede congelar un host de servicios por-usuario' {
        $facts = @( (New-Proc 6100 'thegame' 1), (New-Proc 6101 'svchost' 1) )
        $plan  = Get-AXESessionPlan -Processes $facts -GamePid 6100 -GameName 'thegame' -SelfPid 99 -SessionId 1 -Config @{ svchost = 'congelado' }
        NamesOf $plan.Congelado | Should -Not -Contain 'svchost'
    }
}

Describe 'Get-AXESessionPlan - config y casos limite' -Tag 'unit' {

    It 'la config del usuario sobreescribe el default por app' {
        $facts = @( (New-Proc 2000 'thegame' 1), (New-Proc 2001 'chrome' 1), (New-Proc 2002 'randomthing' 1) )
        # chrome (default DEGRADADO) -> forzado a CONGELADO; randomthing (default CONGELADO) -> INTACTO.
        $cfg  = @{ chrome = 'congelado'; randomthing = 'intacto' }
        $plan = Get-AXESessionPlan -Processes $facts -GamePid 2000 -GameName 'thegame' -SelfPid 99 -SessionId 1 -Config $cfg
        NamesOf $plan.Congelado | Should -Contain 'chrome'
        NamesOf $plan.Intacto   | Should -Contain 'randomthing'
    }

    It 'la config NO puede desproteger un proceso duro (shell sigue INTACTO)' {
        $facts = @( (New-Proc 2100 'thegame' 1), (New-Proc 2101 'explorer' 1) )
        $plan = Get-AXESessionPlan -Processes $facts -GamePid 2100 -GameName 'thegame' -SelfPid 99 -SessionId 1 -Config @{ explorer = 'congelado' }
        NamesOf $plan.Congelado | Should -Not -Contain 'explorer'
        NamesOf $plan.Intacto   | Should -Contain 'explorer'
    }

    It 'con la lista de procesos vacia, el plan sale vacio y no revienta' {
        $plan = Get-AXESessionPlan -Processes @() -GamePid 0 -GameName 'x' -SelfPid 1 -SessionId 1
        @($plan.Intacto).Count   | Should -Be 0
        @($plan.Degradado).Count | Should -Be 0
        @($plan.Congelado).Count | Should -Be 0
    }

    It 'SessionId invalido (0) devuelve plan vacio sin clasificar nada' {
        $facts = @( (New-Proc 3000 'randomthing' 1) )
        $plan = Get-AXESessionPlan -Processes $facts -GamePid 0 -GameName 'x' -SelfPid 1 -SessionId 0
        @($plan.Congelado).Count | Should -Be 0
    }

    It 'solo se consideran procesos de la sesion interactiva pedida' {
        $facts = @( (New-Proc 4000 'randomA' 1), (New-Proc 4001 'randomB' 2) )
        $plan = Get-AXESessionPlan -Processes $facts -GamePid 0 -GameName 'x' -SelfPid 99 -SessionId 1
        NamesOf $plan.Congelado | Should -Contain 'randomA'
        NamesOf $plan.Congelado | Should -Not -Contain 'randomB'
    }
}

# --- Persistencia del reparto (spec 2026-07-25). $script:AXEData apunta a un temporal: mismo
# patron que Fps.Tests/GameGpu.Tests, ningun test toca el AXE/ real de nadie.
Describe 'Overrides del reparto - persistencia' -Tag 'unit' {

    BeforeEach {
        $script:AXEData = Join-Path ([System.IO.Path]::GetTempPath()) ('axe-test-sess-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
    }
    AfterEach {
        if($script:AXEData -and (Test-Path $script:AXEData)){ Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue }
    }

    It 'sin fichero devuelve un mapa vacio (no null, no lanza)' {
        $o = Read-AXESessionOverrides
        $o       | Should -BeOfType ([hashtable])
        $o.Count | Should -Be 0
    }

    It 'un JSON corrupto se ignora y devuelve vacio en vez de lanzar' {
        Set-Content -Path (Get-AXESessionLevelsPath) -Value '{ esto no es json' -Encoding UTF8
        { Read-AXESessionOverrides } | Should -Not -Throw
        (Read-AXESessionOverrides).Count | Should -Be 0
    }

    It 'round-trip: lo que escribe Set lo lee Read' {
        (Set-AXESessionOverride -Name 'chrome' -Level 'congelado').Ok | Should -BeTrue
        (Read-AXESessionOverrides)['chrome'] | Should -Be 'congelado'
    }

    It 'normaliza el nombre: Chrome.exe y chrome son la misma app' {
        [void](Set-AXESessionOverride -Name 'Chrome.exe' -Level 'intacto')
        (Read-AXESessionOverrides)['chrome'] | Should -Be 'intacto'
    }

    It 'un nivel inventado se rechaza y NO se escribe' {
        (Set-AXESessionOverride -Name 'chrome' -Level 'turbo').Ok | Should -BeFalse
        (Read-AXESessionOverrides).ContainsKey('chrome') | Should -BeFalse
    }

    It "'default' borra el override en vez de guardar un nivel" {
        [void](Set-AXESessionOverride -Name 'spotify' -Level 'congelado')
        (Set-AXESessionOverride -Name 'spotify' -Level 'default').Ok | Should -BeTrue
        (Read-AXESessionOverrides).ContainsKey('spotify') | Should -BeFalse
    }

    It 'un proceso duro se rechaza con motivo y no se escribe (nada de ajustes que no hacen nada)' {
        foreach($hard in 'explorer','EasyAntiCheat'){
            $r = Set-AXESessionOverride -Name $hard -Level 'congelado'
            $r.Ok     | Should -BeFalse
            $r.Reason | Should -Not -BeNullOrEmpty
            (Read-AXESessionOverrides).ContainsKey($hard.ToLowerInvariant()) | Should -BeFalse
        }
    }

    It 'una entrada con nivel invalido en el fichero se descarta y las validas sobreviven' {
        Set-Content -Path (Get-AXESessionLevelsPath) -Value '{"chrome":"congelado","spotify":"turbo"}' -Encoding UTF8
        $o = Read-AXESessionOverrides
        $o['chrome']              | Should -Be 'congelado'
        $o.ContainsKey('spotify') | Should -BeFalse
    }

    It 'el override del fichero llega al plan (las dos piezas juntas)' {
        [void](Set-AXESessionOverride -Name 'chrome' -Level 'congelado')
        $facts = @( (New-Proc 5000 'thegame' 1), (New-Proc 5001 'chrome' 1) )
        $plan  = Get-AXESessionPlan -Processes $facts -GamePid 5000 -GameName 'thegame' -SelfPid 99 -SessionId 1 -Config (Read-AXESessionOverrides)
        NamesOf $plan.Congelado | Should -Contain 'chrome'
    }

    It 'sin carpeta de datos resoluble: Read vacio y Set se niega con motivo' {
        $old = $script:AXEData
        $script:AXEData = $null
        try {
            Get-AXESessionLevelsPath         | Should -BeNullOrEmpty
            (Read-AXESessionOverrides).Count | Should -Be 0
            (Set-AXESessionOverride -Name 'chrome' -Level 'congelado').Ok | Should -BeFalse
        } finally { $script:AXEData = $old }
    }
}

# --- Diario de prioridades (auditoria 2026-07-25). La red que el kernel NO da: descongelar es
# estado del job, bajar la prioridad no. Aqui se ejerce con un proceso REAL propio (sin admin): se
# degrada, se simula que AXE murio sin cerrar, y se comprueba que el arranque siguiente la devuelve.
Describe 'Diario de prioridades - la red de la salida sucia' -Tag 'unit' {

    # El helper va en BeforeAll, no en el cuerpo del Describe: Pester 5 corre el cuerpo en la fase de
    # descubrimiento, y lo definido ahi no existe cuando corren los It.
    BeforeAll {
        # Cobaya: otro proceso del MISMO host que corre esta suite. Nadie mas lo toca.
        function New-Guinea {
            $exe = (Get-Process -Id $PID).Path
            $p = Start-Process -FilePath $exe -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -PassThru -WindowStyle Hidden
            Start-Sleep -Milliseconds 500   # que StartTime exista antes de leerlo
            $p
        }
    }

    BeforeEach {
        $script:AXEData = Join-Path ([System.IO.Path]::GetTempPath()) ('axe-test-jrn-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
    }
    AfterEach {
        if($script:AXEData -and (Test-Path $script:AXEData)){ Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue }
    }

    It 'sin diario no hay nada que restaurar' {
        Restore-AXESessionDegraded | Should -Be 0
    }

    It 'un diario ilegible se descarta y se borra, sin lanzar' {
        Set-Content -Path (Get-AXESessionJournalPath) -Value '{ esto no es json' -Encoding UTF8
        { Restore-AXESessionDegraded } | Should -Not -Throw
        Test-Path (Get-AXESessionJournalPath) | Should -BeFalse
    }

    It 'restaura DE VERDAD la prioridad de un proceso degradado tras una muerte sucia' {
        $g = New-Guinea
        try {
            $pr   = Get-Process -Id $g.Id
            $prev = [string]$pr.PriorityClass
            $pr.PriorityClass = 'BelowNormal'
            # Lo que deja Start-AXESession; despues, nadie llama a Stop (kill/BSOD).
            Write-AXESessionJournal @([pscustomobject]@{
                Pid = [int]$g.Id; Name = [string]$pr.ProcessName; Prev = $prev; StartTicks = [long]$pr.StartTime.Ticks })
            Test-Path (Get-AXESessionJournalPath) | Should -BeTrue
            Restore-AXESessionDegraded | Should -Be 1
            [string](Get-Process -Id $g.Id).PriorityClass | Should -Be $prev
            Test-Path (Get-AXESessionJournalPath) | Should -BeFalse   # consumido, no se repite
        } finally { Stop-Process -Id $g.Id -Force -EA SilentlyContinue }
    }

    It 'un pid REUSADO no se toca: si el nombre no cuadra, se ignora' {
        $g = New-Guinea
        try {
            (Get-Process -Id $g.Id).PriorityClass = 'BelowNormal'
            Write-AXESessionJournal @([pscustomobject]@{ Pid = [int]$g.Id; Name = 'otracosa'; Prev = 'High'; StartTicks = 0 })
            Restore-AXESessionDegraded | Should -Be 0
            [string](Get-Process -Id $g.Id).PriorityClass | Should -Be 'BelowNormal'
        } finally { Stop-Process -Id $g.Id -Force -EA SilentlyContinue }
    }

    It 'mismo pid y mismo nombre pero otro arranque tampoco se toca' {
        $g = New-Guinea
        try {
            $pr = Get-Process -Id $g.Id
            $pr.PriorityClass = 'BelowNormal'
            Write-AXESessionJournal @([pscustomobject]@{ Pid = [int]$g.Id; Name = [string]$pr.ProcessName; Prev = 'High'; StartTicks = 1 })
            Restore-AXESessionDegraded | Should -Be 0
            [string](Get-Process -Id $g.Id).PriorityClass | Should -Be 'BelowNormal'
        } finally { Stop-Process -Id $g.Id -Force -EA SilentlyContinue }
    }

    It 'un diario de OTRA instancia de AXE viva no se toca ni se borra' {
        # Dos AXE abiertos: el segundo no puede reparar la sesion del primero. Restaurar a media
        # partida seria molesto; borrar el diario seria peor, porque dejaria al primero sin red si
        # muriese sucio. El JSON se escribe a mano a proposito: lo que se prueba aqui es el LECTOR.
        $owner  = New-Guinea       # hace de "otra instancia de AXE" viva
        $victim = New-Guinea       # el proceso degradado que ese diario dice haber tocado
        try {
            $op = Get-Process -Id $owner.Id
            $vp = Get-Process -Id $victim.Id
            $vp.PriorityClass = 'BelowNormal'
            $doc = [pscustomobject]@{
                owner    = [pscustomobject]@{ pid = [int]$owner.Id; name = [string]$op.ProcessName; startTicks = [long]$op.StartTime.Ticks }
                degraded = @([pscustomobject]@{ pid = [int]$victim.Id; name = [string]$vp.ProcessName; prev = 'Normal'; startTicks = [long]$vp.StartTime.Ticks })
            }
            Set-Content -Path (Get-AXESessionJournalPath) -Value (ConvertTo-Json -InputObject $doc -Depth 4) -Encoding UTF8
            Restore-AXESessionDegraded | Should -Be 0
            [string](Get-Process -Id $victim.Id).PriorityClass | Should -Be 'BelowNormal'
            Test-Path (Get-AXESessionJournalPath) | Should -BeTrue   # sigue siendo la red del otro
        } finally {
            Stop-Process -Id $owner.Id  -Force -EA SilentlyContinue
            Stop-Process -Id $victim.Id -Force -EA SilentlyContinue
        }
    }

    It 'si el dueño ya murio, el diario se repara (es justo el caso que existe para cubrir)' {
        $owner = New-Guinea
        $ownerPid = [int]$owner.Id; $ownerName = (Get-Process -Id $ownerPid).ProcessName
        $ownerTicks = [long](Get-Process -Id $ownerPid).StartTime.Ticks
        Stop-Process -Id $ownerPid -Force            # muerte sucia del "AXE" anterior
        $victim = New-Guinea
        try {
            $vp = Get-Process -Id $victim.Id
            $vp.PriorityClass = 'BelowNormal'
            $doc = [pscustomobject]@{
                owner    = [pscustomobject]@{ pid = $ownerPid; name = [string]$ownerName; startTicks = $ownerTicks }
                degraded = @([pscustomobject]@{ pid = [int]$victim.Id; name = [string]$vp.ProcessName; prev = 'Normal'; startTicks = [long]$vp.StartTime.Ticks })
            }
            Set-Content -Path (Get-AXESessionJournalPath) -Value (ConvertTo-Json -InputObject $doc -Depth 4) -Encoding UTF8
            Restore-AXESessionDegraded | Should -Be 1
            [string](Get-Process -Id $victim.Id).PriorityClass | Should -Be 'Normal'
        } finally { Stop-Process -Id $victim.Id -Force -EA SilentlyContinue }
    }

    It 'Test-AXESessionSameProcess reconoce al propio proceso y rechaza lo dudoso' {
        $me = Get-Process -Id $PID
        Test-AXESessionSameProcess -ProcessId $PID -Name $me.ProcessName -StartTicks ([long]$me.StartTime.Ticks) | Should -BeTrue
        Test-AXESessionSameProcess -ProcessId $PID -Name $me.ProcessName -StartTicks 1 | Should -BeFalse
        Test-AXESessionSameProcess -ProcessId $PID -Name 'otracosa'      -StartTicks 0 | Should -BeFalse
        Test-AXESessionSameProcess -ProcessId 0    -Name $me.ProcessName -StartTicks 0 | Should -BeFalse
    }

    It 'sin carpeta de datos el diario no existe y restaurar es un no-op' {
        $old = $script:AXEData
        $script:AXEData = $null
        try {
            Get-AXESessionJournalPath  | Should -BeNullOrEmpty
            Restore-AXESessionDegraded | Should -Be 0
        } finally { $script:AXEData = $old }
    }
}

Describe 'Get-AXESessionFamily / Test-AXESessionHardApp - puras' -Tag 'unit' {

    It 'clasifica por familia, con o sin extension' {
        Get-AXESessionFamily 'brave'      | Should -Be 'navegador'
        Get-AXESessionFamily 'Chrome.exe' | Should -Be 'navegador'
        Get-AXESessionFamily 'discord'    | Should -Be 'voz'
        Get-AXESessionFamily 'spotify'    | Should -Be 'musica'
    }

    It 'un proceso que no esta en ninguna familia devuelve null (no adivina)' {
        Get-AXESessionFamily 'randomthing' | Should -BeNullOrEmpty
    }

    It 'shell y anticheat son duros; una app normal no' {
        Test-AXESessionHardApp 'explorer'      | Should -BeTrue
        Test-AXESessionHardApp 'EasyAntiCheat' | Should -BeTrue
        Test-AXESessionHardApp 'chrome'        | Should -BeFalse
    }
}

Describe 'Get-AXESessionStatus - DTO puro para la ventana' -Tag 'unit' {

    It 'sin sesion: active=false y no lanza' {
        (Get-AXESessionStatus -Session $null).active | Should -BeFalse
    }

    It 'una sesion fallida no se pinta como activa y conserva su motivo' {
        $st = Get-AXESessionStatus -Session ([pscustomobject]@{ Ok = $false; Reason = 'el juego no esta corriendo.' })
        $st.active | Should -BeFalse
        $st.reason | Should -Match 'no esta corriendo'
    }

    It 'una sesion viva expone juego, contadores y tiempo activo' {
        $sess = [pscustomobject]@{
            Ok = $true; Handle = [IntPtr]::Zero; Game = 'thegame'; GamePid = 1000; SessionId = 1
            Plan = [pscustomobject]@{ Intacto = @(1, 2, 3); Degradado = @(1); Congelado = @(1, 2) }
            Assigned = 2; Failed = 1; Degraded = @([pscustomobject]@{ Pid = 1; Prev = 'Normal' })
            Started = (Get-Date).AddSeconds(-30)
        }
        $st = Get-AXESessionStatus -Session $sess
        $st.active   | Should -BeTrue
        $st.game     | Should -Be 'thegame'
        $st.frozen   | Should -Be 2
        $st.failed   | Should -Be 1
        $st.degraded | Should -Be 1
        $st.intact   | Should -Be 3
        $st.elapsedS | Should -BeGreaterOrEqual 29
        @($st.lines).Count | Should -BeGreaterThan 0
    }

    It 'el motivo de cierre viaja aunque ya no haya sesion (la UI dice POR QUE se apago)' {
        $st = Get-AXESessionStatus -Session $null -EndedReason 'el juego se cerro.'
        $st.active      | Should -BeFalse
        $st.endedReason | Should -Match 'se cerro'
    }
}

Describe 'Format-AXESession - render puro' -Tag 'unit' {
    It 'una sesion fallida se explica, no revienta' {
        $lines = Format-AXESession ([pscustomobject]@{ Ok = $false; Reason = 'el juego no esta corriendo.' })
        ($lines -join "`n") | Should -Match 'NO iniciada'
    }
    It 'sin objeto de sesion devuelve una linea, no null' {
        @(Format-AXESession $null).Count | Should -BeGreaterThan 0
    }
}
