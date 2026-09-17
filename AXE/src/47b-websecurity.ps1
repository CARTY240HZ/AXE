# =====================================================
# REGION 13b - WEBVIEW2 SECURITY HARDENING
#
# Defense-in-depth for the elevated WPF/WebView2 host.
# The UI is local content only: https://axe.local/*.
# No generic external navigation, host objects, dialogs or new-window paths are allowed.
#
# This module defines the policy and a GUI-only watcher. It deliberately does NOT instantiate
# WPF/DispatcherTimer objects while the engine is being loaded headlessly by tests/builds.
# 49-webmain starts the watcher on the STA GUI path.
# =====================================================

function Protect-AXEWebView2 {
    param([Parameter(Mandatory)]$Core)

    if(-not $Core){ return $false }
    try {
        $settings = $Core.Settings
        $settings.AreHostObjectsAllowed = $false
        $settings.AreDefaultScriptDialogsEnabled = $false
        $settings.IsStatusBarEnabled = $false
        $settings.IsWebMessageEnabled = $true
        if($env:AXE_WEBUI_DEBUG -ne '1'){ $settings.AreDevToolsEnabled = $false }

        $Core.Add_NavigationStarting({
            param($sender,$args)
            $uri = $null
            try { $uri = [Uri]$args.Uri } catch {}
            $ok = $false
            if($uri){
                $ok = ($uri.Scheme -eq 'https' -and $uri.Host -eq 'axe.local' -and
                       ($uri.Port -eq -1 -or $uri.Port -eq 443))
            }
            if(-not $ok){
                $args.Cancel = $true
                try { Write-AXELog "WebView2: navegacion bloqueada a '$($args.Uri)'" 'WARN' } catch {}
            }
        })

        $Core.Add_FrameNavigationStarting({
            param($sender,$args)
            $uri = $null
            try { $uri = [Uri]$args.Uri } catch {}
            $ok = $false
            if($uri){
                $ok = ($uri.Scheme -eq 'https' -and $uri.Host -eq 'axe.local' -and
                       ($uri.Port -eq -1 -or $uri.Port -eq 443))
            }
            if(-not $ok){
                $args.Cancel = $true
                try { Write-AXELog "WebView2: frame bloqueado a '$($args.Uri)'" 'WARN' } catch {}
            }
        })

        $Core.Add_NewWindowRequested({
            param($sender,$args)
            $args.Handled = $true
            try { Write-AXELog 'WebView2: ventana nueva bloqueada' 'WARN' } catch {}
        })
        $true
    } catch {
        try { Write-AXELog "WebView2 security policy no pudo aplicarse: $($_.Exception.Message)" 'ERR' } catch {}
        $false
    }
}

function Start-AXEWebSecurityWatcher {
    if($env:AXE_WEBUI_TEST -eq '1'){ return }
    if($script:AXEWebSecurityTimer){ return }
    try {
        $script:AXEWebSecurityTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:AXEWebSecurityTimer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:AXEWebSecurityTimer.Add_Tick({
            try {
                if($script:Web -and $script:Web.CoreWebView2){
                    if(Protect-AXEWebView2 -Core $script:Web.CoreWebView2){
                        $script:AXEWebSecurityTimer.Stop()
                        $script:AXEWebSecurityApplied = $true
                    }
                }
            } catch {}
        })
        $script:AXEWebSecurityTimer.Start()
    } catch {
        try { Write-AXELog "WebView2 security watcher no pudo arrancar: $($_.Exception.Message)" 'ERR' } catch {}
    }
}
