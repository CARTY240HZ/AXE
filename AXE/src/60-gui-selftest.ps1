# ---- 12.16 GUITEST: assert + render PNG, sin ShowDialog ----
if($env:AXE_GUITEST -eq '1'){
    Write-Host "== AXE $($script:AXEVersion) WPF - LAYOUT TEST =="
    Write-Host "NAV items         : $($script:navBtns.Count)"
    Write-Host "Vistas tweaks     : $(($script:tweakCats).Count)"
    $allOk=$true

    # Invoke-AXEDoEvents ya NO se define aqui: vive en 52-gui-build.ps1 con el resto de helpers
    # de GUI. Definirla aqui la hacia existir solo durante el harness, asi que un handler que la
    # usara pasaba el gate y fallaba en el primer clic real.

    # regresion A4+A1: init lanza Get-AXEHardware en runspace (la ventana NO espera ~3.7s de
    # CIM). Al llegar HW: chips + gating + Refresh-States async. Todo drena al bombear el
    # dispatcher. Prueba el fix de "tarda mucho en iniciar" end-to-end.
    try {
        $hwAsync=[bool]$script:hwPS
        $dl=(Get-Date).AddSeconds(40); while(($script:hwPS -or $script:refreshing) -and (Get-Date) -lt $dl){ Invoke-AXEDoEvents }
        $hwDone=($null -ne $script:HW)
        $chipsOk=($HwChips.Children.Count -gt 0)
        $refDone=-not $script:refreshing
        $countOk=($CountLbl.Text -match '^\d+/\d+$')
        Write-Host "HW async          : lanzada=$hwAsync HW=$hwDone chips=$chipsOk (esperado True x3)"
        Write-Host "Refresh async     : completo=$refDone count='$($CountLbl.Text)' (esperado True)"
        if(-not ($hwAsync -and $hwDone -and $chipsOk -and $refDone -and $countOk)){ $allOk=$false }
    } catch { Write-Host "HW/Refresh async  : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # regresion A2: Start-AXEJob corre en runspace de fondo y devuelve log (UI no congela)
    try {
        Start-AXEJob -Work { param($x) "JOBTEST $x" } -JobArgs @('OK') -Button $null
        $jobStarted=[bool]$script:jobPS
        $dl=(Get-Date).AddSeconds(10); while($script:jobPS -and (Get-Date) -lt $dl){ Invoke-AXEDoEvents }
        $jobDone = -not $script:jobPS
        Write-Host "Background job    : arranco=$jobStarted termino=$jobDone (esperado True/True)"
        if(-not ($jobStarted -and $jobDone)){ $allOk=$false }
    } catch { Write-Host "Background job    : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # regresion H10: mutex unico. Con $script:busy=$true, Start-AXEJob DEBE rechazar
    # (no arranca runspace) para no mutar el sistema mientras corre APLICAR/MASTER.
    try {
        $script:busy=$true
        Start-AXEJob -Work { 'NO_DEBE_CORRER' } -Button $null
        $refused=(-not $script:jobPS)
        $script:busy=$false
        Write-Host "Job mutex (H10)   : rechazado con busy=$refused (esperado True)"
        if(-not $refused){ $allOk=$false }
    } catch { $script:busy=$false; Write-Host "Job mutex (H10)   : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # regresion A3: Master revert (cola tail extraida). Solo verifica ESTRUCTURA:
    # la funcion tail definida. NO se ejecuta (revertiria los tweaks reales del sistema).
    $mrOk = [bool](Get-Command Invoke-AXEMasterRevertTail -EA SilentlyContinue)
    Write-Host "Master revert     : tail definido=$mrOk (esperado True)"
    if(-not $mrOk){ $allOk=$false }

    # regresion H2: gate de punto de restauracion. Verifica que el query es no-mutante
    # y devuelve bool sin lanzar, y que el scriptblock reutilizable existe.
    $rpFnOk=[bool](Get-Command Test-RecentRestorePoint -EA SilentlyContinue)
    $rpBool=$false; try { $rpBool=((Test-RecentRestorePoint) -is [bool]) } catch {}
    $rpSbOk=($script:doRestorePoint -is [scriptblock])
    Write-Host "RestorePoint gate : fn=$rpFnOk retornaBool=$rpBool scriptblock=$rpSbOk (esperado True x3)"
    if(-not ($rpFnOk -and $rpBool -and $rpSbOk)){ $allOk=$false }

    foreach($catName in $script:tweakCats){
        $rowCount=$script:rows[$catName].Count
        if($rowCount -eq 0){ Write-Host "  FAIL: $catName vacio"; $allOk=$false } else { Write-Host ("  OK: {0,-12} {1} cards" -f $catName,$rowCount) }
    }
    Switch-View 'CPU'
    $vis=@($script:views.Values | Where-Object { $_.Visibility -eq 'Visible' }).Count
    Write-Host "Switch CPU        : vistas visibles=$vis (esperado 1)"
    if($vis -ne 1){ $allOk=$false }
    # forzar construccion de vistas de accion
    foreach($catName in $script:actionCats){ Build-ActionView $catName | Out-Null }
    Write-Host "Vistas accion     : construidas"
    # regresion PERFILES: la vista cablea el toggle de monitor + refresh de lista, y
    # Tick-GameProfiles no lanza sin juego corriendo (debe devolver el perfil activo o null).
    try {
        $pvOk = ($null -ne $script:profMonTog) -and ($script:profRefreshList -is [scriptblock])
        $tickNull = $null; try { $tickNull = Tick-GameProfiles } catch { $pvOk=$false }
        Write-Host "Perfiles view     : toggle+refresh=$pvOk tickActivo='$tickNull' (esperado True/vacio)"
        if(-not $pvOk){ $allOk=$false }
        if($null -ne $tickNull){ $allOk=$false }   # sin juego corriendo no debe activar nada
    } catch { Write-Host "Perfiles view     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion GPU POR JUEGO (region 10c): la misma vista PERFILES cablea el refresh de la
    # lista de ejecutables. Se EJERCE el scriptblock, no solo se comprueba que exista: construir
    # las tarjetas es donde se lee el registro y se parsea la cadena "K=V;", que es lo que se
    # puede romper. Ojo con confiar en el PNG para esto: el render sale en blanco (el bitmap se
    # toma sin pasar por ShowDialog), asi que la unica prueba real de que la seccion se construye
    # es el Build-ActionView de arriba mas este ejercicio. Solo LEE el registro.
    try {
        $gvOk = ($script:gpuRefreshList -is [scriptblock])
        if($gvOk){ & $script:gpuRefreshList }   # si el parser o la lectura del registro revientan, cae al catch
        $hyb = Test-AXEHybridGpu
        Write-Host "GPU-juego view    : refresh=$gvOk hibrida=$hyb gpus=$((Get-AXEGpuList).Count)"
        if(-not $gvOk){ $allOk=$false }
        if($hyb -isnot [bool]){ $allOk=$false }
    } catch { Write-Host "GPU-juego view    : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion PESTANA FPS: existe como vista propia (no enterrada en PERFILES) y trae el
    # cuadro de medicion cableado. Se comprueba la vista Y el control, porque registrar la
    # categoria sin construir nada daria una pestana vacia que igual pasaba el resto de checks.
    try {
        $fpsTabOk = ($script:actionCats -contains 'FPS') -and ($null -ne $script:views['FPS'])
        $fpsUiOk  = ($null -ne $script:fpsOut)
        # Las funciones de la region 10d tienen que estar cargadas antes que la GUI (33 < 55).
        $fpsFnOk  = [bool](Get-Command Measure-AXEFps -EA SilentlyContinue) -and [bool](Get-Command Get-AXEFpsVerdict -EA SilentlyContinue)
        Write-Host "Pestana FPS       : vista=$fpsTabOk salida=$fpsUiOk funciones=$fpsFnOk (esperado True/True/True)"
        if(-not ($fpsTabOk -and $fpsUiOk -and $fpsFnOk)){ $allOk=$false }
    } catch { Write-Host "Pestana FPS       : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion ICONO+SUBTITULO por categoria. Anadir una pestana son TRES sitios: actionCats
    # (52-gui-build), el glyph de $script:glyphs y la rama del subtitulo en Switch-View
    # (57-gui-handlers). FPS se anadio con el primero y sin los otros dos: la pestana salia
    # funcionando pero sin icono en la barra lateral y sin subtitulo en la cabecera, y el gate
    # daba LAYOUT OK igual. Este check cubre la clase entera, no el caso de FPS.
    try {
        $sinIcono = @($script:actionCats | Where-Object { -not $script:glyphs.ContainsKey($_) })
        $sinSub   = @(foreach($c in $script:actionCats){ Switch-View $c; if([string]::IsNullOrWhiteSpace($ContentSub.Text)){ $c } })
        Write-Host "Iconos/subtitulos : sin icono=$($sinIcono.Count) sin subtitulo=$($sinSub.Count) (esperado 0/0)"
        if($sinIcono.Count -gt 0){ Write-Host "  FAIL: categorias sin glyph -> $($sinIcono -join ', ')"; $allOk=$false }
        if($sinSub.Count   -gt 0){ Write-Host "  FAIL: categorias sin subtitulo -> $($sinSub -join ', ')"; $allOk=$false }
        # Glyph REPETIDO entre categorias. REGISTRO llevaba el mismo codepoint que APPS (E71D):
        # dos secciones con el dibujo identico en la barra lateral, que es donde se elige sin
        # leer. Ningun check lo veia porque cada una tenia SU entrada; el fallo era que las dos
        # apuntaban al mismo sitio. Esto NO cubre parecidos visuales entre codepoints distintos
        # (SISTEMA y FPS dibujaban los dos un portatil con codepoints distintos): eso solo se
        # caza mirando la fuente renderizada, y por eso los glyphs se eligen viendolos.
        $dup = @($script:glyphs.GetEnumerator() | Group-Object Value | Where-Object Count -gt 1)
        if($dup.Count -gt 0){
            foreach($d in $dup){ Write-Host ("  FAIL: glyph 0x{0:X4} repetido en -> {1}" -f [int][char]$d.Name,(($d.Group.Name) -join ', ')) }
            $allOk=$false
        }
    } catch { Write-Host "Iconos/subtitulos : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion: ejercer handler ASISTENTE (bug de scope $out/$doAsk null)
    try {
        $before=$script:aiOut.Text.Length
        $script:aiIn.Text='fps'
        & $script:aiDoAsk
        $grew=$script:aiOut.Text.Length -gt $before
        Write-Host "Asistente handler : output crecio=$grew (esperado True)"
        if(-not $grew){ $allOk=$false }
    } catch { Write-Host "Asistente handler : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion MEDICION: la vista construye score label + boton + reporte, y el helper existe
    try {
        Build-ActionView 'MEDICION' | Out-Null
        $measOk = ($null -ne $script:scoreLbl) -and ($null -ne $script:measureBtn) -and ($null -ne $script:measureOut) -and ([bool](Get-Command Invoke-AXEMeasure -EA SilentlyContinue))
        Write-Host "Medicion view     : score+boton+reporte+helper=$measOk (esperado True)"
        if(-not $measOk){ $allOk=$false }
        # regresion H10-medicion: Invoke-AXEMeasure debe COGER el mutex, no solo leerlo. Era la
        # unica operacion de fondo que comprobaba $script:busy sin ponerlo nunca, asi que durante
        # el muestreo APLICAR/MASTER/Start-AXEJob podian arrancar y mutar el registro en mitad del
        # snapshot, contaminando el "antes" del delta antes/despues.
        #   El test de mutex de mas arriba NO cubria esto: prueba Start-AXEJob, que si lo cogia.
        # Se mide con 1ms de jitter (el minimo util) para no alargar el gate.
        try {
            Invoke-AXEMeasure -JitterMs 1
            $tookMutex = $script:busy
            # Drena hasta que el tick complete y suelte el mutex. Tope por si nunca completa:
            # sin el, un fallo de liberacion colgaria el gate en vez de reportarlo.
            $spins=0
            while($script:busy -and $spins -lt 200){ Invoke-AXEDoEvents; Start-Sleep -Milliseconds 20; $spins++ }
            $released = -not $script:busy
            Write-Host "Medicion mutex    : coge=$tookMutex libera=$released (esperado True/True)"
            if(-not $tookMutex -or -not $released){ $allOk=$false; $script:busy=$false }
        } catch {
            Write-Host "Medicion mutex    : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false; $script:busy=$false
        }
        # regresion §3.5: el barrido de timer vive en la GUI, no solo en el CLI. Se comprueba
        # boton + handler + formateador compartido. El barrido NO se ejecuta aqui: tarda ~30s
        # y sube la prioridad del proceso, que no es aceptable dentro de un selftest.
        $swOk = ($null -ne $script:sweepBtn) -and
                ([bool](Get-Command Invoke-AXETimerSweepJob -EA SilentlyContinue)) -and
                ([bool](Get-Command Format-AXETimerSweep -EA SilentlyContinue))
        Write-Host "Barrido timer view: boton+handler+formateador=$swOk (esperado True)"
        if(-not $swOk){ $allOk=$false }
        # Format-AXETimerSweep con $null (barrido sin datos utiles) debe degradar a un mensaje,
        # no reventar: es el camino real cuando el kernel rechaza todos los requests.
        try {
            $fmtNull = @(Format-AXETimerSweep $null)
            $fmtOk = ($fmtNull.Count -ge 1) -and -not [string]::IsNullOrWhiteSpace($fmtNull[0])
        } catch { $fmtOk=$false }
        Write-Host "Barrido fmt null  : degrada sin excepcion=$fmtOk (esperado True)"
        if(-not $fmtOk){ $allOk=$false }
    } catch { Write-Host "Medicion view     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion REGISTRO: la vista se construye y el extractor de rutas cubre el catalogo.
    # NO se llama a Open-AXERegedit: lanzaria regedit.exe de verdad en medio del selftest.
    try {
        Build-ActionView 'REGISTRO' | Out-Null
        $regViewOk = ($null -ne $script:regOut) -and ($null -ne $script:regBtn) -and
                     ([bool](Get-Command Get-AXERegDiagnostic -EA SilentlyContinue)) -and
                     ([bool](Get-Command Open-AXERegedit -EA SilentlyContinue))
        Write-Host "Registro view     : salida+boton+helpers=$regViewOk (esperado True)"
        if(-not $regViewOk){ $allOk=$false }
        # El extractor debe encontrar clave en la MAYORIA del catalogo. Si un refactor rompe el
        # regex, esto cae a ~0 y los atajos "regedit" desaparecen de las tarjetas en silencio.
        $nPaths=0; foreach($tw in @($script:CAT)){ if((@(Get-AXERegPathsForTweak $tw)).Count){ $nPaths++ } }
        $pathOk = ($nPaths -ge 40)
        Write-Host "Registro rutas    : $nPaths/$(@($script:CAT).Count) tweaks con clave (esperado >=40)"
        if(-not $pathOk){ $allOk=$false }
        # Conversion al formato de LastKey, incluido el rechazo de basura.
        $convOk = ((ConvertTo-AXERegeditPath 'HKLM:\SYSTEM\Foo') -match '\\HKEY_LOCAL_MACHINE\\SYSTEM\\Foo$') -and
                  ($null -eq (ConvertTo-AXERegeditPath 'no-es-una-ruta'))
        Write-Host "Registro convpath : hive+rechazo basura=$convOk (esperado True)"
        if(-not $convOk){ $allOk=$false }
        # PULSAR el boton de verdad, no solo comprobar que existe. Construir la vista NO ejecuta
        # el cuerpo del handler, asi que un comando inexistente ahi dentro pasaba el gate y
        # reventaba en el primer clic del usuario (caso real: Invoke-AXEDoEvents, que solo
        # existe dentro de este selftest). Cuesta ~2s y cubre el camino entero.
        try {
            $script:regBtn.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
            $clickOk = ($script:regOut.Text -match 'claves distintas') -and (-not $script:busy) -and $script:regBtn.IsEnabled
            Write-Host "Registro clic     : handler completo + mutex liberado=$clickOk (esperado True)"
            if(-not $clickOk){ $allOk=$false; Write-Host "  salida: $($script:regOut.Text -split "`r?`n" | Select-Object -First 1)" }
        } catch {
            Write-Host "Registro clic     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false
        }
    } catch { Write-Host "Registro view     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion: badge recomendado curado (no todo Tier<2)
    $recCount=0
    foreach($catName in $script:tweakCats){ foreach($e in $script:rows[$catName]){ if($script:RECOMMENDED -contains $e.Tw.Id){ $recCount++ } } }
    Write-Host "Badges recomendado: $recCount catalogo / $($script:RECOMMENDED.Count) curados"
    # regresion: diff de cambios pendientes (APLICAR muestra contador)
    $row0=$null; foreach($catName in $script:tweakCats){ foreach($e in $script:rows[$catName]){ if(-not $e.Blocked){ $row0=$e; break } }; if($row0){break} }
    if($row0){
        $row0.Base=[bool]$row0.Toggle.IsChecked
        $row0.Toggle.IsChecked = -not [bool]$row0.Base
        Update-AXEPending
        $pendOk = ($BtnApply.Content -match '^APLICAR \(\d')
        Write-Host "Pending diff      : BtnApply='$($BtnApply.Content)' dirty=$pendOk (esperado True)"
        if(-not $pendOk){ $allOk=$false }
        $row0.Toggle.IsChecked=$row0.Base; Update-AXEPending
    }
    # regresion: log sink colorea por severidad (RichTextBox blocks)
    try {
        Write-AXELog 'regresion ERR' 'ERR'
        $sinkOk=($script:LogBox.Document.Blocks.Count -gt 0)
        Write-Host "Log sink          : blocks=$($script:LogBox.Document.Blocks.Count) ok=$sinkOk (esperado True)"
        if(-not $sinkOk){ $allOk=$false }
    } catch { Write-Host "Log sink          : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
    # regresion logo AXE: 6 paths en el Canvas del header (2 Accent + 4 Surface),
    # sin path en negro-sobre-oscuro (invisible). El ActualWidth se mide despues del
    # layout forzado del bloque de render (mas abajo).
    try {
        $paths=@($LogoCanvas.Children)
        # Derivado de los recursos, no hardcodeado: la regresion que importa es "el logo usa
        # los colores de la paleta", no "el logo es teal". Retocar la paleta ya no rompe esto,
        # pero olvidarse de repintar el logo si.
        $accentHex =(New-AXEBrush 'Accent').Color.ToString()
        $surfaceHex=(New-AXEBrush 'Surface').Color.ToString()
        $accent=$paths | Where-Object { $_.Fill -is [System.Windows.Media.SolidColorBrush] -and $_.Fill.Color.ToString() -eq $accentHex }
        $surface=$paths | Where-Object { $_.Fill -is [System.Windows.Media.SolidColorBrush] -and $_.Fill.Color.ToString() -eq $surfaceHex }
        $logoOk=($paths.Count -eq 6) -and ($accent.Count -eq 2) -and ($surface.Count -eq 4)
        Write-Host ("Logo AXE          : paths={0} accent={1} surface={2} (esperado 6/2/4)" -f $paths.Count,$accent.Count,$surface.Count)
        if(-not $logoOk){ $allOk=$false }
    } catch { Write-Host "Logo AXE          : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # regresion 3.3: el header muestra el banner de ecosistema, y es EL MISMO texto que
    # imprime la CLI (-List "ECO:"). Si alguien duplica la logica en la GUI, esto lo caza.
    try {
        $bannerTxt = $EnvBannerLbl.Text
        $bannerOk  = $bannerTxt -and ($bannerTxt -eq (Get-AXEEnvBanner)) -and ($bannerTxt -match 'aplicables')
        Write-Host ("Banner ecosistema : '{0}' coincide con CLI={1} (esperado True)" -f $bannerTxt,$bannerOk)
        if(-not $bannerOk){ $allOk=$false }
    } catch { Write-Host "Banner ecosistema : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

    # render PNG
    try {
        $W=1200;$H=840
        $win.Width=$W; $win.Height=$H
        $win.Measure([System.Windows.Size]::new($W,$H))
        $win.Arrange([System.Windows.Rect]::new(0,0,$W,$H))
        $win.UpdateLayout()
        # logo: el Viewbox escala el Canvas proporcionalmente al Height=34. En modo headless
        # ActualWidth puede quedar en 0 (sin HWND el layout no drena); en runtime con ShowDialog
        # si. Solo informativo aqui - la verificacion estructural (6/2/4) ya cubre la regresion.
        $logoW=[int]$LogoBox.ActualWidth
        Write-Host ("Logo AXE box      : w={0} (info; >0 en runtime con ShowDialog)" -f $logoW)
        $rtb=New-Object System.Windows.Media.Imaging.RenderTargetBitmap($W,$H,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($win.Content)
        $enc=New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $pngPath=Join-Path $env:AXE_GUITEST_PNG_DIR 'axe_render.png'
        $fs=[System.IO.File]::Create($pngPath); $enc.Save($fs); $fs.Close()
        Write-Host "Render PNG        : $pngPath"
    } catch {
        # El volcado del PNG es un ARTEFACTO, no una asercion: que no se pueda escribir no dice
        # nada sobre si la GUI esta bien, asi que no tumba el gate (y esta bien que no lo haga).
        # Pero antes imprimia "FALLO" igualmente y el harness remataba con "LAYOUT OK": un fallo
        # que no era fallo, ruido que entrena a ignorar la palabra FALLO en la salida.
        #   Sin AXE_GUITEST_PNG_DIR (ejecucion manual del harness) ni siquiera es un problema: es
        # que no se pidio el volcado. build.ps1 si define la variable.
        if([string]::IsNullOrWhiteSpace($env:AXE_GUITEST_PNG_DIR)){
            Write-Host "Render PNG        : omitido (AXE_GUITEST_PNG_DIR no definida; no es un fallo)"
        } else {
            Write-Host "Render PNG        : no se pudo escribir -> $($_.Exception.Message)  (artefacto, no tumba el gate)"
        }
    }
    if($allOk){ Write-Host "RESULTADO: LAYOUT OK"; exit 0 } else { Write-Host "RESULTADO: LAYOUT FALLO"; exit 1 }
}

if($env:AXE_GUISHOW -eq '1'){
    $win.Add_ContentRendered({
        try {
            $rtb=New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$win.ActualWidth,[int]$win.ActualHeight,96,96,[System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($win)
            $enc=New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $p=Join-Path $env:AXE_GUITEST_PNG_DIR 'axe_shown.png'
            $fs=[System.IO.File]::Create($p); $enc.Save($fs); $fs.Close(); Write-Host "SHOWN PNG: $p"
        } catch { Write-Host "SHOW render fallo: $($_.Exception.Message)" }
        $win.Dispatcher.InvokeAsync([action]{ $win.Close() },[System.Windows.Threading.DispatcherPriority]::Background) | Out-Null
    })
}
# H4: al cerrar, drena runspaces + timers vivos (evita fuga de handles/hilos si el
# usuario cierra con una tarea de fondo en curso). Stop antes de Dispose por si el
# PowerShell sigue ejecutando (Checkpoint-Computer, HW load, tarea de limpieza).
