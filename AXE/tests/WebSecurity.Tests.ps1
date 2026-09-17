# Unit — static security contracts for the WebView2/native boundary.
# These tests never launch WebView2 and never modify the host.

Describe 'WebView2 security contracts' -Tag 'unit','security' {
    BeforeAll {
        $hostSource = Get-Content "$PSScriptRoot/../src/47b-websecurity.ps1" -Raw
        $rpcSource  = Get-Content "$PSScriptRoot/../src/48b-bridge-security.ps1" -Raw
        $jsSource   = Get-Content "$PSScriptRoot/../webui/bridge.js" -Raw
        $htmlSource = Get-Content "$PSScriptRoot/../webui/index.html" -Raw
    }

    It 'WebView2 policy disables host objects and external navigation' {
        $hostSource | Should -Match 'AreHostObjectsAllowed\s*=\s*\$false'
        $hostSource | Should -Match 'Add_NavigationStarting'
        $hostSource | Should -Match 'Add_FrameNavigationStarting'
        $hostSource | Should -Match 'Add_NewWindowRequested'
        $hostSource | Should -Match "Scheme -eq 'https'"
        $hostSource | Should -Match "Host -eq 'axe.local'"
    }

    It 'native RPC checks the trusted local origin and bounds payloads' {
        $rpcSource | Should -Match "src\.Scheme -ne 'https'"
        $rpcSource | Should -Match "src\.Host -ne 'axe\.local'"
        $rpcSource | Should -Match 'cmd\.Length -gt 64'
        $rpcSource | Should -Match 'Count -gt 32'
        $rpcSource | Should -Match 'Depth -gt 6'
        $rpcSource | Should -Match 'Length -le 4096'
        $rpcSource | Should -Match 'origen web no confiable'
    }

    It 'frontend uses an explicit RPC command allowlist' {
        $jsSource | Should -Match "const ALLOWED = new Set"
        $jsSource | Should -Match "ALLOWED\.has\(cmd\)"
        $jsSource | Should -Match 'Object\.freeze\(\{ call, on \}\)'
    }

    It 'frontend CSP denies network connections and form/base escapes' {
        $htmlSource | Should -Match "connect-src 'none'"
        $htmlSource | Should -Match "base-uri 'none'"
        $htmlSource | Should -Match "form-action 'none'"
    }
}
