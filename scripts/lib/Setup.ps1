# Pure builders for Install.ps1: the scheduled-task definition, crypt secrets and rclone
# config-create arguments. Nothing here touches the registry,
# Task Scheduler, winget or rclone. Windows PowerShell 5.1 compatible; kept ASCII.

function Get-HeadlessPowerShellArgument {
    # conhost.exe argument line that runs a script with no visible window.
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string]$ConfigPath)
    '--headless powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $ScriptPath, $ConfigPath
}

function New-MirrorTaskSpec {
    # Definition of a PikPakMirror scheduled task; Install.ps1 turns it into Task Scheduler objects.
    # Sync is registered disabled unless -EnableSchedule (R14).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Sync')][string]$Kind,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$EnableSchedule,
        [string]$SyncTime = '20:00',
        [bool]$SyncAtLogon = $true,
        [int]$SyncIntervalMinutes = 60
    )
    # A trailing backslash would turn the closing quote into \" on the command line.
    $root = $RepoRoot.TrimEnd('\')
    $settings = @{
        StartWhenAvailable         = $true
        MultipleInstances          = 'IgnoreNew'
        ExecutionTimeLimit         = [TimeSpan]::Zero
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
    }
    $script = Join-Path $root 'scripts\Invoke-Sync.ps1'
    $triggers = @()
    if ($SyncAtLogon) { $triggers += @{ Type = 'AtLogOn'; Delay = 'PT15M'; At = $null } }
    if ($SyncIntervalMinutes -eq 0) { $triggers += @{ Type = 'Daily'; Delay = $null; At = $SyncTime } }
    # 'Every': a one-time trigger from 00:00 that repeats every N minutes with no end (not a daily trigger:
    # its repetitions would only start at the daily activation, so a PC asleep at midnight got none that day).
    else { $triggers += @{ Type = 'Every'; Delay = $null; At = '00:00'; Minutes = $SyncIntervalMinutes } }
    $enabled = [bool]$EnableSchedule
    $description = 'PikPak Sync: two-way sync of the configured folders with PikPak.'
    [pscustomobject]@{
        TaskName    = 'PikPakMirror-' + $Kind
        Description = $description
        Execute     = 'conhost.exe'
        Argument    = (Get-HeadlessPowerShellArgument -ScriptPath $script -ConfigPath $ConfigPath)
        Triggers    = $triggers
        Settings    = $settings
        Enabled     = $enabled
    }
}

function New-CryptSecret {
    # Random [A-Za-z0-9] string from RNGCryptoServiceProvider. Rejection sampling keeps it unbiased
    # (248 = 4 * 62; bytes 248..255 are discarded).
    [CmdletBinding()]
    param([ValidateRange(1, 1024)][int]$Length = 32)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 64
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        while ($sb.Length -lt $Length) {
            $rng.GetBytes($buf)
            foreach ($b in $buf) {
                if ($b -ge 248) { continue }
                [void]$sb.Append($alphabet[$b % 62])
                if ($sb.Length -ge $Length) { break }
            }
        }
    }
    finally { $rng.Dispose() }
    $sb.ToString()
}

function New-PikPakRemoteArgs {
    # rclone config create <name> pikpak user <email> pass <password> --obscure --non-interactive
    # --obscure forces obscuring: without it rclone stores a password that "looks obscured" as-is.
    # --non-interactive: Install.ps1 captures the output (so nothing is echoed), so rclone must never wait
    # on a hidden question; an incomplete remote is caught by the verification that follows.
    [CmdletBinding()]
    param(
        [string]$Name = 'pikpak',
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Password
    )
    [string[]]@('config', 'create', $Name, 'pikpak', 'user', $User, 'pass', $Password, '--obscure', '--non-interactive')
}

function New-CryptRemoteArgs {
    # rclone config create private crypt over <base>:PC-Private with name + directory encryption.
    # --obscure is essential: a 32-char [A-Za-z0-9] secret is valid base64 and rclone would otherwise
    # treat it as already obscured, silently using a different key than the one the user saved.
    [CmdletBinding()]
    param(
        [string]$Name = 'private',
        [string]$BaseRemote = 'pikpak',
        [Parameter(Mandatory)][string]$Password,
        [AllowEmptyString()][string]$Salt = ''
    )
    # An empty salt omits password2 (rclone then uses its built-in default salt).
    $a = @('config', 'create', $Name, 'crypt', 'remote', ($BaseRemote + ':PC-Private'),
        'filename_encryption', 'standard', 'directory_name_encryption', 'true',
        'password', $Password)
    if ($Salt -ne '') { $a += @('password2', $Salt) }
    $a += @('--obscure', '--non-interactive')
    [string[]]$a
}

function New-RecoveryKey {
    # 30 random characters from a 31-symbol alphabet without look-alikes (no 0, O, 1, I, L).
    # Rejection sampling keeps it unbiased (248 = 8 * 31; bytes 248..255 are discarded).
    [CmdletBinding()]
    param()
    $alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
    $sb = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 64
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        while ($sb.Length -lt 30) {
            $rng.GetBytes($buf)
            foreach ($b in $buf) {
                if ($b -ge 248) { continue }
                [void]$sb.Append($alphabet[$b % 31])
                if ($sb.Length -ge 30) { break }
            }
        }
    }
    finally { $rng.Dispose() }
    $sb.ToString()
}

function ConvertTo-RecoveryKey {
    # Normalises typed input (any case, spaces and dashes allowed); $null unless it is a valid key.
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')
    $k = ($Text.ToUpperInvariant() -replace '[ \-]', '')
    if ($k -cmatch '^[ABCDEFGHJKMNPQRSTUVWXYZ2-9]{30}$') { return $k }
    return $null
}

function ConvertTo-CryptPassword {
    # The crypt password typed at Install.ps1 option a): a recovery key from the app (any case, spaces and
    # dashes allowed) in its normal form, anything else exactly as typed (the older 32-character password).
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text = '')
    $k = ConvertTo-RecoveryKey -Text $Text
    if ($null -ne $k) { return $k }
    $Text
}

function ConvertTo-ProcessArgument {
    # Quotes one argument for a Windows command line (CommandLineToArgvW / MSVC rules).
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') { $slashes++; continue }
        if ($ch -eq '"') { [void]$sb.Append('\', 2 * $slashes + 1) }
        elseif ($slashes -gt 0) { [void]$sb.Append('\', $slashes) }
        $slashes = 0
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append('\', 2 * $slashes) }
    [void]$sb.Append('"')
    $sb.ToString()
}

function Join-ProcessArguments {
    # One command-line string for Start-Process (Windows PowerShell 5.1 joins -ArgumentList unquoted).
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Arguments)
    (@($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join ' ')
}

function Test-RemoteListed {
    # True when `rclone listremotes` output contains "<Name>:" (remote names are case-sensitive).
    param([AllowEmptyCollection()][AllowNull()][string[]]$Listing, [Parameter(Mandatory)][string]$Name)
    foreach ($line in @($Listing)) {
        if ($null -eq $line) { continue }
        if ($line.Trim() -ceq ($Name + ':')) { return $true }
    }
    $false
}

function Get-RcloneVersion {
    # 'v1.75.2' from `rclone version` output; $null when not recognised.
    param([AllowEmptyCollection()][AllowNull()][string[]]$Output)
    foreach ($line in @($Output)) {
        if ($null -eq $line) { continue }
        if ($line -match '^\s*rclone\s+(v\d+\.\d+\.\d+\S*)') { return $Matches[1] }
    }
    $null
}

function Test-SavedConfirmation {
    # The user must type SAVED exactly (R16).
    param([AllowNull()][AllowEmptyString()][string]$Answer)
    $Answer -ceq 'SAVED'
}

function ConvertTo-PlainText {
    # SecureString -> string, for the single rclone call that needs it. The BSTR is zeroed afterwards.
    param([Parameter(Mandatory)][Security.SecureString]$Secure)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Test-NativeArgumentSafe {
    # Windows PowerShell 5.1 mangles an embedded double quote, and a trailing backslash, when it passes an
    # argument to a native program, so rclone would receive a different value (M3).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    -not ($Value.Contains('"') -or $Value.EndsWith([string][char]92))
}

function Get-UnsafePasswordMessage {
    'This password contains a double quote or ends with a backslash, which Windows PowerShell 5.1 cannot pass to rclone safely. Change your PikPak password (or create it without those characters) and run the installer again.'
}

function Get-RcloneDownloadSpec {
    # The pinned rclone release from rclone.org (winget only carries up to 1.75.1).
    [pscustomobject]@{
        Url        = 'https://downloads.rclone.org/v1.75.2/rclone-v1.75.2-windows-amd64.zip'
        Sha256     = '8a9db2bad1dc79a65b3348fd857069598e2aab7cf4d118b77b1df23055aff818'
        ExeInZip   = 'rclone-v1.75.2-windows-amd64\rclone.exe'
        InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\rclone'
    }
}

function Add-DirToPathString {
    # PATH-style string with $Dir appended unless already present (case-insensitive, trailing '\' ignored).
    param([AllowNull()][AllowEmptyString()][string]$PathValue, [Parameter(Mandatory)][string]$Dir)
    $want = $Dir.TrimEnd('\')
    $parts = @(([string]$PathValue).Split(';') | Where-Object { $_ })
    foreach ($p in $parts) { if ($p.TrimEnd('\') -ieq $want) { return [string]$PathValue } }
    (@($parts) + $Dir) -join ';'
}
