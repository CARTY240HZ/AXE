# =====================================================
# REGION 10d - FPS REAL (PresentMon)
# =====================================================
# POR QUE ESTE MODULO EXISTE
#   La region 10c afirma FPS. Sin medirlos, esa afirmacion es exactamente el tipo de promesa
#   que este proyecto le reprocha al resto de tweakers. Aqui se miden de verdad.
#
#   PresentMon (Intel, gratis, MIT) engancha el evento Present de DXGI/D3D y saca el tiempo
#   entre frames PRESENTADOS. No es un contador de FPS de overlay: es la fuente que usan las
#   reviews. Se lee su CSV y se calculan medias y percentiles bajos.
#
# NO SE DESCARGA SOLO. Bajarse un ejecutable de internet y correrlo es justo lo que no debe
# hacer una herramienta que pide admin. Si no esta, se dice donde conseguirlo y ya.
#
# LO QUE SE MIDE Y POR QUE
#   El FPS medio es el numero que se ensena y el que menos importa: los tweaks de esta suite
#   (quitar trabajo de fondo, bajar jitter) casi no lo mueven. Lo que mueven son los MINIMOS,
#   porque un servicio que despierta a mitad de un frame no baja la media, crea un tiron. Por
#   eso el 1% low y el 0.1% low salen primero en el informe.
#   Convencion: percentil sobre TIEMPOS de frame, no sobre FPS instantaneo. El 1% low es la
#   media de FPS del 1% de frames MAS LENTOS. Es la definicion que usan CapFrameX y los
#   reviewers; promediar "FPS por frame" da otro numero y no seria comparable con nada.
#
# LIMITE HONESTO QUE NO SE PUEDE ARREGLAR CON CODIGO
#   Dos capturas del mismo juego no son el mismo trabajo salvo que sea la MISMA escena. Un
#   before/after andando por sitios distintos mide el mapa, no el tweak. El veredicto lo dice
#   y no hay forma de detectarlo desde aqui: es responsabilidad de quien mide usar un
#   benchmark integrado o repetir el mismo recorrido.
# =====================================================

$script:FpsCsvDir = Join-Path $script:AXEData 'fps'

# ---- localizar PresentMon (nunca descargarlo) ---------------------------------------
function Get-AXEPresentMon {
    # Orden: variable de entorno explicita -> junto a AXE -> PATH -> instalaciones tipicas.
    $cands = New-Object System.Collections.ArrayList
    if($env:AXE_PRESENTMON){ [void]$cands.Add($env:AXE_PRESENTMON) }
    [void]$cands.Add((Join-Path $script:AXERoot 'PresentMon.exe'))
    [void]$cands.Add((Join-Path $script:AXEData 'PresentMon.exe'))
    foreach($c in $cands){ if($c -and (Test-Path -LiteralPath $c)){ return (Resolve-Path -LiteralPath $c).Path } }
    # PATH y nombres versionados (PresentMon-2.3.0-x64.exe y similares).
    foreach($n in 'PresentMon','PresentMon-x64','presentmon'){
        $cmd = Get-Command $n -EA SilentlyContinue
        if($cmd){ return $cmd.Source }
    }
    foreach($d in @($script:AXERoot,$script:AXEData,"$env:ProgramFiles\PresentMon","${env:ProgramFiles(x86)}\PresentMon")){
        if(-not $d -or -not (Test-Path -LiteralPath $d)){ continue }
        $hit = Get-ChildItem -LiteralPath $d -Filter 'PresentMon*.exe' -EA SilentlyContinue | Select-Object -First 1
        if($hit){ return $hit.FullName }
    }
    return $null
}

# ---- parseo del CSV ------------------------------------------------------------------
# PURA a posta: recibe filas ya parseadas, no toca disco. Asi se testea el calculo sin tener
# PresentMon instalado ni un juego abierto (ver tests/Fps.Tests.ps1).
#
# El nombre de la columna de tiempo de frame cambio entre versiones: PresentMon 1.x emite
# 'msBetweenPresents' y 2.x 'FrameTime'. Se aceptan las dos en vez de fijar una, porque fijar
# la de hoy convierte una actualizacion del binario en un fallo silencioso de "0 frames".
function Get-AXEFrameTimeColumn($row){
    if(-not $row){ return $null }
    $names = @($row.PSObject.Properties.Name)
    foreach($c in 'msBetweenPresents','FrameTime','MsBetweenPresents','msBetweenDisplayChange'){
        if($names -contains $c){ return $c }
    }
    return $null
}

function Get-AXEFpsStats {
    # $FrameTimesMs = tiempos de frame en milisegundos, en orden de captura.
    param([double[]]$FrameTimesMs)
    $ft = @($FrameTimesMs | Where-Object { $_ -gt 0 })
    if($ft.Count -lt 10){
        return [pscustomobject]@{ Frames=$ft.Count; Ok=$false; Reason="solo $($ft.Count) frames validos (<10): captura demasiado corta para decir nada." }
    }
    $sorted = @($ft | Sort-Object -Descending)   # los mas LENTOS primero
    # Percentil bajo = media de FPS sobre el N% de frames mas lentos. Techo a 1 frame minimo
    # para que una captura corta no de una lista vacia y un divide-por-cero.
    $pick = {
        param($pct)
        $n = [math]::Max(1, [int][math]::Ceiling($sorted.Count * $pct))
        $slice = $sorted[0..($n-1)]
        $avgMs = ($slice | Measure-Object -Average).Average
        if($avgMs -le 0){ 0.0 } else { [math]::Round(1000.0/$avgMs, 1) }
    }
    $meanMs = ($ft | Measure-Object -Average).Average
    [pscustomobject]@{
        Frames    = $ft.Count
        Ok        = $true
        Reason    = $null
        AvgFps    = [math]::Round(1000.0/$meanMs, 1)
        P1LowFps  = (& $pick 0.01)
        P01LowFps = (& $pick 0.001)
        AvgMs     = [math]::Round($meanMs,3)
        MaxMs     = [math]::Round(($ft | Measure-Object -Maximum).Maximum,3)
        # Desviacion de los tiempos de frame: es el proxy directo de "tirones", y lo que los
        # tweaks de esta suite pueden mover de verdad.
        StdevMs   = [math]::Round([math]::Sqrt((($ft | ForEach-Object { ($_ - $meanMs) * ($_ - $meanMs) } | Measure-Object -Sum).Sum) / $ft.Count), 3)
        DurationS = [math]::Round(($ft | Measure-Object -Sum).Sum / 1000.0, 1)
    }
}

# ---- veredicto ------------------------------------------------------------------------
# Mismo criterio que Get-AXESweepVerdict: no basta con que el numero suba, tiene que subir
# MAS QUE EL RUIDO. Aqui el ruido se estima con la varianza de los tiempos de frame de las dos
# capturas (Welch sobre la media de tiempo de frame, que es lo que determina el FPS medio).
# PURA: se testea sin hardware.
function Get-AXEFpsVerdict {
    param([object]$Before,[object]$After)

    if(-not $Before -or -not $After -or -not $Before.Ok -or -not $After.Ok){
        return [pscustomobject]@{ Conclusive=$false; Reason='falta una de las dos capturas o no tiene frames suficientes.'; DeltaFps=0.0; DeltaPct=0.0; Warning=$null }
    }

    $dFps = [math]::Round($After.AvgFps - $Before.AvgFps, 1)
    $dPct = if($Before.AvgFps -gt 0){ [math]::Round(100.0*($After.AvgFps-$Before.AvgFps)/$Before.AvgFps, 1) } else { 0.0 }
    # El aviso de escena va SIEMPRE, tambien cuando el resultado sale bonito. Sobre todo cuando
    # sale bonito: es cuando apetece creerselo.
    $warn = 'Solo vale si las dos capturas son la MISMA escena (benchmark integrado o el mismo recorrido). Si no, esto mide el mapa, no el ajuste.'

    # Welch sobre la media de tiempo de frame. Se usa ms y no FPS porque el FPS es 1/x: su
    # media no es el inverso de la media y la varianza no se propaga limpia.
    $seB = $Before.StdevMs / [math]::Sqrt($Before.Frames)
    $seA = $After.StdevMs  / [math]::Sqrt($After.Frames)
    $se  = [math]::Sqrt($seB*$seB + $seA*$seA)
    $dMs = $Before.AvgMs - $After.AvgMs      # positivo = frames mas rapidos despues

    if($se -le 0){
        return [pscustomobject]@{ Conclusive=$false; Reason='varianza nula: captura degenerada (juego pausado o v-sync clavado?).'; DeltaFps=$dFps; DeltaPct=$dPct; Warning=$warn }
    }
    $z = [math]::Abs($dMs) / $se

    # z >= 4: los tiempos de frame estan autocorrelados (un tiron dura varios frames), asi que
    # los N frames NO son N muestras independientes y el error real es mayor que el calculado.
    # Un umbral de 1.96 daria "concluyente" con cualquier cosa. 4 es conservador a posta.
    if($z -lt 4.0){
        return [pscustomobject]@{
            Conclusive=$false
            Reason=("diferencia dentro del ruido (z={0:N1} < 4). {1:N1} FPS de delta no es distinguible de la variacion normal entre dos capturas." -f $z,$dFps)
            DeltaFps=$dFps; DeltaPct=$dPct; Warning=$warn; Z=[math]::Round($z,2)
        }
    }
    [pscustomobject]@{
        Conclusive=$true
        Reason=("delta por encima del ruido (z={0:N1}). Medio {1:N1} -> {2:N1} FPS ({3:+0.0;-0.0;0} / {4:+0.0;-0.0;0}%), 1% low {5:N1} -> {6:N1}." -f $z,$Before.AvgFps,$After.AvgFps,$dFps,$dPct,$Before.P1LowFps,$After.P1LowFps)
        DeltaFps=$dFps; DeltaPct=$dPct; Warning=$warn; Z=[math]::Round($z,2)
    }
}

# ---- captura ---------------------------------------------------------------------------
function Measure-AXEFps {
    param([Parameter(Mandatory)][string]$ProcessName,[int]$Seconds=20)
    $pm = Get-AXEPresentMon
    if(-not $pm){
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason='PresentMon no encontrado. Bajalo de https://github.com/GameTechDev/PresentMon/releases y deja PresentMon.exe junto a AXE (o define AXE_PRESENTMON). AXE no lo descarga solo a proposito.' }
    }
    $proc = ($ProcessName -replace '\.exe$','') + '.exe'
    if(-not (Get-Process -Name ($proc -replace '\.exe$','') -EA SilentlyContinue)){
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason="'$proc' no esta corriendo. Abre el juego, ponlo en la escena que vas a medir y vuelve." }
    }
    if(-not (Test-Path $script:FpsCsvDir)){ New-Item -ItemType Directory -Path $script:FpsCsvDir -Force | Out-Null }
    $csv = Join-Path $script:FpsCsvDir ("fps_{0}_{1}.csv" -f ($proc -replace '\.exe$',''),(Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        # -stop_existing_session: si quedo una sesion ETW colgada de una captura anterior,
        # PresentMon falla al arrancar. -terminate_after_timed cierra el proceso solo.
        $pmArgs = @('-process_name',$proc,'-output_file',$csv,'-timed',$Seconds,'-terminate_after_timed','-stop_existing_session','-no_top')
        $p = Start-Process -FilePath $pm -ArgumentList $pmArgs -PassThru -Wait -WindowStyle Hidden -EA Stop
        if($p.ExitCode -ne 0){ Write-AXELog "PresentMon salio con codigo $($p.ExitCode)." 'WARN' }
    } catch {
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason="no pude ejecutar PresentMon: $($_.Exception.Message). Necesita admin para la sesion ETW." }
    }
    if(-not (Test-Path $csv)){
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason='PresentMon no genero CSV. Suele ser falta de permisos (sesion ETW) o que el juego usa una API que no engancha.' }
    }
    $rows = @(Import-Csv $csv -EA SilentlyContinue)
    if($rows.Count -eq 0){ return [pscustomobject]@{ Ok=$false; Frames=0; Reason='CSV vacio: PresentMon no vio frames de ese proceso.' } }
    $col = Get-AXEFrameTimeColumn $rows[0]
    if(-not $col){
        return [pscustomobject]@{ Ok=$false; Frames=0; Reason="el CSV no trae columna de tiempo de frame conocida (columnas: $((@($rows[0].PSObject.Properties.Name)) -join ', ')). Version de PresentMon no soportada." }
    }
    $ft = @($rows | ForEach-Object { $v=0.0; if([double]::TryParse($_.$col,[ref]$v)){ $v } })
    $st = Get-AXEFpsStats -FrameTimesMs $ft
    $st | Add-Member -NotePropertyName Csv -NotePropertyValue $csv -Force
    $st | Add-Member -NotePropertyName Process -NotePropertyValue $proc -Force
    $st
}

function Format-AXEFpsStats($s,$label='Captura'){
    if(-not $s){ return @("$label : sin datos.") }
    if(-not $s.Ok){ return @("$label : $($s.Reason)") }
    @(
        ("{0} ({1}): {2} frames en {3}s" -f $label,$s.Process,$s.Frames,$s.DurationS)
        # Los minimos van PRIMERO: son lo que mueven los ajustes de esta suite. La media va
        # ultima a posta, para que no sea el numero que se mira.
        ("  1% low   : {0} FPS" -f $s.P1LowFps)
        ("  0.1% low : {0} FPS" -f $s.P01LowFps)
        ("  Medio    : {0} FPS  ({1} ms/frame, stdev {2} ms, peor {3} ms)" -f $s.AvgFps,$s.AvgMs,$s.StdevMs,$s.MaxMs)
    )
}
