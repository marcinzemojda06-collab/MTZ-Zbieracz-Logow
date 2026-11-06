param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'validation/release-0.3.0-rc.1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.IO.Compression
$checks = New-Object 'Collections.Generic.List[string]'
function Assert-RestoreRelease([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ('FAILED: ' + $Name) }
    $checks.Add($Name)
}
function Get-FixtureHash([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Add-FixtureEntry($Zip, [string]$Name, [byte[]]$Bytes) {
    $entry = $Zip.CreateEntry($Name, [IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    try { $stream.Write($Bytes, 0, $Bytes.Length) } finally { $stream.Dispose() }
}
function New-RestoreFixture([string]$Directory, [string]$Scenario = 'valid') {
    [void][IO.Directory]::CreateDirectory($Directory)
    $leaf = 'MTZ-Pelna-test-0001.zip'
    $first = [Text.Encoding]::UTF8.GetBytes('FIRST VERIFIED FILE')
    $second = [Text.Encoding]::UTF8.GetBytes('SECOND VERIFIED FILE')
    $entries = @('__mtz_chunks__/file00000000/chunk000000.bin', '__mtz_chunks__/file00000001/chunk000000.bin')
    $manifest = [pscustomobject]@{
        Format = 'MTZ-FullBundle-1'; BundleId = 'restore-fixture'; Complete = $true
        FileCount = 2; TotalSourceBytes = ($first.Length + $second.Length)
        ContentArchives = @($leaf); Directories = @('mods', 'config')
        Files = @(
            [pscustomobject]@{ Path = 'mods/example.jar'; Length = $first.Length; Sha256 = (Get-FixtureHash $first); LastWriteUtc = '2026-11-06T12:00:00.0000000Z'; Chunks = @([pscustomobject]@{ Archive = $leaf; Entry = $entries[0]; Offset = 0; Length = $first.Length }) },
            [pscustomobject]@{ Path = 'config/example.json'; Length = $second.Length; Sha256 = (Get-FixtureHash $second); LastWriteUtc = '2026-11-06T12:01:00.0000000Z'; Chunks = @([pscustomobject]@{ Archive = $leaf; Entry = $entries[1]; Offset = 0; Length = $second.Length }) }
        )
    }
    switch ($Scenario) {
        'bad-hash' { $second[0] = [byte][char]'X' }
        'empty' { $manifest.Files = @(); $manifest.Directories = @(); $manifest.FileCount = 0; $manifest.TotalSourceBytes = 0 }
        'single' { $manifest.Files = @($manifest.Files[0]); $manifest.Directories = @('mods'); $manifest.FileCount = 1; $manifest.TotalSourceBytes = $first.Length }
        'traversal' { $manifest.Files[1].Path = '../outside.txt' }
        'absolute-path' { $manifest.Files[1].Path = '/outside.txt' }
        'ads-path' { $manifest.Files[1].Path = 'config/example.json:secret' }
        'device-path' { $manifest.Files[1].Path = 'config/NUL.txt' }
        'trailing-dot' { $manifest.Files[1].Path = 'config/example.' }
        'bad-time' { $manifest.Files[1].LastWriteUtc = 'invalid date' }
        'bad-count' { $manifest.FileCount = 3 }
        'bad-total' { $manifest.TotalSourceBytes = $manifest.TotalSourceBytes - 1 }
        'bad-complete' { $manifest.Complete = 'true' }
        'bad-offset' { $manifest.Files[1].Chunks[0].Offset = 1 }
        'missing-chunk' { $manifest.Files[1].Chunks[0].Entry = '__mtz_chunks__/file00000099/chunk000000.bin' }
        'parent-file' { $manifest.Files[0].Path = 'config'; $manifest.Directories = @('mods') }
        'incomplete' { $manifest.Complete = $false }
    }
    $json = $manifest | ConvertTo-Json -Depth 12
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $index = [ordered]@{ Format = 'MTZ-FullBundle-1'; BundleId = $manifest.BundleId; ManifestParts = 1; ManifestLength = $bytes.Length; ManifestSha256 = (Get-FixtureHash $bytes) }
    $stream = New-Object IO.FileStream((Join-Path $Directory $leaf), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = $null
    try {
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        Add-FixtureEntry $zip '__mtz_meta__/index.json' ([Text.Encoding]::UTF8.GetBytes(($index | ConvertTo-Json)))
        Add-FixtureEntry $zip '__mtz_meta__/manifest.000000' $bytes
        Add-FixtureEntry $zip $entries[0] $first
        Add-FixtureEntry $zip $entries[1] $second
        if ($Scenario -eq 'duplicate-entry') { Add-FixtureEntry $zip $entries[1] $second }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        $stream.Dispose()
    }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('MTZ-Restore-Release-' + [guid]::NewGuid().ToString('N'))
$restoreScript = Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1'
[void][IO.Directory]::CreateDirectory($root)
try {
    $validSource = Join-Path $root 'valid-source'
    New-RestoreFixture $validSource
    $newDestination = Join-Path $root 'new-destination'
    $result = & $restoreScript -SourceDirectory $validSource -DestinationDirectory $newDestination
    Assert-RestoreRelease ($result.Complete -and $result.FileCount -eq 2) 'Valid archive publishes two verified files'
    Assert-RestoreRelease ([IO.File]::ReadAllText((Join-Path $newDestination 'mods/example.jar')) -eq 'FIRST VERIFIED FILE') 'First restored file matches source bytes'
    Assert-RestoreRelease ([IO.File]::ReadAllText((Join-Path $newDestination 'config/example.json')) -eq 'SECOND VERIFIED FILE') 'Second restored file matches source bytes'
    $emptyDestination = Join-Path $root 'empty-destination'
    [void][IO.Directory]::CreateDirectory($emptyDestination)
    $result = & $restoreScript -SourceDirectory $validSource -DestinationDirectory ($emptyDestination + [IO.Path]::DirectorySeparatorChar)
    Assert-RestoreRelease ($result.FileCount -eq 2) 'Existing empty destination and trailing separator are supported'
    foreach ($small in @('empty', 'single')) {
        $smallSource = Join-Path $root ('source-' + $small)
        New-RestoreFixture $smallSource $small
        $smallResult = & $restoreScript -SourceDirectory $smallSource -DestinationDirectory (Join-Path $root ('destination-' + $small))
        $expectedCount = 0
        if ($small -eq 'single') { $expectedCount = 1 }
        Assert-RestoreRelease ($smallResult.Complete -and $smallResult.FileCount -eq $expectedCount) ('Valid zero/single-element arrays restore correctly: ' + $small)
    }
    $existing = Join-Path $root 'nonempty'
    [void][IO.Directory]::CreateDirectory($existing)
    [IO.File]::WriteAllText((Join-Path $existing 'KEEP.txt'), 'USER DATA')
    $failed = $false
    try { & $restoreScript -SourceDirectory $validSource -DestinationDirectory $existing | Out-Null } catch { $failed = $true }
    Assert-RestoreRelease $failed 'Existing nonempty directory is rejected'
    Assert-RestoreRelease ([IO.File]::ReadAllText((Join-Path $existing 'KEEP.txt')) -eq 'USER DATA') 'Existing user data is untouched'
    foreach ($scenario in @('bad-hash', 'traversal', 'absolute-path', 'ads-path', 'device-path', 'trailing-dot', 'bad-time', 'bad-count', 'bad-total', 'bad-complete', 'bad-offset', 'missing-chunk', 'parent-file', 'duplicate-entry', 'incomplete')) {
        $source = Join-Path $root ('source-' + $scenario)
        $destination = Join-Path $root ('destination-' + $scenario)
        New-RestoreFixture $source $scenario
        $failed = $false
        try { & $restoreScript -SourceDirectory $source -DestinationDirectory $destination | Out-Null } catch { $failed = $true }
        Assert-RestoreRelease $failed ('Rejects ' + $scenario)
        Assert-RestoreRelease (-not (Test-Path -LiteralPath $destination)) ('Does not publish incomplete destination for ' + $scenario)
        Assert-RestoreRelease (@(Get-ChildItem -LiteralPath $root -Directory -Force -Filter '.mtz-restore-*').Count -eq 0) ('Temporary restore cleaned for ' + $scenario)
    }
    Assert-RestoreRelease (-not (Test-Path -LiteralPath (Join-Path $root 'outside.txt'))) 'Traversal attempt cannot create outside file'
    # The first file has already been verified when the second hash fails.
    # An existing empty destination must nevertheless remain empty.
    $failedEmpty = Join-Path $root 'failed-empty'
    [void][IO.Directory]::CreateDirectory($failedEmpty)
    $failed = $false
    try { & $restoreScript -SourceDirectory (Join-Path $root 'source-bad-hash') -DestinationDirectory $failedEmpty | Out-Null } catch { $failed = $true }
    Assert-RestoreRelease ($failed -and [IO.Directory]::Exists($failedEmpty) -and @(Get-ChildItem -LiteralPath $failedEmpty -Force).Count -eq 0) 'Failed restore preserves an existing empty destination without partial files'
    $partial = & $restoreScript -SourceDirectory (Join-Path $root 'source-incomplete') -DestinationDirectory (Join-Path $root 'partial-allowed') -AllowIncomplete
    Assert-RestoreRelease (-not $partial.Complete -and $partial.FileCount -eq 2) 'Explicit incomplete restore remains labelled incomplete'
    Assert-RestoreRelease (@(Get-ChildItem -LiteralPath $root -Directory -Force -Filter '.mtz-restore-*').Count -eq 0) 'Success leaves no staging directories'
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    [ordered]@{
        status = 'PASS'; checks = $checks.Count; checksPassed = @($checks)
        runtime = $PSVersionTable.PSVersion.ToString(); platform = [Environment]::OSVersion.Platform.ToString()
        actualWindowsRun = $false; realFilesystem = $true; realZip = $true
        scope = 'Real ZIP/manifest/hash validation and filesystem publication; no Windows-specific runtime claims.'
        restoreSha256 = (Get-FileHash $restoreScript -Algorithm SHA256).Hash.ToLowerInvariant()
    } | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'launch-restore-results.json') -Encoding utf8
    Write-Output ('PASS: ' + $checks.Count + ' restore checks; real ZIP/filesystem; actualWindows=false')
} finally {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
