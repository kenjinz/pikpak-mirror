# Folder identity marker: a small hidden JSON file in each synced folder holding the folder's ID.

$script:MarkerSyncedName = '.pikpak-sync.json'
$script:MarkerEncryptedName = '.pikpak-encrypted.json'

function Get-FolderMarkerName {
    param([Parameter(Mandatory)][ValidateSet('pair', 'private')][string]$Kind)
    if ($Kind -eq 'private') { return $script:MarkerEncryptedName }
    $script:MarkerSyncedName
}

function New-FolderId { [guid]::NewGuid().ToString('D') }

function Test-FolderId {
    param([string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $false }
    # \A and \z: '$' would also accept a trailing newline.
    $Id -match '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z'
}

function ConvertFrom-MarkerText {
    # @{ Id; Kind; Name; PikPak; LastPath; Updated } or @{ Invalid = $true }.
    param([string]$Text)
    $j = $null
    try { if (-not [string]::IsNullOrWhiteSpace($Text)) { $j = $Text | ConvertFrom-Json -ErrorAction Stop } } catch { $j = $null }
    if ($null -eq $j -or $null -eq $j.PSObject.Properties['app'] -or [string]$j.app -ne 'pikpak-mirror') { return @{ Invalid = $true } }
    $get = {
        param($n)
        $p = $j.PSObject.Properties[$n]
        if ($null -eq $p -or $null -eq $p.Value) { return $null }
        if ($p.Value -is [datetime]) { return ([datetime]$p.Value).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        [string]$p.Value
    }
    $id = & $get 'id'
    if (-not (Test-FolderId $id)) { return @{ Invalid = $true } }
    @{ Id = $id; Kind = (& $get 'kind'); Name = (& $get 'name'); PikPak = (& $get 'pikpak'); LastPath = (& $get 'lastPath'); Updated = (& $get 'updated') }
}

function Read-FolderMarker {
    # $null when no marker file exists; else the parsed marker plus File and FileKind. Encrypted wins when both exist.
    param([Parameter(Mandatory)][string]$Path)
    $enc = Join-Path $Path $script:MarkerEncryptedName
    $syn = Join-Path $Path $script:MarkerSyncedName
    $file = $null; $fileKind = $null
    if ([IO.File]::Exists($enc)) { $file = $enc; $fileKind = 'private' }
    elseif ([IO.File]::Exists($syn)) { $file = $syn; $fileKind = 'pair' }
    if ($null -eq $file) { return $null }
    $text = $null
    try { $text = [IO.File]::ReadAllText($file, (New-Object Text.UTF8Encoding $false)) }
    catch { return @{ Invalid = $true; File = $file } }
    $m = ConvertFrom-MarkerText $text
    $m['File'] = $file
    if (-not $m.ContainsKey('Invalid')) { $m['FileKind'] = $fileKind }
    $m
}

function ConvertTo-MarkerText {
    param([Parameter(Mandatory)]$Folder, [Parameter(Mandatory)][datetime]$Now)
    $kind = 'synced'
    if ([string]$Folder.Kind -eq 'private') { $kind = 'encrypted' }
    $o = [ordered]@{
        app      = 'pikpak-mirror'
        version  = 1
        id       = [string]$Folder.Id
        kind     = $kind
        name     = [string]$Folder.Name
        pikpak   = [string]$Folder.RemotePath
        lastPath = [string]$Folder.Local
        updated  = $Now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    }
    $o | ConvertTo-Json
}

function Write-FolderMarker {
    # $true when it wrote; $false when the marker already matched (only Hidden is re-set).
    param([Parameter(Mandatory)]$Folder, [Parameter(Mandatory)][datetime]$Now, [switch]$Force)
    if ([string]::IsNullOrWhiteSpace([string]$Folder.Id)) { throw 'The folder has no ID, so no marker can be written.' }
    $kind = [string]$Folder.Kind
    $dir = [string]$Folder.Local
    $file = Join-Path $dir (Get-FolderMarkerName -Kind $kind)
    $otherKind = 'private'
    if ($kind -eq 'private') { $otherKind = 'pair' }
    $other = Join-Path $dir (Get-FolderMarkerName -Kind $otherKind)
    $markerKind = 'synced'
    if ($kind -eq 'private') { $markerKind = 'encrypted' }

    $existing = Read-FolderMarker -Path $dir
    if ($null -ne $existing -and -not $existing.ContainsKey('Invalid')) {
        if ($existing.Id -ne [string]$Folder.Id -and -not $Force) {
            throw ("The folder {0} already has a different ID ({1})." -f $dir, $existing.Id)
        }
        if ($existing.FileKind -eq $kind -and $existing.Id -eq [string]$Folder.Id -and $existing.Kind -eq $markerKind -and
            $existing.Name -eq [string]$Folder.Name -and $existing.PikPak -eq [string]$Folder.RemotePath -and
            $existing.LastPath -eq [string]$Folder.Local) {
            [IO.File]::SetAttributes($file, ([IO.File]::GetAttributes($file) -bor [IO.FileAttributes]::Hidden))
            return $false
        }
    }

    $text = ConvertTo-MarkerText -Folder $Folder -Now $Now
    # Written to <file>.tmp first, then moved over the marker: a crash never leaves a half-written marker.
    $tmp = $file + '.tmp'
    try {
        if ([IO.File]::Exists($tmp)) { [IO.File]::SetAttributes($tmp, [IO.FileAttributes]::Normal); [IO.File]::Delete($tmp) }
        [IO.File]::WriteAllText($tmp, $text, (New-Object Text.UTF8Encoding $false))
        if ([IO.File]::Exists($file)) {
            [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
            [IO.File]::Replace($tmp, $file, [NullString]::Value)
        }
        else { [IO.File]::Move($tmp, $file) }
    }
    finally {
        if ([IO.File]::Exists($tmp)) { try { [IO.File]::Delete($tmp) } catch { } }
    }
    [IO.File]::SetAttributes($file, [IO.FileAttributes]::Hidden)
    if ([IO.File]::Exists($other)) {
        [IO.File]::SetAttributes($other, [IO.FileAttributes]::Normal)
        [IO.File]::Delete($other)
    }
    $true
}

function Remove-FolderMarkerFile {
    # Deletes the marker file of one kind in $Path (hidden or not). $true when there was one; throws when it can't.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][ValidateSet('pair', 'private')][string]$Kind)
    $file = Join-Path $Path (Get-FolderMarkerName -Kind $Kind)
    if (-not [IO.File]::Exists($file)) { return $false }
    [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal)
    [IO.File]::Delete($file)
    $true
}

function Find-NestedMarkers {
    # Every marker below $Path (not $Path itself). Never follows reparse points; gives up after $MaxSeconds.
    # Complete is $false when it gave up or a directory could not be read.
    param([Parameter(Mandatory)][string]$Path, [int]$MaxSeconds = 20)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $limit = [long]$MaxSeconds * 1000
    $items = New-Object System.Collections.Generic.List[object]
    $flag = [IO.FileAttributes]::ReparsePoint
    $top = New-Object IO.DirectoryInfo $Path
    $stack = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
    $stack.Push($top)
    $complete = $true
    while ($stack.Count -gt 0) {
        if ($sw.ElapsedMilliseconds -ge $limit) { return @{ Items = $items.ToArray(); Complete = $false } }
        $dir = $stack.Pop()
        try { $entries = $dir.GetFileSystemInfos() } catch { $complete = $false; continue }
        $has = $false
        foreach ($i in $entries) {
            if ($i -is [IO.FileInfo]) {
                if ($i.Name -ieq $script:MarkerSyncedName -or $i.Name -ieq $script:MarkerEncryptedName) { $has = $true }
            }
            elseif (($i.Attributes -band $flag) -eq 0) { $stack.Push($i) }
        }
        if ($has -and $dir.FullName -ne $top.FullName) {
            $m = Read-FolderMarker -Path $dir.FullName
            if ($null -ne $m) { $items.Add(@{ Path = $dir.FullName; Marker = $m }) }
        }
    }
    @{ Items = $items.ToArray(); Complete = $complete }
}

function Get-RemoteMarker {
    # @{ Found; Marker; Failed } from 'rclone cat <RemotePath>/<marker name>': exit 0 found, 3 or 4 not found, else failed.
    param(
        [Parameter(Mandatory)][string]$RemotePath,
        [Parameter(Mandatory)][ValidateSet('pair', 'private')][string]$Kind,
        [Parameter(Mandatory)][string]$LogFile
    )
    $target = $RemotePath.TrimEnd('/') + '/' + (Get-FolderMarkerName -Kind $Kind)
    $r = Invoke-RcloneOutput -Arguments @('cat', $target, '--log-level', 'INFO', '--log-file', $LogFile)
    ConvertTo-RemoteMarkerResult -Result $r
}

function ConvertTo-RemoteMarkerResult {
    # @{ Found; Marker; Failed } from the result of 'rclone cat <place>/<marker name>' (an object with ExitCode and
    # Output): exit 0 found, 3 or 4 not found, anything else failed.
    param([Parameter(Mandatory)]$Result)
    if ($Result.ExitCode -eq 0) { return @{ Found = $true; Marker = (ConvertFrom-MarkerText (@($Result.Output) -join "`n")); Failed = $false } }
    if ($Result.ExitCode -eq 3 -or $Result.ExitCode -eq 4) { return @{ Found = $false; Marker = $null; Failed = $false } }
    @{ Found = $false; Marker = $null; Failed = $true }
}

# ----- Downloading an encrypted folder ---------------------------------------------------------------

function Test-EncryptedFolderName {
    # $true for a name that is exactly one folder directly in the encrypted remote: not empty, not _holding
    # (the encrypted holding area), no path or wildcard characters, not '.' or '..', no outer spaces.
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name.Trim() -ne $Name -or $Name -eq '.' -or $Name -eq '..') { return $false }
    if ($Name -ieq '_holding') { return $false }
    if ($Name.IndexOfAny([char[]]@('\', '/', ':', '*', '?', '"', '<', '>', '|')) -ge 0) { return $false }
    $true
}

function Get-DownloadTargetProblem {
    # Why a download of an encrypted folder must not go to $Target, or $null: a target in (or equal to) a synced
    # folder would be uploaded readable by that folder's next sync, unless it is in an encrypted folder there.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Target)
    $key = { param($p) $n = $p; try { $n = ConvertTo-MirrorPath $p } catch { }; ConvertTo-PrefixKey $n }
    $t = & $key $Target
    foreach ($priv in @(@($Config['PrivatePaths']) | Where-Object { $_ })) {
        if ($t.StartsWith((& $key ([string]$priv.Path)))) { return $null }
    }
    foreach ($pair in @(@($Config['Pairs']) | Where-Object { $_ })) {
        if ($t.StartsWith((& $key ([string]$pair.Local)))) {
            return ('This folder is inside the synced folder {0}, so the download would be uploaded readable. Choose a folder outside your synced folders.' -f $pair.Name)
        }
    }
    $null
}

function Invoke-EncryptedFolderCopy {
    # Downloads private:<Name> to $Target (a new or empty folder on this PC) with `rclone copy`, under the sync lock
    # and inside today's transfer budget. The ID file and RCLONE_TEST are left out. Toasts the outcome and returns
    # @{ Ok; Status = 'locked' | 'budget' | 'done' | 'partial' | 'failed'; Message }. Ok is $true for done/partial.
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][datetime]$Now
    )
    if (-not (Test-EncryptedFolderName $Name)) { throw ("'{0}' is not the name of an encrypted folder." -f $Name) }
    if ($Target -notmatch '^[A-Za-z]:\\') { throw ("'{0}' is not a folder on a drive of this PC." -f $Target) }
    $inside = Get-DownloadTargetProblem -Config $Config -Target $Target
    if ($null -ne $inside) { throw $inside }
    $title = $script:MirrorToastTitle
    $out = {
        param($ok, $status, $text)
        try { Send-MirrorToast -Title $title -Message $text -Config $Config } catch { }
        @{ Ok = $ok; Status = $status; Message = $text }
    }
    $lock = Enter-MirrorLock -StateDir $Config.StateDir
    if ($null -eq $lock) {
        return (& $out $false 'locked' ('Downloading {0} has to wait: a sync is running. Try again when it has finished.' -f $Name))
    }
    try {
        $state = Get-MirrorState -StateDir $Config.StateDir
        $budget = [long](Get-RunBudget -State $state -Config $Config -Now $Now)
        if ($budget -le 0) {
            return (& $out $false 'budget' ("Downloading {0} waits for tomorrow: today's transfer limit is reached." -f $Name))
        }
        $ctx = @{ StateDir = $Config.StateDir; Now = $Now; LogCounter = 0 }
        $log = New-RunLogFile -Context $ctx -Label ('download-' + $Name)
        $args2 = [string[]]@('copy', ([string]$Config.PrivateRemote + ':' + $Name), $Target,
            '--exclude', ('/' + $script:MarkerEncryptedName), '--exclude', '/RCLONE_TEST',
            '--max-transfer', ('{0}B' -f $budget), '--cutoff-mode', 'soft',
            '--use-json-log', '--stats', '30s', '--stats-log-level', 'NOTICE', '--log-level', 'INFO', '--log-file', $log)
        try { Write-MirrorLog -Config $Config -Message ('Downloading private:{0} to {1} (log {2})' -f $Name, $Target, $log) } catch { }
        $r = Invoke-Rclone -Arguments $args2
        Add-TransferredBytes -State $state -Bytes ([long]$r.Bytes) -Now $Now
        Save-MirrorState -StateDir $Config.StateDir -State $state
        try { Write-MirrorLog -Config $Config -Message ('Download of private:{0} ended with exit {1}, {2} bytes' -f $Name, $r.ExitCode, $r.Bytes) } catch { }
        if ($r.BudgetHit) {
            return (& $out $true 'partial' ('Part of {0} is downloaded to {1}. Download it again tomorrow; it carries on where it stopped.' -f $Name, $Target))
        }
        if ($r.ExitCode -ne 0) { return (& $out $false 'failed' ('Downloading {0} failed. See the log.' -f $Name)) }
        & $out $true 'done' ('{0} is downloaded to {1}.' -f $Name, $Target)
    }
    finally { Exit-MirrorLock -Handle $lock }
}
