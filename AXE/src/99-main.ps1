$win.Add_Closed({
    foreach($t in @($script:hwTimer,$script:jobTimer,$script:rsTimer,$script:applyTimer,$script:mrTimer,$script:profTimer)){
        if($t){ try { $t.Stop() } catch {} }
    }
    foreach($psRef in @($script:hwPS,$script:jobPS,$script:rsPS)){
        if($psRef){ try { $psRef.Stop() } catch {}; try { $psRef.Dispose() } catch {} }
    }
    $script:hwPS=$null; $script:jobPS=$null; $script:rsPS=$null
})
[void]$win.ShowDialog()
