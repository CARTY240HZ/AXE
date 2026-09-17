# Unit — static security contracts for the WebView2/native boundary.
# These tests never launch WebView2 and never modify the host.

Describe 'WebView2 security contracts' -Tag 'unit','security' {
    BeforeAll {
        $host = Get-Content "$PSScriptRoot/../src/47b-websecurity.ps1" -Raw
        $rpc  = Get-Content "$PSScriptRoot/../src/48b-bridge-security.ps1" -Raw
        $js   = Get-Content "$PSScriptRoot/../webui/bridge.js" -Raw
        $html = Get-Content "$PSScriptRoot/../webui/index.html" -Raw
    }

    It 'WebView2 policy disables host objects and external navigation' {
        $host | Should -Match 'AreHostObjectsAllowed\s*=\s*\$false'
        $host | Should -Match 'Add_NavigationStarting'
        $host | Should -Match 'Add_FrameNavigationStarting'
        $host | Should -Match 'Add_NewWindowRequested'
        $host | Should -Match "Scheme -eq 'https'"
        $host | Should -Match "Host -eq 'axe.local'"
    }

    It 'native RPC checks the trusted local origin and bounds payloads' {
        $rpc | Should -Match "src\.Scheme -ne 'https'"
        $rpc | Should -Match "src\.Host -ne 'axe\.local'"
        $rpc | Should -Match 'cmd\.Length -gt 64'
        $rpc | Should -Match 'Count -gt 32'
        $rpc | Should -Match 'Depth -gt 6'
        $rpc | Should -Match 'Length -le 4096'
        $rpc | Should -Match 'origen web no confiable'
    }

    It 'frontend uses an explicit RPC command allowlist' {
        $js | Should -Match "const ALLOWED = new Set"
        $js | Should -Match "ALLOWED\.has\(cmd\)"
        $js | Should -Match 'Object\.freeze\(\{ call, on \}\)'
    }

    It 'frontend CSP denies network connections and form/base escapes' {
        $html | Should -Match "connect-src 'none'"
        $html | Should -Match "base-uri 'none'"
        $html | Should -Match "form-action 'none'"
    }
}
