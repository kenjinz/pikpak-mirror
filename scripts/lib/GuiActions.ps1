# The desktop app's bridge: one JSON request in, one envelope out (scripts\Invoke-GuiAction.ps1).
#   request : { action, args, preview }
#   envelope: @{ ok = $true; data = ... }  or  @{ ok = $false; error = @{ code; message } }
# Each action is a small Invoke-GuiAction<Name> function taking the request context hashtable.
# Secrets (PikPak password, recovery key) only ever arrive in args; they never go into an envelope,
# a log line or an error message. Windows PowerShell 5.1 compatible; ASCII source.
# Requires every other lib file (loaded by _load.ps1 before this one).

# ===== Envelope, errors and small helpers ===========================================================

function New-GuiException {
    # A handled error: Invoke-GuiRequest turns it into { ok: false, error: { code, message } }.
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message)
    $e = New-Object System.Exception $Message
    $e.Data['GuiCode'] = $Code
    $e
}

function Get-GuiErrorCode {
    # The GuiCode of a handled error anywhere in the exception chain, else $null.
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e.Data -and $e.Data.Contains('GuiCode')) { return [string]$e.Data['GuiCode'] }
        $e = $e.InnerException
    }
    $null
}

function Get-GuiErrorMessage {
    param($Exception)
    $e = $Exception
    while ($null -ne $e) {
        if ($e.Data -and $e.Data.Contains('GuiCode')) { return $e.Message }
        $e = $e.InnerException
    }
    $Exception.Message
}

function ConvertTo-GuiValue {
    # JSON (PSCustomObject) -> hashtables and arrays the config writer understands. Whole numbers become
    # [int] (or [long] when large), so budgets and days are written as 30, not 30.0.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-GuiValue $p.Value }
        return $h
    }
    if ($Value -is [hashtable]) {
        $h = @{}
        foreach ($k in @($Value.Keys)) { $h[[string]$k] = ConvertTo-GuiValue $Value[$k] }
        return $h
    }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [char]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = @(foreach ($x in $Value) { , (ConvertTo-GuiValue $x) })
        return , $list
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $d = [decimal]$Value
        if ($d -eq [decimal]::Truncate($d) -and $d -ge [decimal][long]::MinValue -and $d -le [decimal][long]::MaxValue) {
            $Value = [long]$d
        }
        else { return $Value }
    }
    if ($Value -is [long] -and $Value -ge [int]::MinValue -and $Value -le [int]::MaxValue) { return [int]$Value }
    $Value
}

function Get-GuiArg {
    # One request argument, or $Default when it is missing or null.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($Ctx.Args.ContainsKey($Name) -and $null -ne $Ctx.Args[$Name]) { return $Ctx.Args[$Name] }
    $Default
}

function Get-GuiPathArg {
    # A folder path argument in canonical spelling; bad-request unless it is an absolute drive path.
    param([Parameter(Mandatory)][hashtable]$Ctx, [string]$Name = 'path')
    $raw = [string](Get-GuiArg $Ctx $Name '')
    if ([string]::IsNullOrWhiteSpace($raw)) { throw (New-GuiException 'bad-request' 'No folder was given.') }
    $p = $null
    try { $p = ConvertTo-MirrorPath $raw } catch { $p = $null }
    if ($null -eq $p -or $p -notmatch '^[A-Za-z]:\\' -or $p.Contains('%')) {
        throw (New-GuiException 'bad-request' ("'{0}' isn't a folder on a drive of this PC (like D:\Photos)." -f $raw))
    }
    $p
}

function Remove-GuiSecretText {
    # Blanks every secret value of the request out of a text before it is logged.
    param([string]$Text, [string[]]$Secrets)
    $t = [string]$Text
    foreach ($s in @($Secrets)) {
        if (-not [string]::IsNullOrEmpty($s) -and $s.Length -ge 3) { $t = $t.Replace($s, '***') }
    }
    $t
}

function Write-GuiLog {
    # Best effort: the engine's daily log when the config is known.
    param($Config, [string]$Message)
    if ($null -eq $Config) { return }
    try { Write-MirrorLog -Config $Config -Message ('App: ' + $Message) } catch { }
}

function Test-GuiPreview { param([hashtable]$Ctx) [bool]$Ctx.Preview }

function Get-GuiPrefixKey {
    param([string]$Path)
    $n = $Path
    try { $n = ConvertTo-MirrorPath $Path } catch { }
    ConvertTo-PrefixKey $n
}

function Get-GuiFolderRelation {
    # 'same', 'inside' (A is inside B), 'contains' (A contains B) or $null.
    param([string]$A, [string]$B)
    $ka = Get-GuiPrefixKey $A; $kb = Get-GuiPrefixKey $B
    if ($ka -eq $kb) { return 'same' }
    if ($ka.StartsWith($kb)) { return 'inside' }
    if ($kb.StartsWith($ka)) { return 'contains' }
    $null
}

function Get-GuiPairList {
    # The config's pairs as one array object (emitted with the comma operator, so a caller gets an array
    # even when there is exactly one pair).
    param([hashtable]$Config)
    , @(@($Config['Pairs']) | Where-Object { $_ })
}

function Test-GuiConfigCandidate {
    # Validates a raw config without touching the real file: writes it to a temp file, loads it the way
    # the engine does and runs Test-MirrorConfig. Returns @{ Errors; Config (expanded, or $null) }.
    param([Parameter(Mandatory)][hashtable]$Config, [string]$NextTo)
    $dir = [IO.Path]::GetTempPath()
    $tmp = Join-Path $dir ('pikpak-gui-{0}.psd1' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($tmp, (ConvertTo-MirrorConfigText -Config $Config), (New-Object System.Text.UTF8Encoding $true))
        try {
            $loaded = Get-MirrorConfig -Path $tmp
            # A relative filter file resolves next to the real config, not the temp file.
            if ($NextTo -and $Config.ContainsKey('GlobalFiltersFile')) {
                $f = [Environment]::ExpandEnvironmentVariables([string]$Config['GlobalFiltersFile'])
                if (-not [IO.Path]::IsPathRooted($f)) { $loaded['GlobalFiltersFile'] = Join-Path (Split-Path -Path $NextTo -Parent) $f }
            }
        }
        catch { return @{ Errors = @("Config could not be loaded: $($_.Exception.Message)"); Config = $null } }
        return @{ Errors = @(Test-MirrorConfig -Config $loaded); Config = $loaded }
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Save-GuiConfig {
    # Saves a raw config (or under preview only validates it). config-invalid with every message on failure.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Config)
    if (Test-GuiPreview $Ctx) {
        $check = Test-GuiConfigCandidate -Config $Config -NextTo $Ctx.ConfigPath
        $errs = @($check.Errors)
    }
    else { $errs = @(Save-MirrorConfig -Path $Ctx.ConfigPath -Config $Config) }
    if ($errs.Count -gt 0) { throw (New-GuiException 'config-invalid' ($errs -join ' ')) }
}

# ===== Wrappers around the outside world (mocked in tests) ==========================================

function Invoke-GuiRclone {
    # Runs rclone with stdout and stderr captured separately; nothing is shown. rclone writes UTF-8, so the
    # console decoding is switched to UTF-8 for the call (names like Songs with diacritics survive).
    param([Parameter(Mandatory)][string[]]$RcloneArgs)
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
    $prevPref = $ErrorActionPreference
    $prevEnc = $null
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $prevEnc = $null }
    $ErrorActionPreference = 'Continue'
    $code = 0
    try {
        $global:LASTEXITCODE = 0
        & rclone @RcloneArgs 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add([string]$_) } else { $out.Add([string]$_) }
        }
        $code = [int]$global:LASTEXITCODE
    }
    catch [System.Management.Automation.CommandNotFoundException] { $code = 127 }
    finally {
        $ErrorActionPreference = $prevPref
        if ($null -ne $prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
    }
    [pscustomobject]@{ ExitCode = $code; Output = $out.ToArray(); Errors = $err.ToArray() }
}

function Get-GuiTaskInfo {
    # @{ Exists; Enabled; State; NextRun ('yyyy-MM-ddTHH:mm:ss' or $null) } of a scheduled task.
    param([Parameter(Mandatory)][string]$TaskName)
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $t) { return @{ Exists = $false; Enabled = $false; State = $null; NextRun = $null } }
    $next = $null
    try {
        $i = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
        if ($null -ne $i.NextRunTime) { $next = ([datetime]$i.NextRunTime).ToString('s', [Globalization.CultureInfo]::InvariantCulture) }
    }
    catch { }
    @{ Exists = $true; Enabled = ([string]$t.State -ne 'Disabled'); State = [string]$t.State; NextRun = $next }
}

function Set-GuiTaskEnabled {
    param([Parameter(Mandatory)][string]$TaskName, [Parameter(Mandatory)][bool]$Enabled)
    if ($Enabled) { Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
}

function Start-GuiTask {
    param([Parameter(Mandatory)][string]$TaskName)
    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
}

function Start-GuiDetached {
    # Starts a process with no window and does not wait for it.
    param([Parameter(Mandatory)][string]$FilePath, [Parameter(Mandatory)][string]$Arguments)
    Start-Process -FilePath $FilePath -ArgumentList $Arguments -WindowStyle Hidden | Out-Null
}

function Get-GuiKnownFolderPath {
    param([Parameter(Mandatory)][string]$Which)
    [Environment]::GetFolderPath($Which)
}

function Get-GuiBestDrive {
    # Root ('D:\') of the fixed drive with the most free space.
    $best = [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady } |
        Sort-Object -Property AvailableFreeSpace -Descending | Select-Object -First 1
    if ($null -eq $best) { return 'C:\' }
    [string]$best.Name
}

# ===== PikPak account (about) ======================================================================

function Get-GuiRcloneConfigDump {
    # `rclone config dump` as an object, or $null. Holds secrets in memory only; callers take single fields.
    $r = Invoke-GuiRclone -RcloneArgs @('config', 'dump')
    if ($r.ExitCode -ne 0) { return $null }
    try { return ((@($r.Output) -join "`n") | ConvertFrom-Json) } catch { return $null }
}

function Get-GuiRemoteEntry {
    param($Dump, [string]$Name)
    if ($null -eq $Dump -or [string]::IsNullOrEmpty($Name)) { return $null }
    $p = $Dump.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    $p.Value
}

function Resolve-GuiRemoteTarget {
    # The real remote behind a name, following one level of alias ('pikpak' = alias of 'Pikpak remote:'):
    # @{ Name; User } or $null when it is not in the dump.
    param($Dump, [Parameter(Mandatory)][string]$Remote)
    $name = $Remote
    $e = Get-GuiRemoteEntry $Dump $name
    if ($null -eq $e) { return $null }
    if ([string]$e.type -eq 'alias') {
        $target = [string]$e.remote
        $colon = $target.IndexOf(':')
        if ($colon -le 0) { return $null }
        $name = $target.Substring(0, $colon)
        $e = Get-GuiRemoteEntry $Dump $name
        if ($null -eq $e) { return $null }
    }
    $user = $null
    if ($null -ne $e.PSObject.Properties['user']) { $user = [string]$e.user }
    @{ Name = $name; User = $user }
}

function Get-GuiRemoteEmail {
    # The PikPak user of a remote, following one level of alias.
    param([Parameter(Mandatory)][string]$Remote)
    $t = Resolve-GuiRemoteTarget -Dump (Get-GuiRcloneConfigDump) -Remote $Remote
    if ($null -eq $t) { return $null }
    $t.User
}

function Clear-GuiAboutCache {
    # Forgets the cached account check (e.g. an old "signed out" after a successful sign-in).
    param([Parameter(Mandatory)][hashtable]$Ctx)
    if ($null -eq $Ctx.Config -or [string]::IsNullOrWhiteSpace([string]$Ctx.Config.StateDir)) { return }
    $cache = Join-Path ([string]$Ctx.Config.StateDir) 'gui-about.json'
    if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue }
}

function Get-GuiAccountBytes {
    # `rclone about --json <remote>:` -> @{ TotalBytes; UsedBytes; Error ($null|'auth'|'network'); Detail }.
    # Short timeouts: the app waits on this call (status polls included).
    param([Parameter(Mandatory)][string]$Remote)
    $r = Invoke-GuiRclone -RcloneArgs @('about', '--json', '--contimeout', '10s', '--timeout', '30s', ($Remote + ':'))
    $text = ((@($r.Output) + @($r.Errors)) -join ' ')
    if ($r.ExitCode -ne 0) {
        $kind = 'network'
        if ($text -match '401|unauthori|invalid_grant|captcha') { $kind = 'auth' }
        return @{ TotalBytes = $null; UsedBytes = $null; Error = $kind; Detail = ('rclone about exit {0}: {1}' -f $r.ExitCode, $text) }
    }
    $json = (@($r.Output) -join "`n")
    $a = $json.IndexOf('{'); $b = $json.LastIndexOf('}')
    $obj = $null
    if ($a -ge 0 -and $b -gt $a) { try { $obj = $json.Substring($a, $b - $a + 1) | ConvertFrom-Json } catch { $obj = $null } }
    if ($null -eq $obj) { return @{ TotalBytes = $null; UsedBytes = $null; Error = 'network'; Detail = 'rclone about gave no JSON: ' + $text } }
    $total = $null; $used = $null
    if ($null -ne $obj.PSObject.Properties['total']) { $total = [long]$obj.total }
    if ($null -ne $obj.PSObject.Properties['used']) { $used = [long]$obj.used }
    @{ TotalBytes = $total; UsedBytes = $used; Error = $null; Detail = $null }
}

function Get-GuiAboutInfo {
    # Account size and email, cached in <StateDir>\gui-about.json for 10 minutes (errors too, so an
    # offline PC does not run rclone on every status poll). -Refresh always asks PikPak.
    param([Parameter(Mandatory)][hashtable]$Config, [switch]$Refresh, [datetime]$Now = (Get-Date))
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $cache = Join-Path ([string]$Config.StateDir) 'gui-about.json'
    if (-not $Refresh -and (Test-Path -LiteralPath $cache)) {
        try {
            $c = [IO.File]::ReadAllText($cache, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $checked = ConvertTo-GuiDate $c.CheckedAt
            if ($null -ne $checked) {
                $age = ($Now - $checked).TotalMinutes
                if ($age -ge 0 -and $age -lt 10) {
                    $info = @{ UsedBytes = $null; TotalBytes = $null; Email = $null; CheckedAt = (ConvertTo-IsoText $c.CheckedAt); Error = $null }
                    if ($null -ne $c.UsedBytes) { $info.UsedBytes = [long]$c.UsedBytes }
                    if ($null -ne $c.TotalBytes) { $info.TotalBytes = [long]$c.TotalBytes }
                    if ($null -ne $c.Email) { $info.Email = [string]$c.Email }
                    if ($null -ne $c.Error) { $info.Error = [string]$c.Error }
                    return $info
                }
            }
        }
        catch { }
    }
    $info = @{ UsedBytes = $null; TotalBytes = $null; Email = $null; CheckedAt = $Now.ToString('o', $inv); Error = $null }
    if (-not (Test-RcloneInstalled)) {
        $info.Error = 'rclone-missing'
        return $info
    }
    $acct = Get-GuiAccountBytes -Remote ([string]$Config.Remote)
    $info.UsedBytes = $acct.UsedBytes; $info.TotalBytes = $acct.TotalBytes; $info.Error = $acct.Error
    if ($null -ne $acct.Detail) { Write-GuiLog $Config ('PikPak account check failed: ' + $acct.Detail) }
    try { $info.Email = Get-GuiRemoteEmail -Remote ([string]$Config.Remote) } catch { }
    try {
        if (-not (Test-Path -LiteralPath $Config.StateDir)) { New-Item -ItemType Directory -Path $Config.StateDir -Force | Out-Null }
        [IO.File]::WriteAllText($cache, ($info | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding $false))
    }
    catch { }
    $info
}

function Get-GuiAccountErrorMessage {
    param([string]$Code)
    switch ($Code) {
        'auth' { return 'PikPak signed you out. Sign in again so syncing can carry on.' }
        'rclone-missing' { return "rclone isn't installed on this PC, so PikPak can't be reached. Run the setup again to install it." }
        default { return "Couldn't reach PikPak. Check your internet connection and try again." }
    }
}

# ===== The request ==================================================================================

function Invoke-GuiRequest {
    # One request -> one envelope hashtable. Never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Request,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
        [datetime]$Now = (Get-Date)
    )
    $ctx = @{ Action = $null; Args = @{}; Preview = $false; Config = $null; ConfigPath = $ConfigPath; RepoRoot = $RepoRoot; Now = $Now }
    $secrets = @()
    try {
        if ($null -eq $Request -or $null -eq $Request.PSObject.Properties['action'] -or [string]::IsNullOrWhiteSpace([string]$Request.action)) {
            throw (New-GuiException 'bad-request' 'The request names no action.')
        }
        $ctx.Action = [string]$Request.action
        if ($null -ne $Request.PSObject.Properties['args'] -and $null -ne $Request.args) {
            $a = ConvertTo-GuiValue $Request.args
            if ($a -isnot [hashtable]) { throw (New-GuiException 'bad-request' 'The request args must be an object.') }
            $ctx.Args = $a
        }
        foreach ($k in @('password', 'recoveryKey', 'salt')) { if ($ctx.Args.ContainsKey($k)) { $secrets += [string]$ctx.Args[$k] } }
        if ($null -ne $Request.PSObject.Properties['preview']) { $ctx.Preview = [bool]$Request.preview }

        $needsConfig = $true
        switch -CaseSensitive ($ctx.Action) {
            'status' { $fn = 'Invoke-GuiActionStatus' }
            'about' { $fn = 'Invoke-GuiActionAbout' }
            'config.get' { $fn = 'Invoke-GuiActionConfigGet' }
            'config.save' { $fn = 'Invoke-GuiActionConfigSave' }
            'folders.suggest' { $fn = 'Invoke-GuiActionFoldersSuggest'; $needsConfig = $false }
            'folders.size' { $fn = 'Invoke-GuiActionFoldersSize'; $needsConfig = $false }
            'folders.add' { $fn = 'Invoke-GuiActionFoldersAdd' }
            'folders.remove' { $fn = 'Invoke-GuiActionFoldersRemove' }
            'folders.convert' { $fn = 'Invoke-GuiActionFoldersConvert' }
            'folders.convertReview' { $fn = 'Invoke-GuiActionFoldersConvertReview' }
            'folders.pause' { $fn = 'Invoke-GuiActionFoldersPause' }
            'folders.resume' { $fn = 'Invoke-GuiActionFoldersResume' }
            'folders.ensureIds' { $fn = 'Invoke-GuiActionFoldersEnsureIds' }
            'folders.identify' { $fn = 'Invoke-GuiActionFoldersIdentify' }
            'folders.locateReview' { $fn = 'Invoke-GuiActionFoldersLocateReview' }
            'folders.locate' { $fn = 'Invoke-GuiActionFoldersLocate' }
            'folders.adopt' { $fn = 'Invoke-GuiActionFoldersAdopt' }
            'folders.newId' { $fn = 'Invoke-GuiActionFoldersNewId' }
            'private.review' { $fn = 'Invoke-GuiActionPrivateReview' }
            'private.add' { $fn = 'Invoke-GuiActionPrivateAdd' }
            'private.remove' { $fn = 'Invoke-GuiActionPrivateRemove' }
            'private.remoteList' { $fn = 'Invoke-GuiActionPrivateRemoteList' }
            'private.pikpakNames' { $fn = 'Invoke-GuiActionPrivatePikpakNames' }
            'private.download' { $fn = 'Invoke-GuiActionPrivateDownload' }
            'private.deleteRemote' { $fn = 'Invoke-GuiActionPrivateDeleteRemote' }
            'sync.start' { $fn = 'Invoke-GuiActionSyncStart' }
            'sync.repair' { $fn = 'Invoke-GuiActionSyncRepair' }
            'cleanup' { $fn = 'Invoke-GuiActionCleanup' }
            'schedule.get' { $fn = 'Invoke-GuiActionScheduleGet' }
            'schedule.set' { $fn = 'Invoke-GuiActionScheduleSet' }
            'holding.list' { $fn = 'Invoke-GuiActionHoldingList' }
            'holding.restore' { $fn = 'Invoke-GuiActionHoldingRestore' }
            'key.show' { $fn = 'Invoke-GuiActionKeyShow' }
            'backup.push' { $fn = 'Invoke-GuiActionBackupPush' }
            'private.usekey' { $fn = 'Invoke-GuiActionPrivateUsekey' }
            'private.keyState' { $fn = 'Invoke-GuiActionPrivateKeyState' }
            'private.restore' { $fn = 'Invoke-GuiActionPrivateRestore' }
            'setup.signin' { $fn = 'Invoke-GuiActionSetupSignin'; $needsConfig = $false }
            'setup.finish' { $fn = 'Invoke-GuiActionSetupFinish'; $needsConfig = $false }
            'setup.newkey' { $fn = 'Invoke-GuiActionSetupNewkey'; $needsConfig = $false }
            'setup.usekey' { $fn = 'Invoke-GuiActionSetupUsekey'; $needsConfig = $false }
            'setup.discover' { $fn = 'Invoke-GuiActionSetupDiscover'; $needsConfig = $false }
            'setup.scan' { $fn = 'Invoke-GuiActionSetupScan'; $needsConfig = $false }
            'setup.sizes' { $fn = 'Invoke-GuiActionSetupSizes'; $needsConfig = $false }
            default { throw (New-GuiException 'bad-request' ("Unknown action '{0}'." -f $ctx.Action)) }
        }

        if ($needsConfig) {
            if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
                throw (New-GuiException 'config-missing' "PikPak Sync isn't set up on this PC yet. Run the setup to choose what to sync.")
            }
            try { $ctx.Config = Get-MirrorConfig -Path $ConfigPath }
            catch { throw (New-GuiException 'config-invalid' ("Your settings file couldn't be read: {0}" -f $_.Exception.Message)) }
        }
        elseif (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
            # Only for logging; these actions work without a config.
            try { $ctx.Config = Get-MirrorConfig -Path $ConfigPath } catch { $ctx.Config = $null }
        }

        $data = & $fn -Ctx $ctx 3>$null 4>$null 5>$null 6>$null
        $envelope = @{ ok = $true; data = $data }
        if ($ctx.ContainsKey('Warning') -and $ctx.Warning) { $envelope['warning'] = [string]$ctx.Warning }
        return $envelope
    }
    catch {
        $code = Get-GuiErrorCode $_.Exception
        if ($null -ne $code) {
            return @{ ok = $false; error = @{ code = $code; message = (Remove-GuiSecretText (Get-GuiErrorMessage $_.Exception) $secrets) } }
        }
        $where = ''
        if ($_.InvocationInfo) { $where = ' at ' + $_.InvocationInfo.PositionMessage.Replace("`r", ' ').Replace("`n", ' ') }
        Write-GuiLog $ctx.Config (Remove-GuiSecretText ('action {0} failed: {1}{2}' -f $ctx.Action, $_.Exception.Message, $where) $secrets)
        return @{ ok = $false; error = @{ code = 'internal'; message = 'Something went wrong in PikPak Sync. Details are in the log.' } }
    }
    finally {
        if ($ctx.Args.ContainsKey('password')) { $ctx.Args['password'] = $null }
        if ($ctx.Args.ContainsKey('recoveryKey')) { $ctx.Args['recoveryKey'] = $null }
        if ($ctx.Args.ContainsKey('salt')) { $ctx.Args['salt'] = $null }
        $secrets = $null
    }
}

# ===== Actions: Home ================================================================================

function Invoke-GuiActionStatus {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $cfg = $Ctx.Config
    $state = Get-MirrorState -StateDir $cfg.StateDir
    $task = Get-GuiTaskInfo -TaskName 'PikPakMirror-Sync'
    $about = Get-GuiAboutInfo -Config $cfg -Now $Ctx.Now
    # Drive letters of the synced folders whose drive is not there (an unplugged drive, not a moved folder).
    $missingDrives = @()
    $seenDrives = @{}
    foreach ($f in @(Get-SyncFolders -Config $cfg)) {
        $loc = [string]$f.Local
        if ($loc -match '^[A-Za-z]:') {
            $letter = $loc.Substring(0, 1).ToUpperInvariant()
            if (-not $seenDrives.ContainsKey($letter)) {
                $seenDrives[$letter] = $true
                if (-not (Test-Path -LiteralPath ($letter + ':\'))) { $missingDrives += $letter }
            }
        }
    }
    $facts = @{
        MissingDrives = [string[]]$missingDrives
        SyncRunning  = [bool](Test-SyncRunning -StateDir $cfg.StateDir)
        TaskEnabled  = ([bool]$task.Exists -and [bool]$task.Enabled)
        NextRun      = $task.NextRun
        About        = @{ UsedBytes = $about['UsedBytes']; TotalBytes = $about['TotalBytes']; Error = $about['Error'] }
        ConfigErrors = @(Test-MirrorConfig -Config $cfg)
    }
    $status = Get-GuiStatus -Config $cfg -State $state -Now $Ctx.Now -Facts $facts
    $status['backup'] = Get-GuiBackupInfo -Config $cfg -Now $Ctx.Now
    $status
}

function Invoke-GuiActionAbout {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $info = Get-GuiAboutInfo -Config $Ctx.Config -Refresh:([bool](Get-GuiArg $Ctx 'refresh' $false)) -Now $Ctx.Now
    if ($info.Error) { throw (New-GuiException ([string]$info.Error) (Get-GuiAccountErrorMessage ([string]$info.Error))) }
    @{ usedBytes = $info.UsedBytes; totalBytes = $info.TotalBytes; email = $info.Email; checkedAt = $info.CheckedAt }
}

# ===== Actions: settings file =======================================================================

function Invoke-GuiActionConfigGet {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $cfg = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    # A file that only has the old per-run RunBudgetGB shows (and, once saved, keeps) that number as the daily limit.
    if (-not $cfg.ContainsKey('DailyBudgetGB') -and $cfg.ContainsKey('RunBudgetGB')) { $cfg['DailyBudgetGB'] = Get-DailyBudgetGB -Config $cfg }
    $cfg
}

function Invoke-GuiActionConfigSave {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $cfg = Get-GuiArg $Ctx 'config'
    if ($cfg -isnot [hashtable]) { throw (New-GuiException 'bad-request' 'No settings were given to save.') }
    Save-GuiConfig -Ctx $Ctx -Config $cfg
    if (Test-GuiPreview $Ctx) { return @{ saved = $false; preview = @('Would save the settings to ' + $Ctx.ConfigPath) } }
    @{ saved = $true }
}

# ===== Actions: folders =============================================================================

function Invoke-GuiActionFoldersSuggest {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $rows = foreach ($k in @(@('Pictures', 'MyPictures'), @('Documents', 'MyDocuments'), @('Desktop', 'Desktop'), @('Music', 'MyMusic'), @('Videos', 'MyVideos'))) {
        $p = [string](Get-GuiKnownFolderPath -Which $k[1])
        @{ name = $k[0]; path = $p; exists = (-not [string]::IsNullOrEmpty($p) -and (Test-Path -LiteralPath $p -PathType Container)) }
    }
    , @($rows)
}

function Measure-GuiFolder {
    # Bytes under a folder, giving up after $MaxSeconds (complete = $false). Never follows junctions.
    # changed: the newest file's last-write day ('yyyy-MM-dd', local time; the ID files left out), or $null.
    param([Parameter(Mandatory)][string]$Path, [int]$MaxSeconds = 20)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $limit = [long]$MaxSeconds * 1000
    $bytes = [long]0
    $newest = [datetime]::MinValue
    $flag = [IO.FileAttributes]::ReparsePoint
    $stack = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
    $stack.Push((New-Object IO.DirectoryInfo $Path))
    $complete = $true
    while ($stack.Count -gt 0) {
        if ($sw.ElapsedMilliseconds -ge $limit) { $complete = $false; break }
        $dir = $stack.Pop()
        try { $items = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($i in $items) {
            if ($i -is [IO.FileInfo]) {
                $bytes += $i.Length
                if ($i.Name -ine '.pikpak-sync.json' -and $i.Name -ine '.pikpak-encrypted.json' -and $i.LastWriteTime -gt $newest) { $newest = $i.LastWriteTime }
            }
            elseif (($i.Attributes -band $flag) -eq 0) { $stack.Push($i) }
        }
    }
    $changed = $null
    if ($newest -gt [datetime]::MinValue) { $changed = $newest.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    @{ bytes = $bytes; complete = $complete; changed = $changed }
}

function Invoke-GuiActionFoldersSize {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $p = Get-GuiPathArg $Ctx
    $max = 20
    try { $max = [int](Get-GuiArg $Ctx 'maxSeconds' 20) } catch { $max = 20 }
    if ($max -lt 1) { $max = 1 }
    if (Test-Path -LiteralPath $p -PathType Leaf) {
        $fi = Get-Item -LiteralPath $p -Force
        return @{ bytes = [long]$fi.Length; complete = $true; changed = $fi.LastWriteTime.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw (New-GuiException 'not-found' ("The folder {0} wasn't found." -f $p)) }
    Measure-GuiFolder -Path $p -MaxSeconds $max
}

function Get-GuiPairOverlapMessage {
    # Plain-words reason why $Path cannot become a synced folder, or $null when it can.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Path)
    foreach ($pair in @(@($Config['Pairs']) | Where-Object { $_ })) {
        $rel = Get-GuiFolderRelation $Path ([string]$pair.Local)
        if ($rel -eq 'same') { return ("{0} is already synced (as '{1}')." -f $Path, $pair.Name) }
        if ($rel -eq 'inside') { return ("{0} is inside {1}, which is already synced (as '{2}')." -f $Path, $pair.Local, $pair.Name) }
        if ($rel -eq 'contains') { return ("{0} contains {1}, which is already synced (as '{2}'). Remove that folder from syncing first, or choose another folder." -f $Path, $pair.Local, $pair.Name) }
    }
    foreach ($priv in @(@($Config['PrivatePaths']) | Where-Object { $_ })) {
        $rel = Get-GuiFolderRelation $Path ([string]$priv.Path)
        if ($rel -eq 'same') { return ('{0} is an encrypted folder; it is synced locked with your recovery key, so it cannot also be synced unencrypted.' -f $Path) }
        if ($rel -eq 'inside') { return ('{0} is inside the encrypted folder {1}; it cannot also be synced unencrypted.' -f $Path, $priv.Path) }
    }
    $lh = [string]$Config['LocalHolding']
    if ($lh -and $null -ne (Get-GuiFolderRelation $Path $lh)) {
        return ("{0} overlaps {1}, where PikPak Sync keeps deleted files. Choose another folder." -f $Path, $lh)
    }
    $null
}

function Invoke-GuiActionFoldersAdd {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $p = Get-GuiPathArg $Ctx
    $enc = Get-GuiArg $Ctx 'encrypted' $false
    if ($enc -is [bool] -and $enc) {
        # Add as an encrypted folder: every refusal of private.add applies. A folder that is already synced
        # (or already encrypted) is changed with folders.convert, never silently from here.
        foreach ($pair in @(@($Ctx.Config['Pairs']) | Where-Object { $_ })) {
            if ((Get-GuiFolderRelation $p ([string]$pair.Local)) -eq 'same') {
                throw (New-GuiException 'refused' ("{0} is already synced (as '{1}'). Use 'Make encrypted' on its row to change it." -f $p, $pair.Name))
            }
        }
        foreach ($priv in @(@($Ctx.Config['PrivatePaths']) | Where-Object { $_ })) {
            if ((Get-GuiFolderRelation $p ([string]$priv.Path)) -eq 'same') {
                throw (New-GuiException 'refused' ('{0} is already an encrypted folder.' -f $p))
            }
        }
        # Inside a synced folder the files are already in PikPak, readable: the add from Settings (reviewed) has
        # shown that copy in its box first; from Home it is refused.
        $rv = Get-GuiArg $Ctx 'reviewed' $false
        if (-not ($rv -is [bool] -and $rv)) {
            foreach ($pair in @(@($Ctx.Config['Pairs']) | Where-Object { $_ })) {
                if ((Get-GuiFolderRelation $p ([string]$pair.Local)) -eq 'inside') {
                    throw (New-GuiException 'refused' ('{0} is inside the synced folder {1}, so it is already in PikPak readable. Use Settings, Add encrypted folder: it shows that copy and what to do with it.' -f $p, $pair.Name))
                }
            }
        }
        $ident = Resolve-GuiAddIdentity -Ctx $Ctx -Path $p -Encrypted $true
        $name = Resolve-GuiAddPrivateName -Ctx $Ctx -Raw (Get-RawMirrorConfig -Path $Ctx.ConfigPath) -Path $p -NewId $ident.NewId
        $r = Invoke-GuiActionPrivateAdd -Ctx $Ctx -UseName $name -UseId $ident.Id
        $now = Get-RawMirrorConfig -Path $Ctx.ConfigPath
        $out = @{ pairs = (Get-GuiPairList $now); encrypted = $true; saved = [bool]$r.saved }
        if ($r.ContainsKey('preview')) { $out['preview'] = $r.preview }
        if ($r.ContainsKey('privatePaths')) { $out['privatePaths'] = $r.privatePaths }
        if ($ident.NewId) {
            if (Test-GuiPreview $Ctx) { $out['preview'] = @($out['preview']) + @(('Would give {0} a new ID and rewrite its ID file.' -f $p), 'Would check PikPak first that this new place is free; if it is taken there, the next free name is used.') }
            else { Write-GuiEntryMarker -Ctx $Ctx -Kind 'private' -Name $name -Local $p -Id $ident.Id }
        }
        elseif ($ident.Rewrite) {
            if (Test-GuiPreview $Ctx) { $out['preview'] = @($out['preview']) + @(('Would replace the ID in the ID file of {0} with the one in PikPak.' -f $p)) }
            else { Write-GuiEntryMarker -Ctx $Ctx -Kind 'private' -Name $name -Local $p -Id $ident.Id }
        }
        return $out
    }
    $why = Get-GuiPairOverlapMessage -Config $Ctx.Config -Path $p
    if ($null -ne $why) { throw (New-GuiException 'refused' $why) }
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw (New-GuiException 'not-found' ("The folder {0} wasn't found." -f $p)) }
    $ident = Resolve-GuiAddIdentity -Ctx $Ctx -Path $p -Encrypted $false
    if ($ident.NewId -or $ident.Rewrite) { Assert-GuiNotSyncing $Ctx }
    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $pair = New-MirrorPair -Path $p -Config $raw
    $pair['Remote'] = Resolve-GuiAddRemote -Ctx $Ctx -Raw $raw -Path $p -NewId $ident.NewId
    $pair['Id'] = $ident.Id
    $raw['Pairs'] = @(@($raw['Pairs']) | Where-Object { $_ }) + @($pair)
    Save-GuiConfig -Ctx $Ctx -Config $raw
    if (Test-GuiPreview $Ctx) {
        $lines = @(("Would sync {0} as '{1}' (PikPak folder {2}/{3})." -f $pair.Local, $pair.Name, $raw['MirrorRoot'], $pair.Remote))
        if ($ident.NewId) { $lines += ('Would give {0} a new ID and rewrite its ID file.' -f $p); $lines += 'Would check PikPak first that this new place is free; if it is taken there, the next free name is used.' }
        elseif ($ident.Rewrite) { $lines += ('Would replace the ID in the ID file of {0} with the one in PikPak.' -f $p) }
        return @{ pairs = (Get-GuiPairList $raw); preview = $lines }
    }
    if ($ident.NewId -or $ident.Rewrite) { Write-GuiEntryMarker -Ctx $Ctx -Kind 'pair' -Name $pair.Name -Local $p -Remote $pair.Remote -Id $ident.Id }
    Get-GuiPairList (Get-RawMirrorConfig -Path $Ctx.ConfigPath)
}

function Invoke-GuiActionFoldersRemove {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $name = [string](Get-GuiArg $Ctx 'name' '')
    if ([string]::IsNullOrWhiteSpace($name)) { throw (New-GuiException 'bad-request' 'No folder name was given.') }
    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $pairs = @(@($raw['Pairs']) | Where-Object { $_ })
    $keep = @($pairs | Where-Object { [string]$_.Name -ine $name })
    if ($keep.Count -eq $pairs.Count) { throw (New-GuiException 'not-found' ("No synced folder is called '{0}'." -f $name)) }
    $raw['Pairs'] = $keep
    Save-GuiConfig -Ctx $Ctx -Config $raw
    if (Test-GuiPreview $Ctx) {
        return @{ pairs = (Get-GuiPairList $raw); preview = @(("Would stop syncing '{0}'. Nothing is deleted on this PC or in PikPak." -f $name)) }
    }
    Clear-GuiAcceptRemoteId -Ctx $Ctx -StateKeys @($pairs | Where-Object { [string]$_.Name -ieq $name } | ForEach-Object { [string]$_.Name })
    Get-GuiPairList (Get-RawMirrorConfig -Path $Ctx.ConfigPath)
}

function Set-GuiFolderPaused {
    # folders.pause / folders.resume: name + private pick the entry (as sync.repair does). Pausing sets Paused;
    # resuming removes it (and PausedForKey). The encrypted-folder paths hash covers paths only, so it does not change.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][bool]$Paused)
    $name = [string](Get-GuiArg $Ctx 'name' '')
    if ([string]::IsNullOrWhiteSpace($name)) { throw (New-GuiException 'bad-request' 'No folder name was given.') }
    $isPrivate = $false
    $priv = Get-GuiArg $Ctx 'private' $false
    if ($priv -is [bool] -and $priv) { $isPrivate = $true }
    $key = 'Pairs'; if ($isPrivate) { $key = 'PrivatePaths' }
    Assert-GuiNotSyncing $Ctx
    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $entry = @(@($raw[$key]) | Where-Object { $_ -and [string]$_.Name -ieq $name }) | Select-Object -First 1
    if ($null -eq $entry) { throw (New-GuiException 'not-found' ("No synced folder is called '{0}'." -f $name)) }
    # PausedForKey says a restore paused it for the missing key; once the owner pauses or resumes it, that is no longer so.
    $entry.Remove('PausedForKey')
    if ($Paused) { $entry['Paused'] = $true } else { $entry.Remove('Paused') }
    Save-GuiConfig -Ctx $Ctx -Config $raw
    if (Test-GuiPreview $Ctx) {
        $line = "Would pause '{0}'. It is skipped until you resume it. Nothing is deleted on this PC or in PikPak." -f $name
        if (-not $Paused) { $line = "Would resume '{0}'. It syncs again at the next sync." -f $name }
        return @{ saved = $false; preview = @($line) }
    }
    if ($Paused -and $isPrivate) {
        $f = @(Get-SyncFolders -Config $Ctx.Config | Where-Object { $_.Kind -eq 'private' -and [string]$_.Name -ieq $name }) | Select-Object -First 1
        if ($null -ne $f) {
            try { $null = Write-GuiEncryptedMarkerIfMissing -Folder $f -State (Get-MirrorState -StateDir $Ctx.Config.StateDir) -Now $Ctx.Now }
            catch { Write-GuiLog $Ctx.Config ('Writing the ID file of {0} failed: {1}' -f $f.Local, $_.Exception.Message) }
        }
    }
    @{ saved = $true }
}

function Write-GuiEncryptedMarkerIfMissing {
    # An encrypted folder that is paused (or never synced) has no ID file yet, so a synced folder it is moved into
    # would not leave it out (--exclude-if-present). Writes it (on this PC only) when the folder is there, has an
    # Id and no ID file, and no run wrote one before (a lost one is the run's to report). $true when written.
    param([Parameter(Mandatory)][hashtable]$Folder, $State, [Parameter(Mandatory)][datetime]$Now)
    if ($Folder.Kind -ne 'private' -or [string]::IsNullOrEmpty([string]$Folder.Id)) { return $false }
    if (-not (Test-Path -LiteralPath ([string]$Folder.Local) -PathType Container)) { return $false }
    if ($null -ne (Read-FolderMarker -Path ([string]$Folder.Local))) { return $false }
    if ($null -ne $State) {
        $ps = $State.Pairs[[string]$Folder.StateKey]
        if ($null -ne $ps -and [bool]$ps['MarkerWritten']) { return $false }
    }
    [bool](Write-FolderMarker -Folder $Folder -Now $Now)
}

function Invoke-GuiActionFoldersPause {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    Set-GuiFolderPaused -Ctx $Ctx -Paused $true
}

function Invoke-GuiActionFoldersResume {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    Set-GuiFolderPaused -Ctx $Ctx -Paused $false
}

function Invoke-GuiActionFoldersEnsureIds {
    # Every entry without an Id gets one: the PC marker's id when that id is free; without a valid PC marker, the id
    # of the marker at its PikPak place when valid and free (none when PikPak can't be read: later); else a new one.
    # One save. Then encrypted folders without an ID file get one (Write-GuiEncryptedMarkerIfMissing).
    # While a sync runs it waits (later) instead of refusing: the app calls it on its own at start-up.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    if (Test-SyncRunning -StateDir $Ctx.Config.StateDir) { return @{ assigned = 0; later = $true } }
    $preview = Test-GuiPreview $Ctx
    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $localOf = @{}
    $remoteOf = @{}
    foreach ($f in @(Get-SyncFolders -Config $Ctx.Config)) {
        $localOf[[string]$f.Kind + '|' + [string]$f.Name] = [string]$f.Local
        $remoteOf[[string]$f.Kind + '|' + [string]$f.Name] = [string]$f.RemotePath
    }
    $later = $false
    $taken = @{}
    foreach ($key in 'Pairs', 'PrivatePaths') {
        foreach ($e in @(@($raw[$key]) | Where-Object { $_ })) {
            if ($e.ContainsKey('Id') -and -not [string]::IsNullOrWhiteSpace([string]$e['Id'])) { $taken[([string]$e['Id']).ToLowerInvariant()] = $true }
        }
    }
    $assigned = 0
    foreach ($key in 'Pairs', 'PrivatePaths') {
        $kind = 'pair'; if ($key -eq 'PrivatePaths') { $kind = 'private' }
        foreach ($e in @(@($raw[$key]) | Where-Object { $_ })) {
            if ($e.ContainsKey('Id') -and -not [string]::IsNullOrWhiteSpace([string]$e['Id'])) { continue }
            $id = $null
            $local = $localOf[$kind + '|' + [string]$e['Name']]
            $pcValid = $false
            if (-not [string]::IsNullOrEmpty($local)) {
                $m = Read-FolderMarker -Path $local
                if ($null -ne $m -and -not $m.ContainsKey('Invalid')) {
                    $pcValid = $true
                    if (-not $taken.ContainsKey(([string]$m.Id).ToLowerInvariant())) { $id = [string]$m.Id }
                }
            }
            # No valid PC ID file: the ID file at its PikPak place, when there is one with a valid, unused id. When
            # PikPak can't be read, no id is made up for this entry now (later); the others go ahead.
            $remote = $remoteOf[$kind + '|' + [string]$e['Name']]
            if (-not $pcValid -and -not $preview -and -not [string]::IsNullOrEmpty($remote)) {
                $rr = Invoke-GuiRclone -RcloneArgs @('cat', ($remote.TrimEnd('/') + '/' + (Get-FolderMarkerName -Kind $kind)))
                $found = ConvertTo-RemoteMarkerResult -Result $rr
                if ($found.Failed) {
                    Write-GuiLog $Ctx.Config ('Reading the ID file at {0} failed (exit {1}): {2}' -f $remote, $rr.ExitCode, (@($rr.Errors) -join ' '))
                    $later = $true
                    continue
                }
                if ($found.Found -and -not $found.Marker.ContainsKey('Invalid') -and -not $taken.ContainsKey(([string]$found.Marker.Id).ToLowerInvariant())) {
                    $id = [string]$found.Marker.Id
                }
            }
            if ($null -eq $id) { $id = New-FolderId }
            $taken[$id.ToLowerInvariant()] = $true
            $e['Id'] = $id
            $assigned++
        }
    }
    $out = @{ assigned = $assigned }
    if ($later) { $out['later'] = $true }
    if ($assigned -gt 0) {
        Save-GuiConfig -Ctx $Ctx -Config $raw
        if ($preview) {
            $out['preview'] = @(("Would give {0} folder(s) an ID. Nothing is moved or deleted." -f $assigned))
            return $out
        }
    }
    elseif ($preview) { return $out }
    # Encrypted folders that are there without an ID file get one now (on this PC only), paused ones included.
    $written = 0
    try {
        $state = Get-MirrorState -StateDir $Ctx.Config.StateDir
        foreach ($f in @(Get-SyncFolders -Config (Get-MirrorConfig -Path $Ctx.ConfigPath) | Where-Object { $_.Kind -eq 'private' })) {
            try { if (Write-GuiEncryptedMarkerIfMissing -Folder $f -State $state -Now $Ctx.Now) { $written++ } }
            catch { Write-GuiLog $Ctx.Config ('Writing the ID file of {0} failed: {1}' -f $f.Local, $_.Exception.Message) }
        }
    }
    catch { Write-GuiLog $Ctx.Config ('Writing the encrypted ID files failed: ' + $_.Exception.Message) }
    if ($written -gt 0) { $out['markers'] = $written }
    $out
}

# ===== Actions: private folders =====================================================================

function Get-GuiPlainCopyCheck {
    # Is a plain (unencrypted) copy of the folder already in PikPak? One `rclone lsf` per place it would be.
    param([Parameter(Mandatory)][string[]]$RemotePaths)
    $verified = $true; $found = $false; $where = @(); $unverified = @()
    if (-not (Test-RcloneInstalled)) {
        return @{ verified = $false; found = $false; message = "rclone isn't installed, so PikPak couldn't be checked for a plain copy." }
    }
    foreach ($rp in $RemotePaths) {
        $r = Invoke-GuiRclone -RcloneArgs @('lsf', $rp)
        $c = Get-PlainCopyCheckResult -ExitCode $r.ExitCode -Listing ([string[]]@($r.Output)) -RemotePath $rp
        if (-not $c.Verified) { $verified = $false; $unverified += $rp }
        elseif ($c.Found) { $found = $true; $where += $rp }
    }
    if ($found) {
        $msg = 'A plain (unencrypted) copy is already in PikPak at {0}. Making the folder encrypted does not delete it; delete it there yourself.' -f ($where -join ', ')
    }
    elseif (-not $verified) { $msg = "Couldn't check PikPak for a plain copy ({0}). Check your internet connection." -f ($unverified -join ', ') }
    else { $msg = 'No plain copy is in PikPak.' }
    @{ verified = $verified; found = $found; message = $msg }
}

function Invoke-GuiActionPrivateReview {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $cfg = $Ctx.Config
    $p = Get-GuiPathArg $Ctx
    $probe = @{} + $cfg
    $probe['PrivatePaths'] = @(@{ Path = $p; Name = 'review' })
    $rep = @(Get-PrivatePathReport -Config $probe)[0]
    $also = $null; $targets = @()
    foreach ($pair in @(@($cfg['Pairs']) | Where-Object { $_ })) {
        if ((Get-GuiFolderRelation $p ([string]$pair.Local)) -eq 'same') {
            $also = [string]$pair.Name
            $targets += (Join-RemotePath $cfg.Remote @($cfg.MirrorRoot, $pair.Remote))
        }
    }
    foreach ($by in @($rep.ExcludedBy)) { if ($null -ne $by) { $targets += [string]$by.RemotePath } }
    if ($targets.Count -eq 0) { $plain = @{ verified = $true; found = $false; message = 'Not inside a synced folder, so no plain copy can be in PikPak.' } }
    else { $plain = Get-GuiPlainCopyCheck -RemotePaths $targets }
    @{ path = $p; exists = [bool]$rep.Exists; sizeGB = $rep.SizeGB; plainCopy = $plain; alsoPair = $also }
}

function Assert-GuiNotSyncing {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    if (Test-SyncRunning -StateDir $Ctx.Config.StateDir) {
        throw (New-GuiException 'locked' 'A sync is running right now. Try again when it has finished.')
    }
}

function Get-GuiRemoteList {
    # `rclone listremotes` output. A failure to read is an error, never "no such remote": acting on an
    # empty list could create (or replace) a remote that is really there.
    $list = Invoke-GuiRclone -RcloneArgs @('listremotes')
    if ($list.ExitCode -ne 0) {
        throw (New-GuiException 'internal' "Couldn't read this PC's rclone settings. Try again.")
    }
    @($list.Output)
}

function Assert-GuiPrivateRemote {
    # Private folders are encrypted with the recovery key (the private rclone remote): without it every
    # backup of them would fail.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    if (-not (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name ([string]$Ctx.Config.PrivateRemote))) {
        throw (New-GuiException 'refused' "Encrypted folders need a recovery key, and this PC doesn't have one yet. Set it up with the setup steps in docs\README.md.")
    }
}

function Save-GuiPrivateConfirmation {
    # Records the confirmation hash for the private folders now in the config file.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $saved = Get-MirrorConfig -Path $Ctx.ConfigPath
    if (-not (Save-PrivateConfirmation -Config $saved)) {
        throw (New-GuiException 'locked' "Your encrypted folders were saved, but a sync started at the same moment, so they couldn't be confirmed yet. Try again when it has finished.")
    }
}

function Get-GuiPrivateOverlapMessage {
    # Plain-words reason why $Path cannot become an encrypted folder (the private.add rules), or $null. The same
    # path as an existing encrypted folder is not refused here: private.add then only confirms it again.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Path)
    foreach ($priv in @(@($Config['PrivatePaths']) | Where-Object { $_ })) {
        $rel = Get-GuiFolderRelation $Path ([string]$priv.Path)
        if ($rel -eq 'inside') { return ('{0} is already inside the encrypted folder {1}.' -f $Path, $priv.Path) }
        if ($rel -eq 'contains') { return ('{0} contains the encrypted folder {1}. Remove that one from the encrypted folders first.' -f $Path, $priv.Path) }
    }
    foreach ($pair in @(@($Config['Pairs']) | Where-Object { $_ })) {
        $rel = Get-GuiFolderRelation $Path ([string]$pair.Local)
        # A synced folder is changed with folders.convert (synced one last time first), never switched here.
        if ($rel -eq 'same') { return ('{0} is synced now. Use Make encrypted on its row on Home, so it is synced one last time first.' -f $Path) }
        if ($rel -eq 'contains') { return ("{0} contains {1}, which is synced unencrypted (as '{2}'). Remove that folder from syncing first." -f $Path, $pair.Local, $pair.Name) }
    }
    $lh = [string]$Config['LocalHolding']
    if ($lh -and $null -ne (Get-GuiFolderRelation $Path $lh)) { return ('{0} overlaps {1}, where PikPak Sync keeps deleted files.' -f $Path, $lh) }
    $null
}

function Invoke-GuiActionPrivateAdd {
    # -UseName / -UseId: set by folders.add (a reconnect or a new ID); private.add itself names the folder after its leaf.
    param([Parameter(Mandatory)][hashtable]$Ctx, [string]$UseName, [string]$UseId)
    $cfg = $Ctx.Config
    $p = Get-GuiPathArg $Ctx
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw (New-GuiException 'not-found' ("The folder {0} wasn't found." -f $p)) }
    Assert-GuiNotSyncing $Ctx
    $why = Get-GuiPrivateOverlapMessage -Config $cfg -Path $p
    if ($null -ne $why) { throw (New-GuiException 'refused' $why) }
    $already = (@(@($cfg['PrivatePaths']) | Where-Object { $_ -and (Get-GuiFolderRelation $p ([string]$_.Path)) -eq 'same' }).Count -gt 0)
    Assert-GuiPrivateRemote $Ctx

    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $preview = @()
    $name = $null
    $rewriteMarker = $false
    if (-not $already) {
        $name = $UseName
        if ([string]::IsNullOrWhiteSpace($name)) { $name = New-ConversionPrivateName -Config $raw -Path $p }
        $entry = @{ Path = $p; Name = $name }
        $newEntryId = $UseId
        $rewriteMarker = $false
        if ([string]::IsNullOrWhiteSpace($newEntryId)) {
            # As folders.add: a valid encrypted marker id that no configured folder uses, else a new one. A synced
            # folder's ID file is not taken over: the folder gets a new id and its ID file is rewritten encrypted.
            $m = Read-GuiValidMarker -Path $p
            if ($null -ne $m -and (Get-GuiMarkerKind $m) -eq 'encrypted' -and $null -eq (Find-GuiFolderById -Config $cfg -Id ([string]$m.Id))) { $newEntryId = [string]$m.Id }
            else {
                $newEntryId = New-FolderId
                if ($null -ne $m -and (Get-GuiMarkerKind $m) -ne 'encrypted') {
                    $rewriteMarker = $true
                    $preview += ('Would give {0} a new ID: its ID file says it was synced normally.' -f $p)
                }
            }
        }
        $entry['Id'] = $newEntryId
        $raw['PrivatePaths'] = @(@($raw['PrivatePaths']) | Where-Object { $_ }) + @($entry)
        $preview += ("Would make {0} an encrypted folder (locked with your recovery key) as '{1}'." -f $p, $name)
    }
    $preview += 'Would record that you confirmed the encrypted folders.'
    Save-GuiConfig -Ctx $Ctx -Config $raw
    if (Test-GuiPreview $Ctx) { return @{ saved = $false; preview = $preview } }
    if ($rewriteMarker) { Write-GuiEntryMarker -Ctx $Ctx -Kind 'private' -Name $name -Local $p -Id $newEntryId }
    Save-GuiPrivateConfirmation $Ctx
    @{ saved = $true; privatePaths = @(@((Get-RawMirrorConfig -Path $Ctx.ConfigPath)['PrivatePaths']) | Where-Object { $_ }) }
}

function Invoke-GuiActionPrivateRemove {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $p = Get-GuiPathArg $Ctx
    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $privs = @(@($raw['PrivatePaths']) | Where-Object { $_ })
    $keep = @($privs | Where-Object { (Get-GuiFolderRelation $p ([string]$_.Path)) -ne 'same' })
    if ($keep.Count -eq $privs.Count) { throw (New-GuiException 'not-found' ('{0} is not one of your encrypted folders.' -f $p)) }
    Assert-GuiNotSyncing $Ctx
    # Pairs that hold this folder back it up unlocked from now on; the app may warn about that.
    $plainBy = @(@($Ctx.Config['Pairs']) | Where-Object { $_ } | Where-Object { (Get-GuiFolderRelation $p ([string]$_.Local)) -eq 'inside' } | ForEach-Object { [string]$_.Name })
    $raw['PrivatePaths'] = $keep
    Save-GuiConfig -Ctx $Ctx -Config $raw
    if (Test-GuiPreview $Ctx) {
        $lines = @(('Would stop treating {0} as encrypted.' -f $p), 'Would record that you confirmed the encrypted folders.')
        if ($plainBy.Count -gt 0) { $lines += ('Would delete its encrypted ID file, so {0} syncs it again.' -f ($plainBy -join ', ')) }
        return @{ saved = $false; backedUpPlainBy = $plainBy; preview = $lines }
    }
    Save-GuiPrivateConfirmation $Ctx
    Clear-GuiAcceptRemoteId -Ctx $Ctx -StateKeys @($privs | Where-Object { (Get-GuiFolderRelation $p ([string]$_.Path)) -eq 'same' } | ForEach-Object { 'private:' + [string]$_.Name })
    # A synced folder leaves out every folder with an encrypted ID file (--exclude-if-present): inside one, the
    # file goes now, or this folder would never be synced again. A standalone folder keeps it.
    if ($plainBy.Count -gt 0) {
        try { $null = Remove-FolderMarkerFile -Path $p -Kind 'private' }
        catch {
            Write-GuiLog $Ctx.Config ('Deleting the encrypted ID file in {0} failed: {1}' -f $p, $_.Exception.Message)
            throw (New-GuiException 'internal' ("{0} is no longer encrypted, but its file {1} couldn't be deleted, so {2} leaves it out. Delete that file yourself." -f $p, (Get-FolderMarkerName -Kind 'private'), ($plainBy -join ', ')))
        }
    }
    @{ saved = $true; backedUpPlainBy = $plainBy; privatePaths = $keep }
}

# ===== Actions: choose and change a folder's kind ===================================================

function Get-GuiConvertPlan {
    # The plan for changing the folder at -Path (refused with the plan's own message when not allowed).
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$To, [bool]$DeleteOldCopy = $false)
    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    try { $plan = Get-FolderConversionPlan -Config $raw -Path $Path -To $To -DeleteOldCopy:$DeleteOldCopy }
    catch { throw (New-GuiException 'refused' $_.Exception.Message) }
    # The job syncs the folder one last time first; a paused folder is not synced, so it can't be changed.
    if ([bool]$plan.From.Paused) { throw (New-GuiException 'refused' ('Resume {0} first, then change it.' -f $plan.From.Name)) }
    $plan
}

function Invoke-GuiActionFoldersConvertReview {
    # What the confirm box needs before a change. Changes nothing; works in preview.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $p = Get-GuiPathArg $Ctx
    $to = [string](Get-GuiArg $Ctx 'to' '')
    if ($to -ne 'encrypted' -and $to -ne 'plain') { throw (New-GuiException 'bad-request' "The change must be to 'encrypted' or 'plain'.") }
    $plan = Get-GuiConvertPlan -Ctx $Ctx -Path $p -To $to
    $size = $null
    $complete = $true
    if (Test-Path -LiteralPath $p -PathType Container) {
        $m = Measure-GuiFolder -Path $p -MaxSeconds 20
        $size = [math]::Round(([double]$m.bytes) / 1GB, 6)
        $complete = [bool]$m.complete
    }
    @{
        name = [string]$plan.From.Name; path = $p; sizeGB = $size; sizeComplete = $complete
        oldRemote = [string]$plan.OldRemote; oldCopyPlace = [string]$plan.OldCopyPlace; note = $plan.Note
        canDeleteOldCopy = ($null -eq $plan.PurgeRefusal); purgeRefusal = $plan.PurgeRefusal
    }
}

function Invoke-GuiActionFoldersConvert {
    # Changes a synced folder to encrypted, or an encrypted folder to a normal synced one, as a detached job
    # (scripts\Convert-Folder.ps1: last sync, switch, forget old state, delete the old copy when asked, first sync).
    # The app never deletes anything itself.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $p = Get-GuiPathArg $Ctx
    $to = [string](Get-GuiArg $Ctx 'to' '')
    if ($to -ne 'encrypted' -and $to -ne 'plain') { throw (New-GuiException 'bad-request' "The change must be to 'encrypted' or 'plain'.") }
    $del = $false
    $dv = Get-GuiArg $Ctx 'deleteOldCopy' $false
    if ($dv -is [bool] -and $dv) { $del = $true }
    $plan = Get-GuiConvertPlan -Ctx $Ctx -Path $p -To $to -DeleteOldCopy $del
    if ($to -eq 'encrypted') { Assert-GuiPrivateRemote $Ctx }
    Assert-GuiNotSyncing $Ctx
    Assert-GuiNotBudgetPaused -Ctx $Ctx -Then 'change the folder'
    $script = Join-Path $Ctx.RepoRoot 'scripts\Convert-Folder.ps1'
    $cfgFull = [IO.Path]::GetFullPath($Ctx.ConfigPath)
    $line = (Get-HeadlessPowerShellArgument -ScriptPath $script -ConfigPath $cfgFull) + ' -Path ' + (ConvertTo-ProcessArgument $p) + ' -To ' + $to
    if ($del) { $line += ' -DeleteOldCopy' }
    if (Test-GuiPreview $Ctx) {
        $what = 'encrypted (locked with your recovery key)'
        if ($to -eq 'plain') { $what = 'a normal synced folder (readable in PikPak)' }
        $lines = @(
            ("Would change '{0}' ({1}) to {2}. Would sync it one last time first; if that fails, nothing changes." -f $plan.From.Name, $p, $what),
            ('Would start in the background: conhost.exe {0}' -f $line)
        )
        if ($del) { $lines += ("The old copy {0} would be deleted (it goes to PikPak's trash)." -f $plan.OldCopyPlace) }
        else { $lines += ('The old copy {0} would stay.' -f $plan.OldCopyPlace) }
        if ($plan.Note) { $lines += [string]$plan.Note }
        return @{ started = $false; preview = [string[]]$lines }
    }
    Start-GuiDetached -FilePath 'conhost.exe' -Arguments $line
    @{ started = $true }
}

# ===== Actions: folder identity (identify, add, Locate..., adopt, Give a new ID) =====================
# A folder's ID file (Marker.ps1) says which configured folder it is. These actions use it to recognise a folder
# being added, to point an entry at a folder that moved, to make a folder take its entry's ID ("Use this folder
# anyway") and to split a copy off with a new ID. The app calls the write actions only after the owner confirmed
# them in a box. Spec: docs\superpowers\specs\2026-11-19-folder-identity-design.md.

function Get-GuiFolderSelection {
    # name + private pick one configured folder, as sync.repair does: @{ Name; Key; Folder (Get-SyncFolders item) }.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $name = [string](Get-GuiArg $Ctx 'name' '')
    if ([string]::IsNullOrWhiteSpace($name)) { throw (New-GuiException 'bad-request' 'No folder name was given.') }
    $kind = 'pair'
    $priv = Get-GuiArg $Ctx 'private' $false
    if ($priv -is [bool] -and $priv) { $kind = 'private' }
    $folder = @(Get-SyncFolders -Config $Ctx.Config | Where-Object { $_.Kind -eq $kind -and [string]$_.Name -ieq $name }) | Select-Object -First 1
    if ($null -eq $folder) { throw (New-GuiException 'not-found' ("No synced folder is called '{0}'." -f $name)) }
    $key = 'Pairs'; if ($kind -eq 'private') { $key = 'PrivatePaths' }
    @{ Name = [string]$folder.Name; Key = $key; Folder = $folder }
}

function Get-GuiRawEntry {
    # The raw config entry (the hashtable a save writes) named $Sel.Name in $Sel.Key.
    param([Parameter(Mandatory)][hashtable]$Raw, [Parameter(Mandatory)][hashtable]$Sel)
    @(@($Raw[$Sel.Key]) | Where-Object { $_ -and [string]$_.Name -ieq $Sel.Name }) | Select-Object -First 1
}

function Find-GuiFolderById {
    # The configured folder (Get-SyncFolders item) whose Id is $Id, or $null.
    param([Parameter(Mandatory)][hashtable]$Config, [string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    @(Get-SyncFolders -Config $Config | Where-Object { -not [string]::IsNullOrEmpty([string]$_.Id) -and [string]$_.Id -eq $Id }) | Select-Object -First 1
}

function ConvertTo-GuiConfiguredInfo {
    # @{ name; private; path; exists } of a configured folder, or $null.
    param($Folder)
    if ($null -eq $Folder) { return $null }
    $p = [string]$Folder.Local
    @{ name = [string]$Folder.Name; private = ($Folder.Kind -eq 'private'); path = $p; exists = (Test-Path -LiteralPath $p -PathType Container) }
}

function Read-GuiValidMarker {
    # The folder's ID file when it is valid, else $null (none, or one that can't be read).
    param([Parameter(Mandatory)][string]$Path)
    $m = Read-FolderMarker -Path $Path
    if ($null -eq $m -or $m.ContainsKey('Invalid')) { return $null }
    $m
}

function Get-GuiMarkerKind {
    # 'synced' or 'encrypted': the marker's kind field, else the kind its file name stands for.
    param([Parameter(Mandatory)][hashtable]$Marker)
    $k = [string]$Marker.Kind
    if ($k -eq 'synced' -or $k -eq 'encrypted') { return $k }
    if ($Marker.FileKind -eq 'private') { return 'encrypted' }
    'synced'
}

function Get-GuiKindNote {
    param([Parameter(Mandatory)][string]$MarkerKind)
    if ($MarkerKind -eq 'encrypted') { return 'This folder was encrypted before; it will be reconnected encrypted.' }
    'This folder was synced normally before; it will be reconnected that way.'
}

function Get-GuiNestedFolders {
    # The ID files inside $Path, as the add and Locate boxes list them: @{ Items; Complete }.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Path)
    $scan = Find-NestedMarkers -Path $Path
    $items = @(foreach ($i in @($scan.Items)) {
            $m = $i.Marker
            if ($m.ContainsKey('Invalid')) { continue }
            @{
                path = [string]$i.Path; kind = (Get-GuiMarkerKind $m); name = [string]$m.Name
                configured = (ConvertTo-GuiConfiguredInfo (Find-GuiFolderById -Config $Ctx.Config -Id ([string]$m.Id)))
            }
        })
    @{ Items = $items; Complete = [bool]$scan.Complete }
}

function Get-GuiPairRemoteUser {
    # The pair whose Remote is the same as, inside or around $Remote, or $null. $Except: a pair Name to skip.
    param([Parameter(Mandatory)][hashtable]$Config, [string]$Remote, [string]$Except)
    $k = (ConvertTo-RemoteKey $Remote) + '/'
    if ($k -eq '/') { return $null }
    foreach ($pair in @(@($Config['Pairs']) | Where-Object { $_ })) {
        if ($Except -and [string]$pair.Name -ieq $Except) { continue }
        $o = (ConvertTo-RemoteKey ([string]$pair.Remote)) + '/'
        if ($o -eq '/') { continue }
        if ($k.StartsWith($o, [StringComparison]::Ordinal) -or $o.StartsWith($k, [StringComparison]::Ordinal)) { return $pair }
    }
    $null
}

function Get-GuiPairRemoteKeys {
    # @{ <remote key> = $true } of the pairs, except the one named $Except.
    param([Parameter(Mandatory)][hashtable]$Config, [string]$Except)
    $t = @{}
    foreach ($pair in @(@($Config['Pairs']) | Where-Object { $_ })) {
        if ($Except -and [string]$pair.Name -ieq $Except) { continue }
        $t[(ConvertTo-RemoteKey ([string]$pair.Remote))] = $true
    }
    $t
}

$script:GuiFreePlaceTries = 50

function Get-GuiFreePairRemote {
    # The path-derived Remote of $Path, with ' (2)', ' (3)'... appended while it is taken: the same as, inside or
    # around a remote key in $Taken. With -Ctx (a new copy: add with newId, folders.newId) a place that exists in
    # PikPak is taken too (`rclone lsf <place> --max-depth 1` must exit 3); not checked in preview.
    # Refused after $script:GuiFreePlaceTries names.
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Taken, [hashtable]$Ctx)
    $check = ($null -ne $Ctx -and -not (Test-GuiPreview $Ctx))
    $base = (New-MirrorPair -Path $Path -Config $Config).Remote
    $isTaken = {
        param([string]$k)
        foreach ($t in @($Taken.Keys)) {
            $o = [string]$t
            if ($o -eq '') { continue }
            if ($o -eq $k -or $k.StartsWith($o + '/', [StringComparison]::Ordinal) -or $o.StartsWith($k + '/', [StringComparison]::Ordinal)) { return $true }
        }
        $false
    }
    $r = $base; $n = 2
    while ($true) {
        if ($n -gt $script:GuiFreePlaceTries + 1) { throw (New-GuiException 'refused' 'No free place for this folder was found in PikPak.') }
        if (-not (& $isTaken (ConvertTo-RemoteKey $r))) {
            if (-not $check) { return $r }
            $place = Join-RemotePath ([string]$Ctx.Config.Remote) @([string]$Ctx.Config.MirrorRoot, $r)
            $x = Invoke-GuiRclone -RcloneArgs @('lsf', $place, '--max-depth', '1')
            if ($x.ExitCode -eq 3) { return $r }
            if ($x.ExitCode -ne 0) { Assert-GuiNewPlaceChecked -Ctx $Ctx -What $place -Result $x }
        }
        $r = '{0} ({1})' -f $base, $n; $n++
    }
}

function Assert-GuiNewPlaceChecked {
    # Refuses (nothing saved) when PikPak could not be checked for a new copy's place.
    param([Parameter(Mandatory)][hashtable]$Ctx, [string]$What, $Result)
    Write-GuiLog $Ctx.Config ('Checking {0} failed (exit {1}): {2}' -f $What, $Result.ExitCode, (@($Result.Errors) -join ' '))
    throw (New-GuiException 'refused' "PikPak couldn't be checked, so a new place for this folder couldn't be chosen. Try again.")
}

function Get-GuiFreePrivateName {
    # The next free Name for an encrypted folder at $Path that starts a new copy: names in the config and (not in
    # preview) the folders in <PrivateRemote>: count as taken.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Raw, [Parameter(Mandatory)][string]$Path)
    $probe = @{ PrivatePaths = @(@($Raw['PrivatePaths']) | Where-Object { $_ }) }
    if (-not (Test-GuiPreview $Ctx)) {
        $root = [string]$Ctx.Config.PrivateRemote + ':'
        $x = Invoke-GuiRclone -RcloneArgs @('lsf', $root, '--dirs-only')
        if ($x.ExitCode -ne 0) { Assert-GuiNewPlaceChecked -Ctx $Ctx -What $root -Result $x }
        foreach ($d in @($x.Output)) {
            $n = ([string]$d).Trim().TrimEnd('/')
            if ($n) { $probe.PrivatePaths += @(@{ Name = $n }) }
        }
    }
    New-ConversionPrivateName -Config $probe -Path $Path
}

function Write-GuiEntryMarker {
    # Writes a folder's ID file now, replacing whatever ID it had (-Force).
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Local, [string]$Remote, [Parameter(Mandatory)][string]$Id)
    $cfg = $Ctx.Config
    if ($Kind -eq 'private') { $rp = Join-RemotePath ([string]$cfg.PrivateRemote) @($Name) }
    else { $rp = Join-RemotePath ([string]$cfg.Remote) @([string]$cfg.MirrorRoot, $Remote) }
    $null = Write-FolderMarker -Folder @{ Kind = $Kind; Name = $Name; Local = $Local; RemotePath = $rp; Id = $Id } -Now $Ctx.Now -Force
}

# ----- folders.identify ------------------------------------------------------------------------------

function Get-GuiMarkerPlace {
    # The PikPak place an ID file names, when this config could use it and no configured folder does:
    # @{ Remote; Name } or $null. Synced: <Remote>:<MirrorRoot>/<rel> (Name = <rel>, a pair's Remote);
    # encrypted: <PrivateRemote>:<Name> (one folder, never _holding).
    param([Parameter(Mandatory)][hashtable]$Config, [Parameter(Mandatory)][hashtable]$Marker, [Parameter(Mandatory)][string]$Kind)
    $pk = [string]$Marker.PikPak
    $cmp = [StringComparison]::OrdinalIgnoreCase
    if ($Kind -eq 'encrypted') {
        $prefix = [string]$Config.PrivateRemote + ':'
        if (-not $pk.StartsWith($prefix, $cmp)) { return $null }
        $name = $pk.Substring($prefix.Length).Trim('/')
        if ($name -eq '' -or $name.Contains('/') -or $name -ieq '_holding') { return $null }
        if (@(@($Config['PrivatePaths']) | Where-Object { $_ -and ([string]$_.Name).Trim() -ieq $name }).Count -gt 0) { return $null }
        return @{ Remote = $prefix + $name; Name = $name }
    }
    $prefix = [string]$Config.Remote + ':' + ([string]$Config.MirrorRoot).Trim('/') + '/'
    if (-not $pk.StartsWith($prefix, $cmp)) { return $null }
    $rel = $pk.Substring($prefix.Length).Trim('/')
    if ($rel -eq '' -or $null -ne (Get-GuiPairRemoteUser -Config $Config -Remote $rel)) { return $null }
    @{ Remote = $prefix + $rel; Name = $rel }
}

function Get-GuiEarlierCopy {
    # Rules 2 and 3 of folders.identify: an earlier copy of the folder in PikPak.
    # @{ Pikpak = $null | @{ remote; name; matches; id (of the ID file there, or $null) }; Failed = [bool] (rclone
    # could not check) }.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Kind, $Marker)
    $cfg = $Ctx.Config
    $none = @{ Pikpak = $null; Failed = $false }
    $failed = @{ Pikpak = $null; Failed = $true }
    $fileKind = 'pair'; if ($Kind -eq 'encrypted') { $fileKind = 'private' }
    # 2. The ID file names its PikPak place, and the ID file there has the same ID.
    if ($null -ne $Marker) {
        $place = Get-GuiMarkerPlace -Config $cfg -Marker $Marker -Kind $Kind
        if ($null -ne $place) {
            $target = $place.Remote.TrimEnd('/') + '/' + (Get-FolderMarkerName -Kind $fileKind)
            $r = Invoke-GuiRclone -RcloneArgs @('cat', $target)
            $found = ConvertTo-RemoteMarkerResult -Result $r
            if ($found.Failed) { return $failed }
            if ($found.Found) {
                $rm = $found.Marker
                if (-not $rm.ContainsKey('Invalid') -and [string]$rm.Id -eq [string]$Marker.Id) {
                    return @{ Pikpak = @{ remote = $place.Remote; name = $place.Name; matches = $true; id = [string]$rm.Id }; Failed = $false }
                }
            }
        }
    }
    # 3. A folder already sits where this one would go, and no configured folder uses it. The ID file there (if
    # any) gives its id: a Reconnect takes it, so the run's PikPak ID check passes.
    $placeId = {
        param([string]$Remote)
        $x = ConvertTo-RemoteMarkerResult -Result (Invoke-GuiRclone -RcloneArgs @('cat', ($Remote.TrimEnd('/') + '/' + (Get-FolderMarkerName -Kind $fileKind))))
        if ($x.Failed) { return @{ Failed = $true; Id = $null } }
        if ($x.Found -and -not $x.Marker.ContainsKey('Invalid')) { return @{ Failed = $false; Id = [string]$x.Marker.Id } }
        @{ Failed = $false; Id = $null }
    }
    if ($Kind -eq 'encrypted') {
        $leaf = New-ConversionPrivateName -Config @{ PrivatePaths = @() } -Path $Path
        if (@(@($cfg['PrivatePaths']) | Where-Object { $_ -and ([string]$_.Name).Trim() -ieq $leaf }).Count -gt 0) { return $none }
        $r = Invoke-GuiRclone -RcloneArgs @('lsf', ([string]$cfg.PrivateRemote + ':'), '--dirs-only')
        if ($r.ExitCode -ne 0) { return $failed }
        $hit = @(@($r.Output) | ForEach-Object { ([string]$_).Trim().TrimEnd('/') } | Where-Object { $_ -ieq $leaf }) | Select-Object -First 1
        if ($null -eq $hit) { return $none }
        $where = [string]$cfg.PrivateRemote + ':' + $hit
        $pid3 = & $placeId $where
        if ($pid3.Failed) { return $failed }
        return @{ Pikpak = @{ remote = $where; name = $hit; matches = $false; id = $pid3.Id }; Failed = $false }
    }
    $remote = (New-MirrorPair -Path $Path -Config $cfg).Remote
    if ($null -ne (Get-GuiPairRemoteUser -Config $cfg -Remote $remote)) { return $none }
    $place = Join-RemotePath ([string]$cfg.Remote) @([string]$cfg.MirrorRoot, $remote)
    $r = Invoke-GuiRclone -RcloneArgs @('lsf', $place, '--max-depth', '1')
    if ($r.ExitCode -eq 3) { return $none }
    if ($r.ExitCode -ne 0) { return $failed }
    $pid3 = & $placeId $place
    if ($pid3.Failed) { return $failed }
    @{ Pikpak = @{ remote = $place; name = $remote; matches = $false; id = $pid3.Id }; Failed = $false }
}

function Invoke-GuiActionFoldersIdentify {
    # What the add box needs to know about a folder before it is added (spec: Adding a folder). Changes nothing.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $p = Get-GuiPathArg $Ctx
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw (New-GuiException 'not-found' ("The folder {0} wasn't found." -f $p)) }
    $want = 'synced'
    $enc = Get-GuiArg $Ctx 'encrypted' $false
    if ($enc -is [bool] -and $enc) { $want = 'encrypted' }
    $m = Read-GuiValidMarker -Path $p
    $kind = $want; $note = $null; $markerOut = $null
    if ($null -ne $m) {
        $kind = Get-GuiMarkerKind $m
        if ($kind -ne $want) { $note = Get-GuiKindNote $kind }
        $markerOut = @{ id = [string]$m.Id; kind = $kind; name = [string]$m.Name }
    }
    $nested = Get-GuiNestedFolders -Ctx $Ctx -Path $p
    $out = @{
        path = $p; marker = $markerOut; case = 'new'; configured = $null; pikpak = $null
        kind = $kind; kindNote = $note; nested = $nested.Items; nestedComplete = $nested.Complete
    }
    # 1. Its ID is a configured folder's: moved (that path is gone) or a copy (it is still there).
    $owner = $null
    if ($null -ne $m) { $owner = Find-GuiFolderById -Config $Ctx.Config -Id ([string]$m.Id) }
    if ($null -ne $owner) {
        $out.configured = ConvertTo-GuiConfiguredInfo $owner
        if ($out.configured.exists) { $out.case = 'copy' } else { $out.case = 'moved' }
        return $out
    }
    # 2 and 3. An earlier copy in PikPak; 4. otherwise new.
    $copy = Get-GuiEarlierCopy -Ctx $Ctx -Path $p -Kind $kind -Marker $m
    if ($copy.Failed) {
        $Ctx.Warning = "PikPak couldn't be checked for an earlier copy of this folder."
        return $out
    }
    if ($null -ne $copy.Pikpak) { $out.case = 'reconnect'; $out.pikpak = $copy.Pikpak }
    $out
}

# ----- folders.add: ID, place and name of the folder being added -------------------------------------

function Resolve-GuiAddIdentity {
    # The refusals for a folder's ID file when it is added, then the ID it gets: @{ Id; NewId; Rewrite } (Rewrite:
    # the PC ID file has another, unused id and is overwritten with Id).
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][bool]$Encrypted)
    $nv = Get-GuiArg $Ctx 'newId' $false
    if ($nv -is [bool] -and $nv) { return @{ Id = (New-FolderId); NewId = $true; Rewrite = $false } }
    $m = Read-GuiValidMarker -Path $Path
    if ($null -ne $m) {
        $mk = Get-GuiMarkerKind $m
        $want = 'synced'; if ($Encrypted) { $want = 'encrypted' }
        if ($mk -ne $want) { throw (New-GuiException 'refused' (Get-GuiKindNote $mk)) }
        $owner = Find-GuiFolderById -Config $Ctx.Config -Id ([string]$m.Id)
        if ($null -ne $owner) {
            throw (New-GuiException 'refused' ("This folder has the same ID as '{0}'. Choose what to do in the box." -f $owner.Name))
        }
    }
    $idArg = [string](Get-GuiArg $Ctx 'id' '')
    if (-not [string]::IsNullOrWhiteSpace($idArg)) {
        if (-not (Test-FolderId $idArg)) { throw (New-GuiException 'bad-request' ("'{0}' isn't a folder ID." -f $idArg)) }
        $owner = Find-GuiFolderById -Config $Ctx.Config -Id $idArg
        if ($null -ne $owner) { throw (New-GuiException 'refused' ("That ID is already used by '{0}'." -f $owner.Name)) }
        # The id comes from the ID file in PikPak (Reconnect, confirmed in its box). A PC ID file with another id
        # that no configured folder uses (one that is used was refused above) is overwritten with it.
        $rewrite = ($null -ne $m -and [string]$m.Id -ne $idArg)
        return @{ Id = $idArg; NewId = $false; Rewrite = $rewrite }
    }
    if ($null -ne $m) { return @{ Id = [string]$m.Id; NewId = $false; Rewrite = $false } }
    @{ Id = (New-FolderId); NewId = $false; Rewrite = $false }
}

function Resolve-GuiAddRemote {
    # A synced folder's Remote when it is added: the free path-derived one (new ID), the exact one asked for
    # (a reconnect), else the path-derived one as always.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Raw, [Parameter(Mandatory)][string]$Path, [bool]$NewId)
    if ($NewId) { return Get-GuiFreePairRemote -Config $Raw -Path $Path -Taken (Get-GuiPairRemoteKeys -Config $Raw) -Ctx $Ctx }
    $arg = [string](Get-GuiArg $Ctx 'remote' '')
    if ([string]::IsNullOrWhiteSpace($arg)) { return (New-MirrorPair -Path $Path -Config $Raw).Remote }
    $segs = @($arg.Split('/') | ForEach-Object { $_.Trim() })
    if ($arg.Contains('\') -or $arg.Contains(':') -or $arg.Trim().StartsWith('/') -or ($segs -contains '..') -or ($segs -contains '.')) {
        throw (New-GuiException 'bad-request' ("'{0}' isn't a folder path inside {1} in PikPak." -f $arg, $Raw['MirrorRoot']))
    }
    $user = Get-GuiPairRemoteUser -Config $Raw -Remote $arg
    if ($null -ne $user) { throw (New-GuiException 'refused' ("The PikPak folder {0} is already used by '{1}'." -f $arg, $user.Name)) }
    $arg
}

function Resolve-GuiAddPrivateName {
    # An encrypted folder's Name when it is added: the exact one asked for (a reconnect), else the next free name.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Raw, [Parameter(Mandatory)][string]$Path, [bool]$NewId)
    $arg = [string](Get-GuiArg $Ctx 'name' '')
    if ($NewId) { return Get-GuiFreePrivateName -Ctx $Ctx -Raw $Raw -Path $Path }
    if ([string]::IsNullOrWhiteSpace($arg)) { return New-ConversionPrivateName -Config $Raw -Path $Path }
    if ($arg -match '[\\/:*?"<>|]' -or $arg.Trim() -ne $arg) { throw (New-GuiException 'bad-request' ("'{0}' can't be the name of an encrypted folder." -f $arg)) }
    $used = @(@($Raw['PrivatePaths']) | Where-Object { $_ -and ([string]$_.Name).Trim() -ieq $arg }).Count -gt 0
    if ($used -or $arg -ieq '_holding') { throw (New-GuiException 'refused' ("The name '{0}' is already used by another encrypted folder." -f $arg)) }
    $arg
}

# ----- folders.locateReview / folders.locate ---------------------------------------------------------

function Get-GuiLocateMatch {
    # How the folder at $Path relates to $Folder: @{ Match = 'same'|'none'|'other'; OtherName }.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Folder, [Parameter(Mandatory)][string]$Path)
    $m = Read-GuiValidMarker -Path $Path
    if ($null -eq $m) { return @{ Match = 'none'; OtherName = $null } }
    if (-not [string]::IsNullOrEmpty([string]$Folder.Id) -and [string]$m.Id -eq [string]$Folder.Id) { return @{ Match = 'same'; OtherName = $null } }
    $other = [string]$m.Name
    $owner = Find-GuiFolderById -Config $Ctx.Config -Id ([string]$m.Id)
    if ($null -ne $owner) { $other = [string]$owner.Name }
    @{ Match = 'other'; OtherName = $other }
}

function Get-GuiLocateRemote {
    # The Remote a synced folder found at $Path would get (path-derived, made free), or $null when that is its
    # current Remote. An encrypted folder keeps private:<Name>: always $null.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Sel, [Parameter(Mandatory)][string]$Path)
    if ($Sel.Key -ne 'Pairs') { return $null }
    $r = Get-GuiFreePairRemote -Config $Ctx.Config -Path $Path -Taken (Get-GuiPairRemoteKeys -Config $Ctx.Config -Except $Sel.Name)
    if ((ConvertTo-RemoteKey $r) -eq (ConvertTo-RemoteKey ([string]$Sel.Folder.Remote))) { return $null }
    $r
}

function Assert-GuiLocatePath {
    # The add rules for a folder's new path, checked against the config without that folder.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][hashtable]$Sel, [Parameter(Mandatory)][string]$Path)
    if ($Path -match '^[A-Za-z]:\\?$') { throw (New-GuiException 'refused' ('{0} is a whole drive. Choose a folder on it.' -f $Path)) }
    $probe = @{} + $Ctx.Config
    $probe[$Sel.Key] = @(@($Ctx.Config[$Sel.Key]) | Where-Object { $_ -and [string]$_.Name -ine $Sel.Name })
    if ($Sel.Key -eq 'Pairs') { $why = Get-GuiPairOverlapMessage -Config $probe -Path $Path }
    else {
        $why = Get-GuiPrivateOverlapMessage -Config $probe -Path $Path
        foreach ($priv in @(@($probe['PrivatePaths']) | Where-Object { $_ })) {
            if ($null -eq $why -and (Get-GuiFolderRelation $Path ([string]$priv.Path)) -eq 'same') { $why = '{0} is already an encrypted folder.' -f $Path }
        }
    }
    if ($null -ne $why) { throw (New-GuiException 'refused' $why) }
}

function Get-GuiAlsoLocate {
    # The encrypted folders that moved with the located one: @{ Name; Path } each, checked (an encrypted folder,
    # its new folder there, its ID file with that folder's ID). Emitted unrolled.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    foreach ($a in @(Get-GuiArg $Ctx 'alsoLocate' @())) {
        if ($a -isnot [hashtable]) { throw (New-GuiException 'bad-request' 'The folders to update too are not valid.') }
        $n = [string]$a['name']
        $f = @(Get-SyncFolders -Config $Ctx.Config | Where-Object { $_.Kind -eq 'private' -and [string]$_.Name -ieq $n }) | Select-Object -First 1
        if ($null -eq $f) { throw (New-GuiException 'not-found' ("No encrypted folder is called '{0}'." -f $n)) }
        $p = Get-GuiPathArg -Ctx @{ Args = $a } -Name 'path'
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw (New-GuiException 'not-found' ("The folder {0} wasn't found." -f $p)) }
        $match = Get-GuiLocateMatch -Ctx $Ctx -Folder $f -Path $p
        if ($match.Match -eq 'none') { throw (New-GuiException 'refused' ("{0} has no ID, so the app can't tell if it is '{1}'." -f $p, $f.Name)) }
        if ($match.Match -eq 'other') { throw (New-GuiException 'refused' ("This is '{0}', not '{1}'." -f $match.OtherName, $f.Name)) }
        @{ Name = [string]$f.Name; Path = $p }
    }
}

function Move-GuiPairInPikPak {
    # Moves a synced folder inside PikPak (server side, nothing is uploaded). The new place must not exist yet.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$From, [Parameter(Mandatory)][string]$To)
    $r = Invoke-GuiRclone -RcloneArgs @('lsf', $To, '--max-depth', '1')
    if ($r.ExitCode -eq 0) { throw (New-GuiException 'refused' ('PikPak already has a folder at {0}. Nothing was changed.' -f $To)) }
    if ($r.ExitCode -ne 3) {
        Write-GuiLog $Ctx.Config ('Checking {0} failed (exit {1}): {2}' -f $To, $r.ExitCode, (@($r.Errors) -join ' '))
        throw (New-GuiException 'refused' ("PikPak couldn't be checked, so the folder wasn't moved there. Nothing was changed."))
    }
    $r = Invoke-GuiRclone -RcloneArgs @('moveto', $From, $To)
    if ($r.ExitCode -ne 0) {
        Write-GuiLog $Ctx.Config ('Moving {0} to {1} failed (exit {2}): {3}' -f $From, $To, $r.ExitCode, (@($r.Errors) -join ' '))
        throw (New-GuiException 'refused' ("The folder couldn't be moved in PikPak from {0} to {1}. Your settings were not changed." -f $From, $To))
    }
}

function Invoke-GuiActionFoldersLocateReview {
    # What the Locate... box needs. Changes nothing.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $sel = Get-GuiFolderSelection $Ctx
    $p = Get-GuiPathArg $Ctx
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw (New-GuiException 'not-found' ("The folder {0} wasn't found." -f $p)) }
    $match = Get-GuiLocateMatch -Ctx $Ctx -Folder $sel.Folder -Path $p
    $nested = Get-GuiNestedFolders -Ctx $Ctx -Path $p
    @{
        match = $match.Match; otherName = $match.OtherName; oldPath = [string]$sel.Folder.Local
        newRemote = (Get-GuiLocateRemote -Ctx $Ctx -Sel $sel -Path $p); nested = $nested.Items; nestedComplete = $nested.Complete
    }
}

function Invoke-GuiActionFoldersLocate {
    # Points a folder (and the encrypted folders that moved with it) at its new path; with movePikpak a synced
    # folder's PikPak copy is moved to its new path-derived place first. One config save.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $sel = Get-GuiFolderSelection $Ctx
    $p = Get-GuiPathArg $Ctx
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { throw (New-GuiException 'not-found' ("The folder {0} wasn't found." -f $p)) }
    Assert-GuiLocatePath -Ctx $Ctx -Sel $sel -Path $p
    $match = Get-GuiLocateMatch -Ctx $Ctx -Folder $sel.Folder -Path $p
    if ($match.Match -eq 'other') { throw (New-GuiException 'refused' ("This is '{0}', not '{1}'." -f $match.OtherName, $sel.Name)) }
    $force = Get-GuiArg $Ctx 'force' $false
    if ($match.Match -eq 'none' -and -not ($force -is [bool] -and $force)) {
        throw (New-GuiException 'refused' 'This folder has no ID. Confirm to use it anyway.')
    }
    $also = @(Get-GuiAlsoLocate -Ctx $Ctx)
    Assert-GuiNotSyncing $Ctx
    $isPair = ($sel.Key -eq 'Pairs')
    $newRemote = $null
    $mv = Get-GuiArg $Ctx 'movePikpak' $false
    if ($isPair -and $mv -is [bool] -and $mv) { $newRemote = Get-GuiLocateRemote -Ctx $Ctx -Sel $sel -Path $p }

    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $entry = Get-GuiRawEntry -Raw $raw -Sel $sel
    if ($isPair) { $entry['Local'] = $p } else { $entry['Path'] = $p }
    if ($null -ne $newRemote) { $entry['Remote'] = $newRemote }
    foreach ($a in $also) { (Get-GuiRawEntry -Raw $raw -Sel @{ Key = 'PrivatePaths'; Name = $a.Name })['Path'] = $a.Path }
    $pathChanged = (-not $isPair) -or ($also.Count -gt 0)
    $cfg = $Ctx.Config
    $oldPlace = $null; $newPlace = $null
    if ($null -ne $newRemote) {
        $oldPlace = Join-RemotePath ([string]$cfg.Remote) @([string]$cfg.MirrorRoot, [string]$sel.Folder.Remote)
        $newPlace = Join-RemotePath ([string]$cfg.Remote) @([string]$cfg.MirrorRoot, $newRemote)
    }

    if (Test-GuiPreview $Ctx) {
        Save-GuiConfig -Ctx $Ctx -Config $raw
        $lines = @(("Would use {0} for '{1}' from now on (was {2}). The next sync merges both sides and deletes nothing." -f $p, $sel.Name, $sel.Folder.Local))
        if ($null -ne $newPlace) { $lines += ('Would move it in PikPak from {0} to {1} (moved inside PikPak, nothing is uploaded).' -f $oldPlace, $newPlace) }
        foreach ($a in $also) { $lines += ("Would use {0} for '{1}' too." -f $a.Path, $a.Name) }
        if ($match.Match -eq 'none') { $lines += ("Would give the folder the ID of '{0}'." -f $sel.Name) }
        return @{ saved = $false; preview = [string[]]$lines }
    }
    if ($null -ne $newPlace) {
        # The settings must be valid before anything moves in PikPak.
        $check = Test-GuiConfigCandidate -Config $raw -NextTo $Ctx.ConfigPath
        if (@($check.Errors).Count -gt 0) { throw (New-GuiException 'config-invalid' (@($check.Errors) -join ' ')) }
        Move-GuiPairInPikPak -Ctx $Ctx -From $oldPlace -To $newPlace
        Write-GuiLog $cfg ("Locate: moved '{0}' in PikPak from {1} to {2}" -f $sel.Name, $oldPlace, $newPlace)
        # The folder moved in PikPak: when the settings can't be saved, it goes back, or the owner is told where it is.
        try { Save-GuiConfig -Ctx $Ctx -Config $raw }
        catch {
            $saveErr = $_
            $reason = Get-GuiErrorMessage $_.Exception
            $back = $null
            try { $back = Invoke-GuiRclone -RcloneArgs @('moveto', $newPlace, $oldPlace) } catch { $back = $null }
            if ($null -ne $back -and $back.ExitCode -eq 0) {
                Write-GuiLog $cfg ("Locate: settings not saved ({0}); moved '{1}' back in PikPak to {2}" -f $reason, $sel.Name, $oldPlace)
                throw $saveErr
            }
            $why = 'it could not be started'
            if ($null -ne $back) { $why = 'exit {0}: {1}' -f $back.ExitCode, (@($back.Errors) -join ' ') }
            Write-GuiLog $cfg ("Locate: settings not saved ({0}); moving '{1}' back to {2} failed ({3})" -f $reason, $sel.Name, $oldPlace, $why)
            $reasonText = $reason.TrimEnd('.')
            throw (New-GuiException 'internal' ("The folder was moved in PikPak to {0}, but the settings couldn't be saved: {1}. Run Locate again and untick the move box." -f $newPlace, $reasonText))
        }
    }
    else { Save-GuiConfig -Ctx $Ctx -Config $raw }
    if ($pathChanged) { Save-GuiPrivateConfirmation $Ctx }
    Clear-GuiAcceptRemoteId -Ctx $Ctx -StateKeys (@([string]$sel.Folder.StateKey) + @($also | ForEach-Object { 'private:' + [string]$_.Name }))
    $id = [string]$sel.Folder.Id
    if ($match.Match -eq 'none' -and -not [string]::IsNullOrEmpty($id)) {
        Write-GuiEntryMarker -Ctx $Ctx -Kind ([string]$sel.Folder.Kind) -Name $sel.Name -Local $p -Remote ([string]$entry['Remote']) -Id $id
    }
    $out = @{ saved = $true; path = $p }
    if ($isPair) { $out['remote'] = [string]$entry['Remote'] }
    $out
}

# ----- folders.adopt / folders.newId -----------------------------------------------------------------

function Invoke-GuiActionFoldersAdopt {
    # "Use this folder anyway": the folder at the configured path takes the entry's ID, then a repair (a merge
    # that deletes nothing) starts. Returns the repair's result.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $sel = Get-GuiFolderSelection $Ctx
    $f = $sel.Folder
    if (-not (Test-Path -LiteralPath ([string]$f.Local) -PathType Container)) { throw (New-GuiException 'not-found' ("The folder {0} wasn't found." -f $f.Local)) }
    if ([string]::IsNullOrEmpty([string]$f.Id)) { throw (New-GuiException 'refused' ("'{0}' has no ID yet. Open the app again, then try again." -f $sel.Name)) }
    Assert-GuiNotSyncing $Ctx
    Assert-GuiNotBudgetPaused -Ctx $Ctx -Then 'repair'
    if (Test-GuiPreview $Ctx) {
        $r = Invoke-GuiActionSyncRepair -Ctx $Ctx
        $r['preview'] = [string[]](@(("Would give the folder at {0} the ID of '{1}'." -f $f.Local, $sel.Name),
                "Would skip the PikPak ID check once, so the repair writes this folder's ID file in PikPak too.") + @($r['preview']))
        return $r
    }
    Set-GuiAcceptRemoteId -Ctx $Ctx -StateKey ([string]$f.StateKey)
    $null = Write-FolderMarker -Folder $f -Now $Ctx.Now -Force
    Invoke-GuiActionSyncRepair -Ctx $Ctx
}

function Clear-GuiAcceptRemoteId {
    # Forgets AcceptRemoteId of these state keys (after Give a new ID, Locate or Stop syncing), so a flag left from
    # an earlier "Use this folder anyway" can't skip a later PikPak ID check. Best effort, under the sync lock: when
    # a run holds it, or the state can't be read, it is logged and left.
    param([Parameter(Mandatory)][hashtable]$Ctx, [string[]]$StateKeys)
    $lock = Enter-MirrorLock -StateDir $Ctx.Config.StateDir
    if ($null -eq $lock) { Write-GuiLog $Ctx.Config 'AcceptRemoteId not cleared: a sync holds the lock'; return }
    try {
        $state = Get-MirrorState -StateDir $Ctx.Config.StateDir
        $changed = $false
        foreach ($k in @($StateKeys | Where-Object { $_ })) {
            $ps = $state.Pairs[[string]$k]
            if ($null -ne $ps -and $ps.ContainsKey('AcceptRemoteId')) { $ps.Remove('AcceptRemoteId'); $changed = $true }
        }
        if ($changed) { Save-MirrorState -StateDir $Ctx.Config.StateDir -State $state }
    }
    catch { Write-GuiLog $Ctx.Config ('AcceptRemoteId not cleared: ' + $_.Exception.Message) }
    finally { Exit-MirrorLock -Handle $lock }
}

function Set-GuiAcceptRemoteId {
    # "Use this folder anyway" also clears a mismatch of the ID file in PikPak: the folder's state gets
    # AcceptRemoteId, so its next resync skips the PikPak ID check once and (path1 wins) writes the PC ID file there.
    # Load, set and save under the sync lock, as Save-PrivateConfirmation does; locked when a run holds it.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$StateKey)
    $lock = Enter-MirrorLock -StateDir $Ctx.Config.StateDir
    if ($null -eq $lock) { throw (New-GuiException 'locked' 'A sync is running right now. Try again when it has finished.') }
    try {
        $state = Get-MirrorState -StateDir $Ctx.Config.StateDir
        $ps = $state.Pairs[$StateKey]
        if ($null -eq $ps) { $ps = @{}; $state.Pairs[$StateKey] = $ps }
        $ps['AcceptRemoteId'] = $true
        Save-MirrorState -StateDir $Ctx.Config.StateDir -State $state
    }
    finally { Exit-MirrorLock -Handle $lock }
}

function Invoke-GuiActionFoldersNewId {
    # "Give a new ID": the folder starts a new copy in PikPak (the old one stays where it is). A synced folder gets
    # its path-derived place (with a suffix while taken, its current place included); an encrypted folder the
    # next free name. The ID file is rewritten now when the folder is there.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $sel = Get-GuiFolderSelection $Ctx
    Assert-GuiNotSyncing $Ctx
    $f = $sel.Folder
    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $entry = Get-GuiRawEntry -Raw $raw -Sel $sel
    $id = New-FolderId
    $out = @{}
    $name = $sel.Name; $remote = $null
    if ($sel.Key -eq 'Pairs') {
        $remote = Get-GuiFreePairRemote -Config $raw -Path ([string]$f.Local) -Taken (Get-GuiPairRemoteKeys -Config $raw) -Ctx $Ctx
        $entry['Remote'] = $remote
        $out['remote'] = $remote
        $place = '{0}/{1}' -f $raw['MirrorRoot'], $remote
    }
    else {
        $name = Get-GuiFreePrivateName -Ctx $Ctx -Raw $raw -Path ([string]$f.Local)
        $entry['Name'] = $name
        $out['name'] = $name
        $place = 'encrypted as ' + $name
    }
    $entry['Id'] = $id
    Save-GuiConfig -Ctx $Ctx -Config $raw
    if (Test-GuiPreview $Ctx) {
        $out['saved'] = $false
        $out['preview'] = @(("Would give '{0}' a new ID. It would be uploaded as a new folder ({1}); its old copy in PikPak stays where it is." -f $sel.Name, $place), 'Would check PikPak first that this new place is free; if it is taken there, the next free name is used.')
        return $out
    }
    if (Test-Path -LiteralPath ([string]$f.Local) -PathType Container) {
        Write-GuiEntryMarker -Ctx $Ctx -Kind ([string]$f.Kind) -Name $name -Local ([string]$f.Local) -Remote $remote -Id $id
    }
    $newKey = $name; if ($sel.Key -ne 'Pairs') { $newKey = 'private:' + $name }
    Clear-GuiAcceptRemoteId -Ctx $Ctx -StateKeys @([string]$f.StateKey, $newKey)
    $out['saved'] = $true
    $out
}

# ===== Actions: running syncs, schedule, cleanup ===================================================

function Get-GuiExistingTask {
    param([Parameter(Mandatory)][string]$TaskName)
    $t = Get-GuiTaskInfo -TaskName $TaskName
    if (-not $t.Exists) { throw (New-GuiException 'not-found' ("The scheduled task {0} isn't set up on this PC. Run the setup again." -f $TaskName)) }
    $t
}

function Assert-GuiNotBudgetPaused {
    # Sync now and Repair would start a run that does nothing while today's (or this month's) transfer limit is
    # used up: refuse instead of answering "started".
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Then)
    $pause = $null
    try {
        $state = Get-MirrorState -StateDir $Ctx.Config.StateDir
        $pause = Get-BudgetPause -State $state -Config $Ctx.Config -Now $Ctx.Now
    }
    catch { $pause = $null }   # an unreadable state is not a reason to refuse
    if ($pause -eq 'day') {
        throw (New-GuiException 'refused' ("Today's transfer limit is reached. Syncing carries on tomorrow, and you can {0} then." -f $Then))
    }
    if ($pause -eq 'month') {
        $next = (New-Object DateTime ($Ctx.Now.Year), ($Ctx.Now.Month), 1).AddMonths(1)
        throw (New-GuiException 'refused' ("This month's transfer limit is reached. Syncing carries on on 1 {0}, and you can {1} then." -f $next.ToString('MMMM', [Globalization.CultureInfo]::InvariantCulture), $Then))
    }
}

function Invoke-GuiActionSyncStart {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $t = Get-GuiExistingTask 'PikPakMirror-Sync'
    if (-not $t.Enabled) { throw (New-GuiException 'refused' 'Syncing is paused. Turn it back on in Settings first.') }
    Assert-GuiNotBudgetPaused -Ctx $Ctx -Then 'sync'
    if (Test-GuiPreview $Ctx) { return @{ started = $false; preview = @('Would start the sync now (scheduled task PikPakMirror-Sync).') } }
    Start-GuiTask -TaskName 'PikPakMirror-Sync'
    @{ started = $true }
}

function Invoke-GuiActionCleanup {
    # The one-time cleanup of the old drives and Explorer menu (see Invoke-MirrorCleanup); the app calls it
    # once per start. Returns what it did (or, in preview, what it would do); parts with nothing to do say nothing.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $isPreview = Test-GuiPreview $Ctx
    $cfgFull = [IO.Path]::GetFullPath($Ctx.ConfigPath)
    $res = Invoke-MirrorCleanup -Config $Ctx.Config -ConfigPath $cfgFull -RepoRoot $Ctx.RepoRoot -WhatIf:$isPreview
    $messages = @()
    foreach ($d in @($res.Details)) {
        if (-not $d.Skipped) { $messages += [string]$d.Message }
        if ($d.Warning) { $messages += [string]$d.Warning }
        if (-not $isPreview) {
            # Logged only when something happened or went wrong: this runs at every app start.
            if ($d.Done) { Write-GuiLog $Ctx.Config ('cleanup: ' + [string]$d.Message) }
            if ($d.Warning) { Write-GuiLog $Ctx.Config ('cleanup: ' + [string]$d.Warning) }
        }
    }
    $out = @{ done = [bool]$res.Done; messages = [string[]]$messages }
    if ($isPreview) { $out['preview'] = [string[]]$messages }
    $out
}

function Invoke-GuiActionSyncRepair {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    # name = the folder's Name; private = $true for an encrypted folder (its -Resync key is private:<Name>).
    $name = [string](Get-GuiArg $Ctx 'name' '')
    if ([string]::IsNullOrWhiteSpace($name)) { throw (New-GuiException 'bad-request' 'No folder name was given.') }
    $kind = 'pair'
    $priv = Get-GuiArg $Ctx 'private' $false
    if ($priv -is [bool] -and $priv) { $kind = 'private' }
    $folder = @(Get-SyncFolders -Config $Ctx.Config | Where-Object { $_.Kind -eq $kind -and [string]$_.Name -ieq $name }) | Select-Object -First 1
    if ($null -eq $folder) { throw (New-GuiException 'not-found' ("No synced folder is called '{0}'." -f $name)) }
    Assert-GuiNotSyncing $Ctx
    Assert-GuiNotBudgetPaused -Ctx $Ctx -Then 'repair'
    $script = Join-Path $Ctx.RepoRoot 'scripts\Invoke-Sync.ps1'
    $cfgFull = [IO.Path]::GetFullPath($Ctx.ConfigPath)
    $line = (Get-HeadlessPowerShellArgument -ScriptPath $script -ConfigPath $cfgFull) + ' -Resync ' + (ConvertTo-ProcessArgument ([string]$folder.StateKey))
    if (Test-GuiPreview $Ctx) { return @{ started = $false; preview = @(("Would repair '{0}': conhost.exe {1}" -f $folder.Name, $line)) } }
    Start-GuiDetached -FilePath 'conhost.exe' -Arguments $line
    @{ started = $true }
}

# ----- Encrypted folders in PikPak (Settings): list, download, delete --------------------------------

function Get-GuiRemotePrivateNames {
    # The folders directly in <PrivateRemote>: (never _holding). A failure to list is remote-failed.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $x = Invoke-GuiRclone -RcloneArgs @('lsf', ([string]$Ctx.Config.PrivateRemote + ':'), '--dirs-only')
    if ($x.ExitCode -ne 0) {
        Write-GuiLog $Ctx.Config ('Listing the encrypted folders in PikPak failed (exit {0}): {1}' -f $x.ExitCode, (@($x.Errors) -join ' '))
        throw (New-GuiException 'remote-failed' "Your encrypted folders in PikPak couldn't be listed. Try again.")
    }
    @(@($x.Output) | ForEach-Object { ([string]$_).TrimEnd('/') } | Where-Object { Test-EncryptedFolderName $_ })
}

function Get-GuiRemotePrivateInfo {
    # What ties an encrypted folder in PikPak to a configured one: @{ Id; Connected } (Connected = the configured
    # folder or $null). By ID when the folder has an ID file there, by Name when it has none. A marker that cannot
    # be read is remote-failed: "not connected" must never be a guess.
    param([Parameter(Mandatory)][hashtable]$Ctx, [Parameter(Mandatory)][string]$Name)
    $remote = [string]$Ctx.Config.PrivateRemote + ':' + $Name
    $r = Invoke-GuiRclone -RcloneArgs @('cat', ($remote + '/' + (Get-FolderMarkerName -Kind 'private')))
    $found = ConvertTo-RemoteMarkerResult -Result $r
    if ($found.Failed) {
        Write-GuiLog $Ctx.Config ('Reading the ID file of {0} failed (exit {1}): {2}' -f $remote, $r.ExitCode, (@($r.Errors) -join ' '))
        throw (New-GuiException 'remote-failed' "Your encrypted folders in PikPak couldn't be listed. Try again.")
    }
    $id = $null
    if ($found.Found -and -not $found.Marker.ContainsKey('Invalid')) { $id = [string]$found.Marker.Id }
    # A configured encrypted folder always syncs into <PrivateRemote>:<its Name>, so that folder is in use whatever
    # its ID file says; an entry with the ID file's ID also owns it.
    $owner = @(Get-SyncFolders -Config $Ctx.Config | Where-Object { $_.Kind -eq 'private' -and [string]$_.Name -ieq $Name }) | Select-Object -First 1
    if ($null -eq $owner -and $null -ne $id) { $owner = Find-GuiFolderById -Config $Ctx.Config -Id $id }
    @{ Id = $id; Connected = $owner }
}

function Assert-GuiRemotePrivateName {
    param([string]$Name)
    if (-not (Test-EncryptedFolderName $Name)) {
        throw (New-GuiException 'bad-request' ("'{0}' isn't the name of an encrypted folder in PikPak." -f $Name))
    }
}

function Invoke-GuiActionPrivateRemoteList {
    # The encrypted folders in PikPak, and the configured folder each is connected to. Changes nothing.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    Assert-GuiPrivateRemote -Ctx $Ctx
    $folders = New-Object System.Collections.Generic.List[object]
    foreach ($n in @(Get-GuiRemotePrivateNames -Ctx $Ctx)) {
        $info = Get-GuiRemotePrivateInfo -Ctx $Ctx -Name $n
        $bytes = $null
        $sz = Invoke-GuiRclone -RcloneArgs @('size', ([string]$Ctx.Config.PrivateRemote + ':' + $n), '--json')
        if ($sz.ExitCode -eq 0) {
            try { $bytes = [long]((@($sz.Output) -join "`n" | ConvertFrom-Json -ErrorAction Stop).bytes) } catch { $bytes = $null }
        }
        $conn = $null; $paused = $false
        if ($null -ne $info.Connected) { $conn = [string]$info.Connected.Local; $paused = [bool]$info.Connected.Paused }
        $folders.Add(@{ name = $n; bytes = $bytes; id = $info.Id; connectedTo = $conn; paused = $paused })
    }
    @{ folders = $folders.ToArray() }
}

function Invoke-GuiActionPrivatePikpakNames {
    # The scrambled folder each encrypted folder Name has in PikPak (PC-Private/<scrambled>), for the app's
    # tooltip and "Copy PikPak folder name". `rclone cryptdecode --reverse` works it out from the key on this PC
    # without contacting PikPak. Nothing is stored, and the log never pairs a real name with its scrambled one.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $names = @(@(Get-GuiArg $Ctx 'names' @()) | ForEach-Object { [string]$_ } | Where-Object { Test-EncryptedFolderName $_ } | Select-Object -Unique)
    if ($names.Count -eq 0) { return @{ folders = @() } }
    # '--' so that a name starting with '-' is never read as an rclone flag.
    $r = Invoke-GuiRclone -RcloneArgs (@('cryptdecode', '--reverse', ([string]$Ctx.Config.PrivateRemote + ':'), '--') + $names)
    if ($r.ExitCode -ne 0) {
        Write-GuiLog $Ctx.Config ('Working out the PikPak names of the encrypted folders failed (exit {0}).' -f $r.ExitCode)
        throw (New-GuiException 'remote-failed' "The PikPak names of your encrypted folders couldn't be worked out.")
    }
    # rclone prints "<name> \t <scrambled>" per name; a name it did not answer is left out.
    $lines = @($r.Output | ForEach-Object { [string]$_ })
    $folders = New-Object System.Collections.Generic.List[object]
    foreach ($n in $names) {
        $prefix = $n + " `t "
        $line = @($lines | Where-Object { $_.StartsWith($prefix, [StringComparison]::Ordinal) }) | Select-Object -First 1
        if ($null -eq $line) { continue }
        $enc = $line.Substring($prefix.Length).Trim()
        if ($enc -ne '') { $folders.Add(@{ name = $n; pikpak = 'PC-Private/' + $enc }) }
    }
    @{ folders = $folders.ToArray() }
}

function Invoke-GuiActionPrivateDownload {
    # Starts a download of one encrypted folder of PikPak into a new or empty folder, detached (like repair).
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $name = [string](Get-GuiArg $Ctx 'name' '')
    Assert-GuiRemotePrivateName $name
    $target = Get-GuiPathArg $Ctx 'path'
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        throw (New-GuiException 'refused' ('{0} is a file. Choose a folder that is empty or does not exist yet.' -f $target))
    }
    if ((Test-Path -LiteralPath $target -PathType Container) -and @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0) {
        throw (New-GuiException 'refused' ('{0} is not empty. Choose a folder that is empty or does not exist yet.' -f $target))
    }
    $inside = Get-DownloadTargetProblem -Config $Ctx.Config -Target $target
    if ($null -ne $inside) { throw (New-GuiException 'refused' $inside) }
    Assert-GuiPrivateRemote -Ctx $Ctx
    if (@(Get-GuiRemotePrivateNames -Ctx $Ctx | Where-Object { $_ -ceq $name }).Count -eq 0) {
        throw (New-GuiException 'not-found' ("There is no encrypted folder '{0}' in PikPak." -f $name))
    }
    $script = Join-Path $Ctx.RepoRoot 'scripts\Copy-EncryptedFolder.ps1'
    $cfgFull = [IO.Path]::GetFullPath($Ctx.ConfigPath)
    $line = (Get-HeadlessPowerShellArgument -ScriptPath $script -ConfigPath $cfgFull) + ' -Name ' + (ConvertTo-ProcessArgument $name) + ' -Target ' + (ConvertTo-ProcessArgument $target)
    if (Test-GuiPreview $Ctx) { return @{ started = $false; preview = @(("Would download '{0}' to {1}: conhost.exe {2}" -f $name, $target, $line)) } }
    Write-GuiLog $Ctx.Config ("Downloading the encrypted folder '{0}' to {1}" -f $name, $target)
    Start-GuiDetached -FilePath 'conhost.exe' -Arguments $line
    @{ started = $true }
}

function Invoke-GuiActionPrivateDeleteRemote {
    # Deletes exactly private:<name> in PikPak (it goes to PikPak's trash), for a folder no configured folder uses.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $name = [string](Get-GuiArg $Ctx 'name' '')
    Assert-GuiRemotePrivateName $name
    Assert-GuiPrivateRemote -Ctx $Ctx
    Assert-GuiNotSyncing $Ctx
    if (@(Get-GuiRemotePrivateNames -Ctx $Ctx | Where-Object { $_ -ceq $name }).Count -eq 0) {
        throw (New-GuiException 'not-found' ("There is no encrypted folder '{0}' in PikPak." -f $name))
    }
    $info = Get-GuiRemotePrivateInfo -Ctx $Ctx -Name $name
    if ($null -ne $info.Connected) {
        throw (New-GuiException 'refused' ("'{0}' is connected to {1}. Stop syncing it first." -f $name, $info.Connected.Local))
    }
    $target = [string]$Ctx.Config.PrivateRemote + ':' + $name
    if (Test-GuiPreview $Ctx) {
        return @{ deleted = $false; preview = @(("Would delete '{0}' in PikPak ({1}). It goes to PikPak's trash." -f $name, $target)) }
    }
    $log = New-RunLogFile -Context @{ StateDir = $Ctx.Config.StateDir; Now = $Ctx.Now; LogCounter = 0 } -Label ('delete-private-' + $name)
    $purge = [string[]](New-PurgeArgs -Target $target -LogFile $log)
    Write-GuiLog $Ctx.Config ('Deleting {0} in PikPak (rclone purge, log {1})' -f $target, $log)
    $p = Invoke-Rclone -Arguments $purge
    Write-GuiLog $Ctx.Config ('Delete of {0} ended with exit {1}' -f $target, $p.ExitCode)
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3) {
        throw (New-GuiException 'remote-failed' ("'{0}' couldn't be deleted in PikPak. Try again." -f $name))
    }
    @{ deleted = $true }
}

function Get-GuiSchedule {
    param([Parameter(Mandatory)][hashtable]$Ctx, [hashtable]$Config)
    if ($null -eq $Config) { $Config = $Ctx.Config }
    $t = Get-GuiTaskInfo -TaskName 'PikPakMirror-Sync'
    $time = '20:00'; $logon = $true
    if ($Config.ContainsKey('SyncTime') -and -not [string]::IsNullOrWhiteSpace([string]$Config['SyncTime'])) { $time = [string]$Config['SyncTime'] }
    if ($Config.ContainsKey('SyncAtLogon') -and $null -ne $Config['SyncAtLogon']) { $logon = [bool]$Config['SyncAtLogon'] }
    @{ paused = -not ([bool]$t.Exists -and [bool]$t.Enabled); syncTime = $time; syncAtLogon = $logon; intervalMinutes = (Get-SyncIntervalMinutes -Config $Config); nextRun = $t.NextRun }
}

function Invoke-GuiActionScheduleGet {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    Get-GuiSchedule -Ctx $Ctx
}

function Invoke-GuiActionScheduleSet {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $preview = @()
    $isPreview = Test-GuiPreview $Ctx
    $raw = Get-RawMirrorConfig -Path $Ctx.ConfigPath
    $changed = $false
    $time = Get-GuiArg $Ctx 'syncTime'
    if ($null -ne $time -and [string]$time -ne [string]$raw['SyncTime']) { $raw['SyncTime'] = [string]$time; $changed = $true }
    $logon = Get-GuiArg $Ctx 'syncAtLogon'
    if ($null -ne $logon) {
        if ($logon -isnot [bool]) { throw (New-GuiException 'bad-request' 'syncAtLogon must be true or false.') }
        if (-not $raw.ContainsKey('SyncAtLogon') -or $raw['SyncAtLogon'] -ne $logon) { $raw['SyncAtLogon'] = $logon; $changed = $true }
    }
    $interval = Get-GuiArg $Ctx 'intervalMinutes'
    if ($null -ne $interval) {
        if (-not (Test-SyncIntervalMinutes $interval)) { throw (New-GuiException 'bad-request' 'intervalMinutes must be 0, 15, 30, 60, 180 or 360.') }
        if ((Get-SyncIntervalMinutes -Config $raw) -ne [int]$interval -or -not $raw.ContainsKey('SyncIntervalMinutes')) { $raw['SyncIntervalMinutes'] = [int]$interval; $changed = $true }
    }
    $effective = $Ctx.Config
    if ($changed) {
        Save-GuiConfig -Ctx $Ctx -Config $raw
        if ($isPreview) { $effective = (Test-GuiConfigCandidate -Config $raw -NextTo $Ctx.ConfigPath).Config }
        else { $effective = Get-MirrorConfig -Path $Ctx.ConfigPath }
        $cfgFull = [IO.Path]::GetFullPath($Ctx.ConfigPath)
        $step = Register-MirrorTasks -Config $effective -ConfigPath $cfgFull -RepoRoot $Ctx.RepoRoot -Kind Sync -WhatIf:$isPreview
        if ($isPreview) { $preview += ('Would save the sync schedule ({0}) to {1}' -f $(if ((Get-SyncIntervalMinutes -Config $effective) -eq 0) { 'once a day' } else { 'every ' + (Get-SyncIntervalMinutes -Config $effective) + ' minutes' }), $Ctx.ConfigPath); $preview += [string]$step.Message }
    }
    $paused = Get-GuiArg $Ctx 'paused'
    if ($null -ne $paused) {
        $null = Get-GuiExistingTask 'PikPakMirror-Sync'
        if ($isPreview) {
            if ([bool]$paused) { $preview += 'Would pause syncing (disable PikPakMirror-Sync).' } else { $preview += 'Would turn syncing back on (enable PikPakMirror-Sync).' }
        }
        else { Set-GuiTaskEnabled -TaskName 'PikPakMirror-Sync' -Enabled (-not [bool]$paused) }
    }
    $res = Get-GuiSchedule -Ctx $Ctx -Config $effective
    if ($isPreview) { $res['preview'] = $preview }
    $res
}

# ===== Actions: deleted files ==============================================================

function Invoke-GuiActionHoldingList {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $cfg = $Ctx.Config
    $entries = New-Object System.Collections.Generic.List[object]
    $lh = [string]$cfg.LocalHolding
    if ($lh -and (Test-Path -LiteralPath $lh -PathType Container)) {
        $base = $lh.TrimEnd('\').Length + 1
        foreach ($f in @(Get-ChildItem -LiteralPath $lh -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $entries.Add(@{ Path = $f.FullName.Substring($base).Replace('\', '/'); IsDir = $false; Size = [long]$f.Length })
        }
    }
    $items = @(ConvertTo-HoldingItems -Config $cfg -Source pc -Entries $entries.ToArray())

    $cloud = @()
    if (-not (Test-RcloneInstalled)) {
        $Ctx.Warning = "rclone isn't installed, so deleted files in PikPak can't be listed."
    }
    else {
        $root = ([string]$cfg.Remote) + ':' + ([string]$cfg.HoldingRoot)
        $r = Invoke-GuiRclone -RcloneArgs @('lsjson', '-R', '--files-only', $root)
        if ($r.ExitCode -eq 0) {
            $json = (@($r.Output) -join "`n")
            if (-not [string]::IsNullOrWhiteSpace($json)) { $cloud = @(ConvertTo-HoldingItems -Config $cfg -Source cloud -Entries @($json | ConvertFrom-Json)) }
        }
        elseif ($r.ExitCode -ne 3) {
            Write-GuiLog $cfg ('Listing {0} failed (exit {1}): {2}' -f $root, $r.ExitCode, (@($r.Errors) -join ' '))
            $Ctx.Warning = "Couldn't list the deleted files in PikPak; only the ones on this PC are shown."
        }
    }
    # Encrypted folders: files the PC side deleted are in private:_holding (readable through the remote).
    $priv = @()
    if ($cfg.ContainsKey('PrivatePaths') -and @($cfg.PrivatePaths | Where-Object { $_ }).Count -gt 0 -and (Test-RcloneInstalled)) {
        $proot = ([string]$cfg.PrivateRemote) + ':_holding'
        $r = Invoke-GuiRclone -RcloneArgs @('lsjson', '-R', '--files-only', $proot)
        if ($r.ExitCode -eq 0) {
            $json = (@($r.Output) -join "`n")
            if (-not [string]::IsNullOrWhiteSpace($json)) { $priv = @(ConvertTo-HoldingItems -Config $cfg -Source private -Entries @($json | ConvertFrom-Json)) }
        }
        elseif ($r.ExitCode -ne 3) {
            Write-GuiLog $cfg ('Listing {0} failed (exit {1}): {2}' -f $proot, $r.ExitCode, (@($r.Errors) -join ' '))
            $msg = "Couldn't list the deleted files of your encrypted folders in PikPak; the ones on this PC are still shown."
            if ($Ctx.ContainsKey('Warning') -and -not [string]::IsNullOrEmpty([string]$Ctx.Warning)) { $msg = ([string]$Ctx.Warning) + ' ' + $msg }
            $Ctx.Warning = $msg
        }
    }
    $all = @($items) + @($cloud) + @($priv)
    , @($all | Sort-Object -Property @{ Expression = { $_.Date }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $false })
}

function Copy-GuiCreateNew {
    # Copies to a free name, never overwriting: create-new semantics, one retry with the next free name.
    param([Parameter(Mandatory)][scriptblock]$Copy, [Parameter(Mandatory)][string]$RestoreTo)
    $exists = { param($x) Test-Path -LiteralPath $x }
    $dst = Get-RestoreTarget -Path $RestoreTo -Exists $exists
    $parent = Split-Path -Path $dst -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    try { & $Copy $dst }
    catch {
        # Most likely the name was taken in the meantime: once more with the next free name.
        $dst = Get-RestoreTarget -Path $RestoreTo -Exists $exists
        & $Copy $dst
    }
    $dst
}

function Invoke-GuiActionHoldingRestore {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $cfg = $Ctx.Config
    $item = Get-GuiArg $Ctx 'item'
    if ($item -isnot [hashtable]) { throw (New-GuiException 'bad-request' 'No file was given to restore.') }
    $source = [string]$item['Source']
    if ($source -ne 'pc' -and $source -ne 'cloud' -and $source -ne 'private') { throw (New-GuiException 'bad-request' "That file can't be restored.") }
    # A missing Private counts as false; source private always means an encrypted folder.
    $isPriv = ($source -eq 'private')
    if ($item.ContainsKey('Private') -and $null -ne $item['Private'] -and [bool]$item['Private']) { $isPriv = $true }
    if ($isPriv -and $source -eq 'cloud') { throw (New-GuiException 'bad-request' "That file can't be restored.") }
    # Re-derive every path from the config; the item only names date, folder and relative path.
    $rel = ([string]$item['RelPath']).Replace('\', '/')
    if ($source -eq 'pc' -and $isPriv) { $entryPath = '{0}/_private/{1}/{2}' -f $item['Date'], $item['Pair'], $rel }
    else { $entryPath = '{0}/{1}/{2}' -f $item['Date'], $item['Pair'], $rel }
    $entry = @{ Path = $entryPath; IsDir = $false; Size = $item['Size'] }
    $it = @(ConvertTo-HoldingItems -Config $cfg -Source $source -Entries @($entry)) | Select-Object -First 1
    # The canonical item must agree with what the caller claimed (a pair can never pass as an encrypted folder or back).
    if ($null -eq $it -or [bool]$it.Private -ne $isPriv) { throw (New-GuiException 'bad-request' "That file can't be restored.") }

    if ($source -eq 'pc') {
        if (-not (Test-Path -LiteralPath $it.HoldingPath -PathType Leaf)) { throw (New-GuiException 'not-found' ("{0} is no longer in the deleted files." -f $it.Name)) }
        if (Test-GuiPreview $Ctx) {
            return @{ restoredTo = $null; preview = @(('Would copy {0} back to {1}.' -f $it.HoldingPath, (Get-RestoreTarget -Path $it.RestoreTo -Exists { param($x) Test-Path -LiteralPath $x }))) }
        }
        $src = $it.HoldingPath
        $dst = Copy-GuiCreateNew -RestoreTo $it.RestoreTo -Copy { param($d) [IO.File]::Copy($src, $d, $false) }
        return @{ restoredTo = $dst }
    }

    if ($source -eq 'private') { $remote = ([string]$cfg.PrivateRemote) + ':' + $it.HoldingPath }
    else { $remote = ([string]$cfg.Remote) + ':' + $it.HoldingPath }
    if (Test-GuiPreview $Ctx) {
        return @{ restoredTo = $null; preview = @(('Would download {0} to {1}.' -f $remote, (Get-RestoreTarget -Path $it.RestoreTo -Exists { param($x) Test-Path -LiteralPath $x }))) }
    }
    if (-not (Test-RcloneInstalled)) { throw (New-GuiException 'rclone-missing' (Get-GuiAccountErrorMessage 'rclone-missing')) }
    # Download next to the target under a temporary name, then move it into place without overwriting.
    $tmp = Join-Path (Split-Path -Path $it.RestoreTo -Parent) ('.pikpak-restore-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $r = Invoke-GuiRclone -RcloneArgs @('copyto', $remote, $tmp)
    if ($r.ExitCode -ne 0) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        Write-GuiLog $cfg ('Restore of {0} failed (exit {1}): {2}' -f $remote, $r.ExitCode, (@($r.Errors) -join ' '))
        throw (New-GuiException 'network' ("Couldn't download {0} from PikPak. Check your internet connection and try again." -f $it.Name))
    }
    try { $dst = Copy-GuiCreateNew -RestoreTo $it.RestoreTo -Copy { param($d) [IO.File]::Move($tmp, $d) } }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    @{ restoredTo = $dst }
}

# ===== Actions: recovery key ========================================================================

function Invoke-GuiActionKeyShow {
    # Reveals the private remote's key from the rclone config. The result goes to the app only.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    if (-not (Test-RcloneInstalled)) { throw (New-GuiException 'rclone-missing' (Get-GuiAccountErrorMessage 'rclone-missing')) }
    $entry = Get-GuiRemoteEntry (Get-GuiRcloneConfigDump) ([string]$Ctx.Config.PrivateRemote)
    if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['password'] -or [string]::IsNullOrEmpty([string]$entry.password)) {
        throw (New-GuiException 'not-found' 'There is no recovery key on this PC: encrypted folders are not set up.')
    }
    $reveal = {
        param([string]$Obscured)
        $r = Invoke-GuiRclone -RcloneArgs @('reveal', $Obscured)
        if ($r.ExitCode -ne 0) { throw (New-GuiException 'internal' "The recovery key couldn't be read from the rclone settings.") }
        (@($r.Output) -join '').Trim()
    }
    $pw = & $reveal ([string]$entry.password)
    $salt = ''
    if ($null -ne $entry.PSObject.Properties['password2'] -and -not [string]::IsNullOrEmpty([string]$entry.password2)) { $salt = & $reveal ([string]$entry.password2) }
    if ([string]::IsNullOrEmpty($salt)) { return @{ kind = 'single'; key = ($pw -replace '(.{5})(?=.)', '$1 ') } }
    @{ kind = 'pair'; password = $pw; salt = $salt }
}

# ===== Actions: first-time setup ====================================================================

function Invoke-GuiActionSetupNewkey {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    @{ key = (New-RecoveryKey) }
}

function Invoke-GuiActionSetupSignin {
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $email = ([string](Get-GuiArg $Ctx 'email' '')).Trim()
    $pw = [string](Get-GuiArg $Ctx 'password' '')
    $Ctx.Args['password'] = $null
    if ([string]::IsNullOrEmpty($email) -or [string]::IsNullOrEmpty($pw)) { throw (New-GuiException 'bad-request' 'Type your PikPak email and password.') }
    $remote = 'pikpak'
    if (Test-GuiPreview $Ctx) {
        $lines = @()
        if (-not (Test-RcloneInstalled)) { $lines += [string](Install-MirrorRclone -WhatIf).Message }
        $lines += ("Would create the rclone remote '{0}' for {1} and check it with rclone about." -f $remote, $email)
        $pw = $null
        return @{ email = $email; totalBytes = [long]6GB; usedBytes = [long]0; preset = 'free'; preview = $lines }
    }
    try {
        if (-not (Test-RcloneInstalled)) {
            try { $null = Install-MirrorRclone }
            catch { throw (New-GuiException 'rclone-missing' ("rclone couldn't be installed: {0}" -f $_.Exception.Message)) }
        }
        # An unreadable list must never look like "no remote": that would create the remote again.
        if (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name $remote) {
            # Signing in again (signed out, or an earlier setup got this far): store the new password in the
            # real remote behind the name. Same account only: switching accounts is not supported.
            $target = Resolve-GuiRemoteTarget -Dump (Get-GuiRcloneConfigDump) -Remote $remote
            if ($null -eq $target) { throw (New-GuiException 'refused' ("The rclone remote '{0}' couldn't be read. Check it with: rclone config" -f $remote)) }
            if (-not [string]::IsNullOrEmpty($target.User) -and $target.User -ine $email) {
                throw (New-GuiException 'refused' ("This PC is already signed in to PikPak as {0}. Use that account, or remove the rclone remote '{1}' first." -f $target.User, $remote))
            }
            if (-not (Test-NativeArgumentSafe -Value $pw)) { throw (New-GuiException 'bad-request' (Get-UnsafePasswordMessage)) }
            $upArgs = @('config', 'update', $target.Name, 'user', $email, 'pass', $pw, '--obscure', '--non-interactive')
            try { $u = Invoke-RcloneCaptured -RcloneArgs $upArgs }
            finally { $upArgs = $null }
            if ($u.ExitCode -ne 0) {
                # The output may echo the settings; only the exit code is logged.
                Write-GuiLog $Ctx.Config ("rclone config update of remote '{0}' failed (exit {1})" -f $target.Name, $u.ExitCode)
                throw (New-GuiException 'internal' "PikPak Sync couldn't save the new password in rclone's settings. Try again.")
            }
        }
        else {
            try { $null = New-MirrorPikPakRemote -Name $remote -Email $email -Password $pw }
            catch {
                $m = [string]$_.Exception.Message
                if ($m -match "didn't accept") { throw (New-GuiException 'auth' "PikPak didn't accept that email and password.") }
                if ($m -match "Couldn't reach") { throw (New-GuiException 'network' "Couldn't reach PikPak. Check your internet connection and try again.") }
                throw (New-GuiException 'bad-request' $m)
            }
        }
    }
    finally { $pw = $null }
    $acct = Get-GuiAccountBytes -Remote $remote
    if ($acct.Error -eq 'auth') { throw (New-GuiException 'auth' "PikPak didn't accept that email and password.") }
    if ($acct.Error) { throw (New-GuiException ([string]$acct.Error) (Get-GuiAccountErrorMessage ([string]$acct.Error))) }
    Clear-GuiAboutCache $Ctx
    $total = [long]0; if ($null -ne $acct.TotalBytes) { $total = [long]$acct.TotalBytes }
    $used = [long]0; if ($null -ne $acct.UsedBytes) { $used = [long]$acct.UsedBytes }
    @{ email = $email; totalBytes = $total; usedBytes = $used; preset = (Get-BudgetPreset -TotalBytes $total).Name }
}

function New-GuiSetupConfig {
    # A new raw config from the shipped defaults, the chosen folders and the budget preset.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Folders,
        [Parameter(Mandatory)][hashtable]$Preset,
        [Parameter(Mandatory)][string]$DriveRoot,
        [string]$Holding
    )
    if ([string]::IsNullOrWhiteSpace($Holding)) { $Holding = Join-Path $DriveRoot '.pikpak-holding' }
    $cfg = @{
        Remote = 'pikpak'; PrivateRemote = 'private'; MirrorRoot = 'PC-Mirror'; HoldingRoot = 'PC-Holding'
        LocalHolding = $Holding; StateDir = '%LOCALAPPDATA%\PikPakMirror'; GlobalFiltersFile = 'filters.txt'
        HoldingDays = 30; MaxDeletePercent = 10; DailyBudgetGB = [int]$Preset.DailyBudgetGB; MonthlyBudgetGB = [int]$Preset.MonthlyBudgetGB
        QuotaWarnPercent = 90; StaleRunDays = 3; LogKeepDays = 60; BwLimit = '18:00,2M:off 23:00,off'
        SyncTime = '20:00'; SyncIntervalMinutes = 60; SyncAtLogon = $true
        PrivatePaths = @(); Pairs = @()
    }
    $privTaken = @{ '_holding' = $true }
    foreach ($f in $Folders) {
        if ($f.Private) {
            $leaf = Split-Path -Path $f.Path -Leaf
            if ([string]::IsNullOrEmpty($leaf) -or $leaf -match '[\\/:*?"<>|]') { $leaf = $f.Path.Substring(0, 1).ToUpperInvariant() }
            $name = $leaf; $n = 2
            while ($privTaken.ContainsKey($name.ToLowerInvariant())) { $name = '{0} ({1})' -f $leaf, $n; $n++ }
            $privTaken[$name.ToLowerInvariant()] = $true
            $cfg['PrivatePaths'] = @($cfg['PrivatePaths']) + @(@{ Path = $f.Path; Name = $name })
        }
        else {
            $cfg['Pairs'] = @($cfg['Pairs']) + @(New-MirrorPair -Path $f.Path -Config $cfg)
        }
    }
    $cfg
}

function Invoke-GuiActionSetupFinish {
    # Runs the install from the setup screens. Every step that can fail on PikPak's side (rclone there,
    # account reachable, PC-Private empty, crypt remote created) runs BEFORE the config is written, so a
    # failure there leaves the PC as it was. A failing step stops the rest; the steps so far are reported.
    # When the config already exists, a real run is refused unless args.resume = true: then the config
    # write is skipped and the remaining idempotent steps (tasks, local folders, private
    # confirmation) run again with the existing config. Under preview every step runs with -WhatIf
    # and nothing is written or registered. args.restore (instead of folders) restores the folders and
    # settings of an earlier install (GuiBackup.ps1): no new key, the backup's filter rules, the missing folders
    # created where their drive exists (step 'Restored folders', also run on a resume), one backup push. The result
    # then has restored = @{ count; saved; driveMissing; pausedForKey; problems } for the screen to report.
    param([Parameter(Mandatory)][hashtable]$Ctx)
    $isPreview = Test-GuiPreview $Ctx
    $resume = $false
    if (-not $isPreview -and (Test-Path -LiteralPath $Ctx.ConfigPath)) {
        if ((Get-GuiArg $Ctx 'resume' $false) -ne $true) {
            throw (New-GuiException 'refused' 'PikPak Sync is already set up on this PC. If the setup stopped part-way, try again to finish the remaining steps.')
        }
        $resume = $true
    }
    $key = $null
    $cfgFull = [IO.Path]::GetFullPath($Ctx.ConfigPath)
    $steps = New-Object System.Collections.Generic.List[object]
    $preview = New-Object System.Collections.Generic.List[string]
    $state = @{ Config = $null; Failed = $false; Preset = $null; Raw = $null; Restored = $null }
    $savedText = ''
    $run = {
        param([string]$Name, [scriptblock]$Body)
        if ($state.Failed) { return }
        try {
            $res = & $Body
            $msg = ''; $done = -not $isPreview
            if ($res -is [string]) { $msg = $res }
            elseif ($null -ne $res) { $msg = [string]$res.Message; if (-not $isPreview) { $done = ([bool]$res.Done -or [bool]$res.Skipped) } }
            $steps.Add(@{ name = $Name; done = $done; message = $msg })
            if ($isPreview) { $preview.Add($msg) }
        }
        catch {
            $state.Failed = $true
            $steps.Add(@{ name = $Name; done = $false; message = (Remove-GuiSecretText (Get-GuiErrorMessage $_.Exception) @($key)) })
            Write-GuiLog $state.Config (Remove-GuiSecretText ('Setup step {0} failed: {1}' -f $Name, $_.Exception.Message) @($key))
        }
    }
    # Creates the folders of the config that are missing, on drives that exist (a restore onto a new PC or a wiped
    # disk). Idempotent, so it also runs on a resume. The summary for the result is left in $state.Restored.
    $restoredStep = {
        & $run 'Restored folders' {
            $made = New-GuiRestoredFolders -Config $state.Config -WhatIf:$isPreview
            $state.Restored = New-GuiRestoredSummary -Config $state.Config -Result $made -Saved $savedText
            $made
        }
    }
    # The idempotent part of the install: safe to run again on a resume.
    $installSteps = {
        & $run 'Scheduled syncing' { Register-MirrorTasks -Config $state.Config -ConfigPath $cfgFull -RepoRoot $Ctx.RepoRoot -EnableSchedule -WhatIf:$isPreview }
        & $run 'Local folders' { New-MirrorLocalFolders -Config $state.Config -WhatIf:$isPreview }
        & $run 'Encrypted folders confirmed' {
            if ($isPreview) { return 'Would record that you confirmed the encrypted folders.' }
            if (-not (Save-PrivateConfirmation -Config $state.Config)) { throw 'a sync is running; confirm the encrypted folders in Settings later.' }
            'Encrypted folders confirmed'
        }
    }

    if ($resume) {
        $Ctx.Args['recoveryKey'] = $null
        try { $state.Config = Get-MirrorConfig -Path $cfgFull }
        catch { throw (New-GuiException 'config-invalid' ("Your settings file couldn't be read: {0}" -f $_.Exception.Message)) }
        & $restoredStep
        & $installSteps
        $out = @{ steps = $steps.ToArray(); complete = (-not $state.Failed) }
        if ($null -ne $state.Restored) { $out['restored'] = $state.Restored }
        return $out
    }

    $restore = Get-GuiRestoreArg -Ctx $Ctx
    if ($null -ne $restore) { $savedText = [string]$restore.saved }
    $folders = @()
    foreach ($f in @(Get-GuiArg $Ctx 'folders' @())) {
        if ($f -isnot [hashtable]) { throw (New-GuiException 'bad-request' 'The folder list is not valid.') }
        $p = Get-GuiPathArg -Ctx @{ Args = $f } -Name 'path'
        $folders += [pscustomobject]@{ Path = $p; Private = [bool]$f['private'] }
    }
    if ($folders.Count -eq 0 -and $null -eq $restore) { throw (New-GuiException 'bad-request' 'Choose at least one folder to sync.') }
    $anyPrivate = (@($folders | Where-Object { $_.Private }).Count -gt 0)
    if ($anyPrivate) {
        $key = ConvertTo-RecoveryKey -Text ([string](Get-GuiArg $Ctx 'recoveryKey' ''))
        if ($null -eq $key) { throw (New-GuiException 'bad-request' 'Encrypted folders need the recovery key from the previous screen.') }
    }
    $Ctx.Args['recoveryKey'] = $null

    try {
        $presetName = [string](Get-GuiArg $Ctx 'preset' '')
        # 1. PikPak reachable (and the budget preset from the account size).
        & $run 'PikPak account' {
            if ($presetName -eq 'premium') { $state.Preset = Get-BudgetPreset -TotalBytes ([long]11GB) }
            elseif ($presetName -eq 'free' -or $isPreview) { $state.Preset = Get-BudgetPreset -TotalBytes ([long]6GB) }
            if ($isPreview) { return 'Would check the PikPak account with rclone about.' }
            if (-not (Test-RcloneInstalled)) { throw (Get-GuiAccountErrorMessage 'rclone-missing') }
            $acct = Get-GuiAccountBytes -Remote 'pikpak'
            if ($acct.Error) {
                Write-GuiLog $Ctx.Config ('Setup account check failed: ' + $acct.Detail)
                throw (Get-GuiAccountErrorMessage ([string]$acct.Error))
            }
            if ($null -eq $state.Preset) {
                $total = [long]6GB
                if ($null -ne $acct.TotalBytes) { $total = [long]$acct.TotalBytes }
                $state.Preset = Get-BudgetPreset -TotalBytes $total
            }
            ('PikPak account checked ({0} plan budgets)' -f $state.Preset.Name)
        }
        # 2. The new settings validate (nothing written yet).
        & $run 'Settings check' {
            if ($null -ne $restore) {
                $raw = New-GuiRestoreSetupConfig -Restore $restore -Preset $state.Preset -DriveRoot (Get-GuiBestDrive) `
                    -Holding ([string](Get-GuiArg $Ctx 'holding' ''))
            }
            else {
                $raw = New-GuiSetupConfig -Folders $folders -Preset $state.Preset -DriveRoot (Get-GuiBestDrive) `
                    -Holding ([string](Get-GuiArg $Ctx 'holding' ''))
            }
            $check = Test-GuiConfigCandidate -Config $raw -NextTo $cfgFull
            if (@($check.Errors).Count -gt 0) { throw (@($check.Errors) -join ' ') }
            $state.Raw = $raw
            $state.Config = $check.Config
            $names = @(@($raw.Pairs) | ForEach-Object { $_.Name }) + @(@($raw.PrivatePaths) | ForEach-Object { $_.Name + ' (encrypted)' })
            ('Settings checked; syncing: {0}' -f ($names -join ', '))
        }
        # 3. The private key: never replaces an existing one; New-MirrorPrivateRemote refuses when
        #    PC-Private already holds data.
        if ($anyPrivate) {
            & $run 'Recovery key' {
                if (-not $isPreview) {
                    if (Test-RemoteListed -Listing (Get-GuiRemoteList) -Name 'private') {
                        throw "This PC already has a recovery key (rclone remote 'private'); it was not replaced and nothing was saved."
                    }
                }
                New-MirrorPrivateRemote -Name 'private' -BaseRemote 'pikpak' -Password $key -Mode New -WhatIf:$isPreview
            }
        }
        if ($null -ne $restore -and @($restore.privatePaths).Count -gt 0) {
            & $run 'Recovery key' { Confirm-GuiRestoreKey -WhatIf:$isPreview }
        }
        # 4. The backup's filter rules: a local file only, written BEFORE the config so a failure here leaves
        #    no config (a Retry would take the resume path, skip this step and let the next sync upload a
        #    backup without the owner's rules). $state.Config already names GlobalFiltersFile from the check.
        if ($null -ne $restore) { & $run 'Filters' { Save-GuiRestoreFilters -Config $state.Config -Text $restore.globalFilters -WhatIf:$isPreview } }
        # 5. Only now the config file.
        & $run 'Settings' {
            if ($isPreview) { return ('Would write {0}' -f $cfgFull) }
            $dir = Split-Path -Path $cfgFull -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $errs = @(Save-MirrorConfig -Path $cfgFull -Config $state.Raw)
            if ($errs.Count -gt 0) { throw ($errs -join ' ') }
            $state.Config = Get-MirrorConfig -Path $cfgFull
            ('Settings saved to {0}' -f $cfgFull)
        }
        # 6. The folders of the restored list that are missing are created (only where their drive exists).
        if ($null -ne $restore) { & $restoredStep }
        & $installSteps
        if ($null -ne $restore) {
            & $run 'Folder list backup' { Invoke-GuiRestoreBackupPush -ConfigPath $cfgFull -Config $state.Config -Now $Ctx.Now -WhatIf:$isPreview }
        }
    }
    finally { $key = $null }
    $res = @{ steps = $steps.ToArray(); complete = (-not $state.Failed) -and (-not $isPreview) }
    if ($null -ne $state.Restored) { $res['restored'] = $state.Restored }
    if ($isPreview) { $res['preview'] = $preview.ToArray() }
    $res
}
