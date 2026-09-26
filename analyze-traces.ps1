param(
    # A trace batch directory produced by collect-traces.ps1, e.g. traces\<UTC stamp>
    [Parameter(Mandatory = $true)][string]$TraceRoot,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'results\action-metrics.json')
)

$ErrorActionPreference = 'Stop'

function Convert-AuditArgument {
    param([string]$Value)

    if ($Value.StartsWith('"') -and $Value.EndsWith('"')) {
        return $Value.Substring(1, $Value.Length - 2)
    }

    if ($Value -match '^[0-9A-Fa-f]+$' -and ($Value.Length % 2) -eq 0) {
        try {
            $bytes = for ($i = 0; $i -lt $Value.Length; $i += 2) {
                [Convert]::ToByte($Value.Substring($i, 2), 16)
            }
            return [Text.Encoding]::UTF8.GetString($bytes)
        }
        catch {
            return $Value
        }
    }

    return $Value
}

$rows = foreach ($modelDir in Get-ChildItem -LiteralPath $TraceRoot -Directory) {
    $startText = (Get-Content -Raw -LiteralPath (Join-Path $modelDir.FullName 'model-access-ready-at')).Trim()
    $start = [DateTimeOffset]::ParseExact(
        $startText,
        'yyyy-MM-dd HH:mm:ss ''UTC''',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )

    $sshLog = Get-Content -Raw -LiteralPath (Join-Path $modelDir.FullName 'ssh-commands.log')
    $sessionBlocks = [regex]::Split($sshLog, '(?m)(?=^--- session=)') | Where-Object { $_ -match '^--- session=' }
    $modelBlocks = $sessionBlocks | Where-Object { $_ -notmatch '(?m)^/usr/local/sbin/server-benchmark-collect$' }
    $collectorBlock = $sessionBlocks | Where-Object { $_ -match '(?m)^/usr/local/sbin/server-benchmark-collect$' } | Select-Object -First 1

    if (-not $collectorBlock -or $collectorBlock -notmatch '(?m)^time_utc=(\d{8}T\d{6})(?:\.(\d+))?Z$') {
        throw "Collector boundary is missing for $($modelDir.Name)"
    }
    $end = [DateTimeOffset]::ParseExact(
        $Matches[1] + 'Z',
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    )

    $startEpoch = [double]$start.ToUnixTimeSeconds()
    $endEpoch = [double]$end.ToUnixTimeSeconds() + 1
    $executables = [Collections.Generic.List[string]]::new()
    $rootEventIds = [Collections.Generic.HashSet[string]]::new()
    $auditFiles = @(Get-ChildItem -LiteralPath (Join-Path $modelDir.FullName 'audit-source') -File)

    # EXECVE records do not include the login audit ID. First identify events
    # attributed to the root SSH login (auid=0), excluding background daemons.
    foreach ($auditFile in $auditFiles) {
        foreach ($line in [IO.File]::ReadLines($auditFile.FullName)) {
            if ($line -notmatch '^type=SYSCALL msg=audit\(([0-9]+(?:\.[0-9]+)?):([0-9]+)\):') { continue }
            $epoch = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            $eventId = $Matches[2]
            if ($epoch -lt $startEpoch -or $epoch -ge $endEpoch) { continue }
            if ($line -match '(?:^| )auid=0(?: |$)') {
                [void]$rootEventIds.Add($eventId)
            }
        }
    }

    foreach ($auditFile in $auditFiles) {
        foreach ($line in [IO.File]::ReadLines($auditFile.FullName)) {
            if ($line -notmatch '^type=EXECVE msg=audit\(([0-9]+(?:\.[0-9]+)?):([0-9]+)\):') { continue }
            $epoch = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
            $eventId = $Matches[2]
            if ($epoch -lt $startEpoch -or $epoch -ge $endEpoch) { continue }
            if (-not $rootEventIds.Contains($eventId)) { continue }
            if ($line -match '(?:^| )a0=("(?:\\.|[^"])*"|\S+)') {
                $executables.Add((Convert-AuditArgument $Matches[1]))
            }
            else {
                $executables.Add('<unknown>')
            }
        }
    }

    $firstModelTime = if ($modelBlocks[0] -match '(?m)^time_utc=(\d{8}T\d{6})') { $Matches[1] } else { $null }
    $lastModelTime = if ($modelBlocks[-1] -match '(?m)^time_utc=(\d{8}T\d{6})') { $Matches[1] } else { $null }
    $top = $executables | Group-Object | Sort-Object -Property @(
        @{ Expression = 'Count'; Descending = $true },
        @{ Expression = 'Name'; Descending = $false }
    ) | Select-Object -First 12

    [pscustomobject]@{
        model = $modelDir.Name
        observationStartUtc = $start.ToUniversalTime().ToString('o')
        collectionStartUtc = $end.ToUniversalTime().ToString('o')
        firstModelSshUtc = $firstModelTime
        lastModelSshUtc = $lastModelTime
        sshCalls = @($modelBlocks).Count
        rootSessionExecveCalls = $executables.Count
        uniqueExecutables = @($executables | Sort-Object -Unique).Count
        topExecutables = @($top | ForEach-Object {
            [pscustomobject]@{ executable = $_.Name; count = $_.Count }
        })
    }
}

$rows = @($rows | Sort-Object model)
$rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$rows | Select-Object model, sshCalls, rootSessionExecveCalls, uniqueExecutables | Format-Table -AutoSize
Write-Host "Saved: $OutputPath"
