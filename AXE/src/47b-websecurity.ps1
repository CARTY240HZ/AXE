# =====================================================
# REGION 13b - WEBVIEW2 SECURITY HARDENING
#
# Defense-in-depth for the elevated WPF/WebView2 host.
# The UI is local content only: https://axe.local/*.
# No generic external navigation, host objects, dialogs or new-window paths are allowed.
#
# This module does not change business logic. It waits for CoreWebView2 to exist and then
# applies the security policy once. The timer is intentionally tiny and stops immediately
# after the control is protected.
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
        # DevTools remain opt-in for an explicitly debugged local session; production is closed.
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
            try { Write-AXELog "WebView2: ventana nueva bloqueada" 'WARN' } catch {}
        })
        $true
    } catch {
        try { Write-AXELog "WebView2 security policy no pudo aplicarse: $($_.Exception.Message)" 'ERR' } catch {}
        $false
    }
}

# Show-AXEWebHost crea CoreWebView2 dentro de un evento Loaded/InitializationCompleted.
# Este timer evita tocar la lógica existente y aplica la política en el primer tick de UI.
if(-not $script:AXEWebSecurityTimer){
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
}
