# =====================================================
# REGION 12b - DAEMON DE SESION DE JUEGO (subsistema A) - spec 2026-07-20
# =====================================================
# Congela el fondo mientras juegas y lo descongela al cerrar el juego o AXE. El hueco que
# ninguna suite (hone.gg/Pulse/Atlas/Delta) rellena de verdad: congelan cuatro cosas y timido,
# porque un fallo cuelga el PC y les come el soporte. Aqui la recuperacion la garantiza el
# KERNEL (al cerrar el handle del job, Windows descongela solo), asi que no hay codigo de
# recuperacion que pueda fallar.
#
# Reparto igual que Get-AXEDiagFacts vs Get-AXEDiagFindings: lo PURO (que hacer) es testeable
# sin hardware (Get-AXESessionPlan); lo que toca el kernel (hacerlo) no se testea, se documenta.
# Carga despues de 32-measure, donde vive [AXE.Native] (extendido con los Job* methods).

# --- Familias (deteccion por grupo, no por nombres sueltos). Nivel por defecto: ---
#   voz/anticheat/shell -> INTACTO ; navegador/musica/mensajeria -> DEGRADADO ; resto -> CONGELADO
$script:AXESessionFamilies = @{
    voz        = @('discord','discordptb','discordcanary','teamspeak','teamspeak3','ts3client','mumble','ventrilo')
    anticheat  = @('easyanticheat','easyanticheat_eos','beservice','battleye','bedaisy','vgc','vgtray','vgk','faceitservice','faceit')
    # svchost/conhost/audiodg estan aqui por una razon que el spec de A no vio: Windows aloja los
    # servicios POR-USUARIO (CDPUserSvc, WpnUserService, OneSyncSvc, UnistoreSvc, PimIndexMaintenance
    # ...) en instancias de svchost que corren en la SESION INTERACTIVA, no en la 0. "Session 0 queda
    # fuera por definicion" no los cubre. Congelar uno cuelga a quien le haga un RPC SINCRONO -shell,
    # notificaciones, portapapeles- hasta el timeout. Lo caza el test del puente sobre una maquina real.
    shell      = @('dwm','explorer','csrss','winlogon','wininit','services','lsass','smss','svchost','conhost','audiodg','fontdrvhost','sihost','ctfmon','textinputhost','startmenuexperiencehost','searchhost','searchapp','shellexperiencehost','taskhostw','runtimebroker','dllhost','applicationframehost','systemsettings','lockapp')
    navegador  = @('chrome','brave','msedge','edge','firefox','opera','opera_gx','vivaldi','browser')
    musica     = @('spotify','tidal','deezer','foobar2000','aimp','musicbee')
    mensajeria = @('whatsapp','telegram','signal','slack')
}

function Get-AXESessionProcesses {
    # Impura: lee procesos. NO juzga. Alimenta a Get-AXESessionPlan con hechos planos.
    # Ventana, titulo y memoria viajan para el detector de juego (Get-AXEGameCandidates); el
    # planificador los ignora. Se leen AQUI y no alli para que el detector siga siendo puro.
    #   Nada de esto abre un handle al proceso: Path, MainWindowHandle y WorkingSet64 salen del
    # snapshot que ya trae Get-Process. Es deliberado - abrir handles contra un juego protegido es
    # justo lo que un anti-cheat interpreta mal, y AXE promete por escrito no hacerlo.
    $out = New-Object System.Collections.ArrayList
    foreach($p in (Get-Process -EA SilentlyContinue)){
        $path = $null; try { $path = $p.Path } catch {}
        $hwnd = [IntPtr]::Zero; try { $hwnd = $p.MainWindowHandle } catch {}
        $title = ''; try { $title = [string]$p.MainWindowTitle } catch {}
        $ws = 0.0; try { $ws = [math]::Round($p.WorkingSet64 / 1MB, 0) } catch {}
        [void]$out.Add([pscustomobject]@{
            Pid          = [int]$p.Id
            Name         = [string]$p.ProcessName
            SessionId    = [int]$p.SessionId
            Path         = $path
            HasWindow    = ($hwnd -ne [IntPtr]::Zero)
            Title        = $title
            WorkingSetMB = [double]$ws
        })
    }
    @($out)
}

# --- Smart detect: que proceso es el juego ---------------------------------------------------
# El defecto que arregla: la seccion de sesion pedia ESCRIBIR el nombre del proceso. Quien no sabe
# que Valorant corre como 'VALORANT-Win64-Shipping' no podia usarla, y ese es justo el usuario al
# que sirve congelar el fondo. La funcion existia; la puerta de entrada no.
#
# Como NO se resuelve: con una lista de juegos conocidos. Es lo que hacen las suites de pago y
# envejece sola - cada lanzamiento es una actualizacion, y el juego que no esta en la lista no
# existe para el programa. Un indie de itch.io no entra en esa lista jamas.
#
# Como si: puntuando senales que valen para un juego que salio ayer.
#   - La CARPETA de la tienda es el indicio fuerte y estable. Cambian los juegos, no las rutas:
#     'steamapps\common' lleva ahi desde 2003.
#   - El SUFIJO DEL MOTOR es el segundo. Unreal compila a '<Juego>-Win64-Shipping.exe'; eso
#     identifica al MOTOR, no al titulo, asi que cubre juegos que todavia no existen.
#   - Ventana propia y memoria desempatan.
# Y no se arranca solo: se PROPONE con el motivo a la vista. Congelar el fondo es lo mas agresivo
# que hace AXE; elegir por el usuario sobre que proceso se hace seria pasarse de la raya.

# Fragmentos de ruta (minusculas) -> tienda. Es el indicio de mas peso.
$script:AXEGameStorePaths = [ordered]@{
    'steamapps\common'              = 'Steam'
    'epic games\'                   = 'Epic Games'
    'riot games\'                   = 'Riot Games'
    'gog galaxy\games'              = 'GOG'
    'ubisoft game launcher\games'   = 'Ubisoft'
    'ea games\'                     = 'EA'
    'origin games\'                 = 'EA (Origin)'
    'rockstar games\'               = 'Rockstar'
    'battle.net\games'              = 'Battle.net'
    '\xboxgames\'                   = 'Xbox'
    '\.minecraft'                   = 'Minecraft'
}
# Marcador RECHAZADO a proposito: '\windowsapps\'. Parecia cubrir los juegos de Microsoft Store,
# pero ahi vive TODA app empaquetada MSIX. En la maquina de referencia hacia que Claude Desktop y
# la utilidad NitroSense puntuasen 70 y se colasen por delante de cualquier juego real. Un indicio
# que marca a todo el mundo no es un indicio. Los juegos de Xbox si tienen carpeta propia
# (\XboxGames\) y esa si discrimina, asi que se queda solo esa.

# Lanzaderas y utilidades: NUNCA son "el juego", aunque cumplan el resto de senales (viven en la
# carpeta de la tienda, tienen ventana y comen memoria). Excluirlas evita el falso positivo mas
# probable de todos: proponer Steam como juego porque Steam esta dentro de steamapps.
$script:AXEGameNotGame = @(
    'steam','steamwebhelper','steamservice','epicgameslauncher','epicwebhelper','unrealcefsubprocess'
    'battle.net','battle.net helper','blizzarderror','agent','riotclientservices','riotclientux'
    'riotclientuxrender','riotclientcrashhandler','galaxyclient','galaxyclienthelper','galaxycommunication'
    'upc','uplay','ubisoftconnect','ubisoftgamelauncher','eadesktop','eabackgroundservice','ealauncher'
    'origin','originwebhelperservice','originclientservice','rockstarservice','rockstarerrorhandler'
    'launcher','gamelaunchhelper','xboxapp','xboxpcapp','gamingservices','gameoverlayui','gamebar'
    'gamebarpresencewriter','obs64','obs32','streamlabs obs','streamlabs','xsplit.core'
    'nvcontainer','nvidia share','nvidia web helper','nvidiaoverlay','msiafterburner','rtss'
    'rivatuner','code','devenv','idea64','pycharm64','rider64','pwsh','powershell','cmd'
    'windowsterminal','taskmgr','notepad','notepad++','msiexec','setup','install','unins000'
)

function Test-AXEGameExcluded {
    # PURA. Un proceso que NO puede ser el juego, con el motivo. Devuelve $null si si puede serlo.
    # Se separa del puntuador porque "descartado" y "puntua bajo" son cosas distintas: lo primero
    # no se ensena, lo segundo se ensena al final de la lista.
    param($Proc,[int]$SelfPid)
    if(-not $Proc){ return 'proceso vacio' }
    $name = Get-AXESessionAppName $Proc.Name
    if([int]$Proc.Pid -eq $SelfPid){ return 'es AXE' }
    if([int]$Proc.Pid -le 4){ return 'proceso del sistema' }
    if(Test-AXESessionHardApp $name){ return 'shell o anticheat: AXE nunca lo toca' }
    # Familias conocidas que no son juegos. La voz, el navegador y la musica ya tienen su reparto.
    foreach($fam in 'voz','navegador','musica','mensajeria'){
        if($script:AXESessionFamilies[$fam] -contains $name){ return "es $fam, no un juego" }
    }
    if($script:AXEGameNotGame -contains $name){ return 'es una lanzadera o utilidad, no el juego' }
    # Infraestructura por como SE LLAMA, no por estar en una lista. Cazado en la maquina de
    # referencia: 'epiconlineservicesuserhelper' vive en la carpeta de Epic Games, o sea que se
    # llevaba los 50 puntos de tienda y salia PRIMERO, por delante de cualquier juego real.
    # Ampliar la lista nombre a nombre es perder la carrera: cada tienda trae los suyos y cambian
    # con cada version. La regla no: ningun juego se llama '<algo>service' ni '<algo>helper'.
    #   Se ancla al FINAL del nombre a proposito. Como subcadena suelta, 'agent' descartaria un
    # juego llamado 'Agents of Mayhem' y 'launcher' uno que la lleve en el titulo.
    if($name -match '(service|services|helper|crashhandler|crashreporter|errorreporter|overlay|updater|broker|daemon|launcher|agent|installer)$'){
        return 'es un proceso de servicio o ayudante, no el juego'
    }
    $path = [string]$Proc.Path
    if($path){
        # %WINDIR% queda fuera entero: ahi no se instala ningun juego, y lo que hay dentro es justo
        # lo que no conviene proponerle a nadie como centro de una sesion.
        $win = ([string]$env:SystemRoot).ToLowerInvariant()
        if($win -and $path.ToLowerInvariant().StartsWith($win)){ return 'vive en la carpeta de Windows' }
    }
    $null
}

function Get-AXEGameCandidates {
    # PURA sobre los hechos que recibe (por eso es testeable sin un solo juego instalado). Devuelve
    # los candidatos ORDENADOS por puntuacion, cada uno con sus razones en texto. No decide: propone.
    param(
        [object[]]$Processes,
        [int]$SelfPid,
        [int]$SessionId,
        [int]$Top = 8
    )
    # Cuantos procesos hay con cada nombre en esta sesion. Se cuenta sobre TODOS, no solo sobre los
    # que puntuan: la interfaz dira "x9 procesos" y eso tiene que cuadrar con el Administrador de
    # tareas, no ser un recuento interno de candidatos. De los 9 procesos de una app de Electron
    # solo uno tiene ventana, asi que contar los puntuados habria dicho "x1" teniendo 9 delante.
    $byName = @{}
    foreach($p in @($Processes)){
        if($null -eq $p){ continue }
        if([int]$p.SessionId -ne $SessionId){ continue }
        $k = Get-AXESessionAppName $p.Name
        if($byName.ContainsKey($k)){ $byName[$k]++ } else { $byName[$k] = 1 }
    }

    $out = New-Object System.Collections.ArrayList
    foreach($p in @($Processes)){
        if($null -eq $p){ continue }
        if([int]$p.SessionId -ne $SessionId){ continue }   # solo la sesion interactiva, igual que el plan
        if(Test-AXEGameExcluded -Proc $p -SelfPid $SelfPid){ continue }

        $score   = 0
        $reasons = New-Object System.Collections.ArrayList
        $name    = Get-AXESessionAppName $p.Name
        $path    = [string]$p.Path
        $lp      = $path.ToLowerInvariant()

        # 1. Carpeta de tienda: el indicio de mas peso y el que no envejece.
        $store = $null
        if($lp){
            foreach($frag in $script:AXEGameStorePaths.Keys){
                if($lp.Contains($frag)){ $store = $script:AXEGameStorePaths[$frag]; break }
            }
        }
        if($store){ $score += 50; [void]$reasons.Add("instalado en la carpeta de $store") }

        # 2. Firma del MOTOR, no del titulo: cubre juegos que todavia no existen.
        if($name -match '\-win(64|32|gdk)\-shipping$'){
            $score += 30; [void]$reasons.Add('ejecutable de Unreal Engine (build shipping)')
        } elseif($name -match 'win64|win32'){
            $score += 8;  [void]$reasons.Add('nombre de ejecutable tipico de juego')
        }

        # 3. Ventana propia. Un juego siempre tiene una; un servicio de fondo no.
        if($p.PSObject.Properties['HasWindow'] -and $p.HasWindow){
            $score += 20; [void]$reasons.Add('tiene ventana propia')
        }

        # 4. Memoria. Escalonada y sin llevarse el protagonismo: la RAM sola no prueba nada -un
        #    navegador gasta mas que un indie- pero acompanada de lo de arriba desempata bien.
        $ws = 0.0
        if($p.PSObject.Properties['WorkingSetMB']){ $ws = [double]$p.WorkingSetMB }
        if($ws -ge 1500){ $score += 20; [void]$reasons.Add("usa $([int]$ws) MB de memoria") }
        elseif($ws -ge 600){ $score += 12; [void]$reasons.Add("usa $([int]$ws) MB de memoria") }
        elseif($ws -ge 250){ $score += 6 }

        # Sin una sola senal positiva no se propone: seria ruido, no un candidato.
        if($score -le 0){ continue }

        [void]$out.Add([pscustomobject]@{
            Name    = $name
            Pid     = [int]$p.Pid
            Score   = [int]$score
            Store   = $store
            Title   = $(if($p.PSObject.Properties['Title']){ [string]$p.Title } else { '' })
            Path    = $path
            # "Probable" = tienda, o motor + ventana. Una sola senal debil no basta para que la
            # interfaz lo preseleccione: proponerlo si, elegirlo por el usuario no.
            Likely  = [bool]($score -ge 50)
            Reasons = @($reasons)
        })
    }

    # UNA fila por APP, no por pid. Mismo principio que ya aplica session.preview con Chrome: doce
    # procesos son UNA decision, no doce. Sin esto una app de Electron -que abre un proceso por
    # pestana o por servicio- llenaba la lista entera con su propio nombre repetido y empujaba al
    # juego de verdad fuera del top. Representa al grupo la instancia de MAYOR puntuacion, que es
    # la que tiene la ventana; el numero de procesos viaja para que la interfaz pueda decirlo.
    $best = [ordered]@{}
    foreach($c in $out){
        $k = $c.Name
        if(-not $best.Contains($k) -or $c.Score -gt $best[$k].Score){ $best[$k] = $c }
    }
    foreach($k in @($best.Keys)){
        $best[$k] | Add-Member -NotePropertyName Instances -NotePropertyValue ([int]$byName[$k]) -Force
    }
    # Empate por puntuacion -> orden estable por nombre, para que dos lecturas seguidas no bailen.
    @(@($best.Values) | Sort-Object -Property @{Expression='Score';Descending=$true},@{Expression='Name';Descending=$false} |
        Select-Object -First ([math]::Max(1,$Top)))
}

function Get-AXESessionLevel {
    # PURA. Un proceso -> 'intacto'|'degradado'|'congelado' dado el contexto. Orden a posta:
    # los DUROS (juego, AXE, shell, anticheat) ganan a la config del usuario; nunca se tocan.
    param($Proc,[int]$GamePid,[int]$SelfPid,[hashtable]$Config)
    $name = (([string]$Proc.Name).ToLowerInvariant()) -replace '\.exe$',''
    # 1. Duros: intocables incluso con config.
    if([int]$Proc.Pid -eq $GamePid){ return 'intacto' }
    if([int]$Proc.Pid -eq $SelfPid){ return 'intacto' }
    $fam = $script:AXESessionFamilies
    if(($fam.shell -contains $name) -or ($fam.anticheat -contains $name)){ return 'intacto' }
    if($name -match 'anticheat|battleye|easyanti'){ return 'intacto' }   # variantes con sufijos raros
    # 2. Config del usuario sobreescribe el default por app (solo apps NO duras).
    if($Config -and $Config.ContainsKey($name)){
        $lvl = ([string]$Config[$name]).ToLowerInvariant()
        if($lvl -in 'intacto','degradado','congelado'){ return $lvl }
    }
    # 3. Familias por defecto.
    if($fam.voz -contains $name){ return 'intacto' }   # la voz es sensible a latencia: degradarla se oye
    if(($fam.navegador -contains $name) -or ($fam.musica -contains $name) -or ($fam.mensajeria -contains $name)){ return 'degradado' }
    # 4. Desconocido de la sesion del usuario -> congelado.
    return 'congelado'
}

function Get-AXESessionPlan {
    # PURA. Hechos + config -> los tres grupos. El nucleo testeable (tests/Session.Tests.ps1).
    # Frontera: Session 0 (servicios/drivers/audiodg/lsass) queda fuera POR DEFINICION - lo aisla
    # ya el SO. Solo se considera la sesion interactiva actual.
    param(
        [object[]]$Processes,
        [int]$GamePid,
        [string]$GameName,
        [int]$SelfPid,
        [int]$SessionId,
        [hashtable]$Config = @{}
    )
    # SessionId <= 0 o sin procesos -> plan vacio, sin reventar (caso testeado).
    if($SessionId -le 0){ return [pscustomobject]@{ Intacto=@(); Degradado=@(); Congelado=@() } }
    $intacto   = New-Object System.Collections.ArrayList
    $degradado = New-Object System.Collections.ArrayList
    $congelado = New-Object System.Collections.ArrayList
    foreach($p in @($Processes)){
        if($null -eq $p){ continue }
        if([int]$p.SessionId -eq 0){ continue }             # Session 0 nunca (defensivo)
        if([int]$p.SessionId -ne $SessionId){ continue }    # fuera de la sesion interactiva
        switch(Get-AXESessionLevel -Proc $p -GamePid $GamePid -SelfPid $SelfPid -Config $Config){
            'intacto'   { [void]$intacto.Add($p) }
            'degradado' { [void]$degradado.Add($p) }
            default     { [void]$congelado.Add($p) }
        }
    }
    [pscustomobject]@{ Intacto=@($intacto); Degradado=@($degradado); Congelado=@($congelado) }
}

# --- Reparto configurable por app: persistencia (spec 2026-07-25) ---------------------------
# El planificador ya aceptaba -Config y estaba testeado con overrides; lo que faltaba era el par
# leer/escribir y quien lo edite (la seccion de la WebUI). Fichero PROPIO, no dentro de
# game_profiles.json: ese es un ARRAY de perfiles de plan de energia que recorre Tick-GameProfiles;
# meter un mapa app->nivel en el mismo array mezcla dos esquemas sin relacion, obliga a filtrar a
# todos sus consumidores y arriesga el monitor que si toca el plan de energia en vivo.
$script:AXESessionLevels = @('intacto','degradado','congelado')

function Write-AXESessionLog {
    # 40-session se dot-sourcea SUELTO en tests (sin 05-core, donde vive Write-AXELog): loguear es
    # best-effort, nunca un error que tumbe una sesion.
    param([string]$Message,[string]$Level='INFO')
    if(Get-Command Write-AXELog -EA SilentlyContinue){ Write-AXELog $Message $Level }
}

function Get-AXESessionAppName {
    # PURA. Normaliza a la clave con la que trabajan familias y overrides: minusculas, sin .exe.
    param([string]$Name)
    (([string]$Name).Trim().ToLowerInvariant()) -replace '\.exe$',''
}

function Get-AXESessionLevelsPath {
    # Sin $script:AXEData (motor cargado suelto) devuelve $null: el llamante degrada, no inventa ruta.
    if([string]::IsNullOrWhiteSpace($script:AXEData)){ return $null }
    Join-Path $script:AXEData 'session_levels.json'
}

function Get-AXESessionFamily {
    # PURA. Nombre -> familia ('navegador','voz','musica'...) o $null si no esta en ninguna. No adivina.
    param([string]$Name)
    $n = Get-AXESessionAppName $Name
    foreach($fam in @($script:AXESessionFamilies.Keys)){
        if($script:AXESessionFamilies[$fam] -contains $n){ return [string]$fam }
    }
    $null
}

function Test-AXESessionHardApp {
    # PURA. Duro = shell o anticheat. El planificador los deja INTACTOS ganando a la config, asi que
    # un override sobre ellos no haria NADA: se rechaza al escribir en vez de ignorarlo en silencio.
    param([string]$Name)
    $n = Get-AXESessionAppName $Name
    $fam = $script:AXESessionFamilies
    [bool](($fam.shell -contains $n) -or ($fam.anticheat -contains $n) -or ($n -match 'anticheat|battleye|easyanti'))
}

function Read-AXESessionOverrides {
    # Overrides por-app {nombre->nivel} desde disco. Tolerante como Read-Profiles: ausente, corrupto
    # o con entradas invalidas -> se descarta lo que no vale y NUNCA lanza. Un fichero corrupto no se
    # borra: se deja para inspeccion (el usuario puede haberlo editado a mano).
    $out = @{}
    $path = Get-AXESessionLevelsPath
    if(-not $path -or -not (Test-Path $path)){ return $out }
    $raw = $null
    try { $raw = Get-Content $path -Raw -Encoding UTF8 -EA Stop } catch { return $out }
    if([string]::IsNullOrWhiteSpace($raw)){ return $out }
    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -EA Stop } catch {
        Write-AXESessionLog 'Sesion: session_levels.json ilegible; se usan los niveles por defecto.' 'WARN'
        return $out
    }
    foreach($p in @($obj.PSObject.Properties)){
        $name = Get-AXESessionAppName $p.Name
        if([string]::IsNullOrWhiteSpace($name)){ continue }
        $lvl = ([string]$p.Value).Trim().ToLowerInvariant()
        if($script:AXESessionLevels -notcontains $lvl){ continue }   # nivel inventado: se descarta
        $out[$name] = $lvl
    }
    $out
}

function Set-AXESessionOverride {
    # Escribe o borra UN override. -Level 'default' borra (vuelve al reparto por familias).
    # Devuelve {Ok,Reason,Overrides}; nunca lanza.
    param([string]$Name,[string]$Level)
    $n = Get-AXESessionAppName $Name
    if([string]::IsNullOrWhiteSpace($n)){
        return [pscustomobject]@{ Ok=$false; Reason='falta el nombre de la app.'; Overrides=(Read-AXESessionOverrides) }
    }
    $lvl = ([string]$Level).Trim().ToLowerInvariant()
    if($lvl -ne 'default' -and $script:AXESessionLevels -notcontains $lvl){
        return [pscustomobject]@{ Ok=$false; Overrides=(Read-AXESessionOverrides)
            Reason=("nivel '{0}' invalido: usa {1} o default." -f $Level,($script:AXESessionLevels -join '/')) }
    }
    if(Test-AXESessionHardApp $n){
        return [pscustomobject]@{ Ok=$false; Overrides=(Read-AXESessionOverrides)
            Reason=("'{0}' es shell o anticheat: AXE nunca lo toca, asi que su nivel no es configurable." -f $n) }
    }
    $path = Get-AXESessionLevelsPath
    if(-not $path){
        return [pscustomobject]@{ Ok=$false; Reason='sin carpeta de datos de AXE: no puedo guardar el nivel.'; Overrides=@{} }
    }
    $map = Read-AXESessionOverrides
    if($lvl -eq 'default'){ [void]$map.Remove($n) } else { $map[$n] = $lvl }
    try {
        $dir = Split-Path $path -Parent
        if($dir -and -not (Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force -EA Stop | Out-Null }
        # '{}' explicito cuando queda vacio: ConvertTo-Json de un hashtable vacio no emite nada y
        # Set-Content dejaria el fichero anterior intacto (misma trampa que documenta Save-Profiles).
        $json = if($map.Count -eq 0){ '{}' } else { ConvertTo-Json -InputObject $map -Depth 3 }
        Set-Content -Path $path -Value $json -Encoding UTF8 -EA Stop
    } catch {
        return [pscustomobject]@{ Ok=$false; Reason=("no pude guardar el nivel: {0}" -f $_.Exception.Message); Overrides=(Read-AXESessionOverrides) }
    }
    Write-AXESessionLog ("Sesion: nivel de '{0}' -> {1}." -f $n,$lvl)
    [pscustomobject]@{ Ok=$true; Reason=$null; Overrides=$map }
}

# --- Red para la salida SUCIA: prioridades degradadas (auditoria 2026-07-25) -----------------
# El diseño apoya TODA la recuperacion en el kernel: al cerrarse el handle del job, Windows
# descongela. Es cierto para lo CONGELADO y FALSO para lo DEGRADADO: bajar la prioridad no es un
# estado del job, es una propiedad del proceso, y ahi el kernel no ayuda. Si AXE muere -o si
# simplemente cierras la ventana- nadie la devuelve, y el navegador se queda en BelowNormal hasta
# que lo reinicies: exactamente el "dejar la maquina a medias" que el spec prohibe.
#   Dos redes: el cierre limpio llama a Stop (47-webhost), y para el kill/BSOD queda este diario en
# disco, que se restaura en el siguiente arranque.
function Get-AXESessionJournalPath {
    if([string]::IsNullOrWhiteSpace($script:AXEData)){ return $null }
    Join-Path $script:AXEData 'session_degraded.json'
}

function Test-AXESessionSameProcess {
    # Impura (lee el proceso). Los pid SE REUSAN: restaurar una prioridad por pid a secas puede
    # tocar un proceso ajeno que heredo el numero. Nombre + instante de arranque cierra el hueco.
    # Ante cualquier duda devuelve $false: no tocar es siempre mejor que tocar lo que no es.
    param([int]$ProcessId,[string]$Name,[long]$StartTicks)
    if($ProcessId -le 0){ return $false }
    $p = Get-Process -Id $ProcessId -EA SilentlyContinue
    if(-not $p){ return $false }
    if((Get-AXESessionAppName $p.ProcessName) -ne (Get-AXESessionAppName $Name)){ return $false }
    if($StartTicks -gt 0){
        $t = 0
        try { $t = [long]$p.StartTime.Ticks } catch { return $false }
        if($t -ne $StartTicks){ return $false }
    }
    $true
}

function Clear-AXESessionJournal {
    $path = Get-AXESessionJournalPath
    if($path -and (Test-Path $path)){ Remove-Item $path -Force -EA SilentlyContinue }
}

function Write-AXESessionJournal {
    # Deja constancia de lo degradado ANTES de que pueda hacer falta. Best-effort: si no se puede
    # escribir, la sesion sigue (el diario es una red, no un requisito).
    param($Degraded)
    $path = Get-AXESessionJournalPath
    if(-not $path){ return }
    try {
        $rows = @(@($Degraded) | Where-Object { $_ } | ForEach-Object {
            [pscustomobject]@{ pid=[int]$_.Pid; name=[string]$_.Name; prev=[string]$_.Prev; startTicks=[long]$_.StartTicks }
        })
        if($rows.Count -eq 0){ Clear-AXESessionJournal; return }
        # El diario lleva DUEÑO: si hay dos AXE abiertos, el que arranca segundo no puede reparar el
        # de una sesion que sigue viva. Sin esto le devolveria la prioridad a media partida y, peor,
        # borraria el diario: si la primera instancia muriera sucia ya no habria red que la cubriese.
        $me = $null; try { $me = Get-Process -Id $PID -EA Stop } catch {}
        $ownerTicks = 0; if($me){ try { $ownerTicks = [long]$me.StartTime.Ticks } catch {} }
        $doc = [pscustomobject]@{
            owner    = [pscustomobject]@{ pid=[int]$PID; name=$(if($me){ [string]$me.ProcessName } else { '' }); startTicks=$ownerTicks }
            degraded = $rows
        }
        Set-Content -Path $path -Value (ConvertTo-Json -InputObject $doc -Depth 4) -Encoding UTF8 -EA Stop
    } catch { Write-AXESessionLog ("Sesion: no pude escribir el diario de prioridades: {0}" -f $_.Exception.Message) 'WARN' }
}

function Restore-AXESessionDegraded {
    # Se llama al arrancar. Devuelve cuantas prioridades se restauraron (0 si no habia diario).
    # Nunca lanza: un diario ilegible se descarta y se sigue.
    $path = Get-AXESessionJournalPath
    if(-not $path -or -not (Test-Path $path)){ return 0 }
    $doc = $null
    try { $doc = (Get-Content $path -Raw -Encoding UTF8 -EA Stop) | ConvertFrom-Json -EA Stop } catch {
        Write-AXESessionLog 'Sesion: diario de prioridades ilegible; se descarta.' 'WARN'
        Clear-AXESessionJournal
        return 0
    }
    # Dueño vivo y distinto de mi => otra instancia de AXE tiene la sesion abierta. Ni restaurar ni
    # borrar: ese diario sigue siendo SU red.
    $owner = $doc.owner
    if($owner -and ([int]$owner.pid -ne $PID) -and
       (Test-AXESessionSameProcess -ProcessId ([int]$owner.pid) -Name ([string]$owner.name) -StartTicks ([long]$owner.startTicks))){
        Write-AXESessionLog 'Sesion: el diario de prioridades es de otra instancia de AXE que sigue viva; no se toca.' 'WARN'
        return 0
    }
    $rows = @($doc.degraded)
    $n = 0
    foreach($r in $rows){
        if(-not $r){ continue }
        if(-not (Test-AXESessionSameProcess -ProcessId ([int]$r.pid) -Name ([string]$r.name) -StartTicks ([long]$r.startTicks))){ continue }
        try { (Get-Process -Id ([int]$r.pid) -EA Stop).PriorityClass = [string]$r.prev; $n++ } catch {}
    }
    Clear-AXESessionJournal
    if($n -gt 0){ Write-AXESessionLog ("Sesion: restauradas {0} prioridad(es) de una sesion anterior que no cerro limpiamente." -f $n) }
    $n
}

function Start-AXESession {
    # Impura. Sonda freeze -> crea job -> asigna congelados -> congela -> degrada. Devuelve el
    # objeto de sesion. PRINCIPIO: cualquier fallo ANTES de congelar -> abortar sin tocar nada.
    param([string]$GameName)
    if([string]::IsNullOrWhiteSpace($GameName)){ return [pscustomobject]@{ Ok=$false; Reason='falta el nombre del juego.' } }
    $gproc = Get-Process -Name ($GameName -replace '\.exe$','') -EA SilentlyContinue | Select-Object -First 1
    if(-not $gproc){ return [pscustomobject]@{ Ok=$false; Reason="el juego '$GameName' no esta corriendo. Abrelo y reintenta." } }

    if(-not ('AXE.Native' -as [type]) -or -not [AXE.Native].GetMethod('JobProbeFreeze')){
        return [pscustomobject]@{ Ok=$false; Reason='capa nativa de sesion ausente (reinicia AXE tras rebuild).' }
    }
    # Sonda: si JobObjectFreezeInformation no existe en este Windows -> abortar limpio, sin fallback.
    $probe = [AXE.Native]::JobProbeFreeze()
    if($probe -ne 0){
        return [pscustomobject]@{ Ok=$false; Reason=("JobObjectFreezeInformation no disponible aqui (status 0x{0:X8}): sesion abortada sin tocar nada." -f $probe) }
    }

    $sid   = [int]$gproc.SessionId
    $facts = Get-AXESessionProcesses
    $plan  = Get-AXESessionPlan -Processes $facts -GamePid ([int]$gproc.Id) -GameName $GameName -SelfPid $PID -SessionId $sid -Config (Read-AXESessionOverrides)

    $hJob = [AXE.Native]::JobCreate()
    if($hJob -eq [IntPtr]::Zero){ return [pscustomobject]@{ Ok=$false; Reason='CreateJobObject fallo; nada congelado.' } }

    # Asignar congelados. Un pid protegido que falle NO tumba la sesion: se cuenta y se sigue.
    $assigned = 0; $failed = 0
    foreach($p in @($plan.Congelado)){
        $rc = [AXE.Native]::JobAssignPid($hJob, [int]$p.Pid)
        if($rc -eq 0){ $assigned++ } else { $failed++ }
    }
    # Congelar el job entero de una vez.
    $fr = [AXE.Native]::JobFreeze($hJob)
    if($fr -ne 0){
        [void][AXE.Native]::JobClose($hJob)   # cerrar => el kernel descongela lo asignado
        return [pscustomobject]@{ Ok=$false; Reason=("freeze fallo (status 0x{0:X8}) tras asignar; job cerrado, nada quedo congelado." -f $fr) }
    }

    # Degradar (best-effort, no critico): prioridad baja pero VIVO y usable. Pinning a nucleos
    # fuera del juego es el subsistema B, no este. Guardamos la prioridad previa para restaurar.
    $degraded = New-Object System.Collections.ArrayList
    foreach($p in @($plan.Degradado)){
        try {
            $pr = Get-Process -Id ([int]$p.Pid) -EA Stop
            $prev = $pr.PriorityClass
            # Nombre + arranque junto al pid: es lo que permite comprobar mas tarde que el pid sigue
            # siendo ESTE proceso y no otro que heredo el numero.
            $startTicks = 0
            try { $startTicks = [long]$pr.StartTime.Ticks } catch {}
            $pr.PriorityClass = 'BelowNormal'
            [void]$degraded.Add([pscustomobject]@{ Pid=[int]$p.Pid; Name=[string]$pr.ProcessName; Prev=[string]$prev; StartTicks=$startTicks })
            # Diario en disco tras CADA proceso, no al final del bucle: si AXE muere a mitad del
            # bucle (crash/kill/BSOD), el ultimo proceso degradado antes de morir tenia que quedar
            # escrito YA, o el proximo arranque no sabe que restaurarle. Write-AXESessionJournal
            # sobreescribe con la lista completa (no acumula), asi que llamarla aqui es seguro y
            # barato: cada iteracion dega el diario al dia.
            Write-AXESessionJournal $degraded
        } catch {}
    }

    [pscustomobject]@{
        Ok=$true; Handle=$hJob; Game=$GameName; GamePid=[int]$gproc.Id; SessionId=$sid
        Plan=$plan; Assigned=$assigned; Failed=$failed; Degraded=@($degraded); Started=(Get-Date)
    }
}

function Stop-AXESession {
    # Impura. Cierra el handle (kernel descongela) y restaura las prioridades degradadas.
    param($Session)
    if(-not $Session -or -not $Session.Ok){ return }
    foreach($d in @($Session.Degraded)){
        # Verificar identidad antes de escribir: si el proceso murio y otro heredo su pid, subirle la
        # prioridad "de vuelta" seria tocar a un tercero por error.
        if(-not (Test-AXESessionSameProcess -ProcessId ([int]$d.Pid) -Name ([string]$d.Name) -StartTicks ([long]$d.StartTicks))){ continue }
        try { (Get-Process -Id ([int]$d.Pid) -EA Stop).PriorityClass = $d.Prev } catch {}
    }
    Clear-AXESessionJournal   # cerrado en orden: el diario ya no hace falta
    try { [void][AXE.Native]::JobClose($Session.Handle) } catch {}
}

function Watch-AXESession {
    # Impura. Bloquea hasta que el proceso del juego muere (salida automatica). El llamante
    # (CLI) envuelve en try/finally -> Stop. Si AXE muere aqui, el kernel descongela igual.
    param($Session,[int]$PollMs=1000)
    if(-not $Session -or -not $Session.Ok){ return }
    if($PollMs -lt 100){ $PollMs = 100 }
    while(Get-Process -Id ([int]$Session.GamePid) -EA SilentlyContinue){
        Start-Sleep -Milliseconds $PollMs
    }
}

# --- Ciclo de vida no bloqueante para la ventana (spec 2026-07-25) ---------------------------
# La CLI usa Watch-AXESession (bloqueante). La ventana NO puede: colgaria el hilo que atiende el
# puente. El ciclo vive aqui porque es logica de negocio y 48-webbridge no lleva logica; el
# frontend lo mueve sondeando session.status cada 2 s. UNA sesion por proceso AXE (invariante del
# spec A): dos handles romperian lo unico que hace segura la recuperacion, que cerrar EL handle
# descongele TODO.
$script:AXESessionCur   = $null   # sesion viva, o $null
$script:AXESessionEnded = $null   # motivo del ultimo cierre, para que la UI diga por que se apago

function Get-AXESessionCurrent { $script:AXESessionCur }

function Start-AXESessionTracked {
    # Idempotente a proposito: con sesion viva devuelve LA MISMA, no crea un segundo job. La UI no
    # ofrece ON mientras hay sesion, asi que este camino es una red defensiva; se loguea.
    param([string]$GameName)
    if($script:AXESessionCur){
        Write-AXESessionLog 'Sesion: ON ignorado, ya habia una sesion activa (un proceso, un dueno, un handle).' 'WARN'
        return $script:AXESessionCur
    }
    $s = Start-AXESession -GameName $GameName
    if($s -and $s.Ok){
        $script:AXESessionCur = $s; $script:AXESessionEnded = $null
        Write-AXESessionLog ("Sesion ON - juego '{0}' (pid {1}): {2} congelados, {3} fallidos, {4} degradados." -f `
            $s.Game,$s.GamePid,$s.Assigned,$s.Failed,@($s.Degraded).Count)
    }
    $s
}

function Stop-AXESessionTracked {
    # Cierra el handle (el kernel descongela) y restaura prioridades. Guarda el motivo para la UI.
    param([string]$Reason='OFF manual.')
    if(-not $script:AXESessionCur){ return $null }
    $s = $script:AXESessionCur
    Stop-AXESession $s
    $script:AXESessionCur   = $null
    $script:AXESessionEnded = [string]$Reason
    Write-AXESessionLog ("Sesion OFF - {0} Fondo descongelado y prioridades restauradas." -f $Reason)
    $s
}

function Sync-AXESessionTracked {
    # Salida automatica: si el proceso del juego murio, la sesion se cierra AQUI. Lo llama
    # session.status en cada sondeo. Si AXE muere antes de sondear, el kernel descongela igual: lo
    # que se pierde con la ventana cerrada no es la recuperacion, es el aviso.
    if(-not $script:AXESessionCur){ return $null }
    if(-not (Get-Process -Id ([int]$script:AXESessionCur.GamePid) -EA SilentlyContinue)){
        [void](Stop-AXESessionTracked -Reason ("el juego '{0}' se cerro." -f $script:AXESessionCur.Game))
        return $null
    }
    $script:AXESessionCur
}

function Get-AXESessionStatus {
    # PURA sobre su argumento: NO lee la sesion viva (la resuelve el llamante), por eso es testeable
    # headless igual que Get-AXESessionPlan. DTO plano y JSON-seguro, con las mismas lineas que ve la
    # CLI: la honestidad del texto vive en Format-AXESession, no duplicada aqui.
    param($Session,[string]$EndedReason)
    $ended = $(if([string]::IsNullOrWhiteSpace($EndedReason)){ $null } else { [string]$EndedReason })
    $lines = @(Format-AXESession $Session)
    if(-not $Session -or -not $Session.Ok){
        return [pscustomobject]@{
            active=$false; game=$null; gamePid=$null; sessionId=$null
            frozen=0; failed=0; degraded=0; intact=0; elapsedS=$null; startedAt=$null
            reason=$(if($Session){ [string]$Session.Reason } else { $null })
            endedReason=$ended; lines=$lines
        }
    }
    $elapsed = $null
    if($Session.Started){ $elapsed = [int][math]::Max(0, ((Get-Date) - [datetime]$Session.Started).TotalSeconds) }
    [pscustomobject]@{
        active    = $true
        game      = [string]$Session.Game
        gamePid   = [int]$Session.GamePid
        sessionId = [int]$Session.SessionId
        frozen    = [int]$Session.Assigned
        failed    = [int]$Session.Failed
        degraded  = @($Session.Degraded).Count
        intact    = @($Session.Plan.Intacto).Count
        elapsedS  = $elapsed
        startedAt = $(if($Session.Started){ ([datetime]$Session.Started).ToString('HH:mm:ss') } else { $null })
        reason    = $null
        endedReason = $ended
        lines     = $lines
    }
}

function Format-AXESession {
    # PURA. Render compartido CLI/GUI.
    param($Session)
    if(-not $Session){ return @('sin sesion.') }
    if(-not $Session.Ok){ return @("Sesion NO iniciada: $($Session.Reason)") }
    $L = New-Object System.Collections.ArrayList
    [void]$L.Add("Sesion AXE activa - juego: $($Session.Game) (pid $($Session.GamePid), sesion $($Session.SessionId))")
    [void]$L.Add("  Congelados : $($Session.Assigned)  (fallidos: $($Session.Failed))")
    [void]$L.Add("  Degradados : $(@($Session.Degraded).Count)")
    [void]$L.Add("  Intactos   : $(@($Session.Plan.Intacto).Count)")
    [void]$L.Add('  El fondo se descongela al cerrar el juego, al pulsar OFF o si AXE muere (lo garantiza el kernel).')
    @($L)
}
