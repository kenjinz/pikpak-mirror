# rclone filter rule generation. Windows PowerShell 5.1 compatible. Requires Config.ps1 (ConvertTo-PrefixKey).

function ConvertTo-RcloneFilterPath {
    # Relative Windows path -> rclone filter path: forward slashes, leading '/', glob metacharacters escaped.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RelativePath)

    $p = $RelativePath.Replace('\', '/').Trim('/')
    $p = [regex]::Replace($p, '([\[\]{}*?])', '\$1')
    '/' + $p
}

function New-PairFilterRules {
    # A '- <path>/**' exclude for each private path nested under the pair's local folder FIRST (rclone
    # applies the first matching rule, so no global '+' rule can re-include private data), then the
    # global rules (blank lines and '#' comments skipped).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [Parameter(Mandatory)][hashtable]$Pair,
        [Parameter(Mandatory)][string]$GlobalRulesPath
    )

    $rules = New-Object System.Collections.Generic.List[string]
    $pairKey = ConvertTo-PrefixKey $Pair.Local
    foreach ($priv in @($Config['PrivatePaths']) | Where-Object { $_ }) {
        $privKey = ConvertTo-PrefixKey $priv.Path
        # Strictly under the pair; equal paths are rejected by Test-MirrorConfig, not handled here.
        if ($privKey.Length -gt $pairKey.Length -and $privKey.StartsWith($pairKey)) {
            $rel = $priv.Path.TrimEnd('\').Substring($pairKey.Length)
            $rules.Add('- ' + (ConvertTo-RcloneFilterPath -RelativePath $rel) + '/**')
        }
    }
    foreach ($t in @(Get-GlobalFilterRules -GlobalRulesPath $GlobalRulesPath)) { $rules.Add($t) }
    # Emitted unrolled; callers wrap in @() to get a (possibly empty) array.
    $rules.ToArray()
}

function Get-GlobalFilterRules {
    # The global rules file without blank lines and '#' comments, each line trimmed. Emitted unrolled.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$GlobalRulesPath)
    foreach ($line in [IO.File]::ReadAllLines($GlobalRulesPath)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $t
    }
}

function Get-TextHash {
    # SHA256 (lowercase hex) of the lines joined with LF, UTF-8 encoded.
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines)

    $bytes = [Text.Encoding]::UTF8.GetBytes(($Lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
    (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
}
