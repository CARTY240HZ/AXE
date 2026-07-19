# ---- 12.10 vistas de accion ----
function New-ActionButton($text,$brushKey){
    $b=New-Object System.Windows.Controls.Button; $b.Style=$win.FindResource('Pill')
    $b.Background=New-AXEBrush $brushKey; $b.Content=$text; $b.HorizontalAlignment='Left'; $b.Margin=New-Object System.Windows.Thickness(0,0,0,8)
    $b
}
function Build-ActionView($catName){
    $panel=New-Object System.Windows.Controls.StackPanel; $panel.Visibility='Collapsed'
    [void]$ContentHost.Children.Add($panel); $script:views[$catName]=$panel
    switch($catName){
        'LIMPIEZA' {
            # --- monitor auto standby (ISLC-style): purga cuando la RAM libre baja del umbral ---
            $mon=New-Object System.Windows.Controls.StackPanel; $mon.Orientation='Horizontal'; $mon.Margin=New-Object System.Windows.Thickness(0,0,0,4)
            $sbTog=New-Object System.Windows.Controls.CheckBox; $sbTog.Style=$win.FindResource('ToggleSwitch'); $sbTog.VerticalAlignment='Center'
            [System.Windows.Automation.AutomationProperties]::SetName($sbTog,'Auto-limpiar standby cuando la RAM libre baja')
            $sbLbl=New-Object System.Windows.Controls.TextBlock; $sbLbl.Text='Auto-limpiar standby'; $sbLbl.Foreground=New-AXEBrush 'Fg'; $sbLbl.FontWeight='SemiBold'; $sbLbl.VerticalAlignment='Center'; $sbLbl.Margin=New-Object System.Windows.Thickness(10,0,0,0)
            [void]$mon.Children.Add($sbTog); [void]$mon.Children.Add($sbLbl); [void]$panel.Children.Add($mon)
            $sbInfo=New-Object System.Windows.Controls.TextBlock; $sbInfo.Text='Monitor ON: cada 5s, si la RAM libre baja del 15%, AXE purga la standby list. Solo mientras AXE este abierto.'; $sbInfo.Foreground=New-AXEBrush 'Muted'; $sbInfo.FontSize=12; $sbInfo.TextWrapping='Wrap'; $sbInfo.Margin=New-Object System.Windows.Thickness(0,0,0,12)
            [void]$panel.Children.Add($sbInfo)
            $sbTog.Add_Checked({
                if(-not $script:sbTimer){
                    $script:sbTimer=New-Object System.Windows.Threading.DispatcherTimer
                    $script:sbTimer.Interval=[TimeSpan]::FromSeconds(5)
                    # ponytail: umbral fijo 15%, chequeo en UI thread (CIM ya caliente por deteccion HW). Config si alguien lo pide.
                    $script:sbTimer.Add_Tick({
                        if($script:busy){ return }
                        try {
                            $os=Get-CimInstance Win32_OperatingSystem
                            $freePct=$os.FreePhysicalMemory/$os.TotalVisibleMemorySize
                            if($freePct -lt 0.15){
                                $rc=[AXE.Native]::PurgeStandby()
                                if($rc -eq 0){ Write-AXELog ("Auto-standby: RAM libre {0:P0} < 15%, standby purgada." -f $freePct) }
                                elseif($rc -eq -4){ Write-AXELog 'Auto-standby: sin privilegio (ejecuta como admin). Monitor detenido.' 'WARN'; $script:sbTimer.Stop() }
                            }
                        } catch { Write-AXELog "Auto-standby: $($_.Exception.Message)" 'WARN' }
                    })
                }
                $script:sbTimer.Start(); Write-AXELog 'Monitor standby ON (cada 5s, umbral 15%).'
            })
            $sbTog.Add_Unchecked({ if($script:sbTimer){ $script:sbTimer.Stop() }; Write-AXELog 'Monitor standby OFF.' })
            foreach($cl in $script:CLEAN){
                $card=New-Object System.Windows.Controls.Border; $card.Background=New-AXEBrush 'Surface'; $card.BorderBrush=New-AXEBrush 'Line'
                $card.BorderThickness=New-Object System.Windows.Thickness(1); $card.CornerRadius=New-Object System.Windows.CornerRadius(8)
                $card.Padding=New-Object System.Windows.Thickness(14,10,14,10); $card.Margin=New-Object System.Windows.Thickness(0,0,0,8)
                $g=New-Object System.Windows.Controls.Grid
                $ca=New-Object System.Windows.Controls.ColumnDefinition; $ca.Width='*'; $cb=New-Object System.Windows.Controls.ColumnDefinition; $cb.Width='Auto'
                [void]$g.ColumnDefinitions.Add($ca); [void]$g.ColumnDefinitions.Add($cb)
                $sp=New-Object System.Windows.Controls.StackPanel
                $t=New-Object System.Windows.Controls.TextBlock; $t.Text=$cl.Name; $t.FontWeight='SemiBold'
                $d=New-Object System.Windows.Controls.TextBlock; $d.Text=$cl.Desc; $d.Foreground=New-AXEBrush 'Muted'; $d.FontSize=12; $d.TextWrapping='Wrap'; $d.Margin=New-Object System.Windows.Thickness(0,3,10,0)
                [void]$sp.Children.Add($t); [void]$sp.Children.Add($d); [System.Windows.Controls.Grid]::SetColumn($sp,0); [void]$g.Children.Add($sp)
                $btn=New-Object System.Windows.Controls.Button; $btn.Style=$win.FindResource('Pill'); $btn.Background=New-AXEBrush 'Accent'; $btn.Content='Ejecutar'; $btn.VerticalAlignment='Center'; $btn.Margin=New-Object System.Windows.Thickness(0)
                $btn.Tag=$cl
                $btn.Add_Click({ param($s,$e)
                    $act=$s.Tag; Write-AXELog "Limpieza: $($act.Name)..."
                    Start-AXEJob -Work { param($src) & ([scriptblock]::Create($src)) } -JobArgs @([string]$act.Run.ToString()) -Button $s
                })
                [System.Windows.Controls.Grid]::SetColumn($btn,1); [void]$g.Children.Add($btn)
                $card.Child=$g; [void]$panel.Children.Add($card)
            }
        }
        'DEBLOAT' {
            $script:debloatChecks=New-Object System.Collections.ArrayList
            foreach($app in $script:DEBLOAT){
                $cb=New-Object System.Windows.Controls.CheckBox; $cb.Content=$app.Name; $cb.Foreground=New-AXEBrush 'Fg'; $cb.Margin=New-Object System.Windows.Thickness(2,4,0,4); $cb.Tag=$app.Pkg
                if(-not (Get-DebloatInstalled $app.Pkg)){ $cb.IsEnabled=$false; $cb.Content="$($app.Name)  (no instalada)"; $cb.Foreground=New-AXEBrush 'Muted' }
                [void]$panel.Children.Add($cb); [void]$script:debloatChecks.Add($cb)
            }
            $btn=New-ActionButton 'Quitar seleccionadas' 'Red'; $btn.Margin=New-Object System.Windows.Thickness(0,10,0,0)
            $btn.Add_Click({ param($s,$e)
                $sel=@(); foreach($cb in $script:debloatChecks){ if($cb.IsEnabled -and $cb.IsChecked){ $sel+=[string]$cb.Tag } }
                if($sel.Count -eq 0){ Write-AXELog 'Sin apps seleccionadas.' 'WARN'; return }
                Write-AXELog "Quitando $($sel.Count) app(s) en segundo plano..."
                Start-AXEJob -Button $s -JobArgs @([string]($sel -join ',')) -Work {
                    param($csv)
                    $out=@()
                    foreach($pkg in ($csv -split ',')){
                        $p=Get-AppxPackage -Name $pkg -EA SilentlyContinue
                        if($p){ try{ $p | Remove-AppxPackage -EA Stop; $out+="Quitada app: $pkg" } catch { $out+="ERROR quitando $pkg : $($_.Exception.Message)" } }
                        else { $out+="No instalada: $pkg" }
                    }
                    $out+="$(@($csv -split ',').Count) app(s) procesadas."
                    $out
                }
            })
            [void]$panel.Children.Add($btn)
        }
        'DNS' {
            foreach($dns in $script:DNSPROFILES){
                $b=New-ActionButton $dns.Name 'Accent'; $b.Tag=$dns.V4
                $b.Add_Click({ param($s,$e)
                    $nic=[string]$script:HW.NicName
                    $csv=$(if($s.Tag){ ($s.Tag -join ',') } else { '' })
                    Write-AXELog 'Aplicando DNS en segundo plano...'
                    Start-AXEJob -Button $s -JobArgs @($nic,[string]$csv) -Work {
                        param($nic,$serverCsv)
                        if(-not $nic){ return @('WARN Sin adaptador activo detectado') }
                        if([string]::IsNullOrEmpty($serverCsv)){ Set-DnsClientServerAddress -InterfaceAlias $nic -ResetServerAddresses; $msg='DNS -> automatico (DHCP)' }
                        else { Set-DnsClientServerAddress -InterfaceAlias $nic -ServerAddresses ($serverCsv -split ','); $msg="DNS -> $($serverCsv -replace ',',', ')" }
                        Clear-DnsClientCache
                        @($msg)
                    }
                })
                $lbl=New-Object System.Windows.Controls.TextBlock; $lbl.Text=$(if($dns.V4){$dns.V4 -join '   /   '}else{'quita DNS manual (DHCP)'}); $lbl.Foreground=New-AXEBrush 'Muted'; $lbl.FontSize=12; $lbl.Margin=New-Object System.Windows.Thickness(2,0,0,10)
                [void]$panel.Children.Add($b); [void]$panel.Children.Add($lbl)
            }
        }
        'STARTUP' {
            $script:startupChecks=New-Object System.Collections.ArrayList
            foreach($ar in (Get-Autoruns)){
                $cb=New-Object System.Windows.Controls.CheckBox; $cb.Content="[$($ar.Hive)] $($ar.Name)"; $cb.Foreground=New-AXEBrush 'Fg'; $cb.Margin=New-Object System.Windows.Thickness(2,4,0,2); $cb.Tag=$ar
                $cb.ToolTip=$ar.Value
                [void]$panel.Children.Add($cb); [void]$script:startupChecks.Add($cb)
            }
            $row=New-Object System.Windows.Controls.StackPanel; $row.Orientation='Horizontal'; $row.Margin=New-Object System.Windows.Thickness(0,10,0,0)
            $bDis=New-ActionButton 'Desactivar' 'Amber'
            $bDis.Add_Click({
                if($script:busy){ Write-AXELog 'Otra operacion en curso, espera a que termine.' 'WARN'; return }   # H10/H11 mutex
                $n=0; foreach($cb in $script:startupChecks){ if($cb.IsChecked){ Disable-Autorun $cb.Tag; $n++ } }
                Write-AXELog "$n autorun(s) desactivado(s)."
            })
            $bRes=New-ActionButton 'Restaurar backup' 'Green'
            $bRes.Add_Click({
                if($script:busy){ Write-AXELog 'Otra operacion en curso, espera a que termine.' 'WARN'; return }   # H10/H11 mutex
                Restore-Autorun | Out-Null
            })
            [void]$row.Children.Add($bDis); [void]$row.Children.Add($bRes); [void]$panel.Children.Add($row)
        }
        'PERFILES' {
            # --- fila monitor automatico ---
            $mon=New-Object System.Windows.Controls.StackPanel; $mon.Orientation='Horizontal'; $mon.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            $script:profMonTog=New-Object System.Windows.Controls.CheckBox; $script:profMonTog.Style=$win.FindResource('ToggleSwitch'); $script:profMonTog.VerticalAlignment='Center'
            [System.Windows.Automation.AutomationProperties]::SetName($script:profMonTog,'Monitor automatico de perfiles por juego')
            $monLbl=New-Object System.Windows.Controls.TextBlock; $monLbl.Text='Monitor automatico'; $monLbl.Foreground=New-AXEBrush 'Fg'; $monLbl.FontWeight='SemiBold'; $monLbl.VerticalAlignment='Center'; $monLbl.Margin=New-Object System.Windows.Thickness(10,0,0,0)
            [void]$mon.Children.Add($script:profMonTog); [void]$mon.Children.Add($monLbl); [void]$panel.Children.Add($mon)
            $info=New-Object System.Windows.Controls.TextBlock; $info.Text='Monitor ON: al abrir un juego con perfil, AXE cambia su plan de energia; al cerrarlo lo restaura. No toca el proceso del juego (0 riesgo anticheat).'; $info.Foreground=New-AXEBrush 'Muted'; $info.FontSize=12; $info.TextWrapping='Wrap'; $info.Margin=New-Object System.Windows.Thickness(0,0,0,12)
            [void]$panel.Children.Add($info)
            $script:profMonTog.Add_Checked({
                if(-not $script:profTimer){
                    $script:profTimer=New-Object System.Windows.Threading.DispatcherTimer
                    $script:profTimer.Interval=[TimeSpan]::FromSeconds(4)
                    $script:profTimer.Add_Tick({ try { Tick-GameProfiles | Out-Null } catch { Write-AXELog "Monitor perfiles: $($_.Exception.Message)" 'ERR' } })
                }
                $script:profTimer.Start(); Write-AXELog 'Monitor de perfiles ON (revisa cada 4s).'
            })
            $script:profMonTog.Add_Unchecked({ if($script:profTimer){ $script:profTimer.Stop() }; Revert-GameProfile; Write-AXELog 'Monitor de perfiles OFF.' })

            # --- lista de perfiles existentes ---
            $listPanel=New-Object System.Windows.Controls.StackPanel; $listPanel.Margin=New-Object System.Windows.Thickness(0,0,0,10); [void]$panel.Children.Add($listPanel)
            $script:profRefreshList={
                $listPanel.Children.Clear()
                $profs=@(Read-Profiles)
                if($profs.Count -eq 0){
                    $e=New-Object System.Windows.Controls.TextBlock; $e.Text='Sin perfiles todavia. Crea uno abajo.'; $e.Foreground=New-AXEBrush 'Muted'; $e.FontSize=12; [void]$listPanel.Children.Add($e); return
                }
                foreach($p in $profs){
                    $card=New-Object System.Windows.Controls.Border; $card.Background=New-AXEBrush 'Surface'; $card.BorderBrush=New-AXEBrush 'Line'; $card.BorderThickness=New-Object System.Windows.Thickness(1); $card.CornerRadius=New-Object System.Windows.CornerRadius(8); $card.Padding=New-Object System.Windows.Thickness(14,10,14,10); $card.Margin=New-Object System.Windows.Thickness(0,0,0,6)
                    $g=New-Object System.Windows.Controls.Grid
                    $c0=New-Object System.Windows.Controls.ColumnDefinition; $c0.Width='*'; $c1=New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='Auto'
                    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
                    $t=New-Object System.Windows.Controls.TextBlock; $t.Text="$($p.Name)    [$($p.Exe)]    ->  $($p.PlanName)"; $t.Foreground=New-AXEBrush 'Fg'; $t.VerticalAlignment='Center'; $t.TextWrapping='Wrap'
                    [System.Windows.Controls.Grid]::SetColumn($t,0); [void]$g.Children.Add($t)
                    $bb=New-Object System.Windows.Controls.StackPanel; $bb.Orientation='Horizontal'; [System.Windows.Controls.Grid]::SetColumn($bb,1)
                    $ba=New-Object System.Windows.Controls.Button; $ba.Style=$win.FindResource('Pill'); $ba.Background=New-AXEBrush 'Accent'; $ba.Content='Aplicar'; $ba.Height=28; $ba.Padding=New-Object System.Windows.Thickness(12,0,12,0); $ba.Margin=New-Object System.Windows.Thickness(0,0,6,0); $ba.Tag=$p
                    [System.Windows.Automation.AutomationProperties]::SetName($ba,"Aplicar perfil $($p.Name) ahora")
                    $ba.Add_Click({ param($s,$e) if($script:busy){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }; Apply-GameProfile $s.Tag })
                    $bd=New-Object System.Windows.Controls.Button; $bd.Style=$win.FindResource('PillDanger'); $bd.Content='Borrar'; $bd.Height=28; $bd.Padding=New-Object System.Windows.Thickness(12,0,12,0); $bd.Tag=$p.Name
                    [System.Windows.Automation.AutomationProperties]::SetName($bd,"Borrar perfil $($p.Name)")
                    $bd.Add_Click({ param($s,$e) if($script:profActive -eq $s.Tag){ Revert-GameProfile }; Remove-GameProfile $s.Tag; & $script:profRefreshList; Write-AXELog "Perfil '$($s.Tag)' borrado." })
                    [void]$bb.Children.Add($ba); [void]$bb.Children.Add($bd); [void]$g.Children.Add($bb)
                    $card.Child=$g; [void]$listPanel.Children.Add($card)
                }
            }

            # --- formulario de alta ---
            $form=New-Object System.Windows.Controls.Border; $form.Background=New-AXEBrush 'Surface'; $form.BorderBrush=New-AXEBrush 'Line'; $form.BorderThickness=New-Object System.Windows.Thickness(1); $form.CornerRadius=New-Object System.Windows.CornerRadius(8); $form.Padding=New-Object System.Windows.Thickness(14)
            $fp=New-Object System.Windows.Controls.StackPanel
            $ft=New-Object System.Windows.Controls.TextBlock; $ft.Text='Nuevo perfil'; $ft.FontWeight='SemiBold'; $ft.Foreground=New-AXEBrush 'Fg'; $ft.Margin=New-Object System.Windows.Thickness(0,0,0,8); [void]$fp.Children.Add($ft)
            $nameBox=New-Object System.Windows.Controls.TextBox; $nameBox.Style=$win.FindResource('Input'); $nameBox.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            [System.Windows.Automation.AutomationProperties]::SetName($nameBox,'Nombre del perfil'); [void]$fp.Children.Add($nameBox)
            $nameHint=New-Object System.Windows.Controls.TextBlock; $nameHint.Text='Nombre del perfil (ej: CS2 gaming)'; $nameHint.Foreground=New-AXEBrush 'Muted'; $nameHint.FontSize=11; $nameHint.Margin=New-Object System.Windows.Thickness(2,0,0,8); [void]$fp.Children.Add($nameHint)
            $procRow=New-Object System.Windows.Controls.Grid; $pr0=New-Object System.Windows.Controls.ColumnDefinition; $pr0.Width='*'; $pr1=New-Object System.Windows.Controls.ColumnDefinition; $pr1.Width='Auto'; [void]$procRow.ColumnDefinitions.Add($pr0); [void]$procRow.ColumnDefinitions.Add($pr1); $procRow.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            $procCombo=New-Object System.Windows.Controls.ComboBox; $procCombo.IsEditable=$true; $procCombo.Margin=New-Object System.Windows.Thickness(0,0,6,0)
            [System.Windows.Automation.AutomationProperties]::SetName($procCombo,'Proceso del juego'); [System.Windows.Controls.Grid]::SetColumn($procCombo,0); [void]$procRow.Children.Add($procCombo)
            $procBtn=New-Object System.Windows.Controls.Button; $procBtn.Style=$win.FindResource('PillGhost'); $procBtn.Content='Refrescar'; $procBtn.Height=32; [System.Windows.Controls.Grid]::SetColumn($procBtn,1); [void]$procRow.Children.Add($procBtn); [void]$fp.Children.Add($procRow)
            $procHint=New-Object System.Windows.Controls.TextBlock; $procHint.Text='Proceso del juego (elige de la lista o escribe, sin .exe). Abre el juego y pulsa Refrescar.'; $procHint.Foreground=New-AXEBrush 'Muted'; $procHint.FontSize=11; $procHint.TextWrapping='Wrap'; $procHint.Margin=New-Object System.Windows.Thickness(2,0,0,8); [void]$fp.Children.Add($procHint)
            $planCombo=New-Object System.Windows.Controls.ComboBox; $planCombo.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            [System.Windows.Automation.AutomationProperties]::SetName($planCombo,'Plan de energia'); [void]$fp.Children.Add($planCombo)
            $planHint=New-Object System.Windows.Controls.TextBlock; $planHint.Text='Plan de energia a activar mientras el juego corre.'; $planHint.Foreground=New-AXEBrush 'Muted'; $planHint.FontSize=11; $planHint.Margin=New-Object System.Windows.Thickness(2,0,0,10); [void]$fp.Children.Add($planHint)
            $saveBtn=New-Object System.Windows.Controls.Button; $saveBtn.Style=$win.FindResource('Pill'); $saveBtn.Background=New-AXEBrush 'Accent'; $saveBtn.Content='Guardar perfil'; $saveBtn.HorizontalAlignment='Left'
            [System.Windows.Automation.AutomationProperties]::SetName($saveBtn,'Guardar perfil'); [void]$fp.Children.Add($saveBtn)
            $form.Child=$fp; [void]$panel.Children.Add($form)

            # rellenar combos + lista
            $fillProcs={ $procCombo.Items.Clear(); foreach($pn in @(Get-Process -EA SilentlyContinue | Where-Object { $_.MainWindowTitle } | Select-Object -ExpandProperty ProcessName -Unique | Sort-Object)){ [void]$procCombo.Items.Add($pn) } }
            $fillPlans={ $planCombo.Items.Clear(); foreach($pl in (Get-PowerPlans)){ $it=New-Object System.Windows.Controls.ComboBoxItem; $it.Content=$pl.Name; $it.Tag=$pl.Guid; [void]$planCombo.Items.Add($it) }; if($planCombo.Items.Count -gt 0){ $planCombo.SelectedIndex=0 } }
            $procBtn.Add_Click($fillProcs)
            $saveBtn.Add_Click({ param($s,$e)
                $nm=$nameBox.Text.Trim(); $ex=[string]$procCombo.Text; if([string]::IsNullOrWhiteSpace($ex) -and $procCombo.SelectedItem){ $ex=[string]$procCombo.SelectedItem }
                $pi=$planCombo.SelectedItem
                if([string]::IsNullOrWhiteSpace($nm) -or [string]::IsNullOrWhiteSpace($ex) -or -not $pi){ Write-AXELog 'Rellena nombre, proceso y plan.' 'WARN'; return }
                [void](Add-GameProfile $nm $ex $pi.Tag ([string]$pi.Content))
                $nameBox.Clear(); Write-AXELog "Perfil '$nm' guardado ($ex -> $($pi.Content))."
                & $script:profRefreshList
            })
            & $fillProcs; & $fillPlans; & $script:profRefreshList

        }
        'FPS' {
            # ================= FPS: subirlos (10c) y MEDIRLOS (10d) =================
            # Pestana propia y no un apartado de PERFILES: es lo unico de toda la suite que
            # sube FPS de verdad, y estaba enterrado bajo los planes de energia. Aparte, aqui
            # conviven la palanca y su medicion a proposito -- aplicar sin medir es como se
            # llega a un catalogo lleno de placebos, que es justo lo que este proyecto corrigio.
            # ================= GPU POR JUEGO (region 10c) =================
            # Va en esta pestana y no en una nueva porque es la misma idea (ajuste por juego,
            # no global), pero OJO: los perfiles de arriba guardan NOMBRE DE PROCESO y esto
            # necesita RUTA COMPLETA. Windows indexa UserGpuPreferences por ruta, asi que un
            # nombre suelto crearia una entrada que el sistema no mira nunca. De ahi el
            # selector de fichero y que el combo muestre la ruta resuelta, no solo el nombre.
            $gpuHdr=New-Object System.Windows.Controls.TextBlock; $gpuHdr.Text='GPU por juego'; $gpuHdr.FontWeight='SemiBold'; $gpuHdr.FontSize=15; $gpuHdr.Foreground=New-AXEBrush 'Fg'; $gpuHdr.Margin=New-Object System.Windows.Thickness(0,18,0,4); [void]$panel.Children.Add($gpuHdr)

            $gpuInfo=New-Object System.Windows.Controls.TextBlock; $gpuInfo.Foreground=New-AXEBrush 'Muted'; $gpuInfo.FontSize=12; $gpuInfo.TextWrapping='Wrap'; $gpuInfo.Margin=New-Object System.Windows.Thickness(0,0,0,10)
            # El texto NO promete ganancia: la dice segun la maquina. En equipo de una sola
            # GPU, forzar la "dedicada" no existe y fingirlo seria justo el fallo que este
            # proyecto persigue en el resto del catalogo.
            $gpuInfo.Text = if(Test-AXEHybridGpu){
                "Equipo HIBRIDO ($(((Get-AXEGpuList | Select-Object -Expand Name) -join ' + '))). Forzar la GPU dedicada en un juego es el mayor lever de FPS de toda la suite: si Windows lo estaba corriendo en la integrada, no es un 3%, son 2-5x. Los cambios entran al ARRANCAR el juego."
            } else {
                "Una sola GPU ($((Get-AXEGpuList | Select-Object -First 1 -Expand Name))). 'GPU alto rendimiento' no aplica aqui: no hay otra entre la que elegir, ganancia por esa via = 0. El flip model (juegos en ventana) si sirve."
            }
            [void]$panel.Children.Add($gpuInfo)

            # El panel va en scope SCRIPT, no local. $script:gpuRefreshList se invoca despues de
            # que Build-ActionView haya retornado (desde el boton 'Deshacer' y desde el harness),
            # y PowerShell resuelve las variables de un scriptblock EN EL MOMENTO DE LLAMARLO: una
            # local ya no existe entonces y '.Children.Clear()' revienta con "No se puede llamar a
            # un metodo en una expresion con valor NULL".
            #   .GetNewClosure() tampoco vale aqui: crea un scope de modulo propio donde los
            # '$script:*' de este fichero (GpuPrefKey, LayersKey) dejan de resolver, y el fallo se
            # muda a "No se puede enlazar el argumento al parametro 'Path' porque es nulo".
            # Scope script es ademas el idiom que ya usa el resto de la GUI ($script:profMonTog,
            # $script:aiOut, $script:scoreLbl).
            $script:gpuListPanel=New-Object System.Windows.Controls.StackPanel; $script:gpuListPanel.Margin=New-Object System.Windows.Thickness(0,0,0,10); [void]$panel.Children.Add($script:gpuListPanel)
            $script:gpuRefreshList={
                $script:gpuListPanel.Children.Clear()
                $k=Get-Item $script:GpuPrefKey -EA SilentlyContinue
                $names=if($k){ @($k.GetValueNames()) } else { @() }
                if($names.Count -eq 0){
                    $e=New-Object System.Windows.Controls.TextBlock; $e.Text='Sin ajustes por juego. Windows decide la GPU de todo por heuristica.'; $e.Foreground=New-AXEBrush 'Muted'; $e.FontSize=12; [void]$script:gpuListPanel.Children.Add($e); return
                }
                foreach($n in $names){
                    $st=Get-AXEGameGpuState $n
                    # 'Windows decide' (clave ausente) != 'delegado' (0 explicito). Se distinguen
                    # a posta: uno es estado de fabrica, el otro lo escribio alguien.
                    $pv=(ConvertFrom-AXEGpuPref $st.Raw)['GpuPreference']
                    $gtxt=switch($pv){ '2'{'dGPU'} '1'{'iGPU'} '0'{'delegado'} default{'Windows decide'} }
                    $card=New-Object System.Windows.Controls.Border; $card.Background=New-AXEBrush 'Surface'; $card.BorderBrush=New-AXEBrush 'Line'; $card.BorderThickness=New-Object System.Windows.Thickness(1); $card.CornerRadius=New-Object System.Windows.CornerRadius(8); $card.Padding=New-Object System.Windows.Thickness(14,10,14,10); $card.Margin=New-Object System.Windows.Thickness(0,0,0,6)
                    $g=New-Object System.Windows.Controls.Grid
                    $c0=New-Object System.Windows.Controls.ColumnDefinition; $c0.Width='*'; $c1=New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='Auto'
                    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)
                    $t=New-Object System.Windows.Controls.TextBlock; $t.Text="$(Split-Path $n -Leaf)    [$gtxt]    flip: $(if($st.FlipModel){'si'}else{'no'})    FSO: $(if($st.NoFSO){'off'}else{'on'})"; $t.Foreground=New-AXEBrush 'Fg'; $t.VerticalAlignment='Center'; $t.TextWrapping='Wrap'; $t.ToolTip=$n
                    [System.Windows.Controls.Grid]::SetColumn($t,0); [void]$g.Children.Add($t)
                    $bu=New-Object System.Windows.Controls.Button; $bu.Style=$win.FindResource('PillDanger'); $bu.Content='Deshacer'; $bu.Height=28; $bu.Padding=New-Object System.Windows.Thickness(12,0,12,0); $bu.Tag=$n
                    [System.Windows.Automation.AutomationProperties]::SetName($bu,"Deshacer ajustes de GPU de $(Split-Path $n -Leaf)")
                    $bu.Add_Click({ param($s,$e)
                        $r=Revert-AXEGameGpu $s.Tag
                        # 0 = AXE nunca capturo ese exe (lo escribio Windows o el usuario). No se
                        # inventa un original: se dice y se deja como esta.
                        if($r -eq 0){ Write-AXELog "GPU '$(Split-Path $s.Tag -Leaf)': sin captura previa de AXE, no revierto (escribir un default seria dejarte un estado que quiza nunca tuviste)." 'WARN' }
                        else { Write-AXELog "GPU '$(Split-Path $s.Tag -Leaf)': restauradas $r clave(s) al estado exacto anterior." }
                        & $script:gpuRefreshList
                    })
                    [System.Windows.Controls.Grid]::SetColumn($bu,1); [void]$g.Children.Add($bu)
                    $card.Child=$g; [void]$script:gpuListPanel.Children.Add($card)
                }
            }

            # --- alta: selector de ejecutable ---
            $gform=New-Object System.Windows.Controls.Border; $gform.Background=New-AXEBrush 'Surface'; $gform.BorderBrush=New-AXEBrush 'Line'; $gform.BorderThickness=New-Object System.Windows.Thickness(1); $gform.CornerRadius=New-Object System.Windows.CornerRadius(8); $gform.Padding=New-Object System.Windows.Thickness(14)
            $gfp=New-Object System.Windows.Controls.StackPanel
            $gft=New-Object System.Windows.Controls.TextBlock; $gft.Text='Optimizar un juego'; $gft.FontWeight='SemiBold'; $gft.Foreground=New-AXEBrush 'Fg'; $gft.Margin=New-Object System.Windows.Thickness(0,0,0,8); [void]$gfp.Children.Add($gft)
            $exeRow=New-Object System.Windows.Controls.Grid; $er0=New-Object System.Windows.Controls.ColumnDefinition; $er0.Width='*'; $er1=New-Object System.Windows.Controls.ColumnDefinition; $er1.Width='Auto'; [void]$exeRow.ColumnDefinitions.Add($er0); [void]$exeRow.ColumnDefinitions.Add($er1); $exeRow.Margin=New-Object System.Windows.Thickness(0,0,0,6)
            $exeCombo=New-Object System.Windows.Controls.ComboBox; $exeCombo.IsEditable=$true; $exeCombo.Margin=New-Object System.Windows.Thickness(0,0,6,0)
            [System.Windows.Automation.AutomationProperties]::SetName($exeCombo,'Ruta del ejecutable del juego'); [System.Windows.Controls.Grid]::SetColumn($exeCombo,0); [void]$exeRow.Children.Add($exeCombo)
            $exeBtn=New-Object System.Windows.Controls.Button; $exeBtn.Style=$win.FindResource('PillGhost'); $exeBtn.Content='Examinar...'; $exeBtn.Height=32; [System.Windows.Controls.Grid]::SetColumn($exeBtn,1); [void]$exeRow.Children.Add($exeBtn); [void]$gfp.Children.Add($exeRow)
            $exeHint=New-Object System.Windows.Controls.TextBlock; $exeHint.Text='Ruta COMPLETA del .exe. El combo lista los juegos abiertos ahora con su ruta ya resuelta; si no esta, usa Examinar.'; $exeHint.Foreground=New-AXEBrush 'Muted'; $exeHint.FontSize=11; $exeHint.TextWrapping='Wrap'; $exeHint.Margin=New-Object System.Windows.Thickness(2,0,0,8); [void]$gfp.Children.Add($exeHint)
            $fsoChk=New-Object System.Windows.Controls.CheckBox; $fsoChk.Content='Apagar tambien Fullscreen Optimizations (opt-in)'; $fsoChk.Foreground=New-AXEBrush 'Fg'; $fsoChk.Margin=New-Object System.Windows.Thickness(0,0,0,4); [void]$gfp.Children.Add($fsoChk)
            $fsoHint=New-Object System.Windows.Controls.TextBlock; $fsoHint.Text='Sin marcar por defecto: en muchos juegos FSO ya usa flip model y quitarlo NO da FPS, solo empeora el alt-tab. Marcalo si mides que te mejora.'; $fsoHint.Foreground=New-AXEBrush 'Muted'; $fsoHint.FontSize=11; $fsoHint.TextWrapping='Wrap'; $fsoHint.Margin=New-Object System.Windows.Thickness(2,0,0,10); [void]$gfp.Children.Add($fsoHint)
            $gpuBtn=New-Object System.Windows.Controls.Button; $gpuBtn.Style=$win.FindResource('Pill'); $gpuBtn.Background=New-AXEBrush 'Accent'; $gpuBtn.Content='Optimizar GPU'; $gpuBtn.HorizontalAlignment='Left'
            [System.Windows.Automation.AutomationProperties]::SetName($gpuBtn,'Optimizar la GPU de este juego'); [void]$gfp.Children.Add($gpuBtn)
            $gform.Child=$gfp; [void]$panel.Children.Add($gform)

            # Procesos con ventana Y ruta legible. El .Path de un proceso elevado o protegido
            # lanza, por eso el try: se omite en vez de tumbar el rellenado entero.
            $fillExes={
                $exeCombo.Items.Clear()
                foreach($pr in @(Get-Process -EA SilentlyContinue | Where-Object { $_.MainWindowTitle })){
                    try { if($pr.Path){ [void]$exeCombo.Items.Add($pr.Path) } } catch {}
                }
            }
            $exeBtn.Add_Click({ param($s,$e)
                $dlg=New-Object Microsoft.Win32.OpenFileDialog
                $dlg.Filter='Ejecutables (*.exe)|*.exe'; $dlg.Title='Elige el ejecutable del juego'
                if($dlg.ShowDialog()){ $exeCombo.Text=$dlg.FileName }
            })
            $gpuBtn.Add_Click({ param($s,$e)
                $ex=[string]$exeCombo.Text; if([string]::IsNullOrWhiteSpace($ex) -and $exeCombo.SelectedItem){ $ex=[string]$exeCombo.SelectedItem }
                if([string]::IsNullOrWhiteSpace($ex)){ Write-AXELog 'Elige el ejecutable del juego.' 'WARN'; return }
                # Optimize-AXEGame ya valida que la ruta exista y devuelve el motivo si no.
                foreach($l in (Optimize-AXEGame -Exe $ex -NoFSO:([bool]$fsoChk.IsChecked))){ Write-AXELog $l }
                & $script:gpuRefreshList
            })
            & $fillExes; & $script:gpuRefreshList

            # --- MEDICION REAL (region 10d) ---
            $mHdr=New-Object System.Windows.Controls.TextBlock; $mHdr.Text='Medir FPS reales'; $mHdr.FontWeight='SemiBold'; $mHdr.FontSize=15; $mHdr.Foreground=New-AXEBrush 'Fg'; $mHdr.Margin=New-Object System.Windows.Thickness(0,18,0,4); [void]$panel.Children.Add($mHdr)
            $mInfo=New-Object System.Windows.Controls.TextBlock; $mInfo.Foreground=New-AXEBrush 'Muted'; $mInfo.FontSize=12; $mInfo.TextWrapping='Wrap'; $mInfo.Margin=New-Object System.Windows.Thickness(0,0,0,10); [void]$panel.Children.Add($mInfo)
            $pmPath=Get-AXEPresentMon
            $mInfo.Text = if($pmPath){
                "PresentMon: $pmPath`nMide el tiempo entre frames PRESENTADOS (la fuente que usan las reviews). El 1% low es lo que mueven los ajustes de esta suite; la media casi no se entera."
            } else {
                'PresentMon no encontrado. Bajalo de github.com/GameTechDev/PresentMon/releases y deja PresentMon.exe junto a AXE. AXE no lo descarga solo: bajar y ejecutar binarios de internet no es cosa de una herramienta que corre como admin.'
            }
            $mOut=New-Object System.Windows.Controls.TextBox; $mOut.IsReadOnly=$true; $mOut.Background=New-AXEBrush 'Surface'; $mOut.Foreground=New-AXEBrush 'Fg'; $mOut.BorderBrush=New-AXEBrush 'Line'; $mOut.BorderThickness=New-Object System.Windows.Thickness(1); $mOut.FontFamily='Consolas'; $mOut.FontSize=12; $mOut.MinHeight=110; $mOut.TextWrapping='NoWrap'; $mOut.VerticalScrollBarVisibility='Auto'; $mOut.Padding=New-Object System.Windows.Thickness(10,10,10,10); $mOut.Margin=New-Object System.Windows.Thickness(0,0,0,8)
            $mOut.Text='Sin medir todavia.'
            $script:fpsOut=$mOut; [void]$panel.Children.Add($mOut)
            $mRow=New-Object System.Windows.Controls.StackPanel; $mRow.Orientation='Horizontal'
            $mBtn=New-Object System.Windows.Controls.Button; $mBtn.Style=$win.FindResource('Pill'); $mBtn.Background=New-AXEBrush 'Accent'; $mBtn.Content='Medir 20s'; $mBtn.Margin=New-Object System.Windows.Thickness(0,0,6,0)
            [System.Windows.Automation.AutomationProperties]::SetName($mBtn,'Medir FPS del juego seleccionado durante 20 segundos')
            $mBase=New-Object System.Windows.Controls.Button; $mBase.Style=$win.FindResource('PillGhost'); $mBase.Content='Guardar como ANTES'; $mBase.Margin=New-Object System.Windows.Thickness(0,0,6,0)
            [System.Windows.Automation.AutomationProperties]::SetName($mBase,'Guardar la ultima medicion como referencia ANTES')
            $mCmp=New-Object System.Windows.Controls.Button; $mCmp.Style=$win.FindResource('PillGhost'); $mCmp.Content='Comparar con ANTES'
            [System.Windows.Automation.AutomationProperties]::SetName($mCmp,'Comparar la ultima medicion con la referencia ANTES')
            [void]$mRow.Children.Add($mBtn); [void]$mRow.Children.Add($mBase); [void]$mRow.Children.Add($mCmp); [void]$panel.Children.Add($mRow)

            # El flujo es en TRES pasos manuales (medir / guardar ANTES / comparar) y no un
            # boton unico de "antes y despues", porque entre las dos capturas hay que aplicar el
            # cambio Y volver a la MISMA escena. Un boton que lo hiciera solo produciria
            # comparaciones de escenas distintas con pinta de rigor.
            $mBtn.Add_Click({ param($s,$e)
                if($script:busy){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }   # H10/H11 mutex
                $ex=[string]$exeCombo.Text; if([string]::IsNullOrWhiteSpace($ex) -and $exeCombo.SelectedItem){ $ex=[string]$exeCombo.SelectedItem }
                if([string]::IsNullOrWhiteSpace($ex)){ Write-AXELog 'Elige arriba el ejecutable del juego que quieres medir.' 'WARN'; return }
                $name=[System.IO.Path]::GetFileNameWithoutExtension($ex)
                $script:fpsOut.Text="Midiendo 20s de $name... (la ventana se queda quieta mientras tanto)"
                $script:fpsOut.Dispatcher.Invoke([action]{},'Render')   # pinta el aviso antes de bloquear
                $r=Measure-AXEFps -ProcessName $name -Seconds 20
                $script:fpsLast=$r
                $script:fpsOut.Text=((Format-AXEFpsStats $r 'Ultima') -join "`r`n")
                foreach($l in (Format-AXEFpsStats $r 'FPS')){ Write-AXELog $l }
            })
            $mBase.Add_Click({ param($s,$e)
                if(-not $script:fpsLast -or -not $script:fpsLast.Ok){ Write-AXELog 'No hay una medicion valida que guardar. Mide primero.' 'WARN'; return }
                $script:fpsBefore=$script:fpsLast
                $script:fpsOut.Text=(((Format-AXEFpsStats $script:fpsBefore 'ANTES (guardado)') -join "`r`n") + "`r`n`r`nAhora aplica el cambio, vuelve a la MISMA escena y pulsa Medir otra vez.")
                Write-AXELog 'Referencia ANTES guardada.'
            })
            $mCmp.Add_Click({ param($s,$e)
                if(-not $script:fpsBefore){ Write-AXELog 'Falta la referencia ANTES. Mide, pulsa Guardar como ANTES, aplica el cambio y vuelve a medir.' 'WARN'; return }
                if(-not $script:fpsLast -or -not $script:fpsLast.Ok){ Write-AXELog 'Falta una medicion valida DESPUES.' 'WARN'; return }
                $v=Get-AXEFpsVerdict -Before $script:fpsBefore -After $script:fpsLast
                $txt=@()
                $txt+=(Format-AXEFpsStats $script:fpsBefore 'ANTES')
                $txt+=(Format-AXEFpsStats $script:fpsLast  'DESPUES')
                $txt+=''
                $txt+=$(if($v.Conclusive){ "VEREDICTO: CONCLUYENTE - $($v.Reason)" } else { "VEREDICTO: NO CONCLUYENTE - $($v.Reason)" })
                if($v.Warning){ $txt+="AVISO: $($v.Warning)" }
                $script:fpsOut.Text=($txt -join "`r`n")
                foreach($l in $txt){ if($l){ Write-AXELog $l } }
            })
        }
        'ASISTENTE IA' {
            $script:aiOut=New-Object System.Windows.Controls.TextBox; $script:aiOut.IsReadOnly=$true; $script:aiOut.Background=New-AXEBrush 'Surface'; $script:aiOut.Foreground=New-AXEBrush 'Fg'
            $script:aiOut.BorderBrush=New-AXEBrush 'Line'; $script:aiOut.BorderThickness=New-Object System.Windows.Thickness(1); $script:aiOut.Padding=New-Object System.Windows.Thickness(12,8,12,8)
            $script:aiOut.Height=340; $script:aiOut.TextWrapping='Wrap'; $script:aiOut.VerticalScrollBarVisibility='Auto'; $script:aiOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:aiOut.FontSize=12
            $script:aiOut.Text="Asistente AXE $($script:AXEVersion) (local, sin API). Pregunta o pulsa ANALIZAR.`r`nTemas: que aplico, input lag, fps, red, seguridad, extremo.`r`n`r`n"
            $inRow=New-Object System.Windows.Controls.Grid; $inRow.Margin=New-Object System.Windows.Thickness(0,8,0,0)
            $q0=New-Object System.Windows.Controls.ColumnDefinition; $q0.Width='*'; $q1=New-Object System.Windows.Controls.ColumnDefinition; $q1.Width='Auto'; $q2=New-Object System.Windows.Controls.ColumnDefinition; $q2.Width='Auto'
            [void]$inRow.ColumnDefinitions.Add($q0); [void]$inRow.ColumnDefinitions.Add($q1); [void]$inRow.ColumnDefinitions.Add($q2)
            $script:aiIn=New-Object System.Windows.Controls.TextBox; $script:aiIn.Style=$win.FindResource('Input'); $script:aiIn.Margin=New-Object System.Windows.Thickness(0,0,8,0)
            [System.Windows.Controls.Grid]::SetColumn($script:aiIn,0); [void]$inRow.Children.Add($script:aiIn)
            $ask=New-Object System.Windows.Controls.Button; $ask.Style=$win.FindResource('Pill'); $ask.Background=New-AXEBrush 'Accent'; $ask.Content='Preguntar'
            [System.Windows.Controls.Grid]::SetColumn($ask,1); [void]$inRow.Children.Add($ask)
            $ana=New-Object System.Windows.Controls.Button; $ana.Style=$win.FindResource('Pill'); $ana.Background=New-AXEBrush 'Purple'; $ana.Content='Analizar'; $ana.Margin=New-Object System.Windows.Thickness(0)
            [System.Windows.Controls.Grid]::SetColumn($ana,2); [void]$inRow.Children.Add($ana)
            $script:aiDoAsk={ if($script:busy){ $script:aiOut.AppendText(">> (operacion en curso; espera a que termine)`r`n"); $script:aiOut.ScrollToEnd(); return }; $qtext=$script:aiIn.Text; if([string]::IsNullOrWhiteSpace($qtext)){return}; $script:aiOut.AppendText(">> $qtext`r`n"); $script:aiOut.AppendText((Invoke-AXEAssistant $qtext)+"`r`n`r`n"); $script:aiOut.ScrollToEnd(); $script:aiIn.Clear() }
            $ask.Add_Click($script:aiDoAsk)
            $script:aiIn.Add_KeyDown({ param($s,$e) if($e.Key -eq 'Return'){ & $script:aiDoAsk; $e.Handled=$true } })
            $ana.Add_Click({ if($script:busy){ $script:aiOut.AppendText(">> (operacion en curso; espera a que termine)`r`n"); $script:aiOut.ScrollToEnd(); return }; $script:aiOut.AppendText(">> Analisis del sistema`r`n"); $script:aiOut.AppendText(((Get-AXERecommendations) -join "`r`n")+"`r`n`r`n"); $script:aiOut.ScrollToEnd() })
            [void]$panel.Children.Add($script:aiOut); [void]$panel.Children.Add($inRow)
        }
        'REGISTRO' {
            # Foto global: que clave toca cada tweak y si el Test la da por aplicada. Solo
            # lectura; escribir sigue siendo cosa de APLICAR (punto de restauracion + snapshot).
            $hint=New-Object System.Windows.Controls.TextBlock
            $hint.Text='Claves del registro que toca el catalogo, agrupadas por ruta. Solo lectura: aqui no se cambia nada. Cada tarjeta de ajuste tiene ademas su propio atajo "regedit".'
            $hint.Foreground=New-AXEBrush 'Muted'; $hint.TextWrapping='Wrap'; $hint.FontSize=12; $hint.Margin=New-Object System.Windows.Thickness(0,0,0,10)
            [void]$panel.Children.Add($hint)

            $script:regOut=New-Object System.Windows.Controls.TextBox
            $script:regOut.IsReadOnly=$true; $script:regOut.Background=New-AXEBrush 'Surface'; $script:regOut.Foreground=New-AXEBrush 'Fg'
            $script:regOut.BorderBrush=New-AXEBrush 'Line'; $script:regOut.BorderThickness=New-Object System.Windows.Thickness(1)
            $script:regOut.Padding=New-Object System.Windows.Thickness(12,8,12,8); $script:regOut.Height=420
            $script:regOut.VerticalScrollBarVisibility='Auto'; $script:regOut.HorizontalScrollBarVisibility='Auto'
            $script:regOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:regOut.FontSize=12
            $script:regOut.Text='Pulsa "Leer estado del registro".'

            $script:regBtn=New-ActionButton 'Leer estado del registro' 'Accent'
            $script:regBtn.Add_Click({
                if($script:busy){ return }
                # ~1.8s medido (ejecuta el Test de 55 tweaks). Corto para montar un runspace,
                # largo para no avisar: se pinta el aviso y se fuerza UNA pasada de render.
                #   Prioridad Render y NO un bombeo tipo PushFrame/DoEvents: el bombeo es
                #   reentrante y procesa entrada, o sea que durante la lectura se podria pulsar
                #   APLICAR y mutar el sistema en mitad del diagnostico. Render repinta sin
                #   dejar pasar clics. (Invoke-AXEDoEvents, ademas, solo existe dentro del
                #   selftest: usarlo aqui reventaba con CommandNotFoundException.)
                $script:busy=$true
                $script:regBtn.IsEnabled=$false
                try {
                    $script:regOut.Text='Leyendo el registro...'
                    $script:regOut.Dispatcher.Invoke([action]{},[System.Windows.Threading.DispatcherPriority]::Render)
                    $script:regOut.Text=((Format-AXERegDiagnostic (Get-AXERegDiagnostic)) -join "`r`n")
                } catch {
                    $script:regOut.Text="No se pudo leer: $($_.Exception.Message)"
                } finally {
                    $script:regBtn.IsEnabled=$true
                    $script:busy=$false
                }
            })
            [void]$panel.Children.Add($script:regBtn)
            [void]$panel.Children.Add($script:regOut)
        }
        'MEDICION' {
            # Numero grande del score
            $scoreRow=New-Object System.Windows.Controls.StackPanel; $scoreRow.Orientation='Horizontal'; $scoreRow.Margin=New-Object System.Windows.Thickness(0,0,0,4)
            $script:scoreLbl=New-Object System.Windows.Controls.TextBlock; $script:scoreLbl.Text='--'; $script:scoreLbl.FontSize=48; $script:scoreLbl.FontWeight='Bold'; $script:scoreLbl.Foreground=New-AXEBrush 'Accent'; $script:scoreLbl.VerticalAlignment='Center'
            $of=New-Object System.Windows.Controls.TextBlock; $of.Text='/100  AXE Score'; $of.Foreground=New-AXEBrush 'Muted'; $of.FontSize=15; $of.VerticalAlignment='Bottom'; $of.Margin=New-Object System.Windows.Thickness(8,0,0,10)
            [void]$scoreRow.Children.Add($script:scoreLbl); [void]$scoreRow.Children.Add($of); [void]$panel.Children.Add($scoreRow)
            # Desglose
            $script:scoreBreak=New-Object System.Windows.Controls.TextBlock; $script:scoreBreak.Text='Pulsa "Medir ahora" para calcular.'; $script:scoreBreak.Foreground=New-AXEBrush 'Fg'; $script:scoreBreak.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:scoreBreak.FontSize=12; $script:scoreBreak.TextWrapping='Wrap'; $script:scoreBreak.Margin=New-Object System.Windows.Thickness(0,0,0,10)
            [void]$panel.Children.Add($script:scoreBreak)
            # Boton Medir ahora
            $script:measureBtn=New-ActionButton 'Medir ahora' 'Accent'
            $script:measureBtn.Add_Click({ Invoke-AXEMeasure -JitterMs 1000 })
            [void]$panel.Children.Add($script:measureBtn)
            # §3.5: el boton vive en MEDICION a posta. Marca los ajustes de latencia pero NO
            # aplica nada: obliga a pasar por APLICAR (punto de restauracion + snapshot) y deja
            # el medir-antes / medir-despues a un clic, que es lo unico que convierte "va mejor"
            # en un numero. Un boton que tocase el registro directamente se saltaria las dos cosas.
            $script:latBtn=New-ActionButton 'Optimizar latencia e input lag' 'Green'
            $script:latBtn.Add_Click({
                if($script:busy){ return }
                if(-not $script:HW){ Write-AXELog 'Hardware aun sin detectar: espera a que termine para no marcar ajustes que no aplican.' 'WARN'; return }
                $set=@(Get-AXELatencySet); $n=0
                foreach($catName in $script:tweakCats){
                    foreach($e in $script:rows[$catName]){
                        if(-not $e.Blocked -and ($set -contains $e.Tw.Id) -and -not $e.Toggle.IsChecked){ $e.Toggle.IsChecked=$true; $n++ }
                    }
                }
                Update-AXEPending
                Write-AXELog ("Latencia/input lag: {0} ajustes marcados de {1} aplicables a este equipo. NO se ha cambiado nada todavia: pulsa APLICAR." -f $n,$set.Count)
                $notes = @(Get-AXELatencyNotes) | ForEach-Object { "  - $_" }
                $bat = if($script:HW.OnBattery){ "`r`nAVISO: estas en BATERIA. Mide enchufado o los numeros no seran comparables.`r`n" } else { '' }
                $script:measureOut.Text = @"
PLAN DE LATENCIA PARA ESTE EQUIPO
$($script:HW.CpuName) - $($script:HW.RamGB)GB - $(if($script:HW.IsSSD){'SSD'}else{'HDD'}) - $(if($script:HW.IsLaptop){'Portatil'}else{'Sobremesa'}) - $(if($script:HW.IsWifi){'Wi-Fi'}else{'Ethernet'})

$n ajustes marcados ($($set.Count) aplicables; el resto fuera por tu hardware, o por ser Tier 2 / placebo probable).

Por que este plan y no otro:
$($notes -join "`r`n")
$bat
Nada se ha cambiado aun. Para que el numero signifique algo:
  1. "Medir ahora"        -> guarda el score ANTES
  2. "APLICAR cambios"    -> crea punto de restauracion y aplica
  3. Reinicia si se pide  -> varios ajustes solo entran al arrancar
  4. "Medir ahora"        -> compara el score DESPUES

El jitter es un PROXY de latencia: sirve para comparar la misma maquina antes/despues,
no para comparar entre maquinas distintas.
"@
            })
            [void]$panel.Children.Add($script:latBtn)
            # §3.5: barrido de resolucion de timer. Separado de "Medir ahora" a posta -- aquel
            # tarda 1s y se puede pulsar a menudo; este tarda ~30s (3 pasadas) y sube el proceso
            # a prioridad High, asi que no debe colarse dentro del flujo de medir-antes/despues.
            # Corre en runspace de fondo: bloquearlo en el UI thread congelaria la ventana 30s.
            $script:sweepBtn=New-ActionButton 'Barrido de timer (~30s)' 'Accent'
            $script:sweepBtn.Add_Click({ Invoke-AXETimerSweepJob })
            [void]$panel.Children.Add($script:sweepBtn)
            # Reporte / delta
            $script:measureOut=New-Object System.Windows.Controls.TextBox; $script:measureOut.IsReadOnly=$true; $script:measureOut.Background=New-AXEBrush 'Surface'; $script:measureOut.Foreground=New-AXEBrush 'Fg'; $script:measureOut.BorderBrush=New-AXEBrush 'Line'; $script:measureOut.BorderThickness=New-Object System.Windows.Thickness(1); $script:measureOut.Padding=New-Object System.Windows.Thickness(12,8,12,8); $script:measureOut.Height=260; $script:measureOut.TextWrapping='Wrap'; $script:measureOut.VerticalScrollBarVisibility='Auto'; $script:measureOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:measureOut.FontSize=12
            $script:measureOut.Text="Medicion local, 0 dependencias. El jitter es un PROXY de latencia (no atribuible a driver concreto)."
            [void]$panel.Children.Add($script:measureOut)
        }
    }
    $panel
}

