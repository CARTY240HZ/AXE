# =====================================================
# REGION 14c - RPC SECURITY HARDENING
#
# Defense-in-depth around the existing closed RPC map in 48-webbridge.ps1.
# The original dispatcher remains the single business-logic path; this wrapper
# only validates trust boundary inputs before handing them to it.
# =====================================================

$script:AXEBridgeOriginal = $null
try {
    if(Get-Command Invoke-AXEBridgeCmd -CommandType Function -EA SilentlyContinue){
        $script:AXEBridgeOriginal = ${function:Invoke-AXEBridgeCmd}
    }
} catch {}

function Test-AXEBridgeValue {
    param([AllowNull()]$Value,[int]$Depth=0)
    if($Depth -gt 6){ return $false }
    if($null -eq $Value){ return $true }
    if($Value -is [string]){ return $Value.Length -le 4096 }
    if($Value -is [bool] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]){ return $true }
    if($Value -is [System.Collections.IDictionary]){
        if($Value.Count -gt 32){ return $false }
        foreach($k in $Value.Keys){
            $ks = [string]$k
            if($ks.Length -gt 64 -or $ks -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$'){ return $false }
            if(-not (Test-AXEBridgeValue $Value[$k] ($Depth+1))){ return $false }
        }
        return $true
    }
    if($Value -is [System.Collections.IEnumerable]){
        $n = 0
        foreach($v in $Value){
            $n++
            if($n -gt 32){ return $false }
            if(-not (Test-AXEBridgeValue $v ($Depth+1))){ return $false }
        }
        return $true
    }
    if($Value.PSObject -and $Value.PSObject.Properties){
        $props = @($Value.PSObject.Properties)
        if($props.Count -gt 32){ return $false }
        foreach($p in $props){
            if($p.Name.Length -gt 64 -or $p.Name -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$'){ return $false }
            if(-not (Test-AXEBridgeValue $p.Value ($Depth+1))){ return $false }
        }
        return $true
    }
    $false
}

function Invoke-AXEBridgeCmd {
    param([string]$cmd,[hashtable]$cmdArgs)

    if(-not $script:AXEBridgeOriginal){
        return [pscustomobject]@{ ok=$false; data=$null; err='puente no inicializado' }
    }
    if([string]::IsNullOrWhiteSpace($cmd) -or $cmd.Length -gt 64){
        return [pscustomobject]@{ ok=$false; data=$null; err='cmd invalido' }
    }

    # The host is allowed to execute privileged operations only for the trusted local document.
    # A navigation elsewhere must never retain access to this process boundary.
    try {
        $src = if($script:Web -and $script:Web.Source){ [Uri]$script:Web.Source } else { $null }
        if(-not $src -or $src.Scheme -ne 'https' -or $src.Host -ne 'axe.local' -or ($src.Port -ne -1 -and $src.Port -ne 443)){
            return [pscustomobject]@{ ok=$false; data=$null; err='origen web no confiable' }
        }
    } catch {
        return [pscustomobject]@{ ok=$false; data=$null; err='origen web invalido' }
    }

    if($null -ne $cmdArgs){
        if(-not ($cmdArgs -is [hashtable])){
            return [pscustomobject]@{ ok=$false; data=$null; err='args invalidos' }
        }
        if($cmdArgs.Count -gt 32 -or -not (Test-AXEBridgeValue $cmdArgs)){ 
            return [pscustomobject]@{ ok=$false; data=$null; err='payload fuera de limites' }
        }
    }

    & $script:AXEBridgeOriginal $cmd $cmdArgs
}
