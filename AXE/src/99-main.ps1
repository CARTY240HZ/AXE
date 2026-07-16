$win.Add_Closed({
    foreach($t in @($script:hwTimer,$script:jobTimer,$script:rsTimer,$script:applyTimer,$script:mrTimer,$script:profTimer,$script:sbTimer,$script:measureTimer,$script:refTimer)){
        if($t){ try { $t.Stop() } catch {} }
    }
    foreach($psRef in @($script:hwPS,$script:jobPS,$script:rsPS,$script:measurePS)){
        if($psRef){ try { $psRef.Stop() } catch {}; try { $psRef.Dispose() } catch {} }
    }
    $script:hwPS=$null; $script:jobPS=$null; $script:rsPS=$null; $script:measurePS=$null
})
[void]$win.ShowDialog()
