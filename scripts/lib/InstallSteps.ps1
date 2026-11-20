# Install steps as reusable, non-interactive functions. Install.ps1 (console) and the desktop app's
# bridge call them; nothing here prompts or writes to the console. Each returns
#   [pscustomobject]@{ Name; Done; Skipped; Message }   (+ Warning, Output, Details where useful)
# and throws a plain message on failure. Under -WhatIf nothing is changed and Message says what would
# happen. Windows PowerShell 5.1 compatible; kept ASCII.

function New-InstallStepResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [bool]$Done = $false,
        [bool]$Skipped = $false,
        [Parameter(Mandatory)][string]$Message,
        [string]$Warning = '',
        [string[]]$Output = @(),
        $Details = $null
    )
    $r = [pscustomobject]@{ Name = $Name; Done = $Done; Skipped = $Skipped; Message = $Message; Warning = $Warning; Output = @($Output) }
    if ($null -ne $Details) { $r | Add-Member -NotePropertyName Details -NotePropertyValue @($Details) }
    $r
}

function Join-InstallStepResults {
    # One result for a step made of several parts (tasks, registry entries, folders).
    param([Parameter(Mandatory)][string]$Name, [AllowEmptyCollection()][object[]]$Parts = @(), [string]$EmptyMessage = 'nothing to do')
    $parts = @($Parts)
    if ($parts.Count -eq 0) { return (New-InstallStepResult -Name $Name -Skipped $true -Message $EmptyMessage -Details @()) }
    $done = (@($parts | Where-Object { $_.Done }).Count -gt 0)
    $skipped = (@($parts | Where-Object { -not $_.Skipped }).Count -eq 0)
    $msg = (@($parts | ForEach-Object { $_.Message }) -join '; ')
    New-InstallStepResult -Name $Name -Done $done -Skipped $skipped -Message $msg -Details $parts
}

function Test-RcloneInstalled { $null -ne (Get-Command rclone -ErrorAction SilentlyContinue) }

function Update-SessionPath {
    # rclone was added to the user PATH; make it visible to this session too.
    $parts = @($env:Path, [Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User'))
    $env:Path = (@($parts | Where-Object { $_ }) -join ';')
}

function Invoke-RcloneCaptured {
    # Runs rclone with stdout+stderr captured (never shown), so secrets on the command line are not echoed.
    param([Parameter(Mandatory)][string[]]$RcloneArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = 0
    try {
        $out = @(& rclone @RcloneArgs 2>&1 | ForEach-Object { [string]$_ })
        $code = [int]$global:LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    [pscustomobject]@{ ExitCode = $code; Output = $out }
}

function Get-RemoteEntryCount {
    # Entries at the top of a remote folder: -1 when it cannot be listed, 0 when missing or empty.
    param([Parameter(Mandatory)][string]$Target)
    $r = Invoke-RcloneCaptured -RcloneArgs @('lsf', $Target, '--max-depth', '1')
    if ($r.ExitCode -eq 3) { return 0 }
    if ($r.ExitCode -ne 0) { return -1 }
    @($r.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^\d{4}/\d\d/\d\d \d\d:\d\d:\d\d ' }).Count
}

function Install-MirrorRclone {
    # The pinned rclone: official download, SHA256 checked, installed per user and added to the user PATH.
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Test-RcloneInstalled) { return (New-InstallStepResult -Name 'rclone' -Skipped $true -Message 'rclone is installed') }
    $spec = Get-RcloneDownloadSpec
    $what = 'download {0} (SHA256 checked) and install to {1}' -f $spec.Url, $spec.InstallDir
    if (-not $PSCmdlet.ShouldProcess('rclone v1.75.2', $what)) {
        return (New-InstallStepResult -Name 'rclone' -Message ('Would ' + $what))
    }
    # winget only carries rclone up to 1.75.1, so use the official download.
    [Net.ServicePointManager]::SecurityProtocol = 'Tls12'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pikpak-rclone-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $zip = Join-Path $tmp 'rclone.zip'
        # PS 5.1's progress bar makes a 25 MB download take minutes.
        $prevProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $spec.Url -OutFile $zip -UseBasicParsing }
        finally { $ProgressPreference = $prevProgress }
        $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        if ($hash -ne $spec.Sha256.ToUpperInvariant()) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            throw ('the rclone download did not match the expected SHA256 (got {0}); it was deleted, nothing was installed.' -f $hash)
        }
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
        if (-not (Test-Path -LiteralPath $spec.InstallDir)) { New-Item -ItemType Directory -Path $spec.InstallDir -Force | Out-Null }
        Copy-Item -LiteralPath (Join-Path (Join-Path $tmp 'x') $spec.ExeInZip) -Destination (Join-Path $spec.InstallDir 'rclone.exe') -Force
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $newPath = Add-DirToPathString -PathValue $userPath -Dir $spec.InstallDir
    if ($newPath -ne [string]$userPath) { [Environment]::SetEnvironmentVariable('Path', $newPath, 'User') }
    Update-SessionPath
    if (-not (Test-RcloneInstalled)) { throw 'rclone was installed but is not on PATH yet; open a new PowerShell window and run Install.ps1 again.' }
    New-InstallStepResult -Name 'rclone' -Done $true -Message ('rclone installed to {0}' -f $spec.InstallDir)
}

function New-MirrorPikPakRemote {
    # Creates the PikPak remote, verifies it with `rclone about`, and deletes it again on failure so a
    # half-made remote cannot make the next run skip this step (M2). The password is never logged (R16).
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Email,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password
    )
    $what = "create rclone remote '{0}' (pikpak) for {1}, then verify it with 'rclone about {0}:'" -f $Name, $Email
    if (-not $PSCmdlet.ShouldProcess("rclone remote '$Name'", $what)) {
        return (New-InstallStepResult -Name $Name -Message ('Would ' + $what))
    }
    $rcArgs = $null; $r = $null
    try {
        if ([string]::IsNullOrEmpty($Email) -or [string]::IsNullOrEmpty($Password)) { throw 'the email or password was empty; nothing was created.' }
        # Refuse before calling rclone: PS 5.1 would pass a different password (M3).
        if (-not (Test-NativeArgumentSafe -Value $Password)) { throw (Get-UnsafePasswordMessage) }
        $rcArgs = New-PikPakRemoteArgs -Name $Name -User $Email -Password $Password
        $r = Invoke-RcloneCaptured -RcloneArgs $rcArgs
    }
    finally {
        $Password = $null; $rcArgs = $null
        Remove-Variable -Name Password, rcArgs -ErrorAction SilentlyContinue
    }
    if ($r.ExitCode -ne 0) {
        [void](Invoke-RcloneCaptured -RcloneArgs @('config', 'delete', $Name))
        throw ("Creating remote '{0}' failed (exit {1}); it was removed, try again." -f $Name, $r.ExitCode)
    }
    $about = Invoke-RcloneCaptured -RcloneArgs @('about', ($Name + ':'))
    if ($about.ExitCode -ne 0) {
        [void](Invoke-RcloneCaptured -RcloneArgs @('config', 'delete', $Name))
        $text = (($about.Output | Select-Object -First 3) -join ' ')
        if ($text -match '401|unauthori[sz]ed|invalid[_ ](grant|credential|password|user)|incorrect|wrong password|captcha|login failed|authenticat') {
            throw ("PikPak didn't accept that email and password (rclone about exit {0}): {1}. The remote was removed; check them and try again." -f $about.ExitCode, $text)
        }
        throw ("Couldn't reach PikPak (rclone about exit {0}): {1}. The remote was removed; check the connection and try again." -f $about.ExitCode, $text)
    }
    New-InstallStepResult -Name $Name -Done $true -Message ("remote '{0}' created and verified" -f $Name) -Output @($about.Output)
}

function New-MirrorPrivateRemote {
    # Creates the crypt remote over <base>:PC-Private. -Mode New refuses when PC-Private already holds data
    # (a new key would make it unreadable); -Mode Existing refuses when data exists but none of it decrypts.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BaseRemote,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Password,
        [AllowEmptyString()][string]$Salt = '',
        [Parameter(Mandatory)][ValidateSet('New', 'Existing')][string]$Mode
    )
    $target = $BaseRemote + ':PC-Private'
    $what = "create rclone crypt remote '{0}' over {1} ({2} key)" -f $Name, $target, $Mode.ToLowerInvariant()
    if (-not $PSCmdlet.ShouldProcess("rclone remote '$Name'", $what)) {
        return (New-InstallStepResult -Name $Name -Message ('Would ' + $what))
    }
    $rcArgs = $null; $r = $null
    try {
        if ([string]::IsNullOrEmpty($Password)) { throw 'the crypt password was empty; nothing was created.' }
        # Same PS 5.1 limitation as the PikPak password (M3); generated secrets are [A-Za-z0-9] only.
        if (-not ((Test-NativeArgumentSafe -Value $Password) -and (Test-NativeArgumentSafe -Value $Salt))) {
            throw 'The crypt password or salt contains a double quote or ends with a backslash, which Windows PowerShell 5.1 cannot pass to rclone safely. Create the private remote with the interactive "rclone config" (see docs\RECOVERY.md), then run the installer again.'
        }
        if ($Mode -eq 'New') {
            $raw = Get-RemoteEntryCount -Target $target
            if ($raw -lt 0) { throw ('could not check {0}; refusing to generate a new key. Check the connection and try again.' -f $target) }
            if ($raw -gt 0) { throw ('{0} already holds encrypted data; a new key would make it unreadable. Use the saved password and salt instead.' -f $target) }
        }
        $rcArgs = New-CryptRemoteArgs -Name $Name -BaseRemote $BaseRemote -Password $Password -Salt $Salt
        $r = Invoke-RcloneCaptured -RcloneArgs $rcArgs
    }
    finally {
        $Password = $null; $Salt = $null; $rcArgs = $null
        Remove-Variable -Name Password, Salt, rcArgs -ErrorAction SilentlyContinue
    }
    if ($r.ExitCode -ne 0) {
        [void](Invoke-RcloneCaptured -RcloneArgs @('config', 'delete', $Name))
        throw ("creating remote '{0}' failed (exit {1}); it was removed, try again." -f $Name, $r.ExitCode)
    }
    $warning = ''
    if ($Mode -eq 'Existing') {
        $raw = Get-RemoteEntryCount -Target $target
        $dec = Get-RemoteEntryCount -Target ($Name + ':')
        if ($raw -gt 0 -and $dec -eq 0) {
            [void](Invoke-RcloneCaptured -RcloneArgs @('config', 'delete', $Name))
            throw ("{0} has data but none of it decrypts: the password or salt is wrong. Remote '{1}' was removed; try again." -f $target, $Name)
        }
        if ($raw -lt 0 -or $dec -lt 0) { $warning = ("could not verify remote '{0}' against existing data; check it with: rclone lsf {0}:" -f $Name) }
    }
    New-InstallStepResult -Name $Name -Done $true -Message ("remote '{0}' created" -f $Name) -Warning $warning
}

function Get-TaskTriggerSignature {
    # 'Daily@20:00' / 'AtLogOn+PT15M' for a registered CIM trigger, so a changed time or delay is noticed.
    param($Trigger)
    $cls = ''
    if ($null -ne $Trigger.CimClass) { $cls = [string]$Trigger.CimClass.CimClassName }
    $iv = ''
    if ($null -ne $Trigger.Repetition) { $iv = [string]$Trigger.Repetition.Interval }
    $mins = $iv
    if (-not [string]::IsNullOrWhiteSpace($iv)) {
        try { $mins = [string][int][System.Xml.XmlConvert]::ToTimeSpan($iv).TotalMinutes } catch { $mins = $iv }
    }
    if ($cls -match 'TimeTrigger' -and -not [string]::IsNullOrWhiteSpace($iv)) {
        # A one-time trigger repeating every N minutes (PT1H, PT60M, PT3H) is the repeating sync trigger;
        # its start date is ignored, so a task registered on another day is still the same.
        return ('Every@' + $mins)
    }
    if ($cls -match 'Daily') {
        # A daily trigger with a repetition is the old form whose repetitions stopped when the PC slept
        # through midnight: signed 'Repeat@N' so it never equals a spec and gets replaced.
        if (-not [string]::IsNullOrWhiteSpace($iv)) { return ('Repeat@' + $mins) }
        $at = ''
        if ([string]$Trigger.StartBoundary -match 'T(\d\d):(\d\d)') { $at = $Matches[1] + ':' + $Matches[2] }
        return ('Daily@' + $at)
    }
    if ($cls -match 'Logon') { return ('AtLogOn+' + [string]$Trigger.Delay) }
    return $cls
}

function Get-SpecTriggerSignature {
    param($Trigger)
    if ($Trigger.Type -eq 'Daily') {
        $at = [string]$Trigger.At
        if ($at -match '^(\d{1,2}):(\d\d)') { $at = ('{0:00}:{1}' -f [int]$Matches[1], $Matches[2]) }
        return ('Daily@' + $at)
    }
    if ($Trigger.Type -eq 'Every') { return ('Every@' + [int]$Trigger.Minutes) }
    return ('AtLogOn+' + [string]$Trigger.Delay)
}

function New-MirrorTaskTrigger {
    # One spec trigger as a Task Scheduler trigger object (in memory; nothing is registered).
    param([Parameter(Mandatory)]$Trigger, [string]$User = [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    if ($Trigger.Type -eq 'Daily') { return (New-ScheduledTaskTrigger -Daily -At $Trigger.At) }
    if ($Trigger.Type -eq 'Every') {
        # A one-time trigger from today at At (a past moment is fine: Task Scheduler runs the next
        # repetition from now) repeating every N minutes with no end, so it runs whenever the PC is
        # awake, also after sleep or a restart. No -RepetitionDuration gives an empty Duration (= no end);
        # it is set to '' as well in case a Windows version fills in a default span.
        $start = [datetime]::Today.Add([TimeSpan]::Parse([string]$Trigger.At))
        $tr = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes ([int]$Trigger.Minutes))
        $tr.Repetition.Duration = ''
        return $tr
    }
    $tr = New-ScheduledTaskTrigger -AtLogOn -User $User
    if ($Trigger.Delay) { $tr.Delay = $Trigger.Delay }
    $tr
}

function Install-MirrorTask {
    # Registers one scheduled task from a New-MirrorTaskSpec; "same" = same action and same trigger
    # types, times and delays, so a changed sync time re-registers.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)]$Spec, [string]$RepoRoot = (Get-Location).ProviderPath)
    $existing = Get-ScheduledTask -TaskName $Spec.TaskName -ErrorAction SilentlyContinue
    $same = $false
    if ($null -ne $existing) {
        $acts = @($existing.Actions)
        $have = @(@($existing.Triggers) | ForEach-Object { Get-TaskTriggerSignature -Trigger $_ } | Sort-Object)
        $want = @(@($Spec.Triggers) | ForEach-Object { Get-SpecTriggerSignature -Trigger $_ } | Sort-Object)
        $same = ($acts.Count -eq 1) -and ($acts[0].Execute -eq $Spec.Execute) -and ($acts[0].Arguments -eq $Spec.Argument) -and
            (($have -join '|') -eq ($want -join '|'))
    }
    if ($same) {
        $msg = '{0} is already registered ({1})' -f $Spec.TaskName, $existing.State
        if ($Spec.Enabled -and [string]$existing.State -eq 'Disabled') {
            if ($PSCmdlet.ShouldProcess($Spec.TaskName, 'Enable scheduled task')) {
                Enable-ScheduledTask -TaskName $Spec.TaskName | Out-Null
                return (New-InstallStepResult -Name $Spec.TaskName -Done $true -Message ('{0} enabled' -f $Spec.TaskName))
            }
            return (New-InstallStepResult -Name $Spec.TaskName -Message ('Would enable scheduled task {0}' -f $Spec.TaskName))
        }
        $warn = ''
        if (-not $Spec.Enabled -and [string]$existing.State -ne 'Disabled') {
            $warn = '{0} stays enabled. To pause it: Disable-ScheduledTask -TaskName {0}' -f $Spec.TaskName
        }
        return (New-InstallStepResult -Name $Spec.TaskName -Skipped $true -Message $msg -Warning $warn)
    }

    # New task, or the repo/config/time moved: (re)register. Keep a task the user already enabled enabled.
    $enabled = $Spec.Enabled -or (($null -ne $existing) -and ([string]$existing.State -ne 'Disabled'))
    $trigText = (@($Spec.Triggers) | ForEach-Object {
            if ($_.Type -eq 'Daily') { 'daily at ' + $_.At }
            elseif ($_.Type -eq 'Every') { 'every {0} minutes' -f $_.Minutes }
            elseif ($_.Delay) { 'at logon + ' + $_.Delay }
            else { 'at logon' }
        }) -join ', '
    $state = 'enabled'
    if (-not $enabled) { $state = 'DISABLED (run Install.ps1 -EnableSchedule to turn it on)' }
    $what = 'Register scheduled task: {0} {1} | triggers: {2} | {3}' -f $Spec.Execute, $Spec.Argument, $trigText, $state
    if (-not $PSCmdlet.ShouldProcess($Spec.TaskName, $what)) {
        return (New-InstallStepResult -Name $Spec.TaskName -Message ('Would ' + $what))
    }

    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $triggers = @(foreach ($t in @($Spec.Triggers)) { New-MirrorTaskTrigger -Trigger $t -User $user })
    $action = New-ScheduledTaskAction -Execute $Spec.Execute -Argument $Spec.Argument -WorkingDirectory $RepoRoot
    $s = $Spec.Settings
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable:([bool]$s.StartWhenAvailable) -MultipleInstances $s.MultipleInstances `
        -ExecutionTimeLimit $s.ExecutionTimeLimit -AllowStartIfOnBatteries:([bool]$s.AllowStartIfOnBatteries) `
        -DontStopIfGoingOnBatteries:([bool]$s.DontStopIfGoingOnBatteries)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $Spec.TaskName -Description $Spec.Description -Action $action -Trigger $triggers `
        -Settings $settings -Principal $principal -Force | Out-Null
    if (-not $enabled) { Disable-ScheduledTask -TaskName $Spec.TaskName | Out-Null }
    New-InstallStepResult -Name $Spec.TaskName -Done $true -Message ('{0} registered ({1})' -f $Spec.TaskName, $state)
}

function Register-MirrorTasks {
    # The Sync task (disabled unless -EnableSchedule, R14). SyncTime / SyncAtLogon / SyncIntervalMinutes come
    # from the config when present. -Kind is kept so callers keep working; Sync is the only task.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [switch]$EnableSchedule,
        [ValidateSet('Sync')][string]$Kind = 'Sync'
    )
    $syncArgs = @{ Kind = 'Sync'; RepoRoot = $RepoRoot; ConfigPath = $ConfigPath; EnableSchedule = $EnableSchedule }
    if ($Config.ContainsKey('SyncTime') -and -not [string]::IsNullOrWhiteSpace([string]$Config['SyncTime'])) { $syncArgs['SyncTime'] = [string]$Config['SyncTime'] }
    if ($Config.ContainsKey('SyncAtLogon') -and $null -ne $Config['SyncAtLogon']) { $syncArgs['SyncAtLogon'] = [bool]$Config['SyncAtLogon'] }
    $syncArgs['SyncIntervalMinutes'] = Get-SyncIntervalMinutes -Config $Config
    Install-MirrorTask -Spec (New-MirrorTaskSpec @syncArgs) -RepoRoot $RepoRoot
}

function New-MirrorLocalFolders {
    # Local holding and state folders.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Config)
    $parts = @()
    foreach ($k in @('LocalHolding', 'StateDir')) {
        $dir = [string]$Config[$k]
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        if (Test-Path -LiteralPath $dir -PathType Container) {
            $parts += New-InstallStepResult -Name $k -Skipped $true -Message ('{0} exists: {1}' -f $k, $dir)
        }
        elseif ($PSCmdlet.ShouldProcess($dir, ('Create folder ({0})' -f $k))) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $parts += New-InstallStepResult -Name $k -Done $true -Message ('{0} created: {1}' -f $k, $dir)
        }
        else {
            $parts += New-InstallStepResult -Name $k -Message ('Would create folder {0}: {1}' -f $k, $dir)
        }
    }
    Join-InstallStepResults -Name 'Local folders' -Parts $parts
}

function Test-MirrorMountCommandLine {
    # $true only for the old mount command line: `rclone mount <remote>: <drive> ...` (mount is the FIRST
    # argument and the drive the second), so a sync, a bisync or a copy can never match.
    param([AllowNull()][AllowEmptyString()][string]$CommandLine, [string[]]$Drives = @('P:', 'Q:'))
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    foreach ($d in $Drives) {
        $pat = '^\s*(?:"[^"]*"|\S+)\s+mount\s+(?:"[^"]*"|\S+)\s+"?' + [regex]::Escape($d) + '"?(?:\s|$)'
        if ($CommandLine -match $pat) { return $true }
    }
    $false
}

function Stop-MirrorMounts {
    # Stops the rclone mount processes behind the old P: and Q: drives (a one-time cleanup of installs from
    # before the drives were removed). With --vfs-cache-mode full, rclone would otherwise keep uploading
    # whatever was still waiting in its cache. Only `rclone.exe mount <remote>: P:|Q:` is stopped.
    # Returns the PIDs it stopped (empty when none matched); throws when the process list cannot be read.
    param([string[]]$Drives = @('P:', 'Q:'))
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'rclone.exe'" -ErrorAction Stop)
    $stopped = @()
    foreach ($p in $procs) {
        if (Test-MirrorMountCommandLine -CommandLine ([string]$p.CommandLine) -Drives $Drives) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            $stopped += [int]$p.ProcessId
        }
    }
    $stopped
}

function Invoke-MirrorCleanup {
    # One-time, repeatable cleanup of what the old version (drives P:/Q:, the Explorer "Offload" menu) left
    # on this PC. Four parts, each skipped when there is nothing to do:
    #   1. stop the `rclone mount` processes (only while the PikPakMirror-Mount task exists; never during a sync)
    #   2. unregister the task PikPakMirror-Mount
    #   3. delete HKCU\<ClassesRoot>\*\shell\PikPakOffload and ...\Directory\shell\PikPakOffload
    #   4. re-register PikPakMirror-Sync with the current trigger, without -EnableSchedule (an enabled task
    #      stays enabled, a disabled one stays disabled); never creates a task that does not exist
    # Never touches WinFsp, the cache folder or anything in PikPak. -SkipSyncTask leaves part 4 to the caller.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RepoRoot,
        [ValidateNotNullOrEmpty()][string]$ClassesRoot = 'Software\Classes',
        [switch]$SkipSyncTask
    )
    $mountTask = 'PikPakMirror-Mount'
    $syncTask = 'PikPakMirror-Sync'
    # Validate before anything is touched.
    $root = $ClassesRoot.Trim('\').Trim()
    if ([string]::IsNullOrWhiteSpace($root)) { throw 'ClassesRoot must not be empty.' }
    $parts = @()

    $mountTaskExists = $false
    try { $mountTaskExists = ($null -ne (Get-ScheduledTask -TaskName $mountTask -ErrorAction SilentlyContinue)) } catch { $mountTaskExists = $false }
    $syncTaskExists = $false
    if (-not $SkipSyncTask) {
        try { $syncTaskExists = ($null -ne (Get-ScheduledTask -TaskName $syncTask -ErrorAction SilentlyContinue)) } catch { $syncTaskExists = $false }
    }

    # One sync-running answer for the drive parts and the sync-task part. Read-only; -WhatIf is switched off
    # around it so loading the CIM module prints no "Set Alias" lines.
    $syncRunning = $false
    if ($mountTaskExists -or $syncTaskExists) {
        $prevWhatIf = $WhatIfPreference
        $WhatIfPreference = $false
        try { $syncRunning = [bool](Test-SyncRunning -StateDir ([string]$Config['StateDir'])) } catch { $syncRunning = $false }
        finally { $WhatIfPreference = $prevWhatIf }
    }

    # Parts 1 and 2: the drives and their task. The task marks that this PC still has the old drives; while
    # a sync runs, or when the drives could not be stopped, both wait so the next run finds the task again.
    if (-not $mountTaskExists) {
        $parts += New-InstallStepResult -Name 'Drives' -Skipped $true -Message 'no old drive task, nothing to stop'
        $parts += New-InstallStepResult -Name 'Drive task' -Skipped $true -Message ('{0} is not registered' -f $mountTask)
    }
    elseif ($syncRunning) {
        $w = 'A sync is running, so the old drives (P: and Q:) and their task {0} were left alone; the next run of the cleanup removes them.' -f $mountTask
        $parts += New-InstallStepResult -Name 'Drives' -Skipped $true -Message 'old drives left for now' -Warning $w
        $parts += New-InstallStepResult -Name 'Drive task' -Skipped $true -Message ('{0} kept until the drives are stopped' -f $mountTask)
    }
    else {
        $drivesOk = $true
        if ($PSCmdlet.ShouldProcess('rclone mount processes for P: and Q:', 'Stop')) {
            try {
                $stopped = @(Stop-MirrorMounts)
                if ($stopped.Count -gt 0) {
                    $parts += New-InstallStepResult -Name 'Drives' -Done $true -Message ('stopped {0} rclone drive process(es) (P:, Q:), pid {1}' -f $stopped.Count, ($stopped -join ', '))
                }
                else { $parts += New-InstallStepResult -Name 'Drives' -Skipped $true -Message 'no rclone drive process was running' }
            }
            catch {
                $drivesOk = $false
                $parts += New-InstallStepResult -Name 'Drives' -Skipped $true -Message 'could not check for the old drives' -Warning ('Could not stop the old drives: {0} ({1} is kept; the next run tries again)' -f $_.Exception.Message, $mountTask)
            }
        }
        else { $parts += New-InstallStepResult -Name 'Drives' -Message 'Would stop the old rclone drive processes (P:, Q:)' }
        if (-not $drivesOk) {
            $parts += New-InstallStepResult -Name 'Drive task' -Skipped $true -Message ('{0} kept until the drives are stopped' -f $mountTask)
        }
        else {
            try {
                if ($PSCmdlet.ShouldProcess($mountTask, 'Unregister scheduled task')) {
                    Unregister-ScheduledTask -TaskName $mountTask -Confirm:$false -ErrorAction Stop
                    $parts += New-InstallStepResult -Name 'Drive task' -Done $true -Message ('removed the scheduled task {0}' -f $mountTask)
                }
                else { $parts += New-InstallStepResult -Name 'Drive task' -Message ('Would remove the scheduled task {0}' -f $mountTask) }
            }
            catch { $parts += New-InstallStepResult -Name 'Drive task' -Message ('could not remove {0}' -f $mountTask) -Warning ('Could not remove {0}: {1}' -f $mountTask, $_.Exception.Message) }
        }
    }

    # Part 3: the two Explorer menu keys. The .NET registry API takes the exact key path, so the key that is
    # literally named '*' is never treated as a wildcard. Only the PikPakOffload subkey is deleted.
    foreach ($e in @(@{ Name = 'File menu'; Sub = '*\shell\PikPakOffload' }, @{ Name = 'Folder menu'; Sub = 'Directory\shell\PikPakOffload' })) {
        $path = $root + '\' + $e.Sub
        $display = 'HKCU:\' + $path
        try {
            $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($path)
            $exists = ($null -ne $k)
            if ($exists) { $k.Close() }
            if (-not $exists) { $parts += New-InstallStepResult -Name $e.Name -Skipped $true -Message ('{0} is not there' -f $display); continue }
            if ($PSCmdlet.ShouldProcess($display, 'Delete registry key')) {
                [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($path, $false)
                $parts += New-InstallStepResult -Name $e.Name -Done $true -Message ('removed the Explorer menu entry {0}' -f $display)
            }
            else { $parts += New-InstallStepResult -Name $e.Name -Message ('Would remove the Explorer menu entry {0}' -f $display) }
        }
        catch { $parts += New-InstallStepResult -Name $e.Name -Message ('could not remove {0}' -f $display) -Warning ('Could not remove {0}: {1}' -f $display, $_.Exception.Message) }
    }

    # Part 4: the sync task gets the current trigger, only when it exists and no sync is running (never
    # re-register a task over its own running instance; the next run does it).
    if ($SkipSyncTask) {
        $parts += New-InstallStepResult -Name 'Sync task' -Skipped $true -Message 'sync task is registered by the caller'
    }
    elseif (-not $syncTaskExists) {
        $parts += New-InstallStepResult -Name 'Sync task' -Skipped $true -Message ('{0} is not set up, not creating it' -f $syncTask)
    }
    elseif ($syncRunning) {
        $w = 'A sync is running, so {0} was not re-registered; the next run of the cleanup does it.' -f $syncTask
        $parts += New-InstallStepResult -Name 'Sync task' -Skipped $true -Message ('{0} left for now' -f $syncTask) -Warning $w
    }
    else {
        try {
            $r = Register-MirrorTasks -Kind Sync -Config $Config -ConfigPath $ConfigPath -RepoRoot $RepoRoot -WhatIf:$WhatIfPreference
            if ($r.Skipped) {
                # Unchanged: the "stays enabled" hint of the installer is not news for the cleanup.
                $r = New-InstallStepResult -Name $r.Name -Skipped $true -Message ([string]$r.Message)
            }
            $parts += $r
        }
        catch { $parts += New-InstallStepResult -Name 'Sync task' -Message ('could not update {0}' -f $syncTask) -Warning ('Could not update {0}: {1}' -f $syncTask, $_.Exception.Message) }
    }
    Join-InstallStepResults -Name 'Cleanup' -Parts $parts
}
