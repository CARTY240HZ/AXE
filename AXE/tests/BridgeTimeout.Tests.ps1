Describe 'Bridge RPC timeouts' -Tag 'unit' {
    It 'mantiene 15s como default para operaciones cortas/desconocidas' {
        $js = Get-Content (Join-Path $PSScriptRoot '..\webui\bridge.js') -Raw
        $js | Should -Match 'const DEFAULT_TIMEOUT_MS = 15000;'
    }

    It 'da margen suficiente a las operaciones largas conocidas' {
        $js = Get-Content (Join-Path $PSScriptRoot '..\webui\bridge.js') -Raw
        foreach($entry in @(
            "'fps.capture': 150000",
            "'bench.baseline': 120000",
            "'bench.after': 120000",
            "'net.probe': 90000",
            "'tweaks.masterRevert': 120000"
        )) {
            $js | Should -Match ([regex]::Escape($entry))
        }
    }

    It 'corta la espera solo de la peticion que ha expirado' {
        $js = Get-Content (Join-Path $PSScriptRoot '..\webui\bridge.js') -Raw
        $js | Should -Match 'if \(pending\.has\(id\)\)'
        $js | Should -Match 'pending\.delete\(id\);'
    }
}
