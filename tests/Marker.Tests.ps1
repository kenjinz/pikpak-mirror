BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\lib\_load.ps1')

    function script:New-TestFolder {
        param([string]$Kind = 'pair', [string]$Local, [string]$Id = (New-FolderId))
        @{ Kind = $Kind; Name = 'Nh' + [char]0x1EA1 + 'c'; Local = $Local; RemotePath = 'PC-Mirror/Nh' + [char]0x1EA1 + 'c'; Id = $Id }
    }
    $script:now = [datetime]'2026-11-20T10:00:00'
}

Describe 'Marker names and ids' {
    It 'maps kinds to file names' {
        Get-FolderMarkerName -Kind 'pair' | Should -Be '.pikpak-sync.json'
        Get-FolderMarkerName -Kind 'private' | Should -Be '.pikpak-encrypted.json'
    }
    It 'makes lower-case ids that validate' {
        $id = New-FolderId
        $id | Should -Be $id.ToLowerInvariant()
        Test-FolderId $id | Should -BeTrue
        Test-FolderId $id.ToUpperInvariant() | Should -BeTrue
        Test-FolderId 'abc' | Should -BeFalse
        Test-FolderId '' | Should -BeFalse
    }
    It 'M5: refuses an id with a trailing newline or text around it' {
        $id = New-FolderId
        Test-FolderId ($id + "`n") | Should -BeFalse
        Test-FolderId ($id + "`r`n") | Should -BeFalse
        Test-FolderId ("x`n" + $id) | Should -BeFalse
    }
}

Describe 'Folder markers' {
    It 'round-trips a marker with non-ASCII and spaces' {
        $dir = Join-Path $TestDrive ('Nh' + [char]0x1EA1 + 'c\New folder')
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $f = New-TestFolder -Local $dir
        Write-FolderMarker -Folder $f -Now $script:now | Should -BeTrue
        $m = Read-FolderMarker -Path $dir
        $m.Id | Should -Be $f.Id
        $m.Kind | Should -Be 'synced'
        $m.Name | Should -Be $f.Name
        $m.PikPak | Should -Be $f.RemotePath
        $m.LastPath | Should -Be $dir
        $m.Updated | Should -Be '2026-11-20'
        $m.FileKind | Should -Be 'pair'
        $bytes = [IO.File]::ReadAllBytes($m.File)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        ((Get-Item -LiteralPath $m.File -Force).Attributes -band [IO.FileAttributes]::Hidden) | Should -Be ([IO.FileAttributes]::Hidden)
    }

    It 'writes keys in the documented order' {
        $t = ConvertTo-MarkerText -Folder (New-TestFolder -Local 'D:\X') -Now $script:now
        $keys = @((ConvertFrom-Json $t).PSObject.Properties.Name)
        $keys -join ',' | Should -Be 'app,version,id,kind,name,pikpak,lastPath,updated'
    }

    It 'returns $null when there is no marker' {
        Read-FolderMarker -Path $TestDrive | Should -BeNullOrEmpty
    }

    It 'reads empty, truncated, non-JSON and bad-id markers as Invalid' {
        $good = ConvertTo-MarkerText -Folder (New-TestFolder -Local 'D:\X') -Now $script:now
        $cases = @(
            '',
            $good.Substring(0, 30),
            'hello world',
            ($good -replace '"id":\s*"[^"]+"', '"id": "not-a-guid"')
        )
        $n = 0
        foreach ($c in $cases) {
            $n++
            $dir = Join-Path $TestDrive "bad$n"
            New-Item -ItemType Directory -Path $dir | Out-Null
            [IO.File]::WriteAllText((Join-Path $dir '.pikpak-sync.json'), $c, (New-Object Text.UTF8Encoding $false))
            $m = Read-FolderMarker -Path $dir
            $m.Invalid | Should -BeTrue
            $m.File | Should -Be (Join-Path $dir '.pikpak-sync.json')
        }
        (ConvertFrom-MarkerText $good).Invalid | Should -BeNullOrEmpty
        (ConvertFrom-MarkerText ($good -replace 'pikpak-mirror', 'other')).Invalid | Should -BeTrue
    }

    It 'prefers the encrypted file when both exist' {
        $dir = Join-Path $TestDrive 'both'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $a = New-TestFolder -Kind 'pair' -Local $dir
        $b = New-TestFolder -Kind 'private' -Local $dir
        [IO.File]::WriteAllText((Join-Path $dir '.pikpak-sync.json'), (ConvertTo-MarkerText -Folder $a -Now $script:now), (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText((Join-Path $dir '.pikpak-encrypted.json'), (ConvertTo-MarkerText -Folder $b -Now $script:now), (New-Object Text.UTF8Encoding $false))
        $m = Read-FolderMarker -Path $dir
        $m.Id | Should -Be $b.Id
        $m.FileKind | Should -Be 'private'
    }

    It 'Write-FolderMarker switches file name with the kind and deletes the other' {
        $dir = Join-Path $TestDrive 'switch'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-TestFolder -Kind 'pair' -Local $dir
        Write-FolderMarker -Folder $f -Now $script:now | Out-Null
        $f.Kind = 'private'
        Write-FolderMarker -Folder $f -Now $script:now | Should -BeTrue
        [IO.File]::Exists((Join-Path $dir '.pikpak-sync.json')) | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir '.pikpak-encrypted.json') | Should -BeTrue
        (Read-FolderMarker -Path $dir).Kind | Should -Be 'encrypted'
    }

    It 'Write-FolderMarker refuses another id without -Force' {
        $dir = Join-Path $TestDrive 'other'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-TestFolder -Local $dir
        Write-FolderMarker -Folder $f -Now $script:now | Out-Null
        $g = New-TestFolder -Local $dir
        { Write-FolderMarker -Folder $g -Now $script:now } | Should -Throw
        (Read-FolderMarker -Path $dir).Id | Should -Be $f.Id
        Write-FolderMarker -Folder $g -Now $script:now -Force | Should -BeTrue
        (Read-FolderMarker -Path $dir).Id | Should -Be $g.Id
    }

    It 'Write-FolderMarker throws when the folder has no Id' {
        $dir = Join-Path $TestDrive 'noid'
        New-Item -ItemType Directory -Path $dir | Out-Null
        { Write-FolderMarker -Folder (New-TestFolder -Local $dir -Id '') -Now $script:now } | Should -Throw
    }

    It 'Write-FolderMarker does not rewrite when only updated differs' {
        $dir = Join-Path $TestDrive 'same'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-TestFolder -Local $dir
        Write-FolderMarker -Folder $f -Now $script:now | Out-Null
        $file = Join-Path $dir '.pikpak-sync.json'
        (Get-Item -LiteralPath $file -Force).LastWriteTime = [datetime]'2020-01-01T00:00:00'
        $before = (Get-Item -LiteralPath $file -Force).LastWriteTime
        Write-FolderMarker -Folder $f -Now $script:now.AddDays(5) | Should -BeFalse
        (Get-Item -LiteralPath $file -Force).LastWriteTime | Should -Be $before
        # a changed field does rewrite
        $f.Name = 'Renamed'
        Write-FolderMarker -Folder $f -Now $script:now.AddDays(5) | Should -BeTrue
        (Read-FolderMarker -Path $dir).Updated | Should -Be '2026-11-25'
    }

    It 'M6: Write-FolderMarker writes through a temp file and leaves none behind' {
        $dir = Join-Path $TestDrive 'atomic'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $f = New-TestFolder -Local $dir
        # a temp file left by an interrupted earlier write is replaced, not a reason to fail
        [IO.File]::WriteAllText((Join-Path $dir '.pikpak-sync.json.tmp'), 'stale', (New-Object Text.UTF8Encoding $false))
        Write-FolderMarker -Folder $f -Now $script:now | Should -BeTrue
        $f.Name = 'Renamed'
        Write-FolderMarker -Folder $f -Now $script:now | Should -BeTrue
        @(Get-ChildItem -LiteralPath $dir -Force | ForEach-Object { $_.Name }) | Should -Be @('.pikpak-sync.json')
        $file = Join-Path $dir '.pikpak-sync.json'
        ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::Hidden) | Should -Be ([IO.FileAttributes]::Hidden)
        $bytes = [IO.File]::ReadAllBytes($file)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
        (Read-FolderMarker -Path $dir).Name | Should -Be 'Renamed'
    }

    It 'C1: Remove-FolderMarkerFile deletes one kind of marker (hidden too) and says whether there was one' {
        $dir = Join-Path $TestDrive 'remove'
        New-Item -ItemType Directory -Path $dir | Out-Null
        $null = Write-FolderMarker -Folder (New-TestFolder -Kind 'private' -Local $dir) -Now $script:now
        Remove-FolderMarkerFile -Path $dir -Kind 'pair' | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir '.pikpak-encrypted.json') | Should -BeTrue
        Remove-FolderMarkerFile -Path $dir -Kind 'private' | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $dir '.pikpak-encrypted.json') | Should -BeFalse
        Remove-FolderMarkerFile -Path $dir -Kind 'private' | Should -BeFalse
    }
}

Describe 'Find-NestedMarkers' {
    It 'lists markers below the top only' {
        $top = Join-Path $TestDrive 'nest'
        $sub = Join-Path $top 'a\b'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Write-FolderMarker -Folder (New-TestFolder -Local $top) -Now $script:now | Out-Null
        $inner = New-TestFolder -Kind 'private' -Local $sub
        Write-FolderMarker -Folder $inner -Now $script:now | Out-Null
        $r = Find-NestedMarkers -Path $top
        $r.Complete | Should -BeTrue
        @($r.Items).Count | Should -Be 1
        $r.Items[0].Path | Should -Be $sub
        $r.Items[0].Marker.Id | Should -Be $inner.Id
    }

    It 'reports incomplete when the time limit is hit' {
        $top = Join-Path $TestDrive 'nest2'
        New-Item -ItemType Directory -Path (Join-Path $top 'x') -Force | Out-Null
        $r = Find-NestedMarkers -Path $top -MaxSeconds 0
        $r.Complete | Should -BeFalse
    }

    It 'reports incomplete when a directory could not be read' {
        $top = Join-Path $TestDrive 'nest3'
        $locked = Join-Path $top 'locked'
        New-Item -ItemType Directory -Path $locked -Force | Out-Null
        $acl = Get-Acl -LiteralPath $locked
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($me, 'ListDirectory', 'Deny')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $locked -AclObject $acl
        try {
            $r = Find-NestedMarkers -Path $top
            $r.Complete | Should -BeFalse
        }
        finally {
            $acl = Get-Acl -LiteralPath $locked
            $null = $acl.RemoveAccessRule($rule)
            Set-Acl -LiteralPath $locked -AclObject $acl
        }
    }
}

Describe 'Get-RemoteMarker' {
    It 'maps exit <Code> to Found=<Found> Failed=<Failed>' -TestCases @(
        @{ Code = 0; Found = $true; Failed = $false }
        @{ Code = 3; Found = $false; Failed = $false }
        @{ Code = 4; Found = $false; Failed = $false }
        @{ Code = 1; Found = $false; Failed = $true }
    ) {
        param($Code, $Found, $Failed)
        $id = '0a1b2c3d-0000-4000-8000-0123456789ab'
        $json = ConvertTo-MarkerText -Folder (New-TestFolder -Local 'D:\X' -Id $id) -Now $script:now
        $script:capturedArgs = $null
        $script:mockCode = $Code
        $script:mockJson = $json
        Mock Invoke-RcloneOutput {
            $script:capturedArgs = $Arguments
            [pscustomobject]@{ ExitCode = $script:mockCode; Output = @($script:mockJson -split "`n") }
        }
        $r = Get-RemoteMarker -RemotePath 'pikpak:PC-Mirror/Music' -Kind 'pair' -LogFile (Join-Path $TestDrive 'r.log')
        $r.Found | Should -Be $Found
        $r.Failed | Should -Be $Failed
        if ($Found) { $r.Marker.Id | Should -Be $id } else { $r.Marker | Should -BeNullOrEmpty }
        $script:capturedArgs[0] | Should -Be 'cat'
        $script:capturedArgs[1] | Should -Be 'pikpak:PC-Mirror/Music/.pikpak-sync.json'
    }
}

Describe 'Invoke-EncryptedFolderCopy' {
    BeforeEach {
        $script:cfg = @{ StateDir = (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))); DailyBudgetGB = 1; MonthlyBudgetGB = 30; PrivateRemote = 'private' }
        $script:toasts = New-Object System.Collections.Generic.List[string]
        $script:calls = New-Object System.Collections.Generic.List[object]
        $script:rc = [pscustomobject]@{ ExitCode = 0; Bytes = [long]1234; BudgetHit = $false }
        Mock Send-MirrorToast { $script:toasts.Add($Message) }
        Mock Write-MirrorLog { }
        Mock Invoke-Rclone { $script:calls.Add($Arguments); $script:rc }
    }
    It 'toasts and does nothing when a sync holds the lock' {
        $h = Enter-MirrorLock -StateDir $script:cfg.StateDir
        try {
            $r = Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Secret' -Target 'D:\Back' -Now $script:now
        }
        finally { Exit-MirrorLock -Handle $h }
        $r.Ok | Should -BeFalse
        $r.Status | Should -Be 'locked'
        @($script:toasts)[0] | Should -Be 'Downloading Secret has to wait: a sync is running. Try again when it has finished.'
        $script:calls.Count | Should -Be 0
    }
    It 'toasts and does nothing when today is used up' {
        $st = New-MirrorState
        Add-TransferredBytes -State $st -Bytes ([long]2GB) -Now $script:now
        Save-MirrorState -StateDir $script:cfg.StateDir -State $st
        $r = Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Secret' -Target 'D:\Back' -Now $script:now
        $r.Ok | Should -BeFalse
        $r.Status | Should -Be 'budget'
        @($script:toasts)[0] | Should -Be "Downloading Secret waits for tomorrow: today's transfer limit is reached."
        $script:calls.Count | Should -Be 0
        (Enter-MirrorLock -StateDir $script:cfg.StateDir) | ForEach-Object { $_ | Should -Not -BeNullOrEmpty; Exit-MirrorLock -Handle $_ }
    }
    It 'copies private:<name> with the right arguments, counts the bytes, toasts, and releases the lock' {
        $r = Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Secret' -Target 'D:\Back' -Now $script:now
        $r.Ok | Should -BeTrue
        $r.Status | Should -Be 'done'
        $a = [string[]]$script:calls[0]
        $a[0] | Should -Be 'copy'
        $a[1] | Should -Be 'private:Secret'
        $a[2] | Should -Be 'D:\Back'
        $line = $a -join ' '
        $line | Should -Match '--exclude /\.pikpak-encrypted\.json --exclude /RCLONE_TEST'
        $line | Should -Match ('--max-transfer {0}B --cutoff-mode soft' -f [long](1GB))
        $a | Should -Contain '--log-file'
        @($script:toasts)[0] | Should -Be 'Secret is downloaded to D:\Back.'
        (Get-MirrorState -StateDir $script:cfg.StateDir).DayBytes | Should -Be 1234
        $h = Enter-MirrorLock -StateDir $script:cfg.StateDir
        $h | Should -Not -BeNullOrEmpty
        Exit-MirrorLock -Handle $h
    }
    It 'says part of it is downloaded when the limit was reached' {
        $script:rc = [pscustomobject]@{ ExitCode = 8; Bytes = [long]5000; BudgetHit = $true }
        $r = Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Secret' -Target 'D:\Back' -Now $script:now
        $r.Status | Should -Be 'partial'
        @($script:toasts)[0] | Should -Be 'Part of Secret is downloaded to D:\Back. Download it again tomorrow; it carries on where it stopped.'
        (Get-MirrorState -StateDir $script:cfg.StateDir).DayBytes | Should -Be 5000
    }
    It 'reports an error when rclone fails' {
        $script:rc = [pscustomobject]@{ ExitCode = 1; Bytes = [long]0; BudgetHit = $false }
        $r = Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Secret' -Target 'D:\Back' -Now $script:now
        $r.Ok | Should -BeFalse
        $r.Status | Should -Be 'failed'
        @($script:toasts)[0] | Should -Be 'Downloading Secret failed. See the log.'
    }
    It 'uses the configured encrypted remote and refuses a target that is not a drive path' {
        $script:cfg.PrivateRemote = 'vault'
        $null = Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Secret' -Target 'D:\Back' -Now $script:now
        ([string[]]$script:calls[0])[1] | Should -Be 'vault:Secret'
        foreach ($t in @('Back', '\srv\share', '..\x', '')) {
            { Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Secret' -Target $t -Now $script:now } | Should -Throw
        }
        $script:calls.Count | Should -Be 1
    }
    It 'I3: refuses a target inside a synced folder, but not one inside an encrypted folder there' {
        $script:cfg.Pairs = @(@{ Name = 'Docs'; Local = 'D:\Docs'; Remote = 'D/Docs'; Priority = 1 })
        $script:cfg.PrivatePaths = @(@{ Path = 'D:\Docs\Secret'; Name = 'Secret' })
        foreach ($t in @('D:\Docs', 'D:\Docs\Back', 'd:\docs\a\b')) {
            { Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Old' -Target $t -Now $script:now } |
                Should -Throw 'This folder is inside the synced folder Docs, so the download would be uploaded readable. Choose a folder outside your synced folders.'
        }
        $script:calls.Count | Should -Be 0
        Get-DownloadTargetProblem -Config $script:cfg -Target 'D:\Docs\Secret\Back' | Should -BeNullOrEmpty
        Get-DownloadTargetProblem -Config $script:cfg -Target 'D:\Docsx\Back' | Should -BeNullOrEmpty
        $null = Invoke-EncryptedFolderCopy -Config $script:cfg -Name 'Old' -Target 'D:\Docs\Secret\Back' -Now $script:now
        $script:calls.Count | Should -Be 1
    }
    It 'refuses names that could reach beyond one encrypted folder' {
        foreach ($bad in @('', '_holding', 'a/b', '..')) {
            { Invoke-EncryptedFolderCopy -Config $script:cfg -Name $bad -Target 'D:\Back' -Now $script:now } | Should -Throw
        }
        $script:calls.Count | Should -Be 0
    }
}
