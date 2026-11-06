param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'validation/release-0.3.0-rc.1'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'session.ps1')
$script:Checks = 0
function Assert-Session {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw ('FAILED: ' + $Name) }
    $script:Checks++
}
$t = [DateTime]::SpecifyKind([DateTime]'2026-01-01T12:00:00', [DateTimeKind]::Utc)
$s = New-MtzSessionState -Fingerprint 'old' -NowUtc $t
Assert-Session (-not $s.SeenGame -and -not $s.Completed -and -not $s.ShouldCollect) 'initial state waits'
$s = Update-MtzSessionState -State $s -Fingerprint 'old' -ProcessStateKnown $true -GameRunning $false -NowUtc $t.AddHours(1)
Assert-Session (-not $s.ShouldCollect) 'old existing logs never autoexport before game'
$s = Update-MtzSessionState -State $s -Fingerprint 'new' -ProcessStateKnown $false -GameRunning $false -NowUtc $t.AddHours(1).AddSeconds(1)
Assert-Session ($s.SeenLogChange -and -not $s.ShouldCollect -and -not $s.Completed) 'unknown process plus changed logs cannot claim session ended'
$s = Update-MtzSessionState -State $s -Fingerprint 'new' -ProcessStateKnown $true -GameRunning $true -NowUtc $t.AddHours(1).AddSeconds(2)
Assert-Session ($s.SeenGame -and $s.IsRunning -and -not $s.ShouldCollect) 'running game observed'
$s = Update-MtzSessionState -State $s -Fingerprint 'new2' -ProcessStateKnown $true -GameRunning $true -NowUtc $t.AddHours(1).AddSeconds(10)
Assert-Session ($s.LastChangeUtc -eq $t.AddHours(1).AddSeconds(10)) 'log change time updates'
$s = Update-MtzSessionState -State $s -Fingerprint 'new2' -ProcessStateKnown $true -GameRunning $false -NowUtc $t.AddHours(1).AddSeconds(12)
Assert-Session (-not $s.ShouldCollect -and -not $s.Completed) 'shutdown waits for final quiet period'
$s = Update-MtzSessionState -State $s -Fingerprint 'new3' -ProcessStateKnown $true -GameRunning $false -NowUtc $t.AddHours(1).AddSeconds(20)
Assert-Session (-not $s.ShouldCollect -and $s.LastChangeUtc -eq $t.AddHours(1).AddSeconds(20)) 'late final write restarts quiet interval'
$s = Update-MtzSessionState -State $s -Fingerprint 'new3' -ProcessStateKnown $true -GameRunning $false -NowUtc $t.AddHours(1).AddSeconds(31)
Assert-Session (-not $s.ShouldCollect) 'eleven seconds is not quiet enough'
$s = Update-MtzSessionState -State $s -Fingerprint 'new3' -ProcessStateKnown $true -GameRunning $false -NowUtc $t.AddHours(1).AddSeconds(32)
Assert-Session ($s.ShouldCollect -and $s.Completed) 'closed game plus twelve quiet seconds exports'
$s = Update-MtzSessionState -State $s -Fingerprint 'new3' -ProcessStateKnown $true -GameRunning $false -NowUtc $t.AddHours(1).AddSeconds(40)
Assert-Session (-not $s.ShouldCollect -and $s.Completed) 'completed session exports once'
$s = Update-MtzSessionState -State $s -Fingerprint 'new4' -ProcessStateKnown $true -GameRunning $true -NowUtc $t.AddHours(2)
Assert-Session ($s.IsRunning -and -not $s.Completed -and $s.StartedUtc -eq $t.AddHours(2)) 'new game resets session'
$s = Update-MtzSessionState -State $s -Fingerprint 'new5' -ProcessStateKnown $false -GameRunning $false -NowUtc $t.AddHours(3)
Assert-Session (-not $s.ShouldCollect -and -not $s.Completed) 'process query failure cannot autoexport running history'
foreach ($good in @('https://chatgpt.com/c/12345678-abcd-1234-abcd-123456789012','https://chatgpt.com/g/g-example/c/12345678-abcd','https://chatgpt.com/c/abcd/')) {
    Assert-Session (Test-MtzChatUrl $good) 'valid existing conversation URL'
}
foreach ($bad in @('http://chatgpt.com/c/abc','https://chatgpt.com/','https://chatgpt.com/share/abc','https://chatgpt.com.evil.invalid/c/abc','https://evil.invalid/c/abc','https://chatgpt.com:444/c/abc','https://user@chatgpt.com/c/abc','https://chatgpt.com/c/abc?secret=1','file:///C:/secret','not a URL','')) {
    Assert-Session (-not (Test-MtzChatUrl $bad)) 'invalid or foreign URL rejected'
}
# Mock only the operating-system process query; never inspect this machine's processes.
function Get-CimInstance {
    param($ClassName,$Filter,$ErrorAction)
    return $script:FixtureProcesses
}
$script:FixtureProcesses = @([pscustomobject]@{CommandLine='java -jar unrelated.jar'})
$p = Get-MtzGameProcessState -InstancePath ([IO.Path]::GetTempPath())
Assert-Session ($p.Known -and -not $p.Running) 'unrelated Java process ignored'
$script:FixtureProcesses = @([pscustomobject]@{CommandLine=''})
$p = Get-MtzGameProcessState -InstancePath ([IO.Path]::GetTempPath())
Assert-Session (-not $p.Known -and -not $p.Running) 'unreadable process arguments yield unknown'
$root = Join-Path ([IO.Path]::GetTempPath()) 'mtz-session-test'
$script:FixtureProcesses = @([pscustomobject]@{CommandLine=('java --gameDir "' + $root + '" --accessToken DUMMY')})
$p = Get-MtzGameProcessState -InstancePath $root
Assert-Session ($p.Known -and $p.Running) 'exact selected gameDir detected'
$p = Get-MtzGameProcessState -InstancePath ($root + '-other')
Assert-Session ($p.Known -and -not $p.Running) 'sibling prefix is not selected instance'
$script:FixtureProcesses = @([pscustomobject]@{CommandLine='java --gameDir relative-instance'})
$p = Get-MtzGameProcessState -InstancePath $root
Assert-Session (-not $p.Known) 'relative gameDir yields unknown'
# Tokenization follows the Windows rules even when these fixtures run on Linux.
$windowsExamples = @(
    @{ Input = '"a b c" d e'; Expected = @('a b c', 'd', 'e') },
    @{ Input = '"ab\"c" "\\" d'; Expected = @('ab"c', '\', 'd') },
    @{ Input = 'a\\\b d"e f"g h'; Expected = @('a\\\b', 'de fg', 'h') },
    @{ Input = 'a\\\"b c d'; Expected = @('a\"b', 'c', 'd') },
    @{ Input = 'a\\\\"b c" d e'; Expected = @('a\\b c', 'd', 'e') },
    @{ Input = 'a"b"" c d'; Expected = @('ab" c d') }
)
foreach ($example in $windowsExamples) {
    $parsed = @(Split-MtzWindowsArguments $example.Input)
    Assert-Session ($parsed.Count -eq $example.Expected.Count -and ($parsed -join '|') -ceq ($example.Expected -join '|')) 'documented Windows quote/backslash handling'
}
$spacedRoot = Join-Path ([IO.Path]::GetTempPath()) 'mtz session żółw & !'
foreach ($command in @(
    ('java "--gameDir" "' + $spacedRoot + '"'),
    ('java --gameDir="' + $spacedRoot + '"'),
    ('java "--gameDir=' + $spacedRoot + '"'),
    ('"C:\Program Files\Java\javaw.exe" --gameDir "' + $spacedRoot + '" --username DUMMY')
)) {
    $script:FixtureProcesses = @([pscustomobject]@{ CommandLine = $command })
    $p = Get-MtzGameProcessState -InstancePath $spacedRoot
    Assert-Session ($p.Known -and $p.Running) 'quoted option and equal-sign gameDir styles are recognized'
}
$script:FixtureProcesses = @([pscustomobject]@{ CommandLine = ('java -Dnote="text --gameDir ' + $root + '" -jar unrelated.jar') })
$p = Get-MtzGameProcessState -InstancePath $root
Assert-Session ($p.Known -and -not $p.Running) 'gameDir-looking text inside another argument is ignored'
$script:FixtureProcesses = @([pscustomobject]@{ CommandLine = ('java --gameDirectory "' + $root + '"') })
$p = Get-MtzGameProcessState -InstancePath $root
Assert-Session ($p.Known -and -not $p.Running) 'different option with shared prefix is ignored'
$script:FixtureProcesses = @([pscustomobject]@{ CommandLine = ('java --gameDir "' + $root + '" --gameDir "' + $root + '-other"') })
$p = Get-MtzGameProcessState -InstancePath $root
Assert-Session (-not $p.Known -and -not $p.Running) 'ambiguous repeated gameDir is not guessed'
$script:FixtureProcesses = @([pscustomobject]@{ CommandLine = 'java --gameDir' })
$p = Get-MtzGameProcessState -InstancePath $root
Assert-Session (-not $p.Known) 'missing gameDir value is unknown'
$script:FixtureProcesses = @([pscustomobject]@{ CommandLine = ('java @not-read.txt --gameDir "' + $root + '"') })
$p = Get-MtzGameProcessState -InstancePath $root
Assert-Session ($p.Known -and $p.Running) 'visible gameDir works with JVM argument files without reading them'
$script:FixtureProcesses = @([pscustomobject]@{ CommandLine = 'java @not-read.txt' })
$p = Get-MtzGameProcessState -InstancePath $root
Assert-Session (-not $p.Known -and -not $p.Running) 'hidden argument-file gameDir is not opened or guessed'
Remove-Item function:Get-CimInstance
[void][IO.Directory]::CreateDirectory($OutputDirectory)
[ordered]@{
    status = 'PASS'; checks = $script:Checks; runtime = $PSVersionTable.PSVersion.ToString()
    platform = [Environment]::OSVersion.Platform.ToString(); actualWindowsRun = $false; actualCimProcessQuery = $false
    scope = 'Real pure session state and Windows argument parser; CIM query uses fixtures, no user process arguments collected.'
    sessionSha256 = (Get-FileHash (Join-Path $PSScriptRoot 'session.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputDirectory 'launch-session-results.json') -Encoding utf8
Write-Output ('PASS: ' + $script:Checks + ' session checks')
