# =====================================================
# REGION 7 - ACCIONES (limpieza, debloat, DNS)
# =====================================================
$script:CLEAN = New-Object System.Collections.ArrayList
function Add-Clean($h){ [void]$script:CLEAN.Add([pscustomobject]$h) }
# NOTA: los Run DEVUELVEN lineas de log (string) en vez de llamar Write-AXELog, para
# poder ejecutarse en runspace de fondo (la GUI no congela). El handler GUI las loguea.
Add-Clean @{Name='Temporales (usuario + Windows)';Desc='Borra %TEMP% y C:\Windows\Temp';Run={
    $b=[math]::Round((Get-PSDrive C).Free/1GB,2); Remove-Item "$env:TEMP\*" -Recurse -Force -EA SilentlyContinue; Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -EA SilentlyContinue; $a=[math]::Round((Get-PSDrive C).Free/1GB,2); "Temporales limpios. Libre: $b -> $a GB" }}
Add-Clean @{Name='Cache shaders DirectX';Desc='Se regenera sola; util tras update de driver';Run={ Remove-Item "$env:LOCALAPPDATA\D3DSCache\*" -Recurse -Force -EA SilentlyContinue; 'Cache shaders DirectX limpiada.' }}
Add-Clean @{Name='Cache Windows Update';Desc='Para wuauserv/bits, borra Download, reinicia';Run={
    Stop-Service wuauserv,bits -Force -EA SilentlyContinue; Remove-Item 'C:\Windows\SoftwareDistribution\Download\*' -Recurse -Force -EA SilentlyContinue; Start-Service bits,wuauserv -EA SilentlyContinue; 'Cache Windows Update limpiada.' }}
Add-Clean @{Name='Flush DNS';Desc='Vacia cache de resolucion de nombres';Run={ ipconfig /flushdns | Out-Null; 'Cache DNS vaciada.' }}
Add-Clean @{Name='Purga working set (RAM)';Desc='Libera RAM en cache de procesos idle';Run={
    $sig='[DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);'; $t=('LW.WS' -as [type]); if(-not $t){ $t=Add-Type -MemberDefinition $sig -Name WS -Namespace LW -PassThru }; $n=0; Get-Process | ForEach-Object { try{ if($t::EmptyWorkingSet($_.Handle)){$n++} }catch{} }; "Working set purgado en $n procesos." }}

$script:DEBLOAT = @(
    @{Pkg='Microsoft.BingNews';Name='Noticias (Bing)'}
    @{Pkg='Microsoft.BingWeather';Name='El Tiempo'}
    @{Pkg='Microsoft.GamingApp';Name='Xbox App'}
    @{Pkg='Microsoft.XboxGamingOverlay';Name='Xbox Game Bar overlay'}
    @{Pkg='Microsoft.XboxSpeechToTextOverlay';Name='Xbox voz'}
    @{Pkg='Microsoft.549981C3F5F10';Name='Cortana'}
    @{Pkg='Clipchamp.Clipchamp';Name='Clipchamp (editor video)'}
    @{Pkg='Microsoft.Todos';Name='Microsoft To Do'}
    @{Pkg='Microsoft.PowerAutomateDesktop';Name='Power Automate'}
    @{Pkg='Microsoft.MicrosoftOfficeHub';Name='Office Hub'}
    @{Pkg='Microsoft.MicrosoftSolitaireCollection';Name='Solitaire'}
    @{Pkg='Microsoft.People';Name='Contactos'}
    @{Pkg='Microsoft.WindowsFeedbackHub';Name='Comentarios'}
    @{Pkg='Microsoft.GetHelp';Name='Obtener ayuda'}
    @{Pkg='Microsoft.Getstarted';Name='Sugerencias'}
    @{Pkg='MicrosoftTeams';Name='Teams (personal)'}
    @{Pkg='Microsoft.Copilot';Name='Copilot (app)'}
)
function Get-DebloatInstalled($pkg){ [bool](Get-AppxPackage -Name $pkg -EA SilentlyContinue) }

$script:DNSPROFILES = @(
    @{Name='Cloudflare (1.1.1.1)';V4=@('1.1.1.1','1.0.0.1')}
    @{Name='Google (8.8.8.8)';V4=@('8.8.8.8','8.8.4.4')}
    @{Name='AdGuard (bloquea ads)';V4=@('94.140.14.14','94.140.15.15')}
    @{Name='Quad9 (seguridad)';V4=@('9.9.9.9','149.112.112.112')}
    @{Name='Automatico (DHCP)';V4=$null}
)
