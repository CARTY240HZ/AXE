# =====================================================
# REGION 9c - OPTIMIZAR EN UN CLIC (spec 2026-09-24)
# =====================================================
# Que queda por aplicar, por tier, en ESTE equipo, y el registro de la ultima optimizacion (ids
# aplicados + id del benchmark 'antes') que sobrevive al reinicio. La orquestacion (medir, aplicar
# en lote por el broker, medir) la hace la UI con comandos existentes; aqui no se aplica nada.

function Get-AXEOneClickPending {
    # Una sola pasada por el catalogo; los tres perfiles salen de aqui (seguro=t0,
    # equilibrado=t0+t1, maximo=+t2). Ilegible sin admin (BCD) cuenta como pendiente: aplicar
    # es idempotente y no se puede saber si ya lo esta.
    param([object[]]$Catalog = $script:CAT)
    $out = @{ t0 = New-Object System.Collections.ArrayList; t1 = New-Object System.Collections.ArrayList; t2 = New-Object System.Collections.ArrayList }
    foreach($tw in @($Catalog)){
        if(-not $tw -or [int]$tw.Tier -notin 0,1,2){ continue }
        try { if(Get-BlockReason $tw){ continue } } catch { continue }
        if(-not (Test-AXETweakUnreadable $tw) -and (Test-TweakSafe $tw)){ continue }
        [void]$out["t$([int]$tw.Tier)"].Add([pscustomobject]@{ id=[string]$tw.Id; name=[string]$tw.Name; desc=[string]$tw.Desc; reboot=[bool]$tw.Reboot })
    }
    [pscustomobject]@{ t0=@($out.t0); t1=@($out.t1); t2=@($out.t2) }
}

function Get-AXEOneClickStatePath { Join-Path $script:AXEData 'oneclick_last.json' }

function Get-AXEBootStamp {
    # Arranque del SO en UTC (ISO 8601), o $null si CIM no responde. Con el se sabe si hubo reinicio
    # entre guardar una optimizacion que lo pedia y volver a abrir AXE.
    try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o') } catch { $null }
}

function Test-AXEOneClickRebooted {
    # PURA. $true si el reinicio que pedia la optimizacion YA ocurrio (o si no hacia falta). Sin
    # uno de los dos arranques no se puede saber: se da por hecho, como antes de guardar el dato,
    # para no dejar la medida del 'despues' bloqueada para siempre. Tolerancia de 60 s: el valor de
    # CIM se redondea distinto segun la lectura.
    param($State, [string]$NowBoot)
    if(-not $State -or -not $State.rebootNeeded){ return $true }
    # ConvertFrom-Json de pwsh ya entrega un DateTime; el de 5.1, el texto ISO. Se aceptan los dos.
    $toUtc = { param($v)
        if($v -is [DateTime]){ return $v.ToUniversalTime() }
        [DateTime]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    if($null -eq $State.bootTime -or [string]::IsNullOrWhiteSpace([string]$State.bootTime) -or [string]::IsNullOrWhiteSpace($NowBoot)){ return $true }
    try { [Math]::Abs(((& $toUtc $NowBoot) - (& $toUtc $State.bootTime)).TotalSeconds) -gt 60 } catch { $true }
}

function Save-AXEOneClickState($State){
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-AXEOneClickStatePath) -Encoding UTF8
}

function Read-AXEOneClickState {
    # $null = no hay optimizacion registrada; corrupt=$true = la habia pero no se puede leer (la UI
    # lo dice en vez de fingir que no paso nada).
    $p = Get-AXEOneClickStatePath
    if(-not (Test-Path -LiteralPath $p)){ return $null }
    try { Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json -EA Stop }
    catch { [pscustomobject]@{ corrupt=$true } }
}
