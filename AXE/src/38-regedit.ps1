# =====================================================
# REGION 8c - REGEDIT (diagnostico): saltar al regedit.exe de Windows en la clave de un tweak
# =====================================================
# No es un editor propio: abre el Registry Editor de Microsoft posicionado en la clave exacta
# que toca un tweak, para poder comprobar a mano lo que AXE dice. Escribir en el registro sigue
# siendo responsabilidad de APLICAR (punto de restauracion + snapshot + gating); aqui solo se
# mira. La unica escritura de este modulo es LastKey, que es el cursor del propio regedit.

# Las rutas NO estan declaradas como campo del tweak: viven dentro de los scriptblocks
# Test/Apply. Extraerlas del codigo (en vez de anadir un campo RegPath a los 78) evita que el
# campo y el codigo se desincronicen, que es el fallo clasico: alguien cambia la ruta en Apply
# y el RegPath declarado sigue apuntando a la vieja, asi que el boton abre la clave equivocada
# y el usuario concluye que el tweak no se aplico.
#   Cobertura medida sobre el catalogo actual (78): 43 con ruta literal, 12 via variable de
#   modulo ($MM, $SP, $GD...), 23 sin registro (servicios / bcdedit) que no llevan boton.
#   Las variables de BUCLE ($i, $p, $s, $_) son locales al scriptblock y no se pueden resolver
#   estaticamente: esos tweaks iteran dispositivos PnP, donde no hay UNA clave que ensenar.
function Get-AXERegPathsForTweak {
    param($Tweak)
    $paths = New-Object System.Collections.ArrayList
    if(-not $Tweak){ return @() }
    $code = ''
    foreach($sb in @($Tweak.Test,$Tweak.Apply)){ if($sb){ $code += "`n" + $sb.ToString() } }

    # 1. Rutas literales: 'HKLM:\Foo\Bar' entre comillas simples o dobles.
    foreach($m in [regex]::Matches($code,"['`"](HK(?:LM|CU|CR|CC|U):\\[^'`"]+)['`"]")){
        $p = $m.Groups[1].Value.Trim()
        if($p -and -not $paths.Contains($p)){ [void]$paths.Add($p) }
    }
    # 2. Rutas via variable de modulo: Get-RV $MM 'Valor'. Se resuelve el valor ACTUAL de la
    #    variable en el scope del modulo; si no existe o no parece ruta de registro, se ignora.
    foreach($m in [regex]::Matches($code,'(?:Get-RV|Set-RD|Set-RS|Del-RV)\s+\$(\w+)')){
        $name = $m.Groups[1].Value
        if($name -in @('_','i','p','s')){ continue }   # variables de bucle: no resolubles
        $val = $null
        try { $val = Get-Variable $name -ValueOnly -Scope Script -EA SilentlyContinue } catch {}
        if(-not $val){ try { $val = Get-Variable $name -ValueOnly -EA SilentlyContinue } catch {} }
        if($val -is [string] -and $val -match '^HK(LM|CU|CR|CC|U):\\' -and -not $paths.Contains($val)){
            [void]$paths.Add($val)
        }
    }
    @($paths)
}

# Prefijo de LastKey. OJO: esta LOCALIZADO. Medido en Windows 11 es-ES: 'Equipo\HKEY_LOCAL_MACHINE'
# (no 'Computer\'). Hardcodear el ingles hace que regedit ignore el valor y abra donde estaba,
# sin error visible: el boton "funciona" pero no salta. Por eso se reutiliza el prefijo que ya
# tiene el perfil, que por definicion esta en el idioma correcto.
function Get-AXERegeditPrefix {
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit'
    $cur = Get-RV $k 'LastKey'
    if($cur -is [string] -and $cur -match '^([^\\]+)\\'){ return $Matches[1] }
    'Computer'   # perfil sin regedit abierto nunca; peor caso, abre en la raiz
}

# 'HKLM:\Foo\Bar' -> '<prefijo>\HKEY_LOCAL_MACHINE\Foo\Bar' (formato que espera LastKey).
function ConvertTo-AXERegeditPath {
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){ return $null }
    $hives = @{
        'HKLM' = 'HKEY_LOCAL_MACHINE'; 'HKCU' = 'HKEY_CURRENT_USER'
        'HKCR' = 'HKEY_CLASSES_ROOT';  'HKU'  = 'HKEY_USERS'
        'HKCC' = 'HKEY_CURRENT_CONFIG'
    }
    if($Path -notmatch '^(HK(?:LM|CU|CR|CC|U)):\\(.*)$'){ return $null }
    $hive = $hives[$Matches[1]]
    if(-not $hive){ return $null }
    $rest = $Matches[2].TrimEnd('\')
    $prefix = Get-AXERegeditPrefix
    if($rest){ "$prefix\$hive\$rest" } else { "$prefix\$hive" }
}

function Open-AXERegedit {
    # Posiciona regedit.exe en $Path. Devuelve $true si se lanzo.
    param([string]$Path)
    $target = ConvertTo-AXERegeditPath $Path
    if(-not $target){ Write-AXELog "Regedit: ruta no reconocida '$Path'." 'WARN'; return $false }
    $k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Applets\Regedit'
    try {
        if(-not (Test-Path $k)){ New-Item -Path $k -Force -EA Stop | Out-Null }
        # Escritura directa a posta, SIN Push-RegBackup: LastKey es la posicion del cursor de
        # regedit, no un ajuste del sistema. Meterlo en el backup de tweaks ensuciaria el
        # revert con una clave cosmetica que nadie quiere restaurar.
        New-ItemProperty -Path $k -Name 'LastKey' -Value $target -PropertyType String -Force -EA Stop | Out-Null
        # -m permite instancia nueva: sin el, un regedit ya abierto se lleva el foco y se
        # queda donde estaba, ignorando LastKey (que solo se lee al arrancar).
        Start-Process regedit.exe -ArgumentList '-m' -EA Stop | Out-Null
        Write-AXELog "Regedit abierto en: $Path"
        $true
    } catch {
        Write-AXELog "Regedit: no se pudo abrir -> $($_.Exception.Message)" 'ERR'
        $false
    }
}

# Foto del registro para la vista de diagnostico: una fila por (tweak, clave), con si la clave
# existe y si el Test del tweak da por aplicado. NO ejecuta Apply ni toca nada.
function Get-AXERegDiagnostic {
    param($Catalog=$null)
    if(-not $Catalog){ $Catalog = $script:CAT }
    $rows = New-Object System.Collections.ArrayList
    foreach($tw in @($Catalog)){
        $paths = @(Get-AXERegPathsForTweak $tw)
        if($paths.Count -eq 0){ continue }
        # Test puede lanzar (clave inexistente, permisos): un diagnostico que revienta no
        # diagnostica nada, asi que se degrada a $null y se sigue.
        #   El centinela es $null y NO la cadena 'n/a'. Con 'n/a', el chequeo posterior
        #   '$Applied -eq "n/a"' coacciona la cadena a booleano ($true por no estar vacia), asi
        #   que TODO tweak aplicado ($true -eq 'n/a' => True) se pintaba como indecidible.
        #   Medido: 47 de 55 filas aplicadas se mostraban como [?]. Con $null no hay coercion.
        $applied = $null
        try { $applied = [bool](& $tw.Test) } catch {}
        foreach($p in $paths){
            [void]$rows.Add([pscustomobject]@{
                Id      = $tw.Id
                Cat     = $tw.Cat
                Tier    = $tw.Tier
                Name    = $tw.Name
                Path    = $p
                Exists  = [bool](Test-Path $p)
                Applied = $applied
            })
        }
    }
    @($rows)
}

function Format-AXERegDiagnostic {
    # Render de la vista. Agrupa por clave y no por tweak: varios tweaks comparten ruta
    # (Memory Management, SystemProfile), y verlos juntos es justo lo que hace falta para
    # entender por que dos ajustes se pisan.
    param($Rows)
    $Rows = @($Rows)
    if($Rows.Count -eq 0){ return @('Sin claves de registro en el catalogo cargado.') }
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add("$($Rows.Count) entradas sobre $(@($Rows | Select-Object -ExpandProperty Path -Unique).Count) claves distintas.")
    [void]$L.Add('  [x] = Test dice aplicado   [ ] = no aplicado   [?] = el Test no pudo decidir')
    [void]$L.Add('  (falta) = la clave no existe todavia en este equipo')
    [void]$L.Add('')
    foreach($grp in ($Rows | Group-Object Path | Sort-Object Name)){
        $miss = if($grp.Group[0].Exists){ '' } else { '   (falta)' }
        [void]$L.Add("$($grp.Name)$miss")
        foreach($r in ($grp.Group | Sort-Object Id)){
            # '$null -eq' delante a proposito: al reves, PowerShell coacciona y falla raro.
            $mark = if($null -eq $r.Applied){ '?' } elseif($r.Applied){ 'x' } else { ' ' }
            [void]$L.Add(("    [{0}] {1,-22} T{2}  {3}" -f $mark,$r.Id,$r.Tier,$r.Name))
        }
        [void]$L.Add('')
    }
    @($L)
}
