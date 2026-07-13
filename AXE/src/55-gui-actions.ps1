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
                    $ba=New-Object System.Windows.Controls.Button; $ba.Style=$win.FindResource('Pill'); $ba.Background=New-AXEBrush 'Accent'; $ba.Content='Aplicar'; $ba.Height=28; $ba.Padding=New-Object System.Windows.Thickness(12,0); $ba.Margin=New-Object System.Windows.Thickness(0,0,6,0); $ba.Tag=$p
                    [System.Windows.Automation.AutomationProperties]::SetName($ba,"Aplicar perfil $($p.Name) ahora")
                    $ba.Add_Click({ param($s,$e) if($script:busy){ Write-AXELog 'Otra operacion en curso, espera.' 'WARN'; return }; Apply-GameProfile $s.Tag })
                    $bd=New-Object System.Windows.Controls.Button; $bd.Style=$win.FindResource('PillDanger'); $bd.Content='Borrar'; $bd.Height=28; $bd.Padding=New-Object System.Windows.Thickness(12,0); $bd.Tag=$p.Name
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
        'ASISTENTE IA' {
            $script:aiOut=New-Object System.Windows.Controls.TextBox; $script:aiOut.IsReadOnly=$true; $script:aiOut.Background=New-AXEBrush 'Surface'; $script:aiOut.Foreground=New-AXEBrush 'Fg'
            $script:aiOut.BorderBrush=New-AXEBrush 'Line'; $script:aiOut.BorderThickness=New-Object System.Windows.Thickness(1); $script:aiOut.Padding=New-Object System.Windows.Thickness(12,8,12,8)
            $script:aiOut.Height=340; $script:aiOut.TextWrapping='Wrap'; $script:aiOut.VerticalScrollBarVisibility='Auto'; $script:aiOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:aiOut.FontSize=12
            $script:aiOut.Text="Asistente AXE v5 (local, sin API). Pregunta o pulsa ANALIZAR.`r`nTemas: que aplico, input lag, fps, red, seguridad, extremo.`r`n`r`n"
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
            # Reporte / delta
            $script:measureOut=New-Object System.Windows.Controls.TextBox; $script:measureOut.IsReadOnly=$true; $script:measureOut.Background=New-AXEBrush 'Surface'; $script:measureOut.Foreground=New-AXEBrush 'Fg'; $script:measureOut.BorderBrush=New-AXEBrush 'Line'; $script:measureOut.BorderThickness=New-Object System.Windows.Thickness(1); $script:measureOut.Padding=New-Object System.Windows.Thickness(12,8,12,8); $script:measureOut.Height=260; $script:measureOut.TextWrapping='Wrap'; $script:measureOut.VerticalScrollBarVisibility='Auto'; $script:measureOut.FontFamily=New-Object System.Windows.Media.FontFamily('Cascadia Code, Consolas'); $script:measureOut.FontSize=12
            $script:measureOut.Text="Medicion local, 0 dependencias. El jitter es un PROXY de latencia (no atribuible a driver concreto)."
            [void]$panel.Children.Add($script:measureOut)
        }
    }
    $panel
}

