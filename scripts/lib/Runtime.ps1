# Runtime helpers: rclone wrapper, log parsing, logging, toast notifications, single-instance lock.

function Get-TransferredBytesFromLog {
    # Bytes transferred in one rclone run: max(last "stats".bytes, sum of "size" over Copied lines).
    # An interrupted run has no (or only a partial) stats line, but its Copied lines are still in the log.
    # Server-side copies move no data through this PC and are not counted. 0 if nothing / file missing.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    $statsBytes = [long]0
    $copiedBytes = [long]0
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $hasStats = $line.IndexOf('"stats"', [StringComparison]::Ordinal) -ge 0
        $hasCopied = $line.IndexOf('"Copied (', [StringComparison]::Ordinal) -ge 0
        if (-not $hasStats -and -not $hasCopied) { continue }
        try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if ($null -eq $obj) { continue }
        if ($hasStats -and $null -ne $obj.PSObject.Properties['stats']) {
            $stats = $obj.stats
            if ($null -ne $stats -and $null -ne $stats.PSObject.Properties['bytes']) { $statsBytes = [long]$stats.bytes }
        }
        if ($hasCopied -and $null -ne $obj.PSObject.Properties['msg'] -and $null -ne $obj.PSObject.Properties['size']) {
            $msg = [string]$obj.msg
            if (($msg.StartsWith('Copied (new)', [StringComparison]::Ordinal) -or
                 $msg.StartsWith('Copied (replaced existing)', [StringComparison]::Ordinal)) -and
                $msg.IndexOf('server-side', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                $copiedBytes += [long]$obj.size
            }
        }
    }
    return [long][Math]::Max($statsBytes, $copiedBytes)
}

function Invoke-Rclone {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $logFile = $null
    $i = [array]::IndexOf($Arguments, '--log-file')
    if ($i -ge 0 -and ($i + 1) -lt $Arguments.Count) { $logFile = $Arguments[$i + 1] }
    if ($logFile) {
        $logDir = [IO.Path]::GetDirectoryName($logFile)
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
    }

    $global:LASTEXITCODE = 0
    $exit = 0
    try {
        & rclone @Arguments | Out-Null
        $exit = [int]$global:LASTEXITCODE
    } catch [System.Management.Automation.CommandNotFoundException] {
        $exit = 127
    }

    $bytes = [long]0
    $needsResync = $false
    $emptyListing = $null
    $budgetHit = $false
    $tooManyDeletes = $false
    $stuck =New-Object System.Collections.Generic.List[string]
    if ($logFile) {
        $bytes = Get-TransferredBytesFromLog -Path $logFile
        if (Test-Path -LiteralPath $logFile) {
            $text = [IO.File]::ReadAllText($logFile)
            $needsResync = $text.IndexOf('must run --resync', [StringComparison]::OrdinalIgnoreCase) -ge 0
            # bisync refuses to run against an empty listing (Path1 = PC, Path2 = PikPak).
            if ($text.IndexOf('empty current Path1 listing', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $emptyListing = 'Path1' }
            elseif ($text.IndexOf('empty current Path2 listing', [StringComparison]::OrdinalIgnoreCase) -ge 0) { $emptyListing = 'Path2' }
            # --max-transfer reached; inside bisync this aborts the run with exit 7 instead of rclone's usual 8.
            $budgetHit = $text.IndexOf('max transfer limit reached', [StringComparison]::OrdinalIgnoreCase) -ge 0
            # bisync --max-delete safety abort ("Safety abort: too many deletes (>10%, 4 of 10) on Path1 ...").
            $tooManyDeletes = $text.IndexOf('too many deletes', [StringComparison]::OrdinalIgnoreCase) -ge 0
            # PikPak keeps a hidden unfinished upload after a hard kill and then rejects that name:
            # uploaded file name mismatch: expected "a.bin", got "a(1).bin"  (quotes are \" inside the JSON log).
            foreach ($m in [regex]::Matches($text, 'uploaded file name mismatch: expected \\?"([^"\\]+)\\?"')) {
                $n = $m.Groups[1].Value
                if (-not $stuck.Contains($n)) { $stuck.Add($n) }
            }
        }
    }
    [pscustomobject]@{
        ExitCode     = $exit
        Bytes        = [long]$bytes
        LogFile      = $logFile
        NeedsResync  = [bool]$needsResync
        EmptyListing = $emptyListing
        BudgetHit    = [bool]$budgetHit
        StuckUploads = [string[]]$stuck.ToArray()
        TooManyDeletes = [bool]$tooManyDeletes
    }
}

function Write-MirrorLog {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Message
    )
    $dir = [IO.Path]::Combine($Config.StateDir, 'logs')
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $now = Get-Date
    $file = [IO.Path]::Combine($dir, ($now.ToString('yyyy-MM-dd') + '.log'))
    $line = '{0} {1}{2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($file, $line, (New-Object Text.UTF8Encoding $false))
}

function Show-MirrorToastNative {
    # Private helper: the WinRT call, kept separate so tests can mock it.
    param([string]$Title, [string]$Message)
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $t = [Security.SecurityElement]::Escape($Title)
    $m = [Security.SecurityElement]::Escape($Message)
    $xml.LoadXml("<toast><visual><binding template=`"ToastText02`"><text id=`"1`">$t</text><text id=`"2`">$m</text></binding></visual></toast>")
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}

function Send-MirrorToast {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        $Config
    )
    # Every notification is also kept in the daily log; logging problems never block the toast.
    if ($null -ne $Config) {
        try { Write-MirrorLog -Config $Config -Message ('Notify: ' + $Message) } catch { }
    }
    try {
        Show-MirrorToastNative -Title $Title -Message $Message
    } catch {
        $text = 'toast failed: {0}' -f $_.Exception.Message
        try {
            if ($null -ne $Config) { Write-MirrorLog -Config $Config -Message $text }
            else { Write-Warning $text }
        } catch { }
    }
}

function Send-CrashToastOnce {
    # The toast for a run that crashed before state existed (a config that does not load, an unreadable
    # state.json): at most once per day per distinct message, remembered in a small marker file (name = hash of
    # the message, content = the day) under -MarkerDir, which defaults to the state folder of -Config when it
    # loaded, else %LOCALAPPDATA%\PikPakMirror. A marker that cannot be read or written never hides the toast
    # and never throws.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        $Config,
        [string]$MarkerDir,
        [datetime]$Now = (Get-Date),
        [string]$Title = 'PikPak Sync'
    )
    $today = $Now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $marker = $null
    try {
        if ([string]::IsNullOrEmpty($MarkerDir)) {
            if ($null -ne $Config -and $null -ne $Config['StateDir'] -and -not [string]::IsNullOrWhiteSpace([string]$Config['StateDir'])) { $MarkerDir = [string]$Config['StateDir'] }
            else { $MarkerDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'PikPakMirror' }
        }
        $marker = Join-Path $MarkerDir ('crash-toast-{0}.txt' -f (Get-TextHash -Lines @($Message)).Substring(0, 16))
        if ((Test-Path -LiteralPath $marker -PathType Leaf) -and ([IO.File]::ReadAllText($marker).Trim() -eq $today)) {
            try { if ($null -ne $Config) { Write-MirrorLog -Config $Config -Message ('Notify (already shown today): ' + $Message) } } catch { }
            return $false
        }
    }
    catch { $marker = $null }
    try { Send-MirrorToast -Title $Title -Message $Message -Config $Config } catch { }
    try {
        if ($null -ne $marker) {
            if (-not (Test-Path -LiteralPath $MarkerDir)) { New-Item -ItemType Directory -Path $MarkerDir -Force | Out-Null }
            [IO.File]::WriteAllText($marker, $today, (New-Object Text.UTF8Encoding $false))
        }
    }
    catch { }
    $true
}

function Enter-MirrorLock {
    # Returns an open FileStream holding an exclusive lock, or $null if another instance holds it.
    param([Parameter(Mandatory)][string]$StateDir)
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    }
    $path = [IO.Path]::Combine($StateDir, 'sync.lock')
    try {
        return [IO.File]::Open($path, 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [System.IO.IOException] {
        return $null
    }
}

function Test-SyncRunning {
    # $true when another running process's command line mentions Invoke-Sync.ps1 (the scheduled run or a
    # repair). Deliberately never opens sync.lock: a scheduled sync starting in that instant would find the
    # lock held and skip its whole run. $StateDir is kept for callers; it is not needed any more.
    param([Parameter(Mandatory)][string]$StateDir)
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "CommandLine LIKE '%Invoke-Sync.ps1%'" -ErrorAction Stop)
    }
    catch { return $false }
    foreach ($p in $procs) {
        if ($null -eq $p -or [int]$p.ProcessId -eq $PID) { continue }
        if ([string]$p.CommandLine -match 'Invoke-Sync\.ps1') { return $true }
    }
    $false
}

function Exit-MirrorLock {
    param($Handle)
    if ($null -ne $Handle) { $Handle.Dispose() }
}

function Remove-OldLogs {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][datetime]$Now
    )
    $dir = [IO.Path]::Combine($Config.StateDir, 'logs')
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $cutoff = $Now.AddDays(-[int]$Config.LogKeepDays)
    Get-ChildItem -LiteralPath $dir -Recurse -File |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}

function Clear-StaleBisyncLocks {
    # Call only while holding sync.lock: this engine is the sole user of <StateDir>\bisync, so any *.lck there is a
    # leftover from an interrupted run (otherwise bisync fails with "prior lock file found" until --max-lock expires).
    # Returns the removed file names.
    param([Parameter(Mandatory)]$Config)
    $dir = [IO.Path]::Combine($Config.StateDir, 'bisync')
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $removed = New-Object System.Collections.Generic.List[string]
    # -Filter '*.lck' would also match '*.lckx' (8.3 short names), so check the extension exactly.
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -ieq '.lck' })) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
        }
        catch {
            # Leave it; bisync then reports the lock and the run's normal error handling takes over.
            Write-MirrorLog -Config $Config -Message ('Could not remove stale bisync lock {0}: {1}' -f $f.Name, $_.Exception.Message)
            continue
        }
        $removed.Add($f.Name)
        Write-MirrorLog -Config $Config -Message ('Removed stale bisync lock {0} (previous run was interrupted)' -f $f.Name)
    }
    $removed.ToArray()
}

function Invoke-RcloneOutput {
    # Runs rclone and returns @{ ExitCode; Output = <string[]> } (stdout lines; stderr dropped). rclone writes UTF-8,
    # so the console decoding is switched to UTF-8 for the call (names with diacritics survive).
    param([Parameter(Mandatory)][string[]]$Arguments)
    $out = New-Object System.Collections.Generic.List[string]
    $prevPref = $ErrorActionPreference
    $prevEnc = $null
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $prevEnc = $null }
    $ErrorActionPreference = 'Continue'
    $code = 0
    try {
        $global:LASTEXITCODE = 0
        & rclone @Arguments 2>&1 | ForEach-Object {
            if ($_ -isnot [System.Management.Automation.ErrorRecord]) { $out.Add([string]$_) }
        }
        $code = [int]$global:LASTEXITCODE
    }
    catch [System.Management.Automation.CommandNotFoundException] { $code = 127 }
    finally {
        $ErrorActionPreference = $prevPref
        if ($null -ne $prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
    }
    [pscustomobject]@{ ExitCode = $code; Output = $out.ToArray() }
}
