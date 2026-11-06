# MTZ 0.3.0-rc.2. Load core.ps1 before this file. PowerShell 5.1 / .NET 4.5+.
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.IO.Compression

function Test-MtzFullRelatedPath {
    param([string]$First, [string]$Second)
    $a = [IO.Path]::GetFullPath($First).TrimEnd([char[]]'\/')
    $b = [IO.Path]::GetFullPath($Second).TrimEnd([char[]]'\/')
    return ($a.Equals($b, [StringComparison]::OrdinalIgnoreCase) -or
        $a.StartsWith($b + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $b.StartsWith($a + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))
}

function Assert-MtzFullNoLinkPath {
    param([string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Dowiazanie w sciezce: ' + $cursor }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Write-MtzFullZipText {
    param($Archive, [string]$Name, [string]$Text, [switch]$Utf8Bom)
    $entry = $Archive.CreateEntry($Name, [IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    try {
        $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding($Utf8Bom.IsPresent)))
        try { $writer.Write($Text); $writer.Flush() } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
}

function Open-MtzFullPart {
    param($State)
    $State.Number++
    $leaf = '{0}-{1:D4}.zip' -f $State.Prefix, $State.Number
    $final = Join-Path $State.Directory $leaf
    $temporary = $final + '.building'
    $State.Stream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $State.Current = [pscustomobject]@{ Name = $leaf; TemporaryPath = $temporary; FinalPath = $final; Published = $false }
    $State.Parts.Add($State.Current)
    $State.Archive = New-Object IO.Compression.ZipArchive($State.Stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    $State.BudgetUsed = 0L
}

function Close-MtzFullPart {
    param($State)
    $archive = $State.Archive; $State.Archive = $null
    $stream = $State.Stream; $State.Stream = $null
    try { if ($null -ne $archive) { $archive.Dispose() } }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function New-MtzFullInventoryCandidate {
    param($Item, [string]$Relative)
    # This is an estimate for the progress denominator, not the capture's safety
    # or consistency check. An unavailable metadata value must not abort a job.
    $length = 0L
    try {
        if (-not ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $length = [Math]::Max(0L, [long]$Item.Length)
        }
    } catch { }
    return [pscustomobject]@{ Path = $Item.FullName; Relative = $Relative; ProgressLength = $length }
}

function Get-MtzFullInventory {
    param(
        [string]$Root,
        [string[]]$ScopeFolders,
        [string[]]$PrivateRootNames,
        [scriptblock]$ProgressCallback = $null,
        [int]$ProgressPercent = 10,
        [string]$ProgressStage = 'Zliczanie plików',
        [scriptblock]$CancellationCheck = $null
    )
    $skipped = New-Object 'Collections.Generic.List[object]'
    $excluded = New-Object 'Collections.Generic.List[string]'
    $directories = New-Object 'Collections.Generic.List[string]'
    $candidates = New-Object 'Collections.Generic.List[object]'
    $stack = New-Object 'Collections.Generic.Stack[object]'
    $candidateBytes = 0L
    Send-MtzCaptureProgress $ProgressCallback $ProgressPercent $ProgressStage 'Przeglądanie zakresu paczki; liczba plików jest jeszcze ustalana.' -Force
    foreach ($item in (Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop)) {
        Assert-MtzCaptureNotCancelled $CancellationCheck
        $name = $item.Name
        if ($item.PSIsContainer) {
            if ($scopeFolders -contains $name) { $stack.Push([pscustomobject]@{ Item = $item; Relative = $name }) }
            else { $excluded.Add($name + '/') }
        } elseif (($privateRootNames -notcontains $name.ToLowerInvariant()) -and
            (($item.Extension.ToLowerInvariant() -in @('.json', '.json5', '.toml', '.properties', '.cfg', '.conf', '.ini', '.txt', '.log')) -or $name -like 'options*' -or $name -eq 'servers.dat' -or $name -eq 'servers.dat_old')) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $skipped.Add([pscustomobject]@{ Path = $name; Reason = 'ReparsePoint'; Detail = 'Nie odczytano dowiazania.' }) }
            else {
                $candidate = New-MtzFullInventoryCandidate $item $name
                $candidates.Add($candidate); $candidateBytes += $candidate.ProgressLength
            }
        } else { $excluded.Add($name) }
        Send-MtzCaptureProgress $ProgressCallback $ProgressPercent $ProgressStage ('Znaleziono {0} plików, {1:N2} MiB.' -f $candidates.Count, ($candidateBytes / 1MB)) -TotalBytes $candidateBytes -CompletedFiles $candidates.Count
    }
    while ($stack.Count -gt 0) {
        Assert-MtzCaptureNotCancelled $CancellationCheck
        $node = $stack.Pop()
        $item = $node.Item
        $relative = $node.Relative
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $skipped.Add([pscustomobject]@{ Path = $relative; Reason = 'ReparsePoint'; Detail = 'Nie odczytano dowiazania ani jego zawartosci.' }); continue
        }
        try {
            [void](Get-MtzSafeChildPath -RootPath $root -RelativePath $relative)
            $directories.Add($relative)
            foreach ($child in $item.GetFileSystemInfos()) {
                Assert-MtzCaptureNotCancelled $CancellationCheck
                $childRelative = $relative + '/' + $child.Name
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $skipped.Add([pscustomobject]@{ Path = $childRelative; Reason = 'ReparsePoint'; Detail = 'Nie odczytano dowiazania ani jego zawartosci.' })
                } elseif ($child.Attributes -band [IO.FileAttributes]::Directory) {
                    $stack.Push([pscustomobject]@{ Item = $child; Relative = $childRelative })
                } else {
                    $candidate = New-MtzFullInventoryCandidate $child $childRelative
                    $candidates.Add($candidate); $candidateBytes += $candidate.ProgressLength
                }
            }
        } catch {
            if (Test-MtzCaptureCancelled $_.Exception) { throw }
            $skipped.Add([pscustomobject]@{ Path = $relative; Reason = 'EnumerationFailed'; Detail = $_.Exception.Message })
        }
        Send-MtzCaptureProgress $ProgressCallback $ProgressPercent $ProgressStage ('Znaleziono {0} plików, {1:N2} MiB; sprawdzono {2} folderów.' -f $candidates.Count, ($candidateBytes / 1MB), $directories.Count) -TotalBytes $candidateBytes -CompletedFiles $candidates.Count
    }
    # Filesystem enumeration order is not stable. Use ordinal relative paths so
    # file/chunk numbering is reproducible for the same selected contents.
    $ordered = New-Object 'Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($candidate in $candidates) {
        Assert-MtzCaptureNotCancelled $CancellationCheck
        $ordered.Add($candidate.Relative, $candidate)
    }
    $candidates.Clear()
    foreach ($candidate in $ordered.Values) { $candidates.Add($candidate) }
    $sortedDirectories = [string[]]$directories.ToArray()
    [Array]::Sort($sortedDirectories, [StringComparer]::Ordinal)
    $directories.Clear(); $directories.AddRange($sortedDirectories)
    $sortedExcluded = [string[]]$excluded.ToArray()
    [Array]::Sort($sortedExcluded, [StringComparer]::Ordinal)
    $excluded.Clear(); $excluded.AddRange($sortedExcluded)
    return [pscustomobject]@{ Candidates = $candidates; Directories = $directories; Excluded = $excluded; Skipped = $skipped; TotalCandidateBytes = $candidateBytes }
}

function New-MtzFullBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [DateTime]$SessionStartedUtc = [DateTime]::MinValue,
        [ValidateRange(1, 24)][int]$PartMiB = 24,
        [scriptblock]$ProgressCallback = $null,
        [scriptblock]$CancellationCheck = $null
    )
    Assert-MtzCaptureNotCancelled $CancellationCheck
    $info = Get-MtzInstanceInfo -InstancePath $InstancePath
    $root = $info.RootPath
    Assert-MtzFullNoLinkPath $root
    $output = [IO.Path]::GetFullPath($OutputDirectory)
    if (Test-MtzFullRelatedPath $root $output) { throw 'Folder wynikowy musi byc poza instancja i nie moze byc jej folderem nadrzednym.' }
    Assert-MtzFullNoLinkPath $output
    [void][IO.Directory]::CreateDirectory($output)
    $bundleId = [Guid]::NewGuid().ToString('N')
    $prefix = 'MTZ-Pelna-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + $bundleId.Substring(0, 8)
    $sessionDir = Join-Path $output $prefix
    if (Test-Path -LiteralPath $sessionDir) { throw 'Folder tej próby już istnieje. Uruchom przygotowanie paczki ponownie.' }
    [void][IO.Directory]::CreateDirectory($sessionDir)
    $diagnostic = $null
    $state = $null
    $manifestCreated = $false
    $manifestPath = Join-Path $sessionDir 'full-manifest.json'
    try {
        $diagnostic = New-MtzDiagnosticBundle -InstancePath $root -OutputDirectory $sessionDir -SessionStartedUtc $SessionStartedUtc -ProgressCallback $ProgressCallback -ProgressMaximum 10 -CancellationCheck $CancellationCheck
        $warnings = New-Object 'Collections.Generic.List[string]'
        foreach ($warning in $diagnostic.Warnings) { $warnings.Add([string]$warning) }
        $skipped = New-Object 'Collections.Generic.List[object]'
        $excluded = New-Object 'Collections.Generic.List[string]'
        $directories = New-Object 'Collections.Generic.List[string]'
        $candidates = New-Object 'Collections.Generic.List[object]'
        $files = New-Object 'Collections.Generic.List[object]'
        $scopeFolders = @('mods', 'mods.disabled', 'mods-disabled', 'disabledmods', 'disabled-mods', 'logs', 'debug', 'crash-reports', 'reports', 'config', 'defaultconfigs', 'data', 'datapacks', 'kubejs', 'scripts', 'resourcepacks', 'resources', 'shaderpacks', 'shaders', 'shadercache', 'saves', 'worlds', 'world', 'global_packs', 'global_data_packs', 'global_resource_packs', 'generated', 'backups')
        $privateRootNames = @('launcher_accounts.json', 'launcher_profiles.json', 'launcher_msa_credentials.bin', 'usercache.json', 'usernamecache.json', 'clientid.txt', 'launcher_log.txt')
        $inventoryArguments = @{ Root = $root; ScopeFolders = $scopeFolders; PrivateRootNames = $privateRootNames }
        if ($null -ne $ProgressCallback) { $inventoryArguments.ProgressCallback = $ProgressCallback }
        if ($null -ne $CancellationCheck) { $inventoryArguments.CancellationCheck = $CancellationCheck }
        $inventory = Get-MtzFullInventory @inventoryArguments
        $candidates = $inventory.Candidates
        $directories = $inventory.Directories
        $excluded = $inventory.Excluded
        foreach ($skip in $inventory.Skipped) { $skipped.Add($skip) }
        $plannedTotalBytes = [long]$inventory.TotalCandidateBytes
        $settledPlannedBytes = 0L
        $processedBytes = 0L
        Send-MtzCaptureProgress $ProgressCallback 12 'Kopiowanie i kompresja' ('Do przetworzenia: {0} plików, około {1:N2} MiB.' -f $candidates.Count, ($plannedTotalBytes / 1MB)) -TotalBytes $plannedTotalBytes -TotalFiles $candidates.Count -Force
        $state = [pscustomobject]@{
            Directory = $sessionDir; Prefix = $prefix; Number = 0; Current = $null
            Stream = $null; Archive = $null; BudgetUsed = 0L; Limit = ([long]$PartMiB * 1MB)
            Parts = (New-Object 'Collections.Generic.List[object]')
        }
        $buffer = New-Object byte[] 1048576
        $totalBytes = 0L
        $fileNumber = 0
        $restorePath = Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1'
        if (-not (Test-Path -LiteralPath $restorePath -PathType Leaf)) { throw 'Brakuje Restore-MTZ-Paczka.ps1.' }
        foreach ($candidate in $candidates) {
            Assert-MtzCaptureNotCancelled $CancellationCheck
            $fileNumber++
            $source = $null
            $hasher = $null
            $plannedLength = [long]$candidate.ProgressLength
            $processedCurrentBytes = 0L
            $outputFailed = $false
            try {
                $safe = Get-MtzSafeChildPath -RootPath $root -RelativePath $candidate.Relative
                $before = New-Object IO.FileInfo($safe)
                $expectedLength = $before.Length
                $expectedWrite = $before.LastWriteTimeUtc
                $source = New-Object IO.FileStream($safe, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                if ($source.Length -ne $expectedLength) { throw 'Plik zmienil rozmiar przed odczytem.' }
                $hasher = [Security.Cryptography.SHA256]::Create()
                $chunks = New-Object 'Collections.Generic.List[object]'
                $offset = 0L
                $chunkNumber = 0
                do {
                    Assert-MtzCaptureNotCancelled $CancellationCheck
                    $entryName = '__mtz_chunks__/file{0:D8}/chunk{1:D6}.bin' -f $fileNumber, $chunkNumber
                    $overhead = 512L + ([Text.Encoding]::UTF8.GetByteCount($entryName) * 2)
                    if ($null -eq $state.Archive -or (($state.Limit - $state.BudgetUsed) -le $overhead)) {
                        try {
                            Close-MtzFullPart $state
                            Open-MtzFullPart $state
                        } catch { $outputFailed = $true; throw }
                    }
                    $chunkLength = [Math]::Min($expectedLength - $offset, $state.Limit - $state.BudgetUsed - $overhead)
                    # Reserve the complete planned entry even if a locked/truncated source fails
                    # part way through: abandoned bytes still occupy this ZIP.
                    $state.BudgetUsed += $chunkLength + $overhead
                    try {
                        $entry = $state.Archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                        $sink = $entry.Open()
                    } catch { $outputFailed = $true; throw }
                    try {
                        $remaining = $chunkLength
                        while ($remaining -gt 0) {
                            Assert-MtzCaptureNotCancelled $CancellationCheck
                            $read = $source.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
                            if ($read -le 0) { throw 'Plik zostal skrocony podczas odczytu.' }
                            try { $sink.Write($buffer, 0, $read) }
                            catch { $outputFailed = $true; throw }
                            [void]$hasher.TransformBlock($buffer, 0, $read, $buffer, 0)
                            $remaining -= $read
                            $processedCurrentBytes += $read
                            $processedBytes += $read
                            if ($plannedTotalBytes -gt 0) {
                                $packingFraction = [Math]::Min(1.0, ($settledPlannedBytes + [Math]::Min($plannedLength, $processedCurrentBytes)) / [double]$plannedTotalBytes)
                            } else {
                                $packingFraction = ($fileNumber - 1) / [double][Math]::Max(1, $candidates.Count)
                            }
                            Send-MtzCaptureProgress $ProgressCallback (12 + 76 * $packingFraction) 'Kopiowanie i kompresja' ('Plik {0}/{1}; odczytano i skompresowano {2:N2} MiB.' -f $fileNumber, $candidates.Count, ($processedBytes / 1MB)) -CompletedBytes $processedBytes -TotalBytes $plannedTotalBytes -CompletedFiles ($fileNumber - 1) -TotalFiles $candidates.Count
                        }
                    } finally {
                        try { $sink.Dispose() }
                        catch { $outputFailed = $true; throw }
                    }
                    $chunks.Add([pscustomobject]@{ Archive = $state.Current.Name; Entry = $entryName; Offset = $offset; Length = $chunkLength })
                    $offset += $chunkLength
                    $chunkNumber++
                } while ($offset -lt $expectedLength)
                if ($source.ReadByte() -ne -1) { throw 'Plik zostal powiekszony podczas odczytu.' }
                [void]$hasher.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                $source.Dispose(); $source = $null
                [void](Get-MtzSafeChildPath -RootPath $root -RelativePath $candidate.Relative)
                $after = New-Object IO.FileInfo($safe)
                if ($after.Length -ne $expectedLength -or $after.LastWriteTimeUtc -ne $expectedWrite) { throw 'Plik zmienil sie podczas odczytu.' }
                $hash = [BitConverter]::ToString($hasher.Hash).Replace('-', '').ToLowerInvariant()
                $files.Add([pscustomobject]@{ Path = $candidate.Relative; Length = $expectedLength; Sha256 = $hash; LastWriteUtc = $expectedWrite.ToString('o'); Chunks = @($chunks.ToArray()) })
                $totalBytes += $expectedLength
            } catch {
                # An unreadable source may make an explicitly incomplete backup.
                # A canceled job or failed destination cannot produce a usable job.
                if ($outputFailed -or (Test-MtzCaptureCancelled $_.Exception)) { throw }
                $skipped.Add([pscustomobject]@{ Path = $candidate.Relative; Reason = 'ReadFailedOrChanged'; Detail = $_.Exception.Message })
            } finally {
                if ($null -ne $source) { $source.Dispose() }
                if ($null -ne $hasher) { $hasher.Dispose() }
                # A failed/skipped attempt is finished work, but its unread bytes
                # are never added to the actual processed-byte counter.
                $settledPlannedBytes += $plannedLength
                if ($plannedTotalBytes -gt 0) {
                    $packingFraction = [Math]::Min(1.0, $settledPlannedBytes / [double]$plannedTotalBytes)
                } else {
                    $packingFraction = $fileNumber / [double][Math]::Max(1, $candidates.Count)
                }
                Send-MtzCaptureProgress $ProgressCallback (12 + 76 * $packingFraction) 'Kopiowanie i kompresja' ('Przetworzono {0}/{1} plików; pominięcia: {2}.' -f $fileNumber, $candidates.Count, $skipped.Count) -CompletedBytes $processedBytes -TotalBytes $plannedTotalBytes -CompletedFiles $fileNumber -TotalFiles $candidates.Count
            }
        }
        Assert-MtzCaptureNotCancelled $CancellationCheck
        Close-MtzFullPart $state
        # Recheck the complete scope after streaming: late edits, additions and removed paths
        # must not be reported as a complete coherent capture.
        $finalInventoryArguments = @{ Root = $root; ScopeFolders = $scopeFolders; PrivateRootNames = $privateRootNames }
        if ($null -ne $CancellationCheck) { $finalInventoryArguments.CancellationCheck = $CancellationCheck }
        if ($null -ne $ProgressCallback) {
            $finalInventoryArguments.ProgressCallback = $ProgressCallback
            $finalInventoryArguments.ProgressPercent = 88
            $finalInventoryArguments.ProgressStage = 'Sprawdzanie spójności'
        }
        Send-MtzCaptureProgress $ProgressCallback 88 'Sprawdzanie spójności' 'Ponowny spis plików po kopiowaniu.' -Force
        $finalInventory = Get-MtzFullInventory @finalInventoryArguments
        $skipPaths = @{}
        foreach ($skip in $skipped) { $skipPaths[$skip.Path] = $true }
        foreach ($skip in $finalInventory.Skipped) {
            if (-not $skipPaths.ContainsKey($skip.Path)) { $skipped.Add($skip); $skipPaths[$skip.Path] = $true }
        }
        $initialPaths = @{}
        foreach ($candidate in $candidates) { $initialPaths[$candidate.Relative] = $true }
        foreach ($candidate in $finalInventory.Candidates) {
            if (-not $initialPaths.ContainsKey($candidate.Relative) -and -not $skipPaths.ContainsKey($candidate.Relative)) {
                $skipped.Add([pscustomobject]@{ Path = $candidate.Relative; Reason = 'AppearedDuringCapture'; Detail = 'Plik pojawil sie po pierwszym spisie; powtorz zbieranie po zamknieciu gry.' })
                $skipPaths[$candidate.Relative] = $true
            }
        }
        $initialDirs = @{}
        $finalDirs = @{}
        foreach ($directory in $directories) { $initialDirs[$directory] = $true }
        foreach ($directory in $finalInventory.Directories) { $finalDirs[$directory] = $true }
        foreach ($directory in @($initialDirs.Keys) + @($finalDirs.Keys)) {
            if ($initialDirs.ContainsKey($directory) -ne $finalDirs.ContainsKey($directory)) {
                if (-not $skipPaths.ContainsKey($directory)) {
                    $skipped.Add([pscustomobject]@{ Path = $directory; Reason = 'DirectoryChangedDuringCapture'; Detail = 'Folder pojawil sie albo zniknal podczas zbierania.' })
                    $skipPaths[$directory] = $true
                }
            }
        }
        $stableFiles = New-Object 'Collections.Generic.List[object]'
        $totalBytes = 0L
        $verifiedFiles = 0L
        $verifyTotal = $files.Count
        foreach ($file in $files) {
            Assert-MtzCaptureNotCancelled $CancellationCheck
            try {
                $safe = Get-MtzSafeChildPath -RootPath $root -RelativePath $file.Path
                $current = New-Object IO.FileInfo($safe)
                $capturedWrite = [DateTime]::Parse($file.LastWriteUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
                if ($current.Length -ne $file.Length -or $current.LastWriteTimeUtc -ne $capturedWrite) { throw 'Plik zmienil sie po odczytaniu.' }
                if ($skipPaths.ContainsKey($file.Path)) { continue }
                $stableFiles.Add($file)
                $totalBytes += [long]$file.Length
            } catch {
                if (-not $skipPaths.ContainsKey($file.Path)) {
                    $skipped.Add([pscustomobject]@{ Path = $file.Path; Reason = 'ChangedAfterRead'; Detail = $_.Exception.Message })
                    $skipPaths[$file.Path] = $true
                }
            } finally {
                $verifiedFiles++
                Send-MtzCaptureProgress $ProgressCallback (88 + 6 * $verifiedFiles / [double][Math]::Max(1, $verifyTotal)) 'Sprawdzanie spójności' ('Sprawdzono {0}/{1} skopiowanych plików.' -f $verifiedFiles, $verifyTotal) -CompletedFiles $verifiedFiles -TotalFiles $verifyTotal
            }
        }
        $files = $stableFiles
        if ($skipped.Count -gt 0) { $warnings.Add('Pelna paczka jest NIEKOMPLETNA: pominieto ' + $skipped.Count + ' plikow lub folderow. Szczegoly: full-manifest.json / Skipped.') }
        Send-MtzCaptureProgress $ProgressCallback 94 'Zapisywanie manifestu' 'Przygotowywanie spisu i sum kontrolnych paczki.' -CompletedFiles $verifiedFiles -TotalFiles $verifyTotal -Force
        $manifest = [ordered]@{
            Format = 'MTZ-FullBundle-1'; Version = '0.3.0-rc.2'; BundleId = $bundleId
            CreatedUtc = [DateTime]::UtcNow.ToString('o'); InstanceName = $info.DisplayName
            SessionStartedUtc = $(if ($SessionStartedUtc -ne [DateTime]::MinValue) { $SessionStartedUtc.ToUniversalTime().ToString('o') } else { $null })
            Complete = ($skipped.Count -eq 0); FileCount = $files.Count; TotalSourceBytes = $totalBytes
            ConsistencyCheck = 'Per-file streamed SHA256 and before/after metadata, then final scope inventory and file metadata revalidation; not a filesystem snapshot.'
            ScopeFolders = $scopeFolders; RootScope = 'Configuration/metadata text files, options and servers.dat; account/launcher identity files excluded.'
            ExcludedRootEntries = @($excluded.ToArray()); Directories = @($directories.ToArray())
            Files = @($files.ToArray()); Skipped = @($skipped.ToArray())
            ContentArchives = @($state.Parts | ForEach-Object { $_.Name })
            Instructions = 'Keep all ZIPs from this bundle together. Extract Restore-MTZ-Paczka.ps1 from a metadata ZIP and run it with -SourceDirectory and a NEW empty -DestinationDirectory. Raw files are not redacted; diagnostic ZIP is separate.'
        }
        Assert-MtzCaptureNotCancelled $CancellationCheck
        $json = $manifest | ConvertTo-Json -Depth 12
        $manifestStream = New-Object IO.FileStream($manifestPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $manifestCreated = $true
        try {
            $manifestWriter = New-Object IO.StreamWriter($manifestStream, (New-Object Text.UTF8Encoding($false)))
            try { $manifestWriter.Write($json); $manifestWriter.Flush() } finally { $manifestWriter.Dispose() }
        } finally { $manifestStream.Dispose() }
        $manifestInfo = New-Object IO.FileInfo($manifestPath)
        if ($manifestInfo.Length -gt 128MB) { throw 'Manifest przekracza bezpieczny limit 128 MiB. Podziel instancje na mniejsze paczki.' }
        $manifestSha = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestPartLimit = [long]$PartMiB * 1MB
        $manifestPartCount = [int][Math]::Ceiling($manifestInfo.Length / [double]$manifestPartLimit)
        $index = [ordered]@{ Format = 'MTZ-FullBundle-1'; BundleId = $bundleId; ManifestParts = $manifestPartCount; ManifestLength = $manifestInfo.Length; ManifestSha256 = $manifestSha }
        $indexText = $index | ConvertTo-Json -Compress
        $restoreText = [IO.File]::ReadAllText($restorePath)
        $manifestSource = [IO.File]::OpenRead($manifestPath)
        $manifestWrittenBytes = 0L
        Send-MtzCaptureProgress $ProgressCallback 94 'Kompresja manifestu' ('Do zapisania: {0:N2} MiB metadanych.' -f ($manifestInfo.Length / 1MB)) -TotalBytes $manifestInfo.Length -Force
        try {
            for ($m = 0; $m -lt $manifestPartCount; $m++) {
                Assert-MtzCaptureNotCancelled $CancellationCheck
                $leaf = '{0}-meta{1:D4}.zip' -f $prefix, ($m + 1)
                $final = Join-Path $sessionDir $leaf
                $temporary = $final + '.building'
                $metaStream = New-Object IO.FileStream($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                $part = [pscustomobject]@{ Name = $leaf; TemporaryPath = $temporary; FinalPath = $final; Published = $false }
                $state.Parts.Add($part)
                $metaArchive = $null
                try {
                    $metaArchive = New-Object IO.Compression.ZipArchive($metaStream, [IO.Compression.ZipArchiveMode]::Create, $true)
                    $entry = $metaArchive.CreateEntry(('__mtz_meta__/manifest.{0:D6}' -f $m), [IO.Compression.CompressionLevel]::Optimal)
                    $sink = $entry.Open()
                    try {
                        $remaining = [Math]::Min($manifestPartLimit, $manifestSource.Length - $manifestSource.Position)
                        while ($remaining -gt 0) {
                            Assert-MtzCaptureNotCancelled $CancellationCheck
                            $read = $manifestSource.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
                            if ($read -le 0) { throw 'Niepelny odczyt manifestu.' }
                            $sink.Write($buffer, 0, $read); $remaining -= $read
                            $manifestWrittenBytes += $read
                            Send-MtzCaptureProgress $ProgressCallback (94 + $manifestWrittenBytes / [double][Math]::Max(1L, $manifestInfo.Length)) 'Kompresja manifestu' ('Zapisano {0:N2}/{1:N2} MiB metadanych.' -f ($manifestWrittenBytes / 1MB), ($manifestInfo.Length / 1MB)) -CompletedBytes $manifestWrittenBytes -TotalBytes $manifestInfo.Length
                        }
                    } finally { $sink.Dispose() }
                } finally {
                    try { if ($null -ne $metaArchive) { $metaArchive.Dispose() } }
                    finally { $metaStream.Dispose() }
                }
            }
        } finally { $manifestSource.Dispose() }
        # Add only bounded metadata to each ordinary ZIP, then publish completed files atomically.
        $finalizedParts = 0L
        Send-MtzCaptureProgress $ProgressCallback 95 'Zamykanie archiwów' ('Części ZIP do ukończenia: {0}.' -f $state.Parts.Count) -TotalFiles $state.Parts.Count -Force
        foreach ($part in $state.Parts) {
            Assert-MtzCaptureNotCancelled $CancellationCheck
            $updateStream = New-Object IO.FileStream($part.TemporaryPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            $updateArchive = $null
            try {
                $updateArchive = New-Object IO.Compression.ZipArchive($updateStream, [IO.Compression.ZipArchiveMode]::Update, $true)
                Write-MtzFullZipText $updateArchive '__mtz_meta__/index.json' $indexText
                Write-MtzFullZipText $updateArchive 'Restore-MTZ-Paczka.ps1' $restoreText -Utf8Bom
            } finally {
                try { if ($null -ne $updateArchive) { $updateArchive.Dispose() } }
                finally { $updateStream.Dispose() }
            }
            if ((New-Object IO.FileInfo($part.TemporaryPath)).Length -gt 30MB) { throw 'Czesc ZIP przekroczyla limit 30 MiB.' }
            $finalizedParts++
            Send-MtzCaptureProgress $ProgressCallback (95 + 2 * $finalizedParts / [double][Math]::Max(1, $state.Parts.Count)) 'Zamykanie archiwów' ('Ukończono {0}/{1} części ZIP.' -f $finalizedParts, $state.Parts.Count) -CompletedFiles $finalizedParts -TotalFiles $state.Parts.Count
        }
        $publishedParts = 0L
        Send-MtzCaptureProgress $ProgressCallback 97 'Zapisywanie gotowych części' 'Udostępnianie zakończonych archiwów.' -TotalFiles $state.Parts.Count -Force
        foreach ($part in $state.Parts) {
            Assert-MtzCaptureNotCancelled $CancellationCheck
            [IO.File]::Move($part.TemporaryPath, $part.FinalPath)
            $part.Published = $true
            $publishedParts++
            Send-MtzCaptureProgress $ProgressCallback (97 + $publishedParts / [double][Math]::Max(1, $state.Parts.Count)) 'Zapisywanie gotowych części' ('Zapisano {0}/{1} części ZIP.' -f $publishedParts, $state.Parts.Count) -CompletedFiles $publishedParts -TotalFiles $state.Parts.Count
        }
        Assert-MtzCaptureNotCancelled $CancellationCheck
        Send-MtzCaptureProgress $ProgressCallback 98 'Archiwa zapisane' 'Końcowe sprawdzanie wyniku zbierania.' -CompletedFiles $publishedParts -TotalFiles $state.Parts.Count -Force
        Assert-MtzCaptureNotCancelled $CancellationCheck
        return [pscustomobject]@{
            ZipPath = $diagnostic.ZipPath
            ZipPaths = @($diagnostic.ZipPath) + @($state.Parts | ForEach-Object { $_.FinalPath })
            Warnings = @($warnings.ToArray()); ManifestPath = $manifestPath
            FileCount = $files.Count; TotalSourceBytes = $totalBytes; Full = $true
            Complete = ($skipped.Count -eq 0); SkippedCount = $skipped.Count; SessionDirectory = $sessionDir
        }
    } catch {
        $captureFailure = $_
        $cleanupWarnings = New-Object 'Collections.Generic.List[string]'
        foreach ($warning in @(Get-MtzCaptureCleanupWarnings $captureFailure.Exception)) { Add-MtzCaptureCleanupWarning $cleanupWarnings $warning }
        # Delete only files created by this attempt, never an existing directory
        # recursively. A failed/canceled attempt must not leave valid-looking ZIPs.
        if ($null -ne $state) {
            try { Close-MtzFullPart $state } catch { }
            foreach ($part in $state.Parts) {
                Remove-MtzOwnedCaptureFile $part.TemporaryPath $cleanupWarnings
                if ($part.Published) { Remove-MtzOwnedCaptureFile $part.FinalPath $cleanupWarnings }
            }
        }
        if ($manifestCreated) { Remove-MtzOwnedCaptureFile $manifestPath $cleanupWarnings }
        if ($null -ne $diagnostic) { Remove-MtzOwnedCaptureFile $diagnostic.ZipPath $cleanupWarnings }
        Remove-MtzOwnedCaptureDirectoryIfEmpty $sessionDir $cleanupWarnings
        if ($cleanupWarnings.Count -gt 0) { $captureFailure.Exception.Data['MtzCleanupWarnings'] = @($cleanupWarnings.ToArray()) }
        throw $captureFailure
    }
}
