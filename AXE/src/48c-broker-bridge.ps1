# =====================================================
# REGION 14d - BRIDGE -> PRIVILEGED BROKER
# =====================================================
# Only operations that modify system state are routed through the elevated broker when the GUI
# process is unelevated. Read-only measurements remain local to minimize privileged attack surface.

if($script:AXEBridgeMap -is [hashtable]){
    foreach($name in @('tweaks.apply','tweaks.revert','tweaks.masterRevert')){
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
