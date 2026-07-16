# =====================================================
# REGION 12 - GUI WPF FLUENT (rediseno elite, tema dark Win11)
# Reemplaza la GUI WinForms. Motor (regiones 1-11) intacto.
#   - WPF nativo (PresentationFramework, 0 deps externas)
#   - DPI PerMonitorV2 (P/Invoke) + titlebar oscuro + Mica best-effort
#   - ToggleSwitch Fluent, tarjetas redondeadas, nav con grupos
#   - Apply sin freeze (DispatcherTimer 1 tweak/tick)
#   - Gate de seguridad para Tier 2 (EXTREMO)
#   - LW_GUITEST=1 : construye + assert + render PNG, sin ShowDialog
# =====================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# ---- 12.0 Guard STA (WPF lo exige; el .bat ya pasa -STA, esto cubre run directo) ----
if($env:AXE_GUITEST -ne '1' -and $env:AXE_GUISHOW -ne '1' -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'){
    Write-Host 'WPF requiere apartment STA. Relanzando con -STA...'
    Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',"`"$PSCommandPath`"") -Verb RunAs
    return
}

# ---- 12.1 P/Invoke: DPI awareness + DWM (titlebar oscuro + Mica) ----
if(-not ('LWNative.Win' -as [type])){
Add-Type -Namespace LWNative -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
'@
}
# PerMonitorV2 = -4. Debe llamarse ANTES de crear ventana. Falla silencioso en Win viejo.
try { [void][LWNative.Win]::SetProcessDpiAwarenessContext([System.IntPtr](-4)) } catch {}

function Set-AXEWindowChrome($hwnd){
    # DWMWA_USE_IMMERSIVE_DARK_MODE = 20 : titlebar negra (fiable en Win10 2004+/Win11)
    try { $d=1; [void][LWNative.Win]::DwmSetWindowAttribute($hwnd,20,[ref]$d,4) } catch {}
    # DWMWA_SYSTEMBACKDROP_TYPE = 38, valor 2 = Mica (best-effort, Win11 22621+)
    try { $m=2; [void][LWNative.Win]::DwmSetWindowAttribute($hwnd,38,[ref]$m,4) } catch {}
}

# ---- 12.2 Guards admin + catalogo (WPF MessageBox, sin cargar WinForms) ----
if($env:AXE_GUITEST -ne '1' -and $env:AXE_GUISHOW -ne '1' -and -not (Test-Admin)){
    [System.Windows.MessageBox]::Show("Ejecuta 'AXE.bat' (se eleva solo).","Admin requerido",'OK','Warning') | Out-Null
    return
}
if($script:CAT.Count -lt 10){
    [System.Windows.MessageBox]::Show("Catalogo roto ($($script:CAT.Count) tweaks). Abortando para protegerte.","AXE",'OK','Error') | Out-Null
    return
}

# ---- 12.3 XAML: shell + estilos Fluent ----
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AXE" Height="840" Width="1200" MinHeight="720" MinWidth="1040"
        WindowStartupLocation="CenterScreen" Background="#1B1B1F"
        TextOptions.TextFormattingMode="Ideal" UseLayoutRounding="True"
        FontFamily="Segoe UI Variable, Segoe UI" FontSize="13" Foreground="#ECECF0">
  <Window.Resources>
    <SolidColorBrush x:Key="Bg"       Color="#1B1B1F"/>
    <SolidColorBrush x:Key="Surface"  Color="#26262B"/>
    <SolidColorBrush x:Key="Surface2" Color="#303036"/>
    <SolidColorBrush x:Key="Line"     Color="#3A3A42"/>
    <SolidColorBrush x:Key="Fg"       Color="#ECECF0"/>
    <SolidColorBrush x:Key="Muted"    Color="#9A9AA6"/>
    <SolidColorBrush x:Key="Accent"   Color="#2DD4BF"/>
    <SolidColorBrush x:Key="AccentDim" Color="#242DD4BF"/>
    <SolidColorBrush x:Key="OnAccent" Color="#0B0B0D"/>
    <SolidColorBrush x:Key="Green"    Color="#4ADE80"/>
    <SolidColorBrush x:Key="Amber"    Color="#FBBF24"/>
    <SolidColorBrush x:Key="Red"      Color="#F87171"/>
    <SolidColorBrush x:Key="Purple"   Color="#A78BFA"/>

    <!-- Anillo de foco de teclado (a11y: foco visible por teclado, guia Fluent) -->
    <Style x:Key="FocusRing">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Stroke="#3AE7D0" StrokeThickness="2" RadiusX="8" RadiusY="8" Margin="-2" SnapsToDevicePixels="True"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ScrollBar fino -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border CornerRadius="5" Background="#4A4A55" Margin="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton><RepeatButton Opacity="0" Command="ScrollBar.PageDownCommand"/></Track.IncreaseRepeatButton>
                <Track.DecreaseRepeatButton><RepeatButton Opacity="0" Command="ScrollBar.PageUpCommand"/></Track.DecreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Input redondeado -->
    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource Surface2}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Fg}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border CornerRadius="6" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Boton pastilla (color via Background) -->
    <Style x:Key="Pill" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Background" Value="{StaticResource Accent}"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="8" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.90"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.78"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.40"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Boton secundario ghost (transparente + borde, hover rellena) -->
    <Style x:Key="PillGhost" TargetType="Button" BasedOn="{StaticResource Pill}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{StaticResource Line}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Surface2}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Line}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.40"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Boton destructivo (outline rojo, hover rellena rojo) -->
    <Style x:Key="PillDanger" TargetType="Button" BasedOn="{StaticResource PillGhost}">
      <Setter Property="Foreground" Value="{StaticResource Red}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{StaticResource Red}" BorderThickness="1" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource Red}"/>
                <Setter Property="Foreground" Value="{StaticResource OnAccent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.40"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Item de navegacion (RadioButton) -->
    <Style x:Key="NavItem" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Foreground" Value="{StaticResource Fg}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <!-- Sel = capa de seleccion (glow teal) que se FUNDE via Opacity; separada de B
                 para no pelear con el brush de hover (swap de brush congelado no es animable) -->
            <Grid Margin="8,1">
              <Border x:Name="Sel" CornerRadius="7" Background="{StaticResource AccentDim}" Opacity="0"/>
              <Border x:Name="B" Background="Transparent" BorderBrush="{StaticResource Accent}"
                      BorderThickness="0" CornerRadius="7" Padding="10,8">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="22"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                  <TextBlock x:Name="Ico" Grid.Column="0" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                             FontSize="15" Text="{TemplateBinding Tag}" Foreground="{StaticResource Muted}" VerticalAlignment="Center"/>
                  <TextBlock Grid.Column="1" Margin="10,0,0,0" Text="{TemplateBinding Content}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </Border>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{StaticResource Surface2}"/></Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Sel" Storyboard.TargetProperty="Opacity" To="1" Duration="0:0:0.16"/></Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="Sel" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.16"/></Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
                <Setter TargetName="B" Property="BorderThickness" Value="3,0,0,0"/>
                <Setter TargetName="Ico" Property="Foreground" Value="{StaticResource Accent}"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ToggleSwitch Fluent (CheckBox retemplado) -->
    <Style x:Key="ToggleSwitch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="46" Height="24" Background="Transparent">
              <Border x:Name="Track" CornerRadius="12" Background="{StaticResource Surface2}"
                      BorderBrush="{StaticResource Line}" BorderThickness="1"/>
              <Ellipse x:Name="Thumb" Width="16" Height="16" HorizontalAlignment="Left" Margin="4,0,0,0" Fill="#C4C4CE">
                <Ellipse.RenderTransform><TranslateTransform x:Name="TT" X="0"/></Ellipse.RenderTransform>
              </Ellipse>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource Accent}"/>
                <Setter TargetName="Track" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter TargetName="Thumb" Property="Fill" Value="White"/>
                <Trigger.EnterActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="TT" Storyboard.TargetProperty="X" To="22" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="TT" Storyboard.TargetProperty="X" To="0" Duration="0:0:0.14"/></Storyboard></BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.35"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- ProgressBar slim -->
    <Style x:Key="Slim" TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="{StaticResource Surface2}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border CornerRadius="3" Background="{TemplateBinding Background}" ClipToBounds="True">
              <Border x:Name="PART_Indicator" HorizontalAlignment="Left" CornerRadius="3" Background="{TemplateBinding Foreground}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- HEADER -->
    <Border Grid.Row="0" Background="{StaticResource Surface}" Padding="18,12" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Viewbox x:Name="LogoBox" Height="34" VerticalAlignment="Center">
            <Canvas x:Name="LogoCanvas" Width="2624" Height="1624">
              <Path Data="M1856.000000,1626.000000 C1237.405884,1626.000000 619.811768,1626.000000 2.108846,1626.000000 C2.108846,1084.802856 2.108846,543.605652 2.108846,2.204240 C876.427673,2.204240 1750.855469,2.204240 2625.641602,2.204240 C2625.641602,543.333130 2625.641602,1084.666504 2625.641602,1626.000000 C2369.605225,1626.000000 2113.302490,1626.000000 1856.000000,1626.000000 M741.003723,951.907471 C720.601868,900.810181 708.002563,847.833557 704.400574,792.951172 C698.314270,700.215698 715.926758,612.031311 757.112488,528.650330 C790.572327,460.910431 836.139404,402.351746 891.699402,351.369720 C893.863403,349.384094 897.597351,348.223022 897.326965,343.842010 C890.258789,343.842010 883.595947,343.841797 876.933105,343.842072 C748.944885,343.846893 620.956604,343.851654 492.968384,343.856659 C455.638489,343.858124 418.307892,343.727142 380.978912,343.912415 C358.721924,344.022888 343.173431,354.896149 333.785980,374.837799 C332.232880,378.137024 331.015594,381.608856 329.832794,385.065796 C307.539948,450.219971 285.285889,515.387390 263.003632,580.545166 C197.339005,772.561401 131.656342,964.571533 66.058945,1156.610718 C64.680763,1160.645386 63.630501,1164.983765 63.499184,1169.213745 C63.202446,1178.772339 68.966484,1185.783936 78.278770,1187.771851 C81.180626,1188.391479 84.242310,1188.442383 87.231262,1188.446533 C125.227692,1188.498291 163.224213,1188.506104 201.220703,1188.498169 C217.504593,1188.494873 229.064255,1180.660767 236.600128,1166.613525 C238.789276,1162.532837 240.419632,1158.118896 241.986984,1153.743408 C256.011475,1114.592651 269.953369,1075.412109 283.957001,1036.253906 C285.261963,1032.604858 286.825653,1029.048340 288.075714,1025.931274 C394.718384,1025.931274 500.275909,1025.931274 606.261597,1025.931274 C608.316528,1031.495850 610.324585,1036.754883 612.206665,1042.058594 C626.115540,1081.251587 640.087097,1120.422607 653.853027,1159.665771 C660.484558,1178.570801 676.049255,1188.799683 695.744385,1188.661987 C760.401917,1188.209473 825.064636,1188.497070 889.725342,1188.479492 C892.204163,1188.478760 894.682922,1188.262695 898.003601,1188.107666 C884.125305,1172.441650 870.884888,1158.038330 858.242249,1143.128174 C809.667419,1085.841309 769.424805,1023.395020 741.003723,951.907471 M2298.998535,1188.551147 C2311.994873,1188.544922 2324.991211,1188.540527 2337.987549,1188.532349 C2373.984619,1188.509399 2409.984375,1188.217651 2445.977539,1188.587646 C2461.147217,1188.743530 2475.829590,1177.036011 2475.954346,1158.973755 C2476.196289,1123.977905 2476.309326,1088.975952 2475.905518,1053.983032 C2475.725586,1038.375244 2463.325439,1026.539917 2447.783447,1025.636353 C2445.125488,1025.481812 2442.452637,1025.561646 2439.786621,1025.561523 C2317.795166,1025.552856 2195.803711,1025.547485 2073.812256,1025.541748 C2070.576172,1025.541626 2067.339844,1025.541748 2063.896973,1025.541748 C2063.896973,957.266785 2063.896973,890.110535 2063.896973,822.152039 C2067.737549,822.152039 2071.002197,822.152588 2074.266602,822.151978 C2093.931885,822.148071 2113.597412,822.143311 2133.262695,822.139832 C2199.924805,822.127930 2266.587158,822.159973 2333.249268,822.080811 C2356.197998,822.053528 2367.428467,810.603333 2367.515869,787.510498 C2367.552246,777.844604 2367.522461,768.178406 2367.523438,758.512390 C2367.525391,735.847229 2367.761475,713.178955 2367.459229,690.517822 C2367.195312,670.725037 2355.044434,658.926025 2335.476807,658.687744 C2333.810547,658.667419 2332.143555,658.688782 2330.477051,658.688538 C2245.149414,658.675659 2159.821777,658.662415 2074.494141,658.649414 C2070.962402,658.648865 2067.430420,658.649353 2063.643066,658.649353 C2063.643066,607.827271 2063.643066,558.297424 2063.643066,507.765686 C2067.900391,507.765686 2071.814453,507.765320 2075.728760,507.765717 C2198.053955,507.777496 2320.379150,507.797760 2442.704346,507.793396 C2464.362061,507.792603 2476.173340,496.155548 2476.229980,474.605011 C2476.316650,441.607697 2475.783691,408.600342 2476.458252,375.616577 C2476.775391,360.098694 2463.436768,343.605408 2444.192627,343.636292 C2239.206787,343.965332 2034.220093,343.835907 1829.233643,343.865936 C1827.153809,343.866241 1825.074097,344.316284 1822.123657,344.656921 C1825.074341,348.075958 1827.256592,350.549347 1829.379395,353.072723 C1857.298584,386.260101 1883.350220,420.751587 1905.127075,458.398499 C1954.704834,544.106323 1982.693115,636.224670 1987.672241,735.146484 C1990.929810,799.865417 1982.993164,863.489929 1967.007690,926.150269 C1944.681030,1013.666748 1910.217407,1096.472046 1869.110840,1176.666504 C1867.328125,1180.144653 1865.623779,1183.662842 1863.228394,1188.478149 C2008.674561,1188.478149 2152.836914,1188.478149 2298.998535,1188.551147 M1621.000000,343.843628 C1579.338257,343.846527 1537.675293,343.998779 1496.015747,343.699249 C1489.393066,343.651642 1485.064697,345.757996 1480.725098,350.633270 C1447.488281,387.972565 1413.985718,425.075317 1380.547607,462.235229 C1377.549316,465.567413 1374.422974,468.784393 1371.208740,472.211853 C1368.636963,469.458984 1366.778687,467.558502 1365.017700,465.571808 C1331.195923,427.415771 1297.290894,389.332550 1263.683960,350.988129 C1259.122070,345.783234 1254.562256,343.661560 1247.561890,343.679779 C1154.240112,343.922913 1060.917603,343.842285 967.595215,343.842255 C964.343140,343.842255 961.091003,343.842255 957.258484,343.842255 C957.003601,347.947449 956.698303,351.217316 956.613586,354.492828 C956.043213,376.563385 958.280090,398.412811 962.078430,420.113953 C973.317261,484.325195 1000.697815,540.159912 1048.175415,585.516174 C1081.889404,617.723938 1120.993164,641.403137 1164.369019,658.037598 C1247.624756,689.965881 1333.524414,698.987854 1421.688843,686.440613 C1487.893555,677.018616 1549.435181,654.522217 1605.521729,618.065613 C1668.029907,577.434875 1713.862793,522.841492 1739.086182,452.219055 C1749.146973,424.049652 1757.163818,395.146820 1765.957520,366.530640 C1768.166870,359.340454 1769.782837,351.967896 1771.888428,343.842072 C1721.589722,343.842072 1672.294922,343.842072 1621.000000,343.843628 M1528.367798,804.523376 C1491.405640,793.821167 1453.634888,787.851135 1415.249878,786.166382 C1370.157349,784.187134 1325.323975,786.811340 1281.029053,796.026917 C1214.693970,809.827820 1152.974854,834.333923 1098.535278,875.444946 C1038.928589,920.458130 999.535950,979.075806 981.692932,1051.668091 C972.444824,1089.292969 969.162720,1127.847290 966.578064,1166.420776 C966.379761,1169.381226 966.578430,1172.440796 967.100891,1175.363525 C968.722046,1184.433716 972.632751,1187.779663 981.938293,1188.401245 C983.930481,1188.534424 985.935852,1188.491455 987.935181,1188.491577 C1079.921509,1188.499756 1171.907837,1188.503540 1263.894165,1188.507812 C1266.440063,1188.507935 1268.985962,1188.507812 1272.235962,1188.507812 C1272.235962,1183.543335 1272.235474,1179.605103 1272.235962,1175.666748 C1272.244141,1093.678955 1272.098999,1011.690735 1272.320679,929.703552 C1272.446289,883.286438 1296.331787,850.767517 1340.236694,835.575439 C1364.406006,827.212341 1389.233765,826.346069 1414.267334,828.815918 C1430.628174,830.430115 1446.167114,835.377258 1460.574707,843.559448 C1479.794067,854.474304 1492.906494,870.367798 1497.903442,891.922058 C1500.435181,902.842529 1501.866333,914.269775 1501.909668,925.475220 C1502.234619,1009.461487 1502.088745,1093.449463 1502.090332,1177.437012 C1502.090454,1180.974609 1502.090454,1184.512085 1502.090454,1187.790649 C1602.876831,1187.790649 1702.373535,1187.790649 1802.727661,1187.790649 C1803.923706,1180.727905 1805.455688,1174.260498 1806.053101,1167.708130 C1808.670166,1139.002319 1806.910278,1110.422729 1802.246216,1082.057983 C1788.231079,996.826599 1746.351440,928.432007 1677.224487,876.747253 C1632.707397,843.462891 1583.211548,820.315796 1528.367798,804.523376 z" Fill="{StaticResource Accent}"/>
              <Path Data="M741.326904,952.609741 C769.424805,1023.395020 809.667419,1085.841309 858.242249,1143.128174 C870.884888,1158.038330 884.125305,1172.441650 898.003601,1188.107666 C894.682922,1188.262695 892.204163,1188.478760 889.725342,1188.479492 C825.064636,1188.497070 760.401917,1188.209473 695.744385,1188.661987 C676.049255,1188.799683 660.484558,1178.570801 653.853027,1159.665771 C640.087097,1120.422607 626.115540,1081.251587 612.206665,1042.058594 C610.324585,1036.754883 608.316528,1031.495850 606.261597,1025.931274 C500.275909,1025.931274 394.718384,1025.931274 288.075714,1025.931274 C286.825653,1029.048340 285.261963,1032.604858 283.957001,1036.253906 C269.953369,1075.412109 256.011475,1114.592651 241.986984,1153.743408 C240.419632,1158.118896 238.789276,1162.532837 236.600128,1166.613525 C229.064255,1180.660767 217.504593,1188.494873 201.220703,1188.498169 C163.224213,1188.506104 125.227692,1188.498291 87.231262,1188.446533 C84.242310,1188.442383 81.180626,1188.391479 78.278770,1187.771851 C68.966484,1185.783936 63.202446,1178.772339 63.499184,1169.213745 C63.630501,1164.983765 64.680763,1160.645386 66.058945,1156.610718 C131.656342,964.571533 197.339005,772.561401 263.003632,580.545166 C285.285889,515.387390 307.539948,450.219971 329.832794,385.065796 C331.015594,381.608856 332.232880,378.137024 333.785980,374.837799 C343.173431,354.896149 358.721924,344.022888 380.978912,343.912415 C418.307892,343.727142 455.638489,343.858124 492.968384,343.856659 C620.956604,343.851654 748.944885,343.846893 876.933105,343.842072 C883.595947,343.841797 890.258789,343.842010 897.326965,343.842010 C897.597351,348.223022 893.863403,349.384094 891.699402,351.369720 C836.139404,402.351746 790.572327,460.910431 757.112488,528.650330 C715.926758,612.031311 698.314270,700.215698 704.400574,792.951172 C708.002563,847.833557 720.601868,900.810181 741.326904,952.609741 M437.795624,552.698364 C406.735779,654.143494 375.672363,755.587524 344.652863,857.044983 C344.224060,858.447571 344.347687,860.019104 344.194763,861.719727 C413.117462,861.719727 481.374115,861.719727 550.661011,861.719727 C516.194763,749.239075 481.903137,637.328430 446.968933,523.320679 C443.559052,534.068054 440.851166,542.602783 437.795624,552.698364 z" Fill="{StaticResource Surface}"/>
              <Path Data="M2297.999023,1188.514648 C2152.836914,1188.478149 2008.674561,1188.478149 1863.228394,1188.478149 C1865.623779,1183.662842 1867.328125,1180.144653 1869.110840,1176.666504 C1910.217407,1096.472046 1944.681030,1013.666748 1967.007690,926.150269 C1982.993164,863.489929 1990.929810,799.865417 1987.672241,735.146484 C1982.693115,636.224670 1954.704834,544.106323 1905.127075,458.398499 C1883.350220,420.751587 1857.298584,386.260101 1829.379395,353.072723 C1827.256592,350.549347 1825.074341,348.075958 1822.123657,344.656921 C1825.074097,344.316284 1827.153809,343.866241 1829.233643,343.865936 C2034.220093,343.835907 2239.206787,343.965332 2444.192627,343.636292 C2463.436768,343.605408 2476.775391,360.098694 2476.458252,375.616577 C2475.783691,408.600342 2476.316650,441.607697 2476.229980,474.605011 C2476.173340,496.155548 2464.362061,507.792603 2442.704346,507.793396 C2320.379150,507.797760 2198.053955,507.777496 2075.728760,507.765717 C2071.814453,507.765320 2067.900391,507.765686 2063.643066,507.765686 C2063.643066,558.297424 2063.643066,607.827271 2063.643066,658.649353 C2067.430420,658.649353 2070.962402,658.648865 2074.494141,658.649414 C2159.821777,658.662415 2245.149414,658.675659 2330.477051,658.688538 C2332.143555,658.688782 2333.810547,658.667419 2335.476807,658.687744 C2355.044434,658.926025 2367.195312,670.725037 2367.459229,690.517822 C2367.761475,713.178955 2367.525391,735.847229 2367.523438,758.512390 C2367.522461,768.178406 2367.552246,777.844604 2367.515869,787.510498 C2367.428467,810.603333 2356.197998,822.053528 2333.249268,822.080811 C2266.587158,822.159973 2199.924805,822.127930 2133.262695,822.139832 C2113.597412,822.143311 2093.931885,822.148071 2074.266602,822.151978 C2071.002197,822.152588 2067.737549,822.152039 2063.896973,822.152039 C2063.896973,890.110535 2063.896973,957.266785 2063.896973,1025.541748 C2067.339844,1025.541748 2070.576172,1025.541626 2073.812256,1025.541748 C2195.803711,1025.547485 2317.795166,1025.552856 2439.786621,1025.561523 C2442.452637,1025.561646 2445.125488,1025.481812 2447.783447,1025.636353 C2463.325439,1026.539917 2475.725586,1038.375244 2475.905518,1053.983032 C2476.309326,1088.975952 2476.196289,1123.977905 2475.954346,1158.973755 C2475.829590,1177.036011 2461.147217,1188.743530 2445.977539,1188.587646 C2409.984375,1188.217651 2373.984619,1188.509399 2337.987549,1188.532349 C2324.991211,1188.540527 2311.994873,1188.544922 2297.999023,1188.514648 z" Fill="{StaticResource Surface}"/>
              <Path Data="M1622.000000,343.842834 C1672.294922,343.842072 1721.589722,343.842072 1771.888428,343.842072 C1769.782837,351.967896 1768.166870,359.340454 1765.957520,366.530640 C1757.163818,395.146820 1749.146973,424.049652 1739.086182,452.219055 C1713.862793,522.841492 1668.029907,577.434875 1605.521729,618.065613 C1549.435181,654.522217 1487.893555,677.018616 1421.688843,686.440613 C1333.524414,698.987854 1247.624756,689.965881 1164.369019,658.037598 C1120.993164,641.403137 1081.889404,617.723938 1048.175415,585.516174 C1000.697815,540.159912 973.317261,484.325195 962.078430,420.113953 C958.280090,398.412811 956.043213,376.563385 956.613586,354.492828 C956.698303,351.217316 957.003601,347.947449 957.258484,343.842255 C961.091003,343.842255 964.343140,343.842255 967.595215,343.842255 C1060.917603,343.842285 1154.240112,343.922913 1247.561890,343.679779 C1254.562256,343.661560 1259.122070,345.783234 1263.683960,350.988129 C1297.290894,389.332550 1331.195923,427.415771 1365.017700,465.571808 C1366.778687,467.558502 1368.636963,469.458984 1371.208740,472.211853 C1374.422974,468.784393 1377.549316,465.567413 1380.547607,462.235229 C1413.985718,425.075317 1447.488281,387.972565 1480.725098,350.633270 C1485.064697,345.757996 1489.393066,343.651642 1496.015747,343.699249 C1537.675293,343.998779 1579.338257,343.846527 1622.000000,343.842834 z" Fill="{StaticResource Surface}"/>
              <Path Data="M1529.124512,804.814697 C1583.211548,820.315796 1632.707397,843.462891 1677.224487,876.747253 C1746.351440,928.432007 1788.231079,996.826599 1802.246216,1082.057983 C1806.910278,1110.422729 1808.670166,1139.002319 1806.053101,1167.708130 C1805.455688,1174.260498 1803.923706,1180.727905 1802.727661,1187.790649 C1702.373535,1187.790649 1602.876831,1187.790649 1502.090454,1187.790649 C1502.090454,1184.512085 1502.090454,1180.974609 1502.090332,1177.437012 C1502.088745,1093.449463 1502.234619,1009.461487 1501.909668,925.475220 C1501.866333,914.269775 1500.435181,902.842529 1497.903442,891.922058 C1492.906494,870.367798 1479.794067,854.474304 1460.574707,843.559448 C1446.167114,835.377258 1430.628174,830.430115 1414.267334,828.815918 C1389.233765,826.346069 1364.406006,827.212341 1340.236694,835.575439 C1296.331787,850.767517 1272.446289,883.286438 1272.320679,929.703552 C1272.098999,1011.690735 1272.244141,1093.678955 1272.235962,1175.666748 C1272.235474,1179.605103 1272.235962,1183.543335 1272.235962,1188.507812 C1268.985962,1188.507812 1266.440063,1188.507935 1263.894165,1188.507812 C1171.907837,1188.503540 1079.921509,1188.499756 987.935181,1188.491577 C985.935852,1188.491455 983.930481,1188.534424 981.938293,1188.401245 C972.632751,1187.779663 968.722046,1184.433716 967.100891,1175.363525 C966.578430,1172.440796 966.379761,1169.381226 966.578064,1166.420776 C969.162720,1127.847290 972.444824,1089.292969 981.692932,1051.668091 C999.535950,979.075806 1038.928589,920.458130 1098.535278,875.444946 C1152.974854,834.333923 1214.693970,809.827820 1281.029053,796.026917 C1325.323975,786.811340 1370.157349,784.187134 1415.249878,786.166382 C1453.634888,787.851135 1491.405640,793.821167 1529.124512,804.814697 z" Fill="{StaticResource Surface}"/>
              <Path Data="M437.969482,551.917969 C440.851166,542.602783 443.559052,534.068054 446.968933,523.320679 C481.903137,637.328430 516.194763,749.239075 550.661011,861.719727 C481.374115,861.719727 413.117462,861.719727 344.194763,861.719727 C344.347687,860.019104 344.224060,858.447571 344.652863,857.044983 C375.672363,755.587524 406.735779,654.143494 437.969482,551.917969 z" Fill="{StaticResource Accent}"/>


            </Canvas>
          </Viewbox>
          <TextBlock x:Name="VerLbl" Text="v6" FontSize="12" Foreground="{StaticResource Muted}" Margin="7,4,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel x:Name="HwChips" Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,18,0"/>
        <Border Grid.Column="2" Background="{StaticResource Surface2}" CornerRadius="8" Padding="14,8" VerticalAlignment="Center" MinWidth="172">
          <StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <TextBlock x:Name="CountLbl" Text="-/-" FontWeight="Bold" FontSize="15"/>
              <TextBlock Text="activas" Foreground="{StaticResource Muted}" FontSize="11" Margin="6,4,0,0"/>
            </StackPanel>
            <ProgressBar x:Name="StatusBar" Style="{StaticResource Slim}" Background="#131318" Minimum="0" Maximum="100" Value="0" Margin="0,7,0,0"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- MAIN -->
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="212"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

      <!-- NAV -->
      <Border Grid.Column="0" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
        <DockPanel Margin="0,10,0,0">
          <Grid DockPanel.Dock="Top" Margin="10,0,10,8">
            <TextBox x:Name="SearchBox" Style="{StaticResource Input}" TabIndex="1" AutomationProperties.Name="Buscar tweaks por nombre o descripcion"/>
            <!-- H12: watermark real (overlay), no texto-literal-como-valor -->
            <TextBlock Text="Buscar..." Foreground="{StaticResource Muted}" IsHitTestVisible="False"
                       VerticalAlignment="Center" Margin="11,0,0,0" FontSize="13">
              <TextBlock.Style>
                <Style TargetType="TextBlock">
                  <Setter Property="Visibility" Value="Collapsed"/>
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding Text.Length, ElementName=SearchBox}" Value="0">
                      <Setter Property="Visibility" Value="Visible"/>
                    </DataTrigger>
                  </Style.Triggers>
                </Style>
              </TextBlock.Style>
            </TextBlock>
          </Grid>
          <Border DockPanel.Dock="Bottom" Background="{StaticResource Surface}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="16,9,10,12">
            <StackPanel>
              <TextBlock Text="TIER" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Muted}" Margin="0,0,0,5"/>
              <StackPanel Orientation="Horizontal" Margin="0,1">
                <Ellipse Width="8" Height="8" Fill="{StaticResource Green}" VerticalAlignment="Center"/>
                <TextBlock Text="0  Seguro" FontSize="11" Foreground="{StaticResource Muted}" Margin="7,0,0,0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,1">
                <Ellipse Width="8" Height="8" Fill="{StaticResource Accent}" VerticalAlignment="Center"/>
                <TextBlock Text="1  Elite" FontSize="11" Foreground="{StaticResource Muted}" Margin="7,0,0,0"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" Margin="0,1">
                <Ellipse Width="8" Height="8" Fill="{StaticResource Red}" VerticalAlignment="Center"/>
                <TextBlock Text="2  EXTREMO" FontSize="11" Foreground="{StaticResource Muted}" Margin="7,0,0,0"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="NavPanel"/></ScrollViewer>
        </DockPanel>
      </Border>

      <!-- CONTENT -->
      <Border Grid.Column="1" Background="{StaticResource Bg}">
        <DockPanel Margin="16,12,8,8">
          <StackPanel DockPanel.Dock="Top" Margin="4,0,0,10">
            <TextBlock x:Name="ContentTitle" FontSize="17" FontWeight="Bold"/>
            <TextBlock x:Name="ContentSub" Foreground="{StaticResource Muted}" FontSize="12" Margin="0,2,0,0"/>
          </StackPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><Grid x:Name="ContentHost"/></ScrollViewer>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ACTION BAR -->
    <Border Grid.Row="2" Background="{StaticResource Surface}" Padding="16,10" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <WrapPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="BtnRestore" Style="{StaticResource PillGhost}" Content="Punto restauracion" TabIndex="10" AutomationProperties.Name="Crear punto de restauracion del sistema"/>
          <Button x:Name="BtnPreset"  Style="{StaticResource PillGhost}" Content="Preset gaming" TabIndex="11" AutomationProperties.Name="Marcar preset gaming (Tier 0 y 1)"/>
          <Button x:Name="BtnRead"    Style="{StaticResource PillGhost}" Content="Leer estado" TabIndex="12" AutomationProperties.Name="Leer estado real de los tweaks"/>
          <ProgressBar x:Name="ApplyBar" Style="{StaticResource Slim}" Width="150" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center" Margin="4,0,0,0" Visibility="Collapsed" AutomationProperties.Name="Progreso de aplicacion"/>
        </WrapPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="BtnMaster" Style="{StaticResource PillDanger}" Content="Master revert" TabIndex="13" AutomationProperties.Name="Revertir todos los tweaks a fabrica"/>
          <Button x:Name="BtnApply"  Style="{StaticResource Pill}" Background="{StaticResource Accent}" Content="APLICAR cambios" MinWidth="152" Margin="8,0,0,0" TabIndex="14" AutomationProperties.Name="Aplicar los cambios marcados"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- LOG -->
    <Border Grid.Row="3" Background="#131318" Height="152" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
      <DockPanel>
        <Grid DockPanel.Dock="Top" Background="#101015">
          <TextBlock Text="REGISTRO" FontSize="10" FontWeight="Bold" Foreground="{StaticResource Muted}" VerticalAlignment="Center" Margin="12,0,0,0"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,4,8,4">
            <Button x:Name="BtnLogCopy" Style="{StaticResource PillGhost}" Height="24" Padding="12,0" FontSize="11" Margin="0,0,6,0" Content="Copiar"/>
            <Button x:Name="BtnLogClear" Style="{StaticResource PillGhost}" Height="24" Padding="12,0" FontSize="11" Margin="0" Content="Limpiar"/>
          </StackPanel>
        </Grid>
        <RichTextBox x:Name="LogBox" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                 Foreground="#7CDCA0" FontFamily="Cascadia Code, Consolas" FontSize="12"
                 VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Padding="12,6">
          <RichTextBox.Document><FlowDocument PagePadding="0"/></RichTextBox.Document>
        </RichTextBox>
      </DockPanel>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$win = [System.Windows.Markup.XamlReader]::Load($reader)

# ---- 12.4 refs nombradas ----
$NavPanel     = $win.FindName('NavPanel')
$ContentHost  = $win.FindName('ContentHost')
$ContentTitle = $win.FindName('ContentTitle')
$SearchBox    = $win.FindName('SearchBox')
$HwChips      = $win.FindName('HwChips')
$LogoBox      = $win.FindName('LogoBox')
$LogoCanvas   = $win.FindName('LogoCanvas')
$CountLbl     = $win.FindName('CountLbl')
$StatusBar    = $win.FindName('StatusBar')
$VerLbl       = $win.FindName('VerLbl'); if($VerLbl){ $VerLbl.Text = "v$($script:AXEVersion)" }
$ApplyBar     = $win.FindName('ApplyBar')
$script:LogBox = $win.FindName('LogBox')
# Sink de log con color por severidad (ERR rojo / WARN ambar / INFO verde) + cap 500 lineas
$script:AXELogSink = {
    param($line,$level)
    $col = switch($level){ 'ERR' {'#F87171'} 'WARN' {'#FBBF24'} default {'#7CDCA0'} }
    $p = New-Object System.Windows.Documents.Paragraph
    $p.Margin = New-Object System.Windows.Thickness(0)
    $run = New-Object System.Windows.Documents.Run([string]$line)
    $run.Foreground = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($col))
    [void]$p.Inlines.Add($run)
    [void]$script:LogBox.Document.Blocks.Add($p)
    while($script:LogBox.Document.Blocks.Count -gt 500){ $script:LogBox.Document.Blocks.Remove($script:LogBox.Document.Blocks.FirstBlock) }
    $script:LogBox.ScrollToEnd()
}
$BtnRestore = $win.FindName('BtnRestore'); $BtnPreset = $win.FindName('BtnPreset')
$BtnRead = $win.FindName('BtnRead'); $BtnApply = $win.FindName('BtnApply'); $BtnMaster = $win.FindName('BtnMaster')
$ContentSub = $win.FindName('ContentSub')
$BtnLogCopy = $win.FindName('BtnLogCopy'); $BtnLogClear = $win.FindName('BtnLogClear')
$BtnLogCopy.Add_Click({ try { $tr=New-Object System.Windows.Documents.TextRange($script:LogBox.Document.ContentStart,$script:LogBox.Document.ContentEnd); [System.Windows.Clipboard]::SetText($tr.Text) } catch {} })
$BtnLogClear.Add_Click({ $script:LogBox.Document.Blocks.Clear() })

# ---- 12.5 chrome DWM (dark titlebar + Mica) tras tener HWND ----
$win.Add_SourceInitialized({
    $h = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    Set-AXEWindowChrome $h
})

