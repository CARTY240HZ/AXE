# Unit — security contracts for GitHub Actions supply-chain boundaries.
# Static only: no workflow is executed here.

Describe 'Workflow security contracts' -Tag 'unit','security' {
    BeforeAll {
        $script:CI      = Get-Content "$PSScriptRoot/../.github/workflows/ci.yml" -Raw
        $script:Release = Get-Content "$PSScriptRoot/../.github/workflows/release.yml" -Raw
    }

    It 'all third-party actions are pinned to a full commit SHA' {
        $uses = @(
            [regex]::Matches($script:CI,      '(?m)^\s*-\s*uses:\s*([^\s#]+)')    | ForEach-Object { $_.Groups[1].Value }
            [regex]::Matches($script:Release, '(?m)^\s*-\s*uses:\s*([^\s#]+)') | ForEach-Object { $_.Groups[1].Value }
        )
        $uses.Count | Should -BeGreaterThan 0
        foreach($u in $uses){ $u | Should -Match '@[0-9a-fA-F]{40}$' }
    }

    It 'CI has read-only repository permissions' {
        $script:CI | Should -Match '(?ms)^permissions:\s*\r?\n\s+contents:\s*read\b'
        $script:CI | Should -Not -Match '(?m)^\s+contents:\s*write\b'
    }

    It 'release defaults to read-only and isolates write permissions to tag publish' {
        $script:Release | Should -Match '(?ms)^permissions:\s*\r?\n\s+contents:\s*read\b'
        $script:Release | Should -Match '(?ms)^\s+publish:\s*\r?\n\s+if:\s*startsWith\(github\.ref,\s*''refs/tags/v''\)'
        $script:Release | Should -Match '(?ms)^\s+publish:\s*.*?^\s+permissions:\s*\r?\n\s+contents:\s*write\b'
        $script:Release | Should -Match '(?ms)^\s+publish:\s*.*?^\s+permissions:.*?^\s+id-token:\s*write\b'
        $script:Release | Should -Match '(?ms)^\s+publish:\s*.*?^\s+permissions:.*?^\s+attestations:\s*write\b'
    }

    It 'privileged publish does not checkout repository code' {
        $pub = ($script:Release -split "`n") | Select-String -Pattern '^\s+publish:'
        $pub | Should -Not -BeNullOrEmpty
        $script:Release | Should -Match '(?s)publish:.*?Download immutable release bundle.*?actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
    }
}
