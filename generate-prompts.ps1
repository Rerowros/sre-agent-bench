[CmdletBinding()]
param(
    # Path to a servers JSON file (see config/servers.example.json). Defaults to $env:SRE_BENCH_SERVERS.
    [string]$ServersFile = $env:SRE_BENCH_SERVERS,
    # Task text. TASK.md is the exact (Russian) text used in the published runs; TASK.en.md is an English translation.
    [string]$TaskFile = (Join-Path $PSScriptRoot 'TASK.md'),
    [string]$TemplateFile = (Join-Path $PSScriptRoot 'prompts\TEMPLATE.md')
)

$ErrorActionPreference = 'Stop'
if (-not $ServersFile) { throw 'Pass -ServersFile or set SRE_BENCH_SERVERS (see config/servers.example.json).' }
$task = Get-Content -LiteralPath $TaskFile -Raw -Encoding UTF8
$template = Get-Content -LiteralPath $TemplateFile -Raw -Encoding UTF8
$servers = @((Get-Content -LiteralPath $ServersFile -Raw | ConvertFrom-Json) | ForEach-Object { $_ })
if ($servers.Count -eq 0) { throw 'Servers file is empty.' }
$duplicateNames = @($servers | Group-Object -Property name | Where-Object Count -gt 1)
if ($duplicateNames.Count) { throw "Server names must be unique: $($duplicateNames.Name -join ', ')" }
$promptDir = Join-Path $PSScriptRoot 'prompts'
$knownHosts = Join-Path $PSScriptRoot 'known_hosts'
New-Item -ItemType Directory -Path $promptDir -Force | Out-Null

foreach ($server in $servers) {
    if (-not $server.name -or -not $server.host -or -not $server.port -or -not $server.user -or -not $server.keyPath) {
        throw 'Every server entry must contain name, host, port, user, and keyPath.'
    }
    $sshCommand = "ssh -i `"$($server.keyPath)`" -p $($server.port) -o UserKnownHostsFile=`"$knownHosts`" -o StrictHostKeyChecking=accept-new $($server.user)@$($server.host)"
    $content = $template.Replace('{{NAME}}', $server.name).Replace('{{SSH_COMMAND}}', $sshCommand).Replace('{{TASK}}', $task.Trim())
    $path = Join-Path $promptDir "$($server.name).prompt.md"
    Set-Content -LiteralPath $path -Value $content -Encoding utf8
    Write-Host "$($server.name): $path"
}
