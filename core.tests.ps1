param([string]$FixtureLog = '')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'core.ps1')
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:Failures = New-Object System.Collections.Generic.List[string]
function Assert-Mtz {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Expect-MtzThrow {
    param([scriptblock]$Action)
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-Mtz $threw 'Expected rejection did not occur.'
}
function Test-Mtz {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        $script:Passed++
        Write-Output ('PASS ' + $Name)
    } catch {
        $script:Failed++
        $script:Failures.Add($Name + ': ' + $_.Exception.Message)
        Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message)
    }
}
function Set-MtzTestText {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Get-MtzTestZipText {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression
    $stream = [System.IO.File]::OpenRead($Path)
    $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        $result = @{}
        foreach ($entry in $zip.Entries) {
            $reader = New-Object System.IO.StreamReader($entry.Open(), (New-Object System.Text.UTF8Encoding($false)))
            try { $result[$entry.FullName] = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        return $result
    } finally { $zip.Dispose(); $stream.Dispose() }
}
$base = Join-Path ([System.IO.Path]::GetTempPath()) ('mtz-collector-selftest-' + [Guid]::NewGuid().ToString('N'))
$instance = Join-Path $base 'instance'
$output = Join-Path $base 'output'
[void][System.IO.Directory]::CreateDirectory($base)
try {
    foreach ($child in @('logs','mods','crash-reports','saves/world','config')) {
        [void][System.IO.Directory]::CreateDirectory((Join-Path $instance $child))
    }
    Set-MtzTestText (Join-Path $instance 'logs/latest.log') "Setting user: MtzTestPlayer`n[main/ERROR] RealMod.java:52 Cannot get config value before config is loaded`n"
    Set-MtzTestText (Join-Path $instance 'logs/debug.log') "--accessToken abcSECRET123 --username MtzTestPlayer`nserverAddress=mc.example.org`n"
    Set-MtzTestText (Join-Path $instance 'saves/world/level.dat') 'NEVER_UPLOAD_WORLD'
    Set-MtzTestText (Join-Path $instance 'config/private.toml') 'NEVER_UPLOAD_CONFIG'
    Set-MtzTestText (Join-Path $instance 'launcher_profiles.json') 'NEVER_UPLOAD_CREDENTIALS'
    Set-MtzTestText (Join-Path $instance 'mods/public-mod-1.2.3.jar') 'NEVER_UPLOAD_MOD_BINARY'
    Set-MtzTestText (Join-Path $instance 'mods/private-mod.jar.disabled') 'NEVER_UPLOAD_DISABLED_BINARY'
    Set-MtzTestText (Join-Path $instance 'mods/ignored.txt') 'NEVER_UPLOAD_OTHER'

    Test-Mtz 'instance validates selected root only' {
        $info = Get-MtzInstanceInfo -InstancePath $instance
        Assert-Mtz ($info.HasLogs -and $info.HasMods) 'Expected logs and mods directories.'
        Expect-MtzThrow { Get-MtzInstanceInfo -InstancePath $base }
        Expect-MtzThrow { Get-MtzInstanceInfo -InstancePath ([System.IO.Path]::GetPathRoot($instance)) }
    }
    Test-Mtz 'traversal and absolute children rejected' {
        foreach ($bad in @('../outside.log', 'logs/../latest.log', 'logs/./latest.log', 'logs//latest.log', ([System.IO.Path]::GetFullPath($base)))) {
            Expect-MtzThrow { Get-MtzSafeChildPath -RootPath $instance -RelativePath $bad -AllowMissing }
        }
    }
    Test-Mtz 'empty instance produces no diagnostic success' {
        $empty = Join-Path $base 'empty'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $empty 'mods'))
        Expect-MtzThrow { New-MtzDiagnosticBundle -InstancePath $empty -OutputDirectory $output }
    }
    Test-Mtz 'fingerprint detects append and truncation' {
        $before = Get-MtzLogFingerprint -InstancePath $instance
        $path = Join-Path $instance 'logs/latest.log'
        [System.IO.File]::AppendAllText($path, "extra line`n")
        $after = Get-MtzLogFingerprint -InstancePath $instance
        Assert-Mtz ($before.Key -ne $after.Key) 'Append not observed.'
        $text = [System.IO.File]::ReadAllText($path)
        Set-MtzTestText $path 'new session'
        Assert-Mtz ((Get-MtzLogFingerprint -InstancePath $instance).Key -ne $after.Key) 'Truncation not observed.'
        Set-MtzTestText $path $text
    }
    Test-Mtz 'fingerprint detects same-size rewrite' {
        $path = Join-Path $instance 'logs/debug.log'
        $before = Get-MtzLogFingerprint -InstancePath $instance
        $text = [System.IO.File]::ReadAllText($path)
        Set-MtzTestText $path ($text.Replace('abcSECRET123','xyzSECRET123'))
        [System.IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddSeconds(2))
        Assert-Mtz ((Get-MtzLogFingerprint -InstancePath $instance).Key -ne $before.Key) 'Equal-size replacement not observed.'
    }
    Test-Mtz 'live writer permits bounded snapshot' {
        $path = Join-Path $instance 'logs/live.log'
        $writer = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("first line`nsecond line`n")
            $writer.Write($bytes, 0, $bytes.Length); $writer.Flush()
            $snapshot = Read-MtzBoundedText -RootPath $instance -RelativePath 'logs/live.log' -MaxBytes 1024
            Assert-Mtz ($snapshot.Text -match 'second line') 'Live snapshot missing data.'
            Assert-Mtz ($snapshot.ReadBytes -eq $bytes.Length) 'Snapshot byte count incorrect.'
        } finally { $writer.Dispose() }
    }
    Test-Mtz 'bounded tail drops partial first line' {
        $path = Join-Path $instance 'logs/tail.log'
        Set-MtzTestText $path (('PRIVATE_PARTIAL_' * 200) + "`nfinal error kept`n")
        $snapshot = Read-MtzBoundedText -RootPath $instance -RelativePath 'logs/tail.log' -MaxBytes 1024
        Assert-Mtz ($snapshot.Truncated -and $snapshot.ReadBytes -le 1024) 'Expected bounded tail.'
        Assert-Mtz ($snapshot.Text -match 'final error kept') 'Final complete line was lost.'
        Assert-Mtz ($snapshot.Text -notmatch 'PRIVATE_PARTIAL') 'Partial private line leaked.'
    }
    Test-Mtz 'bounded huge single line is omitted' {
        Set-MtzTestText (Join-Path $instance 'logs/huge.log') ('A' * 10000)
        $snapshot = Read-MtzBoundedText -RootPath $instance -RelativePath 'logs/huge.log' -MaxBytes 1024
        Assert-Mtz ($snapshot.Truncated -and $snapshot.Text.Length -lt 200) 'Single-line tail not safely bounded.'
    }
    Test-Mtz 'invalid UTF8 does not crash reader' {
        [System.IO.File]::WriteAllBytes((Join-Path $instance 'logs/invalid.log'), [byte[]]@(255,254,128,10,65))
        $snapshot = Read-MtzBoundedText -RootPath $instance -RelativePath 'logs/invalid.log' -MaxBytes 1024
        Assert-Mtz ($snapshot.ReadBytes -eq 5) 'Invalid UTF8 source length lost.'
    }
    Test-Mtz 'redaction removes command line and structured tokens' {
        $text = '--accessToken CLI_TOKEN_SECRET --username MtzTestPlayer --uuid 11111111-2222-3333-4444-555555555555' + "`n" + '{"refreshToken":"JSON_REFRESH_SECRET","client_token":"JSON_CLIENT_SECRET","password":"SECRET WITH SPACES"}'
        $safe = Protect-MtzDiagnosticText -Text $text
        foreach ($secret in @('CLI_TOKEN_SECRET','MtzTestPlayer','11111111-2222-3333-4444-555555555555','JSON_REFRESH_SECRET','JSON_CLIENT_SECRET','SECRET WITH SPACES')) {
            Assert-Mtz (-not $safe.Contains($secret)) 'A test credential value survived redaction.'
        }
    }
    Test-Mtz 'redaction handles actual ModLauncher comma-separated arguments' {
        $text = '--username, FixtureUser, --accessToken, FixtureSecretToken, --clientId, 11223344aabbccdd11223344aabbccdd, --xuid, 11223344556677, --version, neoforge-21.1.236' + "`n" + '--accessToken=FlagEqualsSecret --username=OtherPlayer --uuid=12345678-1234-1234-1234-123456789012'
        $safe = Protect-MtzDiagnosticText -Text $text
        foreach ($secret in @('FixtureUser','FixtureSecretToken','11223344aabbccdd11223344aabbccdd','11223344556677','FlagEqualsSecret','OtherPlayer','12345678-1234-1234-1234-123456789012')) {
            Assert-Mtz (-not $safe.Contains($secret)) 'A ModLauncher argument value survived redaction.'
        }
        Assert-Mtz ($safe.Contains('neoforge-21.1.236')) 'Nonprivate adjacent loader version was lost.'
    }
    Test-Mtz 'redaction handles auth cookies session fields and URLs' {
        $text = "Authorization: Bearer AUTH_SECRET_123`nCookie: session=COOKIE_SECRET_123; other=COOKIE_OTHER_123`nsessionId=SESSION_SECRET_123`nhttps://example.org/path?token=URL_SECRET_123`nmail@example.org"
        $safe = Protect-MtzDiagnosticText -Text $text
        foreach ($secret in @('AUTH_SECRET_123','COOKIE_SECRET_123','COOKIE_OTHER_123','SESSION_SECRET_123','URL_SECRET_123','mail@example.org')) {
            Assert-Mtz (-not $safe.Contains($secret)) 'Auth/cookie/session/URL/email data survived.'
        }
    }
    Test-Mtz 'redaction removes private paths and player aliases' {
        $text = "C:\Users\PrivatePerson\curseforge\minecraft\Instances\MyPack\logs\latest.log`nD:/Games/PrivateInstance/mods`nSetting user: MtzTestPlayer`nPlayer MtzTestPlayer loaded"
        $safe = Protect-MtzDiagnosticText -Text $text -InstancePath 'D:\Games\PrivateInstance'
        Assert-Mtz (-not $safe.Contains('PrivatePerson')) 'Windows profile name survived.'
        Assert-Mtz (-not $safe.Contains('PrivateInstance')) 'Slash-normalized instance path survived.'
        Assert-Mtz (-not $safe.Contains('MtzTestPlayer')) 'Detected player alias survived.'
    }
    Test-Mtz 'redaction preserves diagnostics registry IDs versions and line numbers' {
        $text = "Mekanism version 10.7.19.85`nmekanism-1.21.1-10.7.19.85.jar`nnet.example.RealMod.java:52`nminecraft:iron_ingot`nConnecting to 10.7.19.85, 25565`nConnecting to mc.example.org:25565`nserverAddress=[2001:db8::1234]:25565"
        $safe = Protect-MtzDiagnosticText -Text $text
        Assert-Mtz ($safe.Contains('Mekanism version 10.7.19.85')) 'Dotted mod version was destroyed.'
        Assert-Mtz ($safe.Contains('mekanism-1.21.1-10.7.19.85.jar')) 'Mod filename was destroyed.'
        Assert-Mtz ($safe.Contains('RealMod.java:52') -and $safe.Contains('minecraft:iron_ingot')) 'Diagnostic IDs/lines lost.'
        Assert-Mtz (-not $safe.Contains('Connecting to 10.7.19.85')) 'Server IP survived.'
        Assert-Mtz (-not $safe.Contains('mc.example.org') -and -not $safe.Contains('2001:db8::1234')) 'Server domain/IPv6 survived.'
    }
    Test-Mtz 'redaction preserves suffixed filenames mod tables and JVM versions' {
        $lines = @(
            'Found mod file "garnished-2.1.0.0+1.21.1-neoforged.jar"',
            'Found mod file "aces_spell_utils-1.0.1.2-1.21.1.jar"',
            'Found mod file "owo-lib-neoforge-0.12.1.0-beta.1+1.21.jar.disabled"',
            "`t`tCreate: Garnished 2.1.0.0 (garnished)",
            "`t`tAce's Spell Utils 1.0.1.2-1.21.1 (aces_spell_utils)",
            'JVM identified as Eclipse Adoptium OpenJDK 64-Bit Server VM 21.0.9.0+1-LTS'
        )
        $text = $lines -join "`n"
        Assert-Mtz ((Protect-MtzDiagnosticText -Text $text) -ceq $text) 'Software versions were mistaken for addresses.'
        $addresses = "Connecting to 10.7.19.85, 25565`nserverIP=192.168.1.20`nhost=127.0.0.1:25565"
        $safe = Protect-MtzDiagnosticText -Text $addresses
        Assert-Mtz (-not ($safe -match '10\.7\.19\.85|192\.168\.1\.20|127\.0\.0\.1')) 'Address exception became too broad.'
    }
    Test-Mtz 'redaction keeps Polish diagnostic text' {
        $text = [char]0x0142 + 'adowanie ' + [char]0x017c + 'elaza'
        Assert-Mtz ((Protect-MtzDiagnosticText -Text $text) -ceq $text) 'Nonprivate Unicode text changed.'
    }
    Test-Mtz 'output inside selected instance rejected' {
        Expect-MtzThrow { New-MtzDiagnosticBundle -InstancePath $instance -OutputDirectory (Join-Path $instance 'diagnostics') }
        Expect-MtzThrow { New-MtzDiagnosticBundle -InstancePath $instance -OutputDirectory $instance }
    }
    Test-Mtz 'recent crash reports limited to three safe names' {
        for ($i=0; $i -lt 5; $i++) {
            $path = Join-Path $instance ('crash-reports/crash-PrivatePerson-' + $i + '.txt')
            Set-MtzTestText $path ('CRASH_' + $i)
            [System.IO.File]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddMinutes(-$i))
        }
        $old = Join-Path $instance 'crash-reports/crash-old.txt'
        Set-MtzTestText $old 'OLD_CRASH'
        [System.IO.File]::SetLastWriteTimeUtc($old, [DateTime]::UtcNow.AddDays(-3))
        $bundle = New-MtzDiagnosticBundle -InstancePath $instance -OutputDirectory $output -SessionStartedUtc ([DateTime]::UtcNow.AddMinutes(-10))
        $contents = Get-MtzTestZipText $bundle.ZipPath
        $crashes = @($contents.Keys | Where-Object { $_ -like 'crash-reports/*' })
        Assert-Mtz ($crashes.Count -eq 3) 'Wrong crash limit.'
        Assert-Mtz (@($crashes | Where-Object { $_ -match '^crash-reports/crash-[123]\.txt$' }).Count -eq 3) 'Source crash names exposed.'
        Assert-Mtz ((@($contents.Values) -join "`n") -notmatch 'OLD_CRASH') 'Stale crash included.'
    }
    Test-Mtz 'ZIP allowlist manifest and inventory roundtrip' {
        $bundle = New-MtzDiagnosticBundle -InstancePath $instance -OutputDirectory $output
        $contents = Get-MtzTestZipText $bundle.ZipPath
        foreach ($name in $contents.Keys) {
            Assert-Mtz ($name -match '^(?:logs/(?:latest|debug)\.log|crash-reports/crash-[123]\.txt|mods-inventory\.json|manifest\.json|CZYTAJ\.txt)$') 'Unexpected archive entry.'
        }
        $all = @($contents.Values) -join "`n"
        Assert-Mtz ($all -notmatch 'NEVER_UPLOAD_|SECRET123|MtzTestPlayer|mc\.example\.org|PrivatePerson') 'Private/unselected fixture data was exported.'
        Assert-Mtz ($all -match 'Cannot get config value before config is loaded') 'Real error was lost.'
        $manifest = $contents['manifest.json'] | ConvertFrom-Json
        $inventory = $contents['mods-inventory.json'] | ConvertFrom-Json
        Assert-Mtz ($manifest.modCount -eq 2 -and @($inventory).Count -eq 2) 'Inventory count incorrect.'
        Assert-Mtz (-not $manifest.worldsIncluded -and -not $manifest.configsIncluded -and -not $manifest.modBinariesIncluded -and -not $manifest.networkRequestsMade) 'Manifest scope incorrect.'
        Assert-Mtz (@($inventory | Where-Object { $_.enabled }).Count -eq 1) 'Disabled mod state incorrect.'
        foreach ($entry in $manifest.files) {
            Assert-Mtz ([System.Text.Encoding]::UTF8.GetByteCount($contents[$entry.name]) -eq $entry.archiveBytes) 'Manifest archive byte count differs.'
        }
    }
    Test-Mtz 'source timestamps and stale-session provenance are explicit' {
        $stale = Join-Path $base 'stale'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $stale 'logs'))
        $oldLog = Join-Path $stale 'logs/latest.log'
        Set-MtzTestText $oldLog 'old diagnostic log retained for manual review'
        $oldTime = [DateTime]::UtcNow.AddDays(-2)
        [System.IO.File]::SetLastWriteTimeUtc($oldLog, $oldTime)
        $snapshot = Read-MtzBoundedText -RootPath $stale -RelativePath 'logs/latest.log' -MaxBytes 1024
        Assert-Mtz ($null -ne $snapshot.SourceLastWriteUtc) 'Source write timestamp omitted.'
        Assert-Mtz ([Math]::Abs(($snapshot.SourceLastWriteUtc - $oldTime).TotalSeconds) -lt 2) 'Source write timestamp incorrect.'
        $bundle = New-MtzDiagnosticBundle -InstancePath $stale -OutputDirectory $output -SessionStartedUtc ([DateTime]::UtcNow)
        Assert-Mtz (-not $bundle.Manifest.sessionOnly) 'Snapshot falsely claims session-only contents.'
        Assert-Mtz (@($bundle.Warnings).Count -gt 0) 'Stale latest.log lacks a warning.'
        $contents = Get-MtzTestZipText $bundle.ZipPath
        $manifest = $contents['manifest.json'] | ConvertFrom-Json
        Assert-Mtz (-not [string]::IsNullOrWhiteSpace($manifest.files[0].sourceLastWriteUtc)) 'Archive lacks source write provenance.'
    }
    Test-Mtz 'empty and singleton inventory stays JSON array' {
        $single = Join-Path $base 'single'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $single 'logs'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $single 'mods'))
        Set-MtzTestText (Join-Path $single 'logs/latest.log') 'hello'
        $first = New-MtzDiagnosticBundle -InstancePath $single -OutputDirectory $output
        $firstContents = Get-MtzTestZipText $first.ZipPath
        Assert-Mtz ($firstContents['mods-inventory.json'].Trim() -eq '[]') 'Zero inventory not an array.'
        Set-MtzTestText (Join-Path $single 'mods/one.jar') 'BINARY'
        $second = New-MtzDiagnosticBundle -InstancePath $single -OutputDirectory $output
        $secondContents = Get-MtzTestZipText $second.ZipPath
        Assert-Mtz ($secondContents['mods-inventory.json'].Trim().StartsWith('[')) 'Singleton inventory not an array.'
        Assert-Mtz ($first.ZipPath -ne $second.ZipPath) 'Separate exports overwrite.'
    }
    Test-Mtz 'combined source-byte cap enforced' {
        $big = Join-Path $base 'big'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $big 'logs'))
        Set-MtzTestText (Join-Path $big 'logs/latest.log') (("bounded line`n" * 60000))
        Set-MtzTestText (Join-Path $big 'logs/debug.log') (("bounded debug line`n" * 60000))
        $bundle = New-MtzDiagnosticBundle -InstancePath $big -OutputDirectory $output -MaxLogBytes 1048576 -MaxTotalBytes 1048576
        $sum = ($bundle.IncludedFiles | Measure-Object -Property sourceBytes -Sum).Sum
        $rawBytes = (Get-Item (Join-Path $big 'logs/latest.log')).Length + (Get-Item (Join-Path $big 'logs/debug.log')).Length
        Assert-Mtz ($rawBytes -gt 1048576) 'Invalid cap fixture.'
        $archivedBytes = ($bundle.IncludedFiles | Measure-Object -Property archiveBytes -Sum).Sum
        Assert-Mtz ($archivedBytes -le 1050000) 'Combined text cap materially exceeded.'
        Assert-Mtz (@($bundle.IncludedFiles | Where-Object { $_.tailOnly }).Count -gt 0) 'Truncated source unmarked.'
    }
    Test-Mtz 'symbolic link escape rejected when supported' {
        $outside = Join-Path $base 'outside.log'
        Set-MtzTestText $outside 'NEVER_FOLLOW_SYMLINK'
        $link = Join-Path $instance 'logs/link.log'
        $created = $false
        try { New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop | Out-Null; $created = $true } catch { }
        if ($created) {
            Expect-MtzThrow { Read-MtzBoundedText -RootPath $instance -RelativePath 'logs/link.log' -MaxBytes 1024 }
        } else {
            $script:Skipped++
            Write-Output 'SKIP symbolic link creation requires privilege on this machine.'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($FixtureLog)) {
        Test-Mtz 'real log fixture preserves config exception and strips token values' {
            $text = [System.IO.File]::ReadAllText($FixtureLog)
            $safe = Protect-MtzDiagnosticText -Text $text
            Assert-Mtz ($safe.Contains('Cannot get config value before config is loaded')) 'Historical error missing.'
            foreach ($match in [regex]::Matches($text, '(?i)--accessToken\s+([^\s]+)')) {
                $secret = $match.Groups[1].Value
                if ($secret.Length -gt 4) { Assert-Mtz (-not $safe.Contains($secret)) 'Historical token value survived.' }
            }
            Assert-Mtz ($safe.Length -gt 100000) 'Redactor unexpectedly removed most diagnostics.'
        }
    }
} finally {
    if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
}
Write-Output ('RESULT passed=' + $script:Passed + ' failed=' + $script:Failed + ' skipped=' + $script:Skipped)
if ($script:Failed -gt 0) { throw (($script:Failures.ToArray()) -join "`n") }
