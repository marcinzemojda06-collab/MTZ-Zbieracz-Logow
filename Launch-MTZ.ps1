#Requires -Version 5.1
[CmdletBinding()]
param([switch]$NoLaunch)
# Shared launcher/installer. Windows PowerShell 5.1 syntax only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-MtzLauncherFiles {
    param([string]$SourceDirectory = '')
    $files = @(
        'Launch-MTZ.ps1', 'MTZ-Logi.ps1', 'core.ps1', 'session.ps1', 'full-bundle.ps1',
        'Collect-Worker.ps1', 'Restore-MTZ-Paczka.ps1', 'bridge/Bridge.cs',
        'Instaluj-MTZ-Logi.ps1', 'Instaluj-MTZ-Logi.cmd',
        'rozszerzenie/manifest.json', 'rozszerzenie/common.js',
        'rozszerzenie/content.js', 'rozszerzenie/service-worker.js',
        'rozszerzenie/README-PL.txt', 'INSTRUKCJA-PL.txt',
        'WERYFIKACJA-PL.txt', 'LICENSE.txt'
    )
    # Optional release documents are copied only when present in this distribution.
    if (-not [string]::IsNullOrWhiteSpace($SourceDirectory)) {
        foreach ($relative in @('START-TUTAJ.txt', 'PRYWATNOSC-PL.txt', 'ZMIANY-0.3.0-rc.2.txt', 'VERSION.json')) {
            if ([IO.File]::Exists((Join-Path $SourceDirectory $relative))) { $files += $relative }
        }
    }
    return $files
}

function Assert-MtzLauncherFiles {
    param([string]$Directory, [string[]]$Files)
    foreach ($relative in $Files) {
        $path = Join-Path $Directory $relative
        $stream = $null
        try {
            if (-not [IO.File]::Exists($path)) { throw 'Brak zwyklego pliku.' }
            $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            if ($stream.ReadByte() -lt 0) { throw 'Plik jest pusty.' }
        } catch {
            $message = 'Wymagany plik jest niedostepny lub pusty: ' + $path + '. Paczka moze byc niekompletnie rozpakowana albo plik mogl zostac usuniety lub przeniesiony do kwarantanny przez ochrone. Sprawdz zawartosc paczki i historie ochrony. Operacja zostala przerwana.'
            throw [IO.IOException]::new($message, $_.Exception)
        } finally { if ($null -ne $stream) { $stream.Dispose() } }
    }
}

function Install-MtzLauncherApplication {
    param([string]$SourceDirectory, [string]$DataDirectory, [string]$LauncherPath)
    # Validate the complete input before moving any installed application.
    $files = @(Get-MtzLauncherFiles -SourceDirectory $SourceDirectory)
    Assert-MtzLauncherFiles -Directory $SourceDirectory -Files $files
    $installed = Join-Path $DataDirectory 'Aplikacja'
    $trim = [char[]]@([char]92, [char]47)
    if ([IO.Path]::GetFullPath($SourceDirectory).TrimEnd($trim).Equals(
            [IO.Path]::GetFullPath($installed).TrimEnd($trim), [StringComparison]::OrdinalIgnoreCase)) {
        # CMD may be running from this very directory. Windows can reject moving
        # its current directory, and the replacement launcher is already here.
        $installedLauncher = Join-Path $installed 'Uruchom-MTZ-Logi.cmd'
        if (-not [IO.Path]::GetFullPath($LauncherPath).Equals(
                [IO.Path]::GetFullPath($installedLauncher), [StringComparison]::OrdinalIgnoreCase)) {
            [IO.File]::Copy($LauncherPath, $installedLauncher, $true)
        }
        return $installed
    }
    $stage = Join-Path $DataDirectory ('Aplikacja-nowa-' + [guid]::NewGuid().ToString('N'))
    $backup = $null
    $operation = 'przygotowanie folderu'; $currentPath = $stage
    try {
        [void][IO.Directory]::CreateDirectory($stage)
        foreach ($relative in $files) {
            $destination = Join-Path $stage $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            $operation = 'kopiowanie pliku aplikacji'; $currentPath = $destination
            # Use normal Windows file copying; keep download/security metadata.
            # User settings and archives are outside the application directory.
            [IO.File]::Copy((Join-Path $SourceDirectory $relative), $destination, $false)
            if ($relative.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
                $tokens = $null; $errors = $null
                [void][Management.Automation.Language.Parser]::ParseFile($destination, [ref]$tokens, [ref]$errors)
                if (@($errors).Count -ne 0) { throw ('Niepoprawny skrypt aplikacji: ' + $relative) }
            }
        }
        $operation = 'kopiowanie launchera'; $currentPath = Join-Path $stage 'Uruchom-MTZ-Logi.cmd'
        [IO.File]::Copy($LauncherPath, $currentPath, $false)
        # A copied file can disappear or become unavailable before commit.
        # Validate the whole prepared directory before moving the old installation.
        $operation = 'sprawdzanie kompletnej aplikacji'; $currentPath = $stage
        Assert-MtzLauncherFiles -Directory $stage -Files ($files + @('Uruchom-MTZ-Logi.cmd'))
        $operation = 'zatwierdzanie instalacji'; $currentPath = $installed
        if ([IO.Directory]::Exists($installed)) {
            $backupRoot = Join-Path $DataDirectory 'Kopie-aplikacji'
            [void][IO.Directory]::CreateDirectory($backupRoot)
            $backup = Join-Path $backupRoot ('Aplikacja-' + [guid]::NewGuid().ToString('N'))
            [IO.Directory]::Move($installed, $backup)
        }
        try { [IO.Directory]::Move($stage, $installed) }
        catch {
            if ($null -ne $backup -and -not [IO.Directory]::Exists($installed)) {
                [IO.Directory]::Move($backup, $installed)
            }
            throw
        }
        return $installed
    } catch {
        $message = 'Etap: ' + $operation + '; plik lub folder: ' + $currentPath + '. ' + $_.Exception.Message
        throw [IO.IOException]::new($message, $_.Exception)
    } finally {
        try { if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) } }
        catch { Write-MtzLauncherCleanupFailure $stage $_ $DataDirectory }
    }
}

function New-MtzLauncherShell { return New-Object -ComObject WScript.Shell }
function Release-MtzLauncherCom {
    param($Value)
    if ($null -ne $Value -and [Runtime.InteropServices.Marshal]::IsComObject($Value)) {
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($Value)
    }
}

function Write-MtzLauncherCleanupFailure {
    param([string]$Path, $Failure, [string]$DataDirectory)
    # Cleanup must never replace the original installation/shortcut error.
    $message = 'Nie udalo sie posprzatac: ' + $Path + "`r`n" + $Failure.Exception.ToString()
    Write-Warning $message -WarningAction Continue
    try { [IO.File]::AppendAllText((Join-Path $DataDirectory 'blad-sprzatania.txt'), $message + "`r`n") } catch { }
}

function New-MtzLauncherShortcut {
    param([string]$DesktopDirectory, [string]$DataDirectory,
          [string]$ApplicationDirectory, [string]$PowerShellPath, [string]$LaunchArguments)
    [void][IO.Directory]::CreateDirectory($DesktopDirectory)
    $target = Join-Path $DesktopDirectory 'MTZ - Zbieracz logow.lnk'
    $temporary = Join-Path $DesktopDirectory ('MTZ-nowy-skrot-' + [guid]::NewGuid().ToString('N') + '.lnk')
    $shell = $null; $link = $null; $check = $null
    try {
        $shell = New-MtzLauncherShell
        $link = $shell.CreateShortcut($temporary)
        $link.TargetPath = $PowerShellPath
        $link.Arguments = $LaunchArguments
        $link.WorkingDirectory = $ApplicationDirectory
        $link.Description = 'MTZ - Zbieracz logow Minecrafta'
        $link.WindowStyle = 1
        $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
        if (-not [string]::IsNullOrWhiteSpace($systemDirectory)) {
            $link.IconLocation = (Join-Path $systemDirectory 'shell32.dll') + ',71'
        }
        $link.Save()
        Release-MtzLauncherCom $link; $link = $null
        if (-not [IO.File]::Exists($temporary)) { throw 'Windows nie zapisal nowego skrotu.' }
        $check = $shell.CreateShortcut($temporary)
        if (-not $PowerShellPath.Equals([string]$check.TargetPath, [StringComparison]::OrdinalIgnoreCase) -or
            $LaunchArguments -cne [string]$check.Arguments -or
            -not $ApplicationDirectory.Equals([string]$check.WorkingDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Nie udalo sie zweryfikowac celu nowego skrotu.'
        }
        Release-MtzLauncherCom $check; $check = $null
        $replaced = [IO.File]::Exists($target)
        if ($replaced) {
            # Both files are on the desktop volume. Replace the old shortcut
            # at its exact name only after the new one has been validated.
            [IO.File]::Replace($temporary, $target, [Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($temporary, $target) }
        return [pscustomobject]@{ Path = $target; ReplacedOld = $replaced }
    } finally {
        Release-MtzLauncherCom $check; Release-MtzLauncherCom $link; Release-MtzLauncherCom $shell
        try { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
        catch { Write-MtzLauncherCleanupFailure $temporary $_ $DataDirectory }
    }
}

function Show-MtzLauncherWarning {
    param([string]$Text)
    Write-Warning $Text
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($Text, 'MTZ - skrot aplikacji', 'OK', 'Warning')
    } catch { }
}

function Get-MtzLauncherLocations {
    if ($env:OS -ne 'Windows_NT') { throw 'Ten program jest przeznaczony dla Windows 10/11.' }
    $dataRoot = [Environment]::GetFolderPath('LocalApplicationData')
    $desktop = [Environment]::GetFolderPath('DesktopDirectory')
    if ([string]::IsNullOrWhiteSpace($dataRoot)) { throw 'Windows nie podal folderu danych aplikacji.' }
    if ([string]::IsNullOrWhiteSpace($desktop)) { throw 'Windows nie podal folderu pulpitu.' }
    return [pscustomobject]@{
        SourceDirectory = $PSScriptRoot
        DataDirectory = (Join-Path $dataRoot 'MTZ-Logi')
        DesktopDirectory = $desktop
        PowerShellPath = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    }
}

function Start-MtzLauncherGui {
    param([string]$PowerShellPath, [string]$Arguments, [string]$ApplicationDirectory)
    Start-Process -FilePath $PowerShellPath -ArgumentList $Arguments -WorkingDirectory $ApplicationDirectory -WindowStyle Hidden
}

function Invoke-MtzLauncher {
    param([switch]$NoLaunch)
    $locations = Get-MtzLauncherLocations
    $source = [IO.Path]::GetFullPath($locations.SourceDirectory)
    $dataDirectory = [IO.Path]::GetFullPath($locations.DataDirectory)
    $desktop = [IO.Path]::GetFullPath($locations.DesktopDirectory)
    $powerShell = $locations.PowerShellPath
    if (-not [IO.File]::Exists($powerShell)) { throw 'Nie znaleziono Windows PowerShell.' }
    if (-not [IO.File]::Exists((Join-Path $source 'MTZ-Logi.ps1'))) {
        throw 'Brakuje MTZ-Logi.ps1. Najpierw wypakuj caly ZIP do jednego folderu.'
    }
    [void][IO.Directory]::CreateDirectory($dataDirectory)
    $expected = Join-Path $dataDirectory 'Aplikacja'
    $trim = [char[]]@([char]92, [char]47)
    $sameDirectory = $source.TrimEnd($trim).Equals($expected.TrimEnd($trim), [StringComparison]::OrdinalIgnoreCase)
    $shortcutOnly = ($NoLaunch -and $sameDirectory)
    $lock = $null; $applicationLock = $null
    $installed = $null; $arguments = $null
    try {
        try { $lock = [IO.File]::Open((Join-Path $dataDirectory 'instalacja.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { throw 'Inne uruchomienie aktualizuje aplikacje. Zamknij je i sprobuj ponownie.' }
        if ($shortcutOnly) {
            # The running GUI may repair its shortcut. Do not replace any code.
            $installed = $expected
        } else {
            try { $applicationLock = [IO.File]::Open((Join-Path $dataDirectory 'aplikacja.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch { throw 'MTZ Zbieracz jest juz uruchomiony. Zamknij jego okno i poczekaj na zakonczenie zbierania przed aktualizacja.' }
            $launcher = Join-Path $source 'Uruchom-MTZ-Logi.cmd'
            $installed = Install-MtzLauncherApplication -SourceDirectory $source -DataDirectory $dataDirectory -LauncherPath $launcher
        }
        $main = Join-Path $installed 'MTZ-Logi.ps1'
        $arguments = '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $main + '"'
        $shortcut = New-MtzLauncherShortcut -DesktopDirectory $desktop -DataDirectory $dataDirectory -ApplicationDirectory $installed -PowerShellPath $powerShell -LaunchArguments $arguments
    } finally {
        # Do not remove either lock file: replacing the path could bypass an open lock.
        if ($null -ne $applicationLock) { $applicationLock.Dispose() }
        if ($null -ne $lock) { $lock.Dispose() }
    }
    # GUI takes its own application lock; release the installer lock first.
    if (-not $NoLaunch) { Start-MtzLauncherGui -PowerShellPath $powerShell -Arguments $arguments -ApplicationDirectory $installed }
}

try { Invoke-MtzLauncher -NoLaunch:$NoLaunch }
catch {
    $failure = $_
    Write-Host ('MTZ: ' + $failure.Exception.Message) -ForegroundColor Red
    try {
        $dataRoot = [Environment]::GetFolderPath('LocalApplicationData')
        if (-not [string]::IsNullOrWhiteSpace($dataRoot)) {
            $directory = Join-Path $dataRoot 'MTZ-Logi'
            [void][IO.Directory]::CreateDirectory($directory)
            $details = $failure.Exception.ToString() + "`r`n" + $failure.InvocationInfo.PositionMessage + "`r`n" + $failure.ScriptStackTrace
            [IO.File]::WriteAllText((Join-Path $directory 'blad-instalacji.txt'), $details)
        }
    } catch { }
    # Preserve a terminating error for the GUI's installer call as well as CMD.
    # A nested "exit 1" could otherwise return to a wrapper that reports success.
    throw
}
