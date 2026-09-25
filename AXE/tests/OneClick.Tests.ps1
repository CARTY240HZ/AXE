# Unit - Optimizar en un clic (26-oneclick.ps1): que queda pendiente por tier y el estado que
# sobrevive al reinicio. Catalogo SINTETICO: nada toca el registro real.
BeforeAll {
    $script:CAT = New-Object System.Collections.ArrayList
    . "$PSScriptRoot/../src/10-reg-helpers.ps1"
    . "$PSScriptRoot/../src/20-tweaks.ps1"
    . "$PSScriptRoot/../src/28-revert-export.ps1"
    . "$PSScriptRoot/../src/26-oneclick.ps1"
    function T($id,$tier,[scriptblock]$test,$req=@{},$reboot=$false){
        [pscustomobject]@{ Id=$id; Tier=$tier; Name="n-$id"; Desc="d-$id"; Reboot=$reboot; Requires=$req; Test=$test; Apply={}; Revert={} }
    }
}

Describe 'Get-AXEOneClickPending - que queda por aplicar, por tier' -Tag 'unit' {
    BeforeEach { $script:HW = [pscustomobject]@{ IsLaptop=$true; IsHybrid=$false; NicName=$null } }
    It 'reparte por tier y deja fuera lo ya aplicado' {
        $cat = @( (T 'a0' 0 {$false}), (T 'b0' 0 {$true}), (T 'a1' 1 {$false} @{} $true), (T 'a2' 2 {$false}) )
        $p = Get-AXEOneClickPending -Catalog $cat
        @($p.t0 | ForEach-Object id) | Should -Be @('a0')
        @($p.t1 | ForEach-Object id) | Should -Be @('a1')
        @($p.t2 | ForEach-Object id) | Should -Be @('a2')
        $p.t1[0].reboot | Should -BeTrue
        $p.t1[0].name | Should -Be 'n-a1'
    }
    It 'deja fuera lo no aplicable en este hardware (solo-torre en portatil)' {
        $p = Get-AXEOneClickPending -Catalog @( (T 'desk' 1 {$false} @{ Desktop=$true }) )
        @($p.t1).Count | Should -Be 0
    }
    It 'un tweak ilegible sin admin (BCD) cuenta como pendiente: aplicar es idempotente' {
        function Test-Admin { $false }
        $p = Get-AXEOneClickPending -Catalog @( (T 'bcd' 1 { bcdedit /enum | Out-Null; $true }) )
        @($p.t1 | ForEach-Object id) | Should -Be @('bcd')
    }
    It 'catalogo vacio: tres listas vacias, sin reventar' {
        $p = Get-AXEOneClickPending -Catalog @()
        @($p.t0).Count + @($p.t1).Count + @($p.t2).Count | Should -Be 0
    }
}

Describe 'Save/Read-AXEOneClickState - sobrevive al reinicio' -Tag 'unit' {
    BeforeEach {
        $script:AXEData = Join-Path ([IO.Path]::GetTempPath()) ('axe-oc-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:AXEData -Force | Out-Null
    }
    AfterEach { Remove-Item $script:AXEData -Recurse -Force -EA SilentlyContinue }
    It 'sin fichero devuelve $null' { Read-AXEOneClickState | Should -BeNullOrEmpty }
    It 'ida y vuelta conserva ids, perfil y banderas' {
        Save-AXEOneClickState ([pscustomobject]@{ ts='t'; profile='equilibrado'; benchId='b1'; applied=@('x','y'); rebootNeeded=$true; done=$false })
        $s = Read-AXEOneClickState
        $s.profile | Should -Be 'equilibrado'
        @($s.applied) | Should -Be @('x','y')
        $s.rebootNeeded | Should -BeTrue
        $s.done | Should -BeFalse
    }
    It 'fichero corrupto devuelve corrupt=$true en vez de lanzar' {
        Set-Content -LiteralPath (Join-Path $script:AXEData 'oneclick_last.json') -Value '{no es json'
        (Read-AXEOneClickState).corrupt | Should -BeTrue
    }
}

Describe 'Test-AXEOneClickRebooted - no medir el despues ni pisar el registro antes de reiniciar (REGRESION ultrareview #15)' -Tag 'unit' {
    BeforeAll { $script:B1 = '2026-09-25T08:00:00.0000000Z'; $script:B2 = '2026-09-25T10:30:00.0000000Z' }
    It 'mismo arranque que al guardar = aun NO se ha reiniciado' {
        Test-AXEOneClickRebooted ([pscustomobject]@{ rebootNeeded=$true; bootTime=$script:B1 }) $script:B1 | Should -BeFalse
    }
    It 'otro arranque = ya se reinicio' {
        Test-AXEOneClickRebooted ([pscustomobject]@{ rebootNeeded=$true; bootTime=$script:B1 }) $script:B2 | Should -BeTrue
    }
    It 'unos segundos de diferencia en la lectura de CIM no cuentan como reinicio' {
        Test-AXEOneClickRebooted ([pscustomobject]@{ rebootNeeded=$true; bootTime='2026-09-25T08:00:00Z' }) '2026-09-25T08:00:02Z' | Should -BeFalse
    }
    It 'si no hacia falta reiniciar, cuenta como hecho' {
        Test-AXEOneClickRebooted ([pscustomobject]@{ rebootNeeded=$false; bootTime=$script:B1 }) $script:B1 | Should -BeTrue
    }
    It 'sin dato de arranque (registro antiguo o CIM caido) no se bloquea para siempre' {
        Test-AXEOneClickRebooted ([pscustomobject]@{ rebootNeeded=$true }) $script:B1 | Should -BeTrue
        Test-AXEOneClickRebooted ([pscustomobject]@{ rebootNeeded=$true; bootTime=$script:B1 }) $null | Should -BeTrue
    }
    It 'acepta el DateTime que entrega ConvertFrom-Json de pwsh' {
        $dt = [DateTime]::Parse($script:B1, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        Test-AXEOneClickRebooted ([pscustomobject]@{ rebootNeeded=$true; bootTime=$dt }) $script:B1 | Should -BeFalse
    }
}
