# =====================================================
# REGION 11b - PRIVILEGED BROKER ENTRYPOINT
# =====================================================
# This module is loaded after the complete business engine (1-45) but before the WebView2 host.
# If -BrokerServer is present, handle exactly one authenticated IPC request and terminate before
# any GUI code can load. Normal GUI/CLI execution never enters this block.
if($BrokerServer){
    if([string]::IsNullOrWhiteSpace($BrokerPipeName) -or [string]::IsNullOrWhiteSpace($BrokerNonce)){
        Write-Error 'BrokerServer requiere -BrokerPipeName y -BrokerNonce.'
        exit 2
    }
    try { [void](Start-AXEBrokerServer -PipeName $BrokerPipeName -ExpectedNonce $BrokerNonce); exit 0 }
    catch { Write-Error ("BrokerServer fallo: {0}" -f $_.Exception.Message); exit 1 }
}
