[CmdletBinding()]
param(
    # Path to a servers JSON file (see config/servers.example.json). Defaults to $env:SRE_BENCH_SERVERS.
    [string]$ServersFile = $env:SRE_BENCH_SERVERS
)

$ErrorActionPreference = 'Stop'
if (-not $ServersFile) { throw 'Pass -ServersFile or set SRE_BENCH_SERVERS (see config/servers.example.json).' }
$servers = @((Get-Content -LiteralPath $ServersFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
if ($servers.Count -eq 0) { throw 'Servers file is empty.' }
$duplicateNames = @($servers | Group-Object -Property name | Where-Object Count -gt 1)
if ($duplicateNames.Count) { throw "Server names must be unique: $($duplicateNames.Name -join ', ')" }

foreach ($server in $servers) {
    if (-not $server.name -or -not $server.host -or -not $server.port -or -not $server.user -or -not $server.keyPath) {
        throw 'Every server entry must contain name, host, port, user, and keyPath.'
    }
    if ($server.host -match '^203\.0\.113\.') { throw "$($server.name): replace the documentation IP address" }
    if (-not (Test-Path -LiteralPath $server.keyPath)) { throw "$($server.name): SSH key not found: $($server.keyPath)" }
}

$knownHosts = Join-Path $PSScriptRoot 'known_hosts'
if (-not (Test-Path -LiteralPath $knownHosts)) { New-Item -ItemType File -Path $knownHosts | Out-Null }
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$batchDir = Join-Path (Join-Path $PSScriptRoot 'traces') $stamp
New-Item -ItemType Directory -Path $batchDir -Force | Out-Null

$jobs = foreach ($server in $servers) {
    Start-Job -Name $server.name -ArgumentList $server, $knownHosts, $batchDir -ScriptBlock {
        param($server, $knownHosts, $batchDir)
        $ErrorActionPreference = 'Continue'
        $target = "$($server.user)@$($server.host)"
        $sshArgs = @(
            '-i', $server.keyPath,
            '-p', [string]$server.port,
            '-o', "UserKnownHostsFile=$knownHosts",
            '-o', 'StrictHostKeyChecking=accept-new',
            '-o', 'BatchMode=yes',
            '-o', 'ConnectTimeout=12'
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

        $serverDir = Join-Path $batchDir $server.name
        New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
        $archive = Join-Path $serverDir 'trace.tar.gz'

        $remoteOutput = @(& ssh @sshArgs $target '/usr/local/sbin/server-benchmark-collect' 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): remote trace collection failed: $($remoteOutput -join "`n")" }

        $copyArgs = @($scpArgs) + @("${target}:/root/server-benchmark-trace.tar.gz", $archive)
        $copyOutput = @(& scp @copyArgs 2>&1 | ForEach-Object { $_.ToString() })
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): trace download failed: $($copyOutput -join "`n")" }

        & tar -tzf $archive | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): downloaded trace archive is invalid" }
        & tar -xzf $archive -C $serverDir
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): trace archive extraction failed" }

        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        Set-Content -LiteralPath (Join-Path $serverDir 'trace.sha256') -Value "$hash  trace.tar.gz" -Encoding ascii
        [PSCustomObject]@{ Name = $server.name; Success = $true; Path = $serverDir; SHA256 = $hash }
    }
}

Wait-Job -Job $jobs | Out-Null
$records = [System.Collections.Generic.List[object]]::new()
$failed = $false
foreach ($job in $jobs) {
    try {
        $payload = Receive-Job -Job $job -ErrorAction Stop
        foreach ($item in @($payload)) {
            if ($item.PSObject.Properties.Name -contains 'Success') { $records.Add($item) }
        }
    } catch {
        $failed = $true
        $records.Add([PSCustomObject]@{ Name = $job.Name; Success = $false; Path = ''; SHA256 = ''; Error = $_.Exception.Message })
    } finally {
        Remove-Job -Job $job -Force
    }
}

$records | Select-Object Name, Success, Path, SHA256 | Format-Table -AutoSize
Write-Host "Trace batch: $batchDir"
if ($failed) { exit 1 }
