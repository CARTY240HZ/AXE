# =====================================================
# REGION 14c - BROKER (proceso privilegiado bajo demanda)
# =====================================================
# Separa la logica privilegiada (Set-RD/sc.exe/bcdedit/Set-ProcessMitigation) del proceso
# UI/WebView2 (issue #5, auditoria 2026-09-22 s1.2). Solo 4 comandos del bridge la necesitan
# (grep de Test-Admin en 48-webbridge.ps1, verificado): tweaks.apply, tweaks.revert,
# tweaks.masterRevert, safety.restorePoint. El resto del bridge sigue en el proceso UI sin
# cambios.
#
# Modelo: on-demand por operacion. La UI relanza ESTE MISMO script con -Broker <pipeName>
# -Token <ruta> via Start-Process -Verb RunAs; el broker procesa EXACTAMENTE una peticion
# (o un lote resuelto el mismo, ver tweaks.masterRevert en Invoke-AXEBrokerCommand) y sale.
# Nunca queda residente.
#
# Funciones puras primero (testeables sin pipe real, mismo patron que 35-diag.ps1): validacion
# de mensaje. Luego las impuras (Start-AXEBroker/servidor, Send-AXEBrokerRequest/cliente).

$script:AXEBrokerCommands  = @('tweaks.apply','tweaks.revert','tweaks.masterRevert','safety.restorePoint')
$script:AXEBrokerMaxBytes  = 65536   # 64 KB: tope de tamano del mensaje
$script:AXEBrokerMaxDepth  = 8       # tope de profundidad JSON
$script:AXEBrokerMaxSkewSec = 5      # ventana de frescura del timestamp

function Test-AXEBrokerCommand([string]$Cmd){
    # Whitelist HARDCODEADA aqui, no compartida por referencia con $script:AXEBrokerMap del
    # bridge: aunque coincida en valores hoy, el broker no debe depender de que nadie la amplie
    # sin querer. -ccontains: mismo criterio case-sensitive que ya usa Invoke-AXEBridgeCmd.
    @($script:AXEBrokerCommands) -ccontains $Cmd
}

function Test-AXEBrokerJsonDepth([string]$Json, [int]$MaxDepth = $script:AXEBrokerMaxDepth){
    # Prescan de profundidad ANTES de parsear: ConvertFrom-Json no tiene -Depth en Windows
    # PowerShell 5.1 (solo ConvertTo-Json lo tiene), asi que el tope se aplica a mano sobre el
    # texto, no fiandose del parser. Cuenta { [ frente a } ] IGNORANDO lo que hay dentro de
    # cadenas JSON (respeta \" como escape), sin depender de ninguna libreria nueva.
    $depth = 0; $max = 0; $inStr = $false; $esc = $false
    foreach($ch in $Json.ToCharArray()){
        if($esc){ $esc = $false; continue }
        if($inStr){
            if($ch -eq '\'){ $esc = $true }
            elseif($ch -eq '"'){ $inStr = $false }
            continue
        }
        switch($ch){
            '"' { $inStr = $true }
            '{' { $depth++; if($depth -gt $max){ $max = $depth } }
            '[' { $depth++; if($depth -gt $max){ $max = $depth } }
            '}' { $depth-- }
            ']' { $depth-- }
        }
        if($max -gt $MaxDepth){ return $false }
    }
    $true
}

function Test-AXEBrokerTimestamp([long]$Ts, [datetime]$Now = (Get-Date)){
    # $Ts en epoch-millis UTC (Date.now() de JS / [DateTimeOffset]::UtcNow en PS).
    if($Ts -le 0){ return $false }
    $msgTime = [DateTimeOffset]::FromUnixTimeMilliseconds($Ts).UtcDateTime
    $skew = [Math]::Abs(($Now.ToUniversalTime() - $msgTime).TotalSeconds)
    $skew -le $script:AXEBrokerMaxSkewSec
}

function Write-AXEBrokerFrame([System.IO.Stream]$Stream, [string]$Json){
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    if($bytes.Length -gt $script:AXEBrokerMaxBytes){
        throw "mensaje demasiado grande ($($bytes.Length) bytes, maximo $script:AXEBrokerMaxBytes)"
    }
    $lenBytes = [BitConverter]::GetBytes([int]$bytes.Length)
    if(-not [BitConverter]::IsLittleEndian){ [Array]::Reverse($lenBytes) }
    $Stream.Write($lenBytes, 0, 4)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Read-AXEBrokerFrame([System.IO.Stream]$Stream){
    # Devuelve el JSON como string, o $null si el stream se cerro sin mandar nada (EOF limpio).
    # Rechaza por TAMANO DECLARADO antes de leer el cuerpo: nunca bufferiza un payload sin limite.
    $lenBytes = New-Object byte[] 4
    $read = 0
    while($read -lt 4){
        $n = $Stream.Read($lenBytes, $read, 4 - $read)
        if($n -eq 0){ if($read -eq 0){ return $null } else { throw 'conexion cerrada a mitad de la cabecera' } }
        $read += $n
    }
    if(-not [BitConverter]::IsLittleEndian){ [Array]::Reverse($lenBytes) }
    $len = [BitConverter]::ToInt32($lenBytes, 0)
    if($len -le 0 -or $len -gt $script:AXEBrokerMaxBytes){
        throw "longitud de mensaje invalida o excede el tope ($len bytes, maximo $script:AXEBrokerMaxBytes)"
    }
    $buf = New-Object byte[] $len
    $read = 0
    while($read -lt $len){
        $n = $Stream.Read($buf, $read, $len - $read)
        if($n -eq 0){ throw 'conexion cerrada a mitad del cuerpo' }
        $read += $n
    }
    [System.Text.Encoding]::UTF8.GetString($buf)
}

function Read-AXEBrokerRequest([string]$Json, [string]$ExpectedToken){
    # PURA: valida y devuelve {Ok;Cmd;Args;Reason}. Nunca lanza por un mensaje malformado --
    # eso es EXACTAMENTE el input que hay que poder rechazar sin reventar el broker (issue #5,
    # criterio de aceptacion 4).
    if(-not (Test-AXEBrokerJsonDepth $Json)){
        return [pscustomobject]@{ Ok=$false; Cmd=$null; Args=$null; Reason='profundidad de JSON excede el tope' }
    }
    try { $msg = $Json | ConvertFrom-Json -EA Stop }
    catch { return [pscustomobject]@{ Ok=$false; Cmd=$null; Args=$null; Reason='JSON invalido' } }
    foreach($k in 'cmd','token','ts'){
        if(-not $msg.PSObject.Properties[$k]){ return [pscustomobject]@{ Ok=$false; Cmd=$null; Args=$null; Reason="falta '$k'" } }
    }
    if([string]$msg.token -ne [string]$ExpectedToken){
        return [pscustomobject]@{ Ok=$false; Cmd=$null; Args=$null; Reason='token invalido' }
    }
    if(-not (Test-AXEBrokerTimestamp ([long]$msg.ts))){
        return [pscustomobject]@{ Ok=$false; Cmd=$null; Args=$null; Reason='timestamp fuera de ventana' }
    }
    if(-not (Test-AXEBrokerCommand ([string]$msg.cmd))){
        return [pscustomobject]@{ Ok=$false; Cmd=$null; Args=$null; Reason="comando no permitido: $($msg.cmd)" }
    }
    $argsHt = @{}
    if($msg.args){ $msg.args.PSObject.Properties | ForEach-Object { $argsHt[$_.Name] = $_.Value } }
    [pscustomobject]@{ Ok=$true; Cmd=[string]$msg.cmd; Args=$argsHt; Reason=$null }
}
