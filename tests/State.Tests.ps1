BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')
    $script:GB = [long]1073741824
    $script:cfg = @{ DailyBudgetGB = 8; MonthlyBudgetGB = 250; StaleRunDays = 3 }
}

Describe 'Get-MirrorState' {
    It 'returns defaults when no file' {
        $s = Get-MirrorState -StateDir (Join-Path $TestDrive 'nostate')
        $s.Month | Should -BeNullOrEmpty
        $s.TransferredBytes | Should -Be 0
        $s.TransferredBytes | Should -BeOfType [long]
        $s.LastSuccess | Should -BeNullOrEmpty
        $s.Pairs | Should -BeOfType [hashtable]
        $s.Pairs.Count | Should -Be 0
        $s.PSObject.Properties.Name | Should -Not -Contain 'NotifiedUnmapped'
        $s.QuotaWarned | Should -BeFalse
    }

    It 'F1: an old state.json without DayStopped/MonthStopped loads with both empty, and they round-trip' {
        $dir = Join-Path $TestDrive 'oldstate-f1'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'state.json'), '{"Month":"2026-10","TransferredBytes":5,"Pairs":{}}')
        $s = Get-MirrorState -StateDir $dir
        $s.DayStopped | Should -BeNullOrEmpty
        $s.MonthStopped | Should -BeNullOrEmpty
        $s.LastPruneDay | Should -BeNullOrEmpty
        $s.LastPruneDay = '2026-10-23'
        $s.DayStopped = '2026-10-24'; $s.MonthStopped = '2026-10'
        Save-MirrorState -StateDir $dir -State $s
        $r = Get-MirrorState -StateDir $dir
        $r.DayStopped | Should -Be '2026-10-24'
        $r.MonthStopped | Should -Be '2026-10'
        $r.LastPruneDay | Should -Be '2026-10-23'
    }

    It 'round-trips through disk' {
        $dir = Join-Path $TestDrive 'rt'
        $s = Get-MirrorState -StateDir $dir
        $s.Month = '2026-10'
        $s.TransferredBytes = [long](3 * $script:GB)
        $s.LastSuccess = ([datetime]'2026-10-23').ToString('o')
        $s.PrivateConfirmedHash = 'abc123'
        $s.QuotaWarned = $true
        $s.Pairs['Music'] = @{ Seeded = $true; FilterHash = 'h1'; LastExit = 0; LastRun = '2026-10-23T10:00:00.0000000' }
        Save-MirrorState -StateDir $dir -State $s
        Test-Path (Join-Path $dir 'state.json') | Should -BeTrue
        Get-ChildItem $dir -Filter '*.tmp' | Should -BeNullOrEmpty

        $r = Get-MirrorState -StateDir $dir
        $r.Month | Should -Be '2026-10'
        $r.TransferredBytes | Should -Be ([long](3 * $script:GB))
        $r.TransferredBytes | Should -BeOfType [long]
        $r.PrivateConfirmedHash | Should -Be 'abc123'
        $r.QuotaWarned | Should -BeTrue
        $r.Pairs | Should -BeOfType [hashtable]
        $r.Pairs['Music'] | Should -BeOfType [hashtable]
        $r.Pairs['Music'].Seeded | Should -BeTrue
        $r.Pairs['Music'].FilterHash | Should -Be 'h1'
        $r.Pairs['Music'].LastExit | Should -Be 0
    }

    It 'loads a state.json that still has NotifiedUnmapped' {
        $dir = Join-Path $TestDrive 'oldunm'
        New-Item -ItemType Directory -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'state.json'), '{"NotifiedUnmapped":["D:\\X"],"Month":"2026-10"}')
        $r = Get-MirrorState -StateDir $dir
        $r.Month | Should -Be '2026-10'
        $r.PSObject.Properties.Name | Should -Not -Contain 'NotifiedUnmapped'
    }

    It 'LastRunInfo round-trips through save and load' {
        $s = New-MirrorState
        $s.LastRunInfo = @{ Started = '2026-10-25T20:00:00.0000000+07:00'; Finished = '2026-10-25T20:05:00.0000000+07:00'; Result = 'failed'
            Issues = @(@{ Pair = 'Documents'; Kind = 'folder-empty'; Message = 'm'; Log = 'C:\l.log' }) }
        Save-MirrorState -StateDir $TestDrive -State $s
        $r = Get-MirrorState -StateDir $TestDrive
        $r.LastRunInfo.Result | Should -BeExactly 'failed'
        @($r.LastRunInfo.Issues).Count | Should -Be 1
        $r.LastRunInfo.Issues[0].Kind | Should -BeExactly 'folder-empty'
        $r.LastRunInfo.Issues[0].Pair | Should -BeExactly 'Documents'
        $r.LastRunInfo.Issues[0].Log | Should -BeExactly 'C:\l.log'
        $r.LastRunInfo.Started | Should -BeExactly '2026-10-25T20:00:00.0000000+07:00'
        $r.LastRunInfo | Should -BeOfType [hashtable]
        $r.LastRunInfo.Issues[0] | Should -BeOfType [hashtable]
    }

    It 'keeps the Private flag of an issue, and reads an old issue without it as not private' {
        $dir = Join-Path $TestDrive 'lripriv'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $json = '{"LastRunInfo":{"Started":"s","Finished":"f","Result":"failed","Issues":[' +
            '{"Pair":"Docs","Private":true,"Kind":"other","Message":"m","Log":null},' +
            '{"Pair":"Docs","Kind":"other","Message":"old","Log":null}]}}'
        [IO.File]::WriteAllText((Join-Path $dir 'state.json'), $json)
        $r = Get-MirrorState -StateDir $dir
        @($r.LastRunInfo.Issues).Count | Should -Be 2
        $r.LastRunInfo.Issues[0].Private | Should -BeTrue
        $r.LastRunInfo.Issues[0].Private | Should -BeOfType [bool]
        $r.LastRunInfo.Issues[1].Private | Should -BeFalse
        $r.LastRunInfo.Issues[1].Private | Should -BeOfType [bool]
        # and it round-trips
        Save-MirrorState -StateDir $dir -State $r
        (Get-MirrorState -StateDir $dir).LastRunInfo.Issues[0].Private | Should -BeTrue
    }

    It 'LastRunInfo with no issues loads Issues as an empty array' {
        $dir = Join-Path $TestDrive 'lri0'
        $s = New-MirrorState
        $s.LastRunInfo = @{ Started = 's'; Finished = 'f'; Result = 'ok'; Issues = @() }
        Save-MirrorState -StateDir $dir -State $s
        $r = Get-MirrorState -StateDir $dir
        $r.LastRunInfo.Result | Should -BeExactly 'ok'
        $null -ne $r.LastRunInfo.Issues | Should -BeTrue
        @($r.LastRunInfo.Issues).Count | Should -Be 0
    }

    It 'old state.json without LastRunInfo loads with LastRunInfo = $null' {
        $dir = Join-Path $TestDrive 'lriold'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'state.json'), '{"Month":"2026-10","TransferredBytes":5}', (New-Object Text.UTF8Encoding $false))
        $r = Get-MirrorState -StateDir $dir
        $r.Month | Should -Be '2026-10'
        $null -eq $r.LastRunInfo | Should -BeTrue
        $null -eq (New-MirrorState).LastRunInfo | Should -BeTrue
    }

    It 'overwrites an existing state file on save' {
        $dir = Join-Path $TestDrive 'ow'
        $s = Get-MirrorState -StateDir $dir
        $s.Month = '2026-01'
        Save-MirrorState -StateDir $dir -State $s
        $s.Month = '2026-02'
        Save-MirrorState -StateDir $dir -State $s
        (Get-MirrorState -StateDir $dir).Month | Should -Be '2026-02'
    }
}

Describe 'Add-TransferredBytes' {
    It 'adds within the same month' {
        $s = Get-MirrorState -StateDir (Join-Path $TestDrive 'a1')
        $s.Month = '2026-10'; $s.TransferredBytes = [long]100
        Add-TransferredBytes -State $s -Bytes 50 -Now ([datetime]'2026-10-24')
        $s.TransferredBytes | Should -Be 150
        $s.Month | Should -Be '2026-10'
    }
    It 'resets usage and QuotaWarned on month change, then adds' {
        $s = Get-MirrorState -StateDir (Join-Path $TestDrive 'a2')
        $s.Month = '2026-09'; $s.TransferredBytes = [long](200 * $script:GB); $s.QuotaWarned = $true
        Add-TransferredBytes -State $s -Bytes 50 -Now ([datetime]'2026-10-01')
        $s.Month | Should -Be '2026-10'
        $s.TransferredBytes | Should -Be 50
        $s.QuotaWarned | Should -BeFalse
    }
    It 'sets Month when it was null' {
        $s = Get-MirrorState -StateDir (Join-Path $TestDrive 'a3')
        Add-TransferredBytes -State $s -Bytes 7 -Now ([datetime]'2026-10-24')
        $s.Month | Should -Be '2026-10'
        $s.TransferredBytes | Should -Be 7
    }
}

Describe 'Get-RunBudget' {
    It 'month rollover resets usage (pure, no mutation)' {
        $s = Get-MirrorState -StateDir (Join-Path $TestDrive 'b1')
        $s.Month = '2026-09'; $s.TransferredBytes = [long](200 * $script:GB)
        Get-RunBudget -State $s -Config $script:cfg -Now ([datetime]'2026-10-01') | Should -Be (8 * $script:GB)
        $s.Month | Should -Be '2026-09'
        $s.TransferredBytes | Should -Be ([long](200 * $script:GB))
    }
    It 'returns the full run budget when nothing used' {
        $s = Get-MirrorState -StateDir (Join-Path $TestDrive 'b2')
        Get-RunBudget -State $s -Config $script:cfg -Now ([datetime]'2026-10-24') | Should -Be 8589934592
    }
    It 'is capped by monthly remainder' {
        $s = Get-MirrorState -StateDir (Join-Path $TestDrive 'b3')
        $s.Month = '2026-10'; $s.TransferredBytes = [long](246 * $script:GB)
        Get-RunBudget -State $s -Config $script:cfg -Now ([datetime]'2026-10-24') | Should -Be (4 * $script:GB)
    }
    It 'floors at 0 when monthly budget is used or exceeded' {
        $s = Get-MirrorState -StateDir (Join-Path $TestDrive 'b4')
        $s.Month = '2026-10'; $s.TransferredBytes = [long](250 * $script:GB)
        Get-RunBudget -State $s -Config $script:cfg -Now ([datetime]'2026-10-24') | Should -Be 0
        $s.TransferredBytes = [long](260 * $script:GB)
        Get-RunBudget -State $s -Config $script:cfg -Now ([datetime]'2026-10-24') | Should -Be 0
    }
}

Describe 'Per-day budget' {
    It 'counts bytes per day and resets on a new day' {
        $s = New-MirrorState
        Add-TransferredBytes -State $s -Bytes 100 -Now ([datetime]'2026-11-15T23:50:00')
        Add-TransferredBytes -State $s -Bytes 50  -Now ([datetime]'2026-11-16T00:10:00')
        $s.Day | Should -Be '2026-11-16'; $s.DayBytes | Should -Be 50; $s.TransferredBytes | Should -Be 150
    }
    It 'adds to the day within the same day' {
        $s = New-MirrorState
        Add-TransferredBytes -State $s -Bytes 100 -Now ([datetime]'2026-11-15T08:00:00')
        Add-TransferredBytes -State $s -Bytes 50  -Now ([datetime]'2026-11-15T21:00:00')
        $s.DayBytes | Should -Be 150; $s.DayBytes | Should -BeOfType [long]
    }
    It 'resets day and month counts on a new month' {
        $s = New-MirrorState
        Add-TransferredBytes -State $s -Bytes 100 -Now ([datetime]'2026-11-30T23:00:00')
        Add-TransferredBytes -State $s -Bytes 7   -Now ([datetime]'2026-12-01T01:00:00')
        $s.Month | Should -Be '2026-12'; $s.Day | Should -Be '2026-12-01'
        $s.DayBytes | Should -Be 7; $s.TransferredBytes | Should -Be 7
    }
    It 'Get-DayKey formats yyyy-MM-dd' {
        Get-DayKey -Now ([datetime]'2026-01-05T23:59:59') | Should -Be '2026-01-05'
    }
    It 'limits a run to what is left today' {
        $cfg = @{ DailyBudgetGB = 1; MonthlyBudgetGB = 30 }
        $s = New-MirrorState
        $s.Month = '2026-11'; $s.TransferredBytes = [long](2 * $script:GB)
        $s.Day = '2026-11-15'; $s.DayBytes = [long](0.75 * $script:GB)
        $now = [datetime]'2026-11-15T10:00:00'
        Get-RunBudget -State $s -Config $cfg -Now $now | Should -Be ([long](0.25 * $script:GB))
        $left = Get-BudgetLeft -State $s -Config $cfg -Now $now
        $left.Day | Should -Be ([long](0.25 * $script:GB)); $left.Month | Should -Be ([long](28 * $script:GB))
    }
    It 'gives the full daily budget on a new day, though DayBytes is stale' {
        $cfg = @{ DailyBudgetGB = 1; MonthlyBudgetGB = 30 }
        $s = New-MirrorState
        $s.Month = '2026-11'; $s.TransferredBytes = [long](2 * $script:GB)
        $s.Day = '2026-11-14'; $s.DayBytes = [long]$script:GB
        Get-RunBudget -State $s -Config $cfg -Now ([datetime]'2026-11-15T10:00:00') | Should -Be $script:GB
    }
    It 'limits a run to what is left this month when that is less' {
        $cfg = @{ DailyBudgetGB = 8; MonthlyBudgetGB = 30 }
        $s = New-MirrorState
        $s.Month = '2026-11'; $s.TransferredBytes = [long](29.5 * $script:GB)
        Get-RunBudget -State $s -Config $cfg -Now ([datetime]'2026-11-15T10:00:00') | Should -Be ([long](0.5 * $script:GB))
    }
    It 'never reports a negative budget' {
        $cfg = @{ DailyBudgetGB = 1; MonthlyBudgetGB = 30 }
        $s = New-MirrorState
        $s.Month = '2026-11'; $s.TransferredBytes = [long](40 * $script:GB)
        $s.Day = '2026-11-15'; $s.DayBytes = [long](3 * $script:GB)
        $left = Get-BudgetLeft -State $s -Config $cfg -Now ([datetime]'2026-11-15T10:00:00')
        $left.Day | Should -Be 0; $left.Month | Should -Be 0
    }
    It 'uses RunBudgetGB when DailyBudgetGB is missing' {
        Get-DailyBudgetGB -Config @{ RunBudgetGB = 3 } | Should -Be 3
        Get-DailyBudgetGB -Config @{ RunBudgetGB = 3; DailyBudgetGB = 5 } | Should -Be 5
        $s = New-MirrorState
        Get-RunBudget -State $s -Config @{ RunBudgetGB = 3; MonthlyBudgetGB = 30 } -Now ([datetime]'2026-11-15') | Should -Be (3 * $script:GB)
    }
    It 'loads an old state.json without Day and DayBytes' {
        $dir = Join-Path $TestDrive 'oldstate'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'state.json'), '{"Month":"2026-11","TransferredBytes":123,"Pairs":{}}')
        $s = Get-MirrorState -StateDir $dir
        $s.Day | Should -BeNullOrEmpty; $s.DayBytes | Should -Be 0; $s.TransferredBytes | Should -Be 123
    }
    It 'round-trips Day and DayBytes through disk' {
        $dir = Join-Path $TestDrive 'daystate'
        $s = New-MirrorState
        Add-TransferredBytes -State $s -Bytes 42 -Now ([datetime]'2026-11-15T10:00:00')
        Save-MirrorState -StateDir $dir -State $s
        $r = Get-MirrorState -StateDir $dir
        $r.Day | Should -Be '2026-11-15'; $r.DayBytes | Should -Be 42; $r.DayBytes | Should -BeOfType [long]
    }
}

Describe 'Notified memory' {
    It 'loads an old state.json without Notified' {
        $dir = Join-Path $TestDrive 'nonotified'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'state.json'), '{"Month":"2026-11","Pairs":{}}')
        $s = Get-MirrorState -StateDir $dir
        $s.Notified | Should -BeOfType [hashtable]
        $s.Notified.Count | Should -Be 0
    }
    It 'round-trips Notified, also when empty' {
        $dir = Join-Path $TestDrive 'notified'
        $s = New-MirrorState
        Save-MirrorState -StateDir $dir -State $s
        (Get-MirrorState -StateDir $dir).Notified.Count | Should -Be 0
        $s.Notified['Alpha|other'] = '2026-11-15'
        Save-MirrorState -StateDir $dir -State $s
        $r = Get-MirrorState -StateDir $dir
        $r.Notified | Should -BeOfType [hashtable]
        $r.Notified['Alpha|other'] | Should -Be '2026-11-15'
    }
}

Describe 'Test-StaleSuccess' {
    BeforeEach { $script:st = Get-MirrorState -StateDir (Join-Path $TestDrive 'st') }
    It 'is stale after 3 days' {
        $script:st.LastSuccess = ([datetime]'2026-10-20').ToString('o')
        Test-StaleSuccess -State $script:st -Config $script:cfg -Now ([datetime]'2026-10-24') | Should -BeTrue
    }
    It 'is not stale within 3 days' {
        $script:st.LastSuccess = ([datetime]'2026-10-22').ToString('o')
        Test-StaleSuccess -State $script:st -Config $script:cfg -Now ([datetime]'2026-10-24') | Should -BeFalse
    }
    It 'is not stale when never run' {
        Test-StaleSuccess -State $script:st -Config $script:cfg -Now ([datetime]'2026-10-24') | Should -BeFalse
    }
}

Describe 'BudgetPauseNotified (M2)' {
    It 'defaults to false, round-trips, and resets with QuotaWarned on month change' {
        $dir = Join-Path $TestDrive 'bp'
        $s = Get-MirrorState -StateDir $dir
        $s.BudgetPauseNotified | Should -BeFalse
        $s.Month = '2026-09'; $s.BudgetPauseNotified = $true; $s.QuotaWarned = $true
        Save-MirrorState -StateDir $dir -State $s
        $r = Get-MirrorState -StateDir $dir
        $r.BudgetPauseNotified | Should -BeTrue
        Add-TransferredBytes -State $r -Bytes 0 -Now ([datetime]'2026-10-01')
        $r.BudgetPauseNotified | Should -BeFalse
        $r.QuotaWarned | Should -BeFalse
    }
}

Describe 'Get-RunBudget without script-scope helpers' {
    It 'does not depend on a $script: GB constant' {
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\scripts\lib\State.ps1') -Raw) | Should -Not -Match 'BytesPerGB'
        Remove-Variable -Name BytesPerGB -Scope Script -ErrorAction SilentlyContinue
        $s = New-MirrorState
        Get-RunBudget -State $s -Config $script:cfg -Now ([datetime]'2026-10-24') | Should -Be (8 * $script:GB)
    }
}
