# Unit -- backup/restore de startup (15-startup.ps1). Read-StartupBackup/Repair-StartupBackup solo
# tocan un JSON propio de AXE (seguro de ejecutar en un test). Get-Autoruns/Disable-Autorun/
# Restore-Autorun tocan las claves Run REALES del registro (HKCU/HKLM): no se ejecutan aqui -- se
# cubren por inspeccion de codigo, mismo criterio que RevertFidelity.Tests.ps1 usa para los tweaks
# fuera de snapshot que tampoco se pueden correr sin mutar el sistema real.
BeforeAll {
    . "$PSScriptRoot/../src/05-core.ps1"
    . "$PSScriptRoot/../src/15-startup.ps1"
    $script:TestBak = Join-Path ([System.IO.Path]::GetTempPath()) ("axe_test_runbak_{0}.json" -f ([guid]::NewGuid().ToString('N')))
}

Describe 'Read-StartupBackup -- backup corrupto se pone en cuarentena, no se pierde en silencio (REGRESION)' -Tag 'unit' {
    BeforeEach {
        $script:RunBak = $script:TestBak
        Remove-Item $script:RunBak -ErrorAction SilentlyContinue
        Remove-Item "$($script:RunBak).corrupt" -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item $script:RunBak -ErrorAction SilentlyContinue
        Remove-Item "$($script:RunBak).corrupt" -ErrorAction SilentlyContinue
    }

    It 'JSON valido se lee normal (linea base)' {
        @([pscustomobject]@{Hive='HKCU';Path='x';Name='y';Value='z';Kind='String'}) |
            ConvertTo-Json -Depth 5 | Set-Content $script:RunBak -Encoding UTF8
        # @() en el sitio de la llamada: el propio Disable-Autorun/Restore-Autorun lo hacen igual --
        # PowerShell desenrolla un array de 1 elemento al devolverlo por el pipeline.
        $r = @(Read-StartupBackup)
        $r.Count  | Should -Be 1
        $r[0].Name | Should -Be 'y'
    }

    It 'REGRESION: JSON corrupto se renombra a .corrupt en vez de perderse en silencio' {
        # Antes: 'catch { return @() }' -- el fichero corrupto se quedaba tal cual y Disable-Autorun
        # lo SOBREESCRIBIA con solo la entrada nueva en la siguiente llamada, perdiendo para siempre
        # cualquier backup previo recuperable.
        Set-Content -Path $script:RunBak -Value '{ esto no es json valido' -Encoding UTF8
        $r = Read-StartupBackup
        $r.Count | Should -Be 0
        Test-Path "$($script:RunBak).corrupt" | Should -BeTrue
        Test-Path $script:RunBak             | Should -BeFalse
    }

    It 'REGRESION: el archivo en cuarentena conserva el contenido original (recuperable a mano)' {
        Set-Content -Path $script:RunBak -Value '{ esto no es json valido' -Encoding UTF8
        Read-StartupBackup | Out-Null
        (Get-Content "$($script:RunBak).corrupt" -Raw) | Should -Match 'esto no es json valido'
    }
}

Describe 'ValueKind del autorun (REG_SZ vs REG_EXPAND_SZ) -- inspeccion de codigo' -Tag 'unit' {
    # Get-Autoruns/Disable-Autorun/Restore-Autorun tocan las claves Run REALES del registro: no se
    # ejecutan en un test unitario (ver cabecera). Se comprueba que el codigo captura y propaga
    # Kind de punta a punta, no que la restauracion contra el registro real salga bien.
    BeforeAll { $script:StartupSrc = Get-Content "$PSScriptRoot/../src/15-startup.ps1" -Raw }

    It 'Get-Autoruns captura GetValueKind, no solo el Value' {
        $script:StartupSrc | Should -Match 'GetValueKind\(\$n\)'
    }

    It 'Disable-Autorun propaga Kind al backup' {
        $script:StartupSrc | Should -Match 'Kind=\$kind'
    }

    It 'REGRESION: Restore-Autorun usa el Kind capturado, ya no fija -PropertyType String a ciegas' {
        # Antes: 'New-ItemProperty ... -PropertyType String' incondicional. Un autorun REG_EXPAND_SZ
        # (rutas con %ProgramFiles% etc., comun) volvia sin expandir tras desactivar+restaurar.
        $script:StartupSrc | Should -Match '-PropertyType \$kind'
    }

    It 'Restore-Autorun cae a String si el backup es de antes del fix (sin Kind)' {
        # Compatibilidad hacia atras: un backup viejo en disco no tiene la propiedad Kind.
        $script:StartupSrc | Should -Match "if\(\`$e\.PSObject\.Properties\['Kind'\]"
    }
}
