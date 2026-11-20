BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    $script:Now = [datetime]'2026-10-24T13:45:10'

    function New-TestRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root
    }

    function New-RawConfig {
        # A raw config whose every local path lives under $Root. Pairs: @{Name; Dir (under <root>\watch); Remote}.
        # PrivatePaths: @{Name; Dir (under <root>\watch)}. Folders are created.
        param([string]$Root, [object[]]$Pairs = @(), [object[]]$PrivatePaths = @())
        $watch = Join-Path $Root 'watch'
        New-Item -ItemType Directory -Path $watch -Force | Out-Null
        $global = Join-Path $Root 'filters.txt'
        if (-not (Test-Path -LiteralPath $global)) {
            [IO.File]::WriteAllLines($global, [string[]]@('# global', '- Thumbs.db'), (New-Object Text.UTF8Encoding $false))
        }
        $pairList = @()
        foreach ($p in $Pairs) {
            $local = Join-Path $watch $p.Dir
            New-Item -ItemType Directory -Path $local -Force | Out-Null
            $prio = 1
            if ($p.ContainsKey('Priority')) { $prio = $p.Priority }
            $pairList += @{ Name = $p.Name; Local = $local; Remote = $p.Remote; Priority = $prio }
        }
        $privList = @()
        foreach ($v in $PrivatePaths) {
            $path = Join-Path $watch $v.Dir
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            $privList += @{ Path = $path; Name = $v.Name }
        }
        @{
            Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror'; HoldingRoot = 'PC-Holding'
            LocalHolding = (Join-Path $Root 'holding'); StateDir = (Join-Path $Root 'state')
            GlobalFiltersFile = $global
            HoldingDays = 30; MaxDeletePercent = 10; DailyBudgetGB = 8; MonthlyBudgetGB = 250; QuotaWarnPercent = 90
            StaleRunDays = 3; LogKeepDays = 60; BwLimit = 'off'
            PrivatePaths = $privList; Pairs = $pairList
        }
    }

    function New-ConfigFile {
        # Writes the raw config to <root>\config\mirror.config.psd1 with the app's writer and confirms its
        # encrypted folders in a seeded state (every folder Seeded, as after earlier syncs). Returns the path.
        param([string]$Root, [hashtable]$Raw, [switch]$Unseeded)
        $dir = Join-Path $Root 'config'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'mirror.config.psd1'
        $errs = @(Save-MirrorConfig -Path $path -Config $Raw)
        $errs | Should -BeNullOrEmpty
        $cfg = Get-MirrorConfig -Path $path
        $s = Get-MirrorState -StateDir $cfg.StateDir
        $s.PrivateConfirmedHash = Get-PrivatePathsHash -Config $cfg
        Save-MirrorState -StateDir $cfg.StateDir -State $s
        $path
    }

    function Get-ArgValue {
        param([string[]]$A, [string]$Name)
        $i = [array]::IndexOf($A, $Name)
        if ($i -ge 0) { $A[$i + 1] }
    }

    function Get-Bisyncs { @($script:calls | Where-Object { $_[0] -eq 'bisync' }) }
    function Get-Purges { @($script:calls | Where-Object { $_[0] -eq 'purge' }) }
}

Describe 'Get-BisyncSessionName' {
    It 'names a folder pair the way rclone bisync names its listing files' {
        # Names seen in a real bisync workdir of this app.
        Get-BisyncSessionName -Local 'H:\Data\Photos\Album' -RemotePath 'Pikpak remote:PC-Mirror/H/Data/Photos/Album' |
            Should -BeExactly 'H__Data_Photos_Album..Pikpak_remote_PC-Mirror_H_Data_Photos_Album'
        Get-BisyncSessionName -Local 'C:\Users\Alex\Documents' -RemotePath 'Pikpak remote:PC-Mirror/C-Users/Documents' |
            Should -BeExactly 'C__Users_Alex_Documents..Pikpak_remote_PC-Mirror_C-Users_Documents'
        Get-BisyncSessionName -Local 'D:\PrivateMock' -RemotePath 'private:PrivateMock' | Should -BeExactly 'D__PrivateMock..private_PrivateMock'
    }

    It 'refuses an empty side' {
        { Get-BisyncSessionName -Local '' -RemotePath 'private:A' } | Should -Throw
        { Get-BisyncSessionName -Local 'D:\A' -RemotePath '' } | Should -Throw
    }
}

Describe 'Remove-BisyncListings' {
    It 'deletes the listing files of exactly one session' {
        $dir = Join-Path (New-TestRoot) 'bisync'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $mine = 'D__w_Docs..pikpak_PC-Mirror_D_Docs'
        $suffixes = @('.path1.lst', '.path2.lst', '.path1.lst-old', '.path2.lst-new', '.path1.lst-err', '.path1.lst-dry-new', '.lck', '.copy1to2.que')
        $others = @(
            'D__w_Docs..private_Docs.path1.lst',                     # same folder, other remote
            'D__w_Docs2..pikpak_PC-Mirror_D_Docs2.path1.lst',        # name that starts the same
            'X..D__w_Docs..pikpak_PC-Mirror_D_Docs.path1.lst',       # contains the session
            'D__w_Docs..pikpak_PC-Mirror_D_Docs.notes.txt',          # not a bisync file
            'D__w_Docs..pikpak_PC-Mirror_D_Docs_more.path1.lst'
        )
        foreach ($s in $suffixes) { [IO.File]::WriteAllText((Join-Path $dir ($mine + $s)), 'x') }
        foreach ($o in $others) { [IO.File]::WriteAllText((Join-Path $dir $o), 'x') }
        $removed = @(Remove-BisyncListings -WorkDir $dir -Session $mine)
        $removed.Count | Should -Be $suffixes.Count
        @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @($others | Sort-Object)
    }

    It 'does nothing when the work folder does not exist' {
        @(Remove-BisyncListings -WorkDir (Join-Path (New-TestRoot) 'nope') -Session 'a..b').Count | Should -Be 0
    }

    It 'refuses a session name that is not <path1>..<path2>' {
        $dir = New-TestRoot
        foreach ($s in @('', '..', 'a..', '..b', 'ab', 'a..b\c', '*..b')) {
            { Remove-BisyncListings -WorkDir $dir -Session $s } | Should -Throw -Because "session '$s'"
        }
    }
}

Describe 'Get-FolderConversionPlan' {
    It 'plans synced to encrypted' {
        $root = New-TestRoot
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }, @{ Name = 'Music'; Dir = 'Music'; Remote = 'D/Music' })
        $docs = Join-Path $root 'watch\Docs'
        $p = Get-FolderConversionPlan -Config $raw -Path $docs -To 'encrypted'
        @($p.NewConfig.Pairs | ForEach-Object { $_.Name }) | Should -Be @('Music')
        @($p.NewConfig.PrivatePaths).Count | Should -Be 1
        $p.NewConfig.PrivatePaths[0].Path | Should -Be $docs
        $p.NewConfig.PrivatePaths[0].Name | Should -BeExactly 'Docs'
        $p.OldRemote | Should -BeExactly 'pikpak:PC-Mirror/D/Docs'
        $p.NewKind | Should -Be 'private'
        $p.NewName | Should -BeExactly 'Docs'
        $p.NewStateKey | Should -BeExactly 'private:Docs'
        $p.From.Kind | Should -Be 'pair'
        $p.From.StateKey | Should -BeExactly 'Docs'
        $p.Note | Should -BeNullOrEmpty
        # the input is not changed
        @($raw.Pairs).Count | Should -Be 2
        @($raw.PrivatePaths).Count | Should -Be 0
    }

    It 'names the new encrypted folder like adding one does (unique, never _holding)' {
        $root = New-TestRoot
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }, @{ Name = 'H'; Dir = '_holding'; Remote = 'D/_holding' }) `
            -PrivatePaths @(@{ Name = 'docs'; Dir = 'Other' })
        (Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted').NewName | Should -BeExactly 'Docs (2)'
        (Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\_holding') -To 'encrypted').NewName | Should -BeExactly '_holding (2)'
    }

    It 'plans encrypted to synced with a new pair' {
        $root = New-TestRoot
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Music'; Dir = 'Music'; Remote = 'D/Music' }) -PrivatePaths @(@{ Name = 'Docs'; Dir = 'Docs' })
        $docs = Join-Path $root 'watch\Docs'
        $p = Get-FolderConversionPlan -Config $raw -Path $docs -To 'plain'
        $p.OldRemote | Should -BeExactly 'private:Docs'
        $p.From.Kind | Should -Be 'private'
        $p.From.StateKey | Should -BeExactly 'private:Docs'
        @($p.NewConfig.PrivatePaths | Where-Object { $_ }).Count | Should -Be 0
        $expected = New-MirrorPair -Path $docs -Config $raw
        $new = @($p.NewConfig.Pairs | Where-Object { $_.Name -ne 'Music' })
        $new.Count | Should -Be 1
        foreach ($k in 'Name', 'Local', 'Remote', 'Priority') { $new[0][$k] | Should -Be $expected[$k] }
        $p.NewKind | Should -Be 'pair'
        $p.NewName | Should -BeExactly $expected.Name
        $p.NewStateKey | Should -BeExactly $expected.Name
        $p.Note | Should -BeNullOrEmpty
    }

    It 'plans encrypted to synced inside a synced folder without a new pair' {
        $root = New-TestRoot
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Docs\Secret' })
        $p = Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs\Secret') -To 'plain'
        $p.Note | Should -Not -BeNullOrEmpty
        $p.Note | Should -Match 'Docs'
        @($p.NewConfig.Pairs).Count | Should -Be 1
        @($p.NewConfig.PrivatePaths | Where-Object { $_ }).Count | Should -Be 0
        $p.NewKind | Should -Be 'pair'
        $p.NewStateKey | Should -BeExactly 'Docs'
        $p.OldRemote | Should -BeExactly 'private:Secret'
    }

    It 'carries Id and Paused to the new entry' {
        $root = New-TestRoot
        $id1 = [guid]::NewGuid().ToString(); $id2 = [guid]::NewGuid().ToString(); $id3 = [guid]::NewGuid().ToString()
        # synced -> encrypted (paused)
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $raw.Pairs[0].Id = $id1; $raw.Pairs[0].Paused = $true
        $p = Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted'
        $p.NewConfig.PrivatePaths[0].Id | Should -BeExactly $id1
        $p.NewConfig.PrivatePaths[0].Paused | Should -BeTrue
        # synced -> encrypted (not paused: no Paused key invented)
        $raw.Pairs[0].Remove('Paused')
        $p = Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted'
        $p.NewConfig.PrivatePaths[0].Id | Should -BeExactly $id1
        $p.NewConfig.PrivatePaths[0].ContainsKey('Paused') | Should -BeFalse
        # encrypted -> synced (new pair)
        $raw = New-RawConfig -Root $root -PrivatePaths @(@{ Name = 'Vault'; Dir = 'Vault' })
        $raw.PrivatePaths[0].Id = $id2; $raw.PrivatePaths[0].Paused = $true
        $p = Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Vault') -To 'plain'
        $np = @($p.NewConfig.Pairs)[0]
        $np.Id | Should -BeExactly $id2
        $np.Paused | Should -BeTrue
        # encrypted -> synced inside a synced folder: no new entry, nothing carried
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Docs\Secret' })
        $raw.Pairs[0].Id = $id3
        $raw.PrivatePaths[0].Id = $id2; $raw.PrivatePaths[0].Paused = $true
        $p = Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs\Secret') -To 'plain'
        @($p.NewConfig.Pairs).Count | Should -Be 1
        $p.NewConfig.Pairs[0].Id | Should -BeExactly $id3
        $p.NewConfig.Pairs[0].ContainsKey('Paused') | Should -BeFalse
    }

    It 'refuses a folder that is not of the old kind' {
        $root = New-TestRoot
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Secret' })
        { Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Secret') -To 'encrypted' } | Should -Throw '*is not a synced folder*'
        { Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'plain' } | Should -Throw '*is not an encrypted folder*'
        { Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Elsewhere') -To 'encrypted' } | Should -Throw '*is not a synced folder*'
        { Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs\Sub') -To 'encrypted' } | Should -Throw '*is not a synced folder*'
        { Get-FolderConversionPlan -Config $raw -Path '' -To 'encrypted' } | Should -Throw
    }

    It 'M4: every refusal message starts with a capital letter' {
        $root = New-TestRoot
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Docs\Secret' }, @{ Name = 'Top'; Dir = 'Top' })
        $cases = @(
            @{ P = (Join-Path $root 'watch\Top'); To = 'encrypted' }
            @{ P = (Join-Path $root 'watch\Docs'); To = 'plain' }
            @{ P = (Join-Path $root 'watch\Docs'); To = 'encrypted' }
            @{ P = (Join-Path $root 'watch\Docs\Secret\Sub'); To = 'encrypted' }
            @{ P = (Join-Path $root 'watch\Nowhere'); To = 'encrypted' }
            @{ P = ''; To = 'encrypted' }
        )
        foreach ($c in $cases) {
            $msg = $null
            try { $null = Get-FolderConversionPlan -Config $raw -Path $c.P -To $c.To } catch { $msg = $_.Exception.Message }
            $msg | Should -Not -BeNullOrEmpty -Because "case $($c.P) $($c.To)"
            $msg | Should -MatchExactly '^[A-Z]' -Because $msg
        }
        $raw2 = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = '//' })
        $msg = $null
        try { $null = Get-FolderConversionPlan -Config $raw2 -Path (Join-Path $root 'watch\Docs') -To 'encrypted' -DeleteOldCopy } catch { $msg = $_.Exception.Message }
        $msg | Should -MatchExactly '^[A-Z]'
    }

    It 'refuses to make encrypted a synced folder that contains an encrypted folder' {
        $root = New-TestRoot
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Docs\Secret' })
        { Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted' } | Should -Throw '*contains the encrypted folder*'
    }

    It 'builds the old copy from the pair''s own Remote (unusual remotes)' {
        $root = New-TestRoot
        $cases = @(
            @{ Remote = 'D'; Expected = 'pikpak:PC-Mirror/D' }
            @{ Remote = 'C-Users/Documents'; Expected = 'pikpak:PC-Mirror/C-Users/Documents' }
            @{ Remote = 'H/New folder/My Docs.2024'; Expected = 'pikpak:PC-Mirror/H/New folder/My Docs.2024' }
            @{ Remote = '/D/Docs/'; Expected = 'pikpak:PC-Mirror/D/Docs' }
        )
        foreach ($c in $cases) {
            $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = $c.Remote })
            (Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted').OldRemote | Should -BeExactly $c.Expected -Because $c.Remote
        }
    }

    It 'refuses to plan a purge of a root' {
        $root = New-TestRoot
        foreach ($r in @('', '/', ' ', '//', '../x', 'D/../..')) {
            $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
            $raw.Pairs[0].Remote = $r
            { Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted' -DeleteOldCopy } | Should -Throw '*cannot be deleted safely*' -Because "Remote '$r'"
        }
        # renamed roots are followed: MirrorRoot 'Mirror2' gives pikpak:Mirror2/D
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D' })
        $raw.MirrorRoot = 'Mirror2'
        (Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted').OldRemote | Should -BeExactly 'pikpak:Mirror2/D'

        $cfg = New-RawConfig -Root $root
        $pair = @{ Kind = 'pair'; Name = 'X'; Remote = 'D' }
        $priv = @{ Kind = 'private'; Name = 'X'; Remote = $null }
        foreach ($t in @('pikpak:PC-Mirror', 'pikpak:PC-Mirror/', 'pikpak:/PC-Mirror', 'PIKPAK:pc-mirror', 'pikpak:PC-Holding', 'pikpak:PC-Holding/2026-10-24',
                'pikpak:', 'pikpak:PC-Private', 'pikpak:PC-Private/x', 'private:PC-Mirror/D', 'pikpak:Other/D', 'D:\Docs')) {
            { Assert-ConversionPurgeTarget -Config $cfg -Folder ($pair + @{ RemotePath = $t }) } | Should -Throw -Because "pair target '$t'"
        }
        foreach ($t in @('private:_holding', 'private:_HOLDING', 'private:', 'private:/', 'private:a/b', 'pikpak:X', 'private:_holding/2026-10-24')) {
            { Assert-ConversionPurgeTarget -Config $cfg -Folder ($priv + @{ RemotePath = $t }) } | Should -Throw -Because "encrypted target '$t'"
        }
        Assert-ConversionPurgeTarget -Config $cfg -Folder ($pair + @{ RemotePath = 'pikpak:PC-Mirror/D' }) | Should -BeExactly 'pikpak:PC-Mirror/D'
        Assert-ConversionPurgeTarget -Config $cfg -Folder ($priv + @{ RemotePath = 'private:X' }) | Should -BeExactly 'private:X'
        # an encrypted folder that would be named _holding (a hand-edited config) is refused too
        $raw = New-RawConfig -Root $root -PrivatePaths @(@{ Name = '_holding'; Dir = 'H' })
        { Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\H') -To 'plain' -DeleteOldCopy } | Should -Throw '*cannot be deleted safely*'
    }

    It 'does not let an odd old-copy path block a change that keeps the old copy' {
        $root = New-TestRoot
        foreach ($r in @('D/ Docs', 'D/Docs ', ' D/Docs')) {
            $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
            $raw.Pairs[0].Remote = $r
            $p = Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted'
            $p.PurgeRefusal | Should -Not -BeNullOrEmpty -Because "Remote '$r'"
            $p.NewKind | Should -Be 'private'
        }
        $raw = New-RawConfig -Root $root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        (Get-FolderConversionPlan -Config $raw -Path (Join-Path $root 'watch\Docs') -To 'encrypted').PurgeRefusal | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-MirrorFolderConversion' {
    BeforeEach {
        $script:calls = New-Object System.Collections.Generic.List[object]
        $script:toasts = New-Object System.Collections.Generic.List[string]
        $script:responder = $null
        Mock Invoke-Rclone {
            $script:calls.Add([string[]]$Arguments)
            $r = $null
            if ($script:responder) { $r = & $script:responder ([string[]]$Arguments) }
            if ($null -eq $r) { $r = @{} }
            $exit = 0; $bh = $false
            if ($r.ContainsKey('ExitCode')) { $exit = $r.ExitCode }
            if ($r.ContainsKey('BudgetHit')) { $bh = $r.BudgetHit }
            [pscustomobject]@{ ExitCode = $exit; Bytes = [long]0; LogFile = (Get-ArgValue $Arguments '--log-file'); NeedsResync = $false; EmptyListing = $null; BudgetHit = $bh; StuckUploads = [string[]]@(); TooManyDeletes = [bool]$r['TooManyDeletes'] }
        }
        Mock Send-MirrorToast { $script:toasts.Add($Message) }
        $script:root = New-TestRoot
        $script:docs = Join-Path $script:root 'watch\Docs'
    }

    It 'changes nothing when the last sync fails' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $before = [IO.File]::ReadAllBytes($path)
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 1 } } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.OldCopyDeleted | Should -BeFalse
        $r.Message | Should -Match '^Docs was not changed: it could not be synced one last time \('
        [IO.File]::ReadAllBytes($path) | Should -Be $before
        @(Get-Purges).Count | Should -Be 0
        @(Get-Bisyncs).Count | Should -Be 1
        (Get-MirrorState -StateDir $raw.StateDir).Pairs.ContainsKey('Docs') | Should -BeTrue
        $script:toasts | Should -Contain $r.Message
    }

    It 'changes nothing when a sync is already running (lock held)' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $before = [IO.File]::ReadAllBytes($path)
        $h = Enter-MirrorLock -StateDir $raw.StateDir
        try { $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now }
        finally { Exit-MirrorLock -Handle $h }
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'a sync is already running'
        $script:calls.Count | Should -Be 0
        [IO.File]::ReadAllBytes($path) | Should -Be $before
        @($script:toasts).Count | Should -Be 1
    }

    It 'changes nothing when today''s transfer limit is reached' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $s = Get-MirrorState -StateDir $raw.StateDir
        $s.DayStopped = '2026-10-24'
        Save-MirrorState -StateDir $raw.StateDir -State $s
        $before = [IO.File]::ReadAllBytes($path)
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'transfer limit'
        $script:calls.Count | Should -Be 0
        [IO.File]::ReadAllBytes($path) | Should -Be $before
    }

    It 'changes nothing when the last sync is cut off by the transfer limit' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $before = [IO.File]::ReadAllBytes($path)
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; BudgetHit = $true } } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        @(Get-Purges).Count | Should -Be 0
        [IO.File]::ReadAllBytes($path) | Should -Be $before
    }

    It 'changes nothing when the folder is missing or the encrypted folders are not confirmed' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'S'; Dir = 'S' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $before = [IO.File]::ReadAllBytes($path)
        Remove-Item -LiteralPath $script:docs -Recurse -Force
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'not found'
        New-Item -ItemType Directory -Path $script:docs -Force | Out-Null
        $s = Get-MirrorState -StateDir $raw.StateDir
        $s.PrivateConfirmedHash = 'other'
        Save-MirrorState -StateDir $raw.StateDir -State $s
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'not confirmed'
        @(Get-Bisyncs).Count | Should -Be 0
        @(Get-Purges).Count | Should -Be 0
        [IO.File]::ReadAllBytes($path) | Should -Be $before
    }

    It 'changes nothing when the plan is refused' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'plain' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'is not an encrypted folder'
        $script:calls.Count | Should -Be 0
        @($script:toasts).Count | Should -Be 1
    }

    It 'switches, forgets the old state, purges the old copy and syncs the new form' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }, @{ Name = 'Music'; Dir = 'Music'; Remote = 'D/Music' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $cfg = Get-MirrorConfig -Path $path
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(-1) | Out-Null
        $s = Get-MirrorState -StateDir $cfg.StateDir
        $s.Notified['Docs|other'] = '2026-10-23'
        $s.Notified['Music|other'] = '2026-10-23'
        Save-MirrorState -StateDir $cfg.StateDir -State $s
        $oldFilter = Join-Path $cfg.StateDir 'filters\Docs.txt'
        Test-Path -LiteralPath $oldFilter | Should -BeTrue
        $work = Join-Path $cfg.StateDir 'bisync'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        $docsFolder = @(Get-SyncFolders -Config $cfg | Where-Object { $_.StateKey -eq 'Docs' })[0]
        $musicFolder = @(Get-SyncFolders -Config $cfg | Where-Object { $_.StateKey -eq 'Music' })[0]
        $docsSession = Get-BisyncSessionName -Local $docsFolder.Local -RemotePath $docsFolder.RemotePath
        $musicSession = Get-BisyncSessionName -Local $musicFolder.Local -RemotePath $musicFolder.RemotePath
        foreach ($f in @("$docsSession.path1.lst", "$docsSession.path2.lst", "$musicSession.path1.lst", "$musicSession.path2.lst")) {
            [IO.File]::WriteAllText((Join-Path $work $f), 'x')
        }
        $script:calls.Clear()

        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now

        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeTrue
        $c = $script:calls.ToArray()
        $c.Count | Should -Be 4
        $c[0][0] | Should -Be 'bisync'
        $c[0][2] | Should -BeExactly 'pikpak:PC-Mirror/D/Docs'
        $c[0] | Should -Not -Contain '--resync'
        $c[1][0] | Should -Be 'purge'
        $c[1][1] | Should -BeExactly 'pikpak:PC-Mirror/D/Docs'
        $c[2][0] | Should -Be 'copyto'
        $c[2][2] | Should -BeExactly 'private:Docs/RCLONE_TEST'
        $c[3][0] | Should -Be 'bisync'
        $c[3][2] | Should -BeExactly 'private:Docs'
        $c[3] | Should -Contain '--resync'
        $new = Get-MirrorConfig -Path $path
        @($new.Pairs | ForEach-Object { $_.Name }) | Should -Be @('Music')
        @($new.PrivatePaths).Count | Should -Be 1
        $new.PrivatePaths[0].Name | Should -BeExactly 'Docs'
        Test-Path -LiteralPath ($path + '.bak') | Should -BeTrue
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Pairs.ContainsKey('Docs') | Should -BeFalse
        $st.Pairs.ContainsKey('private:Docs') | Should -BeTrue
        $st.Pairs['private:Docs']['Seeded'] | Should -BeTrue
        $st.Pairs['Music']['Seeded'] | Should -BeTrue
        $st.PrivateConfirmedHash | Should -Be (Get-PrivatePathsHash -Config $new)
        $st.Notified.ContainsKey('Docs|other') | Should -BeFalse
        $st.Notified['Music|other'] | Should -Be '2026-10-23'
        Test-Path -LiteralPath $oldFilter | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $cfg.StateDir 'filters\Music.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $work "$docsSession.path1.lst") | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $work "$docsSession.path2.lst") | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $work "$musicSession.path1.lst") | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $work "$musicSession.path2.lst") | Should -BeTrue
        @($script:toasts).Count | Should -Be 1
        $script:toasts[0] | Should -BeExactly $r.Message
        $r.Message | Should -Match 'Docs is now an encrypted folder'
        $r.Message | Should -Match ([regex]::Escape('PikPak/PC-Mirror/D/Docs'))
        $r.Message | Should -Not -Match ([regex]::Escape('pikpak:'))
        $log = [IO.File]::ReadAllText((Join-Path $cfg.StateDir ('logs\' + (Get-Date).ToString('yyyy-MM-dd') + '.log')))
        $log | Should -Match 'purge'
        $log | Should -Match ([regex]::Escape('pikpak:PC-Mirror/D/Docs'))
    }

    It 'keeps the old copy when not asked to delete it' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeFalse
        @(Get-Purges).Count | Should -Be 0
        $r.Message | Should -Match ([regex]::Escape('The old copy is still in PikPak at PikPak/PC-Mirror/D/Docs.'))
        $r.Message | Should -Not -Match ([regex]::Escape('pikpak:'))
        (Get-MirrorState -StateDir $raw.StateDir).Pairs.ContainsKey('Docs') | Should -BeFalse
    }

    It 'reports a failed purge without undoing the change' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $script:responder = { param($a) if ($a[0] -eq 'purge') { @{ ExitCode = 1 } } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeFalse
        $r.Message | Should -Match 'could not be deleted'
        @((Get-MirrorConfig -Path $path).PrivatePaths).Count | Should -Be 1
        @(Get-Bisyncs)[-1][2] | Should -BeExactly 'private:Docs'
    }

    It 'counts a missing old copy as nothing to delete' {
        $raw = New-RawConfig -Root $script:root -PrivatePaths @(@{ Name = 'Docs'; Dir = 'Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $script:responder = { param($a) if ($a[0] -eq 'purge') { @{ ExitCode = 3 } } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'plain' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeTrue
        @(Get-Purges)[0][1] | Should -BeExactly 'private:Docs'
        $r.Message | Should -Match 'no old copy'
        $r.Message | Should -Match ([regex]::Escape('under PC-Private, with a scrambled name'))
        $r.Message | Should -Not -Match 'private:Docs'
    }

    It 'says the upload continues when the first sync in the new form hits the transfer limit' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $script:responder = { param($a) if ($a[0] -eq 'bisync' -and $a[2] -eq 'private:Docs') { @{ ExitCode = 7; BudgetHit = $true } } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.Message | Should -Match 'continues at the next syncs'
    }

    It 'makes an encrypted folder inside a synced folder part of it again' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Docs\Secret' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $cfg = Get-MirrorConfig -Path $path
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(-1) | Out-Null
        $script:calls.Clear()
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path (Join-Path $script:docs 'Secret') -To 'plain' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $c = @($script:calls | Where-Object { $_[0] -ne 'copyto' })
        $c[0][2] | Should -BeExactly 'private:Secret'
        $c[1][0] | Should -Be 'purge'
        $c[1][1] | Should -BeExactly 'private:Secret'
        $c[2][0] | Should -Be 'bisync'
        $c[2][2] | Should -BeExactly 'pikpak:PC-Mirror/D/Docs'
        $c[2] | Should -Contain '--resync'   # its filters lost the exclude of Secret
        $new = Get-MirrorConfig -Path $path
        @($new.Pairs).Count | Should -Be 1
        @($new.PrivatePaths | Where-Object { $_ }).Count | Should -Be 0
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Pairs.ContainsKey('private:Secret') | Should -BeFalse
        $st.Pairs['Docs']['Seeded'] | Should -BeTrue
        $r.Message | Should -Match 'part of the synced folder'
    }

    It 'C1: removes the encrypted ID file before the old copy is purged, so the synced folder takes it in again' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Docs\Secret' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $secret = Join-Path $script:docs 'Secret'
        $null = Write-FolderMarker -Folder @{ Kind = 'private'; Name = 'Secret'; Local = $secret; RemotePath = 'private:Secret'; Id = (New-FolderId) } -Now $script:Now
        $marker = Join-Path $secret '.pikpak-encrypted.json'
        $script:markerAtPurge = $null
        $script:responder = { param($a) if ($a[0] -eq 'purge') { $script:markerAtPurge = [IO.File]::Exists($marker) } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $secret -To 'plain' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeTrue
        $script:markerAtPurge | Should -BeFalse
        [IO.File]::Exists($marker) | Should -BeFalse
    }

    It 'C1: when the encrypted ID file cannot be removed, the old copy is not purged and the message says so' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Docs\Secret' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $secret = Join-Path $script:docs 'Secret'
        Mock Remove-FolderMarkerFile { throw 'access denied' }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $secret -To 'plain' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeFalse
        @(Get-Purges).Count | Should -Be 0
        $r.Message | Should -Match ([regex]::Escape('.pikpak-encrypted.json'))
        $r.Message | Should -Match 'access denied'
    }

    It 'C1: a standalone encrypted folder made normal keeps no encrypted ID file problem (the run rewrites it as synced)' {
        $raw = New-RawConfig -Root $script:root -PrivatePaths @(@{ Name = 'Secret'; Dir = 'Secret' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $secret = Join-Path $script:root 'watch\Secret'
        Mock Remove-FolderMarkerFile { throw 'must not be called for a standalone folder' }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $secret -To 'plain' -Now $script:Now
        $r.Changed | Should -BeTrue
        Should -Invoke Remove-FolderMarkerFile -Times 0
    }

    It 'touches only the changed folder when a folder of the other kind has the same name' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' }) -PrivatePaths @(@{ Name = 'Docs'; Dir = 'Private\Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $cfg = Get-MirrorConfig -Path $path
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(-1) | Out-Null
        $s = Get-MirrorState -StateDir $cfg.StateDir
        $s.Notified['private:Docs|other'] = '2026-10-23'
        Save-MirrorState -StateDir $cfg.StateDir -State $s
        $privBefore = $s.Pairs['private:Docs']
        $privFilter = Join-Path $cfg.StateDir 'filters\private\Docs.txt'
        $privFilterBytes = [IO.File]::ReadAllBytes($privFilter)
        $privFolder = @(Get-SyncFolders -Config $cfg | Where-Object { $_.StateKey -eq 'private:Docs' })[0]
        $privSession = Get-BisyncSessionName -Local $privFolder.Local -RemotePath $privFolder.RemotePath
        $work = Join-Path $cfg.StateDir 'bisync'
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $work "$privSession.path1.lst"), 'x')
        $script:calls.Clear()

        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now

        $r.Changed | Should -BeTrue
        @(Get-Purges).Count | Should -Be 1
        @(Get-Purges)[0][1] | Should -BeExactly 'pikpak:PC-Mirror/D/Docs'
        @(Get-Bisyncs | ForEach-Object { $_[2] }) | Should -Be @('pikpak:PC-Mirror/D/Docs', 'private:Docs (2)')
        $new = Get-MirrorConfig -Path $path
        @($new.PrivatePaths | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('Docs', 'Docs (2)')
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Pairs.ContainsKey('Docs') | Should -BeFalse
        $st.Pairs['private:Docs']['LastRun'] | Should -Be $privBefore['LastRun']
        $st.Pairs['private:Docs']['Seeded'] | Should -BeTrue
        $st.Notified['private:Docs|other'] | Should -Be '2026-10-23'
        [IO.File]::ReadAllBytes($privFilter) | Should -Be $privFilterBytes
        Test-Path -LiteralPath (Join-Path $work "$privSession.path1.lst") | Should -BeTrue
        $st.Pairs.ContainsKey('private:Docs (2)') | Should -BeTrue
    }

    It 'starts clean when a folder is changed and changed back' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $cfg = Get-MirrorConfig -Path $path
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(-1) | Out-Null
        (Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now).Changed | Should -BeTrue
        # the new pair gets a fresh remote; keep the test on the same plain remote as before
        Mock New-MirrorPair { @{ Name = 'Docs'; Local = (ConvertTo-MirrorPath $Path); Remote = 'D/Docs'; Priority = 3 } }
        $script:calls.Clear()
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'plain' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $b = @(Get-Bisyncs)
        $b[0][2] | Should -BeExactly 'private:Docs'
        $b[0] | Should -Not -Contain '--resync'
        @(Get-Purges)[0][1] | Should -BeExactly 'private:Docs'
        $b[-1][2] | Should -BeExactly 'pikpak:PC-Mirror/D/Docs'
        $b[-1] | Should -Contain '--resync'
        $st = Get-MirrorState -StateDir $cfg.StateDir
        $st.Pairs.ContainsKey('private:Docs') | Should -BeFalse
    }

    It 'forgets leftover state of the new form''s key before its first sync' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $cfg = Get-MirrorConfig -Path $path
        $future = New-SyncFolder -Config $cfg -Private @{ Path = $script:docs; Name = 'Docs' }
        $hash = (Update-FolderFilterFile -Config $cfg -Folder $future).Hash
        $s = Get-MirrorState -StateDir $raw.StateDir
        # an encrypted folder of this name was removed earlier, its state stayed behind (same filters, same mapping)
        $s.Pairs['private:Docs'] = @{ Seeded = $true; FilterHash = $hash; Identity = (Get-FolderIdentity -Folder $future); LastExit = 0; LastRun = $null }
        Save-MirrorState -StateDir $raw.StateDir -State $s
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        @(Get-Bisyncs)[-1] | Should -Contain '--resync'
    }

    It 'leaves a valid config and state if it stops right after the switch' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $cfg = Get-MirrorConfig -Path $path
        Invoke-MirrorRun -Config $cfg -Now $script:Now.AddDays(-1) | Out-Null
        # everything after the switch breaks: the delete and the first sync in the new form
        $script:responder = { param($a) if ($a[0] -eq 'purge' -or ($a -join ' ') -match 'private:Docs') { throw 'interrupted' } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeFalse
        @($script:toasts | Where-Object { $_ -eq $r.Message }).Count | Should -Be 1
        # the lock was released
        $h = Enter-MirrorLock -StateDir $cfg.StateDir
        $h | Should -Not -BeNullOrEmpty
        Exit-MirrorLock -Handle $h
        $new = Get-MirrorConfig -Path $path
        @(Test-MirrorConfig -Config $new) | Should -BeNullOrEmpty
        $script:responder = $null
        $script:calls.Clear()
        $run = Invoke-MirrorRun -Config $new -Now $script:Now.AddHours(1)
        @($run.Errors) | Should -BeNullOrEmpty
        $b = @(Get-Bisyncs)
        $b.Count | Should -Be 1
        $b[0][2] | Should -BeExactly 'private:Docs'
        $b[0] | Should -Contain '--resync'
        @($script:calls | Where-Object { $_[1] -like 'pikpak:PC-Mirror*' }).Count | Should -Be 0
    }

    It 'tells the truth when clearing the old state fails after the switch' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        Mock Clear-FolderSyncState { throw 'disk full' }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeFalse
        $r.Message | Should -Match '^Docs is now an encrypted folder\.'
        $r.Message | Should -Match ([regex]::Escape('The old copy in PikPak at PikPak/PC-Mirror/D/Docs was not deleted because the old sync state could not be cleared'))
        $r.Message | Should -Match 'disk full'
        @(Get-Purges).Count | Should -Be 0   # never delete the old copy while its old state may linger
        # F1: the first sync in the new form is not run on top of state that was not cleared
        @(Get-Bisyncs | Where-Object { $_[2] -ceq 'private:Docs' }).Count | Should -Be 0
        $r.Message | Should -Match 'first encrypted sync did not run'
        $r.Message | Should -Match 'it runs at the next sync'
        @($script:toasts).Count | Should -Be 1
        $script:toasts[0] | Should -BeExactly $r.Message
        @((Get-MirrorConfig -Path $path).PrivatePaths).Count | Should -Be 1
    }

    It 'tells the truth when the delete cannot be started' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $script:responder = { param($a) if ($a[0] -eq 'purge') { throw 'rclone missing' } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeFalse
        $r.Message | Should -Match '^Docs is now an encrypted folder\.'
        $r.Message | Should -Match ([regex]::Escape('The old copy in PikPak at PikPak/PC-Mirror/D/Docs may not have been deleted'))
        $r.Message | Should -Match 'rclone missing'
        $r.Message | Should -Match 'It was synced in its new form'
        @($script:toasts).Count | Should -Be 1
    }

    It 'tells the truth when the first sync in the new form throws' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        Mock Invoke-MirrorRun { throw 'state.json is locked' } -ParameterFilter { @($OnlyFolders) -contains 'private:Docs' }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeTrue
        $r.OldCopyDeleted | Should -BeTrue
        $r.Message | Should -Match '^Docs is now an encrypted folder\.'
        $r.Message | Should -Match ([regex]::Escape("The old copy in PikPak at PikPak/PC-Mirror/D/Docs was deleted"))
        $r.Message | Should -Match 'The first encrypted sync did not run \(state\.json is locked\); it runs at the next sync\.'
        @($script:toasts).Count | Should -Be 1
    }

    It 'changes nothing when the last sync hits the delete safety stop' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $before = [IO.File]::ReadAllBytes($path)
        $script:responder = { param($a) if ($a[0] -eq 'bisync') { @{ ExitCode = 7; TooManyDeletes = $true } } }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'would be deleted'
        @(Get-Purges).Count | Should -Be 0
        [IO.File]::ReadAllBytes($path) | Should -Be $before
    }

    It 'changes nothing while this month''s transfer limit is reached' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $s = Get-MirrorState -StateDir $raw.StateDir
        $s.MonthStopped = '2026-10'
        Save-MirrorState -StateDir $raw.StateDir -State $s
        $before = [IO.File]::ReadAllBytes($path)
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'transfer limit'
        $script:calls.Count | Should -Be 0
        [IO.File]::ReadAllBytes($path) | Should -Be $before
    }

    It 'changes a folder with an odd old-copy path when the old copy is kept, and refuses when it is to be deleted' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/ Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $before = [IO.File]::ReadAllBytes($path)
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'cannot be deleted safely'
        $script:calls.Count | Should -Be 0
        [IO.File]::ReadAllBytes($path) | Should -Be $before
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -Now $script:Now
        $r.Changed | Should -BeTrue
        @(Get-Purges).Count | Should -Be 0
        $r.Message | Should -Match ([regex]::Escape('The old copy is still in PikPak at PikPak/PC-Mirror/D/ Docs.'))
        $r.Message | Should -Not -Match 'delete'
    }

    It 'changes nothing when the settings file changed while the last sync ran' {
        $raw = New-RawConfig -Root $script:root -Pairs @(@{ Name = 'Docs'; Dir = 'Docs'; Remote = 'D/Docs' })
        $path = New-ConfigFile -Root $script:root -Raw $raw
        $script:cfgPath = $path
        $script:responder = {
            param($a)
            if ($a[0] -eq 'bisync') {
                $x = Get-RawMirrorConfig -Path $script:cfgPath
                $x['BwLimit'] = '1M'
                $null = Save-MirrorConfig -Path $script:cfgPath -Config $x
            }
        }
        $r = Invoke-MirrorFolderConversion -ConfigPath $path -Path $script:docs -To 'encrypted' -DeleteOldCopy -Now $script:Now
        $r.Changed | Should -BeFalse
        $r.Message | Should -Match 'settings were changed'
        @(Get-Purges).Count | Should -Be 0
        (Get-RawMirrorConfig -Path $path).BwLimit | Should -Be '1M'
        @((Get-MirrorConfig -Path $path).Pairs).Count | Should -Be 1
    }
}

Describe 'Convert-Folder.ps1' {
    It 'is a thin entry point with -ConfigPath -Path -To -DeleteOldCopy' {
        $file = Join-Path $PSScriptRoot '..\scripts\Convert-Folder.ps1'
        $tokens = $null; $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $file).ProviderPath, [ref]$tokens, [ref]$errs)
        @($errs) | Should -BeNullOrEmpty
        $names = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($n in 'ConfigPath', 'Path', 'To', 'DeleteOldCopy') { $names | Should -Contain $n }
        $text = [IO.File]::ReadAllText((Resolve-Path $file).ProviderPath)
        $text | Should -Match 'Invoke-MirrorFolderConversion'
        $text | Should -Match 'Get-Date'
    }
}
