# Session observer: pure transitions; no process launch or network.
function Test-MtzChatUrl {
    param([AllowEmptyString()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($Value.Trim(), [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'chatgpt.com' -or -not $uri.IsDefaultPort -or $uri.UserInfo) { return $false }
    return ($uri.AbsolutePath -match '^/(?:g/[A-Za-z0-9_-]+/)?c/[A-Za-z0-9-]+/?$' -and -not $uri.Query)
}

function New-MtzSessionState {
    param([string]$Fingerprint = '', [DateTime]$NowUtc = [DateTime]::UtcNow)
    [pscustomobject]@{
        StartedUtc = $NowUtc
        LastChangeUtc = $NowUtc
        Fingerprint = $Fingerprint
        SeenGame = $false
        SeenLogChange = $false
        Completed = $false
        IsRunning = $false
        Status = 'Oczekiwanie na Minecrafta'
        ShouldCollect = $false
    }
}

function Update-MtzSessionState {
    param(
        [Parameter(Mandatory = $true)]$State,
        [string]$Fingerprint,
        [bool]$ProcessStateKnown,
        [bool]$GameRunning,
        [DateTime]$NowUtc = [DateTime]::UtcNow
    )
    $State.ShouldCollect = $false
    if ($Fingerprint -ne $State.Fingerprint) {
        $State.Fingerprint = $Fingerprint
        $State.LastChangeUtc = $NowUtc
        $State.SeenLogChange = $true
    }
    $State.IsRunning = ($ProcessStateKnown -and $GameRunning)
    if ($State.IsRunning) {
        if ($State.Completed) {
            # A new game process is a new observation, even if latest.log has not rotated yet.
            $State.StartedUtc = $NowUtc
            $State.SeenLogChange = $false
        }
        $State.SeenGame = $true
        $State.Completed = $false
        $State.Status = 'Minecraft dziala - obserwuje logi'
    } elseif ($ProcessStateKnown -and $State.SeenGame -and -not $State.Completed) {
        if (($NowUtc - $State.LastChangeUtc).TotalSeconds -ge 12) {
            $State.ShouldCollect = $true
            $State.Completed = $true
            $State.Status = 'Minecraft zamkniety - przygotowuje ZIP'
        } else {
            $State.Status = 'Czekam na koncowe wpisy logow'
        }
    } elseif ($State.Completed) {
        $State.Status = 'Sesja zakonczona - paczka gotowa'
    } elseif ($State.SeenLogChange) {
        $State.Status = 'Logi sie zmieniaja; ZIP mozesz przygotowac przyciskiem'
    } else {
        $State.Status = 'Oczekiwanie na Minecrafta'
    }
    return $State
}

function Split-MtzWindowsArguments {
    param([AllowEmptyString()][string]$CommandLine)
    # Windows C-runtime quoting rules. No evaluation, process launch or file access.
    # https://learn.microsoft.com/cpp/c-language/parsing-c-command-line-arguments
    $arguments = New-Object 'Collections.Generic.List[string]'
    $position = 0
    while ($position -lt $CommandLine.Length) {
        while ($position -lt $CommandLine.Length -and ($CommandLine[$position] -eq ' ' -or $CommandLine[$position] -eq [char]9)) { $position++ }
        if ($position -ge $CommandLine.Length) { break }
        $word = New-Object Text.StringBuilder
        $quoted = $false
        while ($position -lt $CommandLine.Length) {
            if (-not $quoted -and ($CommandLine[$position] -eq ' ' -or $CommandLine[$position] -eq [char]9)) { break }
            $slashes = 0
            while ($position -lt $CommandLine.Length -and $CommandLine[$position] -eq [char]92) { $slashes++; $position++ }
            if ($position -lt $CommandLine.Length -and $CommandLine[$position] -eq '"') {
                [void]$word.Append([char]92, [int][Math]::Floor($slashes / 2))
                if (($slashes % 2) -eq 1) { [void]$word.Append('"'); $position++ }
                elseif ($quoted -and $position + 1 -lt $CommandLine.Length -and $CommandLine[$position + 1] -eq '"') {
                    [void]$word.Append('"'); $position += 2
                } else { $quoted = -not $quoted; $position++ }
                continue
            }
            [void]$word.Append([char]92, $slashes)
            if ($position -ge $CommandLine.Length) { break }
            if (-not $quoted -and ($CommandLine[$position] -eq ' ' -or $CommandLine[$position] -eq [char]9)) { break }
            [void]$word.Append($CommandLine[$position]); $position++
        }
        $arguments.Add($word.ToString())
    }
    return $arguments.ToArray()
}

function Get-MtzGameProcessState {
    param([Parameter(Mandatory = $true)][string]$InstancePath)
    $full = [System.IO.Path]::GetFullPath($InstancePath)
    if ($full.TrimEnd([char[]]'\/') -eq [System.IO.Path]::GetPathRoot($full).TrimEnd([char[]]'\/')) {
        throw 'Wybierz folder instancji Minecrafta, nie glowny folder dysku.'
    }
    $root = $full.TrimEnd([char[]]'\/')
    $unknown = $false
    try {
        $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction Stop)
        foreach ($process in $processes) {
            $commandLine = [string]$process.CommandLine
            if ([string]::IsNullOrWhiteSpace($commandLine)) { $unknown = $true; continue }
            # Command lines are inspected in memory only; never stored or displayed.
            # Tokenizing first prevents a --gameDir string inside -Dnote="..." from
            # being mistaken for the actual game argument.
            $arguments = @(Split-MtzWindowsArguments -CommandLine $commandLine)
            $candidates = New-Object 'Collections.Generic.List[string]'
            $usesArgumentFile = $false
            for ($argument = 1; $argument -lt $arguments.Count; $argument++) {
                $value = $arguments[$argument]
                if ($value.StartsWith('@', [StringComparison]::Ordinal)) { $usesArgumentFile = $true }
                if ($value.Equals('--gameDir', [StringComparison]::OrdinalIgnoreCase)) {
                    if ($argument + 1 -ge $arguments.Count) { $unknown = $true; continue }
                    $argument++
                    $candidates.Add($arguments[$argument])
                } elseif ($value.StartsWith('--gameDir=', [StringComparison]::OrdinalIgnoreCase)) {
                    $candidates.Add($value.Substring('--gameDir='.Length))
                }
            }
            # Do not open arbitrary Java @argument files. A visible gameDir is
            # sufficient for normal launchers using @files for JVM parameters;
            # without it the selected instance cannot be determined reliably.
            if ($candidates.Count -gt 1) { $unknown = $true; continue }
            if ($candidates.Count -eq 0) {
                if ($usesArgumentFile) { $unknown = $true }
                continue
            }
            $candidate = $candidates[0]
            if ([string]::IsNullOrWhiteSpace($candidate)) { $unknown = $true; continue }
            if (-not [System.IO.Path]::IsPathRooted($candidate)) { $unknown = $true; continue }
            try {
                $normalized = [System.IO.Path]::GetFullPath($candidate).TrimEnd([char[]]'\/')
                if ($normalized.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [pscustomobject]@{ Known = $true; Running = $true }
                }
            } catch { $unknown = $true }
        }
        return [pscustomobject]@{ Known = (-not $unknown); Running = $false }
    } catch {
        return [pscustomobject]@{ Known = $false; Running = $false }
    }
}
