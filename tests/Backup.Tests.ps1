BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    function New-TestConfig {
        @{
            Remote = 'pikpak'; MirrorRoot = 'PC-Mirror'; LocalHolding = 'D:\PikPakHolding'; StateDir = 'D:\PikPakState'
            DailyBudgetGB = 30; SyncIntervalMinutes = 60
            PrivatePaths = @(
                @{ Path = 'D:\Documents\Private'; Name = 'Private'; Id = 'enc-1'; Paused = $false }
            )
            Pairs = @(
                @{ Name = 'Documents'; Local = 'D:\Documents'; Remote = 'D/Documents'; Priority = 1; Id = 'id-docs' }
                @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 3; Id = 'id-music' }
                @{ Name = 'Mine'; Local = '%USERPROFILE%\Mine'; Remote = 'C-Users/Mine'; Priority = 3; Id = 'id-mine' }
            )
        }
    }
    $script:Now = [datetime]::new(2026, 11, 21, 10, 0, 0, [DateTimeKind]::Utc)
}

Describe 'ConvertTo-BackupDocuments' {
    It 'leaves PrivatePaths out of the readable backup and flags pairs that hold encrypted folders' {
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters '- *.tmp' -Now $script:Now -PcName 'KEN-PC' -AppVersion '1.2.3'
        $plain = $docs.Plain | ConvertFrom-Json
        $plain.app | Should -Be 'pikpak-mirror'
        $plain.kind | Should -Be 'folder-list-backup'
        $plain.version | Should -Be 1
        $plain.pcName | Should -Be 'KEN-PC'
        $plain.appVersion | Should -Be '1.2.3'
        $plain.globalFilters | Should -Be '- *.tmp'
        $plain.config.PSObject.Properties.Name | Should -Not -Contain 'PrivatePaths'
        $docs.Plain | Should -Not -Match 'Private'
        $docs.Plain | Should -Not -Match 'enc-1'
        ($plain.config.Pairs | Where-Object Name -eq 'Documents').holdsEncrypted | Should -BeTrue
        ($plain.config.Pairs | Where-Object Name -eq 'Music').PSObject.Properties.Name | Should -Not -Contain 'holdsEncrypted'

        $enc = $docs.Encrypted | ConvertFrom-Json
        $enc.kind | Should -Be 'encrypted-folder-list'
        $enc.app | Should -Be 'pikpak-mirror'
        @($enc.privatePaths).Count | Should -Be 1
        $enc.privatePaths[0].Path | Should -Be 'D:\Documents\Private'
        $enc.privatePaths[0].Id | Should -Be 'enc-1'
        $docs.Hash | Should -Match '^[0-9a-f]{64}$'
    }

    It 'does not change the config it is given' {
        $cfg = New-TestConfig
        $null = ConvertTo-BackupDocuments -RawConfig $cfg -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1'
        $cfg.ContainsKey('PrivatePaths') | Should -BeTrue
        $cfg.Pairs[0].ContainsKey('holdsEncrypted') | Should -BeFalse
    }

    It 'writes an empty encrypted list when there are no encrypted folders' {
        $cfg = New-TestConfig
        $cfg.Remove('PrivatePaths')
        $docs = ConvertTo-BackupDocuments -RawConfig $cfg -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1'
        $enc = $docs.Encrypted | ConvertFrom-Json
        @($enc.privatePaths).Count | Should -Be 0
        $docs.Encrypted | Should -Match '"privatePaths": \[\]'
        ($docs.Plain | ConvertFrom-Json).config.Pairs[0].PSObject.Properties.Name | Should -Not -Contain 'holdsEncrypted'
    }

    It 'keeps %USERPROFILE% paths unexpanded' {
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1'
        $plain = $docs.Plain | ConvertFrom-Json
        ($plain.config.Pairs | Where-Object Name -eq 'Mine').Local | Should -Be '%USERPROFILE%\Mine'
        $docs.Plain | Should -Not -Match ([regex]::Escape($env:USERPROFILE))
    }

    It 'keeps whole numbers whole' {
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1'
        $docs.Plain | Should -Match '"DailyBudgetGB": 30,'
    }

    It 'gives the same hash when only the time or PC name differ' {
        $a = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters 'x' -Now $script:Now -PcName 'PC-A' -AppVersion '1.0'
        $b = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters 'x' -Now $script:Now.AddDays(3) -PcName 'PC-B' -AppVersion '2.0'
        $b.Hash | Should -Be $a.Hash
        $b.Plain | Should -Not -Be $a.Plain
    }

    It 'changes the hash when a pair, a setting, the filters or an encrypted entry changes' {
        $base = (ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters 'x' -Now $script:Now -PcName 'A' -AppVersion '1').Hash

        $c = New-TestConfig; $c.Pairs[1].Priority = 2
        (ConvertTo-BackupDocuments -RawConfig $c -GlobalFilters 'x' -Now $script:Now -PcName 'A' -AppVersion '1').Hash | Should -Not -Be $base

        $c = New-TestConfig; $c.DailyBudgetGB = 20
        (ConvertTo-BackupDocuments -RawConfig $c -GlobalFilters 'x' -Now $script:Now -PcName 'A' -AppVersion '1').Hash | Should -Not -Be $base

        (ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters 'y' -Now $script:Now -PcName 'A' -AppVersion '1').Hash | Should -Not -Be $base

        $c = New-TestConfig; $c.PrivatePaths[0].Paused = $true
        (ConvertTo-BackupDocuments -RawConfig $c -GlobalFilters 'x' -Now $script:Now -PcName 'A' -AppVersion '1').Hash | Should -Not -Be $base

        $c = New-TestConfig; $c.Pairs += @{ Name = 'Extra'; Local = 'D:\Extra'; Remote = 'D/Extra'; Priority = 3 }
        (ConvertTo-BackupDocuments -RawConfig $c -GlobalFilters 'x' -Now $script:Now -PcName 'A' -AppVersion '1').Hash | Should -Not -Be $base
    }

    It 'gives the same hash whatever order the keys were added in' {
        $a = @{ Remote = 'pikpak'; Pairs = @(@{ Name = 'A'; Local = 'D:\A'; Remote = 'D/A' }) }
        $b = @{ Pairs = @([ordered]@{ Remote = 'D/A'; Local = 'D:\A'; Name = 'A' }); Remote = 'pikpak' }
        $ha = (ConvertTo-BackupDocuments -RawConfig $a -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1').Hash
        $hb = (ConvertTo-BackupDocuments -RawConfig $b -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1').Hash
        $hb | Should -Be $ha
    }

    It 'round-trips non-ASCII names without BOM' {
        $name = 'Nh' + [char]0x1EA1 + 'c'
        $cfg = New-TestConfig
        $cfg.Pairs[1].Name = $name
        $cfg.PrivatePaths[0].Name = $name
        $docs = ConvertTo-BackupDocuments -RawConfig $cfg -GlobalFilters $name -Now $script:Now -PcName $name -AppVersion '1'
        foreach ($text in $docs.Plain, $docs.Encrypted) { $text[0] | Should -Not -Be ([char]0xFEFF) }

        $file = Join-Path $TestDrive 'b.json'
        [IO.File]::WriteAllText($file, $docs.Plain, (New-Object System.Text.UTF8Encoding $false))
        $bytes = [IO.File]::ReadAllBytes($file)
        $bytes[0] | Should -Be ([byte][char]'{')
        $parsed = ConvertFrom-BackupText -Text ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)) -Kind plain
        $parsed.Invalid | Should -BeNullOrEmpty
        ($parsed.Config.Pairs | Where-Object { $_.Id -eq 'id-music' }).Name | Should -BeExactly $name
        $parsed.GlobalFilters | Should -BeExactly $name
        $parsed.PcName | Should -BeExactly $name

        $encFile = Join-Path $TestDrive 'e.json'
        [IO.File]::WriteAllText($encFile, $docs.Encrypted, (New-Object System.Text.UTF8Encoding $false))
        $enc = ConvertFrom-BackupText -Text ([IO.File]::ReadAllText($encFile, [Text.Encoding]::UTF8)) -Kind encrypted
        $enc.PrivatePaths[0].Name | Should -BeExactly $name
    }

    It 'escapes quotes, backslashes and control characters' {
        $nasty = 'a"b\c' + [char]10 + [char]9 + [char]1 + 'z'
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters $nasty -Now $script:Now -PcName 'A' -AppVersion '1'
        (ConvertFrom-BackupText -Text $docs.Plain -Kind plain).GlobalFilters | Should -BeExactly $nasty
    }
}

Describe 'ConvertFrom-BackupText' {
    It 'reads a plain backup into hashtables' {
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters 'f' -Now $script:Now -PcName 'KEN-PC' -AppVersion '1'
        $r = ConvertFrom-BackupText -Text $docs.Plain -Kind plain
        $r.Invalid | Should -BeNullOrEmpty
        $r.Config | Should -BeOfType [hashtable]
        @($r.Config.Pairs).Count | Should -Be 3
        $r.Config.Pairs[0] | Should -BeOfType [hashtable]
        $r.Config.Pairs[0].holdsEncrypted | Should -BeTrue
        $r.Config.DailyBudgetGB | Should -BeOfType [int]
        $r.Config.DailyBudgetGB | Should -Be 30
        $r.Config.ContainsKey('PrivatePaths') | Should -BeFalse
        $r.GlobalFilters | Should -Be 'f'
        $r.PcName | Should -Be 'KEN-PC'
        $r.Saved | Should -Be '2026-11-21T10:00:00Z'
        @($r.PrivatePaths).Count | Should -Be 0
    }

    It 'reads an encrypted backup into hashtables' {
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters '' -Now $script:Now -PcName 'KEN-PC' -AppVersion '1'
        $r = ConvertFrom-BackupText -Text $docs.Encrypted -Kind encrypted
        $r.Invalid | Should -BeNullOrEmpty
        @($r.PrivatePaths).Count | Should -Be 1
        $r.PrivatePaths[0] | Should -BeOfType [hashtable]
        $r.PrivatePaths[0].Path | Should -Be 'D:\Documents\Private'
        $r.PrivatePaths[0].Paused | Should -BeFalse
        $r.PcName | Should -Be 'KEN-PC'
    }

    It 'keeps a one-element list a list' {
        $cfg = @{ Remote = 'pikpak'; Pairs = @(@{ Name = 'A'; Local = 'D:\A'; Remote = 'D/A' }) }
        $docs = ConvertTo-BackupDocuments -RawConfig $cfg -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1'
        $r = ConvertFrom-BackupText -Text $docs.Plain -Kind plain
        ($r.Config.Pairs -is [array]) | Should -BeTrue
        @($r.Config.Pairs).Count | Should -Be 1
    }

    It 'reads empty, non-JSON, wrong kind and version 2 as Invalid' {
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1'
        $v2 = $docs.Plain.Replace('"version": 1', '"version": 2')
        $v2 | Should -Not -Be $docs.Plain
        $cases = @(
            @{ Text = '' }
            @{ Text = 'this is { not json' }
            @{ Text = $docs.Encrypted }   # an encrypted file where the readable one is expected
            @{ Text = $v2 }
        )
        foreach ($c in $cases) {
            $r = ConvertFrom-BackupText -Text $c.Text -Kind plain
            $r.Invalid | Should -BeTrue
            $r.Reason | Should -Not -BeNullOrEmpty
        }
    }

    It 'reads another app, a non-object, a missing config and a missing version as Invalid' {
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1'
        $texts = @(
            $docs.Plain.Replace('pikpak-mirror', 'other-app')
            '[1, 2, 3]'
            '42'
            '{ "app": "pikpak-mirror", "kind": "folder-list-backup", "version": 1 }'
            '{ "app": "pikpak-mirror", "kind": "folder-list-backup" }'
        )
        foreach ($t in $texts) { (ConvertFrom-BackupText -Text $t -Kind plain).Invalid | Should -BeTrue -Because $t }
        (ConvertFrom-BackupText -Text $docs.Plain -Kind encrypted).Invalid | Should -BeTrue
        (ConvertFrom-BackupText -Text $null -Kind plain).Invalid | Should -BeTrue
    }

    It 'accepts a file saved with a BOM' {
        $docs = ConvertTo-BackupDocuments -RawConfig (New-TestConfig) -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1'
        (ConvertFrom-BackupText -Text ([string][char]0xFEFF + $docs.Plain) -Kind plain).Invalid | Should -BeNullOrEmpty
    }
}

Describe 'Backup: Resolve-RestorePath' {
    It 'moves C:\Users\Old paths to the current profile only when Old is missing' {
        $exists = { param($p) $p -in @('C:\', 'D:\', 'C:\Users\Present') }
        $r = Resolve-RestorePath -Path 'C:\Users\Old\Documents\Stuff' -UserProfile 'C:\Users\Ken' -PathExists $exists
        $r.Path | Should -Be 'C:\Users\Ken\Documents\Stuff'
        $r.Moved | Should -BeTrue
        $r.DriveMissing | Should -BeFalse

        $r = Resolve-RestorePath -Path 'C:\Users\Present\Docs' -UserProfile 'C:\Users\Ken' -PathExists $exists
        $r.Path | Should -Be 'C:\Users\Present\Docs'
        $r.Moved | Should -BeFalse

        $r = Resolve-RestorePath -Path 'C:\Users\ken\Docs' -UserProfile 'C:\Users\Ken' -PathExists { param($p) $false }
        $r.Path | Should -Be 'C:\Users\ken\Docs'
        $r.Moved | Should -BeFalse

        $r = Resolve-RestorePath -Path 'C:\Users\Old' -UserProfile 'C:\Users\Ken' -PathExists $exists
        $r.Path | Should -Be 'C:\Users\Ken'
        $r.Moved | Should -BeTrue

        $r = Resolve-RestorePath -Path 'D:\Users\Old\Docs' -UserProfile 'C:\Users\Ken' -PathExists $exists
        $r.Path | Should -Be 'D:\Users\Old\Docs'
        $r.Moved | Should -BeFalse
    }

    It 'returns %VAR% paths unchanged' {
        $r = Resolve-RestorePath -Path '%USERPROFILE%\Documents' -UserProfile 'C:\Users\Ken' -PathExists { param($p) $true }
        $r.Path | Should -Be '%USERPROFILE%\Documents'
        $r.Moved | Should -BeFalse
        $r.DriveMissing | Should -BeFalse
    }

    It 'marks a missing drive' {
        $exists = { param($p) $p -in @('C:\', 'D:\') }
        (Resolve-RestorePath -Path 'E:\Old' -UserProfile 'C:\Users\Ken' -PathExists $exists).DriveMissing | Should -BeTrue
        (Resolve-RestorePath -Path 'D:\Music' -UserProfile 'C:\Users\Ken' -PathExists $exists).DriveMissing | Should -BeFalse
        (Resolve-RestorePath -Path 'e:\old' -UserProfile 'C:\Users\Ken' -PathExists $exists).DriveMissing | Should -BeTrue
    }
}

Describe 'Backup: New-RestoreConfig' {
    It 'New-RestoreConfig replaces machine paths on a missing drive and fills missing settings from defaults' {
        $settings = @{
            Remote = 'pikpak'; LocalHolding = 'E:\Hold'; StateDir = 'D:\State'; DailyBudgetGB = 12
            Pairs = @(@{ Name = 'Old'; Local = 'E:\Old'; Remote = 'E/Old'; Id = 'x' })
        }
        $defaults = @{
            Remote = 'pikpak'; LocalHolding = '%LOCALAPPDATA%\PikPakSync\holding'; StateDir = '%LOCALAPPDATA%\PikPakSync\state'
            DailyBudgetGB = 5; SyncIntervalMinutes = 60; HoldingDays = 14; Pairs = @(); PrivatePaths = @()
        }
        $pairs = @(@{ Name = 'Docs'; Local = 'D:\Docs'; Remote = 'D/Docs'; Id = 'a'; holdsEncrypted = $true; Paused = $true })
        $priv = @(@{ Path = 'D:\Docs\Private'; Name = 'Private'; Id = 'e1' })
        $exists = { param($p) $p -in @('C:\', 'D:\') }

        $cfg = New-RestoreConfig -Settings $settings -Pairs $pairs -PrivatePaths $priv -Defaults $defaults -PathExists $exists
        $cfg.LocalHolding | Should -Be '%LOCALAPPDATA%\PikPakSync\holding'
        $cfg.StateDir | Should -Be 'D:\State'
        $cfg.DailyBudgetGB | Should -Be 12
        $cfg.SyncIntervalMinutes | Should -Be 60
        $cfg.HoldingDays | Should -Be 14
        @($cfg.Pairs).Count | Should -Be 1
        $cfg.Pairs[0].Name | Should -Be 'Docs'
        $cfg.Pairs[0].Id | Should -Be 'a'
        $cfg.Pairs[0].Paused | Should -BeTrue
        $cfg.Pairs[0].ContainsKey('holdsEncrypted') | Should -BeFalse
        @($cfg.PrivatePaths).Count | Should -Be 1
        $cfg.PrivatePaths[0].Id | Should -Be 'e1'
        # the inputs are left alone
        $pairs[0].ContainsKey('holdsEncrypted') | Should -BeTrue
        @($settings.Pairs).Count | Should -Be 1
    }

    It 'keeps the backup machine paths when their drive exists and allows empty lists' {
        $settings = @{ Remote = 'pikpak'; LocalHolding = 'D:\Hold'; StateDir = '%LOCALAPPDATA%\State'; PrivatePaths = @(@{ Path = 'D:\x' }) }
        $defaults = @{ Remote = 'pikpak'; LocalHolding = 'C:\h'; StateDir = 'C:\s' }
        $cfg = New-RestoreConfig -Settings $settings -Pairs @() -PrivatePaths @() -Defaults $defaults -PathExists { param($p) $p -in @('C:\', 'D:\') }
        $cfg.LocalHolding | Should -Be 'D:\Hold'
        $cfg.StateDir | Should -Be '%LOCALAPPDATA%\State'
        @($cfg.Pairs).Count | Should -Be 0
        @($cfg.PrivatePaths).Count | Should -Be 0
        ($cfg.Pairs -is [array]) | Should -BeTrue
    }

    It 'produces a config the writer can save' {
        $settings = @{ Remote = 'pikpak'; MirrorRoot = 'PC-Mirror'; LocalHolding = 'D:\H'; StateDir = 'D:\S' }
        $pairs = @(@{ Name = 'Docs'; Local = 'D:\Docs'; Remote = 'D/Docs'; Priority = 3 })
        $cfg = New-RestoreConfig -Settings $settings -Pairs $pairs -PrivatePaths @() -Defaults @{} -PathExists { param($p) $true }
        $text = ConvertTo-MirrorConfigText -Config $cfg
        $text | Should -Match "Name = 'Docs'"
        $text | Should -Match 'PrivatePaths = @\(\)'
    }
}
