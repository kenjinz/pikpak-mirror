BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    $script:Now = [datetime]'2026-10-24T13:45:10'
    $script:GB = [long]1073741824

    function New-TestRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root
    }

    function New-TestConfig {
        # Builds a config whose every local path lives under $Root. Pairs: @{Name;Priority;Create}.
        param([string]$Root, [object[]]$Pairs = @(@{ Name = 'Alpha'; Priority = 1 }), [object[]]$PrivatePaths = @())
        $watch = Join-Path $Root 'watch'
        New-Item -ItemType Directory -Path $watch -Force | Out-Null
        $global = Join-Path $Root 'filters.txt'
        [IO.File]::WriteAllLines($global, [string[]]@('# global', '- Thumbs.db'), (New-Object Text.UTF8Encoding $false))
        $pairList = @()
        foreach ($p in $Pairs) {
            $dir = $p.Name
            if ($p.ContainsKey('Dir')) { $dir = $p.Dir }
            $local = Join-Path $watch $dir
            if ($p.ContainsKey('Create') -and -not $p.Create) { } else { New-Item -ItemType Directory -Path $local -Force | Out-Null }
            $entry = @{ Name = $p.Name; Local = $local; Remote = 'D/' + $p.Name; Priority = $p.Priority }
            if ($p.ContainsKey('Id')) { $entry.Id = $p.Id }
            if ($p.ContainsKey('Paused')) { $entry.Paused = $p.Paused }
            $pairList += $entry
        }
        @{
            Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror'; HoldingRoot = 'PC-Holding'
            LocalHolding = (Join-Path $Root 'holding'); StateDir = (Join-Path $Root 'state')
            GlobalFiltersFile = $global
            HoldingDays = 30; MaxDeletePercent = 10; DailyBudgetGB = 8; MonthlyBudgetGB = 250; QuotaWarnPercent = 90
            StaleRunDays = 3; LogKeepDays = 60; BwLimit = 'off'
            PrivatePaths = @($PrivatePaths); Pairs = $pairList
        }
    }

    function Set-Confirmed {
        param($Config, [scriptblock]$Mutate)
        $s = Get-MirrorState -StateDir $Config.StateDir
        $s.PrivateConfirmedHash = Get-PrivatePathsHash -Config $Config
        if ($Mutate) { & $Mutate $s }
        Save-MirrorState -StateDir $Config.StateDir -State $s
    }

    function Get-ArgValue {
        param([string[]]$A, [string]$Name)
        $i = [array]::IndexOf($A, $Name)
        if ($i -ge 0) { $A[$i + 1] }
    }

    function Clear-StopPause {
        # Lifts the "stopped by the budget today/this month" pause, so a test can look at a later same-day run.
        param($Config)
        $s = Get-MirrorState -StateDir $Config.StateDir
        $s.DayStopped = $null; $s.MonthStopped = $null
        Save-MirrorState -StateDir $Config.StateDir -State $s
    }

    function Get-NonSentinel { @($script:calls | Where-Object { $_[0] -ne 'copyto' }) }
}

Describe 'Invoke-MirrorRun' {
    BeforeEach {
        $script:calls = New-Object System.Collections.Generic.List[object]
        $script:toasts = New-Object System.Collections.Generic.List[string]
        $script:responder = $null
        Mock Invoke-Rclone {
            $script:calls.Add([string[]]$Arguments)
            $r = $null
            if ($script:responder) { $r = & $script:responder ([string[]]$Arguments) }
            if ($null -eq $r) { $r = @{} }
            $exit = 0; $bytes = [long]0; $nr = $false; $el = $null; $bh = $false; $su = [string[]]@()
            if ($r.ContainsKey('ExitCode')) { $exit = $r.ExitCode }
            if ($r.ContainsKey('Bytes')) { $bytes = [long]$r.Bytes }
            if ($r.ContainsKey('NeedsResync')) { $nr = $r.NeedsResync }
            if ($r.ContainsKey('EmptyListing')) { $el = $r.EmptyListing }
            if ($r.ContainsKey('BudgetHit')) { $bh = $r.BudgetHit }
            if ($r.ContainsKey('StuckUploads')) { $su = [string[]]$r.StuckUploads }
            $tmd = $false
            if ($r.ContainsKey('TooManyDeletes')) { $tmd = $r.TooManyDeletes }
            [pscustomobject]@{ ExitCode = $exit; Bytes = $bytes; LogFile = (Get-ArgValue $Arguments '--log-file'); NeedsResync = $nr; EmptyListing = $el; BudgetHit = $bh; StuckUploads = $su; TooManyDeletes = $tmd }
        }
        Mock Send-MirrorToast { $script:toasts.Add($Message) }
        # rclone cat of a PikPak marker: not found (exit 3) unless $script:catResponder says otherwise.
        $script:catCalls = New-Object System.Collections.Generic.List[object]
        $script:catResponder = $null
        Mock Invoke-RcloneOutput {
            $script:catCalls.Add([string[]]$Arguments)
            $r = $null
            if ($script:catResponder) { $r = & $script:catResponder ([string[]]$Arguments) }
            if ($null -eq $r) { $r = @{ ExitCode = 3; Output = [string[]]@() } }
            $r
        }
    }

    It 'stops when private paths not confirmed' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $script:calls.Count | Should -Be 0
        ($script:toasts -join "`n") | Should -Match 'Confirm-PrivatePaths'
        @($r.Errors).Count | Should -BeGreaterThan 0
    }

    It 'stops when Test-MirrorConfig reports errors' {
        $root = New-TestRoot
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'Alpha'; Priority = 1 }, @{ Name = 'Beta'; Priority = 1 })
        $cfg.Pairs[1].Name = 'alpha'
        Set-Confirmed $cfg
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $script:calls.Count | Should -Be 0
        ($script:toasts -join "`n") | Should -Match 'Duplicate pair name'
        @($r.Errors).Count | Should -BeGreaterThan 0
    }

    It 'locked run returns Skipped locked' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $h = Enter-MirrorLock -StateDir $cfg.StateDir
        try {
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        } finally { Exit-MirrorLock -Handle $h }
        @($r.Skipped) | Should -Contain 'locked'
        $script:calls.Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $cfg.StateDir 'state.json') | Should -BeFalse
    }

    It 'clears stale bisync locks right after taking the lock' {
        Mock Clear-StaleBisyncLocks { @() }
        $cfg = New-TestConfig -Root (New-TestRoot)
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        Should -Invoke Clear-StaleBisyncLocks -Times 1 -Exactly
    }

    It 'does not clear bisync locks when another instance holds the lock' {
        Mock Clear-StaleBisyncLocks { @() }
        $cfg = New-TestConfig -Root (New-TestRoot)
        $h = Enter-MirrorLock -StateDir $cfg.StateDir
        try { Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null } finally { Exit-MirrorLock -Handle $h }
        Should -Invoke Clear-StaleBisyncLocks -Times 0 -Exactly
    }

    It 'runs private first then pairs by priority' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'Zeta'; Priority = 2 }, @{ Name = 'Omega'; Priority = 1 }) `
            -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $seq = Get-NonSentinel
        $seq[0][0] | Should -Be 'bisync'
        $seq[0][1] | Should -Be $secret
        $seq[0][2] | Should -Be 'private:Secret'
        $seq[1][0] | Should -Be 'bisync'
        $seq[1][1] | Should -Be $cfg.Pairs[1].Local
        $seq[2][0] | Should -Be 'bisync'
        $seq[2][1] | Should -Be $cfg.Pairs[0].Local
    }

    It 'first run uses resync and uploads the sentinel with copyto --ignore-existing' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $sentIdx = -1; $bisyncIdx = -1
        for ($i = 0; $i -lt $script:calls.Count; $i++) {
            if ($script:calls[$i][0] -eq 'copyto' -and $sentIdx -lt 0) { $sentIdx = $i }
            if ($script:calls[$i][0] -eq 'bisync' -and $bisyncIdx -lt 0) { $bisyncIdx = $i }
        }
        $sentIdx | Should -BeGreaterOrEqual 0
        $sentIdx | Should -BeLessThan $bisyncIdx
        $sent = [string[]]$script:calls[$sentIdx]
        $sent[1] | Should -Be (Join-Path $cfg.Pairs[0].Local 'RCLONE_TEST')
        $sent[2] | Should -Be 'pikpak:PC-Mirror/D/Alpha/RCLONE_TEST'
        $sent | Should -Contain '--ignore-existing'
        Get-ArgValue $sent '--log-file' | Should -Not -BeNullOrEmpty
        @($script:calls | Where-Object { $_[0] -eq 'touch' }).Count | Should -Be 0
        $script:calls[$bisyncIdx] | Should -Contain '--resync'
        Test-Path -LiteralPath (Join-Path $cfg.Pairs[0].Local 'RCLONE_TEST') | Should -BeTrue
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].Seeded | Should -BeTrue

        $script:calls.Clear()
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0] | Should -Not -Contain '--resync'
        @($script:calls | Where-Object { $_[0] -eq 'copyto' -or $_[0] -eq 'touch' }).Count | Should -Be 0
    }

    It 'a second unseeded run (remote sentinel already there) still reaches bisync' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        # first seed attempt is cut off by the transfer budget, so the pair stays unseeded
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 8 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].Seeded | Should -BeFalse

        $script:calls.Clear()
        $script:responder = $null   # sentinel copy succeeds (rclone skips the existing file, exit 0)
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(1) | Out-Null   # the budget stop paused the rest of the day
        $cmds = @($script:calls | ForEach-Object { $_[0] })
        $cmds | Should -Not -Contain 'touch'
        $s = @($script:calls | Where-Object { $_[0] -eq 'copyto' })
        $s.Count | Should -Be 1
        $s[0] | Should -Contain '--ignore-existing'
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0] | Should -Contain '--resync'
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].Seeded | Should -BeTrue
    }

    It 'exit 8 keeps pair unseeded and stops remaining pairs' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'First'; Priority = 1 }, @{ Name = 'Second'; Priority = 2 })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 8; Bytes = 5000 } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0][1] | Should -Be $cfg.Pairs[0].Local
        $s = Get-MirrorState -StateDir $cfg.StateDir
        $s.Pairs['First'].Seeded | Should -BeFalse
        $s.Pairs['First'].LastExit | Should -Be 8
        $s.TransferredBytes | Should -Be 5000
        # Prunes still run after a budget stop (two areas: this config has no private folders).
        @($script:calls | Where-Object { $_[0] -eq 'delete' }).Count | Should -Be 2
        @($r.Errors).Count | Should -Be 0
    }

    It 'stops further transfers once the run budget is used up' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync' -and $a[2] -eq 'private:Secret') { @{ ExitCode = 0; Bytes = 8 * 1073741824 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0][2] | Should -Be 'private:Secret'
        @($script:calls | Where-Object { $_[0] -eq 'delete' }).Count | Should -Be 3
    }

    It 'passes the remaining run budget to later commands' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync' -and $a[2] -eq 'private:Secret') { @{ ExitCode = 0; Bytes = 1000 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $sync = @($script:calls | Where-Object { $_[0] -eq 'bisync' -and $_[2] -eq 'private:Secret' })[0]
        $bis = @($script:calls | Where-Object { $_[0] -eq 'bisync' -and $_[2] -ne 'private:Secret' })[0]
        Get-ArgValue $sync '--max-transfer' | Should -Be ([string](8 * $script:GB) + 'B')
        Get-ArgValue $bis '--max-transfer' | Should -Be ([string](8 * $script:GB - 1000) + 'B')
    }

    It 'filter change forces resync and warns' {
        $root = New-TestRoot
        $cfg = New-TestConfig -Root $root
        $priv = Join-Path $cfg.Pairs[0].Local 'Hidden'
        New-Item -ItemType Directory -Path $priv -Force | Out-Null
        $cfg.PrivatePaths = @(@{ Path = $priv; Name = 'Hidden' })
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = 'old'; LastExit = 0; LastRun = $null } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        # the pair's bisync (Hidden itself now also runs through bisync, as an encrypted folder, before it)
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' -and $_[2] -eq 'pikpak:PC-Mirror/D/Alpha' })
        $b.Count | Should -Be 1
        $b[0] | Should -Contain '--resync'
        ($script:toasts -join "`n") | Should -Match 'delete any plain copy'
        ($script:toasts -join "`n") | Should -Match ([regex]::Escape('pikpak:PC-Mirror/D/Alpha'))
        $filterFile = Get-ArgValue $b[0] '--filters-file'
        ([IO.File]::ReadAllLines($filterFile)) | Should -Contain '- /Hidden/**'
    }

    It 'I6: a changed folder mapping forces a resync, toasts, and records the new identity' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        $old = Get-FolderIdentity -Folder (New-SyncFolder -Config $cfg -Pair @{ Name = 'Alpha'; Local = $cfg.Pairs[0].Local; Remote = 'D/OldPlace'; Priority = 1 })
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; Identity = $old; LastExit = 0; LastRun = $null } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0] | Should -Contain '--resync'
        @($script:toasts) | Should -Contain 'Alpha folder mapping changed: resyncing'
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].Identity | Should -Be (Get-FolderIdentity -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0]))

        # next run: identity matches, no resync, no toast
        $script:calls.Clear(); $script:toasts.Clear()
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' })[0] | Should -Not -Contain '--resync'
        @($script:toasts | Where-Object { $_ -match 'mapping changed' }).Count | Should -Be 0
    }

    It 'I6: a seeded pair without a stored identity migrates silently' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' })[0] | Should -Not -Contain '--resync'
        @($script:toasts | Where-Object { $_ -match 'mapping changed' }).Count | Should -Be 0
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].Identity | Should -Be (Get-FolderIdentity -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0]))
    }

    It 'K1: the mapping-changed toast is shown once while a budget-stopped resync continues over several runs' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; Identity = 'old'; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; BudgetHit = $true } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(1) | Out-Null
        @($script:toasts | Where-Object { $_ -match 'mapping changed' }).Count | Should -Be 1
        @($script:calls | Where-Object { $_[0] -eq 'bisync' })[1] | Should -Contain '--resync'
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].Identity | Should -Be 'old'
    }

    It 'K1: the filter-change toast is shown once while the resync keeps failing' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = 'old'; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 2 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(1) | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' })[1] | Should -Contain '--resync'
        @($script:toasts | Where-Object { $_ -match 'delete any plain copy' }).Count | Should -Be 1
    }

    It 'filter change that REMOVES an encrypted folder exclusion resyncs but sends no "delete the plain copy" toast' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = 'old'; FilterExcludes = '- /Hidden/**'; LastExit = 0; LastRun = $null } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' })[0] | Should -Contain '--resync'
        @($script:toasts | Where-Object { $_ -match 'delete any plain copy' }).Count | Should -Be 0
        $ps = (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha']
        $ps.FilterExcludes | Should -Be ''
    }

    It 'filter change that ADDS an encrypted folder exclusion toasts once, and the run remembers the exclusion' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $priv = Join-Path $cfg.Pairs[0].Local 'Hidden'
        New-Item -ItemType Directory -Path $priv -Force | Out-Null
        $cfg.PrivatePaths = @(@{ Path = $priv; Name = 'Hidden' })
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = 'old'; FilterExcludes = ''; LastExit = 0; LastRun = $null } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:toasts | Where-Object { $_ -match 'delete any plain copy' }).Count | Should -Be 1
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].FilterExcludes | Should -Be '- /Hidden/**'
    }

    It 'K1: a second, different mapping change toasts again' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; Identity = 'old'; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; BudgetHit = $true } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $cfg.Pairs[0].Remote = 'D/Moved'
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(1) | Out-Null
        @($script:toasts | Where-Object { $_ -match 'mapping changed' }).Count | Should -Be 2
    }

    It 'I6: identity is not updated when the resync fails' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; Identity = 'stale'; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 2 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].Identity | Should -Be 'stale'
    }

    It 'skips pair whose local folder is missing' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Gone'; Priority = 1; Create = $false }, @{ Name = 'Here'; Priority = 2 })
        Set-Confirmed $cfg
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0][1] | Should -Be $cfg.Pairs[1].Local
        ($script:toasts -join "`n") | Should -Match 'Gone'
        @($r.Skipped) | Should -Contain 'Gone'
        @($r.Errors).Count | Should -Be 0
    }

    It 'needs-resync is reported, not auto-fixed' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; NeedsResync = $true } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        ($script:toasts -join "`n") | Should -Match ([regex]::Escape('Alpha needs a repair run: see README "A folder keeps failing".'))
        @($script:calls | Where-Object { $_ -contains '--resync' }).Count | Should -Be 0
        @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -Be 1
        @($r.Errors).Count | Should -Be 1
        $r.Errors[0] | Should -Match ([regex]::Escape('Alpha needs a repair run: see README "A folder keeps failing".'))
        $r.Errors[0] | Should -Match 'bisync-Alpha'
        (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].LastExit | Should -Be 7
    }

    It 'empty Path2 listing gets its own message (checked before NeedsResync)' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; NeedsResync = $true; EmptyListing = 'Path2' } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $expected = 'Alpha: the PikPak folder is empty, so nothing was synced or deleted. If that is a mistake, see README "A folder keeps failing".'
        $script:toasts | Should -Contain $expected
        ($script:toasts -join "`n") | Should -Not -Match 'repair run'
        @($r.Errors).Count | Should -Be 1
        $r.Errors[0] | Should -Match ([regex]::Escape($expected))
        $r.Errors[0] | Should -Match 'bisync-Alpha'
    }

    It 'empty Path1 listing says the PC folder is empty' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; EmptyListing = 'Path1' } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $script:toasts | Should -Contain 'Alpha: the PC folder is empty, so nothing was synced or deleted. If that is a mistake, see README "A folder keeps failing".'
        @($r.Errors).Count | Should -Be 1
    }

    It 'J1: bisync exit 7 with BudgetHit is a budget stop: no error, no toast, Seeded false, later pairs skipped' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1 }, @{ Name = 'Beta'; Priority = 2 })
        $fa = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        $fb = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[1])
        $ida = Get-FolderIdentity -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s)
            $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $fa.Hash; Identity = $ida; LastExit = 0; LastRun = $null }
            $s.Pairs['Beta'] = @{ Seeded = $true; FilterHash = $fb.Hash; LastExit = 0; LastRun = $null }
        }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; NeedsResync = $true; BudgetHit = $true; Bytes = 100 } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        @($r.Errors).Count | Should -Be 0
        $script:toasts.Count | Should -Be 0
        @($r.Skipped) | Should -Contain 'budget'
        @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -Be 1
        $ps = (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha']
        $ps.Seeded | Should -BeFalse
        $ps.LastExit | Should -Be 7
        $ps.FilterHash | Should -Be $fa.Hash
        $ps.Identity | Should -Be $ida
        $logFile = Join-Path $cfg.StateDir ('logs\' + (Get-Date).ToString('yyyy-MM-dd') + '.log')
        (Get-Content -LiteralPath $logFile -Raw) | Should -Match ([regex]::Escape('Alpha: run budget reached, continues at the next sync'))
    }

    It 'J1: the run after a budget stop does --resync' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; BudgetHit = $true } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:calls.Clear()
        $script:responder = $null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(1) | Out-Null   # the budget stop paused the rest of the day
        @($script:calls | Where-Object { $_[0] -eq 'bisync' -and ($_ -contains '--resync') }).Count | Should -Be 1
    }

    It 'J1: bisync exit 8 is still a budget stop (and sets Seeded false)' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 8 } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        @($r.Errors).Count | Should -Be 0
        $script:toasts.Count | Should -Be 0
        @($r.Skipped) | Should -Contain 'budget'
        $ps = (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha']
        $ps.Seeded | Should -BeFalse
        $ps.LastExit | Should -Be 8
    }

    It 'J1: budget stop is checked before empty listing, stuck uploads and needs-resync' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; BudgetHit = $true; EmptyListing = 'Path1'; NeedsResync = $true; StuckUploads = @('x.bin') } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        @($r.Errors).Count | Should -Be 0
        $script:toasts.Count | Should -Be 0
    }

    It 'J1: an encrypted folder''s exit 8 or BudgetHit is a budget stop without error or toast' {
        foreach ($res in @(@{ ExitCode = 8 }, @{ ExitCode = 7; BudgetHit = $true })) {
            $script:calls.Clear(); $script:toasts.Clear()
            $script:res = $res
            $root = New-TestRoot
            $secret = Join-Path $root 'secret'
            New-Item -ItemType Directory -Path $secret -Force | Out-Null
            $cfg = New-TestConfig -Root $root -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
            Set-Confirmed $cfg
            $script:responder = { param($a) if ($a[0] -eq 'bisync' -and $a[2] -eq 'private:Secret') { $script:res } }
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            @($r.Errors).Count | Should -Be 0
            $script:toasts.Count | Should -Be 0
            @($r.Skipped) | Should -Contain 'budget'
            # the pair after it is not reached
            @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -Be 1
            $ps = (Get-MirrorState -StateDir $cfg.StateDir).Pairs['private:Secret']
            $ps.Seeded | Should -BeFalse
            (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -BeExactly 'budget-stopped'
        }
    }

    It 'J2: stuck uploads give a toast and error naming the file, and Seeded false' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; NeedsResync = $true; StuckUploads = @('part1.bin') } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $expected = 'Alpha: PikPak is still holding an unfinished upload of part1.bin from an interrupted sync. See README "Stuck uploads".'
        $script:toasts | Should -Contain $expected
        ($script:toasts -join "`n") | Should -Not -Match 'repair run'
        @($r.Errors).Count | Should -Be 1
        $r.Errors[0] | Should -Match ([regex]::Escape($expected))
        $ps = (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha']
        $ps.Seeded | Should -BeFalse
        $ps.LastExit | Should -Be 7
    }

    It 'J2: at most 3 stuck names are listed, then an ellipsis' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; StuckUploads = @('a.bin', 'b.bin', 'c.bin', 'd.bin', 'e.bin') } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $dots = [string][char]0x2026
        $script:toasts | Should -Contain ('Alpha: PikPak is still holding an unfinished upload of a.bin, b.bin, c.bin, ' + $dots + ' from an interrupted sync. See README "Stuck uploads".')
    }

    It 'ForceResync passes --resync for the named pair only, case-insensitively' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1 }, @{ Name = 'Beta'; Priority = 2 })
        $fa = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        $fb = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[1])
        Set-Confirmed $cfg { param($s)
            $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $fa.Hash; LastExit = 0; LastRun = $null }
            $s.Pairs['Beta'] = @{ Seeded = $true; FilterHash = $fb.Hash; LastExit = 0; LastRun = $null }
        }
        Invoke-MirrorRun -Config $cfg -Now $script:Now -ForceResync @('bETA') | Out-Null
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 2
        $alpha = @($b | Where-Object { $_[1] -eq $cfg.Pairs[0].Local })[0]
        $beta = @($b | Where-Object { $_[1] -eq $cfg.Pairs[1].Local })[0]
        $alpha | Should -Not -Contain '--resync'
        $beta | Should -Contain '--resync'
        # the sentinel copyto runs for the forced pair only
        $s = @($script:calls | Where-Object { $_[0] -eq 'copyto' })
        $s.Count | Should -Be 1
        $s[0][2] | Should -BeLike '*Beta*RCLONE_TEST'
    }

    It 'without ForceResync a seeded pair does not resync' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:calls | Where-Object { $_ -contains '--resync' }).Count | Should -Be 0
    }

    It 'does not look for or toast about folders that are not synced' {
        $root = New-TestRoot
        $cfg = New-TestConfig -Root $root
        New-Item -ItemType Directory -Path (Join-Path $root 'watch/NewStuff') -Force | Out-Null
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:toasts | Where-Object { $_ -match 'NewStuff|not synced' }).Count | Should -Be 0
        (Get-MirrorState -StateDir $cfg.StateDir).PSObject.Properties.Name | Should -Not -Contain 'NotifiedUnmapped'
    }

    It 'budget zero skips everything' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s) $s.Month = '2026-10'; $s.TransferredBytes = [long](250 * 1073741824) }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:calls.Count | Should -Be 0
        $script:toasts.Count | Should -Be 1
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.BudgetPauseNotified | Should -BeTrue
        $st.QuotaWarned | Should -BeFalse
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $script:calls.Count | Should -Be 0
        $script:toasts.Count | Should -Be 1
    }

    It 'skips the run quietly when today''s budget is used up' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s)
            $s.Month = '2026-10'; $s.TransferredBytes = [long](8 * 1073741824)
            $s.Day = '2026-10-24'; $s.DayBytes = [long](8 * 1073741824)
            $s.LastSuccess = '2026-10-20T00:00:00.0000000'
        }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $script:calls.Count | Should -Be 0
        $script:toasts.Count | Should -Be 0
        @($r.Skipped) | Should -Contain 'budget'
        @($r.Errors).Count | Should -Be 0
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.LastRunInfo.Result | Should -BeExactly 'day-paused'
        @($st.LastRunInfo.Issues).Count | Should -Be 0
        $st.LastSuccess | Should -Be '2026-10-20T00:00:00.0000000'
        $st.BudgetPauseNotified | Should -BeFalse
    }

    It 'runs again the next day after a day-paused run' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s)
            $s.Month = '2026-10'; $s.TransferredBytes = [long](8 * 1073741824)
            $s.Day = '2026-10-24'; $s.DayBytes = [long](8 * 1073741824)
        }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:calls.Count | Should -Be 0
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(1) | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -Be 1
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -BeExactly 'ok'
    }

    It 'F1: a run cut by the daily budget pauses the rest of the day quietly, the next day syncs again' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'First'; Priority = 1 }, @{ Name = 'Second'; Priority = 2 })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 8; Bytes = 5000 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null   # plenty "left" numerically
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.DayStopped | Should -Be '2026-10-24'
        $st.MonthStopped | Should -BeNullOrEmpty
        (Get-BudgetLeft -State $st -Config $cfg -Now $script:Now).Day | Should -BeGreaterThan 0
        $script:calls.Clear(); $script:toasts.Clear()
        foreach ($h in 1, 2) {
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours($h)
            $script:calls.Count | Should -Be 0
            $script:toasts.Count | Should -Be 0
            @($r.Errors).Count | Should -Be 0
            (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -BeExactly 'day-paused'
        }
        # 00:30 the next day
        $script:responder = $null
        Invoke-MirrorRun -Config $cfg -Now ([datetime]'2026-10-25T00:30:00') | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -BeGreaterThan 0
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -BeExactly 'ok'
    }

    It 'F1: a run cut by the monthly budget pauses the rest of the month quietly, the next month syncs again' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $cfg.MonthlyBudgetGB = 2
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 8; Bytes = 5000 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.MonthStopped | Should -Be '2026-10'
        $st.DayStopped | Should -BeNullOrEmpty
        $script:calls.Clear(); $script:toasts.Clear()
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(3) | Out-Null
        $script:calls.Count | Should -Be 0
        $script:toasts.Count | Should -Be 0
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -BeExactly 'month-paused'
        $script:responder = $null
        Invoke-MirrorRun -Config $cfg -Now ([datetime]'2026-11-01T01:00:00') | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -BeGreaterThan 0
    }

    It 'F2: a paused run keeps the issues of the last real run' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'First'; Priority = 1 }, @{ Name = 'Second'; Priority = 2 }, @{ Name = 'Third'; Priority = 3 })
        Set-Confirmed $cfg
        $script:responder = { param($a)
            if ($a[0] -eq 'bisync' -and $a[1] -like '*First') { @{ ExitCode = 2 } }
            elseif ($a[0] -eq 'bisync' -and $a[1] -like '*Second') { @{ ExitCode = 8; Bytes = 5000 } }
        }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i1 = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i1.Result | Should -BeExactly 'failed'
        @($i1.Issues).Count | Should -Be 1
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $i2 = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i2.Result | Should -BeExactly 'day-paused'
        @($i2.Issues).Count | Should -Be 1
        $i2.Issues[0].Pair | Should -BeExactly 'First'
        $i2.Issues[0].Kind | Should -BeExactly 'other'
    }

    It 'passes what is left today as --max-transfer' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s)
            $s.Month = '2026-10'; $s.TransferredBytes = [long](3 * 1073741824)
            $s.Day = '2026-10-24'; $s.DayBytes = [long](3 * 1073741824)
        }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $bis = @($script:calls | Where-Object { $_[0] -eq 'bisync' })[0]
        Get-ArgValue $bis '--max-transfer' | Should -Be ([string](5 * $script:GB) + 'B')
    }

    It 'a config with only RunBudgetGB is still a daily budget' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $cfg.Remove('DailyBudgetGB'); $cfg.RunBudgetGB = 8
        Set-Confirmed $cfg { param($s) $s.Month = '2026-10'; $s.Day = '2026-10-24'; $s.DayBytes = [long](8 * 1073741824) }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:calls.Count | Should -Be 0
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -BeExactly 'day-paused'
    }

    It 'records the bytes of a run for the day' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 0; Bytes = 1000 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Day | Should -Be '2026-10-24'; $st.DayBytes | Should -Be 1000
    }

    It 'M2: the budget-used-up toast still fires after the 90% warning was shown' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s) $s.Month = '2026-10'; $s.TransferredBytes = [long](250 * 1073741824); $s.QuotaWarned = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:toasts | Where-Object { $_ -match 'budget used up' }).Count | Should -Be 1
    }

    It 'M3: the stale-sync toast uses StaleRunDays' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $cfg.StaleRunDays = 5
        Set-Confirmed $cfg { param($s) $s.LastSuccess = '2026-10-01T00:00:00.0000000' }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 2 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:toasts) | Should -Contain 'No successful sync for 5+ days'
    }

    It 'runs already-seeded pairs before unseeded ones, each group by Priority then Name' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(
            @{ Name = 'NewHigh'; Priority = 1 }, @{ Name = 'OldLow'; Priority = 3 }, @{ Name = 'NewLow'; Priority = 2 },
            @{ Name = 'OldHigh'; Priority = 2 }, @{ Name = 'OldAlso'; Priority = 2 })
        $seed = @{}
        foreach ($p in $cfg.Pairs) {
            if ($p.Name -like 'Old*') {
                $seed[$p.Name] = @{ Seeded = $true; FilterHash = (Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $p)).Hash
                    Identity = (Get-FolderIdentity -Folder (New-SyncFolder -Config $cfg -Pair $p)); LastExit = 0; LastRun = $null }
            }
        }
        Set-Confirmed $cfg { param($s) foreach ($k in $seed.Keys) { $s.Pairs[$k] = $seed[$k] } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $order = @($script:calls | Where-Object { $_[0] -eq 'bisync' } | ForEach-Object { Split-Path $_[1] -Leaf })
        $order | Should -Be @('OldAlso', 'OldHigh', 'OldLow', 'NewHigh', 'NewLow')
    }

    It 'F4: runs seeded encrypted, seeded pairs, unseeded encrypted, unseeded pairs' {
        $root = New-TestRoot
        $dirs = @{}
        foreach ($n in 'EncOld', 'EncNew') { $dirs[$n] = Join-Path $root $n; New-Item -ItemType Directory -Path $dirs[$n] -Force | Out-Null }
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'PairNew'; Priority = 1 }, @{ Name = 'PairOld'; Priority = 5 }) `
            -PrivatePaths @(@{ Path = $dirs['EncNew']; Name = 'EncNew' }, @{ Path = $dirs['EncOld']; Name = 'EncOld' })
        $seed = @{}
        foreach ($f in @(Get-SyncFolders -Config $cfg)) {
            if ($f.Name -like '*Old') {
                $seed[$f.StateKey] = @{ Seeded = $true; FilterHash = (Update-FolderFilterFile -Config $cfg -Folder $f).Hash
                    Identity = (Get-FolderIdentity -Folder $f); LastExit = 0; LastRun = $null }
            }
        }
        Set-Confirmed $cfg { param($s) foreach ($k in $seed.Keys) { $s.Pairs[$k] = $seed[$k] } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $order = @($script:calls | Where-Object { $_[0] -eq 'bisync' } | ForEach-Object { $_[2] })
        $order | Should -Be @('private:EncOld', 'pikpak:PC-Mirror/D/PairOld', 'private:EncNew', 'pikpak:PC-Mirror/D/PairNew')
    }

    It 'prunes all three holding areas' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $d = @($script:calls | Where-Object { $_[0] -eq 'delete' })
        $d.Count | Should -Be 3
        foreach ($c in $d) {
            $c | Should -Not -Contain '--min-age'
            $ex = Get-ArgValue $c '--exclude'
            $ex | Should -BeLike '/{2026-10-24,2026-10-23,*,2026-09-25}/**'
            $ex.Split(',').Count | Should -Be 30
        }
        $targets = @($d | ForEach-Object { $_[1] })
        $targets | Should -Contain 'pikpak:PC-Holding'
        $targets | Should -Contain $cfg.LocalHolding
        $targets | Should -Contain 'private:_holding'
    }

    It 'F5: prunes once a day: not at the second run of the same day, again the next day' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'delete' }).Count | Should -Be 2
        (Get-MirrorState -StateDir $cfg.StateDir).LastPruneDay | Should -Be '2026-10-24'
        $script:calls.Clear()
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -Be 1
        @($script:calls | Where-Object { $_[0] -eq 'delete' }).Count | Should -Be 0
        $script:calls.Clear()
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(1) | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'delete' }).Count | Should -Be 2
    }

    It 'F5: a failed prune is retried at the next run' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'delete' -and $a[1] -eq 'pikpak:PC-Holding') { @{ ExitCode = 1 } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        @($r.Errors).Count | Should -Be 1
        (Get-MirrorState -StateDir $cfg.StateDir).LastPruneDay | Should -BeNullOrEmpty
        $script:calls.Clear(); $script:responder = $null
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1)
        @($script:calls | Where-Object { $_[0] -eq 'delete' }).Count | Should -Be 2
        @($r.Errors).Count | Should -Be 0
        (Get-MirrorState -StateDir $cfg.StateDir).LastPruneDay | Should -Be '2026-10-24'
    }

    It 'skips the private holding prune when the config has no private folders' {
        # A fresh setup without a private folder has no private remote: pruning it would fail every night.
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $targets = @($script:calls | Where-Object { $_[0] -eq 'delete' } | ForEach-Object { $_[1] })
        $targets.Count | Should -Be 2
        $targets | Should -Contain 'pikpak:PC-Holding'
        $targets | Should -Contain $cfg.LocalHolding
        $targets | Should -Not -Contain 'private:_holding'
        @($r.Errors).Count | Should -Be 0
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -BeExactly 'ok'
    }

    It 'per-invocation log paths are unique' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        # a tab is an invalid file-name character that Test-MirrorConfig still allows in a pair name
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = "A`tB"; Dir = 'AB'; Priority = 1 }, @{ Name = 'C'; Priority = 1 }) `
            -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $logs = @($script:calls | ForEach-Object { Get-ArgValue $_ '--log-file' })
        $logs.Count | Should -Be $script:calls.Count
        $logs.Count | Should -BeGreaterThan 5
        @($logs | Sort-Object -Unique).Count | Should -Be $logs.Count
        $dayDir = [IO.Path]::Combine($cfg.StateDir, 'logs', '2026-10-24') + '\'
        foreach ($l in $logs) {
            $l.StartsWith($dayDir) | Should -BeTrue
            [IO.Path]::GetFileName($l) | Should -Match '^134510-'
            [IO.Path]::GetFileName($l).IndexOfAny([IO.Path]::GetInvalidFileNameChars()) | Should -Be -1
        }
    }

    It 'sets LastSuccess when there are no errors' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        @($r.Errors).Count | Should -Be 0
        (Get-MirrorState -StateDir $cfg.StateDir).LastSuccess | Should -Not -BeNullOrEmpty
    }

    It 'reports a failing bisync and warns about stale success' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s) $s.LastSuccess = '2026-10-01T00:00:00.0000000' }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 2 } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        @($r.Errors).Count | Should -BeGreaterThan 0
        ($script:toasts -join "`n") | Should -Match 'No successful sync for 3\+ days'
        (Get-MirrorState -StateDir $cfg.StateDir).LastSuccess | Should -Be '2026-10-01T00:00:00.0000000'
    }

    It 'warns once when monthly usage passes the quota threshold' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s) $s.Month = '2026-10'; $s.TransferredBytes = [long](230 * 1073741824) }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:toasts | Where-Object { $_ -match 'quota|budget' }).Count | Should -Be 1
        (Get-MirrorState -StateDir $cfg.StateDir).QuotaWarned | Should -BeTrue
    }

    It 'records Result ok and no issues after a clean run' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'ok'
        @($i.Issues).Count | Should -Be 0
        $i.Started | Should -Be $script:Now.ToString('o')
        [datetime]::Parse($i.Finished) | Should -BeOfType [datetime]
    }

    It 'records private-unconfirmed and Result failed when private paths are not confirmed' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        @($i.Issues).Count | Should -Be 1
        $i.Issues[0].Kind | Should -BeExactly 'private-unconfirmed'
        $null -eq $i.Issues[0].Pair | Should -BeTrue
        $i.Issues[0].Message | Should -Match 'Confirm-PrivatePaths'
    }

    It 'records config-invalid for each config error' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1 }, @{ Name = 'Beta'; Priority = 1 })
        $cfg.Pairs[1].Name = 'alpha'
        Set-Confirmed $cfg
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        @($i.Issues).Count | Should -Be @($r.Errors).Count
        foreach ($x in @($i.Issues)) { $x.Kind | Should -BeExactly 'config-invalid' }
        $i.Issues[0].Message | Should -Match 'Duplicate pair name'
    }

    It 'records month-paused, not ok, when the month budget is used up' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg { param($s) $s.Month = '2026-10'; $s.TransferredBytes = [long](250 * 1073741824); $s.LastSuccess = '2026-10-20T00:00:00.0000000' }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.LastRunInfo.Result | Should -BeExactly 'month-paused'
        $st.LastSuccess | Should -Be '2026-10-20T00:00:00.0000000'
    }

    It 'records budget-stopped when a pair hits the run budget and nothing failed' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 8 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'budget-stopped'
        @($i.Issues).Count | Should -Be 0
    }

    It 'records failed, not budget-stopped, when a failure happened before the budget stop' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1 }, @{ Name = 'Beta'; Priority = 2 })
        $fa = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        $fb = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[1])
        Set-Confirmed $cfg { param($s)
            $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $fa.Hash; LastExit = 0; LastRun = $null }
            $s.Pairs['Beta'] = @{ Seeded = $true; FilterHash = $fb.Hash; LastExit = 0; LastRun = $null }
        }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { if ($a[1] -like '*Alpha') { @{ ExitCode = 2 } } else { @{ ExitCode = 8 } } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        $i.Issues[0].Kind | Should -BeExactly 'other'
        $i.Issues[0].Pair | Should -BeExactly 'Alpha'
    }

    It 'records folder-empty with the pair name and log path' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; NeedsResync = $true; EmptyListing = 'Path1' } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        $i.Issues[0].Kind | Should -BeExactly 'folder-empty'
        $i.Issues[0].Pair | Should -BeExactly 'Alpha'
        $i.Issues[0].Log | Should -Match 'bisync-Alpha'
        $i.Issues[0].Message | Should -Match 'folder is empty'
    }

    It 'records stuck-upload with the pair name and log path' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 1; StuckUploads = @('a.bin') } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Issues[0].Kind | Should -BeExactly 'stuck-upload'
        $i.Issues[0].Pair | Should -BeExactly 'Alpha'
        $i.Issues[0].Log | Should -Match 'bisync-Alpha'
    }

    It 'records needs-repair with the pair name and log path' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; NeedsResync = $true } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Issues[0].Kind | Should -BeExactly 'needs-repair'
        $i.Issues[0].Pair | Should -BeExactly 'Alpha'
        $i.Issues[0].Log | Should -Match 'bisync-Alpha'
    }

    It 'records delete-safety (checked after EmptyListing, before NeedsResync) with the pair name and log path' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; LastExit = 0; LastRun = $null } }
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; NeedsResync = $true; TooManyDeletes = $true } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        @($i.Issues).Count | Should -Be 1
        $i.Issues[0].Kind | Should -BeExactly 'delete-safety'
        $i.Issues[0].Pair | Should -BeExactly 'Alpha'
        $i.Issues[0].Log | Should -Match 'bisync-Alpha'
        $i.Issues[0].Message | Should -BeExactly ("Alpha: more than 10% of the folder would be deleted, so nothing was synced. To get the files back, use Repair. If you deleted them on purpose, raise 'Stop and ask me if a sync would delete more than' in Settings, Advanced, for one sync, then set it back.")
        $script:toasts | Should -Contain $i.Issues[0].Message
        @($r.Errors).Count | Should -Be 1
        # EmptyListing wins over TooManyDeletes
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; EmptyListing = 'Path1'; TooManyDeletes = $true } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Issues[0].Kind | Should -BeExactly 'folder-empty'
    }

    It 'records sentinel-failed when the remote RCLONE_TEST cannot be created' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'copyto') { @{ ExitCode = 1 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        $i.Issues[0].Kind | Should -BeExactly 'sentinel-failed'
        $i.Issues[0].Pair | Should -BeExactly 'Alpha'
        $i.Issues[0].Log | Should -Match 'sentinel-Alpha'
    }

    It 'records a failing encrypted folder like a pair (kind other), marked Private' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync' -and $a[2] -eq 'private:Secret') { @{ ExitCode = 1 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $i = $st.LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        @($i.Issues).Count | Should -Be 1
        $i.Issues[0].Kind | Should -BeExactly 'other'
        $i.Issues[0].Pair | Should -BeExactly 'Secret'
        $i.Issues[0].Private | Should -BeTrue
        $i.Issues[0].Log | Should -Match 'bisync-private-Secret'
        $st.Notified.ContainsKey('private:Secret|other-exit1') | Should -BeTrue
        @($st.Notified.Keys | Where-Object { $_ -like '*private-failed*' }).Count | Should -Be 0
    }

    It 'syncs an encrypted folder with bisync, resync on its first run' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -Pairs @() -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        Set-Confirmed $cfg
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        @($r.Errors).Count | Should -Be 0
        @($script:calls | Where-Object { $_[0] -eq 'sync' }).Count | Should -Be 0
        $sent = @($script:calls | Where-Object { $_[0] -eq 'copyto' })
        $sent.Count | Should -Be 1
        $sent[0][1] | Should -Be (Join-Path $secret 'RCLONE_TEST')
        $sent[0][2] | Should -BeExactly 'private:Secret/RCLONE_TEST'
        $sent[0] | Should -Contain '--ignore-existing'
        Get-ArgValue $sent[0] '--log-file' | Should -Match 'sentinel-private-Secret'
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0][1] | Should -Be $secret
        $b[0][2] | Should -BeExactly 'private:Secret'
        $b[0] | Should -Contain '--resync'
        Get-ArgValue $b[0] '--backup-dir1' | Should -Be ([IO.Path]::Combine($cfg.LocalHolding, '2026-10-24', '_private', 'Secret'))
        Get-ArgValue $b[0] '--backup-dir2' | Should -BeExactly 'private:_holding/2026-10-24/Secret'
        Get-ArgValue $b[0] '--filters-file' | Should -Be ([IO.Path]::Combine($cfg.StateDir, 'filters', 'private', 'Secret.txt'))
        # no call of an encrypted folder touches the plain remote
        foreach ($c in @($script:calls | Where-Object { $_[0] -ne 'delete' })) { ($c -join ' ') | Should -Not -Match 'pikpak:' }
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Pairs['private:Secret'].Seeded | Should -BeTrue
        $st.Pairs['private:Secret'].LastExit | Should -Be 0
        $st.Pairs['private:Secret'].Identity | Should -Be (Get-FolderIdentity -Folder (New-SyncFolder -Config $cfg -Private $cfg.PrivatePaths[0]))
        $st.Pairs.ContainsKey('Secret') | Should -BeFalse
        @($r.Ran) | Should -Contain 'private:Secret'

        # the next run is incremental
        $script:calls.Clear()
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0] | Should -Not -Contain '--resync'
        @($script:calls | Where-Object { $_[0] -eq 'copyto' }).Count | Should -Be 0
    }

    It 'keeps a synced folder and an encrypted folder of the same name apart' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secretdocs'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'Docs'; Priority = 1 }) -PrivatePaths @(@{ Path = $secret; Name = 'Docs' })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync' -and $a[2] -eq 'private:Docs') { @{ ExitCode = 1 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Pairs['Docs'].LastExit | Should -Be 0
        $st.Pairs['Docs'].Seeded | Should -BeTrue
        $st.Pairs['private:Docs'].LastExit | Should -Be 1
        $st.Pairs['private:Docs'].Seeded | Should -BeFalse
        @($st.LastRunInfo.Issues).Count | Should -Be 1
        $st.LastRunInfo.Issues[0].Private | Should -BeTrue
        $st.LastRunInfo.Issues[0].Pair | Should -BeExactly 'Docs'
        @($st.Notified.Keys) | Should -Be @('private:Docs|other-exit1')
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 2
        $enc = @($b | Where-Object { $_[2] -eq 'private:Docs' })[0]
        $pair = @($b | Where-Object { $_[2] -eq 'pikpak:PC-Mirror/D/Docs' })[0]
        (Get-ArgValue $enc '--filters-file') | Should -Not -Be (Get-ArgValue $pair '--filters-file')
        (Get-ArgValue $enc '--backup-dir1') | Should -Not -Be (Get-ArgValue $pair '--backup-dir1')
        (Get-ArgValue $enc '--backup-dir2') | Should -Not -Be (Get-ArgValue $pair '--backup-dir2')
        (Get-ArgValue $enc '--log-file') | Should -Not -Be (Get-ArgValue $pair '--log-file')

        # the next run: the pair's problem memory is untouched by the encrypted folder and vice versa
        $script:responder = $null
        $script:calls.Clear()
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Notified.Count | Should -Be 0
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        @($b | Where-Object { $_[2] -eq 'private:Docs' })[0] | Should -Contain '--resync'
        @($b | Where-Object { $_[2] -eq 'pikpak:PC-Mirror/D/Docs' })[0] | Should -Not -Contain '--resync'
    }

    It 'applies the delete safety stop to an encrypted folder' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -Pairs @() -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; NeedsResync = $true; TooManyDeletes = $true } } }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        @($i.Issues).Count | Should -Be 1
        $i.Issues[0].Kind | Should -BeExactly 'delete-safety'
        $i.Issues[0].Private | Should -BeTrue
        $i.Issues[0].Pair | Should -BeExactly 'Secret'
        $i.Issues[0].Message | Should -Match '^Secret: more than 10% of the folder would be deleted'
        $script:toasts | Should -Contain $i.Issues[0].Message
        @($r.Errors).Count | Should -Be 1
    }

    It 'resyncs only the encrypted folder named private:Docs' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secretdocs'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'Docs'; Priority = 1 }) -PrivatePaths @(@{ Path = $secret; Name = 'Docs' })
        $fp = New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0]
        $fe = New-SyncFolder -Config $cfg -Private $cfg.PrivatePaths[0]
        $hp = (Update-FolderFilterFile -Config $cfg -Folder $fp).Hash
        $he = (Update-FolderFilterFile -Config $cfg -Folder $fe).Hash
        Set-Confirmed $cfg { param($s)
            $s.Pairs['Docs'] = @{ Seeded = $true; FilterHash = $hp; Identity = (Get-FolderIdentity -Folder $fp); LastExit = 0; LastRun = $null }
            $s.Pairs['private:Docs'] = @{ Seeded = $true; FilterHash = $he; Identity = (Get-FolderIdentity -Folder $fe); LastExit = 0; LastRun = $null }
        }
        Invoke-MirrorRun -Config $cfg -Now $script:Now -ForceResync @('PRIVATE:docs') | Out-Null
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 2
        @($b | Where-Object { $_[2] -eq 'private:Docs' })[0] | Should -Contain '--resync'
        @($b | Where-Object { $_[2] -eq 'pikpak:PC-Mirror/D/Docs' })[0] | Should -Not -Contain '--resync'

        $script:calls.Clear()
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) -ForceResync @('Docs') | Out-Null
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        @($b | Where-Object { $_[2] -eq 'private:Docs' })[0] | Should -Not -Contain '--resync'
        @($b | Where-Object { $_[2] -eq 'pikpak:PC-Mirror/D/Docs' })[0] | Should -Contain '--resync'
    }

    It 'does not toast about plain copies when the global filters change for an encrypted folder' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -Pairs @() -PrivatePaths @(@{ Path = $secret; Name = 'Secret' })
        $fe = New-SyncFolder -Config $cfg -Private $cfg.PrivatePaths[0]
        Set-Confirmed $cfg { param($s) $s.Pairs['private:Secret'] = @{ Seeded = $true; FilterHash = 'old'; Identity = (Get-FolderIdentity -Folder $fe); LastExit = 0; LastRun = $null } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' })[0] | Should -Contain '--resync'
        @($script:toasts | Where-Object { $_ -match 'plain copy' }).Count | Should -Be 0
    }

    It 'leaves an existing seeded pair exactly as it was (no resync, same state key, filter file and identity)' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        $id = Get-FolderIdentity -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; Identity = $id; LastExit = 0; LastRun = $null } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0] | Should -Not -Contain '--resync'
        Get-ArgValue $b[0] '--filters-file' | Should -Be ([IO.Path]::Combine($cfg.StateDir, 'filters', 'Alpha.txt'))
        Get-ArgValue $b[0] '--backup-dir1' | Should -Be ([IO.Path]::Combine($cfg.LocalHolding, '2026-10-24', 'Alpha'))
        Get-ArgValue $b[0] '--backup-dir2' | Should -BeExactly 'pikpak:PC-Holding/2026-10-24/Alpha'
        $b[0][2] | Should -BeExactly 'pikpak:PC-Mirror/D/Alpha'
        Get-ArgValue $b[0] '--log-file' | Should -Match 'bisync-Alpha-'
        $st = Get-MirrorState -StateDir $cfg.StateDir
        @($st.Pairs.Keys) | Should -Be @('Alpha')
        $st.Pairs['Alpha'].Identity | Should -Be $id
        $st.Pairs['Alpha'].FilterHash | Should -Be $f.Hash
    }

    It 'records folder-missing for a missing pair folder without failing the run' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1; Create = $false })
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'ok'
        $i.Issues[0].Kind | Should -BeExactly 'folder-missing'
        $i.Issues[0].Pair | Should -BeExactly 'Alpha'
    }

    It 'records folder-missing for a missing private folder without failing the run' {
        $root = New-TestRoot
        $cfg = New-TestConfig -Root $root -PrivatePaths @(@{ Path = (Join-Path $root 'nope'); Name = 'Secret' })
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'ok'
        $i.Issues[0].Kind | Should -BeExactly 'folder-missing'
        $i.Issues[0].Pair | Should -BeExactly 'Secret'
        $i.Issues[0].Private | Should -BeTrue
        $i.Issues[0].Message | Should -BeExactly ('Encrypted folder missing, skipped: ' + (Join-Path $root 'nope'))
        @($script:calls | Where-Object { ($_[0] -eq 'bisync' -or $_[0] -eq 'copyto') -and ($_ -join ' ') -match 'private:' }).Count | Should -Be 0
        (Get-MirrorState -StateDir $cfg.StateDir).Notified.ContainsKey('private:Secret|folder-missing') | Should -BeTrue
    }

    It 'records prune-failed with Pair $null' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'delete') { @{ ExitCode = 1 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $i = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $i.Result | Should -BeExactly 'failed'
        $i.Issues[0].Kind | Should -BeExactly 'prune-failed'
        $null -eq $i.Issues[0].Pair | Should -BeTrue
        $i.Issues[0].Log | Should -Match 'prune-1'
    }

    It 'syncs only the listed folders' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'A'; Priority = 1 }, @{ Name = 'C'; Priority = 2 }) `
            -PrivatePaths @(@{ Path = $secret; Name = 'B' })
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $before = Get-MirrorState -StateDir $cfg.StateDir
        $before.Notified['A|other'] = '2026-10-23'
        Save-MirrorState -StateDir $cfg.StateDir -State $before
        $script:calls.Clear()
        $later = $script:Now.AddDays(1)
        $r = Invoke-MirrorRun -Config $cfg -Now $later -OnlyFolders @('PRIVATE:b')
        $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
        $b.Count | Should -Be 1
        $b[0][2] | Should -BeExactly 'private:B'
        @($script:calls | Where-Object { $_[0] -eq 'delete' }).Count | Should -Be 0
        @($r.Ran) | Should -Be @('private:B')
        $after = Get-MirrorState -StateDir $cfg.StateDir
        foreach ($k in 'A', 'C') {
            $after.Pairs[$k]['LastRun'] | Should -Be $before.Pairs[$k]['LastRun']
            $after.Pairs[$k]['Seeded'] | Should -BeTrue
        }
        $after.Pairs['private:B']['LastRun'] | Should -Be $later.ToString('o')
        $after.Notified['A|other'] | Should -Be '2026-10-23'
        $after.LastPruneDay | Should -Be '2026-10-24'
        $after.LastSuccess | Should -Be $before.LastSuccess
    }

    It 'an -OnlyFolders run keeps the other folders'' problems on Home' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        # an encrypted folder with the same Name as the pair A: its issue must not be taken for A's
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'A'; Priority = 1 }, @{ Name = 'B'; Priority = 2 }) `
            -PrivatePaths @(@{ Path = $secret; Name = 'A' })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync' -and ($a[2] -like '*/B' -or $a[2] -eq 'private:A')) { @{ ExitCode = 1 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:responder = $null
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) -OnlyFolders @('a')
        @($r.Ran) | Should -Be @('A')
        $info = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        $info.Result | Should -Be 'failed'
        $keys = @($info.Issues | ForEach-Object { if ($_.Private) { 'private:' + $_.Pair } else { $_.Pair } } | Sort-Object)
        $keys | Should -Be @('B', 'private:A')
    }

    It 'an -OnlyFolders run replaces the problem of its own folder' {
        $root = New-TestRoot
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'A'; Priority = 1 }, @{ Name = 'B'; Priority = 2 })
        Set-Confirmed $cfg
        $script:responder = { param($a) if ($a[0] -eq 'bisync' -and $a[2] -like '*/A') { @{ ExitCode = 1 } } }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -Be 'failed'
        $script:responder = $null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) -OnlyFolders @('A') | Out-Null
        $info = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
        @($info.Issues | Where-Object { $_ }).Count | Should -Be 0
        $info.Result | Should -Be 'ok'
    }

    It 'an -OnlyFolders run without earlier problems reports ok' {
        $root = New-TestRoot
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'A'; Priority = 1 }, @{ Name = 'B'; Priority = 2 })
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now -OnlyFolders @('B') | Out-Null
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Result | Should -Be 'ok'
    }

    It 'with an empty -OnlyFolders syncs every folder and prunes, as before' {
        $root = New-TestRoot
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'A'; Priority = 1 }, @{ Name = 'C'; Priority = 2 })
        Set-Confirmed $cfg
        Invoke-MirrorRun -Config $cfg -Now $script:Now -OnlyFolders @() | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -Be 2
        @($script:calls | Where-Object { $_[0] -eq 'delete' }).Count | Should -Be 2
    }

    It 'a locked run writes no LastRunInfo' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        Set-Confirmed $cfg
        $h = Enter-MirrorLock -StateDir $cfg.StateDir
        try { Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null } finally { Exit-MirrorLock -Handle $h }
        $null -eq (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo | Should -BeTrue
    }

    Context 'folder identity' {
        BeforeAll {
            $script:id1 = '11111111-1111-4111-8111-111111111111'
            $script:id2 = '22222222-2222-4222-8222-222222222222'
            $script:id3 = '33333333-3333-4333-8333-333333333333'
            $script:id9 = '99999999-9999-4999-8999-999999999999'
            function Set-OtherMarker {
                # A marker of another folder (name Other, id9 unless given) in $Path.
                param([string]$Path, [string]$Id = $script:id9, [string]$Name = 'Other')
                $null = Write-FolderMarker -Folder @{ Kind = 'pair'; Name = $Name; Local = $Path; RemotePath = 'pikpak:PC-Mirror/X'; Id = $Id } -Now $script:Now
            }
            function Get-FolderCalls {
                # Every rclone call (bisync, sentinel copyto) that names this local folder.
                param([string]$Local)
                $sent = Join-Path $Local 'RCLONE_TEST'
                @($script:calls | Where-Object { $c = [string[]]$_; ($c -contains $Local) -or ($c -contains $sent) })
            }
            function Get-MarkerJson {
                param([string]$Id, [string]$Name)
                [string[]]@(('{{"app": "pikpak-mirror", "version": 1, "id": "{0}", "kind": "synced", "name": "{1}"}}' -f $Id, $Name))
            }
        }

        It 'skips a paused folder without issue or rclone call' {
            $root = New-TestRoot
            $cfg = New-TestConfig -Root $root -Pairs @(
                @{ Name = 'Alpha'; Priority = 1; Id = $script:id1; Paused = $true },
                @{ Name = 'Beta'; Priority = 1; Id = $script:id2 },
                @{ Name = 'Gone'; Priority = 1; Id = $script:id3; Paused = $true; Create = $false }) `
                -PrivatePaths @(@{ Path = (Join-Path $root 'nosecret'); Name = 'Secret'; Paused = $true })
            Set-Confirmed $cfg
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            @(Get-FolderCalls $cfg.Pairs[0].Local).Count | Should -Be 0
            @(Get-FolderCalls (Join-Path $root 'nosecret')).Count | Should -Be 0
            @($r.Ran) | Should -Not -Contain 'Alpha'
            @($r.Ran) | Should -Contain 'Beta'
            @($r.Skipped) | Should -Not -Contain 'Gone'
            @($r.Errors).Count | Should -Be 0
            $script:toasts.Count | Should -Be 0
            Read-FolderMarker -Path $cfg.Pairs[0].Local | Should -BeNullOrEmpty
            $info = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
            @($info.Issues).Count | Should -Be 0
            $info.Result | Should -Be 'ok'
            (Get-MirrorState -StateDir $cfg.StateDir).Pairs.ContainsKey('Alpha') | Should -BeFalse
        }

        It 'writes the marker on the first run and records MarkerWritten' {
            $root = New-TestRoot
            $secret = Join-Path $root 'secret'
            New-Item -ItemType Directory -Path $secret -Force | Out-Null
            $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'Alpha'; Priority = 1; Id = $script:id1 }) `
                -PrivatePaths @(@{ Path = $secret; Name = 'Secret'; Id = $script:id2 })
            Set-Confirmed $cfg
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            @($r.Errors).Count | Should -Be 0
            @($r.Ran) | Should -Contain 'Alpha'
            @($r.Ran) | Should -Contain 'private:Secret'
            $m = Read-FolderMarker -Path $cfg.Pairs[0].Local
            $m.Id | Should -Be $script:id1
            $m.FileKind | Should -Be 'pair'
            $m.Kind | Should -Be 'synced'
            $m.Name | Should -Be 'Alpha'
            $m.PikPak | Should -BeExactly 'pikpak:PC-Mirror/D/Alpha'
            $m.LastPath | Should -Be $cfg.Pairs[0].Local
            ([IO.File]::GetAttributes($m.File) -band [IO.FileAttributes]::Hidden) | Should -Be ([IO.FileAttributes]::Hidden)
            $e = Read-FolderMarker -Path $secret
            $e.Id | Should -Be $script:id2
            $e.FileKind | Should -Be 'private'
            $e.PikPak | Should -BeExactly 'private:Secret'
            $st = Get-MirrorState -StateDir $cfg.StateDir
            $st.Pairs['Alpha'].MarkerWritten | Should -BeTrue
            $st.Pairs['private:Secret'].MarkerWritten | Should -BeTrue

            # the next run finds its own marker and syncs normally
            $script:calls.Clear()
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1)
            @($r.Errors).Count | Should -Be 0
            @($r.Ran) | Should -Contain 'Alpha'
        }

        It 'skips a folder whose marker has another id' {
            $root = New-TestRoot
            $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'Alpha'; Priority = 1; Id = $script:id1 }, @{ Name = 'Beta'; Priority = 2; Id = $script:id2 })
            Set-OtherMarker $cfg.Pairs[0].Local
            Set-Confirmed $cfg
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            $msg = "Alpha: the folder at {0} is a different folder (it belongs to 'Other'). Nothing was synced. Open PikPak Sync to sort it out." -f $cfg.Pairs[0].Local
            @(Get-FolderCalls $cfg.Pairs[0].Local).Count | Should -Be 0
            @($r.Ran) | Should -Be @('Beta')
            @($r.Errors) | Should -Be @($msg)
            @($r.Skipped) | Should -Not -Contain 'Alpha'
            $script:toasts | Should -Contain $msg
            $info = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo
            $info.Result | Should -Be 'failed'
            @($info.Issues).Count | Should -Be 1
            $info.Issues[0].Kind | Should -Be 'folder-identity-mismatch'
            $info.Issues[0].Pair | Should -Be 'Alpha'
            $info.Issues[0].Message | Should -BeExactly $msg
            $info.Issues[0].Private | Should -BeFalse
            (Read-FolderMarker -Path $cfg.Pairs[0].Local).Id | Should -Be $script:id9
            @($script:catCalls | Where-Object { ($_ -join ' ') -match 'Alpha' }).Count | Should -Be 0
        }

        It 'skips a folder whose marker is invalid' {
            $root = New-TestRoot
            $secret = Join-Path $root 'secret'
            New-Item -ItemType Directory -Path $secret -Force | Out-Null
            $cfg = New-TestConfig -Root $root -Pairs @() -PrivatePaths @(@{ Path = $secret; Name = 'Secret'; Id = $script:id1 })
            $bad = Join-Path $secret '.pikpak-encrypted.json'
            [IO.File]::WriteAllText($bad, '{ not json', (New-Object Text.UTF8Encoding $false))
            Set-Confirmed $cfg
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            $msg = "Secret: the folder at {0} is a different folder (it belongs to 'unknown'). Nothing was synced. Open PikPak Sync to sort it out." -f $secret
            @(Get-FolderCalls $secret).Count | Should -Be 0
            @($r.Errors) | Should -Be @($msg)
            $issue = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Issues[0]
            $issue.Kind | Should -Be 'folder-identity-mismatch'
            $issue.Pair | Should -Be 'Secret'
            $issue.Private | Should -BeTrue
            [IO.File]::ReadAllText($bad) | Should -BeExactly '{ not json'
        }

        It 'skips a folder whose marker disappeared after it was written' {
            $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1; Id = $script:id1 })
            Set-Confirmed $cfg
            Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
            $file = (Read-FolderMarker -Path $cfg.Pairs[0].Local).File
            [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
            [IO.File]::Delete($file)
            $script:calls.Clear()
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1)
            $msg = 'Alpha: the folder at {0} has lost its ID file, so it may be a different folder. Nothing was synced. Open PikPak Sync to sort it out.' -f $cfg.Pairs[0].Local
            $script:calls.Count | Should -Be 0
            @($r.Errors) | Should -Be @($msg)
            @($r.Ran).Count | Should -Be 0
            $issue = (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Issues[0]
            $issue.Kind | Should -Be 'folder-marker-missing'
            $issue.Message | Should -BeExactly $msg
            Read-FolderMarker -Path $cfg.Pairs[0].Local | Should -BeNullOrEmpty
            (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].MarkerWritten | Should -BeTrue
        }

        It 'skips both entries with the same Id, also when one is paused' {
            $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(
                @{ Name = 'Alpha'; Priority = 1; Id = $script:id1 }, @{ Name = 'Beta'; Priority = 1; Id = $script:id1.ToUpperInvariant() })
            Set-Confirmed $cfg
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -Be 0
            @($r.Errors) | Should -Be @(
                'Alpha: another folder (Beta) has the same ID, so nothing was synced. Open PikPak Sync to choose.',
                'Beta: another folder (Alpha) has the same ID, so nothing was synced. Open PikPak Sync to choose.')
            $issues = @((Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Issues)
            @($issues | ForEach-Object { $_.Kind }) | Should -Be @('folder-duplicate-id', 'folder-duplicate-id')
            @($issues | ForEach-Object { $_.Pair }) | Should -Be @('Alpha', 'Beta')
            Read-FolderMarker -Path $cfg.Pairs[0].Local | Should -BeNullOrEmpty
            Read-FolderMarker -Path $cfg.Pairs[1].Local | Should -BeNullOrEmpty

            # one of the two paused: the other is still skipped, the paused one raises nothing; others sync
            $script:calls.Clear()
            $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(
                @{ Name = 'Alpha'; Priority = 1; Id = $script:id1 }, @{ Name = 'Gamma'; Priority = 1; Id = $script:id1; Paused = $true },
                @{ Name = 'Delta'; Priority = 1; Id = $script:id2 })
            Set-Confirmed $cfg
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            @($r.Errors) | Should -Be @('Alpha: another folder (Gamma) has the same ID, so nothing was synced. Open PikPak Sync to choose.')
            @($r.Ran) | Should -Be @('Delta')
            @(Get-FolderCalls $cfg.Pairs[0].Local).Count | Should -Be 0
            @(Get-FolderCalls $cfg.Pairs[1].Local).Count | Should -Be 0
            $issues = @((Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Issues)
            $issues.Count | Should -Be 1
            $issues[0].Kind | Should -Be 'folder-duplicate-id'
        }

        It 'checks the PikPak marker only when resyncing' {
            $root = New-TestRoot
            $secret = Join-Path $root 'secret'
            New-Item -ItemType Directory -Path $secret -Force | Out-Null
            $id4 = '44444444-4444-4444-8444-444444444444'
            $id5 = '55555555-5555-4555-8555-555555555555'
            $cfg = New-TestConfig -Root $root -Pairs @(
                @{ Name = 'Alpha'; Priority = 1; Id = $script:id1 }, @{ Name = 'Beta'; Priority = 2; Id = $script:id2 },
                @{ Name = 'Gamma'; Priority = 3; Id = $script:id3 }, @{ Name = 'Delta'; Priority = 4; Id = $id4 }) `
                -PrivatePaths @(@{ Path = $secret; Name = 'Secret'; Id = $id5 })
            # Alpha is seeded with its marker in place: no resync, so no cat
            $alpha = New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0]
            $f = Update-FolderFilterFile -Config $cfg -Folder $alpha
            $ident = Get-FolderIdentity -Folder $alpha
            $null = Write-FolderMarker -Folder $alpha -Now $script:Now
            Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = $f.Hash; Identity = $ident; LastExit = 0; LastRun = $null; MarkerWritten = $true } }
            $script:logDirOk = $true
            $script:catResponder = {
                param($a)
                $ld = [IO.Path]::GetDirectoryName((Get-ArgValue $a '--log-file'))
                if (-not (Test-Path -LiteralPath $ld)) { $script:logDirOk = $false }
                if ($a[1] -like '*/Beta/*') { return @{ ExitCode = 4; Output = [string[]]@() } }
                if ($a[1] -like '*/Gamma/*') { return @{ ExitCode = 0; Output = (Get-MarkerJson $script:id9 'Elsewhere') } }
                if ($a[1] -like '*/Delta/*') { return @{ ExitCode = 1; Output = [string[]]@() } }
                @{ ExitCode = 0; Output = (Get-MarkerJson '55555555-5555-4555-8555-555555555555' 'Secret') }
            }
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            $targets = @($script:catCalls | ForEach-Object { $_[1] })
            $targets | Should -Be @('private:Secret/.pikpak-encrypted.json', 'pikpak:PC-Mirror/D/Beta/.pikpak-sync.json',
                'pikpak:PC-Mirror/D/Gamma/.pikpak-sync.json', 'pikpak:PC-Mirror/D/Delta/.pikpak-sync.json')
            foreach ($c in $script:catCalls) { $c[0] | Should -Be 'cat'; Get-ArgValue $c '--log-file' | Should -Not -BeNullOrEmpty }
            $script:logDirOk | Should -BeTrue
            @($r.Ran) | Should -Be @('Alpha', 'private:Secret', 'Beta')
            @(Get-FolderCalls $cfg.Pairs[2].Local).Count | Should -Be 0
            @(Get-FolderCalls $cfg.Pairs[3].Local).Count | Should -Be 0
            $gmsg = "Gamma: the PikPak copy at pikpak:PC-Mirror/D/Gamma belongs to another folder ('Elsewhere'). Nothing was synced. Open PikPak Sync to sort it out."
            $dmsg = "Delta: couldn't read the ID file in PikPak, so nothing was synced. It is tried again at the next sync."
            $issues = @((Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Issues)
            $issues.Count | Should -Be 2
            $issues[0].Pair | Should -Be 'Gamma'
            $issues[0].Kind | Should -Be 'folder-identity-mismatch'
            $issues[0].Message | Should -BeExactly $gmsg
            $issues[1].Pair | Should -Be 'Delta'
            $issues[1].Kind | Should -Be 'other'
            $issues[1].Message | Should -BeExactly $dmsg
            $issues[1].Log | Should -Not -BeNullOrEmpty
            @($r.Errors).Count | Should -Be 2
            $script:toasts | Should -Contain $gmsg
            $script:toasts | Should -Contain $dmsg
            # the PC marker is written before the PikPak check
            (Read-FolderMarker -Path $cfg.Pairs[2].Local).Id | Should -Be $script:id3
            $beta = @(Get-FolderCalls $cfg.Pairs[1].Local)
            $beta[0][0] | Should -Be 'copyto'
            $beta[1] | Should -Contain '--resync'

            # once seeded, no more cat for those folders
            $script:catCalls.Clear()
            $script:calls.Clear()
            $script:catResponder = $null
            Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
            @($script:catCalls | Where-Object { $_[1] -like '*/Beta/*' -or $_[1] -like 'private:*' -or $_[1] -like '*/Alpha/*' }).Count | Should -Be 0
        }

        It 'I1b: AcceptRemoteId skips the PikPak ID check once, the resync runs, and the flag is cleared' {
            $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1; Id = $script:id1 })
            Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ AcceptRemoteId = $true } }
            $script:catResponder = { param($a) @{ ExitCode = 0; Output = (Get-MarkerJson $script:id9 'Elsewhere') } }
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            @($r.Errors).Count | Should -Be 0
            @($r.Ran) | Should -Be @('Alpha')
            $script:catCalls.Count | Should -Be 0
            $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
            $b.Count | Should -Be 1
            $b[0] | Should -Contain '--resync'
            (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].ContainsKey('AcceptRemoteId') | Should -BeFalse

            # the next resync checks PikPak again
            $script:calls.Clear()
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) -ForceResync @('Alpha')
            $script:catCalls.Count | Should -Be 1
            @($r.Ran).Count | Should -Be 0
        }

        It 'I1b: a budget stop keeps AcceptRemoteId for the resync that carries on' {
            $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1; Id = $script:id1 })
            Set-Confirmed $cfg { param($s) $s.Pairs['Alpha'] = @{ AcceptRemoteId = $true } }
            $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 8; BudgetHit = $true } } }
            $null = Invoke-MirrorRun -Config $cfg -Now $script:Now
            $script:catCalls.Count | Should -Be 0
            (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha']['AcceptRemoteId'] | Should -BeTrue
        }

        It 'keeps excluding a paused encrypted folder inside a synced folder' {
            $root = New-TestRoot
            $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'Alpha'; Priority = 1; Id = $script:id1 })
            $secret = Join-Path $cfg.Pairs[0].Local 'Secret'
            New-Item -ItemType Directory -Path $secret -Force | Out-Null
            $cfg.PrivatePaths = @(@{ Path = $secret; Name = 'Secret'; Id = $script:id2; Paused = $true })
            Set-Confirmed $cfg
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            @($r.Ran) | Should -Be @('Alpha')
            @(Get-FolderCalls $secret).Count | Should -Be 0
            $b = @($script:calls | Where-Object { $_[0] -eq 'bisync' })
            $b.Count | Should -Be 1
            $rules = [IO.File]::ReadAllLines((Get-ArgValue $b[0] '--filters-file'))
            $rules | Should -Contain '- /Secret/**'
            Get-ArgValue $b[0] '--exclude-if-present' | Should -BeExactly '.pikpak-encrypted.json'
        }

        It 'leaves a folder without Id as before' {
            $cfg = New-TestConfig -Root (New-TestRoot)
            Set-Confirmed $cfg
            $r = Invoke-MirrorRun -Config $cfg -Now $script:Now
            @($r.Ran) | Should -Be @('Alpha')
            @($r.Errors).Count | Should -Be 0
            Read-FolderMarker -Path $cfg.Pairs[0].Local | Should -BeNullOrEmpty
            $script:catCalls.Count | Should -Be 0
            (Get-MirrorState -StateDir $cfg.StateDir).Pairs['Alpha'].ContainsKey('MarkerWritten') | Should -BeFalse
        }
    }
}

Describe 'Get-FolderIdentity' {
    BeforeAll {
        $script:icfg = @{ Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror' }
        function script:Get-PairId { param($Local, $Remote) Get-FolderIdentity -Folder (New-SyncFolder -Config $script:icfg -Pair @{ Name = 'M'; Local = $Local; Remote = $Remote; Priority = 1 }) }
    }

    It 'ignores spelling differences in the local path and remote folder' {
        $a = Get-PairId 'D:\Music' 'D/Music'
        $a | Should -Match '^[0-9a-f]{64}$'
        Get-PairId 'd:/music/' ' d/music/ ' | Should -Be $a
    }

    It 'changes when either side of the mapping changes' {
        $a = Get-PairId 'D:\Music' 'D/Music'
        Get-PairId 'D:\Music' 'D/Musik' | Should -Not -Be $a
        Get-PairId 'E:\Music' 'D/Music' | Should -Not -Be $a
    }

    It 'keeps the identity hash of an existing pair' {
        # The hash the old Get-PairIdentity gave for D:\Music <-> D/Music; a different one would resync live pairs.
        Get-PairId 'D:\Music' 'D/Music' | Should -BeExactly 'a9d5e3599475a06ddd423bb37d5d53bbca5f97f1b459fdba6f1e5b45e307cb8d'
    }

    It 'gives an encrypted folder its own identity, from its local path and private:<Name>' {
        $p = Get-FolderIdentity -Folder (New-SyncFolder -Config $script:icfg -Private @{ Path = 'D:\Music'; Name = 'Music' })
        $p | Should -Match '^[0-9a-f]{64}$'
        $p | Should -Not -Be (Get-PairId 'D:\Music' 'D/Music')
        $p | Should -BeExactly (Get-TextHash -Lines @('d:\music|private:music'))
        Get-FolderIdentity -Folder (New-SyncFolder -Config $script:icfg -Private @{ Path = 'd:/music/'; Name = 'MUSIC' }) | Should -Be $p
        Get-FolderIdentity -Folder (New-SyncFolder -Config $script:icfg -Private @{ Path = 'D:\Music'; Name = 'Other' }) | Should -Not -Be $p
    }
}

Describe 'Update-FolderFilterFile' {
    It 'writes the rules without BOM and returns their hash' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        $f.Path | Should -Be ([IO.Path]::Combine($cfg.StateDir, 'filters', 'Alpha.txt'))
        $bytes = [IO.File]::ReadAllBytes($f.Path)
        $bytes[0] | Should -Not -Be 0xEF
        $rules = @(New-PairFilterRules -Config $cfg -Pair $cfg.Pairs[0] -GlobalRulesPath $cfg.GlobalFiltersFile)
        $f.Hash | Should -Be (Get-TextHash -Lines $rules)
        @([IO.File]::ReadAllLines($f.Path)) | Should -Be $rules
    }

    It 'keeps a pair''s filter file path and content (private excludes first, then the global rules)' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $priv = Join-Path $cfg.Pairs[0].Local 'Hidden'
        $cfg.PrivatePaths = @(@{ Path = $priv; Name = 'Hidden' })
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        $f.Path | Should -Be ([IO.Path]::Combine($cfg.StateDir, 'filters', 'Alpha.txt'))
        @([IO.File]::ReadAllLines($f.Path)) | Should -Be @('- /Hidden/**', '- Thumbs.db')
        $f.Hash | Should -Be (Get-TextHash -Lines @('- /Hidden/**', '- Thumbs.db'))
    }

    It 'writes an encrypted folder''s rules (global rules only) to filters\private\<Name>.txt' {
        $cfg = New-TestConfig -Root (New-TestRoot)
        $priv = Join-Path $cfg.Pairs[0].Local 'Alpha'
        $cfg.PrivatePaths = @(@{ Path = $priv; Name = 'Alpha' })
        $pf = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Private $cfg.PrivatePaths[0])
        $pf.Path | Should -Be ([IO.Path]::Combine($cfg.StateDir, 'filters', 'private', 'Alpha.txt'))
        @([IO.File]::ReadAllLines($pf.Path)) | Should -Be @('- Thumbs.db')
        $pf.Hash | Should -Be (Get-TextHash -Lines @('- Thumbs.db'))
        [IO.File]::ReadAllBytes($pf.Path)[0] | Should -Not -Be 0xEF
        # the pair of the same name keeps its own file
        $f = Update-FolderFilterFile -Config $cfg -Folder (New-SyncFolder -Config $cfg -Pair $cfg.Pairs[0])
        $f.Path | Should -Not -Be $pf.Path
    }
}

Describe 'Get-SyncFolders' {
    It 'lists encrypted folders first, then pairs by priority and name' {
        $cfg = @{
            Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror'; HoldingRoot = 'PC-Holding'
            PrivatePaths = @(@{ Path = 'D:\Zed'; Name = 'Zed' }, @{ Path = 'D:\Abc'; Name = 'Abc' })
            Pairs = @(
                @{ Name = 'Zeta'; Local = 'D:\Zeta'; Remote = 'D/Zeta'; Priority = 2 }
                @{ Name = 'Alpha'; Local = 'D:\Alpha'; Remote = 'D/Alpha'; Priority = 2 }
                @{ Name = 'Beta'; Local = 'D:\Beta'; Remote = 'D/Beta'; Priority = 1 })
        }
        $f = @(Get-SyncFolders -Config $cfg)
        @($f | ForEach-Object { $_.StateKey }) | Should -Be @('private:Zed', 'private:Abc', 'Beta', 'Alpha', 'Zeta')
        $f[0].Kind | Should -BeExactly 'private'
        $f[0].Name | Should -BeExactly 'Zed'
        $f[0].Local | Should -BeExactly 'D:\Zed'
        $f[0].RemotePath | Should -BeExactly 'private:Zed'
        $f[0].HoldLocal | Should -BeExactly '_private\Zed'
        $f[0].HoldRemote | Should -BeExactly 'private:_holding'
        $f[0].Priority | Should -Be 0
        $f[2].Kind | Should -BeExactly 'pair'
        $f[2].Name | Should -BeExactly 'Beta'
        $f[2].Local | Should -BeExactly 'D:\Beta'
        $f[2].RemotePath | Should -BeExactly 'pikpak:PC-Mirror/D/Beta'
        $f[2].HoldLocal | Should -BeExactly 'Beta'
        $f[2].HoldRemote | Should -BeExactly 'pikpak:PC-Holding'
        $f[2].Priority | Should -Be 1
    }

    It 'returns nothing for an empty config' {
        @(Get-SyncFolders -Config @{ Pairs = @(); PrivatePaths = @() }).Count | Should -Be 0
        @(Get-SyncFolders -Config @{}).Count | Should -Be 0
    }
}

Describe 'Invoke-MirrorRun notifies once per problem' {
    BeforeEach {
        $script:calls = New-Object System.Collections.Generic.List[object]
        $script:toasts = New-Object System.Collections.Generic.List[string]
        $script:responder = $null
        $script:bisyncFail = @{}; $script:bisyncExit = @{}; $script:bisyncThrow = @{}; $script:bisyncBudget = @{}
        Mock Invoke-Rclone {
            $script:calls.Add([string[]]$Arguments)
            $exit = 0; $tmd = $false; $bytes = [long]0
            if ($Arguments[0] -eq 'bisync') {
                $local = $Arguments[1]
                foreach ($k in $script:bisyncFail.Keys) {
                    if ($local -like ('*\' + $k)) { $exit = 2; $tmd = $true }
                }
                foreach ($k in $script:bisyncExit.Keys) {
                    if ($local -like ('*\' + $k)) { $exit = $script:bisyncExit[$k] }
                }
                foreach ($k in $script:bisyncBudget.Keys) {
                    if ($local -like ('*\' + $k)) { $exit = 8 }
                }
                foreach ($k in $script:bisyncThrow.Keys) {
                    if ($local -like ('*\' + $k)) { throw 'boom' }
                }
                if ($script:bytesFor -and $script:bytesFor.ContainsKey($local)) { $bytes = [long]$script:bytesFor[$local] }
            }
            [pscustomobject]@{ ExitCode = $exit; Bytes = $bytes; LogFile = (Get-ArgValue $Arguments '--log-file'); NeedsResync = $false; EmptyListing = $null; BudgetHit = $false; StuckUploads = [string[]]@(); TooManyDeletes = $tmd }
        }
        Mock Send-MirrorToast { $script:toasts.Add($Message) }
        $script:bytesFor = $null
    }

    It 'toasts a lasting problem once, not at every run of the same day' {
        $cfg = New-TestConfig -Root (New-TestRoot); Set-Confirmed $cfg
        $script:bisyncFail = @{ Alpha = $true }
        $r1 = Invoke-MirrorRun -Config $cfg -Now $script:Now
        $r2 = Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1)
        $script:toasts.Count | Should -Be 1
        @($r1.Errors).Count | Should -Be 1
        @($r2.Errors).Count | Should -Be 1
        (Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Issues.Count | Should -Be 1
        (Get-MirrorState -StateDir $cfg.StateDir).Notified['Alpha|delete-safety'] | Should -Be '2026-10-24'
    }
    It 'leaves a Notify log line for a suppressed toast' {
        $cfg = New-TestConfig -Root (New-TestRoot); Set-Confirmed $cfg
        $script:bisyncFail = @{ Alpha = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $logs = @(Get-ChildItem -LiteralPath (Join-Path $cfg.StateDir 'logs') -Filter '*.log' -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
        ($logs -join "`n") | Should -Match 'Notify \(already shown today\): Alpha'
    }
    It 'toasts a lasting problem again the next day' {
        $cfg = New-TestConfig -Root (New-TestRoot); Set-Confirmed $cfg
        $script:bisyncFail = @{ Alpha = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(1) | Out-Null
        $script:toasts.Count | Should -Be 2
    }
    It 'toasts again the same day when the problem was solved in between' {
        $cfg = New-TestConfig -Root (New-TestRoot); Set-Confirmed $cfg
        $script:bisyncFail = @{ Alpha = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:bisyncFail = @{}
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        (Get-MirrorState -StateDir $cfg.StateDir).Notified.ContainsKey('Alpha|delete-safety') | Should -BeFalse
        $script:bisyncFail = @{ Alpha = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(2) | Out-Null
        $script:toasts.Count | Should -Be 2
    }
    It 'keeps the memory of a folder that was not reached because the budget stopped the run' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1 }, @{ Name = 'Beta'; Priority = 2 })
        Set-Confirmed $cfg
        $script:bisyncFail = @{ Beta = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:toasts.Count | Should -Be 1
        # run 2: Alpha is cut off by the run budget (exit 8), so Beta is not tried
        $script:bisyncFail = @{}
        $script:bisyncBudget = @{ Alpha = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        @($script:calls | Where-Object { $_[0] -eq 'bisync' }).Count | Should -BeGreaterThan 0
        (Get-MirrorState -StateDir $cfg.StateDir).Notified.ContainsKey('Beta|delete-safety') | Should -BeTrue
        # run 3, same day (few bytes were used, not day-paused): Beta fails again -> still one toast in total
        Clear-StopPause $cfg
        $script:bisyncBudget = @{}
        $script:bisyncFail = @{ Beta = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(2) | Out-Null
        $script:toasts.Count | Should -Be 1
    }
    It 'an encrypted folder cut off by the budget keeps its memory (it runs behind the seeded pair)' {
        $root = New-TestRoot
        $secret = Join-Path $root 'secret'
        New-Item -ItemType Directory -Path $secret -Force | Out-Null
        $cfg = New-TestConfig -Root $root -Pairs @(@{ Name = 'Alpha'; Priority = 1 }) -PrivatePaths @(@{ Path = $secret; Name = 'Alpha' })
        Set-Confirmed $cfg
        $script:bisyncFail = @{ secret = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:toasts.Count | Should -Be 1
        (Get-MirrorState -StateDir $cfg.StateDir).Notified.ContainsKey('private:Alpha|delete-safety') | Should -BeTrue
        (Get-MirrorState -StateDir $cfg.StateDir).Notified.ContainsKey('Alpha|delete-safety') | Should -BeFalse
        # run 2 (F4 order): the seeded pair runs first, then the unseeded encrypted folder is cut off by the budget
        $script:calls.Clear()
        $script:bisyncFail = @{}
        $script:bisyncBudget = @{ secret = $true }
        $r = Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1)
        @($script:calls | Where-Object { $_[0] -eq 'bisync' } | ForEach-Object { $_[2] }) | Should -Be @('pikpak:PC-Mirror/D/Alpha', 'private:Alpha')
        @($r.Skipped) | Should -Contain 'budget'
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Notified.ContainsKey('private:Alpha|delete-safety') | Should -BeTrue
        $st.Pairs['private:Alpha'].Seeded | Should -BeFalse
        $st.LastRunInfo.Result | Should -BeExactly 'budget-stopped'
        # run 3: fails again the same day -> still one toast
        Clear-StopPause $cfg
        $script:bisyncBudget = @{}
        $script:bisyncFail = @{ secret = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(2) | Out-Null
        $script:toasts.Count | Should -Be 1
    }
    It 'a folder cut off by the budget keeps its earlier problem memory' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1 }, @{ Name = 'Beta'; Priority = 2 })
        Set-Confirmed $cfg
        $script:bisyncFail = @{ Beta = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:bisyncFail = @{}
        $script:bisyncBudget = @{ Beta = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        (Get-MirrorState -StateDir $cfg.StateDir).Notified.ContainsKey('Beta|delete-safety') | Should -BeTrue
        Clear-StopPause $cfg
        $script:bisyncBudget = @{}
        $script:bisyncFail = @{ Beta = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(2) | Out-Null
        $script:toasts.Count | Should -Be 1
    }
    It 'toasts an exit failure and then an exception of the same folder on the same day' {
        $cfg = New-TestConfig -Root (New-TestRoot); Set-Confirmed $cfg
        $script:bisyncExit = @{ Alpha = 5 }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        $script:bisyncExit = @{}
        $script:bisyncThrow = @{ Alpha = $true }
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $script:toasts.Count | Should -Be 2
        $kinds = @((Get-MirrorState -StateDir $cfg.StateDir).LastRunInfo.Issues | ForEach-Object { $_.Kind })
        $kinds | Should -Be @('other')
    }
    It 'toasts the same exit failure once per day' {
        $cfg = New-TestConfig -Root (New-TestRoot); Set-Confirmed $cfg
        $script:bisyncExit = @{ Alpha = 5 }
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $script:toasts.Count | Should -Be 1
        $script:bisyncExit = @{ Alpha = 6 }
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(2) | Out-Null
        $script:toasts.Count | Should -Be 2
    }
    It 'toasts a different config error on the same day, the same one once' {
        $cfg = New-TestConfig -Root (New-TestRoot); Set-Confirmed $cfg
        $cfg.SyncAtLogon = 'maybe'
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $script:toasts.Count | Should -Be 1
        $cfg.Remove('SyncAtLogon'); $cfg.SyncTime = '99:99'
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(2) | Out-Null
        $script:toasts.Count | Should -Be 2
        $cfg.Remove('SyncTime')
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(3) | Out-Null
        @((Get-MirrorState -StateDir $cfg.StateDir).Notified.Keys | Where-Object { $_ -like 'global|config-invalid*' }).Count | Should -Be 0
    }
    It 'forgets global|config-invalid once the config validates' {
        $cfg = New-TestConfig -Root (New-TestRoot) -Pairs @(@{ Name = 'Alpha'; Priority = 1 }, @{ Name = 'Beta'; Priority = 1 })
        Set-Confirmed $cfg
        $cfg.Pairs[1].Name = 'alpha'
        Invoke-MirrorRun -Config $cfg -Now $script:Now | Out-Null
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(1) | Out-Null
        $script:toasts.Count | Should -Be 1
        @((Get-MirrorState -StateDir $cfg.StateDir).Notified.Keys | Where-Object { $_ -like 'global|config-invalid|*' }).Count | Should -Be 1
        $cfg.Pairs[1].Name = 'Beta'
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddHours(2) | Out-Null
        @((Get-MirrorState -StateDir $cfg.StateDir).Notified.Keys | Where-Object { $_ -like 'global|config-invalid*' }).Count | Should -Be 0
    }
}

Describe 'Get-UnknownPairNames' {
    BeforeAll { $script:cfgN = @{ Pairs = @(@{ Name = 'Holiday Photos' }, @{ Name = 'Music' }) } }
    It 'returns nothing when every name matches (case-insensitive)' {
        @(Get-UnknownPairNames -Config $script:cfgN -Names @('holiday photos', 'MUSIC')).Count | Should -Be 0
    }
    It 'returns the names that do not match' {
        @(Get-UnknownPairNames -Config $script:cfgN -Names @('Music', 'Nope', 'Zip')) | Should -Be @('Nope', 'Zip')
    }
    It 'handles an empty list' {
        @(Get-UnknownPairNames -Config $script:cfgN -Names @()).Count | Should -Be 0
    }
    It 'accepts private:<Name> and rejects unknown names' {
        $cfg = @{ Pairs = @(@{ Name = 'Docs'; Local = 'D:\Docs'; Remote = 'D/Docs'; Priority = 1 }); PrivatePaths = @(@{ Path = 'D:\Secret'; Name = 'Docs' }) }
        @(Get-UnknownPairNames -Config $cfg -Names 'private:Docs', 'Docs', 'private:Nope') | Should -Be @('private:Nope')
        @(Get-UnknownPairNames -Config $cfg -Names 'PRIVATE:docs').Count | Should -Be 0
        # a bare encrypted-folder name is not its key
        $cfg2 = @{ Pairs = @(); PrivatePaths = @(@{ Path = 'D:\Secret'; Name = 'Secret' }) }
        @(Get-UnknownPairNames -Config $cfg2 -Names 'Secret') | Should -Be @('Secret')
    }
}

Describe 'Invoke-Sync.ps1' {
    It 'parses without errors' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '..\scripts\Invoke-Sync.ps1'), [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
    }
}
