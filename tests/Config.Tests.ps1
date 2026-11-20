BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    function New-TempConfig {
        param([string]$Body)
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("pmcfg-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $path = Join-Path $dir 'test.psd1'
        Set-Content -LiteralPath $path -Value $Body -Encoding UTF8
        $path
    }

    function New-ValidConfig {
        # A complete, valid config; tests override only the keys they exercise.
        param([hashtable]$Override = @{})
        $c = @{
            Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror'; HoldingRoot = 'PC-Holding'
            LocalHolding = 'D:\.pikpak-holding'; StateDir = 'C:\State\PikPakMirror'
            HoldingDays = 30; MaxDeletePercent = 10; DailyBudgetGB = 8; MonthlyBudgetGB = 250; QuotaWarnPercent = 90
            StaleRunDays = 3; LogKeepDays = 60; BwLimit = 'off'
            PrivatePaths = @(); Pairs = @()
        }
        foreach ($k in $Override.Keys) { $c[$k] = $Override[$k] }
        $c
    }
}

Describe 'ConvertTo-MirrorPath' {
    It 'normalises <In> to <Out>' -TestCases @(
        @{ In = 'D:/Music/S'; Out = 'D:\Music\S' }
        @{ In = ' D:\Music\S'; Out = 'D:\Music\S' }
        @{ In = 'D:\Music\S '; Out = 'D:\Music\S' }
        @{ In = 'D:\Music\x\..\S'; Out = 'D:\Music\S' }
        @{ In = 'D:\Music\\S\'; Out = 'D:\Music\S' }
        @{ In = 'D:\Music\S. \'; Out = 'D:\Music\S' }
        @{ In = 'D:\Mu sic \S..'; Out = 'D:\Mu sic\S' }
        @{ In = 'd:\music\s'; Out = 'd:\music\s' }
        @{ In = 'D:/'; Out = 'D:\' }
        @{ In = 'D:'; Out = 'D:\' }
        @{ In = 'D:\\'; Out = 'D:\' }
        @{ In = '%NOPE_PM_TEST%\x'; Out = '%NOPE_PM_TEST%\x' }
    ) {
        param($In, $Out)
        ConvertTo-MirrorPath $In | Should -BeExactly $Out
    }
}

Describe 'Private path spellings (C2)' {
    BeforeAll {
        $script:globalRules = Join-Path $TestDrive 'filters.txt'
        [IO.File]::WriteAllLines($script:globalRules, [string[]]@('- Thumbs.db'), (New-Object Text.UTF8Encoding $false))
    }

    It 'pair <Pair> / private <Priv> excludes /S/**' -TestCases @(
        @{ Pair = 'D:\Music'; Priv = 'D:/Music/S' }
        @{ Pair = 'D:\Music'; Priv = ' D:\Music\S' }
        @{ Pair = 'D:\Music'; Priv = 'D:\Music\S ' }
        @{ Pair = 'D:\Music'; Priv = 'D:\Music\x\..\S' }
        @{ Pair = 'D:\Music'; Priv = 'D:\Music\\S' }
        @{ Pair = 'D:\Music'; Priv = 'D:\Music\S.' }
        @{ Pair = 'D:\Music'; Priv = 'd:\music\s' }
        @{ Pair = 'D:/Music'; Priv = 'D:\Music\S' }
        @{ Pair = ' D:\Music\ '; Priv = 'D:\Music\S\' }
    ) {
        param($Pair, $Priv)
        $p = New-TempConfig ("@{{ PrivatePaths = @(@{{ Name = 'S'; Path = '{0}' }}); Pairs = @(@{{ Name = 'Music'; Local = '{1}'; Remote = 'D/Music'; Priority = 2 }}) }}" -f $Priv, $Pair)
        $loaded = Get-MirrorConfig -Path $p
        $cfg = New-ValidConfig @{ PrivatePaths = $loaded.PrivatePaths; Pairs = $loaded.Pairs }
        @(Test-MirrorConfig -Config $cfg) | Should -BeNullOrEmpty
        $rules = @(New-PairFilterRules -Config $cfg -Pair $cfg.Pairs[0] -GlobalRulesPath $script:globalRules)
        $rules.Count | Should -Be 2
        $rules | Should -Contain '- /S/**'
    }

    It 'bisync matches filters case-insensitively' {
        $vc = New-ValidConfig
        $a = @(New-BisyncArgs -Config $vc -Folder (New-SyncFolder -Config $vc -Pair @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 2 }) `
                -FiltersFile 'f' -Date ([datetime]'2026-10-24') -BudgetBytes 1 -LogFile 'l')
        $a | Should -Contain '--ignore-case'
    }

    It 'rejects <What> that is not an absolute drive path or has an undefined variable: <Value>' -TestCases @(
        @{ What = 'pair Local'; Value = '%NOPE_PM_TEST%\x' }
        @{ What = 'pair Local'; Value = 'D:\%NOPE_PM_TEST%\x' }
        @{ What = 'pair Local'; Value = 'Music' }
        @{ What = 'pair Local'; Value = '\\server\share\Music' }
        @{ What = 'private Path'; Value = '%NOPE_PM_TEST%\x' }
        @{ What = 'private Path'; Value = 'Secret' }
    ) {
        param($What, $Value)
        $kind = 'Pairs'; $body = "Pairs = @(@{{ Name = 'X'; Local = '{0}'; Remote = 'D/X'; Priority = 1 }})" -f $Value
        if ($What -eq 'private Path') { $kind = 'PrivatePaths'; $body = "PrivatePaths = @(@{{ Name = 'X'; Path = '{0}' }})" -f $Value }
        $loaded = Get-MirrorConfig -Path (New-TempConfig ('@{ ' + $body + ' }'))
        $errs = @(Test-MirrorConfig -Config (New-ValidConfig @{ $kind = $loaded[$kind] }))
        $errs.Count | Should -BeGreaterThan 0
        ($errs -join "`n") | Should -BeLike '*absolute*'
    }
}

Describe 'Get-MirrorConfig' {
    It 'expands env vars and strips trailing backslash' {
        $p = New-TempConfig @'
@{
  StateDir='%LOCALAPPDATA%\PikPakMirror'
  Pairs=@( @{ Name='Music'; Local='D:\Music\'; Remote='D/Music'; Priority=2 } )
}
'@
        $c = Get-MirrorConfig -Path $p
        $c.StateDir | Should -Be "$env:LOCALAPPDATA\PikPakMirror"
        $c.Pairs[0].Local | Should -Be 'D:\Music'
    }

    It 'resolves GlobalFiltersFile to an absolute path next to the config file' {
        $p = New-TempConfig "@{ GlobalFiltersFile='filters.txt' }"
        $c = Get-MirrorConfig -Path $p
        $c.GlobalFiltersFile | Should -Be (Join-Path (Split-Path $p -Parent) 'filters.txt')
    }

    It 'loads the sample config and it validates clean' {
        $real = Join-Path $PSScriptRoot '..\config\mirror.config.sample.psd1'
        $c = Get-MirrorConfig -Path $real
        @(Test-MirrorConfig -Config $c).Count | Should -Be 0
        Test-Path -LiteralPath $c.GlobalFiltersFile | Should -BeTrue
    }

    It 'J3: the sample config keeps a 20 GB margin under the ~250 GB app limit' {
        $c = Get-MirrorConfig -Path (Join-Path $PSScriptRoot '..\config\mirror.config.sample.psd1')
        $c.MonthlyBudgetGB | Should -BeLessOrEqual 230
    }
}

Describe 'Test-MirrorConfig' {
    It 'flags pair whose local is inside a private path' {
        $c = New-ValidConfig @{
            PrivatePaths = @( @{ Path = 'D:\Secret'; Name = 'secret' } )
            Pairs = @( @{ Name = 'Pics'; Local = 'D:\Secret\Pics'; Remote = 'D/Pics'; Priority = 1 } )
        }
        $errs = @(Test-MirrorConfig -Config $c)
        $errs.Count | Should -Be 1
        $errs[0] | Should -BeLike '*D:\Secret\Pics*'
    }

    It 'flags pair that is itself private' {
        $c = New-ValidConfig @{
            PrivatePaths = @( @{ Path = 'D:\New folder (3)'; Name = 'nf3' } )
            Pairs = @( @{ Name = 'New folder (3)'; Local = 'D:\New folder (3)'; Remote = 'D/New folder (3)'; Priority = 4 } )
        }
        $errs = @(Test-MirrorConfig -Config $c)
        $errs.Count | Should -Be 1
        $errs[0] | Should -BeLike "*is itself a private path: delete this folder's line from Pairs (keep it in PrivatePaths)*"
        $errs[0] | Should -Not -BeLike '*remove*private path entry*'
    }

    It 'allows private path nested under a pair' {
        $c = New-ValidConfig @{
            PrivatePaths = @( @{ Path = 'D:\New folder\Private'; Name = 'priv' } )
            Pairs = @( @{ Name = 'New folder'; Local = 'D:\New folder'; Remote = 'D/New folder'; Priority = 4 } )
        }
        @(Test-MirrorConfig -Config $c).Count | Should -Be 0
    }

    It 'does not treat a sibling with a shared name prefix as inside' {
        $c = New-ValidConfig @{
            PrivatePaths = @( @{ Path = 'D:\Secret'; Name = 'secret' } )
            Pairs = @( @{ Name = 'Secrets'; Local = 'D:\Secrets'; Remote = 'D/Secrets'; Priority = 1 } )
        }
        @(Test-MirrorConfig -Config $c).Count | Should -Be 0
    }

    It "flags duplicate pair names and private Name '_holding'" {
        $c = New-ValidConfig @{
            PrivatePaths = @( @{ Path = 'D:\X'; Name = '_holding' } )
            Pairs = @(
                @{ Name = 'Dup'; Local = 'D:\A'; Remote = 'D/A'; Priority = 1 }
                @{ Name = 'Dup'; Local = 'D:\B'; Remote = 'D/B'; Priority = 1 }
            )
        }
        @(Test-MirrorConfig -Config $c).Count | Should -Be 2
    }
}

Describe 'Test-MirrorConfig hardening (I2, I3, M9)' {
    BeforeAll {
        $script:pairsOk = @(
            @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 2 }
            @{ Name = 'Film'; Local = 'D:\Film'; Remote = 'D/Film'; Priority = 4 }
        )
        $script:privOk = @(@{ Name = 'Secret'; Path = 'D:\Music\Secret' })
        function script:Get-Errors {
            param([hashtable]$Override)
            $base = @{ Pairs = $script:pairsOk; PrivatePaths = $script:privOk }
            foreach ($k in $Override.Keys) { $base[$k] = $Override[$k] }
            $c = New-ValidConfig $base
            foreach ($k in @($Override.Keys)) { if ($null -eq $Override[$k] -and $k -notin @('Pairs', 'PrivatePaths')) { $c.Remove($k) } }
            @(Test-MirrorConfig -Config $c)
        }
    }

    It 'rejects SyncTime 24:00 and 8pm' {
        @(Get-Errors @{ SyncTime = '24:00' }) -join '|' | Should -Match 'SyncTime'
        @(Get-Errors @{ SyncTime = '8pm' }) -join '|' | Should -Match 'SyncTime'
    }

    It 'accepts SyncTime 07:05 and no SyncTime at all' {
        Get-Errors @{ SyncTime = '07:05'; SyncAtLogon = $false } | Should -BeNullOrEmpty
        Get-Errors @{} | Should -BeNullOrEmpty
    }

    It 'rejects SyncAtLogon = "yes"' {
        @(Get-Errors @{ SyncAtLogon = 'yes' }) -join '|' | Should -Match 'SyncAtLogon'
    }

    It 'defaults to 60 minutes when the key is missing' {
        Get-SyncIntervalMinutes -Config @{} | Should -Be 60
        Get-SyncIntervalMinutes -Config @{ SyncIntervalMinutes = 180 } | Should -Be 180
        Get-SyncIntervalMinutes -Config @{ SyncIntervalMinutes = 0 } | Should -Be 0
    }

    It 'rejects an interval that is not offered' {
        $e = @(Get-Errors @{ SyncIntervalMinutes = 45 })
        $e.Count | Should -Be 1
        $e[0] | Should -Match 'SyncIntervalMinutes'
    }

    It 'accepts 0, 15, 30, 60, 180 and 360 and no key at all' {
        foreach ($n in 0, 15, 30, 60, 180, 360) {
            Get-Errors @{ SyncIntervalMinutes = $n } | Should -BeNullOrEmpty
        }
        Get-Errors @{} | Should -BeNullOrEmpty
    }

    It 'the base config used by these tests is valid' {
        Get-Errors @{} | Should -BeNullOrEmpty
    }

    It 'I2: rejects a private path that is a file' {
        $f = Join-Path $TestDrive 'notafolder.txt'
        [IO.File]::WriteAllText($f, 'x')
        $errs = @(Get-Errors @{ PrivatePaths = @(@{ Name = 'F'; Path = $f }) })
        $errs.Count | Should -Be 1
        $errs[0] | Should -BeLike '*must be a folder*'
        # a missing private path is fine (Invoke-MirrorRun skips it with a toast)
        Get-Errors @{ PrivatePaths = @(@{ Name = 'F'; Path = (Join-Path $TestDrive 'missing') }) } | Should -BeNullOrEmpty
    }

    It 'I3: required setting <Key> missing (<Mode>)' -TestCases @(
        foreach ($k in 'Remote', 'PrivateRemote', 'MirrorRoot', 'HoldingRoot', 'LocalHolding', 'StateDir') {
            @{ Key = $k; Mode = 'absent' }
            @{ Key = $k; Mode = 'blank' }
        }
    ) {
        param($Key, $Mode)
        $v = $null
        if ($Mode -eq 'blank') { $v = '  ' }
        $errs = Get-Errors @{ $Key = $v }
        ($errs -join "`n") | Should -BeLike "*Required setting '$Key'*"
    }

    It 'I3: remote roots must be distinct and not nested: <Desc>' -TestCases @(
        @{ Desc = 'MirrorRoot=PC-Holding'; Over = @{ MirrorRoot = 'PC-Holding' } }
        @{ Desc = 'HoldingRoot=pc-mirror\'; Over = @{ HoldingRoot = 'pc-mirror\' } }
        @{ Desc = 'MirrorRoot=PC-Private'; Over = @{ MirrorRoot = 'PC-Private' } }
        @{ Desc = 'MirrorRoot=/'; Over = @{ MirrorRoot = '/' } }
    ) {
        param($Desc, $Over)
        $errs = Get-Errors $Over
        $errs.Count | Should -BeGreaterThan 0
        ($errs -join "`n") | Should -BeLike '*remote root*'
    }

    It 'I3: LocalHolding <Value> is rejected' -TestCases @(
        @{ Value = 'holding' }
        @{ Value = 'D:\' }
        @{ Value = 'D:\Music' }
        @{ Value = 'd:\music\.hold' }
        @{ Value = 'D:\Music\Secret\h' }
        @{ Value = 'D:\Film\..\Film' }
    ) {
        param($Value)
        (Get-Errors @{ LocalHolding = $Value } -join "`n") | Should -BeLike '*LocalHolding*'
    }

    It 'I3: LocalHolding that contains a pair or a private path is rejected' {
        $errs = Get-Errors @{ LocalHolding = 'D:\'; Pairs = @(@{ Name = 'Deep'; Local = 'D:\H\Deep'; Remote = 'D/Deep'; Priority = 1 }); PrivatePaths = @() }
        ($errs -join "`n") | Should -BeLike '*LocalHolding*'
        $errs = Get-Errors @{ LocalHolding = 'D:\H'; Pairs = @(@{ Name = 'Deep'; Local = 'D:\H\Deep'; Remote = 'D/Deep'; Priority = 1 }); PrivatePaths = @() }
        ($errs -join "`n") | Should -BeLike "*LocalHolding*overlaps pair 'Deep'*"
        $errs = Get-Errors @{ LocalHolding = 'D:\H'; PrivatePaths = @(@{ Name = 'P'; Path = 'D:\H\P' }) }
        ($errs -join "`n") | Should -BeLike "*LocalHolding*overlaps private path*"
    }

    It 'I3: pair with empty <Field> is rejected' -TestCases @(
        @{ Field = 'Name' }, @{ Field = 'Local' }, @{ Field = 'Remote' }
    ) {
        param($Field)
        $p = @{ Name = 'X'; Local = 'D:\X'; Remote = 'D/X'; Priority = 1 }
        $p[$Field] = ' '
        (Get-Errors @{ Pairs = @($p) } -join "`n") | Should -BeLike "*empty $Field*"
    }

    It 'I3: pair remote <Remote> is rejected' -TestCases @(
        @{ Remote = 'D/../X' }, @{ Remote = '/D/X' }, @{ Remote = 'D\X' }, @{ Remote = '..' }
    ) {
        param($Remote)
        (Get-Errors @{ Pairs = @(@{ Name = 'X'; Local = 'D:\X'; Remote = $Remote; Priority = 1 }) } -join "`n") | Should -BeLike "*remote*"
    }

    It 'I3: pair remotes <A> and <B> overlap' -TestCases @(
        @{ A = 'D/Music'; B = 'D/Music' }
        @{ A = 'D/Music'; B = ' d/music/ ' }
        @{ A = 'D'; B = 'D/Music' }
        @{ A = 'D/Music/Sub'; B = 'D/Music' }
    ) {
        param($A, $B)
        $errs = Get-Errors @{ Pairs = @(
                @{ Name = 'One'; Local = 'D:\One'; Remote = $A; Priority = 1 }
                @{ Name = 'Two'; Local = 'D:\Two'; Remote = $B; Priority = 1 }); PrivatePaths = @() }
        ($errs -join "`n") | Should -BeLike '*remote*overlap*'
    }

    It 'I3: remotes that merely share a name prefix are fine' {
        Get-Errors @{ Pairs = @(
                @{ Name = 'One'; Local = 'D:\One'; Remote = 'D/New folder'; Priority = 1 }
                @{ Name = 'Two'; Local = 'D:\Two'; Remote = 'D/New folder (2)'; Priority = 1 }); PrivatePaths = @() } | Should -BeNullOrEmpty
    }

    It 'I3: pair locals <A> and <B> overlap' -TestCases @(
        @{ A = 'D:\Music'; B = 'D:\Music\Sub' }
        @{ A = 'D:\Music'; B = 'd:\music' }
        @{ A = 'D:\Music\Sub'; B = 'D:\Music' }
    ) {
        param($A, $B)
        $errs = Get-Errors @{ Pairs = @(
                @{ Name = 'One'; Local = $A; Remote = 'D/One'; Priority = 1 }
                @{ Name = 'Two'; Local = $B; Remote = 'D/Two'; Priority = 1 }); PrivatePaths = @() }
        ($errs -join "`n") | Should -BeLike '*local*overlap*'
    }

    It 'I3: duplicate private <What>' -TestCases @(
        @{ What = 'name'; P = @(@{ Name = 'S'; Path = 'D:\Music\A' }, @{ Name = 's'; Path = 'D:\Music\B' }) }
        @{ What = 'path'; P = @(@{ Name = 'A'; Path = 'D:\Music\A' }, @{ Name = 'B'; Path = 'd:\music\a' }) }
    ) {
        param($What, $P)
        (Get-Errors @{ PrivatePaths = $P } -join "`n") | Should -BeLike "*Duplicate private $What*"
    }

    It 'I3: nested private paths are rejected' {
        (Get-Errors @{ PrivatePaths = @(@{ Name = 'A'; Path = 'D:\Music\A' }, @{ Name = 'B'; Path = 'D:\Music\A\B' }) } -join "`n") |
            Should -BeLike '*nested*'
    }

    It 'I3: an empty private name is rejected' {
        (Get-Errors @{ PrivatePaths = @(@{ Name = ' '; Path = 'D:\Music\A' }) } -join "`n") | Should -BeLike '*empty Name*'
    }

    It 'M9: <Kind> name <Name> with a forbidden character is rejected' -TestCases @(
        foreach ($ch in '\', '/', ':', '*', '?', '"', '<', '>', '|') {
            @{ Kind = 'pair'; Name = ('A{0}B' -f $ch) }
            @{ Kind = 'private'; Name = ('S{0}T' -f $ch) }
        }
    ) {
        param($Kind, $Name)
        if ($Kind -eq 'pair') { $o = @{ Pairs = @(@{ Name = $Name; Local = 'D:\X'; Remote = 'D/X'; Priority = 1 }) } }
        else { $o = @{ PrivatePaths = @(@{ Name = $Name; Path = 'D:\Music\X' }) } }
        (Get-Errors $o -join "`n") | Should -BeLike '*must not contain*'
    }

    It "R18: pair name '<Name>' is reserved" -TestCases @(
        @{ Name = '_private' }
        @{ Name = '_Private ' }
    ) {
        param($Name)
        $errs = Get-Errors @{ Pairs = @(@{ Name = $Name; Local = 'D:\X'; Remote = 'D/X'; Priority = 1 }) }
        @($errs).Count | Should -Be 1
        ($errs -join "`n") | Should -BeLike "*reserved name '_private'*"
    }

    It "F6: pair name 'global' is reserved (notification keys starting with global| are global checks)" -TestCases @(
        @{ Name = 'global' }
        @{ Name = ' Global ' }
    ) {
        param($Name)
        $errs = Get-Errors @{ Pairs = @(@{ Name = $Name; Local = 'D:\X'; Remote = 'D/X'; Priority = 1 }) }
        @($errs).Count | Should -Be 1
        ($errs -join "`n") | Should -BeLike "*reserved name 'global'*"
        Get-Errors @{ Pairs = @(@{ Name = 'globals'; Local = 'D:\X'; Remote = 'D/X'; Priority = 1 }) } | Should -BeNullOrEmpty
    }

    It "R18: '_archive' is no longer reserved, and a name that merely contains '_private' is fine" {
        Get-Errors @{ Pairs = @(@{ Name = '_archive'; Local = 'D:\X'; Remote = 'D/X'; Priority = 1 }) } | Should -BeNullOrEmpty
        Get-Errors @{ Pairs = @(@{ Name = 'my_private'; Local = 'D:\X'; Remote = 'D/X'; Priority = 1 }) } | Should -BeNullOrEmpty
    }

    It 'accepts a config without ArchiveRoot, CacheDir, WatchRoots and IgnoredFolders' {
        $cfg = New-ValidConfig
        foreach ($k in 'ArchiveRoot', 'CacheDir', 'WatchRoots', 'IgnoredFolders') { $cfg.Remove($k) }
        @(Test-MirrorConfig -Config $cfg).Count | Should -Be 0
    }

    It 'still accepts a config that has the removed keys' {
        $cfg = New-ValidConfig
        $cfg.ArchiveRoot = 'Archive'; $cfg.CacheDir = 'D:\.pikpak-cache'; $cfg.WatchRoots = @('D:\'); $cfg.IgnoredFolders = @('Game')
        @(Test-MirrorConfig -Config $cfg).Count | Should -Be 0
    }

    It 'I3: <Key> = <Value> is not a positive integer' -TestCases @(
        foreach ($k in 'DailyBudgetGB', 'MonthlyBudgetGB', 'HoldingDays') {
            @{ Key = $k; Value = 0 }
            @{ Key = $k; Value = -3 }
            @{ Key = $k; Value = 1.5 }
            @{ Key = $k; Value = '8' }
            @{ Key = $k; Value = $null }
        }
    ) {
        param($Key, $Value)
        (Get-Errors @{ $Key = $Value } -join "`n") | Should -BeLike "*$Key*positive whole number*"
    }
}

Describe 'Daily budget setting' {
    It 'accepts DailyBudgetGB without RunBudgetGB, and RunBudgetGB without DailyBudgetGB' {
        $a = New-ValidConfig; $a.Remove('RunBudgetGB'); $a['DailyBudgetGB'] = 2
        @(Test-MirrorConfig -Config $a).Count | Should -Be 0
        $b = New-ValidConfig; $b.Remove('DailyBudgetGB'); $b['RunBudgetGB'] = 2
        @(Test-MirrorConfig -Config $b).Count | Should -Be 0
    }
    It 'rejects a config with neither' {
        $c = New-ValidConfig; $c.Remove('DailyBudgetGB'); $c.Remove('RunBudgetGB')
        $e = @(Test-MirrorConfig -Config $c)
        $e.Count | Should -Be 1
        $e[0] | Should -BeLike '*DailyBudgetGB*positive whole number*'
    }
    It 'checks the old RunBudgetGB when it is the only key' {
        $c = New-ValidConfig; $c.Remove('DailyBudgetGB'); $c['RunBudgetGB'] = 0
        (@(Test-MirrorConfig -Config $c) -join "`n") | Should -BeLike '*RunBudgetGB*positive whole number*'
    }
    It 'ignores an invalid old RunBudgetGB when DailyBudgetGB is set' {
        $c = New-ValidConfig; $c['RunBudgetGB'] = 0
        @(Test-MirrorConfig -Config $c).Count | Should -Be 0
    }
}

Describe 'Get-PrivatePathsHash' {
    It 'ignores order and case' {
        $a = @{ PrivatePaths = @( @{ Path = 'D:\A'; Name = 'a' }, @{ Path = 'd:\b'; Name = 'b' } ) }
        $b = @{ PrivatePaths = @( @{ Path = 'D:\B'; Name = 'b' }, @{ Path = 'D:\a'; Name = 'a' } ) }
        Get-PrivatePathsHash -Config $a | Should -Be (Get-PrivatePathsHash -Config $b)
    }

    It 'differs when the set of paths differs' {
        $a = @{ PrivatePaths = @( @{ Path = 'D:\A'; Name = 'a' } ) }
        $b = @{ PrivatePaths = @( @{ Path = 'D:\B'; Name = 'a' } ) }
        Get-PrivatePathsHash -Config $a | Should -Not -Be (Get-PrivatePathsHash -Config $b)
    }
}

Describe 'Test-MirrorConfig folder Id and Paused' {
    BeforeAll {
        $script:gid = '0a1b2c3d-0000-4000-8000-0123456789ab'
        function script:Get-IdErrors {
            param($Pairs, $Privs)
            @(Test-MirrorConfig -Config (New-ValidConfig @{ Pairs = $Pairs; PrivatePaths = $Privs }))
        }
    }

    It 'rejects an invalid Id on a pair and on a private path' {
        $e = Get-IdErrors @(@{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Id = 'nope' }) @(@{ Name = 'Secret'; Path = 'D:\Secret'; Id = 'xyz' })
        $e -join '|' | Should -Match "Pair 'Music' has an invalid Id 'nope'\."
        $e -join '|' | Should -Match "Private path '$([regex]::Escape('D:'+[char]92+'Secret'))' has an invalid Id 'xyz'\."
    }

    It 'rejects a non-bool Paused' {
        $e = Get-IdErrors @(@{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Paused = 'yes' }) @(@{ Name = 'Secret'; Path = 'D:\Secret'; Paused = 1 })
        $e -join '|' | Should -Match "Pair 'Music' Paused must be \`$true or \`$false\."
        $e -join '|' | Should -Match "Private path '$([regex]::Escape('D:'+[char]92+'Secret'))' Paused must be \`$true or \`$false\."
    }

    It 'accepts valid Id and bool Paused, and duplicate Ids are not an error' {
        $e = Get-IdErrors @(
            @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Id = $script:gid; Paused = $true }
            @{ Name = 'Film'; Local = 'D:\Film'; Remote = 'D/Film'; Id = $script:gid; Paused = $false }
        ) @()
        $e.Count | Should -Be 0
    }
}
