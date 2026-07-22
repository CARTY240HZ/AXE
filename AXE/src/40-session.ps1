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
    shell      = @('dwm','explorer','csrss','winlogon','wininit','services','lsass','smss','fontdrvhost','sihost','ctfmon','textinputhost','startmenuexperiencehost','searchhost','searchapp','shellexperiencehost','taskhostw','runtimebroker','dllhost','applicationframehost','systemsettings','lockapp')
    navegador  = @('chrome','brave','msedge','edge','firefox','opera','opera_gx','vivaldi','browser')
    musica     = @('spotify','tidal','deezer','foobar2000','aimp','musicbee')
    mensajeria = @('whatsapp','telegram','signal','slack')
}

function Get-AXESessionProcesses {
    # Impura: lee procesos. NO juzga. Alimenta a Get-AXESessionPlan con hechos planos.
    $out = New-Object System.Collections.ArrayList
    foreach($p in (Get-Process -EA SilentlyContinue)){
        $path = $null; try { $path = $p.Path } catch {}
        [void]$out.Add([pscustomobject]@{
            Pid       = [int]$p.Id
            Name      = [string]$p.ProcessName
            SessionId = [int]$p.SessionId
            Path      = $path
        })
    }
    @($out)
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

function Read-AXESessionOverrides {
    # Overrides por-app {nombre->nivel}. La persistencia (UI de sesion) esta FUERA de este spec
    # (CLI primero). El planificador puro ya acepta -Config y esta testeado con overrides; aqui
    # se devuelve vacio hasta que exista la UI que los escriba. Honesto: no inventa config.
    @{}
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
            $pr.PriorityClass = 'BelowNormal'
            [void]$degraded.Add([pscustomobject]@{ Pid=[int]$p.Pid; Prev=[string]$prev })
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
        try { (Get-Process -Id ([int]$d.Pid) -EA Stop).PriorityClass = $d.Prev } catch {}
    }
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
