# =====================================================
# REGION 5B - QUALITY GATE FOR PERFORMANCE TWEAKS
#
# This module runs immediately after 20-tweaks.ps1 (build.ps1 sorts by name)
# and before the catalog consumers in 22-catalogs.ps1.
# It deliberately changes recommendation policy, not the underlying tweak
# primitives, except for one documented MMCSS value correction.
#
# Principle: a tweak may remain available for expert/manual use without being
# presented as a broadly useful performance recommendation.
# =====================================================

# Microsoft documents that SystemResponsiveness values below 10 are clamped
# to 20. Therefore the old Apply=0 did NOT produce a 10% reservation; it
# resolved to 20%. Use the documented floor value explicitly.
$mmcss = @($script:CAT | Where-Object Id -eq 'cpu_mmcss')[0]
if($null -ne $mmcss){
    $mmcss.Desc = 'SystemResponsiveness=10: reserva el 10% de CPU a tareas de baja prioridad; el valor 10 es el minimo efectivo documentado por Windows'
    $mmcss.NotesEng = 'Microsoft documents that values below 10 are clamped to 20. Use 10 when the goal is the minimum documented low-priority CPU reservation; this is explicit and avoids the misleading "0 means 10" behavior of the previous catalog entry.'
    $mmcss.Test  = { (Get-RV 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness') -eq 10 }
    $mmcss.Apply = { Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 10 }
    $mmcss.Revert = { Set-RD 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 20 }
}

# CTCP is intentionally manual/experimental. The catalog itself documents
# that modern Windows defaults to CUBIC; keeping CTCP in Wi-Fi recommendation
# rules contradicts its own evidence notes and can make AXE recommend a legacy
# transport choice without a workload-specific measurement.
$ctcp = @($script:CAT | Where-Object Id -eq 'net_ctcp')[0]
if($null -ne $ctcp){
    $ctcp.Tier = 2
    $ctcp | Add-Member -Force -MemberType NoteProperty -Name PlaceboLikely -Value $true
    $ctcp.Name = 'CTCP (experimental / opt-in)'
    $ctcp.Desc = 'Algoritmo de congestion alternativo. CUBIC es la opcion moderna por defecto; solo probar con medicion especifica de latencia/throughput'
    $ctcpNotes = 'Opt-in only. Microsoft documentation and current Windows behavior do not justify presenting CTCP as a general gaming optimization. Keep available for controlled A/B testing on a workload that demonstrably benefits from it.'
    $ctcp | Add-Member -Force -MemberType NoteProperty -Name NotesEng -Value $ctcpNotes
}
if($script:RECRULES -is [hashtable]){ [void]$script:RECRULES.Remove('net_ctcp') }
if($script:LATRULES -is [hashtable]){ [void]$script:LATRULES.Remove('net_ctcp') }

# HAGS has real feature-level uses (for example frame-generation paths), but
# community measurements are mixed: some systems improve, others regress or
# stutter. It therefore stays available as Tier 1/manual, not a universal
# AXE recommendation.
if($script:RECCORE){
    $script:RECCORE = @($script:RECCORE | Where-Object { $_ -notin @('gpu_hags','rend_mpo','priv_recall') })
}

# MPO disable is a troubleshooting switch: useful when a specific overlay /
# compositor fault is present, but unnecessary in a healthy system and can
# affect presentation behavior. Keep it out of the default recommendation set.
$mpo = @($script:CAT | Where-Object Id -eq 'rend_mpo')[0]
if($null -ne $mpo){
    $mpo.Tier = 2
    $mpo.Name = 'MPO OFF (diagnostico: stutter/flicker)'
    $mpo.Desc = 'Desactiva Multi-Plane Overlay para diagnosticar stutter/flicker; NO es una optimizacion universal (REINICIO)'
    $mpo.NotesEng = 'Troubleshooting-only. Community reports and GPU-vendor workarounds show that disabling MPO can resolve specific flicker/stutter paths, but unnecessary global disablement can change presentation behavior and add latency. Keep manual and measure.'
}

# Privacy-only changes may still be useful to a user, but they must not be
# mixed into the performance baseline. priv_recall remains in the catalog and
# can be applied deliberately; it is simply not a default performance item.
