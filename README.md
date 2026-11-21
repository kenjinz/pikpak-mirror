# PikPak Sync

A Windows app that keeps folders on your PC in two-way sync with [PikPak](https://mypikpak.com). A file you add,
change or delete on one side reaches the other by itself. Some folders can be **encrypted**: PikPak then holds only
scrambled files that nobody can read without your key. It lives in the tray and only notifies you when something
needs your attention. It is built on [rclone](https://rclone.org).

## Download and run

1. Open the [latest release](../../releases/latest) and download `PikPak-Sync-v<version>-windows-x64.exe`.
2. Double-click it. That is the whole install: the file is the app.

Windows SmartScreen will say "Windows protected your PC" because the file is not code-signed. Click
**More info**, then **Run anyway**. You can check the download against the `.sha256` file on the release page.

Needs Windows 10 or 11 (with the WebView2 runtime, already there on current versions) and, for the first run,
internet. Early release: so far it has been used on one Windows 11 PC.

## Your folder list is backed up

The app saves your list of synced folders and your settings to PikPak by itself, every time you change them. On a
new PC, or after reinstalling Windows, sign in during setup and click **Restore**: your folders come back.
Encrypted folders need your recovery key, and their names stay unreadable in the backup. Your passwords and your
key are never saved. See [Recovery](docs/RECOVERY.md).

## Learn more

- [User guide](docs/README.md): folders, encryption, schedule, getting deleted files back, recovery.
- [Recovery](docs/RECOVERY.md): restoring your folders and encrypted files on a new PC.
- [Open requirements](docs/OPEN-REQUIREMENTS.md): what is not built yet.

Built with Tauri (Rust) around a PowerShell engine; GitHub Actions builds the release from a version tag.
