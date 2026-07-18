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
    # 3.3: mismo banner que imprime la CLI (-List "ECO:"). Fuente unica: Get-AXEEnvBanner.
    if($EnvBannerLbl){
        $EnvBannerLbl.Text = Get-AXEEnvBanner
        $EnvBannerLbl.ToolTip = 'Ecosistema detectado: define que tweaks aplican a esta maquina y cuantos quedan ocultos por gating (3.2).'
    }
}
if($script:HW){ Build-HwChips }   # headless/GUISHOW con HW ya cargado

# ---- 12.7 catalogo -> categorias + iconos ----
$script:glyphs = @{
    'CPU'=[char]0xE950; 'LATENCIA'=[char]0xE945; 'GPU'=[char]0xE7F4; 'RED'=[char]0xE774;
    'MEMORIA'=[char]0xE964; 'SISTEMA'=[char]0xE770; 'RENDIMIENTO'=[char]0xE9D9; 'SERVICIOS'=[char]0xE90F;
    'PRIVACIDAD'=[char]0xE72E; 'APPS'=[char]0xE71D; 'EXTREMO'=[char]0xE7BA;
    'LIMPIEZA'=[char]0xE74D; 'DEBLOAT'=[char]0xE738; 'DNS'=[char]0xE968; 'STARTUP'=[char]0xE768; 'ASISTENTE IA'=[char]0xE99A; 'PERFILES'=[char]0xE7FC; 'MEDICION'=[char]0xE9D2
}
# Sombra suave compartida (solo se aplica en hover -> 1 card a la vez, sin coste en reposo)
$script:cardShadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$script:cardShadow.Color=[System.Windows.Media.Colors]::Black; $script:cardShadow.BlurRadius=20; $script:cardShadow.ShadowDepth=0; $script:cardShadow.Opacity=0.40
# Brush translucido de un color base (tiles de icono tenidos por tier / badges). alpha 0-255.
function New-TintBrush($key,$alpha){
    $c=(New-AXEBrush $key).Color
    New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($alpha,$c.R,$c.G,$c.B))
}
# ---- helpers de animacion (easing CubicOut, micro-transiciones estilo Fluent) ----
$script:easeOut = New-Object System.Windows.Media.Animation.CubicEase; $script:easeOut.EasingMode='EaseOut'
function New-DblAnim($to,$ms){
    $a=New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To=[double]$to; $a.Duration=[System.Windows.Duration][TimeSpan]::FromMilliseconds($ms); $a.EasingFunction=$script:easeOut; $a
}
function New-ColorAnim($to,$ms){
    $a=New-Object System.Windows.Media.Animation.ColorAnimation
    $a.To=[System.Windows.Media.Color]$to; $a.Duration=[System.Windows.Duration][TimeSpan]::FromMilliseconds($ms); $a.EasingFunction=$script:easeOut; $a
}
# Fade-in de un elemento (cambio de vista). Opacity 0 -> 1.
function Start-AXEFade($el,$ms=170){
    $el.Opacity=0
    $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty,(New-DblAnim 1 $ms))
}
# Pulso del tile al activar un tweak (scale 1 -> 1.18 -> 1, centrado). Solo en accion del usuario.
function Pulse-Tile($tile){
    if($tile.RenderTransform -isnot [System.Windows.Media.ScaleTransform]){
        $tile.RenderTransformOrigin=New-Object System.Windows.Point(0.5,0.5)
        $tile.RenderTransform=New-Object System.Windows.Media.ScaleTransform
    }
    $a=New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To=1.18; $a.Duration=[System.Windows.Duration][TimeSpan]::FromMilliseconds(110); $a.AutoReverse=$true; $a.EasingFunction=$script:easeOut
    $tile.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty,$a)
    $tile.RenderTransform.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty,$a)
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
    $tierKey = switch($tw.Tier){ 0 {'Green'} 1 {'Accent'} 2 {'Red'} }
    $tierTip = switch($tw.Tier){ 0 {'Tier 0 - Seguro'} 1 {'Tier 1 - Elite'} 2 {'Tier 2 - EXTREMO (baja seguridad)'} }
    $glyph = $script:glyphs[$tw.Cat]; if(-not $glyph){ $glyph=[char]0xE9D9 }

    $card = New-Object System.Windows.Controls.Border
    $card.Background = New-AXEBrush 'Surface'; $card.BorderBrush = New-AXEBrush 'Line'
    $card.BorderThickness = New-Object System.Windows.Thickness(1)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $card.Padding = New-Object System.Windows.Thickness(12,10,14,10)
    $card.Margin = New-Object System.Windows.Thickness(0,0,0,8)

    $g = New-Object System.Windows.Controls.Grid
    foreach($w in @('Auto','*','Auto')){ $cd=New-Object System.Windows.Controls.ColumnDefinition; $cd.Width=$w; [void]$g.ColumnDefinitions.Add($cd) }

    # tile de icono tenido por tier (verde=seguro / teal=elite / rojo=extremo) -> escaneable de un vistazo
    $tile = New-Object System.Windows.Controls.Border
    $tile.Width=38; $tile.Height=38; $tile.CornerRadius=New-Object System.Windows.CornerRadius(9)
    $tile.Background = New-TintBrush $tierKey 30
    $tile.VerticalAlignment='Center'; $tile.Margin=New-Object System.Windows.Thickness(0,0,12,0); $tile.ToolTip=$tierTip
    $ico = New-Object System.Windows.Controls.TextBlock
    $ico.Text=$glyph; $ico.FontFamily=New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $ico.FontSize=17; $ico.Foreground=New-AXEBrush $tierKey; $ico.HorizontalAlignment='Center'; $ico.VerticalAlignment='Center'
    $tile.Child=$ico
    [System.Windows.Controls.Grid]::SetColumn($tile,0); [void]$g.Children.Add($tile)

    $left = New-Object System.Windows.Controls.StackPanel; $left.VerticalAlignment='Center'
    $nameRow = New-Object System.Windows.Controls.StackPanel; $nameRow.Orientation='Horizontal'
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text=$tw.Name; $name.FontWeight='SemiBold'; $name.FontSize=13.5; $name.VerticalAlignment='Center'
    [void]$nameRow.Children.Add($name)
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text=$tw.Desc; $desc.Foreground=New-AXEBrush 'Muted'; $desc.TextWrapping='Wrap'; $desc.Margin=New-Object System.Windows.Thickness(0,2,10,0); $desc.FontSize=12
    [void]$left.Children.Add($nameRow); [void]$left.Children.Add($desc)
    [System.Windows.Controls.Grid]::SetColumn($left,1); [void]$g.Children.Add($left)

    $tog = New-Object System.Windows.Controls.CheckBox
    $tog.Style = $win.FindResource('ToggleSwitch'); $tog.VerticalAlignment='Center'; $tog.Tag=$tw
    [System.Windows.Automation.AutomationProperties]::SetName($tog,$tw.Name)
    [System.Windows.Controls.Grid]::SetColumn($tog,2); [void]$g.Children.Add($tog)

    $blk = Get-BlockReason $tw
    if($blk){
        $tog.IsEnabled=$false; $desc.Foreground=New-AXEBrush 'Red'; $desc.Text="[BLOQUEADO] $blk"
        $tile.Background = New-TintBrush 'Red' 30; $ico.Foreground=New-AXEBrush 'Red'; $ico.Text=[char]0xE72E  # candado
    }
    if(-not $blk -and ($script:RECOMMENDED -contains $tw.Id)){
        $recB = New-Object System.Windows.Controls.Border
        $recB.Background=New-TintBrush 'Accent' 28
        $recB.CornerRadius=New-Object System.Windows.CornerRadius(5); $recB.Padding=New-Object System.Windows.Thickness(6,1,6,2)
        $recB.Margin=New-Object System.Windows.Thickness(9,0,0,0); $recB.VerticalAlignment='Center'
        $recT = New-Object System.Windows.Controls.TextBlock
        $recT.Text='Recomendado'; $recT.Foreground=New-AXEBrush 'Accent'; $recT.FontSize=10; $recT.FontWeight='SemiBold'
        $recB.Child=$recT; [void]$nameRow.Children.Add($recB)
    }
    # Card clickable (patron Fluent SettingsCard) + hover ANIMADO: eleva (lift) + fade de fondo + sombra.
    # NO toca BorderBrush -> no pisa el borde accent de "cambio pendiente" (Update-AXEPending).
    if(-not $blk){
        $tog.Add_Click({ if($tog.IsChecked){ Pulse-Tile $tile }; Update-AXEPending }.GetNewClosure())
        $card.Cursor='Hand'; $card.Tag=$tog
        # brush propio (animable; el de recursos esta congelado) + transform de elevacion
        $card.Background = New-Object System.Windows.Media.SolidColorBrush ((New-AXEBrush 'Surface').Color)
        $card.RenderTransform = New-Object System.Windows.Media.TranslateTransform
        $card.Add_MouseEnter({ param($s,$e)
            $s.Effect=$script:cardShadow   # sombra: assign en enter (sin coste en reposo)
            $s.Background.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty,(New-ColorAnim (New-AXEBrush 'Surface2').Color 130))
            $s.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty,(New-DblAnim -3 130))
        })
        $card.Add_MouseLeave({ param($s,$e)
            $s.Effect=$null
            $s.Background.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty,(New-ColorAnim (New-AXEBrush 'Surface').Color 150))
            $s.RenderTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty,(New-DblAnim 0 150))
        })
        $card.Add_MouseLeftButtonUp({ param($s,$e)
            if($tog.IsEnabled -and -not $tog.IsMouseOver){ $tog.IsChecked = -not $tog.IsChecked; if($tog.IsChecked){ Pulse-Tile $tile }; Update-AXEPending }
        }.GetNewClosure())
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

