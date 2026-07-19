# Unit — integridad del catalogo. NO toca registro (solo carga las definiciones).
# 20-tweaks.ps1 + 23-defender.ps1 definen Add-Tweak, $script:CAT y Get-BlockReason;
# los scriptblocks Test/Apply/Revert no se ejecutan al cargar.
#
# Pester separa DISCOVERY (evalua -ForEach) de RUN (ejecuta It/BeforeAll). Por eso el
# catalogo se carga a nivel top (discovery, alimenta -ForEach) Y en BeforeAll (run, para
# los It sin -ForEach y la whitelist).

$script:CAT = New-Object System.Collections.ArrayList
. "$PSScriptRoot/../src/20-tweaks.ps1"
. "$PSScriptRoot/../src/23-defender.ps1"
$AllTweaks = @($script:CAT)

BeforeAll {
    $script:CAT = New-Object System.Collections.ArrayList
    . "$PSScriptRoot/../src/20-tweaks.ps1"
    . "$PSScriptRoot/../src/23-defender.ps1"
    $script:AllTweaks = @($script:CAT)
    $script:KnownReq  = @('MinRam','Desktop','NotLaptop','NotHybrid','AC','Wired','NotHome','Nvidia','WinVer','WinBuild','CpuArch','CpuVendor','HAGS','TamperOff','Defender','NotSMode')
}

Describe 'Catalogo AXE' -Tag 'unit' {

    It 'tiene masa critica (>=60 tweaks)' {
        $script:AllTweaks.Count | Should -BeGreaterOrEqual 60
    }

    It 'ids unicos' {
        ($script:AllTweaks.Id | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
    }

    It '<_.Id> tiene las 10 claves requeridas' -ForEach $AllTweaks {
        $names = $_.PSObject.Properties.Name
        foreach ($k in 'Id','Cat','Tier','Reboot','Name','Desc','Requires','Test','Apply','Revert') {
            $names | Should -Contain $k
        }
    }

    It '<_.Id> Tier en {0,1,2}' -ForEach $AllTweaks {
        $_.Tier | Should -BeIn 0,1,2
    }

    It '<_.Id> Test/Apply/Revert son scriptblocks' -ForEach $AllTweaks {
        $_.Test   | Should -BeOfType scriptblock
        $_.Apply  | Should -BeOfType scriptblock
        $_.Revert | Should -BeOfType scriptblock
    }

    It '<_.Id> Apply != Revert (revert no no-op)' -ForEach ($AllTweaks | Where-Object Id -ne 'svc_remotereg') {
        $_.Apply.ToString() | Should -Not -Be $_.Revert.ToString()
    }

    It '<_.Id> Source declarado bien formado' -ForEach ($AllTweaks | Where-Object { $_.PSObject.Properties['Source'] -and $_.Source }) {
        $_.Source | Should -Match '^https?://'
    }

    It '<_.Id> sin claves Requires fabricadas (whitelist §3.2)' -ForEach $AllTweaks {
        if ($_.Requires -is [hashtable]) {
            foreach ($k in $_.Requires.Keys) { $k | Should -BeIn $script:KnownReq }
        }
    }
}

# La deuda se calcula UNA vez en discovery y alimenta el -ForEach de abajo.
$SourceDebt = @($AllTweaks | Where-Object { -not $_.PSObject.Properties['Source'] -or -not $_.Source })

Describe 'Deuda de procedencia (§12 anti-patron #12)' -Tag 'sourcedebt' {
    # ANTES: '-Skip -ForEach (Tier -in 0,1)' listaba los 64 tweaks Tier 0/1 ENTEROS, tuvieran
    # Source o no, y como -Skip impide que el assert corra, el listado no distinguia deuda de
    # no-deuda: 64 skipped constantes daban la misma senal con 0 pendientes que con 64. Ademas
    # Tier 2 quedaba fuera del filtro, o sea que el tier que apaga ASLR/CFG/DEP/VBS era el unico
    # sin rastreo. Ahora el -ForEach ya filtra por 'sin Source', asi que lo listado ES la deuda
    # y el recuento de skipped baja segun se rellena.
    # Dos trampas de Pester aqui, las dos silenciosas:
    #  1. '-Skip' NO expande el nombre: el test nunca corre, asi que la plantilla se queda
    #     literal ('<Id> ...') y el listado no dice QUE tweak falta. Por eso se usa
    #     Set-ItResult -Skipped: el test SI corre (el nombre expande) y luego se auto-marca
    #     skipped, que sigue sin romper CI.
    #  2. '<Id>' solo expande para entradas hashtable; el catalogo son PSCustomObject, donde
    #     hay que escribir '<_.Id>'. Con '<Id>' el nombre salia '$null'.
    It '<_.Id> (Tier <_.Tier>) sin Source' -ForEach $SourceDebt {
        Set-ItResult -Skipped -Because 'deuda de procedencia pendiente (auditoria §5)'
    }

    # Tier 2 SI bloquea. Un tweak que apaga una mitigacion del sistema sin fuente citable no es
    # auditable, y es justo donde el coste de equivocarse es mayor. Trinquete: hoy la deuda
    # Tier 2 es 0; esto la mantiene en 0 en vez de dejarla volver en silencio.
    It 'ningun Tier 2 sin Source (trinquete)' {
        $t2 = @($script:AllTweaks | Where-Object {
            $_.Tier -eq 2 -and (-not $_.PSObject.Properties['Source'] -or -not $_.Source)
        })
        $t2.Id -join ', ' | Should -BeNullOrEmpty
    }
}
