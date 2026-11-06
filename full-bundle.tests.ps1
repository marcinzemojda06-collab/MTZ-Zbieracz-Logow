# Portable integration tests; run with powershell.exe or pwsh -NoProfile -File .\full-bundle.tests.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'core.ps1')
. (Join-Path $PSScriptRoot 'full-bundle.ps1')
$script:checks = 0
function Assert-MtzFullTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw 'TEST FAILED: ' + $Message }
    $script:checks++
}
function Write-MtzFullTestFile {
    param([string]$Root, [string]$Relative, [byte[]]$Bytes)
    $path = Join-Path $Root $Relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllBytes($path, $Bytes)
}
function Assert-MtzFullThrows {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-MtzFullTest $threw $Message
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mtz-full-tests-' + [Guid]::NewGuid().ToString('N'))
$instance = Join-Path $testRoot 'instance'
$output = Join-Path $testRoot 'bundles'
$destination = Join-Path $testRoot 'restored'
[void][IO.Directory]::CreateDirectory($instance)
try {
    $sample = [Text.Encoding]::UTF8.GetBytes('Raw bytes must remain exact. accessToken=not-a-real-token 127.0.0.1')
    $paths = @(
        'logs/latest.log', 'logs/debug.log', 'debug/report.txt', 'crash-reports/crash-test.txt',
        'config/test.toml', 'defaultconfigs/test.json', 'data/test.bin', 'datapacks/test.zip',
        'kubejs/server_scripts/test.js', 'scripts/test.zs', 'resourcepacks/texture.zip',
        'resources/custom.bin', 'shaderpacks/shader.zip', 'shadercache/test.bin',
        'saves/main/DIM-1/region/r.0.0.mca', 'saves/main/DIM1/region/r.0.0.mca',
        'saves/main/dimensions/custom/deep/region/r.0.0.mca', 'saves/main/datapacks/world-pack.zip',
        'worlds/other/level.dat', 'world/level.dat', 'mods.disabled/inactive.jar', 'mods/small.jar.disabled',
        'options.txt', 'minecraftinstance.json'
    )
    foreach ($relative in $paths) { Write-MtzFullTestFile $instance $relative $sample }
    $unicodePath = 'saves/' + [char]0x015A + 'wiat/' + [char]0x017C + [char]0x00F3 + [char]0x0142 + 'w.dat'
    Write-MtzFullTestFile $instance $unicodePath ([byte[]]@(0, 255, 127, 128, 1))
    Write-MtzFullTestFile $instance 'mods/empty.jar.disabled' (New-Object byte[] 0)
    [void][IO.Directory]::CreateDirectory((Join-Path $instance 'saves/main/empty-directory'))
    # Incompressible file crosses several independent ZIPs and requires chunk reassembly.
    $large = New-Object byte[] (3MB + 12345)
    $random = New-Object Random(719)
    $random.NextBytes($large)
    Write-MtzFullTestFile $instance 'mods/large.jar' $large
    $large = $null
    Write-MtzFullTestFile $instance 'launcher_accounts.json' ([Text.Encoding]::UTF8.GetBytes('excluded account credentials'))
    $result = New-MtzFullBundle -InstancePath $instance -OutputDirectory $output -PartMiB 1
    Assert-MtzFullTest $result.Full 'Full flag'
    Assert-MtzFullTest $result.Complete 'No files skipped in regular instance'
    Assert-MtzFullTest ($result.SkippedCount -eq 0) 'Zero skipped count'
    Assert-MtzFullTest ($result.ZipPaths[0] -eq $result.ZipPath) 'Diagnostic archive first'
    Assert-MtzFullTest ($result.ZipPaths.Count -ge 6) 'Multiple ordinary ZIP parts'
    $manifest = [IO.File]::ReadAllText($result.ManifestPath) | ConvertFrom-Json
    Assert-MtzFullTest ($manifest.FileCount -eq ($paths.Count + 3)) 'Every scoped file inventoried'
    Assert-MtzFullTest ($manifest.ExcludedRootEntries -contains 'launcher_accounts.json') 'Excluded account file declared'
    Assert-MtzFullTest (@($manifest.Files | Where-Object { $_.Path -eq 'mods/large.jar' })[0].Chunks.Count -ge 4) 'Large file chunked'
    Assert-MtzFullTest (@($manifest.Files | Where-Object { $_.Path -eq 'mods.disabled/inactive.jar' }).Count -eq 1) 'Disabled mods folder captured'
    foreach ($zipPath in $result.ZipPaths) {
        Assert-MtzFullTest ((New-Object IO.FileInfo($zipPath)).Length -lt 30MB) 'Every ZIP below bridge limit'
        $stream = [IO.File]::OpenRead($zipPath)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            Assert-MtzFullTest ($zip.Entries.Count -gt 0) 'Each part opens as an independent ZIP'
            if ($zipPath -ne $result.ZipPath) {
                $restoreEntry = $zip.GetEntry('Restore-MTZ-Paczka.ps1')
                Assert-MtzFullTest ($null -ne $restoreEntry) 'Restore script in every full part'
                $restoreStream = $restoreEntry.Open()
                try {
                    $bom = New-Object byte[] 3
                    $readBom = $restoreStream.Read($bom, 0, 3)
                    Assert-MtzFullTest ($readBom -eq 3 -and $bom[0] -eq 239 -and $bom[1] -eq 187 -and $bom[2] -eq 191) 'ZIP-embedded restore script retains UTF8 BOM for Windows PowerShell'
                } finally { $restoreStream.Dispose() }
            }
        } finally { $zip.Dispose(); $stream.Dispose() }
    }
    $restore = & (Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1') -SourceDirectory $result.SessionDirectory -DestinationDirectory $destination
    Assert-MtzFullTest ($restore.FileCount -eq $manifest.FileCount) 'Restore file count'
    Assert-MtzFullTest ($restore.TotalBytes -eq $manifest.TotalSourceBytes) 'Restore byte count'
    foreach ($file in $manifest.Files) {
        $original = Join-Path $instance $file.Path
        $restored = Join-Path $destination $file.Path
        Assert-MtzFullTest (Test-Path -LiteralPath $restored -PathType Leaf) ('Restored ' + $file.Path)
        Assert-MtzFullTest ((Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $restored -Algorithm SHA256).Hash) ('Exact byte hash ' + $file.Path)
    }
    Assert-MtzFullTest (Test-Path -LiteralPath (Join-Path $destination 'saves/main/empty-directory') -PathType Container) 'Empty directory restored'
    Assert-MtzFullThrows { & (Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1') -SourceDirectory $result.SessionDirectory -DestinationDirectory $destination } 'Nonempty destination rejected'
    Assert-MtzFullThrows { New-MtzFullBundle -InstancePath $instance -OutputDirectory (Join-Path $instance 'bundles') } 'Recursive output rejected'
    Assert-MtzFullThrows { New-MtzFullBundle -InstancePath $instance -OutputDirectory $testRoot } 'Ancestor output rejected'
    $firstPart = $result.ZipPaths[1]
    [IO.File]::Move($firstPart, $firstPart + '.missing')
    try {
        Assert-MtzFullThrows { & (Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1') -SourceDirectory $result.SessionDirectory -DestinationDirectory (Join-Path $testRoot 'missing-part') } 'Missing content part rejected'
        Assert-MtzFullTest (-not (Test-Path -LiteralPath (Join-Path $testRoot 'missing-part'))) 'No output files before missing-part validation'
    } finally { [IO.File]::Move($firstPart + '.missing', $firstPart) }
    # An exclusively locked source must be visible in the incomplete manifest.
    $lockedPath = Join-Path $instance 'config/locked.toml'
    [IO.File]::WriteAllText($lockedPath, 'locked source')
    $lock = New-Object IO.FileStream($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { $incomplete = New-MtzFullBundle -InstancePath $instance -OutputDirectory $output -PartMiB 1 } finally { $lock.Dispose() }
    $incompleteManifest = [IO.File]::ReadAllText($incomplete.ManifestPath) | ConvertFrom-Json
    Assert-MtzFullTest (-not $incomplete.Complete) 'Locked file makes capture incomplete'
    Assert-MtzFullTest (@($incompleteManifest.Skipped | Where-Object { $_.Path -eq 'config/locked.toml' }).Count -eq 1) 'Locked file skip explicit'
    Assert-MtzFullThrows { & (Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1') -SourceDirectory $incomplete.SessionDirectory -DestinationDirectory (Join-Path $testRoot 'incomplete-refused') } 'Incomplete restore needs explicit opt-in'
    $partialRestore = & (Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1') -SourceDirectory $incomplete.SessionDirectory -DestinationDirectory (Join-Path $testRoot 'incomplete-allowed') -AllowIncomplete
    Assert-MtzFullTest (-not $partialRestore.Complete) 'Explicit incomplete restore remains labelled incomplete'
    # Creating symlinks can require privileges on Windows; where available verify no following.
    $outside = Join-Path $testRoot 'outside-secret.txt'
    [IO.File]::WriteAllText($outside, 'outside instance must never be collected')
    $link = Join-Path $instance 'config/outside-link.txt'
    $linkCreated = $false
    try { New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop | Out-Null; $linkCreated = $true } catch { Write-Host 'SKIP symlink fixture: OS permission unavailable.' }
    if ($linkCreated) {
        $linked = New-MtzFullBundle -InstancePath $instance -OutputDirectory $output -PartMiB 1
        $linkedManifest = [IO.File]::ReadAllText($linked.ManifestPath) | ConvertFrom-Json
        Assert-MtzFullTest (-not $linked.Complete) 'Reparse point makes completeness explicit'
        Assert-MtzFullTest (@($linkedManifest.Skipped | Where-Object { $_.Path -eq 'config/outside-link.txt' -and $_.Reason -eq 'ReparsePoint' }).Count -eq 1) 'Reparse point explicit in manifest'
        Assert-MtzFullTest (@($linkedManifest.Files | Where-Object { $_.Path -eq 'config/outside-link.txt' }).Count -eq 0) 'No outside bytes collected'
    }
    # Inject actual filesystem edits at the boundary between streaming and final validation.
    # This is deterministic and verifies the saved manifest/restore behavior of a changing instance.
    $lateInstance = Join-Path $testRoot 'late-instance'
    foreach ($relative in @('mods/already-read.jar', 'data/deleted.bin', 'logs/latest.log', 'logs/debug.log')) {
        Write-MtzFullTestFile $lateInstance $relative ([Text.Encoding]::UTF8.GetBytes('ORIGINAL_BYTES'))
    }
    [void][IO.Directory]::CreateDirectory((Join-Path $lateInstance 'data/removed-empty'))
    $script:MtzTestInventoryOriginal = (Get-Command Get-MtzFullInventory).ScriptBlock
    $script:MtzTestInventoryCalls = 0
    function Get-MtzFullInventory {
        param([string]$Root, [string[]]$ScopeFolders, [string[]]$PrivateRootNames)
        $script:MtzTestInventoryCalls++
        if ($script:MtzTestInventoryCalls -eq 2) {
            [IO.File]::WriteAllText((Join-Path $Root 'mods/already-read.jar'), 'MODIFIED_BYTES')
            [IO.File]::SetLastWriteTimeUtc((Join-Path $Root 'mods/already-read.jar'), [DateTime]::UtcNow.AddSeconds(3))
            [IO.File]::Delete((Join-Path $Root 'data/deleted.bin'))
            [IO.File]::WriteAllText((Join-Path $Root 'data/new-file.bin'), 'NEW')
            [void][IO.Directory]::CreateDirectory((Join-Path $Root 'data/new-empty'))
            [IO.Directory]::Delete((Join-Path $Root 'data/removed-empty'))
        }
        return (& $script:MtzTestInventoryOriginal -Root $Root -ScopeFolders $ScopeFolders -PrivateRootNames $PrivateRootNames)
    }
    try { $late = New-MtzFullBundle -InstancePath $lateInstance -OutputDirectory $output -PartMiB 1 }
    finally { Set-Item -Path Function:Get-MtzFullInventory -Value $script:MtzTestInventoryOriginal }
    $lateManifest = [IO.File]::ReadAllText($late.ManifestPath) | ConvertFrom-Json
    Assert-MtzFullTest (-not $late.Complete -and -not $lateManifest.Complete) 'Post-read changes make both result and manifest incomplete'
    foreach ($changed in @('mods/already-read.jar', 'data/deleted.bin')) {
        Assert-MtzFullTest (@($lateManifest.Skipped | Where-Object { $_.Path -eq $changed -and $_.Reason -eq 'ChangedAfterRead' }).Count -eq 1) ('Late change explicitly recorded: ' + $changed)
    }
    Assert-MtzFullTest (@($lateManifest.Skipped | Where-Object { $_.Path -eq 'data/new-file.bin' -and $_.Reason -eq 'AppearedDuringCapture' }).Count -eq 1) 'Late new scoped file explicitly recorded'
    foreach ($changed in @('data/new-empty', 'data/removed-empty')) {
        Assert-MtzFullTest (@($lateManifest.Skipped | Where-Object { $_.Path -eq $changed -and $_.Reason -eq 'DirectoryChangedDuringCapture' }).Count -eq 1) ('Late directory change explicitly recorded: ' + $changed)
    }
    Assert-MtzFullTest ($late.FileCount -eq 2 -and $late.TotalSourceBytes -eq 28) 'Only stable file records contribute final counts and bytes'
    Assert-MtzFullTest (@($lateManifest.Files | Where-Object { $_.Path -in @('mods/already-read.jar', 'data/deleted.bin', 'data/new-file.bin') }).Count -eq 0) 'Unstable and uncollected files absent from valid records'
    $lateRestored = & (Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1') -SourceDirectory $late.SessionDirectory -DestinationDirectory (Join-Path $testRoot 'late-restored') -AllowIncomplete
    Assert-MtzFullTest (-not $lateRestored.Complete -and $lateRestored.FileCount -eq 2) 'Late-change incomplete restore recovers stable files only'
    # Force EOF after writing 20 MiB of an expected 25 MiB file. Its abandoned entry
    # must consume the ZIP budget before a following 26 MiB incompressible file.
    $partialInstance = Join-Path $testRoot 'partial-instance'
    Write-MtzFullTestFile $partialInstance 'logs/latest.log' ([Text.Encoding]::UTF8.GetBytes('fixture log'))
    $script:MtzTestFailedSource = Join-Path $partialInstance 'mods/first-truncated.jar'
    $random = New-Object Random(819)
    $randomBytes = New-Object byte[] (25MB)
    $random.NextBytes($randomBytes)
    Write-MtzFullTestFile $partialInstance 'mods/first-truncated.jar' $randomBytes
    $randomBytes = New-Object byte[] (26MB)
    $random.NextBytes($randomBytes)
    Write-MtzFullTestFile $partialInstance 'mods/second-valid.jar' $randomBytes
    $randomBytes = $null
    $expectedPartialHash = (Get-FileHash -LiteralPath (Join-Path $partialInstance 'mods/second-valid.jar') -Algorithm SHA256).Hash
    $script:MtzTestInventoryOriginal = (Get-Command Get-MtzFullInventory).ScriptBlock
    $script:MtzTestOpenOriginal = (Get-Command Open-MtzFullPart).ScriptBlock
    $script:MtzTestTruncated = $false
    function Get-MtzFullInventory {
        param([string]$Root, [string[]]$ScopeFolders, [string[]]$PrivateRootNames)
        $inventory = & $script:MtzTestInventoryOriginal -Root $Root -ScopeFolders $ScopeFolders -PrivateRootNames $PrivateRootNames
        $ordered = New-Object 'Collections.Generic.List[object]'
        foreach ($candidate in $inventory.Candidates) { if ($candidate.Relative -eq 'mods/first-truncated.jar') { $ordered.Add($candidate) } }
        foreach ($candidate in $inventory.Candidates) { if ($candidate.Relative -ne 'mods/first-truncated.jar') { $ordered.Add($candidate) } }
        $inventory.Candidates = $ordered
        return $inventory
    }
    function Open-MtzFullPart {
        param($State)
        & $script:MtzTestOpenOriginal $State
        if (-not $script:MtzTestTruncated) {
            $truncateStream = New-Object IO.FileStream($script:MtzTestFailedSource, [IO.FileMode]::Open, [IO.FileAccess]::Write, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            try { $truncateStream.SetLength(20MB) } finally { $truncateStream.Dispose() }
            $script:MtzTestTruncated = $true
        }
    }
    try { $partial = New-MtzFullBundle -InstancePath $partialInstance -OutputDirectory $output -PartMiB 24 }
    finally {
        Set-Item -Path Function:Get-MtzFullInventory -Value $script:MtzTestInventoryOriginal
        Set-Item -Path Function:Open-MtzFullPart -Value $script:MtzTestOpenOriginal
    }
    $partialManifest = [IO.File]::ReadAllText($partial.ManifestPath) | ConvertFrom-Json
    Assert-MtzFullTest ($script:MtzTestTruncated -and -not $partial.Complete) 'Mid-entry EOF produces reviewable incomplete bundle'
    Assert-MtzFullTest (@($partialManifest.Skipped | Where-Object { $_.Path -eq 'mods/first-truncated.jar' -and $_.Reason -eq 'ReadFailedOrChanged' }).Count -eq 1) 'Mid-entry EOF explicitly reported'
    Assert-MtzFullTest (@($partialManifest.Files | Where-Object { $_.Path -eq 'mods/first-truncated.jar' }).Count -eq 0) 'Partial entry excluded from recoverable file records'
    $foundAbandonedBytes = $false
    foreach ($zipPath in $partial.ZipPaths) {
        Assert-MtzFullTest ((New-Object IO.FileInfo($zipPath)).Length -le 30MB) 'Failed partial entry cannot overfill a bridge ZIP'
        $stream = [IO.File]::OpenRead($zipPath)
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName -like '__mtz_chunks__/file00000001/*' -and $entry.Length -eq 20MB) { $foundAbandonedBytes = $true }
            }
        } finally { $archive.Dispose(); $stream.Dispose() }
    }
    Assert-MtzFullTest $foundAbandonedBytes 'Physical abandoned 20 MiB entry exercises failure-budget accounting'
    $partialDestination = Join-Path $testRoot 'partial-restored'
    $partialRecovered = & (Join-Path $PSScriptRoot 'Restore-MTZ-Paczka.ps1') -SourceDirectory $partial.SessionDirectory -DestinationDirectory $partialDestination -AllowIncomplete
    Assert-MtzFullTest (-not $partialRecovered.Complete -and $partialRecovered.FileCount -eq 2) 'Following valid file survives failed partial entry'
    Assert-MtzFullTest ((Get-FileHash -LiteralPath (Join-Path $partialDestination 'mods/second-valid.jar') -Algorithm SHA256).Hash -eq $expectedPartialHash) 'Following 26 MiB JAR exact byte restoration after failed partial source'
    Write-Host ('PASS full-bundle integration: ' + $script:checks + ' assertions')
} finally {
    # Remove links themselves before recursive cleanup to avoid host-specific link recursion.
    $linkPath = Join-Path $instance 'config/outside-link.txt'
    if (Test-Path -LiteralPath $linkPath) {
        $linkItem = Get-Item -LiteralPath $linkPath -Force
        if ($linkItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-Item -LiteralPath $linkPath -Force }
    }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
