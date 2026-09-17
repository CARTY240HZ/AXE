# Unit — policy checks for the post-catalog quality gate.
# No tweak Test/Apply/Revert scriptblock is executed here; we only verify that
# the final catalog metadata and recommendation sets are conservative.

BeforeAll {
    $script:CAT = New-Object System.Collections.ArrayList
    . "$PSScriptRoot/../src/20-tweaks.ps1"
    . "$PSScriptRoot/../src/21-tweak-quality.ps1"
    $script:AllTweaks = @($script:CAT)
}

Describe 'Tweak quality gate' -Tag 'unit','tweak-quality' {
    It 'cpu_mmcss uses the documented minimum effective value of 10' {
        $t = $script:AllTweaks | Where-Object Id -eq 'cpu_mmcss'
        $t.Tier | Should -Be 1
        $t.PlaceboLikely | Should -Be $false
        $t.Test.ToString()  | Should -Match "'SystemResponsiveness'\) -eq 10"
        $t.Apply.ToString() | Should -Match "'SystemResponsiveness' 10"
        $t.Desc | Should -Match 'SystemResponsiveness=10'
        $t.Desc | Should -Not -Match 'SystemResponsiveness=0'
    }

    It 'net_ctcp is never a default recommendation' {
        $t = $script:AllTweaks | Where-Object Id -eq 'net_ctcp'
        $t.Tier | Should -Be 2
        $t.PlaceboLikely | Should -Be $true
        @($script:RECRULES.Keys) | Should -Not -Contain 'net_ctcp'
        @($script:LATRULES.Keys) | Should -Not -Contain 'net_ctcp'
    }

    It 'HAGS is manual/feature-specific, not universal baseline' {
        @($script:RECCORE) | Should -Not -Contain 'gpu_hags'
        ($script:AllTweaks | Where-Object Id -eq 'gpu_hags').Tier | Should -Be 1
    }

    It 'MPO disable is troubleshooting-only' {
        $t = $script:AllTweaks | Where-Object Id -eq 'rend_mpo'
        $t.Tier | Should -Be 2
        @($script:RECCORE) | Should -Not -Contain 'rend_mpo'
        $t.Desc | Should -Match 'NO es una optimizacion universal'
    }

    It 'privacy-only Recall tweak is not counted as performance baseline' {
        @($script:RECCORE) | Should -Not -Contain 'priv_recall'
        $script:AllTweaks.Id | Should -Contain 'priv_recall'
    }
}
