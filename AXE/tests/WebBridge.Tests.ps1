# Pester del puente RPC (48-webbridge). Sin hardware grafico: solo la logica de despacho.
BeforeAll {
    . "$PSScriptRoot/_load-engine.ps1"
    # _load-engine salta 00-header (bloque param/#Requires); en dist ese modulo fija la version.
    # Aqui la suplimos para probar app.info como en produccion (donde nunca es nula: fallback 6.1.0-dev).
    if(-not $script:AXEVersion){ $script:AXEVersion = '0.0.0-test' }
}

Describe 'Puente: lista blanca cerrada' {
    It 'rechaza un cmd que no esta en la lista blanca' {
        $r = Invoke-AXEBridgeCmd 'os.format' @{}
        $r.ok  | Should -BeFalse
        $r.err | Should -Match 'desconocido'
    }
    It 'acepta hw.get y devuelve un objeto con CpuName' {
        $r = Invoke-AXEBridgeCmd 'hw.get' @{}
        $r.ok | Should -BeTrue
        $r.data.PSObject.Properties.Name | Should -Contain 'CpuName'
    }
    It 'no ejecuta el payload como codigo (sin eval)' {
        $r = Invoke-AXEBridgeCmd 'Get-Process; hw.get' @{}
        $r.ok | Should -BeFalse
    }
    It 'la respuesta siempre tiene la forma {ok,data,err}' {
        $r = Invoke-AXEBridgeCmd 'hw.get' @{}
        foreach($k in 'ok','data','err'){ $r.PSObject.Properties.Name | Should -Contain $k }
    }
}

Describe 'Puente: comandos del Panel (Fase 4)' {
    It 'app.info devuelve version y tamano de catalogo' {
        $r = Invoke-AXEBridgeCmd 'app.info' @{}
        $r.ok | Should -BeTrue
        $r.data.version | Should -Not -BeNullOrEmpty
        $r.data.tweaks  | Should -BeGreaterThan 0
    }
    It 'catalog.tiers devuelve totales por tier que suman el catalogo' {
        $r = Invoke-AXEBridgeCmd 'catalog.tiers' @{}
        $r.ok | Should -BeTrue
        $sum = ($r.data | Measure-Object -Property total -Sum).Sum
        $sum | Should -Be $script:CAT.Count
        foreach($t in $r.data){ $t.PSObject.Properties.Name | Should -Contain 'tier' }
    }
    It 'measure.score devuelve un DTO plano con total 0-100 y receta' {
        $r = Invoke-AXEBridgeCmd 'measure.score' @{}
        $r.ok | Should -BeTrue
        foreach($k in 'total','timer','jitter','coverage','idle','breakdown','ts'){
            $r.data.PSObject.Properties.Name | Should -Contain $k
        }
        $r.data.total | Should -BeGreaterOrEqual 0
        $r.data.total | Should -BeLessOrEqual 100
        $r.data.breakdown | Should -Not -BeNullOrEmpty
    }
    It 'measure.score es JSON-seguro (nulls, no la cadena n/a en campos numericos)' {
        $r = Invoke-AXEBridgeCmd 'measure.score' @{}
        # timerMs/jitterP999/on/app son null cuando no se pudo medir, nunca 'n/a'
        foreach($k in 'timerMs','jitterP999','on','app'){
            $v = $r.data.$k
            if($null -ne $v){ $v | Should -Not -Be 'n/a' }
        }
    }
}

Describe 'Puente: Optimizar (Fase 6) - solo lecturas seguras' {
    It 'tweaks.list devuelve un item por tweak con la forma esperada' {
        $r = Invoke-AXEBridgeCmd 'tweaks.list' @{}
        $r.ok | Should -BeTrue
        @($r.data).Count | Should -Be $script:CAT.Count
        foreach($k in 'id','name','desc','tier','reboot','applied','blocked','source'){
            $r.data[0].PSObject.Properties.Name | Should -Contain $k
        }
    }
    It 'tweaks.apply con id inexistente NO modifica nada (ok=false)' {
        # Sin admin -> "requiere admin"; con admin -> "tweak desconocido". En ambos casos ok=false y
        # cero cambios en el sistema (un id bogus nunca coincide con un tweak real).
        $r = Invoke-AXEBridgeCmd 'tweaks.apply' @{ id = '__no_existe__' }
        $r.ok  | Should -BeFalse
        $r.err | Should -Not -BeNullOrEmpty
    }
}

Describe 'Puente: Fase 7 - lecturas seguras' {
    It 'diag.get devuelve lines y findings (no aplica nada)' {
        $r = Invoke-AXEBridgeCmd 'diag.get' @{}
        $r.ok | Should -BeTrue
        foreach($k in 'lines','findings','bad','unknown'){ $r.data.PSObject.Properties.Name | Should -Contain $k }
    }
    It 'prueba.report SIN linea base previa se niega (no inventa un antes)' {
        # Estado limpio: PruebaSnap0 arranca $null hasta que se capture una baseline.
        $script:PruebaSnap0 = $null
        $r = Invoke-AXEBridgeCmd 'prueba.report' @{}
        $r.ok  | Should -BeFalse
        $r.err | Should -Match 'linea base'
    }
    It 'prueba.baseline luego prueba.report producen un informe real' {
        $b = Invoke-AXEBridgeCmd 'prueba.baseline' @{}
        $b.ok | Should -BeTrue
        foreach($k in 'total','timerMs','jitterP999','ts'){ $b.data.PSObject.Properties.Name | Should -Contain $k }
        $r = Invoke-AXEBridgeCmd 'prueba.report' @{}
        $r.ok | Should -BeTrue
        @($r.data.lines).Count | Should -BeGreaterThan 0
        $r.data.PSObject.Properties.Name | Should -Contain 'after'
    }
}

Describe 'Puente: sesion de juego (spec 2026-07-25)' {
    # session.setLevel escribe en disco: se aisla $script:AXEData en un temporal, como Fps/GameGpu.
    # Nada aqui congela un proceso: solo preview (read-only), estado, stop sin sesion y overrides.
    BeforeAll {
        $script:SessDataOld = $script:AXEData
        $script:AXEData = Join-Path ([IO.Path]::GetTempPath()) ('axe-test-bridge-sess-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
    }
    AfterAll {
        if($script:AXEData -and (Test-Path $script:AXEData)){ Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue }
        $script:AXEData = $script:SessDataOld
    }

    It 'session.preview devuelve el reparto y NO deja sesion activa (read-only)' {
        $r = Invoke-AXEBridgeCmd 'session.preview' @{}
        $r.ok | Should -BeTrue
        foreach($k in 'freezeOk','freezeReason','gameFound','gamePid','counts','apps'){
            $r.data.PSObject.Properties.Name | Should -Contain $k
        }
        $r.data.gameFound | Should -BeFalse   # no se pidio ningun juego
        (Invoke-AXEBridgeCmd 'session.status' @{}).data.active | Should -BeFalse
    }

    It 'el reparto reparte algo y jamas propone tocar un proceso duro (maquina real)' {
        $r = Invoke-AXEBridgeCmd 'session.preview' @{}
        $c = $r.data.counts
        ([int]$c.congelado + [int]$c.degradado + [int]$c.intacto) | Should -BeGreaterThan 0
        # Este check corre sobre los procesos REALES de la maquina, y por eso caza lo que un fixture
        # sintetico no: svchost aparece en la sesion interactiva (servicios POR-USUARIO). Puede salir
        # en el reparto, pero nunca como congelable ni degradable.
        foreach($a in @($r.data.apps | Where-Object { $_.level -ne 'intacto' })){ $a.hard | Should -BeFalse }
        @($r.data.apps | Where-Object { $_.name -eq 'svchost' -and $_.level -ne 'intacto' }).Count | Should -Be 0
    }

    It 'el pid del propio proceso solo puede salir en una fila INTACTA' {
        # Regresion: las filas se agrupaban solo por nombre, asi que si el proceso propio (o el juego)
        # comparte nombre con otro -dos pwsh, dos instancias del mismo launcher- la fila nacia en el
        # pase 'congelado' por el ajeno y luego se marcaba dura por el propio: el DTO decia
        # "congelar" y "intocable" a la vez. Solo salta cuando existe el homonimo, de ahi el check
        # por pid en vez de por nombre.
        $r = Invoke-AXEBridgeCmd 'session.preview' @{}
        foreach($a in @($r.data.apps)){
            if(@($a.pids) -contains $PID){ $a.level | Should -Be 'intacto' }
        }
    }

    It 'cada fila del reparto trae nivel, familia y si es duro' {
        $r = Invoke-AXEBridgeCmd 'session.preview' @{}
        foreach($k in 'name','level','count','pids','family','hard','override'){
            @($r.data.apps)[0].PSObject.Properties.Name | Should -Contain $k
        }
        foreach($a in @($r.data.apps)){ $a.level | Should -BeIn @('congelado','degradado','intacto') }
    }

    It 'session.start sin juego se niega y no arranca nada' {
        (Invoke-AXEBridgeCmd 'session.start' @{}).ok | Should -BeFalse
        (Invoke-AXEBridgeCmd 'session.start' @{ game = '__no_existe__' }).ok | Should -BeFalse
        (Invoke-AXEBridgeCmd 'session.status' @{}).data.active | Should -BeFalse
    }

    It 'session.setLevel guarda un nivel valido y queda en disco' {
        $r = Invoke-AXEBridgeCmd 'session.setLevel' @{ name = 'chrome'; level = 'congelado' }
        $r.ok | Should -BeTrue
        $r.data.needsRestart | Should -BeFalse     # sin sesion viva no hay nada que re-repartir
        (Read-AXESessionOverrides)['chrome'] | Should -Be 'congelado'
    }

    It 'session.setLevel rechaza duros y niveles inventados' {
        (Invoke-AXEBridgeCmd 'session.setLevel' @{ name = 'explorer'; level = 'congelado' }).ok | Should -BeFalse
        (Invoke-AXEBridgeCmd 'session.setLevel' @{ name = 'chrome';   level = 'turbo'     }).ok | Should -BeFalse
    }

    It 'session.stop sin sesion es un no-op limpio' {
        $r = Invoke-AXEBridgeCmd 'session.stop' @{}
        $r.ok          | Should -BeTrue
        $r.data.active | Should -BeFalse
    }
}

Describe 'Puente: endurecimiento' {
    It 'todo cmd de la lista blanca responde con la forma {ok,data,err} y no tumba el proceso' {
        foreach($cmd in $script:AXEBridgeMap.Keys){
            $r = Invoke-AXEBridgeCmd $cmd @{}   # args vacios: apply/revert/master/restore gatean admin -> ok:false limpio
            foreach($k in 'ok','data','err'){ $r.PSObject.Properties.Name | Should -Contain $k }
        }
    }
    It 'la lista blanca es EXACTA: mayusculas distintas no colisionan (HW.GET != hw.get)' {
        (Invoke-AXEBridgeCmd 'HW.GET' @{}).ok | Should -BeFalse
        (Invoke-AXEBridgeCmd 'Tweaks.Apply' @{}).ok | Should -BeFalse
    }
    It 'args ausentes en tweaks.apply no ejecutan nada peligroso (ok:false, cero cambios)' {
        $r = Invoke-AXEBridgeCmd 'tweaks.apply' @{}
        $r.ok  | Should -BeFalse
        $r.err | Should -Not -BeNullOrEmpty
    }
}
