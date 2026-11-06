# Rebuild MTZ-FullBundle-1 in a NEW empty folder, publishing only after full verification.
[CmdletBinding()]
param(
    [string]$SourceDirectory = $PSScriptRoot,
    [Parameter(Mandatory = $true)][string]$DestinationDirectory,
    [string]$BundleId,
    [switch]$AllowIncomplete
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

function Assert-MtzRestoreNoLink {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Dowiazanie w sciezce: ' + $cursor }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function ConvertTo-MtzRestoreInteger {
    param($Value, [long]$Minimum, [long]$Maximum)
    if ($null -eq $Value -or $Value -is [string] -or $Value -is [bool] -or $Value -isnot [ValueType]) { throw 'Nieprawidlowe pole liczbowe manifestu.' }
    try { $number = [decimal]$Value } catch { throw 'Nieprawidlowe pole liczbowe manifestu.' }
    if ($number -ne [decimal]::Truncate($number) -or $number -lt $Minimum -or $number -gt $Maximum) { throw 'Pole liczbowe manifestu poza zakresem.' }
    return [long]$number
}

function Get-MtzRestoreTarget {
    param([string]$Root, [string]$Relative)
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or $Relative.Contains([char]0)) { throw 'Niebezpieczna sciezka w manifeście.' }
    $parts = $Relative.Replace('\', '/').Split('/')
    foreach ($piece in $parts) {
        if ([string]::IsNullOrWhiteSpace($piece) -or $piece -eq '.' -or $piece -eq '..') { throw 'Niebezpieczna sciezka w manifeście: ' + $Relative }
        if ($piece.EndsWith(' ') -or $piece.EndsWith('.')) { throw 'Niejednoznaczna sciezka Windows: ' + $Relative }
        if ($piece -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'Zastrzezona nazwa Windows: ' + $Relative }
    }
    $result = [IO.Path]::GetFullPath((Join-Path $Root ($parts -join [IO.Path]::DirectorySeparatorChar)))
    $prefix = $Root.TrimEnd([char[]]'\/') + [IO.Path]::DirectorySeparatorChar
    if (-not $result.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Sciezka poza folderem docelowym.' }
    return $result
}

function Open-MtzRestoreZip {
    param([string]$Path)
    Assert-MtzRestoreNoLink $Path
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { return New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $false) }
    catch { $stream.Dispose(); throw }
}

function Read-MtzRestoreIndex {
    param($Archive)
    $entries = @($Archive.Entries | Where-Object { $_.FullName -eq '__mtz_meta__/index.json' })
    if ($entries.Count -eq 0) { return $null }
    if ($entries.Count -ne 1 -or $entries[0].Length -gt 65536) { throw 'Nieprawidlowy indeks paczki.' }
    $reader = New-Object IO.StreamReader($entries[0].Open(), [Text.Encoding]::UTF8)
    try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
}

$source = [IO.Path]::GetFullPath($SourceDirectory)
$destination = [IO.Path]::GetFullPath($DestinationDirectory)
if ($destination.TrimEnd([char[]]'\/') -eq [IO.Path]::GetPathRoot($destination).TrimEnd([char[]]'\/')) {
    throw 'Wybierz nowy folder docelowy, nie glowny folder dysku.'
}
$destination = $destination.TrimEnd([char[]]'\/')
Assert-MtzRestoreNoLink $source
Assert-MtzRestoreNoLink $destination
if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'Brak folderu z czesciami ZIP.' }
$destinationExisted = Test-Path -LiteralPath $destination
if ($destinationExisted) {
    if (-not (Test-Path -LiteralPath $destination -PathType Container) -or @(Get-ChildItem -LiteralPath $destination -Force).Count -ne 0) { throw 'Folder docelowy musi byc NOWY albo pusty. Nie nadpisuje istniejacych danych.' }
}
$available = New-Object 'Collections.Generic.List[object]'
foreach ($item in (Get-ChildItem -LiteralPath $source -File -Filter '*.zip' -Force)) {
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Plik ZIP nie moze byc dowiazaniem: ' + $item.Name }
    $archive = Open-MtzRestoreZip $item.FullName
    try {
        $index = Read-MtzRestoreIndex $archive
        if ($null -ne $index -and $index.Format -eq 'MTZ-FullBundle-1') { $available.Add([pscustomobject]@{ Name = $item.Name; Path = $item.FullName; Index = $index }) }
    } finally { $archive.Dispose() }
}
if ($available.Count -eq 0) { throw 'Nie znaleziono pelnej paczki MTZ. Sam ZIP diagnostyczny nie zawiera swiata ani modow.' }
$ids = @($available | ForEach-Object { $_.Index.BundleId } | Select-Object -Unique)
if ([string]::IsNullOrWhiteSpace($BundleId)) {
    if ($ids.Count -ne 1) { throw 'W folderze jest kilka paczek. Podaj -BundleId albo umiesc jedna paczke w osobnym folderze.' }
    $BundleId = $ids[0]
}
$selected = @($available | Where-Object { $_.Index.BundleId -eq $BundleId })
if ($selected.Count -eq 0) { throw 'Nie znaleziono wybranego BundleId.' }
$index = $selected[0].Index
$index.ManifestLength = ConvertTo-MtzRestoreInteger $index.ManifestLength 1 134217728
$index.ManifestParts = ConvertTo-MtzRestoreInteger $index.ManifestParts 1 128
if ($index.ManifestLength -le 0 -or $index.ManifestLength -gt 128MB -or $index.ManifestParts -lt 1 -or $index.ManifestParts -gt 128) { throw 'Nieprawidlowy rozmiar manifestu.' }
$archives = @{}
$shards = @{}
foreach ($part in $selected) {
    $part.Index.ManifestLength = ConvertTo-MtzRestoreInteger $part.Index.ManifestLength 1 134217728
    $part.Index.ManifestParts = ConvertTo-MtzRestoreInteger $part.Index.ManifestParts 1 128
    if ($archives.ContainsKey($part.Name)) { throw 'Powtorzona nazwa archiwum.' }
    if ($part.Index.ManifestSha256 -ne $index.ManifestSha256 -or $part.Index.ManifestLength -ne $index.ManifestLength -or $part.Index.ManifestParts -ne $index.ManifestParts) { throw 'Niezgodne indeksy czesci paczki.' }
    $archives[$part.Name] = $part.Path
    $archive = Open-MtzRestoreZip $part.Path
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -match '^__mtz_meta__/manifest\.([0-9]{6})$') {
                $number = [int]$Matches[1]
                if ($shards.ContainsKey($number) -or $number -ge $index.ManifestParts -or $entry.Length -gt 24MB) { throw 'Powtorzona lub nieprawidlowa czesc manifestu.' }
                $shards[$number] = [pscustomobject]@{ Archive = $part.Path; Entry = $entry.FullName; Length = $entry.Length }
            }
        }
    } finally { $archive.Dispose() }
}
if ($shards.Count -ne $index.ManifestParts) { throw 'Brakuje czesci manifestu. Umiesc WSZYSTKIE ZIP-y paczki w jednym folderze.' }
$manifestStream = New-Object IO.MemoryStream
$buffer = New-Object byte[] 1048576
try {
    for ($i = 0; $i -lt $index.ManifestParts; $i++) {
        if (-not $shards.ContainsKey($i)) { throw 'Brakuje czesci manifestu.' }
        $shard = $shards[$i]
        if ($manifestStream.Length + $shard.Length -gt $index.ManifestLength) { throw 'Przekroczony rozmiar manifestu.' }
        $archive = Open-MtzRestoreZip $shard.Archive
        try {
            $stream = $archive.GetEntry($shard.Entry).Open()
            try { $stream.CopyTo($manifestStream, $buffer.Length) } finally { $stream.Dispose() }
        } finally { $archive.Dispose() }
    }
    if ($manifestStream.Length -ne $index.ManifestLength) { throw 'Niepelny manifest.' }
    $manifestStream.Position = 0
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $actual = [BitConverter]::ToString($sha.ComputeHash($manifestStream)).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
    if ($actual -ne $index.ManifestSha256) { throw 'Suma kontrolna manifestu jest niezgodna.' }
    $manifestStream.Position = 0
    $reader = New-Object IO.StreamReader($manifestStream, [Text.Encoding]::UTF8, $true, 4096, $true)
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
} finally { $manifestStream.Dispose() }
if ($manifest.Format -ne 'MTZ-FullBundle-1' -or $manifest.BundleId -ne $BundleId) { throw 'Nieprawidlowy format manifestu.' }
if ($manifest.Complete -isnot [bool] -or $manifest.Files -isnot [array] -or
    $manifest.Directories -isnot [array] -or $manifest.ContentArchives -isnot [array]) { throw 'Nieprawidlowa struktura manifestu.' }
$declaredFiles = ConvertTo-MtzRestoreInteger $manifest.FileCount 0 ([long]::MaxValue)
$declaredBytes = ConvertTo-MtzRestoreInteger $manifest.TotalSourceBytes 0 ([long]::MaxValue)
if ($declaredFiles -ne @($manifest.Files).Count) { throw 'Liczba plikow manifestu jest niezgodna.' }
if (-not $manifest.Complete -and -not $AllowIncomplete) { throw 'Paczka jest NIEKOMPLETNA. Przejrzyj Skipped w full-manifest.json; -AllowIncomplete odtwarza tylko poprawnie zebrane pliki.' }
foreach ($leaf in $manifest.ContentArchives) {
    if ([IO.Path]::GetFileName($leaf) -ne $leaf -or -not $archives.ContainsKey($leaf)) { throw 'Brakuje czesci danych: ' + $leaf }
}
# Validate EVERY destination and chunk before creating any output file.
$targets = @{}
$validatedBytes = 0L
foreach ($directory in $manifest.Directories) {
    $target = Get-MtzRestoreTarget $destination $directory
    if ($targets.ContainsKey($target)) { throw 'Powtorzona sciezka w manifeście: ' + $directory }
    $targets[$target] = 'Directory'
}
foreach ($file in $manifest.Files) {
    $target = Get-MtzRestoreTarget $destination $file.Path
    if ($targets.ContainsKey($target)) { throw 'Powtorzona sciezka w manifeście: ' + $file.Path }
    $targets[$target] = 'File'
    $file.Length = ConvertTo-MtzRestoreInteger $file.Length 0 ([long]::MaxValue)
    if ($file.Length -gt ($declaredBytes - $validatedBytes)) { throw 'Rozmiar plikow przekracza podany rozmiar paczki.' }
    $validatedBytes += $file.Length
    # Parse timestamps before writing data, not after partially restoring a file.
    try { [void][DateTime]::Parse($file.LastWriteUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    catch { throw 'Nieprawidlowy czas pliku w manifeście: ' + $file.Path }
    $offset = 0L
    if ($file.Length -lt 0 -or $file.Sha256 -notmatch '^[0-9a-fA-F]{64}$' -or @($file.Chunks).Count -lt 1) { throw 'Nieprawidlowy rekord pliku.' }
    foreach ($chunk in $file.Chunks) {
        $chunk.Offset = ConvertTo-MtzRestoreInteger $chunk.Offset 0 ([long]::MaxValue)
        $chunk.Length = ConvertTo-MtzRestoreInteger $chunk.Length 0 25165824
        if ($chunk.Offset -ne $offset -or $chunk.Length -lt 0 -or $chunk.Length -gt 24MB -or
            [IO.Path]::GetFileName($chunk.Archive) -ne $chunk.Archive -or -not $archives.ContainsKey($chunk.Archive) -or
            $chunk.Entry -notmatch '^__mtz_chunks__/file[0-9]{8}/chunk[0-9]{6}\.bin$') { throw 'Nieprawidlowa mapa fragmentow: ' + $file.Path }
        if ($chunk.Length -gt ($file.Length - $offset)) { throw 'Fragment wykracza poza plik.' }
        $offset += [long]$chunk.Length
        if ($offset -gt $file.Length) { throw 'Fragment wykracza poza plik.' }
    }
    if ($offset -ne $file.Length) { throw 'Niepelna mapa fragmentow pliku.' }
}
if ($validatedBytes -ne $declaredBytes) { throw 'Laczny rozmiar plikow manifestu jest niezgodny.' }
foreach ($target in @($targets.Keys)) {
    $parent = [IO.Path]::GetDirectoryName($target)
    while ($parent -and -not $parent.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        if ($targets.ContainsKey($parent) -and $targets[$parent] -eq 'File') { throw 'Plik jest rodzicem innej sciezki w manifeście.' }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}
# Never expose a partially restored profile as the destination. Stage next to it
# so the final directory move stays on one filesystem; retain only verified files.
$parentDirectory = [IO.Path]::GetDirectoryName($destination)
Assert-MtzRestoreNoLink $parentDirectory
[void][IO.Directory]::CreateDirectory($parentDirectory)
$stage = Join-Path $parentDirectory ('.mtz-restore-' + [guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $stage) { throw 'Folder tymczasowy odtwarzania juz istnieje.' }
[void][IO.Directory]::CreateDirectory($stage)
$published = $false
try {
foreach ($directory in $manifest.Directories) {
    $target = Get-MtzRestoreTarget $stage $directory
    Assert-MtzRestoreNoLink $target
    [void][IO.Directory]::CreateDirectory($target)
}
$count = 0
$total = 0L
$currentArchive = $null
$currentArchiveName = ''
$currentEntries = $null
try {
foreach ($file in $manifest.Files) {
    $target = Get-MtzRestoreTarget $stage $file.Path
    Assert-MtzRestoreNoLink $target
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    $outputStream = New-Object IO.FileStream($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($chunk in $file.Chunks) {
            # Keep only the current part open. Normal capture order visits each part once;
            # index its entries once rather than reopen/rescan a ZIP for every small file.
            if ($null -eq $currentArchive -or $currentArchiveName -cne $chunk.Archive) {
                if ($null -ne $currentArchive) { $currentArchive.Dispose(); $currentArchive = $null }
                $currentArchive = Open-MtzRestoreZip $archives[$chunk.Archive]
                $currentArchiveName = $chunk.Archive
                $currentEntries = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
                foreach ($zipEntry in $currentArchive.Entries) {
                    if ($currentEntries.ContainsKey($zipEntry.FullName)) { throw 'Powtorzona nazwa wpisu w ZIP: ' + $zipEntry.FullName }
                    $currentEntries.Add($zipEntry.FullName, $zipEntry)
                }
            }
            if (-not $currentEntries.ContainsKey($chunk.Entry)) { throw 'Brak fragmentu: ' + $chunk.Entry }
            $entry = $currentEntries[$chunk.Entry]
            if ($entry.Length -ne $chunk.Length) { throw 'Zly rozmiar fragmentu: ' + $chunk.Entry }
            $stream = $entry.Open()
            try {
                $remaining = [long]$chunk.Length
                while ($remaining -gt 0) {
                    $read = $stream.Read($buffer, 0, [int][Math]::Min($remaining, $buffer.Length))
                    if ($read -le 0) { throw 'Niepelny fragment pliku.' }
                    $outputStream.Write($buffer, 0, $read)
                    [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
                    $remaining -= $read
                }
                if ($stream.ReadByte() -ne -1) { throw 'Nadmiar danych we fragmencie.' }
            } finally { $stream.Dispose() }
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $actual = [BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant()
        if ($outputStream.Length -ne $file.Length -or $actual -ne $file.Sha256) { throw 'Niezgodna suma kontrolna pliku: ' + $file.Path }
    } finally { $outputStream.Dispose(); $sha.Dispose() }
    [IO.File]::SetLastWriteTimeUtc($target, [DateTime]::Parse($file.LastWriteUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind))
    $count++
    $total += [long]$file.Length
}
} finally {
    if ($null -ne $currentArchive) { $currentArchive.Dispose() }
}
    Assert-MtzRestoreNoLink $destination
    if ($destinationExisted) {
        if (-not [IO.Directory]::Exists($destination) -or @(Get-ChildItem -LiteralPath $destination -Force).Count -ne 0) {
            throw 'Folder docelowy zmienil sie podczas odtwarzania. Nie nadpisuje jego zawartosci.'
        }
        # Non-recursive delete fails if another process added a file meanwhile.
        [IO.Directory]::Delete($destination, $false)
    } elseif (Test-Path -LiteralPath $destination) {
        throw 'Folder docelowy powstal podczas odtwarzania. Wybierz inny nowy folder.'
    }
    try { [IO.Directory]::Move($stage, $destination); $published = $true }
    catch {
        if ($destinationExisted -and -not (Test-Path -LiteralPath $destination)) { [void][IO.Directory]::CreateDirectory($destination) }
        throw
    }
} finally {
    if (-not $published -and [IO.Directory]::Exists($stage)) {
        try {
            Assert-MtzRestoreNoLink $stage
            [IO.Directory]::Delete($stage, $true)
        } catch {
            Write-Warning ('Nie udalo sie usunac folderu niedokonczonego odtwarzania: ' + $stage) -WarningAction Continue
        }
    }
}
[pscustomobject]@{ DestinationDirectory = $destination; FileCount = $count; TotalBytes = $total; Complete = [bool]$manifest.Complete; BundleId = $BundleId }
