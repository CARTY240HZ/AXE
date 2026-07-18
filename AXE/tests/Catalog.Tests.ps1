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

    It '<Id> tiene las 10 claves requeridas' -ForEach $AllTweaks {
        $names = $_.PSObject.Properties.Name
        foreach ($k in 'Id','Cat','Tier','Reboot','Name','Desc','Requires','Test','Apply','Revert') {
            $names | Should -Contain $k
        }
    }

    It '<Id> Tier en {0,1,2}' -ForEach $AllTweaks {
        $_.Tier | Should -BeIn 0,1,2
    }

    It '<Id> Test/Apply/Revert son scriptblocks' -ForEach $AllTweaks {
        $_.Test   | Should -BeOfType scriptblock
        $_.Apply  | Should -BeOfType scriptblock
        $_.Revert | Should -BeOfType scriptblock
    }

    It '<Id> Apply != Revert (revert no no-op)' -ForEach ($AllTweaks | Where-Object Id -ne 'svc_remotereg') {
        $_.Apply.ToString() | Should -Not -Be $_.Revert.ToString()
    }

    It '<Id> Source declarado bien formado' -ForEach ($AllTweaks | Where-Object { $_.PSObject.Properties['Source'] -and $_.Source }) {
        $_.Source | Should -Match '^https?://'
    }

    It '<Id> sin claves Requires fabricadas (whitelist §3.2)' -ForEach $AllTweaks {
        if ($_.Requires -is [hashtable]) {
            foreach ($k in $_.Requires.Keys) { $k | Should -BeIn $script:KnownReq }
        }
    }
}

Describe 'Deuda de procedencia (§12 anti-patron #12)' -Tag 'sourcedebt' {
    # Excluido de CI (Tag sourcedebt): rastrea, no bloquea. El catalogo legacy aun
    # tiene tweaks Tier 0/1 sin Source; se van rellenando por auditoria (§5).
    It '<Id> Tier 0/1 tiene Source' -ForEach ($AllTweaks | Where-Object { $_.Tier -in 0,1 }) {
        $_.Source | Should -Not -BeNullOrEmpty
    }
}
