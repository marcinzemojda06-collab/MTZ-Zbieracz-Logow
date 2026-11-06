#Requires -Version 5.1
[CmdletBinding()]
param([switch]$NoGui)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
function Open-MtzApplicationLock {
    param([Parameter(Mandatory = $true)][string]$DataDirectory)
    [void][IO.Directory]::CreateDirectory($DataDirectory)
    return [IO.File]::Open((Join-Path $DataDirectory 'aplikacja.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
$script:applicationLock = $null
if (-not $NoGui) {
    if ($env:OS -ne 'Windows_NT') { throw 'Ten program graficzny jest przeznaczony dla Windows 10/11.' }
    $script:dataDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MTZ-Logi'
    # Lock before loading any replaceable dependencies or compiling the bridge.
    try { $script:applicationLock = Open-MtzApplicationLock -DataDirectory $script:dataDir }
    catch {
        $message = 'Nie można otworzyć zbieracza. Sprawdź, czy jego drugie okno lub instalator nie są już uruchomione i czy masz dostęp do folderu danych aplikacji.'
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][Windows.Forms.MessageBox]::Show($message, 'MTZ — aplikacja jest zajęta', 'OK', 'Information')
        } catch { }
        throw $message
    }
}
. (Join-Path $PSScriptRoot 'core.ps1')
. (Join-Path $PSScriptRoot 'session.ps1')

# Quote one argument for CreateProcess / Windows PowerShell -File. No user text is evaluated as code.
function ConvertTo-MtzProcessArgument {
    param([AllowEmptyString()][string]$Value)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) { $slashes++; continue }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, (2 * $slashes + 1))
            [void]$builder.Append([char]34)
        } else {
            if ($slashes -gt 0) { [void]$builder.Append([char]92, $slashes) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append([char]92, (2 * $slashes)) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

# A bounded, data-only snapshot from the current worker. Missing/locked/old snapshots
# leave the last visible value intact; only Complete-MtzWorker may show 100 percent.
function Read-MtzCaptureProgress {
    param([string]$JobDirectory, [long]$AfterSequence = -1)
    $stream = $null
    $reader = $null
    try {
        if ([string]::IsNullOrWhiteSpace($JobDirectory)) { return $null }
        $path = Join-Path $JobDirectory 'progress.json'
        if (-not [IO.File]::Exists($path)) { return $null }
        $stream = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -le 0 -or $stream.Length -gt 16384) { return $null }
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)))
        $snapshot = $reader.ReadToEnd() | ConvertFrom-Json
        if ($null -eq $snapshot) { return $null }
        foreach ($name in @('Version', 'Sequence', 'Percent', 'Stage', 'Detail')) {
            if ($snapshot.PSObject.Properties.Name -notcontains $name) { return $null }
        }
        if ($snapshot.Version -ne 1) { return $null }
        $sequence = [long]$snapshot.Sequence
        $percent = [double]$snapshot.Percent
        if ($sequence -lt 0 -or $sequence -le $AfterSequence -or
            [double]::IsNaN($percent) -or [double]::IsInfinity($percent) -or
            $percent -lt 0 -or $percent -gt 99 -or $percent -ne [Math]::Floor($percent)) { return $null }
        $stage = [string]$snapshot.Stage
        $detail = [string]$snapshot.Detail
        if ($stage.Length -gt 120) { $stage = $stage.Substring(0, 120) }
        if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) }
        return [pscustomobject]@{ Sequence = $sequence; Percent = [int]$percent; Stage = $stage; Detail = $detail }
    } catch { return $null }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Assert-MtzReadyArchive {
    param([string]$Path, [long]$MaximumBytes = 31457280)
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -lt 4 -or $file.Length -gt $MaximumBytes) {
        throw 'Jedna z części ZIP jest nieprawidłowa lub przekracza limit 30 MiB. Sprawdź folder paczek.'
    }
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    $stream = $null
    $archive = $null
    try {
        $stream = New-Object IO.FileStream($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $archive = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Read, $true)
        # Loading the central directory rejects arbitrary or truncated files without
        # reading/decompressing every byte of a potentially large multipart capture.
        if ($archive.Entries.Count -eq 0) { throw 'Jedna z części ZIP nie zawiera danych.' }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}
function Get-MtzSuggestedInstances {
    param(
        [string]$UserProfile = [Environment]::GetFolderPath('UserProfile'),
        [string]$RoamingData = [Environment]::GetFolderPath('ApplicationData')
    )
    # Only inspect the standard launchers' immediate profile directories. Never
    # scan a drive, read launcher accounts or silently select a found profile.
    $choices = New-Object 'Collections.Generic.List[object]'
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $paths = New-Object 'Collections.Generic.List[object]'
    if (-not [string]::IsNullOrWhiteSpace($UserProfile)) {
        $instances = Join-Path $UserProfile 'curseforge/minecraft/Instances'
        if ([IO.Directory]::Exists($instances)) {
            try {
                $directory = Get-Item -LiteralPath $instances -Force
                if (-not ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    foreach ($child in @(Get-ChildItem -LiteralPath $instances -Directory -ErrorAction Stop | Select-Object -First 200)) {
                        $paths.Add([pscustomobject]@{ Path = $child.FullName; Launcher = 'CurseForge' })
                    }
                }
            } catch { }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($RoamingData)) {
        $paths.Add([pscustomobject]@{ Path = (Join-Path $RoamingData '.minecraft'); Launcher = 'Minecraft Launcher' })
    }
    foreach ($entry in $paths) {
        try {
            $info = Get-MtzInstanceInfo -InstancePath $entry.Path
            if ($seen.Add($info.RootPath)) {
                $choices.Add([pscustomobject]@{ Path = $info.RootPath; Label = ($entry.Launcher + ' — ' + $info.DisplayName + '  |  ' + $info.RootPath) })
            }
        } catch { }
    }
    return @($choices | Sort-Object Label)
}
function Read-MtzUserPreferences {
    param([Parameter(Mandatory = $true)][string]$Path)
    $preferences = [pscustomobject]@{ InstancePath = ''; ConversationUrl = ''; CaptureMode = 'Diagnostics'; Warning = '' }
    if (-not [IO.File]::Exists($Path)) { return $preferences }
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($file.Length -gt 65536) { throw 'Settings file is too large.' }
        $raw = [IO.File]::ReadAllText($Path)
        if (-not $raw.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'Invalid settings object.' }
        $saved = $raw | ConvertFrom-Json
        if ($null -eq $saved -or $saved.GetType().FullName -ne 'System.Management.Automation.PSCustomObject') { throw 'Invalid settings object.' }
        if ($saved.PSObject.Properties.Name -contains 'InstancePath' -and $saved.InstancePath -is [string]) {
            $preferences.InstancePath = [string]$saved.InstancePath
        }
        if ($saved.PSObject.Properties.Name -contains 'ConversationUrl' -and $saved.ConversationUrl -is [string] -and (Test-MtzChatUrl $saved.ConversationUrl)) {
            $preferences.ConversationUrl = [string]$saved.ConversationUrl
        }
        if ($saved.PSObject.Properties.Name -contains 'CaptureMode' -and $saved.CaptureMode -is [string] -and $saved.CaptureMode -eq 'Full') { $preferences.CaptureMode = 'Full' }
    } catch {
        $preferences.Warning = 'Nie udało się odczytać ustawień. Wybierz profil i zakres paczki ponownie.'
    }
    return $preferences
}
if ($NoGui) { return }
if ($env:OS -ne 'Windows_NT') { throw 'Ten program graficzny jest przeznaczony dla Windows 10/11.' }
trap {
    $failure = [string]$_.Exception.Message
    try {
        $failure = Protect-MtzDiagnosticText -Text $failure
        $failureDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MTZ-Logi'
        [void][IO.Directory]::CreateDirectory($failureDirectory)
        [IO.File]::WriteAllText((Join-Path $failureDirectory 'blad-uruchomienia.txt'), $failure, (New-Object Text.UTF8Encoding($false)))
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($failure, 'MTZ — nie udało się uruchomić', 'OK', 'Error')
    } catch { }
    exit 1
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot 'bridge/Bridge.cs')
[Windows.Forms.Application]::EnableVisualStyles()
$script:dataDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'MTZ-Logi'
$script:outputDir = Join-Path $script:dataDir 'Paczki'
$script:jobsDir = Join-Path $script:dataDir 'Zadania'
[void][IO.Directory]::CreateDirectory($script:dataDir)
[void][IO.Directory]::CreateDirectory($script:jobsDir)
$script:settingsFile = Join-Path $script:dataDir 'ustawienia.json'
$script:rememberedInstancePath = ''
$script:rememberedConversationUrl = ''
$script:settingsReady = $false
$script:instance = $null
$script:session = $null
$script:bundle = $null
$script:bundlePaths = @()
$script:bridge = $null
$script:busy = $false
$script:worker = $null
$script:workerJob = ''
$script:workerMode = ''
$script:workerStartedUtc = [DateTime]::MinValue
$script:workerSawRunning = $false
$script:lastCaptureError = ''
$script:pendingAutomatic = $false
$script:lastProcessPoll = [DateTime]::MinValue
$script:processState = [pscustomobject]@{ Known = $false; Running = $false }
$script:lastCount = 0
$script:handoffUrl = ''
$script:lastProgressSequence = -1L
$script:progressPercent = 0
$script:cancelRequested = $false
$script:captureCanceled = $false
$script:closeAfterCapture = $false

$form = New-Object Windows.Forms.Form
$form.Text = 'MTZ — Zbieracz logów Minecrafta 0.3.0 RC2'
$workArea = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size = New-Object Drawing.Size(1040, ([Math]::Min(900, [Math]::Max(620, $workArea.Height - 60))))
$form.MinimumSize = New-Object Drawing.Size(960, 620)
$form.AutoScaleMode = 'Font'
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(22, 26, 33)
$form.ForeColor = [Drawing.Color]::FromArgb(234, 239, 246)
$panel = New-Object Windows.Forms.TableLayoutPanel
$panel.Dock = 'Fill'; $panel.AutoScroll = $true
$panel.Padding = New-Object Windows.Forms.Padding(24)
$panel.ColumnCount = 1; $panel.RowCount = 15
foreach ($height in @(48, 48, 25, 42, 25, 42, 44, 42, 76, 36, 0, 52, 52, 30, 88)) {
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, $height)))
}
[void]$form.Controls.Add($panel)
function Add-MtzLabel {
    param([string]$Text, [int]$Row, [int]$FontSize = 10)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text; $label.Dock = 'Fill'; $label.TextAlign = 'MiddleLeft'
    $label.Font = New-Object Drawing.Font('Segoe UI', $FontSize)
    [void]$panel.Controls.Add($label, 0, $Row)
    return $label
}
function New-MtzButton {
    param([string]$Text, [int]$Width = 170)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.Width = $Width; $button.Height = 38; $button.FlatStyle = 'Flat'
    $button.BackColor = [Drawing.Color]::FromArgb(44, 56, 72); $button.ForeColor = [Drawing.Color]::White
    $button.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
    return $button
}
$null = Add-MtzLabel 'Minecraft: pełna paczka albo szybka diagnostyka' 0 19
$null = Add-MtzLabel "Zostaw program otwarty, uruchom Minecrafta swoim launcherem i zamknij grę.`nPo zakończeniu obserwowanej sesji program sam przygotuje paczkę." 1
$null = Add-MtzLabel 'Obserwowany folder instancji — pełna, rzeczywiście wybrana ścieżka' 2
$folderRow = New-Object Windows.Forms.TableLayoutPanel
$folderRow.Dock = 'Fill'; $folderRow.ColumnCount = 3
[void]$folderRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$folderRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 150)))
[void]$folderRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 140)))
$folderText = New-Object Windows.Forms.TextBox
$folderText.ReadOnly = $true; $folderText.Dock = 'Fill'; $folderText.Margin = New-Object Windows.Forms.Padding(0, 4, 10, 0)
$chooseButton = New-MtzButton 'Wybierz folder' 130
$profilesButton = New-MtzButton 'Wykryj profile' 140
[void]$folderRow.Controls.Add($folderText, 0, 0); [void]$folderRow.Controls.Add($profilesButton, 1, 0); [void]$folderRow.Controls.Add($chooseButton, 2, 0)
[void]$panel.Controls.Add($folderRow, 0, 3)
$null = Add-MtzLabel 'Adres rozmowy ChatGPT — opcjonalny, potrzebny do przycisku przekazywania' 4
$chatText = New-Object Windows.Forms.TextBox
$chatText.Dock = 'Fill'; $chatText.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
[void]$panel.Controls.Add($chatText, 0, 5)
$modeRow = New-Object Windows.Forms.FlowLayoutPanel
$modeRow.Dock = 'Fill'; $modeRow.WrapContents = $false
$modeLabel = New-Object Windows.Forms.Label
$modeLabel.Text = 'Zakres paczki:'; $modeLabel.AutoSize = $true; $modeLabel.Margin = New-Object Windows.Forms.Padding(0, 6, 12, 0)
$modeBox = New-Object Windows.Forms.ComboBox
$modeBox.DropDownStyle = 'DropDownList'; $modeBox.Width = 680
[void]$modeBox.Items.Add('Pełna — mody, logi, konfiguracje, data, zasoby, shadery i światy')
[void]$modeBox.Items.Add('Szybka diagnostyka — logi, raporty awarii i lista modów')
$modeBox.SelectedIndex = 1
[void]$modeRow.Controls.AddRange(@($modeLabel, $modeBox)); [void]$panel.Controls.Add($modeRow, 0, 6)
$statusRow = New-Object Windows.Forms.TableLayoutPanel
$statusRow.Dock = 'Fill'; $statusRow.ColumnCount = 2
[void]$statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$statusRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 145)))
$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Dock = 'Fill'; $statusLabel.TextAlign = 'MiddleLeft'; $statusLabel.Text = 'Wybierz folder instancji, aby rozpocząć.'
$statusLabel.ForeColor = [Drawing.Color]::FromArgb(125, 211, 169)
[void]$statusRow.Controls.Add($statusLabel, 0, 0)
$cancelButton = New-MtzButton 'Anuluj' 135
$cancelButton.Enabled = $false
[void]$statusRow.Controls.Add($cancelButton, 1, 0)
[void]$panel.Controls.Add($statusRow, 0, 7)
$packageLabel = Add-MtzLabel "Szybka diagnostyka zbiera logi i listę modów z filtrowaniem rozpoznanych danych prywatnych.`nPełną kopię plików i światów możesz wybrać osobno w polu Zakres paczki." 8
$packageLabel.UseMnemonic = $false
$progressRow = New-Object Windows.Forms.TableLayoutPanel
$progressRow.Dock = 'Fill'; $progressRow.ColumnCount = 2; $progressRow.Margin = New-Object Windows.Forms.Padding(0)
[void]$progressRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$progressRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 120)))
$progress = New-Object Windows.Forms.ProgressBar
$progress.Style = 'Continuous'; $progress.Minimum = 0; $progress.Maximum = 100; $progress.Value = 0; $progress.Dock = 'Fill'
$progress.Margin = New-Object Windows.Forms.Padding(0, 4, 8, 4)
$progress.AccessibleName = 'Postęp przygotowania paczki'
$progressLabel = New-Object Windows.Forms.Label
$progressLabel.Dock = 'Fill'; $progressLabel.TextAlign = 'MiddleRight'; $progressLabel.Text = '0%'
$progressLabel.AccessibleName = 'Procent ukończenia'
[void]$progressRow.Controls.Add($progress, 0, 0); [void]$progressRow.Controls.Add($progressLabel, 1, 0)
[void]$panel.Controls.Add($progressRow, 0, 9)
$partsRow = New-Object Windows.Forms.TableLayoutPanel
$partsRow.Dock = 'Fill'; $partsRow.ColumnCount = 2; $partsRow.Visible = $false
[void]$partsRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute, 115)))
[void]$partsRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
$partsLabel = New-Object Windows.Forms.Label
$partsLabel.Text = 'Gotowe części:'; $partsLabel.Dock = 'Fill'; $partsLabel.TextAlign = 'MiddleLeft'
$partsBox = New-Object Windows.Forms.ComboBox
$partsBox.DropDownStyle = 'DropDownList'; $partsBox.Dock = 'Fill'; $partsBox.Enabled = $false
[void]$partsRow.Controls.Add($partsLabel, 0, 0); [void]$partsRow.Controls.Add($partsBox, 1, 0)
[void]$panel.Controls.Add($partsRow, 0, 10)
$buttonRow = New-Object Windows.Forms.FlowLayoutPanel
$buttonRow.Dock = 'Fill'; $buttonRow.WrapContents = $false
$buildButton = New-MtzButton 'Przygotuj paczkę' 170
$sendButton = New-MtzButton 'Przekaż wybraną do ChatGPT' 250
$sendButton.BackColor = [Drawing.Color]::FromArgb(29, 103, 76)
$showButton = New-MtzButton 'Pokaż wybrany ZIP' 175
$folderButton = New-MtzButton 'Folder paczek' 145
[void]$buttonRow.Controls.AddRange(@($buildButton, $sendButton, $showButton, $folderButton))
[void]$panel.Controls.Add($buttonRow, 0, 11)
$helpRow = New-Object Windows.Forms.FlowLayoutPanel
$helpRow.Dock = 'Fill'; $helpRow.WrapContents = $false
$helpButton = New-MtzButton 'Instrukcja / rozszerzenie' 220
$restartButton = New-MtzButton 'Nowa sesja' 135
$copyLinkButton = New-MtzButton 'Kopiuj link' 135
$installButton = New-MtzButton 'Zainstaluj skrót' 175
$warningsButton = New-MtzButton 'Uwagi' 90
[void]$helpRow.Controls.AddRange(@($helpButton, $restartButton, $copyLinkButton, $installButton, $warningsButton))
[void]$panel.Controls.Add($helpRow, 0, 12)
$hint = Add-MtzLabel 'Po dołączeniu jednej części wybierz następną z listy. Wyślij wiadomość samodzielnie w rozmowie.' 13 9
$notice = Add-MtzLabel "Przekazanie wymaga dołączonego rozszerzenia Opery; to okno musi pozostać otwarte.`nBez rozszerzenia: Pokaż wybrany ZIP → przeciągnij plik do rozmowy.`nDiagnostyka maskuje dane w logach. Pełne pliki modów, konfiguracji i światów są kopiowane w oryginale — przed przekazaniem możesz je obejrzeć." 14 9
$notice.ForeColor = [Drawing.Color]::FromArgb(172, 183, 197)
$progressTimer = New-Object Windows.Forms.Timer
$progressTimer.Interval = 250

function Reset-MtzProgressDisplay {
    $progressTimer.Stop()
    $script:lastProgressSequence = -1L; $script:progressPercent = 0
    $progress.Value = 0; $progressLabel.Text = '0%'
    $progress.AccessibleDescription = 'Oczekiwanie na przygotowanie paczki.'
}
function Update-MtzCaptureProgressDisplay {
    if (-not $script:busy) { return }
    $snapshot = Read-MtzCaptureProgress -JobDirectory $script:workerJob -AfterSequence $script:lastProgressSequence
    if ($null -eq $snapshot) { return }
    $script:lastProgressSequence = $snapshot.Sequence
    $script:progressPercent = [Math]::Max($script:progressPercent, [int]$snapshot.Percent)
    $progress.Value = $script:progressPercent
    $progressLabel.Text = ('{0}%' -f $script:progressPercent)
    $packageLabel.Text = $snapshot.Stage + "`n" + $snapshot.Detail
    $progress.AccessibleDescription = ('{0}% — {1}' -f $script:progressPercent, $snapshot.Stage)
    if ($script:cancelRequested) { $progressLabel.Text = ('{0}% — anulowanie' -f $script:progressPercent) }
}
$progressTimer.Add_Tick({ Update-MtzCaptureProgressDisplay })

function Save-MtzSettings {
    if (-not $script:settingsReady) { return }
    try {
        $root = $script:rememberedInstancePath
        if ($null -ne $script:instance) { $root = $script:instance.RootPath }
        $url = $chatText.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($url)) { $url = ''; $script:rememberedConversationUrl = '' }
        elseif (Test-MtzChatUrl $url) { $script:rememberedConversationUrl = $url }
        else { $url = $script:rememberedConversationUrl }
        $mode = 'Full'; if ($modeBox.SelectedIndex -eq 1) { $mode = 'Diagnostics' }
        $json = @{ InstancePath = $root; ConversationUrl = $url; CaptureMode = $mode } | ConvertTo-Json
        $temporary = $script:settingsFile + '.new'
        [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temporary -Destination $script:settingsFile -Force
    } catch { }
}
function Update-MtzButtons {
    $hasInstance = ($null -ne $script:instance)
    $hasPart = ($partsBox.SelectedIndex -ge 0 -and $script:bundlePaths.Count -gt 0)
    $buildButton.Enabled = ($hasInstance -and -not $script:busy)
    $chooseButton.Enabled = (-not $script:busy); $modeBox.Enabled = (-not $script:busy)
    $profilesButton.Enabled = (-not $script:busy)
    $cancelButton.Enabled = ($script:busy -and -not $script:cancelRequested)
    $restartButton.Enabled = ($hasInstance -and -not $script:busy)
    $installButton.Enabled = (-not $script:busy)
    $warningsButton.Enabled = ($null -ne $script:bundle -and @($script:bundle.Warnings).Count -gt 0 -and -not $script:busy)
    $sendButton.Enabled = ($hasPart -and -not $script:busy)
    $showButton.Enabled = ($hasPart -and -not $script:busy)
    $partsBox.Enabled = ($script:bundlePaths.Count -gt 0 -and -not $script:busy)
    $partsRow.Visible = ($script:bundlePaths.Count -gt 0 -and -not $script:busy)
    if ($partsRow.Visible) { $panel.RowStyles[10].Height = 42 } else { $panel.RowStyles[10].Height = 0 }
    $folderButton.Enabled = [IO.Directory]::Exists($script:outputDir)
    $copyLinkButton.Enabled = ([bool]$script:handoffUrl -and -not $script:busy)
}
function Reset-MtzHandoff {
    if ($null -ne $script:bridge) { $script:bridge.Revoke() }
    $script:handoffUrl = ''; $copyLinkButton.Enabled = $false
}
function Request-MtzCancellation {
    if (-not $script:busy -or $null -eq $script:worker) { return }
    [IO.File]::WriteAllText((Join-Path $script:workerJob 'cancel.request'), 'cancel', (New-Object Text.UTF8Encoding($false)))
    $script:cancelRequested = $true
    $script:pendingAutomatic = $false
    Reset-MtzHandoff
    $statusLabel.Text = 'Anulowanie — kończę bieżący odczyt i porządkuję pliki tej próby…'
    $progressLabel.Text = ('{0}% — anulowanie' -f $script:progressPercent)
    Update-MtzButtons
}
function Set-MtzInstance {
    param([string]$Path)
    if ($script:busy) { throw 'Poczekaj na zakończenie przygotowywania paczki.' }
    $info = Get-MtzInstanceInfo -InstancePath $Path
    $script:instance = $info; $script:rememberedInstancePath = $info.RootPath
    $folderText.Text = $info.RootPath
    $fingerprint = Get-MtzLogFingerprint -InstancePath $info.RootPath
    $script:session = New-MtzSessionState -Fingerprint $fingerprint.Key
    $script:bundle = $null; $script:bundlePaths = @(); $partsBox.Items.Clear()
    Reset-MtzProgressDisplay
    $script:lastCaptureError = ''
    $script:captureCanceled = $false; $script:cancelRequested = $false
    $script:pendingAutomatic = $false; $script:lastProcessPoll = [DateTime]::MinValue
    $script:processState = [pscustomobject]@{ Known = $false; Running = $false }
    Reset-MtzHandoff
    $packageLabel.Text = 'Obserwuję wybraną instancję. Możesz teraz uruchomić Minecrafta swoim launcherem.'
    $statusLabel.Text = 'Oczekiwanie na Minecrafta'
    Update-MtzButtons; Save-MtzSettings
}
function Start-MtzPackage {
    param([switch]$Automatic)
    if ($script:busy) { throw 'Przygotowywanie paczki już trwa.' }
    if ($null -eq $script:instance) { throw 'Najpierw wybierz folder instancji.' }
    # A new attempt invalidates the former selection, even if preflight or the worker fails.
    $script:bundle = $null; $script:bundlePaths = @(); $partsBox.Items.Clear()
    Reset-MtzProgressDisplay
    $script:lastCaptureError = ''
    $script:captureCanceled = $false; $script:cancelRequested = $false
    Reset-MtzHandoff; Update-MtzButtons
    $mode = 'Full'; if ($modeBox.SelectedIndex -eq 1) { $mode = 'Diagnostics' }
    # Query again on manual clicks, not only from the observer's last poll.
    $script:processState = Get-MtzGameProcessState -InstancePath $script:instance.RootPath
    $script:lastProcessPoll = [DateTime]::UtcNow
    if ($mode -eq 'Full' -and $script:processState.Running) {
        throw 'Zamknij Minecrafta przed pełnym kopiowaniem światów. Po zamknięciu gra zostanie zebrana automatycznie. Podczas gry możesz wybrać szybką diagnostykę.'
    }
    $job = Join-Path $script:jobsDir ([Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($job)
    $request = @{
        InstancePath = $script:instance.RootPath; OutputDirectory = $script:outputDir
        SessionStartedUtc = $script:session.StartedUtc.ToUniversalTime().ToString('o')
        Mode = $mode; PartMiB = 24
    }
    $requestPath = Join-Path $job 'request.json'
    [IO.File]::WriteAllText($requestPath, ($request | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $workerScript = Join-Path $PSScriptRoot 'Collect-Worker.ps1'
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $workerScript, '-RequestPath', $requestPath)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $powerShell
    $start.Arguments = (($arguments | ForEach-Object { ConvertTo-MtzProcessArgument ([string]$_) }) -join ' ')
    $start.WorkingDirectory = $PSScriptRoot; $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    if (-not $process.Start()) { $process.Dispose(); throw 'Nie udało się uruchomić zbierania w tle.' }
    $script:worker = $process; $script:workerJob = $job; $script:workerMode = $mode
    $script:workerStartedUtc = [DateTime]::UtcNow; $script:workerSawRunning = $false
    $script:busy = $true
    $progressTimer.Start()
    Reset-MtzHandoff
    if ($Automatic) { $script:pendingAutomatic = $false }
    elseif ($mode -eq 'Full' -and $script:session.SeenGame -and -not $script:processState.Running) {
        $script:session.Completed = $true; $script:pendingAutomatic = $false
    }
    $statusLabel.Text = 'Przygotowuję paczkę w tle. Okno pozostaje aktywne.'
    $packageLabel.Text = "Przygotowuję spis danych do zebrania…`nPasek pokaże postęp odczytu, kompresji i zapisu paczki."
    Update-MtzButtons; Save-MtzSettings
}
function Show-MtzError {
    param([string]$Message)
    $safe = Protect-MtzDiagnosticText -Text $Message
    $statusLabel.Text = 'Nie udało się wykonać tej czynności. Szczegóły w komunikacie.'
    [void][Windows.Forms.MessageBox]::Show($form, $safe, 'MTZ — informacja', 'OK', 'Warning')
}
function Complete-MtzWorker {
    if (-not $script:busy -or $null -eq $script:worker -or -not $script:worker.HasExited) { return }
    Update-MtzCaptureProgressDisplay
    $progressTimer.Stop()
    $job = $script:workerJob
    $exitCode = $script:worker.ExitCode
    $script:worker.Dispose(); $script:worker = $null; $script:busy = $false
    try {
        $resultPath = Join-Path $job 'result.json'
        if (-not [IO.File]::Exists($resultPath)) { throw ('Proces zbierania zakończył się bez wyniku (kod {0}). Możesz spróbować ponownie.' -f $exitCode) }
        $result = [IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
        if ($result.Success -isnot [bool]) { throw 'Proces zbierania zwrócił nieprawidłowy stan ukończenia.' }
        $canceled = $false
        if ($result.PSObject.Properties.Name -contains 'Canceled') {
            if ($result.Canceled -isnot [bool]) { throw 'Proces zbierania zwrócił nieprawidłowy stan anulowania.' }
            $canceled = $result.Canceled
        }
        if ($canceled) {
            if ($result.Success -or $exitCode -ne 3) { throw 'Proces zbierania zwrócił sprzeczny wynik anulowania.' }
            $script:captureCanceled = $true; $script:pendingAutomatic = $false
            $script:bundle = $null; $script:bundlePaths = @(); $partsBox.Items.Clear()
            Reset-MtzHandoff
            $statusLabel.Text = 'Anulowano przygotowywanie paczki. Możesz rozpocząć ponownie.'
            $packageLabel.Text = 'Oryginalne pliki Minecrafta i wcześniejsze paczki pozostają zachowane.'
            if ($result.PSObject.Properties.Name -contains 'Warnings' -and @($result.Warnings).Count -gt 0) {
                $packageLabel.Text += "`n" + (Protect-MtzDiagnosticText -Text ((@($result.Warnings) | Select-Object -First 2) -join ' '))
            }
            $progressLabel.Text = ('{0}% — anulowano' -f $script:progressPercent)
            $progress.AccessibleDescription = 'Przygotowanie paczki zostało anulowane.'
            return
        }
        if (-not $result.Success) { throw ([string]$result.Error) }
        if ($exitCode -ne 0) { throw ('Proces zgłosił błąd zakończenia (kod {0}). Przygotuj paczkę ponownie.' -f $exitCode) }
        $bundle = $result.Bundle
        $paths = @($bundle.ZipPaths)
        if ($paths.Count -eq 0) { $paths = @([string]$bundle.ZipPath) }
        foreach ($path in $paths) {
            Assert-MtzReadyArchive -Path ([string]$path) -MaximumBytes ([Mtz.LogBridge]::MaximumBundleBytes)
        }
        $script:bundle = $bundle; $script:bundlePaths = $paths
        $partsBox.Items.Clear()
        $totalBytes = 0L
        for ($i = 0; $i -lt $paths.Count; $i++) {
            $file = Get-Item -LiteralPath ([string]$paths[$i])
            $totalBytes += $file.Length
            [void]$partsBox.Items.Add(('{0}/{1}: {2}  ({3:N2} MiB)' -f ($i + 1), $paths.Count, $file.Name, ($file.Length / 1MB)))
        }
        $partsBox.SelectedIndex = 0
        $complete = $true
        if ($bundle.PSObject.Properties.Name -contains 'Complete') {
            if ($bundle.Complete -isnot [bool]) { throw 'Proces zbierania zwrócił nieprawidłowy stan kompletności paczki.' }
            $complete = $bundle.Complete
        }
        if ($script:workerMode -eq 'Full' -and $script:workerSawRunning) { $complete = $false }
        $warningCount = @($bundle.Warnings).Count
        $stateText = 'Paczka gotowa.'
        if (-not $complete) { $stateText = 'Paczka niepełna — sprawdź uwagi w manifeście i przygotuj ją ponownie.' }
        $statusLabel.Text = $stateText
        $detail = ('Części ZIP: {0}  |  razem {1:N2} MiB  |  uwagi: {2}.' -f $paths.Count, ($totalBytes / 1MB), $warningCount)
        if ($script:workerMode -eq 'Full') { $detail += "`nDo odtworzenia pełnej zawartości potrzebne są wszystkie części, także diagnostyka i manifest." }
        if ($script:workerSawRunning -and $script:workerMode -eq 'Full') { $detail += "`nMinecraft uruchomiono podczas kopiowania. Zamknij grę i przygotuj pełną paczkę ponownie." }
        $packageLabel.Text = $detail
        if ($complete) {
            $script:progressPercent = 100; $progress.Value = 100; $progressLabel.Text = '100%'
            $progress.AccessibleDescription = '100% — paczka zapisana i gotowa.'
        } else {
            $progressLabel.Text = ('{0}% — niepełna' -f $script:progressPercent)
            $progress.AccessibleDescription = 'Zakończono z pominięciami. Paczka jest niepełna; sprawdź uwagi.'
        }
    } catch {
        $script:lastCaptureError = [string]$_.Exception.Message
        $script:bundle = $null; $script:bundlePaths = @(); $partsBox.Items.Clear()
        Reset-MtzHandoff
        $packageLabel.Text = 'Ta próba nie utworzyła gotowej paczki. Sprawdź komunikat i użyj Przygotuj paczkę, aby ponowić.'
        $progressLabel.Text = ('{0}% — błąd' -f $script:progressPercent)
        $progress.AccessibleDescription = 'Przygotowanie paczki zakończyło się błędem.'
        Show-MtzError $script:lastCaptureError
    }
    finally {
        # Only tiny worker-control JSON files are removed; capture outputs and source data are retained.
        foreach ($name in @('request.json', 'result.json', 'result.json.new', 'progress.json', 'progress.json.new', 'cancel.request')) {
            $control = Join-Path $job $name
            if ([IO.File]::Exists($control)) { try { [IO.File]::Delete($control) } catch { } }
        }
        try { [IO.Directory]::Delete($job, $false) } catch { }
        $script:cancelRequested = $false
        Update-MtzButtons
    }
}
function Get-MtzSelectedZip {
    if ($partsBox.SelectedIndex -lt 0 -or $partsBox.SelectedIndex -ge $script:bundlePaths.Count) { throw 'Najpierw przygotuj paczkę i wybierz część ZIP z listy.' }
    $path = [string]$script:bundlePaths[$partsBox.SelectedIndex]
    if (-not [IO.File]::Exists($path)) { throw 'Wybrany ZIP nie istnieje. Przygotuj paczkę ponownie.' }
    return $path
}

function Show-MtzProfilePicker {
    param([object[]]$Choices)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'MTZ — wybierz profil Minecrafta'
    $dialog.Size = New-Object Drawing.Size(860, 360)
    $dialog.MinimumSize = New-Object Drawing.Size(600, 280)
    $dialog.StartPosition = 'CenterParent'; $dialog.Font = $form.Font
    $dialog.BackColor = $form.BackColor; $dialog.ForeColor = $form.ForeColor
    $dialog.Tag = ''
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.Padding = New-Object Windows.Forms.Padding(16)
    $layout.ColumnCount = 1; $layout.RowCount = 3
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 44)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 48)))
    $label = New-Object Windows.Forms.Label
    $label.Text = 'Wybierz profil, którego dane chcesz zebrać. Inne lokalizacje wskaż przez Wybierz folder.'
    $label.Dock = 'Fill'; $label.TextAlign = 'MiddleLeft'
    $list = New-Object Windows.Forms.ListBox
    $list.Dock = 'Fill'; $list.HorizontalScrollbar = $true; $list.DisplayMember = 'Label'
    foreach ($choice in $Choices) { [void]$list.Items.Add($choice) }
    $row = New-Object Windows.Forms.FlowLayoutPanel
    $row.Dock = 'Fill'; $row.Padding = New-Object Windows.Forms.Padding(0, 8, 0, 0)
    $accept = New-MtzButton 'Wybierz profil' 150
    $back = New-MtzButton 'Wróć' 110
    $accept.Add_Click({
        if ($list.SelectedIndex -ge 0) {
            $dialog.Tag = [string]$list.SelectedItem.Path
            $dialog.DialogResult = 'OK'; $dialog.Close()
        }
    }.GetNewClosure())
    $back.DialogResult = 'Cancel'; $dialog.CancelButton = $back
    [void]$row.Controls.AddRange(@($accept, $back))
    [void]$layout.Controls.Add($label, 0, 0); [void]$layout.Controls.Add($list, 0, 1); [void]$layout.Controls.Add($row, 0, 2)
    [void]$dialog.Controls.Add($layout)
    try { if ($dialog.ShowDialog($form) -eq 'OK') { return [string]$dialog.Tag }; return '' }
    finally { $dialog.Dispose() }
}
$profilesButton.Add_Click({
    try {
        $choices = @(Get-MtzSuggestedInstances)
        if ($choices.Count -eq 0) {
            $statusLabel.Text = 'Nie znaleziono profili w standardowych lokalizacjach. Użyj Wybierz folder.'
            return
        }
        $selected = Show-MtzProfilePicker -Choices $choices
        if ($selected) { Set-MtzInstance -Path $selected }
    } catch { Show-MtzError $_.Exception.Message }
})
$chooseButton.Add_Click({
    $picker = New-Object Windows.Forms.FolderBrowserDialog
    $picker.Description = 'W CurseForge: menu paczki → Otwórz folder. Wskaż folder zawierający logs lub mods.'
    if ($null -ne $script:instance) { $picker.SelectedPath = $script:instance.RootPath }
    if ($picker.ShowDialog($form) -eq 'OK') { try { Set-MtzInstance $picker.SelectedPath } catch { Show-MtzError $_.Exception.Message } }
    $picker.Dispose()
})
$buildButton.Add_Click({
    try { Start-MtzPackage }
    catch {
        $script:lastCaptureError = [string]$_.Exception.Message
        $packageLabel.Text = 'Nowa paczka nie została przygotowana. Po usunięciu przyczyny możesz ponowić zbieranie.'
        Show-MtzError $script:lastCaptureError; Update-MtzButtons
    }
})
$cancelButton.Add_Click({ try { Request-MtzCancellation } catch { Show-MtzError $_.Exception.Message } })
$showButton.Add_Click({
    try { $path = Get-MtzSelectedZip; Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $path + '"') }
    catch { Show-MtzError $_.Exception.Message }
})
$folderButton.Add_Click({ try { Start-Process -FilePath 'explorer.exe' -ArgumentList (ConvertTo-MtzProcessArgument $script:outputDir) } catch { Show-MtzError $_.Exception.Message } })
$helpButton.Add_Click({ try { Start-Process -FilePath (Join-Path $PSScriptRoot 'INSTRUKCJA-PL.txt') } catch { Show-MtzError $_.Exception.Message } })
$warningsButton.Add_Click({
    if ($null -eq $script:bundle) { return }
    $messages = @($script:bundle.Warnings)
    $text = ($messages | Select-Object -First 20) -join "`r`n`r`n"
    if ($messages.Count -gt 20) { $text += "`r`n`r`nPozostałe uwagi znajdziesz w manifestach paczki." }
    [void][Windows.Forms.MessageBox]::Show($form, $text, 'MTZ — uwagi do paczki', 'OK', 'Information')
})
$restartButton.Add_Click({ try { Set-MtzInstance $folderText.Text } catch { Show-MtzError $_.Exception.Message } })
$installButton.Add_Click({
    try {
        & (Join-Path $PSScriptRoot 'Instaluj-MTZ-Logi.ps1') -NoLaunch
        $statusLabel.Text = 'Skrót MTZ — Zbieracz logów jest na pulpicie. Ustawienia i paczki zostały zachowane.'
    } catch { Show-MtzError $_.Exception.Message }
})
$copyLinkButton.Add_Click({
    try {
        if (-not $script:handoffUrl) { throw 'Najpierw przekaż wybraną część do ChatGPT.' }
        [Windows.Forms.Clipboard]::SetText($script:handoffUrl)
        $statusLabel.Text = 'Link skopiowany. Wklej go w pasku Opery z włączonym rozszerzeniem.'
    } catch { Show-MtzError $_.Exception.Message }
})
$chatText.Add_Leave({ Save-MtzSettings })
$modeBox.Add_SelectedIndexChanged({
    if ($null -eq $script:bundle -and -not $script:busy) {
        if ($modeBox.SelectedIndex -eq 0) {
            $packageLabel.Text = "Pełna kopia zawiera oryginalne pliki, światy, dane graczy i ustawienia serwerów.`nPrzygotuj ją po zamknięciu gry. Przed przekazaniem innym sprawdź jej zawartość."
        } else {
            $packageLabel.Text = "Diagnostyka obejmuje logi, raporty awarii i listę modów.`nMaskuje rozpoznane dane prywatne; przed przekazaniem możesz sprawdzić ZIP."
        }
    }
    Save-MtzSettings
})
$partsBox.Add_SelectedIndexChanged({ Reset-MtzHandoff; Update-MtzButtons })
$sendButton.Add_Click({
    try {
        $url = $chatText.Text.Trim()
        if (-not (Test-MtzChatUrl $url)) { throw 'Wklej adres istniejącej rozmowy: https://chatgpt.com/c/... (bez znaku ? i dodatkowych parametrów).' }
        $path = Get-MtzSelectedZip
        if ($null -eq $script:bridge -or -not $script:bridge.IsRunning) {
            if ($null -ne $script:bridge) { $script:bridge.Dispose() }
            $script:bridge = New-Object Mtz.LogBridge; $script:bridge.Start()
        }
        $token = $script:bridge.Publish($path)
        $script:lastCount = $script:bridge.DownloadCount
        $target = ($url.Split('#')[0]) + '#mtz-logs=' + $token
        $script:handoffUrl = $target; Save-MtzSettings; Update-MtzButtons
        $opened = $false
        foreach ($opera in @(Get-Process -Name 'opera' -ErrorAction SilentlyContinue)) {
            try {
                $operaPath = $opera.Path
                if ($operaPath -and [IO.File]::Exists($operaPath)) {
                    Start-Process -FilePath $operaPath -ArgumentList (ConvertTo-MtzProcessArgument $target)
                    $opened = $true; break
                }
            } catch { }
        }
        if (-not $opened) { Start-Process -FilePath $target }
        $statusLabel.Text = 'Otwieram rozmowę. Rozszerzenie spróbuje dołączyć ZIP. Sprawdź załącznik przed wysłaniem.'
        $hint.Text = ('Wybrano część {0}/{1}. Zostaw okno otwarte. Link działa przez 15 minut.' -f ($partsBox.SelectedIndex + 1), $script:bundlePaths.Count)
    } catch { Show-MtzError $_.Exception.Message }
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({
    try {
        Complete-MtzWorker
        if ($script:closeAfterCapture -and -not $script:busy) {
            $script:closeAfterCapture = $false; $form.Close(); return
        }
        if ($null -ne $script:bridge -and $script:bridge.DownloadCount -gt $script:lastCount) {
            $script:lastCount = $script:bridge.DownloadCount
            $statusLabel.Text = 'Rozszerzenie pobrało wybrany ZIP. Sprawdź załącznik, wybierz kolejną część albo kliknij Wyślij.'
        }
        if ($null -eq $script:instance) { return }
        $now = [DateTime]::UtcNow
        if (($now - $script:lastProcessPoll).TotalSeconds -ge 6) {
            $script:processState = Get-MtzGameProcessState -InstancePath $script:instance.RootPath
            $script:lastProcessPoll = $now
        }
        if ($script:busy -and $script:processState.Running) { $script:workerSawRunning = $true }
        $fp = Get-MtzLogFingerprint -InstancePath $script:instance.RootPath
        $script:session = Update-MtzSessionState -State $script:session -Fingerprint $fp.Key -ProcessStateKnown $script:processState.Known -GameRunning $script:processState.Running -NowUtc $now
        if ($script:session.ShouldCollect) { $script:pendingAutomatic = $true }
        if ($script:pendingAutomatic -and -not $script:busy -and -not $script:processState.Running) {
            # One attempt per observed session; failures remain available for manual retry.
            $script:pendingAutomatic = $false
            try { Start-MtzPackage -Automatic }
            catch {
                $script:lastCaptureError = [string]$_.Exception.Message
                $statusLabel.Text = 'Paczka nie powstała. Kliknij Przygotuj paczkę, aby ponowić.'
                $packageLabel.Text = 'Przyczyna: ' + (Protect-MtzDiagnosticText -Text $script:lastCaptureError)
                Update-MtzButtons
            }
        } elseif ($script:busy) {
            $elapsed = [DateTime]::UtcNow - $script:workerStartedUtc
            if ($script:cancelRequested) { $statusLabel.Text = 'Anulowanie — czekam na zakończenie odczytu i porządkowania plików…' }
            else { $statusLabel.Text = ('Przygotowuję paczkę w tle… {0:mm\:ss}' -f $elapsed) }
        } elseif ($script:lastCaptureError) {
            $statusLabel.Text = 'Paczka nie powstała. Sprawdź komunikat i kliknij Przygotuj paczkę, aby ponowić.'
        } elseif ($script:captureCanceled) {
            $statusLabel.Text = 'Anulowano przygotowywanie paczki. Możesz rozpocząć ponownie.'
        } elseif ($null -eq $script:bundle) { $statusLabel.Text = $script:session.Status }
    } catch {
        if ($script:lastCaptureError) {
            $statusLabel.Text = 'Paczka nie powstała. Kliknij Przygotuj paczkę, aby ponowić.'
        } else {
            $statusLabel.Text = 'Obserwacja chwilowo niedostępna. Możesz przygotować paczkę przyciskiem.'
        }
    }
})
$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:busy -and $null -ne $script:worker -and -not $script:worker.HasExited) {
        $eventArgs.Cancel = $true
        if ($script:cancelRequested) { $script:closeAfterCapture = $true; return }
        $answer = [Windows.Forms.MessageBox]::Show($form, 'Trwa przygotowywanie paczki. Anulować je i zamknąć program po zakończeniu porządkowania plików tej próby?', 'MTZ — kopiowanie w toku', 'YesNo', 'Question', 'Button2')
        if ($answer -ne 'Yes') { return }
        try {
            Request-MtzCancellation
            $script:closeAfterCapture = $true
        } catch {
            Show-MtzError 'Nie udało się zgłosić anulowania. Poczekaj na zakończenie paczki przed zamknięciem programu.'
        }
    }
})
$form.Add_FormClosed({
    $timer.Stop(); $timer.Dispose(); $progressTimer.Stop(); $progressTimer.Dispose(); Save-MtzSettings
    if ($null -ne $script:bridge) { $script:bridge.Dispose() }
    if ($null -ne $script:worker) { $script:worker.Dispose(); $script:worker = $null }
})
try {
    $saved = Read-MtzUserPreferences -Path $script:settingsFile
    $chatText.Text = $saved.ConversationUrl; $script:rememberedConversationUrl = $saved.ConversationUrl
    if ($saved.CaptureMode -eq 'Full') { $modeBox.SelectedIndex = 0 }
    $script:rememberedInstancePath = $saved.InstancePath
    if ($script:rememberedInstancePath) { try { Set-MtzInstance $script:rememberedInstancePath } catch { } }
    # Never silently choose somebody else's profile or persist an author's path.
    # A valid saved instance survives upgrades; new users choose one explicitly.
    if ($null -eq $script:instance) {
        $folderText.Text = $script:rememberedInstancePath
        if ($script:rememberedInstancePath) {
            $statusLabel.Text = 'Wskaż folder instancji na tym komputerze; zapamiętana ścieżka nie jest teraz dostępna.'
        } else {
            $statusLabel.Text = 'Kliknij Wykryj profile lub Wybierz folder. Program zapamięta Twój wybór.'
        }
    }
    if ($saved.Warning) { $statusLabel.Text = $saved.Warning }
    $script:settingsReady = $true
    Save-MtzSettings; Update-MtzButtons; $timer.Start(); [void]$form.ShowDialog()
} finally {
    if ($null -ne $script:bridge) { $script:bridge.Dispose() }
    if ($null -ne $script:worker) {
        try {
            if (-not $script:worker.HasExited) {
                [IO.File]::WriteAllText((Join-Path $script:workerJob 'cancel.request'), 'cancel')
                # Emergency cleanup after an unexpected window failure only.
                # Normal Cancel/Close waits asynchronously for the worker above.
                if (-not $script:worker.WaitForExit(3000)) { $script:worker.Kill(); [void]$script:worker.WaitForExit(3000) }
            }
        } catch { }
        $script:worker.Dispose()
    }
    if ($null -ne $script:applicationLock) { $script:applicationLock.Dispose(); $script:applicationLock = $null }
    $form.Dispose()
}
