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
