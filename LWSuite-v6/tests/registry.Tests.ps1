BeforeAll {
    . "$PSScriptRoot\..\src\core\Logging.ps1"
    . "$PSScriptRoot\..\src\core\Registry.ps1"
    # Use a throwaway HKCU subkey for safe round-trip testing
    $script:tk = 'HKCU:\Software\LWSuiteTest'
}

Describe 'Registry helpers' {
    AfterEach { Remove-Item $script:tk -Recurse -Force -EA SilentlyContinue }

    It 'Set-RD then Get-RV round-trips a DWord' {
        Set-RD $script:tk 'MyVal' 42
        Get-RV $script:tk 'MyVal' | Should -Be 42
    }

    It 'Get-RV returns $null for missing value (no throw)' {
        Get-RV $script:tk 'NoSuch' | Should -BeNullOrEmpty
    }

    It 'Del-RV removes a value' {
        Set-RD $script:tk 'Gone' 1
        Del-RV $script:tk 'Gone'
        Get-RV $script:tk 'Gone' | Should -BeNullOrEmpty
    }

    It 'Set-RS stores a String' {
        Set-RS $script:tk 'Str' 'hello'
        Get-RV $script:tk 'Str' | Should -Be 'hello'
    }
}

Describe 'Set-LWService' {
    It 'Logs WARN and does not throw for a non-existent service' {
        { Set-LWService 'DefinitelyNotAService_xyz' 'disabled' } | Should -Not -Throw
    }
}
