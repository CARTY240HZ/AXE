# =====================================================
# REGION 8f - CADENA DE CONFIANZA + UPDATER (subproyectos A+B) - spec 2026-07-24
# =====================================================
# Lo que cierra: que AXE se pueda INSTALAR y ACTUALIZAR sin que eso abra un agujero de
# supply-chain. La mayoria de optimizadores de GitHub se distribuyen como un .bat crudo que
# hace Invoke-WebRequest a una URL y lo ejecuta. Eso es exactamente lo que aqui NO se hace.
#
# Las tres piezas, por orden de lo que garantizan:
#   SHA256SUMS   -> integridad EN TRANSITO (llego entero, sin corrupcion ni MITM)
#   sbom.json    -> transparencia (que hay dentro del paquete, con hash y licencia)
#   Authenticode -> AUTENTICIDAD (quien lo firmo). La unica de las tres que prueba PROCEDENCIA.
#
# POR QUE EL CHECKSUM NO BASTA PARA REEMPLAZAR EL SCRIPT (decision de seguridad, no de estilo):
# el SHA256SUMS viaja en el MISMO release que el asset. Quien pueda alterar uno altera el otro
# y ambos seguirian cuadrando. Ademas AXE se instala en %LOCALAPPDATA% (escribible por el
# usuario) y luego AXE.bat lo ELEVA a admin: un proceso sin privilegios que consiga escribir
# ahi se convierte en admin la proxima vez que el usuario abra AXE. Por eso Invoke-AXEUpdate
# solo REEMPLAZA con firma Authenticode valida; sin firma informa y se para. Es menos comodo y
# es lo correcto: el updater no puede ser el eslabon debil de la cadena que el resto del
# proyecto presume de tener.
#
# Reparto igual que el resto del motor: aqui vive lo PURO y testeable (comparar versiones,
# generar/parsear checksums, construir el SBOM); la red queda en funciones finas que degradan
# a $null en vez de lanzar, para que la CI sin red no se ponga roja.
#
# Este modulo se dot-sourcea SUELTO desde scripts/New-AXERelease.ps1 (que no carga el motor
# entero). Por eso no depende de nada de 05-core: el log va por el helper guardado de abajo y
# las rutas se pasan siempre por parametro.

# Repo oficial HARDCODED, a posta. Un updater al que se le puede decir owner/repo por
# parametro o por fichero de config es un updater al que se le puede decir de donde bajar.
$script:AXEUpdateOwner = 'CARTY240HZ'
$script:AXEUpdateRepo  = 'AXE'
# Hosts desde los que GitHub sirve assets de release. Se comprueba el host de la URL que
# devuelve la API ANTES de descargar: aunque la respuesta viniera manipulada, no se baja de un
# dominio arbitrario.
$script:AXEUpdateHosts = @('github.com','objects.githubusercontent.com','release-assets.githubusercontent.com')

function Write-AXEUpdLog {
    # 05-core puede no estar cargado (uso suelto desde el script de release): degrada a verbose.
    param([string]$Msg,[string]$Level='INFO')
    if(Get-Command Write-AXELog -EA SilentlyContinue){ Write-AXELog $Msg $Level } else { Write-Verbose "[$Level] $Msg" }
}

# --- Version ------------------------------------------------------------------------------

function ConvertTo-AXEVersionParts {
    # SemVer parcial A POSTA: numeros + prerelease. Los metadatos de build (+sha) se ignoran
    # porque por spec de SemVer no participan en la precedencia. No se usa [version] de .NET
    # porque trata '7.1.0-beta' como invalido y porque su cuarto campo (revision) no es SemVer.
    param([string]$Version)
    if([string]::IsNullOrWhiteSpace($Version)){ return $null }
    $s = $Version.Trim()
    if($s -match '^[vV]'){ $s = $s.Substring(1) }
    $plus = $s.IndexOf('+'); if($plus -ge 0){ $s = $s.Substring(0,$plus) }
    $pre = ''
    $dash = $s.IndexOf('-'); if($dash -ge 0){ $pre = $s.Substring($dash+1); $s = $s.Substring(0,$dash) }
    $nums = @()
    foreach($p in ($s -split '\.')){
        $n = 0
        if(-not [int]::TryParse($p,[ref]$n)){ return $null }   # '7.x.0' no es una version
        $nums += $n
    }
    if($nums.Count -eq 0){ return $null }
    while($nums.Count -lt 3){ $nums += 0 }                      # '7' y '7.0' == '7.0.0'
    [pscustomobject]@{ Numbers = $nums; PreRelease = $pre }
}

function Compare-AXEVersion {
    # -1 si A < B, 0 si iguales, 1 si A > B. $null si alguna no es parseable: quien llama
    # decide que hacer, en vez de recibir un 0 que se confunde con "estan al dia".
    param([string]$A,[string]$B)
    $pa = ConvertTo-AXEVersionParts $A; $pb = ConvertTo-AXEVersionParts $B
    if(-not $pa -or -not $pb){ return $null }
    $n = [math]::Max($pa.Numbers.Count,$pb.Numbers.Count)
    for($i=0; $i -lt $n; $i++){
        $x = if($i -lt $pa.Numbers.Count){ $pa.Numbers[$i] } else { 0 }
        $y = if($i -lt $pb.Numbers.Count){ $pb.Numbers[$i] } else { 0 }
        if($x -lt $y){ return -1 }
        if($x -gt $y){ return 1 }
    }
    # SemVer §11: una version CON prerelease va SIEMPRE por debajo de la misma sin el. Sin
    # esto '7.1.0-beta' y '7.1.0' saldrian iguales y el updater no ofreceria la estable.
    if($pa.PreRelease -eq $pb.PreRelease){ return 0 }
    if([string]::IsNullOrEmpty($pa.PreRelease)){ return 1 }
    if([string]::IsNullOrEmpty($pb.PreRelease)){ return -1 }
    [math]::Sign([string]::CompareOrdinal($pa.PreRelease,$pb.PreRelease))
}

# --- Firma --------------------------------------------------------------------------------

function Test-AXESignature {
    # $true SOLO con Status 'Valid'. 'NotSigned', 'HashMismatch', 'NotTrusted' y
    # 'UnknownError' son todos $false: a la hora de decidir si se reemplaza un fichero que
    # luego correra ELEVADO no se distingue "aun no firmado" de "firma rota".
    param([string]$Path)
    if([string]::IsNullOrWhiteSpace($Path)){ return $false }
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ return $false }
    try { return ((Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).Status -eq 'Valid') }
    catch { return $false }
}

function Get-AXESignatureInfo {
    # Detalle para el informe (quien firma, si lleva timestamp). Nunca lanza.
    param([string]$Path)
    $out = [pscustomobject]@{ Path=$Path; Valid=$false; Status='NotChecked'; Signer=$null; TimeStamped=$false }
    if([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)){
        $out.Status = 'NotFound'; return $out
    }
    try {
        $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $out.Status      = [string]$s.Status
        $out.Valid       = ($s.Status -eq 'Valid')
        $out.Signer      = if($s.SignerCertificate){ $s.SignerCertificate.Subject } else { $null }
        $out.TimeStamped = [bool]$s.TimeStamperCertificate
    } catch { $out.Status = 'Error' }
    $out
}

# --- Checksums ----------------------------------------------------------------------------

function New-AXEChecksums {
    # Formato coreutils ('<sha256>  <nombre>', dos espacios) para que se pueda verificar con
    # `sha256sum -c SHA256SUMS` desde cualquier Linux/WSL sin fiarse de una herramienta
    # nuestra. Determinista: orden ordinal por nombre, hex en minusculas, LF y UTF-8 SIN BOM.
    # Dos ejecuciones sobre los mismos ficheros dan bytes identicos, que es lo que permite
    # comprobar en CI que el release no derivo.
    param(
        [Parameter(Mandatory)][string]$Dir,
        [string]$OutFile,
        [string[]]$Exclude = @('SHA256SUMS','SHA256SUMS.sig')
    )
    if(-not (Test-Path -LiteralPath $Dir -PathType Container)){ throw "New-AXEChecksums: no existe el directorio '$Dir'" }
    if(-not $OutFile){ $OutFile = Join-Path $Dir 'SHA256SUMS' }
    $files = @(Get-ChildItem -LiteralPath $Dir -File |
               Where-Object { $Exclude -notcontains $_.Name } |
               Sort-Object { $_.Name })
    $lines = foreach($f in $files){
        '{0}  {1}' -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $f.Name
    }
    $text = if(@($lines).Count){ (@($lines) -join "`n") + "`n" } else { '' }
    [IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding $false))
    Write-AXEUpdLog "SHA256SUMS generado sobre $(@($files).Count) ficheros de '$Dir'"
    $OutFile
}

function Get-AXEChecksumFor {
    # Extrae el hash de UN nombre concreto del texto de un SHA256SUMS. $null si no esta: quien
    # llama debe negarse a instalar, nunca asumir que "no listado" equivale a "correcto".
    param([string]$SumsText,[string]$Name)
    if([string]::IsNullOrWhiteSpace($SumsText) -or [string]::IsNullOrWhiteSpace($Name)){ return $null }
    foreach($line in ($SumsText -split "`r?`n")){
        # El '*' opcional es el marcador de modo binario de coreutils.
        if($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$'){
            if($Matches[2] -eq $Name){ return $Matches[1].ToLowerInvariant() }
        }
    }
    $null
}

function Test-AXEChecksumFile {
    # Comprueba UN fichero contra el hash esperado. Comparacion ordinal sobre hex, no el -eq
    # de PowerShell sobre objetos. $false ante cualquier duda.
    param([string]$Path,[string]$Expected)
    if([string]::IsNullOrWhiteSpace($Expected)){ return $false }
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ return $false }
    try { $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return $false }
    [string]::Equals($actual, $Expected, [StringComparison]::OrdinalIgnoreCase)
}

function Test-AXEChecksums {
    # Verifica un directorio entero contra su SHA256SUMS. Devuelve la LISTA de problemas
    # (vacia = todo OK), no un bool: si algo falla hay que poder decir QUE fallo.
    param([Parameter(Mandatory)][string]$Dir,[string]$SumsPath)
    if(-not $SumsPath){ $SumsPath = Join-Path $Dir 'SHA256SUMS' }
    $bad = New-Object System.Collections.ArrayList
    if(-not (Test-Path -LiteralPath $SumsPath -PathType Leaf)){ [void]$bad.Add("falta $SumsPath"); return $bad.ToArray() }
    $text = Get-Content -LiteralPath $SumsPath -Raw -Encoding UTF8
    $seen = 0
    foreach($line in ($text -split "`r?`n")){
        if([string]::IsNullOrWhiteSpace($line)){ continue }
        if($line -notmatch '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$'){ [void]$bad.Add("linea ilegible: '$line'"); continue }
        $seen++
        $hash = $Matches[1]; $name = $Matches[2]
        $p = Join-Path $Dir $name
        if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ [void]$bad.Add("listado pero ausente: $name"); continue }
        if(-not (Test-AXEChecksumFile $p $hash)){ [void]$bad.Add("hash no cuadra: $name") }
    }
    if($seen -eq 0){ [void]$bad.Add('SHA256SUMS vacio') }
    $bad.ToArray()
}

# --- SBOM ---------------------------------------------------------------------------------

function New-AXESbom {
    # CycloneDX 1.5 a mano (~40 lineas) en vez de traer cyclonedx-cli: seria una dependencia
    # binaria de terceros en el pipeline de release, justo la clase de cosa que este
    # subproyecto existe para no tener. El unico componente de terceros que AXE redistribuye
    # es el SDK de WebView2 (3 DLL); PresentMon NO se vendoriza (lo aporta el usuario) y por
    # eso no aparece aqui: un SBOM que lista lo que no envias es un SBOM que miente.
    param(
        [Parameter(Mandatory)][string]$Root,     # raiz del repo (donde vive webview2/)
        [Parameter(Mandatory)][string]$Version,  # version de AXE
        [string]$OutFile
    )
    if(-not $OutFile){ $OutFile = Join-Path $Root 'sbom.json' }
    $components = New-Object System.Collections.ArrayList

    $wv = Join-Path $Root 'webview2'
    if(Test-Path -LiteralPath $wv){
        foreach($f in @(Get-ChildItem -LiteralPath $wv -Recurse -File -Filter '*.dll' | Sort-Object { $_.Name })){
            $fv = $null
            try { $fv = $f.VersionInfo.FileVersion } catch {}
            if([string]::IsNullOrWhiteSpace($fv)){ $fv = 'unknown' } else { $fv = $fv.Trim() }
            [void]$components.Add([ordered]@{
                type      = 'library'
                name      = $f.BaseName
                version   = $fv
                publisher = 'Microsoft Corporation'
                purl      = ('pkg:nuget/Microsoft.Web.WebView2@{0}' -f $fv)
                hashes    = @(@{ alg='SHA-256'; content=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant() })
                # Licencia PROPIETARIA con permiso de redistribucion, no OSS. Se declara tal
                # cual: poner 'MIT' aqui porque queda mas limpio seria falsear el SBOM.
                licenses  = @(@{ license = @{ name = 'Microsoft Software License Terms - Microsoft Edge WebView2 SDK (redistributable)' } })
            })
        }
    }

    # serialNumber DETERMINISTA: UUID derivado del sha256 de (version + componentes). Un
    # [guid]::NewGuid() haria que dos SBOM del MISMO codigo salieran distintos, y entonces no
    # se podria comprobar en CI que el release no derivo.
    $seed = ($Version + '|' + ((@($components) | ForEach-Object { '{0}@{1}:{2}' -f $_.name,$_.version,$_.hashes[0].content }) -join ';'))
    $sha  = [Security.Cryptography.SHA256]::Create()
    try { $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($seed)) } finally { $sha.Dispose() }
    $uuid = [guid]::new([byte[]]$h[0..15])

    $bom = [ordered]@{
        bomFormat    = 'CycloneDX'
        specVersion  = '1.5'
        serialNumber = "urn:uuid:$uuid"
        version      = 1
        metadata     = [ordered]@{
            # Unico campo NO determinista del documento, y lo exige el formato.
            timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ',[cultureinfo]::InvariantCulture)
            component = [ordered]@{
                type     = 'application'
                name     = 'AXE'
                version  = $Version
                purl     = "pkg:github/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)@$Version"
                licenses = @(@{ license = @{ id = 'MIT' } })
            }
        }
        components   = @($components)
    }
    [IO.File]::WriteAllText($OutFile, ($bom | ConvertTo-Json -Depth 12), (New-Object System.Text.UTF8Encoding $false))
    Write-AXEUpdLog "sbom.json generado con $(@($components).Count) componentes de terceros"
    $OutFile
}

# --- Release remoto -----------------------------------------------------------------------

function ConvertFrom-AXEReleaseJson {
    # Separado de la llamada de red A POSTA: asi el parseo se testea con un fixture local y la
    # CI no necesita salir a internet (misma politica que Fps.Tests con PresentMon).
    param($Release)
    if(-not $Release -or [string]::IsNullOrWhiteSpace([string]$Release.tag_name)){ return $null }
    $assets = @()
    foreach($a in @($Release.assets)){
        if([string]::IsNullOrWhiteSpace([string]$a.name)){ continue }
        $size = 0L; try { $size = [int64]$a.size } catch {}
        $assets += [pscustomobject]@{
            Name = [string]$a.name
            Url  = [string]$a.browser_download_url
            Size = $size
        }
    }
    [pscustomobject]@{
        Tag         = [string]$Release.tag_name
        Version     = ([string]$Release.tag_name) -replace '^[vV]',''
        PublishedAt = [string]$Release.published_at
        PreRelease  = [bool]$Release.prerelease
        Assets      = $assets
    }
}

function Get-AXELatestRelease {
    # GET publico a la API de GitHub: sin token, sin telemetria, sin enviar nada del equipo.
    # Devuelve $null ante CUALQUIER problema -sin red, rate limit, JSON raro-: comprobar
    # actualizaciones no puede tumbar la herramienta.
    param([string]$Uri)
    if(-not $Uri){ $Uri = "https://api.github.com/repos/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/latest" }
    try {
        # PS 5.1 negocia SSL3/TLS1.0 por defecto contra api.github.com y falla.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        $r = Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 20 -ErrorAction Stop `
                -Headers @{ 'User-Agent' = 'AXE-Updater'; 'Accept' = 'application/vnd.github+json' }
    } catch {
        Write-AXEUpdLog "No pude consultar releases: $($_.Exception.Message)" 'WARN'
        return $null
    }
    ConvertFrom-AXEReleaseJson $r
}

function Test-AXEAssetUrl {
    # La URL tiene que ser https, de un host de GitHub conocido Y (en github.com) apuntar a
    # owner/repo. Aunque la respuesta de la API llegara manipulada, no se descarga de un
    # dominio arbitrario.
    param([string]$Url)
    if([string]::IsNullOrWhiteSpace($Url)){ return $false }
    $u = $null
    if(-not [uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$u)){ return $false }
    if($u.Scheme -ne 'https'){ return $false }
    if($script:AXEUpdateHosts -notcontains $u.Host){ return $false }
    # En los hosts de CDN el owner/repo no va en la ruta (es un blob opaco firmado por
    # GitHub), asi que ahi basta el host: el enlace lo emitio la propia API de ESTE repo.
    if($u.Host -eq 'github.com' -and $u.AbsolutePath -notlike "/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/*"){ return $false }
    $true
}

# --- Updater ------------------------------------------------------------------------------

function Invoke-AXEUpdate {
    <#
      Estados devueltos (Status):
        current    ya estas en la ultima
        available  hay una nueva (modo -Check)
        updated    descargada, VERIFICADA y reemplazada
        refused    hay una nueva pero NO se puede verificar -> no se toca nada
        error      no se pudo comprobar (sin red, API rara, version ilegible, escritura fallida)
      Nunca lanza: quien llama imprime .Message y sale con el codigo que quiera.
    #>
    param(
        [switch]$Check,
        [string]$Target,          # fichero a reemplazar. Default: el AXE.ps1 en ejecucion.
        [object]$Release          # inyectable para test; si falta se consulta la API.
    )
    $current = if($script:AXEVersion){ [string]$script:AXEVersion } else { '0.0.0' }
    $mk = { param($s,$l,$m) [pscustomobject]@{ Status=$s; Current=$current; Latest=$l; Message=$m } }

    if(-not $Release){ $Release = Get-AXELatestRelease }
    if(-not $Release){ return (& $mk 'error' $null 'No pude comprobar actualizaciones (sin red, o la API de GitHub no respondio). No se ha tocado nada.') }

    $cmp = Compare-AXEVersion $current $Release.Version
    if($null -eq $cmp){ return (& $mk 'error' $Release.Version "No entiendo alguna de las dos versiones (local '$current', remota '$($Release.Version)'). No se ha tocado nada.") }
    if($cmp -ge 0){ return (& $mk 'current' $Release.Version "Estas en la ultima version ($current).") }

    if($Check){ return (& $mk 'available' $Release.Version "Hay una version nueva: $current -> $($Release.Version). Instalala con:  AXE -Update") }

    if(-not $Target){ $Target = $PSCommandPath }
    if([string]::IsNullOrWhiteSpace($Target) -or -not (Test-Path -LiteralPath $Target -PathType Leaf)){
        return (& $mk 'error' $Release.Version 'No pude localizar el AXE.ps1 a reemplazar. Descarga el release a mano.')
    }

    $asset = @($Release.Assets | Where-Object Name -eq 'AXE.ps1')    | Select-Object -First 1
    $sums  = @($Release.Assets | Where-Object Name -eq 'SHA256SUMS') | Select-Object -First 1
    if(-not $asset -or -not $sums){
        return (& $mk 'refused' $Release.Version "El release $($Release.Tag) no trae AXE.ps1 + SHA256SUMS. No se instala nada sin las dos cosas.")
    }
    foreach($a in @($asset,$sums)){
        if(-not (Test-AXEAssetUrl $a.Url)){
            return (& $mk 'refused' $Release.Version "La URL de '$($a.Name)' no apunta al repo oficial. Descarga abortada.")
        }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('axe_upd_{0}' -f [guid]::NewGuid())
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
        $newPs   = Join-Path $tmp 'AXE.ps1'
        $newSums = Join-Path $tmp 'SHA256SUMS'
        try {
            Invoke-WebRequest -Uri $asset.Url -OutFile $newPs   -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
            Invoke-WebRequest -Uri $sums.Url  -OutFile $newSums -TimeoutSec 60  -UseBasicParsing -ErrorAction Stop
        } catch {
            return (& $mk 'error' $Release.Version "Fallo la descarga: $($_.Exception.Message). No se ha tocado nada.")
        }

        # (1) INTEGRIDAD: el fichero llego entero.
        $want = Get-AXEChecksumFor (Get-Content -LiteralPath $newSums -Raw -Encoding UTF8) 'AXE.ps1'
        if(-not $want){ return (& $mk 'refused' $Release.Version 'El SHA256SUMS del release no lista AXE.ps1. Abortado sin tocar nada.') }
        if(-not (Test-AXEChecksumFile $newPs $want)){
            return (& $mk 'refused' $Release.Version 'El SHA256 del AXE.ps1 descargado NO coincide con el publicado. Abortado sin tocar nada.')
        }

        # (2) AUTENTICIDAD: quien lo firmo. Es lo unico que el checksum NO puede dar, porque
        #     ambos ficheros vienen del mismo release. Sin firma valida NO se reemplaza: el
        #     destino es escribible por el usuario y AXE.bat lo ejecuta ELEVADO despues.
        if(-not (Test-AXESignature $newPs)){
            return (& $mk 'refused' $Release.Version @"
El AXE.ps1 de $($Release.Tag) no lleva firma Authenticode valida: no se reemplaza nada.
El checksum SI cuadra, pero viaja en el mismo release que el fichero, asi que prueba que
llego entero, no QUIEN lo publico. Como AXE se ejecuta elevado, reemplazarlo sin firma
convertiria al updater en la via de escalada de privilegios que el resto del proyecto evita.
Descarga el release a mano si quieres continuar:
  https://github.com/$($script:AXEUpdateOwner)/$($script:AXEUpdateRepo)/releases/tag/$($Release.Tag)
"@)
        }

        # (3) REEMPLAZO ATOMICO: se escribe al lado del destino (mismo volumen => Move-Item es
        #     un rename, no una copia a medias) y se sustituye de una. Nunca queda un AXE.ps1
        #     truncado si el proceso muere en medio.
        $stage = "$Target.new"
        try {
            Copy-Item -LiteralPath $newPs -Destination $stage -Force -ErrorAction Stop
            Move-Item -LiteralPath $stage -Destination $Target -Force -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $stage -Force -ErrorAction SilentlyContinue
            return (& $mk 'error' $Release.Version "Verificado pero no pude escribir en '$Target': $($_.Exception.Message). Cierra AXE y reintenta.")
        }
        Write-AXEUpdLog "Actualizado $current -> $($Release.Version) (firma y checksum verificados)"
        return (& $mk 'updated' $Release.Version "Actualizado a $($Release.Version). Firma y checksum verificados. Reinicia AXE.")
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
