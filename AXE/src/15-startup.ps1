# =====================================================
# REGION 4 - STARTUP BACKUP/RESTORE  (FIX C1)
# Array tipado + serializacion robusta + Restore-Autorun (antes inexistente)
# =====================================================
$script:RunKeys = [ordered]@{
    'HKCU'  = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'HKLM'  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    'WOW64' = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
}
function Read-StartupBackup {
    # Lee el JSON como array SIEMPRE (corregible y robusto ante formato corrupto/heredado)
    if(-not(Test-Path $script:RunBak)){ return @() }
    $raw = Get-Content $script:RunBak -Raw -Encoding UTF8
    if([string]::IsNullOrWhiteSpace($raw)){ return @() }
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        # Normalizar a array SIEMPRE (@(...) envuelve objeto suelto o deja array tal cual)
        return @($obj)
    } catch {
        # Antes: return @() en silencio. Disable-Autorun lee esto, anade UNA entrada y SOBREESCRIBE
        # el fichero entero con solo esa lista -- si el JSON estaba corrupto (crash a mitad de
        # escritura, etc.) con entradas previas recuperables, se perdian todas sin aviso ni rastro.
        # Mismo patron que Read-StateBak (10-reg-helpers.ps1): renombrar a .corrupt en vez de tragarselo.
        Write-AXELog "startup_disabled.json ilegible: $($_.Exception.Message). Renombrado a .corrupt" 'ERR'
        try { Move-Item $script:RunBak "$($script:RunBak).corrupt" -Force -EA Stop } catch {}
        return @()
    }
}
function Get-Autoruns {
    $list = New-Object System.Collections.ArrayList
    foreach($k in $script:RunKeys.Keys){
        $p = $script:RunKeys[$k]; if(-not(Test-Path $p)){ continue }
        $item = Get-Item $p
        foreach($n in $item.GetValueNames()){
            # Captura el ValueKind (REG_SZ vs REG_EXPAND_SZ, comun en autoruns con %ProgramFiles%
            # etc.). Antes se perdia y Restore-Autorun restauraba siempre como String -- una entrada
            # ExpandString volvia sin expandir sus variables tras desactivar+restaurar.
            $kind = try { $item.GetValueKind($n).ToString() } catch { 'String' }
            [void]$list.Add([pscustomobject]@{Hive=$k; Path=$p; Name=$n; Value=$item.GetValue($n); Kind=$kind})
        }
    }
    $list
}
function Disable-Autorun($entry){
    $bak = [System.Collections.ArrayList]@(Read-StartupBackup)
    $kind = if($entry.PSObject.Properties['Kind'] -and $entry.Kind){ $entry.Kind } else { 'String' }
    [void]$bak.Add([pscustomobject]@{Hive=$entry.Hive; Path=$entry.Path; Name=$entry.Name; Value=$entry.Value; Kind=$kind})
    $bak.ToArray() | ConvertTo-Json -Depth 5 | Set-Content $script:RunBak -Encoding UTF8
    Remove-ItemProperty $entry.Path -Name $entry.Name -ErrorAction SilentlyContinue
    Write-AXELog "Startup desactivado: $($entry.Name) (backup guardado)"
}
function Restore-Autorun {
    # FIX C1: funcion que antes NO existia. Restaura todos los autoruns del backup.
    $bak = Read-StartupBackup
    if($bak.Count -eq 0){ Write-AXELog 'No hay startup en backup.' 'WARN'; return 0 }
    $restored = 0
    foreach($e in $bak){
        try {
            if(-not(Test-Path $e.Path)){ New-Item -Path $e.Path -Force | Out-Null }
            # Backups anteriores a este fix no traen Kind -> String (comportamiento previo, sin
            # cambios para ellos). Los nuevos restauran el tipo real capturado en Get-Autoruns.
            $kind = if($e.PSObject.Properties['Kind'] -and $e.Kind){ $e.Kind } else { 'String' }
            New-ItemProperty -Path $e.Path -Name $e.Name -Value $e.Value -PropertyType $kind -Force | Out-Null
            $restored++
            Write-AXELog "Startup restaurado: $($e.Name)"
        } catch { Write-AXELog "No pude restaurar $($e.Name): $($_.Exception.Message)" 'ERR' }
    }
    if($restored -gt 0){ Remove-Item $script:RunBak -ErrorAction SilentlyContinue }
    Write-AXELog "$restored autorun(s) restaurado(s)."
    return $restored
}
function Repair-StartupBackup {
    # Migra el JSON corrupto heredado (objeto anidado con value/Count) a array plano.
    if(-not(Test-Path $script:RunBak)){ return 0 }
    $raw = Get-Content $script:RunBak -Raw -Encoding UTF8
    $clean = New-Object System.Collections.ArrayList
    try {
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        $candidates = @()
        if($obj -is [array]){ $candidates = $obj } else { $candidates = @($obj) }
        foreach($c in $candidates){
            # Objeto valido: tiene Hive, Path, Name
            if($c.PSObject.Properties['Hive'] -and $c.PSObject.Properties['Path'] -and $c.PSObject.Properties['Name']){
                $k = if($c.PSObject.Properties['Kind'] -and $c.Kind){ $c.Kind } else { 'String' }
                [void]$clean.Add([pscustomobject]@{Hive=$c.Hive; Path=$c.Path; Name=$c.Name; Value=$c.Value; Kind=$k})
                continue
            }
            # Formato heredado corrupto: el dato real puede estar bajo 'value' (array)
            if($c.PSObject.Properties['value'] -and $c.value){
                foreach($inner in @($c.value)){
                    if($inner.PSObject.Properties['Hive'] -and $inner.PSObject.Properties['Path']){
                        $k = if($inner.PSObject.Properties['Kind'] -and $inner.Kind){ $inner.Kind } else { 'String' }
                        [void]$clean.Add([pscustomobject]@{Hive=$inner.Hive; Path=$inner.Path; Name=$inner.Name; Value=$inner.Value; Kind=$k})
                    }
                }
            }
        }
    } catch {
        Write-AXELog "startup_disabled.json corrupto: $($_.Exception.Message). Renombrado a .corrupt" 'ERR'
        try { Move-Item $script:RunBak "$($script:RunBak).corrupt" -Force -EA Stop } catch {}
        return 0
    }
    if($clean.Count -eq 0){ return 0 }
    $clean.ToArray() | ConvertTo-Json -Depth 5 | Set-Content $script:RunBak -Encoding UTF8
    return $clean.Count
}

