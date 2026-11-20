BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    $script:repo = 'G:\pikpak mirror'
    $script:cfgPath = 'G:\pikpak mirror\config\mirror.config.psd1'
    $script:cfg = @{
        Remote        = 'pikpak'
        PrivateRemote = 'private'
        StateDir      = 'C:\State\PikPak Mirror'
    }
}

Describe 'New-MirrorTaskSpec' {
    It 'Sync: runs Invoke-Sync.ps1 headless with quoted paths' {
        $t = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath
        $t.TaskName | Should -BeExactly 'PikPakMirror-Sync'
        $t.Execute | Should -BeExactly 'conhost.exe'
        $t.Argument | Should -BeExactly '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "G:\pikpak mirror\scripts\Invoke-Sync.ps1" -ConfigPath "G:\pikpak mirror\config\mirror.config.psd1"'
    }

    It 'Sync: AtLogOn +15 min and a repeating trigger every hour by default' {
        $t = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath
        @($t.Triggers).Count | Should -Be 2
        $t.Triggers[0].Type | Should -BeExactly 'AtLogOn'
        $t.Triggers[0].Delay | Should -BeExactly 'PT15M'
        $t.Triggers[1].Type | Should -BeExactly 'Every'
        $t.Triggers[1].Minutes | Should -Be 60
    }

    It 'builds one repeating trigger (Every, from 00:00, no Daily) plus the logon trigger' {
        $s = New-MirrorTaskSpec -Kind Sync -RepoRoot 'C:\r' -ConfigPath 'C:\r\c.psd1' -SyncIntervalMinutes 60
        @($s.Triggers).Count | Should -Be 2
        @($s.Triggers | Where-Object { $_.Type -eq 'AtLogOn' }).Count | Should -Be 1
        $e = @($s.Triggers | Where-Object { $_.Type -eq 'Every' })
        $e.Count | Should -Be 1
        $e[0].Minutes | Should -Be 60
        $e[0].At | Should -BeExactly '00:00'
        @($s.Triggers | Where-Object { $_.Type -eq 'Daily' }).Count | Should -Be 0
        @($s.Triggers | Where-Object { $_.Type -eq 'Repeat' }).Count | Should -Be 0
        $s2 = New-MirrorTaskSpec -Kind Sync -RepoRoot 'C:\r' -ConfigPath 'C:\r\c.psd1' -SyncIntervalMinutes 15
        @($s2.Triggers | Where-Object { $_.Type -eq 'Every' })[0].Minutes | Should -Be 15
    }

    It 'builds the daily trigger for interval 0, at SyncTime' {
        $t = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncTime '22:30' -SyncIntervalMinutes 0
        @($t.Triggers | Where-Object { $_.Type -eq 'Every' }).Count | Should -Be 0
        $d = @($t.Triggers | Where-Object { $_.Type -eq 'Daily' })
        $d.Count | Should -Be 1
        $d[0].At | Should -BeExactly '22:30'
    }

    It 'Sync has only the repeating trigger when -SyncAtLogon $false' {
        $t = New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -SyncAtLogon $false
        @($t.Triggers).Count | Should -Be 1
        @($t.Triggers)[0].Type | Should -BeExactly 'Every'
    }

    It 'describes the task as PikPak Sync' {
        (New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath).Description |
            Should -BeExactly 'PikPak Sync: two-way sync of the configured folders with PikPak.'
    }

    It 'Sync: catch-up, single instance, no time limit, runs on battery' {
        $s = (New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath).Settings
        $s.StartWhenAvailable | Should -BeTrue
        $s.MultipleInstances | Should -BeExactly 'IgnoreNew'
        $s.ExecutionTimeLimit | Should -Be ([TimeSpan]::Zero)
        $s.AllowStartIfOnBatteries | Should -BeTrue
        $s.DontStopIfGoingOnBatteries | Should -BeTrue
    }

    It 'R14: Sync is disabled unless -EnableSchedule' {
        (New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath).Enabled | Should -BeFalse
        (New-MirrorTaskSpec -Kind Sync -RepoRoot $repo -ConfigPath $cfgPath -EnableSchedule).Enabled | Should -BeTrue
    }

    It 'Mount is no longer a task kind' {
        { New-MirrorTaskSpec -Kind Mount -RepoRoot $repo -ConfigPath $cfgPath } | Should -Throw
    }

    It 'trims a trailing backslash from RepoRoot (a \" would break the quoting)' {
        $t = New-MirrorTaskSpec -Kind Sync -RepoRoot 'G:\pikpak-mirror\' -ConfigPath 'G:\pikpak-mirror\config\mirror.config.psd1'
        $t.Argument | Should -BeLike '*-File "G:\pikpak-mirror\scripts\Invoke-Sync.ps1" *'
    }
}

Describe 'New-CryptSecret' {
    It 'is 32 characters of [A-Za-z0-9] by default' {
        $s = New-CryptSecret
        $s | Should -BeOfType [string]
        $s | Should -MatchExactly '^[A-Za-z0-9]{32}$'
    }

    It 'honours -Length' {
        (New-CryptSecret -Length 16).Length | Should -Be 16
    }

    It 'differs between calls' {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($i in 1..50) { [void]$set.Add((New-CryptSecret)) }
        $set.Count | Should -Be 50
    }

    It 'uses the whole alphabet' {
        $text = -join @(1..100 | ForEach-Object { New-CryptSecret })
        $set = New-Object 'System.Collections.Generic.HashSet[char]'
        foreach ($c in $text.ToCharArray()) { [void]$set.Add($c) }
        $set.Count | Should -Be 62
    }
}

Describe 'rclone config-create arguments' {
    It 'New-PikPakRemoteArgs builds the pikpak remote (forced obscure)' {
        $a = New-PikPakRemoteArgs -User 'me@example.com' -Password 'p w"d'
        $a | Should -BeOfType [string]
        ($a -join '|') | Should -BeExactly 'config|create|pikpak|pikpak|user|me@example.com|pass|p w"d|--obscure|--non-interactive'
    }

    It 'New-PikPakRemoteArgs honours -Name' {
        (New-PikPakRemoteArgs -Name 'pp' -User 'u' -Password 'p')[2] | Should -BeExactly 'pp'
    }

    It 'New-CryptRemoteArgs builds the crypt remote over pikpak:PC-Private (forced obscure)' {
        $a = New-CryptRemoteArgs -Password 'PASS' -Salt 'SALT'
        ($a -join '|') | Should -BeExactly 'config|create|private|crypt|remote|pikpak:PC-Private|filename_encryption|standard|directory_name_encryption|true|password|PASS|password2|SALT|--obscure|--non-interactive'
    }

    It 'New-CryptRemoteArgs omits password2 when the salt is empty' {
        $a = New-CryptRemoteArgs -Password 'PASS'
        $a -notcontains 'password2' | Should -BeTrue
        $a -contains 'password' | Should -BeTrue
        $a[-1] | Should -BeExactly '--non-interactive'
        $b = New-CryptRemoteArgs -Password 'PASS' -Salt ''
        $b -notcontains 'password2' | Should -BeTrue
    }

    It 'New-CryptRemoteArgs honours -Name and -BaseRemote' {
        $a = New-CryptRemoteArgs -Name 'priv' -BaseRemote 'pp' -Password 'P' -Salt 'S'
        $a[2] | Should -BeExactly 'priv'
        $a[5] | Should -BeExactly 'pp:PC-Private'
    }
}

Describe 'Join-ProcessArguments' {
    It 'quotes only what needs quoting: <Desc>' -TestCases @(
        @{ Desc = 'plain'; In = @('mount', 'pikpak:', 'P:'); Out = 'mount pikpak: P:' }
        @{ Desc = 'space'; In = @('--cache-dir', 'D:\my cache'); Out = '--cache-dir "D:\my cache"' }
        @{ Desc = 'empty'; In = @('a', '', 'b'); Out = 'a "" b' }
        @{ Desc = 'trailing backslash with space'; In = @('C:\a b\'); Out = '"C:\a b\\"' }
        @{ Desc = 'trailing backslash without space'; In = @('C:\ab\'); Out = 'C:\ab\' }
        @{ Desc = 'embedded quote'; In = @('a"b'); Out = '"a\"b"' }
        @{ Desc = 'backslashes before a quote'; In = @('a\\"b'); Out = '"a\\\\\"b"' }
        @{ Desc = 'bwlimit timetable'; In = @('--bwlimit', '18:00,2M:off 23:00,off'); Out = '--bwlimit "18:00,2M:off 23:00,off"' }
    ) {
        param($Desc, $In, $Out)
        Join-ProcessArguments -Arguments $In | Should -BeExactly $Out
    }
}

Describe 'Test-RemoteListed' {
    It 'finds <Name> in the listremotes output: <Expected>' -TestCases @(
        @{ Lines = @('pikpak:', 'private:'); Name = 'private'; Expected = $true }
        @{ Lines = @('pikpak:'); Name = 'private'; Expected = $false }
        @{ Lines = @(' pikpak: ', ''); Name = 'pikpak'; Expected = $true }
        @{ Lines = @('PikPak:'); Name = 'pikpak'; Expected = $false }
        @{ Lines = @('pikpak-dav:'); Name = 'pikpak'; Expected = $false }
        @{ Lines = @(); Name = 'pikpak'; Expected = $false }
    ) {
        param($Lines, $Name, $Expected)
        Test-RemoteListed -Listing $Lines -Name $Name | Should -Be $Expected
    }
}

Describe 'Get-RcloneVersion' {
    It 'reads the version from rclone version output' {
        Get-RcloneVersion -Output @('rclone v1.75.2', '- os/version: Microsoft Windows 11 Pro') | Should -BeExactly 'v1.75.2'
    }
    It 'returns $null for unrecognised output' {
        Get-RcloneVersion -Output @('something else') | Should -BeNullOrEmpty
        Get-RcloneVersion -Output @() | Should -BeNullOrEmpty
    }
}

Describe 'Test-SavedConfirmation' {
    It '<Answer> -> <Expected>' -TestCases @(
        @{ Answer = 'SAVED'; Expected = $true }
        @{ Answer = 'saved'; Expected = $false }
        @{ Answer = ' SAVED'; Expected = $false }
        @{ Answer = ''; Expected = $false }
        @{ Answer = $null; Expected = $false }
    ) {
        param($Answer, $Expected)
        Test-SavedConfirmation -Answer $Answer | Should -Be $Expected
    }
}

Describe 'ConvertTo-PlainText' {
    It 'round-trips a SecureString' {
        $plain = 'Nh{0}c p@ss' -f [char]0x1EA1
        $s = ConvertTo-SecureString -String $plain -AsPlainText -Force
        ConvertTo-PlainText -Secure $s | Should -BeExactly $plain
    }
}

Describe 'Test-NativeArgumentSafe (M3)' {
    It '<Desc> -> <Expected>' -TestCases @(
        @{ Desc = 'plain'; Value = 'Secret123'; Expected = $true }
        @{ Desc = 'spaces and symbols'; Value = "p w'd!@#$%"; Expected = $true }
        @{ Desc = 'backslash inside'; Value = 'a\b'; Expected = $true }
        @{ Desc = 'double quote'; Value = 'pa"ss'; Expected = $false }
        @{ Desc = 'trailing backslash'; Value = 'pass\'; Expected = $false }
        @{ Desc = 'only a backslash'; Value = '\'; Expected = $false }
    ) {
        param($Desc, $Value, $Expected)
        Test-NativeArgumentSafe -Value $Value | Should -Be $Expected
    }

    It 'the refusal message is the agreed text' {
        Get-UnsafePasswordMessage | Should -BeExactly 'This password contains a double quote or ends with a backslash, which Windows PowerShell 5.1 cannot pass to rclone safely. Change your PikPak password (or create it without those characters) and run the installer again.'
    }
}

Describe 'Get-RcloneDownloadSpec (F3)' {
    It 'pins the official rclone.org download' {
        $s = Get-RcloneDownloadSpec
        $s.Url | Should -BeExactly 'https://downloads.rclone.org/v1.75.2/rclone-v1.75.2-windows-amd64.zip'
        $s.Sha256 | Should -BeExactly '8a9db2bad1dc79a65b3348fd857069598e2aab7cf4d118b77b1df23055aff818'
        $s.ExeInZip | Should -BeExactly 'rclone-v1.75.2-windows-amd64\rclone.exe'
        $s.InstallDir | Should -BeExactly (Join-Path $env:LOCALAPPDATA 'Programs\rclone')
    }
}

Describe 'Add-DirToPathString (F3)' {
    It 'appends a missing directory' {
        Add-DirToPathString -PathValue 'C:\a;C:\b' -Dir 'C:\rc' | Should -BeExactly 'C:\a;C:\b;C:\rc'
    }
    It 'returns the value unchanged when the directory is already there (case and trailing slash ignored)' {
        Add-DirToPathString -PathValue 'C:\a;c:\RC\' -Dir 'C:\rc' | Should -BeExactly 'C:\a;c:\RC\'
    }
    It 'handles an empty PATH' {
        Add-DirToPathString -PathValue '' -Dir 'C:\rc' | Should -BeExactly 'C:\rc'
        Add-DirToPathString -PathValue $null -Dir 'C:\rc' | Should -BeExactly 'C:\rc'
    }
}

Describe 'Recovery key' {
    It 'New-RecoveryKey is 30 chars from the no-look-alike alphabet' {
        $k = New-RecoveryKey
        $k | Should -Match '^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{30}$'
        $k -cmatch '^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{30}$' | Should -BeTrue
        (New-RecoveryKey) | Should -Not -BeExactly $k
    }

    It 'ConvertTo-RecoveryKey accepts grouped lower-case input and rejects bad characters' {
        ConvertTo-RecoveryKey -Text '7hqx2 mpd4t-w9kzr c3vne 6bjya fu8ts' | Should -BeExactly '7HQX2MPD4TW9KZRC3VNE6BJYAFU8TS'
        ConvertTo-RecoveryKey -Text '7HQX2MPD4TW9KZRC3VNE6BJYAFU8TO' | Should -BeNullOrEmpty
        ConvertTo-RecoveryKey -Text '7HQX2MPD4TW9KZRC3VNE6BJYAFU8T' | Should -BeNullOrEmpty
        ConvertTo-RecoveryKey -Text '7HQX2MPD4TW9KZRC3VNE6BJYAFU8TSA' | Should -BeNullOrEmpty
    }

    It 'ConvertTo-CryptPassword (Install.ps1 option a) uses a typed recovery key in its normal form' {
        ConvertTo-CryptPassword -Text '7hqx2 mpd4t-w9kzr c3vne 6bjya fu8ts' | Should -BeExactly '7HQX2MPD4TW9KZRC3VNE6BJYAFU8TS'
        ConvertTo-CryptPassword -Text '7HQX2MPD4TW9KZRC3VNE6BJYAFU8TS' | Should -BeExactly '7HQX2MPD4TW9KZRC3VNE6BJYAFU8TS'
    }

    It 'ConvertTo-CryptPassword keeps anything else exactly as typed (the older 32-character password)' {
        ConvertTo-CryptPassword -Text 'aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF' | Should -BeExactly 'aB3dE6gH9jK2mN5pQ8sT1vW4yZ7bC0eF'
        ConvertTo-CryptPassword -Text ' my old pass-word ' | Should -BeExactly ' my old pass-word '
    }
}
