#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "inject-faults.sh must run as root" >&2
  exit 1
fi

if [[ ! -f /var/lib/server-benchmark/baseline-ready-at ]]; then
  echo "Verified baseline is missing" >&2
  exit 1
fi

# Simulate a failed secrets rotation: the role still has its original password,
# while the application receives a new invalid password.
sed -E -i 's#(postgresql://orders_app:)[^@]+#\1rotation-failed-password#' /etc/orders-api/orders.env
chmod 0644 /etc/orders-api/orders.env

# Simulate a reverse-proxy configuration copied from another environment.
sed -i 's/127\.0\.0\.1:3000/127.0.0.1:3999/' /etc/nginx/sites-available/orders-api
nginx -t

# Simulate a rushed service override that weakens both privilege separation and recovery.
sed -i 's/^User=orders-api$/User=root/' /etc/systemd/system/orders-api.service
sed -i 's/^Group=orders-api$/Group=root/' /etc/systemd/system/orders-api.service
sed -i 's/^Restart=on-failure$/Restart=no/' /etc/systemd/system/orders-api.service

# Simulate an accidental public database exposure during remote debugging.
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET listen_addresses = '*';"
PG_HBA="$(runuser -u postgres -- psql -tAc 'SHOW hba_file' | xargs)"
if ! grep -q 'server-benchmark-public-debug' "${PG_HBA}"; then
  printf '\n# server-benchmark-public-debug\nhost all all 0.0.0.0/0 scram-sha-256\n' >>"${PG_HBA}"
fi
ufw allow 5432/tcp >/dev/null

# Simulate a backup script that exits unsuccessfully after targeting the wrong database.
cat >/usr/local/sbin/orders-backup <<'BACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PGPASSFILE=/etc/orders-api/pgpass
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
pg_dump -h 127.0.0.1 -U orders_app -d orders_archive_old -Fc \
  -f "/var/backups/orders-api/orders-${STAMP}.dump"
BACKUP
chown root:root /usr/local/sbin/orders-backup
chmod 0755 /usr/local/sbin/orders-backup
rm -f /var/backups/orders-api/*.dump /var/backups/orders-api/*.tmp

# Simulate an unmanaged, overly permissive application log left by a debugging session.
truncate -s 64M /var/log/orders-api/app.log
chown root:root /var/log/orders-api/app.log
chmod 0666 /var/log/orders-api/app.log

systemctl daemon-reload
systemctl disable orders-api.service >/dev/null
systemctl stop orders-api.service || true
systemctl restart postgresql
systemctl reload nginx

date -u +%FT%TZ >/var/lib/server-benchmark/faults-injected-at

if curl -fsS --max-time 3 http://127.0.0.1/health >/dev/null 2>&1; then
  echo "Fault injection did not make the public service unavailable" >&2
  exit 1
fi

echo "Fault injection verified: the benchmark service is unavailable as expected."
