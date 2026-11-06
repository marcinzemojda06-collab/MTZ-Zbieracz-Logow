#Requires -Version 5.1
[CmdletBinding()]
param([string]$PowerShellExecutable = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $sourceRoot 'core.ps1')
. (Join-Path $sourceRoot 'full-bundle.ps1')
$script:releaseChecks = 0
$script:releaseResults = New-Object 'Collections.Generic.List[object]'
$script:releaseCancel = $false
$script:releaseEvents = New-Object 'Collections.Generic.List[object]'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mtz-release-core-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) {
    foreach ($leaf in @('pwsh', 'pwsh.exe', 'powershell.exe')) {
        $candidate = Join-Path $PSHOME $leaf
        if ([IO.File]::Exists($candidate)) { $PowerShellExecutable = $candidate; break }
    }
    if ([string]::IsNullOrWhiteSpace($PowerShellExecutable)) { throw 'Pass -PowerShellExecutable for this runtime.' }
}
function Assert-Release {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('TEST FAILED: ' + $Message) }
    $script:releaseChecks++
}
function Invoke-ReleaseTest {
    param([string]$Name, [scriptblock]$Action)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Action | Out-Null
        $script:releaseResults.Add([pscustomobject]@{ Name = $Name; Passed = $true; Error = ''; Seconds = $watch.Elapsed.TotalSeconds })
        Write-Host ('PASS ' + $Name)
    } catch {
        $script:releaseResults.Add([pscustomobject]@{ Name = $Name; Passed = $false; Error = $_.Exception.Message; Seconds = $watch.Elapsed.TotalSeconds })
        Write-Host ('FAIL ' + $Name + ': ' + $_.Exception.Message)
    }
}
function Write-ReleaseText {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function New-ReleaseFixture {
    param([string]$Name, [switch]$LongLog)
    $instance = Join-Path $testRoot ($Name + '/instance')
    $output = Join-Path $testRoot ($Name + '/output')
    [void][IO.Directory]::CreateDirectory((Join-Path $instance 'mods'))
    [void][IO.Directory]::CreateDirectory($output)
    $log = "Setting user: TestPlayer`nNeoForge version 21.1.236`nRealMod.java:42 ERROR example diagnostic`n"
    if ($LongLog) { $log += ("large diagnostic example line`n" * 150000) }
    Write-ReleaseText (Join-Path $instance 'logs/latest.log') $log
    $bytes = New-Object byte[] (3MB + 137)
    (New-Object Random(7291)).NextBytes($bytes)
    [IO.File]::WriteAllBytes((Join-Path $instance 'mods/sample.jar'), $bytes)
    Write-ReleaseText (Join-Path $output 'earlier-package.zip') 'KEEP_EARLIER_PACKAGE'
    return [pscustomobject]@{ Instance = $instance; Output = $output; Previous = (Join-Path $output 'earlier-package.zip') }
}
function Assert-OnlyEarlierPackage {
    param($Fixture)
    $entries = @(Get-ChildItem -LiteralPath $Fixture.Output -Force)
    Assert-Release ($entries.Count -eq 1 -and $entries[0].Name -eq 'earlier-package.zip') 'Failed/canceled attempt left an archive or a work directory.'
    Assert-Release ([IO.File]::ReadAllText($Fixture.Previous) -ceq 'KEEP_EARLIER_PACKAGE') 'Earlier package was changed.'
}
function Expect-ReleaseCancellation {
    param([scriptblock]$Action)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception }
    Assert-Release ($null -ne $caught -and (Test-MtzCaptureCancelled $caught)) 'Capture did not propagate a cancellation exception.'
}
function Read-ReleaseZipText {
    param([string]$Path, [string]$EntryName)
    $stream = [IO.File]::OpenRead($Path)
    $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
    try {
        $entry = $archive.GetEntry($EntryName)
        Assert-Release ($null -ne $entry) ('Required entry missing: ' + $EntryName)
        $reader = New-Object IO.StreamReader($entry.Open(), (New-Object Text.UTF8Encoding($false)))
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $archive.Dispose(); $stream.Dispose() }
}
function Invoke-ReleaseWorker {
    param($Fixture, [string]$Mode, [switch]$PreCanceled)
    $job = Join-Path $testRoot ('job-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($job)
    $requestPath = Join-Path $job 'request.json'
    $request = [ordered]@{ InstancePath = $Fixture.Instance; OutputDirectory = $Fixture.Output; SessionStartedUtc = [DateTime]::UtcNow.ToString('o'); Mode = $Mode; PartMiB = 1 }
    Write-ReleaseText $requestPath ($request | ConvertTo-Json)
    if ($PreCanceled) { Write-ReleaseText (Join-Path $job 'cancel.request') 'cancel' }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $PowerShellExecutable
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $sourceRoot 'Collect-Worker.ps1') + '" -RequestPath "' + $requestPath + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'Worker did not complete within 30 seconds.' }
        $errorText = $process.StandardError.ReadToEnd()
        $standardText = $process.StandardOutput.ReadToEnd()
        $resultPath = Join-Path $job 'result.json'
        Assert-Release ([IO.File]::Exists($resultPath)) ('Worker did not write a result: ' + $errorText + $standardText)
        $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
        $progress = [IO.File]::ReadAllText((Join-Path $job 'progress.json')) | ConvertFrom-Json
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Result = $result; Progress = $progress }
    } finally { $process.Dispose() }
}
try {
    Invoke-ReleaseTest 'Windows profile names with spaces and escaped JSON paths are redacted' {
        $text = 'C:\Users\Private Person\game\latest.log' + "`n" +
            '{"path":"C:\\Users\\Private Person\\game\\latest.log"}' + "`n" +
            '{"path":"D:\\Custom\\Selected Instance\\mods\\demo.jar"}'
        $safe = Protect-MtzDiagnosticText -Text $text -InstancePath 'D:\Custom\Selected Instance'
        Assert-Release (-not $safe.Contains('Private Person')) 'Windows account name with spaces survived.'
        Assert-Release (-not $safe.Contains('Selected Instance')) 'JSON escaped selected instance path survived.'
        Assert-Release ($safe.Contains('latest.log') -and $safe.Contains('demo.jar')) 'Useful relative filenames were removed.'
    }
    Invoke-ReleaseTest 'Raw and JSON authentication headers redact non-Bearer schemes' {
        $text = "Authorization: token TEST_AUTH_PRIVATE`nProxy-Authorization: Digest TEST_PROXY_PRIVATE`nX-Auth-Token: TEST_X_PRIVATE`n" +
            '{"Authorization":"Token TEST_JSON_AUTH_PRIVATE","Cookie":"sid=TEST_JSON_COOKIE_PRIVATE","message":"RealMod.java:42"}'
        $safe = Protect-MtzDiagnosticText -Text $text
        foreach ($secret in @('TEST_AUTH_PRIVATE', 'TEST_PROXY_PRIVATE', 'TEST_X_PRIVATE', 'TEST_JSON_AUTH_PRIVATE', 'TEST_JSON_COOKIE_PRIVATE')) {
            Assert-Release (-not $safe.Contains($secret)) ('Header credential survived: ' + $secret)
        }
        Assert-Release ($safe.Contains('RealMod.java:42')) 'Neighboring diagnostic content was lost.'
    }
    Invoke-ReleaseTest 'Inventory numbering uses stable ordinal relative path order' {
        $f = New-ReleaseFixture 'ordinal'
        Write-ReleaseText (Join-Path $f.Instance 'mods/Z.jar') 'z'
        Write-ReleaseText (Join-Path $f.Instance 'mods/a.jar') 'a'
        Write-ReleaseText (Join-Path $f.Instance 'mods/B.jar') 'b'
        $inventory = Get-MtzFullInventory -Root $f.Instance -ScopeFolders @('mods', 'logs') -PrivateRootNames @()
        $actual = [string[]]@($inventory.Candidates | ForEach-Object { $_.Relative })
        $expected = [string[]]$actual.Clone()
        [Array]::Sort($expected, [StringComparer]::Ordinal)
        Assert-Release (($actual -join '|') -ceq ($expected -join '|')) 'Filesystem order leaked into file/chunk numbering.'
    }
    Invoke-ReleaseTest 'A cancellation before starting creates no archive' {
        $f = New-ReleaseFixture 'cancel-before'
        Expect-ReleaseCancellation { New-MtzFullBundle -InstancePath $f.Instance -OutputDirectory $f.Output -CancellationCheck { $true } }
        Assert-OnlyEarlierPackage $f
    }
    Invoke-ReleaseTest 'Diagnostic cancellation during compression closes and removes the partial file' {
        $f = New-ReleaseFixture 'cancel-diagnostic' -LongLog
        $script:releaseCancel = $false
        $script:releaseEvents.Clear()
        $callback = {
            param($Snapshot)
            $script:releaseEvents.Add($Snapshot)
            if ($Snapshot.Stage -eq 'Kompresja diagnostyki' -and $Snapshot.CompletedBytes -ge 1MB) { $script:releaseCancel = $true }
        }
        Expect-ReleaseCancellation { New-MtzDiagnosticBundle -InstancePath $f.Instance -OutputDirectory $f.Output -ProgressCallback $callback -CancellationCheck { $script:releaseCancel } }
        Assert-Release $script:releaseCancel 'Fixture never canceled inside a compressed entry.'
        Assert-Release (@($script:releaseEvents | Where-Object { $_.Percent -ge 100 }).Count -eq 0) 'Canceled engine reported 100 percent.'
        Assert-OnlyEarlierPackage $f
    }
    Invoke-ReleaseTest 'Full cancellation during enumeration removes the preliminary diagnostic ZIP' {
        $f = New-ReleaseFixture 'cancel-enumeration'
        $script:releaseCancel = $false
        $callback = { param($Snapshot); if ($Snapshot.Stage -eq 'Zliczanie plików') { $script:releaseCancel = $true } }
        Expect-ReleaseCancellation { New-MtzFullBundle -InstancePath $f.Instance -OutputDirectory $f.Output -PartMiB 1 -ProgressCallback $callback -CancellationCheck { $script:releaseCancel } }
        Assert-OnlyEarlierPackage $f
    }
    Invoke-ReleaseTest 'Full cancellation inside a file preserves original files and earlier packages' {
        $f = New-ReleaseFixture 'cancel-full-write'
        $originalHash = (Get-FileHash -LiteralPath (Join-Path $f.Instance 'mods/sample.jar')).Hash
        $script:releaseCancel = $false
        $script:releaseEvents.Clear()
        $callback = {
            param($Snapshot)
            $script:releaseEvents.Add($Snapshot)
            if ($Snapshot.Stage -eq 'Kopiowanie i kompresja' -and $Snapshot.CompletedBytes -ge 1MB) { $script:releaseCancel = $true }
        }
        Expect-ReleaseCancellation { New-MtzFullBundle -InstancePath $f.Instance -OutputDirectory $f.Output -PartMiB 1 -ProgressCallback $callback -CancellationCheck { $script:releaseCancel } }
        Assert-Release $script:releaseCancel 'Fixture never reached streamed source bytes.'
        Assert-Release ((Get-FileHash -LiteralPath (Join-Path $f.Instance 'mods/sample.jar')).Hash -ceq $originalHash) 'Source bytes changed on cancellation.'
        Assert-Release (@($script:releaseEvents | Where-Object { $_.Percent -ge 100 }).Count -eq 0) 'Canceled full capture reported 100 percent.'
        Assert-OnlyEarlierPackage $f
    }
    Invoke-ReleaseTest 'Cancellation after publishing a part removes this attempt final ZIPs too' {
        $f = New-ReleaseFixture 'cancel-after-publish'
        $script:releaseCancel = $false
        $callback = {
            param($Snapshot)
            if ($Snapshot.Stage -eq 'Zapisywanie gotowych części' -and $Snapshot.CompletedFiles -eq 1) { $script:releaseCancel = $true }
        }
        Expect-ReleaseCancellation { New-MtzFullBundle -InstancePath $f.Instance -OutputDirectory $f.Output -PartMiB 1 -ProgressCallback $callback -CancellationCheck { $script:releaseCancel } }
        Assert-Release $script:releaseCancel 'Fixture did not reach a published final ZIP.'
        Assert-OnlyEarlierPackage $f
    }
    Invoke-ReleaseTest 'Destination write failure is fatal rather than a source skip' {
        $f = New-ReleaseFixture 'output-failure'
        $original = (Get-Command Open-MtzFullPart).ScriptBlock
        function Open-MtzFullPart { param($State); throw [IO.IOException]::new('TEST_DESTINATION_WRITE_FAILURE') }
        $caught = $null
        try { New-MtzFullBundle -InstancePath $f.Instance -OutputDirectory $f.Output -PartMiB 1 | Out-Null }
        catch { $caught = $_.Exception }
        finally { Set-Item -Path Function:Open-MtzFullPart -Value $original }
        Assert-Release ($null -ne $caught -and $caught.Message.Contains('TEST_DESTINATION_WRITE_FAILURE')) 'Output failure was converted into an apparently usable incomplete job.'
        Assert-OnlyEarlierPackage $f
    }
    Invoke-ReleaseTest 'Metadata finalization failure removes the current job files' {
        $f = New-ReleaseFixture 'metadata-failure'
        $original = (Get-Command Write-MtzFullZipText).ScriptBlock
        function Write-MtzFullZipText { param($Archive, [string]$Name, [string]$Text, [switch]$Utf8Bom); throw [IO.IOException]::new('TEST_METADATA_WRITE_FAILURE') }
        $caught = $null
        try { New-MtzFullBundle -InstancePath $f.Instance -OutputDirectory $f.Output -PartMiB 1 | Out-Null }
        catch { $caught = $_.Exception }
        finally { Set-Item -Path Function:Write-MtzFullZipText -Value $original }
        Assert-Release ($null -ne $caught -and $caught.Message.Contains('TEST_METADATA_WRITE_FAILURE')) 'Metadata finalization failure was hidden.'
        Assert-OnlyEarlierPackage $f
    }
    Invoke-ReleaseTest 'Cleanup refusal is propagated as a warning without deleting unrelated paths' {
        $f = New-ReleaseFixture 'cleanup-refused'
        $script:releaseCancel = $false
        $script:cleanupRefusedPath = ''
        $callback = {
            param($Snapshot)
            if ($Snapshot.Stage -eq 'Zapisywanie gotowych części' -and $Snapshot.CompletedFiles -eq 1) {
                $firstPart = @(Get-ChildItem -LiteralPath $f.Output -Recurse -File | Where-Object { $_.Name -match '-0001\.zip$' })[0]
                # A directory in the place of an owned file makes File.Delete
                # fail on both platforms, even when the test runner is root.
                [IO.File]::Delete($firstPart.FullName)
                [void][IO.Directory]::CreateDirectory($firstPart.FullName)
                $script:cleanupRefusedPath = $firstPart.FullName
                $script:releaseCancel = $true
            }
        }
        $caught = $null
        try { New-MtzFullBundle -InstancePath $f.Instance -OutputDirectory $f.Output -PartMiB 1 -ProgressCallback $callback -CancellationCheck { $script:releaseCancel } | Out-Null }
        catch { $caught = $_.Exception }
        Assert-Release ($null -ne $caught -and (Test-MtzCaptureCancelled $caught)) 'Cleanup refusal changed cancellation into a successful result.'
        $wrapped = [Exception]::new('PowerShell wrapper fixture', $caught)
        $warnings = @(Get-MtzCaptureCleanupWarnings $wrapped)
        Assert-Release ($warnings.Count -gt 0 -and (($warnings -join '|').Contains([IO.Path]::GetFileName($script:cleanupRefusedPath)))) 'Cleanup warning was lost before worker result serialization.'
        Assert-Release ([IO.Directory]::Exists($script:cleanupRefusedPath)) 'Cleanup recursively removed a directory occupying a file path.'
        Assert-Release ([IO.File]::ReadAllText($f.Previous) -ceq 'KEEP_EARLIER_PACKAGE') 'Cleanup refusal affected a previous package.'
    }
    Invoke-ReleaseTest 'Worker observes cancel.request and returns a separate canceled result' {
        $f = New-ReleaseFixture 'worker-cancel'
        $worker = Invoke-ReleaseWorker -Fixture $f -Mode Full -PreCanceled
        Assert-Release ($worker.ExitCode -eq 3 -and -not $worker.Result.Success -and $worker.Result.Canceled) 'Worker cancellation protocol or exit code incorrect.'
        Assert-Release ($null -eq $worker.Result.Bundle) 'Canceled worker exposed a package for sending.'
        Assert-Release ($worker.Progress.Percent -lt 100 -and $worker.Progress.Stage -eq 'Anulowano') 'Canceled worker advertised completion.'
        Assert-OnlyEarlierPackage $f
    }
    Invoke-ReleaseTest 'Diagnostic worker succeeds with an inspected ZIP and stays below GUI completion' {
        $f = New-ReleaseFixture 'worker-success'
        $worker = Invoke-ReleaseWorker -Fixture $f -Mode Diagnostics
        Assert-Release ($worker.ExitCode -eq 0 -and $worker.Result.Success -and -not $worker.Result.Canceled) 'Regular worker could not complete.'
        Assert-Release ($worker.Progress.Percent -eq 99) 'Only GUI may acknowledge final 100 percent.'
        $manifest = (Read-ReleaseZipText -Path $worker.Result.Bundle.ZipPath -EntryName 'manifest.json') | ConvertFrom-Json
        Assert-Release ($manifest.collectorVersion -eq '0.3.0-rc.1') 'Diagnostic archive has stale collector version.'
        Assert-Release (-not $manifest.worldsIncluded -and -not $manifest.configsIncluded -and -not $manifest.modBinariesIncluded -and -not $manifest.networkRequestsMade) 'Diagnostic default scope changed.'
        Assert-Release ([IO.File]::ReadAllText($f.Previous) -ceq 'KEEP_EARLIER_PACKAGE') 'Success changed an earlier package.'
    }
} finally {
    if ([IO.Directory]::Exists($testRoot)) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
$failed = @($script:releaseResults | Where-Object { -not $_.Passed }).Count
$report = [ordered]@{
    Version = '0.3.0-rc.1'; GeneratedUtc = [DateTime]::UtcNow.ToString('o')
    PowerShell = $PSVersionTable.PSVersion.ToString()
    RuntimeWindows = ($env:OS -eq 'Windows_NT')
    NativeWindowsUiValidated = $false
    EngineTestsOnly = $true
    Tests = $script:releaseResults.Count; Passed = $script:releaseResults.Count - $failed; Failed = $failed
    Assertions = $script:releaseChecks
    Results = @($script:releaseResults.ToArray())
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'release-core-results.json'), ($report | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Write-Host ('RESULT release core: ' + $report.Passed + '/' + $report.Tests + ' tests, ' + $report.Assertions + ' assertions')
if ($failed -gt 0) { exit 1 }

