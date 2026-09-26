#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "server-benchmark-collect must run as root" >&2
  exit 1
fi

OUTPUT="${1:-/root/server-benchmark-trace.tar.gz}"
WORK_DIR="$(mktemp -d /root/server-benchmark-trace.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

install -d -m 0700 "${WORK_DIR}/sessions"
START_AT="$(cat /var/lib/server-benchmark/model-access-ready-at 2>/dev/null || cat /var/lib/server-benchmark/trace-start-at 2>/dev/null || printf 'today')"
START_EPOCH="$(cat /var/lib/server-benchmark/model-access-ready-epoch 2>/dev/null || true)"
AUDIT_START=()
if [[ "${START_EPOCH}" =~ ^[0-9]+$ ]]; then
  AUDIT_START=(--start "$(date -d "@${START_EPOCH}" +%m/%d/%Y)" "$(date -d "@${START_EPOCH}" +%H:%M:%S)")
fi

auditctl --signal sync >/dev/null 2>&1 || true
sleep 1

cp -a /var/log/server-benchmark/sessions/. "${WORK_DIR}/sessions/" 2>/dev/null || true
cp -a /var/log/server-benchmark/ssh-commands.log "${WORK_DIR}/ssh-commands.log" 2>/dev/null || true
cp -a /var/lib/server-benchmark/trace-start-at "${WORK_DIR}/trace-start-at" 2>/dev/null || true
cp -a /var/lib/server-benchmark/model-access-ready-at "${WORK_DIR}/model-access-ready-at" 2>/dev/null || true
cp -a /var/lib/server-benchmark/initial-state.tar.gz "${WORK_DIR}/initial-state.tar.gz" 2>/dev/null || true
cp -a /root/REPORT.md "${WORK_DIR}/REPORT.md" 2>/dev/null || true

ausearch "${AUDIT_START[@]}" -k benchmark_exec --raw >"${WORK_DIR}/audit-exec.raw" 2>&1 || true
ausearch "${AUDIT_START[@]}" -k benchmark_exec -i >"${WORK_DIR}/audit-exec.interpreted.txt" 2>&1 || true
ausearch "${AUDIT_START[@]}" -k benchmark_exec --format csv >"${WORK_DIR}/audit-exec.csv" 2>&1 || true
aureport "${AUDIT_START[@]}" --executable --summary -i >"${WORK_DIR}/audit-executable-summary.txt" 2>&1 || true
ausearch "${AUDIT_START[@]}" -k benchmark_files -i >"${WORK_DIR}/audit-files.interpreted.txt" 2>&1 || true

journalctl --no-pager --since "$(if [[ "${START_EPOCH}" =~ ^[0-9]+$ ]]; then printf '@%s' "${START_EPOCH}"; else printf '%s' "${START_AT}"; fi)" \
  -u orders-api.service -u orders-backup.service -u orders-backup.timer \
  -u nginx.service -u postgresql.service >"${WORK_DIR}/service-journal.txt" 2>&1 || true

{
  printf '%s\n' '=== timestamp ==='
  date -u +%FT%TZ
  printf '%s\n' '=== systemd ==='
  systemctl status --no-pager orders-api.service orders-backup.timer nginx postgresql || true
  printf '%s\n' '=== enabled ==='
  systemctl is-enabled orders-api.service orders-backup.timer nginx postgresql || true
  printf '%s\n' '=== listeners ==='
  ss -lntup || true
  printf '%s\n' '=== firewall ==='
  ufw status verbose || true
  printf '%s\n' '=== processes ==='
  ps auxf || true
  printf '%s\n' '=== disk ==='
  df -hT || true
} >"${WORK_DIR}/final-state.txt" 2>&1

tar --ignore-failed-read --exclude='opt/orders-api/.venv' --exclude='*/__pycache__' \
  -C / -czf "${WORK_DIR}/final-config.tar.gz" \
  etc/orders-api \
  etc/nginx/sites-available/orders-api \
  etc/systemd/system/orders-api.service \
  etc/systemd/system/orders-backup.service \
  etc/systemd/system/orders-backup.timer \
  etc/postgresql \
  usr/local/sbin/orders-backup \
  opt/orders-api \
  var/log/orders-api

printf '%s\n' \
  'This archive may contain commands, configuration values, and disposable-server secrets.' \
  'Do not publish it without reviewing and redacting its contents.' \
  >"${WORK_DIR}/SENSITIVE.txt"

tar -C "${WORK_DIR}" -czf "${OUTPUT}" .
chmod 0600 "${OUTPUT}"
printf '%s\n' "${OUTPUT}"
