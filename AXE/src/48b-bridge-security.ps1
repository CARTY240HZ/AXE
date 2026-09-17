# =====================================================
# REGION 14c - RPC SECURITY HARDENING
#
# Defense-in-depth around the existing closed RPC map in 48-webbridge.ps1.
# The original dispatcher remains the single business-logic path; this wrapper
# only validates trust boundary inputs before handing them to it.
#
# GUI-only long-running reads (timer sweep) are also dispatched asynchronously
# so the WebView2/WPF UI thread never blocks on a multi-second measurement.
# =====================================================

$script:AXEBridgeOriginal = $null
$script:AXETimerSweepState = $null
$script:AXETimerSweepTimer = $null
try {
    if(Get-Command Invoke-AXEBridgeCmd -CommandType Function -EA SilentlyContinue){
        $script:AXEBridgeOriginal = ${function:Invoke-AXEBridgeCmd}
    }
} catch {}

function Test-AXEBridgeOriginTrusted {
    try {
        $src = if($script:Web -and $script:Web.Source){ [Uri]$script:Web.Source } else { $null }
        if(-not $src){ return $false }
        if($src.Scheme -ne 'https'){ return $false }
        if($src.Host -ne 'axe.local'){ return $false }
        if($src.Port -ne -1 -and $src.Port -ne 443){ return $false }
        return $true
    } catch {
        return $false
    }
}

function Complete-AXETimerSweepAsync {
    $st = $script:AXETimerSweepState
    if(-not $st -or -not $st.Process){ return }
    try {
        if(-not $st.Process.HasExited){ return }

        $exitCode = [int]$st.Process.ExitCode
        $raw = ''
        $errRaw = ''
        try { if(Test-Path -LiteralPath $st.OutFile){ $raw = Get-Content -LiteralPath $st.OutFile -Raw -EA SilentlyContinue } } catch {}
        try { if(Test-Path -LiteralPath $st.ErrFile){ $errRaw = Get-Content -LiteralPath $st.ErrFile -Raw -EA SilentlyContinue } } catch {}

        if($exitCode -eq 0){
            $lines = @($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $res = [pscustomobject]@{
                ok   = $true
                data = [pscustomobject]@{
                    lines      = $lines
                    conclusive = $null
                    bestMs     = $null
                    originalMs = $null
                }
                err = ''
            }
        } else {
            $why = ([string]$errRaw).Trim()
            if([string]::IsNullOrWhiteSpace($why)){ $why = "el barrido termino con codigo $exitCode" }
            $res = [pscustomobject]@{ ok=$false; data=$null; err=$why }
        }

        if($script:Web -and $script:Web.CoreWebView2){
            $json = ($res | ConvertTo-Json -Depth 8 -Compress)
            $js = 'window.__axeReply(' + [int]$st.RequestId + ', ' + ($json | ConvertTo-Json) + ')'
            [void]$script:Web.CoreWebView2.ExecuteScriptAsync($js)
        }
    } catch {
        try {
            if($script:Web -and $script:Web.CoreWebView2){
                $res = [pscustomobject]@{ ok=$false; data=$null; err="barrido: $($_.Exception.Message)" }
                $json = ($res | ConvertTo-Json -Depth 6 -Compress)
                $js = 'window.__axeReply(' + [int]$st.RequestId + ', ' + ($json | ConvertTo-Json) + ')'
                [void]$script:Web.CoreWebView2.ExecuteScriptAsync($js)
            }
        } catch {}
    } finally {
        try { if($script:AXETimerSweepTimer){ $script:AXETimerSweepTimer.Stop() } } catch {}
        try { $st.Process.Dispose() } catch {}
        try { if($st.TempDir -and (Test-Path -LiteralPath $st.TempDir)){ Remove-Item -LiteralPath $st.TempDir -Recurse -Force -EA SilentlyContinue } } catch {}
        $script:AXETimerSweepState = $null
    }
}

function Start-AXETimerSweepAsync {
    param([int]$RequestId)
    if($RequestId -le 0){ return [pscustomobject]@{ Ok=$false; Err='request id invalido' } }
    if($script:AXETimerSweepState){ return [pscustomobject]@{ Ok=$false; Err='barrido ya en curso' } }
    if(-not $script:AXERoot){ return [pscustomobject]@{ Ok=$false; Err='ruta de AXE no disponible' } }
    if(-not ($script:Web -and $script:Web.CoreWebView2)){ return [pscustomobject]@{ Ok=$false; Err='WebView2 no inicializado' } }

    # En un build normal AXERoot = ...\AXE\dist y AXE.ps1 es el entrypoint consolidado.
    $scriptPath = Join-Path $script:AXERoot 'AXE.ps1'
    if(-not (Test-Path -LiteralPath $scriptPath)){
        return [pscustomobject]@{ Ok=$false; Err='entrypoint dist/AXE.ps1 no encontrado' }
    }

    $dir = Join-Path ([IO.Path]::GetTempPath()) ('axe-timersweep-' + [guid]::NewGuid().ToString('N'))
    $outFile = Join-Path $dir 'stdout.txt'
    $errFile = Join-Path $dir 'stderr.txt'
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if(-not (Test-Path -LiteralPath $psExe)){ throw 'powershell.exe no disponible' }

        $argList = @('-NoProfile','-NonInteractive')
        # Mantener, cuando exista, la politica de proceso con la que se lanzo AXE. Si no existe,
        # se deja que powershell.exe use la politica efectiva del usuario/equipo.
        if($env:PSExecutionPolicyPreference){ $argList += @('-ExecutionPolicy',[string]$env:PSExecutionPolicyPreference) }
        $argList += @('-File',$scriptPath,'-TimerSweep')

        $proc = Start-Process -FilePath $psExe -ArgumentList $argList -WorkingDirectory $script:AXERoot `
            -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile -PassThru -ErrorAction Stop

        $script:AXETimerSweepState = [pscustomobject]@{
            RequestId = $RequestId
            Process   = $proc
            OutFile   = $outFile
            ErrFile   = $errFile
            TempDir   = $dir
        }

        if(-not $script:AXETimerSweepTimer){
            $script:AXETimerSweepTimer = New-Object System.Windows.Threading.DispatcherTimer
            $script:AXETimerSweepTimer.Interval = [TimeSpan]::FromMilliseconds(250)
            $script:AXETimerSweepTimer.Add_Tick({ Complete-AXETimerSweepAsync })
        }
        $script:AXETimerSweepTimer.Start()
        [pscustomobject]@{ Ok=$true; Err='' }
    } catch {
        try { if(Test-Path -LiteralPath $dir){ Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue } } catch {}
        [pscustomobject]@{ Ok=$false; Err=$_.Exception.Message }
    }
}

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

    if(-not (Test-AXEBridgeOriginTrusted)){
        return [pscustomobject]@{ ok=$false; data=$null; err='origen web no confiable' }
    }

    # measure.timerSweep es la unica lectura GUI con identificador interno de correlacion.
    # Se procesa ANTES del validador generico porque `_axeRid` es un nombre interno deliberado
    # que empieza por '_' y por eso no puede entrar en la gramática normal de propiedades JS.
    # Solo se permite ese campo, entero positivo, y se elimina antes de cualquier dispatcher.
    if($cmd -eq 'measure.timerSweep' -and $null -ne $cmdArgs -and $cmdArgs.ContainsKey('_axeRid')){
        if($cmdArgs.Count -ne 1){
            return [pscustomobject]@{ ok=$false; data=$null; err='args invalidos' }
        }
        $ridRaw = $cmdArgs['_axeRid']
        $rid = 0
        try { $rid = [int]$ridRaw } catch { return [pscustomobject]@{ ok=$false; data=$null; err='request id invalido' } }
        if($rid -le 0){ return [pscustomobject]@{ ok=$false; data=$null; err='request id invalido' } }
        $start = Start-AXETimerSweepAsync -RequestId $rid
        if($start.Ok){ return [pscustomobject]@{ ok=$true; async=$true; data=$null; err='' } }
        return [pscustomobject]@{ ok=$false; data=$null; err=[string]$start.Err }
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
