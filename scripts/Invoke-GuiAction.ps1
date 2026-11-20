# Bridge for the desktop app: reads ONE JSON request on stdin, writes ONE JSON envelope on stdout.
#   in : {"action": "<name>", "args": { ... }, "preview": false}
#   out: {"ok": true, "data": ...}  or  {"ok": false, "error": {"code": "...", "message": "..."}}
# Secrets travel only on stdin. Nothing else is ever written to stdout: console output of everything
# called (Write-Host, warnings, -WhatIf lines) is swallowed. Always exits 0; failures are envelopes.
[CmdletBinding()]
param([string]$ConfigPath)

$ErrorActionPreference = 'Stop'
$stdout = [Console]::OpenStandardOutput()
$originalOut = [Console]::Out
$envelope = $null
$config = $null
try {
    # The console host writes Write-Host / What if: lines through Console.Out; send them nowhere.
    [Console]::SetOut([IO.TextWriter]::Null)
    . (Join-Path $PSScriptRoot 'lib\_load.ps1')
    # The app may have been started before setup installed rclone, so the PATH this process inherited can
    # lack it: rebuild PATH from the machine and user settings (Update-SessionPath, InstallSteps.ps1).
    Update-SessionPath
    if ([string]::IsNullOrEmpty($ConfigPath)) {
        $ConfigPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'config\mirror.config.psd1'
    }
    # The app sends UTF-8 (paths with diacritics), whatever the console code page is.
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
    $text = $reader.ReadToEnd()
    $request = $null
    $parsed = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($text)) { $request = $text | ConvertFrom-Json; $parsed = $true }
    }
    catch { $parsed = $false }
    $text = $null
    if (-not $parsed) {
        $envelope = @{ ok = $false; error = @{ code = 'bad-request'; message = 'The request was not valid JSON.' } }
    }
    else {
        $out = @(Invoke-GuiRequest -Request $request -ConfigPath $ConfigPath -RepoRoot (Split-Path -Path $PSScriptRoot -Parent) 3>$null 4>$null 5>$null 6>$null)
        # Defensive: keep only the envelope, even if something leaked into the output stream.
        foreach ($o in $out) { if ($o -is [hashtable] -and $o.ContainsKey('ok')) { $envelope = $o } }
        if ($null -eq $envelope) { throw 'the bridge produced no envelope' }
    }
    $request = $null
}
catch {
    $envelope = @{ ok = $false; error = @{ code = 'internal'; message = 'Something went wrong in PikPak Sync. Details are in the log.' } }
    try {
        if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath)) {
            $config = Get-MirrorConfig -Path $ConfigPath
            Write-MirrorLog -Config $config -Message ('App: bridge failed: {0}' -f $_.Exception.Message)
        }
    }
    catch { }
}
finally {
    [Console]::SetOut($originalOut)
}

try { $json = ConvertTo-Json -InputObject $envelope -Depth 8 -Compress }
catch { $json = '{"ok":false,"error":{"code":"internal","message":"Something went wrong in PikPak Sync. Details are in the log."}}' }
$bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($json + "`n")
$stdout.Write($bytes, 0, $bytes.Length)
$stdout.Flush()
exit 0
