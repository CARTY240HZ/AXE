# Integration — corre contra Windows REAL. Tag 'integration' (excluido del job unit).
#
# Dos bloques:
#   1) READ-ONLY  : ejecuta Get-AXEHardware y los Test de todo el catalogo contra el
#                   sistema real. No escribe nada. Detecta Test rotos que el -SelfTest
#                   (que solo valida schema) no puede ver.
#   2) ROUND-TRIP : Apply -> Test -> Restore-TweakState -> valor original, sobre una
#                   whitelist de tweaks SOLO-HKCU. Ejercita el motor de snapshot (H3)
#                   de punta a punta. MUTA EL REGISTRO: requiere AXE_INTEGRATION=1.
#
# Local: $env:AXE_INTEGRATION='1'; Invoke-Pester tests/Integration.Tests.ps1
# CI   : job 'integration' en windows-latest (runner desechable).
#
# Pester separa DISCOVERY (evalua -ForEach) de RUN (BeforeAll). Igual que Catalog.Tests.ps1,
# el catalogo se carga a nivel top (discovery) Y en BeforeAll (run).

$script:CAT = New-Object System.Collections.ArrayList
. "$PSScriptRoot/../src/20-tweaks.ps1"
. "$PSScriptRoot/../src/23-defender.ps1"
$AllTweaks    = @($script:CAT)
$RoundTripIds = @(
    'sys_menudelay','sys_autoend','sys_startdelay','sys_fse',
    'sys_gamebar','sys_bing','priv_ads','priv_tips','rend_visualfx'
)

BeforeAll {
    $script:srcDir = "$PSScriptRoot/../src"
    # 05-core crea <src>/AXE/ (datos + log). Anotamos si ya existia para limpiar despues.
    $script:dataDir        = Join-Path $script:srcDir 'AXE'
    $script:dataPreExisted = Test-Path $script:dataDir

    . "$script:srcDir/05-core.ps1"
    . "$script:srcDir/10-reg-helpers.ps1"
    $script:CAT = New-Object System.Collections.ArrayList
    . "$script:srcDir/20-tweaks.ps1"
    . "$script:srcDir/23-defender.ps1"

    $script:HW        = Get-AXEHardware
    $script:AllTweaks = @($script:CAT)
}

AfterAll {
    # Limpia los datos que 05-core genero dentro de /src si no estaban antes.
    if (-not $script:dataPreExisted -and (Test-Path $script:dataDir)) {
        Remove-Item $script:dataDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Integracion — deteccion de hardware real' -Tag 'integration' {

    It 'Get-AXEHardware no lanza y devuelve el objeto completo' {
        $script:HW | Should -Not -BeNullOrEmpty
        foreach ($f in 'CpuName','Cores','Threads','RamGB','BuildNumber','CpuArch','CpuVendor') {
            $script:HW.PSObject.Properties.Name | Should -Contain $f
        }
    }

    It 'los campos numericos tienen valores plausibles' {
        [int]$script:HW.Cores       | Should -BeGreaterThan 0
        [int]$script:HW.Threads     | Should -BeGreaterOrEqual ([int]$script:HW.Cores)
        [double]$script:HW.RamGB    | Should -BeGreaterThan 0
        [int]$script:HW.BuildNumber | Should -BeGreaterThan 9000
    }

    It 'los campos booleanos de ecosistema son bool (no null)' {
        foreach ($f in 'IsLaptop','IsHybrid','HasNvidia','IsWifi','IsHome','IsWin11','HasDefender','IsTamperProtected','IsSMode','SupportsHAGS','IsSSD') {
            $script:HW.$f | Should -BeOfType [bool] -Because "$f alimenta el gating de la seccion 3.2"
        }
    }

    It 'Get-AXEEnvBanner produce el banner con HW real' {
        $b = Get-AXEEnvBanner
        $b | Should -Not -BeNullOrEmpty
        $b | Should -Match 'aplicables'
    }
}

Describe 'Integracion — Test de catalogo contra el sistema (read-only)' -Tag 'integration' {

    It '<Id> Test se ejecuta sin lanzar y devuelve algo booleanizable' -ForEach $AllTweaks {
        $script:tCache = @{}
        $tw = $script:AllTweaks | Where-Object Id -eq $_.Id
        $r  = $null
        { $script:r = & $tw.Test } | Should -Not -Throw
        { [bool]$script:r }        | Should -Not -Throw
    }

    It '<Id> Get-BlockReason devuelve null o un motivo en texto' -ForEach $AllTweaks {
        $tw     = $script:AllTweaks | Where-Object Id -eq $_.Id
        $reason = Get-BlockReason $tw
        if ($null -ne $reason) { $reason | Should -BeOfType [string] }
    }
}

Describe 'Integracion — round-trip Apply/Revert real (muta HKCU)' -Tag 'integration' {

    # -Skip salvo AXE_INTEGRATION=1: correr esto en la maquina del usuario le tocaria el
    # registro de verdad. En CI (runner desechable) el job lo activa explicitamente.
    It '<_> Apply deja Test en true y Restore-TweakState devuelve el valor original' -Skip:($env:AXE_INTEGRATION -ne '1') -ForEach $RoundTripIds {
        $id = $_
        $tw = $script:AllTweaks | Where-Object Id -eq $id
        $tw | Should -Not -BeNullOrEmpty -Because 'la whitelist debe seguir al catalogo'
        Test-SnapEligible $tw | Should -BeTrue -Because 'la whitelist es solo-registro'

        # Estado limpio: sin snapshot previo de este id.
        Remove-TweakState $id

        $script:capTweak = $id
        try { & $tw.Apply } finally { $script:capTweak = $null }
        Commit-TweakState $id

        $script:tCache = @{}
        [bool](& $tw.Test) | Should -BeTrue -Because "$id acaba de aplicarse"

        # Los records guardan el valor PREVIO real de cada clave que Apply toco.
        $recs = @((Read-StateBak)[$id])
        $recs.Count | Should -BeGreaterThan 0 -Because 'Apply debe capturar al menos una clave'

        (Restore-TweakState $id) | Should -BeTrue

        foreach ($r in $recs) {
            $now = Get-RV $r.P $r.N
            if ($r.Had) { "$now" | Should -Be "$($r.V)" -Because "$($r.P)\$($r.N) debe volver a su valor original" }
            else        { $now   | Should -BeNullOrEmpty -Because "$($r.P)\$($r.N) no existia antes" }
        }

        (Read-StateBak).ContainsKey($id) | Should -BeFalse -Because 'Restore limpia el snapshot'
    }
}
