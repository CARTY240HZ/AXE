@{
    # Config de PSScriptAnalyzer para AXE. La lee scripts/Invoke-AXETests.ps1 -Lint.
    # Politica: el runner SOLO bloquea el build/CI con diagnosticos de severidad Error.
    # Los Warning informan pero no rompen -> se puede endurecer con el tiempo sin frenar el ship.
    Severity = @('Error', 'Warning')

    # Reglas excluidas: patrones DELIBERADOS de este codebase, no defectos.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',            # la CLI/gate imprime a consola a proposito (UX de terminal)
        'PSUseShouldProcessForStateChangingFunctions', # Apply/Revert de tweaks son el producto; -WhatIf lo cubre el motor
        'PSAvoidUsingEmptyCatchBlock',      # los catch {} best-effort son intencionales (telemetria/SR nunca deben tumbar la GUI)
        'PSUseBOMForUnicodeEncodedFile',    # build.ps1 fuerza UTF-8 sin BOM a proposito
        'PSAvoidUsingPositionalParameters', # helpers cortos (Set-RD $k $n $v) son idiomaticos aqui
        'PSUseSingularNouns'                # nombres del dominio (Get-PowerPlans, Read-Profiles)
    )

    Rules = @{
        PSPlaceOpenBrace           = @{ Enable = $false }  # estilo K&R propio del proyecto
        PSUseConsistentIndentation = @{ Enable = $false }  # modulos densos de una linea (scriptblocks Test/Apply)
    }
}
