# =====================================================
# REGION 13 - WEBVIEW2 HOST (carcasa WPF fina)
# =====================================================
# Aloja UN control WebView2 a pantalla completa. Toda la UI vive en web (webui/).
# La deteccion (runtime + SDK + rutas) esta en 39-webdetect. Aqui solo el HOST.
# Unico frontend desde el cutover (Fase 8): la GUI WPF vieja (50-60, 99) se retiro. El arranque
# (bootstrap) vive en 49-webmain, que carga tras 48 para que Register-AXEBridge exista al invocarlo.

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

    # WebView2Loader.dll (nativo): precargarlo por RUTA ABSOLUTA antes de CreateAsync. El Core.dll
    # lo carga con busqueda "segura" (LOAD_LIBRARY_SEARCH_*), que IGNORA PATH y CWD; por eso ni
    # prepender PATH ni el CWD bastan, y da 0x8007007E ERROR_MOD_NOT_FOUND. Si ya esta cargado en el
    # proceso por ruta completa, el LoadLibrary("WebView2Loader.dll") posterior del SDK resuelve al
    # modulo ya presente (match por nombre base). LoadLibrary (kernel32) via P/Invoke funciona en
    # PS 5.1 y 7. MemberDefinition en una sola linea: evita here-strings que el build concatena mal.
    $rid = if($env:PROCESSOR_ARCHITECTURE -match 'ARM64'){ 'win-arm64' } else { 'win-x64' }
    $nativeDir  = Join-Path $sdk (Join-Path 'runtimes' (Join-Path $rid 'native'))
    $loaderPath = Join-Path $nativeDir 'WebView2Loader.dll'
    if(Test-Path $loaderPath){
        if(-not ('AXE.NativeLoad' -as [type])){
            Add-Type -Namespace AXE -Name NativeLoad -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)] public static extern System.IntPtr LoadLibrary(string lpFileName);' -ErrorAction SilentlyContinue
        }
        $h = [IntPtr]::Zero
        try { $h = [AXE.NativeLoad]::LoadLibrary($loaderPath) } catch {}
        if($h -eq [IntPtr]::Zero){ Write-AXELog "No pude precargar WebView2Loader.dll ($loaderPath)" 'WARN' }
    } else {
        Write-AXELog "WebView2Loader.dll ausente en $nativeDir (arch $rid)" 'WARN'
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
        Register-AXEBridge $core   # Fase 2: define el despacho JS->PS (48-webbridge).
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
        # Sesion de juego activa: cerrarla AQUI. Lo CONGELADO lo descongela el kernel al morir el
        # proceso -esa es la garantia del diseño-, pero la prioridad de lo DEGRADADO no es estado del
        # job y el kernel no la devuelve: sin esto, cerrar la ventana dejaba el navegador en
        # BelowNormal hasta reiniciarlo. La salida sucia (kill/BSOD) la cubre el diario en disco.
        if(Get-Command Get-AXESessionCurrent -EA SilentlyContinue){
            try { if(Get-AXESessionCurrent){ [void](Stop-AXESessionTracked -Reason 'AXE se cerro.') } } catch {}
        }
    })

    if($env:AXE_WEBUI_TEST -eq '1'){ Write-Host 'WEBHOST OK'; return }
    [void]$win.ShowDialog()
}

# El arranque (bootstrap) vive en 49-webmain.ps1, que carga DESPUES de 48-webbridge, para que
# Register-AXEBridge (48) este definido cuando Show-AXEWebHost lo invoque. Si el arranque viviera
# aqui, su 'exit 0' cortaria la carga antes de 48 y el puente quedaria sin enganchar (JS->PS muerto).
