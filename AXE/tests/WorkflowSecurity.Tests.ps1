# Unit — security contracts for GitHub Actions supply-chain boundaries.
# Static only: no workflow is executed here.

Describe 'Workflow security contracts' -Tag 'unit','security' {
    BeforeAll {
        # tests/ lives at repo/AXE/tests. Workflows live at repo/.github/workflows.
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $script:CI      = Get-Content (Join-Path $repoRoot '.github/workflows/ci.yml') -Raw
        $script:Release = Get-Content (Join-Path $repoRoot '.github/workflows/release.yml') -Raw
        $script:Publish = (($script:Release -split '(?m)^\s+publish:\s*$')[1])
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

    It 'CI checkout never persists the repository token' {
        $script:CI | Should -Match '(?s)actions/checkout@[0-9a-fA-F]{40}.*?persist-credentials:\s*false'
    }

    It 'release defaults to read-only and isolates write permissions to tag publish' {
        $script:Release | Should -Match '(?ms)^permissions:\s*\r?\n\s+contents:\s*read\b'
        $script:Release | Should -Match '(?ms)^\s+publish:\s*\r?\n\s+if:\s*startsWith\(github\.ref,\s*''refs/tags/v''\)'
        $script:Release | Should -Match '(?ms)^\s+publish:\s*.*?^\s+permissions:\s*\r?\n\s+contents:\s*write\b'
        $script:Release | Should -Match '(?ms)^\s+publish:\s*.*?^\s+permissions:.*?^\s+id-token:\s*write\b'
        $script:Release | Should -Match '(?ms)^\s+publish:\s*.*?^\s+permissions:.*?^\s+attestations:\s*write\b'
    }

    It 'signing secrets are only referenced by tag-gated steps' {
        $script:Release | Should -Match "if: startsWith\(github\.ref, 'refs/tags/v'\)\s*\r?\n\s*id: cert"
        $script:Release | Should -Match "if: startsWith\(github\.ref, 'refs/tags/v'\)\s*\r?\n\s*env:\s*\r?\n\s*PFX_PATH"
        $script:Release | Should -Match '\$\{\{ secrets\.AXE_CODESIGN_PFX_BASE64 \}\}'
        $script:Release | Should -Match '\$\{\{ secrets\.AXE_CODESIGN_PFX_PASSWORD \}\}'
        $script:Release | Should -Match "if: \$\{\{ !startsWith\(github\.ref, 'refs/tags/v'\) \}\}"
    }

    It 'privileged publish does not checkout repository code' {
        $script:Publish | Should -Not -Match 'actions/checkout@'
        $script:Publish | Should -Match 'Download immutable release bundle'
        $script:Publish | Should -Match 'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093'
    }
}
