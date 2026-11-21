# Folder list backup actions of the app bridge. Loaded after GuiActions.ps1 (uses its helpers).
# Windows PowerShell 5.1 compatible, ASCII source.

function Invoke-GuiActionBackupPush {
    # Uploads the folder list backup when it changed. Not a write action (it changes nothing on this PC but the
    # backup status file), so it also runs while a sync is going. A failed upload is data, not an error envelope.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $cfg = $Ctx.Config
    if (Test-GuiPreview $Ctx) {
        $where = Join-RemotePath ([string]$cfg.Remote) @([string]$cfg.MirrorRoot, $script:BackupPlainName)
        return @{ uploaded = $false; skipped = $false; error = $null; preview = @("Would upload your folder list to PikPak ($where).") }
    }
    $r = Publish-ConfigBackup -ConfigPath $Ctx.ConfigPath -Config $cfg -Now $Ctx.Now
    @{ uploaded = [bool]$r.Uploaded; skipped = [bool]$r.Skipped; error = $r.Error }
}

function Get-GuiBackupInfo {
    # The Home facts about the backup: since when it keeps failing (ISO text or $null) and whether that is longer
    # than StaleRunDays days. Never throws.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][datetime]$Now)
    $info = @{ failingSince = $null; stale = $false }
    try {
        $st = Get-BackupStatus -StateDir ([string]$Config.StateDir)
        if (-not [string]::IsNullOrEmpty([string]$st.FailingSince)) {
            $info.failingSince = [string]$st.FailingSince
            $since = [datetime]::MinValue
            if ([datetime]::TryParse([string]$st.FailingSince, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$since)) {
                $info.stale = (($Now - $since).TotalDays -gt [double]$Config.StaleRunDays)
            }
        }
    }
    catch { }
    $info
}

# ===== Using an existing recovery key ================================================================
# The owner's key is typed in setup (setup.usekey) or later in Settings (private.usekey). Secrets only arrive in
# args 'recoveryKey' and 'salt'; they are cleared after use and never reach an error message, a log or a result.

function Get-GuiKeyRemotes {
    # The rclone remote names: from the config when there is one, else the defaults New-GuiSetupConfig writes.
    param([hashtable]$Ctx)
    $base = 'pikpak'; $priv = 'private'
    if ($null -ne $Ctx -and $null -ne $Ctx.Config) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Ctx.Config.Remote)) { $base = [string]$Ctx.Config.Remote }
        if (-not [string]::IsNullOrWhiteSpace([string]$Ctx.Config.PrivateRemote)) { $priv = [string]$Ctx.Config.PrivateRemote }
    }
    @{ Base = $base; Private = $priv }
}

function Get-GuiKeyArgs {
    # The typed key as @{ Password; Salt }. Without a salt it is the app's 30-character recovery key (any case,
    # spaces and dashes allowed); with a salt it is the password and salt of a key made by Install.ps1, both as
    # typed (trimmed). A value Windows PowerShell 5.1 cannot pass to rclone is refused here, before any rclone call.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $typed = [string](Get-GuiArg $Ctx 'recoveryKey' '')
    $salt = ([string](Get-GuiArg $Ctx 'salt' '')).Trim()
    if ($salt -eq '') {
        $key = ConvertTo-RecoveryKey -Text $typed
        if ($null -eq $key) { throw (New-GuiException 'bad-request' "That isn't a recovery key. It has 30 letters and numbers.") }
        return @{ Password = $key; Salt = '' }
    }
    $pw = $typed.Trim()
    if ($pw -eq '') { throw (New-GuiException 'bad-request' 'Type both the password and the salt of your key.') }
    if (-not ((Test-NativeArgumentSafe -Value $pw) -and (Test-NativeArgumentSafe -Value $salt))) {
        throw (New-GuiException 'bad-request' (Get-UnsafePasswordMessage))
    }
    @{ Password = $pw; Salt = $salt }
}

function Get-GuiEncryptedRestoreList {
    # The encrypted folders the key opens: @{ source = 'backup'|'idfiles'; folders = @(@{ name; id; lastPath; paused;
    # entry; resolved }) } (resolved: where lastPath goes on this PC, as a Pair's Resolved). From the companion file in the encrypted remote when it is a valid backup that lists at least one
    # folder (entry = the raw entry of the config); otherwise one row per folder in the remote with its ID file
    # (entry = $null).
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    $remote = $names.Private + ':'
    $cat = Invoke-GuiRclone -RcloneArgs @('cat', ($remote + $script:BackupEncryptedName))
    if ($cat.ExitCode -eq 0) {
        $doc = ConvertFrom-BackupText -Text (@($cat.Output) -join "`n") -Kind 'encrypted'
        if (-not $doc.ContainsKey('Invalid')) {
            $rows = New-Object System.Collections.Generic.List[object]
            foreach ($e in @($doc.PrivatePaths)) {
                if ($e -isnot [hashtable] -or [string]::IsNullOrWhiteSpace([string]$e['Name'])) { continue }
                $id = $null; if (-not [string]::IsNullOrEmpty([string]$e['Id'])) { $id = [string]$e['Id'] }
                $last = $null; if (-not [string]::IsNullOrEmpty([string]$e['Path'])) { $last = [string]$e['Path'] }
                $rows.Add(@{ name = [string]$e['Name']; id = $id; lastPath = $last; paused = ($e['Paused'] -eq $true); entry = $e; resolved = (Get-GuiRestorePathInfo -Path $last) })
            }
            # A companion file that lists no encrypted folder says nothing about what PikPak holds.
            if ($rows.Count -gt 0) { return @{ source = 'backup'; folders = $rows.ToArray() } }
        }
    }
    # No usable companion file: what PikPak itself holds. Get-GuiRemotePrivateNames needs a config for the remote
    # name only, and setup has none yet.
    $cfg = $Ctx.Config
    if ($null -eq $cfg) { $cfg = @{ PrivateRemote = $names.Private } }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($n in @(Get-GuiRemotePrivateNames -Ctx @{ Config = $cfg })) {
        $r = Invoke-GuiRclone -RcloneArgs @('cat', ($remote + $n + '/' + (Get-FolderMarkerName -Kind 'private')))
        $found = ConvertTo-RemoteMarkerResult -Result $r
        if ($found.Failed) {
            Write-GuiLog $Ctx.Config ('Reading the ID file of {0}{1} failed (exit {2})' -f $remote, $n, $r.ExitCode)
            throw (New-GuiException 'remote-failed' "Your encrypted folders in PikPak couldn't be listed. Try again.")
        }
        $id = $null; $last = $null
        if ($found.Found -and -not $found.Marker.ContainsKey('Invalid')) {
            $id = [string]$found.Marker.Id
            if (-not [string]::IsNullOrEmpty([string]$found.Marker.LastPath)) { $last = [string]$found.Marker.LastPath }
        }
        $rows.Add(@{ name = $n; id = $id; lastPath = $last; paused = $false; entry = $null; resolved = (Get-GuiRestorePathInfo -Path $last) })
    }
    @{ source = 'idfiles'; folders = $rows.ToArray() }
}

function Get-GuiExistingKeyState {
    # What the 'private' rclone remote on this PC does: 'none' (no such remote), 'opens' (it opens the data in
    # PikPak, or PikPak holds nothing to contradict it), 'wrong' (PikPak holds data and the remote opens none of it)
    # or 'unchecked' (PikPak, or the remote, could not be listed: "try again", never "wrong"). Changes nothing. -RawCount reuses a count of PC-Private entries
    # the caller already has.
    param([Parameter(Mandatory)][hashtable]$Ctx, [int]$RawCount = -2)
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    if (-not (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name $names.Private)) { return 'none' }
    if ($RawCount -eq -2) { $RawCount = Get-RemoteEntryCount -Target ($names.Base + ':PC-Private') }
    if ($RawCount -lt 0) { return 'unchecked' }
    if ($RawCount -eq 0) { return 'opens' }
    $x = Invoke-GuiRclone -RcloneArgs @('lsf', ($names.Private + ':'), '--dirs-only')
    if ($x.ExitCode -ne 0) { return 'unchecked' }
    if (@(@($x.Output) | ForEach-Object { ([string]$_).TrimEnd('/') } | Where-Object { Test-EncryptedFolderName $_ }).Count -gt 0) { return 'opens' }
    # No folder of its own (only files or the holding area): anything the key decrypts shows it is the right key.
    if ((Get-RemoteEntryCount -Target ($names.Private + ':')) -gt 0) { return 'opens' }
    'wrong'
}

function Test-GuiExistingKeyOpens {
    # $true when this PC has a 'private' rclone remote and it opens the encrypted data in PikPak.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    (Get-GuiExistingKeyState -Ctx $Ctx) -eq 'opens'
}

function Invoke-GuiUseKey {
    # Shared by setup.usekey and private.usekey. -Setup: an existing 'private' remote that opens the data is used
    # as it is. Otherwise an existing remote is a refusal. A 'private' remote is never deleted here: it may hold
    # the owner's only working key.
    param([Parameter(Mandatory)][hashtable]$Ctx, [switch]$Setup)
    # In setup, no key typed at all asks to use this PC's existing 'private' remote (setup.discover said hasKey):
    # it is used only when it opens the data, else the owner is asked to type the key.
    $noKey = $Setup -and ([string](Get-GuiArg $Ctx 'recoveryKey' '')).Trim() -eq '' -and ([string](Get-GuiArg $Ctx 'salt' '')).Trim() -eq ''
    $k = $null
    if (-not $noKey) { $k = Get-GuiKeyArgs -Ctx $Ctx }
    $Ctx.Args['recoveryKey'] = $null
    $Ctx.Args['salt'] = $null
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    $target = $names.Base + ':PC-Private'
    $typeKey = 'Type your recovery key.'
    try {
        if ($noKey -and -not (Test-GuiPreview $Ctx) -and -not (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name $names.Private)) {
            throw (New-GuiException 'bad-request' $typeKey)
        }
        if (Test-GuiPreview $Ctx) {
            if ($noKey) {
                return @{ source = $null; folders = @(); usedExisting = $true
                    preview = @(("Would check that this PC's rclone remote '{0}' opens the encrypted folders in {1}, then list them." -f $names.Private, $target)) }
            }
            return @{ source = $null; folders = @(); usedExisting = $false
                preview = @(("Would check that {0} holds encrypted folders, then create the rclone remote '{1}' with the key you typed (it is removed again when it opens nothing)." -f $target, $names.Private)) }
        }
        if (-not $Setup -and (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name $names.Private)) {
            throw (New-GuiException 'refused' ("This PC already has a recovery key (rclone remote '{0}'). It was not replaced." -f $names.Private))
        }
        $raw = Get-RemoteEntryCount -Target $target
        if ($raw -lt 0) { throw (New-GuiException 'remote-failed' "PikPak couldn't be checked, so the key wasn't used. Check your internet connection and try again.") }
        if ($raw -eq 0) { throw (New-GuiException 'refused' 'PikPak holds no encrypted folders, so there is nothing for a recovery key to open.') }
        if ($Setup) {
            $state = Get-GuiExistingKeyState -Ctx $Ctx -RawCount $raw
            if ($state -eq 'opens') {
                $res = Get-GuiEncryptedRestoreList -Ctx $Ctx
                $res['usedExisting'] = $true
                return $res
            }
            if ($state -eq 'unchecked') { throw (New-GuiException 'remote-failed' "PikPak couldn't be checked, so the key wasn't used. Check your internet connection and try again.") }
            if ($noKey) { throw (New-GuiException 'bad-request' $typeKey) }
            if ($state -eq 'wrong') {
                throw (New-GuiException 'refused' ("This PC already has a different recovery key in rclone (remote '{0}'). Remove it with rclone config, then try again." -f $names.Private))
            }
        }
        # Never reached without a key ($noKey is setup only and every setup state above returned or threw).
        if ($noKey) { throw (New-GuiException 'bad-request' $typeKey) }
        try { $null = New-MirrorPrivateRemote -Name $names.Private -BaseRemote $names.Base -Password $k.Password -Salt $k.Salt -Mode Existing }
        catch { throw (New-GuiException 'bad-key' "That key doesn't open your encrypted folders. Check it and try again.") }
    }
    finally { $k = $null }
    $res = Get-GuiEncryptedRestoreList -Ctx $Ctx
    $res['usedExisting'] = $false
    $res
}

function Invoke-GuiActionSetupUsekey {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    Invoke-GuiUseKey -Ctx $Ctx -Setup
}

function Invoke-GuiActionPrivateUsekey {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    if (-not (Test-GuiPreview $Ctx)) { Assert-GuiNotSyncing -Ctx $Ctx }
    Invoke-GuiUseKey -Ctx $Ctx
}

function Invoke-GuiActionPrivateKeyState {
    # Whether this PC has a recovery key (the 'private' remote) and, when it has none, whether PikPak holds
    # encrypted data it cannot open. The entries are only counted when there is no key. Changes nothing.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    if (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name $names.Private) { return @{ hasKey = $true; encryptedData = $false } }
    $raw = Get-RemoteEntryCount -Target ($names.Base + ':PC-Private')
    if ($raw -lt 0) { throw (New-GuiException 'remote-failed' "PikPak couldn't be checked. Try again.") }
    @{ hasKey = $false; encryptedData = ($raw -gt 0) }
}

# ===== Setup with a restore ==========================================================================
# After sign-in: setup.discover reads the backup, setup.scan rebuilds the list from the ID files when there is no
# backup, setup.sizes asks PikPak how much each folder holds, and setup.finish with args.restore saves the chosen
# folders. None of them needs a config. Restore never deletes anything in PikPak.

function Get-GuiMirrorRootName {
    param([hashtable]$Ctx)
    if ($null -ne $Ctx -and $null -ne $Ctx.Config -and -not [string]::IsNullOrWhiteSpace([string]$Ctx.Config.MirrorRoot)) { return [string]$Ctx.Config.MirrorRoot }
    'PC-Mirror'
}

function Get-GuiRestorePathInfo {
    # Where a backed-up local path goes on this PC (Resolve-RestorePath). No path: nowhere yet, so the row needs a
    # place chosen.
    param([AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return @{ Path = $null; Moved = $false; DriveMissing = $true } }
    Resolve-RestorePath -Path $Path -UserProfile ([string]$env:USERPROFILE) -PathExists { param($p) Test-Path -LiteralPath $p }
}

function Invoke-GuiActionSetupDiscover {
    # @{ backup; backupProblem; encryptedData; hasKey }: the parsed backup with each Pair's Resolved place (or $null),
    # why a backup file that exists could not be used, whether PikPak holds encrypted folders, and whether this PC's
    # rclone already has a key that opens them. A failure to read PikPak is remote-failed, never a guess.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    $where = Join-RemotePath $names.Base @((Get-GuiMirrorRootName -Ctx $Ctx), $script:BackupPlainName)
    $private = $names.Base + ':PC-Private'
    if (Test-GuiPreview $Ctx) {
        return @{ backup = $null; backupProblem = $null; encryptedData = $false; hasKey = $false
            preview = @(("Would read your folder list backup ({0}) and check whether {1} holds encrypted folders and this PC's recovery key opens them." -f $where, $private)) }
    }
    $backup = $null; $problem = $null
    $cat = Invoke-GuiRclone -RcloneArgs @('cat', $where)
    if ($cat.ExitCode -eq 0) {
        $doc = ConvertFrom-BackupText -Text (@($cat.Output) -join "`n") -Kind 'plain'
        if ($doc.ContainsKey('Invalid')) { $problem = [string]$doc.Reason }
        else {
            $pairs = New-Object System.Collections.Generic.List[object]
            foreach ($p in @($doc.Config['Pairs'])) {
                if ($p -isnot [hashtable]) { continue }
                $row = @{} + $p
                $row['Resolved'] = Get-GuiRestorePathInfo -Path ([string]$p['Local'])
                $pairs.Add($row)
            }
            $backup = @{ Config = $doc.Config; GlobalFilters = $doc.GlobalFilters; PrivatePaths = @(); Saved = $doc.Saved; PcName = $doc.PcName; Pairs = $pairs.ToArray() }
        }
    }
    elseif ($cat.ExitCode -ne 3 -and $cat.ExitCode -ne 4) {
        Write-GuiLog $Ctx.Config ('Reading the folder list backup failed (exit {0})' -f $cat.ExitCode)
        throw (New-GuiException 'remote-failed' "Your folder list backup in PikPak couldn't be read. Check your internet connection and try again.")
    }
    $raw = Get-RemoteEntryCount -Target $private
    if ($raw -lt 0) { throw (New-GuiException 'remote-failed' "PikPak couldn't be checked for encrypted folders. Check your internet connection and try again.") }
    $state = Get-GuiExistingKeyState -Ctx $Ctx -RawCount $raw
    if ($state -eq 'unchecked') { throw (New-GuiException 'remote-failed' "PikPak couldn't be checked for encrypted folders. Check your internet connection and try again.") }
    @{ backup = $backup; backupProblem = $problem; encryptedData = ($raw -gt 0); hasKey = ($state -eq 'opens') }
}

function Invoke-GuiActionSetupScan {
    # The synced folders found from their ID files in PikPak, as Pairs ready for the restore screen:
    # @{ pairs = @(@{ Name; Local (the last path); Remote; Id; Priority; Resolved }) }.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    $root = Get-GuiMirrorRootName -Ctx $Ctx
    if (Test-GuiPreview $Ctx) {
        return @{ pairs = @(); preview = @(("Would look for the ID files of your synced folders in {0} and read each one." -f (Join-RemotePath $names.Base @($root)))) }
    }
    try { $found = @(Find-RemoteSyncedFolders -Remote $names.Base -MirrorRoot $root -Config $Ctx.Config) }
    catch {
        Write-GuiLog $Ctx.Config ('Looking for synced folders in PikPak failed: ' + $_.Exception.Message)
        throw (New-GuiException 'remote-failed' "Your folders in PikPak couldn't be looked up. Check your internet connection and try again.")
    }
    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($f in $found) {
        $pairs.Add(@{ Name = $f.Name; Local = $f.LastPath; Remote = $f.Remote; Id = $f.Id; Priority = 3; Resolved = (Get-GuiRestorePathInfo -Path $f.LastPath) })
    }
    @{ pairs = $pairs.ToArray() }
}

function Invoke-GuiActionSetupSizes {
    # @{ sizes = @{ <place> = <bytes or $null> } } from 'rclone size --json' for each place in args.places, which must
    # be in the PikPak remote or the encrypted remote. A place PikPak cannot size gets $null.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    $places = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-GuiArg $Ctx 'places' @())) {
        $t = [string]$p
        $ok = ($p -is [string]) -and ($t.IndexOfAny([char[]]@([char]13, [char]10)) -lt 0) -and
            ($t.StartsWith($names.Base + ':', [StringComparison]::Ordinal) -or $t.StartsWith($names.Private + ':', [StringComparison]::Ordinal))
        if (-not $ok) { throw (New-GuiException 'bad-request' ("'{0}' isn't a place in PikPak." -f $t)) }
        $places.Add($t)
    }
    if (Test-GuiPreview $Ctx) {
        return @{ sizes = @{}; preview = @(('Would ask PikPak how much {0} folder(s) hold.' -f $places.Count)) }
    }
    $sizes = @{}
    foreach ($t in $places) {
        $bytes = $null
        $r = Invoke-GuiRclone -RcloneArgs @('size', $t, '--json')
        if ($r.ExitCode -eq 0) {
            try { $bytes = [long]((@($r.Output) -join "`n" | ConvertFrom-Json -ErrorAction Stop).bytes) } catch { $bytes = $null }
        }
        $sizes[$t] = $bytes
    }
    @{ sizes = $sizes }
}

function Get-GuiRestoreArg {
    # args.restore of setup.finish, checked: @{ settings; pairs; privatePaths; globalFilters; keySkipped } with
    # hashtable rows, or $null when the setup chose folders instead.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $r = Get-GuiArg $Ctx 'restore' $null
    if ($null -eq $r) { return $null }
    if ($r -isnot [hashtable] -or $null -ne (Get-GuiArg $Ctx 'folders' $null)) { throw (New-GuiException 'bad-request' 'The folder list is not valid.') }
    $out = @{ settings = @{}; pairs = @(); privatePaths = @(); globalFilters = ''; keySkipped = ($r['keySkipped'] -eq $true) }
    if ($null -ne $r['settings']) {
        if ($r['settings'] -isnot [hashtable]) { throw (New-GuiException 'bad-request' 'The settings to restore are not valid.') }
        $out.settings = $r['settings']
    }
    foreach ($k in @('pairs', 'privatePaths')) {
        $rows = @(@($r[$k]) | Where-Object { $null -ne $_ })
        foreach ($row in $rows) { if ($row -isnot [hashtable]) { throw (New-GuiException 'bad-request' 'The folder list is not valid.') } }
        $out[$k] = $rows
    }
    if ($r['globalFilters'] -is [string]) { $out.globalFilters = $r['globalFilters'] }
    if ($out.pairs.Count + $out.privatePaths.Count -eq 0) { throw (New-GuiException 'bad-request' 'Choose at least one folder to sync.') }
    if ($out.keySkipped -and $out.privatePaths.Count -gt 0) { throw (New-GuiException 'bad-request' 'Encrypted folders can only be restored with your recovery key.') }
    $out
}

function New-GuiRestoreSetupConfig {
    # The raw config of a restore: the backup's settings, the chosen folders as they were (Id, Remote, Name kept)
    # and the preset's setup defaults for anything missing. A synced folder that holds encrypted folders and gets no
    # restored encrypted folder under it is restored paused (PausedForKey says why), so it cannot upload them
    # readable. The rclone
    # remote names are this PC's: setup.signin made 'pikpak' and setup.usekey 'private'.
    param(
        [Parameter(Mandatory)][hashtable]$Restore,
        [Parameter(Mandatory)][hashtable]$Preset,
        [Parameter(Mandatory)][string]$DriveRoot,
        [string]$Holding
    )
    $defaults = New-GuiSetupConfig -Folders @() -Preset $Preset -DriveRoot $DriveRoot -Holding $Holding
    # Where the restored encrypted folders are. One whose path cannot be resolved counts as not restored (fail closed).
    $privateKeys = @()
    foreach ($e in @($Restore.privatePaths)) {
        try { $privateKeys += , (ConvertTo-PrefixKey (ConvertTo-MirrorPath ([string]$e['Path']))) } catch { }
    }
    $pairs = New-Object System.Collections.Generic.List[hashtable]
    foreach ($p in @($Restore.pairs)) {
        $row = @{} + $p
        $row.Remove('Resolved')
        # A synced folder that held encrypted folders keeps them out of PikPak only through the filter rules of
        # restored PrivatePaths entries under it. With none (key skipped, folder unticked or moved elsewhere) it
        # is restored paused for the key. A folder the owner paused stays paused as it was, so entering the key
        # later never resumes it.
        if ($row['holdsEncrypted'] -eq $true -and $row['Paused'] -ne $true) {
            $covered = $false
            try {
                $localKey = ConvertTo-PrefixKey (ConvertTo-MirrorPath ([string]$row['Local']))
                foreach ($pk in $privateKeys) { if ($pk.StartsWith($localKey, [StringComparison]::Ordinal)) { $covered = $true; break } }
            }
            catch { $covered = $false }
            if (-not $covered) { $row['Paused'] = $true; $row['PausedForKey'] = $true }
        }
        $pairs.Add($row)
    }
    $priv = New-Object System.Collections.Generic.List[hashtable]
    foreach ($e in @($Restore.privatePaths)) { $priv.Add($e) }
    $cfg = New-RestoreConfig -Settings $Restore.settings -Pairs $pairs.ToArray() -PrivatePaths $priv.ToArray() -Defaults $defaults `
        -PathExists { param($p) Test-Path -LiteralPath $p }
    $cfg['Remote'] = $defaults['Remote']
    $cfg['PrivateRemote'] = $defaults['PrivateRemote']
    $cfg
}

function Confirm-GuiRestoreKey {
    # The recovery key step of a restore: the key was entered with setup.usekey, so the 'private' remote must be
    # there. A new key is never made here.
    param([switch]$WhatIf)
    if ($WhatIf) { return "Would use the recovery key you entered (rclone remote 'private'); no new key is made." }
    if (-not (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name 'private')) {
        throw "This PC has no recovery key yet (rclone remote 'private'). Go back and type your recovery key; nothing was saved."
    }
    'Recovery key from your earlier install is in use'
}

function Save-GuiRestoreFilters {
    # Writes the backup's global filter rules to the config's filter file, UTF-8 without BOM. No rules in the backup
    # leaves the file that is there.
    param([Parameter(Mandatory)][hashtable]$Config, [AllowEmptyString()][string]$Text, [switch]$WhatIf)
    $file = [string]$Config['GlobalFiltersFile']
    if ([string]::IsNullOrEmpty($Text)) { return 'No filter rules in the backup; the filter file was left as it is.' }
    if ($WhatIf) { return ('Would write your filter rules to {0}' -f $file) }
    $dir = Split-Path -Path $file -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($file, $Text, (New-Object Text.UTF8Encoding $false))
    ('Filter rules written to {0}' -f $file)
}

function Invoke-GuiRestoreBackupPush {
    # The last step of a restore: the folder list is uploaded once. A failure is a quiet line, never a failed step.
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][datetime]$Now, [switch]$WhatIf)
    if ($WhatIf) { return 'Would upload your folder list to PikPak.' }
    $r = Publish-ConfigBackup -ConfigPath $ConfigPath -Config $Config -Now $Now -Force
    if ($r.Error) { return "Your folder list couldn't be backed up to PikPak yet; the next sync tries again." }
    'Folder list backed up to PikPak'
}
