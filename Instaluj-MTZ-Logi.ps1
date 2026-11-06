#Requires -Version 5.1
[CmdletBinding()]
param([switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# Check the literal file before invoking it, including direct .ps1 installation.
$launcher = Join-Path $PSScriptRoot 'Launch-MTZ.ps1'
$launcherStream = $null
try {
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw 'Brak zwyklego pliku launchera.' }
    $launcherStream = [IO.File]::Open($launcher, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    if ($launcherStream.ReadByte() -lt 0) { throw 'Plik launchera jest pusty.' }
} catch {
    $message = 'Wymagany plik jest niedostepny lub pusty: ' + $launcher + '. Paczka moze byc niekompletnie rozpakowana albo plik mogl zostac usuniety lub przeniesiony do kwarantanny przez ochrone. Sprawdz zawartosc paczki i historie ochrony. Instalacja zostala przerwana.'
    throw [IO.IOException]::new($message, $_.Exception)
} finally { if ($null -ne $launcherStream) { $launcherStream.Dispose() } }
# Both entry points use the same staged installation, backup and app lock.
& $launcher -NoLaunch:$NoLaunch
