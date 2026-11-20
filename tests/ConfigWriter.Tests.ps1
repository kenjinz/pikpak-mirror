BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')
    $script:Shipped = Join-Path $PSScriptRoot '..\config\mirror.config.sample.psd1'

    function Compare-Value {
        param($A, $B)
        if ($A -is [hashtable]) {
            if ($B -isnot [hashtable] -or $A.Count -ne $B.Count) { return $false }
            foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or -not (Compare-Value $A[$k] $B[$k])) { return $false } }
            return $true
        }
        if ($A -is [array]) {
            if ($B -isnot [array] -or $A.Count -ne $B.Count) { return $false }
            for ($i = 0; $i -lt $A.Count; $i++) { if (-not (Compare-Value $A[$i] $B[$i])) { return $false } }
            return $true
        }
        return ($A -ceq $B) -and ($A.GetType() -eq $B.GetType())
    }
}

Describe 'ConfigWriter' {
    It 'round-trips the shipped config: text -> file -> Get-RawMirrorConfig equals the input' {
        $raw = Get-RawMirrorConfig -Path $script:Shipped
        $out = Join-Path $TestDrive 'rt.psd1'
        [IO.File]::WriteAllText($out, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
        $back = Get-RawMirrorConfig -Path $out
        $back.Keys.Count | Should -Be $raw.Keys.Count
        foreach ($k in $raw.Keys) { (Compare-Value $raw[$k] $back[$k]) | Should -BeTrue -Because "key $k" }
    }

    It 'writes keys in the fixed order with the header' {
        $raw = Get-RawMirrorConfig -Path $script:Shipped
        $raw['Zeta'] = 1; $raw['Alpha'] = 2
        $text = ConvertTo-MirrorConfigText -Config $raw
        $text | Should -Match '^# Managed by the PikPak Sync app\.'
        $names = [regex]::Matches($text, '(?m)^    (\w+) = ') | ForEach-Object { $_.Groups[1].Value }
        $names[0] | Should -Be 'Remote'
        $names.IndexOf('SyncTime') | Should -BeLessThan $names.IndexOf('PrivatePaths')
        $names.IndexOf('SyncIntervalMinutes') | Should -Be ($names.IndexOf('SyncTime') + 1)
        $names.IndexOf('Pairs') | Should -BeLessThan $names.IndexOf('Alpha')
        $names.IndexOf('Alpha') | Should -BeLessThan $names.IndexOf('Zeta')
    }

    It 'drops the removed keys when the config is written' {
        $raw = Get-RawMirrorConfig -Path $script:Shipped
        $raw['ArchiveRoot'] = 'Archive'; $raw['CacheDir'] = 'D:\.pikpak-cache'; $raw['WatchRoots'] = @('D:\'); $raw['IgnoredFolders'] = @('Game')
        $text = ConvertTo-MirrorConfigText -Config $raw
        $text | Should -Not -Match 'ArchiveRoot|CacheDir|WatchRoots|IgnoredFolders'
    }

    It 'keeps apostrophes, spaces and non-ASCII names' {
        $raw = Get-RawMirrorConfig -Path $script:Shipped
        $local = "D:\Nh$([char]0x1EA1)c"
        $name = "O'Brien's music"
        $odd = "It$([char]0x2019)s $([char]0x2018)x$([char]0x2019)"
        $raw['Pairs'] = @($raw['Pairs']) + @(@{ Name = $name; Local = $local; Remote = 'D/Nh c'; Priority = 3 }, @{ Name = $odd; Local = 'D:\Odd'; Remote = 'D/Odd'; Priority = 2 })
        $out = Join-Path $TestDrive 'odd.psd1'
        [IO.File]::WriteAllText($out, (ConvertTo-MirrorConfigText -Config $raw), (New-Object Text.UTF8Encoding $true))
        $back = Get-RawMirrorConfig -Path $out
        $p = @($back['Pairs'] | Where-Object { $_.Name -ceq $name })
        $p.Count | Should -Be 1
        $p[0].Local | Should -BeExactly $local
        @($back['Pairs'] | Where-Object { $_.Name -ceq $odd }).Count | Should -Be 1
    }

    It 'Save-MirrorConfig refuses an overlapping pair and leaves the file untouched' {
        $dir = Join-Path $TestDrive 'ov'; New-Item -ItemType Directory -Path $dir | Out-Null
        $path = Join-Path $dir 'mirror.config.psd1'
        $raw = Get-RawMirrorConfig -Path $script:Shipped
        $raw['Pairs'] = @(@{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 2 })
        (Save-MirrorConfig -Path $path -Config $raw).Count | Should -Be 0
        $before = (Get-FileHash -LiteralPath $path).Hash
        Remove-Item -LiteralPath "$path.bak" -ErrorAction SilentlyContinue
        $raw['Pairs'] = @($raw['Pairs']) + @(@{ Name = 'Live'; Local = 'D:\Music\Live'; Remote = 'D/Live'; Priority = 3 })
        $errs = @(Save-MirrorConfig -Path $path -Config $raw)
        ($errs -join "`n") | Should -Match 'overlap'
        (Get-FileHash -LiteralPath $path).Hash | Should -Be $before
        Test-Path -LiteralPath "$path.bak" | Should -BeFalse
        Test-Path -LiteralPath "$path.tmp" | Should -BeFalse
    }

    It 'Save-MirrorConfig keeps .bak and writes .original only once' {
        $dir = Join-Path $TestDrive 'bak'; New-Item -ItemType Directory -Path $dir | Out-Null
        $path = Join-Path $dir 'mirror.config.psd1'
        Copy-Item -LiteralPath $script:Shipped -Destination $path
        $shippedText = [IO.File]::ReadAllText($path)
        $raw = Get-RawMirrorConfig -Path $path
        $raw['HoldingDays'] = 31
        @(Save-MirrorConfig -Path $path -Config $raw).Count | Should -Be 0
        $orig = Join-Path $dir 'mirror.config.original.psd1'
        [IO.File]::ReadAllText($orig) | Should -BeExactly $shippedText
        [IO.File]::ReadAllText("$path.bak") | Should -BeExactly $shippedText
        (Get-RawMirrorConfig -Path $path)['HoldingDays'] | Should -Be 31
        $raw['HoldingDays'] = 32
        @(Save-MirrorConfig -Path $path -Config $raw).Count | Should -Be 0
        [IO.File]::ReadAllText($orig) | Should -BeExactly $shippedText
        (Get-RawMirrorConfig -Path "$path.bak")['HoldingDays'] | Should -Be 31
        (Get-RawMirrorConfig -Path $path)['HoldingDays'] | Should -Be 32
    }

    It 'New-MirrorPair derives C-Users and drive remotes and unique names' {
        $cfg = @{ Pairs = @(@{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 2 }) }
        $a = New-MirrorPair -Path (Join-Path $env:USERPROFILE 'Pictures') -Config $cfg
        $a.Name | Should -Be 'Pictures'
        $a.Remote | Should -Be 'C-Users/Pictures'
        $a.Priority | Should -Be 3
        $b = New-MirrorPair -Path 'D:\Holiday Photos' -Config $cfg
        $b.Remote | Should -Be 'D/Holiday Photos'
        $b.Local | Should -Be 'D:\Holiday Photos'
        (New-MirrorPair -Path 'E:\Other\music' -Config $cfg).Name | Should -Be 'music (2)'
        $cfg.Pairs += @{ Name = 'music (2)'; Local = 'E:\x'; Remote = 'E/x'; Priority = 3 }
        (New-MirrorPair -Path 'F:\MUSIC' -Config $cfg).Name | Should -Be 'MUSIC (3)'
    }

    It 'writes RunBudgetGB as DailyBudgetGB and never writes RunBudgetGB' {
        $raw = Get-RawMirrorConfig -Path $script:Shipped
        $raw.Remove('DailyBudgetGB'); $raw['RunBudgetGB'] = 4
        $text = ConvertTo-MirrorConfigText -Config $raw
        $text | Should -Not -Match 'RunBudgetGB'
        $out = Join-Path $TestDrive 'conv.psd1'
        [IO.File]::WriteAllText($out, $text, (New-Object Text.UTF8Encoding $true))
        (Get-RawMirrorConfig -Path $out).DailyBudgetGB | Should -Be 4
        $raw.ContainsKey('DailyBudgetGB') | Should -BeFalse -Because 'the caller config is not modified'
    }

    It 'keeps DailyBudgetGB over RunBudgetGB and puts it in the budget key position' {
        $raw = Get-RawMirrorConfig -Path $script:Shipped
        $raw['DailyBudgetGB'] = 6; $raw['RunBudgetGB'] = 4
        $text = ConvertTo-MirrorConfigText -Config $raw
        $text | Should -Not -Match 'RunBudgetGB'
        $names = [regex]::Matches($text, '(?m)^    (\w+) = ') | ForEach-Object { $_.Groups[1].Value }
        $names.IndexOf('MaxDeletePercent') + 1 | Should -Be $names.IndexOf('DailyBudgetGB')
        $names.IndexOf('DailyBudgetGB') + 1 | Should -Be $names.IndexOf('MonthlyBudgetGB')
        $out = Join-Path $TestDrive 'conv2.psd1'
        [IO.File]::WriteAllText($out, $text, (New-Object Text.UTF8Encoding $true))
        (Get-RawMirrorConfig -Path $out).DailyBudgetGB | Should -Be 6
    }
}
