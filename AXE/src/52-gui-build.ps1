# ---- 12.6 helpers UI ----
function New-AXEBrush($key){ $win.FindResource($key) }
function New-Chip($glyph,$text){
    $b = New-Object System.Windows.Controls.Border
    $b.Background = New-AXEBrush 'Surface2'; $b.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $b.Padding = New-Object System.Windows.Thickness(9,4,9,4); $b.Margin = New-Object System.Windows.Thickness(5,0,0,0)
    $sp = New-Object System.Windows.Controls.StackPanel; $sp.Orientation='Horizontal'
    $ic = New-Object System.Windows.Controls.TextBlock
    $ic.Text=$glyph; $ic.FontFamily=New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $ic.Foreground=New-AXEBrush 'Accent'; $ic.FontSize=12; $ic.VerticalAlignment='Center'
    $tx = New-Object System.Windows.Controls.TextBlock
    $tx.Text=$text; $tx.Foreground=New-AXEBrush 'Muted'; $tx.FontSize=12; $tx.Margin=New-Object System.Windows.Thickness(6,0,0,0); $tx.VerticalAlignment='Center'
    [void]$sp.Children.Add($ic); [void]$sp.Children.Add($tx); $b.Child=$sp; $b
}

# Chips de hardware: se pueblan cuando HW llega (async en GUI). Idempotente.
function Build-HwChips {
    if(-not $script:HW){ return }
    $HwChips.Children.Clear()
    [void]$HwChips.Children.Add((New-Chip ([char]0xE950) ("{0}  {1}C/{2}T" -f ($script:HW.CpuName -replace '\(R\)|\(TM\)|CPU| Processor',''),$script:HW.Cores,$script:HW.Threads)))
    [void]$HwChips.Children.Add((New-Chip ([char]0xE964) ("RAM {0}GB" -f $script:HW.RamGB)))
    [void]$HwChips.Children.Add((New-Chip ([char]0xE7F4) ($(if($script:HW.IsLaptop){'Portatil'}else{'Desktop'}))))
    [void]$HwChips.Children.Add((New-Chip ([char]0xE701) ($(if($script:HW.IsWifi){'Wi-Fi'}else{'Ethernet'}))))
    [void]$HwChips.Children.Add((New-Chip ([char]0xE83E) ($(if($script:HW.OnBattery){'Bateria'}else{'AC'}))))
}
if($script:HW){ Build-HwChips }   # headless/GUISHOW con HW ya cargado

# ---- 12.7 catalogo -> categorias + iconos ----
$script:glyphs = @{
    'CPU'=[char]0xE950; 'LATENCIA'=[char]0xE945; 'GPU'=[char]0xE7F4; 'RED'=[char]0xE774;
    'MEMORIA'=[char]0xE964; 'SISTEMA'=[char]0xE770; 'RENDIMIENTO'=[char]0xE9D9; 'SERVICIOS'=[char]0xE90F;
    'PRIVACIDAD'=[char]0xE72E; 'APPS'=[char]0xE71D; 'EXTREMO'=[char]0xE7BA;
    'LIMPIEZA'=[char]0xE74D; 'DEBLOAT'=[char]0xE738; 'DNS'=[char]0xE968; 'STARTUP'=[char]0xE768; 'ASISTENTE IA'=[char]0xE99A; 'PERFILES'=[char]0xE7FC; 'MEDICION'=[char]0xE9D2
}
$script:tweakCats = New-Object System.Collections.ArrayList
foreach($tw in $script:CAT){ if(-not $script:tweakCats.Contains($tw.Cat)){ [void]$script:tweakCats.Add($tw.Cat) } }
$script:actionCats = @('MEDICION','LIMPIEZA','DEBLOAT','DNS','STARTUP','PERFILES','ASISTENTE IA')
# Badge "Recomendado" = senal curada (no todo Tier<2): mejores ganancias seguras y universales
$script:RECOMMENDED = @('cpu_mmcss','cpu_prio','lat_mouse','sys_gamedvr','sys_fse','rend_gamemode','rend_visualfx','rend_mpo','gpu_hags','net_throttle','net_nagle','priv_recall','mem_lastaccess')

$script:views    = @{}   # cat -> panel (en ContentHost)
$script:rows     = @{}   # cat -> lista de @{Tw;Toggle;Desc}
$script:navBtns  = @{}
$script:activeCat = $null
$script:busy = $false

# ---- 12.8 construir una tarjeta de tweak ----
function New-TweakCard($tw){
    $card = New-Object System.Windows.Controls.Border
    $card.Background = New-AXEBrush 'Surface'; $card.BorderBrush = New-AXEBrush 'Line'
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $card.Padding = New-Object System.Windows.Thickness(14,10,14,10)
    $card.Margin = New-Object System.Windows.Thickness(0,0,0,8)

    $g = New-Object System.Windows.Controls.Grid
    $c0=New-Object System.Windows.Controls.ColumnDefinition; $c0.Width='*'
    $c1=New-Object System.Windows.Controls.ColumnDefinition; $c1.Width='Auto'
    [void]$g.ColumnDefinitions.Add($c0); [void]$g.ColumnDefinitions.Add($c1)

    $left = New-Object System.Windows.Controls.StackPanel
    # fila nombre + punto de tier
    $nameRow = New-Object System.Windows.Controls.StackPanel; $nameRow.Orientation='Horizontal'
    $dot = New-Object System.Windows.Shapes.Ellipse; $dot.Width=9; $dot.Height=9; $dot.VerticalAlignment='Center'
    $dot.Fill = switch($tw.Tier){ 0 {New-AXEBrush 'Green'} 1 {New-AXEBrush 'Accent'} 2 {New-AXEBrush 'Red'} }
    $tierTip = switch($tw.Tier){ 0 {'Tier 0 - Seguro'} 1 {'Tier 1 - Elite'} 2 {'Tier 2 - EXTREMO (baja seguridad)'} }
    $dot.ToolTip = $tierTip
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text=$tw.Name; $name.FontWeight='SemiBold'; $name.Margin=New-Object System.Windows.Thickness(9,0,0,0); $name.VerticalAlignment='Center'
    [void]$nameRow.Children.Add($dot); [void]$nameRow.Children.Add($name)
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text=$tw.Desc; $desc.Foreground=New-AXEBrush 'Muted'; $desc.TextWrapping='Wrap'; $desc.Margin=New-Object System.Windows.Thickness(18,3,10,0); $desc.FontSize=12
    [void]$left.Children.Add($nameRow); [void]$left.Children.Add($desc)
    [System.Windows.Controls.Grid]::SetColumn($left,0); [void]$g.Children.Add($left)

    $tog = New-Object System.Windows.Controls.CheckBox
    $tog.Style = $win.FindResource('ToggleSwitch'); $tog.VerticalAlignment='Center'; $tog.Tag=$tw
    [System.Windows.Automation.AutomationProperties]::SetName($tog,$tw.Name)
    [System.Windows.Controls.Grid]::SetColumn($tog,1); [void]$g.Children.Add($tog)

    $blk = Get-BlockReason $tw
    if($blk){
        $tog.IsEnabled=$false; $desc.Foreground=New-AXEBrush 'Red'; $desc.Text="[BLOQUEADO] $blk"
    }
    if(-not $blk -and ($script:RECOMMENDED -contains $tw.Id)){
        $recB = New-Object System.Windows.Controls.Border
        $recB.BorderBrush=New-AXEBrush 'Accent'; $recB.BorderThickness=New-Object System.Windows.Thickness(1)
        $recB.CornerRadius=New-Object System.Windows.CornerRadius(4); $recB.Padding=New-Object System.Windows.Thickness(5,0,5,1)
        $recB.Margin=New-Object System.Windows.Thickness(8,0,0,0); $recB.VerticalAlignment='Center'
        $recT = New-Object System.Windows.Controls.TextBlock
        $recT.Text='Recomendado'; $recT.Foreground=New-AXEBrush 'Accent'; $recT.FontSize=10; $recT.FontWeight='SemiBold'
        $recB.Child=$recT; [void]$nameRow.Children.Add($recB)
    }
    # Card entera clickable (patron Fluent SettingsCard) + hook de cambios pendientes
    if(-not $blk){
        $tog.Add_Click({ Update-AXEPending })
        $card.Cursor='Hand'; $card.Tag=$tog
        $card.Add_MouseEnter({ param($s,$e) $s.Background = New-AXEBrush 'Surface2' })
        $card.Add_MouseLeave({ param($s,$e) $s.Background = New-AXEBrush 'Surface' })
        $card.Add_MouseLeftButtonUp({ param($s,$e)
            $tg=$s.Tag
            if($tg -and $tg.IsEnabled -and -not $tg.IsMouseOver){ $tg.IsChecked = -not $tg.IsChecked; Update-AXEPending }
        })
    }
    $card.Child=$g
    @{Card=$card; Toggle=$tog; Desc=$desc; Tw=$tw; Blocked=[bool]$blk; Base=$null}
}

# ---- 12.9 construir vistas de tweaks ----
function Build-TweakViews {
    $allTweaks=@($script:CAT)
    foreach($catName in $script:tweakCats){
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Visibility='Collapsed'
        [void]$ContentHost.Children.Add($panel)
        $script:views[$catName]=$panel
        $script:rows[$catName]=New-Object System.Collections.ArrayList
        foreach($tw in ($allTweaks | Where-Object { $_.Cat -eq $catName })){
            try {
                $e = New-TweakCard $tw
                [void]$panel.Children.Add($e.Card)
                [void]$script:rows[$catName].Add($e)
            } catch { Write-AXELog "No pude construir card $($tw.Id): $($_.Exception.Message)" 'ERR' }
        }
    }
}
Build-TweakViews

# ---- 12.9b tarea en segundo plano (runspace + poll DispatcherTimer) ----
# A2: LIMPIEZA/DEBLOAT/DNS corrian inline en el UI thread (Remove-AppxPackage ~20-30s,
# Stop/Start-Service, purga de todos los procesos) => freeze. Ahora van a un runspace
# de fondo con el MISMO patron que el "Punto de restauracion". El $Work DEVUELVE lineas
# de log (string[]); al completar se escriben con Write-AXELog en el UI thread. Args solo
# ESCALARES (une arrays con coma; el $Work los separa) para evitar aplanado de PowerShell.
$script:jobPS=$null
function Start-AXEJob {
    param([scriptblock]$Work,[string[]]$JobArgs=@(),$Button)
    # H10: mutex unico con APLICAR/MASTER. $script:busy cubre tambien Limpieza/DNS/Debloat/
    # Startup para que ninguna tarea de fondo mute el sistema mientras corre otra operacion.
    if($script:busy -or $script:jobPS){ Write-AXELog 'Otra operacion en curso, espera a que termine.' 'WARN'; return }
    $script:busy=$true
    if($Button){ $script:jobBtn=$Button; $Button.IsEnabled=$false } else { $script:jobBtn=$null }
    $ps=[PowerShell]::Create(); [void]$ps.AddScript($Work)
    foreach($a in $JobArgs){ [void]$ps.AddArgument($a) }
    $script:jobPS=$ps; $script:jobHandle=$ps.BeginInvoke()
    $script:jobTimer=New-Object System.Windows.Threading.DispatcherTimer
    $script:jobTimer.Interval=[TimeSpan]::FromMilliseconds(120)
    $script:jobTimer.Add_Tick({
        if(-not $script:jobHandle.IsCompleted){ return }
        $script:jobTimer.Stop()
        try { $res=$script:jobPS.EndInvoke($script:jobHandle) } catch { $res=@("ERROR tarea de fondo: $($_.Exception.Message)") }
        $script:jobPS.Dispose(); $script:jobPS=$null
        foreach($line in $res){
            if($null -eq $line -or "$line" -eq ''){ continue }
            $lvl = if("$line" -match '^(ERROR|ERR)\b'){'ERR'} elseif("$line" -match '^WARN\b'){'WARN'} else {'INFO'}
            Write-AXELog ("$line" -replace '^(ERROR|ERR|WARN)\s*','') $lvl
        }
        if($script:jobBtn){ $script:jobBtn.IsEnabled=$true; $script:jobBtn=$null }
        $script:busy=$false   # H10: libera el mutex al completar la tarea
    })
    $script:jobTimer.Start()
}

