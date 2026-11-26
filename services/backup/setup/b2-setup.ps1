#requires -Version 7.2
<#
.SYNOPSIS
  Creates (or checks) the B2 backup bucket, makes a hide-only key for one
  server, and places that server's backup secrets on it.

.DESCRIPTION
  The owner runs this in their own PowerShell window, never through an AI
  session: it asks for the B2 master application key. It prints no secret.

  Before running:
  - B2 web UI > Application Keys > Generate New Master Application Key, and
    keep the page open (the key is shown once).
  - The server is prepared: backup-host.sh copied to -HostScript, `prep`
    done, and sudo unlocked (ssh.exe -t <server> sudo -v).

  What it does:
  - Bucket: private, Object Lock on, default retention governance 30 days,
    hidden versions deleted 30 days after hiding. If the bucket exists, its
    settings are checked instead and only the retention is fixed.
  - Key "backup-<server>": this bucket, prefix "<server>/", capabilities
    listBuckets listFiles readFiles writeFiles. It can upload and hide files
    but cannot delete a version or touch retention.
  - A new restic password (only if the server has none: replacing it would
    lock you out of an existing repository) and the repository URL.
  - The values go to the server over ssh, and one at a time to the
    clipboard so you can save them in Vaultwarden. Then it runs `init`.
  - -Admin also creates "backup-admin" (the same capabilities, whole
    bucket) for forget/prune from the PC. Clipboard only.

  Afterwards: generate a new master key again in the web UI and don't save
  it. That invalidates the one used here; the keys made here keep working.

.EXAMPLE
  pwsh -File .\b2-setup.ps1 -Bucket homelab-backups-3f9c2a -Server pi -Admin
#>
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{5,62}$')]
    [string] $Bucket,
    [ValidatePattern('^[a-z0-9-]+$')]
    [string] $Server = 'pi',
    # The ssh alias of the server (C:\Users\<you>\.ssh\config).
    [string] $SshHost = $Server,
    [string] $HostScript = '/home/serbog/backup-setup/setup/backup-host.sh',
    [switch] $Admin
)
$ErrorActionPreference = 'Stop'
$ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'
$caps = @('listBuckets', 'listFiles', 'readFiles', 'writeFiles')

# Runs a command on the server, showing its output; returns the exit code.
function Invoke-Server([string] $Command, [string] $InputText) {
    if ($PSBoundParameters.ContainsKey('InputText')) {
        $InputText | & $ssh $SshHost $Command | Out-Host
    } else {
        & $ssh $SshHost $Command | Out-Host
    }
    return $LASTEXITCODE
}

# --- 1. The server must be ready before any key exists.
Write-Host "Checking $SshHost ..."
if ((Invoke-Server "sudo -n true") -ne 0) {
    throw "sudo is locked on $SshHost. Run: ssh.exe -t $SshHost sudo -v"
}
if ((Invoke-Server "sudo -n test -f $HostScript -a -d /srv/backup/secrets") -ne 0) {
    throw "$HostScript or /srv/backup/secrets is missing on $SshHost (copy the script, run prep)."
}
$present = @(& $ssh $SshHost "sudo -n ls -1 /srv/backup/secrets")

# Calls the B2 API. On failure it throws only B2's own error (status, code,
# message), never PowerShell's: some of those quote the request headers,
# which hold the key or the session token.
function Invoke-B2Api([string] $Method, [string] $Uri, [string] $Authorization, [string] $Json) {
    $p = @{
        Method               = $Method
        Uri                  = $Uri
        Headers              = @{ Authorization = $Authorization }
        # B2's tokens are not "<scheme> <value>", which .NET rejects.
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

# --- 2. Sign in with the master key.
$keyId = (Read-Host 'B2 master keyID').Trim()
$keySecure = Read-Host 'B2 master applicationKey' -AsSecureString
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
        "${keyId}:$(ConvertFrom-SecureString $keySecure -AsPlainText)"))
$auth = Invoke-B2Api Get 'https://api.backblazeb2.com/b2api/v4/b2_authorize_account' "Basic $basic"
Remove-Variable basic, keySecure
$api = $auth.apiInfo.storageApi
foreach ($c in 'listKeys', 'writeKeys', 'listBuckets', 'writeBuckets', 'readBucketRetentions', 'writeBucketRetentions') {
    if ($api.allowed.capabilities -notcontains $c) { throw "That key lacks $c. Use the master application key." }
}

function Invoke-B2([string] $Call, [hashtable] $Body) {
    $Body.accountId = $auth.accountId
    Invoke-B2Api Post "$($api.apiUrl)/b2api/v4/$Call" $auth.authorizationToken ($Body | ConvertTo-Json -Depth 10 -Compress)
}

# --- 3. The bucket.
$bucketInfo = @((Invoke-B2 b2_list_buckets @{ bucketName = $Bucket }).buckets)
if ($bucketInfo.Count -eq 0) {
    Write-Host "Creating bucket $Bucket ..."
    $null = Invoke-B2 b2_create_bucket @{
        bucketName      = $Bucket
        bucketType      = 'allPrivate'
        fileLockEnabled = $true
        lifecycleRules  = @(@{ fileNamePrefix = ''; daysFromHidingToDeleting = 30; daysFromUploadingToHiding = $null })
    }
    $bucketInfo = @((Invoke-B2 b2_list_buckets @{ bucketName = $Bucket }).buckets)
} else {
    Write-Host "Bucket $Bucket exists; checking it."
}
$b = $bucketInfo[0]
if ($b.bucketType -ne 'allPrivate') { throw "$Bucket is $($b.bucketType), not allPrivate." }
if (-not $b.fileLockConfiguration.value.isFileLockEnabled) { throw "$Bucket has Object Lock off. Use a new bucket." }
$retention = $b.fileLockConfiguration.value.defaultRetention
if ($retention.mode -ne 'governance' -or $retention.period.duration -ne 30 -or $retention.period.unit -ne 'days') {
    if ($retention.mode -eq 'compliance') { throw "$Bucket uses compliance mode; the owner chose governance." }
    Write-Host 'Setting default retention: governance, 30 days ...'
    $null = Invoke-B2 b2_update_bucket @{
        bucketId         = $b.bucketId
        defaultRetention = @{ mode = 'governance'; period = @{ duration = 30; unit = 'days' } }
    }
    $b = @((Invoke-B2 b2_list_buckets @{ bucketName = $Bucket }).buckets)[0]
    $retention = $b.fileLockConfiguration.value.defaultRetention
}
$rule = @($b.lifecycleRules | Where-Object { $_.fileNamePrefix -eq '' -and $_.daysFromHidingToDeleting -eq 30 })
if ($rule.Count -eq 0) {
    Write-Warning "$Bucket has no rule deleting hidden versions after 30 days. Set it under Lifecycle Settings ('Keep prior versions for this number of days': 30)."
}
Write-Host ("Bucket {0}: {1}, Object Lock {2} {3} {4}, lifecycle rules: {5}" -f $Bucket, $b.bucketType,
    $retention.mode, $retention.period.duration, $retention.period.unit, ($b.lifecycleRules | ConvertTo-Json -Compress))

# --- 4. Keys.
$existingKeys = @((Invoke-B2 b2_list_keys @{ maxKeyCount = 1000 }).keys)
function New-HideOnlyKey([string] $Name, [string] $Prefix) {
    if ($existingKeys | Where-Object keyName -eq $Name) {
        throw "A key named $Name exists already. Delete it in the web UI (Application Keys) and rerun."
    }
    $body = @{ keyName = $Name; capabilities = $caps; bucketIds = @($b.bucketId) }
    if ($Prefix) { $body.namePrefix = $Prefix }
    $k = Invoke-B2 b2_create_key $body
    if (Compare-Object @($k.capabilities | Sort-Object) @($caps | Sort-Object)) {
        throw "Key $Name came back with capabilities $($k.capabilities -join ' '). Delete it in the web UI."
    }
    Write-Host "Created key $Name ($($k.capabilities -join ' '); prefix '$($k.namePrefix)')."
    return $k
}

function Copy-ForVault([string] $Label, [string] $Value) {
    Set-Clipboard -Value $Value
    $null = Read-Host "Copied $Label. Paste it into Vaultwarden, then press Enter"
}

$serverKey = New-HideOnlyKey "backup-$Server" "$Server/"
$repo = "s3:$($api.s3ApiUrl)/$Bucket/$Server"

Write-Host "Placing secrets on $SshHost ..."
$flag = if ($present -contains 's3_credentials') { ' --replace' } else { '' }
if ((Invoke-Server "sudo -n bash $HostScript secret s3_credentials$flag" "$($serverKey.applicationKeyId)`n$($serverKey.applicationKey)") -ne 0) {
    throw "Placing s3_credentials failed. Delete key backup-$Server in the web UI before rerunning."
}
$flag = if ($present -contains 'restic_repository') { ' --replace' } else { '' }
if ((Invoke-Server "sudo -n bash $HostScript secret restic_repository$flag" $repo) -ne 0) { throw 'Placing restic_repository failed.' }
$password = $null
if ($present -contains 'restic_password') {
    Write-Host 'The server already has a restic password; keeping it.'
} else {
    $password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    if ((Invoke-Server "sudo -n bash $HostScript secret restic_password" $password) -ne 0) { throw 'Placing restic_password failed.' }
}

Write-Host "`nSave these in one Vaultwarden item, e.g. 'B2 backup - $Server':"
Copy-ForVault "the key ID of backup-$Server" $serverKey.applicationKeyId
Copy-ForVault "the application key of backup-$Server" $serverKey.applicationKey
if ($password) { Copy-ForVault "the restic password for $Server" $password }
Copy-ForVault 'the repository URL' $repo

if ($Admin) {
    $adminKey = New-HideOnlyKey 'backup-admin' ''
    Write-Host "`nSave these in a Vaultwarden item 'B2 backup - admin':"
    Copy-ForVault 'the key ID of backup-admin' $adminKey.applicationKeyId
    Copy-ForVault 'the application key of backup-admin' $adminKey.applicationKey
    Copy-ForVault 'the S3 endpoint' $api.s3ApiUrl
}
Set-Clipboard -Value ' '

Write-Host "`nCreating the repository on $SshHost ..."
if ((Invoke-Server "sudo -n bash $HostScript init") -ne 0) {
    Write-Warning "init failed. The keys exist and the secrets are placed; after fixing the cause, run on ${SshHost}: sudo bash $HostScript init"
}

Write-Host @"

Done. Now:
- B2 web UI > Application Keys > Generate New Master Application Key, and
  don't save it. That kills the master key used here.
- If Windows clipboard history is on: Win+V > Clear all.
"@
