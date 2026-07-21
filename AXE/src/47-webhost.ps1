# =====================================================
# REGION 13 - WEBVIEW2 HOST (carcasa WPF fina)
# =====================================================
# Aloja UN control WebView2 a pantalla completa. Toda la UI vive en web (webui/).
# La deteccion (runtime + SDK + rutas) esta en 39-webdetect. Aqui solo el HOST.
# Detras del flag AXE_WEBUI=1 hasta el cutover (Fase 8); sin el, arranca la GUI WPF vieja (50-60).

function Show-AXEWebHost {
    # Guard STA (WPF lo exige; el .bat pasa -STA, esto cubre run directo).
    if($env:AXE_WEBUI_TEST -ne '1' -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){
        Write-Host 'WebView2/WPF requiere STA. Relanza via AXE.bat.'; return
    }
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    $sdk = Get-AXEWebView2SdkPath
    if(-not $sdk){ [System.Windows.MessageBox]::Show('Faltan los DLL de WebView2 (AXE/webview2/). Reinstala AXE.','AXE','OK','Error') | Out-Null; return }
    # Orden de carga: Core antes que Wpf. El nativo WebView2Loader.dll lo resuelve el runtime
    # desde runtimes\win-x64\native. Add-Type idempotente (si ya cargo en esta sesion, no repite).
    try {
        Add-Type -Path (Join-Path $sdk 'Microsoft.Web.WebView2.Core.dll') -EA Stop
        Add-Type -Path (Join-Path $sdk 'Microsoft.Web.WebView2.Wpf.dll')  -EA Stop
    } catch {
        Write-AXELog "No pude cargar los DLL de WebView2: $($_.Exception.Message)" 'ERR'
        [System.Windows.MessageBox]::Show("No pude cargar WebView2:`n$($_.Exception.Message)",'AXE','OK','Error') | Out-Null
        return
    }

    $rt  = Get-AXEWebView2Runtime
    $bc  = New-Object System.Windows.Media.BrushConverter
    $win = New-Object System.Windows.Window
    $win.Title='AXE'; $win.Width=1200; $win.Height=840; $win.MinWidth=1040; $win.MinHeight=720
    $win.WindowStartupLocation='CenterScreen'
    $win.Background=$bc.ConvertFrom('#0E1013')
    $script:WebWin = $win

    if(-not $rt.Available){
        # Runtime ausente: no pantalla en blanco. Mensaje claro con enlace (riesgo #4 del spec).
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text=$rt.Reason; $tb.TextWrapping='Wrap'; $tb.Margin='40'; $tb.FontSize=15
        $tb.Foreground=$bc.ConvertFrom('#E6EAF0')
        $win.Content=$tb
        if($env:AXE_WEBUI_TEST -eq '1'){ Write-Host 'WEBHOST OK (sin runtime, mensaje mostrado)'; return }
        [void]$win.ShowDialog(); return
    }

    $web = New-Object Microsoft.Web.WebView2.Wpf.WebView2
    $script:Web = $web
    $win.Content = $web

    # user data folder fuera de Archivos de programa (powershell.exe corre desde System32, sin
    # permiso de escritura). Se pasa explicito a CreateAsync en Loaded (el env var no se honra).
    $udf = Join-Path $env:LOCALAPPDATA 'AXE\WebView2'
    if(-not (Test-Path $udf)){ New-Item -ItemType Directory -Path $udf -Force | Out-Null }
    $script:Udf = $udf

    # Init asincrono: suscribir el evento ANTES de EnsureCoreWebView2Async. Cuando complete,
    # mapear el host virtual y navegar.
    $web.Add_CoreWebView2InitializationCompleted({
        param($s,$e)
        if(-not $e.IsSuccess){ Write-AXELog "WebView2 init fallo: $($e.InitializationException)" 'ERR'; return }
        $core = $s.CoreWebView2
        # host virtual -> carpeta local, solo lectura (Deny cross-origin).
        $core.SetVirtualHostNameToFolderMapping('axe.local', $script:WebUIDir, 'Deny')
        if($env:AXE_WEBUI_DEBUG -ne '1'){
            $core.Settings.AreDefaultContextMenusEnabled = $false
            $core.Settings.AreDevToolsEnabled = $false
        }
        $core.Settings.IsStatusBarEnabled = $false
        Register-AXEBridge $core   # Fase 2: stub defensivo hasta que exista 48-webbridge.
        $s.Source = [uri]'https://axe.local/index.html'
    })
    # En Loaded (dispatcher YA corriendo tras ShowDialog): crear el entorno con NUESTRO user-data
    # folder y luego el controlador. Pasar $null como entorno hace que WebView2 use la carpeta por
    # defecto (junto a powershell.exe en System32, sin permiso) => COMException E_UNEXPECTED en
    # CreateCoreWebView2ControllerAsync. CreateAsync corre en el threadpool (no necesita el hilo UI),
    # asi que GetResult() no deadlockea; EnsureCoreWebView2Async con el entorno ya hecho crea el
    # controlador en el hilo UI con el loop vivo. En AXE_WEBUI_TEST no hay ShowDialog => Loaded no
    # dispara: el smoke test solo valida que carcasa+control se construyen.
    $win.Add_Loaded({
        try {
            $cwEnv = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $script:Udf, $null).GetAwaiter().GetResult()
            $script:Web.EnsureCoreWebView2Async($cwEnv) | Out-Null
        } catch { Write-AXELog "WebView2 entorno/init fallo: $($_.Exception.Message)" 'ERR' }
    })

    # Liberar timers/runspaces de telemetria al cerrar (definidos en Fase 3/5; defensivo aqui).
    $win.Add_Closed({
        if($script:TelemetryTimer){ try { $script:TelemetryTimer.Stop() } catch {} }
        if($script:TelemPS){ try { $script:TelemPS.Stop() } catch {}; try { $script:TelemPS.Dispose() } catch {} }
        if($script:TelemRS){ try { $script:TelemRS.Close() } catch {} }
    })

    if($env:AXE_WEBUI_TEST -eq '1'){ Write-Host 'WEBHOST OK'; return }
    [void]$win.ShowDialog()
}

# Register-AXEBridge se define en 48-webbridge.ps1 (Fase 2). Stub defensivo por si aun no existe.
if(-not (Get-Command Register-AXEBridge -EA SilentlyContinue)){
    function Register-AXEBridge($core){ }
}

# Arranque del host web. Solo en modo GUI (sin args CLI, que ya hicieron 'exit' en 45-cli) y con
# el flag activo. En el cutover (Fase 8) el flag desaparece y esto pasa a ser incondicional.
if($env:AXE_WEBUI -eq '1' -and $env:AXE_GUITEST -ne '1' -and $env:AXE_GUISHOW -ne '1'){
    Show-AXEWebHost
    exit 0   # no seguir al bloque GUI viejo 50-60 ni a 99-main.
}
