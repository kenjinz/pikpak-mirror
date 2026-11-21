BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')
}

Describe 'ConvertTo-RcloneFilterPath' {
    It 'escapes glob metacharacters' {
        ConvertTo-RcloneFilterPath -RelativePath '[2024] trip\a*b' | Should -Be '/\[2024\] trip/a\*b'
    }

    It 'escapes braces and question marks' {
        ConvertTo-RcloneFilterPath -RelativePath 'x{1}\y?' | Should -Be '/x\{1\}/y\?'
    }

    It 'keeps unicode and parentheses' {
        $rel = "Nh$([char]0x1EA1)c\New folder (3)"
        ConvertTo-RcloneFilterPath -RelativePath $rel | Should -Be "/Nh$([char]0x1EA1)c/New folder (3)"
    }
}

Describe 'New-PairFilterRules' {
    BeforeEach {
        $script:globalFile = Join-Path $TestDrive 'filters.txt'
        Set-Content -LiteralPath $script:globalFile -Value @('# comment', '', '- *.tmp', '   ', '- Thumbs.db') -Encoding UTF8
    }

    It 'adds private exclude relative to pair' {
        $cfg = @{ PrivatePaths = @(@{ Path = 'D:\New folder\Private'; Name = 'p' }) }
        $pair = @{ Name = 'NF'; Local = 'D:\New folder'; Remote = 'D/NF'; Priority = 1 }
        $rules = @(New-PairFilterRules -Config $cfg -Pair $pair -GlobalRulesPath $script:globalFile)
        # private excludes come first: rclone uses the first matching rule
        $rules[0] | Should -Be '- /Private/**'
        $rules[1..2] | Should -Be @('- *.tmp', '- Thumbs.db')
        $rules.Count | Should -Be 3
    }

    It 'puts every private exclude before the global rules, even before a global include' {
        Set-Content -LiteralPath $script:globalFile -Value @('+ *.jpg', '- *.tmp') -Encoding UTF8
        $cfg = @{ PrivatePaths = @(@{ Path = 'D:\NF\A'; Name = 'a' }, @{ Path = 'D:\Other'; Name = 'o' }, @{ Path = 'D:\NF\B\C'; Name = 'c' }) }
        $pair = @{ Name = 'NF'; Local = 'D:\NF'; Remote = 'D/NF'; Priority = 1 }
        $rules = @(New-PairFilterRules -Config $cfg -Pair $pair -GlobalRulesPath $script:globalFile)
        $rules | Should -Be @('- /A/**', '- /B/C/**', '+ *.jpg', '- *.tmp')
    }

    It 'ignores private paths outside the pair' {
        $cfg = @{ PrivatePaths = @(@{ Path = 'D:\Secret'; Name = 's' }) }
        $pair = @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 1 }
        $rules = @(New-PairFilterRules -Config $cfg -Pair $pair -GlobalRulesPath $script:globalFile)
        $rules | Should -Be @('- *.tmp', '- Thumbs.db')
    }

    It 'ignores sibling paths that merely share a name prefix' {
        $cfg = @{ PrivatePaths = @(@{ Path = 'D:\Music2\x'; Name = 's' }) }
        $pair = @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 1 }
        @(New-PairFilterRules -Config $cfg -Pair $pair -GlobalRulesPath $script:globalFile).Count | Should -Be 2
    }

    It 'matches the pair prefix case-insensitively and escapes the relative path' {
        $cfg = @{ PrivatePaths = @(@{ Path = 'd:\music\[Vault]\a'; Name = 's' }) }
        $pair = @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 1 }
        $rules = @(New-PairFilterRules -Config $cfg -Pair $pair -GlobalRulesPath $script:globalFile)
        $rules[0] | Should -Be '- /\[Vault\]/a/**'
    }

    It 'works for a drive-root pair' {
        $cfg = @{ PrivatePaths = @(@{ Path = 'D:\Private'; Name = 'p' }) }
        $pair = @{ Name = 'All'; Local = 'D:\'; Remote = 'D'; Priority = 1 }
        $rules = @(New-PairFilterRules -Config $cfg -Pair $pair -GlobalRulesPath $script:globalFile)
        $rules[0] | Should -Be '- /Private/**'
    }

    It 'skips a private path equal to the pair root' {
        $cfg = @{ PrivatePaths = @(@{ Path = 'D:\Music'; Name = 'p' }) }
        $pair = @{ Name = 'Music'; Local = 'D:\Music'; Remote = 'D/Music'; Priority = 1 }
        @(New-PairFilterRules -Config $cfg -Pair $pair -GlobalRulesPath $script:globalFile).Count | Should -Be 2
    }
}

Describe 'Get-TextHash' {
    It 'is deterministic and matches SHA256 of the lines joined with LF' {
        $sha = [Security.Cryptography.SHA256]::Create()
        $expected = (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("a`nb")) | ForEach-Object { $_.ToString('x2') }) -join '')
        Get-TextHash -Lines @('a', 'b') | Should -Be $expected
        Get-TextHash -Lines @('a', 'b') | Should -Be (Get-TextHash -Lines @('a', 'b'))
    }

    It 'differs when lines differ' {
        Get-TextHash -Lines @('a', 'b') | Should -Not -Be (Get-TextHash -Lines @('a', 'c'))
    }
}

Describe 'M2: the global filter rules never exclude the ID files' {
    BeforeAll {
        function ConvertTo-TestGlobRegex {
            # An rclone filter glob as a regex over a slash path (case-insensitive, as bisync runs with --ignore-case):
            # a leading / anchors at the folder root, else the pattern matches the end of the path at any depth.
            param([string]$Glob)
            $anchored = $Glob.StartsWith('/')
            $g = $Glob.TrimStart('/')
            $sb = New-Object System.Text.StringBuilder
            $i = 0
            while ($i -lt $g.Length) {
                $c = $g[$i]
                if ($c -eq '\' -and $i + 1 -lt $g.Length) { [void]$sb.Append([regex]::Escape([string]$g[$i + 1])); $i += 2; continue }
                if ($c -eq '*') {
                    if ($i + 1 -lt $g.Length -and $g[$i + 1] -eq '*') { [void]$sb.Append('.*'); $i += 2; continue }
                    [void]$sb.Append('[^/]*'); $i++; continue
                }
                if ($c -eq '?') { [void]$sb.Append('[^/]'); $i++; continue }
                if ($c -eq '{') { [void]$sb.Append('(?:'); $i++; continue }
                if ($c -eq '}') { [void]$sb.Append(')'); $i++; continue }
                if ($c -eq ',') { [void]$sb.Append('|'); $i++; continue }
                if ($c -eq '[') { $j = $g.IndexOf(']', $i); [void]$sb.Append($g.Substring($i, $j - $i + 1)); $i = $j + 1; continue }
                [void]$sb.Append([regex]::Escape([string]$c)); $i++
            }
            $head = '(^|/)'
            if ($anchored) { $head = '^' }
            '(?i)' + $head + $sb.ToString() + '$'
        }
        $script:shipped = (Resolve-Path (Join-Path $PSScriptRoot '..\config\filters.txt')).ProviderPath
    }

    It 'the converter itself catches an exclude that would hit an ID file' {
        '.pikpak-sync.json' | Should -Match (ConvertTo-TestGlobRegex '.pikpak-*')
        'a/b/.pikpak-encrypted.json' | Should -Match (ConvertTo-TestGlobRegex '*.json')
        '.pikpak-sync.json' | Should -Not -Match (ConvertTo-TestGlobRegex '*.tmp')
    }

    It 'no exclude rule of config\filters.txt matches .pikpak-sync.json or .pikpak-encrypted.json' {
        $rules = @(Get-GlobalFilterRules -GlobalRulesPath $script:shipped)
        $rules.Count | Should -BeGreaterThan 0
        foreach ($rule in $rules) {
            if (-not $rule.StartsWith('- ')) { continue }
            $rx = ConvertTo-TestGlobRegex $rule.Substring(2).Trim()
            foreach ($name in '.pikpak-sync.json', '.pikpak-encrypted.json') {
                foreach ($path in $name, ('Sub/' + $name), ('a/b/' + $name)) {
                    $path | Should -Not -Match $rx -Because ("rule '{0}' must not exclude {1}" -f $rule, $path)
                }
            }
        }
    }

    It 'no exclude rule of config\filters.txt matches the folder list backup files' {
        $rules = @(Get-GlobalFilterRules -GlobalRulesPath $script:shipped)
        foreach ($rule in $rules) {
            if (-not $rule.StartsWith('- ')) { continue }
            $rx = ConvertTo-TestGlobRegex $rule.Substring(2).Trim()
            foreach ($name in '.pikpak-sync-backup.json', '.pikpak-sync-encrypted.json') {
                foreach ($path in $name, ('Sub/' + $name)) {
                    $path | Should -Not -Match $rx -Because ("rule '{0}' must not exclude {1}" -f $rule, $path)
                }
            }
        }
    }
}
