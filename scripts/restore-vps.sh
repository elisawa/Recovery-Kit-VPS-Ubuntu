#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# VPS FULL RESTORE v2
# Restore a backup created by backup-vps.sh.
# Run on a rebuilt VPS. Docker must already be installed.
# SSH is NEVER overwritten automatically.
# ============================================================

BACKUP_DIR=""
YES=0
SKIP_SYSTEM=0

usage() {
  cat <<'EOF'
Usage:
  sudo ./restore-vps.sh --backup-dir /path/to/backup
  sudo ./restore-vps.sh --backup-dir /path/to/backup --yes

Options:
  --backup-dir PATH   Recovery backup directory (required)
  --yes               Skip confirmation
  --skip-system       Skip Docker/UFW/Fail2Ban/cron/systemd restore
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2 ;;
    --yes) YES=1; shift ;;
    --skip-system) SKIP_SYSTEM=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1"; usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root/sudo."; exit 1; }
[[ -n "$BACKUP_DIR" ]] || { echo "ERROR: --backup-dir is required."; exit 1; }
BACKUP_DIR="$(realpath "$BACKUP_DIR")"
[[ -d "$BACKUP_DIR" ]] || { echo "ERROR: backup not found: $BACKUP_DIR"; exit 1; }
[[ -f "$BACKUP_DIR/manifest/checksums.sha256" ]] || { echo "ERROR: checksum file missing."; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command missing: $1"; exit 1; }; }
need_file() { [[ -f "$1" ]] || { echo "ERROR: missing file: $1"; exit 1; }; }
need_dir() { [[ -d "$1" ]] || { echo "ERROR: missing directory: $1"; exit 1; }; }
confirm() {
  [[ "$YES" -eq 1 ]] && return 0
  read -r -p "$1 [yes/NO]: " a
  [[ "$a" == yes ]]
}

restore_tar() {
  local archive="$1" dest="$2"
  need_file "$archive"
  mkdir -p "$dest"
  tar -xzf "$archive" -C "$dest"
}

compose_up() {
  local f="$1"
  [[ -f "$f" ]] || { echo "ERROR: compose file missing: $f"; exit 1; }
  docker compose -f "$f" up -d
}

wait_pg() {
  for i in {1..60}; do
    if docker exec postgres pg_isready -U admin -d postgres >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "ERROR: PostgreSQL did not become ready."; exit 1
}

echo "============================================================"
echo " VPS FULL RESTORE v2"
echo "============================================================"
echo "Backup: $BACKUP_DIR"
echo

need_cmd docker
need_cmd tar
need_cmd sha256sum
need_cmd systemctl

if [[ ! -f /opt/stacks/n8n/compose.yaml ]]; then
  echo "NOTE: this looks like a fresh VPS."
fi

echo "WARNING: this restores application data onto this VPS."
echo "Use it on a rebuilt/fresh VPS whenever possible."
confirm "Continue with RESTORE?" || { echo "Cancelled."; exit 0; }

# ------------------------------------------------------------
# 1. Verify every backup file before changing anything.
# ------------------------------------------------------------
echo "[1/11] Verifying backup integrity..."
(
  cd "$BACKUP_DIR"
  sha256sum -c manifest/checksums.sha256
)
echo "Checksum verification: OK"

# ------------------------------------------------------------
# 2. Restore stack definitions/configuration.
# Data directories are intentionally excluded from this copy and
# restored from their dedicated archives below.
# ------------------------------------------------------------
echo "[2/11] Restoring Compose/configuration..."
mkdir -p /opt/stacks /opt/npm /opt/dockge /opt/content-factory/docker /opt/scripts

cp -a "$BACKUP_DIR/docker/compose/stacks/." /opt/stacks/
cp -a "$BACKUP_DIR/docker/compose/npm/." /opt/npm/
cp -a "$BACKUP_DIR/docker/compose/dockge/." /opt/dockge/
cp -a "$BACKUP_DIR/docker/compose/content-factory-docker/." /opt/content-factory/docker/

# ------------------------------------------------------------
# 3. Restore application data.
# ------------------------------------------------------------
echo "[3/11] Restoring Docker application data..."
restore_tar "$BACKUP_DIR/docker/data/n8n-data.tar.gz" /opt/stacks/n8n
restore_tar "$BACKUP_DIR/docker/data/cloudbeaver-data.tar.gz" /opt/stacks/cloudbeaver
restore_tar "$BACKUP_DIR/docker/data/uptime-kuma-data.tar.gz" /opt/stacks/uptime-kuma
restore_tar "$BACKUP_DIR/docker/data/npm-data.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/npm-letsencrypt.tar.gz" /opt/npm
restore_tar "$BACKUP_DIR/docker/data/dockge-data.tar.gz" /opt/dockge

# ------------------------------------------------------------
# 4. Restore named Docker volumes.
# ------------------------------------------------------------
echo "[4/11] Restoring Docker volumes..."
docker volume create portainer_portainer_data >/dev/null

docker run --rm \
  -v portainer_portainer_data:/target \
  -v "$BACKUP_DIR/docker/volumes":/backup:ro \
  alpine sh -c 'tar xzf /backup/portainer_portainer_data.tar.gz -C /target'

if [[ -f "$BACKUP_DIR/docker/volumes/n8n-sandbox_sandbox-tls.tar.gz" ]]; then
  docker volume create n8n-sandbox_sandbox-tls >/dev/null
  docker run --rm \
    -v n8n-sandbox_sandbox-tls:/target \
    -v "$BACKUP_DIR/docker/volumes":/backup:ro \
    alpine sh -c 'tar xzf /backup/n8n-sandbox_sandbox-tls.tar.gz -C /target'
fi

# ------------------------------------------------------------
# 5. Prepare proxy network.
# ------------------------------------------------------------
echo "[5/11] Preparing Docker network..."
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy >/dev/null

# ------------------------------------------------------------
# 6. PostgreSQL first.
# ------------------------------------------------------------
echo "[6/11] Starting PostgreSQL..."
compose_up /opt/stacks/postgres/compose.yaml
wait_pg

need_file "$BACKUP_DIR/postgres/globals.sql"
need_file "$BACKUP_DIR/postgres/n8n_konten.dump"
need_file "$BACKUP_DIR/postgres/postgres.dump"

# Restore roles. Existing-role errors are acceptable, but other
# SQL errors are surfaced so a broken globals restore is visible.
docker exec -i postgres psql -U admin -d postgres < "$BACKUP_DIR/postgres/globals.sql" || true

# Ensure the n8n role exists and database exists.
if ! docker exec postgres psql -U admin -d postgres -tAc "SELECT 1 FROM pg_roles WHERE rolname='n8n'" | grep -q 1; then
  echo "ERROR: PostgreSQL role n8n was not restored."; exit 1
fi
if ! docker exec postgres psql -U admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='n8n_konten'" | grep -q 1; then
  docker exec postgres psql -U admin -d postgres -c 'CREATE DATABASE n8n_konten OWNER n8n;'
fi

docker cp "$BACKUP_DIR/postgres/n8n_konten.dump" postgres:/tmp/n8n_konten.dump
docker exec postgres pg_restore -U admin -d n8n_konten --clean --if-exists --no-owner /tmp/n8n_konten.dump
docker exec postgres rm -f /tmp/n8n_konten.dump

docker cp "$BACKUP_DIR/postgres/postgres.dump" postgres:/tmp/postgres.dump
docker exec postgres pg_restore -U admin -d postgres --clean --if-exists --no-owner /tmp/postgres.dump || true
docker exec postgres rm -f /tmp/postgres.dump

# ------------------------------------------------------------
# 7. Restore Render/TTS source and service definitions.
# ------------------------------------------------------------
echo "[7/11] Restoring Render/TTS services..."
rm -rf /opt/render-service /opt/tts-service
restore_tar "$BACKUP_DIR/services/render-service/render-service.tar.gz" /opt
restore_tar "$BACKUP_DIR/services/tts-service/tts-service.tar.gz" /opt

cp "$BACKUP_DIR/services/render-service/render-service.service" /etc/systemd/system/render-service.service
cp "$BACKUP_DIR/services/tts-service/tts-service.service" /etc/systemd/system/tts-service.service

# Existing venvs are restored from the backup. Reinstalling packages
# is attempted only when the venv's pip exists; failures are reported
# but do not destroy the restored venv.
if [[ -x /opt/render-service/venv/bin/pip && -f "$BACKUP_DIR/services/render-service/requirements.freeze.txt" ]]; then
  /opt/render-service/venv/bin/pip install -r "$BACKUP_DIR/services/render-service/requirements.freeze.txt" || echo "WARNING: Render pip dependency refresh failed."
fi
if [[ -x /opt/tts-service/venv/bin/pip && -f "$BACKUP_DIR/services/tts-service/requirements.freeze.txt" ]]; then
  /opt/tts-service/venv/bin/pip install -r "$BACKUP_DIR/services/tts-service/requirements.freeze.txt" || echo "WARNING: TTS pip dependency refresh failed."
fi

if id zkonten >/dev/null 2>&1; then
  chown -R zkonten:zkonten /opt/render-service /opt/tts-service
fi

# ------------------------------------------------------------
# 8. Optional system configuration.
# Never overwrite SSH automatically.
# ------------------------------------------------------------
echo "[8/11] System configuration..."
if [[ "$SKIP_SYSTEM" -eq 0 ]]; then
  tar -xzf "$BACKUP_DIR/system/docker-config.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/ufw.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/fail2ban.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/cron.tar.gz" -C /etc
  tar -xzf "$BACKUP_DIR/system/systemd.tar.gz" -C /etc
  echo "SSH config intentionally NOT restored."
else
  echo "System configuration skipped."
fi

systemctl daemon-reload

# ------------------------------------------------------------
# 9. Start application stacks.
# ------------------------------------------------------------
echo "[9/11] Starting application stacks..."
compose_up /opt/npm/compose.yaml
compose_up /opt/stacks/n8n-sandbox/compose.yaml
compose_up /opt/stacks/n8n/compose.yaml
compose_up /opt/stacks/cloudbeaver/compose.yaml
compose_up /opt/stacks/uptime-kuma/compose.yaml
compose_up /opt/dockge/compose.yaml
compose_up /opt/content-factory/docker/portainer/docker-compose.yml

# ------------------------------------------------------------
# 10. Start native services.
# ------------------------------------------------------------
echo "[10/11] Starting Render/TTS services..."
systemctl enable render-service.service tts-service.service
systemctl restart render-service.service
systemctl restart tts-service.service

# ------------------------------------------------------------
# 11. Health report.
# ------------------------------------------------------------
echo "[11/11] Health check..."
sleep 5

echo
 echo "===== CONTAINERS ====="
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

echo
 echo "===== PROXY NETWORK ====="
docker network inspect proxy --format '{{range .Containers}}{{println .Name}}{{end}}' 2>/dev/null || true

echo
 echo "===== POSTGRES ====="
docker exec postgres psql -U admin -d postgres -c '\l'

echo
 echo "===== RENDER ====="
if curl -fsS http://127.0.0.1:5006/health >/dev/null 2>&1; then echo "Render /health: OK"; else echo "Render /health: FAILED"; fi

echo
 echo "===== TTS SERVICE ====="
systemctl --no-pager --full status tts-service.service --lines=5 || true

echo
 echo "===== n8n ====="
if curl -fsS http://127.0.0.1:5678/healthz >/dev/null 2>&1; then echo "n8n /healthz: OK"; else echo "n8n /healthz: not responding"; fi

echo
 echo "============================================================"
echo " RESTORE FINISHED"
echo "============================================================"
echo "Backup: $BACKUP_DIR"
echo
 echo "IMPORTANT:"
echo "- Verify n8n login and workflows."
echo "- Verify NPM Proxy Hosts and SSL."
echo "- Verify Render/TTS logs."
echo "- Verify SSH before closing this session."
