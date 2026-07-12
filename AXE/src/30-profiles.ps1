# =====================================================
# REGION 10b - PERFILES POR-JUEGO (power-plan-per-game, live-safe)
# Detecta el juego corriendo -> cambia el plan de energia -> restaura al cerrar.
# Lever REAL en vivo (la freq policy cambia al instante). NO toca el proceso del juego
# (0 riesgo anticheat) ni aplica tweaks de registro (esos son reboot / solo-al-arrancar).
# =====================================================
$script:ProfilesBak = Join-Path $script:AXEData 'game_profiles.json'
$script:profActive   = $null    # nombre del perfil actualmente aplicado
$script:profPrevPlan = $null    # GUID del plan que estaba activo antes de aplicar (para restaurar)

function Read-Profiles {
    if(-not(Test-Path $script:ProfilesBak)){ return @() }
    $raw = Get-Content $script:ProfilesBak -Raw -Encoding UTF8
    if([string]::IsNullOrWhiteSpace($raw)){ return @() }
    try { return @($raw | ConvertFrom-Json -ErrorAction Stop) } catch { return @() }
}
function Save-Profiles($list) {
    $arr = @($list)
    # forzar '[]' cuando esta vacio: si no, ConvertTo-Json no emite nada y Set-Content
    # no llega a escribir (dejaria el fichero anterior intacto = borrado que no borra).
    $json = if($arr.Count -eq 0){ '[]' } else { ConvertTo-Json -InputObject $arr -Depth 5 }
    Set-Content -Path $script:ProfilesBak -Value $json -Encoding UTF8
}
function Add-GameProfile($name,$exe,$plan,$planName) {
    $exe = ($exe -replace '\.exe$','')   # normaliza: guardamos el nombre de proceso sin extension
    $list = [System.Collections.ArrayList]@(Read-Profiles | Where-Object { $_.Name -ne $name })
    [void]$list.Add([pscustomobject]@{Name=$name; Exe=$exe; Plan=$plan; PlanName=$planName})
    Save-Profiles $list.ToArray()
    return $list.Count
}
function Remove-GameProfile($name) {
    Save-Profiles (@(Read-Profiles | Where-Object { $_.Name -ne $name }))
}
# ---- power plans (locale-agnostico: el GUID se extrae por regex) ----
function Get-PowerPlans {
    $out = New-Object System.Collections.ArrayList
    foreach($line in (powercfg /list 2>$null)){
        if($line -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}).*\(([^)]+)\)'){
            [void]$out.Add([pscustomobject]@{Guid=$matches[1]; Name=$matches[2].Trim()})
        }
    }
    $out
}
function Get-ActivePlan {
    $s = (powercfg /getactivescheme 2>$null | Out-String)
    if($s -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'){ return $matches[1] }
    return $null
}
function Set-ActivePlan($guid) {
    if([string]::IsNullOrWhiteSpace($guid)){ return $false }
    powercfg /setactive $guid 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Test-GameRunning($exe) {
    if([string]::IsNullOrWhiteSpace($exe)){ return $false }
    [bool](Get-Process -Name ($exe -replace '\.exe$','') -EA SilentlyContinue)
}
function Apply-GameProfile($p) {
    if($script:profActive -eq $p.Name){ return }   # idempotente
    $script:profPrevPlan = Get-ActivePlan
    if(Set-ActivePlan $p.Plan){
        $script:profActive = $p.Name
        Write-AXELog "Perfil '$($p.Name)' ON -> plan '$($p.PlanName)' (juego: $($p.Exe))."
    } else { Write-AXELog "Perfil '$($p.Name)': no pude cambiar el plan de energia." 'WARN' }
}
function Revert-GameProfile {
    if(-not $script:profActive){ return }
    $name = $script:profActive
    if($script:profPrevPlan){ Set-ActivePlan $script:profPrevPlan | Out-Null }
    Write-AXELog "Perfil '$name' OFF -> plan restaurado (juego cerrado)."
    $script:profActive = $null; $script:profPrevPlan = $null
}
# Un tick del monitor: aplica el perfil del juego que corre, o revierte si su juego cerro.
# Puro (sin timer) => testeable headless. Devuelve el nombre del perfil activo o $null.
function Tick-GameProfiles {
    if($script:busy){ return $script:profActive }   # no colisiona con APLICAR/MASTER/jobs
    $profs = Read-Profiles
    if($script:profActive){
        $ap = $profs | Where-Object { $_.Name -eq $script:profActive } | Select-Object -First 1
        if(-not $ap -or -not (Test-GameRunning $ap.Exe)){ Revert-GameProfile }
        return $script:profActive
    }
    foreach($p in $profs){ if(Test-GameRunning $p.Exe){ Apply-GameProfile $p; break } }
    return $script:profActive
}

