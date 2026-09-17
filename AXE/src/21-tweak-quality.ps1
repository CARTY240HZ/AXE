# =====================================================
# REGION 5B - QUALITY GATE FOR PERFORMANCE TWEAKS
# =====================================================
# Recommendation policy only. Underlying tweak primitives remain unchanged
# except for the documented MMCSS value correction.

# Microsoft documents that SystemResponsiveness values below 10 are clamped to 20.
# The previous Apply=0 therefore did not express the intended 10% reservation.
$mmcss = @($script:CAT | Where-Object Id -eq 'cpu_mmcss')[0]
if($null -ne $mmcss){
    $mmcss.Desc = 'SystemResponsiveness=10: reserva el 10% de CPU a tareas de baja prioridad; el valor 10 es el minimo efectivo documentado por Windows'
    $mmcss.NotesEng = 'Microsoft documents that values below 10 are clamped to 20. Use 10 when the goal is the minimum documented low-priority CPU reservation.'
    $mmcss.Test  = { (Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness') -eq 10 }
    $mmcss.Apply = { Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10 }
    $mmcss.Revert = { Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 20 }
}

# CTCP remains available only for explicit/manual A/B testing.
$ctcp = @($script:CAT | Where-Object Id -eq 'net_ctcp')[0]
if($null -ne $ctcp){
    $ctcp.Tier = 2
    $ctcp.Name = 'CTCP (experimental / opt-in)'
    $ctcp.Desc = 'Algoritmo de congestion alternativo. CUBIC es la opcion moderna por defecto; solo probar con medicion especifica de latencia/throughput'
}
if($script:RECRULES -is [hashtable]){ [void]$script:RECRULES.Remove('net_ctcp') }
if($script:LATRULES -is [hashtable]){ [void]$script:LATRULES.Remove('net_ctcp') }

# HAGS stays available for explicit hardware/game A/B tests, not a universal recommendation.
if($script:RECCORE){
    $script:RECCORE = @($script:RECCORE | Where-Object { $_ -notin @('gpu_hags','rend_mpo','priv_recall') })
}

# MPO disable is troubleshooting-only.
$mpo = @($script:CAT | Where-Object Id -eq 'rend_mpo')[0]
if($null -ne $mpo){
    $mpo.Tier = 2
    $mpo.Name = 'MPO OFF (diagnostico: stutter/flicker)'
    $mpo.Desc = 'Desactiva Multi-Plane Overlay para diagnosticar stutter/flicker; NO es una optimizacion universal (REINICIO)'
}

# Privacy-only tweaks remain available but do not count as performance recommendations.
