# Unit — Get-BlockReason (§3.2). Matriz de ecosistema con $script:HW sintetico.
# No toca hardware real: inyecta el objeto HW y comprueba el motivo de bloqueo.
BeforeAll {
    $script:CAT = New-Object System.Collections.ArrayList
    . "$PSScriptRoot/../src/20-tweaks.ps1"
    . "$PSScriptRoot/../src/23-defender.ps1"

    function Set-HW {
        param([hashtable]$Over = @{})
        $base = @{
            RamGB=16; IsLaptop=$false; IsHybrid=$false; OnBattery=$false; IsWifi=$false
            IsHome=$false; HasNvidia=$true; IsWin11=$true; BuildNumber=26100
            CpuArch='AMD64'; CpuVendor='AuthenticAMD'; HasDefender=$true
            IsTamperProtected=$false; IsSMode=$false; SupportsHAGS=$true
        }
        foreach ($k in $Over.Keys) { $base[$k] = $Over[$k] }
        $script:HW = [pscustomobject]$base
    }
    function Tw($id) { $script:CAT | Where-Object Id -eq $id }
}

Describe 'Get-BlockReason — ecosistema (§3.2)' -Tag 'unit' {

    It 'MinRam bloquea con RAM insuficiente (8GB)' {
        Set-HW @{ RamGB = 8 }
        Get-BlockReason (Tw 'mem_pagingexec') | Should -Match '16GB'
    }

    It 'MinRam pasa con RAM holgada (32GB)' {
        Set-HW @{ RamGB = 32 }
        Get-BlockReason (Tw 'mem_pagingexec') | Should -BeNullOrEmpty
    }

    It 'mem_ntfsmem exige >=12GB' {
        Set-HW @{ RamGB = 8 }
        Get-BlockReason (Tw 'mem_ntfsmem') | Should -Match '12GB'
    }

    It 'HAGS bloquea sin soporte WDDM' {
        Set-HW @{ SupportsHAGS = $false }
        Get-BlockReason (Tw 'gpu_hags') | Should -Match 'HAGS'
    }

    It 'TamperOff bloquea ext_vbs con Tamper ON' {
        Set-HW @{ IsTamperProtected = $true }
        Get-BlockReason (Tw 'ext_vbs') | Should -Match 'Tamper'
    }

    It 'Defender bloquea def_cpulimit con AV de terceros' {
        Set-HW @{ HasDefender = $false }
        Get-BlockReason (Tw 'def_cpulimit') | Should -Match 'Defender'
    }

    It 'ARM64 no afecta a un tweak sin CpuArch' {
        Set-HW @{ CpuArch = 'ARM64' }
        Get-BlockReason (Tw 'cpu_mmcss') | Should -BeNullOrEmpty
    }

    It 'sin HW cargado no bloquea nada (arranque en runspace)' {
        $script:HW = $null
        Get-BlockReason (Tw 'mem_pagingexec') | Should -BeNullOrEmpty
    }
}
