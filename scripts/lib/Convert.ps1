# Change a folder's kind: synced (a Pairs entry, plain remote) <-> encrypted (a PrivatePaths entry, crypt remote).
# Windows PowerShell 5.1 compatible. Requires Config, RcloneArgs, State, Runtime, Run, Status, ConfigWriter.
# This file is kept ASCII; non-ASCII characters are built with [char].
#
# The job (Invoke-MirrorFolderConversion), for one folder:
#   1. sync it a last time in its old form (Invoke-MirrorRun -OnlyFolders); anything but a clean success stops
#      the job with nothing changed;
#   2. save the new config and record the encrypted-folder confirmation for it; an encrypted folder that becomes
#      part of its synced folder again loses its .pikpak-encrypted.json (else no old copy is deleted);
#   3. forget the old form's sync state (state entry, notification memory, filter file, bisync listings);
#   4. when asked, delete the old copy in PikPak with `rclone purge` (exactly that folder, never a root);
#   5. sync the new form (Invoke-MirrorRun -OnlyFolders).
# Steps 2 to 4 hold the sync lock, so no run can start between the switch and the forgetting.

# Seconds the job waits for the sync lock after the last sync (a scheduled run may start in between).
$script:ConversionLockWaitSeconds = 30

function Get-BisyncSessionName {
    # The base name rclone bisync gives a folder pair's files in its workdir (<base>.path1.lst, .path2.lst,
    # their -new/-old/-err variants, .lck): each side as rclone sees it, with surrounding \ and / trimmed and every
    # whitespace, \, /, :, ? and * replaced by '_', joined with '..' (rclone bilib.SessionName/CanonicalPath).
    # Checked against a real workdir of this app: H:\Data\Photos\Album with
    # 'Pikpak remote:PC-Mirror/H/...' gives 'H__Data_Photos_Album..Pikpak_remote_PC-Mirror_H_...'.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Local, [Parameter(Mandatory)][AllowEmptyString()][string]$RemotePath)
    $canon = {
        param([string]$s)
        [regex]::Replace($s.Trim('\', '/'), '[\s\\/:?*]', '_')
    }
    $a = & $canon $Local
    $b = & $canon $RemotePath
    if ([string]::IsNullOrEmpty($a) -or [string]::IsNullOrEmpty($b)) { throw 'bisync session name: a side is empty' }
    $a + '..' + $b
}

function Remove-BisyncListings {
    # Deletes the bisync files of exactly one session in -WorkDir: <Session>.path1.lst / .path2.lst (with any
    # -new, -old, -err, -dry... suffix), <Session>.lck and <Session>.<name>.que. Nothing else, so the files of
    # another folder pair stay even when its name starts with or contains this session. Returns the removed names.
    param([Parameter(Mandatory)][string]$WorkDir, [Parameter(Mandatory)][AllowEmptyString()][string]$Session)
    $i = $Session.IndexOf('..')
    if ($i -lt 1 -or ($i + 2) -ge $Session.Length -or $Session -match '[\\/:*?"<>|]') {
        throw ('bisync session name is not <path1>..<path2>: ' + $Session)
    }
    if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { return }
    $pattern = '^' + [regex]::Escape($Session) + '\.(path[12]\.lst(-[a-z]+)*|lck|[a-z0-9]+\.que)$'
    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $WorkDir -File -Force)) {
        if ($f.Name -notmatch $pattern) { continue }
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        $removed.Add($f.Name)
    }
    $removed.ToArray()
}

function Get-ConversionPathKey {
    # Prefix key of a local path in canonical spelling (as Test-MirrorConfig compares them).
    param([string]$Path)
    $n = $Path
    try { $n = ConvertTo-MirrorPath $Path } catch { }
    ConvertTo-PrefixKey $n
}

function New-ConversionPrivateName {
    # The Name a new encrypted folder at $Path gets, as the app's "Add encrypted folder" (private.add) names it:
    # the folder's leaf (the drive letter for a drive root), made unique against '_holding' and the existing
    # encrypted folders' names with ' (2)', ' (3)'...
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Path)
    $p = ConvertTo-MirrorPath $Path
    $leaf = Split-Path -Path $p -Leaf
    if ([string]::IsNullOrEmpty($leaf) -or $leaf -match '[\\/:*?"<>|]') { $leaf = $p.Substring(0, 1).ToUpperInvariant() }
    $taken = @{ '_holding' = $true }
    foreach ($priv in @(@($Config['PrivatePaths']) | Where-Object { $_ })) { $taken[([string]$priv.Name).Trim().ToLowerInvariant()] = $true }
    $name = $leaf; $n = 2
    while ($taken.ContainsKey($name.ToLowerInvariant())) { $name = '{0} ({1})' -f $leaf, $n; $n++ }
    $name
}

function Assert-ConversionPurgeTarget {
    # Returns the PikPak folder that deleting the old copy of -Folder (a Get-SyncFolders item) may purge, or
    # throws. Allowed is only exactly the folder's own remote path, rebuilt from the config:
    #   a synced folder:    <Remote>:<MirrorRoot>/<pair Remote>  (strictly below MirrorRoot)
    #   an encrypted folder: <PrivateRemote>:<Name>              (one folder, never _holding)
    # Never a remote root, <Remote>:<MirrorRoot>, <Remote>:<HoldingRoot>, <Remote>:PC-Private or
    # <PrivateRemote>:_holding, and never a folder that is, holds or sits inside one of -KeepFolders (the folders
    # that stay synced).
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][hashtable]$Folder, [object[]]$KeepFolders = @())
    $target = [string]$Folder.RemotePath
    $null = New-PurgeArgs -Target $target -LogFile 'check'   # shape: <remote>:<path>, not a root, no odd segment
    $no = { param($why) throw ('refusing to delete {0}: {1}' -f $target, $why) }
    $i = $target.IndexOf(':')
    $rname = $target.Substring(0, $i)
    $tkey = $rname.ToLowerInvariant() + ':' + (ConvertTo-RemoteKey $target.Substring($i + 1))
    $main = ([string]$Config['Remote']).Trim()
    $privR = ([string]$Config['PrivateRemote']).Trim()
    $mirror = ConvertTo-RemoteKey ([string]$Config['MirrorRoot'])
    $hold = ConvertTo-RemoteKey ([string]$Config['HoldingRoot'])
    if ($main -eq '' -or $privR -eq '' -or $mirror -eq '' -or $hold -eq '') { & $no 'the remote settings are incomplete' }
    if ($main -ieq $privR) { & $no 'the plain and the encrypted remote have the same name' }
    $m = $main.ToLowerInvariant(); $v = $privR.ToLowerInvariant()
    $roots = @(($m + ':'), ($m + ':' + $mirror), ($m + ':' + $hold), ($m + ':pc-private'), ($v + ':'), ($v + ':_holding'))
    if ($roots -contains $tkey) { & $no 'it is a root folder' }
    foreach ($r in $roots) {
        if ($r.EndsWith(':')) { continue }
        if ($r -ne ($m + ':' + $mirror) -and $tkey.StartsWith($r + '/')) { & $no 'it is inside a reserved folder' }
    }
    if ($Folder.Kind -eq 'pair') {
        $expected = Join-RemotePath $main @([string]$Config['MirrorRoot'], [string]$Folder.Remote)
        if ($rname -cne $main) { & $no 'it is not on the plain remote' }
        if (-not $tkey.StartsWith($m + ':' + $mirror + '/')) { & $no 'it is not inside the mirror folder' }
        if ($target -cne $expected) { & $no ('it is not the synced folder''s own PikPak folder ' + $expected) }
    }
    elseif ($Folder.Kind -eq 'private') {
        $name = [string]$Folder.Name
        $expected = Join-RemotePath $privR @($name)
        if ($rname -cne $privR) { & $no 'it is not on the encrypted remote' }
        if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\\/:*?"<>|]' -or $name.Trim().ToLowerInvariant() -eq '_holding') {
            & $no 'the encrypted folder''s name is not usable'
        }
        if ($target -cne $expected) { & $no ('it is not the encrypted folder''s own PikPak folder ' + $expected) }
    }
    else { & $no 'unknown folder kind' }
    foreach ($k in @($KeepFolders | Where-Object { $_ })) {
        $kp = [string]$k.RemotePath
        $j = $kp.IndexOf(':')
        if ($j -lt 1) { continue }
        $kkey = $kp.Substring(0, $j).ToLowerInvariant() + ':' + (ConvertTo-RemoteKey $kp.Substring($j + 1))
        if ($kkey -eq $tkey -or $kkey.StartsWith($tkey + '/') -or $tkey.StartsWith($kkey + '/') -or $kkey.EndsWith(':')) {
            & $no ('it overlaps the PikPak folder of {0}' -f $k.Name)
        }
    }
    $target
}

function Get-ConversionCopyPlace {
    # Where a folder's old copy is, in PikPak's own words (rclone notation stays in the log lines): a synced
    # folder's copy as PikPak/PC-Mirror/<Remote>; an encrypted folder's copy has a scrambled name.
    param([Parameter(Mandatory)][hashtable]$Folder)
    if ([string]$Folder.Kind -eq 'private') { return 'in PikPak under PC-Private, with a scrambled name (only PikPak Sync can read it)' }
    'in PikPak at ' + ([string]$Folder.RemotePath -replace '^[^:]*:', 'PikPak/')
}

function Copy-FolderIdentityFields {
    # A folder keeps its ID (and its paused state) when its kind changes: copy Id / Paused from the old config entry.
    param([hashtable]$From, [hashtable]$To)
    foreach ($k in 'Id', 'Paused') {
        if ($From.ContainsKey($k) -and $null -ne $From[$k]) { $To[$k] = $From[$k] }
    }
}

function Get-FolderConversionPlan {
    # Pure: what changing the folder at -Path to -To ('encrypted' | 'plain') does to the raw config -Config.
    # Returns @{ From (Get-SyncFolders item of the old form); NewConfig (raw config after the switch); NewKind
    # ('private' | 'pair'); NewName; NewStateKey; NewIsExisting ($true when the new form is an existing synced
    # folder that the encrypted folder sits in); OldRemote (the old copy in PikPak, the folder's own RemotePath);
    # OldCopyPlace (the same place in plain words, Get-ConversionCopyPlace);
    # PurgeRefusal ($null, or why Assert-ConversionPurgeTarget refuses to delete OldRemote); Note (or $null) }.
    # Throws a plain message when the change is not allowed. With -DeleteOldCopy an old copy that cannot be
    # deleted safely makes the change not allowed; without it, it only fills PurgeRefusal.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][ValidateSet('encrypted', 'plain')][string]$To,
        [switch]$DeleteOldCopy
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'No folder was given.' }
    $key = Get-ConversionPathKey $Path
    $pairs = @(@($Config['Pairs']) | Where-Object { $_ })
    $privs = @(@($Config['PrivatePaths']) | Where-Object { $_ })
    $new = @{} + $Config
    $note = $null
    $isExisting = $false
    if ($To -eq 'encrypted') {
        $pair = @($pairs | Where-Object { (Get-ConversionPathKey ([string]$_.Local)) -eq $key }) | Select-Object -First 1
        if ($null -eq $pair) { throw ('The folder {0} is not a synced folder.' -f $Path) }
        foreach ($priv in $privs) {
            $pk = Get-ConversionPathKey ([string]$priv.Path)
            if ($pk -eq $key) { throw ('The folder {0} is already an encrypted folder.' -f $Path) }
            if ($pk.StartsWith($key)) {
                throw ('The folder {0} contains the encrypted folder {1}. Remove that one from the encrypted folders first.' -f $Path, $priv.Path)
            }
            if ($key.StartsWith($pk)) { throw ('The folder {0} is inside the encrypted folder {1}.' -f $Path, $priv.Path) }
        }
        $from = New-SyncFolder -Config $Config -Pair $pair
        $name = New-ConversionPrivateName -Config $Config -Path ([string]$pair.Local)
        $new['Pairs'] = @($pairs | Where-Object { -not [object]::ReferenceEquals($_, $pair) })
        $entry = @{ Path = [string]$pair.Local; Name = $name }
        Copy-FolderIdentityFields -From $pair -To $entry
        $new['PrivatePaths'] = @($privs) + @($entry)
        $newKind = 'private'; $newName = $name; $newKey = 'private:' + $name
    }
    else {
        $priv = @($privs | Where-Object { (Get-ConversionPathKey ([string]$_.Path)) -eq $key }) | Select-Object -First 1
        if ($null -eq $priv) { throw ('The folder {0} is not an encrypted folder.' -f $Path) }
        $from = New-SyncFolder -Config $Config -Private $priv
        $new['PrivatePaths'] = @($privs | Where-Object { -not [object]::ReferenceEquals($_, $priv) })
        $outer = @($pairs | Where-Object { $k = Get-ConversionPathKey ([string]$_.Local); $key.Length -gt $k.Length -and $key.StartsWith($k) }) | Select-Object -First 1
        if ($null -ne $outer) {
            $new['Pairs'] = @($pairs)
            $note = ("The folder {0} becomes part of the synced folder '{1}' again." -f $Path, $outer.Name)
            $newKind = 'pair'; $newName = [string]$outer.Name; $newKey = [string]$outer.Name; $isExisting = $true
        }
        else {
            $pair = New-MirrorPair -Path (ConvertTo-MirrorPath ([string]$priv.Path)) -Config $Config
            Copy-FolderIdentityFields -From $priv -To $pair
            $new['Pairs'] = @($pairs) + @($pair)
            $newKind = 'pair'; $newName = [string]$pair.Name; $newKey = [string]$pair.Name
        }
    }
    $keep = @(Get-SyncFolders -Config $new)
    $oldRemote = [string]$from.RemotePath
    $refusal = $null
    try { $null = Assert-ConversionPurgeTarget -Config $Config -Folder $from -KeepFolders $keep }
    catch { $refusal = $_.Exception.Message }
    if ($DeleteOldCopy -and $null -ne $refusal) {
        throw ('The old copy {0} cannot be deleted safely ({1}). Change the folder without deleting the old copy.' -f (Get-ConversionCopyPlace -Folder $from), $refusal)
    }
    @{
        From = $from; NewConfig = $new; NewKind = $newKind; NewName = $newName; NewStateKey = $newKey
        NewIsExisting = $isExisting; OldRemote = $oldRemote; OldCopyPlace = (Get-ConversionCopyPlace -Folder $from); PurgeRefusal = $refusal; Note = $note
    }
}

function Test-ConversionConfig {
    # Validation errors of a raw config, checked the way Save-MirrorConfig will (a temp file, loaded and tested),
    # without touching the real config file. Emitted unrolled; callers wrap in @().
    param([Parameter(Mandatory)][hashtable]$Config)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pikpak-convert-{0}.psd1' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($tmp, (ConvertTo-MirrorConfigText -Config $Config), (New-Object System.Text.UTF8Encoding $true))
        try { $loaded = Get-MirrorConfig -Path $tmp }
        catch { return ('the new settings could not be loaded: ' + $_.Exception.Message) }
        Test-MirrorConfig -Config $loaded
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Clear-FolderSyncState {
    # Forgets everything a run remembers about one folder (a Get-SyncFolders item of a loaded config): its
    # State.Pairs entry, its State.Notified keys ('<StateKey>|<kind>'), its filter file and its bisync listings.
    # The next run of a folder with this StateKey starts unseeded (--resync). -KeepFolders: folders whose
    # listings must survive (a session name shared with one of them is not deleted). Changes $State in memory;
    # the caller saves it. Returns what was removed, as text for the log.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)]$State, [Parameter(Mandatory)][hashtable]$Folder,
        [object[]]$KeepFolders = @())
    $done = New-Object System.Collections.Generic.List[string]
    $key = [string]$Folder.StateKey
    if ([string]::IsNullOrEmpty($key)) { throw 'folder without a state key' }
    if ($State.Pairs.ContainsKey($key)) { $State.Pairs.Remove($key); $done.Add('state ' + $key) }
    foreach ($k in @($State.Notified.Keys)) {
        $ks = [string]$k
        $bar = $ks.LastIndexOf('|')
        if ($bar -gt 0 -and $ks.Substring(0, $bar) -ieq $key) { $State.Notified.Remove($k); $done.Add('notification ' + $ks) }
    }
    $filter = Get-FolderFilterPath -Config $Config -Folder $Folder
    $keepFilters = @(@($KeepFolders | Where-Object { $_ }) | ForEach-Object { Get-FolderFilterPath -Config $Config -Folder $_ })
    if ((Test-Path -LiteralPath $filter -PathType Leaf) -and @($keepFilters | Where-Object { $_ -ieq $filter }).Count -eq 0) {
        Remove-Item -LiteralPath $filter -Force -ErrorAction Stop
        $done.Add('filter ' + $filter)
    }
    $session = Get-BisyncSessionName -Local ([string]$Folder.Local) -RemotePath ([string]$Folder.RemotePath)
    $keepSessions = @(@($KeepFolders | Where-Object { $_ }) | ForEach-Object { Get-BisyncSessionName -Local ([string]$_.Local) -RemotePath ([string]$_.RemotePath) })
    if (@($keepSessions | Where-Object { $_ -ieq $session }).Count -eq 0) {
        foreach ($n in @(Remove-BisyncListings -WorkDir (Join-Path $Config.StateDir 'bisync') -Session $session)) { $done.Add('listing ' + $n) }
    }
    $done.ToArray()
}

function Get-ConversionRunProblem {
    # Why a run of one folder (-Key) did not end successfully, in plain words; $null when it did (its StateKey
    # in Ran and no error reported).
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Key)
    $ranIt = @(@($Result.Ran) | Where-Object { [string]$_ -ieq $Key }).Count -gt 0
    $errs = @(@($Result.Errors) | Where-Object { $_ })
    if ($ranIt -and $errs.Count -eq 0) { return $null }
    $skipped = @($Result.Skipped)
    if ($skipped -contains 'locked') { return 'a sync is already running' }
    if ($errs.Count -gt 0) { return [string]$errs[0] }
    if ($skipped -contains 'budget') { return 'the transfer limit is reached' }
    if (@($skipped | Where-Object { [string]$_ -ieq $Key }).Count -gt 0) { return 'the folder was not found on this PC' }
    'the sync did not finish'
}

function Invoke-MirrorFolderConversion {
    # Changes the folder at -Path to -To ('encrypted' | 'plain'); see the top of this file for the steps.
    # Returns [pscustomobject]@{ Changed; OldCopyDeleted; Message } and sends one toast with Message.
    # Before the config switch, an exception propagates (nothing was changed). After it, every outcome returns
    # Changed = $true with a message that says what happened to the old copy and what failed, if anything.
    # -Now is the job's start time; each step runs at -Now plus the time elapsed since the start.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('encrypted', 'plain')][string]$To,
        [switch]$DeleteOldCopy,
        [Parameter(Mandatory)][datetime]$Now
    )
    $start = Get-Date
    $at = { $Now + ((Get-Date) - $start) }
    $title = $script:MirrorToastTitle
    # The config the last sync runs with ($cfg) and the one the switch is planned from ($raw) come from the same
    # file contents: read the bytes, load both, and check the bytes did not change meanwhile.
    $file = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
    $fileBefore = [IO.File]::ReadAllBytes($file)
    $cfg = Get-MirrorConfig -Path $file
    $raw = Get-RawMirrorConfig -Path $file
    $sameFile = { [Convert]::ToBase64String($fileBefore) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($file)) }
    $finish = {
        param([bool]$Changed, [bool]$Deleted, [string]$Message)
        Send-MirrorToast -Title $title -Message $Message -Config $cfg
        [pscustomobject]@{ Changed = $Changed; OldCopyDeleted = $Deleted; Message = $Message }
    }
    $log = { param($m) try { Write-MirrorLog -Config $cfg -Message ('Change of kind: ' + $m) } catch { } }
    if (-not (& $sameFile)) { return (& $finish $false $false ('{0} was not changed: the settings were being changed. Try again.' -f $Path)) }
    try { $plan = Get-FolderConversionPlan -Config $raw -Path $Path -To $To -DeleteOldCopy:$DeleteOldCopy }
    catch { return (& $finish $false $false ('{0} was not changed. {1}' -f $Path, $_.Exception.Message)) }
    $name = [string]$plan.From.Name
    $oldKey = [string]$plan.From.StateKey
    $newKey = [string]$plan.NewStateKey
    $target = [string]$plan.OldRemote
    $place = [string]$plan.OldCopyPlace
    $notChanged = { param($why) & $finish $false $false ('{0} was not changed: {1}' -f $name, $why) }

    $errs = @(Test-ConversionConfig -Config $plan.NewConfig)
    if ($errs.Count -gt 0) { return (& $notChanged ('the new settings would not be valid ({0}).' -f ($errs -join ' '))) }
    $oldFolder = @(Get-SyncFolders -Config $cfg | Where-Object { [string]$_.StateKey -ceq $oldKey }) | Select-Object -First 1
    if ($null -eq $oldFolder) { return (& $notChanged 'it is not in the settings.') }

    # 1. Last sync in the old form.
    $r1 = Invoke-MirrorRun -Config $cfg -Now (& $at) -OnlyFolders @($oldKey)
    $why = Get-ConversionRunProblem -Result $r1 -Key $oldKey
    if ($null -ne $why) { return (& $notChanged ('it could not be synced one last time ({0}).' -f $why)) }

    # 2.-4. under the sync lock: no run can start between the switch and the forgetting.
    $lock = $null
    $deadline = (Get-Date).AddSeconds([int]$script:ConversionLockWaitSeconds)
    while ($true) {
        $lock = Enter-MirrorLock -StateDir $cfg.StateDir
        if ($null -ne $lock -or (Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($null -eq $lock) { return (& $notChanged 'a sync started in the meantime. Try again when it has finished.') }
    $switched = $false
    $deleted = $false
    $copyText = $null
    $problems = New-Object System.Collections.Generic.List[string]
    $newCfg = $null
    $cleaned = $false
    $markerLeft = $null
    try {
        if (-not (& $sameFile)) { return (& $notChanged 'the settings were changed in the meantime. Try again.') }
        # 2. Switch the config.
        $errs = @(Save-MirrorConfig -Path $ConfigPath -Config $plan.NewConfig)
        if ($errs.Count -gt 0) { return (& $notChanged ('the new settings could not be saved ({0}).' -f ($errs -join ' '))) }
        $switched = $true
        & $log ('{0} switched from {1} to {2} ({3})' -f $name, $oldKey, $newKey, $Path)

        # 2. (cont.) An encrypted folder that becomes part of its synced folder again loses its encrypted ID file
        # now: that synced folder leaves out every folder that has one (--exclude-if-present), so with the file
        # its files would never reach PikPak readable, and the old copy must not be deleted then.
        if ($plan.NewIsExisting) {
            $encFile = Join-Path ([string]$plan.From.Local) (Get-FolderMarkerName -Kind 'private')
            try {
                if (Remove-FolderMarkerFile -Path ([string]$plan.From.Local) -Kind 'private') { & $log ('{0} removed {1}' -f $name, $encFile) }
            }
            catch {
                $markerLeft = $_.Exception.Message
                & $log ('{0} removing {1} failed: {2}' -f $name, $encFile, $markerLeft)
                $problems.Add(("The file {0} couldn't be deleted ({1}); delete it yourself, or '{2}' keeps leaving this folder out." -f $encFile, $markerLeft, $plan.NewName))
            }
        }

        # 2. (cont.) Confirm the encrypted folders of the new config; 3. forget the old form's sync state (and any
        # leftover state under the new form's key when the new entry is new).
        try {
            $newCfg = Get-MirrorConfig -Path $ConfigPath
            $state = Get-MirrorState -StateDir $newCfg.StateDir
            $state.PrivateConfirmedHash = Get-PrivatePathsHash -Config $newCfg
            Save-MirrorState -StateDir $newCfg.StateDir -State $state
            $newFolders = @(Get-SyncFolders -Config $newCfg)
            $forget = @($oldFolder)
            if (-not $plan.NewIsExisting) {
                $f = @($newFolders | Where-Object { [string]$_.StateKey -ceq $newKey }) | Select-Object -First 1
                if ($null -ne $f) { $forget += $f }
            }
            $done = New-Object System.Collections.Generic.List[string]
            foreach ($f in $forget) {
                $keep = @($newFolders | Where-Object { [string]$_.StateKey -cne [string]$f.StateKey })
                foreach ($d in @(Clear-FolderSyncState -Config $newCfg -State $state -Folder $f -KeepFolders $keep)) { $done.Add($d) }
            }
            Save-MirrorState -StateDir $newCfg.StateDir -State $state
            if ($done.Count -gt 0) { & $log ('{0} forgot {1}' -f $name, ($done.ToArray() -join ', ')) }
            $cleaned = $true
        }
        catch {
            & $log ('{0} clearing the old sync state failed: {1}' -f $name, $_.Exception.Message)
            $problems.Add(('Clearing the old sync state failed ({0}).' -f $_.Exception.Message))
        }

        # 4. Delete the old copy when asked: only after a clean switch, and only the folder step 1 synced.
        if ($DeleteOldCopy) {
            $refused = $null
            if (-not $cleaned) { $refused = 'the old sync state could not be cleared' }
            elseif ($null -ne $markerLeft) { $refused = 'its encrypted ID file could not be deleted, so the synced folder would not upload it' }
            else {
                try {
                    if ([string]$oldFolder.RemotePath -cne $target) { throw 'the last sync used another PikPak folder' }
                    $checked = Assert-ConversionPurgeTarget -Config $newCfg -Folder $plan.From -KeepFolders $newFolders
                    if ($checked -cne $target) { throw 'the old copy is not the folder the last sync used' }
                }
                catch { $refused = $_.Exception.Message }
            }
            if ($null -ne $refused) {
                & $log ('{0} old copy {1} not deleted: {2}' -f $name, $target, $refused)
                $copyText = 'The old copy {0} was not deleted because {1}; delete it in PikPak yourself.' -f $place, $refused
            }
            else {
                try {
                    $ctx = @{ StateDir = $newCfg.StateDir; Now = (& $at); LogCounter = 0 }
                    $plog = New-RunLogFile -Context $ctx -Label ('purge-' + ($oldKey -replace ':', '-'))
                    & $log ('{0} deleting the old copy {1} (rclone purge, log {2})' -f $name, $target, $plog)
                    $p = Invoke-Rclone -Arguments @(New-PurgeArgs -Target $target -LogFile $plog)
                    & $log ('{0} delete of {1} ended with exit {2}' -f $name, $target, $p.ExitCode)
                    if ($p.ExitCode -eq 0) {
                        $deleted = $true
                        $copyText = "The old copy {0} was deleted; it is in PikPak's trash." -f $place
                    }
                    elseif ($p.ExitCode -eq 3) {
                        $deleted = $true
                        $copyText = 'There was no old copy {0} to delete.' -f $place
                    }
                    else {
                        $copyText = 'The old copy {0} could not be deleted (rclone exit {1}, see {2}); delete it in PikPak yourself.' -f $place, $p.ExitCode, $plog
                    }
                }
                catch {
                    & $log ('{0} delete of {1} failed: {2}' -f $name, $target, $_.Exception.Message)
                    $copyText = 'The old copy {0} may not have been deleted: the delete failed ({1}). Check PikPak and delete it yourself if it is still there.' -f $place, $_.Exception.Message
                }
            }
        }
    }
    catch {
        if (-not $switched) { throw }
        & $log ('{0} failed after the switch: {1}' -f $name, $_.Exception.Message)
        $problems.Add(('Something failed after the switch ({0}).' -f $_.Exception.Message))
    }
    finally { Exit-MirrorLock -Handle $lock }
    if ($null -eq $copyText) {
        if ($DeleteOldCopy) { $copyText = 'The old copy {0} was not deleted; delete it in PikPak yourself.' -f $place }
        else { $copyText = 'The old copy is still {0}.' -f $place }
    }

    # 5. First sync in the new form.
    $kindWord = 'normal'
    if ($plan.NewKind -eq 'private') { $kindWord = 'encrypted' }
    if (-not $cleaned) {
        # The old state was not cleared: a run now could treat the folder with stale state. It waits for the next sync.
        $syncText = 'The first {0} sync did not run because the old sync state could not be cleared; it runs at the next sync.' -f $kindWord
    }
    else { try {
        if ($null -eq $newCfg) { $newCfg = Get-MirrorConfig -Path $ConfigPath }
        $r5 = Invoke-MirrorRun -Config $newCfg -Now (& $at) -OnlyFolders @($newKey)
        $ranIt = @(@($r5.Ran) | Where-Object { [string]$_ -ieq $newKey }).Count -gt 0
        $noErr = @(@($r5.Errors) | Where-Object { $_ }).Count -eq 0
        if ($ranIt -and $noErr) { $syncText = 'It was synced in its new form.' }
        elseif (@($r5.Skipped) -contains 'locked') { $syncText = ('The first {0} sync did not run (a sync is running); it runs at the next sync.' -f $kindWord) }
        elseif (@($r5.Skipped) -contains 'budget' -and $noErr) { $syncText = 'Its upload continues at the next syncs (transfer limit).' }
        else { $syncText = 'The first {0} sync reported a problem: {1}' -f $kindWord, (Get-ConversionRunProblem -Result $r5 -Key $newKey) }
    }
    catch {
        & $log ('{0} first sync in the new form failed: {1}' -f $name, $_.Exception.Message)
        $syncText = 'The first {0} sync did not run ({1}); it runs at the next sync.' -f $kindWord, $_.Exception.Message
    } }

    if ($plan.NewIsExisting) { $kindText = "{0} is no longer encrypted; it is part of the synced folder '{1}' again." -f $name, $plan.NewName }
    elseif ($plan.NewKind -eq 'private') {
        $kindText = '{0} is now an encrypted folder.' -f $name
        if ($plan.NewName -cne $name) { $kindText = "{0} is now an encrypted folder (named '{1}')." -f $name, $plan.NewName }
    }
    else {
        $kindText = '{0} is now a synced folder, readable in PikPak.' -f $name
        if ($plan.NewName -cne $name) { $kindText = "{0} is now a synced folder (named '{1}'), readable in PikPak." -f $name, $plan.NewName }
    }
    & $finish $true $deleted ((@($kindText, $copyText) + @($problems.ToArray()) + @($syncText)) -join ' ')
}
