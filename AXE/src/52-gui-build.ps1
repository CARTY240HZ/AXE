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
    'MEMORIA'=[char]0xE964; 'SISTEMA'=[char]0xE713; 'RENDIMIENTO'=[char]0xE9D9; 'SERVICIOS'=[char]0xE90F;
    'PRIVACIDAD'=[char]0xE72E; 'APPS'=[char]0xE71D; 'EXTREMO'=[char]0xE7BA;
    'LIMPIEZA'=[char]0xE74D; 'DEBLOAT'=[char]0xECC9; 'DNS'=[char]0xE968; 'STARTUP'=[char]0xE768; 'ASISTENTE IA'=[char]0xE99A; 'PERFILES'=[char]0xE7FC; 'MEDICION'=[char]0xE9D2; 'REGISTRO'=[char]0xE8FD
    'FPS'=[char]0xEC4A
}
# NOTA sobre los cuatro glyphs de arriba (FPS, SISTEMA, REGISTRO, DEBLOAT): se eligieron
# RENDERIZANDO la fuente a PNG y mirando el dibujo, no por lo que sugiere el nombre del
# codepoint. Los cuatro anteriores estaban mal y ninguno lo delataba leyendo el codigo:
#   FPS      E7F8 -> EC4A : E7F8 dibuja un PORTATIL, no velocidad. EC4A es el velocimetro.
#   SISTEMA  E770 -> E713 : E770 tambien es un portatil, o sea que SISTEMA y FPS salian con el
#                           mismo dibujo pese a tener codepoints distintos. E713 es el engranaje
#                           de Settings, que ademas describe mejor lo que hay dentro.
#   REGISTRO E71D -> E8FD : E71D era literalmente el MISMO codepoint que APPS. E8FD es la lista
#                           con vinetas, que es lo que la vista ensena (claves del catalogo).
#   DEBLOAT  E738 -> ECC9 : E738 dibuja UN GUION, sin significado. ECC9 es el circulo con menos,
#                           el simbolo de quitar.
# Si se toca alguno, renderizarlo antes: el nombre oficial del glyph miente a menudo.
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
$script:actionCats = @('FPS','MEDICION','REGISTRO','LIMPIEZA','DEBLOAT','DNS','STARTUP','PERFILES','ASISTENTE IA')
# Badge "Recomendado" = §3.4, calculado contra ESTA maquina (Get-AXERecommended en 20-tweaks).
# Al arrancar el HW aun no esta (runspace); sale el nucleo universal y Apply-AXEGating
# lo recalcula en cuanto la deteccion termina. $script:recBadges guarda el Border de cada
# tarjeta para poder encender/apagar la insignia sin reconstruir la vista.
$script:RECOMMENDED = @(Get-AXERecommended)
$script:recBadges   = @{}

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
    # Radio corto: chasis de instrumento, no burbuja. Padding izq 0 -> la espina toca el borde.
    $card.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $card.Padding = New-Object System.Windows.Thickness(0,11,14,11)
    $card.Margin = New-Object System.Windows.Thickness(0,0,0,6)

    $g = New-Object System.Windows.Controls.Grid
    foreach($w in @('Auto','Auto','*','Auto')){ $cd=New-Object System.Windows.Controls.ColumnDefinition; $cd.Width=$w; [void]$g.ColumnDefinitions.Add($cd) }

    # FIRMA: espina de riesgo. Barra vertical tenida por tier en el borde izquierdo.
    # Es el UNICO sitio de la tarjeta donde vive el color de tier: al scrollear, el catalogo
    # se lee como un espectro de riesgo y el racimo de Tier 2 salta a la vista sin leer nada.
    $spine = New-Object System.Windows.Controls.Border
    $spine.Width=3; $spine.CornerRadius=New-Object System.Windows.CornerRadius(2)
    $spine.Background = New-AXEBrush $tierKey
    # Margen negativo = padding vertical de la tarjeta (11) menos 3px de respiro arriba/abajo.
    # Sin esto la espina queda recortada y flotando: se lee como un tick suelto, no como espina.
    $spine.VerticalAlignment='Stretch'; $spine.Margin=New-Object System.Windows.Thickness(0,-8,13,-8)
    $spine.ToolTip=$tierTip
    # Tier 1 es la NORMA (55 de 77 tweaks): a plena saturacion pinta la columna entera de
    # ambar y el "espectro de riesgo" deja de discriminar - T0 y T2 se pierden en el muro.
    # Atenuando solo T1, lo excepcional (verde seguro / rojo extremo) vuelve a saltar.
    if($tw.Tier -eq 1){ $spine.Opacity = 0.45 }
    [System.Windows.Controls.Grid]::SetColumn($spine,0); [void]$g.Children.Add($spine)

    # Tile de icono: NEUTRO. Marca categoria, no riesgo. Tintarlo tambien por tier duplicaria
    # la senal y le quitaria fuerza a la espina (una senal, un sitio).
    $tile = New-Object System.Windows.Controls.Border
    $tile.Width=34; $tile.Height=34; $tile.CornerRadius=New-Object System.Windows.CornerRadius(7)
    $tile.Background = New-AXEBrush 'Surface2'
    $tile.VerticalAlignment='Center'; $tile.Margin=New-Object System.Windows.Thickness(0,0,12,0); $tile.ToolTip=$tierTip
    $ico = New-Object System.Windows.Controls.TextBlock
    $ico.Text=$glyph; $ico.FontFamily=New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')
    $ico.FontSize=16; $ico.Foreground=New-AXEBrush 'Muted'; $ico.HorizontalAlignment='Center'; $ico.VerticalAlignment='Center'
    $tile.Child=$ico
    [System.Windows.Controls.Grid]::SetColumn($tile,1); [void]$g.Children.Add($tile)

    $left = New-Object System.Windows.Controls.StackPanel; $left.VerticalAlignment='Center'
    $nameRow = New-Object System.Windows.Controls.StackPanel; $nameRow.Orientation='Horizontal'
    # Codigo de tier en mono: dato de maquina, escaneable, sin ir a buscar la leyenda.
    $tierC = New-Object System.Windows.Controls.TextBlock
    $tierC.Text=("T{0}" -f $tw.Tier); $tierC.FontFamily=$win.FindResource('Mono')
    $tierC.FontSize=10.5; $tierC.Foreground=New-AXEBrush $tierKey; $tierC.VerticalAlignment='Center'
    $tierC.Margin=New-Object System.Windows.Thickness(0,1,8,0); $tierC.ToolTip=$tierTip
    if($tw.Tier -eq 1){ $tierC.Opacity = 0.6 }   # mismo motivo que la espina: T1 es el fondo, no la senal
    [void]$nameRow.Children.Add($tierC)
    $name = New-Object System.Windows.Controls.TextBlock
    $name.Text=$tw.Name; $name.FontWeight='SemiBold'; $name.FontSize=13.5; $name.VerticalAlignment='Center'
    [void]$nameRow.Children.Add($name)
    $desc = New-Object System.Windows.Controls.TextBlock
    $desc.Text=$tw.Desc; $desc.Foreground=New-AXEBrush 'Muted'; $desc.TextWrapping='Wrap'; $desc.Margin=New-Object System.Windows.Thickness(0,3,10,0); $desc.FontSize=11.5
    [void]$left.Children.Add($nameRow); [void]$left.Children.Add($desc)
    [System.Windows.Controls.Grid]::SetColumn($left,2); [void]$g.Children.Add($left)

    $tog = New-Object System.Windows.Controls.CheckBox
    $tog.Style = $win.FindResource('ToggleSwitch'); $tog.VerticalAlignment='Center'; $tog.Tag=$tw
    [System.Windows.Automation.AutomationProperties]::SetName($tog,$tw.Name)
    [System.Windows.Controls.Grid]::SetColumn($tog,3); [void]$g.Children.Add($tog)

    $blk = Get-BlockReason $tw
    if($blk){
        # Bloqueado es un ESTADO, no un tier: apaga la espina (el riesgo ya no aplica a esta
        # maquina) y mueve la senal al tile + candado, para no ensuciar el espectro de riesgo.
        $tog.IsEnabled=$false; $desc.Foreground=New-AXEBrush 'Muted'; $desc.Text="No aplica: $blk"
        $spine.Background = New-AXEBrush 'Line'
        $card.Opacity = 0.62
        $tile.Background = New-AXEBrush 'Surface2'; $ico.Foreground=New-AXEBrush 'Muted'; $ico.Text=[char]0xE72E  # candado
    }
    # Insignia "Para tu equipo". VERDE, no ambar: el ambar es el color de la accion primaria
    # (APLICAR) y de Tier 1. Si la insignia tambien fuese ambar, tres cosas distintas
    # competirian por el mismo color y ninguna destacaria. Verde = "esto te conviene".
    # Se construye SIEMPRE y se oculta si no toca: asi Apply-AXEGating puede encenderla
    # cuando llega el hardware, sin reconstruir la tarjeta.
    $recB = New-Object System.Windows.Controls.Border
    $recB.Background=New-TintBrush 'Green' 30
    $recB.CornerRadius=New-Object System.Windows.CornerRadius(5); $recB.Padding=New-Object System.Windows.Thickness(6,1,6,2)
    $recB.Margin=New-Object System.Windows.Thickness(9,0,0,0); $recB.VerticalAlignment='Center'
    $recB.ToolTip='Recomendado para ESTE equipo segun el hardware detectado (RAM, disco, GPU, red, portatil/sobremesa).'
    $recT = New-Object System.Windows.Controls.TextBlock
    $recT.Text='Para tu equipo'; $recT.Foreground=New-AXEBrush 'Green'; $recT.FontSize=10; $recT.FontWeight='SemiBold'
    $recB.Child=$recT; [void]$nameRow.Children.Add($recB)
    $recB.Visibility = if(-not $blk -and ($script:RECOMMENDED -contains $tw.Id)){'Visible'}else{'Collapsed'}
    $script:recBadges[$tw.Id] = $recB
    # Atajo a regedit.exe. Solo si el tweak TIENE clave: 23 de 78 son servicios o bcdedit y un
    # boton que abre la raiz del registro seria peor que no tenerlo. La ruta se extrae del
    # Test/Apply (ver 38-regedit.ps1), no de un campo declarado que podria quedar desfasado.
    $regPaths = @(Get-AXERegPathsForTweak $tw)
    if($regPaths.Count -gt 0){
        $regB = New-Object System.Windows.Controls.Border
        $regB.Background=New-TintBrush 'Accent' 26
        $regB.CornerRadius=New-Object System.Windows.CornerRadius(5); $regB.Padding=New-Object System.Windows.Thickness(6,1,6,2)
        $regB.Margin=New-Object System.Windows.Thickness(6,0,0,0); $regB.VerticalAlignment='Center'
        $regB.Cursor='Hand'
        $regB.ToolTip="Abrir regedit.exe en:`n$($regPaths -join "`n")"
        $regT = New-Object System.Windows.Controls.TextBlock
        $regT.Text='regedit'; $regT.Foreground=New-AXEBrush 'Accent'; $regT.FontSize=10; $regT.FontWeight='SemiBold'
        $regB.Child=$regT
        # Handled=$true OBLIGATORIO: la tarjeta entera es clicable (MouseLeftButtonUp conmuta
        # el tweak). Sin esto, abrir regedit marcaria ademas el ajuste para aplicar, que es
        # justo lo contrario de "solo quiero mirar la clave".
        $regB.Add_MouseLeftButtonUp({ param($s,$e)
            $e.Handled=$true
            [void](Open-AXERegedit $regPaths[0])
        }.GetNewClosure())
        [void]$nameRow.Children.Add($regB)
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
# Bombea la cola del dispatcher hasta idle (permite que DispatcherTimer ticke sin ShowDialog).
# Vive AQUI y no dentro del selftest a proposito. Estaba definida como funcion anidada en
# 60-gui-selftest.ps1, o sea que existia SOLO mientras corria el harness: cualquier handler que
# la llamase pasaba el gate en verde y reventaba con CommandNotFoundException en el primer clic
# del usuario. Paso de verdad. Un helper que solo existe en tests convierte el test en un
# entorno distinto del de produccion, que es justo lo que un test no debe ser.
#   OJO al usarla: PushFrame es REENTRANTE y procesa entrada, asi que durante el bombeo se
#   pueden pulsar otros botones. Para "solo repintar antes de una tarea larga" NO uses esto:
#   usa Dispatcher.Invoke([action]{},'Render'), que repinta sin dejar pasar clics.
function Invoke-AXEDoEvents {
    $frame=New-Object System.Windows.Threading.DispatcherFrame
    [void]$win.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::SystemIdle,[action]{ $frame.Continue=$false })
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

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

