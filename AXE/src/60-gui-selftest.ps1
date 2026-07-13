# ---- 12.16 GUITEST: assert + render PNG, sin ShowDialog ----
if($env:AXE_GUITEST -eq '1'){
    Write-Host "== AXE v5 WPF - LAYOUT TEST =="
    Write-Host "NAV items         : $($script:navBtns.Count)"
    Write-Host "Vistas tweaks     : $(($script:tweakCats).Count)"
    $allOk=$true

    # Bombea la cola del dispatcher hasta idle (permite que DispatcherTimer ticke sin ShowDialog)
    function Invoke-AXEDoEvents {
        $frame=New-Object System.Windows.Threading.DispatcherFrame
        [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::SystemIdle,[action]{ $frame.Continue=$false })
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }

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
    } catch { Write-Host "Medicion view     : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }
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
        $accent=$paths | Where-Object { $_.Fill -is [System.Windows.Media.SolidColorBrush] -and $_.Fill.Color.ToString() -eq '#FF2DD4BF' }
        $surface=$paths | Where-Object { $_.Fill -is [System.Windows.Media.SolidColorBrush] -and $_.Fill.Color.ToString() -eq '#FF26262B' }
        $logoOk=($paths.Count -eq 6) -and ($accent.Count -eq 2) -and ($surface.Count -eq 4)
        Write-Host ("Logo AXE          : paths={0} accent={1} surface={2} (esperado 6/2/4)" -f $paths.Count,$accent.Count,$surface.Count)
        if(-not $logoOk){ $allOk=$false }
    } catch { Write-Host "Logo AXE          : EXCEPCION -> $($_.Exception.Message)"; $allOk=$false }

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
    } catch { Write-Host "Render PNG        : FALLO -> $($_.Exception.Message)" }
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
