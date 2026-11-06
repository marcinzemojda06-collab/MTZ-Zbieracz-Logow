param([string]$ApplicationDirectory = (Split-Path $PSScriptRoot -Parent),
      [string]$LauncherPath = '', [string]$OutputDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$results = New-Object 'Collections.Generic.List[string]'
function Assert-MtzTest([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw ('FAIL: ' + $Name) }
    $results.Add($Name)
}
$cmd = $LauncherPath
if ([string]::IsNullOrWhiteSpace($cmd)) { $cmd = Join-Path $ApplicationDirectory 'Uruchom-MTZ-Logi.cmd' }
$text = [IO.File]::ReadAllText($cmd)
$launcherScript = Join-Path $ApplicationDirectory 'Launch-MTZ.ps1'
$payload = [IO.File]::ReadAllText($launcherScript)
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$errors)
Assert-MtzTest (@($errors).Count -eq 0) 'Actual shared launcher parses without errors'
Assert-MtzTest ($text.Contains('-File "%~dp0Launch-MTZ.ps1"') -and -not $text.Contains('ScriptBlock')) 'CMD invokes transparent script without embedded dynamic code'
Assert-MtzTest ($text.Contains('setlocal DisableDelayedExpansion')) 'CMD preserves exclamation marks structurally'
Assert-MtzTest (-not ($text + $payload).Contains('Set-ExecutionPolicy')) 'No persistent execution-policy change'
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([ScriptBlock]::Create($node.Extent.Text))
}

# The fake saves JSON, not Windows .lnk bytes. It checks field handling and
# failure branches; this is explicitly not a Windows COM/Explorer test.
$script:fakeCorrupt = $false
$script:fakeDeny = $false
function New-MtzLauncherShell {
    $shell = [pscustomobject]@{}
    $shell | Add-Member ScriptMethod CreateShortcut {
        param($Path)
        $link = [pscustomobject]@{ Path = $Path; TargetPath = ''; Arguments = ''; WorkingDirectory = ''; Description = ''; WindowStyle = 0; IconLocation = '' }
        if ([IO.File]::Exists($Path)) {
            $saved = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
            $link.TargetPath = $saved.TargetPath; $link.Arguments = $saved.Arguments
            $link.WorkingDirectory = $saved.WorkingDirectory
        }
        $link | Add-Member ScriptMethod Save {
            if ($script:fakeDeny) { throw [UnauthorizedAccessException]::new('Simulated desktop/COM save denial') }
            if ($script:fakeCorrupt) { $this.TargetPath = 'incorrect.exe' }
            [IO.File]::WriteAllText($this.Path, ($this | Select-Object TargetPath,Arguments,WorkingDirectory | ConvertTo-Json))
        }
        return $link
    }
    return $shell
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('MTZ-Launcher-Tests-' + [guid]::NewGuid().ToString('N'))
$source = Join-Path $root "Zrodla ą & ! ' %folder%"
$data = Join-Path $root "Dane ę & ! ' %folder%"
$desktop = Join-Path $root "OneDrive/Pulpit ą & ! ' %folder%"
$previousSystemRoot = $env:SystemRoot
$env:SystemRoot = $root
[void][IO.Directory]::CreateDirectory($source)
[void][IO.Directory]::CreateDirectory($data)
[void][IO.Directory]::CreateDirectory($desktop)
$original = $ApplicationDirectory
foreach ($relative in @(Get-MtzLauncherFiles)) {
    $destination = Join-Path $source $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
    [IO.File]::Copy((Join-Path $original $relative), $destination)
}
$settings = Join-Path $data 'ustawienia.json'
$archive = Join-Path $data 'Paczki/stara-paczka.zip'
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($archive))
[IO.File]::WriteAllText($settings, '{"instance":"KEEP"}')
[IO.File]::WriteAllText($archive, 'KEEP ARCHIVE')
$app = Install-MtzLauncherApplication $source $data $cmd
Assert-MtzTest ([IO.File]::Exists((Join-Path $app 'MTZ-Logi.ps1'))) 'First installation creates main application'
Assert-MtzTest ((Get-FileHash (Join-Path $app 'Uruchom-MTZ-Logi.cmd')).Hash -eq (Get-FileHash $cmd).Hash) 'Installed launcher matches replacement CMD'
Assert-MtzTest ([IO.File]::ReadAllText($settings) -eq '{"instance":"KEEP"}') 'Settings preserved on first installation'
Assert-MtzTest ([IO.File]::ReadAllText($archive) -eq 'KEEP ARCHIVE') 'Existing archives preserved on first installation'
$allCopied = @(@(Get-MtzLauncherFiles) | Where-Object { (Get-FileHash (Join-Path $source $_)).Hash -ne (Get-FileHash (Join-Path $app $_)).Hash }).Count -eq 0
Assert-MtzTest $allCopied 'All whitelisted application bytes preserved'
Assert-MtzTest (-not [IO.File]::Exists((Join-Path $app 'ustawienia.json'))) 'User settings are outside replacement code folder'

[IO.File]::WriteAllText((Join-Path $app 'uzytkownik.txt'), 'KEEP UNRECOGNIZED FILE')
[IO.File]::AppendAllText((Join-Path $source 'MTZ-Logi.ps1'), "`n# Update fixture`n")
$app = Install-MtzLauncherApplication $source $data $cmd
Assert-MtzTest ((Get-FileHash (Join-Path $source 'MTZ-Logi.ps1')).Hash -eq (Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash) 'Update installs changed application bytes'
$old = @(Get-ChildItem (Join-Path $data 'Kopie-aplikacji') -Directory)
Assert-MtzTest ($old.Count -eq 1 -and [IO.File]::ReadAllText((Join-Path $old[0].FullName 'uzytkownik.txt')) -eq 'KEEP UNRECOGNIZED FILE') 'Previous application and unknown files retained in backup'
Assert-MtzTest ([IO.File]::ReadAllText($settings) -eq '{"instance":"KEEP"}' -and [IO.File]::ReadAllText($archive) -eq 'KEEP ARCHIVE') 'Update preserves settings and archives'
$mainHash = (Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash
$missing = Join-Path $source 'core.ps1'
$coreBytes = [IO.File]::ReadAllBytes($missing)
[IO.File]::Delete($missing)
$failed = $false
try { Install-MtzLauncherApplication $source $data $cmd | Out-Null } catch { $failed = $true }
Assert-MtzTest $failed 'Missing input file rejects update'
Assert-MtzTest ((Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash -eq $mainHash) 'Missing input leaves installed application intact'
[IO.File]::WriteAllText($missing, 'function {')
$failed = $false
try { Install-MtzLauncherApplication $source $data $cmd | Out-Null } catch { $failed = $true }
Assert-MtzTest $failed 'Malformed PowerShell input rejects update'
Assert-MtzTest ((Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash -eq $mainHash) 'Malformed input leaves installed application intact'
Assert-MtzTest (@(Get-ChildItem $data -Directory -Filter 'Aplikacja-nowa-*').Count -eq 0) 'Failed update cleans only its temporary staging directory'
[IO.File]::WriteAllBytes($missing, $coreBytes)
$backupCount = @(Get-ChildItem (Join-Path $data 'Kopie-aplikacji') -Directory).Count
$app = Install-MtzLauncherApplication $app $data (Join-Path $app 'Uruchom-MTZ-Logi.cmd')
Assert-MtzTest ((Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash -eq $mainHash) 'Running replacement from installed directory preserves program'
Assert-MtzTest (@(Get-ChildItem (Join-Path $data 'Kopie-aplikacji') -Directory).Count -eq $backupCount) 'Installed CMD never moves its own running directory'

$exe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments = '-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + (Join-Path $app 'MTZ-Logi.ps1') + '"'
$link = New-MtzLauncherShortcut $desktop $data $app $exe $arguments
Assert-MtzTest (-not $link.ReplacedOld) 'Fresh desktop uses standard application name'
$saved = [IO.File]::ReadAllText($link.Path) | ConvertFrom-Json
Assert-MtzTest ($saved.TargetPath -ceq $exe) 'Shortcut target is executable alone'
Assert-MtzTest ($saved.Arguments -ceq $arguments) 'Separate quoted arguments preserve complex path characters'
Assert-MtzTest ($saved.WorkingDirectory -ceq $app) 'Shortcut working directory is stable installed directory'
$before = [IO.File]::ReadAllText($link.Path)
$newArguments = $arguments + ' -NoGui'
$originalPath = $link.Path
$link = New-MtzLauncherShortcut $desktop $data $app $exe $newArguments
Assert-MtzTest ($link.ReplacedOld -and $link.Path -ceq $originalPath) 'Existing shortcut is replaced at exactly the original name'
Assert-MtzTest (([IO.File]::ReadAllText($link.Path) | ConvertFrom-Json).Arguments -ceq $newArguments) 'New shortcut content replaces old content'
Assert-MtzTest (@(Get-ChildItem $desktop -File -Filter '*.lnk').Count -eq 1) 'Successful replacement leaves one desktop shortcut'

[IO.File]::Delete($link.Path)
[void][IO.Directory]::CreateDirectory($link.Path)
$failed = $false
try { New-MtzLauncherShortcut $desktop $data $app $exe $arguments | Out-Null } catch { $failed = $true }
Assert-MtzTest $failed 'Nonreplaceable old path returns failure'
Assert-MtzTest ([IO.Directory]::Exists($originalPath)) 'Replacement failure leaves nonreplaceable old path intact'
Assert-MtzTest (@(Get-ChildItem $desktop -File -Filter '*.lnk').Count -eq 0) 'Failure never creates alternate desktop shortcut names'
[IO.Directory]::Delete($originalPath)
[IO.File]::WriteAllText($originalPath, $before)

$script:fakeCorrupt = $true; $failed = $false
try { New-MtzLauncherShortcut $desktop $data $app $exe $arguments | Out-Null } catch { $failed = $true }
Assert-MtzTest $failed 'Shortcut readback detects incorrect saved target'
Assert-MtzTest ([IO.File]::ReadAllText($originalPath) -ceq $before) 'Incorrect new target never replaces old shortcut'
$script:fakeCorrupt = $false; $script:fakeDeny = $true; $failed = $false
try { New-MtzLauncherShortcut $desktop $data $app $exe $arguments | Out-Null } catch { $failed = $true }
Assert-MtzTest $failed 'Desktop write denial returns failure instead of claiming shortcut success'
Assert-MtzTest ([IO.File]::ReadAllText($originalPath) -ceq $before) 'Desktop save denial preserves old shortcut'
Assert-MtzTest (@(Get-ChildItem $desktop -File -Filter 'MTZ-nowy-skrot-*').Count -eq 0) 'Shortcut failures remove temporary files'
Assert-MtzTest ([IO.File]::ReadAllText($settings) -eq '{"instance":"KEEP"}' -and [IO.File]::ReadAllText($archive) -eq 'KEEP ARCHIVE') 'All shortcut failure cases preserve user data'
# Inject a cleanup-denial exception at the exact Directory.Delete call site.
# The real install catch/finally must retain its earlier parse failure.
$definition = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-MtzLauncherApplication' }, $false)[0].Extent.Text
$injected = $definition.Replace('[IO.Directory]::Delete($stage, $true)', "throw [UnauthorizedAccessException]::new('Cleanup denied fixture')")
. ([ScriptBlock]::Create($injected))
[IO.File]::WriteAllText($missing, 'function {')
$observed = ''; $warnings = @()
try { Install-MtzLauncherApplication $source $data $cmd 3>&1 | ForEach-Object { if ($_ -is [Management.Automation.WarningRecord]) { $warnings += $_ } } }
catch { $observed = $_.Exception.ToString() }
Assert-MtzTest ($observed.Contains('Niepoprawny skrypt aplikacji: core.ps1')) 'Cleanup failure does not mask original script error'
Assert-MtzTest ($observed.Contains('Etap:') -and $observed.Contains('core.ps1')) 'Original error records operation and affected path'
Assert-MtzTest ([IO.File]::ReadAllText((Join-Path $data 'blad-sprzatania.txt')).Contains('Cleanup denied fixture')) 'Cleanup denial is logged separately'
Assert-MtzTest ($warnings.Count -gt 0) 'Cleanup denial is reported as a warning'
Assert-MtzTest ((Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash -eq $mainHash) 'Combined install and cleanup failures preserve installed application'
. ([ScriptBlock]::Create($definition))
[IO.File]::WriteAllBytes($missing, $coreBytes)
# Both public entry points must use the shared implementation. Run the real
# installer wrapper against a tiny fixture launcher; no GUI or system changes.
$wrapperRoot = Join-Path $root 'installer-wrapper'
[void][IO.Directory]::CreateDirectory($wrapperRoot)
[IO.File]::Copy((Join-Path $ApplicationDirectory 'Instaluj-MTZ-Logi.ps1'), (Join-Path $wrapperRoot 'Instaluj-MTZ-Logi.ps1'))
[IO.File]::WriteAllText((Join-Path $wrapperRoot 'Launch-MTZ.ps1'), @'
param([switch]$NoLaunch)
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'observed.json'), (@{ NoLaunch = [bool]$NoLaunch } | ConvertTo-Json))
'@)
& (Join-Path $wrapperRoot 'Instaluj-MTZ-Logi.ps1') -NoLaunch
$observedWrapper = [IO.File]::ReadAllText((Join-Path $wrapperRoot 'observed.json')) | ConvertFrom-Json
Assert-MtzTest $observedWrapper.NoLaunch 'Installer preserves NoLaunch when delegating'
& (Join-Path $wrapperRoot 'Instaluj-MTZ-Logi.ps1')
$observedWrapper = [IO.File]::ReadAllText((Join-Path $wrapperRoot 'observed.json')) | ConvertFrom-Json
Assert-MtzTest (-not $observedWrapper.NoLaunch) 'Normal installer delegates launch request'
[IO.File]::WriteAllText((Join-Path $wrapperRoot 'Launch-MTZ.ps1'), 'param([switch]$NoLaunch); throw "Fixture shared launcher failure"')
$failed = $false
try { & (Join-Path $wrapperRoot 'Instaluj-MTZ-Logi.ps1') -NoLaunch } catch { $failed = $true }
Assert-MtzTest $failed 'Installer propagates shared launcher failure to GUI caller'

# Exercise the real orchestration with controlled locations and COM/start mocks.
$script:fakeDeny = $false; $script:fakeCorrupt = $false
$fixtureExe = Join-Path $root 'powershell-fixture.exe'
[IO.File]::WriteAllText($fixtureExe, 'Not executable: Start-MtzLauncherGui is mocked')
$script:launcherLocations = [pscustomobject]@{
    SourceDirectory = $source; DataDirectory = $data
    DesktopDirectory = $desktop; PowerShellPath = $fixtureExe
}
function Get-MtzLauncherLocations { return $script:launcherLocations }
$script:guiStarts = 0
function Start-MtzLauncherGui {
    param($PowerShellPath, $Arguments, $ApplicationDirectory)
    $script:guiStarts++
    # Starting the GUI while retaining the application lock would block it.
    $free = [IO.File]::Open((Join-Path $data 'aplikacja.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $free.Dispose()
}
# Fixture source needs the standard CMD now used by real orchestration.
[IO.File]::Copy($cmd, (Join-Path $source 'Uruchom-MTZ-Logi.cmd'))
Invoke-MtzLauncher -NoLaunch
Assert-MtzTest ($script:guiStarts -eq 0) 'NoLaunch updates transactionally without starting GUI'
$beforeLockedUpdate = (Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash
[IO.File]::AppendAllText((Join-Path $source 'MTZ-Logi.ps1'), "`n# Change rejected while GUI is active`n")
$appLock = [IO.File]::Open((Join-Path $data 'aplikacja.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $failed = $false
    try { Invoke-MtzLauncher -NoLaunch } catch { $failed = $true }
    Assert-MtzTest $failed 'Active GUI lock rejects code replacement'
    Assert-MtzTest ((Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash -eq $beforeLockedUpdate) 'Rejected update leaves application bytes unchanged'
    $script:launcherLocations.SourceDirectory = $app
    $backupsBeforeShortcut = @(Get-ChildItem (Join-Path $data 'Kopie-aplikacji') -Directory).Count
    Invoke-MtzLauncher -NoLaunch
    Assert-MtzTest (@(Get-ChildItem (Join-Path $data 'Kopie-aplikacji') -Directory).Count -eq $backupsBeforeShortcut) 'Running GUI may repair shortcut without replacing code'
    Assert-MtzTest ((Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash -eq $beforeLockedUpdate) 'Shortcut-only operation preserves running application'
    $failed = $false
    try { Invoke-MtzLauncher } catch { $failed = $true }
    Assert-MtzTest $failed 'Normal second launch does not bypass active GUI lock'
} finally { $appLock.Dispose() }
$script:launcherLocations.SourceDirectory = $source
Invoke-MtzLauncher
Assert-MtzTest ($script:guiStarts -eq 1) 'Successful normal launch releases app lock before GUI starts'
Assert-MtzTest ((Get-FileHash (Join-Path $app 'MTZ-Logi.ps1')).Hash -eq (Get-FileHash (Join-Path $source 'MTZ-Logi.ps1')).Hash) 'Update installs the complete new source after GUI exits'
Assert-MtzTest ([IO.File]::ReadAllText($settings) -eq '{"instance":"KEEP"}' -and [IO.File]::ReadAllText($archive) -eq 'KEEP ARCHIVE') 'Entry-point update preserves settings and archives'
$installLock = [IO.File]::Open((Join-Path $data 'instalacja.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    $failed = $false
    try { Invoke-MtzLauncher -NoLaunch } catch { $failed = $true }
    Assert-MtzTest $failed 'Concurrent installer lock rejects another update'
} finally { $installLock.Dispose() }
Assert-MtzTest ([IO.File]::Exists((Join-Path $data 'instalacja.lock')) -and [IO.File]::Exists((Join-Path $data 'aplikacja.lock'))) 'Lock paths persist after release to avoid lock replacement race'
$report = [ordered]@{
    launcherRevision = '0.3.0-rc.1'; antivirusResolutionVerified = $false
    status = 'PASS'; checks = $results.Count; checksPassed = @($results)
    runtime = $PSVersionTable.PSVersion.ToString(); platform = [Environment]::OSVersion.Platform.ToString()
    actualWindowsRun = $false; actualComShortcut = $false; emulatedShell = $true
    boundary = 'Real filesystem and PowerShell parser; JSON shortcut fake, no Windows PowerShell 5.1/COM/Explorer/OneDrive runtime execution.'
    launcherSha256 = (Get-FileHash $cmd -Algorithm SHA256).Hash.ToLowerInvariant()
    sharedLauncherSha256 = (Get-FileHash $launcherScript -Algorithm SHA256).Hash.ToLowerInvariant()
}
$report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'launch-results.json') -Encoding utf8
Write-Output ('PASS: ' + $results.Count + ' checks; realFilesystem=true fakeCom=true actualWindows=false')
[IO.Directory]::Delete($root, $true)
$env:SystemRoot = $previousSystemRoot
