# =====================================================
# REGION 14d - BRIDGE -> PRIVILEGED BROKER
# =====================================================
# Loaded after 48-webbridge + 48b-bridge-security. Only operations that require admin are
# routed to the one-shot broker when the GUI host is unelevated. Read-only measurements and
# diagnostics remain in-process, preserving the existing UI path and minimizing IPC surface.

if($script:AXEBridgeMap -is [hashtable]){
    foreach($name in @('tweaks.apply','tweaks.revert','tweaks.masterRevert','fps.capture')){
        if(-not $script:AXEBridgeMap.ContainsKey($name)){ continue }
        $original = $script:AXEBridgeMap[$name]
        $script:AXEBridgeMap[$name] = {
            param($a)
            if(Test-Admin){
                & $original $a
            } else {
                Invoke-AXEPrivilegedBroker -Command $name -Args $a
            }
        }.GetNewClosure()
    }
}
