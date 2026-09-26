[CmdletBinding()]
param(
    # Path to a servers JSON file (see config/servers.example.json). Defaults to $env:SRE_BENCH_SERVERS.
    [string]$ServersFile = $env:SRE_BENCH_SERVERS,
    [switch]$Deep,
    [switch]$SkipTraceCollection
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
}
$verifier = Join-Path $PSScriptRoot 'verifier\verify-server.ps1'
$knownHosts = Join-Path $PSScriptRoot 'known_hosts'
$resultsDir = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

if (-not $SkipTraceCollection) {
    $collector = Join-Path $PSScriptRoot 'collect-traces.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $collector -ServersFile $ServersFile
    if ($LASTEXITCODE -ne 0) { throw 'Trace collection failed; verification has not started.' }
}

$jobs = foreach ($server in $servers) {
    $outputPath = Join-Path $resultsDir "$($server.name)-verification.json"
    Start-Job -ArgumentList $verifier, $server, $knownHosts, $outputPath, [bool]$Deep -ScriptBlock {
        param($verifier, $server, $knownHosts, $outputPath, $deep)
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifier,
            '-Name', $server.name,
            '-HostName', $server.host,
            '-Port', [string]$server.port,
            '-User', $server.user,
            '-KeyPath', $server.keyPath,
            '-KnownHostsPath', $knownHosts,
            '-OutputPath', $outputPath
        )
        if ($deep) { $arguments += '-Deep' }
        & powershell @arguments
        if ($LASTEXITCODE -ne 0) { throw "$($server.name): verifier failed" }
    }
}

Wait-Job -Job $jobs | Out-Null
$failed = $false
foreach ($job in $jobs) {
    try {
        Receive-Job -Job $job -ErrorAction Stop | Out-Host
    } catch {
        $failed = $true
        Write-Error $_
    } finally {
        Remove-Job -Job $job -Force
    }
}

Get-ChildItem -LiteralPath $resultsDir -Filter '*-verification.json' | ForEach-Object {
    $result = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
    [PSCustomObject]@{
        Name = $result.name
        Score = $result.qualityScore
        Passed = @($result.checks | Where-Object passed).Count
        Failed = @($result.checks | Where-Object { -not $_.passed -and -not $_.skipped }).Count
        File = $_.FullName
    }
} | Sort-Object Score -Descending | Format-Table -AutoSize

if ($failed) { exit 1 }
