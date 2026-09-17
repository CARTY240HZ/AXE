# =====================================================
# REGION 13c - PRIVILEGED BROKER (least-privilege boundary)
# =====================================================
# GUI/WebView2 stays unelevated. Privileged operations cross a one-shot named-pipe broker.
# The broker is deliberately NOT a generic PowerShell shell: closed command allow-list,
# strict JSON limits, per-request nonce, current-user ACL and independent validation.
#
# The broker process starts with Windows PowerShell -ExecutionPolicy AllSigned. Before UAC is
# requested the client checks that the consolidated AXE.ps1 is Authenticode-valid; AllSigned
# then performs the execution-time signature check again, closing the verify/launch gap for a
# file that lives in a user-writable portable/install location.

$script:AXEBrokerPipePrefix = 'AXE-Broker-'
$script:AXEBrokerMaxJsonBytes = 32768
$script:AXEBrokerMaxCommandLength = 64
$script:AXEBrokerMaxIdLength = 64
$script:AXEBrokerAllowed = @{
    'tweaks.apply'        = $true
    'tweaks.revert'       = $true
    'tweaks.masterRevert' = $true
    'fps.capture'         = $true
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
        return ($sig.Status -eq 'Valid' -and $null -ne $sig.SignerCertificate)
    } catch { return $false }
}

function Test-AXEBrokerPayload {
    param([Parameter(Mandatory)][object]$Payload,[Parameter(Mandatory)][string]$ExpectedNonce)
    if($null -eq $Payload){ throw 'broker: payload vacio' }
    $json = $Payload | ConvertTo-Json -Compress -Depth 8
    if([Text.Encoding]::UTF8.GetByteCount($json) -gt $script:AXEBrokerMaxJsonBytes){ throw 'broker: payload demasiado grande' }
    $p = $Payload.PSObject
    if(-not $p.Properties['v'] -or [int]$Payload.v -ne 1){ throw 'broker: version invalida' }
    if(-not $p.Properties['nonce'] -or [string]$Payload.nonce -cne $ExpectedNonce){ throw 'broker: nonce invalido' }
    if(-not $p.Properties['id'] -or [string]::IsNullOrWhiteSpace([string]$Payload.id) -or [string]$Payload.id.Length -gt $script:AXEBrokerMaxIdLength){ throw 'broker: id invalido' }
    if(-not $p.Properties['cmd']){ throw 'broker: cmd ausente' }
    $cmd = [string]$Payload.cmd
    if($cmd.Length -gt $script:AXEBrokerMaxCommandLength -or -not $script:AXEBrokerAllowed.ContainsKey($cmd)){ throw 'broker: cmd no permitido' }
    if($p.Properties['args'] -and $null -ne $Payload.args){
        $a = $Payload.args
        if(@($a.PSObject.Properties).Count -gt 16){ throw 'broker: demasiados argumentos' }
        foreach($prop in @($a.PSObject.Properties)){
            if($prop.Name.Length -gt 64){ throw 'broker: nombre de argumento demasiado largo' }
            if(([string]$prop.Value).Length -gt 4096){ throw 'broker: valor de argumento demasiado largo' }
        }
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

        $escapedScript = $scriptPath.Replace("'", "''")
        $escapedPipe = $pipeName.Replace("'", "''")
        $escapedNonce = ([string]$request.nonce).Replace("'", "''")
        # UAC is initiated by trusted native PowerShell code, never by WebView2/JS.
        $argsLine = @('-NoProfile','-NonInteractive','-ExecutionPolicy','AllSigned','-STA','-File',"$scriptPath",'-BrokerServer','-BrokerPipeName',$pipeName,'-BrokerNonce',$request.nonce)
        $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -ArgumentList $argsLine -PassThru -WindowStyle Hidden -ErrorAction Stop
        $server.WaitForConnection()

        $reader = New-Object IO.StreamReader($server,[Text.Encoding]::UTF8,$false,4096,$true)
        $line = $reader.ReadLine()
        if([string]::IsNullOrWhiteSpace($line)){ throw 'broker: respuesta vacia' }
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
        $pipe = New-Object System.IO.Pipes.NamedPipeServerStream(
            $PipeName,[System.IO.Pipes.PipeDirection]::InOut,1,[System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::Asynchronous,32768,32768)
        $pipe.WaitForConnection()
        $reader = New-Object IO.StreamReader($pipe,[Text.Encoding]::UTF8,$false,4096,$true)
        $writer = New-Object IO.StreamWriter($pipe,[Text.Encoding]::UTF8,4096,$true)
        $writer.AutoFlush = $true
        $line = $reader.ReadLine()
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
            'fps.capture' {
                $proc=[string]$payload.args.process
                if([string]::IsNullOrWhiteSpace($proc) -or $proc.Length -gt 128){throw 'broker: proceso invalido'}
                if($proc -notmatch '^[A-Za-z0-9._-]+$'){throw 'broker: nombre de proceso invalido'}
                $secs=20;if($payload.args.seconds){$secs=[int]$payload.args.seconds};if($secs -lt 3){$secs=3};if($secs -gt 120){$secs=120}
                $s=Measure-AXEFps -ProcessName $proc -Seconds $secs
                $result=[pscustomobject]@{ok=$true;data=[pscustomobject]@{ok=[bool]$s.Ok;lines=@(Format-AXEFpsStats $s 'Captura')};error=$null}
            }
            default { throw 'broker: cmd no permitido' }
        }
    } catch {
        $result=[pscustomobject]@{ok=$false;data=$null;error=$_.Exception.Message}
    } finally {
        if($pipe){ try{$writer.WriteLine(($result|ConvertTo-Json -Compress -Depth 8));$writer.Flush()}catch{};try{$pipe.Dispose()}catch{} }
    }
    $result
}
