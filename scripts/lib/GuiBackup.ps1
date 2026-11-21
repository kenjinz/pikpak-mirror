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
    # entry }) }. From the companion file in the encrypted remote when it is a valid backup (entry = the raw entry
    # of the config); otherwise one row per folder in the remote with its ID file (entry = $null).
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
                $rows.Add(@{ name = [string]$e['Name']; id = $id; lastPath = $last; paused = ($e['Paused'] -eq $true); entry = $e })
            }
            return @{ source = 'backup'; folders = $rows.ToArray() }
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
        $rows.Add(@{ name = $n; id = $id; lastPath = $last; paused = $false; entry = $null })
    }
    @{ source = 'idfiles'; folders = $rows.ToArray() }
}

function Get-GuiExistingKeyState {
    # What the 'private' rclone remote on this PC does: 'none' (no such remote), 'opens' (it opens the data in
    # PikPak, or PikPak holds nothing to contradict it), 'wrong' (PikPak holds data and the remote opens none of it)
    # or 'unchecked' (PikPak could not be listed). Changes nothing. -RawCount reuses a count of PC-Private entries
    # the caller already has.
    param([Parameter(Mandatory)][hashtable]$Ctx, [int]$RawCount = -2)
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    if (-not (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name $names.Private)) { return 'none' }
    if ($RawCount -eq -2) { $RawCount = Get-RemoteEntryCount -Target ($names.Base + ':PC-Private') }
    if ($RawCount -lt 0) { return 'unchecked' }
    if ($RawCount -eq 0) { return 'opens' }
    $x = Invoke-GuiRclone -RcloneArgs @('lsf', ($names.Private + ':'), '--dirs-only')
    if ($x.ExitCode -ne 0) { return 'wrong' }
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
    $k = Get-GuiKeyArgs -Ctx $Ctx
    $Ctx.Args['recoveryKey'] = $null
    $Ctx.Args['salt'] = $null
    $names = Get-GuiKeyRemotes -Ctx $Ctx
    $target = $names.Base + ':PC-Private'
    try {
        if (Test-GuiPreview $Ctx) {
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
            if ($state -eq 'wrong') {
                throw (New-GuiException 'refused' ("This PC already has a different recovery key in rclone (remote '{0}'). Remove it with rclone config, then try again." -f $names.Private))
            }
            if ($state -eq 'unchecked') { throw (New-GuiException 'remote-failed' "PikPak couldn't be checked, so the key wasn't used. Check your internet connection and try again.") }
        }
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
