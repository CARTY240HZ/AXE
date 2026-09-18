# =====================================================
# REGION 13c - PRIVILEGED BROKER (least-privilege boundary)
# =====================================================
# GUI/WebView2 stays unelevated. Privileged operations cross a one-shot named-pipe broker.
# The broker is deliberately NOT a generic PowerShell shell: closed command allow-list,
# strict JSON limits, per-request nonce, current-user ACL and independent validation.
#
# Protocol:
#   UI process creates an ACL-restricted server pipe.
#   UI launches one elevated AXE process with -BrokerServer + pipe name + nonce.
#   Elevated child connects as the pipe CLIENT, receives exactly one request, executes it,
#   writes exactly one response, and exits.
#   Before sending the request, UI checks the connected pipe client PID against the exact
#   process object returned by Start-Process. This prevents a different same-user process
#   from racing the broker connection even if it can discover the pipe name/nonce.
#
# The broker process starts with Windows PowerShell -ExecutionPolicy AllSigned. Before UAC is
# requested the client checks that the consolidated AXE.ps1 is Authenticode-valid; AllSigned
# performs the execution-time policy check again.

$script:AXEBrokerPipePrefix = 'AXE-Broker-'
$script:AXEBrokerMaxJsonBytes = 32768
$script:AXEBrokerMaxCommandLength = 64
$script:AXEBrokerMaxIdLength = 64
$script:AXEBrokerAllowed = @{
    'tweaks.apply'        = $true
    'tweaks.revert'       = $true
    'tweaks.masterRevert' = $true
}
# Pilot release: the workflow replaces this placeholder in dist/AXE.ps1 with the exact
# certificate thumbprint used to sign that package. The signature remains mandatory.
$script:AXEPilotSignerThumbprint = '__AXE_PILOT_SIGNER_THUMBPRINT__'

if(-not ('AXEBrokerNative' -as [type])){
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AXEBrokerNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetNamedPipeClientProcessId(IntPtr pipe, out uint clientProcessId);
}
'@
}

function Get-AXECurrentUserSid {
    try { [string]([Security.Principal.WindowsIdentity]::GetCurrent().User.Value) }
    catch { $null }
}

function Test-AXEBrokerSignature {
    param([Parameter(Mandatory)][string]$ScriptPath)
    try {
        if(-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)){ return $false }
        $sig = Get-AuthenticodeSignature -LiteralPath $ScriptPath
        if($null -eq $sig.SignerCertificate){ return $false }

        # In the normal/public build the OS trust result must be Valid.
        # In the pilot build the self-signed certificate is pinned by thumbprint, so Windows
        # may report NotTrusted on a clean PC even though the signature itself is valid.
        if($sig.Status -notin @('Valid','NotTrusted')){ return $false }

        $cert = $sig.SignerCertificate
        $now = Get-Date
        if($cert.NotBefore -gt $now -or $cert.NotAfter -lt $now){ return $false }

        $pin = [string]$script:AXEPilotSignerThumbprint
        if([string]::IsNullOrWhiteSpace($pin) -or $pin -eq '__AXE_PILOT_SIGNER_THUMBPRINT__'){
            return ($sig.Status -eq 'Valid')
        }
        return [string]::Equals($cert.Thumbprint.Replace(' ',''),$pin.Replace(' ',''),[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-AXEBrokerClientProcessId {
    param([Parameter(Mandatory)][System.IO.Pipes.NamedPipeServerStream]$Pipe)
    [uint32]$clientPid = 0
    $handle = $Pipe.SafePipeHandle.DangerousGetHandle()
    if(-not [AXEBrokerNative]::GetNamedPipeClientProcessId($handle,[ref]$clientPid)){
        throw 'broker: no pude identificar el PID del cliente del pipe'
    }
    if($clientPid -eq 0){ throw 'broker: PID de cliente invalido' }
    [int]$clientPid
}

function Test-AXEBrokerPayload {
    param([Parameter(Mandatory)][object]$Payload,[Parameter(Mandatory)][string]$ExpectedNonce)
    if($null -eq $Payload){ throw 'broker: payload vacio' }
    $json = $Payload | ConvertTo-Json -Compress -Depth 8
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:AXEBrokerMaxJsonBytes){ throw 'broker: payload demasiado grande' }
    $p = $Payload.PSObject
    if(-not $p.Properties['v'] -or [int]$Payload.v -ne 1){ throw 'broker: version invalida' }
    if(-not $p.Properties['nonce'] -or [string]$Payload.nonce -cne $ExpectedNonce){ throw 'broker: nonce invalido' }
    if(-not $p.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$Payload.id) -or [string]$Payload.id.Length -gt $script:AXEBrokerMaxIdLength -or [string]$Payload.id -notmatch '^[A-Za-z0-9_.-]+$'){ throw 'broker: id invalido' }
    if(-not $p.Properties['cmd']){ throw 'broker: cmd ausente' }
    $cmd = [string]$Payload.cmd
    if($cmd.Length -gt $script:AXEBrokerMaxCommandLength -or -not $script:AXEBrokerAllowed.ContainsKey($cmd)){ throw 'broker: cmd no permitido' }
    if(-not $p.Properties['args'] -or $null -eq $Payload.args){ throw 'broker: args ausentes' }
    $a = $Payload.args
    $props = @($a.PSObject.Properties)
    if($props.Count -gt 4){ throw 'broker: demasiados argumentos' }
    foreach($prop in $props){
        if($prop.Name.Length -gt 64 -or $prop.Name -notmatch '^[A-Za-z][A-Za-z0-9_.-]*$'){ throw 'broker: nombre de argumento invalido' }
        if(([string]$prop.Value).Length -gt 4096){ throw 'broker: valor de argumento demasiado largo' }
    }
    switch($cmd){
        'tweaks.apply' { if(@($props.Name) -notcontains 'id' -or @($props.Name).Count -ne 1){ throw 'broker: forma invalida para tweaks.apply' } }
        'tweaks.revert' { if(@($props.Name) -notcontains 'id' -or @($props.Name).Count -ne 1){ throw 'broker: forma invalida para tweaks.revert' } }
        'tweaks.masterRevert' { if(@($props.Name).Count -ne 0){ throw 'broker: forma invalida para tweaks.masterRevert' } }
    }
    $Payload
}

function New-AXEBrokerRequest {
    param([Parameter(Mandatory)][string]$Command,[object]$Args = [pscustomobject]@{})
    if(-not $script:AXEBrokerAllowed.ContainsKey($Command)){ throw "broker: '$Command' no permitido" }
    [pscustomobject]@{
        v=1
        id=([guid]::NewGuid().ToString('N'))
        nonce=([guid]::NewGuid().ToString('N'))
        cmd=$Command
        args=$Args
    }
}

function Invoke-AXEPrivilegedBroker {
    param([Parameter(Mandatory)][string]$Command,[object]$Args = [pscustomobject]@{})
    if(Test-Admin){ throw 'broker: el host GUI no deberia ejecutar operaciones privilegiadas directamente' }
    if($Command -notin @('tweaks.apply','tweaks.revert','tweaks.masterRevert')){ throw 'broker: operacion no privilegiada rechazada' }
    $scriptPath = $PSCommandPath
    if(-not (Test-AXEBrokerSignature -ScriptPath $scriptPath)){
        throw 'AXE no tiene firma Authenticode valida; no se solicita elevacion automatica.'
    }
    $request = New-AXEBrokerRequest -Command $Command -Args $Args
    $pipeName = $script:AXEBrokerPipePrefix + ([guid]::NewGuid().ToString('N'))
    $currentSid = Get-AXECurrentUserSid
    if(-not $currentSid){ throw 'broker: no pude determinar el usuario actual' }

    $server = $null
    try {
        $pipeSecurity = New-Object System.IO.Pipes.PipeSecurity
        $sid = New-Object System.Security.Principal.SecurityIdentifier($currentSid)
        $rule = New-Object System.IO.Pipes.PipeAccessRule($sid,[System.IO.Pipes.PipeAccessRights]::ReadWrite,[System.Security.AccessControl.AccessControlType]::Allow)
        $pipeSecurity.AddAccessRule($rule)
        $server = New-Object System.IO.Pipes.NamedPipeServerStream(
            $pipeName,[System.IO.Pipes.PipeDirection]::InOut,1,[System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::Asynchronous,32768,32768,$pipeSecurity)

        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if(-not (Test-Path -LiteralPath $psExe -PathType Leaf)){ throw 'broker: powershell.exe no disponible' }
        $quotedScript = '"' + $scriptPath.Replace('"','\"') + '"'
        $argLine = '-NoProfile -NonInteractive -ExecutionPolicy AllSigned -STA -File ' + $quotedScript +
            ' -BrokerServer -BrokerPipeName "' + $pipeName + '" -BrokerNonce "' + $request.nonce + '"'
        $brokerProcess = Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $argLine -PassThru -WindowStyle Hidden -ErrorAction Stop

        $waitTask = $server.WaitForConnectionAsync()
        if(-not $waitTask.Wait(15000)){ throw 'broker: timeout esperando el proceso elevado (UAC cancelado o broker no arranco)' }
        $clientPid = Get-AXEBrokerClientProcessId -Pipe $server
        if($clientPid -ne $brokerProcess.Id){ throw "broker: PID cliente inesperado ($clientPid != $($brokerProcess.Id))" }

        $writer = New-Object IO.StreamWriter($server,[Text.Encoding]::UTF8,4096,$true)
        $writer.AutoFlush = $true
        $reader = New-Object IO.StreamReader($server,[Text.Encoding]::UTF8,$false,4096,$true)
        $writer.WriteLine(($request | ConvertTo-Json -Compress -Depth 8))
        $readTask = $reader.ReadLineAsync()
        if(-not $readTask.Wait(15000)){ throw 'broker: timeout esperando respuesta' }
        $line = $readTask.Result
        if([string]::IsNullOrWhiteSpace($line)){ throw 'broker: respuesta vacia' }
        if([Text.Encoding]::UTF8.GetByteCount($line) -gt $script:AXEBrokerMaxJsonBytes){ throw 'broker: respuesta demasiado grande' }
        $reply = $line | ConvertFrom-Json -Depth 8
        if($reply.ok -ne $true){ throw ([string]$reply.error) }
        $reply.data
    } finally {
        if($server){ try { $server.Dispose() } catch {} }
    }
}

function Start-AXEBrokerServer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PipeName,[Parameter(Mandatory)][string]$ExpectedNonce)
    $result = [pscustomobject]@{ ok=$false; data=$null; error='broker: error desconocido' }
    $pipe = $null
    try {
        if(-not (Test-Admin)){ throw 'broker: el proceso no esta elevado' }
        if($PipeName -notmatch '^AXE-Broker-[0-9a-f]{32}$'){ throw 'broker: nombre de pipe invalido' }
        if($ExpectedNonce -notmatch '^[0-9a-f]{32}$'){ throw 'broker: nonce invalido' }
        $pipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut, [System.IO.Pipes.PipeOptions]::Asynchronous)
        $pipe.Connect(10000)
        $reader = New-Object IO.StreamReader($pipe,[Text.Encoding]::UTF8,$false,4096,$true)
        $writer = New-Object IO.StreamWriter($pipe,[Text.Encoding]::UTF8,4096,$true)
        $writer.AutoFlush = $true
        $readTask = $reader.ReadLineAsync()
        if(-not $readTask.Wait(10000)){ throw 'broker: timeout esperando request' }
        $line = $readTask.Result
        if([string]::IsNullOrWhiteSpace($line)){ throw 'broker: request vacia' }
        if([Text.Encoding]::UTF8.GetByteCount($line) -gt $script:AXEBrokerMaxJsonBytes){ throw 'broker: request demasiado grande' }
        $payload = $line | ConvertFrom-Json -Depth 8
        Test-AXEBrokerPayload -Payload $payload -ExpectedNonce $ExpectedNonce | Out-Null
        switch([string]$payload.cmd){
            'tweaks.apply' {
                $tw = $script:CAT | Where-Object Id -eq ([string]$payload.args.id) | Select-Object -First 1
                if(-not $tw){ throw 'broker: tweak desconocido' }
                $blk = Get-BlockReason $tw; if($blk){ throw "broker: tweak no aplicable: $blk" }
                if(Test-SnapEligible $tw){ $script:capTweak=$tw.Id }
                try { & $tw.Apply } finally { $script:capTweak=$null }
                $result=[pscustomobject]@{ok=$true;data=[pscustomobject]@{id=$tw.Id;applied=[bool](Test-TweakSafe $tw);reboot=[bool]$tw.Reboot};error=$null}
            }
            'tweaks.revert' {
                $tw = $script:CAT | Where-Object Id -eq ([string]$payload.args.id) | Select-Object -First 1
                if(-not $tw){ throw 'broker: tweak desconocido' }
                if(-not ((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){ & $tw.Revert }
                $result=[pscustomobject]@{ok=$true;data=[pscustomobject]@{id=$tw.Id;applied=[bool](Test-TweakSafe $tw);reboot=[bool]$tw.Reboot};error=$null}
            }
            'tweaks.masterRevert' {
                $done=0;$err=0
                foreach($tw in $script:CAT){
                    try { if(Get-BlockReason $tw){continue}; if(-not(Test-TweakSafe $tw)){continue}; if(-not((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){& $tw.Revert};$done++ }
                    catch{$err++;Write-AXELog "Broker MasterRevert: $($tw.Name): $($_.Exception.Message)" 'ERR'}
                }
                try{Invoke-AXEMasterRevertTail}catch{}
                $result=[pscustomobject]@{ok=$true;data=[pscustomobject]@{reverted=$done;errors=$err};error=$null}
            }
            default { throw 'broker: cmd no permitido' }
        }
    } catch { $result=[pscustomobject]@{ok=$false;data=$null;error=$_.Exception.Message} }
    finally {
        if($pipe){ try{$writer.WriteLine(($result|ConvertTo-Json -Compress -Depth 8));$writer.Flush()}catch{};try{$pipe.Dispose()}catch{} }
    }
    $result
}
