# Release guard: the app version must be the same in gui/src-tauri/tauri.conf.json and gui/src-tauri/Cargo.toml,
# and, when -Tag is given (a tag push), the tag must be exactly v<version>.
# Prints the version on success; exit 1 with a message on any mismatch. Works from any folder.
[CmdletBinding()]
param([string]$Tag)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$tauriDir = Join-Path $repoRoot 'gui\src-tauri'

$confVersion = [string]((Get-Content -LiteralPath (Join-Path $tauriDir 'tauri.conf.json') -Raw | ConvertFrom-Json).version)
# [package] is the first table in Cargo.toml, so the first top-level version line is the app's.
$cargoText = Get-Content -LiteralPath (Join-Path $tauriDir 'Cargo.toml') -Raw
$m = [regex]::Match($cargoText, '(?m)^version\s*=\s*"([^"]+)"')
if (-not $m.Success) { Write-Error 'No version found in gui/src-tauri/Cargo.toml.'; exit 1 }
$cargoVersion = $m.Groups[1].Value

if ($confVersion -ne $cargoVersion) {
    Write-Error ("Version mismatch: tauri.conf.json says {0} but Cargo.toml says {1}." -f $confVersion, $cargoVersion)
    exit 1
}
if ($Tag -and $Tag -ne ('v' + $confVersion)) {
    Write-Error ("Tag {0} does not match the app version {1} (expected v{1})." -f $Tag, $confVersion)
    exit 1
}
Write-Output $confVersion
exit 0
