# Unit - estructura de AXE.bat. Un .bat no es Pester-ejecutable como PS1; se comprueba el TEXTO
# fuente, mismo patron que tests/RevertFidelity.Tests.ps1 usa para scriptblocks no ejecutables
# en el gate. La prueba real (GUI no eleva de verdad) es verificacion manual: lanzar AXE.bat sin
# argumentos y comprobar que powershell.exe arranca SIN el dialogo de UAC.
BeforeAll { $script:BatSrc = Get-Content "$PSScriptRoot/../AXE.bat" -Raw }

Describe 'AXE.bat - GUI no eleva de entrada, CLI sin cambios (REGRESION issue #5)' -Tag 'unit' {
    It 'el salto a :gui ocurre ANTES de cualquier "net session"' {
        $iGoto = $script:BatSrc.IndexOf('goto :gui')
        $iNetSession = $script:BatSrc.IndexOf('net session')
        $iGoto | Should -BeGreaterThan -1
        $iNetSession | Should -BeGreaterThan -1
        $iGoto | Should -BeLessThan $iNetSession
    }
    It 'la etiqueta :gui lanza dist\AXE.ps1 sin pasar por Start-Process -Verb RunAs' {
        # NOTA: IndexOf(':gui') a secas encontraria antes la ocurrencia de ":gui" dentro de
        # "goto :gui" (mas arriba en el fichero) que la propia ETIQUETA ":gui" (que empieza de
        # linea). Se ancla a inicio de linea (regex multilinea) para apuntar a la etiqueta real.
        $iGui = [regex]::Match($script:BatSrc, '(?m)^:gui').Index
        $iGui | Should -BeGreaterThan -1
        $tail = $script:BatSrc.Substring($iGui)
        $tail | Should -Not -Match 'Verb RunAs'
        $tail | Should -Match 'dist\\AXE\.ps1'
    }
    It 'el camino CLI (antes de :gui) SI sigue teniendo el chequeo de elevacion' {
        $iGui = [regex]::Match($script:BatSrc, '(?m)^:gui').Index
        $iGui | Should -BeGreaterThan -1
        $head = $script:BatSrc.Substring(0, $iGui)
        $head | Should -Match 'net session'
        $head | Should -Match 'Verb RunAs'
    }
}
