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
