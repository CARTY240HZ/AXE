# =====================================================
# REGION 14c - BROKER (proceso privilegiado bajo demanda)
# =====================================================
# Separa la logica privilegiada (Set-RD/sc.exe/bcdedit/Set-ProcessMitigation) del proceso
# UI/WebView2 (issue #5, auditoria 2026-09-22 s1.2). Solo los 7 comandos de
# $script:AXEBrokerCommands (abajo, fuente unica) corren elevados: tweaks.apply, tweaks.revert,
# tweaks.masterRevert, safety.restorePoint, fps.capture, tweaks.applyBatch y tweaks.revertBatch.
# El resto del bridge sigue en el proceso UI sin cambios.
#
# Modelo: on-demand por operacion. La UI relanza ESTE MISMO script con -Broker <pipeName>
# -Token <ruta> via Start-Process -Verb RunAs; el broker procesa EXACTAMENTE una peticion
# (o un lote resuelto el mismo, ver tweaks.masterRevert en Invoke-AXEBrokerCommand) y sale.
# Nunca queda residente.
#
# Funciones puras primero (testeables sin pipe real, mismo patron que 35-diag.ps1): validacion
# de mensaje. Luego las impuras (Start-AXEBroker/servidor, Send-AXEBrokerRequest/cliente).

# fps.capture: PresentMon abre una sesion ETW, que exige admin; desde que la UI no corre elevada
# (issue #5) la captura fallaba siempre. Su unico dato libre se valida en Invoke-AXEBrokerCommand.
# applyBatch/revertBatch: Optimizar en un clic, N tweaks con UN UAC (spec 2026-09-24).
$script:AXEBrokerCommands  = @('tweaks.apply','tweaks.revert','tweaks.masterRevert','safety.restorePoint','fps.capture','tweaks.applyBatch','tweaks.revertBatch')
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

function Read-AXEBrokerFrame([System.IO.Stream]$Stream, [int]$TimeoutMs = 30000){
    # Devuelve el JSON como string, o $null si el stream se cerro sin mandar nada (EOF limpio).
    # Rechaza por TAMANO DECLARADO antes de leer el cuerpo: nunca bufferiza un payload sin limite.
    # $TimeoutMs acota el frame ENTERO: Stream.Read de un pipe no tiene timeout propio y un
    # extremo que se queda mudo (suspension, AV interceptando el pipe, ventana matada a mitad)
    # dejaba el broker ELEVADO esperando para siempre, contra su "nunca queda residente".
    # ReadAsync + Wait: funciona igual en pipes sincronos y en MemoryStream (tests). Va DENTRO de
    # esta funcion y no en un helper aparte porque Invoke-AXEPrivilegedBackground copia al
    # runspace de fondo solo las funciones que nombra.
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $readSome = {
        param($b, $off, $cnt)
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if($left -le 0){ throw "el otro extremo no respondio en $TimeoutMs ms" }
        $t = $Stream.ReadAsync($b, $off, $cnt)
        if(-not $t.Wait($left)){ throw "el otro extremo no respondio en $TimeoutMs ms" }
        $t.Result
    }
    $lenBytes = New-Object byte[] 4
    $read = 0
    while($read -lt 4){
        $n = & $readSome $lenBytes $read (4 - $read)
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
        $n = & $readSome $buf $read ($len - $read)
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

    # Guard contra top-level null: ConvertFrom-Json retorna $null en PowerShell 5.1,
    # y $null.PSObject.Properties lanza en lugar de retornar $null como en PS7+
    if($null -eq $msg){
        return [pscustomobject]@{ Ok=$false; Cmd=$null; Args=$null; Reason='peticion malformada' }
    }

    # Wrap todo lo demas en try/catch para convertir CUALQUIER excepcion
    # (e.g., [long]$msg.ts con valor no-numerico) en Ok=$false, no throw.
    try {
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
    catch {
        return [pscustomobject]@{ Ok=$false; Cmd=$null; Args=$null; Reason='peticion malformada' }
    }
}

function Test-AXEBrokerIds($Raw){
    # Lote de ids del front: devuelve string[] valido o un string con el motivo. @() normaliza el id
    # unico que PS 5.1 entrega como string al deserializar un array JSON de un elemento. Se valida
    # el lote ENTERO antes de tocar nada: un id malo no aplica "la mitad".
    $ids = @($Raw)
    if($ids.Count -lt 1 -or $ids.Count -gt @($script:CAT).Count){ return 'lote vacio o demasiado grande' }
    foreach($i in $ids){ if($i -isnot [string] -or $i -notmatch '^[A-Za-z0-9_]{1,48}$'){ return 'id invalido en el lote' } }
    if(@($ids | Select-Object -Unique).Count -ne $ids.Count){ return 'ids duplicados en el lote' }
    $known = @($script:CAT | ForEach-Object { [string]$_.Id })
    foreach($i in $ids){ if($known -cnotcontains $i){ return "tweak desconocido: $i" } }
    ,[string[]]$ids
}

function Initialize-AXEBrokerHW {
    # El proceso broker sale en 49-webmain sin haber detectado hardware, y Get-BlockReason con
    # $script:HW vacio devuelve $null = "aplicable": sin esto la revalidacion no bloqueaba nada.
    if(-not $script:HW){ try { $script:HW = Get-AXEHardware } catch {} }
    [bool]$script:HW
}

function Invoke-AXEBrokerApplyOne($tw){
    # Protocolo de snapshot de siempre (capTweak -> Apply -> Commit-TweakState). Nunca lanza: un
    # tweak roto se reporta y el lote sigue.
    try {
        $blk = Get-BlockReason $tw
        if($blk){ return @{ id=$tw.Id; ok=$false; applied=$false; reboot=[bool]$tw.Reboot; err="no aplicable en este equipo: $blk" } }
        if(Test-SnapEligible $tw){ $script:capTweak = $tw.Id }
        try { & $tw.Apply } finally { $script:capTweak = $null }
        Commit-TweakState $tw.Id
        @{ id=$tw.Id; ok=$true; applied=[bool](Test-TweakSafe $tw); reboot=[bool]$tw.Reboot; err=$null }
    } catch { @{ id=$tw.Id; ok=$false; applied=$false; reboot=[bool]$tw.Reboot; err=$_.Exception.Message } }
}

function Invoke-AXEBrokerRevertOne($tw){
    try {
        if(-not ((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){ & $tw.Revert }
        @{ id=$tw.Id; ok=$true; applied=[bool](Test-TweakSafe $tw); reboot=[bool]$tw.Reboot; err=$null }
    } catch { @{ id=$tw.Id; ok=$false; applied=$true; reboot=[bool]$tw.Reboot; err=$_.Exception.Message } }
}

function Invoke-AXEBrokerCommand([string]$Cmd, [hashtable]$A){
    # Motor de decision del broker: los 7 unicos comandos que puede ejecutar, usando EXACTAMENTE
    # el mismo protocolo de snapshot ya arreglado en el bridge (auditoria 2026-09-22 s1.1) --
    # $script:CAT/Get-BlockReason/Test-SnapEligible/Commit-TweakState/Restore-TweakState son las
    # funciones REALES del motor, no una copia. Nunca lanza hacia fuera: cualquier excepcion se
    # repackea como {ok=false}.
    try {
        switch($Cmd){
            'tweaks.apply' {
                $tw = $script:CAT | Where-Object Id -eq ([string]$A.id) | Select-Object -First 1
                if(-not $tw){ return @{ ok=$false; data=$null; err="tweak desconocido: $($A.id)" } }
                # Sin hardware detectable NO se aplica a ciegas. revert/masterRevert no lo necesitan:
                # deshacer siempre vale.
                if(-not (Initialize-AXEBrokerHW)){ return @{ ok=$false; data=$null; err='no pude detectar el hardware: no aplico a ciegas' } }
                $r = Invoke-AXEBrokerApplyOne $tw
                if(-not $r.ok){ return @{ ok=$false; data=$null; err=$r.err } }
                @{ ok=$true; data=@{ id=$r.id; applied=$r.applied; reboot=$r.reboot }; err=$null }
            }
            'tweaks.revert' {
                $tw = $script:CAT | Where-Object Id -eq ([string]$A.id) | Select-Object -First 1
                if(-not $tw){ return @{ ok=$false; data=$null; err="tweak desconocido: $($A.id)" } }
                $r = Invoke-AXEBrokerRevertOne $tw
                if(-not $r.ok){ return @{ ok=$false; data=$null; err=$r.err } }
                @{ ok=$true; data=@{ id=$r.id; applied=$r.applied; reboot=$r.reboot }; err=$null }
            }
            'tweaks.applyBatch' {
                $ids = Test-AXEBrokerIds $A.ids
                if($ids -is [string]){ return @{ ok=$false; data=$null; err=$ids } }
                if(-not (Initialize-AXEBrokerHW)){ return @{ ok=$false; data=$null; err='no pude detectar el hardware: no aplico a ciegas' } }
                # Checkpoint del sistema ANTES del lote, dentro del mismo UAC. Best-effort: si falla
                # (SR desactivado, anticheat, limite de 24 h) el lote sigue con snapshots + .reg.
                $rp = New-AXERestorePoint 'AXE: antes de Optimizar en un clic'
                # Orden del CATALOGO, no el recibido: determinista.
                $res = @($script:CAT | Where-Object { $ids -ccontains [string]$_.Id } | ForEach-Object { Invoke-AXEBrokerApplyOne $_ })
                @{ ok=$true; data=@{ results=$res; restorePoint=@{ status=[string]$rp.Status; message=[string]$rp.Message } }; err=$null }
            }
            'tweaks.revertBatch' {
                $ids = Test-AXEBrokerIds $A.ids
                if($ids -is [string]){ return @{ ok=$false; data=$null; err=$ids } }
                $res = @($script:CAT | Where-Object { $ids -ccontains [string]$_.Id } | ForEach-Object { Invoke-AXEBrokerRevertOne $_ })
                @{ ok=$true; data=@{ results=$res }; err=$null }
            }
            'tweaks.masterRevert' {
                $done = 0; $err = 0
                foreach($tw in $script:CAT){
                    try {
                        if(Get-BlockReason $tw){ continue }
                        if(-not (Test-TweakSafe $tw)){ continue }
                        if(-not ((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){ & $tw.Revert }
                        $done++
                    } catch { $err++; Write-AXELog "Broker MasterRevert: $($tw.Name): $($_.Exception.Message)" 'ERR' }
                }
                # La cola (autoruns desactivados + residuos v1: SmartScreen, login MS, hypervisor)
                # se perdio al portar esto desde el bridge; 'reverted' es el campo que lee la UI.
                try { Invoke-AXEMasterRevertTail } catch { Write-AXELog "Broker MasterRevertTail: $($_.Exception.Message)" 'ERR' }
                @{ ok=$true; data=@{ reverted=$done; errors=$err }; err=$null }
            }
            'safety.restorePoint' {
                $r = New-AXERestorePoint
                @{ ok=$true; data=@{ status=[string]$r.Status; message=[string]$r.Message }; err=$null }
            }
            'fps.capture' {
                # Texto libre del front que acaba en la linea de comandos de PresentMon COMO ADMIN:
                # solo letras/digitos/._- y espacio, empezando por letra o digito (nada de comillas,
                # ';' ni un '-' inicial que PresentMon leeria como flag). Espacio si: "League of
                # Legends"; 33-fps lo entrecomilla, y sin comillas no hay forma de cerrar el argumento.
                $name = [string]$A.process
                if($name -notmatch '^[\p{L}\p{Nd}][\p{L}\p{Nd}._ -]{0,63}$' -or $name -match ' -'){
                    return @{ ok=$false; data=$null; err='nombre de proceso invalido' }
                }
                $secs = 20; if($A.seconds){ $secs = [int]$A.seconds }
                if($secs -lt 3){ $secs = 3 }; if($secs -gt 120){ $secs = 120 }
                $s = Measure-AXEFps -ProcessName $name -Seconds $secs
                @{ ok=$true; data=@{ ok=[bool]$s.Ok; lines=@(Format-AXEFpsStats $s 'Captura') }; err=$null }
            }
            default { @{ ok=$false; data=$null; err="cmd desconocido: $Cmd" } }
        }
    } catch {
        Write-AXELog "Broker: $Cmd lanzo: $($_.Exception.Message)" 'ERR'
        @{ ok=$false; data=$null; err=$_.Exception.Message }
    }
}

if(-not ('AXE.PipeNative' -as [type])){
    Add-Type -Namespace AXE -Name PipeNative -MemberDefinition '[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle Pipe, out uint ClientProcessId);'
}
function Test-AXEBrokerClientPid([int]$Actual, [int]$Expected){
    # PURA. El cliente del pipe tiene que ser EXACTAMENTE el proceso de la UI que lanzo este broker
    # (su PID llega por la linea de comandos del proceso elevado, que un proceso sin elevar no puede
    # tocar). Sin PID esperado se rechaza: falla cerrado. Antes solo se miraba que el cliente se
    # llamara 'powershell', y cualquier proceso del mismo usuario podia leer el token de
    # %LOCALAPPDATA% y ganar la carrera al pipe lanzando un powershell.exe propio.
    $Expected -gt 0 -and $Actual -eq $Expected
}

function Get-AXEBrokerClientPid($ServerStream){
    # PID del proceso conectado al pipe, o 0 si Windows no lo da.
    try {
        [uint32]$procId = 0
        if(-not [AXE.PipeNative]::GetNamedPipeClientProcessId($ServerStream.SafePipeHandle, [ref]$procId)){ return 0 }
        [int]$procId
    } catch { 0 }
}

function Start-AXEBroker([string]$PipeName, [string]$TokenPath, [int]$ClientPid){
    # Servidor de UNA peticion: crea el pipe, la procesa (o rechaza), responde, sale. Nunca queda
    # residente (issue #5: "no persistent service or scheduled task").
    $token = $null
    try { if(Test-Path $TokenPath){ $token = (Get-Content -LiteralPath $TokenPath -Raw).Trim() } } catch {}
    try { Remove-Item -LiteralPath $TokenPath -Force -EA SilentlyContinue } catch {}
    if(-not $token){ Write-AXELog 'Broker: sin token de arranque, salgo.' 'ERR'; return 1 }

    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object System.IO.Pipes.PipeAccessRule($sid, [System.IO.Pipes.PipeAccessRights]::ReadWrite, [System.Security.AccessControl.AccessControlType]::Allow)
    $sec = New-Object System.IO.Pipes.PipeSecurity
    $sec.AddAccessRule($rule)

    $server = $null
    try {
        $server = New-Object System.IO.Pipes.NamedPipeServerStream($PipeName, [System.IO.Pipes.PipeDirection]::InOut, 1, [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::None, 0, 0, $sec)
        $connectTask = $server.WaitForConnectionAsync()
        if(-not $connectTask.Wait(10000)){ Write-AXELog 'Broker: nadie conecto en 10s, salgo.' 'WARN'; return 1 }

        $actualPid = Get-AXEBrokerClientPid $server
        if(-not (Test-AXEBrokerClientPid $actualPid $ClientPid)){
            Write-AXELog "Broker: cliente no autorizado (PID $actualPid, esperado $ClientPid), cierro." 'WARN'; return 1
        }

        $json = Read-AXEBrokerFrame $server
        if(-not $json){ Write-AXELog 'Broker: conexion sin mensaje, salgo.' 'WARN'; return 1 }
        $req = Read-AXEBrokerRequest $json $token
        if(-not $req.Ok){
            Write-AXELog "Broker: peticion rechazada ($($req.Reason))." 'WARN'
            Write-AXEBrokerFrame $server (@{ ok=$false; data=$null; err='peticion invalida' } | ConvertTo-Json -Compress)
            return 1
        }
        if(-not (Test-Admin)){
            Write-AXELog 'Broker: no elevado, no puedo ejecutar nada privilegiado.' 'ERR'
            Write-AXEBrokerFrame $server (@{ ok=$false; data=$null; err='el broker no esta elevado' } | ConvertTo-Json -Compress)
            return 1
        }

        $res = Invoke-AXEBrokerCommand $req.Cmd $req.Args
        Write-AXELog "Broker: $($req.Cmd) -> ok=$($res.ok)"
        Write-AXEBrokerFrame $server ($res | ConvertTo-Json -Compress -Depth 5)
        0
    } catch {
        Write-AXELog "Broker: excepcion $($_.Exception.Message)" 'ERR'
        try { if($server -and $server.IsConnected){ Write-AXEBrokerFrame $server (@{ ok=$false; data=$null; err='fallo interno' } | ConvertTo-Json -Compress) } } catch {}
        1
    } finally {
        if($server){ try { $server.Disconnect() } catch {}; try { $server.Dispose() } catch {} }
    }
}

function New-AXEBrokerToken([string]$Dir){
    # Secreto de un solo uso: la UI lo escribe, el broker lo lee UNA vez y lo borra. Defensa en
    # profundidad redundante con el nombre de pipe ya aleatorio -- barata, se incluye igual.
    if(-not (Test-Path $Dir)){ New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $tok = [guid]::NewGuid().ToString('N')
    $path = Join-Path $Dir ("$([guid]::NewGuid().ToString('N')).token")
    Set-Content -LiteralPath $path -Value $tok -Encoding ASCII -NoNewline
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl $path
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
    Set-Acl $path $acl
    @{ Path = $path; Token = $tok }
}

function Send-AXEBrokerRequest([string]$PipeName, [string]$Cmd, [hashtable]$A, [string]$Token, [int]$ConnectTimeoutMs = 20000){
    # Cliente: conecta a un pipe YA SERVIDO (por Start-AXEBroker o, en tests, por un servidor de
    # pruebas), manda la peticion framed, espera la respuesta. Nunca lanza: cualquier fallo de
    # conexion/transporte se repackea como {ok=false}.
    try {
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
        try {
            $client.Connect($ConnectTimeoutMs)
            $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $req = @{ cmd = $Cmd; args = $A; token = $Token; ts = $ts } | ConvertTo-Json -Compress -Depth 5
            Write-AXEBrokerFrame $client $req
            # Respuesta: un lote con punto de restauracion tarda minutos; 20 min acota un broker colgado
            # (la ventana ya desiste a los 10) sin cortar una operacion larga legitima.
            $json = Read-AXEBrokerFrame $client 1200000
            if(-not $json){ return [pscustomobject]@{ ok=$false; data=$null; err='el broker cerro sin responder' } }
            $r = $json | ConvertFrom-Json
            [pscustomobject]@{ ok=[bool]$r.ok; data=$r.data; err=$r.err }
        } finally { $client.Dispose() }
    } catch {
        [pscustomobject]@{ ok=$false; data=$null; err="no se pudo hablar con el broker: $($_.Exception.Message)" }
    }
}

function Invoke-AXEPrivileged([string]$Cmd, [hashtable]$A, [string]$DistPath = $PSCommandPath){
    # Orquestacion completa del lado UI: token + pipe name aleatorios, lanza el broker elevado,
    # conecta, manda la peticion, repasa la respuesta. NO testeado automaticamente (Start-Process
    # -Verb RunAs dispararia un UAC real) -- las dos funciones de las que depende si lo estan.
    # $DistPath tiene default $PSCommandPath para que una llamada directa (misma thread/runspace
    # que carga el motor) siga resolviendo sola, como antes -- pero Invoke-AXEPrivilegedBackground
    # SIEMPRE lo pasa explicito: $PSCommandPath no cruza a un runspace nuevo vía AddScript (viene
    # vacio ahi dentro), asi que hay que capturarlo en el runspace de LLAMADA y pasarlo como dato.
    $dir = Join-Path $env:LOCALAPPDATA 'AXE\broker'
    $t = New-AXEBrokerToken $dir
    $pipeName = "AXE-Broker-$([guid]::NewGuid().ToString('N'))"
    $distPath = $DistPath
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','RemoteSigned','-File',"`"$distPath`"",'-Broker',$pipeName,'-Token',"`"$($t.Path)`"",'-ClientPid',"$PID") -Verb RunAs -WindowStyle Hidden | Out-Null
    } catch {
        try { Remove-Item -LiteralPath $t.Path -Force -EA SilentlyContinue } catch {}
        if($_.Exception -is [System.ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223){
            return [pscustomobject]@{ ok=$false; data=$null; err='operacion cancelada (UAC)' }
        }
        return [pscustomobject]@{ ok=$false; data=$null; err="no se pudo lanzar el broker: $($_.Exception.Message)" }
    }
    $res = Send-AXEBrokerRequest $pipeName $Cmd $A $t.Token
    try { Remove-Item -LiteralPath $t.Path -Force -EA SilentlyContinue } catch {}
    $res
}

function Invoke-AXEPrivilegedBackground([string]$Cmd, [hashtable]$A){
    # Arranca Invoke-AXEPrivileged en un runspace MTA aparte SIN bloquear el hilo llamante.
    # Devuelve @{Runspace;PS;Handle} para que quien llama sondee Handle.IsCompleted a su ritmo
    # (un DispatcherTimer de UI en produccion -- Start-AXEPrivilegedCommand, mas abajo -- o un
    # bucle simple en tests). Las 5 funciones del cliente del broker son autonomas (no dependen
    # de Write-AXELog ni de $script:CAT), asi que se inyectan por TEXTO leyendo la funcion
    # ACTUALMENTE definida en este runspace (Get-Item function:) -- lo que permite a los tests
    # sustituir Invoke-AXEPrivileged por un doble ANTES de llamar, sin tocar produccion. Nunca se
    # dot-sourcea el motor entero aqui: eso llegaria al fallthrough de 49-webmain.ps1 y abriria
    # OTRA ventana WebView2 desde el runspace de fondo.
    # $PSCommandPath se lee AQUI, en el runspace de LLAMADA (donde SI resuelve al .ps1 real) --
    # nunca dentro del runspace de fondo via AddScript, donde viene vacio (variable automatica,
    # no cruza) y dejaria a Invoke-AXEPrivileged relanzando powershell.exe con -File "" (issue
    # detectado en revision de Task 8: el broker nunca abria el pipe, Send-AXEBrokerRequest
    # timeaba a los 20s tras un UAC ya disparado en vano).
    $distPath = $PSCommandPath
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    $fnNames = 'New-AXEBrokerToken','Write-AXEBrokerFrame','Read-AXEBrokerFrame','Send-AXEBrokerRequest','Invoke-AXEPrivileged'
    $fnSrc = ($fnNames | ForEach-Object { "function $_ { $((Get-Item "function:$_").ScriptBlock) }" }) -join "`n"
    # Las funciones viajan como TEXTO pero las variables $script: que leen no: sin esta linea
    # $script:AXEBrokerMaxBytes llegaba vacio y Write-AXEBrokerFrame rechazaba TODO mensaje
    # ("demasiado grande (109 bytes, maximo )"). Todo apply/revert/restorePoint/fps de la GUI
    # fallaba; lo destapo el smoke E2E con el broker real (scripts\Invoke-AXEUiSmoke.ps1 -WriteFlows).
    [void]$ps.AddScript("`$script:AXEBrokerMaxBytes = $([int]$script:AXEBrokerMaxBytes)`n$fnSrc`nInvoke-AXEPrivileged `$args[0] `$args[1] `$args[2]")
    [void]$ps.AddArgument($Cmd)
    [void]$ps.AddArgument($A)
    [void]$ps.AddArgument($distPath)
    @{ Runspace = $rs; PS = $ps; Handle = $ps.BeginInvoke() }
}

function Receive-AXEPrivilegedBackground($Bg){
    # Recoge el resultado UNA VEZ que Handle.IsCompleted es true. Cierra el runspace. Nunca
    # lanza: una excepcion dentro del runspace se repackea como {ok=false}.
    $result = $null; $exn = $null
    try { $result = $Bg.PS.EndInvoke($Bg.Handle) } catch { $exn = $_ }
    try { $Bg.Runspace.Close() } catch {}
    try { $Bg.PS.Dispose() } catch {}
    if($exn){ return [pscustomobject]@{ ok=$false; data=$null; err=$exn.Exception.Message } }
    [pscustomobject]$result[0]
}

function Start-AXEPrivilegedCommand([string]$Cmd, [hashtable]$A, [scriptblock]$OnDone){
    # Envoltorio WPF: sondea Handle.IsCompleted con un DispatcherTimer -- mismo patron que ya usa
    # $script:TelemetryTimer en 48-webbridge.ps1 para la telemetria -- y llama a $OnDone en el
    # hilo de UI cuando termina. NO testeado por Pester (exige un Dispatcher STA vivo, que un
    # test sin ventana no tiene): verificado por el harness de build.ps1 (AXE_WEBUI_TEST=1) +
    # comprobacion manual antes de release. Las dos funciones de las que depende (arriba) si lo
    # estan por completo.
    Wait-AXEBackground (Invoke-AXEPrivilegedBackground $Cmd $A) $OnDone
}

function Wait-AXEBackground($Bg, [scriptblock]$OnDone){
    # Sondea un @{Runspace;PS;Handle} de fondo desde el hilo de UI y llama a $OnDone con el
    # resultado cuando termina. Compartido por el broker y por los comandos lentos del puente
    # (Invoke-AXEBridgeBackground, 48-webbridge).
    $bg = $Bg
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({
        if(-not $bg.Handle.IsCompleted){ return }
        $timer.Stop()
        & $OnDone (Receive-AXEPrivilegedBackground $bg)
    }.GetNewClosure())
    $timer.Start()
}
