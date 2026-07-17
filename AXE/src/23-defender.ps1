# =====================================================
# REGION 5b - DEFENDER (gaps §7: exclusiones granulares opt-in, CPU limit, scan idle)
# Todo *-MpPreference / ScheduledTask en try/catch (AV de terceros o Tamper pueden
# rechazarlo). NO baja la proteccion global de Defender: solo afina rendimiento del
# escaneo y excluye rutas/procesos concretos de juegos (opt-in, reversible).
# Los cmdlets *-MpPreference funcionan con Tamper ON (no son registro crudo) => no se rutea.
# =====================================================

# --- Tweaks de rendimiento de Defender (catalogo, gated Defender=$true) ---
Add-Tweak @{Id='def_cpulimit';Cat='SERVICIOS';Tier=1;Reboot=$false;Name='Defender: limitar CPU de escaneo';Desc='ScanAvgCPULoadFactor 30 (default 50): el escaneo programado no acapara CPU';Requires=@{Defender=$true};
 Source='https://learn.microsoft.com/en-us/powershell/module/defender/set-mppreference';SourceType='official';PlaceboLikely=$false;NotesEng='Caps average CPU during SCHEDULED scans (not real-time) at 30% vs default 50. Helps only while a scheduled scan overlaps play; measure CPU during a manual scan before/after. Fully reversible to the 50 default.';
 Test={ try{ (Get-MpPreference -ErrorAction Stop).ScanAvgCPULoadFactor -le 30 }catch{ $false } };
 Apply={ try{ Set-MpPreference -ScanAvgCPULoadFactor 30 -ErrorAction Stop }catch{} };
 Revert={ try{ Set-MpPreference -ScanAvgCPULoadFactor 50 -ErrorAction Stop }catch{} }}
Add-Tweak @{Id='def_scanidle';Cat='SERVICIOS';Tier=1;Reboot=$false;Name='Defender: escaneo solo en reposo';Desc='La tarea "Windows Defender Scheduled Scan" corre solo con el equipo inactivo';Requires=@{Defender=$true};
 Source='https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-runonlyifidle';SourceType='official';PlaceboLikely=$false;NotesEng='Sets RunOnlyIfIdle on the Defender scheduled-scan task so it never fires mid-game. Tamper Protection may reject the change (wrapped, no-op on failure). Reversible to RunOnlyIfIdle=false.';
 Test={ try{ [bool](Get-ScheduledTask -TaskName 'Windows Defender Scheduled Scan' -ErrorAction Stop).Settings.RunOnlyIfIdle }catch{ $false } };
 Apply={ try{ $t=Get-ScheduledTask -TaskName 'Windows Defender Scheduled Scan' -ErrorAction Stop; $t.Settings.RunOnlyIfIdle=$true; Set-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null }catch{} };
 Revert={ try{ $t=Get-ScheduledTask -TaskName 'Windows Defender Scheduled Scan' -ErrorAction Stop; $t.Settings.RunOnlyIfIdle=$false; Set-ScheduledTask -InputObject $t -ErrorAction Stop | Out-Null }catch{} }}

# --- Exclusiones granulares opt-in (§7). Devuelven strings (corren en runspace/CLI).
# El modal de consentimiento (trade-off: excluir un proceso reduce cobertura AV) es
# responsabilidad de la capa UI antes de invocar estas funciones.
$script:AXEDefGames = @('cs2.exe','csgo.exe','valorant.exe','LeagueClient.exe','League of Legends.exe','FortniteClient-Win64-Shipping.exe','r5apex.exe','RainbowSix.exe')

function Get-AXESteamCommon {
    <#.SYNOPSIS Resuelve steamapps\common a ruta literal. NUNCA devuelve la raiz de Steam (vector de malware).#>
    $sp = $null
    foreach($k in 'HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam'){
        try{ $v = Get-ItemProperty $k -ErrorAction Stop; $sp = $v.SteamPath; if(-not $sp){ $sp = $v.InstallPath }; if($sp){ break } }catch{}
    }
    if(-not $sp){ return $null }
    try{ return (Resolve-Path -LiteralPath (Join-Path $sp 'steamapps\common') -ErrorAction Stop).Path }catch{ return $null }
}

function Add-AXEDefenderExclusion {
    <#.SYNOPSIS Exclusion opt-in de procesos de juego + steamapps\common. Reversible.#>
    param([string[]]$Process = $script:AXEDefGames)
    $out = New-Object System.Collections.ArrayList
    $mp = $null; try{ $mp = Get-MpComputerStatus -ErrorAction Stop }catch{}
    if(-not ($mp -and $mp.AMServiceEnabled)){ [void]$out.Add('Defender inactivo / AV de terceros: exclusiones omitidas'); return ($out -join "`n") }
    foreach($p in $Process){
        try{ Add-MpPreference -ExclusionProcess $p -ErrorAction Stop; [void]$out.Add("excl proceso: $p") }catch{ [void]$out.Add("fallo proceso $p : $($_.Exception.Message)") }
    }
    $common = Get-AXESteamCommon
    if($common){ try{ Add-MpPreference -ExclusionPath $common -ErrorAction Stop; [void]$out.Add("excl ruta: $common") }catch{ [void]$out.Add("fallo ruta: $($_.Exception.Message)") } }
    else { [void]$out.Add('steamapps\common no encontrado: ruta omitida (nunca se excluye la raiz de Steam)') }
    $out -join "`n"
}

function Remove-AXEDefenderExclusion {
    <#.SYNOPSIS Revierte las exclusiones creadas por Add-AXEDefenderExclusion.#>
    param([string[]]$Process = $script:AXEDefGames)
    $out = New-Object System.Collections.ArrayList
    foreach($p in $Process){ try{ Remove-MpPreference -ExclusionProcess $p -ErrorAction Stop; [void]$out.Add("quitada excl proceso: $p") }catch{} }
    $common = Get-AXESteamCommon
    if($common){ try{ Remove-MpPreference -ExclusionPath $common -ErrorAction Stop; [void]$out.Add("quitada excl ruta: $common") }catch{} }
    $out -join "`n"
}
