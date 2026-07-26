# =====================================================
# REGION 12c - CONSEJERO: QUE HACER AHORA, EN ESTA MAQUINA
# =====================================================
#
# POR QUE EXISTE: AXE sabia muchas cosas sueltas -82 tweaks con su gating, un diagnostico de
# configuracion, mediciones de timer y jitter, un monitor de red- y no juntaba ninguna. El
# usuario tenia que leer cuatro pantallas y decidir por su cuenta. Este modulo responde a la
# unica pregunta que de verdad se hace: "vale, y ahora que hago".
#
# COMO PARECE LISTO SIN SERLO: aqui no hay modelo, ni red neuronal, ni nada que "aprenda" en el
# sentido de moda. Hay tres cosas que ningun optimizador del mercado hace a la vez:
#   1. Razonar sobre COMBINACIONES en vez de campos sueltos. "Panel de 180Hz + RAM en single
#      channel" no es la suma de dos avisos: es un diagnostico distinto, porque con la RAM asi
#      esos 180Hz no los vas a ver toques lo que toques.
#   2. Ordenar por EFECTO REAL. Un hallazgo del diagnostico (10-40%) va SIEMPRE por delante de
#      cualquier tweak del catalogo (porcentajes de un digito, y varios ni eso). Ordenar al reves
#      es lo que hacen las suites de pago, porque los tweaks son lo que ellas venden.
#   3. Recordar lo MEDIDO EN ESTA MAQUINA y usarlo. Si con un ajuste puesto tu score medio no se
#      movio en cinco medidas, eso pesa mas que cualquier recomendacion de catalogo.
#
# LA LINEA QUE NO SE CRUZA: la evidencia local es OBSERVACIONAL, no un experimento controlado.
# Entre dos medidas cambian mil cosas (que tenias abierto, la temperatura, el driver). Decir
# "este ajuste te da +3" seria exactamente la mentira que este proyecto existe para no contar.
# Se dice lo que es: "con esto puesto tu score medio fue X (n=5) y sin ello Y (n=4); no es un
# experimento controlado". Y con menos de MinN muestras a cada lado, no se concluye NADA.

$script:AXEOutcomeMinN   = 3     # muestras minimas a CADA lado para abrir la boca
$script:AXEOutcomeMaxRow = 200   # tope del historico: es una ayuda, no un almacen de datos
$script:AXEOutcomeNoise  = 2.0   # puntos de score por debajo de los cuales no se afirma nada

# --- Almacen de resultados ------------------------------------------------------------------
function Get-AXEOutcomePath {
    if([string]::IsNullOrWhiteSpace($script:AXEData)){ return $null }
    Join-Path $script:AXEData 'outcomes.json'
}

function Write-AXEAdvisorLog {
    # 42 se dot-sourcea suelto en tests (sin 05-core). Loguear es best-effort, jamas un error.
    param([string]$Message,[string]$Level='INFO')
    if(Get-Command Write-AXELog -EA SilentlyContinue){ Write-AXELog $Message $Level }
}

function Read-AXEOutcomes {
    # Tolerante como Read-Profiles: ausente, ilegible o corrupto -> historico vacio, NUNCA lanza.
    # Un fichero roto no puede impedir que AXE arranque ni que aconseje sin evidencia local.
    $empty = [pscustomobject]@{ hwHash=$null; samples=@() }
    $p = Get-AXEOutcomePath
    if(-not $p -or -not (Test-Path $p)){ return $empty }
    try {
        $doc = (Get-Content $p -Raw -Encoding UTF8 -EA Stop) | ConvertFrom-Json -EA Stop
        if(-not $doc){ return $empty }
        # ConvertFrom-Json REHIDRATA las cadenas con pinta de ISO-8601 a [datetime]. Si se reescribe
        # tal cual, la fecha sale como '...T09:09:59.0000000Z' y el formato del fichero deriva en
        # cada ciclo de lectura. Peor todavia: un [string] sobre ese datetime usaria la cultura del
        # sistema y en es-ES escribiria '26/07/2026 9:09:59', con lo que el json dejaria de ser
        # portable entre maquinas. Se normaliza a la entrada y el fichero queda estable.
        $rows = foreach($s in @($doc.samples)){
            if(-not $s){ continue }
            $at = $s.at
            if($at -is [datetime]){ $at = $at.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture) }
            [pscustomobject]@{ at=[string]$at; score=$s.score; jitter=$s.jitter; applied=@($s.applied) }
        }
        return [pscustomobject]@{ hwHash=[string]$doc.hwHash; samples=@($rows) }
    } catch {
        Write-AXEAdvisorLog 'Consejero: outcomes.json ilegible; se sigue sin evidencia local.' 'WARN'
        return $empty
    }
}

function Add-AXEOutcome {
    # Guarda UNA medida con la huella de ajustes aplicados en ese momento. Devuelve $true si quedo
    # escrita. No lanza nunca: perder una muestra es aceptable, romper una medicion no.
    #   El historico se ATA a la maquina (hwHash de 41-bench, que no lleva serial ni usuario ni
    # MAC). Si el hash cambia -otra CPU, otra RAM, otro build- el historico anterior se descarta
    # entero en vez de mezclarse: comparar dos maquinas distintas da un numero sin significado.
    param(
        [Parameter(Mandatory)][int]$Score,
        [double]$JitterP999,
        [string[]]$AppliedIds = @(),
        [string]$HwHash
    )
    $p = Get-AXEOutcomePath
    if(-not $p){ return $false }
    $doc = Read-AXEOutcomes
    if($HwHash -and $doc.hwHash -and $doc.hwHash -ne $HwHash){
        Write-AXEAdvisorLog 'Consejero: la maquina cambio; el historico anterior se descarta en vez de mezclarse.' 'WARN'
        $doc = [pscustomobject]@{ hwHash=$HwHash; samples=@() }
    }
    $rows = [System.Collections.ArrayList]@($doc.samples)
    [void]$rows.Add([pscustomobject]@{
        at      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture)
        score   = [int]$Score
        jitter  = $(if($PSBoundParameters.ContainsKey('JitterP999')){ [double]$JitterP999 } else { $null })
        applied = @(@($AppliedIds) | Where-Object { $_ } | Sort-Object -Unique)
    })
    # Tope por antiguedad: se tiran las mas viejas. Un historico infinito no aconseja mejor y
    # convierte un fichero de ayuda en un problema de disco.
    while($rows.Count -gt $script:AXEOutcomeMaxRow){ $rows.RemoveAt(0) }
    try {
        $dir = Split-Path $p -Parent
        if($dir -and -not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force -EA Stop | Out-Null }
        $save = [pscustomobject]@{ hwHash=$(if($HwHash){ $HwHash } else { $doc.hwHash }); samples=@($rows) }
        Set-Content -Path $p -Value (ConvertTo-Json -InputObject $save -Depth 5) -Encoding UTF8 -EA Stop
        return $true
    } catch {
        Write-AXEAdvisorLog ("Consejero: no pude guardar la medida: {0}" -f $_.Exception.Message) 'WARN'
        return $false
    }
}

function Get-AXETweakEvidence {
    # PURA. Para UN ajuste: que dice el historico de ESTA maquina.
    #
    # Es una comparacion OBSERVACIONAL entre las medidas tomadas con el ajuste puesto y las
    # tomadas sin el. No es un ensayo: nadie controlo que cambiaba en medio. Por eso el veredicto
    # mas fuerte que puede emitir es "asociado a", jamas "causa".
    param(
        [Parameter(Mandatory)][string]$Id,
        [object[]]$Samples,
        [int]$MinN = 0
    )
    if($MinN -le 0){ $MinN = $script:AXEOutcomeMinN }
    $on = New-Object System.Collections.Generic.List[double]
    $off = New-Object System.Collections.Generic.List[double]
    foreach($s in @($Samples)){
        if($null -eq $s -or $null -eq $s.score){ continue }
        if(@($s.applied) -contains $Id){ [void]$on.Add([double]$s.score) } else { [void]$off.Add([double]$s.score) }
    }
    $mOn  = $(if($on.Count){  [math]::Round(($on  | Measure-Object -Average).Average,1) } else { $null })
    $mOff = $(if($off.Count){ [math]::Round(($off | Measure-Object -Average).Average,1) } else { $null })
    $delta = $(if($null -ne $mOn -and $null -ne $mOff){ [math]::Round($mOn - $mOff,1) } else { $null })

    # El orden de los cortes importa: primero "no se sabe", luego "no se aprecia", y solo al final
    # se permite decir algo. Al reves se colaria una afirmacion con n=1, que es ruido con formato.
    $verdict = 'sin evidencia'
    $detail  = "hacen falta $MinN medidas con el ajuste puesto y $MinN sin el; llevas $($on.Count) y $($off.Count)."
    if($on.Count -ge $MinN -and $off.Count -ge $MinN){
        if([math]::Abs($delta) -lt $script:AXEOutcomeNoise){
            $verdict = 'sin diferencia apreciable'
            $detail  = "score medio $mOn con el ajuste y $mOff sin el (n=$($on.Count)/$($off.Count)). La diferencia cae dentro del ruido de medicion."
        } elseif($delta -gt 0){
            $verdict = 'asociado a mejor score'
            $detail  = "score medio $mOn con el ajuste y $mOff sin el (n=$($on.Count)/$($off.Count)). Observacional: entre medidas cambiaron mas cosas, no es un experimento controlado."
        } else {
            $verdict = 'asociado a peor score'
            $detail  = "score medio $mOn con el ajuste y $mOff sin el (n=$($on.Count)/$($off.Count)). Observacional, pero merece que lo revises."
        }
    }
    [pscustomobject]@{
        Id=$Id; NOn=$on.Count; NOff=$off.Count; MeanOn=$mOn; MeanOff=$mOff
        Delta=$delta; Verdict=$verdict; Detail=$detail
    }
}

function Get-AXEBottleneck {
    # PURA. Razona sobre COMBINACIONES de hechos, que es de donde sale la sensacion de que el
    # programa entiende tu equipo. Un aviso por campo suelto lo hace cualquiera; decir "con la RAM
    # asi, esos 180Hz no los vas a ver" exige cruzar dos hechos.
    #   Devuelve una lista ordenada por peso. Vacia es una respuesta valida: significa que no hay
    # ningun cuello identificable con lo que se ha podido medir, y eso se dice, no se rellena.
    param($Hw, $DiagFindings, $Snapshot)
    $out = New-Object System.Collections.Generic.List[object]
    $bad = @{}
    foreach($f in @($DiagFindings)){ if($f -and $f.Status -eq 'BAD'){ $bad[[string]$f.Id] = $f } }

    $hz = $null
    if($Hw -and $Hw.RefreshHz){ $hz = [int]$Hw.RefreshHz }

    # 1. RAM en single channel. El techo mas duro que hay, y el peor combinado con panel rapido.
    if($bad.ContainsKey('ramchan')){
        $msg = 'Tu RAM va en single channel. Es el techo mas alto de esta lista: 20-40% en juego.'
        if($hz -and $hz -ge 100){
            $msg += " Y tienes un panel de $hz Hz, o sea que pagaste por unos frames que la memoria no deja llegar. Arreglar esto vale mas que el catalogo entero."
        }
        [void]$out.Add([pscustomobject]@{ Rank=1; Id='ramchan'; Title='La memoria te limita'; Detail=$msg })
    }

    # 2. XMP/EXPO apagado.
    if($bad.ContainsKey('xmp')){
        [void]$out.Add([pscustomobject]@{ Rank=2; Id='xmp'; Title='La RAM corre por debajo de lo que compraste'
            Detail='El perfil XMP/EXPO parece apagado: la memoria va a la velocidad JEDEC de arranque. 10-30% en juego, y se activa en la BIOS en dos minutos.' })
    }

    # 3. Panel por debajo de sus Hz. Barato de arreglar y de efecto inmediato.
    if($bad.ContainsKey('refresh')){
        [void]$out.Add([pscustomobject]@{ Rank=3; Id='refresh'; Title='El monitor no va a sus Hz'
            Detail=([string]$bad['refresh'].Detail + ' Se cambia en Configuracion de Windows y se nota al instante.') })
    }

    # 4. Windows en disco mecanico.
    if($bad.ContainsKey('ssd')){
        [void]$out.Add([pscustomobject]@{ Rank=4; Id='ssd'; Title='Windows vive en un disco mecanico'
            Detail='Afecta sobre todo a tirones y a cargas. Ningun ajuste del catalogo compensa esto.' })
    }

    # 5. Portatil con bateria: Windows recorta frecuencias pase lo que pase en el registro.
    if($Hw -and $Hw.IsLaptop -and $Hw.OnBattery){
        [void]$out.Add([pscustomobject]@{ Rank=5; Id='battery'; Title='Estas con bateria'
            Detail='Con el portatil desenchufado Windows recorta frecuencias de CPU y GPU por politica de energia. Cualquier medida que tomes ahora sale peor de lo que da tu equipo enchufado.' })
    }

    # 6. Maquina virtual: el timer y el jitter medidos no son los del hierro.
    if($Hw -and $Hw.IsVM){
        [void]$out.Add([pscustomobject]@{ Rank=6; Id='vm'; Title='Esto es una maquina virtual'
            Detail='El timer y el jitter que mide AXE aqui son los que da el hipervisor, no los del hardware. Los numeros valen para compararte contigo mismo, no con un equipo real.' })
    }

    # 7. Nada mal configurado Y sistema ya fino: decirlo es mas util que inventar una tarea.
    if($out.Count -eq 0){
        $timerOk = $false
        if($Snapshot -and $Snapshot.Timer -isnot [string] -and $Snapshot.Timer.CurrentMs -le 1.0){ $timerOk = $true }
        if($timerOk){
            [void]$out.Add([pscustomobject]@{ Rank=9; Id='clean'; Title='No te encuentro un cuello de botella'
                Detail='Lo que este programa sabe comprobar esta bien configurado y el timer ya esta fino. A partir de aqui el margen que queda en software es de un digito, y lo grande esta en el hardware o en los ajustes del propio juego. Preferimos decirtelo a inventarte tareas.' })
        }
    }
    @($out | Sort-Object Rank)
}

function Get-AXEAdvice {
    # PURA. Funde diagnostico + cuellos + catalogo + evidencia local en UN plan ordenado.
    # El orden NO es negociable y es lo que separa esto de un optimizador de pago:
    #   1. Lo que vale 10-40% (diagnostico). No lo arregla AXE, y aun asi va primero.
    #   2. Lo que tu propia maquina asocia a ir PEOR con un ajuste puesto.
    #   3. Ajustes recomendados que faltan (porcentajes de un digito, y se dice en el texto).
    # Un catalogo que se pone por delante de "tienes la RAM en single channel" esta vendiendo,
    # no aconsejando.
    param(
        $Hw, $DiagFindings, $Snapshot,
        [object[]]$Tweaks = @(),          # catalogo con {Id,Name,Tier,PlaceboLikely}
        [string[]]$RecommendedIds = @(),  # Get-AXERecommended
        [string[]]$AppliedIds = @(),      # los que estan puestos ahora
        [object[]]$Samples = @()          # historico local
    )
    $plan = New-Object System.Collections.Generic.List[object]
    $n = 0
    $nombreDe = {
        param($id)
        $t = @(@($Tweaks) | Where-Object { $_ -and $_.Id -eq $id }) | Select-Object -First 1
        if($t -and $t.Name){ [string]$t.Name } else { [string]$id }
    }

    foreach($b in @(Get-AXEBottleneck -Hw $Hw -DiagFindings $DiagFindings -Snapshot $Snapshot)){
        $n++
        [void]$plan.Add([pscustomobject]@{
            Order=$n; Kind='cuello'; Id=$b.Id; Title=$b.Title; Detail=$b.Detail
            Why='medido en tu equipo'; Impact='alto'
            Action=$(if($b.Id -eq 'clean'){ 'nada que hacer' } else { 'lo arreglas tu, fuera de AXE' })
        })
    }

    # 2. Ajustes PUESTOS que tu historico asocia a peor score. Solo con evidencia suficiente:
    # sugerir quitar algo por una corazonada seria peor que no decir nada.
    foreach($id in @($AppliedIds)){
        $ev = Get-AXETweakEvidence -Id $id -Samples $Samples
        if($ev.Verdict -ne 'asociado a peor score'){ continue }
        $n++
        [void]$plan.Add([pscustomobject]@{
            Order=$n; Kind='revisar'; Id=$id
            Title=("Revisa '{0}': en TU equipo va peor con el" -f (& $nombreDe $id))
            Detail=$ev.Detail; Why='historico de esta maquina'; Impact='medio'; Action='considera revertirlo'
        })
    }

    # 3. Recomendados que faltan. Van los ULTIMOS a proposito y con el tamano real declarado.
    $faltan = @(@($RecommendedIds) | Where-Object { @($AppliedIds) -notcontains $_ })
    if($faltan.Count -gt 0){
        $nombres = @($faltan | ForEach-Object { & $nombreDe $_ })
        $n++
        [void]$plan.Add([pscustomobject]@{
            Order=$n; Kind='catalogo'; Id='recomendados'
            Title=("Te faltan {0} ajuste(s) recomendados para este equipo" -f $faltan.Count)
            Detail=("Aplican a tu hardware y no estan puestos: {0}. Aviso de tamano: estos mueven porcentajes de un digito, y varios estan marcados como probable placebo en el propio catalogo. Van los ultimos de esta lista justo por eso." -f ($nombres -join ', '))
            Why='gating sobre tu hardware'; Impact='bajo'; Action='pestana Optimizar'
        })
    }

    # 4. Lo que no se pudo comprobar. Un plan que calla sus huecos parece mas listo de lo que es.
    $unk = @(@($DiagFindings) | Where-Object { $_ -and $_.Status -eq 'UNKNOWN' })
    if($unk.Count -gt 0){
        $n++
        [void]$plan.Add([pscustomobject]@{
            Order=$n; Kind='sin comprobar'; Id='unknown'
            Title=("{0} cosa(s) que no he podido comprobar" -f $unk.Count)
            Detail=((@($unk | ForEach-Object { [string]$_.Title }) -join ', ') + '. No salen como correctas por no haberse podido medir: eso seria un aprobado regalado.')
            Why='no medible aqui'; Impact='desconocido'; Action='compruebalo a mano'
        })
    }

    # .ToArray() y NO @($plan): en PowerShell 7.6.4 el subarray @(...) sobre un
    # System.Collections.Generic.List[T] lanza "Argument types do not match". Comprobado en un
    # proceso limpio, sin el motor de AXE cargado, asi que es del intérprete y no de aqui. Por eso
    # todo este proyecto devuelve .ToArray() (Get-AXEDiagFindings, Format-AXEDiag, Format-AXESession):
    # es la convencion que hay que seguir, no una manía. Pasar por una tuberia -como hace
    # Get-AXEBottleneck con Sort-Object- tambien esquiva el fallo, porque enumera de otra forma.
    $plan.ToArray()
}

function Get-AXEAppliedIds {
    # Impura: ejecuta el Test de cada tweak aplicable. Reusa Test-TweakSafe (28-revert-export),
    # que ya envuelve el scriptblock y devuelve $false ante cualquier error, en vez de contar un
    # fallo de lectura como "aplicado" -que fue justo el defecto que arreglo el FIX de 20-tweaks.
    #   Los bloqueados se saltan: un tweak que no aplica a esta maquina no esta "sin poner", es que
    # no existe aqui, y meterlo en la huella ensuciaria el historico con ruido constante.
    @(foreach($tw in @($script:CAT)){
        if(Get-BlockReason $tw){ continue }
        if(Test-TweakSafe $tw){ [string]$tw.Id }
    })
}

function Get-AXEAdviceNow {
    # Impura: junta hardware, diagnostico, medicion e historico, devuelve el plan y -esto es lo
    # importante- GUARDA la medida con la huella de ajustes puestos en ese momento.
    #
    # El bucle se cierra aqui, y a proposito: pedir consejo es lo que construye la evidencia. No
    # hay que acordarse de "registrar" nada ni pulsar un boton extra; usar el programa es lo que
    # lo hace mas util con el tiempo. Es la unica parte del proyecto que mejora sola, y mejora con
    # TUS datos, que no salen de tu disco.
    param([switch]$NoMeasure)
    $hw = $script:HW
    if(-not $hw){ try { $hw = Get-AXEHardware; $script:HW = $hw } catch { $hw = $null } }

    $findings = @()
    try { $findings = @(Get-AXEDiagFindings -Facts (Get-AXEDiagFacts)) } catch {
        Write-AXEAdvisorLog ("Consejero: el diagnostico fallo: {0}" -f $_.Exception.Message) 'WARN'
    }

    $snap = $null; $score = $null
    if(-not $NoMeasure){
        try { $snap = Get-AXESnapshot; $score = Get-AXEScore $snap } catch {
            Write-AXEAdvisorLog ("Consejero: la medicion fallo: {0}" -f $_.Exception.Message) 'WARN'
        }
    }

    $applied = @(); try { $applied = @(Get-AXEAppliedIds) } catch {}
    $rec = @();     try { $rec = @(Get-AXERecommended) } catch {}

    # Guardar la muestra ANTES de aconsejar, para que el consejo de hoy ya cuente con ella.
    # Sin score no se guarda nada: una fila sin la magnitud que se compara no sirve de nada.
    $doc = Read-AXEOutcomes
    if($null -ne $score -and $null -ne $score.Total){
        $hash = $null
        try {
            $hash = Get-AXEBenchHwHash -Cpu ([string]$hw.CpuName) -RamGB ([double]$hw.RamGB) `
                        -GpuVendor ([string]$hw.GpuVendor) -Build ([int]$hw.BuildNumber) -Version ([string]$script:AXEVersion)
        } catch {}
        $jit = $null
        if($snap -and $snap.Jitter -isnot [string]){ $jit = [double]$snap.Jitter.P999Ms }
        try {
            if($null -ne $jit){ [void](Add-AXEOutcome -Score ([int]$score.Total) -JitterP999 $jit -AppliedIds $applied -HwHash $hash) }
            else              { [void](Add-AXEOutcome -Score ([int]$score.Total) -AppliedIds $applied -HwHash $hash) }
        } catch {}
        $doc = Read-AXEOutcomes
    }

    $plan = Get-AXEAdvice -Hw $hw -DiagFindings $findings -Snapshot $snap `
                -Tweaks @($script:CAT) -RecommendedIds $rec -AppliedIds $applied -Samples @($doc.samples)

    [pscustomobject]@{
        Plan=@($plan); Findings=@($findings); Applied=@($applied); Recommended=@($rec)
        Samples=@($doc.samples); Score=$(if($score){ [int]$score.Total } else { $null })
        Hw=$hw; Timestamp=(Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture)
    }
}

function Format-AXEAdvice {
    # PURA. Render compartido CLI/GUI, como Format-AXEDiag y Format-AXESession.
    param([object[]]$Plan,[object[]]$Samples=@())
    $L = New-Object System.Collections.Generic.List[string]
    [void]$L.Add('== AXE - QUE HACER AHORA ==')
    [void]$L.Add('')
    if(@($Plan).Count -eq 0){
        [void]$L.Add('Sin datos suficientes para aconsejar. Ejecuta antes el diagnostico (-Diag).')
        return $L.ToArray()
    }
    foreach($p in @($Plan)){
        [void]$L.Add(('{0}. [{1}] {2}' -f $p.Order, ([string]$p.Kind).ToUpperInvariant(), $p.Title))
        [void]$L.Add(('     {0}' -f $p.Detail))
        # Separadores ASCII a proposito. El '·' salia como 'Â·' en consola: dist/AXE.ps1 lo lanza
        # 'powershell.exe' (5.1), que lee el .ps1 como ANSI salvo que lleve BOM. Comprobado: esta
        # era la UNICA cadena no-ASCII de todo src/ que llega a la consola; el resto de acentos
        # del proyecto viven en comentarios, que no se imprimen. La convencion ya estaba, se
        # respeta. En la WebUI si se puede usar '·': el HTML declara UTF-8.
        [void]$L.Add(('     efecto: {0} | base: {1} | accion: {2}' -f $p.Impact, $p.Why, $p.Action))
        [void]$L.Add('')
    }
    [void]$L.Add('---')
    $nS = @($Samples).Count
    if($nS -eq 0){
        [void]$L.Add('Sin historico local todavia. Cada medicion que hagas afina esta lista: AXE compara')
        [void]$L.Add('lo medido con cada ajuste puesto y sin el, EN ESTA MAQUINA.')
    } else {
        [void]$L.Add(("Historico local: {0} medicion(es) en este equipo." -f $nS))
        [void]$L.Add('Esa comparacion es OBSERVACIONAL: entre medidas cambian mas cosas que el ajuste,')
        [void]$L.Add('asi que se dice "asociado a", nunca "causa". Con menos de 3 medidas a cada lado')
        [void]$L.Add('no se afirma nada.')
    }
    $L.ToArray()
}
