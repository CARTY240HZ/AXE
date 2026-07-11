# =====================================================
# LW Suite v6 - Logging (headless, no UI dependency)
# Mirrors v4 Write-LWLog (LWSuite_v4.ps1:39-49) minus the GUI sink
# (the GUI sink is wired separately by the entrypoint when in GUI mode).
# =====================================================
$script:LWRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$script:LWData = Join-Path $script:LWRoot 'LWSuite'
$script:LWBackup = Join-Path $script:LWData 'Backups'
$script:LWLogPath = Join-Path $script:LWData ("lw_log_{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
$script:LogBox = $null        # set by GUI entrypoint; null in headless
$script:LWLogSink = $null     # set by GUI entrypoint

# Ensure data dirs exist (idempotent)
foreach($d in @($script:LWData,$script:LWBackup)){ if(-not(Test-Path $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null } }

function Write-LWLog {
    param([string]$Msg,[string]$Level='INFO')
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'),$Level,$Msg
    # Ensure parent dir exists (Set-LWLogPath can point anywhere; Add-Content won't create dirs)
    $dir = Split-Path $script:LWLogPath -Parent
    if($dir -and -not(Test-Path $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $script:LWLogPath -Value $line -Encoding UTF8
    if($script:LogBox -and $script:LWLogSink){
        try {
            if($script:LogBox.Dispatcher.CheckAccess()){ & $script:LWLogSink $line $Level }
            else { $script:LogBox.Dispatcher.Invoke([action]{ & $script:LWLogSink $line $Level }) }
        } catch {}
    }
}

function Set-LWLogPath { param([string]$Path) $script:LWLogPath = $Path }
