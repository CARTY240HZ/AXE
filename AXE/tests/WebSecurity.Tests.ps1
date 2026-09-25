# Pester de la politica de origen de la WebView2 (48a-websecurity). No abre ventana: las funciones de
# decision son puras y el cableado (que el host la aplique y el puente la consulte) se fija por fuente.
BeforeAll {
    . "$PSScriptRoot/_load-engine.ps1"
}

Describe 'Test-AXETrustedWebUri: solo la interfaz propia' -Tag 'unit','security' {
    It 'acepta <_>' -ForEach @('https://axe.local/index.html', 'https://axe.local/', 'https://AXE.local/app.js', 'https://axe.local:443/x') {
        Test-AXETrustedWebUri $_ | Should -BeTrue
    }
    It 'rechaza <_>' -ForEach @(
        'http://axe.local/index.html', 'https://axe.local:8443/', 'https://axe.local.evil.com/',
        'https://evil.com/?axe.local', 'file:///C:/AXE/webui/index.html', 'data:text/html,hola',
        'about:blank', '', 'no es una uri'
    ) {
        Test-AXETrustedWebUri $_ | Should -BeFalse
    }
}

Describe 'Test-AXEExternalLinkUri: que puede ir al navegador del sistema' -Tag 'unit','security' {
    It 'deja salir un https externo (enlace de fuente)' {
        Test-AXEExternalLinkUri 'https://learn.microsoft.com/windows/' | Should -BeTrue
    }
    It 'no deja salir <_>' -ForEach @(
        'http://example.com/', 'file:///C:/Windows/System32/calc.exe', 'ms-settings:privacy',
        'javascript:alert(1)', 'https://axe.local/index.html', ''
    ) {
        Test-AXEExternalLinkUri $_ | Should -BeFalse
    }
}

Describe 'Cableado de la politica' -Tag 'unit','security' {
    BeforeAll {
        $script:secSrc    = Get-Content "$PSScriptRoot/../src/48a-websecurity.ps1" -Raw
        $script:hostSrc   = Get-Content "$PSScriptRoot/../src/47-webhost.ps1" -Raw
        $script:bridgeSrc = Get-Content "$PSScriptRoot/../src/48-webbridge.ps1" -Raw
    }
    It 'bloquea navegacion, frames y ventanas nuevas' {
        $script:secSrc | Should -Match 'Add_NavigationStarting'
        $script:secSrc | Should -Match 'Add_FrameNavigationStarting'
        $script:secSrc | Should -Match 'Add_NewWindowRequested'
        $script:secSrc | Should -Match 'AreHostObjectsAllowed\s*=\s*\$false'
    }
    It 'el host la aplica ANTES de registrar el puente y falla cerrado' {
        $iProtect  = $script:hostSrc.IndexOf('Protect-AXEWebView2 $core')
        $iRegister = $script:hostSrc.IndexOf('Register-AXEBridge $core')
        $iProtect  | Should -BeGreaterThan 0
        $iProtect  | Should -BeLessThan $iRegister
        $script:hostSrc | Should -Match 'if\(-not \(Protect-AXEWebView2 \$core\)\)'
    }
    It 'el puente descarta mensajes de otro origen' {
        $script:bridgeSrc | Should -Match 'Test-AXETrustedWebUri \(\[string\]\$e\.Source\)'
    }
    It 'la telemetria no usa TickCount64 (no existe en Windows PowerShell 5.1)' {
        $code = @($script:bridgeSrc -split "`r?`n" | Where-Object { $_ -notmatch '^\s*#' })
        ($code -match 'TickCount64') | Should -BeNullOrEmpty
    }
}
