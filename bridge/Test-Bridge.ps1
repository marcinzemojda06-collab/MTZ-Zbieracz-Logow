# SPDX-License-Identifier: MIT
# Self-contained regression checks for Bridge.cs. No Internet access, user files,
# browser session, or elevated permissions are used. Run with PowerShell 5.1+.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not ('Mtz.LogBridge' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Bridge.cs')
}

$script:checks = 0
function Assert-Bridge {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw ('FAILED: ' + $Name) }
    $script:checks++
}

function Invoke-BridgeRequest {
    param([string]$Request)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $client.Connect('127.0.0.1', 17643)
        $client.ReceiveTimeout = 7000
        $client.SendTimeout = 7000
        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::ASCII.GetBytes($Request)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $output = New-Object IO.MemoryStream
        try {
            $buffer = New-Object byte[] 8192
            while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $output.Write($buffer, 0, $n)
                # Respect Content-Length; an oversized rejected request may leave
                # unread incoming bytes and cause a reset after the complete reply.
                $received = [Text.Encoding]::ASCII.GetString($output.ToArray())
                $end = $received.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
                if ($end -ge 0) {
                    $head = $received.Substring(0, $end)
                    if ($head -match '(?im)^Content-Length: ([0-9]+)\r?$') {
                        if ($output.Length -ge ($end + 4 + [int]$Matches[1])) { break }
                    }
                }
            }
            $raw = $output.ToArray()
        } finally { $output.Dispose() }
        $headerEnd = -1
        for ($i = 3; $i -lt $raw.Length; $i++) {
            if ($raw[$i-3] -eq 13 -and $raw[$i-2] -eq 10 -and
                $raw[$i-1] -eq 13 -and $raw[$i] -eq 10) {
                $headerEnd = $i + 1
                break
            }
        }
        if ($headerEnd -lt 0) { throw 'Missing HTTP response header.' }
        $headers = [Text.Encoding]::ASCII.GetString($raw, 0, $headerEnd)
        $body = New-Object byte[] ($raw.Length - $headerEnd)
        [Array]::Copy($raw, $headerEnd, $body, 0, $body.Length)
        return [pscustomobject]@{
            Status = [int]($headers.Split(' ')[1])
            Headers = $headers
            Body = $body
        }
    } finally { $client.Close() }
}

function Request-With {
    param([string]$Token, [string]$Extra = '', [string]$Target = '/v1/bundle', [string]$Method = 'GET')
    return ($Method + ' ' + $Target + " HTTP/1.1`r`nHost: 127.0.0.1:17643`r`n" +
        'Authorization: Bearer ' + $Token + "`r`n" + $Extra + "`r`n")
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ('mtz-bridge-test-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$bridge = New-Object Mtz.LogBridge
try {
    # An empty ZIP is the 22-byte EOCD record; a second ZIP has a one-byte comment.
    $zip = Join-Path $temp 'bundle.zip'
    $first = New-Object byte[] 22
    $first[0] = 0x50; $first[1] = 0x4b; $first[2] = 0x05; $first[3] = 0x06
    [IO.File]::WriteAllBytes($zip, $first)

    $bridge.Start()
    $bridge.Start()
    Assert-Bridge $bridge.IsRunning 'start is idempotent'
    $token = $bridge.Publish($zip)
    Assert-Bridge ($token -cmatch '^[0-9a-f]{64}$') 'cryptographic token shape'
    Assert-Bridge $bridge.HasPublishedPackage 'publication is active'

    $r = Invoke-BridgeRequest (Request-With $token)
    Assert-Bridge ($r.Status -eq 200) 'authorized HTTP download'
    Assert-Bridge ([Convert]::ToBase64String($r.Body) -eq [Convert]::ToBase64String($first)) 'binary response equals snapshot'
    Assert-Bridge ($r.Headers.Contains('Content-Type: application/zip')) 'ZIP content type'
    Assert-Bridge ($r.Headers.Contains('X-MTZ-Filename: bundle.zip')) 'sanitized filename header'
    Assert-Bridge ($r.Headers.Contains('Cache-Control: no-store')) 'no caching'
    Assert-Bridge (-not $r.Headers.Contains('Access-Control-Allow-Origin')) 'no website CORS permission'
    Assert-Bridge ($bridge.DownloadCount -eq 1) 'download count'

    $r = Invoke-BridgeRequest "GET /v1/bundle HTTP/1.1`r`nHost: 127.0.0.1:17643`r`n`r`n"
    Assert-Bridge ($r.Status -eq 403) 'missing authorization rejected'
    $wrong = ('0' * 64)
    if ($wrong -ceq $token) { $wrong = ('1' * 64) }
    $r = Invoke-BridgeRequest (Request-With $wrong)
    Assert-Bridge ($r.Status -eq 403) 'wrong token rejected'
    $r = Invoke-BridgeRequest (Request-With ('g' * 64))
    Assert-Bridge ($r.Status -eq 403) 'nonhex token rejected'
    $r = Invoke-BridgeRequest (Request-With 'short')
    Assert-Bridge ($r.Status -eq 403) 'short token rejected'
    $r = Invoke-BridgeRequest (Request-With $token "Origin: https://example.invalid`r`n")
    Assert-Bridge ($r.Status -eq 403) 'ordinary website origin rejected'
    $r = Invoke-BridgeRequest (Request-With $token ("Origin: chrome-extension://" + ('a' * 32) + "`r`n"))
    Assert-Bridge ($r.Status -eq 200) 'extension origin accepted with valid token'
    $r = Invoke-BridgeRequest (Request-With $token ("Origin: chrome-extension://" + ('a' * 32) + "`n`r`n"))
    Assert-Bridge ($r.Status -eq 400) 'bare LF inside header value rejected'
    $r = Invoke-BridgeRequest (Request-With $token "X-Invalid: before`rafter`r`n")
    Assert-Bridge ($r.Status -eq 400) 'bare CR inside header value rejected'
    $r = Invoke-BridgeRequest (Request-With $token '' '/v1/bundle?path=secrets')
    Assert-Bridge ($r.Status -eq 404) 'query parameters rejected'
    $r = Invoke-BridgeRequest (Request-With $token '' '/other')
    Assert-Bridge ($r.Status -eq 404) 'no arbitrary file route'
    $r = Invoke-BridgeRequest (Request-With $token '' '/v1/bundle' 'POST')
    Assert-Bridge ($r.Status -eq 405) 'POST rejected'
    $r = Invoke-BridgeRequest (Request-With $token ("Authorization: Bearer " + $token + "`r`n"))
    Assert-Bridge ($r.Status -eq 400) 'duplicate authorization rejected'
    $r = Invoke-BridgeRequest (Request-With $token "Host: example.invalid`r`n")
    Assert-Bridge ($r.Status -eq 400) 'duplicate Host rejected'
    $r = Invoke-BridgeRequest (Request-With $token "Transfer-Encoding: chunked`r`n")
    Assert-Bridge ($r.Status -eq 400) 'transfer encoding rejected'
    $r = Invoke-BridgeRequest (Request-With $token "Content-Length: 1`r`n")
    Assert-Bridge ($r.Status -eq 400) 'request body rejected'
    $r = Invoke-BridgeRequest "GET /v1/bundle HTTP/1.1`r`nHost: evil.invalid:17643`r`n`r`n"
    Assert-Bridge ($r.Status -eq 400) 'unexpected Host rejected'
    $r = Invoke-BridgeRequest "GET /v1/bundle HTTP/1.1`r`n`r`n"
    Assert-Bridge ($r.Status -eq 400) 'missing Host rejected'
    $r = Invoke-BridgeRequest "GET /v1/bundle HTTP/1.0`r`nHost: 127.0.0.1:17643`r`n`r`n"
    Assert-Bridge ($r.Status -eq 400) 'unsupported HTTP version rejected'
    $r = Invoke-BridgeRequest (Request-With $token ("X-Large: " + ('x' * 8200) + "`r`n"))
    Assert-Bridge ($r.Status -eq 431) 'oversized request header rejected'

    $second = New-Object byte[] 23
    [Array]::Copy($first, $second, $first.Length)
    $second[20] = 1; $second[22] = 65
    [IO.File]::WriteAllBytes($zip, $second)
    $r = Invoke-BridgeRequest (Request-With $token)
    Assert-Bridge ([Convert]::ToBase64String($r.Body) -eq [Convert]::ToBase64String($first)) 'publication is immutable after disk edit'
    $replacement = $bridge.Publish($zip)
    Assert-Bridge ($replacement -cne $token) 'each publication has a new token'
    $r = Invoke-BridgeRequest (Request-With $token)
    Assert-Bridge ($r.Status -eq 403) 'previous token revoked'
    $r = Invoke-BridgeRequest (Request-With $replacement)
    Assert-Bridge ([Convert]::ToBase64String($r.Body) -eq [Convert]::ToBase64String($second)) 'new publication contains new snapshot'
    Assert-Bridge ($bridge.DownloadCount -eq 1) 'replacement resets count'

    # Force the private deadline only within the test instance; never alter system time.
    $field = [Mtz.LogBridge].GetField('expiresUtc', [Reflection.BindingFlags]'Instance,NonPublic')
    $field.SetValue($bridge, [DateTime]::UtcNow.AddSeconds(-1))
    Assert-Bridge (-not $bridge.HasPublishedPackage) 'expired publication status'
    $r = Invoke-BridgeRequest (Request-With $replacement)
    Assert-Bridge ($r.Status -eq 403) 'expired publication rejected'

    [void]$bridge.Publish($zip)
    $bridge.Revoke()
    Assert-Bridge (-not $bridge.HasPublishedPackage) 'explicit revoke'

    $notZip = Join-Path $temp 'bad.zip'
    [IO.File]::WriteAllText($notZip, 'not a zip file')
    $rejected = $false
    try { [void]$bridge.Publish($notZip) } catch { $rejected = $true }
    Assert-Bridge $rejected 'invalid ZIP signature rejected'

    $tooBig = Join-Path $temp 'too-big.zip'
    $large = [IO.File]::Create($tooBig)
    try { $large.SetLength([Mtz.LogBridge]::MaximumBundleBytes + 1) } finally { $large.Dispose() }
    $rejected = $false
    try { [void]$bridge.Publish($tooBig) } catch { $rejected = $true }
    Assert-Bridge $rejected 'payload cap enforced'

    $bridge.Stop()
    Assert-Bridge (-not $bridge.IsRunning) 'stop closes listener'
    $bridge.Start()
    Assert-Bridge $bridge.IsRunning 'listener can restart'
    Assert-Bridge (-not $bridge.HasPublishedPackage) 'stop revokes publication'

    $slow = New-Object Net.Sockets.TcpClient
    try {
        $slow.Connect('127.0.0.1', 17643)
        $slow.ReceiveTimeout = 7000
        $prefix = [Text.Encoding]::ASCII.GetBytes('GET /v1/bundle HTTP/1.1')
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $slow.GetStream().Write($prefix, 0, $prefix.Length)
        $closed = $slow.GetStream().ReadByte()
        Assert-Bridge ($closed -eq -1 -and $clock.ElapsedMilliseconds -lt 6500) 'partial request has bounded header lifetime'
    } finally { $slow.Close() }

    # Stop must cancel a stalled partial request, not leave a foreground process running.
    $stalled = New-Object Net.Sockets.TcpClient
    try {
        $stalled.Connect('127.0.0.1', 17643)
        $partial = [Text.Encoding]::ASCII.GetBytes('GET /v1/bundle HTTP/1.1')
        $stalled.GetStream().Write($partial, 0, $partial.Length)
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $bridge.Stop()
        Assert-Bridge ($clock.ElapsedMilliseconds -lt 6500) 'stop cancels stalled request'
    } finally { $stalled.Close() }

    $bridge.Dispose()
    $rejected = $false
    try { $bridge.Start() } catch { $rejected = $true }
    Assert-Bridge $rejected 'disposed bridge cannot restart'
    Write-Output ('PASS: ' + $script:checks + ' bridge checks')
} finally {
    $bridge.Dispose()
    if ([IO.Directory]::Exists($temp)) { [IO.Directory]::Delete($temp, $true) }
}
