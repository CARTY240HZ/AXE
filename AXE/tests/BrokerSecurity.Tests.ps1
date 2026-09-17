# Static security contracts for the unelevated WebView2 -> elevated broker boundary.

Describe 'Privileged broker security contracts' -Tag 'unit','security' {
    BeforeAll {
        $root = Split-Path -Parent $PSScriptRoot
        $script:Header = Get-Content (Join-Path $root 'src/00-header.ps1') -Raw
        $script:Entry  = Get-Content (Join-Path $root 'src/47d-brokerentry.ps1') -Raw
        $script:Broker = Get-Content (Join-Path $root 'src/47c-privbroker.ps1') -Raw
        $script:Bridge = Get-Content (Join-Path $root 'src/48c-broker-bridge.ps1') -Raw
        $script:Bat   = Get-Content (Join-Path $root 'AXE.bat') -Raw
    }

    It 'GUI parameters expose only internal broker switches' {
        $script:Header | Should -Match '\[switch\]\$BrokerServer'
        $script:Header | Should -Match '\[string\]\$BrokerPipeName'
        $script:Header | Should -Match '\[string\]\$BrokerNonce'
    }

    It 'broker entrypoint runs after the broker definition and before GUI bootstrap' {
        $script:Entry | Should -Match 'if\(\$BrokerServer\)'
        $script:Entry | Should -Match 'BrokerServer requiere -BrokerPipeName y -BrokerNonce'
        $script:Entry | Should -Match 'Start-AXEBrokerServer -PipeName \$BrokerPipeName -ExpectedNonce \$BrokerNonce'
        $script:Entry | Should -Match 'exit 0'
    }

    It 'broker uses a client connection for one-shot request/response IPC' {
        $script:Broker | Should -Match 'NamedPipeServerStream'
        $script:Broker | Should -Match 'NamedPipeClientStream'
        $script:Broker | Should -Match 'WriteLine.*ConvertTo-Json'
        $script:Broker | Should -Match 'ReadLineAsync'
        $script:Broker | Should -Match 'Wait\(15000\)'
    }

    It 'broker has a closed allow-list and bounded payload' {
        $script:Broker | Should -Match "'tweaks\.apply'"
        $script:Broker | Should -Match "'tweaks\.revert'"
        $script:Broker | Should -Match "'tweaks\.masterRevert'"
        $script:Broker | Should -Match "'fps\.capture'"
        $script:Broker | Should -Match '\$script:AXEBrokerMaxJsonBytes = 32768'
        $script:Broker | Should -Match 'nonce.*ExpectedNonce'
        $script:Broker | Should -Match 'cmd no permitido'
        $script:Broker | Should -Match 'ExecutionPolicy AllSigned'
    }

    It 'broker IPC is user-scoped' {
        $script:Broker | Should -Match 'PipeAccessRule'
        $script:Broker | Should -Match 'WindowsIdentity\]::GetCurrent\(\)\.User\.Value'
    }

    It 'broker validates command-specific argument shapes' {
        $script:Broker | Should -Match 'forma invalida para tweaks\.apply'
        $script:Broker | Should -Match 'forma invalida para tweaks\.revert'
        $script:Broker | Should -Match 'forma invalida para tweaks\.masterRevert'
        $script:Broker | Should -Match 'forma invalida para fps\.capture'
        $script:Broker | Should -Match 'nombre de pipe invalido'
    }

    It 'bridge routes privileged operations to the broker when GUI is unelevated' {
        $script:Bridge | Should -Match "'tweaks\.apply'"
        $script:Bridge | Should -Match "'tweaks\.revert'"
        $script:Bridge | Should -Match "'tweaks\.masterRevert'"
        $script:Bridge | Should -Match "'fps\.capture'"
        $script:Bridge | Should -Match 'Invoke-AXEPrivilegedBroker'
        $script:Bridge | Should -Match 'if\(Test-Admin\)'
    }

    It 'GUI launcher does not auto-elevate the no-argument path' {
        $script:Bat | Should -Match 'set "AXEARGS=%\*"'
        $script:Bat | Should -Match 'if not "%AXEARGS%"=="" \('
        $script:Bat | Should -Match 'net session >nul 2>&1'
        $script:Bat | Should -Match 'if "%AXEARGS%"=="" \('
        $script:Bat | Should -Match 'GUI sin privilegios'
    }
}
