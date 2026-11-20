# One-time setup, safe to run again: installs rclone, creates the rclone remotes, registers the
# scheduled sync task and creates the local folders.
# Each step prints [skip] when it is already done. -WhatIf prints what would happen and changes nothing.
#   .\Install.ps1                     (sync task is created DISABLED)
#   .\Install.ps1 -EnableSchedule     (turn the scheduled sync on)
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$EnableSchedule,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\_load.ps1')

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if ([string]::IsNullOrEmpty($ConfigPath)) { $ConfigPath = Join-Path $repoRoot 'config\mirror.config.psd1' }
# config\mirror.config.psd1 is personal and not in the repository: start from the sample when there is none yet.
$samplePath = Join-Path $repoRoot 'config\mirror.config.sample.psd1'
if (-not (Test-Path -LiteralPath $ConfigPath) -and (Test-Path -LiteralPath $samplePath)) {
    Copy-Item -LiteralPath $samplePath -Destination $ConfigPath
    Write-Host ('Created {0} from the sample. Edit it to list your folders.' -f $ConfigPath) -ForegroundColor Yellow
}
$pinnedVersion = 'v1.75.2'

function Write-Step { param([string]$Text) Write-Host ''; Write-Host ('== ' + $Text) -ForegroundColor Cyan }
function Write-Skip { param([string]$Text) Write-Host ('[skip] ' + $Text) -ForegroundColor DarkGray }
function Write-Done { param([string]$Text) Write-Host ('[done] ' + $Text) -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host ('[warn] ' + $Text) -ForegroundColor Yellow }
function Write-Fail { param([string]$Text) Write-Host ('[fail] ' + $Text) -ForegroundColor Red }

function Read-SecretTwice {
    # Hidden input, typed twice; returns the plain string, or $null when mismatched (or empty, unless -AllowEmpty).
    param([Parameter(Mandatory)][string]$Prompt, [switch]$AllowEmpty)
    $a = Read-Host $Prompt -AsSecureString
    $b = Read-Host ($Prompt + ' (again)') -AsSecureString
    $pa = ConvertTo-PlainText -Secure $a
    $pb = ConvertTo-PlainText -Secure $b
    $a.Dispose(); $b.Dispose()
    if ($pa -cne $pb) { return $null }
    if ([string]::IsNullOrEmpty($pa) -and -not $AllowEmpty) { return $null }
    $pa
}

function Write-StepResult {
    # Prints a step result the way the old inline code did; a -WhatIf preview prints nothing (ShouldProcess did).
    param($Result)
    foreach ($r in @($Result)) {
        if ($null -eq $r) { continue }
        if ($r.PSObject.Properties['Details']) { foreach ($d in @($r.Details)) { Write-StepResult -Result $d }; continue }
        if ($r.Skipped) { Write-Skip $r.Message }
        elseif ($r.Done) { Write-Done $r.Message }
        foreach ($line in @($r.Output)) { Write-Host ('       ' + $line) }
        if ($r.Warning) {
            if ($r.Skipped) { Write-Host ('       ' + $r.Warning) } else { Write-Warn $r.Warning }
        }
    }
}

# ---------------------------------------------------------------------------------------------------
Write-Host 'PikPak Sync install' -ForegroundColor Cyan
if ($WhatIfPreference) { Write-Host 'Dry run (-WhatIf): nothing will be installed, created or registered.' -ForegroundColor Yellow }

# 0. Config must load and validate before anything is installed.
Write-Step '0. Check the config'
try {
    $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
    $config = Get-MirrorConfig -Path $ConfigPath
}
catch {
    Write-Fail ('Cannot read the config {0}: {1}' -f $ConfigPath, $_.Exception.Message)
    exit 1
}
$cfgErrors = @(Test-MirrorConfig -Config $config)
if ($cfgErrors.Count -gt 0) {
    foreach ($e in $cfgErrors) { Write-Fail $e }
    Write-Fail 'Fix the config and run Install.ps1 again.'
    exit 1
}
Write-Done ('config OK: {0}' -f $ConfigPath)

try {
    # 1. rclone (pinned).
    Write-Step ('1. rclone {0}' -f $pinnedVersion)
    Write-StepResult (Install-MirrorRclone)
    $haveRclone = Test-RcloneInstalled
    if ($haveRclone) {
        $ver = Get-RcloneVersion -Output (Invoke-RcloneCaptured -RcloneArgs @('version')).Output
        if ($ver -ne $pinnedVersion) { Write-Warn ('rclone is {0}, this project is tested with {1} (not downgrading).' -f $ver, $pinnedVersion) }
        else { Write-Host ('       rclone {0}' -f $ver) }
    }

    $remotes = @()
    if ($haveRclone) {
        $lr = Invoke-RcloneCaptured -RcloneArgs @('listremotes')
        if ($lr.ExitCode -ne 0) { throw ('rclone listremotes failed (exit {0}): {1}' -f $lr.ExitCode, ($lr.Output -join ' ')) }
        $remotes = $lr.Output
    }

    # 2. The PikPak remote.
    $pk = $config.Remote
    Write-Step ("2. rclone remote '{0}' (PikPak account)" -f $pk)
    if ($haveRclone -and (Test-RemoteListed -Listing $remotes -Name $pk)) { Write-Skip ("remote '{0}' exists" -f $pk) }
    elseif ($PSCmdlet.ShouldProcess("rclone remote '$pk'", "Ask for the PikPak email and password, run 'rclone config create $pk pikpak user <email> pass <hidden>', then verify with 'rclone about ${pk}:'")) {
        if (-not $haveRclone) { throw 'rclone is not available.' }
        $email = Read-Host 'PikPak account email'
        $secure = Read-Host 'PikPak password (hidden)' -AsSecureString
        $plain = $null
        try {
            $plain = ConvertTo-PlainText -Secure $secure
            Write-StepResult (New-MirrorPikPakRemote -Name $pk -Email $email -Password $plain)
        }
        finally {
            $plain = $null
            Remove-Variable -Name plain -ErrorAction SilentlyContinue
            $secure.Dispose()
        }
    }

    # 3. The encrypted (crypt) remote over pikpak:PC-Private.
    $pv = $config.PrivateRemote
    Write-Step ("3. rclone remote '{0}' (encrypted, over {1}:PC-Private)" -f $pv, $pk)
    if ($haveRclone -and (Test-RemoteListed -Listing $remotes -Name $pv)) { Write-Skip ("remote '{0}' exists" -f $pv) }
    elseif ($PSCmdlet.ShouldProcess("rclone remote '$pv'", "Enter the saved crypt password + salt (or generate new ones and confirm by typing SAVED), then 'rclone config create $pv crypt remote ${pk}:PC-Private filename_encryption standard directory_name_encryption true password <hidden> password2 <hidden>'")) {
        if (-not $haveRclone) { throw 'rclone is not available.' }
        Write-Host '  a) enter an existing password and salt (restoring, or the key already exists)'
        Write-Host '  b) generate a new password and salt (first install only)'
        $choice = (Read-Host 'Choose a or b').Trim().ToLowerInvariant()
        $pass = $null; $salt = $null
        if ($choice -eq 'b') {
            # A new key over existing encrypted data would make that data unreadable: refuse.
            $raw = Get-RemoteEntryCount -Target ($pk + ':PC-Private')
            if ($raw -lt 0) { throw ('could not check {0}:PC-Private; refusing to generate a new key. Check the connection and run Install.ps1 again.' -f $pk) }
            if ($raw -gt 0) { throw ('{0}:PC-Private already holds encrypted data; a new key would make it unreadable. Run Install.ps1 again and choose a) with the saved password and salt.' -f $pk) }
            $pass = New-CryptSecret -Length 32
            $salt = New-CryptSecret -Length 32
            Write-Host ''
            Write-Host 'SAVE THESE NOW. Without them your encrypted folders can never be decrypted.' -ForegroundColor Yellow
            Write-Host 'Store them in your password manager AND on paper. They are shown only this once.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host ('  Password (password) : {0}' -f $pass)
            Write-Host ('  Salt     (password2): {0}' -f $salt)
            Write-Host ''
            $answer = Read-Host 'Type SAVED once both are stored safely'
            if (-not (Test-SavedConfirmation -Answer $answer)) {
                $pass = $null; $salt = $null
                Remove-Variable -Name pass, salt -ErrorAction SilentlyContinue
                throw ("not confirmed; remote '{0}' was NOT created. Run Install.ps1 again." -f $pv)
            }
            Clear-Host
        }
        elseif ($choice -eq 'a') {
            $pass = Read-SecretTwice -Prompt 'Crypt password or recovery key (hidden)'
            if ($null -eq $pass) { throw 'the two passwords were empty or did not match; nothing was created.' }
            # A recovery key from the app may be typed in groups or lower case: use its normal form.
            $pass = ConvertTo-CryptPassword -Text $pass
            $salt = Read-SecretTwice -Prompt 'Crypt salt / password2 (hidden; press Enter twice if there is none)' -AllowEmpty
            if ($null -eq $salt) { $pass = $null; throw 'the two salts did not match; nothing was created.' }
        }
        else { throw ("unknown choice '{0}'; nothing was created." -f $choice) }

        $mode = 'Existing'
        if ($choice -eq 'b') { $mode = 'New' }
        try {
            Write-StepResult (New-MirrorPrivateRemote -Name $pv -BaseRemote $pk -Password $pass -Salt $salt -Mode $mode)
        }
        finally {
            $pass = $null; $salt = $null
            Remove-Variable -Name pass, salt -ErrorAction SilentlyContinue
        }
    }

    # 4. Scheduled sync, disabled unless -EnableSchedule.
    Write-Step '4. Scheduled task PikPakMirror-Sync'
    Write-StepResult (Register-MirrorTasks -Kind Sync -Config $config -ConfigPath $ConfigPath -RepoRoot $repoRoot -EnableSchedule:$EnableSchedule)

    # 5. One-time cleanup of the old drives and Explorer menu (step 4 already registered the sync task).
    Write-Step '5. Clean up the old drives and Explorer menu'
    Write-StepResult (Invoke-MirrorCleanup -Config $config -ConfigPath $ConfigPath -RepoRoot $repoRoot -SkipSyncTask)

    # 6. Local folders.
    Write-Step '6. Local folders'
    Write-StepResult (New-MirrorLocalFolders -Config $config)
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}

Write-Host ''
if ($WhatIfPreference) {
    Write-Host 'Dry run finished: nothing was changed.' -ForegroundColor Yellow
    exit 0
}
Write-Host 'Install finished.' -ForegroundColor Green
Write-Host 'Next steps:'
Write-Host '  1. List your encrypted folders in config\mirror.config.psd1 (PrivatePaths), then run scripts\Confirm-PrivatePaths.ps1'
if (-not $EnableSchedule) { Write-Host '  2. When testing is done, turn the scheduled sync on: scripts\Install.ps1 -EnableSchedule' }
exit 0
