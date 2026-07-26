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

function Get-AXEWindowFit {
    # PURA. (area util del escritorio, tamano deseado) -> tamano que CABE de verdad.
    #
    # El bug que arregla: la ventana venia fijada a 1200x840 con MinHeight=720. Width/Height de WPF
    # van en DIP (1/96") y el area util TAMBIEN (SystemParameters.WorkArea), asi que a mas escalado
    # de Windows hay MENOS DIP disponibles, no los mismos. Con la pantalla de referencia -1920x1080
    # al 125%- el area util son 1536x816 DIP: la ventana nacia 24 DIP mas alta que el escritorio.
    # Al 150% son 1280x680 DIP y ni el MINIMO cabia, o sea que no habia forma de encogerla hasta
    # que entrase: el borde inferior se quedaba debajo de la barra de tareas para siempre.
    #   La correccion no toca DPI ni manifiestos: basta con recortar en la MISMA unidad en la que
    # WPF coloca la ventana. Comparar DIP con DIP hace que el escalado deje de importar.
    param(
        [double]$WorkWidth,  [double]$WorkHeight,
        [double]$WantWidth  = 1200, [double]$WantHeight = 840,
        [double]$FloorWidth = 820,  [double]$FloorHeight = 520,
        [double]$Slack      = 24
    )
    # Area util ilegible (0, negativa o NaN): se devuelve lo deseado tal cual. Inventar un tamano a
    # partir de un dato que no tenemos seria peor que dejar el de siempre.
    $bad = [double]::IsNaN($WorkWidth) -or [double]::IsNaN($WorkHeight) -or $WorkWidth -le 0 -or $WorkHeight -le 0
    if($bad){
        return [pscustomobject]@{
            Width=$WantWidth; Height=$WantHeight; MinWidth=$FloorWidth; MinHeight=$FloorHeight
            Clamped=$false; Reason='no pude leer el area util del escritorio; se usa el tamano por defecto.'
        }
    }
    # El hueco (Slack) evita que la ventana nazca pegada a los bordes. En pantallas diminutas se
    # cede antes que dejar la ventana sin area: el suelo duro es 320x240.
    $availW = [math]::Max(320, $WorkWidth  - $Slack)
    $availH = [math]::Max(240, $WorkHeight - $Slack)
    $w = [math]::Min($WantWidth,  $availW)
    $h = [math]::Min($WantHeight, $availH)
    # El MINIMO se recorta al tamano real, nunca al reves. Un MinHeight mayor que la pantalla es
    # justo el defecto que hacia imposible encoger la ventana; asi no puede volver por construccion.
    $minW = [math]::Min($FloorWidth,  $w)
    $minH = [math]::Min($FloorHeight, $h)
    $clamped = ($w -lt $WantWidth) -or ($h -lt $WantHeight)
    [pscustomobject]@{
        Width=$w; Height=$h; MinWidth=$minW; MinHeight=$minH; Clamped=$clamped
        Reason=$(if($clamped){
            'ventana ajustada a {0}x{1} DIP: el escritorio util son {2}x{3} DIP (escalado de Windows ya incluido).' -f [int]$w,[int]$h,[int]$WorkWidth,[int]$WorkHeight
        } else { $null })
    }
}

# --- Zoom de la interfaz, persistente -------------------------------------------------------
# Ctrl+rueda y Ctrl+/- ya funcionan (WebView2 los trae de serie), pero el nivel se perdia al
# cerrar. Es la otra mitad de "que la escala se ajuste": el recorte de ventana hace que la
# interfaz QUEPA, el zoom decide CUANTA interfaz cabe dentro. Vive aqui y no en 47-webhost
# porque 47 no se puede dot-sourcear en tests (abre ventana) y estas dos si tienen que estarlo.
$script:AXEUIZoomMin = 0.6
$script:AXEUIZoomMax = 2.0

function Get-AXEUIPrefsPath {
    # Sin $script:AXEData (motor cargado suelto) devuelve $null: el llamante degrada a 1.0.
    if([string]::IsNullOrWhiteSpace($script:AXEData)){ return $null }
    Join-Path $script:AXEData 'ui.json'
}

function Test-AXEUIZoom {
    # PURA. Un zoom vale si es un numero real dentro del rango util. Fuera de el la interfaz o no
    # se lee o no cabe, asi que se rechaza en vez de guardarse y estropear el proximo arranque.
    param($Zoom)
    if($null -eq $Zoom){ return $false }
    $d = 0.0
    if($Zoom -is [double] -or $Zoom -is [single] -or $Zoom -is [int] -or $Zoom -is [long] -or $Zoom -is [decimal]){
        $d = [double]$Zoom
    } else {
        # TryParse con la CULTURA DEL SISTEMA es una trampa, y se comio este proyecto en la primera
        # ejecucion: en es-ES (y de-DE, fr-FR...) el punto es separador de MILES, asi que '1.5'
        # parseaba como 15, quedaba fuera de rango y el zoom se rechazaba en silencio. En un Windows
        # en ingles habria pasado inadvertido hasta que lo usara alguien fuera de EEUU.
        #   JSON es invariante por definicion, y el valor viaja por JSON: se parsea invariante.
        if(-not [double]::TryParse([string]$Zoom, [System.Globalization.NumberStyles]::Float,
                                   [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)){ return $false }
    }
    if([double]::IsNaN($d) -or [double]::IsInfinity($d)){ return $false }
    ($d -ge $script:AXEUIZoomMin) -and ($d -le $script:AXEUIZoomMax)
}

function Get-AXEUIZoom {
    # Zoom guardado o 1.0. Ausente, ilegible, corrupto o fuera de rango -> 1.0. NUNCA lanza: un
    # fichero de preferencias roto no puede ser el motivo de que la ventana no abra.
    $p = Get-AXEUIPrefsPath
    if(-not $p -or -not (Test-Path $p)){ return 1.0 }
    try {
        $doc = (Get-Content $p -Raw -Encoding UTF8 -EA Stop) | ConvertFrom-Json -EA Stop
        $z = $doc.zoom
        if(Test-AXEUIZoom $z){ return [double]$z }
    } catch {}
    1.0
}

function Set-AXEUIZoom {
    # Guarda el zoom. Devuelve $true solo si quedo escrito: el llamante no tiene que adivinarlo.
    param($Zoom)
    if(-not (Test-AXEUIZoom $Zoom)){ return $false }
    $p = Get-AXEUIPrefsPath
    if(-not $p){ return $false }
    try {
        $dir = Split-Path $p -Parent
        if($dir -and -not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force -EA Stop | Out-Null }
        Set-Content -Path $p -Value (ConvertTo-Json -InputObject ([pscustomobject]@{ zoom=[double]$Zoom }) -Depth 2) -Encoding UTF8 -EA Stop
        return $true
    } catch { return $false }
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
