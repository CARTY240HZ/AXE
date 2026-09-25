# =====================================================
# REGION 14a - POLITICA DE ORIGEN DE LA WEBVIEW2
# =====================================================
# La interfaz es contenido local: https://axe.local/*. Nada mas navega dentro de la ventana ni
# habla con el puente. Portado de la rama ai/least-privilege-broker (47b-websecurity), que nunca
# llego a axe, con dos cambios: se aplica en el init del control (47-webhost) en vez de con un
# temporizador que sondeaba, y los enlaces "fuente" de cada tweak se abren en el navegador del
# sistema en vez de bloquearse (son parte del producto: cada tweak cita de donde sale).
# Cargar este modulo solo DEFINE funciones; no toca WPF, asi que _load-engine lo carga en tests.

function Test-AXETrustedWebUri([string]$Uri){
    # PURA. Solo https://axe.local (puerto por defecto). Cualquier otra cosa -otro host, http,
    # file:, data:, un puerto distinto- no es la interfaz de AXE.
    $u = $null
    if(-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$u)){ return $false }
    $u.Scheme -eq 'https' -and $u.Host -eq 'axe.local' -and $u.IsDefaultPort
}

function Test-AXEExternalLinkUri([string]$Uri){
    # PURA. Que se puede mandar al navegador del sistema: solo https y nunca la propia interfaz.
    # Nada de file:, ms-settings:, javascript: ni esquemas que Windows resolveria a un programa.
    $u = $null
    if(-not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$u)){ return $false }
    $u.Scheme -eq 'https' -and -not (Test-AXETrustedWebUri $Uri)
}

function Protect-AXEWebView2($Core){
    # Endurece un CoreWebView2 ya inicializado. Devuelve $true si la politica quedo aplicada.
    try {
        $Core.Settings.AreHostObjectsAllowed = $false
        $Core.Settings.AreDefaultScriptDialogsEnabled = $false
        $Core.Add_NavigationStarting({
            param($s,$e)
            if(-not (Test-AXETrustedWebUri $e.Uri)){
                $e.Cancel = $true
                try { Write-AXELog "WebView2: navegacion bloqueada a '$($e.Uri)'" 'WARN' } catch {}
            }
        })
        $Core.Add_FrameNavigationStarting({
            param($s,$e)
            if(-not (Test-AXETrustedWebUri $e.Uri)){
                $e.Cancel = $true
                try { Write-AXELog "WebView2: frame bloqueado a '$($e.Uri)'" 'WARN' } catch {}
            }
        })
        # target=_blank: nunca una ventana WebView2 nueva (seria un navegador sin barra de direcciones
        # pegado a la app). Un https externo va al navegador del sistema; el resto se descarta.
        $Core.Add_NewWindowRequested({
            param($s,$e)
            $e.Handled = $true
            if(Test-AXEExternalLinkUri $e.Uri){
                try { Start-Process ([string]([Uri]$e.Uri).AbsoluteUri) } catch { try { Write-AXELog "WebView2: no pude abrir '$($e.Uri)': $($_.Exception.Message)" 'WARN' } catch {} }
            } else {
                try { Write-AXELog "WebView2: ventana nueva bloqueada a '$($e.Uri)'" 'WARN' } catch {}
            }
        })
        $true
    } catch {
        try { Write-AXELog "WebView2: la politica de seguridad no pudo aplicarse: $($_.Exception.Message)" 'ERR' } catch {}
        $false
    }
}
