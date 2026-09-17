# =====================================================
# REGION 13d - PRIVILEGED BROKER ENTRYPOINT
# =====================================================
# Lexically after 47c-privbroker so Start-AXEBrokerServer is already defined.
# Runs before 48-webbridge/49-webmain. Normal GUI/CLI execution never enters this block.
if($BrokerServer){
    if([string]::IsNullOrWhiteSpace($BrokerPipeName) -or [string]::IsNullOrWhiteSpace($BrokerNonce)){
        Write-Error 'BrokerServer requiere -BrokerPipeName y -BrokerNonce.'
        exit 2
    }
    try {
        [void](Start-AXEBrokerServer -PipeName $BrokerPipeName -ExpectedNonce $BrokerNonce)
        exit 0
    } catch {
        Write-Error ("BrokerServer fallo: {0}" -f $_.Exception.Message)
        exit 1
    }
}
