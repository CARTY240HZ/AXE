# =====================================================
# REGION 8c - SEGURIDAD: punto de restauracion best-effort (fuente unica)
# =====================================================
# El cuerpo del checkpoint vive AQUI una sola vez. Lo reusan:
#   - New-AXERestorePoint (headless / CLI, in-process)
#   - $script:doRestorePoint (GUI: lo inyecta en un runspace de fondo; 57-gui-handlers)
# Es AUTOCONTENIDO (no llama funciones de sesion) para poder correr dentro del runspace.
$script:RestorePointScript = {
    param($desc)
    $ac = Get-CimInstance Win32_SystemDriver -EA SilentlyContinue | Where-Object { $_.State -eq 'Running' -and $_.Name -match 'EasyAntiCheat|BEDaisy|BattlEye|vgk' }
    if($ac){ return "ANTICHEAT: '$($ac.Name -join ', ')' bloquea VSS. Cierra el juego/launcher y reintenta." }
    foreach($sv in 'VSS','swprv'){ $s=Get-Service $sv -EA SilentlyContinue; if($s -and $s.StartType -eq 'Disabled'){ & sc.exe config $sv start= demand | Out-Null } }
    Start-Service VSS -EA SilentlyContinue
    Enable-ComputerRestore -Drive 'C:\' -EA SilentlyContinue
    $rp='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    New-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -Value 0 -PropertyType DWord -Force | Out-Null
    try {
        Checkpoint-Computer -Description $desc -RestorePointType MODIFY_SETTINGS
        # §4.2 #5: CREAR *Y VERIFICAR*. Checkpoint-Computer no lanza aunque el throttle 24h
        # o VSS silencien la creacion => confirmar que el punto realmente aterrizo.
        $rpv = Get-ComputerRestorePoint -EA SilentlyContinue | Where-Object { $_.Description -eq $desc } | Select-Object -Last 1
        if($rpv){ 'OK: punto CREADO Y VERIFICADO.' }
        else { 'ERROR: Checkpoint no persistio (throttle 24h o VSS bloqueado): sin punto valido.' }
    }
    catch { "ERROR: $($_.Exception.Message)" }
    finally { Remove-ItemProperty -Path $rp -Name SystemRestorePointCreationFrequency -EA SilentlyContinue }
}

function New-AXERestorePoint {
    # Best-effort, NUNCA lanza. Devuelve {Status; Message}. Ejecucion in-process (CLI/wrap).
    # La GUI usa el runspace (no congela) via $script:doRestorePoint.
    param([string]$Desc='AXE optimizacion')
    if($env:AXE_NOSR){ return [pscustomobject]@{ Status='fallback'; Message='SR omitido (AXE_NOSR / modo test)' } }
    try {
        $out = & $script:RestorePointScript $Desc
        $line = @($out)[-1]
        if("$line" -match '^OK'){ return [pscustomobject]@{ Status='ok'; Message="$line" } }
        # anticheat / SR deshabilitado / throttle -> fallback: apoyate en las redes existentes
        return [pscustomobject]@{ Status='fallback'; Message="$line  (usa backups .reg + Export como red)" }
    } catch {
        return [pscustomobject]@{ Status='error'; Message=$_.Exception.Message }
    }
}

function Assert-AXEVss {
    # §4.1: garantiza VSS+swprv arrancables (demand) y VSS corriendo. Best-effort, NUNCA lanza.
    # Sin VSS el restore point falla; el caller decide fallback (.reg/Export). Devuelve {Ok; Message}.
    try {
        foreach($sv in 'VSS','swprv'){ $s=Get-Service $sv -EA SilentlyContinue; if($s -and $s.StartType -eq 'Disabled'){ & sc.exe config $sv start= demand | Out-Null } }
        Start-Service VSS -EA SilentlyContinue
        $vss = Get-Service VSS -EA SilentlyContinue
        if($vss -and $vss.Status -eq 'Running'){ [pscustomobject]@{ Ok=$true;  Message='VSS operativo' } }
        else { [pscustomobject]@{ Ok=$false; Message='VSS no arranco: restore point puede fallar (usa fallback .reg/Export)' } }
    } catch { [pscustomobject]@{ Ok=$false; Message="VSS check fallo: $($_.Exception.Message)" } }
}

function Get-AXETamperState {
    # §4.1: estado de Tamper Protection. Para rutear tweaks de Defender por registro crudo
    # hacia *-MpPreference (con Tamper ON, la escritura de registro no persiste). Default $false.
    if($script:HW -and $script:HW.PSObject.Properties['IsTamperProtected']){ return [bool]$script:HW.IsTamperProtected }
    try { return [bool](Get-MpComputerStatus -ErrorAction Stop).IsTamperProtected } catch { return $false }
}
