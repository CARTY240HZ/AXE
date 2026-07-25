# Pester de la cadena de confianza + updater (43-update.ps1, spec 2026-07-24, subproyectos A+B).
#
# La propiedad que este fichero existe para proteger es de SEGURIDAD, no de estilo:
#   EL UPDATER NUNCA REEMPLAZA NADA QUE NO HAYA VERIFICADO.
# AXE se instala en una ruta escribible por el usuario y AXE.bat lo ejecuta ELEVADO. Un updater
# que acepte un asset sin verificar convierte eso en una via de escalada de privilegios. Si
# alguien "simplifica" una de las negativas de aqui, la suite se pone roja.
#
# Todo con FIXTURES y SIN RED (misma politica que Bench.Tests con las series sinteticas y
# Fps.Tests con las capturas de PresentMon): Get-AXELatestRelease se parte en dos, la llamada
# HTTP por un lado y ConvertFrom-AXEReleaseJson por otro, y aqui solo se ejercita la segunda.
# Los caminos de rechazo del updater ocurren TODOS antes de la primera descarga, asi que se
# pueden ejercer enteros inyectando el release con -Release.
#
# Lo que NO se cubre, a proposito: que Set-AuthenticodeSignature firme bien (es de Windows) y
# que la descarga real funcione (necesitaria red y un release publicado). De la firma se testea
# el lado del que depende la seguridad: la NEGATIVA sobre lo no firmado.

BeforeAll {
    . "$PSScriptRoot/_load-engine.ps1"

    $script:UpdTmp = Join-Path ([IO.Path]::GetTempPath()) ('axe_upd_test_{0}' -f [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:UpdTmp -Force | Out-Null

    $script:OkUrl  = "https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v9.9.9/AXE.ps1"
    $script:OkSums = "https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/download/v9.9.9/SHA256SUMS"

    # Fabrica de releases con la MISMA forma que devuelve la API de GitHub, para que lo que se
    # testea sea el parseo real y no un atajo.
    function New-Release {
        param([string]$Tag='v9.9.9',[object[]]$Assets,[bool]$Pre=$false)
        if($null -eq $Assets){
            $Assets = @(
                [pscustomobject]@{ name='AXE.ps1';    size=1234; browser_download_url=$script:OkUrl }
                [pscustomobject]@{ name='SHA256SUMS'; size=64;   browser_download_url=$script:OkSums }
            )
        }
        ConvertFrom-AXEReleaseJson ([pscustomobject]@{
            tag_name=$Tag; published_at='2026-01-01T00:00:00Z'; prerelease=$Pre; assets=$Assets })
    }
    function New-TmpDir { $d = Join-Path $script:UpdTmp ([guid]::NewGuid()); New-Item -ItemType Directory -Path $d -Force | Out-Null; $d }
}

AfterAll {
    if($script:UpdTmp -and (Test-Path $script:UpdTmp)){ Remove-Item $script:UpdTmp -Recurse -Force -EA SilentlyContinue }
}

Describe 'Compare-AXEVersion - precedencia SemVer' -Tag 'unit' {

    It 'ordena <A> vs <B> como <W>' -ForEach @(
        @{ A='7.0.0';     B='7.0.1';  W=-1 }
        @{ A='7.0.1';     B='7.0.0';  W=1  }
        @{ A='7.0.0';     B='7.0.0';  W=0  }
        @{ A='7.10.0';    B='7.9.0';  W=1  }   # numerico, no lexicografico
        @{ A='8.0.0';     B='7.99.99';W=1  }
        @{ A='7';         B='7.0.0';  W=0  }   # se normaliza a 3 campos
        @{ A='7.1';       B='7.1.0';  W=0  }
        @{ A='v7.1.0';    B='7.1.0';  W=0  }   # la 'v' del tag no cuenta
        @{ A='7.0.0+abc'; B='7.0.0';  W=0  }   # metadatos de build: SemVer §10, no cuentan
    ) {
        Compare-AXEVersion $A $B | Should -Be $W
    }

    It 'una prerelease va por debajo de la estable con los mismos numeros (SemVer §11)' {
        # Sin esto, 7.1.0-beta y 7.1.0 saldrian iguales y el updater no ofreceria la estable.
        Compare-AXEVersion '7.1.0-beta' '7.1.0'       | Should -Be -1
        Compare-AXEVersion '7.1.0' '7.1.0-beta'       | Should -Be 1
        Compare-AXEVersion '7.1.0-alpha' '7.1.0-beta' | Should -Be -1
    }

    It 'una version ilegible da null, no 0 (0 se confundiria con "estas al dia")' {
        Compare-AXEVersion '7.x.0' '7.0.0' | Should -BeNullOrEmpty
        Compare-AXEVersion ''      '7.0.0' | Should -BeNullOrEmpty
        Compare-AXEVersion $null   '7.0.0' | Should -BeNullOrEmpty
    }
}

Describe 'New-AXEChecksums / Test-AXEChecksums - integridad' -Tag 'unit' {

    It 'lo recien generado se verifica a si mismo' {
        $d = New-TmpDir
        Set-Content (Join-Path $d 'a.txt') -Value 'contenido a' -Encoding UTF8 -NoNewline
        Set-Content (Join-Path $d 'b.txt') -Value 'contenido b' -Encoding UTF8 -NoNewline
        [void](New-AXEChecksums -Dir $d)
        @(Test-AXEChecksums -Dir $d) | Should -BeNullOrEmpty
    }

    It 'un solo byte cambiado se caza' {
        # EL check del fichero. Si esto pasa en verde con el fichero alterado, el updater
        # instalaria un script manipulado sin enterarse.
        $d = New-TmpDir
        Set-Content (Join-Path $d 'a.txt') -Value 'original' -Encoding UTF8 -NoNewline
        [void](New-AXEChecksums -Dir $d)
        Set-Content (Join-Path $d 'a.txt') -Value 'Original' -Encoding UTF8 -NoNewline   # una mayuscula
        $bad = @(Test-AXEChecksums -Dir $d)
        $bad.Count | Should -BeGreaterThan 0
        ($bad -join ' ') | Should -Match 'a\.txt'
    }

    It 'un fichero listado pero ausente se reporta, no se ignora' {
        $d = New-TmpDir
        Set-Content (Join-Path $d 'a.txt') -Value 'x' -Encoding UTF8 -NoNewline
        [void](New-AXEChecksums -Dir $d)
        Remove-Item (Join-Path $d 'a.txt') -Force
        ((Test-AXEChecksums -Dir $d) -join ' ') | Should -Match 'ausente'
    }

    It 'es determinista: dos pasadas dan el mismo texto' {
        # Es lo que permite comprobar en CI que un release no derivo.
        $d = New-TmpDir
        Set-Content (Join-Path $d 'a.txt') -Value 'x' -Encoding UTF8 -NoNewline
        Set-Content (Join-Path $d 'b.txt') -Value 'y' -Encoding UTF8 -NoNewline
        $f = New-AXEChecksums -Dir $d
        $one = Get-Content $f -Raw -Encoding UTF8
        [void](New-AXEChecksums -Dir $d)
        (Get-Content $f -Raw -Encoding UTF8) | Should -Be $one
    }

    It 'usa el formato coreutils (dos espacios, hex en minusculas)' {
        # Para que se pueda verificar con `sha256sum -c` desde WSL sin fiarse de nuestro codigo.
        $d = New-TmpDir
        Set-Content (Join-Path $d 'a.txt') -Value 'x' -Encoding UTF8 -NoNewline
        (Get-Content (New-AXEChecksums -Dir $d) -Raw) | Should -Match '(?m)^[0-9a-f]{64}  a\.txt$'
    }

    It 'no se lista a si mismo' {
        $d = New-TmpDir
        Set-Content (Join-Path $d 'a.txt') -Value 'x' -Encoding UTF8 -NoNewline
        (Get-Content (New-AXEChecksums -Dir $d) -Raw) | Should -Not -Match 'SHA256SUMS'
    }

    It 'un directorio sin SHA256SUMS se reporta en vez de darse por bueno' {
        ((Test-AXEChecksums -Dir (New-TmpDir)) -join ' ') | Should -Match 'falta'
    }

    It 'un SHA256SUMS vacio NO cuenta como verificado' {
        $d = New-TmpDir
        Set-Content (Join-Path $d 'SHA256SUMS') -Value '' -Encoding UTF8
        ((Test-AXEChecksums -Dir $d) -join ' ') | Should -Match 'vacio'
    }
}

Describe 'Get-AXEChecksumFor - parseo del manifiesto' -Tag 'unit' {

    BeforeAll {
        $script:sums = @(
            ('a'*64) + '  AXE.ps1'
            ('b'*64) + '  *AXE.bat'      # marcador de modo binario de coreutils
        ) -join "`n"
    }

    It 'encuentra el hash de un nombre listado' {
        Get-AXEChecksumFor $script:sums 'AXE.ps1' | Should -Be ('a'*64)
    }
    It 'acepta el marcador de modo binario de coreutils' {
        Get-AXEChecksumFor $script:sums 'AXE.bat' | Should -Be ('b'*64)
    }
    It 'un nombre NO listado da null (no se asume que sea correcto)' {
        Get-AXEChecksumFor $script:sums 'otro.ps1' | Should -BeNullOrEmpty
    }
    It 'no hace prefijo: AXE.ps no es AXE.ps1' {
        Get-AXEChecksumFor $script:sums 'AXE.ps' | Should -BeNullOrEmpty
    }
    It 'entradas vacias dan null en vez de lanzar' {
        Get-AXEChecksumFor '' 'AXE.ps1'    | Should -BeNullOrEmpty
        Get-AXEChecksumFor $script:sums '' | Should -BeNullOrEmpty
        Get-AXEChecksumFor $null $null     | Should -BeNullOrEmpty
    }
}

Describe 'Test-AXESignature - la negativa es lo que protege' -Tag 'unit' {

    It 'un .ps1 sin firmar da false' {
        $f = Join-Path (New-TmpDir) 'sinfirma.ps1'
        Set-Content $f -Value '# sin firma' -Encoding UTF8
        Test-AXESignature $f | Should -BeFalse
        (Get-AXESignatureInfo $f).Valid | Should -BeFalse
    }
    It 'un fichero inexistente da false, no lanza' {
        Test-AXESignature 'C:\no\existe\jamas.ps1' | Should -BeFalse
        (Get-AXESignatureInfo 'C:\no\existe\jamas.ps1').Status | Should -Be 'NotFound'
    }
    It 'rutas vacias dan false' {
        Test-AXESignature ''    | Should -BeFalse
        Test-AXESignature $null | Should -BeFalse
    }
}

Describe 'Test-AXEAssetUrl - solo se descarga del repo oficial' -Tag 'unit' {

    It 'acepta la URL de release del repo oficial' {
        Test-AXEAssetUrl $script:OkUrl | Should -BeTrue
    }
    It 'acepta el CDN de assets de GitHub' {
        Test-AXEAssetUrl 'https://objects.githubusercontent.com/github-production-release-asset/1/2' | Should -BeTrue
    }
    It 'rechaza: <case>' -ForEach @(
        @{ case='sin TLS';           url='http://github.com/CARTY240HZ/AXE/releases/download/v1/AXE.ps1' }
        @{ case='otro dominio';      url='https://evil.example.com/AXE.ps1' }
        @{ case='otro repo';         url='https://github.com/otro/repo/releases/download/v1/AXE.ps1' }
        @{ case='host que lo imita'; url='https://github.com.evil.example/CARTY240HZ/AXE/x' }
        @{ case='subdominio falso';  url='https://evil.github.com.attacker.net/CARTY240HZ/AXE/x' }
        @{ case='file://';           url='file:///C:/temp/AXE.ps1' }
        @{ case='no es una url';     url='no-soy-una-url' }
        @{ case='vacia';             url='' }
    ) {
        Test-AXEAssetUrl $url | Should -BeFalse
    }
}

Describe 'ConvertFrom-AXEReleaseJson - parseo sin red' -Tag 'unit' {

    It 'extrae tag, version sin v, y assets' {
        $r = New-Release -Tag 'v7.5.0'
        $r.Tag     | Should -Be 'v7.5.0'
        $r.Version | Should -Be '7.5.0'
        @($r.Assets).Count | Should -Be 2
        (@($r.Assets | Where-Object Name -eq 'AXE.ps1').Url) | Should -Be $script:OkUrl
    }
    It 'un release sin tag_name da null (no es un release)' {
        ConvertFrom-AXEReleaseJson ([pscustomobject]@{ assets=@() }) | Should -BeNullOrEmpty
        ConvertFrom-AXEReleaseJson $null                             | Should -BeNullOrEmpty
    }
    It 'los assets sin nombre se descartan en vez de colarse a medias' {
        $r = New-Release -Assets @([pscustomobject]@{ name=''; browser_download_url='https://x' })
        @($r.Assets).Count | Should -Be 0
    }
}

Describe 'Invoke-AXEUpdate - nunca reemplaza lo que no verifico' -Tag 'unit' {

    BeforeAll { $script:AXEVersion = '7.0.0' }

    It 'con la misma version dice current y no descarga nada' {
        $r = Invoke-AXEUpdate -Release (New-Release -Tag 'v7.0.0')
        $r.Status  | Should -Be 'current'
        $r.Message | Should -Match 'ultima version'
    }
    It 'con una version REMOTA MAS VIEJA tambien dice current (no se degrada sola)' {
        (Invoke-AXEUpdate -Release (New-Release -Tag 'v6.0.0')).Status | Should -Be 'current'
    }
    It '-Check con version nueva informa y NO toca nada' {
        $r = Invoke-AXEUpdate -Release (New-Release -Tag 'v9.9.9') -Check
        $r.Status  | Should -Be 'available'
        $r.Latest  | Should -Be '9.9.9'
        $r.Message | Should -Match '7\.0\.0 -> 9\.9\.9'
    }
    It 'sin poder consultar la API dice error, no "estas al dia"' {
        # Confundir "no pude comprobar" con "al dia" dejaria al usuario en una version vieja
        # creyendo lo contrario.
        #   El mock NO es decorativo: -Release $null es indistinguible de omitirlo, asi que sin el
        # esta prueba caia en Get-AXELatestRelease y llamaba a la API de GitHub DE VERDAD. Pasaba
        # solo mientras no hubiera red ni releases publicados; en cuanto hubo release empezo a
        # devolver 'current', es decir, a probar lo contrario de lo que dice su nombre.
        Mock Get-AXELatestRelease { $null }
        (Invoke-AXEUpdate -Release $null -Check).Status | Should -Be 'error'
    }
    It 'una version remota ilegible da error en vez de intentar instalarla' {
        (Invoke-AXEUpdate -Release (New-Release -Tag 'vNO-ES-VERSION')).Status | Should -Be 'error'
    }

    Context 'rechazos de seguridad (todos antes de la primera descarga)' {

        It 'un release SIN SHA256SUMS se rechaza aunque traiga AXE.ps1' {
            $r = Invoke-AXEUpdate -Release (New-Release -Assets @(
                [pscustomobject]@{ name='AXE.ps1'; size=1; browser_download_url=$script:OkUrl }))
            $r.Status  | Should -Be 'refused'
            $r.Message | Should -Match 'SHA256SUMS'
        }

        It 'un release SIN AXE.ps1 se rechaza' {
            $r = Invoke-AXEUpdate -Release (New-Release -Assets @(
                [pscustomobject]@{ name='SHA256SUMS'; size=1; browser_download_url=$script:OkSums }))
            $r.Status | Should -Be 'refused'
        }

        It 'un AXE.ps1 alojado FUERA del repo oficial se rechaza' {
            $r = Invoke-AXEUpdate -Release (New-Release -Assets @(
                [pscustomobject]@{ name='AXE.ps1';    size=1; browser_download_url='https://evil.example.com/AXE.ps1' }
                [pscustomobject]@{ name='SHA256SUMS'; size=1; browser_download_url=$script:OkSums }))
            $r.Status  | Should -Be 'refused'
            $r.Message | Should -Match 'repo oficial'
        }

        It 'un SHA256SUMS alojado fuera del repo oficial tambien se rechaza' {
            # Si el manifiesto pudiera venir de otro sitio, el atacante fija el hash esperado.
            $r = Invoke-AXEUpdate -Release (New-Release -Assets @(
                [pscustomobject]@{ name='AXE.ps1';    size=1; browser_download_url=$script:OkUrl }
                [pscustomobject]@{ name='SHA256SUMS'; size=1; browser_download_url='https://evil.example.com/SHA256SUMS' }))
            $r.Status | Should -Be 'refused'
        }

        It 'un rechazo deja el fichero destino INTACTO y sin .new tirado' {
            $target = Join-Path (New-TmpDir) 'AXE.ps1'
            Set-Content $target -Value '# version original' -Encoding UTF8
            [void](Invoke-AXEUpdate -Target $target -Release (New-Release -Assets @(
                [pscustomobject]@{ name='AXE.ps1'; size=1; browser_download_url=$script:OkUrl })))
            Test-Path "$target.new" | Should -BeFalse
            (Get-Content $target -Raw) | Should -Match 'version original'
        }
    }
}

Describe 'New-AXESbom - CycloneDX honesto' -Tag 'unit' {

    BeforeAll {
        $script:repoRoot = Split-Path $PSScriptRoot -Parent
        $script:sbomOut  = Join-Path (New-TmpDir) 'sbom.json'
        [void](New-AXESbom -Root $script:repoRoot -Version '7.0.0' -OutFile $script:sbomOut)
        $script:sbom = Get-Content $script:sbomOut -Raw | ConvertFrom-Json
    }

    It 'es CycloneDX 1.5 valido en lo estructural' {
        $script:sbom.bomFormat    | Should -Be 'CycloneDX'
        $script:sbom.specVersion  | Should -Be '1.5'
        $script:sbom.serialNumber | Should -Match '^urn:uuid:[0-9a-f-]{36}$'
        $script:sbom.metadata.component.name    | Should -Be 'AXE'
        $script:sbom.metadata.component.version | Should -Be '7.0.0'
    }

    It 'lista las DLL de WebView2 con hash SHA-256 y licencia' {
        @($script:sbom.components).Count | Should -BeGreaterThan 0
        foreach($c in $script:sbom.components){
            $c.hashes[0].alg            | Should -Be 'SHA-256'
            $c.hashes[0].content        | Should -Match '^[0-9a-f]{64}$'
            $c.licenses[0].license.name | Should -Not -BeNullOrEmpty
        }
    }

    It 'NO declara OSS lo que es propietario redistribuible' {
        # Poner 'MIT' en el SDK de WebView2 porque queda mas limpio seria falsear el SBOM, que
        # es justo lo contrario de para lo que existe.
        foreach($c in $script:sbom.components){
            $c.licenses[0].license.name | Should -Match 'Microsoft Software License Terms'
        }
    }

    It 'NO lista PresentMon (no se redistribuye, lo aporta el usuario)' {
        # Un SBOM que lista lo que no envias miente igual que uno que omite lo que si envias.
        ((@($script:sbom.components) | ForEach-Object name) -join ' ') | Should -Not -Match '(?i)presentmon'
    }

    It 'el serialNumber es determinista para el mismo contenido' {
        $otro = Join-Path (New-TmpDir) 'sbom2.json'
        [void](New-AXESbom -Root $script:repoRoot -Version '7.0.0' -OutFile $otro)
        (Get-Content $otro -Raw | ConvertFrom-Json).serialNumber | Should -Be $script:sbom.serialNumber
    }

    It 'cambiar la version cambia el serialNumber' {
        $otro = Join-Path (New-TmpDir) 'sbom3.json'
        [void](New-AXESbom -Root $script:repoRoot -Version '7.1.0' -OutFile $otro)
        (Get-Content $otro -Raw | ConvertFrom-Json).serialNumber | Should -Not -Be $script:sbom.serialNumber
    }
}
