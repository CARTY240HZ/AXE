# =====================================================
# REGION 14 - PUENTE RPC (JS <-> PS). SUPERFICIE DE ATAQUE.
# =====================================================
# Regla dura: lista blanca cerrada. cmd fuera de la lista => rechazo. Nunca eval del payload.
# Cargar este modulo SOLO define funciones y el mapa; nada se ejecuta hasta Register-AXEBridge
# (lo llama 47-webhost en el init del control). Cada cmd mapea a una funcion YA EXISTENTE del
# motor (1-45); aqui no se anade logica de negocio.

# Mapa cerrado: cmd -> scriptblock($args) que devuelve el 'data' (o lanza).
$script:AXEBridgeMap = @{
    'hw.get' = { param($a)
        if(-not $script:HW){ $script:HW = Get-AXEHardware }
        $script:HW
    }
}

function Invoke-AXEBridgeCmd {
    param([string]$cmd,[hashtable]$cmdArgs)
    $fn = $script:AXEBridgeMap[$cmd]
    if(-not $fn){ return [pscustomobject]@{ ok=$false; data=$null; err="cmd desconocido: $cmd" } }
    try {
        $data = & $fn $cmdArgs
        return [pscustomobject]@{ ok=$true; data=$data; err='' }
    } catch {
        Write-AXELog "Puente: $cmd lanzo: $($_.Exception.Message)" 'ERR'
        return [pscustomobject]@{ ok=$false; data=$null; err=$_.Exception.Message }
    }
}

function Register-AXEBridge($core){
    # JS -> PS: cada mensaje es {id, cmd, args}. Se responde por ExecuteScriptAsync(__axeReply).
    $core.add_WebMessageReceived({
        param($s,$e)
        $reqId = -1
        try {
            $msg = $e.WebMessageAsJson | ConvertFrom-Json
            $reqId = [int]$msg.id
            # Diagnostico (AXE_WEBUI_DEBUG=1): corre en el hilo UI (con runspace) => Write-AXELog
            # funciona. Prueba que el postMessage del navegador llega al puente (JS->PS).
            if($env:AXE_WEBUI_DEBUG -eq '1'){ Write-AXELog "Puente RX id=$reqId cmd=$($msg.cmd)" 'INFO' }
            $argsHt = @{}
            if($msg.args){ $msg.args.PSObject.Properties | ForEach-Object { $argsHt[$_.Name] = $_.Value } }
            $res = Invoke-AXEBridgeCmd $msg.cmd $argsHt
        } catch {
            $res = [pscustomobject]@{ ok=$false; data=$null; err="payload invalido: $($_.Exception.Message)" }
        }
        $json = ($res | ConvertTo-Json -Depth 8 -Compress)
        # __axeReply(id, jsonString): el JSON viaja como argumento string. ConvertTo-Json del string
        # lo envuelve en comillas escapadas => JSON.parse en JS lo desdobla, sin inyeccion de comillas.
        $js = 'window.__axeReply(' + $reqId + ', ' + ($json | ConvertTo-Json) + ')'
        [void]$s.ExecuteScriptAsync($js)
    })
}
