# Pester del puente RPC (48-webbridge). Sin hardware grafico: solo la logica de despacho.
BeforeAll {
    . "$PSScriptRoot/_load-engine.ps1"
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
