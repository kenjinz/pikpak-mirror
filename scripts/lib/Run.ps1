# Sync orchestration: one scheduled run (bisync of encrypted folders and pairs, prune, notifications).
# Windows PowerShell 5.1 compatible. Requires Config, Filters, RcloneArgs, State, Runtime.
# This file is kept ASCII; non-ASCII characters are built with [char].

$script:MirrorToastTitle = 'PikPak Sync'

function ConvertTo-SafeFileName {
    param([string]$Name)
    $s = $Name
    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) { $s = $s.Replace([string]$c, '_') }
    $s
}

function New-RunLogFile {
    # Unique per-invocation rclone log path: <StateDir>\logs\<yyyy-MM-dd>\<HHmmss>-<label>-<n>.log
    param([Parameter(Mandatory)][hashtable]$Context, [Parameter(Mandatory)][string]$Label)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $dir = [IO.Path]::Combine($Context.StateDir, 'logs', $Context.Now.ToString('yyyy-MM-dd', $inv))
    $stamp = $Context.Now.ToString('HHmmss', $inv)
    $safe = ConvertTo-SafeFileName $Label
    do {
        $Context.LogCounter++
        $path = Join-Path $dir ('{0}-{1}-{2}.log' -f $stamp, $safe, $Context.LogCounter)
    } while (Test-Path -LiteralPath $path)
    $path
}

function New-SyncFolder {
    # One folder that a run syncs both ways with bisync: a synced folder (a Pairs entry, plain remote) or an
    # encrypted folder (a PrivatePaths entry, crypt remote). Keys: Kind ('pair'|'private'), Name, Local,
    # RemotePath, StateKey (key in State.Pairs, notification keys, -Resync), HoldLocal (folder under
    # <LocalHolding>\<day>), HoldRemote (remote holding root), Priority, Remote (pair's relative remote; $null
    # for an encrypted folder), Id (the folder ID; $null when the entry has none), Paused ([bool]). An encrypted
    # folder's state key and holding folder carry a 'private' prefix, so a synced folder and an encrypted folder
    # of the same Name never share anything.
    [CmdletBinding(DefaultParameterSetName = 'Pair')]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory, ParameterSetName = 'Pair')][hashtable]$Pair,
        [Parameter(Mandatory, ParameterSetName = 'Private')][hashtable]$Private
    )
    $entry = $Pair
    if ($PSCmdlet.ParameterSetName -eq 'Private') { $entry = $Private }
    $id = [string]$entry['Id']
    if ([string]::IsNullOrWhiteSpace($id)) { $id = $null }
    $paused = [bool]$entry['Paused']
    if ($PSCmdlet.ParameterSetName -eq 'Private') {
        $name = [string]$Private.Name
        return @{
            Kind = 'private'; Name = $name; Local = [string]$Private.Path
            RemotePath = (Join-RemotePath $Config['PrivateRemote'] @($name))
            StateKey = 'private:' + $name
            HoldLocal = '_private\' + $name
            HoldRemote = (Join-RemotePath $Config['PrivateRemote'] @('_holding'))
            Priority = 0; Remote = $null; Id = $id; Paused = $paused
        }
    }
    @{
        Kind = 'pair'; Name = [string]$Pair.Name; Local = [string]$Pair.Local
        RemotePath = (Join-RemotePath $Config['Remote'] @($Config['MirrorRoot'], $Pair.Remote))
        StateKey = [string]$Pair.Name
        HoldLocal = [string]$Pair.Name
        HoldRemote = (Join-RemotePath $Config['Remote'] @($Config['HoldingRoot']))
        Priority = [int]$Pair.Priority; Remote = [string]$Pair.Remote; Id = $id; Paused = $paused
    }
}

function Get-SyncFolders {
    # Every folder a run syncs: encrypted folders first (config order), then pairs by Priority, then Name.
    # Emitted unrolled; callers wrap in @().
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config)
    foreach ($entry in @($Config['PrivatePaths']) | Where-Object { $_ }) { New-SyncFolder -Config $Config -Private $entry }
    $pairs = @(@($Config['Pairs']) | Where-Object { $_ } |
        Sort-Object -Property @{ Expression = { [int]$_.Priority } }, @{ Expression = { [string]$_.Name } })
    foreach ($p in $pairs) { New-SyncFolder -Config $Config -Pair $p }
}

function Get-FolderFilterPath {
    # Where a folder's filter file is: a pair's <StateDir>\filters\<Name>.txt, an encrypted folder's
    # <StateDir>\filters\private\<Name>.txt.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][hashtable]$Folder)
    $dir = Join-Path $Config.StateDir 'filters'
    if ($Folder.Kind -eq 'private') { $dir = Join-Path $dir 'private' }
    Join-Path $dir ((ConvertTo-SafeFileName $Folder.Name) + '.txt')
}

function Update-FolderFilterFile {
    # Writes the folder's rclone filter rules (UTF-8, no BOM) to Get-FolderFilterPath: a pair's private
    # excludes, then the global rules; an encrypted folder's global rules only.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][hashtable]$Folder)
    $excludes = [string[]]@()
    if ($Folder.Kind -eq 'private') {
        $rules = [string[]]@(Get-GlobalFilterRules -GlobalRulesPath $Config.GlobalFiltersFile)
    }
    else {
        $rules = [string[]]@(New-PairFilterRules -Config $Config -Pair $Folder -GlobalRulesPath $Config.GlobalFiltersFile)
        # The encrypted-folder excludes come first, before the global rules.
        $nGlobal = @(Get-GlobalFilterRules -GlobalRulesPath $Config.GlobalFiltersFile).Count
        $excludes = [string[]]@($rules | Select-Object -First ($rules.Count - $nGlobal))
    }
    $path = Get-FolderFilterPath -Config $Config -Folder $Folder
    $dir = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllLines($path, $rules, (New-Object Text.UTF8Encoding $false))
    [pscustomobject]@{ Path = $path; Hash = (Get-TextHash -Lines $rules); Excludes = $excludes }
}

function Get-FolderIdentity {
    # Hash of the folder's mapping (<local>|<remote>, canonical spelling, lower-case). When it changes for a
    # seeded folder, the bisync listings describe a different pair of folders and a resync is needed.
    # A pair keeps hashing its relative remote (ConvertTo-RemoteKey), exactly as before, so live pairs keep
    # their identity; an encrypted folder hashes its remote path (private:<Name>).
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Folder)
    $local = (ConvertTo-MirrorPath ([string]$Folder.Local)).TrimEnd('\').ToLowerInvariant()
    if ($Folder.Kind -eq 'pair') { $remote = ConvertTo-RemoteKey ([string]$Folder.Remote) }
    else { $remote = ([string]$Folder.RemotePath).ToLowerInvariant() }
    Get-TextHash -Lines @(('{0}|{1}' -f $local, $remote))
}

function Get-UnknownPairNames {
    # Names (as given) that match no folder StateKey in the config (case-insensitive): a pair's Name or
    # private:<Name> of an encrypted folder. Emitted unrolled; callers wrap in @().
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Config, [string[]]$Names = @())
    $known = @(Get-SyncFolders -Config $Config | ForEach-Object { [string]$_.StateKey })
    foreach ($n in @($Names) | Where-Object { $_ }) {
        $hit = $false
        foreach ($k in $known) { if ($k -ieq [string]$n) { $hit = $true; break } }
        if (-not $hit) { $n }
    }
}

function Test-FolderIdBeforeSync {
    # The PC-side ID check of a folder with an Id, just before its sync. $null when it may sync: its marker was
    # then written or refreshed (Write-FolderMarker never changes an id) and MarkerWritten set in -PairState.
    # Else @{ Kind; Message } of the issue it is skipped with, and nothing was written.
    # -AllFolders: every configured folder, paused or not (a duplicate Id is checked against all of them).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Folder, [Parameter(Mandatory)][hashtable]$PairState,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$AllFolders, [Parameter(Mandatory)][datetime]$Now
    )
    $id = [string]$Folder.Id
    $name = [string]$Folder.Name
    $others = @($AllFolders | Where-Object { [string]$_.StateKey -ine [string]$Folder.StateKey -and [string]$_.Id -ieq $id } |
        ForEach-Object { [string]$_.Name })
    if ($others.Count -gt 0) {
        $msg = '{0}: another folder ({1}) has the same ID, so nothing was synced. Open PikPak Sync to choose.' -f $name, ($others -join ', ')
        return @{ Kind = 'folder-duplicate-id'; Message = $msg }
    }
    $marker = Read-FolderMarker -Path $Folder.Local
    if ($null -ne $marker) {
        if ($marker.ContainsKey('Invalid') -or [string]$marker.Id -ine $id) {
            $owner = 'unknown'
            if (-not $marker.ContainsKey('Invalid') -and -not [string]::IsNullOrEmpty([string]$marker.Name)) { $owner = [string]$marker.Name }
            $msg = "{0}: the folder at {1} is a different folder (it belongs to '{2}'). Nothing was synced. Open PikPak Sync to sort it out." -f $name, $Folder.Local, $owner
            return @{ Kind = 'folder-identity-mismatch'; Message = $msg }
        }
    }
    elseif ([bool]$PairState['MarkerWritten']) {
        $msg = '{0}: the folder at {1} has lost its ID file, so it may be a different folder. Nothing was synced. Open PikPak Sync to sort it out.' -f $name, $Folder.Local
        return @{ Kind = 'folder-marker-missing'; Message = $msg }
    }
    $null = Write-FolderMarker -Folder $Folder -Now $Now
    $PairState['MarkerWritten'] = $true
    $null
}

function Test-RemoteFolderIdBeforeSync {
    # The PikPak-side ID check of a folder with an Id that is about to be merged (resync). $null when its PikPak
    # place has no marker or one with the same id; else @{ Kind; Message; KeyKind } of the issue it is skipped with.
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Folder, [Parameter(Mandatory)][string]$LogFile)
    # rclone cannot open a log file in a folder that does not exist yet (it would fail with exit 1).
    $dir = [IO.Path]::GetDirectoryName($LogFile)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $name = [string]$Folder.Name
    $r = Get-RemoteMarker -RemotePath ([string]$Folder.RemotePath) -Kind ([string]$Folder.Kind) -LogFile $LogFile
    if ($r.Failed) {
        $msg = "{0}: couldn't read the ID file in PikPak, so nothing was synced. It is tried again at the next sync." -f $name
        return @{ Kind = 'other'; Message = $msg; KeyKind = 'other-marker-read' }
    }
    if ($r.Found -and ($r.Marker.ContainsKey('Invalid') -or [string]$r.Marker.Id -ine [string]$Folder.Id)) {
        $owner = 'unknown'
        if (-not $r.Marker.ContainsKey('Invalid') -and -not [string]::IsNullOrEmpty([string]$r.Marker.Name)) { $owner = [string]$r.Marker.Name }
        $msg = "{0}: the PikPak copy at {1} belongs to another folder ('{2}'). Nothing was synced. Open PikPak Sync to sort it out." -f $name, $Folder.RemotePath, $owner
        return @{ Kind = 'folder-identity-mismatch'; Message = $msg; KeyKind = 'folder-identity-mismatch' }
    }
    $null
}

function Send-RunIssueToast {
    # Toasts a problem only when it was not already toasted today (State.Notified[Key] = day key of the last
    # toast), then remembers today. A suppressed toast is still logged so the problem stays findable.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State, [Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Message
    )
    $today = Get-DayKey -Now $Now
    if ($State.Notified[$Key] -eq $today) {
        try { Write-MirrorLog -Config $Config -Message ('Notify (already shown today): ' + $Message) } catch { }
        return
    }
    Send-MirrorToast -Title $script:MirrorToastTitle -Message $Message -Config $Config
    $State.Notified[$Key] = $today
}

function Invoke-MirrorRun {
    [CmdletBinding()]
    # -OnlyFolders: when not empty, only the folders whose StateKey is listed (case-insensitive) are synced; the
    # others are not attempted (their state and notification memory stay as they are), and the prune (6.) and
    # success bookkeeping (8.) are left to the next full run. Empty: every folder, exactly as before.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][datetime]$Now, [string[]]$ForceResync = @(),
        [string[]]$OnlyFolders = @())

    $ran = New-Object System.Collections.Generic.List[string]
    $only = @(@($OnlyFolders) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) } | ForEach-Object { [string]$_ })
    $partial = $only.Count -gt 0
    $skipped = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    $title = $script:MirrorToastTitle
    $issues = New-Object System.Collections.Generic.List[object]
    # Pair = the folder's Name; Private tells an encrypted folder from a synced folder of the same Name.
    $addIssue = { param($Pair, $Kind, $Message, $Log, $Private) $issues.Add(@{ Pair = $Pair; Kind = $Kind; Message = $Message; Log = $Log; Private = [bool]$Private }) }
    $monthPaused = $false
    $dayPaused = $false
    $result = { [pscustomobject]@{ Ran = $ran.ToArray(); Skipped = $skipped.ToArray(); Errors = $errors.ToArray() } }
    # Notification memory: keys raised in this run, folders attempted, and global checks passed (see 9.).
    $raised = New-Object 'System.Collections.Generic.HashSet[string]'
    $attempted = New-Object 'System.Collections.Generic.HashSet[string]'
    $passedGlobal = New-Object 'System.Collections.Generic.HashSet[string]'
    $crashed = $false
    $notify = {
        # The key may be finer than the issue Kind (KeyKind), so a different failure is not silenced by an earlier one.
        param($Folder, $Kind, $Message, $KeyKind)
        if ([string]::IsNullOrEmpty($KeyKind)) { $KeyKind = $Kind }
        $key = '{0}|{1}' -f $Folder, $KeyKind
        $null = $raised.Add($key)
        Send-RunIssueToast -State $state -Config $Config -Now $Now -Key $key -Message $Message
    }

    # 1. Lock.
    $lock = Enter-MirrorLock -StateDir $Config.StateDir
    if ($null -eq $lock) { $skipped.Add('locked'); return (& $result) }

    $state = $null
    try {
        # A *.lck left in the bisync workdir is from an interrupted run: we hold the only lock.
        $null = Clear-StaleBisyncLocks -Config $Config
        # 2. State and config validation.
        $state = Get-MirrorState -StateDir $Config.StateDir
        $cfgErrors = @(Test-MirrorConfig -Config $Config)
        if ($cfgErrors.Count -gt 0) {
            # One toast for all config errors: they share the key global|config-invalid.
            # The key carries a hash of the error set: a changed error notifies again, an unchanged one once a day.
            $cfgKey = 'config-invalid|' + (Get-TextHash -Lines @($cfgErrors | ForEach-Object { [string]$_ }))
            & $notify 'global' 'config-invalid' (@($cfgErrors | ForEach-Object { 'Config error: ' + $_ }) -join "`n") $cfgKey
            foreach ($e in $cfgErrors) {
                $errors.Add('config: ' + $e)
                & $addIssue $null 'config-invalid' $e $null
            }
            return (& $result)
        }
        $null = $passedGlobal.Add('config-invalid')

        # 3. Private paths must be confirmed.
        if ($state.PrivateConfirmedHash -ne (Get-PrivatePathsHash -Config $Config)) {
            $msg = 'Encrypted folders not confirmed {0} run Confirm-PrivatePaths.ps1' -f [char]0x2013
            & $notify 'global' 'private-unconfirmed' $msg
            $errors.Add($msg)
            & $addIssue $null 'private-unconfirmed' $msg $null
            return (& $result)
        }
        $null = $passedGlobal.Add('private-unconfirmed')

        # 4. Budget.
        $left = Get-BudgetLeft -State $state -Config $Config -Now $Now
        if ($left.Month -le 0) {
            if (-not $state.BudgetPauseNotified) {
                Send-MirrorToast -Title $title -Message 'Monthly PikPak transfer budget used up; syncing paused until next month.' -Config $Config
                $state.BudgetPauseNotified = $true
            }
            $skipped.Add('budget')
            $monthPaused = $true
            return (& $result)
        }
        if ($state.MonthStopped -eq (Get-MonthKey -Now $Now)) {
            # A run was stopped by the monthly limit: the rest of the month is paused, quietly (no toast).
            Write-MirrorLog -Config $Config -Message 'this month''s transfer budget is used up; syncing continues next month'
            $skipped.Add('budget')
            $monthPaused = $true
            return (& $result)
        }
        if ($left.Day -le 0 -or $state.DayStopped -eq (Get-DayKey -Now $Now)) {
            # Today's share is used up (or a run was stopped by it; rclone stops before the limit, so bytes left
            # stay above 0): wait quietly for tomorrow (no toast, not a failure, not a success).
            Write-MirrorLog -Config $Config -Message "today's transfer budget is used up; syncing continues tomorrow"
            $skipped.Add('budget')
            $dayPaused = $true
            return (& $result)
        }
        $remaining = [long](Get-RunBudget -State $state -Config $Config -Now $Now)

        $ctx = @{ StateDir = $Config.StateDir; Now = $Now; LogCounter = 0 }
        $stopped = $false

        # 5. One bisync loop over every folder (Get-SyncFolders). Order: seeded encrypted folders (config order),
        #    seeded pairs (Priority, Name), then the folders that are not seeded yet (a first upload, or one cut
        #    off by the budget): encrypted ones (config order), then pairs (Priority, Name). A long seed so never
        #    holds back a folder that is already in sync. An encrypted folder is a synced folder whose PikPak side
        #    is the crypt remote: same flags, sentinel, resync, safety stops and state, under its own StateKey.
        $all = @(Get-SyncFolders -Config $Config)
        $isSeeded = {
            param($f)
            $e = $state.Pairs[$f.StateKey]
            ($null -ne $e) -and [bool]$e['Seeded']
        }
        $priv = @($all | Where-Object { $_.Kind -eq 'private' })
        $pairsSorted = @($all | Where-Object { $_.Kind -eq 'pair' })
        $folders = @(@($priv | Where-Object { & $isSeeded $_ }) + @($pairsSorted | Where-Object { & $isSeeded $_ }) +
            @($priv | Where-Object { -not (& $isSeeded $_) }) + @($pairsSorted | Where-Object { -not (& $isSeeded $_) }))
        if ($partial) {
            $folders = @($folders | Where-Object { $k = [string]$_.StateKey; @($only | Where-Object { $_ -ieq $k }).Count -gt 0 })
        }
        foreach ($folder in $folders) {
            if ($stopped) { break }
            $key = [string]$folder.StateKey
            $name = [string]$folder.Name
            $isPrivate = ($folder.Kind -eq 'private')
            $labelName = $name
            if ($isPrivate) { $labelName = 'private-' + $name }
            # A paused folder is not attempted at all: no issue, no notification, its memory stays as it is.
            if ($folder.Paused) { continue }
            if (-not (Test-Path -LiteralPath $folder.Local -PathType Container)) {
                $null = $attempted.Add($key)
                if ($isPrivate) { $msg = 'Encrypted folder missing, skipped: ' + $folder.Local }
                else { $msg = 'Folder missing, skipped: {0} ({1})' -f $name, $folder.Local }
                & $notify $key 'folder-missing' $msg
                $skipped.Add($key)
                & $addIssue $name 'folder-missing' $msg $null $isPrivate
                continue
            }
            if ($remaining -le 0) { $stopped = $true; break }
            $null = $attempted.Add($key)
            try {
                $ps = $state.Pairs[$key]
                if ($null -eq $ps) { $ps = @{ Seeded = $false; FilterHash = $null; Identity = $null; LastExit = $null; LastRun = $null }; $state.Pairs[$key] = $ps }
                # The folder ID (an entry without Id skips this, as before): is the folder at this path still the
                # one that was set up? If not, nothing is synced or deleted on either side.
                $hasId = -not [string]::IsNullOrEmpty([string]$folder.Id)
                if ($hasId) {
                    $problem = Test-FolderIdBeforeSync -Folder $folder -PairState $ps -AllFolders $all -Now $Now
                    if ($null -ne $problem) {
                        & $notify $key $problem.Kind $problem.Message
                        $errors.Add($problem.Message)
                        & $addIssue $name $problem.Kind $problem.Message $null $isPrivate
                        continue
                    }
                }
                $seeded = [bool]$ps['Seeded']
                $filter = Update-FolderFilterFile -Config $Config -Folder $folder
                $identity = Get-FolderIdentity -Folder $folder
                # A missing identity (state from before identities existed) is adopted silently on the next success.
                $identityChanged = (-not [string]::IsNullOrEmpty([string]$ps['Identity'])) -and ($ps['Identity'] -ne $identity)
                $forced = @(@($ForceResync) | Where-Object { $_ -and ([string]$_ -ieq $key) }).Count -gt 0
                $resync = (-not $seeded) -or ($ps['FilterHash'] -ne $filter.Hash) -or $identityChanged -or $forced
                $remotePath = [string]$folder.RemotePath
                # AcceptRemoteId: the owner chose "Use this folder anyway", so this resync (path1 wins) overwrites the
                # PikPak ID file with the PC one. Skipped once; cleared after the bisync unless a budget stop cut it off.
                $acceptRemote = [bool]$ps['AcceptRemoteId']
                if ($resync -and $hasId -and $acceptRemote) {
                    Write-MirrorLog -Config $Config -Message ('{0}: PikPak ID check skipped once (Use this folder anyway)' -f $name)
                }
                if ($resync -and $hasId -and -not $acceptRemote) {
                    # A resync merges both sides: the PikPak place must not hold another folder's copy. A normal
                    # run does not read it (a changed remote marker is a change bisync sees anyway).
                    $mlog = New-RunLogFile -Context $ctx -Label ('marker-' + $labelName)
                    $problem = Test-RemoteFolderIdBeforeSync -Folder $folder -LogFile $mlog
                    if ($null -ne $problem) {
                        $ilog = $null
                        $emsg = $problem.Message
                        if ($problem.Kind -eq 'other') { $ilog = $mlog; $emsg = '{0} ({1})' -f $problem.Message, $mlog }
                        & $notify $key $problem.Kind $problem.Message $problem.KeyKind
                        $errors.Add($emsg)
                        & $addIssue $name $problem.Kind $problem.Message $ilog $isPrivate
                        continue
                    }
                }
                # Each change toasts once (NotifiedIdentity/NotifiedFilterHash), not again on every run until the
                # resync succeeds, which can take several nights of budget stops.
                if ($identityChanged -and $ps['NotifiedIdentity'] -ne $identity) {
                    Send-MirrorToast -Title $title -Message ('{0} folder mapping changed: resyncing' -f $name) -Config $Config
                    $ps['NotifiedIdentity'] = $identity
                }
                # Plain copies only exist on the plain remote: the warning is for pairs. An encrypted folder's
                # filters change only with the global rules, which just resyncs it.
                # The advice is only right when a folder BECAME encrypted (an exclusion was added). When encryption
                # was removed from a folder (an exclusion went away) its plain copy is the one just uploaded on
                # purpose, so no toast. The excludes of the last good run are kept as text in FilterExcludes;
                # when unknown (state from before this existed) the toast stays, as it always was.
                if (-not $isPrivate -and $seeded -and $ps['FilterHash'] -ne $filter.Hash -and $ps['NotifiedFilterHash'] -ne $filter.Hash) {
                    $added = $true
                    if ($null -ne $ps['FilterExcludes']) {
                        $before = @(([string]$ps['FilterExcludes']) -split "`n" | Where-Object { $_ })
                        $added = (@(@($filter.Excludes) | Where-Object { $before -notcontains $_ }).Count -gt 0)
                    }
                    if ($added) {
                        $msg = 'Filters changed for {0}: delete any plain copy of newly encrypted folders under {1}' -f $name, $remotePath
                        Send-MirrorToast -Title $title -Message $msg -Config $Config
                    }
                    $ps['NotifiedFilterHash'] = $filter.Hash
                }
                if ($resync) {
                    # Upload the --check-access sentinel. copyto --ignore-existing (not touch): PikPak cannot set
                    # modtimes, so touching an existing remote sentinel fails and would block the folder forever.
                    $sentinel = Join-Path $folder.Local 'RCLONE_TEST'
                    if (-not (Test-Path -LiteralPath $sentinel)) { [IO.File]::WriteAllBytes($sentinel, [byte[]]@()) }
                    $tlog = New-RunLogFile -Context $ctx -Label ('sentinel-' + $labelName)
                    $t = Invoke-Rclone -Arguments @('copyto', $sentinel, (Join-RemoteChild -Base $remotePath -Parts @('RCLONE_TEST')),
                        '--ignore-existing', '--log-file', $tlog)
                    if ($t.ExitCode -ne 0) {
                        $ps['LastExit'] = $t.ExitCode; $ps['LastRun'] = $Now.ToString('o')
                        $msg = '{0}: creating remote RCLONE_TEST failed (exit {1}), see {2}' -f $name, $t.ExitCode, $tlog
                        & $notify $key 'sentinel-failed' $msg
                        $errors.Add($msg)
                        & $addIssue $name 'sentinel-failed' $msg $tlog $isPrivate
                        continue
                    }
                }
                $log = New-RunLogFile -Context $ctx -Label ('bisync-' + $labelName)
                $r = Invoke-Rclone -Arguments @(New-BisyncArgs -Config $Config -Folder $folder -FiltersFile $filter.Path -Date $Now `
                        -BudgetBytes $remaining -Resync:$resync -LogFile $log)
                Add-TransferredBytes -State $state -Bytes $r.Bytes -Now $Now
                $remaining -= [long]$r.Bytes
                $ps['LastExit'] = $r.ExitCode
                $ps['LastRun'] = $Now.ToString('o')
                if ($ps.ContainsKey('AcceptRemoteId') -and -not ($r.ExitCode -eq 8 -or $r.BudgetHit)) { $ps.Remove('AcceptRemoteId') }
                if ($r.ExitCode -eq 0) {
                    $ps['Seeded'] = $true
                    $ps['FilterHash'] = $filter.Hash
                    $ps['FilterExcludes'] = (@($filter.Excludes) -join "`n")
                    $ps['Identity'] = $identity
                    $ran.Add($key)
                }
                elseif ($r.ExitCode -eq 8 -or $r.BudgetHit) {
                    # Budget stop. Inside bisync the cutoff aborts the run (exit 7) and the listings are lost, so the
                    # next run must --resync (how seeding continues). Not an error: no toast, filter/identity kept.
                    $stopped = $true
                    $null = $attempted.Remove($key)   # cut off: its earlier problems are not judged solved
                    $ps['Seeded'] = $false
                    Write-MirrorLog -Config $Config -Message ('{0}: run budget reached, continues at the next sync' -f $name)
                }
                elseif ($r.EmptyListing) {
                    $side = 'PC'
                    if ($r.EmptyListing -eq 'Path2') { $side = 'PikPak' }
                    $msg = '{0}: the {1} folder is empty, so nothing was synced or deleted. If that is a mistake, see README "A folder keeps failing".' -f $name, $side
                    & $notify $key 'folder-empty' $msg
                    $errors.Add(('{0} ({1})' -f $msg, $log))
                    & $addIssue $name 'folder-empty' $msg $log $isPrivate
                }
                elseif ($r.TooManyDeletes) {
                    # Repair (--resync) merges both sides, so it brings the deleted files back; deleting on purpose
                    # needs a higher limit for one sync.
                    $msg = ("{0}: more than {1}% of the folder would be deleted, so nothing was synced. To get the files back, use Repair. " +
                        "If you deleted them on purpose, raise 'Stop and ask me if a sync would delete more than' in Settings, Advanced, " +
                        "for one sync, then set it back.") -f $name, $Config.MaxDeletePercent
                    & $notify $key 'delete-safety' $msg
                    $errors.Add(('{0} ({1})' -f $msg, $log))
                    & $addIssue $name 'delete-safety' $msg $log $isPrivate
                }
                elseif (@($r.StuckUploads | Where-Object { $_ }).Count -gt 0) {
                    # A hard kill left PikPak holding a hidden unfinished upload of these names. Resync automatically
                    # next run (everything else still syncs); only the stuck names keep failing until renamed.
                    $names = @($r.StuckUploads | Where-Object { $_ })
                    $list = (@($names | Select-Object -First 3) -join ', ')
                    if ($names.Count -gt 3) { $list += ', ' + [char]0x2026 }
                    $msg = '{0}: PikPak is still holding an unfinished upload of {1} from an interrupted sync. See README "Stuck uploads".' -f $name, $list
                    & $notify $key 'stuck-upload' $msg
                    $errors.Add(('{0} ({1})' -f $msg, $log))
                    & $addIssue $name 'stuck-upload' $msg $log $isPrivate
                    $ps['Seeded'] = $false
                }
                elseif ($r.NeedsResync) {
                    $msg = '{0} needs a repair run: see README "A folder keeps failing".' -f $name
                    & $notify $key 'needs-repair' $msg
                    $errors.Add(('{0} ({1})' -f $msg, $log))
                    & $addIssue $name 'needs-repair' $msg $log $isPrivate
                }
                else {
                    $msg = 'Sync {0} failed (exit {1}), see {2}' -f $name, $r.ExitCode, $log
                    & $notify $key 'other' $msg ('other-exit' + $r.ExitCode)
                    $errors.Add($msg)
                    & $addIssue $name 'other' $msg $log $isPrivate
                }
            }
            catch {
                $msg = 'Sync {0} failed: {1}' -f $name, $_.Exception.Message
                & $notify $key 'other' $msg 'other-exception'
                $errors.Add($msg)
                & $addIssue $name 'other' $msg $null $isPrivate
            }
        }
        if ($stopped) {
            $skipped.Add('budget')
            # Remember which limit was the binding (smaller) one, so the rest of that day / month is paused.
            $after = Get-BudgetLeft -State $state -Config $Config -Now $Now
            if ($after.Month -le $after.Day) { $state.MonthStopped = Get-MonthKey -Now $Now }
            else { $state.DayStopped = Get-DayKey -Now $Now }
        }

        # 6. Prune holding areas (exit 3 = directory not found yet, which is fine), then old logs: at most once a
        #    day (State.LastPruneDay), and again at the next run when a prune failed.
        #    Without private folders there may be no private remote at all (rclone would fail on every run).
        if (-not $partial -and $state.LastPruneDay -ne (Get-DayKey -Now $Now)) {
            $targets = @(
                (Join-RemotePath $Config.Remote @($Config.HoldingRoot)),
                $Config.LocalHolding
            )
            if (@(@($Config['PrivatePaths']) | Where-Object { $_ }).Count -gt 0) {
                $targets += (Join-RemotePath $Config.PrivateRemote @('_holding'))
            }
            $n = 0
            $pruneFailed = $false
            foreach ($target in $targets) {
                $n++
                $log = New-RunLogFile -Context $ctx -Label ('prune-' + $n)
                $r = Invoke-Rclone -Arguments @(New-PruneArgs -Target $target -Now $Now -Days ([int]$Config.HoldingDays) -LogFile $log)
                if ($r.ExitCode -ne 0 -and $r.ExitCode -ne 3) {
                    $pruneFailed = $true
                    $msg = 'Pruning {0} failed (exit {1}), see {2}' -f $target, $r.ExitCode, $log
                    & $notify 'global' 'prune-failed' $msg
                    $errors.Add($msg)
                    & $addIssue $null 'prune-failed' $msg $log
                }
            }
            $null = $passedGlobal.Add('prune-failed')
            Remove-OldLogs -Config $Config -Now $Now
            if (-not $pruneFailed) { $state.LastPruneDay = Get-DayKey -Now $Now }
        }

        # 7. Monthly quota warning.
        $used = [long]0
        if ($state.Month -eq (Get-MonthKey -Now $Now)) { $used = [long]$state.TransferredBytes }
        $monthly = [double]$Config.MonthlyBudgetGB * 1073741824
        if ($monthly -gt 0 -and -not $state.QuotaWarned -and ($used / $monthly * 100) -ge [double]$Config.QuotaWarnPercent) {
            $pct = [int][Math]::Floor($used / $monthly * 100)
            Send-MirrorToast -Title $title -Message ('PikPak transfer at {0}% of the monthly budget.' -f $pct) -Config $Config
            $state.QuotaWarned = $true
        }

        # 8. Success bookkeeping (a run of some folders only says nothing about the others).
        if (-not $partial) {
            if ($errors.Count -eq 0) { $state.LastSuccess = $Now.ToString('o') }
            if (Test-StaleSuccess -State $state -Config $Config -Now $Now) {
                & $notify 'global' 'stale' ('No successful sync for {0}+ days' -f $Config.StaleRunDays)
            }
            $null = $passedGlobal.Add('stale')
        }
        return (& $result)
    }
    catch {
        $crashed = $true
        # An unexpected failure must never leave a stale "ok" behind; the exception still propagates.
        & $addIssue $null 'other' $_.Exception.Message $null
        throw
    }
    finally {
        # 9. Always persist state and release the lock.
        try {
            if ($null -ne $state) {
                # Forget solved problems: a folder that was attempted and did not raise a kind this run, a global
                # check that was passed without raising. Not after a crash (unknown outcome); untouched keys stay.
                if (-not $crashed) {
                    foreach ($k in @($state.Notified.Keys)) {
                        $ks = [string]$k
                        if ($raised.Contains($ks)) { continue }
                        if ($ks.StartsWith('global|')) {
                            # global keys may carry a suffix (config-invalid|<hash>): the check is the part before it
                            $check = $ks.Substring(7).Split('|')[0]
                            if ($passedGlobal.Contains($check)) { $state.Notified.Remove($k) }
                            continue
                        }
                        $bar = $ks.LastIndexOf('|')
                        if ($bar -lt 0) { continue }
                        if ($attempted.Contains($ks.Substring(0, $bar))) { $state.Notified.Remove($k) }
                    }
                }
                # A paused run attempted nothing: it keeps the last real run's problems on Home.
                if (($monthPaused -or $dayPaused) -and $null -ne $state.LastRunInfo) {
                    foreach ($x in @(@($state.LastRunInfo['Issues']) | Where-Object { $null -ne $_ })) { $issues.Add($x) }
                }
                elseif ($partial -and $null -ne $state.LastRunInfo) {
                    # A run of some folders keeps the last run's problems of every other folder, and its global
                    # problems of a kind this run did not raise again (a prune failure, say).
                    $globalKinds = @($issues | Where-Object { $null -eq $_.Pair } | ForEach-Object { [string]$_.Kind })
                    foreach ($x in @(@($state.LastRunInfo['Issues']) | Where-Object { $null -ne $_ })) {
                        if ($null -eq $x.Pair) {
                            if ($globalKinds -notcontains [string]$x.Kind) { $issues.Add($x) }
                            continue
                        }
                        $xk = [string]$x.Pair
                        if ([bool]$x.Private) { $xk = 'private:' + $xk }
                        if (@($only | Where-Object { $_ -ieq $xk }).Count -eq 0) { $issues.Add($x) }
                    }
                }
                $res = 'ok'
                if ($monthPaused) { $res = 'month-paused' }
                elseif ($dayPaused) { $res = 'day-paused' }
                elseif (@($issues | Where-Object { $_.Kind -ne 'folder-missing' }).Count -gt 0) { $res = 'failed' }
                elseif ($skipped.Contains('budget')) { $res = 'budget-stopped' }
                $state.LastRunInfo = @{ Started = $Now.ToString('o'); Finished = (Get-Date).ToString('o'); Result = $res; Issues = $issues.ToArray() }
                Save-MirrorState -StateDir $Config.StateDir -State $state
            }
        }
        finally { Exit-MirrorLock -Handle $lock }
    }
}
