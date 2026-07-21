# =====================================================
# REGION 12b - WEBVIEW2: DETECCION (runtime + SDK + rutas de assets)
# =====================================================
# Va ANTES de 45-cli a proposito: el bloque -SelfTest de 45-cli hace 'exit' antes de que
# carguen los modulos 47+ (host) y 50+ (GUI vieja). Para que el SelfTest pueda comprobar la
# deteccion (S27) y los assets (S26), estas funciones puras (solo registro + Test-Path) tienen
# que estar definidas aqui. El HOST (ventana WPF + control WebView2) vive en 47-webhost (Fase 1).
# Cargar este modulo SOLO define funciones/vars; nada se ejecuta.

# $AXERoot en runtime = la carpeta del .ps1 que corre. El build produce dist\AXE.ps1, asi que
# AXERoot = ...\AXE\dist, pero webui/ y webview2/ viven en ...\AXE (el padre). AXEHome resuelve
# ambos casos: assets al lado del script, o un nivel arriba (dist).
$script:AXEHome = $script:AXERoot
if(-not (Test-Path (Join-Path $script:AXEHome 'webui'))){
    $parent = Split-Path $script:AXERoot -Parent
    if($parent -and (Test-Path (Join-Path $parent 'webui'))){ $script:AXEHome = $parent }
}
$script:WebUIDir    = Join-Path $script:AXEHome 'webui'
$script:WebView2Sdk = Join-Path $script:AXEHome 'webview2'

function Get-AXEWebView2SdkPath {
    # Los DLL del SDK se vendorizan en AXE/webview2/ (no se descargan en runtime).
    if(Test-Path (Join-Path $script:WebView2Sdk 'Microsoft.Web.WebView2.Wpf.dll')){ return $script:WebView2Sdk }
    return $null
}

function Get-AXEWebView2Runtime {
    # El runtime Evergreen registra su version en EdgeUpdate\Clients\{GUID}. Presente por defecto
    # en Win11; en Win10 puede faltar => Available=$false y la carcasa mostrara un mensaje con enlace.
    $paths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    )
    foreach($p in $paths){
        try {
            $v = (Get-ItemProperty -Path $p -Name pv -ErrorAction Stop).pv
            if($v -and $v -ne '0.0.0.0'){ return [pscustomobject]@{ Available=$true; Version=$v; Reason='' } }
        } catch {}
    }
    return [pscustomobject]@{ Available=$false; Version=$null; Reason='Runtime WebView2 Evergreen no encontrado. Instalalo desde https://developer.microsoft.com/microsoft-edge/webview2/' }
}
