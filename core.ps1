# MTZ Zbieracz logow — core for Windows PowerShell 5.1 / .NET Framework 4.5+
# This file performs no uploads, launches no processes, and reads no world data.
Set-StrictMode -Version 2.0

function Assert-MtzCaptureNotCancelled {
    param([scriptblock]$CancellationCheck = $null)
    # Unlike the observational progress callback, this callback intentionally
    # controls the operation. Keep cancellation distinct from a skipped source.
    if ($null -ne $CancellationCheck -and [bool](& $CancellationCheck)) {
        throw [System.OperationCanceledException]::new('Anulowano przygotowywanie paczki.')
    }
}

function Test-MtzCaptureCancelled {
    param([System.Exception]$Exception)
    # PowerShell can wrap .NET exceptions from method calls in another exception.
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.OperationCanceledException]) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Add-MtzCaptureCleanupWarning {
    param($Warnings, [string]$Message)
    if ($Warnings.Count -lt 8) { $Warnings.Add($Message) }
    elseif ($Warnings.Count -eq 8) { $Warnings.Add('Pozostały też inne pliki robocze tej próby. Sprawdź folder paczek przed ręcznym udostępnieniem.') }
}

function Remove-MtzOwnedCaptureFile {
    param([string]$Path, $Warnings)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { [IO.File]::Delete($Path) }
    catch {
        Add-MtzCaptureCleanupWarning $Warnings ('Nie udało się usunąć pozostałości tej próby: ' + [IO.Path]::GetFileName($Path) + '. Nie udostępniaj tego pliku jako gotowej paczki.')
    }
}

function Remove-MtzOwnedCaptureDirectoryIfEmpty {
    param([string]$Path, $Warnings)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        if ([IO.Directory]::Exists($Path)) {
            if ([IO.Directory]::GetFileSystemEntries($Path).Length -eq 0) { [IO.Directory]::Delete($Path, $false) }
            else { Add-MtzCaptureCleanupWarning $Warnings ('W folderze ' + [IO.Path]::GetFileName($Path) + ' pozostały pliki niedokończonej próby. Sprawdź go ręcznie.') }
        }
    } catch {
        Add-MtzCaptureCleanupWarning $Warnings ('Nie udało się posprzątać folderu tej próby: ' + [IO.Path]::GetFileName($Path) + '. Sprawdź folder paczek ręcznie.')
    }
}

function Get-MtzCaptureCleanupWarnings {
    param([System.Exception]$Exception)
    $warnings = New-Object 'Collections.Generic.List[string]'
    $current = $Exception
    while ($null -ne $current) {
        if ($current.Data.Contains('MtzCleanupWarnings')) {
            foreach ($warning in $current.Data['MtzCleanupWarnings']) {
                if (-not $warnings.Contains([string]$warning)) { Add-MtzCaptureCleanupWarning $warnings ([string]$warning) }
            }
        }
        $current = $current.InnerException
    }
    return @($warnings.ToArray())
}

function Send-MtzCaptureProgress {
    param(
        [scriptblock]$ProgressCallback,
        [double]$Percent,
        [string]$Stage,
        [string]$Detail = '',
        [long]$CompletedBytes = 0,
        [long]$TotalBytes = 0,
        [long]$CompletedFiles = 0,
        [long]$TotalFiles = 0,
        [switch]$Force
    )
    if ($null -eq $ProgressCallback) { return }
    # Reporting is observational: callback failures and callback output must never
    # alter the archive result, hide a capture exception, or mark a job complete.
    try {
        if ([double]::IsNaN($Percent) -or [double]::IsInfinity($Percent)) { return }
        $snapshot = [pscustomobject]@{
            Percent = [int][Math]::Floor([Math]::Max(0.0, [Math]::Min(99.0, $Percent)))
            Stage = $Stage; Detail = $Detail
            CompletedBytes = $CompletedBytes; TotalBytes = $TotalBytes
            CompletedFiles = $CompletedFiles; TotalFiles = $TotalFiles
            Force = $Force.IsPresent
        }
        $null = & $ProgressCallback $snapshot
    } catch { }
}

function Get-MtzSafeChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [switch]$AllowMissing
    )
    $root = [System.IO.Path]::GetFullPath($RootPath).TrimEnd([char[]]'\/')
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw 'Folder instancji nie moze byc dowiazaniem ani plikiem.'
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) { throw 'Wymagana jest sciezka wzgledna.' }
    $parts = @($RelativePath -split '[\\/]')
    if ($parts.Count -eq 0 -or @($parts | Where-Object { $_ -eq '..' -or $_ -eq '.' -or $_ -eq '' }).Count -gt 0) {
        throw 'Niedozwolona sciezka wzgledna.'
    }
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $RelativePath))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Plik znajduje sie poza wybrana instancja.'
    }
    $current = $root
    foreach ($part in $parts) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
            if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw ('Pominieto dowiazanie: ' + $RelativePath)
            }
        } elseif (-not $AllowMissing) {
            throw ('Nie znaleziono: ' + $RelativePath)
        }
    }
    return $full
}

function Get-MtzInstanceInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstancePath)
    if ([string]::IsNullOrWhiteSpace($InstancePath)) { throw 'Wybierz folder instancji Minecrafta.' }
    $fullRoot = [System.IO.Path]::GetFullPath($InstancePath)
    $root = $fullRoot.TrimEnd([char[]]'\/')
    if ($root -eq [System.IO.Path]::GetPathRoot($fullRoot).TrimEnd([char[]]'\/')) {
        throw 'Wybierz konkretny folder instancji Minecrafta, nie caly dysk.'
    }
    $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw 'Wybierz zwykly folder instancji, nie dowiazanie.'
    }
    $logs = Get-MtzSafeChildPath -RootPath $root -RelativePath 'logs' -AllowMissing
    $mods = Get-MtzSafeChildPath -RootPath $root -RelativePath 'mods' -AllowMissing
    $crashes = Get-MtzSafeChildPath -RootPath $root -RelativePath 'crash-reports' -AllowMissing
    $hasLogs = Test-Path -LiteralPath $logs -PathType Container
    $hasMods = Test-Path -LiteralPath $mods -PathType Container
    if (-not $hasLogs -and -not $hasMods) {
        throw 'Ten folder nie zawiera logs ani mods. W CurseForge wybierz Otworz folder i wskaz ten folder.'
    }
    return [pscustomobject]@{
        RootPath = $root
        DisplayName = $item.Name
        LogDirectory = $logs
        ModsDirectory = $mods
        CrashDirectory = $crashes
        HasLogs = [bool]$hasLogs
        HasMods = [bool]$hasMods
    }
}

function Get-MtzLogFingerprint {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$InstancePath)
    $info = Get-MtzInstanceInfo -InstancePath $InstancePath
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($name in @('latest.log', 'debug.log')) {
        $relative = 'logs/' + $name
        try {
            $path = Get-MtzSafeChildPath -RootPath $info.RootPath -RelativePath $relative -AllowMissing
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $items.Add([pscustomobject]@{
                Name = $name
                Length = [long]$file.Length
                LastWriteUtcTicks = [long]$file.LastWriteTimeUtc.Ticks
                CreationUtcTicks = [long]$file.CreationTimeUtc.Ticks
            })
        } catch {
            # A transient rename/rotation must not stop the observer timer.
            $items.Add([pscustomobject]@{ Name = $name; Length = -1L; LastWriteUtcTicks = 0L; CreationUtcTicks = 0L })
        }
    }
    return [pscustomobject]@{
        Key = (@($items | ForEach-Object { '{0}:{1}:{2}:{3}' -f $_.Name, $_.Length, $_.LastWriteUtcTicks, $_.CreationUtcTicks }) -join '|')
        Files = @($items.ToArray())
        ObservedUtc = [DateTime]::UtcNow
    }
}

function Protect-MtzDiagnosticText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][Parameter(Mandatory = $true)][string]$Text,
        [string]$InstancePath = '',
        [string[]]$PlayerNames = @()
    )
    $result = $Text
    # Replace known local prefixes first; never emit the actual selected path.
    $prefixes = @($InstancePath, $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Length -gt 3 } |
        Sort-Object Length -Descending -Unique
    foreach ($prefix in $prefixes) {
        $result = [regex]::Replace($result, [regex]::Escape($prefix), '[FOLDER]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $slashPrefix = $prefix.Replace('\', '/')
        $result = [regex]::Replace($result, [regex]::Escape($slashPrefix), '[FOLDER]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        # JSON log records escape each backslash. Protect the same selected path
        # in that representation too, including Windows account names with spaces.
        $escapedPrefix = $prefix.Replace('\', '\\')
        $result = [regex]::Replace($result, [regex]::Escape($escapedPrefix), '[FOLDER]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    $result = [regex]::Replace($result, '(?i)\b[A-Z]:[\\/]+Users[\\/]+[^\\/\r\n"\x27]+', '[PROFIL]')
    $result = [regex]::Replace($result, '(?i)(?<!\w)/(?:home|Users)/[^/\r\n\s"\x27]+', '[PROFIL]')
    $sensitiveHeaders = '(?:Cookie|Set-Cookie|Authorization|Proxy-Authorization|X-Auth-Token|X-Access-Token|X-Api-Key)'
    $result = [regex]::Replace($result, '(?im)(\b' + $sensitiveHeaders + '\s*:\s*)[^\r\n]+', '$1[SEKRET]')
    $quotedHeaders = '(?i)(\b' + $sensitiveHeaders + '\b["\x27]?\s*[:=]\s*)(?:"(?:\\.|[^"\\\r\n])*"|\x27(?:\\.|[^\x27\\\r\n])*\x27)'
    $result = [regex]::Replace($result, $quotedHeaders, '$1[SEKRET]')
    $quotedSecrets = '(?i)(\b(?:access[_-]?token|refresh[_-]?token|client[_-]?token|identity[_-]?token|id[_-]?token|session[_-]?(?:token|id)|api[_-]?key|password|passwd)\b["\x27]?\s*[:=]\s*)(?:"(?:\\.|[^"\\\r\n])*"|\x27(?:\\.|[^\x27\\\r\n])*\x27)'
    $result = [regex]::Replace($result, $quotedSecrets, '$1[SEKRET]')
    $secretKeyPattern = '(?i)(\b(?:access[_-]?token|refresh[_-]?token|client[_-]?token|identity[_-]?token|id[_-]?token|session[_-]?(?:token|id)|api[_-]?key|password|passwd)\b["\x27]?\s*[:=]\s*["\x27]?)(?!\[SEKRET\])([^\s"\x27,;}\]]+)'
    $result = [regex]::Replace($result, $secretKeyPattern, '$1[SEKRET]')
    $result = [regex]::Replace($result, '(?i)(--(?:accessToken|refreshToken|clientToken|identityToken|sessionToken|sessionId|password|apiKey|username|uuid|xuid|clientId)(?:\s*,\s*|\s+|=))(?:"(?:\\.|[^"\\\r\n])*"|\x27(?:\\.|[^\x27\\\r\n])*\x27|[^,\s]+)', '$1[PRYWATNE]')
    $result = [regex]::Replace($result, '(?i)(\bAuthorization["\x27]?\s*[:=]\s*["\x27]?)(?:Bearer|Basic)\s+[^\s"\x27,;]+', '$1[SEKRET]')
    $result = [regex]::Replace($result, '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b', '[JWT]')
    $result = [regex]::Replace($result, '(?i)\b(?:sk|sess)-[a-z0-9_-]{16,}\b', '[KLUCZ]')
    $result = [regex]::Replace($result, '(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '[UUID]')
    $result = [regex]::Replace($result, '(?i)\b(?:https?|wss?)://[^\s<>"\x27]+', '[URL]')
    $result = [regex]::Replace($result, '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,63}\b', '[EMAIL]')
    $ipv4 = '(?<![A-Za-z0-9_.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![A-Za-z0-9_.])'
    $ipv4Source = $result
    $result = [regex]::Replace($result, $ipv4, {
        param($match)
        $prefixStart = [Math]::Max(0, $match.Index - 100)
        $before = $ipv4Source.Substring($prefixStart, $match.Index - $prefixStart)
        $afterStart = $match.Index + $match.Length
        $after = $ipv4Source.Substring($afterStart, [Math]::Min(64, $ipv4Source.Length - $afterStart))
        # Preserve explicit software versions, including suffixed JAR names and NeoForge's mod table.
        $jarVersion = $before -match '(?i)[A-Za-z0-9_.+]+-$' -and
            $after -match '(?i)^[A-Za-z0-9_.+\-]*\.jar(?:\.disabled)?(?=[^A-Za-z0-9_.+\-]|$)'
        $tableVersion = $before -match '(?:^|[\r\n])[ \t]{2,}[^\r\n]+[ \t]$' -and
            $after -match '^[A-Za-z0-9_.+\-]*[ \t]+\([a-z][a-z0-9_]*\)(?:\r?\n|\r?$)'
        $jvmVersion = $before -match '(?i)JVM identified as[^\r\n]*(?:VM|OpenJDK)[ \t]+$'
        if ($before -match '(?i)(?:version|wersja|Mekanism|NeoForge|Forge|FML|Minecraft|ModVersion|ArtifactVersion|mod[-_ ]version)\s*[:=]?\s*["\x27]?\s*$' -or
            $after -match '(?i)^(?:\.jar(?:\.disabled)?|\.disabled)(?![A-Za-z0-9])' -or
            $jarVersion -or $tableVersion -or $jvmVersion) { return $match.Value }
        return '[IP]'
    })
    $server = '(?i)(\b(?:Connecting\s+to|serverAddress\s*[:=]|serverIP\s*[:=]|server\s*[:=]|host\s*[:=])\s*["\x27]?)(?:[a-z0-9](?:[a-z0-9-]{0,62})\.)+[a-z]{2,63}(?::\d{1,5})?'
    $result = [regex]::Replace($result, $server, '$1[SERWER]')
    $result = [regex]::Replace($result, '(?i)(?<![\w:])(?:\[[0-9a-f:]+\](?::\d{1,5})?|[0-9a-f]*:[0-9a-f:]+)(?![\w:])', {
        param($match)
        $candidate = $match.Value
        if ($candidate.StartsWith('[')) {
            $closing = $candidate.IndexOf(']')
            $candidate = $candidate.Substring(1, $closing - 1)
        }
        $address = $null
        if ([System.Net.IPAddress]::TryParse($candidate, [ref]$address)) { return '[IP]' }
        return $match.Value
    })
    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($player in $PlayerNames) {
        if (-not [string]::IsNullOrWhiteSpace($player) -and $player -match '^[A-Za-z0-9_]{1,16}$') { $aliases.Add($player) }
    }
    foreach ($player in @(Get-MtzPlayerAliases -Snapshots @([pscustomobject]@{ Text = $Text }))) {
        $aliases.Add($player)
    }
    foreach ($alias in @($aliases.ToArray() | Select-Object -Unique)) {
        $result = [regex]::Replace($result, '(?<![A-Za-z0-9_])' + [regex]::Escape($alias) + '(?![A-Za-z0-9_])', '[GRACZ]')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and $env:USERNAME.Length -ge 3) {
        $result = [regex]::Replace($result, '(?i)(\b(?:username|user|owner)\s*[:=]\s*)' + [regex]::Escape($env:USERNAME) + '\b', '$1[UZYTKOWNIK]')
    }
    return $result
}

function Read-MtzBoundedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [ValidateRange(1024, 16777216)][int]$MaxBytes = 8388608,
        [scriptblock]$CancellationCheck = $null
    )
    Assert-MtzCaptureNotCancelled $CancellationCheck
    $path = Get-MtzSafeChildPath -RootPath $RootPath -RelativePath $RelativePath
    $sharing = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $sharing)
        $sourceLastWriteUtc = $null
        try {
            $sourceItem = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            $sourceLastWriteUtc = $sourceItem.LastWriteTimeUtc
        } catch {
            # A file already opened with Delete sharing can be rotated immediately afterward.
            # Keep its readable snapshot and report unknown source time, rather than guessing.
        }
        $sourceLength = [long]$stream.Length
        $start = [Math]::Max(0L, $sourceLength - [long]$MaxBytes)
        [void]$stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        $wanted = [int]($sourceLength - $start)
        $buffer = New-Object byte[] $wanted
        $read = 0
        while ($read -lt $wanted) {
            Assert-MtzCaptureNotCancelled $CancellationCheck
            $amount = $stream.Read($buffer, $read, [int][Math]::Min(1MB, $wanted - $read))
            if ($amount -eq 0) { break }
            $read += $amount
        }
        # Decode only the fixed initial file length. Concurrent appends are for the next snapshot.
        $encoding = New-Object System.Text.UTF8Encoding($false, $false)
        $text = $encoding.GetString($buffer, 0, $read)
        if ($start -gt 0) {
            # A tail can start inside a UTF-8 code point or partial private value: remove that whole line.
            $lineEnd = $text.IndexOf("`n")
            if ($lineEnd -ge 0) { $text = $text.Substring($lineEnd + 1) } else { $text = '' }
            $text = "[MTZ: dolaczono koncowke pliku, starsze wpisy pominieto ze wzgledu na limit.]`r`n" + $text
        }
        return [pscustomobject]@{
            Text = $text
            SourceBytes = $sourceLength
            SourceLastWriteUtc = $sourceLastWriteUtc
            ReadBytes = $read
            Truncated = [bool]($start -gt 0)
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-MtzPlayerAliases {
    param([Parameter(Mandatory = $true)][object[]]$Snapshots)
    $aliases = New-Object System.Collections.Generic.List[string]
    foreach ($snapshot in $Snapshots) {
        foreach ($pattern in @(
            '(?im)(?:Setting user:\s*|--username(?:\s*,\s*|\s+|=)["\x27]?|UUID of player\s+)([A-Za-z0-9_]{1,16})\b',
            '(?m)(?:^|\]:\s*)([A-Za-z0-9_]{1,16})(?:\[[^\]\r\n]*\])? (?:joined the game|left the game|lost connection:)'
        )) {
            foreach ($match in [regex]::Matches($snapshot.Text, $pattern)) { $aliases.Add($match.Groups[1].Value) }
        }
    }
    return @($aliases.ToArray() | Select-Object -Unique)
}

function New-MtzDiagnosticBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstancePath,
        [Parameter(Mandatory = $true)][string]$OutputDirectory,
        [DateTime]$SessionStartedUtc = [DateTime]::MinValue,
        [ValidateRange(1024, 16777216)][int]$MaxLogBytes = 8388608,
        [ValidateRange(1048576, 50331648)][int]$MaxTotalBytes = 25165824,
        [scriptblock]$ProgressCallback = $null,
        [ValidateRange(1, 90)][int]$ProgressMaximum = 90,
        [scriptblock]$CancellationCheck = $null
    )
    Assert-MtzCaptureNotCancelled $CancellationCheck
    Send-MtzCaptureProgress $ProgressCallback 0 'Przygotowywanie diagnostyki' 'Sprawdzanie folderu i dostępnych logów.' -Force
    $info = Get-MtzInstanceInfo -InstancePath $InstancePath
    $output = [System.IO.Path]::GetFullPath($OutputDirectory)
    $sourcePrefix = $info.RootPath.TrimEnd([char[]]'\/') + [System.IO.Path]::DirectorySeparatorChar
    if ($output.Equals($info.RootPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $output.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Folder paczek diagnostycznych musi znajdowac sie poza folderem instancji.'
    }
    [void][System.IO.Directory]::CreateDirectory($output)
    $outputItem = Get-Item -LiteralPath $output -Force -ErrorAction Stop
    if ($outputItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw 'Folder wynikowy nie moze byc dowiazaniem.' }
    $warnings = New-Object System.Collections.Generic.List[string]
    $snapshots = New-Object System.Collections.Generic.List[object]
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('latest.log', 'debug.log')) {
        $relative = 'logs/' + $name
        try {
            $path = Get-MtzSafeChildPath -RootPath $info.RootPath -RelativePath $relative -AllowMissing
            if (Test-Path -LiteralPath $path -PathType Leaf) { $candidates.Add($relative) }
        } catch { $warnings.Add('Pominieto niedostepny lub dowiazany plik ' + $relative) }
    }
    if (Test-Path -LiteralPath $info.CrashDirectory -PathType Container) {
        # Top level only: never walk directories, follow links, or include arbitrary files.
        $crashFiles = @(Get-ChildItem -LiteralPath $info.CrashDirectory -File -Filter 'crash-*.txt' -ErrorAction Stop |
            Where-Object { -not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) } |
            Where-Object { $SessionStartedUtc -eq [DateTime]::MinValue -or $_.LastWriteTimeUtc -ge $SessionStartedUtc.ToUniversalTime().AddMinutes(-2) } |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3)
        foreach ($file in $crashFiles) { $candidates.Add('crash-reports/' + $file.Name) }
    }
    $total = 0L
    $readFiles = 0L
    Send-MtzCaptureProgress $ProgressCallback 0 'Odczyt logów' ('Logi do sprawdzenia: {0}.' -f $candidates.Count) -TotalFiles $candidates.Count -Force
    foreach ($relative in $candidates) {
        Assert-MtzCaptureNotCancelled $CancellationCheck
        $remaining = [long]$MaxTotalBytes - $total
        if ($remaining -lt 1024) { $warnings.Add('Osiagnieto laczny limit logow; pozostale pliki pominieto.'); break }
        try {
            $snapshot = Read-MtzBoundedText -RootPath $info.RootPath -RelativePath $relative -MaxBytes ([int][Math]::Min([long]$MaxLogBytes, $remaining)) -CancellationCheck $CancellationCheck
            $snapshots.Add([pscustomobject]@{
                Name = $relative
                Text = $snapshot.Text
                SourceBytes = $snapshot.SourceBytes
                SourceLastWriteUtc = $snapshot.SourceLastWriteUtc
                ReadBytes = $snapshot.ReadBytes
                Truncated = $snapshot.Truncated
            })
            if ($relative.StartsWith('logs/') -and $SessionStartedUtc -ne [DateTime]::MinValue -and
                $null -ne $snapshot.SourceLastWriteUtc -and
                $snapshot.SourceLastWriteUtc -lt $SessionStartedUtc.ToUniversalTime().AddMinutes(-2)) {
                $warnings.Add('Plik ' + $relative + ' nie byl aktualizowany od poczatku obserwacji; moze pochodzic z poprzedniej sesji.')
            }
            $total += $snapshot.ReadBytes
        } catch {
            if (Test-MtzCaptureCancelled $_.Exception) { throw }
            $warnings.Add('Nie udalo sie odczytac jednego z logow. Sprobuj po zamknieciu gry.')
        }
        finally {
            $readFiles++
            $readFraction = [double]$readFiles / [Math]::Max(1, $candidates.Count)
            Send-MtzCaptureProgress $ProgressCallback ($ProgressMaximum * 0.20 * $readFraction) 'Odczyt logów' ('Sprawdzono {0}/{1} logów; odczytano {2:N2} MiB.' -f $readFiles, $candidates.Count, ($total / 1MB)) -CompletedBytes $total -CompletedFiles $readFiles -TotalFiles $candidates.Count
        }
    }
    if ($snapshots.Count -eq 0) { throw 'Brak logow do zebrania. Uruchom Minecrafta i wskaz jego folder instancji.' }
    $aliases = @(Get-MtzPlayerAliases -Snapshots $snapshots.ToArray())
    $mods = New-Object System.Collections.Generic.List[object]
    Send-MtzCaptureProgress $ProgressCallback ($ProgressMaximum * 0.20) 'Spis modów' 'Zliczanie nazw i rozmiarów modów.' -Force
    if ($info.HasMods) {
        $modEntries = @(Get-ChildItem -LiteralPath $info.ModsDirectory -File -ErrorAction Stop | Sort-Object Name)
        $checkedModEntries = 0L
        foreach ($file in $modEntries) {
            Assert-MtzCaptureNotCancelled $CancellationCheck
            try {
                if ($file.Name -notmatch '(?i)\.(?:jar|disabled)$') { continue }
                if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    $warnings.Add('Pominieto dowiazanie w mods.'); continue
                }
                if ($mods.Count -ge 5000) { $warnings.Add('Spis mods ograniczono do 5000 pozycji.'); break }
                $mods.Add([pscustomobject]@{
                    name = Protect-MtzDiagnosticText -Text $file.Name -InstancePath $info.RootPath -PlayerNames $aliases
                    bytes = [long]$file.Length
                    enabled = [bool]($file.Extension -ieq '.jar')
                })
            } finally {
                $checkedModEntries++
                $modFraction = [double]$checkedModEntries / [Math]::Max(1, $modEntries.Count)
                Send-MtzCaptureProgress $ProgressCallback ($ProgressMaximum * (0.20 + 0.15 * $modFraction)) 'Spis modów' ('Sprawdzono {0}/{1} pozycji; w spisie {2} modów.' -f $checkedModEntries, $modEntries.Count, $mods.Count) -CompletedFiles $checkedModEntries -TotalFiles $modEntries.Count
            }
        }
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $included = New-Object System.Collections.Generic.List[object]
    $payloads = New-Object System.Collections.Generic.List[object]
    $filteredFiles = 0L
    Send-MtzCaptureProgress $ProgressCallback ($ProgressMaximum * 0.35) 'Filtrowanie logów' 'Przygotowywanie bezpiecznej kopii diagnostycznej.' -TotalFiles $snapshots.Count -Force
    foreach ($snapshot in $snapshots) {
        Assert-MtzCaptureNotCancelled $CancellationCheck
        # Crash report names can include a player-entered suffix. Use a fixed safe archive name.
        $archiveName = $snapshot.Name
        if ($archiveName.StartsWith('crash-reports/')) {
            $crashIndex = @($included | Where-Object { $_.name -like 'crash-reports/*' }).Count + 1
            $archiveName = 'crash-reports/crash-' + $crashIndex + '.txt'
        }
        $text = Protect-MtzDiagnosticText -Text $snapshot.Text -InstancePath $info.RootPath -PlayerNames $aliases
        $bytes = $encoding.GetBytes($text)
        $included.Add([pscustomobject]@{
            name = $archiveName
            sourceBytes = $snapshot.SourceBytes
            sourceLastWriteUtc = $(if ($null -ne $snapshot.SourceLastWriteUtc) { $snapshot.SourceLastWriteUtc.ToString('o') } else { $null })
            archiveBytes = $bytes.Length
            tailOnly = $snapshot.Truncated
        })
        $payloads.Add([pscustomobject]@{ Name = $archiveName; Bytes = $bytes })
        $filteredFiles++
        Send-MtzCaptureProgress $ProgressCallback ($ProgressMaximum * (0.35 + 0.30 * $filteredFiles / [double][Math]::Max(1, $snapshots.Count))) 'Filtrowanie logów' ('Przygotowano {0}/{1} kopii logów.' -f $filteredFiles, $snapshots.Count) -CompletedFiles $filteredFiles -TotalFiles $snapshots.Count
    }
    Send-MtzCaptureProgress $ProgressCallback ($ProgressMaximum * 0.65) 'Manifest diagnostyki' 'Zapisywanie spisu plików i uwag.' -Force
    # ConvertTo-Json on a singleton array can unwrap it on PS5.1; force an explicit JSON array.
    $inventory = ConvertTo-Json -InputObject @($mods.ToArray()) -Depth 4
    $payloads.Add([pscustomobject]@{ Name = 'mods-inventory.json'; Bytes = $encoding.GetBytes($inventory) })
    $manifest = [ordered]@{
        format = 'mtz-diagnostics-1'
        collectorVersion = '0.3.0-rc.1'
        createdUtc = [DateTime]::UtcNow.ToString('o')
        sessionStartedUtc = $(if ($SessionStartedUtc -ne [DateTime]::MinValue) { $SessionStartedUtc.ToUniversalTime().ToString('o') } else { $null })
        scope = 'Selected instance: latest.log, debug.log, up to 3 crash reports, mod filenames and sizes only.'
        sessionOnly = $false
        limits = @{ maxPerLogBytes = $MaxLogBytes; maxTotalSourceBytes = $MaxTotalBytes; maxCrashReports = 3; maxMods = 5000 }
        redaction = 'Best effort: account tokens, passwords, known local paths, UUIDs, URLs, emails, IPs, detected player names. Review before sharing.'
        worldsIncluded = $false
        configsIncluded = $false
        modBinariesIncluded = $false
        networkRequestsMade = $false
        modCount = $mods.Count
        files = @($included.ToArray())
        warnings = @($warnings.ToArray())
    }
    $manifestJson = ConvertTo-Json -InputObject $manifest -Depth 8
    $payloads.Add([pscustomobject]@{ Name = 'manifest.json'; Bytes = $encoding.GetBytes($manifestJson) })
    $notice = @'
MTZ — paczka diagnostyczna

To sa logi ze wskazanej instancji Minecrafta i spis nazw modow.
Nie dolaczono swiata, plikow konfiguracyjnych, launcher_profiles ani plikow modow JAR.
Redakcja danych prywatnych jest automatyczna i nie daje gwarancji wykrycia kazdego wpisu.
Przed udostepnieniem mozesz otworzyc ZIP i sprawdzic jego zawartosc.
Ogon duzego logu moze nie zawierac informacji ze startu gry; manifest oznacza takie pliki tailOnly.
Ta paczka jest zapisem momentu jej utworzenia, nie ciaglym nagraniem calej sesji.
Logi moga zawierac poprzednie wpisy. Znacznik czasu w manifest.json pomaga rozpoznac starsze pliki.
'@
    $payloads.Add([pscustomobject]@{ Name = 'CZYTAJ.txt'; Bytes = $encoding.GetBytes($notice) })
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $basename = 'MTZ-Logi-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $zipPath = Join-Path $output ($basename + '.zip')
    $partialPath = Join-Path $output ($basename + '.partial')
    $fileStream = $null
    $archive = $null
    $partialCreated = $false
    $zipCommitted = $false
    $zipTotalBytes = 0L
    foreach ($payload in $payloads) { $zipTotalBytes += [long]$payload.Bytes.LongLength }
    $zipWrittenBytes = 0L
    $zipWrittenFiles = 0L
    Send-MtzCaptureProgress $ProgressCallback ($ProgressMaximum * 0.70) 'Kompresja diagnostyki' ('Do zapisania: {0:N2} MiB.' -f ($zipTotalBytes / 1MB)) -TotalBytes $zipTotalBytes -TotalFiles $payloads.Count -Force
    try {
        Assert-MtzCaptureNotCancelled $CancellationCheck
        $fileStream = New-Object System.IO.FileStream($partialPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $partialCreated = $true
        $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create, $false)
        foreach ($payload in $payloads) {
            Assert-MtzCaptureNotCancelled $CancellationCheck
            $entry = $archive.CreateEntry($payload.Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $offset = 0
                while ($offset -lt $payload.Bytes.Length) {
                    Assert-MtzCaptureNotCancelled $CancellationCheck
                    $writeLength = [int][Math]::Min(1MB, $payload.Bytes.Length - $offset)
                    $entryStream.Write($payload.Bytes, $offset, $writeLength)
                    $offset += $writeLength
                    $zipWrittenBytes += $writeLength
                    $zipFraction = [double]$zipWrittenBytes / [Math]::Max(1L, $zipTotalBytes)
                    Send-MtzCaptureProgress $ProgressCallback ($ProgressMaximum * (0.70 + 0.28 * $zipFraction)) 'Kompresja diagnostyki' ('Zapisano {0:N2}/{1:N2} MiB.' -f ($zipWrittenBytes / 1MB), ($zipTotalBytes / 1MB)) -CompletedBytes $zipWrittenBytes -TotalBytes $zipTotalBytes -CompletedFiles $zipWrittenFiles -TotalFiles $payloads.Count
                }
            } finally { $entryStream.Dispose() }
            $zipWrittenFiles++
        }
        $archive.Dispose(); $archive = $null
        $fileStream.Dispose(); $fileStream = $null
        Assert-MtzCaptureNotCancelled $CancellationCheck
        [System.IO.File]::Move($partialPath, $zipPath)
        $zipCommitted = $true
        Assert-MtzCaptureNotCancelled $CancellationCheck
        Send-MtzCaptureProgress $ProgressCallback $ProgressMaximum 'Diagnostyka zapisana' 'ZIP diagnostyczny został zamknięty i zapisany.' -CompletedBytes $zipWrittenBytes -TotalBytes $zipTotalBytes -CompletedFiles $zipWrittenFiles -TotalFiles $payloads.Count -Force
        Assert-MtzCaptureNotCancelled $CancellationCheck
    } catch {
        $captureFailure = $_
        $cleanupWarnings = New-Object 'Collections.Generic.List[string]'
        if ($null -ne $archive) { try { $archive.Dispose() } catch { }; $archive = $null }
        if ($null -ne $fileStream) { try { $fileStream.Dispose() } catch { }; $fileStream = $null }
        if ($partialCreated) { Remove-MtzOwnedCaptureFile $partialPath $cleanupWarnings }
        if ($zipCommitted) { Remove-MtzOwnedCaptureFile $zipPath $cleanupWarnings }
        if ($cleanupWarnings.Count -gt 0) { $captureFailure.Exception.Data['MtzCleanupWarnings'] = @($cleanupWarnings.ToArray()) }
        throw $captureFailure
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
    }
    return [pscustomobject]@{
        ZipPath = $zipPath
        Manifest = $manifest
        IncludedFiles = @($included.ToArray())
        Warnings = @($warnings.ToArray())
    }
}
