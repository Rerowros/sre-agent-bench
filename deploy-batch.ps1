[CmdletBinding()]
param(
    # Path to a servers JSON file (see config/servers.example.json). Defaults to $env:SRE_BENCH_SERVERS.
    [string]$ServersFile = $env:SRE_BENCH_SERVERS
)

$ErrorActionPreference = 'Stop'
if (-not $ServersFile) { throw 'Pass -ServersFile or set SRE_BENCH_SERVERS (see config/servers.example.json).' }
$bundleRoot = $PSScriptRoot
$serverSource = Join-Path $bundleRoot 'server'
$knownHosts = Join-Path $bundleRoot 'known_hosts'
$resultsDir = Join-Path $bundleRoot 'results'

if (-not (Test-Path -LiteralPath $ServersFile)) {
    throw "Servers file not found: $ServersFile"
}

$servers = @((Get-Content -LiteralPath $ServersFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
if ($servers.Count -eq 0) { throw 'Servers file is empty.' }
$duplicateNames = @($servers | Group-Object -Property name | Where-Object Count -gt 1)
if ($duplicateNames.Count) { throw "Server names must be unique: $($duplicateNames.Name -join ', ')" }

foreach ($server in $servers) {
    if (-not $server.name -or -not $server.host -or -not $server.port -or -not $server.user -or -not $server.keyPath) {
        throw 'Every server entry must contain name, host, port, user, and keyPath.'
    }
    if ($server.user -ne 'root') { throw "$($server.name): current bundle requires user=root" }
    if ($server.host -match '^203\.0\.113\.') { throw "$($server.name): replace the documentation IP address" }
    if (-not (Test-Path -LiteralPath $server.keyPath)) { throw "$($server.name): SSH key not found: $($server.keyPath)" }
}

New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
if (-not (Test-Path -LiteralPath $knownHosts)) { New-Item -ItemType File -Path $knownHosts | Out-Null }

$startedAt = Get-Date
$jobs = foreach ($server in $servers) {
    Start-Job -Name $server.name -ArgumentList $server, $serverSource, $knownHosts -ScriptBlock {
        param($server, $serverSource, $knownHosts)
        $ErrorActionPreference = 'Continue'

        $target = "$($server.user)@$($server.host)"
        $sshArgs = @(
            '-i', $server.keyPath,
            '-p', [string]$server.port,
            '-o', "UserKnownHostsFile=$knownHosts",
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=12',
            '-o', 'ServerAliveInterval=15',
            '-o', 'ServerAliveCountMax=4'
        )
        $scpArgs = @(
            '-O',
            '-i', $server.keyPath,
            '-P', [string]$server.port,
            '-o', "UserKnownHostsFile=$knownHosts",
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=12'
        )

        $transcript = [System.Collections.Generic.List[string]]::new()
        $transcript.Add("[$($server.name)] deployment started at $((Get-Date).ToUniversalTime().ToString('o'))")

        $output = @(& ssh @sshArgs $target 'install -d -m 0700 /root/server-benchmark-setup' 2>&1 | ForEach-Object { $_.ToString() })
        $transcript.Add(($output -join "`n"))
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): cannot create remote setup directory" }

        $scriptUploadArgs = @($scpArgs) + @(
            (Join-Path $serverSource 'bootstrap.sh'),
            (Join-Path $serverSource 'inject-faults.sh'),
            (Join-Path $serverSource 'enable-observability.sh'),
            (Join-Path $serverSource 'collect-trace.sh'),
            "${target}:/root/server-benchmark-setup/"
        )
        $output = @(& scp @scriptUploadArgs 2>&1 | ForEach-Object { $_.ToString() })
        $transcript.Add(($output -join "`n"))
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): failed to upload setup scripts" }

        $appUploadArgs = @($scpArgs) + @('-r', (Join-Path $serverSource 'app'), "${target}:/root/server-benchmark-setup/")
        $output = @(& scp @appUploadArgs 2>&1 | ForEach-Object { $_.ToString() })
        $transcript.Add(($output -join "`n"))
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): failed to upload application" }

        $remoteCommand = @'
set -Eeuo pipefail
chmod 0700 /root/server-benchmark-setup/*.sh
bash /root/server-benchmark-setup/bootstrap.sh
bash /root/server-benchmark-setup/inject-faults.sh
bash /root/server-benchmark-setup/enable-observability.sh /root/server-benchmark-setup/collect-trace.sh
rm -rf /root/server-benchmark-setup
date +%s >/var/lib/server-benchmark/model-access-ready-epoch
date -u +%FT%TZ >/var/lib/server-benchmark/model-access-ready-at
'@
        $output = @(& ssh @sshArgs $target $remoteCommand 2>&1 | ForEach-Object { $_.ToString() })
        $transcript.Add(($output -join "`n"))
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): bootstrap or fault injection failed" }

        $transcript.Add("[$($server.name)] deployment finished at $((Get-Date).ToUniversalTime().ToString('o'))")
        [PSCustomObject]@{
            Name = $server.name
            Host = $server.host
            Success = $true
            Transcript = ($transcript -join "`n")
        }
    }
}

Wait-Job -Job $jobs | Out-Null
$records = [System.Collections.Generic.List[object]]::new()
foreach ($job in $jobs) {
    try {
        $payload = Receive-Job -Job $job -ErrorAction Stop
        foreach ($item in @($payload)) {
            if ($item.PSObject.Properties.Name -contains 'Success') { $records.Add($item) }
        }
        if (-not @($payload | Where-Object { $_.PSObject.Properties.Name -contains 'Success' }).Count) {
            $records.Add([PSCustomObject]@{ Name = $job.Name; Host = ''; Success = $false; Transcript = ($payload -join "`n") })
        }
    } catch {
        $records.Add([PSCustomObject]@{ Name = $job.Name; Host = ''; Success = $false; Transcript = $_.Exception.Message })
    } finally {
        Remove-Job -Job $job -Force
    }
}

$stamp = $startedAt.ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$logPath = Join-Path $resultsDir "deploy-$stamp.log"
$records | ForEach-Object {
    "===== $($_.Name) success=$($_.Success) host=$($_.Host) =====`n$($_.Transcript)`n"
} | Set-Content -LiteralPath $logPath -Encoding utf8

$records | Select-Object Name, Host, Success | Format-Table -AutoSize
Write-Host "Deployment log: $logPath"

if (@($records | Where-Object { -not $_.Success }).Count -gt 0) { exit 1 }
