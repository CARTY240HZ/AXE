BeforeAll {
    $script:cat = Get-Content "$PSScriptRoot\..\config\tweaks.json" -Raw | ConvertFrom-Json
}

Describe 'Catalog schema' {
    It 'Has at least 10 tweaks (mass critical)' {
        (@($script:cat.PSObject.Properties)).Count | Should -BeGreaterOrEqual 10
    }

    It 'Every tweak has required scalar fields' {
        $required = 'Category','Tier','Reboot','Name','Desc','Requires'
        foreach($prop in $script:cat.PSObject.Properties){
            $tw = $prop.Value
            foreach($f in $required){
                $tw.PSObject.Properties.Name | Should -Contain $f -Because "$($prop.Name) needs $f"
            }
        }
    }

    It 'Every tweak has at least one action (Registry, Service, or Script)' {
        foreach($prop in $script:cat.PSObject.Properties){
            $tw = $prop.Value
            ($tw.PSObject.Properties.Name -contains 'Registry') -or
            ($tw.PSObject.Properties.Name -contains 'Service') -or
            ($tw.PSObject.Properties.Name -contains 'Script') |
                Should -BeTrue -Because "$($prop.Name) needs an action"
        }
    }

    It 'Tier is in {0,1,2}' {
        foreach($prop in $script:cat.PSObject.Properties){
            $prop.Value.Tier | Should -BeIn 0,1,2 -Because $prop.Name
        }
    }

    It 'IDs are unique (JSON keys are the IDs)' {
        $ids = $script:cat.PSObject.Properties.Name
        ($ids | Group-Object | Where-Object Count -gt 1).Count | Should -Be 0
    }

    It 'Every Registry entry has OriginalValue (reversibility)' {
        foreach($prop in $script:cat.PSObject.Properties){
            $tw = $prop.Value
            if($tw.PSObject.Properties.Name -contains 'Registry'){
                foreach($r in $tw.Registry){
                    $r.PSObject.Properties.Name | Should -Contain 'OriginalValue' -Because "$($prop.Name) registry entry must be reversible"
                }
            }
        }
    }

    It 'Every Script entry has Test, Apply, AND Undo (reversibility)' {
        foreach($prop in $script:cat.PSObject.Properties){
            $tw = $prop.Value
            if($tw.PSObject.Properties.Name -contains 'Script'){
                $tw.Script.PSObject.Properties.Name | Should -Contain 'Test'  -Because $prop.Name
                $tw.Script.PSObject.Properties.Name | Should -Contain 'Apply' -Because $prop.Name
                $tw.Script.PSObject.Properties.Name | Should -Contain 'Undo'  -Because $prop.Name
            }
        }
    }

    It 'svc_remotereg is the only unidirectional tweak' {
        $unidir = @()
        foreach($prop in $script:cat.PSObject.Properties){
            if($prop.Value.PSObject.Properties.Name -contains 'Unidirectional' -and $prop.Value.Unidirectional){ $unidir += $prop.Name }
        }
        $unidir | Should -Be @('svc_remotereg')
    }
}
