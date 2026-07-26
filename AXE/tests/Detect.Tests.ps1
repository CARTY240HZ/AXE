# Unit - las tres detecciones que se anadieron el 2026-07-26 para poder lanzar:
#   1. Get-AXEWindowFit  (39-webdetect) - que la ventana quepa en el escritorio que HAY.
#   2. zoom persistente  (39-webdetect) - Test/Get/Set-AXEUIZoom.
#   3. smart detect      (40-session)   - Get-AXEGameCandidates / Test-AXEGameExcluded.
#
# Las tres son PURAS o casi, y por eso se testean de verdad en vez de "a mano en mi maquina":
# el fit recibe numeros, el detector recibe hechos de proceso sinteticos. Lo unico que toca disco
# es el zoom, y se le redirige $script:AXEData a un temporal (misma receta que Session.Tests).
#
# Lo que NO se testea, a proposito: leer SystemParameters.WorkArea (es WPF, pide ventana) y
# Get-AXESessionProcesses (depende de que este abierto en la maquina de quien corra la suite, y
# eso no es un test, es una loteria). La frontera esta puesta donde se acaba lo determinista.

BeforeAll {
    . "$PSScriptRoot/_load-engine.ps1"

    # Fabrica de hechos de proceso, con los campos que anadio Get-AXESessionProcesses.
    function New-P {
        param($procId,$name,$path=$null,$win=$false,$mb=0,$sid=1)
        [pscustomobject]@{
            Pid=[int]$procId; Name=[string]$name; SessionId=[int]$sid; Path=$path
            HasWindow=[bool]$win; Title=''; WorkingSetMB=[double]$mb
        }
    }
    function NamesOf($c){ @($c | ForEach-Object { $_.Name }) }
}

Describe 'Get-AXEWindowFit - la ventana cabe en el escritorio real' -Tag 'unit' {

    It 'en un escritorio grande no recorta nada' {
        $f = Get-AXEWindowFit -WorkWidth 2560 -WorkHeight 1400
        $f.Width  | Should -Be 1200
        $f.Height | Should -Be 840
        $f.Clamped | Should -BeFalse
        $f.Reason  | Should -BeNullOrEmpty
    }

    It 'en la pantalla de referencia (1920x1080 al 125% = 1536x816 DIP) el alto se recorta y CABE' {
        # Este es el bug exacto que se arreglo: 840 de alto sobre 816 utiles = 24 DIP por debajo
        # del escritorio, o sea el borde inferior escondido tras la barra de tareas.
        $f = Get-AXEWindowFit -WorkWidth 1536 -WorkHeight 816
        $f.Height  | Should -BeLessOrEqual 816
        $f.Clamped | Should -BeTrue
        $f.Reason  | Should -Match '1536x816'
    }

    It 'REGRESION: a 150% (1280x680 DIP) el MINIMO tambien cabe' {
        # El defecto original no era solo que naciera grande: MinHeight=720 era MAYOR que los 680
        # DIP utiles, asi que la ventana no se podia encoger hasta que entrase. Nunca. Este test
        # es el que impide que vuelva.
        $f = Get-AXEWindowFit -WorkWidth 1280 -WorkHeight 680
        $f.MinHeight | Should -BeLessOrEqual 680
        $f.MinWidth  | Should -BeLessOrEqual 1280
        $f.Height    | Should -BeLessOrEqual 680
    }

    It 'el minimo nunca supera al tamano, sea cual sea el escritorio' -ForEach @(
        @{ w=3840; h=2160 }, @{ w=1920; h=1080 }, @{ w=1536; h=816 }, @{ w=1280; h=680 }
        @{ w=1024; h=600  }, @{ w=800;  h=600  }, @{ w=640;  h=480 }, @{ w=400;  h=300 }
    ) {
        $f = Get-AXEWindowFit -WorkWidth $w -WorkHeight $h
        $f.MinWidth  | Should -BeLessOrEqual $f.Width
        $f.MinHeight | Should -BeLessOrEqual $f.Height
    }

    It 'nunca devuelve mas de lo que se pide' {
        $f = Get-AXEWindowFit -WorkWidth 5000 -WorkHeight 5000 -WantWidth 1200 -WantHeight 840
        $f.Width  | Should -Be 1200
        $f.Height | Should -Be 840
    }

    It 'un escritorio ilegible devuelve lo deseado y lo DICE en vez de inventarse un tamano' -ForEach @(
        @{ w=0; h=0 }, @{ w=-1; h=800 }, @{ w=1200; h=0 }
    ) {
        $f = Get-AXEWindowFit -WorkWidth $w -WorkHeight $h
        $f.Width   | Should -Be 1200
        $f.Height  | Should -Be 840
        $f.Clamped | Should -BeFalse
        $f.Reason  | Should -Match 'no pude leer'
    }

    It 'NaN se trata como ilegible, no como cero' {
        $f = Get-AXEWindowFit -WorkWidth ([double]::NaN) -WorkHeight 800
        $f.Reason | Should -Match 'no pude leer'
    }

    It 'en una pantalla diminuta se respeta el suelo duro y no queda area cero' {
        $f = Get-AXEWindowFit -WorkWidth 100 -WorkHeight 100
        $f.Width  | Should -BeGreaterOrEqual 320
        $f.Height | Should -BeGreaterOrEqual 240
    }
}

Describe 'Zoom de la interfaz - persistente y acotado' -Tag 'unit' {

    BeforeAll {
        $script:zoomOld  = $script:AXEData
        $script:AXEData  = Join-Path ([System.IO.Path]::GetTempPath()) ('axe-test-zoom-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
    }
    AfterAll {
        if($script:AXEData -and (Test-Path $script:AXEData)){ Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue }
        $script:AXEData = $script:zoomOld
    }
    BeforeEach {
        $p = Get-AXEUIPrefsPath
        if($p -and (Test-Path $p)){ Remove-Item $p -Force -EA SilentlyContinue }
    }

    It 'acepta los valores del rango util' -ForEach @(@{z=0.6},@{z=1.0},@{z=1.25},@{z=2.0}) {
        Test-AXEUIZoom $z | Should -BeTrue
    }

    It 'rechaza lo que no es un zoom usable' -ForEach @(
        @{z=0}, @{z=-1}, @{z=0.59}, @{z=2.01}, @{z=10}, @{z='grande'}, @{z=$null}
    ) {
        Test-AXEUIZoom $z | Should -BeFalse
    }

    It 'sin fichero devuelve 1.0' {
        Get-AXEUIZoom | Should -Be 1.0
    }

    It 'lo guardado vuelve tal cual (ida y vuelta)' {
        Set-AXEUIZoom 1.25 | Should -BeTrue
        Get-AXEUIZoom | Should -Be 1.25
    }

    It 'no guarda un zoom invalido: el arranque siguiente no puede quedar inservible' {
        Set-AXEUIZoom 1.5  | Should -BeTrue
        Set-AXEUIZoom 99   | Should -BeFalse
        Get-AXEUIZoom | Should -Be 1.5     # el valido anterior sigue en pie
    }

    It 'un fichero corrupto no lanza: degrada a 1.0' {
        Set-Content -Path (Get-AXEUIPrefsPath) -Value '{esto no es json' -Encoding UTF8
        { Get-AXEUIZoom } | Should -Not -Throw
        Get-AXEUIZoom | Should -Be 1.0
    }

    It 'un zoom fuera de rango YA guardado en disco se ignora' {
        Set-Content -Path (Get-AXEUIPrefsPath) -Value '{"zoom": 42}' -Encoding UTF8
        Get-AXEUIZoom | Should -Be 1.0
    }

    It 'sin carpeta de datos no lanza ni finge que guardo' {
        $old = $script:AXEData
        $script:AXEData = $null
        try {
            Get-AXEUIZoom      | Should -Be 1.0
            Set-AXEUIZoom 1.25 | Should -BeFalse
        } finally { $script:AXEData = $old }
    }
}

Describe 'Smart detect - que proceso es el juego' -Tag 'unit' {

    BeforeEach {
        $script:sysDir = [string]$env:SystemRoot
        $script:facts = @(
            (New-P 1000 'cs2'      'C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive\game\bin\win64\cs2.exe' $true 2400)
            (New-P 1001 'steam'    'C:\Program Files (x86)\Steam\steamapps\common\x\steam.exe' $true 900)
            (New-P 1002 'explorer' (Join-Path $script:sysDir 'explorer.exe') $true 120)
            (New-P 1003 'chrome'   'C:\Program Files\Google\Chrome\Application\chrome.exe' $true 1800)
            (New-P 1004 'EasyAntiCheat' 'C:\Program Files (x86)\EasyAntiCheat\EasyAntiCheat.exe' $false 20)
            (New-P 1005 'svchost'  (Join-Path $script:sysDir 'System32\svchost.exe') $false 30 0)
            (New-P 99   'pwsh'     'C:\Program Files\PowerShell\7\pwsh.exe' $true 300)
        )
        $script:cands = Get-AXEGameCandidates -Processes $script:facts -SelfPid 99 -SessionId 1
    }

    It 'el juego de la carpeta de Steam sale PRIMERO y como probable' {
        $script:cands[0].Name   | Should -Be 'cs2'
        $script:cands[0].Likely | Should -BeTrue
        $script:cands[0].Store  | Should -Be 'Steam'
    }

    It 'la lanzadera NO se propone aunque viva en steamapps y tenga ventana' {
        # El falso positivo mas probable de todos: Steam esta literalmente dentro de steamapps.
        NamesOf $script:cands | Should -Not -Contain 'steam'
    }

    It 'shell, anticheat, navegador y Session 0 quedan fuera' {
        $n = NamesOf $script:cands
        $n | Should -Not -Contain 'explorer'
        $n | Should -Not -Contain 'easyanticheat'
        $n | Should -Not -Contain 'chrome'
        $n | Should -Not -Contain 'svchost'
    }

    It 'AXE no se propone a si mismo' {
        NamesOf $script:cands | Should -Not -Contain 'pwsh'
    }

    It 'da las RAZONES, no solo el nombre' {
        @($script:cands[0].Reasons).Count | Should -BeGreaterThan 0
        ($script:cands[0].Reasons -join ' ') | Should -Match 'Steam'
    }

    It 'REGRESION: un ayudante de tienda no gana por estar en la carpeta de la tienda' {
        # Cazado en la maquina de referencia: 'epiconlineservicesuserhelper' vive en Epic Games\,
        # se llevaba los 50 puntos de tienda y salia el PRIMERO, por delante de un juego real.
        $f = @( (New-P 2000 'EpicOnlineServicesUserHelper' 'C:\Program Files\Epic Games\Launcher\Portal\Extras\EpicOnlineServicesUserHelper.exe' $true 300) )
        @(Get-AXEGameCandidates -Processes $f -SelfPid 99 -SessionId 1).Count | Should -Be 0
    }

    It 'la regla de ayudantes se ancla al FINAL del nombre y no descarta juegos que la contengan' -ForEach @(
        @{ n='gameservice';    fuera=$true  }
        @{ n='milauncher';     fuera=$true  }
        @{ n='agentsofmayhem'; fuera=$false }
        @{ n='servicegame';    fuera=$false }
    ) {
        $r = Test-AXEGameExcluded -Proc (New-P 3000 $n 'D:\Juegos\x.exe' $true 800) -SelfPid 99
        if($fuera){ $r | Should -Not -BeNullOrEmpty } else { $r | Should -BeNullOrEmpty }
    }

    It 'lo que vive en la carpeta de Windows no es candidato' {
        Test-AXEGameExcluded -Proc (New-P 4000 'loquesea' (Join-Path $script:sysDir 'loquesea.exe') $true 900) -SelfPid 99 |
            Should -Match 'Windows'
    }

    It 'reconoce el MOTOR sin conocer el titulo (Unreal shipping, fuera de toda tienda)' {
        $f = @( (New-P 5000 'MiJuegoIndie-Win64-Shipping' 'D:\itch\MiJuegoIndie\Binaries\Win64\MiJuegoIndie-Win64-Shipping.exe' $true 1600) )
        $c = @(Get-AXEGameCandidates -Processes $f -SelfPid 99 -SessionId 1)
        $c.Count | Should -Be 1
        ($c[0].Reasons -join ' ') | Should -Match 'Unreal'
        $c[0].Likely | Should -BeTrue     # motor + ventana + memoria basta sin tienda
    }

    It 'UNA fila por app: N procesos del mismo nombre no inundan la lista' {
        # Sin esto una app de Electron llenaba el top con su propio nombre repetido y empujaba al
        # juego de verdad fuera de la lista.
        $f = @(1..9 | ForEach-Object { New-P (6000 + $_) 'appelectron' 'D:\Apps\appelectron.exe' ($_ -eq 1) 200 })
        $c = @(Get-AXEGameCandidates -Processes $f -SelfPid 99 -SessionId 1)
        $c.Count           | Should -Be 1
        $c[0].Instances    | Should -Be 9
        $c[0].Pid          | Should -Be 6001     # representa el grupo la instancia con ventana
    }

    It 'solo tener ventana NO convierte a nada en probable' {
        $f = @( (New-P 7000 'algunaapp' 'D:\Apps\algunaapp.exe' $true 100) )
        $c = @(Get-AXEGameCandidates -Processes $f -SelfPid 99 -SessionId 1)
        $c[0].Likely | Should -BeFalse
    }

    It 'los procesos de otra sesion de Windows no se consideran' {
        $f = @( (New-P 8000 'juegoajeno' 'C:\Program Files (x86)\Steam\steamapps\common\x\juegoajeno.exe' $true 2000 7) )
        @(Get-AXEGameCandidates -Processes $f -SelfPid 99 -SessionId 1).Count | Should -Be 0
    }

    It 'respeta -Top' {
        $f = @(1..12 | ForEach-Object { New-P (9000 + $_) ("juego$_") "D:\Steam\steamapps\common\j$_\juego$_.exe" $true 900 })
        @(Get-AXEGameCandidates -Processes $f -SelfPid 99 -SessionId 1 -Top 3).Count | Should -Be 3
    }

    It 'sin procesos no lanza y devuelve lista vacia' {
        { Get-AXEGameCandidates -Processes @() -SelfPid 99 -SessionId 1 } | Should -Not -Throw
        @(Get-AXEGameCandidates -Processes @() -SelfPid 99 -SessionId 1).Count | Should -Be 0
    }

    It 'un hecho nulo dentro de la lista no rompe la deteccion' {
        $f = @($null, (New-P 9500 'cs2' 'D:\Steam\steamapps\common\cs2\cs2.exe' $true 2000), $null)
        @(Get-AXEGameCandidates -Processes $f -SelfPid 99 -SessionId 1).Count | Should -Be 1
    }

    It 'el orden es estable: dos lecturas seguidas dan lo mismo' {
        $a = NamesOf (Get-AXEGameCandidates -Processes $script:facts -SelfPid 99 -SessionId 1)
        $b = NamesOf (Get-AXEGameCandidates -Processes $script:facts -SelfPid 99 -SessionId 1)
        ($a -join ',') | Should -Be ($b -join ',')
    }
}

Describe 'Get-AXEHardware - detecta el equipo sin depender de que WMI este entero' -Tag 'unit' {

    BeforeAll { $script:hw = Get-AXEHardware }

    It 'no lanza aunque algo no se pueda leer' {
        { Get-AXEHardware } | Should -Not -Throw
    }

    It 'mantiene los campos de los que depende el gating' -ForEach @(
        @{ f='RamGB' }, @{ f='IsLaptop' }, @{ f='IsSSD' }, @{ f='OnBattery' }, @{ f='IsWifi' }
        @{ f='IsHybrid' }, @{ f='HasNvidia' }, @{ f='BuildNumber' }, @{ f='IsWin11' }, @{ f='Edition' }
        @{ f='CpuArch' }, @{ f='CpuVendor' }, @{ f='SupportsHAGS' }, @{ f='IsSMode' }, @{ f='IsHome' }
        @{ f='HasDefender' }, @{ f='IsTamperProtected' }, @{ f='NicName' }, @{ f='CpuName' }
        @{ f='Cores' }, @{ f='Threads' }
    ) {
        # Trinquete de contrato: 20-tweaks, el banner y los perfiles leen estos nombres. Que exista
        # el campo importa aunque su valor sea $null en una maquina concreta.
        $script:hw.PSObject.Properties.Name | Should -Contain $f
    }

    It 'trae los campos nuevos de deteccion' -ForEach @(
        @{ f='GpuNames' }, @{ f='GpuPrimary' }, @{ f='GpuVendor' }, @{ f='RefreshHz' }
        @{ f='ScreenW' }, @{ f='ScreenH' }, @{ f='IsVM' }, @{ f='Model' }, @{ f='Vendor' }
        @{ f='DisplayVersion' }, @{ f='Ubr' }, @{ f='DetectWarnings' }
    ) {
        $script:hw.PSObject.Properties.Name | Should -Contain $f
    }

    It 'el canal de avisos existe siempre, aunque este vacio' {
        # No se exige que la lista este vacia -depende de la maquina- sino que EXISTA. Que exista el
        # canal es lo que impide que un fallo de deteccion pase desapercibido.
        ,@($script:hw.DetectWarnings) | Should -BeOfType [array]
    }

    It 'Win11 se decide por build, nunca por el nombre del producto' {
        # ProductName del registro sigue diciendo "Windows 10" en Win11: es un fallo conocido de
        # Microsoft y confiar en el rotulo daria Win10 en media flota.
        if($script:hw.BuildNumber){
            $script:hw.IsWin11 | Should -Be ([int]$script:hw.BuildNumber -ge 22000)
        }
    }

    It 'la RAM es un numero utilizable por el gating, no un nulo' {
        $script:hw.RamGB | Should -BeOfType [double]
    }

    It 'si hay GPU, hay nombre y vendor coherentes' {
        if(@($script:hw.GpuNames).Count -gt 0){
            $script:hw.GpuPrimary | Should -Not -BeNullOrEmpty
            if($script:hw.HasNvidia){ $script:hw.GpuVendor | Should -Be 'NVIDIA' }
        }
    }
}
