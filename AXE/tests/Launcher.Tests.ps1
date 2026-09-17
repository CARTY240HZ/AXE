Describe 'Launcher AXE.bat' -Tag 'unit' {
    It 'el texto del launcher soporta dist y release-root' {
        $bat = Get-Content (Join-Path $PSScriptRoot '..\AXE.bat') -Raw
        $bat | Should -Match 'AXEENGINE=%~dp0dist\\AXE\.ps1'
        $bat | Should -Match 'if not exist "%AXEENGINE%" set "AXEENGINE=%~dp0AXE\.ps1"'
    }

    It 'los modos de lectura estan marcados como headless antes del UAC' {
        $bat = Get-Content (Join-Path $PSScriptRoot '..\AXE.bat') -Raw
        ($bat.IndexOf('set "HEADLESS=0"')) | Should -BeGreaterThan -1
        ($bat.IndexOf('if "%HEADLESS%"=="0"')) | Should -BeGreaterThan ($bat.IndexOf('set "HEADLESS=0"'))
    }
}
