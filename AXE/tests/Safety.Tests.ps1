# Unit -- New-AXERestorePoint / $script:RestorePointScript (34-safety.ps1). Sin tests hasta ahora
# pese a ser el codigo que protege al usuario si un tweak sale mal: es justo donde menos margen de
# error deberia haber.
#
# Misma disciplina que RevertFidelity.Tests.ps1: Checkpoint-Computer, Enable-ComputerRestore y el
# bucle VSS/swprv tocan el sistema real (crean un punto de restauracion, arrancan servicios,
# escriben en HKLM). Nada de eso se EJECUTA aqui salvo la rama AXE_NOSR, que por diseno es la unica
# sin efectos secundarios (New-AXERestorePoint retorna antes de tocar nada). El resto se verifica
# inspeccionando el CODIGO del scriptblock, no corriendolo.
BeforeAll {
    $env:AXE_LIBONLY = '1'
    . "$PSScriptRoot/../src/34-safety.ps1"
}

Describe 'New-AXERestorePoint -- guard AXE_NOSR (unico camino sin efectos secundarios, se ejecuta de verdad)' -Tag 'unit' {

    It 'con AXE_NOSR devuelve fallback SIN tocar VSS/registro/Checkpoint-Computer' {
        $env:AXE_NOSR = '1'
        try {
            $r = New-AXERestorePoint -Desc 'test'
            $r.Status  | Should -Be 'fallback'
            $r.Message | Should -Match 'AXE_NOSR'
        } finally {
            Remove-Item Env:\AXE_NOSR -ErrorAction SilentlyContinue
        }
    }

    It 'sin AXE_NOSR, New-AXERestorePoint SI intenta el camino real (premisa de la guard de arriba)' {
        # No se ejecuta (tocaria el sistema real); solo confirma que el guard es la UNICA salida
        # temprana -- si esta linea desaparece, el test de arriba deja de probar nada real.
        $src = (Get-Command New-AXERestorePoint).ScriptBlock.ToString()
        $src | Should -Match "AXE_NOSR.*return"
    }
}

Describe 'New-AXERestorePoint -- contrato "best-effort, NUNCA lanza" (inspeccion de codigo)' -Tag 'unit' {

    It 'el cuerpo entero esta envuelto en try/catch (una excepcion real no debe propagar)' {
        $src = (Get-Command New-AXERestorePoint).ScriptBlock.ToString()
        $src | Should -Match 'try\s*\{'
        $src | Should -Match 'catch\s*\{'
    }

    It 'la rama catch devuelve Status=error en vez de relanzar' {
        $src = (Get-Command New-AXERestorePoint).ScriptBlock.ToString()
        $src | Should -Match "Status='error'"
    }
}

Describe '$script:RestorePointScript -- deteccion de anti-cheat (inspeccion de codigo, no se ejecuta)' -Tag 'unit' {

    It 'reconoce los 4 drivers de anti-cheat documentados (EAC, BattlEye BEDaisy, BattlEye, Vanguard)' {
        $src = $script:RestorePointScript.ToString()
        foreach ($needle in 'EasyAntiCheat','BEDaisy','BattlEye','vgk') {
            $src | Should -Match ([regex]::Escape($needle))
        }
    }

    It 'si detecta anti-cheat, retorna ANTES de tocar VSS/Checkpoint-Computer' {
        # El bloque anticheat hace 'return "ANTICHEAT: ..."' antes de la primera linea que toca
        # VSS/swprv/Enable-ComputerRestore. Si algun refactor moviera el chequeo despues, un juego
        # con anti-cheat activo podria acabar con un checkpoint a medio crear en vez de un aviso.
        $src = $script:RestorePointScript.ToString()
        $anticheatIdx = $src.IndexOf('ANTICHEAT:')
        $vssIdx       = $src.IndexOf('Enable-ComputerRestore')
        $anticheatIdx | Should -BeGreaterThan -1
        $vssIdx       | Should -BeGreaterThan -1
        $anticheatIdx | Should -BeLessThan $vssIdx
    }
}

Describe '$script:RestorePointScript -- crear Y verificar (auditoria 2026-07-19 §4.2 #5)' -Tag 'unit' {

    It 'no se conforma con que Checkpoint-Computer no lance: confirma que el punto aterrizo' {
        # Checkpoint-Computer no lanza aunque el throttle de 24h o VSS bloqueado silencien la
        # creacion -- por eso hace falta releer con Get-ComputerRestorePoint antes de decir OK.
        $src = $script:RestorePointScript.ToString()
        $src | Should -Match 'Checkpoint-Computer'
        $src | Should -Match 'Get-ComputerRestorePoint'
        $src | Should -Match "Where-Object \{ \`$_\.Description -eq \`$desc \}"
    }

    It 'limpia SystemRestorePointCreationFrequency en un finally (no deja el override permanente)' {
        $src = $script:RestorePointScript.ToString()
        $src | Should -Match 'finally\s*\{'
        $src | Should -Match 'Remove-ItemProperty -Path \$rp -Name SystemRestorePointCreationFrequency'
    }
}
