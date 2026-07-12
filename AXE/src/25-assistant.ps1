# =====================================================
# REGION 8 - ASISTENTE IA LOCAL (sin API, state-aware)
# =====================================================
function Get-AXEState($tw){
    $blk=Get-BlockReason $tw
    if($blk){ return @{S='BLOCK';T="  [BLOQUEADO] $($tw.Name)  ->  $blk"} }
    try { if([bool](& $tw.Test)){ return @{S='ON';T="  [ON]  $($tw.Name)"} } else { return @{S='OFF';T="  [off] $($tw.Name)  ->  $($tw.Desc)"} } }
    catch { return @{S='ERR';T="  [?]   $($tw.Name)"} }
}
function Report-Cats($cats,$titulo){
    $out=@("== $titulo =="); $off=0; $blk=0
    foreach($tw in $script:CAT){ if($cats -contains $tw.Cat){ $st=Get-AXEState $tw; $out+=$st.T; if($st.S -eq 'OFF'){$off++}; if($st.S -eq 'BLOCK'){$blk++} } }
    if($off -gt 0){ $out+="`n>> $off sin aplicar." } else { $out+="`n>> Todo lo aplicable ya esta ON." }
    if($blk -gt 0){ $out+=">> $blk bloqueado(s) por tu hardware." }
    $out -join "`r`n"
}
function Get-AXERecommendations {
    $r=New-Object System.Collections.ArrayList
    $ss=(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled')
    if($ss -eq 'Off' -or (Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen') -eq 0){
        [void]$r.Add('[CRITICO] SmartScreen DESACTIVADO. Reactivalo (Seguridad de Windows > Control de apps).')
    }
    $excl=@((Get-MpPreference -EA SilentlyContinue).ExclusionPath)
    if($excl.Count -gt 0){ [void]$r.Add("[SEGURIDAD] Defender tiene $($excl.Count) exclusion(es) de carpeta. Revisa: $($excl -join '; ')") }
    try {
        $up=((Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds
        $hog=Get-Process | Where-Object { $_.CPU -gt ($up*0.8) } | Sort-Object CPU -Descending | Select-Object -First 1
        if($hog){ [void]$r.Add("[RENDIMIENTO] '$($hog.Name)' lleva $('{0:N0}' -f $hog.CPU)s de CPU acumulada (proceso pesado). Cierralo antes de jugar.") }
    } catch {}
    $pend=0; foreach($tw in $script:CAT){ if($tw.Tier -lt 2 -and -not (Get-BlockReason $tw)){ try{ if(-not [bool](& $tw.Test)){$pend++} }catch{} } }
    if($pend -gt 0){ [void]$r.Add("[TWEAKS] $pend optimizaciones del preset aun sin aplicar.") }
    # Aviso EXTREMO sin Tamper: si VBS/CFG/ASLR estan aplicados pero Tamper sigue ON, Windows los reverts
    $tamperOff = (Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows Defender\Features' 'TamperProtection') -eq 0
    $extApplied = $false
    foreach($id in 'ext_vbs','ext_cfg','ext_aslr'){ $tw=$script:CAT | Where-Object Id -eq $id; if($tw -and (Test-TweakSafe $tw)){ $extApplied=$true; break } }
    if($extApplied -and -not $tamperOff){ [void]$r.Add('[AVISO] Tienes EXTREMO aplicado pero Tamper Protection sigue ON. En 24H2/25H2 Windows REVERTIRA esos cambios al reiniciar. Activa "Tamper Protection OFF" primero.') }
    if($script:HW.IsLaptop -and $script:HW.OnBattery){ [void]$r.Add('[ENERGIA] Estas en BATERIA. Conecta el cargador para maximo rendimiento.') }
    [void]$r.Add('[SEGURIDAD] Crea PRIMERO el PUNTO DE RESTAURACION (boton naranja).')
    $r
}
function Invoke-AXEAssistant($q){
    if([string]::IsNullOrWhiteSpace($q)){ return 'Escribe: "que aplico", "input lag", "fps", "red", "seguridad", "portatil".' }
    $s=$q.ToLower()
    if($s -match 'recom|que aplic|que hago|deber|empez|inicio|todo|optimiz'){ return (Get-AXERecommendations) -join "`r`n" }
    if($s -match 'input|lag|raton|mouse|latenc|delay|responsiv'){ return (Report-Cats @('LATENCIA','CPU') 'INPUT LAG / LATENCIA') }
    if($s -match 'fps|juego|gaming|rendi|frame'){ return (Report-Cats @('GPU','SISTEMA','CPU','RENDIMIENTO') 'FPS / GAMING') + "`n>> Cierra overlays de fondo antes de jugar." }
    if($s -match 'red|ping|dns|internet|wifi|online|conexion'){ $r=Report-Cats @('RED') 'RED'; if($script:HW.IsWifi){ $r+="`n>> Wi-Fi: el jitter lo domina la radio. Cable = mas estabilidad." }; $r+="`n>> DNS: pestana DNS."; return $r }
    if($s -match 'segur|virus|defender|smartscreen|malware|proteg'){
        $out=@('== SEGURIDAD ==')
        $ss=(Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled')
        if($ss -eq 'Off' -or (Get-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableSmartScreen') -eq 0){ $out+='  [CRITICO] SmartScreen DESACTIVADO.' } else { $out+='  [OK] SmartScreen activo.' }
        $ex=@((Get-MpPreference -EA SilentlyContinue).ExclusionPath)
        if($ex.Count -gt 0){ $out+="  [AVISO] $($ex.Count) exclusion(es) de Defender." } else { $out+='  [OK] Sin exclusiones.' }
        $out+='  Tier EXTREMO reduce seguridad: solo opt-in consciente.'
        return $out -join "`r`n"
    }
    if($s -match 'portatil|bateria|termic|calor|energia|power'){ $r=Report-Cats @('CPU') 'ENERGIA / CPU'; if($script:HW.IsLaptop){ $r+="`n>> Portatil hibrido: Core Parking/Alto Rendimiento bruto throttlea." }; return $r }
    if($s -match 'ram|memoria|cache'){ return (Report-Cats @('MEMORIA') 'MEMORIA') }
    if($s -match 'extremo|vbs|spectre|mitigac|cfg|aslr|tamper|defender'){ $r=Report-Cats @('EXTREMO') 'EXTREMO (tu estado real)'; $r+="`n>> ORDEN: activa PRIMERO Tamper Protection OFF, despues VBS/CFG/ASLR (sin Tamper off, Windows los revierte al reiniciar en 24H2/25H2)."; $r+="`n>> VBS/HVCI: +5-10% FPS (Tom's Hardware). CFG/ASLR: ganancia pequena en CPU-bound."; $r+="`n>> Cada uno baja seguridad. No recomiendo TODO apagado salvo PC solo-gaming."; return $r }
    if($s -match 'servicio|telemetr|privac'){ return (Report-Cats @('SERVICIOS','PRIVACIDAD') 'SERVICIOS / PRIVACIDAD') }
    if($s -match 'limpi|basura|temp|disco|espacio'){ return "Pestana LIMPIEZA: temporales, shaders, cache WU, flush DNS, working set." }
    if($s -match 'debloat|apps|uwp|bloatware'){ return "Pestana DEBLOAT: apps UWP. Reinstalables desde Store." }
    if($s -match 'startup|inicio|arranque|autorun'){ return "Pestana STARTUP: autoruns reales + RESTAURAR (boton verde) recupera el backup." }
    return "Temas: que aplico, input lag, fps, red, seguridad, portatil, ram, extremo, servicios, limpieza, debloat, startup."
}

