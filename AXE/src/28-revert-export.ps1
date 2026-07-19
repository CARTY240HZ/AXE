# =====================================================
# REGION 9 - MASTER REVERT  (FIX A1: limpia residuos v1)
# =====================================================
# A3: cola (limpieza residuos v1 + restore startup). Extraido para que la GUI pueda
# drenar el loop de reverts ASYNC (sin congelar) y correr esta cola al final.
function Invoke-AXEMasterRevertTail {
    # SmartScreen (v1 lo apagaba; v2 lo quito de apply pero no limpiaba en revert)
    $ssKey='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    if((Get-RV $ssKey 'EnableSmartScreen') -ne $null){ Del-RV $ssKey 'EnableSmartScreen'; Write-AXELog 'Limpieza v1: EnableSmartScreen eliminado (restaura SmartScreen)' }
    # NoConnectedUser (v1 bloqueaba login Microsoft)
    $ncuKey='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if((Get-RV $ncuKey 'NoConnectedUser') -ne $null){ Del-RV $ncuKey 'NoConnectedUser'; Write-AXELog 'Limpieza v1: NoConnectedUser eliminado (desbloquea login MS)' }
    # hypervisorlaunchtype (v1 lo ponia off; rompia WSL2/Docker)
    $hv=((bcdedit /enum '{current}' | Out-String))
    if($hv -match 'hypervisorlaunchtype\s+Off'){ bcdedit /set hypervisorlaunchtype auto | Out-Null; Write-AXELog 'Limpieza v1: hypervisorlaunchtype -> auto (restaura WSL2/Docker)' }
    # useplatformtick / CoalescingTimerDisabled (v1 CPU avanzado)
    if($hv -match 'useplatformclock\s+Yes'){ bcdedit /deletevalue useplatformclock | Out-Null; Write-AXELog 'Limpieza v1: useplatformclock eliminado' }
    if((Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'CoalescingTimerDisabled') -ne $null){ Del-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'CoalescingTimerDisabled'; Write-AXELog 'Limpieza v1: CoalescingTimerDisabled eliminado' }
    # Restaurar startup si hay backup
    Restore-Autorun | Out-Null
    Write-AXELog '=== MASTER REVERT completado. Reinicia el PC. ==='
}

# =====================================================
# REGION 10 - PERFIL EXPORT/IMPORT
# =====================================================
function Test-TweakSafe($tw){
    try { return [bool](& $tw.Test) } catch { return $false }
}
function Export-AXEProfile($file){
    $prof = foreach($tw in $script:CAT){ [pscustomobject]@{Id=$tw.Id; On=(Test-TweakSafe $tw)} }
    $prof | ConvertTo-Json -Depth 3 | Set-Content $file -Encoding UTF8
    Write-AXELog "Perfil exportado: $file ($($prof.Count) tweaks)"
}
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Import-AXEProfile($file){
    if(-not(Test-Path $file)){ Write-AXELog "No existe: $file" 'ERR'; return }
    if(-not (Test-Admin)){ Write-AXELog 'Import requiere admin. Ejecuta via AXE.bat (se eleva solo) o como administrador.' 'ERR'; return }
    $data = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
    $applied=0; $errors=0
    foreach($e in $data){
        $tw = $script:CAT | Where-Object Id -eq $e.Id
        if(-not $tw){ continue }
        if(Get-BlockReason $tw){ continue }
        try {
            if($e.On){
                # Mismo protocolo de snapshot que la GUI (57-gui-handlers:429). Import lo saltaba
                # en los DOS sentidos: aplicaba sin poner $capTweak (no capturaba nada) y revertia
                # llamando al scriptblock directo (ignorando lo capturado). Resultado: aplicar por
                # perfil dejaba el tweak sin estado previo guardado, asi que el revert posterior
                # caia al fallback -- que para varios tweaks escribe un default SUPUESTO, y para
                # gpu_mmcss borra valores que Windows trae de fabrica en la tarea Games.
                if(Test-SnapEligible $tw){ $script:capTweak=$tw.Id }
                try { & $tw.Apply } finally { $script:capTweak=$null }
                Commit-TweakState $tw.Id
            } else {
                # El scriptblock es el FALLBACK, no la via normal: solo si no hay estado previo
                # capturado (tweak aplicado fuera de AXE, o no elegible por usar powercfg/bcdedit).
                if(-not ((Test-SnapEligible $tw) -and (Restore-TweakState $tw.Id))){ & $tw.Revert }
            }
            $applied++
        } catch { $errors++; Write-AXELog "Error importando $($tw.Id): $($_.Exception.Message)" 'ERR' }
    }
    Write-AXELog "Perfil importado: $applied aplicados, $errors errores. Reinicia si hubo cambios."
}

