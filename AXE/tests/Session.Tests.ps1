# Unit - planificador PURO del daemon de sesion (40-session.ps1). Sin hardware, sin kernel:
# Get-AXESessionPlan recibe hechos sinteticos y se comprueba el reparto en los tres niveles.
# El freeze real (Job Object) NO se testea aqui - pide hardware y una version concreta de
# Windows; se valida a mano (ver spec 2026-07-20, "Verificacion manual"). Mismo criterio que
# Fps.Tests documenta que no cubre que PresentMon enganche un juego.

BeforeAll {
    . "$PSScriptRoot/../src/40-session.ps1"

    # Sesion interactiva sintetica = 1. Fabrica de hechos {Pid,Name,SessionId,Path}.
    function New-Proc($procId, $name, $sid = 1) {
        [pscustomobject]@{ Pid = [int]$procId; Name = [string]$name; SessionId = [int]$sid; Path = $null }
    }
    # Nombres de los procesos de un grupo del plan (helper de asercion).
    function NamesOf($group) { @($group | ForEach-Object { $_.Name }) }
}

Describe 'Get-AXESessionPlan - frontera y protegidos' -Tag 'unit' {

    BeforeEach {
        $script:facts = @(
            (New-Proc 1000 'thegame'       1)
            (New-Proc 1001 'explorer'      1)
            (New-Proc 1002 'dwm'           1)
            (New-Proc 1003 'csrss'         1)
            (New-Proc 1004 'winlogon'      1)
            (New-Proc 1005 'discord'       1)
            (New-Proc 1006 'chrome'        1)
            (New-Proc 1007 'brave'         1)
            (New-Proc 1008 'vivaldi'       1)
            (New-Proc 1009 'opera'         1)
            (New-Proc 1010 'spotify'       1)
            (New-Proc 1011 'EasyAntiCheat' 1)
            (New-Proc 1012 'randomthing'   1)
            (New-Proc 1013 'svchost'       0)   # Session 0: fuera por definicion
            (New-Proc 99   'powershell'    1)   # el propio AXE
        )
        $script:plan = Get-AXESessionPlan -Processes $script:facts -GamePid 1000 -GameName 'thegame' -SelfPid 99 -SessionId 1
    }

    It 'un proceso de Session 0 nunca sale como congelable (ni en ningun grupo)' {
        foreach ($g in $script:plan.Intacto, $script:plan.Degradado, $script:plan.Congelado) {
            NamesOf $g | Should -Not -Contain 'svchost'
        }
    }

    It 'dwm/explorer/csrss/winlogon nunca salen como congelables' {
        foreach ($shell in 'dwm', 'explorer', 'csrss', 'winlogon') {
            NamesOf $script:plan.Congelado | Should -Not -Contain $shell
            NamesOf $script:plan.Intacto   | Should -Contain $shell
        }
    }

    It 'el proceso del juego nunca sale como congelable ni degradable' {
        NamesOf $script:plan.Congelado | Should -Not -Contain 'thegame'
        NamesOf $script:plan.Degradado | Should -Not -Contain 'thegame'
        NamesOf $script:plan.Intacto   | Should -Contain 'thegame'
    }

    It 'el propio AXE nunca sale como congelable' {
        NamesOf $script:plan.Congelado | Should -Not -Contain 'powershell'
        NamesOf $script:plan.Intacto   | Should -Contain 'powershell'
    }

    It 'los anti-cheat conocidos nunca salen como congelables' {
        NamesOf $script:plan.Congelado | Should -Not -Contain 'EasyAntiCheat'
        NamesOf $script:plan.Intacto   | Should -Contain 'EasyAntiCheat'
    }

    It 'Discord sale INTACTO, no DEGRADADO (la voz es sensible a latencia)' {
        NamesOf $script:plan.Intacto   | Should -Contain 'discord'
        NamesOf $script:plan.Degradado | Should -Not -Contain 'discord'
    }

    It 'Brave, Vivaldi y Opera salen DEGRADADOS por familia sin estar listados uno a uno' {
        foreach ($b in 'brave', 'vivaldi', 'opera') {
            NamesOf $script:plan.Degradado | Should -Contain $b
        }
    }

    It 'un proceso desconocido de la sesion del usuario sale CONGELADO' {
        NamesOf $script:plan.Congelado | Should -Contain 'randomthing'
    }
}

Describe 'Get-AXESessionPlan - config y casos limite' -Tag 'unit' {

    It 'la config del usuario sobreescribe el default por app' {
        $facts = @( (New-Proc 2000 'thegame' 1), (New-Proc 2001 'chrome' 1), (New-Proc 2002 'randomthing' 1) )
        # chrome (default DEGRADADO) -> forzado a CONGELADO; randomthing (default CONGELADO) -> INTACTO.
        $cfg  = @{ chrome = 'congelado'; randomthing = 'intacto' }
        $plan = Get-AXESessionPlan -Processes $facts -GamePid 2000 -GameName 'thegame' -SelfPid 99 -SessionId 1 -Config $cfg
        NamesOf $plan.Congelado | Should -Contain 'chrome'
        NamesOf $plan.Intacto   | Should -Contain 'randomthing'
    }

    It 'la config NO puede desproteger un proceso duro (shell sigue INTACTO)' {
        $facts = @( (New-Proc 2100 'thegame' 1), (New-Proc 2101 'explorer' 1) )
        $plan = Get-AXESessionPlan -Processes $facts -GamePid 2100 -GameName 'thegame' -SelfPid 99 -SessionId 1 -Config @{ explorer = 'congelado' }
        NamesOf $plan.Congelado | Should -Not -Contain 'explorer'
        NamesOf $plan.Intacto   | Should -Contain 'explorer'
    }

    It 'con la lista de procesos vacia, el plan sale vacio y no revienta' {
        $plan = Get-AXESessionPlan -Processes @() -GamePid 0 -GameName 'x' -SelfPid 1 -SessionId 1
        @($plan.Intacto).Count   | Should -Be 0
        @($plan.Degradado).Count | Should -Be 0
        @($plan.Congelado).Count | Should -Be 0
    }

    It 'SessionId invalido (0) devuelve plan vacio sin clasificar nada' {
        $facts = @( (New-Proc 3000 'randomthing' 1) )
        $plan = Get-AXESessionPlan -Processes $facts -GamePid 0 -GameName 'x' -SelfPid 1 -SessionId 0
        @($plan.Congelado).Count | Should -Be 0
    }

    It 'solo se consideran procesos de la sesion interactiva pedida' {
        $facts = @( (New-Proc 4000 'randomA' 1), (New-Proc 4001 'randomB' 2) )
        $plan = Get-AXESessionPlan -Processes $facts -GamePid 0 -GameName 'x' -SelfPid 99 -SessionId 1
        NamesOf $plan.Congelado | Should -Contain 'randomA'
        NamesOf $plan.Congelado | Should -Not -Contain 'randomB'
    }
}

Describe 'Format-AXESession - render puro' -Tag 'unit' {
    It 'una sesion fallida se explica, no revienta' {
        $lines = Format-AXESession ([pscustomobject]@{ Ok = $false; Reason = 'el juego no esta corriendo.' })
        ($lines -join "`n") | Should -Match 'NO iniciada'
    }
    It 'sin objeto de sesion devuelve una linea, no null' {
        @(Format-AXESession $null).Count | Should -BeGreaterThan 0
    }
}
