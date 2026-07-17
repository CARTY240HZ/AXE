# =====================================================
# REGION 1 - PATHS & LOGGING  (headless, sin UI)
# =====================================================
$script:AXERoot   = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AXEData   = Join-Path $script:AXERoot 'AXE'
$script:AXEBackup = Join-Path $script:AXEData 'Backups'
$script:AXELog    = Join-Path $script:AXEData ("axe_log_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$script:RunBak   = Join-Path $script:AXEData 'startup_disabled.json'
$script:StateBak = Join-Path $script:AXEData 'tweak_state.json'   # snapshot revert: estado previo real por tweak
# Migracion de datos legacy: si existe <root>/LWSuite/ (motor v4 pre-rebrand) y aun no hay
# <root>/AXE/, moverlo entero (Backups, logs, startup_disabled.json). Idempotente.
$legacy = Join-Path $script:AXERoot 'LWSuite'
if((Test-Path $legacy) -and -not (Test-Path $script:AXEData)){
    Move-Item -Path $legacy -Destination $script:AXEData -Force -EA Stop
}
foreach($d in @($script:AXEData,$script:AXEBackup)){ if(-not(Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$script:LogBox = $null
function Write-AXELog {
    param([string]$Msg,[string]$Level='INFO')
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Msg
    Add-Content -Path $script:AXELog -Value $line -Encoding UTF8
    if($script:LogBox -and $script:AXELogSink){
        try {
            if($script:LogBox.Dispatcher.CheckAccess()){ & $script:AXELogSink $line $Level }
            else { $script:LogBox.Dispatcher.Invoke([action]{ & $script:AXELogSink $line $Level }) }
        } catch {}
    }
}

# =====================================================
# REGION 2 - HARDWARE DETECTION  (define que tweaks son validos)
# =====================================================
function Get-AXEHardware {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $os  = Get-CimInstance Win32_OperatingSystem
    $enc = @((Get-CimInstance Win32_SystemEnclosure).ChassisTypes)
    $isLaptop = ($enc | Where-Object { $_ -in 8,9,10,11,12,14,18,21,30,31,32 }).Count -gt 0
    $isHybrid = $false
    try { if($cpu.Name -match '1[2-9]th Gen' -or $cpu.Name -match 'Ultra'){ $isHybrid = $true } } catch {}
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'Virtual|Basic|Meta|Parsec|Remote' }
    $hasNvidia = @($gpu | Where-Object Name -match 'NVIDIA').Count -gt 0
    $activeNic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | Select-Object -First 1
    $isWifi = $activeNic -and ($activeNic.PhysicalMediaType -match 'Native 802.11|Wireless' -or $activeNic.Name -match 'Wi-?Fi|Wireless')
    $edition = $os.Caption
    $onBattery = $false
    try { $b = Get-CimInstance Win32_Battery -ErrorAction Stop; if($b -and $b.BatteryStatus -ne 2){ $onBattery = $true } } catch {}
    # WinVer: Win11 = build >= 22000 (corte oficial Microsoft), Win10 = resto de 10.0.x
    $build = $os.BuildNumber
    $isWin11 = [int]$build -ge 22000
    # --- ecosistema (§3.1): arquitectura, vendor, seguridad. Todo self-contained (corre en runspace) ---
    $cpuArch   = $env:PROCESSOR_ARCHITECTURE                 # AMD64 / ARM64 / x86
    $cpuVendor = $cpu.Manufacturer                            # GenuineIntel / AuthenticAMD / Qualcomm...
    # Defender + Tamper: una sola llamada (lenta), ambos derivados. AV de terceros -> el cmdlet falla o AMServiceEnabled=false.
    $mp = $null; try { $mp = Get-MpComputerStatus -ErrorAction Stop } catch {}
    $hasDefender = [bool]($mp -and $mp.AMServiceEnabled)
    $isTamper    = [bool]($mp -and $mp.IsTamperProtected)
    # S mode: SkuPolicyRequired=1 en CI\Policy (try/catch, default no-S)
    $isSMode = $false
    try { $isSMode = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name SkuPolicyRequired -ErrorAction Stop).SkuPolicyRequired -eq 1) } catch {}
    # HAGS: heuristica conservadora. El OS solo crea el valor HwSchMode en GPUs WDDM>=2.7 capaces;
    # ausente => tratamos como no-soportado (ocultar), nunca falso-positivo que aplique HAGS en HW incompatible.
    $supportsHAGS = $false
    try { $supportsHAGS = ($null -ne (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -ErrorAction Stop).HwSchMode) } catch {}
    [pscustomobject]@{
        CpuName=$cpu.Name; Cores=$cpu.NumberOfCores; Threads=$cpu.NumberOfLogicalProcessors
        IsLaptop=$isLaptop; IsHybrid=$isHybrid; HasNvidia=$hasNvidia
        IsWifi=[bool]$isWifi; NicName=$activeNic.Name; Edition=$edition
        IsHome=($edition -match 'Home'); OnBattery=$onBattery
        IsWin11=$isWin11; BuildNumber=$build
        RamGB=[math]::Round($os.TotalVisibleMemorySize/1MB,1)
        CpuArch=$cpuArch; CpuVendor=$cpuVendor
        HasDefender=$hasDefender; IsTamperProtected=$isTamper
        IsSMode=$isSMode; SupportsHAGS=$supportsHAGS
    }
}

