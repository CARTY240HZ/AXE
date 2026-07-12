BeforeAll {
    . "$PSScriptRoot\..\src\core\Logging.ps1"
    . "$PSScriptRoot\..\src\core\Config.ps1"
}

Describe 'Import-LWConfig' {
    It 'Loads tweaks.json and returns a hashtable with tweaks key' {
        $cfg = Import-LWConfig "$PSScriptRoot\..\config"
        $cfg.tweaks.PSObject.Properties.Name | Should -Contain 'cpu_prio'
    }

    It 'Verifies manifest hash and throws on tamper' {
        $cfgDir = "$PSScriptRoot\..\config"
        $orig = Get-Content "$cfgDir\tweaks.json" -Raw
        try {
            Set-Content "$cfgDir\tweaks.json" -Value ($orig + ' ') -NoNewline
            { Import-LWConfig $cfgDir } | Should -Throw
        } finally {
            Set-Content "$cfgDir\tweaks.json" -Value $orig -NoNewline
        }
    }

    It 'Fails cleanly if manifest.json is missing' {
        $cfgDir = "$TestDrive\empty"
        New-Item -ItemType Directory -Path $cfgDir | Out-Null
        { Import-LWConfig $cfgDir } | Should -Throw
    }
}
