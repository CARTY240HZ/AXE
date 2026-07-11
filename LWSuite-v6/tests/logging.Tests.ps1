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

    It 'Recreates missing log dir and writes the line (Set-LWLogPath can point anywhere)' {
        Remove-Item (Split-Path $script:LWLog) -Recurse -Force -EA SilentlyContinue
        Write-LWLog 'recreate'
        # The logger must recreate the parent dir and actually write
        Test-Path $script:LWLog | Should -BeTrue
        (Get-Content $script:LWLog -Raw) | Should -Match 'recreate'
    }
}
