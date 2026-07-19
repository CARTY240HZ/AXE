# Unit - GPU por juego (31-gamegpu.ps1).
#
# Que se cubre y por que:
#   1. PARSER. El valor de UserGpuPreferences es una cadena "K=V;" que Windows tambien usa para
#      lo suyo ('AppStatus'). Un parser que se coma o reordene claves ajenas le borra estado al
#      sistema sin avisar. En el registro real hay cadenas que empiezan por ';' y pares sueltos,
#      asi que la tolerancia a basura es requisito, no cortesia.
#   2. PRESERVACION. Es el mismo fallo de clase que la auditoria de revert: escribir la entrada
#      entera en vez de la clave concreta = suponer que lo demas no importa.
#   3. REVERT. Restaura la cadena ORIGINAL capturada, o BORRA si el exe no tenia entrada. Nunca
#      escribe un default. Un exe jamas tocado devuelve 0 y no toca nada.
#
# El test SI escribe en HKCU, pero solo bajo nombres sinteticos ('C:\__AXE_TEST_GPU__\...') que
# no existen como ficheros, y los borra en AfterAll. No toca ninguna entrada de juego real:
# machacar la preferencia de GPU del usuario desde un test seria justo el bug que se persigue.

BeforeAll {
    $script:AXEData = Join-Path ([System.IO.Path]::GetTempPath()) ('axe-test-gamegpu-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
    function Write-AXELog($m,$l='INFO'){ }
    . "$PSScriptRoot/../src/10-reg-helpers.ps1"
    . "$PSScriptRoot/../src/31-gamegpu.ps1"

    $script:E1 = 'C:\__AXE_TEST_GPU__\con-estado-previo.exe'
    $script:E2 = 'C:\__AXE_TEST_GPU__\sin-estado-previo.exe'
}

AfterAll {
    foreach($e in @($script:E1,$script:E2)){
        Remove-ItemProperty -Path $script:GpuPrefKey -Name $e -EA SilentlyContinue
        Remove-ItemProperty -Path $script:LayersKey  -Name $e -EA SilentlyContinue
    }
    Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue
}

Describe 'Parser de UserGpuPreferences' -Tag 'unit' {

    It 'roundtrip exacto sobre una cadena real del registro' {
        $raw = 'AppStatus=4096;GpuPreference=2;'
        (ConvertTo-AXEGpuPref (ConvertFrom-AXEGpuPref $raw)) | Should -Be $raw
    }

    It 'tolera la cadena que empieza por ";" que escribe Windows' {
        # Visto tal cual en build 26200: ';SwapEffectUpgradeEnable=1;'
        $h = ConvertFrom-AXEGpuPref ';SwapEffectUpgradeEnable=1;'
        $h.Count | Should -Be 1
        $h['SwapEffectUpgradeEnable'] | Should -Be '1'
    }

    It 'entrada vacia o nula da hashtable vacio, no error' {
        (ConvertFrom-AXEGpuPref $null).Count | Should -Be 0
        (ConvertFrom-AXEGpuPref '').Count    | Should -Be 0
        (ConvertFrom-AXEGpuPref ';;;').Count | Should -Be 0
    }

    It 'descarta pares sin "=" en vez de inventar una clave vacia' {
        $h = ConvertFrom-AXEGpuPref 'basura;GpuPreference=2;=sinclave;'
        $h.Count | Should -Be 1
        $h['GpuPreference'] | Should -Be '2'
    }
}

Describe 'Escritura: no pisar lo que gestiona Windows' -Tag 'unit' {

    It 'preserva AppStatus al forzar GPU y flip model' {
        Set-RS $script:GpuPrefKey $script:E1 'AppStatus=4096;'
        Set-AXEGameGpuPref -Exe $script:E1 -HighPerf $true -FlipModel $true
        $st = Get-AXEGameGpuState $script:E1
        $st.HighPerf  | Should -BeTrue
        $st.FlipModel | Should -BeTrue
        $st.Raw       | Should -Match 'AppStatus=4096'
    }

    It 'apagar HighPerf escribe 0 (delegar en Windows), no borra la clave' {
        Set-AXEGameGpuPref -Exe $script:E1 -HighPerf $false
        (Get-AXEGameGpuState $script:E1).Raw | Should -Match 'GpuPreference=0'
    }

    It 'preserva tokens ajenos de Layers al apagar FSO' {
        Set-RS $script:LayersKey $script:E1 'HIGHDPIAWARE'
        Set-AXEGameFSO -Exe $script:E1 -Disable $true
        $st = Get-AXEGameGpuState $script:E1
        $st.NoFSO     | Should -BeTrue
        $st.RawLayers | Should -Match 'HIGHDPIAWARE'
    }
}

Describe 'Revert: estado real, nunca un default supuesto' -Tag 'unit' {

    It 'restaura la cadena original byte a byte' {
        (Revert-AXEGameGpu $script:E1) | Should -BeGreaterThan 0
        $after = Get-AXEGameGpuState $script:E1
        $after.Raw       | Should -Be 'AppStatus=4096;'
        $after.RawLayers | Should -Be 'HIGHDPIAWARE'
    }

    It 'exe sin entrada previa: revert BORRA, no deja una entrada a medias' {
        (Get-RV $script:GpuPrefKey $script:E2) | Should -BeNullOrEmpty
        Set-AXEGameGpuPref -Exe $script:E2 -HighPerf $true -FlipModel $true
        (Get-AXEGameGpuState $script:E2).HighPerf | Should -BeTrue
        Revert-AXEGameGpu $script:E2 | Out-Null
        (Get-RV $script:GpuPrefKey $script:E2) | Should -BeNullOrEmpty
    }

    It 'exe jamas tocado por AXE: devuelve 0 y no escribe nada' {
        $nunca = 'C:\__AXE_TEST_GPU__\jamas.exe'
        (Revert-AXEGameGpu $nunca) | Should -Be 0
        (Get-RV $script:GpuPrefKey $nunca) | Should -BeNullOrEmpty
    }

    It 'la captura es la PRIMERA, no la de la pasada anterior' {
        # Aplicar dos veces no debe hacer que el "original" pase a ser lo que dejo AXE.
        Set-RS $script:GpuPrefKey $script:E2 'AppStatus=1;'
        Set-AXEGameGpuPref -Exe $script:E2 -HighPerf $true
        Set-AXEGameGpuPref -Exe $script:E2 -FlipModel $true
        Revert-AXEGameGpu $script:E2 | Out-Null
        (Get-RV $script:GpuPrefKey $script:E2) | Should -Be 'AppStatus=1;'
    }
}

Describe 'Topologia de GPU' -Tag 'unit' {

    It 'Get-AXEGpuList no revienta y Test-AXEHybridGpu es booleano' {
        # Sin assert sobre el NUMERO de GPUs: depende de la maquina y un test que exija
        # hibrida fallaria en CI (y en cualquier sobremesa de una sola grafica).
        { Get-AXEGpuList } | Should -Not -Throw
        (Test-AXEHybridGpu) | Should -BeOfType [bool]
    }
}

Describe 'Optimize-AXEGame' -Tag 'unit' {

    It 'ruta inexistente: error claro, sin escribir en el registro' {
        $fantasma = 'C:\__AXE_TEST_GPU__\no-existe-en-disco.exe'
        $out = Optimize-AXEGame -Exe $fantasma
        ($out -join "`n") | Should -Match 'no existe'
        (Get-RV $script:GpuPrefKey $fantasma) | Should -BeNullOrEmpty
    }
}
