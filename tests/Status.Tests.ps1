BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    $script:Now = [datetime]'2026-10-24T13:45:10'
    $script:GB = [long]1073741824

    function New-StatusConfig {
        param([string]$Root, [object[]]$PrivatePaths = @())
        $watch = Join-Path $Root 'watch'
        New-Item -ItemType Directory -Path $watch -Force | Out-Null
        $pairs = @()
        foreach ($n in @(@('Zeta', 2), @('Alpha', 2), @('Beta', 1))) {
            $local = Join-Path $watch $n[0]
            New-Item -ItemType Directory -Path $local -Force | Out-Null
            $pairs += @{ Name = $n[0]; Local = $local; Remote = 'D/' + $n[0]; Priority = $n[1] }
        }
        @{
            StateDir = (Join-Path $Root 'state'); MonthlyBudgetGB = 250; DailyBudgetGB = 8
            PrivatePaths = @($PrivatePaths); Pairs = $pairs
        }
    }
}

Describe 'Get-MirrorStatus' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
    }

    It 'status reports unconfirmed private paths and seeded pairs' {
        $priv = Join-Path $script:root 'secret'
        $cfg = New-StatusConfig -Root $script:root -PrivatePaths @(@{ Path = $priv; Name = 'Secret' })
        $state = New-MirrorState
        $state.PrivateConfirmedHash = 'not-the-right-hash'
        $state.Month = '2026-10'
        $state.LastSuccess = '2026-10-23T10:00:00.0000000'
        $state.Pairs['Alpha'] = @{ Seeded = $true; FilterHash = 'x'; LastExit = 0; LastRun = '2026-10-23T10:00:00' }

        $s = Get-MirrorStatus -Config $cfg -State $state -Now $script:Now
        $s.PrivateConfirmed | Should -BeFalse
        $s.LastSuccess | Should -Be '2026-10-23T10:00:00.0000000'
        $s.Month | Should -Be '2026-10'
        $s.BudgetGB | Should -Be 250
        $alpha = @($s.Pairs | Where-Object { $_.Name -eq 'Alpha' })[0]
        $alpha.Seeded | Should -BeTrue
        $alpha.LastExit | Should -Be 0
        $alpha.LastRun | Should -Be '2026-10-23T10:00:00'
        $alpha.Private | Should -BeFalse
        # three pairs and the encrypted folder
        @($s.Pairs).Count | Should -Be 4
        $sec = @($s.Pairs | Where-Object { $_.Name -eq 'Secret' })[0]
        $sec.Private | Should -BeTrue
        $sec.Seeded | Should -BeFalse

        $state.PrivateConfirmedHash = Get-PrivatePathsHash -Config $cfg
        (Get-MirrorStatus -Config $cfg -State $state -Now $script:Now).PrivateConfirmed | Should -BeTrue
    }

    It 'reports today''s use and the daily budget' {
        $cfg = New-StatusConfig -Root $script:root
        $state = New-MirrorState
        $s0 = Get-MirrorStatus -Config $cfg -State $state -Now $script:Now
        $s0.DayUsedGB | Should -Be 0; $s0.DayBudgetGB | Should -Be 8
        Add-TransferredBytes -State $state -Bytes ([long]($script:GB * 2.34)) -Now $script:Now
        (Get-MirrorStatus -Config $cfg -State $state -Now $script:Now).DayUsedGB | Should -Be 2.3
        (Get-MirrorStatus -Config $cfg -State $state -Now $script:Now.AddDays(1)).DayUsedGB | Should -Be 0
        $cfg.Remove('DailyBudgetGB'); $cfg.RunBudgetGB = 5
        (Get-MirrorStatus -Config $cfg -State $state -Now $script:Now).DayBudgetGB | Should -Be 5
    }

    It 'UsedGB rounds to 0.1' {
        $cfg = New-StatusConfig -Root $script:root
        $state = New-MirrorState
        $state.Month = '2026-10'
        $state.TransferredBytes = [long]($script:GB * 12.34)
        (Get-MirrorStatus -Config $cfg -State $state -Now $script:Now).UsedGB | Should -Be 12.3
        $state.TransferredBytes = [long]($script:GB * 12.36)
        (Get-MirrorStatus -Config $cfg -State $state -Now $script:Now).UsedGB | Should -Be 12.4
    }

    It 'UsedGB is 0 after month rollover' {
        $cfg = New-StatusConfig -Root $script:root
        $state = New-MirrorState
        $state.Month = '2026-09'
        $state.TransferredBytes = [long]($script:GB * 100)
        (Get-MirrorStatus -Config $cfg -State $state -Now $script:Now).UsedGB | Should -Be 0
    }

    It 'pairs absent from state show Seeded false' {
        $cfg = New-StatusConfig -Root $script:root
        $s = Get-MirrorStatus -Config $cfg -State (New-MirrorState) -Now $script:Now
        foreach ($p in @($s.Pairs)) {
            $p.Seeded | Should -BeFalse
            $p.LastExit | Should -BeNullOrEmpty
            $p.LastRun | Should -BeNullOrEmpty
        }
        $s.PrivateConfirmed | Should -BeFalse
    }

    It 'pairs are sorted by Priority then Name' {
        $cfg = New-StatusConfig -Root $script:root
        $s = Get-MirrorStatus -Config $cfg -State (New-MirrorState) -Now $script:Now
        (@($s.Pairs) | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Beta,Alpha,Zeta'
    }

    It 'reads an encrypted folder from its own state key, not from a pair of the same name' {
        $cfg = New-StatusConfig -Root $script:root -PrivatePaths @(@{ Path = (Join-Path $script:root 'secret'); Name = 'Alpha' })
        $state = New-MirrorState
        $state.Pairs['Alpha'] = @{ Seeded = $true; LastExit = 0; LastRun = 'pair-run' }
        $state.Pairs['private:Alpha'] = @{ Seeded = $false; LastExit = 1; LastRun = 'enc-run' }
        $s = Get-MirrorStatus -Config $cfg -State $state -Now $script:Now
        (@($s.Pairs) | ForEach-Object { $_.Name }) -join ',' | Should -Be 'Alpha,Beta,Alpha,Zeta'
        $enc = @($s.Pairs | Where-Object { $_.Name -eq 'Alpha' -and $_.Private })[0]
        $pair = @($s.Pairs | Where-Object { $_.Name -eq 'Alpha' -and -not $_.Private })[0]
        $enc.Seeded | Should -BeFalse; $enc.LastExit | Should -Be 1; $enc.LastRun | Should -Be 'enc-run'; $enc.Priority | Should -Be 0
        $pair.Seeded | Should -BeTrue; $pair.LastExit | Should -Be 0; $pair.LastRun | Should -Be 'pair-run'
    }

    It 'has no Unmapped property' {
        $cfg = New-StatusConfig -Root $script:root
        $s = Get-MirrorStatus -Config $cfg -State (New-MirrorState) -Now $script:Now
        $s.PSObject.Properties.Name | Should -Not -Contain 'Unmapped'
    }

    It 'does not write to the state directory' {
        $cfg = New-StatusConfig -Root $script:root
        [void](Get-MirrorStatus -Config $cfg -State (New-MirrorState) -Now $script:Now)
        Test-Path -LiteralPath $cfg.StateDir | Should -BeFalse
    }
}

Describe 'Get-PrivatePathReport' {
    It 'reports existence, size and the pairs that exclude each private path' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $cfg = New-StatusConfig -Root $root
        $alphaLocal = (@($cfg.Pairs | Where-Object { $_.Name -eq 'Alpha' }))[0].Local
        $priv = Join-Path $alphaLocal 'Secret'
        New-Item -ItemType Directory -Path $priv -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $priv 'a.bin'), (New-Object byte[] 1000))
        $cfg.PrivatePaths = @(@{ Path = $priv; Name = 'Secret' }, @{ Path = (Join-Path $root 'nowhere'); Name = 'Gone' })

        $r = @(Get-PrivatePathReport -Config $cfg)
        $r.Count | Should -Be 2
        $r[0].Exists | Should -BeTrue
        $r[0].SizeGB | Should -Be 0
        @($r[0].ExcludedBy).Count | Should -Be 1
        $r[0].ExcludedBy[0].Name | Should -Be 'Alpha'
        $r[0].ExcludedBy[0].RelPath | Should -Be 'Secret'
        $r[1].Exists | Should -BeFalse
        $r[1].SizeGB | Should -BeNullOrEmpty
        @($r[1].ExcludedBy).Count | Should -Be 0
    }
}

Describe 'Get-PlainCopyCheckResult' {
    BeforeAll { $script:rp = 'pikpak:PC-Mirror/D/Pic/Priv' }

    It 'exit 0 with a listing reports a found plain copy' {
        $r = Get-PlainCopyCheckResult -ExitCode 0 -Listing @('a.txt', 'sub/') -RemotePath $script:rp
        $r.Verified | Should -BeTrue
        $r.Found | Should -BeTrue
        $r.Message | Should -Match 'plain \(unencrypted\) copy already exists'
        $r.Message | Should -Match ([regex]::Escape($script:rp))
    }

    It 'exit 0 with an empty listing is verified clean' {
        $r = Get-PlainCopyCheckResult -ExitCode 0 -Listing @() -RemotePath $script:rp
        $r.Verified | Should -BeTrue
        $r.Found | Should -BeFalse
        $r.Message | Should -Be "no plain copy found at $($script:rp)"
        (Get-PlainCopyCheckResult -ExitCode 0 -Listing @('', '  ') -RemotePath $script:rp).Found | Should -BeFalse
    }

    It 'exit 3 (directory not found) is verified clean' {
        $r = Get-PlainCopyCheckResult -ExitCode 3 -Listing @() -RemotePath $script:rp
        $r.Verified | Should -BeTrue
        $r.Found | Should -BeFalse
        $r.Message | Should -Be "no plain copy found at $($script:rp)"
    }

    It 'other exit codes are unverified' -ForEach @(@{ Code = 1 }, @{ Code = 7 }, @{ Code = -1 }) {
        $r = Get-PlainCopyCheckResult -ExitCode $Code -Listing @() -RemotePath $script:rp
        $r.Verified | Should -BeFalse
        $r.Found | Should -BeFalse
        $r.Message | Should -Match "could not verify $([regex]::Escape($script:rp)) \(rclone exit $Code\)"
        $r.Message | Should -Match 'check your PikPak login/network before typing YES'
    }
}

Describe 'Get-PrivatePathReport remote paths (M1)' {
    It 'builds the plain-copy remote path with Join-RemotePath' {
        $cfg = @{
            Remote = 'pikpak'; MirrorRoot = '/PC-Mirror/'
            PrivatePaths = @(@{ Path = 'D:\Music\A B\C'; Name = 'C' })
            Pairs = @(@{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music/'; Priority = 2 })
        }
        $r = @(Get-PrivatePathReport -Config $cfg)
        $r[0].ExcludedBy[0].RemotePath | Should -BeExactly 'pikpak:PC-Mirror/D/Music/A B/C'
    }
}

Describe 'Save-PrivateConfirmation' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:cfg = New-StatusConfig -Root $script:root -PrivatePaths @(@{ Path = (Join-Path $script:root 'secret'); Name = 'Secret' })
    }

    It 'records the private-paths hash in state' {
        Save-PrivateConfirmation -Config $script:cfg | Should -BeTrue
        (Get-MirrorState -StateDir $script:cfg.StateDir).PrivateConfirmedHash | Should -Be (Get-PrivatePathsHash -Config $script:cfg)
    }

    It 'keeps other state written by a sync' {
        $s = New-MirrorState
        $s.Month = '2026-10'; $s.TransferredBytes = [long]42
        Save-MirrorState -StateDir $script:cfg.StateDir -State $s
        Save-PrivateConfirmation -Config $script:cfg | Should -BeTrue
        (Get-MirrorState -StateDir $script:cfg.StateDir).TransferredBytes | Should -Be 42
    }

    It 'saves nothing and returns false while a sync holds the lock' {
        $lock = Enter-MirrorLock -StateDir $script:cfg.StateDir
        try { Save-PrivateConfirmation -Config $script:cfg | Should -BeFalse }
        finally { Exit-MirrorLock -Handle $lock }
        Test-Path -LiteralPath (Join-Path $script:cfg.StateDir 'state.json') | Should -BeFalse
    }

    It 'releases the lock afterwards' {
        Save-PrivateConfirmation -Config $script:cfg | Out-Null
        $lock = Enter-MirrorLock -StateDir $script:cfg.StateDir
        try { $lock | Should -Not -BeNullOrEmpty } finally { Exit-MirrorLock -Handle $lock }
    }
}

Describe 'Confirm-PrivatePaths.ps1' {
    It 'parses, takes the sync lock and builds remote paths with Join-RemotePath' {
        $path = Join-Path $PSScriptRoot '..\scripts\Confirm-PrivatePaths.ps1'
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
        $text = [IO.File]::ReadAllText($path)
        $text | Should -Match 'Save-PrivateConfirmation'
        $text | Should -Match 'sync running, try again in a minute'
        $text | Should -Match '\.RemotePath'
        $text | Should -Not -Match "'\{0\}:\{1\}/\{2\}/\{3\}'"
    }
}
