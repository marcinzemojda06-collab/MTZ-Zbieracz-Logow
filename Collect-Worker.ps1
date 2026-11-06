#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version 2.0
# Request values are data in JSON, never PowerShell expressions or command fragments.
$requestFile = [IO.Path]::GetFullPath($RequestPath)
$resultFile = Join-Path ([IO.Path]::GetDirectoryName($requestFile)) 'result.json'
$script:progressFile = Join-Path ([IO.Path]::GetDirectoryName($requestFile)) 'progress.json'
$script:cancelRequestFile = Join-Path ([IO.Path]::GetDirectoryName($requestFile)) 'cancel.request'
$script:progressSequence = 0L
$script:progressPercent = 0
$script:progressLastAttemptUtc = [DateTime]::MinValue
$script:progressLastAttemptStage = ''
$result = $null
$exitCode = 0
$capture = $null

function Remove-MtzWorkerCapture {
    param($Capture)
    if ($null -eq $Capture) { return }
    $cleanupWarnings = New-Object 'Collections.Generic.List[string]'
    # These exact files were just returned by this worker's capture engine.
    # Do not recurse into the user's output folder or touch earlier captures.
    $ownedPaths = @([string]$Capture.ZipPath)
    if ($Capture.PSObject.Properties.Name -contains 'ZipPaths') { $ownedPaths = @($Capture.ZipPaths) }
    if ($Capture.PSObject.Properties.Name -contains 'ManifestPath') { $ownedPaths += [string]$Capture.ManifestPath }
    foreach ($path in $ownedPaths) {
        Remove-MtzOwnedCaptureFile ([string]$path) $cleanupWarnings
    }
    if ($Capture.PSObject.Properties.Name -contains 'Full' -and $Capture.Full -and
        $Capture.PSObject.Properties.Name -contains 'SessionDirectory') {
        $directory = [string]$Capture.SessionDirectory
        Remove-MtzOwnedCaptureDirectoryIfEmpty $directory $cleanupWarnings
    }
    return @($cleanupWarnings.ToArray())
}

function Write-MtzWorkerProgress {
    param($Snapshot)
    # Optional local status only. Failure to replace this tiny file must not make
    # a good archive fail, and the UI must never see a partially written JSON.
    $temporary = $script:progressFile + '.new'
    try {
        $now = [DateTime]::UtcNow
        $stage = [string]$Snapshot.Stage
        $detail = [string]$Snapshot.Detail
        if ($stage.Length -gt 80) { $stage = $stage.Substring(0, 80) }
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
        $force = $false
        if ($Snapshot.PSObject.Properties.Name -contains 'Force') { $force = [bool]$Snapshot.Force }
        $phaseChanged = ($stage -ne $script:progressLastAttemptStage)
        if (-not $force -and -not $phaseChanged -and ($now - $script:progressLastAttemptUtc).TotalMilliseconds -lt 200) { return }
        $script:progressLastAttemptUtc = $now
        $script:progressLastAttemptStage = $stage
        $percent = [Math]::Max($script:progressPercent, [Math]::Max(0, [Math]::Min(99, [int]$Snapshot.Percent)))
        $nextSequence = $script:progressSequence + 1L
        $value = [ordered]@{
            Version = 1; Sequence = $nextSequence; Percent = [int]$percent
            Stage = $stage; Detail = $detail; UpdatedUtc = $now.ToString('o')
            CompletedBytes = [long]$Snapshot.CompletedBytes; TotalBytes = [long]$Snapshot.TotalBytes
            CompletedFiles = [long]$Snapshot.CompletedFiles; TotalFiles = [long]$Snapshot.TotalFiles
        }
        [IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($script:progressFile)) {
            [IO.File]::Replace($temporary, $script:progressFile, [NullString]::Value)
        } else {
            [IO.File]::Move($temporary, $script:progressFile)
        }
        $script:progressPercent = [int]$percent
        $script:progressSequence = $nextSequence
    } catch { }
    finally {
        if ([IO.File]::Exists($temporary)) { try { [IO.File]::Delete($temporary) } catch { } }
    }
}

$progressCallback = { param($Snapshot) Write-MtzWorkerProgress -Snapshot $Snapshot }
$cancellationCheck = { [IO.File]::Exists($script:cancelRequestFile) }
try {
    . (Join-Path $PSScriptRoot 'core.ps1')
    . (Join-Path $PSScriptRoot 'session.ps1')
    Send-MtzCaptureProgress $progressCallback 0 'Przygotowywanie paczki' 'Sprawdzanie żądania zbierania.' -Force
    Assert-MtzCaptureNotCancelled $cancellationCheck
    $request = [IO.File]::ReadAllText($requestFile) | ConvertFrom-Json
    foreach ($property in @('InstancePath', 'OutputDirectory', 'SessionStartedUtc', 'Mode', 'PartMiB')) {
        if ($request.PSObject.Properties.Name -notcontains $property) { throw ('Brak pola żądania: ' + $property) }
    }
    if ($request.Mode -notin @('Full', 'Diagnostics')) { throw 'Nieznany zakres paczki.' }
    $instance = Get-MtzInstanceInfo -InstancePath ([string]$request.InstancePath)
    $output = [IO.Path]::GetFullPath([string]$request.OutputDirectory).TrimEnd([char[]]'\/')
    $root = $instance.RootPath.TrimEnd([char[]]'\/')
    $separator = [IO.Path]::DirectorySeparatorChar
    if ($output.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $output.StartsWith($root + $separator, [StringComparison]::OrdinalIgnoreCase) -or $root.StartsWith($output + $separator, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Folder paczek musi znajdować się poza instancją Minecrafta i nie może być jej folderem nadrzędnym.'
    }
    $started = [DateTime]::Parse([string]$request.SessionStartedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    $workerWarnings = @()
    if ($request.Mode -eq 'Full') {
        $processState = Get-MtzGameProcessState -InstancePath $instance.RootPath
        if ($processState.Running) { throw 'Minecraft nadal działa. Zamknij grę przed kopiowaniem światów i przygotuj paczkę ponownie.' }
        if (-not $processState.Known) { $workerWarnings += 'Nie udało się potwierdzić stanu procesu gry. Pełną paczkę światów przygotowuj przy zamkniętym Minecraftcie.' }
        $partMiB = [int]$request.PartMiB
        if ($partMiB -lt 1 -or $partMiB -gt 24) { throw 'Rozmiar części musi wynosić od 1 do 24 MiB.' }
        . (Join-Path $PSScriptRoot 'full-bundle.ps1')
        $capture = New-MtzFullBundle -InstancePath $instance.RootPath -OutputDirectory $output -SessionStartedUtc $started -PartMiB $partMiB -ProgressCallback $progressCallback -CancellationCheck $cancellationCheck
    } else {
        $capture = New-MtzDiagnosticBundle -InstancePath $instance.RootPath -OutputDirectory $output -SessionStartedUtc $started -ProgressCallback $progressCallback -CancellationCheck $cancellationCheck
    }
    $paths = @([string]$capture.ZipPath)
    if ($capture.PSObject.Properties.Name -contains 'ZipPaths') { $paths = @($capture.ZipPaths) }
    $checkStart = 90
    if ($request.Mode -eq 'Full') { $checkStart = 98 }
    $checkedPaths = 0L
    Send-MtzCaptureProgress $progressCallback $checkStart 'Sprawdzanie archiwów' ('Części do sprawdzenia: {0}.' -f $paths.Count) -TotalFiles $paths.Count -Force
    foreach ($path in $paths) {
        Assert-MtzCaptureNotCancelled $cancellationCheck
        $file = Get-Item -LiteralPath ([string]$path) -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Length -lt 4 -or $file.Length -gt (30MB)) { throw 'Powstał nieprawidłowy ZIP lub część przekracza limit 30 MiB.' }
        $checkStream = [IO.File]::OpenRead([string]$path)
        $checkArchive = $null
        try {
            $checkArchive = New-Object IO.Compression.ZipArchive($checkStream, [IO.Compression.ZipArchiveMode]::Read, $true)
            $requiredEntry = 'manifest.json'
            if ([string]$path -ne [string]$capture.ZipPath) { $requiredEntry = '__mtz_meta__/index.json' }
            if ($checkArchive.Entries.Count -eq 0 -or $null -eq $checkArchive.GetEntry($requiredEntry)) {
                throw 'Archiwum nie zawiera wymaganego spisu paczki.'
            }
        } finally {
            try { if ($null -ne $checkArchive) { $checkArchive.Dispose() } }
            finally { $checkStream.Dispose() }
        }
        $checkedPaths++
        Send-MtzCaptureProgress $progressCallback ($checkStart + (99 - $checkStart) * $checkedPaths / [double][Math]::Max(1, $paths.Count)) 'Sprawdzanie archiwów' ('Sprawdzono {0}/{1} części ZIP.' -f $checkedPaths, $paths.Count) -CompletedFiles $checkedPaths -TotalFiles $paths.Count
    }
    $warnings = @($capture.Warnings) + $workerWarnings
    $bundle = [ordered]@{
        ZipPath = [string]$capture.ZipPath; ZipPaths = @($paths); Warnings = @($warnings)
        Full = ($request.Mode -eq 'Full'); Complete = $true; SkippedCount = 0
        ManifestPath = ''; SessionDirectory = [IO.Path]::GetDirectoryName([string]$capture.ZipPath)
        FileCount = 0; TotalSourceBytes = 0L
    }
    foreach ($property in @('Complete', 'SkippedCount', 'ManifestPath', 'SessionDirectory', 'FileCount', 'TotalSourceBytes')) {
        if ($capture.PSObject.Properties.Name -contains $property) { $bundle[$property] = $capture.$property }
    }
    Assert-MtzCaptureNotCancelled $cancellationCheck
    $result = [ordered]@{ Success = $true; Canceled = $false; Error = ''; Warnings = @($warnings); Bundle = $bundle }
} catch {
    $workerFailure = $_
    $canceled = $false
    if (Get-Command Test-MtzCaptureCancelled -ErrorAction SilentlyContinue) { $canceled = Test-MtzCaptureCancelled $workerFailure.Exception }
    $message = [string]$workerFailure.Exception.Message
    if (Get-Command Protect-MtzDiagnosticText -ErrorAction SilentlyContinue) { $message = Protect-MtzDiagnosticText -Text $message }
    $cleanupWarnings = @()
    if (Get-Command Get-MtzCaptureCleanupWarnings -ErrorAction SilentlyContinue) { $cleanupWarnings = @(Get-MtzCaptureCleanupWarnings $workerFailure.Exception) }
    $cleanupWarnings += @(Remove-MtzWorkerCapture $capture)
    $result = [ordered]@{ Success = $false; Canceled = [bool]$canceled; Error = $message; Warnings = @($cleanupWarnings | Select-Object -Unique); Bundle = $null }
    $exitCode = 1
    if ($canceled) { $exitCode = 3 }
    if (Get-Command Send-MtzCaptureProgress -ErrorAction SilentlyContinue) {
        if ($canceled) {
            Send-MtzCaptureProgress $progressCallback $script:progressPercent 'Anulowano' 'Zatrzymano przygotowywanie paczki; wcześniejsze paczki pozostają bez zmian.' -Force
        } else {
            Send-MtzCaptureProgress $progressCallback $script:progressPercent 'Przygotowanie nieudane' 'Paczka nie została ukończona. Szczegóły w komunikacie aplikacji.' -Force
        }
    }
}
try {
    # The parent only reads result.json after this process exits. Rename also prevents partial JSON reads.
    $temporary = $resultFile + '.new'
    [IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $resultFile -Force
} catch { exit 2 }
if ($exitCode -eq 0) {
    Send-MtzCaptureProgress $progressCallback 99 'Wynik zapisany' 'Końcowe zatwierdzanie paczki w oknie aplikacji.' -CompletedFiles $checkedPaths -TotalFiles $paths.Count -Force
}
exit $exitCode
