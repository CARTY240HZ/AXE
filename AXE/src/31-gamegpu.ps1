# =====================================================
# REGION 10c - GPU POR JUEGO (el unico lever de FPS que mueve la aguja de verdad)
# =====================================================
# POR QUE ESTE MODULO EXISTE
#   El resto del catalogo son ajustes GLOBALES de Windows: quitan trabajo de fondo y bajan
#   jitter, pero ninguno le da mas GPU al juego, porque no hay mas GPU que dar. Aqui si:
#
#   1. GpuPreference=2  -> en un equipo con GPU hibrida (iGPU Intel/AMD + dGPU dedicada),
#      Windows decide por heuristica cual usa cada .exe. Cuando falla, el juego corre en la
#      integrada. Forzarlo a la dedicada no es un 3%: es 2-5x FPS. Es, con diferencia, el
#      mayor lever de rendimiento que existe en todo AXE. En equipos de UNA sola GPU no
#      hace absolutamente nada, y este modulo lo dice en vez de fingir.
#   2. SwapEffectUpgradeEnable=1 -> sube los juegos en ventana/borderless del modelo blt
#      (copia extra por frame, via DWM) al modelo flip (la GPU presenta directa). Menos
#      latencia y mas FPS reales en borderless, que es como juega la mayoria. Es la mitad
#      POR-JUEGO de la funcion que gpu_vrr (VRROptimizeEnable, HKLM) activa a nivel global:
#      el interruptor "Optimizaciones para juegos con ventana" de Win11 escribe LAS DOS.
#   3. DISABLEDXMAXIMIZEDWINDOWEDMODE -> apaga Fullscreen Optimizations en ese .exe. NO es
#      universalmente bueno: en muchos juegos FSO ya usa flip y quitarlo EMPEORA el alt-tab
#      sin dar FPS. Va aparte y opt-in por eso, no metido en el boton de "optimizar".
#
# FORMATO DEL REGISTRO (verificado en build 26200, no deducido):
#   HKCU\SOFTWARE\Microsoft\DirectX\UserGpuPreferences
#     nombre = ruta completa del exe, valor = cadena "Clave=Valor;" concatenada.
#     Windows gestiona ahi tambien 'AppStatus' por su cuenta => se PRESERVAN las claves que
#     no tocamos. Reescribir la cadena entera seria borrarle estado al sistema.
#   HKCU\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers
#     nombre = ruta completa del exe, valor = tokens separados por espacio (HIGHDPIAWARE...).
#     Mismo criterio: se anade/quita UN token, el resto se respeta.
#
# REVERT: se captura la cadena ORIGINAL entera la primera vez que se toca un exe, igual que
# hace Push-RegBackup con los tweaks. Si el exe no tenia entrada, el revert la BORRA. No se
# escribe nunca un default supuesto (mismo principio que cpu_park / rend_ultperf).
# =====================================================

$script:GpuPrefKey  = 'HKCU:\SOFTWARE\Microsoft\DirectX\UserGpuPreferences'
$script:LayersKey   = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$script:GameGpuBak  = Join-Path $script:AXEData 'game_gpu.json'
$script:FSOToken    = 'DISABLEDXMAXIMIZEDWINDOWEDMODE'

# ---- parser del formato "K=V;K=V;" -------------------------------------------------
# Tolera la basura real que hay en el registro: cadenas que empiezan por ';', pares sin
# '=', espacios sueltos. Devuelve [ordered] para que reescribir no baraje el orden.
function ConvertFrom-AXEGpuPref($raw){
    $h = [ordered]@{}
    if([string]::IsNullOrWhiteSpace($raw)){ return $h }
    foreach($part in ($raw -split ';')){
        $p = $part.Trim()
        if([string]::IsNullOrWhiteSpace($p)){ continue }
        $i = $p.IndexOf('=')
        if($i -lt 1){ continue }
        $h[$p.Substring(0,$i).Trim()] = $p.Substring($i+1).Trim()
    }
    return $h
}
function ConvertTo-AXEGpuPref($h){
    $sb = New-Object System.Text.StringBuilder
    foreach($k in $h.Keys){ [void]$sb.Append("$k=$($h[$k]);") }
    return $sb.ToString()
}

# ---- topologia de GPU: solo asi sabemos si GpuPreference sirve de algo ---------------
# Cache permanente: la lista de adaptadores no cambia durante la sesion.
function Get-AXEGpuList {
    Get-AXECache 'pnp:gpulist' {
        @(Get-CimInstance Win32_VideoController -EA SilentlyContinue |
            Where-Object { $_.PNPDeviceID -like 'PCI*' -and $_.Name -notmatch 'Virtual|Basic Display|Remote|Meta|Parsec' })
    } -Permanent
}
function Test-AXEHybridGpu { (Get-AXEGpuList).Count -gt 1 }

# ---- snapshot (mismo contrato que tweak_state.json, fichero aparte) -------------------
function Read-GameGpuBak {
    if(-not(Test-Path $script:GameGpuBak)){ return @{} }
    try {
        $raw = Get-Content $script:GameGpuBak -Raw -Encoding UTF8
        if([string]::IsNullOrWhiteSpace($raw)){ return @{} }
        $o = $raw | ConvertFrom-Json -ErrorAction Stop
        $h = @{}; foreach($pr in $o.PSObject.Properties){ $h[$pr.Name] = $pr.Value }
        return $h
    } catch {
        Write-AXELog "game_gpu.json ilegible: $($_.Exception.Message). Renombrado a .corrupt" 'ERR'
        try { Move-Item $script:GameGpuBak "$($script:GameGpuBak).corrupt" -Force -EA Stop } catch {}
        return @{}
    }
}
function Save-GameGpuBak($h){ ($h | ConvertTo-Json -Depth 5) | Set-Content $script:GameGpuBak -Encoding UTF8 }

# Captura el estado previo de UN exe en UNA clave. Solo la primera vez (igual que
# Push-RegBackup): si vuelves a optimizar el mismo juego, el original sigue siendo el de la
# primera vez, no el que dejo AXE en la pasada anterior.
function Push-GameGpuBackup($exe,$key){
    $store = Read-GameGpuBak
    $id = "$key|$exe"
    if($store.ContainsKey($id)){ return }
    $rec = @{ Exe=$exe; Key=$key; Had=$false; V=$null }
    $v = Get-RV $key $exe
    if($null -ne $v){ $rec.Had = $true; $rec.V = [string]$v }
    $store[$id] = $rec
    Save-GameGpuBak $store
}

# ---- lectura de estado (para la GUI / Test) -----------------------------------------
function Get-AXEGameGpuState($exe){
    $pref = ConvertFrom-AXEGpuPref (Get-RV $script:GpuPrefKey $exe)
    $lay  = [string](Get-RV $script:LayersKey $exe)
    [pscustomobject]@{
        Exe       = $exe
        HighPerf  = ($pref['GpuPreference'] -eq '2')
        FlipModel = ($pref['SwapEffectUpgradeEnable'] -eq '1')
        NoFSO     = ($lay -split '\s+' -contains $script:FSOToken)
        Raw       = (Get-RV $script:GpuPrefKey $exe)
        RawLayers = $lay
    }
}

# ---- escritura ----------------------------------------------------------------------
# $HighPerf/$FlipModel son [bool] con $null = "no tocar", para poder cambiar una sola cosa
# sin arrastrar la otra.
function Set-AXEGameGpuPref {
    param([Parameter(Mandatory)][string]$Exe, $HighPerf = $null, $FlipModel = $null)
    if($null -eq $HighPerf -and $null -eq $FlipModel){ return }
    Push-GameGpuBackup $Exe $script:GpuPrefKey
    $h = ConvertFrom-AXEGpuPref (Get-RV $script:GpuPrefKey $Exe)
    # GpuPreference: 0=lo decide Windows, 1=ahorro (iGPU), 2=alto rendimiento (dGPU).
    # Apagarlo = volver a 0 (delegar), NO borrar la clave: borrarla y dejar la entrada del
    # exe a medias deja a Windows con una cadena que el no escribio.
    if($null -ne $HighPerf) { $h['GpuPreference']           = $(if($HighPerf) {'2'}else{'0'}) }
    if($null -ne $FlipModel){ $h['SwapEffectUpgradeEnable'] = $(if($FlipModel){'1'}else{'0'}) }
    Set-RS $script:GpuPrefKey $Exe (ConvertTo-AXEGpuPref $h)
}

function Set-AXEGameFSO {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][bool]$Disable)
    Push-GameGpuBackup $Exe $script:LayersKey
    $cur = [string](Get-RV $script:LayersKey $Exe)
    $toks = @($cur -split '\s+' | Where-Object { $_ -and $_ -ne $script:FSOToken })
    if($Disable){ $toks += $script:FSOToken }
    if($toks.Count -eq 0){
        # Sin tokens no se deja una cadena vacia: eso es una entrada muerta en Layers.
        Remove-ItemProperty -Path $script:LayersKey -Name $Exe -EA SilentlyContinue
    } else {
        Set-RS $script:LayersKey $Exe (($toks | Select-Object -Unique) -join ' ')
    }
}

# ---- revert ------------------------------------------------------------------------
# Devuelve el numero de claves restauradas. 0 = no habia snapshot (nunca se optimizo ese
# exe con AXE) y NO se toca nada: no se inventa un estado.
function Revert-AXEGameGpu($exe){
    $store = Read-GameGpuBak
    $n = 0
    foreach($id in @($store.Keys)){
        $r = $store[$id]
        if($r.Exe -ne $exe){ continue }
        try {
            if($r.Had){ Set-RS $r.Key $r.Exe $r.V }
            else      { Remove-ItemProperty -Path $r.Key -Name $r.Exe -EA SilentlyContinue }
            $store.Remove($id); $n++
        } catch { Write-AXELog "Revert GPU '$exe': fallo en $($r.Key): $($_.Exception.Message)" 'ERR' }
    }
    if($n -gt 0){ Save-GameGpuBak $store }
    return $n
}

# ---- accion de alto nivel ----------------------------------------------------------
# Aplica lo que SI es seguro-bueno para un juego: dGPU (si hay de donde elegir) + flip model.
# FSO queda fuera a proposito (ver cabecera). Devuelve lineas de log como los Run de
# Add-Clean, para poder llamarse desde runspace de fondo sin tocar Write-AXELog.
function Optimize-AXEGame {
    param([Parameter(Mandatory)][string]$Exe, [switch]$NoFSO)
    $out = New-Object System.Collections.ArrayList
    if(-not (Test-Path -LiteralPath $Exe)){
        [void]$out.Add("ERROR: no existe '$Exe'. Hace falta la RUTA COMPLETA del .exe (Windows indexa por ruta, no por nombre de proceso).")
        return $out.ToArray()
    }
    $hybrid = Test-AXEHybridGpu
    Set-AXEGameGpuPref -Exe $Exe -HighPerf $hybrid -FlipModel $true
    if($hybrid){
        $gpus = (Get-AXEGpuList | Select-Object -Expand Name) -join ' + '
        [void]$out.Add("GPU alto rendimiento forzada ($gpus). Este es el ajuste que mas FPS mueve de toda la suite.")
    } else {
        [void]$out.Add("Una sola GPU ($((Get-AXEGpuList | Select-Object -First 1 -Expand Name))): GpuPreference no aplica, no se fuerza. Ganancia por esta via = 0.")
    }
    [void]$out.Add('Flip model activado (SwapEffectUpgradeEnable=1): menos latencia en ventana/borderless.')
    if($NoFSO){
        Set-AXEGameFSO -Exe $Exe -Disable $true
        [void]$out.Add('Fullscreen Optimizations OFF. OJO: en muchos juegos esto NO da FPS y empeora el alt-tab. Mide antes/despues.')
    }
    [void]$out.Add('Los cambios entran al ARRANCAR el juego, no en caliente. Cierralo y abrelo.')
    return $out.ToArray()
}
