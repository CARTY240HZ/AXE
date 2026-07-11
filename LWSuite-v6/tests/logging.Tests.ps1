BeforeAll {
    . "$PSScriptRoot\..\src\core\Logging.ps1"
    # Redirect log root to a temp dir for the test
    $script:LWLog = Join-Path $TestDrive 'lw_test.log'
    Set-LWLogPath $script:LWLog
}

Describe 'Write-LWLog' {
    It 'Appends a timestamped INFO line to the log file' {
        Write-LWLog 'test message'
        $content = Get-Content $script:LWLog -Raw
        $content | Should -Match '\[\d{2}:\d{2}:\d{2}\] INFO  test message'
    }

    It 'Respects the Level parameter' {
        Write-LWLog 'danger' 'ERR'
        $content = Get-Content $script:LWLog -Raw
        $content | Should -Match 'ERR   danger'
    }

    It 'Does not throw if log dir missing (creates it)' {
        Remove-Item (Split-Path $script:LWLog) -Recurse -Force -EA SilentlyContinue
        { Write-LWLog 'recreate' } | Should -Not -Throw
    }
}
