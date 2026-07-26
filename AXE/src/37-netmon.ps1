# =====================================================
# REGION 9.5 - MONITOR DE RED EN VIVO (ping, jitter de red, perdida)
# =====================================================
# POR QUE EXISTE: hasta ahora la cobertura de red medida era CERO. El jitter que reporta
# 32-measure.ps1 es jitter de TIMER (despertar del scheduler), no de red: son dos cosas
# distintas y confundirlas es el tipo de metrica de vanidad que este proyecto rechaza. El
# catalogo toca ~8 ajustes de RED y no habia forma de ver si alguno hacia algo.
#
# QUE MIDE Y QUE NO (leerlo antes de sacar conclusiones):
#   - Mide el camino ICMP. Los juegos usan UDP. Muchos routers y operadores DESPRIORIZAN o
#     limitan ICMP, asi que un ping alto no implica que el juego vaya mal, ni un ping bajo
#     que vaya bien. Es un indicador, no el dato del juego.
#   - Por eso se miden DOS destinos y se reportan por separado:
#       * puerta de enlace -> calidad del ENLACE local (radio Wi-Fi, cable, driver del NIC).
#         Aqui si hay conclusiones duras: perder paquetes contra tu propio router no es normal.
#       * ancla publica    -> el camino a internet. Sin veredicto absoluto: la latencia depende
#         de la geografia y no existe un umbral honesto de "buen ping".
#   - No hay puntuacion 0-100. Un numero unico aqui seria inventado.
#
# La parte que decide (Get-AXENetStats / Get-AXENetFindings) es PURA: recibe muestras y
# devuelve numeros y hallazgos sin tocar la red. Asi se testea sin hardware ni conexion.

function Get-AXENetStats {
    # PURA. $Samples = RTT en ms por sonda; $null = paquete perdido.
    param([object[]]$Samples)

    $all  = @($Samples)
    $ok   = @($all | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $sent = $all.Count
    $recv = $ok.Count

    if($sent -eq 0){
        return [pscustomobject]@{
            Sent=0; Received=0; LostPct=$null; MinMs=$null; AvgMs=$null
            MaxMs=$null; P95Ms=$null; JitterMs=$null
        }
    }
    $lost = [math]::Round(100.0 * ($sent - $recv) / $sent, 1)
    if($recv -eq 0){
        return [pscustomobject]@{
            Sent=$sent; Received=0; LostPct=$lost; MinMs=$null; AvgMs=$null
            MaxMs=$null; P95Ms=$null; JitterMs=$null
        }
    }

    $sorted = @($ok | Sort-Object)
    # P95 por rango mas cercano, sin interpolar. Con 20 sondas la interpolacion finge una
    # precision que no existe; el indice entero es honesto y reproducible.
    $idx = [int][math]::Ceiling(0.95 * $sorted.Count) - 1
    if($idx -lt 0){ $idx = 0 }
    if($idx -ge $sorted.Count){ $idx = $sorted.Count - 1 }

    # Jitter de red = media del |delta| entre RTT CONSECUTIVOS, que es lo que se percibe como
    # inestabilidad. NO es la desviacion tipica: un RTT que sube despacio y de forma monotona
    # da desviacion alta y no se nota; saltar 5ms arriba y abajo cada paquete si se nota.
    #   Los deltas se toman solo entre sondas CONSECUTIVAS RECIBIDAS. Saltarse las perdidas y
    # encadenar los dos extremos del hueco inflaria el jitter con un intervalo que en realidad
    # cubre varios periodos: la perdida ya se reporta aparte y no se cobra dos veces.
    $deltas = New-Object System.Collections.Generic.List[double]
    for($i=1; $i -lt $all.Count; $i++){
        $a = $all[$i-1]; $b = $all[$i]
        if($null -eq $a -or $null -eq $b){ continue }
        [void]$deltas.Add([math]::Abs([double]$b - [double]$a))
    }
    $jit = $null
    if($deltas.Count -gt 0){ $jit = [math]::Round((($deltas | Measure-Object -Average).Average), 2) }

    [pscustomobject]@{
        Sent     = $sent
        Received = $recv
        LostPct  = $lost
        MinMs    = [math]::Round(($ok | Measure-Object -Minimum).Minimum, 2)
        AvgMs    = [math]::Round(($ok | Measure-Object -Average).Average, 2)
        MaxMs    = [math]::Round(($ok | Measure-Object -Maximum).Maximum, 2)
        P95Ms    = [math]::Round($sorted[$idx], 2)
        JitterMs = $jit
    }
}

function Get-AXENetFindings {
    # PURA. Solo emite hallazgos donde el dato es INEQUIVOCO. Deliberadamente corta: la
    # tentacion es puntuar el ping a internet, y no hay umbral defendible (200ms desde otro
    # continente puede ser perfectamente normal). Contra la propia puerta de enlace si lo hay.
    param($Gw, $Pub)

    $out = New-Object System.Collections.ArrayList

    if($Gw -and $Gw.Sent -gt 0){
        if($Gw.Received -eq 0){
            [void]$out.Add([pscustomobject]@{ Sev='ERR'; Msg='La puerta de enlace no responde a ninguna sonda. O filtra ICMP, o el enlace esta caido.' })
        } else {
            # Perdida contra el router: no atraviesa internet, no hay operador de por medio.
            # Cualquier valor > 0 apunta a radio, cable o driver del adaptador.
            if($Gw.LostPct -gt 0){
                [void]$out.Add([pscustomobject]@{ Sev='ERR'; Msg=("Perdida del {0}% contra tu propia puerta de enlace. Eso no cruza internet: mira la radio Wi-Fi, el cable o el driver del NIC." -f $Gw.LostPct) })
            }
            # Jitter local. El umbral es un corte practico, no una constante fisica: por cable el
            # enlace local aporta decimas de ms, asi que varios ms de variacion consecutiva ya
            # delatan la radio o un adaptador con problemas. Se dice que es un corte, no una ley.
            #   AVISO DE INTERPRETACION, y no es un tecnicismo: un router responde a los pings
            # DIRIGIDOS A EL con su CPU de gestion, que tiene la prioridad mas baja del aparato,
            # mientras que el trafico que solo REENVIA va por la ruta rapida. Por eso se ve a
            # menudo mas jitter contra el propio router que contra un destino de internet que
            # pasa por el. Medido en la maquina de referencia: 7.91ms contra la puerta de enlace
            # frente a 0.55ms contra 1.1.1.1, que atraviesa ese mismo router.
            #   Afirmar "tu radio va mal" con este dato seria pasarse. Se reporta la medida y las
            # DOS lecturas posibles, y se apunta a la comparacion que si distingue: si el tramo a
            # internet sale estable, el enlace no puede ser el cuello.
            if($null -ne $Gw.JitterMs -and $Gw.JitterMs -gt 5){
                $msg = "Jitter de {0}ms hasta el router (corte practico: 5ms)." -f $Gw.JitterMs
                if($Pub -and $Pub.Received -gt 0 -and $null -ne $Pub.JitterMs -and $Pub.JitterMs -le $Gw.JitterMs){
                    $msg += " Pero el tramo a internet, que pasa por ese mismo router, sale en {0}ms: entonces lo que ves es la CPU de gestion del router respondiendo tarde a sus propios pings, no tu enlace. No es accionable desde el PC." -f $Pub.JitterMs
                } else {
                    $msg += ' Dos lecturas posibles: enlace inestable (radio, cable, driver) o la CPU de gestion del router respondiendo tarde a sus propios pings. Mide tambien hacia internet: si ese tramo sale estable, el enlace no es el problema.'
                }
                [void]$out.Add([pscustomobject]@{ Sev='WARN'; Msg=$msg })
            }
        }
    }
    # Perdida hacia fuera con enlace local limpio: separa "tu PC" de "tu operador". Sin el 0%
    # local no se puede afirmar, porque la perdida podria venir del propio enlace.
    if($Pub -and $Pub.Sent -gt 0 -and $Pub.Received -gt 0 -and $Pub.LostPct -gt 0 -and $Gw -and $Gw.Received -gt 0 -and $Gw.LostPct -eq 0){
        [void]$out.Add([pscustomobject]@{ Sev='WARN'; Msg=("Perdida del {0}% hacia internet con 0% hasta tu router: el problema esta fuera de casa (operador o ruta), no en el PC." -f $Pub.LostPct) })
    }
    if($out.Count -eq 0){
        [void]$out.Add([pscustomobject]@{ Sev='OK'; Msg='Sin hallazgos inequivocos. Los numeros de arriba siguen siendo del camino ICMP, no del trafico del juego.' })
    }
    $out.ToArray()
}

function Get-AXENetGateway {
    # Puerta de enlace IPv4 por defecto. $null si no hay (sin red, o red solo IPv6).
    try {
        $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA Stop |
             Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } |
             Sort-Object RouteMetric | Select-Object -First 1
        if($r){ return [string]$r.NextHop }
    } catch {}
    try {
        $c = Get-NetIPConfiguration -EA Stop | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1
        if($c){ return [string]$c.IPv4DefaultGateway.NextHop }
    } catch {}
    $null
}

function Measure-AXENetProbe {
    # Sondea UN destino. Devuelve el objeto de Get-AXENetStats con Target anadido.
    # Sin dependencias externas: System.Net.NetworkInformation.Ping viene con .NET.
    param(
        [string]$Target,
        [int]$Count = 20,
        [int]$IntervalMs = 200,
        [int]$TimeoutMs = 1000
    )
    if([string]::IsNullOrWhiteSpace($Target)){ return $null }

    $samples = New-Object System.Collections.Generic.List[object]
    $ping = New-Object System.Net.NetworkInformation.Ping
    # 32 bytes = lo que manda ping.exe, para poder contrastar con el ping del sistema.
    $payload = New-Object byte[] 32
    try {
        for($i=0; $i -lt $Count; $i++){
            $rtt = $null
            try {
                $r = $ping.Send($Target, $TimeoutMs, $payload)
                # Solo Success cuenta como recibido. TimedOut, TtlExpired o DestinationUnreachable
                # son perdida desde el punto de vista del que juega: la respuesta no llego.
                if($r.Status -eq 'Success'){ $rtt = [double]$r.RoundtripTime }
            } catch { $rtt = $null }
            [void]$samples.Add($rtt)
            # Sin espera tras la ultima sonda: solo alargaria la medicion sin aportar nada.
            if($i -lt ($Count-1) -and $IntervalMs -gt 0){ Start-Sleep -Milliseconds $IntervalMs }
        }
    } finally { $ping.Dispose() }

    $st = Get-AXENetStats -Samples $samples.ToArray()
    $st | Add-Member -NotePropertyName Target -NotePropertyValue $Target -PassThru
}

function Measure-AXENetwork {
    # Medicion completa: enlace local + ancla publica, con hallazgos.
    #   El ancla por defecto es 1.1.1.1 porque responde a ICMP de forma estable y es anycast
    # global, o sea que mide TU camino y no la distancia a un pais concreto. No se elige "el
    # DNS mas rapido" ni se rankean proveedores: eso fue justo lo que se borro de
    # 22-catalogs.ps1 por rankear sin medir.
    param(
        [string]$Target = '1.1.1.1',
        [int]$Count = 20,
        [int]$IntervalMs = 200,
        [switch]$NoGateway
    )
    $gw = $null
    $gwIp = $(if($NoGateway){ $null } else { Get-AXENetGateway })
    if($gwIp){ $gw = Measure-AXENetProbe -Target $gwIp -Count $Count -IntervalMs $IntervalMs }
    $pub = Measure-AXENetProbe -Target $Target -Count $Count -IntervalMs $IntervalMs

    [pscustomobject]@{
        Timestamp = (Get-Date).ToUniversalTime().ToString('u')
        Adapter   = $(if($script:HW){ $script:HW.NicName } else { $null })
        IsWifi    = $(if($script:HW){ [bool]$script:HW.IsWifi } else { $null })
        Gateway   = $gw
        Public    = $pub
        Findings  = (Get-AXENetFindings -Gw $gw -Pub $pub)
    }
}

function Format-AXENetwork {
    param($r)
    if(-not $r){ return 'Sin medicion de red.' }
    $L = New-Object System.Collections.ArrayList
    $ad = $(if($r.Adapter){ $r.Adapter } else { 'adaptador desconocido' })
    $md = $(if($r.IsWifi -eq $true){ 'Wi-Fi' } elseif($r.IsWifi -eq $false){ 'cable' } else { 'medio desconocido' })
    [void]$L.Add("RED EN VIVO - $ad ($md)")
    [void]$L.Add('Camino ICMP. Los juegos van por UDP y muchos routers despriorizan ICMP: es un indicador, no el dato del juego.')
    [void]$L.Add('')
    foreach($p in @(@{T='Enlace local (router)';S=$r.Gateway}, @{T='Internet';S=$r.Public})){
        $s = $p.S
        if(-not $s){ [void]$L.Add(("{0,-22} : no medido" -f $p.T)); continue }
        if($s.Received -eq 0){
            [void]$L.Add(("{0,-22} : {1}  sin respuesta ({2} sondas, 100% perdida)" -f $p.T,$s.Target,$s.Sent))
            continue
        }
        [void]$L.Add(("{0,-22} : {1}" -f $p.T,$s.Target))
        [void]$L.Add(("  ping   min/med/max  {0}/{1}/{2} ms    P95 {3} ms" -f $s.MinMs,$s.AvgMs,$s.MaxMs,$s.P95Ms))
        [void]$L.Add(("  jitter {0} ms (media del salto entre paquetes)    perdida {1}% ({2}/{3})" -f $s.JitterMs,$s.LostPct,($s.Sent-$s.Received),$s.Sent))
    }
    [void]$L.Add('')
    foreach($f in @($r.Findings)){ [void]$L.Add(("[{0,-4}] {1}" -f $f.Sev,$f.Msg)) }
    ($L -join "`r`n")
}
