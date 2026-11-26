#requires -Version 7.2
<#
.SYNOPSIS
  Lists the B2 application keys, or deletes one by name.

.DESCRIPTION
  The B2 web UI did not show the keys b2-setup.ps1 made through the API
  (seen 2026-11-26), so this is how to see them and how to revoke one, for
  example a server's key after that server is compromised.

  The owner runs this in their own PowerShell window, never through an AI
  session: it asks for the B2 master application key. Generate a new one
  first, and another one afterwards that you don't save. It prints no
  secret: key names, ids, buckets and capabilities only.

  Deleting a server's key stops its backups until b2-setup.ps1 makes a new
  one (delete the old key first: b2-setup.ps1 refuses an existing name).

.EXAMPLE
  pwsh -File .\b2-keys.ps1
.EXAMPLE
  pwsh -File .\b2-keys.ps1 -Delete backup-pi
#>
param(
    [ValidatePattern('^[A-Za-z0-9-]+$')]
    [string] $Delete
)
$ErrorActionPreference = 'Stop'

# As in b2-setup.ps1: on failure, only B2's own error, never PowerShell's,
# which can quote the request headers (the key or the session token).
function Invoke-B2Api([string] $Method, [string] $Uri, [string] $Authorization, [string] $Json) {
    $p = @{
        Method               = $Method
        Uri                  = $Uri
        Headers              = @{ Authorization = $Authorization }
        SkipHeaderValidation = $true
    }
    if ($Json) { $p.ContentType = 'application/json'; $p.Body = $Json }
    try {
        Invoke-RestMethod @p
    } catch {
        $e = $null
        try { $e = $_.ErrorDetails.Message | ConvertFrom-Json } catch { }
        $detail = if ($e.code) { "$($e.status) $($e.code): $($e.message)" } else { $_.Exception.GetType().Name }
        throw "B2 $($Uri -replace '^.*/', '') failed: $detail"
    }
}

$keyId = (Read-Host 'B2 master keyID').Trim()
$keySecure = Read-Host 'B2 master applicationKey' -AsSecureString
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        "${keyId}:$(ConvertFrom-SecureString $keySecure -AsPlainText)"))
$auth = Invoke-B2Api Get 'https://api.backblazeb2.com/b2api/v4/b2_authorize_account' "Basic $basic"
Remove-Variable basic, keySecure
$api = $auth.apiInfo.storageApi
foreach ($c in 'listKeys', 'listBuckets') {
    if ($api.allowed.capabilities -notcontains $c) { throw "That key lacks $c. Use the master application key." }
}
if ($Delete -and $api.allowed.capabilities -notcontains 'deleteKeys') { throw 'That key lacks deleteKeys. Use the master application key.' }

function Invoke-B2([string] $Call, [hashtable] $Body) {
    Invoke-B2Api Post "$($api.apiUrl)/b2api/v4/$Call" $auth.authorizationToken ($Body | ConvertTo-Json -Depth 10 -Compress)
}

$bucketNames = @{}
foreach ($b in (Invoke-B2 b2_list_buckets @{ accountId = $auth.accountId }).buckets) { $bucketNames[$b.bucketId] = $b.bucketName }

$keys = [Collections.Generic.List[object]]::new()
$start = $null
do {
    $body = @{ accountId = $auth.accountId; maxKeyCount = 1000 }
    if ($start) { $body.startApplicationKeyId = $start }
    $page = Invoke-B2 b2_list_keys $body
    $page.keys | ForEach-Object { $keys.Add($_) }
    $start = $page.nextApplicationKeyId
} while ($start)

$rows = $keys | ForEach-Object {
    [pscustomobject]@{
        Name         = $_.keyName
        KeyId        = $_.applicationKeyId
        Buckets      = if ($_.bucketIds) { ($_.bucketIds | ForEach-Object { $bucketNames[$_] ?? $_ }) -join ', ' } else { '(all)' }
        Prefix       = $_.namePrefix
        Capabilities = ($_.capabilities | Sort-Object) -join ' '
        Expires      = if ($_.expirationTimestamp) { [DateTimeOffset]::FromUnixTimeMilliseconds($_.expirationTimestamp).ToString('u') } else { 'never' }
    }
}
Write-Host "$($keys.Count) application key(s) (the master key is not listed):"
$rows | Format-List | Out-Host

if ($Delete) {
    $match = @($keys | Where-Object keyName -eq $Delete)
    if ($match.Count -eq 0) { throw "No key named $Delete." }
    if ($match.Count -gt 1) { throw "$($match.Count) keys are named $Delete; delete by id in the API or the web UI." }
    $answer = Read-Host "Delete key $Delete ($($match[0].applicationKeyId))? Type its name to confirm"
    if ($answer -cne $Delete) { Write-Host 'Not deleted.'; return }
    $null = Invoke-B2 b2_delete_key @{ applicationKeyId = $match[0].applicationKeyId }
    Write-Host "Deleted $Delete. It can no longer sign in."
}

Write-Host @"

Now generate a new master application key in the web UI and don't save it.
"@
