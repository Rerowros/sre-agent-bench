#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "enable-observability.sh must run as root" >&2
  exit 1
fi

COLLECTOR_SOURCE="${1:-}"
if [[ -z "${COLLECTOR_SOURCE}" || ! -f "${COLLECTOR_SOURCE}" ]]; then
  echo "collector source file is required" >&2
  exit 1
fi

install -d -o root -g root -m 0700 \
  /var/log/server-benchmark \
  /var/log/server-benchmark/sessions \
  /var/lib/server-benchmark

install -o root -g root -m 0700 "${COLLECTOR_SOURCE}" /usr/local/sbin/server-benchmark-collect

cat >/usr/local/sbin/benchmark-session-wrapper <<'WRAPPER'
#!/usr/bin/env bash
set -uo pipefail

LOG_DIR=/var/log/server-benchmark
SESSION_DIR=${LOG_DIR}/sessions
if [[ ! -d "${SESSION_DIR}" ]]; then
  install -d -o root -g root -m 0700 "${LOG_DIR}" "${SESSION_DIR}"
fi

STAMP="$(date -u +%Y%m%dT%H%M%S.%NZ)"
SESSION_ID="${STAMP}-$$"
ORIGINAL="${SSH_ORIGINAL_COMMAND:-}"

(
  flock -x 9
  {
    printf -- '--- session=%s ---\n' "${SESSION_ID}"
    printf 'time_utc=%s\n' "${STAMP}"
    printf 'ssh_connection=%s\n' "${SSH_CONNECTION:-unknown}"
    printf 'interactive=%s\n' "$(if [[ -z "${ORIGINAL}" ]]; then printf true; else printf false; fi)"
    printf 'command_begin\n%s\ncommand_end\n' "${ORIGINAL}"
  } >>"${LOG_DIR}/ssh-commands.log"
) 9>/run/lock/server-benchmark-trace.lock

if [[ -n "${ORIGINAL}" ]]; then
  exec /bin/bash -lc "${ORIGINAL}"
fi

exec /usr/bin/script -qef -c /bin/bash "${SESSION_DIR}/${SESSION_ID}.typescript"
WRAPPER
chmod 0700 /usr/local/sbin/benchmark-session-wrapper

cat >/etc/ssh/sshd_config.d/90-server-benchmark-observability.conf <<'SSHD'
Match User root
    ForceCommand /usr/local/sbin/benchmark-session-wrapper
    PermitTTY yes
Match all
SSHD
chmod 0600 /etc/ssh/sshd_config.d/90-server-benchmark-observability.conf
sshd -t

tar --ignore-failed-read --exclude='opt/orders-api/.venv' --exclude='*/__pycache__' \
  -C / -czf /var/lib/server-benchmark/initial-state.tar.gz \
  etc/orders-api \
  etc/nginx/sites-available/orders-api \
  etc/systemd/system/orders-api.service \
  etc/systemd/system/orders-backup.service \
  etc/systemd/system/orders-backup.timer \
  etc/postgresql \
  usr/local/sbin/orders-backup \
  opt/orders-api
chmod 0600 /var/lib/server-benchmark/initial-state.tar.gz

cat >/etc/audit/rules.d/server-benchmark.rules <<'RULES'
-a always,exit -F arch=b64 -S execve,execveat -F euid=0 -k benchmark_exec
-a always,exit -F arch=b32 -S execve,execveat -F euid=0 -k benchmark_exec
-w /etc/orders-api -p wa -k benchmark_files
-w /etc/nginx/sites-available/orders-api -p wa -k benchmark_files
-w /etc/systemd/system/orders-api.service -p wa -k benchmark_files
-w /etc/systemd/system/orders-backup.service -p wa -k benchmark_files
-w /etc/systemd/system/orders-backup.timer -p wa -k benchmark_files
-w /usr/local/sbin/orders-backup -p wa -k benchmark_files
-w /opt/orders-api -p wa -k benchmark_files
RULES
chmod 0600 /etc/audit/rules.d/server-benchmark.rules

date -u '+%Y-%m-%d %H:%M:%S UTC' >/var/lib/server-benchmark/trace-start-at
systemctl enable --now auditd
augenrules --load
auditctl -l | grep -q 'benchmark_exec'

systemctl reload ssh.service
echo "Observability enabled."
