# =====================================================
# REGION 8d - REPORTE: delta antes/despues + export JSON (Trust & Proof)
# =====================================================
function Format-AXEMetric($v){ if($v -is [string]){ 'n/a' } else { "$v" } }

function Get-AXEDeltaTag {
    # Deadband anti-ruido: |delta| < max(0.1, 10% del previo) => "igual".
    # $better = 'down' si menor es mejor (timer/jitter). Devuelve mejora|igual|regresion.
    param([double]$before,[double]$after,[string]$better='down')
    $band=[math]::Max(0.1,[math]::Abs($before)*0.10)
    $d=$after-$before
    if([math]::Abs($d) -lt $band){ return 'igual' }
    if($better -eq 'down'){ if($d -lt 0){'mejora'}else{'regresion'} }
    else { if($d -gt 0){'mejora'}else{'regresion'} }
}

function New-AXEReport {
    # String multi-linea, runspace-safe. Campos n/a nunca calculan delta falso.
    param($snap0,$snap1,$scoreBefore,$scoreAfter)
    $L=New-Object System.Collections.ArrayList
    [void]$L.Add('=== AXE REPORTE (Trust & Proof) ===')
    # Timer
    if($snap0.Timer -is [string] -or $snap1.Timer -is [string]){
        [void]$L.Add(("Timer          : {0} -> {1}" -f (Format-AXEMetric $snap0.Timer),(Format-AXEMetric $snap1.Timer)))
    } else {
        $tag=Get-AXEDeltaTag ([double]$snap0.Timer.CurrentMs) ([double]$snap1.Timer.CurrentMs) 'down'
        [void]$L.Add(("Timer          : {0}ms -> {1}ms   ({2})" -f $snap0.Timer.CurrentMs,$snap1.Timer.CurrentMs,$tag))
    }
    # Jitter P99.9 (proxy)
    if($snap0.Jitter -is [string] -or $snap1.Jitter -is [string]){
        [void]$L.Add(("Jitter P99.9   : {0} -> {1}  (proxy)" -f (Format-AXEMetric $snap0.Jitter),(Format-AXEMetric $snap1.Jitter)))
    } else {
        $tag=Get-AXEDeltaTag ([double]$snap0.Jitter.P999Ms) ([double]$snap1.Jitter.P999Ms) 'down'
        [void]$L.Add(("Jitter P99.9   : {0}ms -> {1}ms   ({2}, proxy no por-driver)" -f $snap0.Jitter.P999Ms,$snap1.Jitter.P999Ms,$tag))
    }
    # Cobertura
    [void]$L.Add(("Cobertura T0/1 : {0}/{1} -> {2}/{3}" -f (Format-AXEMetric $snap0.TweaksOn),(Format-AXEMetric $snap0.TweaksApplicable),(Format-AXEMetric $snap1.TweaksOn),(Format-AXEMetric $snap1.TweaksApplicable)))
    # Score
    $delta=$scoreAfter.Total-$scoreBefore.Total
    $sign=if($delta -ge 0){"+$delta"}else{"$delta"}
    [void]$L.Add(("AXE Score      : {0} -> {1}   ({2})" -f $scoreBefore.Total,$scoreAfter.Total,$sign))
    [void]$L.Add('--- desglose (despues) ---')
    [void]$L.Add($scoreAfter.Breakdown)
    [void]$L.Add('Deadband: timer exacto; jitter |d|<max(0.1ms,10%) = igual.')
    ($L -join "`r`n")
}

function Export-AXEReport {
    param($snap0,$snap1,$file)
    $obj=[pscustomobject]@{
        timestamp   = (Get-Date).ToUniversalTime().ToString('u')
        snap0       = $snap0
        snap1       = $snap1
        scoreBefore = (Get-AXEScore $snap0)
        scoreAfter  = (Get-AXEScore $snap1 $snap0)
    }
    $obj | ConvertTo-Json -Depth 6 | Set-Content $file -Encoding UTF8
    "Reporte exportado: $file"
}
