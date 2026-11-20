BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')
}

Describe 'Get-TransferredBytesFromLog' {
    It 'reads bytes from last stats line' {
        $f = Join-Path $TestDrive 'stats.log'
        $lines = @(
            '{"level":"notice","msg":"start","time":"2026-10-24T10:00:00"}',
            '{"level":"notice","msg":"stats","stats":{"bytes":100}}',
            'not json at all',
            '{"level":"notice","msg":"stats","stats":{"bytes":2500}}',
            '{"level":"notice","msg":"done"}'
        )
        [IO.File]::WriteAllLines($f, $lines, (New-Object Text.UTF8Encoding $false))
        $b = Get-TransferredBytesFromLog -Path $f
        $b | Should -Be 2500
        $b | Should -BeOfType [long]
    }
    It 'returns 0 for a missing file' {
        Get-TransferredBytesFromLog -Path (Join-Path $TestDrive 'nope.log') | Should -Be 0
    }
    It 'returns 0 when no line has stats' {
        $f = Join-Path $TestDrive 'nostats.log'
        [IO.File]::WriteAllLines($f, @('{"msg":"x"}', 'junk'), (New-Object Text.UTF8Encoding $false))
        Get-TransferredBytesFromLog -Path $f | Should -Be 0
    }
    It 'sums Copied lines when the run was interrupted (no stats line)' {
        $f = Join-Path $TestDrive 'copied-only.log'
        $lines = @(
            '{"time":"2026-10-24T10:00:00","level":"info","msg":"Copied (new)","size":24,"object":"docs/x.txt","objectType":"*pikpak.Object","source":"s"}',
            'junk',
            '{"time":"2026-10-24T10:00:05","level":"info","msg":"Copied (replaced existing)","size":1000,"object":"docs/y.txt","objectType":"*pikpak.Object","source":"s"}',
            '{"time":"2026-10-24T10:00:06","level":"info","msg":"Updated modification time in destination","size":999,"object":"z"}'
        )
        [IO.File]::WriteAllLines($f, $lines, (New-Object Text.UTF8Encoding $false))
        $b = Get-TransferredBytesFromLog -Path $f
        $b | Should -Be 1024
        $b | Should -BeOfType [long]
    }
    It 'uses the final stats when there are no Copied lines' {
        $f = Join-Path $TestDrive 'stats-only.log'
        [IO.File]::WriteAllLines($f, @('{"level":"notice","msg":"stats","stats":{"bytes":5000}}'), (New-Object Text.UTF8Encoding $false))
        Get-TransferredBytesFromLog -Path $f | Should -Be 5000
    }
    It 'takes the larger of last stats and the Copied sum' {
        $f = Join-Path $TestDrive 'both.log'
        $stats = '{"level":"notice","msg":"stats","stats":{"bytes":%d}}'
        $copied = '{"level":"info","msg":"Copied (new)","size":%d,"object":"a"}'
        [IO.File]::WriteAllLines($f, @(($copied -replace '%d', '300'), ($copied -replace '%d', '400'), ($stats -replace '%d', '100')), (New-Object Text.UTF8Encoding $false))
        Get-TransferredBytesFromLog -Path $f | Should -Be 700
        [IO.File]::WriteAllLines($f, @(($copied -replace '%d', '300'), ($stats -replace '%d', '9000')), (New-Object Text.UTF8Encoding $false))
        Get-TransferredBytesFromLog -Path $f | Should -Be 9000
    }
    It 'excludes server-side copies from the Copied sum' {
        $f = Join-Path $TestDrive 'serverside.log'
        $lines = @(
            '{"level":"info","msg":"Copied (server-side copy)","size":5000,"object":"a"}',
            '{"level":"info","msg":"Copied (new) (server-side copy)","size":6000,"object":"b"}',
            '{"level":"info","msg":"Copied (new)","size":7,"object":"c"}'
        )
        [IO.File]::WriteAllLines($f, $lines, (New-Object Text.UTF8Encoding $false))
        Get-TransferredBytesFromLog -Path $f | Should -Be 7
    }
    It 'returns 0 for an empty file' {
        $f = Join-Path $TestDrive 'empty.log'
        [IO.File]::WriteAllText($f, '')
        Get-TransferredBytesFromLog -Path $f | Should -Be 0
    }
}

Describe 'Clear-StaleBisyncLocks' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ('st' + [guid]::NewGuid().ToString('N'))
        $script:cfg = @{ StateDir = $script:dir }
        $script:bis = Join-Path $script:dir 'bisync'
    }
    It 'removes only *.lck files and logs one line per file' {
        New-Item -ItemType Directory -Path $script:bis -Force | Out-Null
        foreach ($n in 'D__a..pikpak_x.lck', 'D__b..pikpak_y.lck', 'D__a..pikpak_x.path1.lst', 'D__a..pikpak_x.path2.lst-new') {
            [IO.File]::WriteAllText((Join-Path $script:bis $n), 'x')
        }
        $removed = @(Clear-StaleBisyncLocks -Config $script:cfg)
        $removed.Count | Should -Be 2
        $removed | Should -Contain 'D__a..pikpak_x.lck'
        $removed | Should -Contain 'D__b..pikpak_y.lck'
        @(Get-ChildItem -LiteralPath $script:bis -Filter *.lck).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $script:bis).Count | Should -Be 2
        $log = [IO.File]::ReadAllText((Join-Path $script:dir ('logs\' + (Get-Date).ToString('yyyy-MM-dd') + '.log')))
        $log | Should -Match 'Removed stale bisync lock D__a\.\.pikpak_x\.lck \(previous run was interrupted\)'
        $log | Should -Match 'Removed stale bisync lock D__b\.\.pikpak_y\.lck \(previous run was interrupted\)'
    }
    It 'leaves files whose extension only starts with .lck' {
        New-Item -ItemType Directory -Path $script:bis -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:bis 'a.lckx'), 'x')
        @(Clear-StaleBisyncLocks -Config $script:cfg).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:bis 'a.lckx') | Should -BeTrue
    }
    It 'logs and skips a lock that cannot be removed' {
        New-Item -ItemType Directory -Path $script:bis -Force | Out-Null
        $p = Join-Path $script:bis 'busy.lck'
        [IO.File]::WriteAllText($p, 'x')
        $hold = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None')
        try {
            @(Clear-StaleBisyncLocks -Config $script:cfg).Count | Should -Be 0
        } finally { $hold.Close() }
        Test-Path -LiteralPath $p | Should -BeTrue
        $log = [IO.File]::ReadAllText((Join-Path $script:dir ('logs\' + (Get-Date).ToString('yyyy-MM-dd') + '.log')))
        $log | Should -Match 'Could not remove stale bisync lock busy\.lck'
    }
    It 'is a no-op when the bisync directory does not exist' {
        @(Clear-StaleBisyncLocks -Config $script:cfg).Count | Should -Be 0
        Test-Path -LiteralPath $script:bis | Should -BeFalse
    }
    It 'does not recurse into subfolders' {
        New-Item -ItemType Directory -Path (Join-Path $script:bis 'sub') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:bis 'sub\keep.lck'), 'x')
        @(Clear-StaleBisyncLocks -Config $script:cfg).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:bis 'sub\keep.lck') | Should -BeTrue
    }
}

Describe 'Enter-MirrorLock / Exit-MirrorLock' {
    It 'second lock attempt fails while first held' {
        $dir = Join-Path $TestDrive 'lockstate'
        $h1 = Enter-MirrorLock -StateDir $dir
        try {
            $h1 | Should -Not -BeNullOrEmpty
            $h2 = Enter-MirrorLock -StateDir $dir
            $h2 | Should -BeNullOrEmpty
        } finally {
            Exit-MirrorLock -Handle $h1
        }
        $h3 = Enter-MirrorLock -StateDir $dir
        try { $h3 | Should -Not -BeNullOrEmpty } finally { Exit-MirrorLock -Handle $h3 }
    }
}

Describe 'Test-SyncRunning' {
    It 'is true when a process command line runs Invoke-Sync.ps1' {
        Mock Get-CimInstance { @([pscustomobject]@{ ProcessId = 999999; CommandLine = 'conhost.exe --headless powershell.exe -NoProfile -File "G:\r\scripts\Invoke-Sync.ps1" -ConfigPath "x"' }) }
        Test-SyncRunning -StateDir (Join-Path $TestDrive 'tsr') | Should -BeTrue
        Should -Invoke Get-CimInstance -Times 1 -Exactly -ParameterFilter { $ClassName -eq 'Win32_Process' }
    }
    It 'is false when no such process runs, and ignores this process' {
        Mock Get-CimInstance { @([pscustomobject]@{ ProcessId = $PID; CommandLine = 'powershell.exe Invoke-Sync.ps1' }, [pscustomobject]@{ ProcessId = 999998; CommandLine = 'notepad.exe' }) }
        Test-SyncRunning -StateDir (Join-Path $TestDrive 'tsr') | Should -BeFalse
    }
    It 'never opens sync.lock (a held lock does not matter, a missing one is not created)' {
        Mock Get-CimInstance { @() }
        $dir = Join-Path $TestDrive 'tsr2'
        Test-SyncRunning -StateDir $dir | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'sync.lock') | Should -BeFalse
        $h = Enter-MirrorLock -StateDir $dir
        try { Test-SyncRunning -StateDir $dir | Should -BeFalse } finally { Exit-MirrorLock -Handle $h }
    }
    It 'is false when the process list cannot be read' {
        Mock Get-CimInstance { throw 'WMI down' }
        Test-SyncRunning -StateDir (Join-Path $TestDrive 'tsr') | Should -BeFalse
    }
}

Describe 'Remove-OldLogs' {
    It 'deletes logs older than 60 days' {
        $dir = Join-Path $TestDrive 'logstate'
        $logs = Join-Path $dir 'logs'
        New-Item -ItemType Directory -Path (Join-Path $logs 'sub') -Force | Out-Null
        $old = Join-Path $logs 'old.log'
        $oldSub = Join-Path $logs 'sub\old2.log'
        $new = Join-Path $logs 'new.log'
        foreach ($p in @($old, $oldSub, $new)) { Set-Content -LiteralPath $p -Value 'x' }
        $now = [datetime]'2026-10-24T12:00:00'
        (Get-Item -LiteralPath $old).LastWriteTime = $now.AddDays(-61)
        (Get-Item -LiteralPath $oldSub).LastWriteTime = $now.AddDays(-90)
        (Get-Item -LiteralPath $new).LastWriteTime = $now.AddDays(-5)
        Remove-OldLogs -Config @{ StateDir = $dir; LogKeepDays = 60 } -Now $now
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $oldSub | Should -BeFalse
        Test-Path -LiteralPath $new | Should -BeTrue
    }
    It 'does not throw when the logs dir is missing' {
        { Remove-OldLogs -Config @{ StateDir = (Join-Path $TestDrive 'nologs'); LogKeepDays = 60 } -Now (Get-Date) } | Should -Not -Throw
    }
}

Describe 'Write-MirrorLog' {
    It 'appends timestamped UTF-8 lines without BOM' {
        $dir = Join-Path $TestDrive 'wl'
        $cfg = @{ StateDir = $dir }
        Write-MirrorLog -Config $cfg -Message 'hello Nhạc'
        Write-MirrorLog -Config $cfg -Message 'second'
        $file = [IO.Path]::Combine($dir, 'logs', ((Get-Date).ToString('yyyy-MM-dd') + '.log'))
        Test-Path -LiteralPath $file | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($file)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        $lines = [IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} hello Nhạc$'
    }
}

Describe 'Send-MirrorToast' {
    It 'does not throw and logs when the WinRT helper fails (Config given)' {
        Mock Show-MirrorToastNative { throw 'winrt boom' }
        $dir = Join-Path $TestDrive 'toastlog'
        { Send-MirrorToast -Title 't' -Message 'm' -Config @{ StateDir = $dir } } | Should -Not -Throw
        $file = [IO.Path]::Combine($dir, 'logs', ((Get-Date).ToString('yyyy-MM-dd') + '.log'))
        (Get-Content -LiteralPath $file -Raw) | Should -Match 'toast failed: .*winrt boom'
    }
    It 'writes every notification to the daily log first (Config given)' {
        Mock Show-MirrorToastNative { }
        $dir = Join-Path $TestDrive 'notifylog'
        Send-MirrorToast -Title 't' -Message 'Folder missing, skipped: X' -Config @{ StateDir = $dir }
        $file = [IO.Path]::Combine($dir, 'logs', ((Get-Date).ToString('yyyy-MM-dd') + '.log'))
        (Get-Content -LiteralPath $file -Raw) | Should -Match 'Notify: Folder missing, skipped: X'
        Should -Invoke Show-MirrorToastNative -Times 1
    }
    It 'still shows the toast when logging fails' {
        Mock Show-MirrorToastNative { }
        Mock Write-MirrorLog { throw 'disk full' }
        { Send-MirrorToast -Title 't' -Message 'm' -Config @{ StateDir = 'x' } } | Should -Not -Throw
        Should -Invoke Show-MirrorToastNative -Times 1
    }
    It 'does not log when no Config is given' {
        Mock Show-MirrorToastNative { }
        Mock Write-MirrorLog { }
        Send-MirrorToast -Title 't' -Message 'm'
        Should -Invoke Write-MirrorLog -Times 0
    }
    It 'warns instead of throwing when no Config is given' {
        Mock Show-MirrorToastNative { throw 'winrt boom' }
        { Send-MirrorToast -Title 't' -Message 'm' -WarningAction SilentlyContinue } | Should -Not -Throw
        $w = Send-MirrorToast -Title 't' -Message 'm' 3>&1
        ($w | Out-String) | Should -Match 'toast failed'
    }
}

Describe 'Invoke-Rclone' {
    It 'returns exit code, bytes, log path and resync flag' {
        $log = Join-Path $TestDrive 'rc\run.log'
        function rclone {
            # fake rclone: write a JSON stats line + resync message, exit 7
            $i = [array]::IndexOf($args, '--log-file')
            $p = $args[$i + 1]
            [IO.File]::WriteAllLines($p, @(
                '{"msg":"stats","stats":{"bytes":4242}}',
                '{"level":"error","msg":"Bisync aborted. Must run --resync to recover."}'),
                (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 7
        }
        $r = Invoke-Rclone -Arguments @('bisync', 'a', 'b', '--log-file', $log)
        $r.ExitCode | Should -Be 7
        $r.Bytes | Should -Be 4242
        $r.LogFile | Should -Be $log
        $r.NeedsResync | Should -BeTrue
    }
    It 'reports an empty Path2 listing (and sets NeedsResync from the same log)' {
        $log = Join-Path $TestDrive 'rc2\run.log'
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @(
                '{"level":"error","msg":"Bisync critical error: empty current Path2 listing. Cannot sync to an empty directory"}',
                '{"level":"error","msg":"Bisync aborted. Must run --resync to recover."}'),
                (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 7
        }
        $r = Invoke-Rclone -Arguments @('bisync', 'a', 'b', '--log-file', $log)
        $r.EmptyListing | Should -Be 'Path2'
        $r.NeedsResync | Should -BeTrue
    }
    It 'reports an empty Path1 listing, case-insensitively' {
        $log = Join-Path $TestDrive 'rc3\run.log'
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @('Bisync critical error: Empty Current Path1 Listing.'), (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 7
        }
        (Invoke-Rclone -Arguments @('bisync', 'a', 'b', '--log-file', $log)).EmptyListing | Should -Be 'Path1'
    }
    It 'EmptyListing is null when the log has no such message or there is no log' {
        $log = Join-Path $TestDrive 'rc4\run.log'
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @('all fine'), (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 0
        }
        (Invoke-Rclone -Arguments @('sync', 'a', 'b', '--log-file', $log)).EmptyListing | Should -BeNullOrEmpty
        function rclone { $global:LASTEXITCODE = 0 }
        (Invoke-Rclone -Arguments @('version')).EmptyListing | Should -BeNullOrEmpty
    }
    It 'reports TooManyDeletes when bisync aborts on too many deletes' {
        $log = Join-Path $TestDrive 'rctmd\run.log'
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @(
                '{"level":"error","msg":"Safety abort: too many deletes (>10%, 4 of 10) on Path1 \"D:\\x\""}'),
                (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 7
        }
        (Invoke-Rclone -Arguments @('bisync', 'a', 'b', '--log-file', $log)).TooManyDeletes | Should -BeTrue
    }
    It 'TooManyDeletes is false without the message or without a log' {
        $log = Join-Path $TestDrive 'rctmd2\run.log'
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @('all fine'), (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 0
        }
        (Invoke-Rclone -Arguments @('bisync', 'a', 'b', '--log-file', $log)).TooManyDeletes | Should -BeFalse
        function rclone { $global:LASTEXITCODE = 0 }
        (Invoke-Rclone -Arguments @('version')).TooManyDeletes | Should -BeFalse
    }
    It 'J1: BudgetHit is set when the log says max transfer limit reached (case-insensitive), else false' {
        $log = Join-Path $TestDrive 'rc5\run.log'
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @(
                '{"level":"error","msg":"Max Transfer Limit Reached as set by --max-transfer"}',
                '{"level":"error","msg":"Bisync aborted. Must run --resync to recover."}'),
                (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 7
        }
        $r = Invoke-Rclone -Arguments @('bisync', 'a', 'b', '--log-file', $log)
        $r.BudgetHit | Should -BeTrue
        $r.ExitCode | Should -Be 7
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @('all fine'), (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 0
        }
        (Invoke-Rclone -Arguments @('sync', 'a', 'b', '--log-file', $log)).BudgetHit | Should -BeFalse
        function rclone { $global:LASTEXITCODE = 0 }
        (Invoke-Rclone -Arguments @('version')).BudgetHit | Should -BeFalse
    }
    It 'J2: StuckUploads lists distinct expected names from JSON-escaped and plain quotes' {
        $log = Join-Path $TestDrive 'rc6\run.log'
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @(
                '{"level":"error","msg":"Failed to copy: uploaded file name mismatch: expected \"part1.bin\", got \"part1(1).bin\""}',
                '{"level":"error","msg":"Failed to copy: uploaded file name mismatch: expected \"part1.bin\", got \"part1(2).bin\""}',
                'ERROR : x: Failed to copy: uploaded file name mismatch: expected "My Movie.mkv", got "My Movie(1).mkv"',
                '{"level":"error","msg":"Bisync aborted. Must run --resync to recover."}'),
                (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 7
        }
        $r = Invoke-Rclone -Arguments @('bisync', 'a', 'b', '--log-file', $log)
        @($r.StuckUploads).Count | Should -Be 2
        $r.StuckUploads | Should -Contain 'part1.bin'
        $r.StuckUploads | Should -Contain 'My Movie.mkv'
    }
    It 'J2: StuckUploads is an empty array when there is no such message or no log' {
        $log = Join-Path $TestDrive 'rc7\run.log'
        function rclone {
            $i = [array]::IndexOf($args, '--log-file')
            [IO.File]::WriteAllLines($args[$i + 1], @('all fine'), (New-Object Text.UTF8Encoding $false))
            $global:LASTEXITCODE = 0
        }
        $r = Invoke-Rclone -Arguments @('sync', 'a', 'b', '--log-file', $log)
        @($r.StuckUploads).Count | Should -Be 0
        function rclone { $global:LASTEXITCODE = 0 }
        @((Invoke-Rclone -Arguments @('version')).StuckUploads).Count | Should -Be 0
    }
    It 'handles no --log-file' {
        function rclone { $global:LASTEXITCODE = 0 }
        $r = Invoke-Rclone -Arguments @('version')
        $r.ExitCode | Should -Be 0
        $r.Bytes | Should -Be 0
        $r.NeedsResync | Should -BeFalse
    }
    It 'returns 127 when rclone cannot be found' {
        $oldPath = $env:PATH
        try {
            $env:PATH = $TestDrive
            $r = Invoke-Rclone -Arguments @('version')
        } finally { $env:PATH = $oldPath }
        $r.ExitCode | Should -Be 127
    }
}

Describe 'Send-CrashToastOnce' {
    BeforeEach {
        $script:crashToasts = New-Object System.Collections.Generic.List[string]
        Mock Send-MirrorToast { $script:crashToasts.Add($Message) }
        $script:markerDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:day = [datetime]'2026-10-24T10:00:00'
    }
    It 'F3: the same message twice on one day gives one toast' {
        Send-CrashToastOnce -Message 'Sync failed: boom' -MarkerDir $script:markerDir -Now $script:day | Should -BeTrue
        Send-CrashToastOnce -Message 'Sync failed: boom' -MarkerDir $script:markerDir -Now $script:day.AddHours(5) | Should -BeFalse
        $script:crashToasts.Count | Should -Be 1
    }
    It 'F3: the next day it toasts again' {
        $null = Send-CrashToastOnce -Message 'Sync failed: boom' -MarkerDir $script:markerDir -Now $script:day
        $null = Send-CrashToastOnce -Message 'Sync failed: boom' -MarkerDir $script:markerDir -Now $script:day.AddDays(1)
        $script:crashToasts.Count | Should -Be 2
    }
    It 'F3: a different message on the same day toasts' {
        $null = Send-CrashToastOnce -Message 'Sync failed: boom' -MarkerDir $script:markerDir -Now $script:day
        $null = Send-CrashToastOnce -Message 'Sync failed: other' -MarkerDir $script:markerDir -Now $script:day
        $script:crashToasts.Count | Should -Be 2
    }
    It 'F3: a marker folder that cannot be written never hides the toast or throws' {
        $blocker = Join-Path $TestDrive 'a-file-not-a-folder'
        [IO.File]::WriteAllText($blocker, 'x')
        { Send-CrashToastOnce -Message 'Sync failed: boom' -MarkerDir (Join-Path $blocker 'sub') -Now $script:day } | Should -Not -Throw
        $script:crashToasts.Count | Should -Be 1
    }
    It 'F3: with the config loaded the marker goes under its state folder, without it under LocalAppData' {
        $state = Join-Path $TestDrive 'st'
        $null = Send-CrashToastOnce -Message 'Sync failed: boom' -Config @{ StateDir = $state } -Now $script:day
        @(Get-ChildItem -LiteralPath $state -Filter 'crash-toast-*.txt').Count | Should -Be 1
    }
}
