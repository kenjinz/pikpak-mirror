# Sample configuration for PikPak Sync. Nothing here is real: the paths are examples.
#
# The app (or scripts\Install.ps1) copies this file to config\mirror.config.psd1 the first time and then
# manages that copy. config\mirror.config.psd1 is yours alone: it is listed in .gitignore and never committed.
@{
    # rclone remotes and remote roots
    Remote            = 'pikpak'
    PrivateRemote     = 'private'
    MirrorRoot        = 'PC-Mirror'
    HoldingRoot       = 'PC-Holding'

    # Local locations (%VAR% is expanded on load)
    LocalHolding      = 'D:\.pikpak-holding'
    StateDir          = '%LOCALAPPDATA%\PikPakMirror'

    # Global rclone filter file, resolved relative to this config file
    GlobalFiltersFile = 'filters.txt'

    # Retention and budgets
    HoldingDays       = 30
    MaxDeletePercent  = 10
    # FREE ACCOUNT (6 GiB storage, ~5 GB/day for apps like rclone): the values below are safe for it.
    # With Premium use DailyBudgetGB = 8 and MonthlyBudgetGB = 230 (PikPak's app limit is ~250 GB/month; 20 GB
    # margin because up to 3 files already uploading may finish past the budget).
    DailyBudgetGB     = 1
    MonthlyBudgetGB   = 30
    QuotaWarnPercent  = 90
    StaleRunDays      = 3
    LogKeepDays       = 60
    BwLimit           = '18:00,2M:off 23:00,off'

    # Scheduled sync: every SyncIntervalMinutes (15, 30, 60, 180 or 360; 0 = once a day at SyncTime, a
    # 24-hour HH:mm time). SyncAtLogon also runs it 15 min after logon.
    SyncTime            = '20:00'
    SyncIntervalMinutes = 60
    SyncAtLogon         = $true

    # Encrypted folders: entries of @{ Path = 'D:\...'; Name = '...' }.
    PrivatePaths      = @(
        # @{ Path = 'D:\Private'; Name = 'Private' }
    )

    # Synced folders. Name must be unique across pairs. Priority 1 runs first, 5 last.
    Pairs             = @(
        @{ Name = 'Documents'; Local = '%USERPROFILE%\Documents'; Remote = 'C-Users/Documents'; Priority = 3 }
        # @{ Name = 'Pictures'; Local = '%USERPROFILE%\Pictures'; Remote = 'C-Users/Pictures'; Priority = 1 }
        # @{ Name = 'Music';    Local = 'D:\Music';                Remote = 'D/Music';            Priority = 2 }
    )
}
