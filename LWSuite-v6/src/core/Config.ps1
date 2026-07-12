# =====================================================
# LW Suite v6 - Config loader + manifest hash verification (security §6)
# =====================================================
function Import-LWConfig {
    param([string]$ConfigDir)
    $manifestPath = Join-Path $ConfigDir 'manifest.json'
    if(-not(Test-Path $manifestPath)){ throw "manifest.json no encontrado en $ConfigDir" }
    $manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $loaded = @{}
    foreach($name in 'tweaks','debloat','dns','clean'){
        $file = Join-Path $ConfigDir "$name.json"
        if(-not(Test-Path $file)){ throw "$name.json no encontrado" }
        $raw = Get-Content $file -Raw -Encoding UTF8
        # Verify SHA-256 against manifest
        $hash = (Get-FileHash -Algorithm SHA256 -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($raw)))).Hash.ToLower()
        $expected = ($manifest.files.$name -replace '^sha256:','').ToLower()
        if($hash -ne $expected){
            Write-LWLog "Hash mismatch en $name.json (esperado $expected, actual $hash). Abortando." 'ERR'
            throw "Integridad comprometida: $name.json no coincide con manifest. Ejecuta Build.ps1 para regenerar, o restaura desde una copia limpia."
        }
        $loaded[$name] = $raw | ConvertFrom-Json
    }
    return $loaded
}

# Helper for Build.ps1: generate manifest from current config files
function New-LWManifest {
    param([string]$ConfigDir,[string]$Version='6.0.0')
    $files = @{}
    foreach($name in 'tweaks','debloat','dns','clean'){
        $file = Join-Path $ConfigDir "$name.json"
        if(-not(Test-Path $file)){ continue }
        $raw = Get-Content $file -Raw -Encoding UTF8
        $hash = (Get-FileHash -Algorithm SHA256 -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($raw)))).Hash.ToLower()
        $files[$name] = "sha256:$hash"
    }
    $manifest = [pscustomobject]@{
        version = $Version
        generated = (Get-Date).ToString('o')
        files = $files
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $ConfigDir 'manifest.json') -Encoding UTF8
}
