#Requires -Version 5.1
# Native PowerShell tests of production logic. Fake controls test state transitions,
# not Windows Forms rendering. All capture inputs are temporary synthetic fixtures.
param(
    [string]$ApplicationDirectory = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [ValidateSet('All', 'UI', 'Engine')][string]$Suite = 'All',
    [string]$ResultPath = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([string]::IsNullOrWhiteSpace($ResultPath)) { $ResultPath = Join-Path $PSScriptRoot ('progress-' + $Suite.ToLowerInvariant() + '.json') }
$ApplicationDirectory = [IO.Path]::GetFullPath($ApplicationDirectory)
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('mtz-progress-030rc1-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:TestRoot)
$script:Cases = New-Object 'Collections.Generic.List[object]'
$script:Assertions = 0
$script:CaseEvidence = $null
$script:QAPowerShellExecutable = @('pwsh', 'pwsh.exe', 'powershell.exe' | ForEach-Object { Join-Path $PSHOME $_ } | Where-Object { [IO.File]::Exists($_) })[0]
if ([string]::IsNullOrWhiteSpace($script:QAPowerShellExecutable)) { throw 'Cannot locate this PowerShell runtime under PSHOME.' }
$inputHashes = [ordered]@{}
foreach ($name in @('MTZ-Logi.ps1', 'core.ps1', 'full-bundle.ps1', 'Collect-Worker.ps1', 'session.ps1', 'Restore-MTZ-Paczka.ps1', 'bridge/Bridge.cs')) {
    $inputHashes[$name] = (Get-FileHash -LiteralPath (Join-Path $ApplicationDirectory $name) -Algorithm SHA256).Hash.ToLowerInvariant()
}
. (Join-Path $ApplicationDirectory 'MTZ-Logi.ps1') -NoGui
. (Join-Path $ApplicationDirectory 'full-bundle.ps1')
Add-Type -AssemblyName System.IO.Compression
if (-not ('Mtz.LogBridge' -as [type])) { Add-Type -Path (Join-Path $ApplicationDirectory 'bridge/Bridge.cs') }

# Import the actual event/state functions without constructing a Forms window.
$tokens = $null; $parseErrors = $null
$uiAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $ApplicationDirectory 'MTZ-Logi.ps1'), [ref]$tokens, [ref]$parseErrors)
if (@($parseErrors).Count -gt 0) { throw 'Production UI script has parser errors.' }
foreach ($name in @('Reset-MtzProgressDisplay', 'Update-MtzCaptureProgressDisplay', 'Update-MtzButtons',
    'Reset-MtzHandoff', 'Request-MtzCancellation', 'Save-MtzSettings', 'Set-MtzInstance',
    'Start-MtzPackage', 'Complete-MtzWorker', 'Get-MtzSelectedZip')) {
    $nodes = @($uiAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true))
    if ($nodes.Count -ne 1) { throw ('Missing or ambiguous production function: ' + $name) }
    . ([scriptblock]::Create($nodes[0].Extent.Text))
}
function Show-MtzError { param([string]$Message) $script:ShownErrors.Add($Message) }
function Get-QACloseAnswer { $script:ConfirmationCalls++; return $script:CloseAnswer }
function Get-QAEventBody {
    param([string]$Variable, [string]$Method, [switch]$StubConfirmation)
    $nodes = @($uiAst.FindAll({ param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Expression -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Expression.VariablePath.UserPath -eq $Variable -and $node.Member.Value -eq $Method
    }.GetNewClosure(), $true))
    if ($nodes.Count -ne 1) { throw ('Missing or ambiguous event: ' + $Variable + '.' + $Method) }
    $body = $nodes[0].Arguments[0].ScriptBlock
    $text = $body.Extent.Text
    if ($StubConfirmation) {
        # The only substituted expression is the visual MessageBox.Show call.
        # All production event branching, cancellation and state logic runs intact.
        $calls = @($body.FindAll({ param($node)
            $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
            $node.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
            $node.Expression.TypeName.FullName -eq 'Windows.Forms.MessageBox' -and $node.Member.Value -eq 'Show'
        }, $true))
        if ($calls.Count -ne 1) { throw 'The close handler must have exactly one visual confirmation dependency.' }
        $start = $calls[0].Extent.StartOffset - $body.Extent.StartOffset
        $text = $text.Remove($start, $calls[0].Extent.Text.Length).Insert($start, '(Get-QACloseAnswer)')
    }
    return [scriptblock]::Create($text.Substring(1, $text.Length - 2))
}
$script:ObserverTick = Get-QAEventBody 'timer' 'Add_Tick'
$script:ClosingEvent = Get-QAEventBody 'form' 'Add_FormClosing' -StubConfirmation

function Assert-QA {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw $Message }
}
function Assert-QAThrows {
    param([scriptblock]$Action, [string]$Message)
    $threw = $false
    try { $null = & $Action } catch { $threw = $true }
    Assert-QA $threw $Message
}
function Test-QA {
    param([string]$Name, [scriptblock]$Action)
    $before = $script:Assertions
    $script:CaseEvidence = [ordered]@{}
    $status = 'PASS'; $failure = ''; $trace = ''
    try { $null = & $Action }
    catch { $status = 'FAIL'; $failure = $_.Exception.Message; $trace = $_.ScriptStackTrace }
    $script:Cases.Add([pscustomobject]@{ Name = $Name; Status = $status; Assertions = $script:Assertions - $before; Error = $failure; Stack = $trace; Evidence = $script:CaseEvidence })
    Write-Output ($status + ' ' + $Name + $(if ($failure) { ': ' + $failure } else { '' }))
}
function New-QADirectory {
    param([string]$Prefix)
    $path = Join-Path $script:TestRoot ($Prefix + '-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function Write-QAText {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}
function New-QASnapshot {
    param([long]$Sequence = 1, [int]$Percent = 42, [string]$Stage = 'Kopiowanie', [string]$Detail = 'Postęp testowy.')
    return [ordered]@{ Version = 1; Sequence = $Sequence; Percent = $Percent; Stage = $Stage; Detail = $Detail; UpdatedUtc = [DateTime]::UtcNow.ToString('o') }
}
function Write-QASnapshot {
    param([string]$Job, $Snapshot)
    Write-QAText (Join-Path $Job 'progress.json') ($Snapshot | ConvertTo-Json -Depth 6 -Compress)
}
function New-QAZip {
    param([string]$Path, [switch]$Empty)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
    try {
        if (-not $Empty) {
            $entry = $zip.CreateEntry('fixture.txt')
            $writer = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
            try { $writer.Write('complete synthetic archive') } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose(); $stream.Dispose() }
    return $Path
}
function Initialize-QAUi {
    $script:progress = [pscustomobject]@{ Value = 0; AccessibleDescription = '' }
    $script:progressLabel = [pscustomobject]@{ Text = '0%' }
    $script:packageLabel = [pscustomobject]@{ Text = '' }
    $script:statusLabel = [pscustomobject]@{ Text = '' }
    $script:partsBox = [pscustomobject]@{ SelectedIndex = -1; Enabled = $false; Items = (New-Object Collections.ArrayList) }
    $script:partsRow = [pscustomobject]@{ Visible = $false }
    $rows = New-Object Collections.ArrayList
    for ($i = 0; $i -lt 15; $i++) { [void]$rows.Add([pscustomobject]@{ Height = 0 }) }
    $script:panel = [pscustomobject]@{ RowStyles = $rows }
    foreach ($name in @('buildButton', 'chooseButton', 'restartButton', 'installButton', 'warningsButton',
        'sendButton', 'showButton', 'folderButton', 'copyLinkButton', 'profilesButton', 'cancelButton')) {
        Set-Variable -Scope Script -Name $name -Value ([pscustomobject]@{ Enabled = $false })
    }
    $script:modeBox = [pscustomobject]@{ Enabled = $true; SelectedIndex = 1 }
    $script:folderText = [pscustomobject]@{ Text = '' }
    $script:chatText = [pscustomobject]@{ Text = '' }
    $script:form = [pscustomobject]@{ CloseCalls = 0 }
    Add-Member -InputObject $script:form -MemberType ScriptMethod -Name Close -Value { $this.CloseCalls++ }
    $script:progressTimer = [pscustomobject]@{ Running = $false; Stops = 0; Starts = 0 }
    Add-Member -InputObject $script:progressTimer -MemberType ScriptMethod -Name Stop -Value { $this.Running = $false; $this.Stops++ }
    Add-Member -InputObject $script:progressTimer -MemberType ScriptMethod -Name Start -Value { $this.Running = $true; $this.Starts++ }
    $script:ShownErrors = New-Object 'Collections.Generic.List[string]'
    $script:busy = $false; $script:worker = $null; $script:workerJob = ''
    $script:workerMode = 'Full'; $script:workerSawRunning = $false
    $script:bundle = $null; $script:bundlePaths = @(); $script:lastCaptureError = ''
    $script:bridge = $null; $script:handoffUrl = ''; $script:instance = $null
    $script:progressPercent = 0; $script:lastProgressSequence = -1L
    $script:outputDir = $script:TestRoot
    $script:cancelRequested = $false; $script:captureCanceled = $false; $script:closeAfterCapture = $false
    $script:pendingAutomatic = $false; $script:CloseAnswer = 'No'; $script:ConfirmationCalls = 0
    $script:settingsReady = $false
    $script:settingsFile = Join-Path $script:TestRoot ('settings-' + [Guid]::NewGuid().ToString('N') + '.json')
    $script:rememberedInstancePath = ''; $script:rememberedConversationUrl = ''
    $script:session = $null; $script:lastProcessPoll = [DateTime]::MinValue
    $script:processState = [pscustomobject]@{ Known = $false; Running = $false }
}
function New-QAActiveWorker {
    $worker = [pscustomobject]@{ HasExited = $false; ExitCode = 3; DisposeCalls = 0; KillCalls = 0; WaitCalls = 0 }
    Add-Member -InputObject $worker -MemberType ScriptMethod -Name Dispose -Value { $this.DisposeCalls++ }
    Add-Member -InputObject $worker -MemberType ScriptMethod -Name Kill -Value { $this.KillCalls++; $this.HasExited = $true }
    Add-Member -InputObject $worker -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) $this.WaitCalls++; return $this.HasExited }
    return $worker
}
function Start-QAExitProcess {
    param([int]$ExitCode = 0, [switch]$Wait)
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $script:QAPowerShellExecutable
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -Command "exit ' + $ExitCode + '"'
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $p = New-Object Diagnostics.Process; $p.StartInfo = $start
    [void]$p.Start()
    if ($Wait -and -not $p.WaitForExit(10000)) { $p.Kill(); throw 'Test subprocess did not terminate.' }
    return $p
}
function New-QAResult {
    param([string[]]$Paths, $Success = $true, $Complete = $true)
    return [ordered]@{ Success = $Success; Error = 'Synthetic capture failure.'; Warnings = @(); Bundle = [ordered]@{
        ZipPath = $Paths[0]; ZipPaths = @($Paths); Warnings = @(); Complete = $Complete
    } }
}
function Invoke-QACompletion {
    param($Result, [int]$ExitCode = 0, [int]$Percent = 99, [switch]$NoResult, [switch]$Malformed, [switch]$GameRestarted, [switch]$CancellationRequested)
    Initialize-QAUi
    $job = New-QADirectory 'ui-job'
    Write-QASnapshot $job (New-QASnapshot -Sequence 4 -Percent $Percent)
    if ($Malformed) { Write-QAText (Join-Path $job 'result.json') '{"Success":true,' }
    elseif (-not $NoResult) { Write-QAText (Join-Path $job 'result.json') ($Result | ConvertTo-Json -Depth 12) }
    $script:workerJob = $job; $script:worker = Start-QAExitProcess -ExitCode $ExitCode -Wait
    $script:workerSawRunning = $GameRestarted.IsPresent
    $script:cancelRequested = $CancellationRequested.IsPresent
    $script:busy = $true; $script:progressTimer.Running = $true
    Complete-MtzWorker
    Assert-QA (-not $script:busy -and $null -eq $script:worker -and -not $script:progressTimer.Running) 'Finished worker must release busy state and stop progress timer.'
}
function New-QAInstance {
    param([string]$Name, [string]$Log = 'Synthetic Minecraft log.')
    $root = New-QADirectory $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'mods'))
    Write-QAText (Join-Path $root 'logs/latest.log') $Log
    return $root
}
function Assert-QAEventSequence {
    param([object[]]$Events, [int]$Maximum = 99)
    Assert-QA ($Events.Count -gt 0) 'No progress callback was observed.'
    $prior = -1
    foreach ($event in $Events) {
        Assert-QA ($event.Percent -ge 0 -and $event.Percent -le $Maximum -and $event.Percent -eq [Math]::Floor([double]$event.Percent)) 'Progress must be an integer in the permitted range.'
        Assert-QA ($event.Percent -ge $prior) 'Progress callback moved backwards.'
        $prior = $event.Percent
    }
}
function Invoke-QAWorker {
    param([string]$Instance, [string]$Mode, [int]$PartMiB = 2, [switch]$InvalidMode,
        [switch]$CancelBeforeStart, [switch]$CancelAtProgress,
        [string]$CancelStage = '', [int]$CancelMinimumPercent = 1)
    $job = New-QADirectory 'native-worker'
    $output = New-QADirectory 'worker-output'
    $request = [ordered]@{ InstancePath = $Instance; OutputDirectory = $output; SessionStartedUtc = [DateTime]::UtcNow.ToString('o'); Mode = $Mode; PartMiB = $PartMiB }
    if ($InvalidMode) { $request.Mode = 'Unsupported' }
    $requestPath = Join-Path $job 'request.json'
    Write-QAText $requestPath ($request | ConvertTo-Json)
    $cancelSent = $false
    if ($CancelBeforeStart) { Write-QAText (Join-Path $job 'cancel.request') 'cancel'; $cancelSent = $true }
    $priorPackage = Join-Path $output 'earlier-package.keep'
    Write-QAText $priorPackage 'existing output must survive cancellation'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $script:QAPowerShellExecutable
    $start.Arguments = '-NoLogo -NoProfile -NonInteractive -File ' +
        (ConvertTo-MtzProcessArgument (Join-Path $ApplicationDirectory 'Collect-Worker.ps1')) +
        ' -RequestPath ' + (ConvertTo-MtzProcessArgument $requestPath)
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $p = New-Object Diagnostics.Process; $p.StartInfo = $start
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
    $seen = New-Object 'Collections.Generic.List[object]'
    $last = -1L; $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not $p.HasExited) {
        $snapshot = Read-MtzCaptureProgress -JobDirectory $job -AfterSequence $last
        if ($null -ne $snapshot) { $seen.Add($snapshot); $last = $snapshot.Sequence }
        if ($CancelAtProgress -and -not $cancelSent -and $null -ne $snapshot -and
            $snapshot.Percent -ge $CancelMinimumPercent -and
            ([string]::IsNullOrWhiteSpace($CancelStage) -or $snapshot.Stage -eq $CancelStage)) {
            Write-QAText (Join-Path $job 'cancel.request') 'cancel'; $cancelSent = $true
        }
        if ($watch.Elapsed.TotalSeconds -gt 35) { $p.Kill(); $p.Dispose(); throw 'Native worker exceeded test deadline.' }
        [void]$p.WaitForExit(20)
    }
    $snapshot = Read-MtzCaptureProgress -JobDirectory $job -AfterSequence $last
    if ($null -ne $snapshot) { $seen.Add($snapshot) }
    $rawProgress = [IO.File]::ReadAllText((Join-Path $job 'progress.json')) | ConvertFrom-Json
    $result = [IO.File]::ReadAllText((Join-Path $job 'result.json')) | ConvertFrom-Json
    return [pscustomobject]@{ Process = $p; ExitCode = $p.ExitCode; Job = $job; Output = $output; Result = $result;
        Snapshots = @($seen.ToArray()); FinalSnapshot = $rawProgress; CancellationSent = $cancelSent; PriorPackage = $priorPackage;
        Stdout = $stdout.GetAwaiter().GetResult(); Stderr = $stderr.GetAwaiter().GetResult() }
}

try {
    if ($Suite -in @('All', 'UI')) {
        Test-QA 'New and legacy settings preserve explicit choices and default to Diagnostics' {
            $path = Join-Path (New-QADirectory 'settings-migration') 'preferences.json'
            $p = Read-MtzUserPreferences -Path $path
            Assert-QA ($p.CaptureMode -eq 'Diagnostics' -and $p.InstancePath -eq '' -and $p.ConversationUrl -eq '' -and $p.Warning -eq '') 'New user inherited a capture scope or author profile.'
            $fixtureRoot = New-QAInstance 'remembered-instance'
            $url = 'https://chatgpt.com/c/test-migration-123'
            foreach ($mode in @('Full', 'Diagnostics', 'unknown', @('Full'), $true, 1)) {
                Write-QAText $path (@{ InstancePath = $fixtureRoot; ConversationUrl = $url; CaptureMode = $mode } | ConvertTo-Json -Depth 4)
                $p = Read-MtzUserPreferences -Path $path
                $expected = 'Diagnostics'; if ($mode -is [string] -and $mode -eq 'Full') { $expected = 'Full' }
                Assert-QA ($p.CaptureMode -eq $expected) 'Settings migration selected an unexpected collection scope.'
                Assert-QA ($p.InstancePath -eq $fixtureRoot -and $p.ConversationUrl -eq $url) 'Existing valid profile or conversation was not preserved.'
            }
            Write-QAText $path (@{ InstancePath = 123; ConversationUrl = 'https://example.invalid/c/private' } | ConvertTo-Json)
            $p = Read-MtzUserPreferences -Path $path
            Assert-QA ($p.InstancePath -eq '' -and $p.ConversationUrl -eq '' -and $p.CaptureMode -eq 'Diagnostics') 'Invalid field types or foreign conversation URL survived migration.'
            $script:CaseEvidence = @{ NewUserScope = 'Diagnostics'; ExistingFullPreserved = $true; InvalidModeTypesRejected = $true }
        }
        Test-QA 'Invalid or oversized settings return a clear warning and safe defaults' {
            $path = Join-Path (New-QADirectory 'settings-invalid') 'preferences.json'
            foreach ($text in @('{', 'null', '[]', '[{"CaptureMode":"Full"}]', '"text"', 'true', '25', (' ' * 65537))) {
                Write-QAText $path $text
                $p = Read-MtzUserPreferences -Path $path
                Assert-QA ($p.CaptureMode -eq 'Diagnostics' -and $p.InstancePath -eq '' -and $p.ConversationUrl -eq '' -and -not [string]::IsNullOrWhiteSpace($p.Warning)) 'Invalid settings did not produce safe defaults with a warning.'
            }
        }
        Test-QA 'Saving preferences roundtrips Full and allows clearing the remembered conversation' {
            Initialize-QAUi
            $instance = New-QAInstance 'save-settings'
            $script:instance = Get-MtzInstanceInfo $instance
            $script:rememberedInstancePath = $instance
            $script:rememberedConversationUrl = 'https://chatgpt.com/c/old-conversation'
            $script:settingsReady = $true; $modeBox.SelectedIndex = 0; $chatText.Text = ''
            Save-MtzSettings
            $p = Read-MtzUserPreferences $script:settingsFile
            Assert-QA ($p.CaptureMode -eq 'Full' -and $p.InstancePath -eq $instance) 'Explicit Full mode or profile was lost when saving.'
            Assert-QA ($p.ConversationUrl -eq '' -and $script:rememberedConversationUrl -eq '') 'The user could not clear a previously remembered conversation.'
            $chatText.Text = 'https://chatgpt.com/c/new-conversation'; $modeBox.SelectedIndex = 1
            Save-MtzSettings
            $chatText.Text = 'https://example.invalid/c/not-chatgpt'; Save-MtzSettings
            $p = Read-MtzUserPreferences $script:settingsFile
            Assert-QA ($p.CaptureMode -eq 'Diagnostics' -and $p.ConversationUrl -eq 'https://chatgpt.com/c/new-conversation') 'An incomplete or invalid edit erased valid stored preferences.'
            Assert-QA (-not [IO.File]::Exists($script:settingsFile + '.new')) 'A pending settings file remained after successful save.'
        }
        Test-QA 'Profile discovery only returns valid immediate known launcher locations' {
            Initialize-QAUi
            $profileRoot = New-QADirectory 'known-home'; $roamingRoot = New-QADirectory 'known-roaming'
            $cf = Join-Path $profileRoot 'curseforge/minecraft/Instances'
            $a = Join-Path $cf 'Profile A'; $b = Join-Path $cf 'Profile B'; $vanilla = Join-Path $roamingRoot '.minecraft'
            foreach ($root in @($a, $b, $vanilla, (Join-Path $profileRoot 'unrelated/game'), (Join-Path $cf 'nested/deeper-profile'))) {
                [void][IO.Directory]::CreateDirectory((Join-Path $root 'mods'))
            }
            [void][IO.Directory]::CreateDirectory((Join-Path $cf 'not-a-game'))
            $symlinkChecked = $false
            try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $cf 'linked-profile') -Target $a -ErrorAction Stop; $symlinkChecked = $true } catch { }
            $found = @(Get-MtzSuggestedInstances -UserProfile $profileRoot -RoamingData $roamingRoot)
            $actual = @($found | Select-Object -ExpandProperty Path | Sort-Object)
            $expected = @($a, $b, $vanilla | Sort-Object)
            Assert-QA ($actual.Count -eq 3 -and @((Compare-Object $expected $actual)).Count -eq 0) 'Discovery included unrelated/nested/linked folders or omitted a known valid profile.'
            Assert-QA ($null -eq $script:instance -and $script:rememberedInstancePath -eq '') 'Discovery silently selected or persisted a profile.'
            Assert-QA (@(Get-MtzSuggestedInstances -UserProfile '' -RoamingData '').Count -eq 0) 'Explicitly empty search roots fell back to scanning the actual user profile.'
            $script:CaseEvidence = @{ ReturnedProfiles = 3; NestedAndUnrelatedExcluded = $true; SymlinkFixtureSupported = $symlinkChecked; NoAutomaticSelection = $true }
        }
        Test-QA 'Profile discovery is capped at 200 immediate CurseForge candidates' {
            $profileRoot = New-QADirectory 'many-profiles'
            $cf = Join-Path $profileRoot 'curseforge/minecraft/Instances'
            for ($i = 0; $i -lt 205; $i++) { [void][IO.Directory]::CreateDirectory((Join-Path $cf ('profile-{0:D3}/mods' -f $i))) }
            $found = @(Get-MtzSuggestedInstances -UserProfile $profileRoot -RoamingData '')
            Assert-QA ($found.Count -eq 200) 'The bounded immediate profile scan did not enforce its 200-candidate limit.'
            $script:CaseEvidence = @{ AvailableProfiles = 205; ReturnedProfiles = $found.Count }
        }
        Test-QA 'Application lock excludes another process and can be reacquired after release' {
            $data = New-QADirectory 'application-lock'; $scriptPath = Join-Path $data 'lock-probe.ps1'
            Write-QAText $scriptPath @'
param([string]$ApplicationDirectory,[string]$DataDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $ApplicationDirectory 'MTZ-Logi.ps1') -NoGui
$handle=$null
try { $handle=Open-MtzApplicationLock -DataDirectory $DataDirectory; Write-Output 'ACQUIRED'; exit 0 }
catch { Write-Output 'BLOCKED'; exit 7 }
finally { if ($null -ne $handle) { $handle.Dispose() } }
'@
            $first = Open-MtzApplicationLock -DataDirectory $data
            try {
                Assert-QAThrows { $unexpected = Open-MtzApplicationLock -DataDirectory $data; $unexpected.Dispose() } 'A second application acquired an already-owned lock.'
                $start = New-Object Diagnostics.ProcessStartInfo
                $start.FileName = $script:QAPowerShellExecutable
                $argv = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath, '-ApplicationDirectory', $ApplicationDirectory, '-DataDirectory', $data)
                $start.Arguments = (($argv | ForEach-Object { ConvertTo-MtzProcessArgument ([string]$_) }) -join ' ')
                $start.UseShellExecute = $false; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
                $p = New-Object Diagnostics.Process; $p.StartInfo = $start
                try {
                    [void]$p.Start(); $stdout = $p.StandardOutput.ReadToEndAsync(); $stderr = $p.StandardError.ReadToEndAsync()
                    if (-not $p.WaitForExit(10000)) { $p.Kill(); throw 'Application-lock probe timed out.' }
                    Assert-QA ($p.ExitCode -eq 7 -and $stdout.GetAwaiter().GetResult().Trim() -eq 'BLOCKED') 'A separate process did not respect the active application lock.'
                } finally { $p.Dispose() }
            } finally { $first.Dispose() }
            $again = Open-MtzApplicationLock -DataDirectory $data
            try { Assert-QA ($again.CanWrite -and [IO.File]::Exists((Join-Path $data 'aplikacja.lock'))) 'The released lock cannot be reused.' }
            finally { $again.Dispose() }
            Assert-QA ([IO.File]::Exists((Join-Path $data 'aplikacja.lock'))) 'Lock cleanup unlinked the stable lock path.'
            $script:CaseEvidence = @{ RealCrossProcessContention = $true; ReacquisitionAfterDispose = $true }
        }
        Test-QA 'Cancellation request preserves progress, source files and prior archives' {
            Initialize-QAUi
            $script:workerJob = New-QADirectory 'cancel-request'
            $marker = Join-Path $script:workerJob 'previous-package.keep'; Write-QAText $marker 'preserve'
            Request-MtzCancellation
            Assert-QA (-not [IO.File]::Exists((Join-Path $script:workerJob 'cancel.request'))) 'Idle Cancel created a request.'
            $worker = New-QAActiveWorker; $script:worker = $worker; $script:busy = $true
            $script:progressPercent = 37; $progress.Value = 37; $script:pendingAutomatic = $true
            Request-MtzCancellation
            Assert-QA ([IO.File]::Exists((Join-Path $script:workerJob 'cancel.request')) -and $script:cancelRequested -and -not $script:pendingAutomatic) 'Cancel did not request cooperative worker shutdown.'
            Assert-QA ($progress.Value -eq 37 -and $progressLabel.Text -like '*anulowanie*' -and $script:busy) 'Cancel invented completion or released the still-running worker.'
            Assert-QA (-not $cancelButton.Enabled -and -not $chooseButton.Enabled -and -not $profilesButton.Enabled -and -not $buildButton.Enabled) 'Controls permit a conflicting operation while canceling.'
            Assert-QA ($worker.KillCalls -eq 0 -and $worker.WaitCalls -eq 0 -and [IO.File]::ReadAllText($marker) -eq 'preserve') 'Cancel blocked the UI, killed the worker or removed previous data.'
            $script:worker = $null; $script:busy = $false
        }
        Test-QA 'Canceled worker is neither success nor error and leaves prior packages intact' {
            $dir = New-QADirectory 'cancel-complete'; $prior = New-QAZip (Join-Path $dir 'previous.zip')
            $result = [ordered]@{ Success = $false; Canceled = $true; Error = 'Anulowano.'; Warnings = @(); Bundle = $null }
            Invoke-QACompletion $result -ExitCode 3 -Percent 62 -CancellationRequested
            Assert-QA ($script:captureCanceled -and $script:lastCaptureError -eq '' -and $script:ShownErrors.Count -eq 0) 'Cancellation was reported as an error.'
            Assert-QA ($progress.Value -eq 62 -and $progressLabel.Text -like '*anulowano*' -and $script:bundlePaths.Count -eq 0) 'Canceled output was presented as a completed bundle.'
            Assert-QA (-not $cancelButton.Enabled -and $chooseButton.Enabled -and $profilesButton.Enabled -and -not $script:cancelRequested) 'Cancellation completion left controls disabled or a stale request active.'
            Assert-QA ([IO.File]::Exists($prior) -and -not [IO.Directory]::Exists($script:workerJob)) 'Cancel cleanup removed a prior ZIP or left its finished job controls.'
            $script:CaseEvidence = @{ DisplayedPercent = $progress.Value; ErrorDialogs = 0; WorkerExit = 3; PreviousZipPreserved = $true }
        }
        Test-QA 'Malformed or contradictory cancellation results are rejected as protocol errors' {
            $zip = New-QAZip (Join-Path (New-QADirectory 'cancel-invalid') 'valid.zip')
            $variants = @(
                @{ Success = $false; Canceled = 'true'; ExitCode = 3 },
                @{ Success = $true; Canceled = $true; ExitCode = 0 },
                @{ Success = $false; Canceled = $true; ExitCode = 0 },
                @{ Success = 'false'; Canceled = $true; ExitCode = 3 }
            )
            foreach ($variant in $variants) {
                $result = New-QAResult -Paths @($zip) -Success $variant.Success; $result.Canceled = $variant.Canceled
                Invoke-QACompletion $result -ExitCode $variant.ExitCode -Percent 52
                Assert-QA (-not $script:captureCanceled -and $script:ShownErrors.Count -eq 1 -and $script:bundlePaths.Count -eq 0 -and $progress.Value -lt 100) 'Malformed worker JSON was concealed as a successful cancellation.'
            }
        }
        Test-QA 'A successful worker result wins a late cancellation request without discarding a good ZIP' {
            $zip = New-QAZip (Join-Path (New-QADirectory 'cancel-race') 'complete.zip')
            $result = New-QAResult -Paths @($zip); $result.Canceled = $false
            Invoke-QACompletion $result -ExitCode 0 -CancellationRequested
            Assert-QA ($progress.Value -eq 100 -and -not $script:captureCanceled -and $script:ShownErrors.Count -eq 0 -and [IO.File]::Exists($zip)) 'Late cancellation hid an already completed, validated result.'
        }
        Test-QA 'Window close asks once and waits asynchronously for canceled worker cleanup' {
            Initialize-QAUi
            $script:workerJob = New-QADirectory 'close-active'
            $worker = New-QAActiveWorker; $script:worker = $worker; $script:busy = $true
            $script:progressPercent = 45; $progress.Value = 45
            $eventArgs = [pscustomobject]@{ Cancel = $false }
            & $script:ClosingEvent $form $eventArgs
            Assert-QA ($eventArgs.Cancel -and -not $script:closeAfterCapture -and -not $script:cancelRequested -and $script:ConfirmationCalls -eq 1) 'Declining the close confirmation did not preserve active work.'
            $script:CloseAnswer = 'Yes'; $eventArgs.Cancel = $false
            & $script:ClosingEvent $form $eventArgs
            Assert-QA ($eventArgs.Cancel -and $script:closeAfterCapture -and $script:cancelRequested) 'Confirmed close did not request asynchronous cancellation.'
            $eventArgs.Cancel = $false; & $script:ClosingEvent $form $eventArgs
            Assert-QA ($eventArgs.Cancel -and $script:ConfirmationCalls -eq 2) 'Repeated close opened another confirmation while cancellation was already pending.'
            & $script:ObserverTick
            Assert-QA ($form.CloseCalls -eq 0 -and $worker.KillCalls -eq 0 -and $worker.WaitCalls -eq 0) 'Window close blocked or forced the still-running worker.'
            Write-QASnapshot $script:workerJob (New-QASnapshot -Sequence 2 -Percent 48)
            Write-QAText (Join-Path $script:workerJob 'result.json') (@{ Success = $false; Canceled = $true; Error = ''; Warnings = @(); Bundle = $null } | ConvertTo-Json)
            $worker.HasExited = $true
            & $script:ObserverTick
            Assert-QA ($form.CloseCalls -eq 1 -and -not $script:busy -and $null -eq $script:worker -and -not $script:closeAfterCapture) 'Window failed to close after worker completion.'
            Assert-QA ($worker.DisposeCalls -eq 1 -and $script:captureCanceled -and $progress.Value -eq 48 -and $script:ShownErrors.Count -eq 0) 'Asynchronous close disposed twice, showed success or displayed a cancellation error.'
            $script:CaseEvidence = @{ FakeFormAndConfirmation = $true; ConfirmationCalls = 2; BlockingWaitCalls = 0; ForcedKillCalls = 0; FinalPercent = $progress.Value }
        }
        Test-QA 'Failed cancellation request leaves the window open and reports the problem' {
            Initialize-QAUi
            $script:workerJob = Join-Path (New-QADirectory 'close-write-error') 'missing-job'
            $worker = New-QAActiveWorker; $script:worker = $worker; $script:busy = $true; $script:CloseAnswer = 'Yes'
            $eventArgs = [pscustomobject]@{ Cancel = $false }
            & $script:ClosingEvent $form $eventArgs
            Assert-QA ($eventArgs.Cancel -and -not $script:closeAfterCapture -and -not $script:cancelRequested -and $script:ShownErrors.Count -eq 1) 'A failed Cancel write closed the window or concealed the failure.'
            Assert-QA ($worker.KillCalls -eq 0 -and $worker.WaitCalls -eq 0 -and $form.CloseCalls -eq 0) 'Cancellation failure force-stopped the worker.'
            $script:worker = $null; $script:busy = $false
        }
        Test-QA 'Snapshot rejects missing, malformed, truncated, oversized and invalid UTF8 data' {
            $job = New-QADirectory 'reader'
            Assert-QA ($null -eq (Read-MtzCaptureProgress -JobDirectory '')) 'Empty job should be ignored.'
            Assert-QA ($null -eq (Read-MtzCaptureProgress -JobDirectory $job)) 'Missing snapshot should be ignored.'
            foreach ($text in @('', '{', '{"Version":1,"Sequence":', 'null', '[]', '{"Version":1}', ('x' * 17000))) {
                Write-QAText (Join-Path $job 'progress.json') $text
                Assert-QA ($null -eq (Read-MtzCaptureProgress -JobDirectory $job)) 'Invalid snapshot was accepted.'
            }
            [IO.File]::WriteAllBytes((Join-Path $job 'progress.json'), [byte[]]@(255, 255, 0, 65))
            Assert-QA ($null -eq (Read-MtzCaptureProgress -JobDirectory $job)) 'Invalid UTF8 was accepted.'
            $script:CaseEvidence = @{ RejectedVariants = 10 }
        }
        Test-QA 'Snapshot protocol rejects old sequences, unsupported version and percent100' {
            $job = New-QADirectory 'protocol'
            foreach ($percent in @(-1, 100, 101, 0.5, 'NaN', 'Infinity')) {
                $s = New-QASnapshot; $s.Percent = $percent; Write-QASnapshot $job $s
                Assert-QA ($null -eq (Read-MtzCaptureProgress -JobDirectory $job)) ('Invalid percent accepted: ' + $percent)
            }
            foreach ($sequence in @(-1L, 4L, 5L)) {
                $s = New-QASnapshot -Sequence $sequence; Write-QASnapshot $job $s
                Assert-QA ($null -eq (Read-MtzCaptureProgress -JobDirectory $job -AfterSequence 5)) 'Old or negative sequence accepted.'
            }
            $s = New-QASnapshot; $s.Version = 2; Write-QASnapshot $job $s
            Assert-QA ($null -eq (Read-MtzCaptureProgress -JobDirectory $job)) 'Unknown protocol version accepted.'
            Write-QASnapshot $job (New-QASnapshot -Sequence 6 -Percent 99 -Stage ('S' * 150) -Detail ('D' * 500))
            $read = Read-MtzCaptureProgress -JobDirectory $job -AfterSequence 5
            Assert-QA ($read.Sequence -eq 6 -and $read.Percent -eq 99) 'Valid latest snapshot lost.'
            Assert-QA ($read.Stage.Length -eq 120 -and $read.Detail.Length -eq 400) 'Display text limits lost.'
        }
        Test-QA 'Actual display state stays monotonic and ignores stale or unavailable snapshots' {
            Initialize-QAUi
            $script:workerJob = New-QADirectory 'display'; $script:busy = $true
            Write-QASnapshot $script:workerJob (New-QASnapshot -Sequence 1 -Percent 70)
            Update-MtzCaptureProgressDisplay
            Assert-QA ($progress.Value -eq 70 -and $progressLabel.Text -eq '70%') 'First actual display update failed.'
            Write-QASnapshot $script:workerJob (New-QASnapshot -Sequence 2 -Percent 30)
            Update-MtzCaptureProgressDisplay
            Assert-QA ($progress.Value -eq 70 -and $script:lastProgressSequence -eq 2) 'Later low percent regressed display.'
            Write-QASnapshot $script:workerJob (New-QASnapshot -Sequence 1 -Percent 99)
            Update-MtzCaptureProgressDisplay
            Assert-QA ($progress.Value -eq 70) 'Old snapshot changed display.'
            Write-QAText (Join-Path $script:workerJob 'progress.json') '{'
            Update-MtzCaptureProgressDisplay
            Assert-QA ($progress.Value -eq 70) 'Partial snapshot reset display.'
            Reset-MtzProgressDisplay
            Assert-QA ($progress.Value -eq 0 -and $script:lastProgressSequence -eq -1 -and $progressLabel.Text -eq '0%') 'Reset did not reset all counters.'
            $script:CaseEvidence = @{ ObservedValues = @(70, 70, 70, 70, 0); FakeControls = $true }
        }
        Test-QA 'New attempt resets old100 and part selection before preflight failure' {
            Initialize-QAUi
            $modeBox.SelectedIndex = 0
            $script:progressPercent = 100; $progress.Value = 100; $progressLabel.Text = '100%'
            $script:bundlePaths = @('old.zip'); [void]$partsBox.Items.Add('old.zip'); $partsBox.SelectedIndex = 0
            $script:instance = [pscustomobject]@{ RootPath = $script:TestRoot }
            $original = (Get-Command Get-MtzGameProcessState).ScriptBlock
            function Get-MtzGameProcessState { param([string]$InstancePath) [pscustomobject]@{ Known = $true; Running = $true } }
            try { Assert-QAThrows { Start-MtzPackage } 'Expected full-capture preflight rejection.' }
            finally { Set-Item Function:Get-MtzGameProcessState $original }
            Assert-QA ($progress.Value -eq 0 -and $progressLabel.Text -eq '0%') 'Old100 survived the next attempt.'
            Assert-QA ($script:bundlePaths.Count -eq 0 -and $partsBox.Items.Count -eq 0 -and -not $sendButton.Enabled) 'Old archive selection survived new attempt.'
        }
        Test-QA 'Archive readiness accepts closed ZIP and rejects arbitrary, truncated and empty ZIPs' {
            $dir = New-QADirectory 'zip-gate'; $good = New-QAZip (Join-Path $dir 'good.zip')
            Assert-MtzReadyArchive -Path $good
            $junk = Join-Path $dir 'junk.zip'; Write-QAText $junk 'this is not a ZIP archive'
            Assert-QAThrows { Assert-MtzReadyArchive -Path $junk } 'Arbitrary bytes passed ZIP validation.'
            $truncated = Join-Path $dir 'truncated.zip'; $bytes = [IO.File]::ReadAllBytes($good)
            [IO.File]::WriteAllBytes($truncated, [byte[]]$bytes[0..($bytes.Length - 12)])
            Assert-QAThrows { Assert-MtzReadyArchive -Path $truncated } 'Missing ZIP trailer passed validation.'
            $empty = New-QAZip (Join-Path $dir 'empty.zip') -Empty
            Assert-QAThrows { Assert-MtzReadyArchive -Path $empty } 'Empty ZIP passed validation.'
            Assert-QAThrows { Assert-MtzReadyArchive -Path $good -MaximumBytes 10 } 'Archive size limit was ignored.'
        }
        Test-QA 'Successful completion alone enables100 and preserves multiple selectable archives' {
            $dir = New-QADirectory 'complete'
            $paths = @(New-QAZip (Join-Path $dir 'one.zip'); New-QAZip (Join-Path $dir 'two.zip'))
            Invoke-QACompletion (New-QAResult -Paths $paths)
            Assert-QA ($progress.Value -eq 100 -and $progressLabel.Text -eq '100%' -and $script:ShownErrors.Count -eq 0) 'Valid completed bundle was not accepted.'
            Assert-QA ($partsRow.Visible -and $partsBox.Enabled -and $partsBox.Items.Count -eq 2 -and $panel.RowStyles[10].Height -eq 42) 'Multipart selection was lost.'
            $partsBox.SelectedIndex = 1; Update-MtzButtons
            Assert-QA ((Get-MtzSelectedZip) -eq $paths[1] -and $sendButton.Enabled -and $showButton.Enabled) 'Second part cannot be selected.'
            Update-MtzCaptureProgressDisplay
            Assert-QA ($progress.Value -eq 100 -and $partsBox.SelectedIndex -eq 1) 'Idle polling changed completed state.'
            Assert-QA ([IO.File]::Exists($paths[0]) -and [IO.File]::Exists($paths[1])) 'UI cleanup deleted capture outputs.'
            $script:CaseEvidence = @{ Percent = 100; Archives = 2; SelectedPart = 2; ActualExitedSubprocess = $true; FakeControls = $true }
        }
        Test-QA 'Error results, nonzero exit, missing result and malformed result never display100' {
            $dir = New-QADirectory 'errors'; $zip = New-QAZip (Join-Path $dir 'valid.zip')
            $variants = @(
                @{ Result = (New-QAResult -Paths @($zip) -Success $false); ExitCode = 0 },
                @{ Result = (New-QAResult -Paths @($zip)); ExitCode = 5 },
                @{ Result = (New-QAResult -Paths @($zip)); NoResult = $true },
                @{ Result = (New-QAResult -Paths @($zip)); Malformed = $true },
                @{ Result = (New-QAResult -Paths @($zip) -Success 'false') },
                @{ Result = (New-QAResult -Paths @($zip) -Complete 'false') }
            )
            foreach ($variant in $variants) {
                Invoke-QACompletion @variant
                Assert-QA ($progress.Value -lt 100 -and $script:ShownErrors.Count -eq 1 -and $script:bundlePaths.Count -eq 0 -and -not $partsRow.Visible) 'Failed/malformed result was presented as completed.'
            }
            $script:CaseEvidence = @{ RejectedResults = 6; MaximumDisplayedPercent = 99; ActualExitedSubprocesses = $true }
        }
        Test-QA 'Bad ZIP content never enables100 despite successful worker result and exit0' {
            $dir = New-QADirectory 'invalid-completion'; $junk = Join-Path $dir 'bad.zip'
            Write-QAText $junk 'incorrect archive contents'
            Invoke-QACompletion (New-QAResult -Paths @($junk))
            Assert-QA ($progress.Value -lt 100 -and $script:bundlePaths.Count -eq 0 -and $script:ShownErrors.Count -eq 1) 'Bad archive reached100.'
        }
        Test-QA 'Incomplete capture and game restart keep reviewable parts but never display100' {
            $dir = New-QADirectory 'incomplete-ui'; $zip = New-QAZip (Join-Path $dir 'partial.zip')
            Invoke-QACompletion (New-QAResult -Paths @($zip) -Complete $false)
            Assert-QA ($progress.Value -eq 99 -and $progressLabel.Text -like '*niepełna*' -and $partsRow.Visible -and $script:ShownErrors.Count -eq 0) 'Incomplete result was not clearly distinguished.'
            Assert-QA ((Get-MtzSelectedZip) -eq $zip) 'Incomplete archive cannot be inspected.'
            Invoke-QACompletion (New-QAResult -Paths @($zip)) -GameRestarted
            Assert-QA ($progress.Value -eq 99 -and $progressLabel.Text -like '*niepełna*') 'Game restart during capture incorrectly reached100.'
        }
    }

    if ($Suite -in @('All', 'Engine')) {
        Test-QA 'Real pre-canceled worker exits3 with no new package and GUI shows cancellation' {
            foreach ($mode in @('Diagnostics', 'Full')) {
                $instance = New-QAInstance ('pre-cancel-' + $mode)
                $before = (Get-FileHash (Join-Path $instance 'logs/latest.log')).Hash
                $capture = Invoke-QAWorker -Instance $instance -Mode $mode -CancelBeforeStart
                Assert-QA ($capture.CancellationSent -and $capture.ExitCode -eq 3 -and -not $capture.Result.Success -and $capture.Result.Canceled -is [bool] -and $capture.Result.Canceled) 'Pre-canceled worker did not return the cancellation protocol.'
                Assert-QAEventSequence $capture.Snapshots 99
                Assert-QA ($capture.FinalSnapshot.Percent -lt 99 -and $capture.FinalSnapshot.Stage -eq 'Anulowano') 'Cancellation reported a ready output stage.'
                Assert-QA ([IO.File]::Exists($capture.PriorPackage) -and @(Get-ChildItem -LiteralPath $capture.Output -Recurse -Force -File).Count -eq 1) 'Cancellation removed prior data or left a new partial archive.'
                Assert-QA ((Get-FileHash (Join-Path $instance 'logs/latest.log')).Hash -eq $before) 'Canceled worker changed a Minecraft source file.'
                Initialize-QAUi
                $script:workerJob = $capture.Job; $script:worker = $capture.Process; $script:workerMode = $mode; $script:busy = $true
                Complete-MtzWorker
                Assert-QA ($script:captureCanceled -and $progress.Value -lt 100 -and $script:ShownErrors.Count -eq 0 -and $script:bundlePaths.Count -eq 0) 'A real canceled worker became a success/error in the GUI.'
            }
            $script:CaseEvidence = @{ Modes = @('Diagnostics', 'Full'); ExitCode = 3; NewArchiveCount = 0; NativeWorkersExecuted = $true; FakeControls = $true }
        }
        Test-QA 'Real Full cancellation after progress cleans its own partial copy and preserves the source' {
            $instance = New-QAInstance 'cancel-in-progress'
            $large = Join-Path $instance 'mods/large.jar'; $bytes = New-Object byte[] (32MB + 117)
            (New-Object Random(933)).NextBytes($bytes); [IO.File]::WriteAllBytes($large, $bytes); $bytes = $null
            $before = (Get-FileHash $large).Hash
            $capture = Invoke-QAWorker -Instance $instance -Mode Full -PartMiB 2 -CancelAtProgress -CancelStage 'Kopiowanie i kompresja' -CancelMinimumPercent 13
            Assert-QA ($capture.CancellationSent -and $capture.ExitCode -eq 3 -and $capture.Result.Canceled -and -not $capture.Result.Success) 'Cancellation after observed progress did not stop the running worker.'
            Assert-QAEventSequence $capture.Snapshots 99
            $copying = @($capture.Snapshots | Where-Object { $_.Stage -eq 'Kopiowanie i kompresja' -and $_.Percent -gt 12 })
            Assert-QA ($copying.Count -gt 0 -and $capture.FinalSnapshot.Stage -eq 'Anulowano') 'The test did not observe actual byte-copy progress before cancellation.'
            Assert-QA ([IO.File]::Exists($capture.PriorPackage) -and @(Get-ChildItem -LiteralPath $capture.Output -Recurse -Force -File).Count -eq 1) 'Cancellation removed prior data or kept owned partial output.'
            Assert-QA ((Get-FileHash $large).Hash -eq $before) 'Cancellation changed the copied source data.'
            Initialize-QAUi
            $script:workerJob = $capture.Job; $script:worker = $capture.Process; $script:workerMode = 'Full'; $script:busy = $true
            Complete-MtzWorker
            Assert-QA ($script:captureCanceled -and $progress.Value -lt 100 -and $script:ShownErrors.Count -eq 0) 'Real mid-copy cancellation was misreported by the GUI.'
            $script:CaseEvidence = @{ ExitCode = 3; ObservedSnapshots = $capture.Snapshots.Count; CancellationStage = 'Kopiowanie i kompresja'; CanceledStatusCompletedBytes = $capture.FinalSnapshot.CompletedBytes; ObservedCopyProgressPercent = $copying[0].Percent; FinalPercent = $progress.Value; NativeWorkerExecuted = $true; FakeControls = $true; OriginalSha256 = $before }
        }
        Test-QA 'Diagnostic ZIP reports bytes within one large entry and stays below completion' {
            $instance = New-QAInstance 'diagnostic' -Log (('[Server thread/INFO] minecraft:stone sample diagnostic.' + [Environment]::NewLine) * 50000)
            $events = New-Object 'Collections.Generic.List[object]'
            $callback = { param($s) $events.Add($s) }.GetNewClosure()
            $bundle = New-MtzDiagnosticBundle -InstancePath $instance -OutputDirectory (New-QADirectory 'diagnostic-output') -ProgressCallback $callback
            Assert-QAEventSequence @($events.ToArray()) 90
            $writes = @($events | Where-Object { $_.Stage -eq 'Kompresja diagnostyki' -and $_.CompletedFiles -eq 0 -and $_.CompletedBytes -gt 0 })
            Assert-QA ($writes.Count -ge 2 -and $writes[-1].CompletedBytes -gt $writes[0].CompletedBytes) 'Large diagnostic entry only reported file-level progress.'
            Assert-MtzReadyArchive $bundle.ZipPath
            $script:CaseEvidence = @{ CallbackEvents = $events.Count; WithinFirstEntry = @($writes | Select-Object Percent, CompletedBytes, TotalBytes); FinalPercent = $events[$events.Count - 1].Percent }
        }
        Test-QA 'Full copy reports byte-level progress inside large file and restores exact bytes' {
            $instance = New-QAInstance 'full-progress'
            $path = Join-Path $instance 'mods/large.jar'; $bytes = New-Object byte[] (8MB + 135)
            (New-Object Random(731)).NextBytes($bytes); [IO.File]::WriteAllBytes($path, $bytes); $bytes = $null
            Write-QAText (Join-Path $instance 'config/empty.toml') ''
            $events = New-Object 'Collections.Generic.List[object]'; $callback = { param($s) $events.Add($s) }.GetNewClosure()
            $bundle = New-MtzFullBundle -InstancePath $instance -OutputDirectory (New-QADirectory 'full-output') -PartMiB 2 -ProgressCallback $callback
            Assert-QAEventSequence @($events.ToArray()) 98
            Assert-QA $bundle.Complete 'Stable fixture was marked incomplete.'
            $pack = @($events | Where-Object { $_.Stage -eq 'Kopiowanie i kompresja' -and $_.CompletedBytes -gt 0 })
            $within = @($pack | Group-Object CompletedFiles | Where-Object { @($_.Group | Select-Object -ExpandProperty CompletedBytes -Unique).Count -ge 4 })
            Assert-QA ($within.Count -gt 0) 'Large file did not produce several distinct byte-progress updates before completion.'
            foreach ($zip in $bundle.ZipPaths) { Assert-MtzReadyArchive $zip }
            $restoreDirectory = Join-Path $script:TestRoot ('restored-' + [Guid]::NewGuid().ToString('N'))
            $restored = & (Join-Path $ApplicationDirectory 'Restore-MTZ-Paczka.ps1') -SourceDirectory $bundle.SessionDirectory -DestinationDirectory $restoreDirectory
            Assert-QA ($restored.Complete -and (Get-FileHash $path).Hash -eq (Get-FileHash (Join-Path $restoreDirectory 'mods/large.jar')).Hash) 'Large source bytes changed during capture/restoration.'
            Assert-QA ((Get-Item (Join-Path $restoreDirectory 'config/empty.toml')).Length -eq 0) 'Empty file was not restored.'
            $script:CaseEvidence = @{ CallbackEvents = $events.Count; DistinctByteUpdatesWithinOneFile = @($within[0].Group | Select-Object -ExpandProperty CompletedBytes -Unique).Count; Archives = $bundle.ZipPaths.Count; RestoredLargeFileSha256 = (Get-FileHash $path).Hash; EmptyFileRestored = $true }
        }
        Test-QA 'All-zero-byte input completes file progress without NaN or false byte counts' {
            $instance = New-QAInstance 'zero-bytes' -Log ''
            Write-QAText (Join-Path $instance 'mods/empty.jar') ''
            Write-QAText (Join-Path $instance 'config/empty.toml') ''
            $events = New-Object 'Collections.Generic.List[object]'; $callback = { param($s) $events.Add($s) }.GetNewClosure()
            $bundle = New-MtzFullBundle -InstancePath $instance -OutputDirectory (New-QADirectory 'zero-output') -PartMiB 1 -ProgressCallback $callback
            Assert-QAEventSequence @($events.ToArray()) 98
            Assert-QA ($bundle.Complete -and $bundle.TotalSourceBytes -eq 0 -and $bundle.FileCount -eq 3) 'Zero-byte fixture capture changed.'
            $pack = @($events | Where-Object { $_.Stage -eq 'Kopiowanie i kompresja' })
            Assert-QA (@($pack | Where-Object { $_.CompletedBytes -ne 0 -or $_.TotalBytes -ne 0 }).Count -eq 0) 'Zero-byte files invented processed bytes.'
            Assert-QA (@($pack | Where-Object { $_.CompletedFiles -eq 3 -and $_.TotalFiles -eq 3 }).Count -gt 0) 'Empty-file completion was not reported.'
            foreach ($zip in $bundle.ZipPaths) { Assert-MtzReadyArchive $zip }
            $script:CaseEvidence = @{ Files = 3; SourceBytes = 0; CallbackEvents = $events.Count; FinalPercent = $events[$events.Count - 1].Percent }
        }
        Test-QA 'Locked file stays an explicit skip and its unread bytes are not credited' {
            $instance = New-QAInstance 'locked-file'
            $lockedPath = Join-Path $instance 'config/locked.bin'
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($lockedPath))
            [IO.File]::WriteAllBytes($lockedPath, (New-Object byte[] 1048576))
            $events = New-Object 'Collections.Generic.List[object]'; $callback = { param($s) $events.Add($s) }.GetNewClosure()
            $lock = New-Object IO.FileStream($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            try { $bundle = New-MtzFullBundle -InstancePath $instance -OutputDirectory (New-QADirectory 'locked-output') -PartMiB 1 -ProgressCallback $callback }
            finally { $lock.Dispose() }
            Assert-QAEventSequence @($events.ToArray()) 98
            Assert-QA (-not $bundle.Complete -and $bundle.SkippedCount -gt 0) 'Locked source was reported as complete.'
            $pack = @($events | Where-Object { $_.Stage -eq 'Kopiowanie i kompresja' })
            Assert-QA ($pack[-1].CompletedBytes -lt $pack[-1].TotalBytes) 'Unread skipped bytes were credited as copied.'
            $manifest = [IO.File]::ReadAllText($bundle.ManifestPath) | ConvertFrom-Json
            Assert-QA (@($manifest.Skipped | Where-Object { $_.Path -eq 'config/locked.bin' }).Count -eq 1) 'Skipped path missing from manifest.'
            foreach ($zip in $bundle.ZipPaths) { Assert-MtzReadyArchive $zip }
            $script:CaseEvidence = @{ Complete = $false; Skipped = $bundle.SkippedCount; ActualCopiedBytes = $pack[-1].CompletedBytes; PlannedBytes = $pack[-1].TotalBytes; FinalPercent = $events[$events.Count - 1].Percent }
        }
        Test-QA 'Throwing or noisy callback cannot corrupt the archive result' {
            $instance = New-QAInstance 'callback-failure'
            $script:CallbackAttempts = 0
            $callback = { param($s) $script:CallbackAttempts++; Write-Output 'unwanted callback output'; throw 'synthetic reporting failure' }
            $results = @(New-MtzDiagnosticBundle -InstancePath $instance -OutputDirectory (New-QADirectory 'callback-output') -ProgressCallback $callback)
            Assert-QA ($results.Count -eq 1 -and $script:CallbackAttempts -gt 0) 'Callback output contaminated capture return value.'
            Assert-MtzReadyArchive $results[0].ZipPath
            $script:CaseEvidence = @{ SuppressedReportingFailures = $script:CallbackAttempts; CaptureSucceeded = $true }
        }
        Test-QA 'Real diagnostics worker writes valid monotonic IPC and only UI promotes99 to100' {
            $instance = New-QAInstance 'ipc-diagnostics' -Log (('A Minecraft diagnostic line.' + [Environment]::NewLine) * 50000)
            $capture = Invoke-QAWorker -Instance $instance -Mode Diagnostics
            $script:CaseEvidence = @{ FinalSnapshot = $capture.FinalSnapshot; WorkerExit = $capture.ExitCode; ObservedSnapshots = $capture.Snapshots.Count }
            Assert-QA ($capture.ExitCode -eq 0 -and $capture.Result.Success -is [bool] -and $capture.Result.Success) 'Native worker failed diagnostics.'
            Assert-QAEventSequence $capture.Snapshots 99
            Assert-QA ($capture.FinalSnapshot.Version -eq 1 -and $capture.FinalSnapshot.Percent -eq 99 -and $capture.FinalSnapshot.Sequence -gt 1 -and $capture.FinalSnapshot.UpdatedUtc) 'Final IPC snapshot is invalid.'
            $prior = -1L
            foreach ($s in $capture.Snapshots) { Assert-QA ($s.Sequence -gt $prior) 'IPC sequence was not strictly increasing.'; $prior = $s.Sequence }
            Assert-QA (-not [IO.File]::Exists((Join-Path $capture.Job 'progress.json.new'))) 'Temporary IPC file survived completion.'
            Initialize-QAUi
            $script:workerJob = $capture.Job; $script:worker = $capture.Process; $script:workerMode = 'Diagnostics'; $script:busy = $true
            Update-MtzCaptureProgressDisplay
            Assert-QA ($progress.Value -eq 99) 'Worker IPC prematurely displayed100.'
            Complete-MtzWorker
            Assert-QA ($progress.Value -eq 100 -and $script:bundlePaths.Count -eq 1 -and $script:ShownErrors.Count -eq 0) 'Actual successful worker result did not enable100.'
            $script:CaseEvidence = @{ WorkerExit = 0; ObservedSnapshots = $capture.Snapshots.Count; WorkerFinalPercent = 99; UiFinalPercent = $progress.Value; FakeControls = $true }
        }
        Test-QA 'Real full worker retains multipart output and completed archive selection' {
            $instance = New-QAInstance 'ipc-full'
            $bytes = New-Object byte[] (3MB + 888); (New-Object Random(33)).NextBytes($bytes)
            [IO.File]::WriteAllBytes((Join-Path $instance 'mods/large.jar'), $bytes)
            $capture = Invoke-QAWorker -Instance $instance -Mode Full -PartMiB 1
            $script:CaseEvidence = @{ FinalSnapshot = $capture.FinalSnapshot; WorkerExit = $capture.ExitCode; ObservedSnapshots = $capture.Snapshots.Count }
            Assert-QA ($capture.ExitCode -eq 0 -and $capture.Result.Success -and $capture.Result.Bundle.Complete) 'Native full worker did not complete.'
            Assert-QAEventSequence $capture.Snapshots 99
            Assert-QA ($capture.FinalSnapshot.Version -eq 1 -and $capture.FinalSnapshot.Percent -eq 99 -and $capture.FinalSnapshot.Sequence -gt 1) 'Full worker never published progress after its initial snapshot.'
            Assert-QA ($capture.Result.Bundle.ZipPaths.Count -ge 5) 'Full worker lost split archives.'
            foreach ($zip in $capture.Result.Bundle.ZipPaths) { Assert-MtzReadyArchive $zip }
            Initialize-QAUi
            $script:workerJob = $capture.Job; $script:worker = $capture.Process; $script:workerMode = 'Full'; $script:busy = $true
            Complete-MtzWorker
            Assert-QA ($progress.Value -eq 100 -and $partsBox.Items.Count -eq $capture.Result.Bundle.ZipPaths.Count -and $partsRow.Visible) 'Full worker completion lost multipart UI state.'
            $partsBox.SelectedIndex = $partsBox.Items.Count - 1
            Assert-QA ((Get-MtzSelectedZip) -eq $capture.Result.Bundle.ZipPaths[-1]) 'Final multipart ZIP is not selectable.'
            $script:CaseEvidence = @{ WorkerExit = 0; ObservedSnapshots = $capture.Snapshots.Count; WorkerFinalPercent = $capture.FinalSnapshot.Percent; UiFinalPercent = $progress.Value; Archives = $partsBox.Items.Count; FakeControls = $true }
        }
        Test-QA 'Real failed worker reports failure IPC and never reaches100' {
            $instance = New-QAInstance 'ipc-failed'
            $capture = Invoke-QAWorker -Instance $instance -Mode Diagnostics -InvalidMode
            Assert-QA ($capture.ExitCode -eq 1 -and -not $capture.Result.Success) 'Invalid request was not rejected by worker.'
            Assert-QAEventSequence $capture.Snapshots 99
            Initialize-QAUi
            $script:workerJob = $capture.Job; $script:worker = $capture.Process; $script:busy = $true
            Complete-MtzWorker
            Assert-QA ($progress.Value -lt 100 -and $script:ShownErrors.Count -eq 1 -and $script:bundlePaths.Count -eq 0) 'Failed native worker enabled successful UI completion.'
            $script:CaseEvidence = @{ WorkerExit = 1; ObservedSnapshots = $capture.Snapshots.Count; WorkerFinalPercent = $capture.FinalSnapshot.Percent; UiFinalPercent = $progress.Value; FakeControls = $true }
        }
    }
} finally {
    if ($null -ne (Get-Variable worker -Scope Script -ErrorAction SilentlyContinue) -and $null -ne $script:worker) {
        try { if (-not $script:worker.HasExited) { $script:worker.Kill() }; $script:worker.Dispose() } catch { }
    }
    if (Test-Path -LiteralPath $script:TestRoot) { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force }
}
$changed = @()
foreach ($name in $inputHashes.Keys) {
    if ((Get-FileHash -LiteralPath (Join-Path $ApplicationDirectory $name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $inputHashes[$name]) { $changed += $name }
}
$failed = @($script:Cases | Where-Object { $_.Status -eq 'FAIL' }).Count
$report = [ordered]@{
    Version = '0.3.0-rc.1'; Suite = $Suite; Runtime = $PSVersionTable.PSVersion.ToString()
    Platform = [Environment]::OSVersion.Platform.ToString(); Cases = $script:Cases.Count
    PassedCases = $script:Cases.Count - $failed; FailedCases = $failed; Assertions = $script:Assertions
    NativePowerShellExecuted = $true; NativeArchiveAndWorkerOperations = ($Suite -in @('All', 'Engine'))
    UiStateUsesExplicitFakeControls = $true; WindowsFormsRendered = $false; WindowsPowerShell51Executed = $false
    InputSha256 = $inputHashes; SourceFilesChangedDuringTests = @($changed); Results = @($script:Cases.ToArray())
}
[IO.File]::WriteAllText($ResultPath, ($report | ConvertTo-Json -Depth 12) + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
Write-Output ('RESULT cases=' + $script:Cases.Count + ' passed=' + ($script:Cases.Count - $failed) + ' failed=' + $failed + ' assertions=' + $script:Assertions)
if ($failed -gt 0 -or $changed.Count -gt 0) { exit 1 }
