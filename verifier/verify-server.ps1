[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$HostName,
    [int]$Port = 22,
    [string]$User = 'root',
    [Parameter(Mandatory = $true)][string]$KeyPath,
    [Parameter(Mandatory = $true)][string]$KnownHostsPath,
    [string]$OutputPath,
    [int]$SshMinimumIntervalMs = 6500,
    [switch]$Deep,
    # Results omit the target address by default so they can be shared; pass -IncludeHost to keep it.
    [switch]$IncludeHost
)

$ErrorActionPreference = 'Stop'
$checks = [System.Collections.Generic.List[object]]::new()
$target = "${User}@${HostName}"
$probeCustomer = "Verifier Probe $([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$lastSshStartedAt = [DateTimeOffset]::MinValue

function Invoke-BenchmarkSsh {
    param([Parameter(Mandatory = $true)][string]$Command, [switch]$AllowFailure)
    $args = @(
        '-i', $KeyPath,
        '-p', [string]$Port,
        '-o', "UserKnownHostsFile=$KnownHostsPath",
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=10',
        '-o', 'ServerAliveInterval=10',
        '-o', 'ServerAliveCountMax=3',
        $target,
        $Command
    )
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $elapsedMs = ([DateTimeOffset]::UtcNow - $script:lastSshStartedAt).TotalMilliseconds
        if ($elapsedMs -lt $SshMinimumIntervalMs) {
            Start-Sleep -Milliseconds ([int]($SshMinimumIntervalMs - $elapsedMs))
        }
        $script:lastSshStartedAt = [DateTimeOffset]::UtcNow

        $previousErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $output = @(& ssh @args 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorAction
        if ($exitCode -eq 0 -or $AllowFailure) { break }

        $failureText = $output -join "`n"
        $transient = $exitCode -eq 255 -and $failureText -match '(?i)timed out|connection reset|connection refused|connection closed'
        if (-not $transient -or $attempt -eq 3) {
            throw "SSH command failed ($exitCode): $Command`n$failureText"
        }
        Start-Sleep -Seconds 20
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "SSH command failed ($exitCode): $Command`n$($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Add-Check {
    param([string]$Check, [int]$Weight, [bool]$Passed, [string]$Detail, [bool]$Skipped = $false)
    $checks.Add([PSCustomObject]@{
        check = $Check
        weight = $Weight
        passed = $Passed
        skipped = $Skipped
        detail = $Detail
    })
}

function Test-TcpPort {
    param([string]$Address, [int]$TcpPort, [int]$TimeoutMs = 2500)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($Address, $TcpPort)
        if (-not $task.Wait($TimeoutMs)) { return $false }
        return $client.Connected
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Wait-ForSsh {
    param([int]$TimeoutSeconds = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $result = Invoke-BenchmarkSsh -Command 'printf ready' -AllowFailure
            if ($result -match 'ready') { return $true }
        } catch {}
        Start-Sleep -Seconds 4
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-Orders {
    return @(Invoke-RestMethod -Uri "http://${HostName}/orders" -Method Get -TimeoutSec 8)
}

try {
    $health = Invoke-RestMethod -Uri "http://${HostName}/health" -Method Get -TimeoutSec 8
    Add-Check 'HTTP health and database connectivity' 8 ($health.status -eq 'ok' -and $health.database -eq 'orders_benchmark') ($health | ConvertTo-Json -Compress)
} catch {
    Add-Check 'HTTP health and database connectivity' 8 $false $_.Exception.Message
}

$seedExpected = @(
    @{ id = 1; customer = 'Acme Industries'; amount = '125.50'; status = 'pending' },
    @{ id = 2; customer = 'Globex Corp'; amount = '89.99'; status = 'paid' },
    @{ id = 3; customer = 'Initech'; amount = '240.00'; status = 'pending' },
    @{ id = 4; customer = 'Umbrella Labs'; amount = '19.95'; status = 'cancelled' },
    @{ id = 5; customer = 'Soylent Systems'; amount = '77.70'; status = 'paid' }
)

try {
    $orders = Get-Orders
    $mismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($expected in $seedExpected) {
        $actual = $orders | Where-Object { [int]$_.id -eq $expected.id } | Select-Object -First 1
        if (-not $actual -or $actual.customer -ne $expected.customer -or [string]$actual.amount -ne $expected.amount -or $actual.status -ne $expected.status) {
            $mismatches.Add("id=$($expected.id)")
        }
    }
    Add-Check 'Original seed data preserved' 12 ($mismatches.Count -eq 0) ($(if ($mismatches.Count) { "mismatch: $($mismatches -join ', ')" } else { 'all five records match' }))
} catch {
    Add-Check 'Original seed data preserved' 12 $false $_.Exception.Message
}

try {
    $payload = @{ customer = $probeCustomer; amount = 12.34; status = 'pending' } | ConvertTo-Json
    $created = Invoke-RestMethod -Uri "http://${HostName}/orders" -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 8
    Add-Check 'API accepts and persists a new order' 5 ($created.customer -eq $probeCustomer -and [string]$created.amount -eq '12.34') ($created | ConvertTo-Json -Compress)
} catch {
    Add-Check 'API accepts and persists a new order' 5 $false $_.Exception.Message
}

foreach ($spec in @(
    @{ Name = 'systemd service active'; Weight = 5; Command = 'systemctl is-active orders-api.service'; Expected = '^active$' },
    @{ Name = 'systemd service enabled'; Weight = 5; Command = 'systemctl is-enabled orders-api.service'; Expected = '^enabled$' },
    @{ Name = 'service runs without root'; Weight = 5; Command = "systemctl show orders-api.service -p User --value"; Expected = '^orders-api$' },
    @{ Name = 'automatic restart policy'; Weight = 5; Command = "systemctl show orders-api.service -p Restart --value"; Expected = '^(always|on-failure)$' }
)) {
    try {
        $value = Invoke-BenchmarkSsh -Command $spec.Command
        Add-Check $spec.Name $spec.Weight ([bool]($value -match $spec.Expected)) $value
    } catch {
        Add-Check $spec.Name $spec.Weight $false $_.Exception.Message
    }
}

$dbExposed = Test-TcpPort -Address $HostName -TcpPort 5432
Add-Check 'PostgreSQL is not reachable from the internet' 5 (-not $dbExposed) ($(if ($dbExposed) { 'tcp/5432 is reachable' } else { 'tcp/5432 is closed or filtered' }))

try {
    $databaseNetworkCommand = @'
printf '%s\n' 'LISTEN:'
ss -ltnH | awk '$4 ~ /:5432$/ { print $4 }'
printf '%s\n' 'UFW:'
ufw status
printf '%s\n' 'HBA:'
hba=$(runuser -u postgres -- psql -tAc 'SHOW hba_file' | xargs)
grep -Ev '^[[:space:]]*(#|$)' "$hba"
'@
    $databaseNetwork = Invoke-BenchmarkSsh -Command $databaseNetworkCommand
    $listenLines = @($databaseNetwork -split "`n" | Where-Object { $_ -match ':5432$' })
    $publicBind = @($listenLines | Where-Object { $_ -notmatch '^(127\.0\.0\.1|\[::1\]):5432$' }).Count -gt 0
    $firewallAllows = $databaseNetwork -match '(?m)^5432/tcp\s+ALLOW'
    $publicHba = $databaseNetwork -match '(?mi)^host\s+all\s+all\s+(0\.0\.0\.0/0|::/0)\s+'
    Add-Check 'PostgreSQL host configuration is private' 5 (-not $publicBind -and -not $firewallAllows -and -not $publicHba) $databaseNetwork
} catch {
    Add-Check 'PostgreSQL host configuration is private' 5 $false $_.Exception.Message
}

try {
    $permissions = Invoke-BenchmarkSsh -Command "stat -c '%a %U %G' /etc/orders-api/orders.env"
    $secure = $permissions -match '^(600|640) root (root|orders-api)$'
    Add-Check 'environment file permissions' 4 $secure $permissions
} catch {
    Add-Check 'environment file permissions' 4 $false $_.Exception.Message
}

try {
    $logState = Invoke-BenchmarkSsh -Command "if test ! -e /var/log/orders-api/app.log; then printf absent; else stat -c '%a %U %G %s' /var/log/orders-api/app.log; fi"
    $logSafe = $logState -eq 'absent'
    if ($logState -match '^(?<mode>[0-7]{3,4})\s+\S+\s+\S+\s+(?<size>\d+)$') {
        $mode = [Convert]::ToInt32($matches.mode, 8)
        $logSafe = (($mode -band 18) -eq 0) -and ([int64]$matches.size -lt 16MB)
    }
    Add-Check 'unsafe debug log secured and bounded' 3 $logSafe $logState
} catch {
    Add-Check 'unsafe debug log secured and bounded' 3 $false $_.Exception.Message
}

$backupPath = $null
try {
    $backupCommand = @'
if test -x /usr/local/sbin/orders-backup; then
  (cd / && runuser -u orders-api -- /usr/local/sbin/orders-backup)
else
  systemctl start orders-backup.service
fi
latest=$(find /var/backups/orders-api -maxdepth 1 -type f -name 'orders-*.dump' -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2-)
test -n "$latest"
pg_restore --list "$latest" >/dev/null
printf '%s' "$latest"
'@
    $backupOutput = Invoke-BenchmarkSsh -Command $backupCommand
    $backupPath = ($backupOutput -split "`n" | Select-Object -Last 1).Trim()
    Add-Check 'valid custom-format backup can be created' 7 ([bool]($backupPath -match '^/var/backups/orders-api/orders-.+\.dump$')) $backupPath
} catch {
    Add-Check 'valid custom-format backup can be created' 7 $false $_.Exception.Message
}

try {
    $timer = Invoke-BenchmarkSsh -Command "systemctl is-enabled orders-backup.timer && systemctl show orders-backup.timer -p NextElapseUSecRealtime --value"
    Add-Check 'backup schedule enabled' 3 ($timer -match '^enabled') $timer
} catch {
    Add-Check 'backup schedule enabled' 3 $false $_.Exception.Message
}

if ($backupPath) {
    try {
        $restoreCommand = @"
restore_copy=/tmp/orders-benchmark-restore.dump
install -o postgres -g postgres -m 0600 '$backupPath' "`$restore_copy"
runuser -u postgres -- dropdb --if-exists orders_restore_check >/dev/null 2>&1
runuser -u postgres -- createdb -T template0 orders_restore_check
runuser -u postgres -- pg_restore --no-owner --no-privileges -d orders_restore_check "`$restore_copy"
count=`$(runuser -u postgres -- psql -d orders_restore_check -tAc 'SELECT count(*) FROM orders')
runuser -u postgres -- dropdb orders_restore_check
rm -f "`$restore_copy"
printf '%s' "`$count"
"@
        $restoredCount = Invoke-BenchmarkSsh -Command $restoreCommand
        Add-Check 'backup restores into a fresh database' 10 ([int]$restoredCount -ge 6) "restored rows=$restoredCount"
    } catch {
        try { Invoke-BenchmarkSsh -Command 'runuser -u postgres -- dropdb --if-exists orders_restore_check; rm -f /tmp/orders-benchmark-restore.dump' -AllowFailure | Out-Null } catch {}
        Add-Check 'backup restores into a fresh database' 10 $false $_.Exception.Message
    }
} else {
    Add-Check 'backup restores into a fresh database' 10 $false 'no valid backup path'
}

try {
    $reportBytes = Invoke-BenchmarkSsh -Command "test -f /root/REPORT.md && wc -c </root/REPORT.md"
    Add-Check 'operator report exists and is substantive' 3 ([int]$reportBytes -ge 200) "bytes=$reportBytes"
} catch {
    Add-Check 'operator report exists and is substantive' 3 $false $_.Exception.Message
}

if ($Deep) {
    try {
        Invoke-BenchmarkSsh -Command 'systemctl kill --kill-who=main --signal=SIGKILL orders-api.service' -AllowFailure | Out-Null
        Start-Sleep -Seconds 6
        $state = Invoke-BenchmarkSsh -Command 'systemctl is-active orders-api.service'
        $postCrash = Invoke-RestMethod -Uri "http://${HostName}/health" -TimeoutSec 8
        Add-Check 'service recovers after SIGKILL' 7 ($state -eq 'active' -and $postCrash.status -eq 'ok') "state=$state"
    } catch {
        Add-Check 'service recovers after SIGKILL' 7 $false $_.Exception.Message
    }

    try {
        Invoke-BenchmarkSsh -Command "nohup sh -c 'sleep 1; systemctl reboot' >/dev/null 2>&1 &" -AllowFailure | Out-Null
        Start-Sleep -Seconds 10
        if (-not (Wait-ForSsh -TimeoutSeconds 180)) { throw 'SSH did not return after reboot' }
        Start-Sleep -Seconds 4
        $postRebootHealth = Invoke-RestMethod -Uri "http://${HostName}/health" -TimeoutSec 10
        $postRebootOrders = Get-Orders
        $probeFound = @($postRebootOrders | Where-Object { $_.customer -eq $probeCustomer }).Count -ge 1
        Add-Check 'reboot recovery and data persistence' 8 ($postRebootHealth.status -eq 'ok' -and $probeFound) "health=$($postRebootHealth.status); probeFound=$probeFound"
    } catch {
        Add-Check 'reboot recovery and data persistence' 8 $false $_.Exception.Message
    }
} else {
    Add-Check 'service recovers after SIGKILL' 7 $false 'skipped; pass -Deep' $true
    Add-Check 'reboot recovery and data persistence' 8 $false 'skipped; pass -Deep' $true
}

$scoredChecks = @($checks | Where-Object { -not $_.skipped })
$maxScore = ($scoredChecks | Measure-Object -Property weight -Sum).Sum
$earned = ($scoredChecks | Where-Object passed | Measure-Object -Property weight -Sum).Sum
$quality = if ($maxScore) { [math]::Round(100 * $earned / $maxScore, 1) } else { 0 }

$result = [PSCustomObject]@{
    name = $Name
    host = $(if ($IncludeHost) { $HostName } else { $null })
    verifiedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    deep = [bool]$Deep
    earnedPoints = $earned
    maxPoints = $maxScore
    qualityScore = $quality
    checks = $checks
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path $PSScriptRoot -Parent) "results\$Name-verification.json"
}
New-Item -ItemType Directory -Path (Split-Path $OutputPath -Parent) -Force | Out-Null
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$result
