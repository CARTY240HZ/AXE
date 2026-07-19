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

# ELIMINADAS (auditoria 2026-07-19): Assert-AXEVss y Get-AXETamperState. Escritas contra la
# spec §4.1 ("preflight de seguridad") y nunca cableadas: cero llamadores de produccion. Su
# unica referencia era un check del SelfTest (S22) que comprobaba que estaban DEFINIDAS -- un
# test sobre funciones que nadie llama, verde para siempre y con cobertura ficticia. Se fue con
# ellas.
#
# No eran codigo util pendiente de conectar, eran duplicados de algo que ya corre:
#   - Assert-AXEVss repetia literalmente el bucle VSS/swprv de $script:RestorePointScript (arriba),
#     que si se ejecuta en cada punto de restauracion.
#   - Get-AXETamperState tenia una consulta en vivo como fallback por si no habia $script:HW,
#     pero Get-BlockReason retorna antes en ese caso (20-tweaks:369), asi que esa rama era
#     inalcanzable. Quien necesita el dato usa $script:HW.IsTamperProtected directo.
#
# Si vuelve a hacer falta un preflight de VSS, extraer el bucle de RestorePointScript a una
# funcion y llamarla desde AMBOS sitios; no reescribirlo al lado.
