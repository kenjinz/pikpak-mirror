BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    function script:Test-HasPair {
        param([string[]]$Args_, [string]$Flag, [string]$Value)
        for ($i = 0; $i -lt $Args_.Count - 1; $i++) {
            if ($Args_[$i] -ceq $Flag -and $Args_[$i + 1] -ceq $Value) { return $true }
        }
        return $false
    }

    $script:cfg = @{
        Remote           = 'pikpak'
        PrivateRemote    = 'private'
        MirrorRoot       = 'PC-Mirror'
        HoldingRoot      = 'PC-Holding'
        LocalHolding     = 'D:\.pikpak-holding'
        StateDir         = 'C:\State\PikPakMirror'
        MaxDeletePercent = 10
        BwLimit          = '18:00,2M:off 23:00,off'
    }
    $script:pair = @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 2 }
    $script:cfg.Pairs = @($script:pair)
    $script:cfg.PrivatePaths = @(@{ Path = 'D:\Photos'; Name = 'Photos' })
    $script:folder = @(Get-SyncFolders -Config $script:cfg | Where-Object { $_.Kind -eq 'pair' })[0]
    $script:date = [datetime]'2026-10-24'
    $script:log = 'C:\logs\run.log'

    function script:Get-ArgValue {
        param([string[]]$A, [string]$Name)
        $i = [array]::IndexOf($A, $Name)
        if ($i -ge 0) { $A[$i + 1] }
    }
}

Describe 'New-BisyncArgs' {
    BeforeEach {
        $script:a = @(New-BisyncArgs -Config $script:cfg -Folder $script:folder -FiltersFile 'C:\State\filters\Music.txt' -Date $script:date -BudgetBytes 8589934592 -LogFile $script:log)
    }

    It 'starts with bisync and the two roots' {
        $script:a[0..2] | Should -Be @('bisync', 'D:\Music', 'pikpak:PC-Mirror/D/Music')
    }

    It 'contains the core flag/value pairs' {
        $pairs = @(
            @('--compare', 'size,modtime'), @('--conflict-resolve', 'path1'), @('--conflict-loser', 'num'),
            @('--max-delete', '10'),
            @('--backup-dir1', 'D:\.pikpak-holding\2026-10-24\Music'),
            @('--backup-dir2', 'pikpak:PC-Holding/2026-10-24/Music'),
            @('--max-transfer', '8589934592B'), @('--cutoff-mode', 'cautious'),
            @('--bwlimit', '18:00,2M:off 23:00,off'),
            @('--filters-file', 'C:\State\filters\Music.txt'),
            @('--workdir', 'C:\State\PikPakMirror\bisync'),
            @('--max-lock', '2h'),
            @('--stats-log-level', 'NOTICE'), @('--stats', '30s'),
            @('--log-file', 'C:\logs\run.log')
        )
        foreach ($p in $pairs) {
            (Test-HasPair -Args_ $script:a -Flag $p[0] -Value $p[1]) | Should -BeTrue -Because "$($p[0]) $($p[1])"
        }
    }

    It 'contains the safety switches' {
        foreach ($f in '--check-access', '--resilient', '--recover', '--use-json-log') { $script:a | Should -Contain $f }
    }

    It 'omits checksum, resync and force by default' {
        foreach ($f in '--checksum', '--resync', '--force') { $script:a | Should -Not -Contain $f }
    }

    It 'adds --resync and --force on request' {
        $r = @(New-BisyncArgs -Config $script:cfg -Folder $script:folder -FiltersFile 'f' -Date $script:date -BudgetBytes 1 -LogFile $script:log -Resync)
        $r | Should -Contain '--resync'
        $r | Should -Not -Contain '--force'
        $f = @(New-BisyncArgs -Config $script:cfg -Folder $script:folder -FiltersFile 'f' -Date $script:date -BudgetBytes 1 -LogFile $script:log -Force)
        $f | Should -Contain '--force'
        $f | Should -Not -Contain '--resync'
    }

    It 'adds exclude-if-present for synced folders only' {
        # A moved-in encrypted folder (it carries .pikpak-encrypted.json) never reaches the plain remote.
        (Test-HasPair -Args_ $script:a -Flag '--exclude-if-present' -Value '.pikpak-encrypted.json') | Should -BeTrue
        @($script:a | Where-Object { $_ -ceq '--exclude-if-present' }).Count | Should -Be 1
        $f = @(Get-SyncFolders -Config $script:cfg | Where-Object { $_.Kind -eq 'private' })[0]
        $e = @(New-BisyncArgs -Config $script:cfg -Folder $f -FiltersFile 'f.txt' -Date $script:date -BudgetBytes 1 -LogFile 'l.log' -Resync)
        $e | Should -Not -Contain '--exclude-if-present'
    }
}

Describe 'New-BisyncArgs for an encrypted folder' {
    It 'builds bisync arguments for an encrypted folder' {
        $f = @(Get-SyncFolders -Config $script:cfg | Where-Object { $_.Kind -eq 'private' })[0]   # entry Name 'Photos', Path D:\Photos
        $a = @(New-BisyncArgs -Config $script:cfg -Folder $f -FiltersFile 'f.txt' -Date ([datetime]'2026-11-15') -BudgetBytes 1 -LogFile 'l.log')
        $a[0..2] | Should -Be @('bisync', 'D:\Photos', 'private:Photos')
        (Get-ArgValue $a '--backup-dir1') | Should -Be (Join-Path $script:cfg.LocalHolding '2026-11-15\_private\Photos')
        (Get-ArgValue $a '--backup-dir2') | Should -Be 'private:_holding/2026-11-15/Photos'
        # nothing of an encrypted folder may point at the plain remote
        foreach ($x in $a) { $x | Should -Not -BeLike 'pikpak:*' }
    }

    It 'uses the same flags as a synced folder, only the paths differ' {
        # (apart from the synced folder's --exclude-if-present .pikpak-encrypted.json)
        $f = @(Get-SyncFolders -Config $script:cfg | Where-Object { $_.Kind -eq 'private' })[0]
        $a = @(New-BisyncArgs -Config $script:cfg -Folder $f -FiltersFile 'f.txt' -Date $script:date -BudgetBytes 1 -LogFile 'l.log' -Resync)
        $b = @(New-BisyncArgs -Config $script:cfg -Folder $script:folder -FiltersFile 'f.txt' -Date $script:date -BudgetBytes 1 -LogFile 'l.log' -Resync)
        $b = @($b | Where-Object { $_ -cne '--exclude-if-present' -and $_ -cne '.pikpak-encrypted.json' })
        $a.Count | Should -Be $b.Count
        @($a | Where-Object { $_.StartsWith('--') }) | Should -Be @($b | Where-Object { $_.StartsWith('--') })
    }
}

Describe 'New-BisyncArgs keeps a pair unchanged' {
    It 'keeps a pair''s arguments exactly as before' {
        # The literal list the old -Pair builder produced; any change would force a resync of the live pairs.
        $a = @(New-BisyncArgs -Config $script:cfg -Folder $script:folder -FiltersFile 'C:\State\filters\Music.txt' -Date $script:date -BudgetBytes 8589934592 -LogFile $script:log -Resync)
        $expected = @(
            'bisync', 'D:\Music', 'pikpak:PC-Mirror/D/Music',
            '--compare', 'size,modtime', '--conflict-resolve', 'path1', '--conflict-loser', 'num', '--max-delete', '10',
            '--backup-dir1', 'D:\.pikpak-holding\2026-10-24\Music', '--backup-dir2', 'pikpak:PC-Holding/2026-10-24/Music',
            '--max-transfer', '8589934592B', '--cutoff-mode', 'cautious', '--bwlimit', '18:00,2M:off 23:00,off',
            '--filters-file', 'C:\State\filters\Music.txt', '--ignore-case', '--workdir', 'C:\State\PikPakMirror\bisync',
            '--max-lock', '2h', '--check-access', '--resilient', '--recover', '--use-json-log', '--stats', '30s',
            '--stats-log-level', 'NOTICE', '--log-level', 'INFO', '--log-file', 'C:\logs\run.log',
            # Added on purpose for every synced folder (no resync needed: Get-FolderIdentity and the filters file stay).
            '--exclude-if-present', '.pikpak-encrypted.json', '--resync')
        $a.Count | Should -Be $expected.Count
        for ($i = 0; $i -lt $expected.Count; $i++) { $a[$i] | Should -BeExactly $expected[$i] -Because "argument $i" }
    }
}

Describe 'one-way private sync is gone' {
    It 'New-PrivateSyncArgs no longer exists' {
        Get-Command New-PrivateSyncArgs -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'New-PruneArgs' {
    It 'builds a delete that keeps the last Days holding-date folders (by folder name, not file age)' {
        $a = @(New-PruneArgs -Target 'pikpak:PC-Holding' -Now ([datetime]'2026-10-24T13:45:10') -Days 30 -LogFile $script:log)
        $a[0..1] | Should -Be @('delete', 'pikpak:PC-Holding')
        $a | Should -Not -Contain '--min-age'
        $a | Should -Contain '--rmdirs'
        (Test-HasPair -Args_ $a -Flag '--log-file' -Value 'C:\logs\run.log') | Should -BeTrue
        $i = [array]::IndexOf($a, '--exclude')
        $i | Should -BeGreaterThan 1
        $ex = $a[$i + 1]
        $ex | Should -BeLike '/{2026-10-24,2026-10-23,*}/**'
        $dates = $ex.Substring(2, $ex.Length - 2 - 4).Split(',')
        $dates.Count | Should -Be 30
        $dates[0] | Should -Be '2026-10-24'
        $dates[29] | Should -Be '2026-09-25'
        @([array]::FindAll($a, [Predicate[string]] { param($x) $x -eq '--exclude' })).Count | Should -Be 1
    }

    It 'keeps exactly one date folder when Days is 1' {
        $a = @(New-PruneArgs -Target 'D:\.pikpak-holding' -Now ([datetime]'2026-01-01T00:10:00') -Days 1 -LogFile $script:log)
        $a[[array]::IndexOf($a, '--exclude') + 1] | Should -Be '/{2026-01-01}/**'
    }

    It 'refuses a bare remote root, a drive root, an empty target or Days below 1' {
        $n = [datetime]'2026-10-24'
        foreach ($t in @('pikpak:', 'private:', 'D:', 'D:\', 'd:\', '', '   ')) {
            { New-PruneArgs -Target $t -Now $n -Days 30 -LogFile $script:log } | Should -Throw '*prune*' -Because "target '$t'"
        }
        { New-PruneArgs -Target 'pikpak:PC-Holding' -Now $n -Days 0 -LogFile $script:log } | Should -Throw '*at least 1*'
        { New-PruneArgs -Target 'pikpak:PC-Holding' -Now $n -Days -5 -LogFile $script:log } | Should -Throw '*at least 1*'
    }
}

Describe 'New-PurgeArgs' {
    It 'builds a purge of exactly the target with a log file' {
        $a = @(New-PurgeArgs -Target 'pikpak:PC-Mirror/D/Docs' -LogFile $script:log)
        $a | Should -Be @('purge', 'pikpak:PC-Mirror/D/Docs', '--log-level', 'INFO', '--log-file', 'C:\logs\run.log')
    }

    It 'refuses an empty target, a remote root, a local path or an unusual segment' {
        $bad = @('', '   ', 'pikpak:', 'private:', 'pikpak:/', 'pikpak://', 'pikpak: / ', 'D:\', 'D:\Docs', 'C:', 'Docs', ':Docs',
            'pikpak:/PC-Mirror/D', 'pikpak:PC-Mirror//D', 'pikpak:PC-Mirror/D/', 'pikpak:PC-Mirror/../D', 'pikpak:PC-Mirror/./D',
            'pikpak:PC-Mirror/ /D', 'pikpak:PC-Mirror/D/ Docs', 'pikpak:PC-Mirror\D')
        foreach ($t in $bad) {
            { New-PurgeArgs -Target $t -LogFile $script:log } | Should -Throw '*refusing to purge*' -Because "target '$t'"
        }
    }

    It 'accepts a folder with spaces and dots in its name and a remote name with a space' {
        @(New-PurgeArgs -Target 'Pikpak remote:PC-Mirror/H/New folder/a.b' -LogFile $script:log)[1] | Should -BeExactly 'Pikpak remote:PC-Mirror/H/New folder/a.b'
        @(New-PurgeArgs -Target 'private:Docs (2)' -LogFile $script:log)[1] | Should -BeExactly 'private:Docs (2)'
    }
}

Describe 'I7: --log-level INFO on every logged builder' {
    It '<Name> logs at INFO' -TestCases @(
        @{ Name = 'bisync'; Build = { New-BisyncArgs -Config $script:cfg -Folder $script:folder -FiltersFile 'f' -Date $script:date -BudgetBytes 1 -LogFile $script:log } }
        @{ Name = 'prune'; Build = { New-PruneArgs -Target 'pikpak:PC-Holding' -Now $script:date -Days 30 -LogFile $script:log } }
        @{ Name = 'purge'; Build = { New-PurgeArgs -Target 'pikpak:PC-Mirror/D/Docs' -LogFile $script:log } }
    ) {
        param($Name, $Build)
        $a = @(& $Build)
        (Test-HasPair -Args_ $a -Flag '--log-level' -Value 'INFO') | Should -BeTrue
        (Test-HasPair -Args_ $a -Flag '--log-file' -Value $script:log) | Should -BeTrue
    }
}
