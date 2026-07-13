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
        $ContentSub.Text = switch($catName){ 'LIMPIEZA'{'Libera espacio en disco'} 'DEBLOAT'{'Quita apps preinstaladas'} 'DNS'{'Servidores DNS rapidos'} 'STARTUP'{'Programas de arranque'} 'PERFILES'{'Plan de energia por-juego (auto)'} 'ASISTENTE IA'{'Recomendaciones locales, sin internet'} default{''} }
        if(-not $script:views.ContainsKey($catName)){ Build-ActionView $catName | Out-Null }
        $script:views[$catName].Visibility='Visible'; return
    }
    if($script:views.ContainsKey($catName)){ $script:views[$catName].Visibility='Visible' }
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
    foreach($catName in $script:tweakCats){
        foreach($e in $script:rows[$catName]){
            $blk = Get-BlockReason $e.Tw
            if($blk -and -not $e.Blocked){
                $e.Blocked=$true; $e.Toggle.IsEnabled=$false; $e.Toggle.IsChecked=$false
                $e.Desc.Foreground=New-AXEBrush 'Red'; $e.Desc.Text="[BLOQUEADO] $blk"
            }
        }
    }
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
        foreach($e in $script:rows[$catName]){ if(-not $e.Blocked -and $e.Tw.Tier -lt 2){ $e.Toggle.IsChecked=$true } }
    }
    Update-AXEPending
    Write-AXELog 'Preset GAMING marcado (Tier 0+1). EXTREMO no se toca. Pulsa APLICAR.'
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
    [void]$ps.AddArgument('AXE v5')
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
Write-AXELog "AXE v5 lista. Tweaks: $($script:CAT.Count)."
Write-AXELog 'Recomendado: crea PRIMERO el punto de restauracion.'
# A4: HW async -> chips + gating + Refresh-States al completar (la ventana ya esta visible)
Start-AXEHardwareLoad

$firstCat = $script:tweakCats | Select-Object -First 1
if($firstCat){ $script:navBtns[$firstCat].IsChecked=$true }

