# ---- 12.11 navegacion ----
function Add-NavHeader($text){
    $t=New-Object System.Windows.Controls.TextBlock; $t.Text=$text; $t.FontSize=11; $t.FontWeight='Bold'; $t.Foreground=New-AXEBrush 'Muted'
    $t.Margin=New-Object System.Windows.Thickness(16,10,10,4); [void]$NavPanel.Children.Add($t)
}
function Add-NavItem($catName){
    $rb=New-Object System.Windows.Controls.RadioButton; $rb.Style=$win.FindResource('NavItem')
    $rb.Content=$catName; $rb.Tag=[string]$script:glyphs[$catName]; $rb.GroupName='nav'
    [System.Windows.Automation.AutomationProperties]::SetName($rb,$catName)
    $rb.Add_Checked({ param($s,$e) Switch-View $s.Content })
    [void]$NavPanel.Children.Add($rb); $script:navBtns[$catName]=$rb
}
Add-NavHeader 'OPTIMIZAR'
foreach($catName in $script:tweakCats){ Add-NavItem $catName }
Add-NavHeader 'ACCIONES'
foreach($catName in $script:actionCats){ Add-NavItem $catName }

function Switch-View($catName){
    foreach($v in $script:views.Values){ $v.Visibility='Collapsed' }
    $ContentTitle.Text=$catName; $script:activeCat=$catName
    if($catName -in $script:actionCats){
        $ContentSub.Text = switch($catName){ 'MEDICION'{'Mide latencia/timer y calcula el AXE Score'} 'REGISTRO'{'Que claves toca el catalogo (solo lectura)'} 'LIMPIEZA'{'Libera espacio en disco'} 'DEBLOAT'{'Quita apps preinstaladas'} 'DNS'{'Servidores DNS rapidos'} 'STARTUP'{'Programas de arranque'} 'PERFILES'{'Plan de energia por-juego (auto)'} 'ASISTENTE IA'{'Recomendaciones locales, sin internet'} default{''} }
        if(-not $script:views.ContainsKey($catName)){ Build-ActionView $catName | Out-Null }
        $script:views[$catName].Visibility='Visible'; Start-AXEFade $script:views[$catName]; return
    }
    if($script:views.ContainsKey($catName)){ $script:views[$catName].Visibility='Visible'; Start-AXEFade $script:views[$catName] }
    Update-AXESubtitle $catName
}
# Subtitulo de contexto: N tweaks / activas / bloqueadas
function Update-AXESubtitle($catName){
    $rc=$script:rows[$catName]; if(-not $rc){ $ContentSub.Text=''; return }
    $bk=@($rc | Where-Object { $_.Blocked }).Count
    $ac=@($rc | Where-Object { -not $_.Blocked -and $_.Toggle.IsChecked }).Count
    $ContentSub.Text = "$($rc.Count) tweaks - $ac activas" + $(if($bk -gt 0){" - $bk bloqueadas"}else{''})
}

# ---- 12.12 refresh estado ----
# Diff de cambios pendientes: resalta filas sucias + contador vivo en APLICAR
function Update-AXEPending {
    $n=0
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){
            if($e.Blocked){ continue }
            $dirty = ($null -ne $e.Base) -and (([bool]$e.Toggle.IsChecked) -ne ([bool]$e.Base))
            $e.Card.BorderBrush = $(if($dirty){ New-AXEBrush 'Accent' } else { New-AXEBrush 'Line' })
            $e.Card.BorderThickness = New-Object System.Windows.Thickness($(if($dirty){2}else{1}))
            if($dirty){ $n++ }
        }
    }
    $BtnApply.Content = $(if($n -gt 0){ "APLICAR ($n)" } else { 'APLICAR cambios' })
}

# A1: async. Antes corria ~60 Test SINCRONOS en el UI thread (bcdedit, CIM lentos,
# Get-ScheduledTask...) => la ventana se congelaba al arrancar y en "Leer estado".
# Ahora procesa por lotes con DispatcherTimer (mismo patron que APLICAR): la UI
# responde y rellena progresivamente. $Then se invoca al completar (p.ej. re-habilitar
# botones tras APLICAR). Reentrante-seguro via $script:refreshing.
function Refresh-States {
    param([scriptblock]$Then)
    if($script:refreshing){ if($Then){ & $Then }; return }
    $script:refreshing=$true; $script:refThen=$Then
    $script:tCache=@{}   # cacheo de tests: nueva pasada => estado fresco
    $script:refQueue=New-Object System.Collections.Queue
    foreach($catName in $script:tweakCats){ foreach($e in $script:rows[$catName]){ if(-not $e.Blocked){ [void]$script:refQueue.Enqueue($e) } } }
    $script:refOn=0; $script:refApplicable=$script:refQueue.Count
    $script:refTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:refTimer.Interval=[TimeSpan]::FromMilliseconds(1)
    $script:refTimer.Add_Tick({
        $budget=6
        while($budget -gt 0 -and $script:refQueue.Count -gt 0){
            $e=$script:refQueue.Dequeue(); $budget--
            try { $s=[bool](& $e.Tw.Test); $e.Toggle.IsChecked=$s; $e.Base=$s; if($s){$script:refOn++} }
            catch { Write-AXELog "Test fallo: $($e.Tw.Name)" 'WARN' }
        }
        if($script:refQueue.Count -gt 0){ return }
        $script:refTimer.Stop()
        $CountLbl.Text="$($script:refOn)/$($script:refApplicable)"
        if($script:refApplicable -gt 0){ $StatusBar.Value=[int](($script:refOn/$script:refApplicable)*100) }
        Update-AXEPending
        if($script:activeCat -and ($script:activeCat -notin $script:actionCats)){ Update-AXESubtitle $script:activeCat }
        $script:refreshing=$false
        if($script:refThen){ $cb=$script:refThen; $script:refThen=$null; & $cb }
    })
    $script:refTimer.Start()
}

# ---- 12.12b carga HW async (GUI): la ventana no espera los ~3.7s de CIM ----
# Re-aplica el gating a las cards ya construidas (se construyeron con HW=null => sin bloqueo).
function Apply-AXEGating {
    # §3.4: las tarjetas se construyen antes de que el runspace devuelva el hardware, asi
    # que la lista inicial es solo el nucleo universal. Aqui ya hay HW real: se recalcula
    # contra ESTA maquina y se encienden/apagan las insignias en sitio.
    $script:RECOMMENDED = @(Get-AXERecommended)
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){
            $blk = Get-BlockReason $e.Tw
            if($blk -and -not $e.Blocked){
                $e.Blocked=$true; $e.Toggle.IsEnabled=$false; $e.Toggle.IsChecked=$false
                $e.Desc.Foreground=New-AXEBrush 'Red'; $e.Desc.Text="[BLOQUEADO] $blk"
            }
            $b = $script:recBadges[$e.Tw.Id]
            if($b){ $b.Visibility = if(-not $blk -and ($script:RECOMMENDED -contains $e.Tw.Id)){'Visible'}else{'Collapsed'} }
        }
    }
    Write-AXELog ("Recomendaciones ajustadas a tu equipo: {0} de {1} tweaks." -f $script:RECOMMENDED.Count,$script:CAT.Count)
}
# Get-AXEHardware es self-contained (solo CIM + pscustomobject) => corre limpio en runspace.
$script:hwPS=$null
function Start-AXEHardwareLoad {
    if($script:HW){ Build-HwChips; Apply-AXEGating; Refresh-States; return }  # ya cargado
    Write-AXELog 'Detectando hardware en segundo plano...'
    $ps=[PowerShell]::Create(); [void]$ps.AddScript([string](Get-Command Get-AXEHardware).ScriptBlock)
    $script:hwPS=$ps; $script:hwHandle=$ps.BeginInvoke()
    $script:hwTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:hwTimer.Interval=[TimeSpan]::FromMilliseconds(120)
    $script:hwTimer.Add_Tick({
        if(-not $script:hwHandle.IsCompleted){ return }
        $script:hwTimer.Stop()
        try { $res=$script:hwPS.EndInvoke($script:hwHandle); $script:HW=@($res)[0] }
        catch { Write-AXELog "Deteccion HW fallo: $($_.Exception.Message)" 'ERR' }
        $script:hwPS.Dispose(); $script:hwPS=$null
        # H7: sin HW fiable el gating por hardware no se puede evaluar. Fail-safe:
        # deshabilita APLICAR/PRESET/MASTER para no aplicar tweaks a ciegas. "Leer
        # estado" reintenta la deteccion.
        if(-not $script:HW){
            Write-AXELog 'No pude detectar el hardware. APLICAR deshabilitado por seguridad (el gating por HW no es fiable). Pulsa "Leer estado" para reintentar.' 'ERR'
            foreach($b in @($BtnApply,$BtnPreset,$BtnMaster)){ $b.IsEnabled=$false }
            return
        }
        foreach($b in @($BtnApply,$BtnPreset,$BtnMaster)){ $b.IsEnabled=$true }
        Build-HwChips
        Apply-AXEGating
        $nBlk=0; foreach($tw in $script:CAT){ if(Get-BlockReason $tw){ $nBlk++ } }
        Write-AXELog "Hardware detectado. Bloqueados por HW: $nBlk."
        Refresh-States
    })
    $script:hwTimer.Start()
}

# ---- 12.13 buscador ----
# H12: el placeholder es un overlay XAML (watermark real). SearchBox.Text es SIEMPRE
# la query real (vacio = sin filtro); ya no hay hacks de GotFocus/LostFocus.
$SearchBox.Add_TextChanged({
    $q=$SearchBox.Text.ToLower()
    $cat=$script:activeCat
    if(-not $cat -or ($cat -in $script:actionCats)){ return }   # busca solo en categorias de tweaks
    foreach($e in $script:rows[$cat]){
        if($q -eq ''){ $e.Card.Visibility='Visible' }
        else {
            $m = ($e.Tw.Name.ToLower().Contains($q)) -or ($e.Tw.Desc.ToLower().Contains($q))
            $e.Card.Visibility = $(if($m){'Visible'}else{'Collapsed'})
        }
    }
    $ContentTitle.Text = $(if($q -ne ''){"$cat  -  buscar: $q"}else{$cat})
})

# ---- 12.14 acciones principales ----
$BtnRead.Add_Click({
    if(-not $script:HW){ Write-AXELog 'Reintentando deteccion de hardware...'; Start-AXEHardwareLoad; return }   # H7: retry
    Write-AXELog 'Leyendo estado real...'; Refresh-States -Then { Write-AXELog 'Estado actualizado.' }
})

$BtnPreset.Add_Click({
    foreach($catName in $script:tweakCats){
        # net_dns queda FUERA del preset a posta: sobrescribe DNS local/VPN (ver su Desc). Opt-in manual en pestana DNS.
        foreach($e in $script:rows[$catName]){ if(-not $e.Blocked -and $e.Tw.Tier -lt 2 -and $e.Tw.Id -ne 'net_dns'){ $e.Toggle.IsChecked=$true } }
    }
    Update-AXEPending
    Write-AXELog 'Preset GAMING marcado (Tier 0+1, excepto DNS manual). EXTREMO no se toca. Pulsa APLICAR.'
})

# A3: Master revert sin freeze. Antes Invoke-AXEMasterRevert corria ~60 reverts SINCRONOS
# en el UI thread (bcdedit, powercfg, sc.exe, Set-ProcessMitigation) => congelaba la
# ventana varios segundos. Ahora drena el catalogo por lotes con DispatcherTimer (mismo
# patron que APLICAR) y corre el tail (residuos v1 + restore startup) al terminar.
$BtnMaster.Add_Click({
    if($script:busy){ return }
    $r=[System.Windows.MessageBox]::Show("Esto revierte TODOS los tweaks a fabrica + limpia residuos de versiones antiguas. Continuar?",'MASTER REVERT','YesNo','Warning')
    if($r -ne 'Yes'){ return }
    Write-AXELog '=== MASTER REVERT: revirtiendo TODO a fabrica ==='
    $script:mrQueue=New-Object System.Collections.Queue
    foreach($tw in $script:CAT){ if(-not (Get-BlockReason $tw)){ [void]$script:mrQueue.Enqueue($tw) } }
    $script:busy=$true
    foreach($b in @($BtnApply,$BtnPreset,$BtnMaster,$BtnRead)){ $b.IsEnabled=$false }
    $ApplyBar.Visibility='Visible'; $ApplyBar.Value=0
    $script:mrTotal=$script:mrQueue.Count; $script:mrDone=0; $script:mrRev=0
    $script:mrTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:mrTimer.Interval=[TimeSpan]::FromMilliseconds(1)
    $script:mrTimer.Add_Tick({
        $budget=3
        while($budget -gt 0 -and $script:mrQueue.Count -gt 0){
            $tw=$script:mrQueue.Dequeue(); $budget--
            try { if((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id)){ } else { & $tw.Revert }; $script:mrRev++ } catch { Write-AXELog "No pude revertir $($tw.Name): $($_.Exception.Message)" 'ERR' }
            $script:mrDone++
        }
        if($script:mrTotal -gt 0){ $ApplyBar.Value=[int](($script:mrDone/$script:mrTotal)*100) }
        if($script:mrQueue.Count -gt 0){ return }
        $script:mrTimer.Stop()
        Write-AXELog "Revertidos $($script:mrRev) tweaks del catalogo."
        Invoke-AXEMasterRevertTail
        Refresh-States -Then {
            foreach($b in @($BtnApply,$BtnPreset,$BtnMaster,$BtnRead)){ $b.IsEnabled=$true }
            $ApplyBar.Visibility='Collapsed'; $script:busy=$false
        }
    })
    $script:mrTimer.Start()
})

# H2: hay un punto de restauracion reciente (ultimas 24h)? Query no-mutante, seguro.
# CIM root/default SystemRestore funciona en PS 5.1 y pwsh 7. Cualquier fallo => $false
# (asi el Apply ofrece crear uno; nunca asume que existe).
function Test-RecentRestorePoint {
    try {
        $pts = Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -EA Stop
        if(-not $pts){ return $false }
        $cut = (Get-Date).AddHours(-24)
        foreach($p in $pts){
            $ct = $p.CreationTime
            if($ct -is [string]){ try { $ct = [Management.ManagementDateTimeConverter]::ToDateTime($ct) } catch { $ct = $null } }
            if($ct -and $ct -ge $cut){ return $true }
        }
        return $false
    } catch { return $false }
}

# Medicion sin freeze: el busy-loop de jitter (1s) va a un runspace; timer + cobertura
# se calculan al volver en el UI thread (instantaneos). Reusa el patron de rsPS/timers.
$script:snapPrev=$null; $script:snapCur=$null; $script:measurePS=$null; $script:measureBtn=$null
function Invoke-AXEMeasure {
    param([int]$JitterMs=1000,[scriptblock]$OnDone=$null)
    if($script:busy -or $script:measurePS){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }
    # H10: medir TAMBIEN coge el mutex. Antes solo lo LEIA: comprobaba $script:busy pero nunca
    # lo ponia, asi que era la unica operacion de fondo que no lo tomaba. Durante el segundo de
    # muestreo, busy seguia en $false y APLICAR/MASTER/Start-AXEJob podian arrancar y mutar el
    # registro EN MITAD del snapshot, contaminando justo el "antes" del delta antes/despues.
    #   Se llama desde el tail de APLICAR (tras liberar el mutex en el Then de Refresh-States),
    #   no desde dentro, asi que tomarlo aqui no se auto-bloquea.
    $script:busy=$true
    if($script:measureBtn){ $script:measureBtn.IsEnabled=$false }
    if($script:scoreLbl){ $script:scoreLbl.Text='...' }
    $ps=[PowerShell]::Create()
    [void]$ps.AddScript({ param($ms) [AXE.Native]::SampleJitter([int]$ms) })   # tipo visible en el AppDomain
    [void]$ps.AddArgument([int]$JitterMs)
    $script:measurePS=$ps; $script:measureHandle=$ps.BeginInvoke()
    $script:measureTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:measureTimer.Interval=[TimeSpan]::FromMilliseconds(150)
    $script:measureTimer.Add_Tick({
        if(-not $script:measureHandle.IsCompleted){ return }
        $script:measureTimer.Stop()
        # try/finally sobre TODO el cuerpo: ahora que el tick tiene el mutex, una excepcion aqui
        # (Get-AXEScore, New-AXEReport, un Test de tweak) lo dejaria cogido para siempre y la
        # ventana quedaria inerte -- ningun boton volveria a responder y sin error visible.
        # $snap/$sc se declaran fuera para que $OnDone, que corre despues del finally, los vea.
        $snap=$null; $sc=$null
        try {
        try { $r=@($script:measurePS.EndInvoke($script:measureHandle)) } catch { $r=$null }
        $script:measurePS.Dispose(); $script:measurePS=$null
        # ensamblar snapshot en el UI thread
        $jit='n/a'
        if($r -and $r.Count -ge 5){ $jit=[pscustomobject]@{ Samples=[int]$r[0]; MeanMs=[math]::Round($r[1],4); MaxMs=[math]::Round($r[2],4); P999Ms=[math]::Round($r[3],4); Stalls1ms=[int]$r[4] } }
        $timer='n/a'; try { $t=Get-AXETimerResolution; if($t){ $timer=$t } } catch {}
        $on='n/a'; $app='n/a'
        try { $onN=0;$appN=0; foreach($tw in $script:CAT){ if($tw.Tier -notin 0,1){continue}; if(Get-BlockReason $tw){continue}; $appN++; if(Test-TweakSafe $tw){$onN++} }; $on=$onN; $app=$appN } catch {}
        $snap=[pscustomobject]@{ Timestamp=(Get-Date).ToUniversalTime().ToString('u'); Timer=$timer; Jitter=$jit; TweaksOn=$on; TweaksApplicable=$app }
        $script:snapPrev=$script:snapCur; $script:snapCur=$snap
        $sc=Get-AXEScore $snap $script:snapPrev
        if($script:scoreLbl){ $script:scoreLbl.Text="$($sc.Total)" }
        if($script:scoreBreak){ $script:scoreBreak.Text=$sc.Breakdown }
        if($script:measureOut){
            if($script:snapPrev){ $script:measureOut.Text=(New-AXEReport $script:snapPrev $snap (Get-AXEScore $script:snapPrev) $sc) }
            else { $script:measureOut.Text=$sc.Breakdown + "`r`n(mide otra vez para ver delta antes/despues)" }
        }
        if($script:measureBtn){ $script:measureBtn.IsEnabled=$true }
        Write-AXELog "Medicion: AXE Score $($sc.Total)/100."
        } catch {
            Write-AXELog "Medicion fallo: $($_.Exception.Message)" 'ERR'
            if($script:measureBtn){ $script:measureBtn.IsEnabled=$true }
            if($script:measurePS){ $script:measurePS.Dispose(); $script:measurePS=$null }
        } finally {
            # El mutex protege la MEDICION, no el callback: liberar aqui deja a $OnDone lanzar
            # otra tarea de fondo sin bloquearse contra la medicion que acaba de terminar.
            $script:busy=$false
        }
        # Fuera del try: si el cuerpo fallo, $sc es $null y no hay nada que reportar.
        if($OnDone -and $sc){ try { & $OnDone $snap $sc } catch {} }
    })
    $script:measureTimer.Start()
}

# Barrido de timer sin freeze. Mismo patron que Invoke-AXEMeasure, pero con un problema extra:
# el jitter llama a [AXE.Native]::SampleJitter, que es un TIPO .NET y por tanto visible desde
# cualquier runspace del AppDomain. Measure-AXETimerSweep es una FUNCION de PowerShell, y el
# scope de funciones es por-runspace: un [PowerShell]::Create() nuevo no la ve. Por eso se envia
# el codigo fuente de la funcion y sus dependencias, en vez de reimplementar el barrido aqui
# (una copia derivaria del original justo en la logica que decide si el resultado es ruido).
$script:sweepPS=$null; $script:sweepHandle=$null; $script:sweepTimer=$null; $script:sweepBtn=$null
function Invoke-AXETimerSweepJob {
    if($script:busy -or $script:measurePS -or $script:sweepPS){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }
    # Mutex H10 compartido con APLICAR/MASTER: durante el barrido el proceso sube a prioridad
    # High y mantiene un request de resolucion de timer. Dejar que APLICAR corra a la vez
    # mezclaria mutacion del sistema con la medicion que intenta caracterizarlo.
    $script:busy=$true
    if($script:sweepBtn){ $script:sweepBtn.IsEnabled=$false }
    if($script:measureBtn){ $script:measureBtn.IsEnabled=$false }
    if($script:measureOut){ $script:measureOut.Text="Barrido en curso: ~30s (3 pasadas en orden aleatorio).`r`nNo toques nada mientras mide o el delta recogera tu actividad." }
    Write-AXELog 'Barrido de timer: midiendo delta de Sleep(1) por resolucion (~30s).'

    $fnSrc = ''
    # Get-AXESweepVerdict y Get-AXEBand van SI O SI: Measure-AXETimerSweep las llama y el scope
    # de funciones es por-runspace, asi que sin enviarlas el barrido de la GUI muere con
    # "termino no reconocido" DENTRO del runspace, donde el error no se ve. La CLI seguiria
    # funcionando, que es justo lo que hace este fallo dificil de pillar.
    foreach($n in 'Get-RV','Get-AXETimerResolution','Set-AXETimerResolution','Get-AXEBand','Get-AXESweepVerdict','Measure-AXETimerSweep'){
        $fnSrc += "function $n {`r`n" + (Get-Command $n).Definition + "`r`n}`r`n"
    }
    $ps=[PowerShell]::Create()
    [void]$ps.AddScript({
        param($src)
        # Shim de log: en un runspace nuevo no existen $script:AXELog ni $script:LogBox, asi que
        # el Write-AXELog real escribiria Add-Content contra ruta vacia y perderia los avisos
        # (el de GlobalTimerResolutionRequests y el de requests no concedidos, que son justo los
        # que explican un resultado raro). Se recogen aqui y el UI thread los reemite.
        $script:swLog = New-Object System.Collections.ArrayList
        function Write-AXELog { param([string]$Msg,[string]$Level='INFO') [void]$script:swLog.Add("$Level|$Msg") }
        . ([scriptblock]::Create($src))
        [pscustomobject]@{ Sweep=(Measure-AXETimerSweep); Log=@($script:swLog) }
    })
    [void]$ps.AddArgument($fnSrc)
    try { $script:sweepPS=$ps; $script:sweepHandle=$ps.BeginInvoke() }
    catch {
        # Si el arranque falla hay que soltar el mutex aqui: el tick de abajo nunca correra.
        $ps.Dispose(); $script:sweepPS=$null; $script:busy=$false
        if($script:sweepBtn){ $script:sweepBtn.IsEnabled=$true }
        if($script:measureBtn){ $script:measureBtn.IsEnabled=$true }
        Write-AXELog "Barrido: no arranco -> $($_.Exception.Message)" 'ERR'
        return
    }
    $script:sweepTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:sweepTimer.Interval=[TimeSpan]::FromMilliseconds(200)
    $script:sweepTimer.Add_Tick({
        if(-not $script:sweepHandle.IsCompleted){ return }
        $script:sweepTimer.Stop()
        $res=$null
        try { $res=@($script:sweepPS.EndInvoke($script:sweepHandle)) | Select-Object -First 1 }
        catch { Write-AXELog "Barrido: fallo en el runspace -> $($_.Exception.Message)" 'ERR' }
        $script:sweepPS.Dispose(); $script:sweepPS=$null
        # Reemitir los avisos del runspace con el logger real, ya en el UI thread.
        if($res -and $res.Log){
            foreach($e in $res.Log){
                $p="$e" -split '\|',2
                if($p.Count -eq 2){ Write-AXELog $p[1] $p[0] } else { Write-AXELog "$e" }
            }
        }
        $sw = if($res){ $res.Sweep } else { $null }
        if($script:measureOut){ $script:measureOut.Text = ((Format-AXETimerSweep $sw) -join "`r`n") }
        if($sw){
            Write-AXELog $(if($sw.Conclusive){
                "Barrido: mejor resolucion {0:F3}ms (spread {1:F3}ms sobre el ruido)." -f $sw.Best.AppliedMs,$sw.SpreadMs
            } else {
                "Barrido: no concluyente (spread {0:F3}ms dentro del ruido). No se recomienda cambiar nada." -f $sw.SpreadMs
            })
        }
        if($script:sweepBtn){ $script:sweepBtn.IsEnabled=$true }
        if($script:measureBtn){ $script:measureBtn.IsEnabled=$true }
        $script:busy=$false
    })
    $script:sweepTimer.Start()
}

# Apply sin freeze: DispatcherTimer procesa 1 tweak/tick
$BtnApply.Add_Click({
    if($script:busy){ return }
    # construir cola de cambios
    $script:applyQueue=New-Object System.Collections.Queue
    $tier2on=$false
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){
            if($e.Blocked){ continue }
            try{ $cur=[bool](& $e.Tw.Test) }catch{ continue }
            $want=[bool]$e.Toggle.IsChecked
            if($want -ne $cur){
                $script:applyQueue.Enqueue(@{Tw=$e.Tw; Want=$want})
                if($want -and $e.Tw.Tier -eq 2){ $tier2on=$true }
            }
        }
    }
    if($script:applyQueue.Count -eq 0){ Write-AXELog 'Sin cambios.'; return }
    # Gate de seguridad Tier 2
    if($tier2on){
        $r=[System.Windows.MessageBox]::Show("Vas a ACTIVAR tweaks EXTREMO (Tier 2) que DESACTIVAN protecciones de seguridad reales (Tamper Protection, VBS/HVCI, CFG/ASLR, Spectre). Solo en PC dedicada a gaming. Continuar?",'RIESGO DE SEGURIDAD','YesNo','Warning')
        if($r -ne 'Yes'){ Write-AXELog 'Aplicacion cancelada por el usuario (gate Tier 2).' 'WARN'; return }
    }
    # H2: exigir punto de restauracion (opt-out). Si no hay uno reciente, ofrecer crearlo.
    if(-not (Test-RecentRestorePoint)){
        $rp=[System.Windows.MessageBox]::Show("No detecto un punto de restauracion reciente (ultimas 24h). Se recomienda crear uno ANTES de aplicar cambios.`n`nSi = crear ahora (vuelve a pulsar APLICAR cuando termine)`nNo = aplicar SIN punto de restauracion`nCancelar = no hacer nada",'Sin punto de restauracion','YesNoCancel','Warning')
        if($rp -eq 'Cancel'){ Write-AXELog 'Aplicacion cancelada (sin punto de restauracion).' 'WARN'; return }
        if($rp -eq 'Yes'){ Write-AXELog 'Creando punto de restauracion primero. Vuelve a pulsar APLICAR al terminar.'; & $script:doRestorePoint; return }
        Write-AXELog 'Aplicando SIN punto de restauracion (opt-out del usuario).' 'WARN'
    }
    $script:applyPreSnap=$script:snapCur   # baseline: ultima medicion (o $null si no midio aun)
    $script:busy=$true
    foreach($b in @($BtnApply,$BtnPreset,$BtnMaster,$BtnRead)){ $b.IsEnabled=$false }
    $ApplyBar.Visibility='Visible'; $ApplyBar.Value=0
    $script:applyTotal=$script:applyQueue.Count; $script:applyDone=0; $script:reboot=$false; $script:changed=0
    $script:applyTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:applyTimer.Interval=[TimeSpan]::FromMilliseconds(1)
    $script:applyTimer.Add_Tick({
        if($script:applyQueue.Count -eq 0){
            $script:applyTimer.Stop()
            if($script:changed -eq 0){ Write-AXELog 'Sin cambios efectivos.' } else { Write-AXELog "$($script:changed) cambio(s) aplicado(s)." }
            if($script:reboot){ Write-AXELog '>>> ALGUNOS CAMBIOS REQUIEREN REINICIAR <<<' 'WARN' }
            # A1: re-habilitar tras completar el refresh async (evita leer estado a medias)
            Refresh-States -Then {
                foreach($b in @($BtnApply,$BtnPreset,$BtnMaster,$BtnRead)){ $b.IsEnabled=$true }
                $ApplyBar.Visibility='Collapsed'; $script:busy=$false
                # Trust & Proof: medir despues (no bloquea; jitter en runspace). Si habia
                # baseline previa, el reporte muestra el delta antes/despues del apply.
                Invoke-AXEMeasure -JitterMs 1000 -OnDone {
                    param($snap,$sc)
                    $pre=$script:applyPreSnap
                    if($pre -and $script:measureOut){ $script:measureOut.Text=(New-AXEReport $pre $snap (Get-AXEScore $pre) $sc) }
                }
            }
            return
        }
        $item=$script:applyQueue.Dequeue(); $tw=$item.Tw
        try {
            if($item.Want){
                if(Test-SnapEligible $tw){ $script:capTweak=$tw.Id }
                try { & $tw.Apply } finally { $script:capTweak=$null }
                Commit-TweakState $tw.Id
                Write-AXELog "APLICADO : $($tw.Name)"
            } else {
                if((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id)){ Write-AXELog "REVERTIDO (estado previo): $($tw.Name)" } else { & $tw.Revert; Write-AXELog "REVERTIDO: $($tw.Name)" }
            }
            $ok=[bool](& $tw.Test)
            if($ok -ne $item.Want){ Write-AXELog "  ! verificacion no coincide en $($tw.Name)" 'WARN' }
            $script:changed++; if($tw.Reboot){ $script:reboot=$true }
        } catch { Write-AXELog "ERROR    : $($tw.Name) -> $($_.Exception.Message)" 'ERR' }
        $script:applyDone++; $ApplyBar.Value=[int](($script:applyDone/$script:applyTotal)*100)
    })
    $script:applyTimer.Start()
})

# Punto de restauracion en runspace (no congela) - portado a WPF.
# Extraido a scriptblock para reutilizarlo desde el gate de APLICAR (H2).
$script:doRestorePoint = {
    if($script:rsPS){ return }
    $BtnRestore.IsEnabled=$false; Write-AXELog 'Creando punto de restauracion en segundo plano...'
    $ps=[PowerShell]::Create()
    [void]$ps.AddScript($script:RestorePointScript.ToString())   # fuente unica en 34-safety.ps1
    [void]$ps.AddArgument("AXE $($script:AXEVersion)")
    $script:rsPS=$ps; $script:rsHandle=$ps.BeginInvoke()
    $t=New-Object System.Windows.Threading.DispatcherTimer; $t.Interval=[TimeSpan]::FromSeconds(1); $script:rsTimer=$t
    $t.Add_Tick({
        if($script:rsHandle.IsCompleted){
            $script:rsTimer.Stop()
            $res=$script:rsPS.EndInvoke($script:rsHandle)
            $script:rsPS.Dispose(); $script:rsPS=$null; $script:rsHandle=$null
            foreach($line in $res){ Write-AXELog "$line" $(if($line -match '^ERROR'){'ERR'}else{'INFO'}) }
            $BtnRestore.IsEnabled=$true
        }
    })
    $t.Start()
}
$BtnRestore.Add_Click($script:doRestorePoint)

# ---- 12.15 init ----
$n = Repair-StartupBackup
if($n -gt 0){ Write-AXELog "Startup backup migrado a formato v5: $n entrada(s)." }
Write-AXELog "AXE $($script:AXEVersion) lista. Tweaks: $($script:CAT.Count)."
Write-AXELog 'Recomendado: crea PRIMERO el punto de restauracion.'
# A4: HW async -> chips + gating + Refresh-States al completar (la ventana ya esta visible)
Start-AXEHardwareLoad

$firstCat = $script:tweakCats | Select-Object -First 1
if($firstCat){ $script:navBtns[$firstCat].IsChecked=$true }

