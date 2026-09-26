#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

test -f /var/lib/server-benchmark/model-access-ready-at || fail 'missing ready marker'
test -f /var/lib/server-benchmark/initial-state.tar.gz || fail 'missing initial snapshot'
test -f /var/lib/server-benchmark/trace-start-at || fail 'missing trace marker'

[[ "$(systemctl is-active orders-api.service || true)" == inactive ]] || fail 'orders-api is not inactive'
[[ "$(systemctl is-enabled orders-api.service || true)" == disabled ]] || fail 'orders-api is not disabled'
grep -q 'User=root' /etc/systemd/system/orders-api.service || fail 'service user fault missing'
grep -q 'Restart=no' /etc/systemd/system/orders-api.service || fail 'restart fault missing'
grep -q 'rotation-failed-password' /etc/orders-api/orders.env || fail 'database credential fault missing'
grep -q '127.0.0.1:3999' /etc/nginx/sites-available/orders-api || fail 'nginx upstream fault missing'
grep -q 'orders_archive_old' /usr/local/sbin/orders-backup || fail 'backup database fault missing'
grep -q 'host all all 0.0.0.0/0' /etc/postgresql/16/main/pg_hba.conf || fail 'public pg_hba fault missing'
[[ "$(runuser -u postgres -- psql -Atqc 'show listen_addresses')" == '*' ]] || fail 'public listen fault missing'
ufw status | grep -Eq '^5432/tcp[[:space:]]+ALLOW[[:space:]]+Anywhere' || fail 'public firewall fault missing'
[[ "$(stat -c '%a %U %G %s' /var/log/orders-api/app.log)" == '666 root root 67108864' ]] || fail 'unsafe log fault missing'
[[ "$(runuser -u postgres -- psql -d orders_benchmark -Atqc 'select count(*) from orders')" == 5 ]] || fail 'seed data mismatch'
auditctl -l | grep -q 'benchmark_exec' || fail 'audit exec rule missing'
grep -Rqs 'benchmark-session-wrapper' /etc/ssh/sshd_config /etc/ssh/sshd_config.d || fail 'ssh command logger missing'

printf 'READY %s seeds=5 faults=10 audit=on\n' "$(cat /var/lib/server-benchmark/model-access-ready-at)"
