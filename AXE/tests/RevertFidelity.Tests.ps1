# Unit - fidelidad del REVERT. Comprueba que deshacer devuelve el estado que habia, no un
# default supuesto. NO ejecuta ningun Apply/Revert: cambiar el plan de energia o el core parking
# de la maquina como efecto secundario de un test es inaceptable. Se inspecciona el CODIGO de los
# scriptblocks, que es donde vivian los tres fallos.
#
# Contexto (auditoria 2026-07-19):
#   AXE tiene DOS capas de restauracion. La normal es el snapshot (Restore-TweakState), que
#   guarda el valor REAL previo. El scriptblock Revert es el fallback. Los tres fallos estaban
#   justo en el borde entre ambas:
#     - rend_ultperf y cpu_park usan powercfg => Test-SnapEligible los EXCLUYE del snapshot, asi
#       que su Revert es el unico camino de vuelta... y escribia valores fijos.
#     - gpu_mmcss si es elegible, pero Import-AXEProfile no usaba el snapshot en NINGUN sentido,
#       asi que por esa via se caia al fallback, que borraba claves de fabrica.
#
# Por que hace falta este fichero y no valen los que ya habia:
#   Catalog.Tests.ps1 valida ESQUEMA (Revert es scriptblock, Apply != Revert). Los tres bugs
#   pasaban ese filtro: eran scriptblocks validos y distintos de Apply.
#   Integration.Tests.ps1 si hace round-trip real, pero exige Test-SnapEligible = true, asi que
#   por construccion no puede cubrir los dos tweaks de powercfg. Y va con -Tag integration.

BeforeAll {
    $script:CAT = New-Object System.Collections.ArrayList
    . "$PSScriptRoot/../src/20-tweaks.ps1"
    $script:AllTweaks = @($script:CAT)

    function Get-Tw { param([string]$Id) $script:AllTweaks | Where-Object Id -eq $Id }

    # Copia de Test-SnapEligible (10-reg-helpers.ps1). Se duplica a posta: cargar el modulo
    # entero arrastraria logging y rutas de datos, y aqui solo hace falta la regla.
    function Test-SnapEligibleLocal($tw){
        $s = "$($tw.Apply)`n$($tw.Revert)"
        foreach($t in 'bcdedit','powercfg','Set-ProcessMitigation','Set-DnsClient'){ if($s -match [regex]::Escape($t)){ return $false } }
        return $true
    }
}

Describe 'Revert sin snapshot: debe capturar, no suponer' -Tag 'unit' {

    It 'rend_ultperf y cpu_park siguen fuera del snapshot (premisa del fix)' {
        # Si un refactor los hiciera elegibles, la captura manual sobraria. Mientras usen
        # powercfg NO lo son, y por tanto la captura es obligatoria.
        (Test-SnapEligibleLocal (Get-Tw 'rend_ultperf')) | Should -BeFalse
        (Test-SnapEligibleLocal (Get-Tw 'cpu_park'))     | Should -BeFalse
    }

    It 'REGRESION rend_ultperf: Apply captura el plan activo previo' {
        $ap = (Get-Tw 'rend_ultperf').Apply.ToString()
        $ap | Should -Match 'PrevPlanGuid'
        $ap | Should -Match 'getactivescheme'
    }

    It 'REGRESION rend_ultperf: Revert usa el plan capturado, no Equilibrado a ciegas' {
        # Antes: 'powercfg /setactive 381b4222-...' incondicional. Ahora Equilibrado solo puede
        # aparecer como fallback explicito, y el camino normal debe leer PrevPlanGuid.
        $rv = (Get-Tw 'rend_ultperf').Revert.ToString()
        $rv | Should -Match 'PrevPlanGuid'
        $rv | Should -Match 'setactive \$prev'
    }

    It 'REGRESION cpu_park: Apply captura el minimo de nucleos previo' {
        (Get-Tw 'cpu_park').Apply.ToString() | Should -Match 'ParkMinCoresPrev'
    }

    It 'REGRESION cpu_park: Revert ya no escribe 0 hardcodeado' {
        # El fallo original: '...0cc5b647-c1df-4637-891a-dec35c318583 0', un default inventado.
        # Windows oculta este ajuste en 'powercfg -q', asi que la suposicion no era verificable
        # ni a mano. Sin valor capturado el Revert debe avisar y NO tocar.
        $rv = (Get-Tw 'cpu_park').Revert.ToString()
        $rv | Should -Not -Match '0cc5b647-c1df-4637-891a-dec35c318583\s+0\b'
        $rv | Should -Match 'ParkMinCoresPrev'
    }
}

Describe 'Revert con snapshot: el fallback no debe empeorar' -Tag 'unit' {

    It 'REGRESION gpu_mmcss: el fallback ya no borra claves de fabrica de la tarea Games' {
        # Verificado en un registro real: la tarea Games trae Affinity, Background Only,
        # Clock Rate, GPU Priority, Priority, Scheduling Category y SFIO Priority. Borrar tres
        # de ellas no restaura nada: deja la tarea sin claves que el sistema espera encontrar.
        $rv = (Get-Tw 'gpu_mmcss').Revert.ToString()
        foreach($v in 'Scheduling Category','SFIO Priority','Background Only'){
            $rv | Should -Not -Match ("Del-RV \`$Games '{0}'" -f [regex]::Escape($v))
        }
    }

    It 'gpu_mmcss sigue siendo elegible para snapshot (la via buena)' {
        (Test-SnapEligibleLocal (Get-Tw 'gpu_mmcss')) | Should -BeTrue
    }
}

Describe 'Import-AXEProfile usa el protocolo de snapshot' -Tag 'unit' {

    BeforeAll {
        $script:ImportSrc = Get-Content "$PSScriptRoot/../src/28-revert-export.ps1" -Raw
    }

    It 'REGRESION: aplicar por perfil CAPTURA el estado previo' {
        # Antes: '& $tw.Apply' pelado, sin poner $capTweak => no se guardaba nada, asi que un
        # revert posterior no tenia de donde restaurar y caia al fallback.
        $script:ImportSrc | Should -Match '\$script:capTweak\s*=\s*\$tw\.Id'
        $script:ImportSrc | Should -Match 'Commit-TweakState'
    }

    It 'REGRESION: revertir por perfil INTENTA el snapshot antes del scriptblock' {
        $script:ImportSrc | Should -Match 'Restore-TweakState'
    }
}

# Cobertura anadida: los otros 7 tweaks fuera de snapshot (bcdedit x4, ProcessMitigation x2,
# Set-DnsClient x1) no tenian NINGUN test de fidelidad -- solo rend_ultperf/cpu_park/gpu_mmcss
# los tenian, que eran justo los que la auditoria 2026-07-19 encontro rotos. Mismo hueco, mismo
# riesgo: si el Revert no invierte de verdad al Apply, aqui es donde se veria.
Describe 'Revert sin snapshot: bcdedit / ProcessMitigation (cobertura previamente ausente)' -Tag 'unit' {

    It '<_> siguen fuera del snapshot (premisa)' -ForEach 'cpu_dyntick','cpu_tsc','ext_hypervisor','ext_dep','ext_cfg','ext_aslr' {
        (Test-SnapEligibleLocal (Get-Tw $_)) | Should -BeFalse
    }

    It 'cpu_dyntick: Revert borra el valor bcd en vez de fijar uno fijo' {
        $rv = (Get-Tw 'cpu_dyntick').Revert.ToString()
        $rv | Should -Match 'deletevalue disabledynamictick'
    }

    It 'cpu_tsc: Revert borra el valor bcd en vez de fijar uno fijo' {
        $rv = (Get-Tw 'cpu_tsc').Revert.ToString()
        $rv | Should -Match 'deletevalue tscsyncpolicy'
    }

    It 'ext_hypervisor: Revert vuelve al default real de Windows (auto), no a un valor inventado' {
        $rv = (Get-Tw 'ext_hypervisor').Revert.ToString()
        $rv | Should -Match 'hypervisorlaunchtype auto'
    }

    It 'ext_dep: Revert vuelve al default real de Windows (OptIn), no a un valor inventado' {
        $rv = (Get-Tw 'ext_dep').Revert.ToString()
        $rv | Should -Match 'nx OptIn'
    }

    It 'ext_cfg: Revert usa -Enable CFG (inverso real de la API), no una copia de Apply' {
        $ap = (Get-Tw 'ext_cfg').Apply.ToString(); $rv = (Get-Tw 'ext_cfg').Revert.ToString()
        $ap | Should -Match '-Disable CFG'
        $rv | Should -Match '-Enable CFG'
    }

    It 'ext_aslr: Revert usa -Enable ForceRelocateImages (inverso real de la API), no una copia de Apply' {
        $ap = (Get-Tw 'ext_aslr').Apply.ToString(); $rv = (Get-Tw 'ext_aslr').Revert.ToString()
        $ap | Should -Match '-Disable ForceRelocateImages'
        $rv | Should -Match '-Enable ForceRelocateImages'
    }
}

Describe 'Revert sin snapshot: net_dns (FIX -- antes asumia DHCP, ahora captura el DNS real previo)' -Tag 'unit' {

    It 'net_dns sigue fuera del snapshot (usa Set-DnsClient)' {
        (Test-SnapEligibleLocal (Get-Tw 'net_dns')) | Should -BeFalse
    }

    It 'REGRESION net_dns: Apply captura el DNS previo antes de sobreescribir' {
        $ap = (Get-Tw 'net_dns').Apply.ToString()
        $ap | Should -Match 'DnsServersPrev'
        $ap | Should -Match 'Get-DnsClientServerAddress'
    }

    It 'REGRESION net_dns: Revert usa el DNS capturado cuando existe, no ResetServerAddresses a ciegas' {
        # Antes: 'Set-DnsClientServerAddress ... -ResetServerAddresses' incondicional, que perdia
        # un DNS manual propio (ISP, Pi-hole, servidor corporativo) sin avisar y sin poder recuperarlo.
        $rv = (Get-Tw 'net_dns').Revert.ToString()
        $rv | Should -Match 'DnsServersPrev'
        $rv | Should -Match "ServerAddresses \(\`$p -split ','\)"
    }

    It 'net_dns: Revert solo cae a ResetServerAddresses si no hay valor capturado o si era automatico' {
        $rv = (Get-Tw 'net_dns').Revert.ToString()
        $rv | Should -Match "-eq '\(auto\)'"
    }
}
