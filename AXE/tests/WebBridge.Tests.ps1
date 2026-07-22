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
