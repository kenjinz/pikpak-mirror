**PikPak Sync** keeps folders on your Windows PC in two-way sync with PikPak. Some folders can be encrypted, so PikPak holds only scrambled files. It runs in the tray and syncs by itself.

## Run it

Download the `.exe` below and double-click it. There is nothing to install and no folder to keep next to it. The first-run screen sets the rest up for you.

Early release: so far it has been used on one Windows 11 PC.

## Good to know

- **Windows SmartScreen will warn** ("Windows protected your PC") because the file is not code-signed. Click **More info**, then **Run anyway**.
- It needs the **Microsoft WebView2 runtime**. Windows 11 and current Windows 10 already have it.
- The first run needs **internet**: setup downloads rclone (a pinned version, checked against its SHA-256).
- Where it keeps things: the app's scripts in `%LOCALAPPDATA%\PikPakSync` (your settings are in `config` there and are never overwritten by an update), and logs and sync state in `%LOCALAPPDATA%\PikPakMirror`.
- Keep the `.exe` somewhere permanent (not Downloads) if you turn on "Start PikPak Sync when I sign in to Windows": Windows starts that exact file.
- To update, quit PikPak Sync from the tray icon, then run the new `.exe`. Your settings stay, and an older `.exe` never replaces a newer one's scripts.

## Check your download

Compare the file's hash with the `.sha256` file from this page:

```powershell
(Get-FileHash .\PikPak-Sync-*-windows-x64.exe -Algorithm SHA256).Hash
```
