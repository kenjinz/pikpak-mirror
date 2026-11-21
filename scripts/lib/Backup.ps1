# Folder list backup documents: build, parse and restore helpers. Pure functions, no network and no rclone.
# Windows PowerShell 5.1 compatible, ASCII source (build non-ASCII text with [char]).

$script:BackupPlainName = '.pikpak-sync-backup.json'
$script:BackupEncryptedName = '.pikpak-sync-encrypted.json'

function ConvertTo-BackupPlainValue {
    # Deep copy of a value as hashtables, object[] arrays, strings, bools and numbers. Reads PSCustomObject too
    # (ConvertFrom-Json in Windows PowerShell 5.1), and turns whole doubles into [long] so 30 stays 30.
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-BackupPlainValue $p.Value }
        return $h
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($Value.Keys)) { $h[[string]$k] = ConvertTo-BackupPlainValue $Value[$k] }
        return $h
    }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [char]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($x in $Value) { $list.Add((ConvertTo-BackupPlainValue $x)) }
        return , ($list.ToArray())
    }
    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        $d = [decimal]$Value
        if ($d -eq [decimal]::Truncate($d) -and $d -ge [decimal][long]::MinValue -and $d -le [decimal][long]::MaxValue) {
            return [long]$d
        }
        return $Value
    }
    return $Value
}

function Add-BackupJsonText {
    # Appends one value as JSON to a StringBuilder. Plain hashtables are written with sorted keys, ordered
    # dictionaries in their own order; -Sorted sorts everything. Strings keep their characters (UTF-8 on write).
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Sb,
        $Value,
        [int]$Level = 0,
        [switch]$Pretty,
        [switch]$Sorted
    )
    $nl = ''
    $pad = ''
    $padIn = ''
    $colon = ':'
    if ($Pretty) {
        $nl = "`n"
        $pad = '  ' * $Level
        $padIn = '  ' * ($Level + 1)
        $colon = ': '
    }
    if ($null -eq $Value) { [void]$Sb.Append('null'); return }
    if ($Value -is [bool]) { if ($Value) { [void]$Sb.Append('true') } else { [void]$Sb.Append('false') }; return }
    if ($Value -is [string] -or $Value -is [char]) {
        [void]$Sb.Append('"')
        foreach ($c in ([string]$Value).ToCharArray()) {
            $n = [int]$c
            if ($c -eq [char]34) { [void]$Sb.Append('\"') }
            elseif ($c -eq [char]92) { [void]$Sb.Append('\\') }
            elseif ($n -eq 10) { [void]$Sb.Append('\n') }
            elseif ($n -eq 13) { [void]$Sb.Append('\r') }
            elseif ($n -eq 9) { [void]$Sb.Append('\t') }
            elseif ($n -eq 8) { [void]$Sb.Append('\b') }
            elseif ($n -eq 12) { [void]$Sb.Append('\f') }
            elseif ($n -lt 32) { [void]$Sb.Append('\u' + $n.ToString('x4')) }
            else { [void]$Sb.Append($c) }
        }
        [void]$Sb.Append('"')
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys | ForEach-Object { [string]$_ })
        if ($Sorted -or $Value -is [hashtable]) { [Array]::Sort($keys, [StringComparer]::Ordinal) }
        if ($keys.Count -eq 0) { [void]$Sb.Append('{}'); return }
        [void]$Sb.Append('{' + $nl)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            [void]$Sb.Append($padIn)
            Add-BackupJsonText -Sb $Sb -Value $keys[$i] -Level ($Level + 1) -Pretty:$Pretty -Sorted:$Sorted
            [void]$Sb.Append($colon)
            Add-BackupJsonText -Sb $Sb -Value $Value[$keys[$i]] -Level ($Level + 1) -Pretty:$Pretty -Sorted:$Sorted
            if ($i -lt $keys.Count - 1) { [void]$Sb.Append(',') }
            [void]$Sb.Append($nl)
        }
        [void]$Sb.Append($pad + '}')
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { [void]$Sb.Append('[]'); return }
        [void]$Sb.Append('[' + $nl)
        for ($i = 0; $i -lt $items.Count; $i++) {
            [void]$Sb.Append($padIn)
            Add-BackupJsonText -Sb $Sb -Value $items[$i] -Level ($Level + 1) -Pretty:$Pretty -Sorted:$Sorted
            if ($i -lt $items.Count - 1) { [void]$Sb.Append(',') }
            [void]$Sb.Append($nl)
        }
        [void]$Sb.Append($pad + ']')
        return
    }
    if ($Value -is [double] -or $Value -is [single]) {
        [void]$Sb.Append(([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if ($Value -is [ValueType] -and $Value -is [IFormattable] -and -not ($Value -is [enum]) -and -not ($Value -is [datetime])) {
        [void]$Sb.Append($Value.ToString($null, [Globalization.CultureInfo]::InvariantCulture))
        return
    }
    Add-BackupJsonText -Sb $Sb -Value ([string]$Value) -Level $Level -Pretty:$Pretty -Sorted:$Sorted
}

function ConvertTo-BackupJson {
    param($Value, [switch]$Pretty, [switch]$Sorted)
    $sb = New-Object System.Text.StringBuilder
    Add-BackupJsonText -Sb $sb -Value $Value -Level 0 -Pretty:$Pretty -Sorted:$Sorted
    $sb.ToString()
}

function ConvertTo-BackupDocuments {
    # The two backup files as JSON text plus the content hash that tells whether either has to be uploaded again.
    # The readable file never carries PrivatePaths; pairs that contain an encrypted folder only get a flag.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$RawConfig,
        [AllowEmptyString()][string]$GlobalFilters = '',
        [Parameter(Mandatory)][datetime]$Now,
        [AllowEmptyString()][string]$PcName = '',
        [AllowEmptyString()][string]$AppVersion = ''
    )

    $config = ConvertTo-BackupPlainValue $RawConfig
    $privatePaths = @()
    if ($config.ContainsKey('PrivatePaths')) {
        $privatePaths = @(@($config['PrivatePaths']) | Where-Object { $null -ne $_ })
        $config.Remove('PrivatePaths')
    }

    # holdsEncrypted keeps a restored synced folder from uploading encrypted files in a readable form, so it fails
    # closed: when an encrypted folder's path cannot be resolved, no pair can be ruled out and every pair is flagged.
    $privateKeys = @()
    $unresolved = $false
    foreach ($e in $privatePaths) {
        if ($e -is [hashtable] -and $e.ContainsKey('Path') -and $e['Path']) {
            try { $privateKeys += , (ConvertTo-PrefixKey (ConvertTo-MirrorPath ([string]$e['Path']))) } catch { $unresolved = $true }
        }
    }
    if ($config.ContainsKey('Pairs') -and $null -ne $config['Pairs']) {
        foreach ($pair in @($config['Pairs'])) {
            if ($pair -isnot [hashtable] -or -not $pair.ContainsKey('Local') -or -not $pair['Local']) { continue }
            if ($unresolved) { $pair['holdsEncrypted'] = $true; continue }
            try { $localKey = ConvertTo-PrefixKey (ConvertTo-MirrorPath ([string]$pair['Local'])) } catch { continue }
            foreach ($pk in $privateKeys) {
                if ($pk.StartsWith($localKey, [StringComparison]::Ordinal)) { $pair['holdsEncrypted'] = $true; break }
            }
        }
    }

    $saved = $Now.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)

    $plain = [ordered]@{
        app = 'pikpak-mirror'; kind = 'folder-list-backup'; version = 1
        saved = $saved; pcName = $PcName; appVersion = $AppVersion
        config = $config; globalFilters = $GlobalFilters
    }
    $encrypted = [ordered]@{
        app = 'pikpak-mirror'; kind = 'encrypted-folder-list'; version = 1
        saved = $saved; pcName = $PcName; appVersion = $AppVersion
        privatePaths = $privatePaths
    }
    $canonical = ConvertTo-BackupJson -Value @{ config = $config; globalFilters = $GlobalFilters; privatePaths = $privatePaths } -Sorted
    @{
        Plain     = ConvertTo-BackupJson -Value $plain -Pretty
        Encrypted = ConvertTo-BackupJson -Value $encrypted -Pretty
        Hash      = Get-TextHash -Lines @($canonical)
    }
}

function ConvertFrom-BackupText {
    # Parses a downloaded backup file. Anything that is not a readable backup of this app, of the wanted kind and
    # of a version this code knows comes back as @{ Invalid = $true; Reason = ... }; it never throws.
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][ValidateSet('plain', 'encrypted')][string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return @{ Invalid = $true; Reason = 'The backup file is empty.' } }
    $clean = $Text.TrimStart([char]0xFEFF)
    try { $doc = ConvertFrom-Json -InputObject $clean -ErrorAction Stop }
    catch { return @{ Invalid = $true; Reason = 'The backup file is not valid JSON.' } }
    if ($doc -isnot [System.Management.Automation.PSCustomObject]) {
        return @{ Invalid = $true; Reason = 'The backup file is not a PikPak Sync backup.' }
    }
    $props = @{}
    foreach ($p in $doc.PSObject.Properties) { $props[$p.Name] = $p.Value }
    $wantKind = if ($Kind -eq 'plain') { 'folder-list-backup' } else { 'encrypted-folder-list' }
    if ($props['app'] -isnot [string] -or $props['app'] -cne 'pikpak-mirror') {
        return @{ Invalid = $true; Reason = 'The backup file is not a PikPak Sync backup.' }
    }
    if ($props['kind'] -isnot [string] -or $props['kind'] -cne $wantKind) {
        return @{ Invalid = $true; Reason = 'The backup file is of another kind.' }
    }
    $ver = $props['version']
    if (($ver -isnot [int] -and $ver -isnot [long] -and $ver -isnot [double] -and $ver -isnot [decimal]) -or $ver -lt 1 -or $ver -gt 1 -or $ver -ne [math]::Floor([double]$ver)) {
        return @{ Invalid = $true; Reason = 'The backup file was made by a newer version of the app.' }
    }

    $saved = ''
    if ($props['saved'] -is [datetime]) { $saved = $props['saved'].ToString('o') } elseif ($props['saved']) { $saved = [string]$props['saved'] }
    $pc = ''
    if ($props['pcName']) { $pc = [string]$props['pcName'] }

    if ($Kind -eq 'plain') {
        if ($props['config'] -isnot [System.Management.Automation.PSCustomObject]) {
            return @{ Invalid = $true; Reason = 'The backup file has no folder list.' }
        }
        $filters = ''
        if ($props['globalFilters'] -is [string]) { $filters = $props['globalFilters'] }
        return @{
            Config = (ConvertTo-BackupPlainValue $props['config']); GlobalFilters = $filters
            PrivatePaths = @(); Saved = $saved; PcName = $pc
        }
    }
    $entries = @()
    if ($null -ne $props['privatePaths']) {
        foreach ($e in @($props['privatePaths'])) {
            if ($e -is [System.Management.Automation.PSCustomObject]) { $entries += , (ConvertTo-BackupPlainValue $e) }
        }
    }
    @{ Config = $null; GlobalFilters = ''; PrivatePaths = $entries; Saved = $saved; PcName = $pc }
}

function Test-BackupDriveMissing {
    # True when the path starts with a drive letter whose root does not exist on this PC.
    param([string]$Path, [scriptblock]$PathExists)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -notmatch '^([A-Za-z]):[\\/]?') { return $false }
    $root = $Matches[1].ToUpperInvariant() + ':\'
    return (-not [bool](& $PathExists $root))
}

function Resolve-RestorePath {
    # Where a backed-up local path lives on this PC. %VAR% paths move by themselves and are returned unchanged.
    # A literal C:\Users\<old>\... path goes to the current profile when <old> is not this user and has no folder here.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$UserProfile,
        [Parameter(Mandatory)][scriptblock]$PathExists
    )

    $result = $Path
    $moved = $false
    if ($Path.IndexOf('%') -lt 0 -and $Path -match '^(?i)C:[\\/]+Users[\\/]+([^\\/]+)((?:[\\/].*)?)$') {
        $old = $Matches[1]
        $rest = $Matches[2]
        $current = Split-Path -Path $UserProfile.TrimEnd('\', '/') -Leaf
        if ($old -ine $current -and -not [bool](& $PathExists ('C:\Users\' + $old))) {
            $result = $UserProfile.TrimEnd('\', '/') + $rest.Replace('/', '\')
            $moved = $true
        }
    }
    @{ Path = $result; Moved = $moved; DriveMissing = (Test-BackupDriveMissing -Path $result -PathExists $PathExists) }
}

function New-RestoreConfig {
    # The raw config to save after a restore: the backup's settings, the chosen folders and encrypted folders, and
    # defaults for anything missing. Machine paths (LocalHolding, StateDir) fall back to the defaults when their
    # drive is not on this PC. holdsEncrypted is a backup-only flag and is removed.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Settings,
        [AllowEmptyCollection()][hashtable[]]$Pairs = @(),
        [AllowEmptyCollection()][hashtable[]]$PrivatePaths = @(),
        [Parameter(Mandatory)][hashtable]$Defaults,
        [Parameter(Mandatory)][scriptblock]$PathExists
    )

    $config = ConvertTo-BackupPlainValue $Settings
    foreach ($k in @('Pairs', 'PrivatePaths')) { if ($config.ContainsKey($k)) { $config.Remove($k) } }
    foreach ($k in @($Defaults.Keys)) {
        if ($k -ceq 'Pairs' -or $k -ceq 'PrivatePaths') { continue }
        if (-not $config.ContainsKey($k) -or $null -eq $config[$k]) { $config[$k] = ConvertTo-BackupPlainValue $Defaults[$k] }
    }
    foreach ($k in @('LocalHolding', 'StateDir')) {
        if ($config.ContainsKey($k) -and $config[$k] -is [string] -and $Defaults.ContainsKey($k) -and (Test-BackupDriveMissing -Path $config[$k] -PathExists $PathExists)) {
            $config[$k] = ConvertTo-BackupPlainValue $Defaults[$k]
        }
    }

    $pairList = New-Object System.Collections.Generic.List[object]
    foreach ($p in @($Pairs)) {
        $copy = ConvertTo-BackupPlainValue $p
        if ($copy.ContainsKey('holdsEncrypted')) { $copy.Remove('holdsEncrypted') }
        $pairList.Add($copy)
    }
    $privList = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($PrivatePaths)) { $privList.Add((ConvertTo-BackupPlainValue $e)) }
    $config['Pairs'] = $pairList.ToArray()
    $config['PrivatePaths'] = $privList.ToArray()
    $config
}

# ===== Uploading the backup =========================================================================

function Get-BackupStatus {
    # @{ Hash; LastSuccess; FailingSince; EncryptedUploaded } from <StateDir>\backup.json. A separate file from
    # state.json, so a push from the app never races the sync run's state save. Defaults when missing or unreadable.
    # LastSuccess and FailingSince are 'yyyy-MM-ddTHH:mm:ss' text (local time) or $null.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateDir)

    $status = @{ Hash = ''; LastSuccess = $null; FailingSince = $null; EncryptedUploaded = $false }
    $file = Join-Path $StateDir 'backup.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $status }
    try {
        $doc = [IO.File]::ReadAllText($file).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop
        if ($doc -is [System.Management.Automation.PSCustomObject]) {
            $p = $doc.PSObject.Properties
            if ($null -ne $p['Hash'] -and $p['Hash'].Value -is [string]) { $status.Hash = $p['Hash'].Value }
            foreach ($k in @('LastSuccess', 'FailingSince')) {
                if ($null -ne $p[$k] -and $p[$k].Value -is [string] -and $p[$k].Value) { $status[$k] = $p[$k].Value }
            }
            if ($null -ne $p['EncryptedUploaded'] -and $p['EncryptedUploaded'].Value -is [bool]) { $status.EncryptedUploaded = $p['EncryptedUploaded'].Value }
        }
    }
    catch { }
    $status
}

function Save-BackupStatus {
    # Writes <StateDir>\backup.json atomically (temp file, then move), UTF-8 without BOM.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][hashtable]$Status)

    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $file = Join-Path $StateDir 'backup.json'
    $tmp = Join-Path $StateDir ('backup.json.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $doc = [ordered]@{
        Hash = [string]$Status['Hash']; LastSuccess = $Status['LastSuccess']; FailingSince = $Status['FailingSince']
        EncryptedUploaded = [bool]$Status['EncryptedUploaded']
    }
    try {
        [IO.File]::WriteAllText($tmp, (ConvertTo-BackupJson -Value $doc -Pretty), (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $file -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-BackupAppVersion {
    # The app version that carries this engine: the first word of the engine.hash marker the app writes next to
    # scripts\. '' when the engine runs from a checkout (no marker) or the marker is not in that form.
    [CmdletBinding()]
    param([string]$EngineRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))

    try {
        $marker = Join-Path $EngineRoot 'engine.hash'
        if (Test-Path -LiteralPath $marker -PathType Leaf) {
            $first = ([IO.File]::ReadAllText($marker).Trim() -split '\s+')[0]
            if ($first -match '^[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$') { return $first }
        }
    }
    catch { }
    ''
}

function Publish-ConfigBackup {
    # Uploads the folder list backup when it changed (or with -Force). Never throws: a failure is logged, leaves the
    # stored hash alone so the next call tries again, and comes back as Error. Log lines and errors name no
    # encrypted folder and no secret.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][datetime]$Now,
        [switch]$Force
    )

    $result = @{ Uploaded = $false; Skipped = $false; Error = $null }
    $temps = New-Object System.Collections.Generic.List[string]
    $stateDir = [string]$Config['StateDir']
    $stamp = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
    try {
        $raw = Get-RawMirrorConfig -Path $ConfigPath
        $filters = ''
        $filtersFile = [string]$Config['GlobalFiltersFile']
        if ($filtersFile -and (Test-Path -LiteralPath $filtersFile -PathType Leaf)) { $filters = [IO.File]::ReadAllText($filtersFile) }
        $docs = ConvertTo-BackupDocuments -RawConfig $raw -GlobalFilters $filters -Now $Now -PcName ([string]$env:COMPUTERNAME) -AppVersion (Get-BackupAppVersion)

        $status = Get-BackupStatus -StateDir $stateDir
        # Skipped only when nothing changed AND the last try did not fail: after a failure (maybe a partial upload)
        # the same content is sent again, which also clears FailingSince once it works.
        if (-not $Force -and $status.Hash -ceq $docs.Hash -and [string]::IsNullOrEmpty([string]$status.FailingSince)) {
            $result.Skipped = $true
            return $result
        }

        $hasEncrypted = @(@($raw['PrivatePaths']) | Where-Object { $null -ne $_ }).Count -gt 0
        $withEncrypted = $hasEncrypted -or $status.EncryptedUploaded

        if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        $uploads = @(, @('the folder list', $docs.Plain, (Join-RemotePath ([string]$Config['Remote']) @([string]$Config['MirrorRoot'], $script:BackupPlainName))))
        if ($withEncrypted) {
            $uploads += , @('the encrypted folder list', $docs.Encrypted, (Join-RemotePath ([string]$Config['PrivateRemote']) @($script:BackupEncryptedName)))
        }
        foreach ($u in $uploads) {
            $tmp = Join-Path $stateDir ('backup-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
            $temps.Add($tmp)
            [IO.File]::WriteAllText($tmp, [string]$u[1], (New-Object Text.UTF8Encoding $false))
            $r = Invoke-RcloneOutput -Arguments ([string[]]@('copyto', $tmp, [string]$u[2]))
            if ($r.ExitCode -ne 0) { throw ('rclone could not upload {0} (exit code {1}).' -f $u[0], $r.ExitCode) }
        }

        $status.Hash = $docs.Hash
        $status.LastSuccess = $stamp
        $status.FailingSince = $null
        $status.EncryptedUploaded = $withEncrypted
        Save-BackupStatus -StateDir $stateDir -Status $status
        $result.Uploaded = $true
    }
    catch {
        $result.Error = [string]$_.Exception.Message
        try { Write-MirrorLog -Config $Config -Message ('Folder list backup failed: ' + $result.Error) } catch { }
        try {
            $st = Get-BackupStatus -StateDir $stateDir
            if ([string]::IsNullOrEmpty([string]$st.FailingSince)) {
                $st.FailingSince = $stamp
                Save-BackupStatus -StateDir $stateDir -Status $st
            }
        }
        catch { }
    }
    finally {
        foreach ($t in $temps) { try { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue } catch { } }
    }
    $result
}

# ===== Finding synced folders from their ID files ===================================================

function Find-RemoteSyncedFolders {
    # The synced folders under <Remote>:<MirrorRoot> found from their ID files (used when there is no backup):
    # @{ Id; Name; Remote; LastPath } items sorted by Remote (wrap in @()). One 'rclone lsf -R' lists every ID file,
    # then each folder top is read with 'rclone cat'. An ID file below a found folder is not read (only folder tops have one). One
    # that is not of a synced folder, or not valid, is skipped and logged (when -Config gives a log). Throws when
    # PikPak cannot be listed or an ID file cannot be read: "no folders there" must never be a guess.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Remote,
        [Parameter(Mandatory)][string]$MirrorRoot,
        $Config
    )

    $marker = Get-FolderMarkerName -Kind 'pair'
    $root = Join-RemotePath $Remote @($MirrorRoot)
    $log = {
        param([string]$Message)
        if ($null -ne $Config) { try { Write-MirrorLog -Config $Config -Message ('Folder scan: ' + $Message) } catch { } }
    }
    $list = Invoke-RcloneOutput -Arguments ([string[]]@('lsf', '-R', '--files-only', '--include', $marker, $root))
    if ($list.ExitCode -eq 3) { return }
    if ($list.ExitCode -ne 0) { throw ('rclone could not list the ID files in {0} (exit code {1}).' -f $root, $list.ExitCode) }

    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($list.Output)) {
        $f = ([string]$line).Trim()
        if ($f -ceq $marker) { & $log ('an ID file at the top of {0} was skipped' -f $root); continue }
        if (-not $f.EndsWith('/' + $marker, [StringComparison]::Ordinal)) { continue }
        $dirs.Add($f.Substring(0, $f.Length - $marker.Length - 1))
    }
    # Shallow folders first, so a nested ID file is dropped before anything reads it.
    $ordered = @($dirs | Sort-Object -Property @{ Expression = { @($_.Split('/')).Count } }, @{ Expression = { $_ } })

    $found = New-Object System.Collections.Generic.List[object]
    foreach ($d in $ordered) {
        $nested = $false
        foreach ($k in $found) { if ($d.StartsWith($k.Remote + '/', [StringComparison]::OrdinalIgnoreCase)) { $nested = $true; break } }
        if ($nested) { continue }
        $r = Invoke-RcloneOutput -Arguments ([string[]]@('cat', ($root.TrimEnd('/') + '/' + $d + '/' + $marker)))
        $res = ConvertTo-RemoteMarkerResult -Result $r
        if ($res.Failed) { throw ('rclone could not read the ID file of {0} (exit code {1}).' -f $d, $r.ExitCode) }
        if (-not $res.Found) { continue }
        if ($res.Marker.ContainsKey('Invalid')) { & $log ('the ID file of {0} is not valid and was skipped' -f $d); continue }
        if ([string]$res.Marker.Kind -cne 'synced') { & $log ('the ID file of {0} is not of a synced folder and was skipped' -f $d); continue }
        $name = [string]$res.Marker.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = @($d.Split('/'))[-1] }
        $last = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$res.Marker.LastPath)) { $last = [string]$res.Marker.LastPath }
        $found.Add(@{ Id = [string]$res.Marker.Id; Name = $name; Remote = $d; LastPath = $last })
    }
    $found | Sort-Object -Property @{ Expression = { $_.Remote } }
}
