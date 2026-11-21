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

    It 'flags every pair when an encrypted folder path cannot be resolved (fails closed)' {
        $cfg = New-TestConfig
        $cfg.PrivatePaths = @(@{ Path = 'D:\Bad<Path'; Name = 'Bad'; Id = 'enc-bad' })
        $plain = (ConvertTo-BackupDocuments -RawConfig $cfg -GlobalFilters '' -Now $script:Now -PcName 'A' -AppVersion '1').Plain | ConvertFrom-Json
        foreach ($p in @($plain.config.Pairs)) { $p.holdsEncrypted | Should -BeTrue }
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

Describe 'Backup: status file' {
    It 'returns defaults when backup.json is missing or unreadable' {
        $dir = Join-Path $TestDrive 'st1'
        $s = Get-BackupStatus -StateDir $dir
        $s.Hash | Should -Be ''
        $s.LastSuccess | Should -BeNullOrEmpty
        $s.FailingSince | Should -BeNullOrEmpty
        $s.EncryptedUploaded | Should -BeFalse
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'backup.json'), '{ not json', (New-Object Text.UTF8Encoding $false))
        (Get-BackupStatus -StateDir $dir).Hash | Should -Be ''
    }

    It 'saves and reads back without a BOM and leaves no temp file' {
        $dir = Join-Path $TestDrive 'st2'
        Save-BackupStatus -StateDir $dir -Status @{ Hash = 'abc'; LastSuccess = '2026-11-21T10:00:00'; FailingSince = $null; EncryptedUploaded = $true }
        $bytes = [IO.File]::ReadAllBytes((Join-Path $dir 'backup.json'))
        ($bytes[0] -eq 0xEF) | Should -BeFalse
        $s = Get-BackupStatus -StateDir $dir
        $s.Hash | Should -Be 'abc'
        $s.LastSuccess | Should -Be '2026-11-21T10:00:00'
        $s.FailingSince | Should -BeNullOrEmpty
        $s.EncryptedUploaded | Should -BeTrue
        @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp').Count | Should -Be 0
    }
}

Describe 'Publish-ConfigBackup' {
    BeforeAll {
        function New-PublishSetup {
            param([switch]$Private)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $docs = Join-Path $root 'Docs'
            New-Item -ItemType Directory -Path $docs -Force | Out-Null
            $cfg = @{
                Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror'; HoldingRoot = 'PC-Holding'
                LocalHolding = (Join-Path $root 'holding'); StateDir = (Join-Path $root 'state')
                HoldingDays = 30; MaxDeletePercent = 10; DailyBudgetGB = 1; MonthlyBudgetGB = 30; QuotaWarnPercent = 90
                StaleRunDays = 3; LogKeepDays = 60; BwLimit = ''; SyncTime = '20:00'; SyncAtLogon = $true
                PrivatePaths = @()
                Pairs = @(@{ Name = 'Docs'; Local = $docs; Remote = 'T/Docs'; Priority = 1 })
            }
            if ($Private) { $cfg.PrivatePaths = @(@{ Path = (Join-Path $root 'Photos'); Name = 'Photos' }) }
            $path = Join-Path $root 'mirror.config.psd1'
            [IO.File]::WriteAllText($path, (ConvertTo-MirrorConfigText -Config $cfg), (New-Object Text.UTF8Encoding $true))
            [pscustomobject]@{ Root = $root; Path = $path; Cfg = $cfg; StateDir = $cfg.StateDir }
        }
        function Set-PublishConfig {
            # Rewrites the config file by hand (no app save), with the given changes to the raw config.
            param($Setup, [hashtable]$Changes)
            foreach ($k in $Changes.Keys) { $Setup.Cfg[$k] = $Changes[$k] }
            [IO.File]::WriteAllText($Setup.Path, (ConvertTo-MirrorConfigText -Config $Setup.Cfg), (New-Object Text.UTF8Encoding $true))
        }
        function Publish-Test {
            param($Setup, [datetime]$At = $script:Now, [switch]$Force)
            $loaded = Get-MirrorConfig -Path $Setup.Path
            Publish-ConfigBackup -ConfigPath $Setup.Path -Config $loaded -Now $At -Force:$Force
        }
    }
    BeforeEach {
        $script:Uploads = New-Object System.Collections.Generic.List[object]
        $script:RcloneExit = 0
        Mock Invoke-RcloneOutput {
            $src = $Arguments[1]
            $script:Uploads.Add(@{ Args = @($Arguments); Text = [IO.File]::ReadAllText($src); Bytes = [IO.File]::ReadAllBytes($src); Src = $src })
            [pscustomobject]@{ ExitCode = $script:RcloneExit; Output = @() }
        }
    }

    It 'uploads both files and stores the hash' {
        $s = New-PublishSetup -Private
        $r = Publish-Test $s
        $r.Uploaded | Should -BeTrue
        $r.Skipped | Should -BeFalse
        $r.Error | Should -BeNullOrEmpty
        $script:Uploads.Count | Should -Be 2
        $script:Uploads[0].Args[0] | Should -Be 'copyto'
        $script:Uploads[0].Args[2] | Should -Be 'pikpak:PC-Mirror/.pikpak-sync-backup.json'
        $script:Uploads[1].Args[2] | Should -Be 'private:.pikpak-sync-encrypted.json'
        ($script:Uploads[0].Text | ConvertFrom-Json).kind | Should -Be 'folder-list-backup'
        ($script:Uploads[1].Text | ConvertFrom-Json).kind | Should -Be 'encrypted-folder-list'
        $script:Uploads[0].Bytes[0] | Should -Not -Be 0xEF
        $script:Uploads[1].Bytes[0] | Should -Not -Be 0xEF
        $script:Uploads[0].Text | Should -Not -Match 'Photos'
        $st = Get-BackupStatus -StateDir $s.StateDir
        $st.Hash | Should -Match '^[0-9a-f]{64}$'
        $st.LastSuccess | Should -Not -BeNullOrEmpty
        $st.FailingSince | Should -BeNullOrEmpty
        $st.EncryptedUploaded | Should -BeTrue
        foreach ($u in $script:Uploads) { Test-Path -LiteralPath $u.Src | Should -BeFalse }
    }

    It 'uploads nothing when the hash is unchanged' {
        $s = New-PublishSetup -Private
        $null = Publish-Test $s
        $script:Uploads.Clear()
        # A later time and another PC name must not matter: the hash covers the content, not 'saved' or 'pcName'.
        $oldPc = $env:COMPUTERNAME
        try {
            $env:COMPUTERNAME = 'OTHER-PC'
            $r = Publish-Test $s -At $script:Now.AddHours(2)
        }
        finally { $env:COMPUTERNAME = $oldPc }
        $r.Skipped | Should -BeTrue
        $r.Uploaded | Should -BeFalse
        $script:Uploads.Count | Should -Be 0
    }

    It 'uploads again with -Force' {
        $s = New-PublishSetup
        $null = Publish-Test $s
        $script:Uploads.Clear()
        (Publish-Test $s -Force).Uploaded | Should -BeTrue
        $script:Uploads.Count | Should -Be 1
    }

    It 'uploads after a hand edit' {
        $s = New-PublishSetup
        $null = Publish-Test $s
        $script:Uploads.Clear()
        Set-PublishConfig $s @{ DailyBudgetGB = 5 }
        $r = Publish-Test $s
        $r.Uploaded | Should -BeTrue
        $script:Uploads.Count | Should -Be 1
        ($script:Uploads[0].Text | ConvertFrom-Json).config.DailyBudgetGB | Should -Be 5
    }

    It 'uploads the global filters text with the folder list' {
        $s = New-PublishSetup
        $f = Join-Path $s.Root 'filters.txt'
        [IO.File]::WriteAllText($f, "- *.tmp`n", (New-Object Text.UTF8Encoding $false))
        $loaded = Get-MirrorConfig -Path $s.Path
        $loaded['GlobalFiltersFile'] = $f
        $null = Publish-ConfigBackup -ConfigPath $s.Path -Config $loaded -Now $script:Now
        ($script:Uploads[0].Text | ConvertFrom-Json).globalFilters | Should -Be "- *.tmp`n"
    }

    It 'keeps the hash and sets FailingSince when rclone fails, and does not throw' {
        $s = New-PublishSetup
        $script:RcloneExit = 1
        $script:Res = $null
        { $script:Res = Publish-Test $s } | Should -Not -Throw
        $script:Res.Uploaded | Should -BeFalse
        $script:Res.Error | Should -Not -BeNullOrEmpty
        $st = Get-BackupStatus -StateDir $s.StateDir
        $st.Hash | Should -Be ''
        $st.FailingSince | Should -Be $script:Now.ToString('yyyy-MM-dd"T"HH:mm:ss')
        foreach ($u in $script:Uploads) { Test-Path -LiteralPath $u.Src | Should -BeFalse }
        # The next success clears it.
        $script:RcloneExit = 0
        (Publish-Test $s -At $script:Now.AddHours(5)).Uploaded | Should -BeTrue
        (Get-BackupStatus -StateDir $s.StateDir).FailingSince | Should -BeNullOrEmpty
    }

    It 'keeps the first FailingSince across repeated failures' {
        $s = New-PublishSetup
        $script:RcloneExit = 1
        $null = Publish-Test $s
        $null = Publish-Test $s -At $script:Now.AddDays(1)
        (Get-BackupStatus -StateDir $s.StateDir).FailingSince | Should -Be $script:Now.ToString('yyyy-MM-dd"T"HH:mm:ss')
    }

    It 'uploads again and clears FailingSince when the config returns to the last uploaded content after a failure' {
        $s = New-PublishSetup
        $null = Publish-Test $s
        Set-PublishConfig $s @{ DailyBudgetGB = 5 }
        $script:RcloneExit = 1
        $null = Publish-Test $s -At $script:Now.AddHours(1)
        (Get-BackupStatus -StateDir $s.StateDir).FailingSince | Should -Not -BeNullOrEmpty
        # Back to the content of the last good upload: PikPak may hold a partial upload, so it is sent again.
        Set-PublishConfig $s @{ DailyBudgetGB = 1 }
        $script:RcloneExit = 0
        $script:Uploads.Clear()
        $r = Publish-Test $s -At $script:Now.AddHours(2)
        $r.Skipped | Should -BeFalse
        $r.Uploaded | Should -BeTrue
        $script:Uploads.Count | Should -Be 1
        (Get-BackupStatus -StateDir $s.StateDir).FailingSince | Should -BeNullOrEmpty
    }

    It 'does not throw when the config file cannot be read' {
        $s = New-PublishSetup
        $loaded = Get-MirrorConfig -Path $s.Path
        $r = Publish-ConfigBackup -ConfigPath (Join-Path $s.Root 'missing.psd1') -Config $loaded -Now $script:Now
        $r.Uploaded | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
    }

    It 'skips the encrypted file when there are no encrypted folders and none was uploaded before' {
        $s = New-PublishSetup
        $r = Publish-Test $s
        $r.Uploaded | Should -BeTrue
        $script:Uploads.Count | Should -Be 1
        $script:Uploads[0].Args[2] | Should -Be 'pikpak:PC-Mirror/.pikpak-sync-backup.json'
        (Get-BackupStatus -StateDir $s.StateDir).EncryptedUploaded | Should -BeFalse
    }

    It 'uploads an empty encrypted list after the last encrypted folder is removed' {
        $s = New-PublishSetup -Private
        $null = Publish-Test $s
        $script:Uploads.Clear()
        Set-PublishConfig $s @{ PrivatePaths = @() }
        $r = Publish-Test $s
        $r.Uploaded | Should -BeTrue
        $script:Uploads.Count | Should -Be 2
        $script:Uploads[1].Args[2] | Should -Be 'private:.pikpak-sync-encrypted.json'
        @(($script:Uploads[1].Text | ConvertFrom-Json).privatePaths).Count | Should -Be 0
        (Get-BackupStatus -StateDir $s.StateDir).EncryptedUploaded | Should -BeTrue
    }

    It 'keeps the hash when only the encrypted upload fails' {
        $s = New-PublishSetup -Private
        Mock Invoke-RcloneOutput {
            $script:Uploads.Add(@{ Args = @($Arguments); Src = $Arguments[1] })
            $code = 0
            if ($Arguments[2] -like 'private:*') { $code = 1 }
            [pscustomobject]@{ ExitCode = $code; Output = @() }
        }
        $r = Publish-Test $s
        $r.Uploaded | Should -BeFalse
        $r.Error | Should -Not -BeNullOrEmpty
        $st = Get-BackupStatus -StateDir $s.StateDir
        $st.Hash | Should -Be ''
        $st.FailingSince | Should -Not -BeNullOrEmpty
    }

    It 'writes no encrypted folder name to the log' {
        $s = New-PublishSetup -Private
        $script:RcloneExit = 1
        $null = Publish-Test $s
        $log = (Get-ChildItem -LiteralPath (Join-Path $s.StateDir 'logs') -Filter '*.log' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ''
        $log | Should -Match 'folder list backup'
        $log | Should -Not -Match 'Photos'
    }
}

Describe 'Backup: Test-MirrorConfig PausedForKey' {
    It 'Test-MirrorConfig rejects a non-bool PausedForKey' {
        $base = @{
            Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror'; HoldingRoot = 'PC-Holding'
            LocalHolding = 'D:\.pikpak-holding'; StateDir = 'C:\State\PikPakMirror'
            HoldingDays = 30; MaxDeletePercent = 10; DailyBudgetGB = 8; MonthlyBudgetGB = 250; QuotaWarnPercent = 90
            StaleRunDays = 3; LogKeepDays = 60; BwLimit = 'off'; PrivatePaths = @()
        }
        $bad = $base.Clone()
        $bad.Pairs = @(@{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Paused = $true; PausedForKey = 'yes' })
        (@(Test-MirrorConfig -Config $bad) -join '|') | Should -Match "Pair 'Music' PausedForKey must be \`$true or \`$false\."
        $good = $base.Clone()
        $good.Pairs = @(@{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Paused = $true; PausedForKey = $true })
        @(Test-MirrorConfig -Config $good).Count | Should -Be 0
    }
}

Describe 'Backup: Find-RemoteSyncedFolders' {
    BeforeAll {
        function script:New-MarkerJson {
            param([string]$Id, [string]$Kind = 'synced', [string]$Name, [string]$LastPath)
            (@{ app = 'pikpak-mirror'; version = 1; id = $Id; kind = $Kind; name = $Name; pikpak = 'x'; lastPath = $LastPath; updated = '2026-11-01' } | ConvertTo-Json)
        }
    }
    BeforeEach {
        $script:Listing = @()
        $script:Markers = @{}
        Mock Invoke-RcloneOutput { throw ('unexpected rclone call: ' + ($Arguments -join ' ')) }
        Mock Invoke-RcloneOutput { [pscustomobject]@{ ExitCode = 0; Output = $script:Listing } } -ParameterFilter { $Arguments[0] -eq 'lsf' }
        Mock Invoke-RcloneOutput {
            $t = $script:Markers[[string]$Arguments[1]]
            if ($null -eq $t) { return [pscustomobject]@{ ExitCode = 3; Output = @() } }
            [pscustomobject]@{ ExitCode = 0; Output = @($t -split "`n") }
        } -ParameterFilter { $Arguments[0] -eq 'cat' }
    }

    It 'lists the ID files with one rclone lsf and reads each top folder' {
        $script:Listing = @('D/Music/.pikpak-sync.json', 'D/Music/Live/.pikpak-sync.json', 'C-Users/Docs/.pikpak-sync.json')
        $script:Markers['pikpak:PC-Mirror/D/Music/.pikpak-sync.json'] = New-MarkerJson -Id '11111111-2222-3333-4444-555555555555' -Name 'Music' -LastPath 'D:\Music'
        $script:Markers['pikpak:PC-Mirror/C-Users/Docs/.pikpak-sync.json'] = New-MarkerJson -Id '22222222-2222-3333-4444-555555555555' -Name 'Docs' -LastPath 'C:\Users\old\Docs'
        $found = @(Find-RemoteSyncedFolders -Remote 'pikpak' -MirrorRoot 'PC-Mirror')
        $found.Count | Should -Be 2
        (@($found | ForEach-Object { $_.Remote }) -join ',') | Should -Be 'C-Users/Docs,D/Music'
        $found[1].Id | Should -Be '11111111-2222-3333-4444-555555555555'
        $found[1].Name | Should -Be 'Music'
        $found[1].LastPath | Should -Be 'D:\Music'
        Should -Invoke Invoke-RcloneOutput -Times 1 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq 'lsf -R --files-only --include .pikpak-sync.json pikpak:PC-Mirror' }
        Should -Invoke Invoke-RcloneOutput -Times 0 -Exactly -ParameterFilter { $Arguments[0] -eq 'cat' -and $Arguments[1] -like '*Live*' }
    }

    It 'skips and logs an ID file that is not of a synced folder or not valid' {
        $state = Join-Path $TestDrive 'scan-state'
        $script:Listing = @('D/Enc/.pikpak-sync.json', 'D/Bad/.pikpak-sync.json', 'D/Gone/.pikpak-sync.json', '.pikpak-sync.json')
        $script:Markers['pikpak:PC-Mirror/D/Enc/.pikpak-sync.json'] = New-MarkerJson -Id '33333333-2222-3333-4444-555555555555' -Kind 'encrypted' -Name 'Enc' -LastPath 'D:\Enc'
        $script:Markers['pikpak:PC-Mirror/D/Bad/.pikpak-sync.json'] = 'not json'
        $found = @(Find-RemoteSyncedFolders -Remote 'pikpak' -MirrorRoot 'PC-Mirror' -Config @{ StateDir = $state })
        $found.Count | Should -Be 0
        $log = (Get-ChildItem -LiteralPath (Join-Path $state 'logs') -File | Get-Content -Raw) -join ''
        $log | Should -Match 'D/Enc'
        $log | Should -Match 'D/Bad'
    }

    It 'throws when PikPak cannot be listed or an ID file cannot be read, and finds nothing in a missing folder' {
        Mock Invoke-RcloneOutput { [pscustomobject]@{ ExitCode = 1; Output = @() } } -ParameterFilter { $Arguments[0] -eq 'lsf' }
        { Find-RemoteSyncedFolders -Remote 'pikpak' -MirrorRoot 'PC-Mirror' } | Should -Throw
        Mock Invoke-RcloneOutput { [pscustomobject]@{ ExitCode = 3; Output = @() } } -ParameterFilter { $Arguments[0] -eq 'lsf' }
        @(Find-RemoteSyncedFolders -Remote 'pikpak' -MirrorRoot 'PC-Mirror').Count | Should -Be 0
        Mock Invoke-RcloneOutput { [pscustomobject]@{ ExitCode = 0; Output = @('D/Music/.pikpak-sync.json') } } -ParameterFilter { $Arguments[0] -eq 'lsf' }
        Mock Invoke-RcloneOutput { [pscustomobject]@{ ExitCode = 1; Output = @() } } -ParameterFilter { $Arguments[0] -eq 'cat' }
        { Find-RemoteSyncedFolders -Remote 'pikpak' -MirrorRoot 'PC-Mirror' } | Should -Throw
    }
}
